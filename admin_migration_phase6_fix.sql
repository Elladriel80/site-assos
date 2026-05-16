-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 6 (FIX : tarif par chambre, pas par pers)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Corrige le modèle après livraison initiale :
--   - Tarifs : 60€ / 90€ / 110€ par CHAMBRE (forfait 2 nuits) — alignés sur
--     la collecte AssoConnect 01KRR18VQF98WSNTRNDGK4RB41.
--   - Capacités : 1 simple, 10 doubles, 3 triples (chambres physiques).
--   - Ajoute la possibilité de capturer les co-occupants prévus dès la
--     réservation (champ optionnel injecté dans admin_notes).
--
-- Cette migration est idempotente : tu peux la re-jouer sans risque.
-- =========================================================================

-- =========================================================================
-- 1. Nouveaux tarifs par CHAMBRE (forfait 2 nuits)
-- =========================================================================
create or replace function public.room_amount(p_type text)
returns numeric language sql immutable as $$
  select case p_type
    when 'simple' then 60.0
    when 'double' then 90.0
    when 'triple' then 110.0
  end::numeric;
$$;

-- =========================================================================
-- 2. Nouvelles capacités (en CHAMBRES, plus en places)
--     simple = 1 · double = 10 · triple = 3   (total = 14 chambres)
-- =========================================================================
create or replace function public.get_room_stock()
returns table(
  room_type     text,
  capacity      int,
  taken         int,
  remaining     int
)
language sql
stable
as $$
  with cap(room_type, capacity) as (
    values ('simple', 1), ('double', 10), ('triple', 3)
  ),
  taken_cte as (
    select room_type, count(*)::int as taken
      from public.room_reservations
      where payment_status <> 'cancelled'
      group by room_type
  )
  select
    cap.room_type,
    cap.capacity,
    coalesce(taken_cte.taken, 0)                       as taken,
    cap.capacity - coalesce(taken_cte.taken, 0)        as remaining
  from cap
    left join taken_cte using (room_type)
  order by case cap.room_type when 'simple' then 1 when 'double' then 2 when 'triple' then 3 end;
$$;

-- =========================================================================
-- 3. RPC create_reservation — ajoute le paramètre optionnel p_co_occupants
--    (injecté en tête d'admin_notes pour rester visible côté admin)
-- =========================================================================
drop function if exists public.create_reservation(text,text,text,text,text);

create or replace function public.create_reservation(
  p_nom            text,
  p_prenom         text,
  p_email          text,
  p_telephone      text,
  p_room_type      text,
  p_co_occupants   text default null
)
returns table(reservation_id uuid, amount_eur numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_remaining int;
  v_amount    numeric;
  v_id        uuid;
  v_note      text;
begin
  if p_nom is null or btrim(p_nom) = ''   then raise exception 'Nom obligatoire'; end if;
  if p_prenom is null or btrim(p_prenom) = '' then raise exception 'Prénom obligatoire'; end if;
  if p_email is null or btrim(p_email) = '' or p_email !~ '^[^@]+@[^@]+\.[^@]+$' then
    raise exception 'Email invalide';
  end if;
  if p_room_type not in ('simple','double','triple') then
    raise exception 'Type de chambre invalide : %', p_room_type;
  end if;

  -- Verrou transactionnel par room_type
  perform pg_advisory_xact_lock(hashtext('room_reservations:' || p_room_type)::bigint);

  select remaining into v_remaining from public.get_room_stock() where room_type = p_room_type;
  if v_remaining is null or v_remaining <= 0 then
    raise exception 'Plus de chambres disponibles en %', p_room_type;
  end if;

  v_amount := public.room_amount(p_room_type);

  v_note := case
    when p_co_occupants is not null and btrim(p_co_occupants) <> ''
    then 'Co-occupants prévus : ' || btrim(p_co_occupants)
    else null
  end;

  insert into public.room_reservations (
    nom, prenom, email, telephone, room_type, nights, amount_eur,
    payment_status, admin_notes
  ) values (
    btrim(p_nom), btrim(p_prenom), lower(btrim(p_email)), nullif(btrim(p_telephone),''),
    p_room_type, 2, v_amount, 'pending', v_note
  ) returning id into v_id;

  return query select v_id, v_amount;
end;
$$;

grant execute on function public.create_reservation(text,text,text,text,text,text) to anon, authenticated;

-- =========================================================================
-- 4. (optionnel) Recalculer les montants des résas déjà créées en test
--    Décommente si tu veux corriger d'anciennes lignes existantes.
-- =========================================================================
-- update public.room_reservations
--   set amount_eur = public.room_amount(room_type)
--   where amount_eur in (56, 42, 34);
