-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 14 (jeu libre 35 -> 36)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Ajuste la capacité jeu_libre de 35 à 36 places dans le CTE `cap` de
-- get_inscription_stock(). Idempotent : create or replace.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.get_inscription_stock()
 RETURNS TABLE(inscription_type text, capacity integer, taken integer, remaining integer, waitlist_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with cap(inscription_type, capacity) as (
    values ('equipe', 16), ('jeu_libre', 36), ('narratif', 22)
  ),
  paid_cte as (
    select inscription_type, count(*)::int as n
      from public.paid_users
      where inscription_type in ('equipe','jeu_libre','narratif')
      group by inscription_type
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
