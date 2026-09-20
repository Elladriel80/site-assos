-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 19 (jeu libre plafonné à 30 places)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Décision du 20/09/2026 : on arrête les inscriptions. Le jeu libre est
-- ramené de 36 à 30 places, soit exactement le nombre d'inscrits actuels.
-- Les trois axes passent donc à remaining = 0, ce qui déclenche côté public
-- (index.html, loadInscriptionStock) le masquage du CTA vers le tunnel et
-- l'affichage du bloc « Inscriptions complètes ».
-- Seule la valeur jeu_libre change dans le CTE cap, le reste de la phase 16
-- (comptage en joueurs via sum(expected_champions)) est conservé tel quel.
-- Idempotent : create or replace.
-- =========================================================================
create or replace function public.get_inscription_stock()
returns table(inscription_type text, capacity integer, taken integer, remaining integer, waitlist_count integer)
language sql
stable security definer
set search_path to 'public'
as $function$
  with cap(inscription_type, capacity) as (
    values ('equipe', 16), ('jeu_libre', 30), ('narratif', 22)
  ),
  paid_cte as (
    select u.inscription_type,
           case
             when u.inscription_type = 'equipe' then count(*)::int
             else sum(greatest(coalesce(u.expected_champions, 1), 1))::int
           end as n
      from public.paid_users u
      where u.inscription_type in ('equipe','jeu_libre','narratif')
      group by u.inscription_type
  ),
  hold_cte as (
    select p.inscription_type, count(*)::int as n
      from public.pending_inscriptions p
      where p.is_waitlist = false
        and p.payment_status = 'pending'
        and p.created_at > now() - interval '30 minutes'
        and not exists (
          select 1 from public.paid_users u
          where lower(u.email) = lower(p.email)
        )
      group by p.inscription_type
  ),
  wait_cte as (
    select inscription_type, count(*)::int as n
      from public.pending_inscriptions
      where payment_status <> 'cancelled'
        and is_waitlist = true
      group by inscription_type
  ),
  taken_cte as (
    select cap.inscription_type,
           coalesce(paid_cte.n,0) + coalesce(hold_cte.n,0) as taken
      from cap
      left join paid_cte using (inscription_type)
      left join hold_cte using (inscription_type)
  )
  select
    cap.inscription_type,
    cap.capacity,
    coalesce(taken_cte.taken, 0)                              as taken,
    greatest(cap.capacity - coalesce(taken_cte.taken, 0), 0)  as remaining,
    coalesce(wait_cte.n, 0)                                   as waitlist_count
  from cap
    left join taken_cte using (inscription_type)
    left join wait_cte  using (inscription_type)
  order by case cap.inscription_type
    when 'equipe'    then 1
    when 'jeu_libre' then 2
    when 'narratif'  then 3
  end;
$function$;

-- Vérif : les trois axes doivent afficher remaining = 0
select * from public.get_inscription_stock();
