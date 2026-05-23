-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 8 (liste d'attente)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Étend pending_inscriptions pour gérer une file d'attente FIFO.
-- - create_inscription continue d'enregistrer même si plein, mais bascule
--   la nouvelle inscription en waitlist (is_waitlist=true)
-- - get_inscription_stock ne compte plus les waitlist contre la capacité
--   et expose un nouveau champ waitlist_count
-- - Un trigger promeut auto le 1er en attente quand un slot actif est annulé
-- - RPC get_waitlist côté admin pour récupérer noms+emails+position
--
-- Idempotent : rejouable sans risque.
-- =========================================================================

-- =========================================================================
-- 0. Nettoyage des tables orphelines créées par erreur en phase précédente
-- =========================================================================
drop trigger  if exists trg_promote_participants on public.participants;
drop trigger  if exists trg_promote_teams        on public.teams;
drop function if exists public.fn_emit_promotion_event() cascade;
drop function if exists public.register_solo(text,text,text,text,text,text,text,text) cascade;
drop function if exists public.register_team(text,text,text,jsonb,text) cascade;
drop function if exists public.confirm_payment(text,uuid) cascade;
drop function if exists public.cancel_registration(text,uuid) cascade;
drop function if exists public.get_waitlist(text) cascade;
drop view     if exists public.waitlist_positions cascade;
drop view     if exists public.category_capacity  cascade;
drop table    if exists public.promotion_events       cascade;
drop table    if exists public.participants           cascade;
drop table    if exists public.teams                  cascade;
drop table    if exists public.tournament_categories  cascade;

-- =========================================================================
-- 1. Étendre pending_inscriptions
-- =========================================================================
alter table public.pending_inscriptions
  add column if not exists is_waitlist  boolean     not null default false,
  add column if not exists promoted_at  timestamptz;

create index if not exists idx_pending_inscriptions_waitlist
  on public.pending_inscriptions (inscription_type, is_waitlist, created_at)
  where payment_status <> 'cancelled';

-- =========================================================================
-- 2. get_inscription_stock — exclut waitlist du compteur "taken"
--    + nouveau champ waitlist_count (compatible front actuel : champs ajoutés à la fin)
--    DROP nécessaire : on change la signature de retour (4 → 5 colonnes)
-- =========================================================================
drop function if exists public.get_inscription_stock();
create or replace function public.get_inscription_stock()
returns table(
  inscription_type text,
  capacity         int,
  taken            int,
  remaining        int,
  waitlist_count   int
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
        and is_waitlist = false
      group by inscription_type
  ),
  wait_cte as (
    select inscription_type, count(*)::int as wait_cnt
      from public.pending_inscriptions
      where payment_status <> 'cancelled'
        and is_waitlist = true
      group by inscription_type
  )
  select
    cap.inscription_type,
    cap.capacity,
    coalesce(taken_cte.taken, 0)                 as taken,
    cap.capacity - coalesce(taken_cte.taken, 0)  as remaining,
    coalesce(wait_cte.wait_cnt, 0)               as waitlist_count
  from cap
    left join taken_cte using (inscription_type)
    left join wait_cte  using (inscription_type)
  order by case cap.inscription_type
    when 'equipe'    then 1
    when 'jeu_libre' then 2
    when 'narratif'  then 3
  end;
$$;

grant execute on function public.get_inscription_stock() to anon, authenticated;

-- =========================================================================
-- 3. create_inscription — bascule en waitlist si plein (ne raise plus)
--    Retourne en plus : is_waitlist, waitlist_position
--    DROP nécessaire : on change la signature de retour (2 → 4 colonnes)
-- =========================================================================
drop function if exists public.create_inscription(text,text,text,text,text,text,text);
create or replace function public.create_inscription(
  p_nom              text,
  p_prenom           text,
  p_email            text,
  p_telephone        text,
  p_inscription_type text,
  p_team_name        text default null,
  p_role             text default null
)
returns table(
  inscription_id     uuid,
  amount_eur         numeric,
  is_waitlist        boolean,
  waitlist_position  int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_remaining   int;
  v_id          uuid;
  v_amount      numeric := 65.0;
  v_waitlist    boolean;
  v_position    int;
begin
  -- Validations (inchangées)
  if p_nom    is null or btrim(p_nom)    = '' then raise exception 'Nom obligatoire'; end if;
  if p_prenom is null or btrim(p_prenom) = '' then raise exception 'Prénom obligatoire'; end if;
  if p_email  is null or btrim(p_email)  = '' or p_email !~ '^[^@]+@[^@]+\.[^@]+$' then
    raise exception 'Email invalide';
  end if;
  if p_inscription_type not in ('equipe','jeu_libre','narratif') then
    raise exception 'Type d''inscription invalide : %', p_inscription_type;
  end if;
  if p_role is not null and p_role not in ('capitaine','coequipier') then
    raise exception 'Rôle invalide : %', p_role;
  end if;

  -- Verrou par type pour éviter le sold-out en course
  perform pg_advisory_xact_lock(hashtext('pending_inscriptions:' || p_inscription_type)::bigint);

  select remaining into v_remaining
    from public.get_inscription_stock()
    where inscription_type = p_inscription_type;

  v_waitlist := coalesce(v_remaining, 0) <= 0;

  insert into public.pending_inscriptions (
    nom, prenom, email, telephone, inscription_type, team_name, role,
    amount_eur, payment_status, is_waitlist
  ) values (
    btrim(p_nom), btrim(p_prenom), lower(btrim(p_email)), nullif(btrim(p_telephone),''),
    p_inscription_type, nullif(btrim(p_team_name),''), p_role,
    v_amount, 'pending', v_waitlist
  ) returning id into v_id;

  if v_waitlist then
    select count(*)::int into v_position
    from public.pending_inscriptions
    where inscription_type = p_inscription_type
      and is_waitlist = true
      and payment_status <> 'cancelled'
      and created_at <= (select created_at from public.pending_inscriptions where id = v_id);
  end if;

  return query select v_id, v_amount, v_waitlist, v_position;
end;
$$;

grant execute on function public.create_inscription(text,text,text,text,text,text,text)
  to anon, authenticated;

-- =========================================================================
-- 4. Trigger : promotion automatique du 1er en attente sur annulation
--    Se déclenche dès qu'un slot actif passe en 'cancelled'
-- =========================================================================
create or replace function public.tg_promote_on_cancel()
returns trigger
language plpgsql
as $$
begin
  -- Slot actif libéré → on promeut le 1er en attente du même type
  if NEW.payment_status = 'cancelled'
     and OLD.payment_status <> 'cancelled'
     and OLD.is_waitlist = false then
    update public.pending_inscriptions
       set is_waitlist = false,
           promoted_at = now()
     where id = (
       select id from public.pending_inscriptions
       where inscription_type = NEW.inscription_type
         and is_waitlist = true
         and payment_status <> 'cancelled'
       order by created_at asc
       limit 1
     );
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_promote_on_cancel on public.pending_inscriptions;
create trigger trg_promote_on_cancel
  after update on public.pending_inscriptions
  for each row execute function public.tg_promote_on_cancel();

-- =========================================================================
-- 5. get_waitlist — pour l'admin : récupère noms + emails + position
-- =========================================================================
create or replace function public.get_waitlist(p_type text default null)
returns table(
  id                uuid,
  inscription_type  text,
  queue_position    int,
  prenom            text,
  nom               text,
  email             text,
  telephone         text,
  team_name         text,
  role              text,
  created_at        timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with ranked as (
    select id, inscription_type, prenom, nom, email, telephone, team_name, role, created_at,
           row_number() over (partition by inscription_type order by created_at)::int as pos
      from public.pending_inscriptions
      where is_waitlist = true
        and payment_status <> 'cancelled'
  )
  select id, inscription_type, pos, prenom, nom, email, telephone, team_name, role, created_at
    from ranked
   where p_type is null or inscription_type = p_type
   order by inscription_type, pos;
$$;

grant execute on function public.get_waitlist(text) to authenticated;

-- =========================================================================
-- 6. RPC admin manuelle : promouvoir un inscrit précis depuis la waitlist
--    (utile si tu veux choisir qui rappeler hors FIFO)
-- =========================================================================
create or replace function public.promote_waitlist_entry(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.pending_inscriptions
     set is_waitlist = false,
         promoted_at = now()
   where id = p_id
     and is_waitlist = true
     and payment_status <> 'cancelled';
  if not found then raise exception 'Entrée waitlist introuvable : %', p_id; end if;
end;
$$;

grant execute on function public.promote_waitlist_entry(uuid) to authenticated;
