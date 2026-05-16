-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 6 (réservations chambres Résidence)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Crée la table `room_reservations` + RPCs pour :
--   - réservation publique (anon, self-service via le site)
--   - actions admin (annuler, marquer payé, créer sans paiement, lien custom)
--   - stock restant calculé en temps réel
--
-- Capacités hardcodées (chambres physiques) :
--   simple : 1 chambre
--   double : 10 chambres
--   triple : 3 chambres
-- Tarifs (par CHAMBRE, forfait 2 nuits) :
--   simple : 60 € · double : 90 € · triple : 110 €
--
-- Toute manip post-migration passe par les RPCs — pas de SQL Editor à part ce
-- one-shot.
-- =========================================================================

-- =========================================================================
-- 1. Table room_reservations
-- =========================================================================
create table if not exists public.room_reservations (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  -- Coordonnées de la personne qui réserve
  nom             text not null,
  prenom          text not null,
  email           text not null,
  telephone       text,

  -- Chambre
  room_type       text not null check (room_type in ('simple','double','triple')),
  nights          int  not null default 2,
  amount_eur      numeric(8,2) not null,

  -- Workflow paiement
  payment_status  text not null default 'pending'
                  check (payment_status in ('pending','paid','waived','cancelled')),
  paid_at         timestamptz,
  cancelled_at    timestamptz,

  -- Notes admin & lien paiement custom optionnel
  admin_notes     text,
  custom_payment_url text
);

create index if not exists idx_room_reservations_status   on public.room_reservations(payment_status);
create index if not exists idx_room_reservations_email    on public.room_reservations(email);
create index if not exists idx_room_reservations_created  on public.room_reservations(created_at desc);

-- updated_at automatique
create or replace function public.tg_room_reservations_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists set_updated_at on public.room_reservations;
create trigger set_updated_at
  before update on public.room_reservations
  for each row execute function public.tg_room_reservations_set_updated_at();

-- =========================================================================
-- 2. RLS — anon peut INSERT et SELECT son propre email ; admin = full access
-- =========================================================================
alter table public.room_reservations enable row level security;

drop policy if exists "Anon can insert reservation"  on public.room_reservations;
drop policy if exists "Public can read own by email" on public.room_reservations;
drop policy if exists "Admin full access"            on public.room_reservations;

-- Tout le monde peut créer une résa (le RPC fait les checks de stock)
create policy "Anon can insert reservation"
  on public.room_reservations
  for insert
  to anon, authenticated
  with check (true);

-- Public lecture : tout le monde peut lire (utile pour afficher le stock restant)
-- on n'expose pas les coordonnées via les vues côté front, ou on filtre côté JS.
-- Comme on a besoin du stock public, on autorise SELECT mais on fera attention.
create policy "Public can read reservations"
  on public.room_reservations
  for select
  to anon, authenticated
  using (true);

-- Admin = tout
create policy "Admin full access"
  on public.room_reservations
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- =========================================================================
-- 3. Fonction utilitaire : tarif par CHAMBRE (forfait 2 nuits)
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
-- 4. RPC : get_room_stock() — renvoie { simple_left, double_left, triple_left }
-- Compte les places restantes en excluant les résas cancelled.
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
-- 5. RPC : create_reservation(...)
-- Appelé depuis le site public (anon). Vérifie le stock atomiquement,
-- calcule le tarif, et insère la résa.
-- Renvoie l'UUID de la résa créée + le montant.
-- =========================================================================
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
  -- Validations
  if p_nom is null or btrim(p_nom) = ''   then raise exception 'Nom obligatoire'; end if;
  if p_prenom is null or btrim(p_prenom) = '' then raise exception 'Prénom obligatoire'; end if;
  if p_email is null or btrim(p_email) = '' or p_email !~ '^[^@]+@[^@]+\.[^@]+$' then
    raise exception 'Email invalide';
  end if;
  if p_room_type not in ('simple','double','triple') then
    raise exception 'Type de chambre invalide : %', p_room_type;
  end if;

  -- Verrou transactionnel par room_type (hash stable) pour éviter la course
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

-- =========================================================================
-- 6. RPC : admin_create_reservation(...)
-- L'admin peut créer une résa avec statut quelconque (notamment 'waived'
-- = pris en charge sans paiement). Bypasse certaines validations.
-- =========================================================================
create or replace function public.admin_create_reservation(
  p_nom        text,
  p_prenom     text,
  p_email      text,
  p_telephone  text,
  p_room_type  text,
  p_status     text default 'pending',
  p_notes      text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_remaining int;
  v_amount    numeric;
  v_id        uuid;
begin
  if not public.is_admin() then
    raise exception 'admin_create_reservation : admin only';
  end if;

  if p_room_type not in ('simple','double','triple') then
    raise exception 'Type de chambre invalide : %', p_room_type;
  end if;
  if p_status not in ('pending','paid','waived') then
    raise exception 'Statut invalide pour création : %', p_status;
  end if;

  -- L'admin peut surbooker si vraiment nécessaire, mais on prévient
  select remaining into v_remaining from public.get_room_stock() where room_type = p_room_type;
  if v_remaining is null or v_remaining <= 0 then
    raise warning 'Stock épuisé en chambre % — création forcée par admin', p_room_type;
  end if;

  v_amount := public.room_amount(p_room_type);

  insert into public.room_reservations (
    nom, prenom, email, telephone, room_type, nights, amount_eur,
    payment_status, paid_at, admin_notes
  ) values (
    btrim(coalesce(p_nom,'')), btrim(coalesce(p_prenom,'')),
    lower(btrim(coalesce(p_email,''))), nullif(btrim(coalesce(p_telephone,'')),''),
    p_room_type, 2, v_amount,
    p_status,
    case when p_status = 'paid' then now() else null end,
    p_notes
  ) returning id into v_id;

  return v_id;
end;
$$;

-- =========================================================================
-- 7. RPC : cancel_reservation(id)
-- =========================================================================
create or replace function public.cancel_reservation(p_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'cancel_reservation : admin only';
  end if;

  update public.room_reservations
    set payment_status = 'cancelled',
        cancelled_at   = now(),
        admin_notes    = coalesce(admin_notes || E'\n', '') || '↳ Annulée le ' || to_char(now(), 'DD/MM/YYYY HH24:MI') || coalesce(' — ' || p_reason, '')
    where id = p_id;
  if not found then
    raise exception 'Réservation introuvable : %', p_id;
  end if;
end;
$$;

-- =========================================================================
-- 8. RPC : mark_paid(id) / mark_waived(id) / unmark_paid(id)
-- =========================================================================
create or replace function public.mark_reservation_paid(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.room_reservations
    set payment_status = 'paid', paid_at = now(), cancelled_at = null
    where id = p_id;
  if not found then raise exception 'Réservation introuvable : %', p_id; end if;
end;
$$;

create or replace function public.mark_reservation_waived(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.room_reservations
    set payment_status = 'waived', paid_at = now(), cancelled_at = null
    where id = p_id;
  if not found then raise exception 'Réservation introuvable : %', p_id; end if;
end;
$$;

create or replace function public.unmark_reservation_paid(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.room_reservations
    set payment_status = 'pending', paid_at = null, cancelled_at = null
    where id = p_id;
  if not found then raise exception 'Réservation introuvable : %', p_id; end if;
end;
$$;

-- =========================================================================
-- 9. RPC : update_reservation_notes / update_payment_url
-- =========================================================================
create or replace function public.update_reservation_notes(p_id uuid, p_notes text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.room_reservations set admin_notes = p_notes where id = p_id;
  if not found then raise exception 'Réservation introuvable : %', p_id; end if;
end;
$$;

create or replace function public.update_reservation_payment_url(p_id uuid, p_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.room_reservations set custom_payment_url = nullif(btrim(p_url),'') where id = p_id;
  if not found then raise exception 'Réservation introuvable : %', p_id; end if;
end;
$$;

-- =========================================================================
-- Droits d'exécution
-- =========================================================================
grant execute on function public.get_room_stock()                        to anon, authenticated;
grant execute on function public.create_reservation(text,text,text,text,text,text) to anon, authenticated;
grant execute on function public.admin_create_reservation(text,text,text,text,text,text,text) to authenticated;
grant execute on function public.cancel_reservation(uuid,text)           to authenticated;
grant execute on function public.mark_reservation_paid(uuid)             to authenticated;
grant execute on function public.mark_reservation_waived(uuid)           to authenticated;
grant execute on function public.unmark_reservation_paid(uuid)           to authenticated;
grant execute on function public.update_reservation_notes(uuid,text)     to authenticated;
grant execute on function public.update_reservation_payment_url(uuid,text) to authenticated;
