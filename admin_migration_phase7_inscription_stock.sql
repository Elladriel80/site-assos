-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 7 (compteur d'inscriptions tournoi)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Ajoute la RPC publique `get_inscription_stock()` qui renvoie en temps réel
-- les places restantes par catégorie (equipe / jeu_libre / narratif), pour
-- affichage sur la page Inscriptions du site.
--
-- Comptage (validé avec orga) :
--   1 ligne paid_users dont inscription_type = 'equipe' = 1 équipe enregistrée
--   (peu importe le nombre de coéquipiers déjà forgés).
--
-- Capacités :
--   equipe    : 12 équipes
--   jeu_libre : 50 places
--   narratif  : 10 places
--
-- Idempotent : tu peux la re-jouer sans risque.
-- =========================================================================

create or replace function public.get_inscription_stock()
returns table(
  inscription_type text,
  capacity         int,
  taken            int,
  remaining        int
)
language sql
stable
as $$
  with cap(inscription_type, capacity) as (
    values ('equipe', 12), ('jeu_libre', 50), ('narratif', 10)
  ),
  taken_cte as (
    select inscription_type, count(*)::int as taken
      from public.paid_users
      where inscription_type in ('equipe','jeu_libre','narratif')
      group by inscription_type
  )
  select
    cap.inscription_type,
    cap.capacity,
    coalesce(taken_cte.taken, 0)                 as taken,
    cap.capacity - coalesce(taken_cte.taken, 0)  as remaining
  from cap
    left join taken_cte using (inscription_type)
  order by case cap.inscription_type
    when 'equipe'    then 1
    when 'jeu_libre' then 2
    when 'narratif'  then 3
  end;
$$;

grant execute on function public.get_inscription_stock() to anon, authenticated;
