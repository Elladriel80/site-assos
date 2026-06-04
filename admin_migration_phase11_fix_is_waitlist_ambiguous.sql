-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 11 (fix ambiguïté is_waitlist)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Bug : lors de la réservation (RPC create_inscription), Postgres renvoyait
--   « column reference "is_waitlist" is ambiguous ».
-- Cause : la fonction déclare un OUT/RETURNS TABLE nommé `is_waitlist`, qui
--   entre en collision avec la colonne `is_waitlist` de pending_inscriptions
--   dans deux requêtes internes non qualifiées (variable_conflict = error).
-- Correctif : qualifier ces références via un alias de table (pi.is_waitlist).
--   Aucun changement de signature ni de comportement. Idempotent.
-- (Remplace la définition issue de phase9_hold_and_amount.sql.)
-- =========================================================================

create or replace function public.create_inscription(p_nom text, p_prenom text, p_email text, p_telephone text, p_inscription_type text, p_team_name text default null::text, p_role text default null::text)
 returns table(inscription_id uuid, amount_eur numeric, is_waitlist boolean, waitlist_position integer)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_remaining   int;
  v_id          uuid;
  v_amount      numeric;
  v_waitlist    boolean;
  v_position    int;
begin
  -- Validations
  if p_nom    is null or btrim(p_nom)    = '' then raise exception 'Nom obligatoire'; end if;
  if p_prenom is null or btrim(p_prenom) = '' then raise exception 'Prénom obligatoire'; end if;
  if p_email  is null or btrim(p_email)  = '' or p_email !~ '^[^@]+@[^@]+\.[^@]+$' then
    raise exception 'Email invalide';
  end if;
  if p_inscription_type not in ('equipe','jeu_libre','narratif') then
    raise exception 'Type d''inscription invalide : %', p_inscription_type;
  end if;
  if p_role is not null and p_role not in ('capitaine','coequipier') then
    raise exception 'Rôle invalide : %', p_role;
  end if;

  v_amount := public.inscription_price(p_inscription_type);

  -- Verrou par type pour éviter le sold-out en course
  perform pg_advisory_xact_lock(hashtext('pending_inscriptions:' || p_inscription_type)::bigint);

  -- Anti-double-clic : si un hold actif (<30 min) existe déjà pour ce
  -- même email + type, on le réutilise au lieu de créer un doublon.
  select pi.id into v_id
    from public.pending_inscriptions pi
    where lower(pi.email) = lower(btrim(p_email))
      and pi.inscription_type = p_inscription_type
      and pi.is_waitlist = false
      and pi.payment_status = 'pending'
      and pi.created_at > now() - interval '30 minutes'
    order by pi.created_at desc
    limit 1;
  if v_id is not null then
    return query select v_id, v_amount, false, null::int;
    return;
  end if;

  select remaining into v_remaining
    from public.get_inscription_stock() s
    where s.inscription_type = p_inscription_type;

  v_waitlist := coalesce(v_remaining, 0) <= 0;

  insert into public.pending_inscriptions (
    nom, prenom, email, telephone, inscription_type, team_name, role,
    amount_eur, payment_status, is_waitlist
  ) values (
    btrim(p_nom), btrim(p_prenom), lower(btrim(p_email)), nullif(btrim(p_telephone),''),
    p_inscription_type, nullif(btrim(p_team_name),''), p_role,
    v_amount, 'pending', v_waitlist
  ) returning id into v_id;

  if v_waitlist then
    select count(*)::int into v_position
    from public.pending_inscriptions pi
    where pi.inscription_type = p_inscription_type
      and pi.is_waitlist = true
      and pi.payment_status <> 'cancelled'
      and pi.created_at <= (select pi2.created_at from public.pending_inscriptions pi2 where pi2.id = v_id);
  end if;

  return query select v_id, v_amount, v_waitlist, v_position;
end;
$function$;
