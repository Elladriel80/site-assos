-- =========================================================================
-- INTER-TOW 2026 : Migration Phase 24 (jeu libre limité à 4 parties)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
-- (après la phase 23)
--
-- En jeu libre, seules 4 parties par joueur comptent pour la Conquête et
-- la roue de la loose (décision du 3 octobre 2026). La 5e est refusée à la
-- déclaration, sur la tablette comme dans l'admin.
--
-- Pour ça, chaque champion porte désormais son axe (competitif, jeu_libre,
-- narratif). Il est déduit de paid_users à la création, et corrigeable à la
-- main dans l'onglet Champions de l'admin. Un champion sans axe connu n'est
-- jamais bloqué.
-- Rejouable sans erreur.
-- =========================================================================

-- =========================================================================
-- 1. L'AXE DU CHAMPION
-- =========================================================================
alter table public.champions
  add column if not exists axis text
  check (axis in ('competitif', 'jeu_libre', 'narratif'));

-- Devine l'axe à partir des billets AssoConnect :
--   1) le billet est à l'email du champion
--   2) sinon le champion a été invité par un capitaine d'équipe → competitif
--   3) sinon l'email du champion est l'acheteur d'un seul type de billet
create or replace function public.guess_champion_axis(p_email text, p_invited_by text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_type text;
begin
  select inscription_type into v_type from public.paid_users where lower(email) = lower(p_email);
  if v_type is null and p_invited_by is not null then
    v_type := 'equipe';
  end if;
  if v_type is null then
    select min(inscription_type) into v_type
      from public.paid_users
     where lower(acheteur_email) = lower(p_email)
    having count(distinct inscription_type) = 1;
  end if;
  return case v_type
           when 'equipe'    then 'competitif'
           when 'jeu_libre' then 'jeu_libre'
           when 'narratif'  then 'narratif'
           else null
         end;
end;
$$;

-- Rattrapage des champions existants (sans écraser une correction manuelle).
update public.champions c
   set axis = public.guess_champion_axis(c.email, c.invited_by_email)
 where c.axis is null;

-- Les nouveaux champions reçoivent leur axe à la création.
create or replace function public.champions_fill_axis()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.axis is null then
    new.axis := public.guess_champion_axis(new.email, new.invited_by_email);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_champions_fill_axis on public.champions;
create trigger trg_champions_fill_axis before insert on public.champions
  for each row execute function public.champions_fill_axis();

-- =========================================================================
-- 2. LE PLAFOND : 4 parties enregistrées par joueur de jeu libre
-- Posé en trigger sur battles pour couvrir tous les chemins d'écriture
-- (declare_battle de la tablette, record_battle et saisie de l'admin).
-- =========================================================================
create or replace function public.enforce_jeu_libre_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ch record;
  v_n  int;
begin
  for v_ch in
    select pseudo, email from public.champions
     where email in (new.winner_email, new.loser_email) and axis = 'jeu_libre'
  loop
    select count(*) into v_n from public.battles
     where winner_email = v_ch.email or loser_email = v_ch.email;
    if v_n >= 4 then
      raise exception 'Jeu libre : % a déjà 4 parties enregistrées. La 5e ne compte ni pour la Conquête ni pour la roue de la loose.', v_ch.pseudo;
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_battles_jeu_libre_cap on public.battles;
create trigger trg_battles_jeu_libre_cap before insert on public.battles
  for each row execute function public.enforce_jeu_libre_cap();

-- =========================================================================
-- 3. CONTRÔLE : à lire après exécution
-- Les champions sans axe ne sont pas plafonnés : à corriger dans l'onglet
-- Champions de l'admin s'ils jouent en jeu libre.
-- =========================================================================
select coalesce(axis, '(inconnu)') as axe, count(*) as champions
  from public.champions
 group by 1
 order by 1;
