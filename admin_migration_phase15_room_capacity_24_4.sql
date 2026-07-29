-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 15 (Augmentation stock chambres)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Passe les capacités de chambres physiques (Résidence du Lac d'Orient) :
--   double : 10 → 24   ·   triple : 3 → 4   (simple : 1 inchangé)
-- dans le CTE `cap` de get_room_stock(). Idempotent (create or replace).
-- =========================================================================
create or replace function public.get_room_stock()
returns table(
  room_type     text,
  capacity      int,
  taken         int,
  remaining     int
)
language sql
stable
as $$
  with cap(room_type, capacity) as (
    values ('simple', 1), ('double', 24), ('triple', 4)
  ),
  taken_cte as (
    select room_type, count(*)::int as taken
      from public.room_reservations
      where payment_status <> 'cancelled'
      group by room_type
  )
  select
    cap.room_type,
    cap.capacity,
    coalesce(taken_cte.taken, 0)                       as taken,
    cap.capacity - coalesce(taken_cte.taken, 0)        as remaining
  from cap
    left join taken_cte using (room_type)
  order by case cap.room_type when 'simple' then 1 when 'double' then 2 when 'triple' then 3 end;
$$;

grant execute on function public.get_room_stock() to anon, authenticated;
