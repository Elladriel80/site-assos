-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 21 (déclaration à la tablette)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Les joueurs déclarent eux-mêmes leurs résultats sur une tablette posée
-- dans la halle : le vainqueur saisit, le vaincu confirme sur le même
-- écran, le territoire bascule immédiatement. Chacun peut ensuite saluer
-- son adversaire, ce qui lui donne une voix pour le titre de Roi.
--
-- Comme la tablette est anonyme, tout passe par deux RPC SECURITY DEFINER
-- avec des garde-fous en dur, et non par des policies ouvertes en écriture.
--
-- Corrige aussi une fuite : la policy « Anon can read battles » exposait
-- winner_email et loser_email, donc les adresses réelles des joueurs, à
-- n'importe qui. Elle est remplacée par une vue sans email.
-- =========================================================================

-- =========================================================================
-- 1. TRAÇABILITÉ ET LIEN ACCLAMATION ↔ BATAILLE
-- =========================================================================
alter table public.battles
  add column if not exists source text not null default 'admin';

alter table public.royal_votes
  add column if not exists battle_id uuid references public.battles(id) on delete set null,
  add column if not exists from_champion_id uuid references public.champions(id) on delete set null;

-- Un salut par partie et par joueur, garanti par la base et pas par l'écran.
create unique index if not exists uq_royal_votes_battle_giver
  on public.royal_votes(battle_id, from_champion_id)
  where battle_id is not null;

-- =========================================================================
-- 2. LA RONDE EN COURS
-- Posée par les orgas dans l'admin, lue par la tablette : les joueurs
-- n'ont pas à la choisir, c'est une source d'erreur en moins.
-- =========================================================================
create or replace function public.current_round()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (value->>'n')::int from public.campaign_state where key = 'round'), 1);
$$;

grant execute on function public.current_round() to anon, authenticated;

-- =========================================================================
-- 3. HISTORIQUE PUBLIC DES BATAILLES, SANS AUCUN EMAIL
-- =========================================================================
drop policy if exists "Anon can read battles" on public.battles;

create or replace view public.battles_public as
  select b.id,
         wc.id as winner_id,
         lc.id as loser_id,
         b.round_number,
         b.cell_transferred_id,
         b.source,
         b.notes,
         b.created_at
  from public.battles b
  left join public.champions wc on wc.email = b.winner_email
  left join public.champions lc on lc.email = b.loser_email;

grant select on public.battles_public to anon, authenticated;

-- =========================================================================
-- 4. RPC declare_battle — appelée par la tablette
-- Reprend la logique de record_battle (même alliance sans cession,
-- auto-pick de la cellule la plus proche du cluster du vainqueur), avec
-- trois garde-fous puisque l'appelant est anonyme :
--   - une seule partie par paire et par ronde, dans un sens ou l'autre
--   - au plus 3 parties déclarées par champion et par ronde
--   - 30 secondes de battement entre deux déclarations d'un même champion
-- =========================================================================
create or replace function public.declare_battle(
  p_winner_id uuid,
  p_loser_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round  int;
  v_w      record;
  v_l      record;
  v_wa     text;
  v_la     text;
  v_cell   record;
  v_has_cell boolean := false;
  v_battle uuid;
  v_cx     double precision;
  v_cy     double precision;
begin
  if p_winner_id is null or p_loser_id is null then
    raise exception 'Il faut un vainqueur et un vaincu';
  end if;
  if p_winner_id = p_loser_id then
    raise exception 'Le vainqueur et le vaincu doivent être deux champions différents';
  end if;

  select * into v_w from public.champions where id = p_winner_id;
  if not found then raise exception 'Vainqueur introuvable'; end if;
  select * into v_l from public.champions where id = p_loser_id;
  if not found then raise exception 'Vaincu introuvable'; end if;

  v_round := public.current_round();

  if exists (
    select 1 from public.battles b
     where b.round_number = v_round
       and ((b.winner_email = v_w.email and b.loser_email = v_l.email)
         or (b.winner_email = v_l.email and b.loser_email = v_w.email))
  ) then
    raise exception 'Cette partie est déjà déclarée pour la ronde %. Vois avec un organisateur.', v_round;
  end if;

  if (select count(*) from public.battles b
       where b.round_number = v_round
         and (b.winner_email = v_w.email or b.loser_email = v_w.email)) >= 3
     or
     (select count(*) from public.battles b
       where b.round_number = v_round
         and (b.winner_email = v_l.email or b.loser_email = v_l.email)) >= 3
  then
    raise exception 'Trop de parties déjà déclarées pour cette ronde par l''un des deux champions. Vois avec un organisateur.';
  end if;

  if exists (
    select 1 from public.battles b
     where b.created_at > now() - interval '30 seconds'
       and (b.winner_email in (v_w.email, v_l.email) or b.loser_email in (v_w.email, v_l.email))
  ) then
    raise exception 'Une déclaration vient d''être enregistrée. Patiente quelques secondes.';
  end if;

  v_wa := public.region_to_alliance(v_w.region);
  v_la := public.region_to_alliance(v_l.region);
  if v_wa is null or v_wa = 'IDF' or v_la is null or v_la = 'IDF' then
    raise exception 'Un des deux champions n''a pas de camp valide. Vois avec un organisateur.';
  end if;

  -- Même camp : la bataille est consignée, aucun territoire ne bouge.
  if v_wa = v_la then
    insert into public.battles (
      winner_email, loser_email, round_number,
      cell_transferred_id, prev_alliance, prev_owner_email, notes, source
    ) values (
      v_w.email, v_l.email, v_round,
      null, null, null, 'Même camp — pas de cession', 'tablette'
    ) returning id into v_battle;

    return jsonb_build_object(
      'battle_id', v_battle, 'round', v_round,
      'same_alliance', true, 'transferred', false,
      'winner', v_w.pseudo, 'loser', v_l.pseudo,
      'winner_alliance', v_wa, 'loser_alliance', v_la,
      'winner_region', v_w.region, 'loser_region', v_l.region
    );
  end if;

  -- Centroïde du cluster du vainqueur, pour céder le territoire le plus
  -- proche de chez lui : la conquête avance de proche en proche.
  select avg(seed_x), avg(seed_y) into v_cx, v_cy
    from public.cells
   where cluster_owner_email = v_w.email and seed_x is not null and seed_y is not null;

  -- 1) le perdant cède un de SES territoires actuels
  select * into v_cell
    from public.cells
   where current_owner_email = v_l.email and seed_x is not null and seed_y is not null
   order by ((seed_x - coalesce(v_cx, seed_x)) ^ 2 + (seed_y - coalesce(v_cy, seed_y)) ^ 2)
   limit 1;
  v_has_cell := found;

  -- 2) s'il n'a plus rien, son camp paie pour lui
  if not v_has_cell then
    select * into v_cell
      from public.cells
     where current_alliance = v_la and seed_x is not null and seed_y is not null
     order by ((seed_x - coalesce(v_cx, seed_x)) ^ 2 + (seed_y - coalesce(v_cy, seed_y)) ^ 2)
     limit 1;
    v_has_cell := found;
  end if;

  if not v_has_cell then
    insert into public.battles (
      winner_email, loser_email, round_number,
      cell_transferred_id, prev_alliance, prev_owner_email, notes, source
    ) values (
      v_w.email, v_l.email, v_round,
      null, null, null, 'Aucun territoire disponible à céder', 'tablette'
    ) returning id into v_battle;

    return jsonb_build_object(
      'battle_id', v_battle, 'round', v_round,
      'same_alliance', false, 'transferred', false,
      'winner', v_w.pseudo, 'loser', v_l.pseudo,
      'winner_alliance', v_wa, 'loser_alliance', v_la,
      'winner_region', v_w.region, 'loser_region', v_l.region
    );
  end if;

  insert into public.battles (
    winner_email, loser_email, round_number,
    cell_transferred_id, prev_alliance, prev_owner_email, source
  ) values (
    v_w.email, v_l.email, v_round,
    v_cell.id, v_cell.current_alliance, v_cell.current_owner_email, 'tablette'
  ) returning id into v_battle;

  update public.cells
     set current_alliance    = v_wa,
         current_owner_email = v_w.email
   where id = v_cell.id;

  return jsonb_build_object(
    'battle_id', v_battle, 'round', v_round,
    'same_alliance', false, 'transferred', true,
    'cell_id', v_cell.id,
    'winner', v_w.pseudo, 'loser', v_l.pseudo,
    'winner_alliance', v_wa, 'loser_alliance', v_la,
    'winner_region', v_w.region, 'loser_region', v_l.region
  );
end;
$$;

grant execute on function public.declare_battle(uuid, uuid) to anon, authenticated;

-- =========================================================================
-- 5. RPC acclaim_opponent — le salut à l'adversaire
-- Une voix, une seule par partie et par joueur, et seulement entre les
-- deux protagonistes de cette partie précise.
-- =========================================================================
create or replace function public.acclaim_opponent(
  p_battle_id uuid,
  p_from_id   uuid,
  p_to_id     uuid,
  p_kind      text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b    record;
  v_from record;
  v_to   record;
begin
  if p_kind is null or p_kind not in ('fairplay', 'roleplay') then
    raise exception 'Type de salut inconnu';
  end if;
  if p_from_id = p_to_id then
    raise exception 'On ne s''acclame pas soi-même';
  end if;

  select * into v_b from public.battles where id = p_battle_id;
  if not found then raise exception 'Partie introuvable'; end if;

  select * into v_from from public.champions where id = p_from_id;
  if not found then raise exception 'Champion introuvable'; end if;
  select * into v_to from public.champions where id = p_to_id;
  if not found then raise exception 'Champion introuvable'; end if;

  if not ((v_from.email = v_b.winner_email and v_to.email = v_b.loser_email)
       or (v_from.email = v_b.loser_email  and v_to.email = v_b.winner_email)) then
    raise exception 'Ces deux champions ne sont pas ceux de cette partie';
  end if;

  begin
    insert into public.royal_votes (
      champion_id, voices, category, reason, round_number,
      created_by, battle_id, from_champion_id
    ) values (
      p_to_id, 1, p_kind,
      case p_kind
        when 'fairplay' then 'Salué pour son fair-play par ' || v_from.pseudo
        else 'Salué pour son panache par ' || v_from.pseudo
      end,
      v_b.round_number, 'tablette', p_battle_id, p_from_id
    );
  exception when unique_violation then
    raise exception 'Tu as déjà salué ton adversaire pour cette partie';
  end;

  return jsonb_build_object('ok', true, 'to', v_to.pseudo, 'kind', p_kind);
end;
$$;

grant execute on function public.acclaim_opponent(uuid, uuid, uuid, text) to anon, authenticated;
