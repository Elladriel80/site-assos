-- =========================================================================
-- Phase 16 — Le stock jeu_libre / narratif se compte en JOUEURS, pas en lignes
-- paid_users a UNIQUE(email) : depuis l'agregation des billets partageant un
-- meme email (aout 2026, cf. mapImportRows/aggregateImportRowsByEmail dans
-- admin.html), une ligne peut porter plusieurs joueurs (expected_champions > 1).
-- Deux freres inscrits avec la meme adresse ne consommaient qu'une place.
-- 'equipe' reste compte en LIGNES : une ligne = une equipe (capacite 16 equipes).
-- Idempotent : create or replace.
-- =========================================================================
create or replace function public.get_inscription_stock()
returns table(inscription_type text, capacity integer, taken integer, remaining integer, waitlist_count integer)
language sql
stable security definer
set search_path to 'public'
as $function$
  with cap(inscription_type, capacity) as (
    values ('equipe', 16), ('jeu_libre', 36), ('narratif', 22)
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
