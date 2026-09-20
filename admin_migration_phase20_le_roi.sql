-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 20 (Le Roi)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Le titre de Roi se joue en voix. Chaque fait d'armes, chaque concours,
-- chaque coup d'éclat rapporte des voix à un champion, attribuées à la main
-- par les organisateurs depuis l'onglet « Couronne » de l'admin.
-- À la clôture, le Roi est le champion le mieux acclamé DANS LE CAMP
-- VAINQUEUR, le camp vainqueur étant celui qui tient le plus de territoires.
--
-- Deux tables seulement :
--   royal_votes    — une ligne par attribution, annulable une par une
--   campaign_state — l'état de la campagne, dont le sacre
--
-- Aucun email n'est exposé publiquement : les vues publiques ne portent que
-- champion_id, déjà présent dans champions_public, et la carte fait le lien.
-- =========================================================================

-- =========================================================================
-- 1. LES VOIX
-- =========================================================================
create table if not exists public.royal_votes (
  id           uuid primary key default gen_random_uuid(),
  champion_id  uuid not null references public.champions(id) on delete cascade,
  voices       int  not null default 1
               check (voices between -50 and 50 and voices <> 0),
  category     text not null default 'autre'
               check (category in ('bataille','territoire','concours','roleplay','fairplay','autre')),
  reason       text,
  round_number int check (round_number between 1 and 5),
  created_at   timestamptz not null default now(),
  created_by   text default auth.email()
);

create index if not exists idx_royal_votes_champion on public.royal_votes(champion_id);
create index if not exists idx_royal_votes_created  on public.royal_votes(created_at desc);

alter table public.royal_votes enable row level security;

drop policy if exists "royal_votes admin select" on public.royal_votes;
create policy "royal_votes admin select" on public.royal_votes
  for select using (public.is_admin());

drop policy if exists "royal_votes admin insert" on public.royal_votes;
create policy "royal_votes admin insert" on public.royal_votes
  for insert with check (public.is_admin());

drop policy if exists "royal_votes admin delete" on public.royal_votes;
create policy "royal_votes admin delete" on public.royal_votes
  for delete using (public.is_admin());

-- Vue publique : ni email d'organisateur, ni email de champion.
create or replace view public.royal_votes_public as
  select id, champion_id, voices, category, reason, round_number, created_at
  from public.royal_votes;

grant select on public.royal_votes_public to anon, authenticated;

-- =========================================================================
-- 2. L'ÉTAT DE LA CAMPAGNE
-- Clés utilisées :
--   'crown'  → {"champion_id": "<uuid>", "crowned_at": "<iso>"}
--              posée au sacre, retirée pour annuler.
-- Table volontairement générique : les prochains jalons de la journée
-- (ouverture, dernière ronde, clôture) y tiendront sans migration.
-- =========================================================================
create table if not exists public.campaign_state (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by text default auth.email()
);

alter table public.campaign_state enable row level security;

drop policy if exists "campaign_state admin select" on public.campaign_state;
create policy "campaign_state admin select" on public.campaign_state
  for select using (public.is_admin());

drop policy if exists "campaign_state admin insert" on public.campaign_state;
create policy "campaign_state admin insert" on public.campaign_state
  for insert with check (public.is_admin());

drop policy if exists "campaign_state admin update" on public.campaign_state;
create policy "campaign_state admin update" on public.campaign_state
  for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists "campaign_state admin delete" on public.campaign_state;
create policy "campaign_state admin delete" on public.campaign_state
  for delete using (public.is_admin());

create or replace view public.campaign_state_public as
  select key, value, updated_at from public.campaign_state;

grant select on public.campaign_state_public to anon, authenticated;
