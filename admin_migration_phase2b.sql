-- =========================================================================
-- INTER-TOW 2026 — Migration "Risk Géant" Phase 2b (saisie des batailles)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Ajoute :
--  - 2 colonnes prev_alliance, prev_owner_email à `battles` pour permettre
--    l'undo propre (savoir à qui restituer la cellule).
--  - RPC record_battle() : transactionnel UPDATE cell + INSERT battle.
--  - RPC undo_last_battle() : restaure l'état d'avant la dernière bataille.
--
-- Toutes les opérations admin pour la phase 2b passent par ces 2 RPC,
-- plus besoin de toucher au SQL Editor après ça.
-- =========================================================================

alter table public.battles
  add column if not exists prev_alliance     text,
  add column if not exists prev_owner_email  text;

-- =========================================================================
-- RPC : record_battle(winner_email, loser_email, round, cell_id)
-- Renvoie l'UUID de la bataille créée.
-- Cas particuliers :
--  - winner == loser → erreur
--  - même alliance → log bataille SANS cession (cell_id ignoré)
--  - cell_id n'appartient pas à l'alliance perdante → erreur
-- =========================================================================
create or replace function public.record_battle(
  p_winner_email text,
  p_loser_email  text,
  p_round        int,
  p_cell_id      text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_battle_id       uuid;
  v_winner          record;
  v_loser           record;
  v_cell            record;
  v_winner_alliance text;
  v_loser_alliance  text;
begin
  if not public.is_admin() then
    raise exception 'record_battle : admin only';
  end if;

  -- Validations basiques
  if p_winner_email is null or p_loser_email is null then
    raise exception 'winner_email et loser_email obligatoires';
  end if;
  if p_winner_email = p_loser_email then
    raise exception 'Vainqueur et vaincu doivent être différents';
  end if;
  if p_round is null or p_round < 1 or p_round > 5 then
    raise exception 'Round invalide (doit être 1..5)';
  end if;

  select * into v_winner from public.champions where email = p_winner_email;
  if not found then raise exception 'Vainqueur introuvable : %', p_winner_email; end if;
  select * into v_loser  from public.champions where email = p_loser_email;
  if not found then raise exception 'Vaincu introuvable : %', p_loser_email; end if;

  v_winner_alliance := public.region_to_alliance(v_winner.region);
  v_loser_alliance  := public.region_to_alliance(v_loser.region);

  if v_winner_alliance is null or v_winner_alliance = 'IDF'
     or v_loser_alliance is null or v_loser_alliance = 'IDF' then
    raise exception 'Un des champions n''a pas d''alliance valide (IDF non redistribué ?)';
  end if;

  -- Cas même alliance : log de la bataille sans cession
  if v_winner_alliance = v_loser_alliance then
    insert into public.battles (
      winner_email, loser_email, round_number,
      cell_transferred_id, prev_alliance, prev_owner_email, notes
    ) values (
      p_winner_email, p_loser_email, p_round,
      null, null, null, 'Même alliance — pas de cession'
    ) returning id into v_battle_id;
    return v_battle_id;
  end if;

  -- Cession effective : il faut une cell_id valide
  if p_cell_id is null then
    raise exception 'Cellule à céder non choisie';
  end if;
  select * into v_cell from public.cells where id = p_cell_id;
  if not found then raise exception 'Cellule introuvable : %', p_cell_id; end if;
  if v_cell.current_alliance <> v_loser_alliance then
    raise exception 'La cellule % appartient à l''alliance % (et non à l''alliance perdante %)',
      p_cell_id, v_cell.current_alliance, v_loser_alliance;
  end if;

  -- Atomique : INSERT battle (avec prev_*) puis UPDATE cell
  insert into public.battles (
    winner_email, loser_email, round_number,
    cell_transferred_id, prev_alliance, prev_owner_email
  ) values (
    p_winner_email, p_loser_email, p_round,
    p_cell_id, v_cell.current_alliance, v_cell.current_owner_email
  ) returning id into v_battle_id;

  update public.cells
    set current_alliance     = v_winner_alliance,
        current_owner_email  = p_winner_email
    where id = p_cell_id;

  return v_battle_id;
end;
$$;

-- =========================================================================
-- RPC : undo_last_battle()
-- Annule la dernière bataille créée (tri par created_at desc).
-- Si elle a transféré une cellule, restaure l'alliance et l'owner précédents.
-- Renvoie l'UUID annulé ou NULL si aucune bataille.
-- =========================================================================
create or replace function public.undo_last_battle()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_last record;
begin
  if not public.is_admin() then
    raise exception 'undo_last_battle : admin only';
  end if;

  select * into v_last
    from public.battles
    order by created_at desc
    limit 1;

  if not found then
    return null;
  end if;

  if v_last.cell_transferred_id is not null then
    update public.cells
      set current_alliance    = coalesce(v_last.prev_alliance,    original_alliance),
          current_owner_email = coalesce(v_last.prev_owner_email, cluster_owner_email)
      where id = v_last.cell_transferred_id;
  end if;

  delete from public.battles where id = v_last.id;
  return v_last.id;
end;
$$;
