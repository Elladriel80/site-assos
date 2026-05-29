-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 9 (montant correct + hold qui expire)
--   ⚠️ À jouer APRÈS la phase 8 (liste d'attente). Cette migration s'appuie
--      sur les signatures de la phase 8 et les préserve (waitlist intacte).
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Corrige DEUX bugs :
--
-- (A) MONTANT — amount_eur était codé en dur à 65 € partout. Une équipe
--     (325 €) était enregistrée à 65 €, d'où l'encaissé admin faux.
--     Tarifs officiels : equipe 325 € · jeu_libre 65 € · narratif 65 €.
--
-- (B) PLACES MANGÉES PAR DES CLICS NON PAYÉS — get_inscription_stock comptait
--     TOUTES les lignes non annulées, y compris les 'pending' jamais payées
--     (12 narratif fantômes, « De Malt En Pils » ×3...). Désormais une place
--     'pending' n'est RÉSERVÉE QUE 30 MINUTES (le temps de payer). Passé ce
--     délai sans paiement, la place se libère automatiquement.
--     → Caps avant paiement (on ne survend pas) MAIS pas de squat éternel.
--
-- Idempotent : rejouable sans risque.
-- =========================================================================

-- Durée du hold (place réservée en attendant le paiement). Modifiable ici.
-- (valeur en dur dans les fonctions ci-dessous : '30 minutes')

-- =========================================================================
-- 1. Fonction de tarification (source de vérité unique des prix)
-- =========================================================================
create or replace function public.inscription_price(p_type text)
returns numeric
language sql
immutable
as $$
  select case p_type
    when 'equipe'    then 325.0
    when 'jeu_libre' then  65.0
    when 'narratif'  then  65.0
    else                   65.0
  end::numeric;
$$;

grant execute on function public.inscription_price(text) to anon, authenticated;

-- =========================================================================
-- 2. get_inscription_stock — HOLD 30 MIN sur les 'pending'
--    Conserve la signature phase 8 (5 colonnes, dont waitlist_count).
--    "taken" = lignes hors waitlist qui sont :
--       - payées / prises en charge (définitif), OU
--       - 'pending' créées il y a moins de 30 min (réservation en cours).
-- =========================================================================
drop function if exists public.get_inscription_stock();
create or replace function public.get_inscription_stock()
returns table(
  inscription_type text,
  capacity         int,
  taken            int,
  remaining        int,
  waitlist_count   int
)
language sql
stable
as $$
  with cap(inscription_type, capacity) as (
    values ('equipe', 12), ('jeu_libre', 50), ('narratif', 10)
  ),
  taken_cte as (
    select inscription_type, count(*)::int as taken
      from public.pending_inscriptions
      where is_waitlist = false
        and (
          payment_status in ('paid','waived')
          or (payment_status = 'pending' and created_at > now() - interval '30 minutes')
        )
      group by inscription_type
  ),
  wait_cte as (
    select inscription_type, count(*)::int as wait_cnt
      from public.pending_inscriptions
      where payment_status <> 'cancelled'
        and is_waitlist = true
      group by inscription_type
  )
  select
    cap.inscription_type,
    cap.capacity,
    coalesce(taken_cte.taken, 0)                            as taken,
    greatest(cap.capacity - coalesce(taken_cte.taken, 0), 0) as remaining,
    coalesce(wait_cte.wait_cnt, 0)                          as waitlist_count
  from cap
    left join taken_cte using (inscription_type)
    left join wait_cte  using (inscription_type)
  order by case cap.inscription_type
    when 'equipe'    then 1
    when 'jeu_libre' then 2
    when 'narratif'  then 3
  end;
$$;

grant execute on function public.get_inscription_stock() to anon, authenticated;

-- =========================================================================
-- 3. create_inscription — prix par type + anti-double-clic
--    Conserve la signature + la logique waitlist de la phase 8.
-- =========================================================================
drop function if exists public.create_inscription(text,text,text,text,text,text,text);
create or replace function public.create_inscription(
  p_nom              text,
  p_prenom           text,
  p_email            text,
  p_telephone        text,
  p_inscription_type text,
  p_team_name        text default null,
  p_role             text default null
)
returns table(
  inscription_id     uuid,
  amount_eur         numeric,
  is_waitlist        boolean,
  waitlist_position  int
)
language plpgsql
security definer
set search_path = public
as $$
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
  select id into v_id
    from public.pending_inscriptions
    where lower(email) = lower(btrim(p_email))
      and inscription_type = p_inscription_type
      and is_waitlist = false
      and payment_status = 'pending'
      and created_at > now() - interval '30 minutes'
    order by created_at desc
    limit 1;
  if v_id is not null then
    return query select v_id, v_amount, false, null::int;
    return;
  end if;

  select remaining into v_remaining
    from public.get_inscription_stock()
    where inscription_type = p_inscription_type;

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
    from public.pending_inscriptions
    where inscription_type = p_inscription_type
      and is_waitlist = true
      and payment_status <> 'cancelled'
      and created_at <= (select created_at from public.pending_inscriptions where id = v_id);
  end if;

  return query select v_id, v_amount, v_waitlist, v_position;
end;
$$;

grant execute on function public.create_inscription(text,text,text,text,text,text,text) to anon, authenticated;

-- =========================================================================
-- 4. admin_create_inscription — prix par type (création depuis l'admin)
-- =========================================================================
create or replace function public.admin_create_inscription(
  p_nom              text,
  p_prenom           text,
  p_email            text,
  p_telephone        text,
  p_inscription_type text,
  p_team_name        text default null,
  p_role             text default null,
  p_status           text default 'pending',
  p_notes            text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if p_inscription_type not in ('equipe','jeu_libre','narratif') then
    raise exception 'Type d''inscription invalide';
  end if;
  if p_status not in ('pending','paid','waived') then
    raise exception 'Statut invalide pour création : %', p_status;
  end if;

  insert into public.pending_inscriptions (
    nom, prenom, email, telephone, inscription_type, team_name, role,
    amount_eur, payment_status, paid_at, admin_notes
  ) values (
    btrim(coalesce(p_nom,'')), btrim(coalesce(p_prenom,'')),
    lower(btrim(coalesce(p_email,''))), nullif(btrim(coalesce(p_telephone,'')),''),
    p_inscription_type, nullif(btrim(coalesce(p_team_name,'')),''), p_role,
    public.inscription_price(p_inscription_type), p_status,
    case when p_status = 'paid' then now() else null end,
    p_notes
  ) returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.admin_create_inscription(text,text,text,text,text,text,text,text,text) to authenticated;

-- =========================================================================
-- 5. DEFAULT de la colonne (évite un futur 65 € par défaut silencieux)
-- =========================================================================
alter table public.pending_inscriptions
  alter column amount_eur drop default;

-- =========================================================================
-- 6. BACKFILL des montants existants
--    ⚠️ Suppose « 1 ligne equipe = 1 équipe entière (325 €) » — confirmé.
--    Recale chaque ligne sur le tarif officiel de son type.
-- =========================================================================
update public.pending_inscriptions
  set amount_eur = public.inscription_price(inscription_type)
  where amount_eur is distinct from public.inscription_price(inscription_type);

-- =========================================================================
-- 7. (OPTIONNEL) Auto-annulation des holds expirés via pg_cron
--    Le point 2 suffit à NE PLUS COMPTER les holds >30 min. Mais ils restent
--    'pending' dans la table (liste admin) et ne déclenchent pas la promotion
--    waitlist. Si tu veux qu'ils passent vraiment en 'cancelled' (ce qui
--    libère ET promeut le 1er en attente), décommente ce bloc une fois.
-- =========================================================================
-- create extension if not exists pg_cron;
-- select cron.schedule(
--   'expire-holds-inscriptions', '*/10 * * * *',
--   $cron$
--     update public.pending_inscriptions
--        set payment_status = 'cancelled',
--            cancelled_at   = now(),
--            admin_notes    = coalesce(admin_notes || E'\n','') || '↳ Hold expiré (>30 min sans paiement)'
--      where payment_status = 'pending'
--        and is_waitlist = false
--        and created_at < now() - interval '30 minutes';
--   $cron$
-- );

-- =========================================================================
-- Vérif : stock + encaissé après migration
-- =========================================================================
select * from public.get_inscription_stock();

select
  inscription_type,
  payment_status,
  count(*)        as nb,
  sum(amount_eur) as total_eur
from public.pending_inscriptions
group by inscription_type, payment_status
order by 1, 2;
