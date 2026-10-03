-- =========================================================================
-- INTER-TOW 2026 : Migration Phase 26 (prime sur la tête)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
-- (après la phase 25)
--
-- Le champion seul en tête des points de chaque alliance porte une prime :
-- un joueur d'une AUTRE alliance qui le bat gagne 3 points de bonus.
-- La prime passe au nouveau leader dès que le classement change. En cas
-- d'égalité en tête d'une alliance, personne ne porte la prime.
--
-- La prime est figée AU MOMENT de la déclaration (trigger sur battles) :
-- un changement de classement plus tard ne la retire pas et n'en crée pas
-- après coup. Un nul ne déclenche pas de prime.
-- Rejouable sans erreur.
-- =========================================================================

alter table public.battles
  add column if not exists bounty boolean not null default false;

-- =========================================================================
-- 1. LES POINTS, AVEC LES PRIMES (remplace la vue de la phase 25)
-- =========================================================================
drop view if exists public.bounty_holders_public;
drop view if exists public.champion_points_public;

create view public.champion_points_public as
with games as (
  select c.id as champion_id,
         case when b.is_draw then 2
              when b.winner_email = c.email then 4
              else 1 end as pts,
         case when b.is_draw then 'D'
              when b.winner_email = c.email then 'W'
              else 'L' end as res,
         (b.bounty and not b.is_draw and b.winner_email = c.email) as bounty_won
    from public.battles b
    join public.champions c on c.email in (b.winner_email, b.loser_email)
),
ranked as (
  select champion_id, pts, res, bounty_won,
         row_number() over (partition by champion_id order by pts desc) as rn
    from games
),
g as (
  select champion_id,
         coalesce(sum(pts) filter (where rn <= 4), 0)::int as game_pts,
         count(*)::int as games,
         count(*) filter (where res = 'W')::int as wins,
         count(*) filter (where res = 'D')::int as draws,
         count(*) filter (where res = 'L')::int as losses,
         (3 * count(*) filter (where bounty_won))::int as bounty_pts
    from ranked
   group by champion_id
),
bonus as (
  select champion_id, sum(voices)::int as bonus
    from public.royal_votes
   group by champion_id
)
select c.id as champion_id,
       coalesce(g.game_pts, 0)   as game_pts,
       coalesce(g.games, 0)      as games,
       coalesce(g.wins, 0)       as wins,
       coalesce(g.draws, 0)      as draws,
       coalesce(g.losses, 0)     as losses,
       coalesce(s.outfit, 0)     as outfit,
       coalesce(s.painting, 0)   as painting,
       coalesce(s.fairplay, 10)  as fairplay,
       coalesce(bonus.bonus, 0)  as bonus,
       coalesce(g.game_pts, 0) + coalesce(s.outfit, 0) + coalesce(s.painting, 0)
         + coalesce(s.fairplay, 10) + coalesce(bonus.bonus, 0) + coalesce(g.bounty_pts, 0) as total,
       coalesce(g.bounty_pts, 0) as bounty_pts
  from public.champions c
  left join g     on g.champion_id = c.id
  left join public.champion_scores s on s.champion_id = c.id
  left join bonus on bonus.champion_id = c.id;

grant select on public.champion_points_public to anon, authenticated;

-- =========================================================================
-- 2. LES TÊTES MISES À PRIX : le leader unique de chaque alliance
-- =========================================================================
create view public.bounty_holders_public as
select alliance, champion_id, total
  from (
    select public.region_to_alliance(c.region) as alliance,
           p.champion_id, p.total,
           rank()   over (partition by public.region_to_alliance(c.region) order by p.total desc) as rk,
           count(*) over (partition by public.region_to_alliance(c.region), p.total) as n
      from public.champion_points_public p
      join public.champions c on c.id = p.champion_id
  ) t
 where rk = 1 and n = 1 and alliance is not null and alliance <> 'IDF';

grant select on public.bounty_holders_public to anon, authenticated;

-- =========================================================================
-- 3. LA PRIME EST POSÉE À LA DÉCLARATION
-- =========================================================================
create or replace function public.set_battle_bounty()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wa text;
  v_la text;
begin
  if new.is_draw then
    new.bounty := false;
    return new;
  end if;
  select public.region_to_alliance(region) into v_wa from public.champions where email = new.winner_email;
  select public.region_to_alliance(region) into v_la from public.champions where email = new.loser_email;
  new.bounty := v_wa is not null and v_la is not null and v_wa <> v_la
    and exists (
      select 1 from public.bounty_holders_public h
        join public.champions c on c.id = h.champion_id
       where c.email = new.loser_email);
  return new;
end;
$$;

drop trigger if exists trg_battles_set_bounty on public.battles;
create trigger trg_battles_set_bounty before insert on public.battles
  for each row execute function public.set_battle_bounty();

-- =========================================================================
-- 4. L'HISTORIQUE PUBLIC EXPOSE LA PRIME
-- =========================================================================
create or replace view public.battles_public as
  select b.id,
         wc.id as winner_id,
         lc.id as loser_id,
         b.round_number,
         b.cell_transferred_id,
         b.source,
         b.notes,
         b.created_at,
         b.is_draw,
         b.bounty
  from public.battles b
  left join public.champions wc on wc.email = b.winner_email
  left join public.champions lc on lc.email = b.loser_email;

grant select on public.battles_public to anon, authenticated;
