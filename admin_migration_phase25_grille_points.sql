-- =========================================================================
-- INTER-TOW 2026 : Migration Phase 25 (grille de points et matchs nuls)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
-- (après les phases 23 et 24)
--
-- Grille décidée le 3 octobre 2026 pour le titre de Roi :
--   - parties : 4 par victoire, 2 par nul, 1 par défaite, et seules les
--     4 meilleures parties de chaque joueur comptent (tous modes de jeu)
--   - tenue : 5 aux couleurs de son alliance, 15 avec en plus ses armoiries
--   - peinture : la note sur 20
--   - fair-play : 10 d'office, que les organisateurs peuvent réduire
--   - bonus : les voix attribuées à la main (faits d'armes, roleplay...)
-- Le Roi reste le champion qui a le plus de points dans l'alliance au
-- meilleur taux de victoires ; un nul y compte pour une demi-victoire.
--
-- Les matchs nuls entrent par une nouvelle RPC declare_draw() (tablette
-- et admin) : aucun territoire ne bouge, pas de roue de la loose.
-- Le salut à l'adversaire de la tablette est retiré (le fair-play vaut
-- 10 points d'office) : acclaim_opponent n'est plus ouvert en anonyme.
-- Rejouable sans erreur.
-- =========================================================================

-- =========================================================================
-- 1. LES MATCHS NULS
-- Un nul est une ligne battles avec is_draw = true : winner_email et
-- loser_email désignent simplement les deux joueurs.
-- =========================================================================
alter table public.battles
  add column if not exists is_draw boolean not null default false;

create or replace view public.battles_public as
  select b.id,
         wc.id as winner_id,
         lc.id as loser_id,
         b.round_number,
         b.cell_transferred_id,
         b.source,
         b.notes,
         b.created_at,
         b.is_draw
  from public.battles b
  left join public.champions wc on wc.email = b.winner_email
  left join public.champions lc on lc.email = b.loser_email;

grant select on public.battles_public to anon, authenticated;

create or replace function public.declare_draw(p_a_id uuid, p_b_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round  int;
  v_a      record;
  v_b      record;
  v_battle uuid;
begin
  if p_a_id is null or p_b_id is null then
    raise exception 'Il faut deux joueurs';
  end if;
  if p_a_id = p_b_id then
    raise exception 'Il faut deux champions différents';
  end if;

  select * into v_a from public.champions where id = p_a_id;
  if not found then raise exception 'Premier joueur introuvable'; end if;
  select * into v_b from public.champions where id = p_b_id;
  if not found then raise exception 'Second joueur introuvable'; end if;

  v_round := public.current_round();

  if exists (
    select 1 from public.battles b
     where b.round_number = v_round
       and ((b.winner_email = v_a.email and b.loser_email = v_b.email)
         or (b.winner_email = v_b.email and b.loser_email = v_a.email))
  ) then
    raise exception 'Cette partie est déjà déclarée pour la ronde %. Vois avec un organisateur.', v_round;
  end if;

  if (select count(*) from public.battles b
       where b.round_number = v_round
         and (b.winner_email = v_a.email or b.loser_email = v_a.email)) >= 3
     or
     (select count(*) from public.battles b
       where b.round_number = v_round
         and (b.winner_email = v_b.email or b.loser_email = v_b.email)) >= 3
  then
    raise exception 'Trop de parties déjà déclarées pour cette ronde par l''un des deux champions. Vois avec un organisateur.';
  end if;

  if not public.is_admin() and exists (
    select 1 from public.battles b
     where b.created_at > now() - interval '30 seconds'
       and (b.winner_email in (v_a.email, v_b.email) or b.loser_email in (v_a.email, v_b.email))
  ) then
    raise exception 'Une déclaration vient d''être enregistrée. Patiente quelques secondes.';
  end if;

  -- Le plafond de 4 parties en jeu libre (phase 24) s'applique ici aussi,
  -- par le trigger posé sur battles.
  insert into public.battles (
    winner_email, loser_email, round_number,
    cell_transferred_id, notes, source, is_draw
  ) values (
    v_a.email, v_b.email, v_round,
    null, 'Match nul', case when public.is_admin() then 'admin' else 'tablette' end, true
  ) returning id into v_battle;

  return jsonb_build_object(
    'battle_id', v_battle, 'round', v_round, 'draw', true,
    'a', v_a.pseudo, 'b', v_b.pseudo,
    'a_alliance', public.region_to_alliance(v_a.region),
    'b_alliance', public.region_to_alliance(v_b.region)
  );
end;
$$;

grant execute on function public.declare_draw(uuid, uuid) to anon, authenticated;

-- Le salut de la tablette disparaît : plus d'appel anonyme.
revoke execute on function public.acclaim_opponent(uuid, uuid, uuid, text) from anon;

-- =========================================================================
-- 2. LA ROUE DE LA LOOSE IGNORE LES NULS
-- =========================================================================
create or replace function public.loose_stand_info(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_stand record;
begin
  select * into v_stand from public.loose_stands where token = p_token and active;
  if not found then raise exception 'Lien de stand invalide ou désactivé. Vois avec un organisateur.'; end if;

  return jsonb_build_object(
    'stand', jsonb_build_object('id', v_stand.id, 'name', v_stand.name),
    'round', public.current_round(),
    'prizes', coalesce((
      select jsonb_agg(jsonb_build_object('number', p.number, 'label', p.label) order by p.number)
        from public.loose_prizes p where p.stand_id = v_stand.id), '[]'::jsonb),
    'pending', coalesce((
      select jsonb_agg(jsonb_build_object(
               'battle_id', b.id, 'round', b.round_number, 'created_at', b.created_at,
               'loser_id', lc.id, 'loser', lc.pseudo, 'loser_region', lc.region,
               'winner', wc.pseudo) order by b.created_at desc)
        from public.battles b
        join public.champions lc on lc.email = b.loser_email
        left join public.champions wc on wc.email = b.winner_email
       where not b.is_draw
         and not exists (select 1 from public.loose_spins s where s.battle_id = b.id)), '[]'::jsonb)
  );
end;
$$;

create or replace function public.spin_loose_wheel(p_token text, p_battle_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stand  record;
  v_b      record;
  v_loser  record;
  v_spin   record;
  v_number int;
  v_label  text;
begin
  select * into v_stand from public.loose_stands where token = p_token and active;
  if not found then raise exception 'Lien de stand invalide ou désactivé.'; end if;

  select * into v_b from public.battles where id = p_battle_id;
  if not found then raise exception 'Défaite introuvable. Le joueur a-t-il déclaré sa partie à la tablette ?'; end if;
  if v_b.is_draw then raise exception 'Un match nul ne donne pas droit à la roue.'; end if;

  select * into v_loser from public.champions where email = v_b.loser_email;
  if not found then raise exception 'Joueur introuvable'; end if;

  if exists (select 1 from public.loose_spins where battle_id = p_battle_id) then
    raise exception 'La roue a déjà été lancée pour cette défaite.';
  end if;

  v_number := 1 + floor(random() * 10)::int;
  select label into v_label from public.loose_prizes where stand_id = v_stand.id and number = v_number;

  insert into public.loose_spins (battle_id, champion_id, stand_id, number, prize_label, round_number)
  values (p_battle_id, v_loser.id, v_stand.id, v_number, coalesce(v_label, ''), v_b.round_number)
  returning * into v_spin;

  return jsonb_build_object('spin_id', v_spin.id, 'number', v_number,
                            'label', coalesce(v_label, ''), 'loser', v_loser.pseudo);
exception
  when unique_violation then
    raise exception 'La roue a déjà été lancée pour cette défaite.';
end;
$$;

-- =========================================================================
-- 3. LES NOTES DES ORGANISATEURS : tenue, peinture, fair-play
-- Une ligne par champion, créée à la première saisie. Sans ligne :
-- tenue 0, peinture 0, fair-play 10.
-- =========================================================================
create table if not exists public.champion_scores (
  champion_id uuid primary key references public.champions(id) on delete cascade,
  outfit      int not null default 0  check (outfit in (0, 5, 15)),
  painting    int not null default 0  check (painting between 0 and 20),
  fairplay    int not null default 10 check (fairplay between 0 and 10),
  updated_at  timestamptz not null default now(),
  updated_by  text default auth.email()
);

alter table public.champion_scores enable row level security;
drop policy if exists "Admins manage champion scores" on public.champion_scores;
create policy "Admins manage champion scores" on public.champion_scores
  for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.champion_scores to authenticated;

-- =========================================================================
-- 4. LE TOTAL PAR CHAMPION, CALCULÉ PAR LA BASE
-- Une seule source de vérité pour la carte, l'écran géant et l'admin.
-- Vue publique sans aucun email.
-- =========================================================================
create or replace view public.champion_points_public as
with games as (
  select c.id as champion_id,
         case when b.is_draw then 2
              when b.winner_email = c.email then 4
              else 1 end as pts,
         case when b.is_draw then 'D'
              when b.winner_email = c.email then 'W'
              else 'L' end as res
    from public.battles b
    join public.champions c on c.email in (b.winner_email, b.loser_email)
),
ranked as (
  select champion_id, pts, res,
         row_number() over (partition by champion_id order by pts desc) as rn
    from games
),
g as (
  select champion_id,
         coalesce(sum(pts) filter (where rn <= 4), 0)::int as game_pts,
         count(*)::int as games,
         count(*) filter (where res = 'W')::int as wins,
         count(*) filter (where res = 'D')::int as draws,
         count(*) filter (where res = 'L')::int as losses
    from ranked
   group by champion_id
),
bonus as (
  select champion_id, sum(voices)::int as bonus
    from public.royal_votes
   group by champion_id
)
select c.id as champion_id,
       coalesce(g.game_pts, 0)  as game_pts,
       coalesce(g.games, 0)     as games,
       coalesce(g.wins, 0)      as wins,
       coalesce(g.draws, 0)     as draws,
       coalesce(g.losses, 0)    as losses,
       coalesce(s.outfit, 0)    as outfit,
       coalesce(s.painting, 0)  as painting,
       coalesce(s.fairplay, 10) as fairplay,
       coalesce(bonus.bonus, 0) as bonus,
       coalesce(g.game_pts, 0) + coalesce(s.outfit, 0) + coalesce(s.painting, 0)
         + coalesce(s.fairplay, 10) + coalesce(bonus.bonus, 0) as total
  from public.champions c
  left join g     on g.champion_id = c.id
  left join public.champion_scores s on s.champion_id = c.id
  left join bonus on bonus.champion_id = c.id;

grant select on public.champion_points_public to anon, authenticated;
