-- =========================================================================
-- INTER-TOW 2026 — Schéma Supabase
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
-- =========================================================================

-- =========================================================================
-- TABLE 1 : paid_users
-- Whitelist des payeurs, alimentée par import CSV de l'onglet INSCRITS d'AssoConnect
-- =========================================================================
create table public.paid_users (
  id uuid primary key default gen_random_uuid(),
  email text unique not null,
  prenom text,
  nom text,
  adresse text,
  code_postal text,
  ville text,
  imported_at timestamptz default now()
);

create index idx_paid_users_email on public.paid_users(email);

-- =========================================================================
-- TABLE 2 : champions
-- Inscriptions perso (1 ligne par paid_user)
-- =========================================================================
create table public.champions (
  id uuid primary key default gen_random_uuid(),
  email text unique not null,
  pseudo text not null,
  faction text,
  region text not null,
  is_parisian_redistributed boolean default false,
  blason jsonb,
  story text,
  heroes text[] default '{}',
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index idx_champions_region on public.champions(region);
create index idx_champions_email on public.champions(email);

-- Trigger pour maintenir updated_at à jour
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger champions_updated_at
  before update on public.champions
  for each row execute function public.set_updated_at();

-- =========================================================================
-- ROW LEVEL SECURITY (RLS)
-- =========================================================================

alter table public.paid_users enable row level security;
alter table public.champions  enable row level security;

-- paid_users : lecture publique (pour vérifier qu'un email a payé), pas d'écriture anon
create policy "Anon can read paid_users"
  on public.paid_users for select
  to anon
  using (true);

-- champions : lecture publique (pour la carte des inscrits)
create policy "Anon can read champions"
  on public.champions for select
  to anon
  using (true);

-- champions : INSERT autorisé seulement si email présent dans paid_users
create policy "Anon can insert champion if paid"
  on public.champions for insert
  to anon
  with check (email in (select email from public.paid_users));

-- champions : UPDATE autorisé seulement si email présent dans paid_users
create policy "Anon can update champion if paid"
  on public.champions for update
  to anon
  using (email in (select email from public.paid_users))
  with check (email in (select email from public.paid_users));

-- =========================================================================
-- TEST DATA (optionnel — à supprimer après tests)
-- =========================================================================
-- insert into public.paid_users (email, prenom, nom, code_postal, ville) values
--   ('test1@example.com', 'Jean', 'Dupont', '10000', 'Troyes'),
--   ('test2@example.com', 'Marie', 'Martin', '75001', 'Paris'),
--   ('test3@example.com', 'Pierre', 'Durand', '67000', 'Strasbourg');
