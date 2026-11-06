-- =========================================================================
-- INTER-TOW 2026 : Migration Phase 28 (adversaire non inscrit + roue en une page)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- 1. Une partie peut se jouer contre un joueur non inscrit. Elle compte
--    dans les points du joueur inscrit (4/2/1, ses 4 meilleures parties)
--    et donne droit à la roue de la loose s'il perd. Aucun territoire ne
--    bouge, l'adversaire n'ayant pas de camp. Décision de Jean-Sébastien
--    du 6/11/2026. Côté base : l'email de l'adversaire est vide et son nom
--    est gardé dans battles.opponent_name.
-- 2. Sur le stand, le vaincu déclare sa défaite et tire son lot dans la
--    même page : RPC loose_declare_and_spin(), qui enchaîne la déclaration
--    (mêmes garde-fous que la tablette) et le tirage, dans une seule
--    transaction.
-- Rejouable sans erreur.
-- =========================================================================

-- =========================================================================
-- 1. UNE PARTIE PEUT N'AVOIR QU'UN SEUL JOUEUR INSCRIT
-- =========================================================================
alter table public.battles alter column winner_email drop not null;
alter table public.battles alter column loser_email  drop not null;
alter table public.battles add column if not exists opponent_name text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'battles_one_registered_player') then
    alter table public.battles add constraint battles_one_registered_player
      check (winner_email is not null or loser_email is not null);
  end if;
end $$;

-- L'historique public expose le nom de l'adversaire non inscrit (jamais d'email).
-- La colonne bounty n'existe que si la phase 26 (prime sur la tête) a été
-- appliquée : la vue s'adapte, pour que cette migration passe dans les deux cas.
do $$
begin
  execute format($v$
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
             %s
             b.opponent_name
      from public.battles b
      left join public.champions wc on wc.email = b.winner_email
      left join public.champions lc on lc.email = b.loser_email
  $v$,
  case when exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'battles' and column_name = 'bounty')
       then 'b.bounty,' else '' end);
end $$;

grant select on public.battles_public to anon, authenticated;

-- =========================================================================
-- 2. RPC declare_outsider_battle : un inscrit contre un non inscrit
--    p_result : 'W' (l'inscrit gagne), 'L' (il perd), 'D' (match nul)
--    Garde-fous côté inscrit : 3 parties max par ronde, 30 s de battement,
--    une seule partie par ronde contre le même nom. Le plafond des 4
--    parties en jeu libre reste porté par le trigger sur battles.
-- =========================================================================
create or replace function public.declare_outsider_battle(
  p_champion_id uuid,
  p_result      text,
  p_opponent    text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round int;
  v_c     record;
  v_name  text := left(btrim(coalesce(p_opponent, '')), 60);
  v_res   text := upper(coalesce(p_result, ''));
  v_battle uuid;
begin
  if p_champion_id is null then raise exception 'Il faut un joueur inscrit'; end if;
  if v_res not in ('W', 'L', 'D') then raise exception 'Résultat inconnu'; end if;
  if length(v_name) < 2 then raise exception 'Indique le nom de l''adversaire non inscrit'; end if;

  select * into v_c from public.champions where id = p_champion_id;
  if not found then raise exception 'Joueur introuvable'; end if;

  v_round := public.current_round();

  if exists (
    select 1 from public.battles b
     where b.round_number = v_round
       and (b.winner_email = v_c.email or b.loser_email = v_c.email)
       and lower(coalesce(b.opponent_name, '')) = lower(v_name)
  ) then
    raise exception 'Cette partie contre % est déjà déclarée pour la ronde %. Vois avec un organisateur.', v_name, v_round;
  end if;

  if (select count(*) from public.battles b
       where b.round_number = v_round
         and (b.winner_email = v_c.email or b.loser_email = v_c.email)) >= 3 then
    raise exception 'Trop de parties déjà déclarées pour cette ronde par %. Vois avec un organisateur.', v_c.pseudo;
  end if;

  if exists (
    select 1 from public.battles b
     where b.created_at > now() - interval '30 seconds'
       and (b.winner_email = v_c.email or b.loser_email = v_c.email)
  ) then
    raise exception 'Une déclaration vient d''être enregistrée. Patiente quelques secondes.';
  end if;

  insert into public.battles (
    winner_email, loser_email, round_number, is_draw,
    cell_transferred_id, prev_alliance, prev_owner_email,
    opponent_name, notes, source
  ) values (
    case when v_res in ('W', 'D') then v_c.email end,
    case when v_res = 'L' then v_c.email end,
    v_round, v_res = 'D',
    null, null, null,
    v_name, 'Adversaire non inscrit : pas de cession', 'tablette'
  ) returning id into v_battle;

  return jsonb_build_object(
    'battle_id', v_battle, 'round', v_round, 'outsider', true,
    'result', v_res, 'draw', v_res = 'D',
    'same_alliance', false, 'transferred', false,
    'champion', v_c.pseudo, 'opponent', v_name,
    'winner', case when v_res = 'L' then v_name else v_c.pseudo end,
    'loser',  case when v_res = 'L' then v_c.pseudo else v_name end
  );
end;
$$;

grant execute on function public.declare_outsider_battle(uuid, text, text) to anon, authenticated;

-- =========================================================================
-- 3. LA LISTE DES DÉFAITES À TIRER AFFICHE L'ADVERSAIRE NON INSCRIT
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
               'winner', coalesce(wc.pseudo, b.opponent_name, 'adversaire non inscrit'),
               'outsider', wc.id is null) order by b.created_at desc)
        from public.battles b
        join public.champions lc on lc.email = b.loser_email
        left join public.champions wc on wc.email = b.winner_email
       where not b.is_draw
         and not exists (select 1 from public.loose_spins s where s.battle_id = b.id)), '[]'::jsonb)
  );
end;
$$;

-- =========================================================================
-- 4. RPC loose_declare_and_spin : le vaincu déclare et tire au stand
--    p_winner_id renseigné : défaite contre un inscrit (declare_battle,
--    le territoire bascule comme à la tablette). Sinon p_opponent : défaite
--    contre un non inscrit. Puis tirage. Tout ou rien.
-- =========================================================================
create or replace function public.loose_declare_and_spin(
  p_token     text,
  p_loser_id  uuid,
  p_winner_id uuid,
  p_opponent  text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_decl jsonb;
  v_spin jsonb;
begin
  if not exists (select 1 from public.loose_stands where token = p_token and active) then
    raise exception 'Lien de stand invalide ou désactivé.';
  end if;

  if p_winner_id is not null then
    v_decl := public.declare_battle(p_winner_id, p_loser_id);
  else
    v_decl := public.declare_outsider_battle(p_loser_id, 'L', p_opponent);
  end if;

  v_spin := public.spin_loose_wheel(p_token, (v_decl->>'battle_id')::uuid);
  return v_spin || jsonb_build_object('declaration', v_decl);
end;
$$;

grant execute on function public.loose_declare_and_spin(text, uuid, uuid, text) to anon, authenticated;
