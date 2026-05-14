-- =========================================================================
-- INTER-TOW 2026 — Migration "Risk Géant" (Phase 2a foundation)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Cette migration ajoute :
--  - une fonction region_to_alliance(text) qui mappe une région à son alliance
--  - une table `cells` (110 cellules à terme, 5 par champion conquérable)
--  - une table `battles` (log des batailles du tournoi, 5 rondes max)
--  - un trigger qui génère automatiquement 5 cellules à chaque création de
--    champion (forge publique OU admin)
--  - les policies RLS (lecture publique pour cells/battles, écriture admin)
--  - un backfill rétroactif : les champions existants (et démos) reçoivent
--    leurs 5 cellules
--
-- AUCUNE policy existante n'est touchée. Idempotent (rejouable).
-- =========================================================================

-- =========================================================================
-- 1. Fonction helper region_to_alliance()
-- =========================================================================
create or replace function public.region_to_alliance(p_region text)
returns text
language sql
immutable
as $$
  select case p_region
    when 'Alsace'            then 'A'
    when 'Bretagne'          then 'A'
    when 'Basse-Normandie'   then 'A'
    when 'Rhône-Alpes'       then 'A'
    when 'Corse'             then 'A'
    when 'Nord-Pas-de-Calais' then 'B'
    when 'Bourgogne'         then 'B'
    when 'Provence-Alpes-Côte d''Azur' then 'B'
    when 'Aquitaine'         then 'B'
    when 'Midi-Pyrénées'     then 'B'
    when 'Picardie'          then 'C'
    when 'Haute-Normandie'   then 'C'
    when 'Centre'            then 'C'
    when 'Franche-Comté'     then 'C'
    when 'Auvergne'          then 'C'
    when 'Lorraine'          then 'D'
    when 'Pays de la Loire'  then 'D'
    when 'Champagne-Ardenne' then 'D'
    when 'Poitou-Charentes'  then 'D'
    when 'Languedoc-Roussillon' then 'D'
    when 'Limousin'          then 'D'
    when 'Île-de-France'     then 'IDF'
    else null
  end;
$$;

-- =========================================================================
-- 2. Table cells
-- =========================================================================
create table if not exists public.cells (
  id text primary key,
  cluster_owner_email text not null
    references public.champions(email) on delete cascade,
  cluster_index int not null check (cluster_index between 0 and 4),
  current_alliance text not null check (current_alliance in ('A','B','C','D')),
  current_owner_email text references public.champions(email) on delete set null,
  original_alliance text not null check (original_alliance in ('A','B','C','D')),
  created_at timestamptz default now()
);
create unique index if not exists uq_cells_cluster
  on public.cells(cluster_owner_email, cluster_index);
create index if not exists idx_cells_owner
  on public.cells(current_owner_email);
create index if not exists idx_cells_alliance
  on public.cells(current_alliance);

-- =========================================================================
-- 3. Table battles (5 rondes max)
-- =========================================================================
create table if not exists public.battles (
  id uuid primary key default gen_random_uuid(),
  winner_email text not null references public.champions(email) on delete cascade,
  loser_email  text not null references public.champions(email) on delete cascade,
  round_number int check (round_number between 1 and 5),
  cell_transferred_id text references public.cells(id) on delete set null,
  notes text,
  created_at timestamptz default now()
);
create index if not exists idx_battles_round on public.battles(round_number);
create index if not exists idx_battles_winner on public.battles(winner_email);

-- =========================================================================
-- 4. Trigger : génère 5 cellules à chaque création de champion
-- =========================================================================
create or replace function public.create_cells_for_champion()
returns trigger
language plpgsql
as $$
declare
  ally text := public.region_to_alliance(new.region);
begin
  -- Les parisiens non redistribués (alliance IDF) ne reçoivent pas de cellules.
  -- En pratique la forge force la redistribution donc ce cas n'arrive pas.
  if ally is null or ally = 'IDF' then
    return new;
  end if;

  insert into public.cells (
    id, cluster_owner_email, cluster_index,
    current_alliance, current_owner_email, original_alliance
  )
  select
    new.email || '#' || gs::text,
    new.email,
    gs,
    ally,
    new.email,
    ally
  from generate_series(0, 4) as gs
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists champions_create_cells on public.champions;
create trigger champions_create_cells
  after insert on public.champions
  for each row execute function public.create_cells_for_champion();

-- =========================================================================
-- 5. RLS
-- =========================================================================
alter table public.cells   enable row level security;
alter table public.battles enable row level security;

-- Lecture publique des cells (la carte est publique)
drop policy if exists "Anon can read cells" on public.cells;
create policy "Anon can read cells"
  on public.cells for select to anon using (true);

-- Lecture publique des battles (historique visible)
drop policy if exists "Anon can read battles" on public.battles;
create policy "Anon can read battles"
  on public.battles for select to anon using (true);

-- Admin : full CRUD sur cells et battles
drop policy if exists "Admins full access cells" on public.cells;
create policy "Admins full access cells"
  on public.cells for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Admins full access battles" on public.battles;
create policy "Admins full access battles"
  on public.battles for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- =========================================================================
-- 6. Backfill : les champions existants reçoivent rétroactivement leurs 5 cellules
-- =========================================================================
insert into public.cells (
  id, cluster_owner_email, cluster_index,
  current_alliance, current_owner_email, original_alliance
)
select
  c.email || '#' || gs.idx,
  c.email,
  gs.idx,
  public.region_to_alliance(c.region),
  c.email,
  public.region_to_alliance(c.region)
from public.champions c
cross join generate_series(0, 4) as gs(idx)
where public.region_to_alliance(c.region) in ('A','B','C','D')
on conflict (id) do nothing;

-- =========================================================================
-- 7. VÉRIFICATIONS (optionnel — décommente pour exécuter)
-- =========================================================================
-- select count(*) as total_cells from public.cells;
-- select current_alliance, count(*) from public.cells group by current_alliance order by 1;
-- select c.email, c.pseudo, c.region, count(cells.id) as nb_cells
--   from public.champions c left join public.cells on cells.cluster_owner_email = c.email
--   group by c.email, c.pseudo, c.region
--   order by c.email;
