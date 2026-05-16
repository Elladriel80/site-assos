-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 7b (tunnel inscription tournoi unifié)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Crée la table `pending_inscriptions` qui sert de source de vérité pour le
-- tunnel public d'inscription au tournoi (page inscription-tournoi.html).
-- Même pattern que room_reservations :
--   - anon peut INSERT via RPC create_inscription
--   - le statut payment_status pilote le cycle de vie
--   - get_inscription_stock() compte les pending_inscriptions non annulées
--
-- ⚠️ Cette migration REMPLACE la définition de get_inscription_stock créée
-- en phase 7 : elle ne compte plus paid_users mais pending_inscriptions.
-- =========================================================================

-- =========================================================================
-- 1. Table pending_inscriptions
-- =========================================================================
create table if not exists public.pending_inscriptions (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  nom             text not null,
  prenom          text not null,
  email           text not null,
  telephone       text,

  inscription_type text not null check (inscription_type in ('equipe','jeu_libre','narratif')),
  team_name       text,                                   -- pour 'equipe' uniquement (optionnel)
  role            text check (role in ('capitaine','coequipier') or role is null),

  amount_eur      numeric(8,2) not null default 65.0,

  payment_status  text not null default 'pending'
                  check (payment_status in ('pending','paid','waived','cancelled')),
  paid_at         timestamptz,
  cancelled_at    timestamptz,

  admin_notes        text,
  custom_payment_url text
);

create index if not exists idx_pending_inscriptions_status  on public.pending_inscriptions(payment_status);
create index if not exists idx_pending_inscriptions_email   on public.pending_inscriptions(email);
create index if not exists idx_pending_inscriptions_type    on public.pending_inscriptions(inscription_type);
create index if not exists idx_pending_inscriptions_created on public.pending_inscriptions(created_at desc);

-- updated_at automatique
create or replace function public.tg_pending_inscriptions_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists set_updated_at on public.pending_inscriptions;
create trigger set_updated_at
  before update on public.pending_inscriptions
  for each row execute function public.tg_pending_inscriptions_set_updated_at();

-- =========================================================================
-- 2. RLS — anon peut INSERT et SELECT publique ; admin = full access
-- =========================================================================
alter table public.pending_inscriptions enable row level security;

drop policy if exists "Anon can insert inscription"   on public.pending_inscriptions;
drop policy if exists "Public can read inscriptions"  on public.pending_inscriptions;
drop policy if exists "Admin full access inscriptions" on public.pending_inscriptions;

create policy "Anon can insert inscription"
  on public.pending_inscriptions
  for insert
  to anon, authenticated
  with check (true);

create policy "Public can read inscriptions"
  on public.pending_inscriptions
  for select
  to anon, authenticated
  using (true);

create policy "Admin full access inscriptions"
  on public.pending_inscriptions
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- =========================================================================
-- 3. get_inscription_stock — REDÉFINITION : compte pending_inscriptions
-- =========================================================================
create or replace function public.get_inscription_stock()
returns table(
  inscription_type text,
  capacity         int,
  taken            int,
  remaining        int
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
      where payment_status <> 'cancelled'
      group by inscription_type
  )
  select
    cap.inscription_type,
    cap.capacity,
    coalesce(taken_cte.taken, 0)                 as taken,
    cap.capacity - coalesce(taken_cte.taken, 0)  as remaining
  from cap
    left join taken_cte using (inscription_type)
  order by case cap.inscription_type
    when 'equipe'    then 1
    when 'jeu_libre' then 2
    when 'narratif'  then 3
  end;
$$;

grant execute on function public.get_inscription_stock() to anon, authenticated;

-- =========================================================================
-- 4. RPC create_inscription — appelée par inscription-tournoi.html (anon)
-- =========================================================================
create or replace function public.create_inscription(
  p_nom              text,
  p_prenom           text,
  p_email            text,
  p_telephone        text,
  p_inscription_type text,
  p_team_name        text default null,
  p_role             text default null
)
returns table(inscription_id uuid, amount_eur numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_remaining int;
  v_id        uuid;
  v_amount    numeric := 65.0;
begin
  if p_nom is null or btrim(p_nom) = '' then raise exception 'Nom obligatoire'; end if;
  if p_prenom is null or btrim(p_prenom) = '' then raise exception 'Prénom obligatoire'; end if;
  if p_email is null or btrim(p_email) = '' or p_email !~ '^[^@]+@[^@]+\.[^@]+$' then
    raise exception 'Email invalide';
  end if;
  if p_inscription_type not in ('equipe','jeu_libre','narratif') then
    raise exception 'Type d''inscription invalide : %', p_inscription_type;
  end if;
  if p_role is not null and p_role not in ('capitaine','coequipier') then
    raise exception 'Rôle invalide : %', p_role;
  end if;

  -- Verrou transactionnel par inscription_type (évite la course au sold-out)
  perform pg_advisory_xact_lock(hashtext('pending_inscriptions:' || p_inscription_type)::bigint);

  select remaining into v_remaining from public.get_inscription_stock() where inscription_type = p_inscription_type;
  if v_remaining is null or v_remaining <= 0 then
    raise exception 'Plus de places disponibles pour : %', p_inscription_type;
  end if;

  insert into public.pending_inscriptions (
    nom, prenom, email, telephone, inscription_type, team_name, role, amount_eur, payment_status
  ) values (
    btrim(p_nom), btrim(p_prenom), lower(btrim(p_email)), nullif(btrim(p_telephone),''),
    p_inscription_type, nullif(btrim(p_team_name),''), p_role, v_amount, 'pending'
  ) returning id into v_id;

  return query select v_id, v_amount;
end;
$$;

-- =========================================================================
-- 5. RPC admin (parallèles aux RPCs chambre)
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
    65.0, p_status,
    case when p_status = 'paid' then now() else null end,
    p_notes
  ) returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.cancel_inscription(p_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.pending_inscriptions
    set payment_status = 'cancelled',
        cancelled_at   = now(),
        admin_notes    = coalesce(admin_notes || E'\n', '') || '↳ Annulée le ' || to_char(now(),'DD/MM/YYYY HH24:MI') || coalesce(' — ' || p_reason, '')
    where id = p_id;
  if not found then raise exception 'Inscription introuvable : %', p_id; end if;
end;
$$;

create or replace function public.mark_inscription_paid(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.pending_inscriptions
    set payment_status = 'paid', paid_at = now(), cancelled_at = null
    where id = p_id;
  if not found then raise exception 'Inscription introuvable : %', p_id; end if;
end;
$$;

create or replace function public.mark_inscription_waived(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.pending_inscriptions
    set payment_status = 'waived', paid_at = now(), cancelled_at = null
    where id = p_id;
  if not found then raise exception 'Inscription introuvable : %', p_id; end if;
end;
$$;

create or replace function public.unmark_inscription_paid(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.pending_inscriptions
    set payment_status = 'pending', paid_at = null, cancelled_at = null
    where id = p_id;
  if not found then raise exception 'Inscription introuvable : %', p_id; end if;
end;
$$;

-- =========================================================================
-- Droits d'exécution
-- =========================================================================
grant execute on function public.create_inscription(text,text,text,text,text,text,text)               to anon, authenticated;
grant execute on function public.admin_create_inscription(text,text,text,text,text,text,text,text,text) to authenticated;
grant execute on function public.cancel_inscription(uuid,text)        to authenticated;
grant execute on function public.mark_inscription_paid(uuid)          to authenticated;
grant execute on function public.mark_inscription_waived(uuid)        to authenticated;
grant execute on function public.unmark_inscription_paid(uuid)        to authenticated;
