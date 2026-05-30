-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 10
-- Le compteur de places repose désormais sur la VÉRITÉ AssoConnect.
--   ⚠️ À jouer APRÈS les phases 8 (waitlist) et 9 (hold + prix).
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- POURQUOI :
--   Le compteur lisait `pending_inscriptions` (le tunnel), pollué par des
--   doublons et des inscriptions de test marquées « payé » à la main
--   (ex. Kevin BONFICO / De Malt En Pils en triple, Vincent DELVAL...).
--   La vérité, c'est `paid_users` : la whitelist importée depuis l'export
--   AssoConnect (5 équipes + 1 jeu libre = la réalité des paiements).
--
-- NOUVEAU MODÈLE de "taken" (places occupées) :
--   = payeurs confirmés AssoConnect (paid_users)
--   + réservations tunnel encore actives (pending < 30 min, hors waitlist,
--     dont l'email n'est PAS déjà dans paid_users → pas de double comptage).
--   → Recoller à AssoConnect devient automatique : il suffit de ré-importer
--     l'export. Les doublons du tunnel n'ont plus aucun effet sur les places.
--
--   Le tunnel (`pending_inscriptions`) ne sert plus qu'à : la réservation
--   temporaire (30 min) pendant le paiement, et la liste d'attente.
--
-- Idempotent : rejouable sans risque.
-- =========================================================================

-- =========================================================================
-- 1. get_inscription_stock — taken = paid_users + holds actifs
--    security definer : peut lire paid_users même si la RLS le restreint
--    (ne renvoie que des comptes agrégés, aucune donnée perso).
--    Signature phase 8 conservée (5 colonnes, dont waitlist_count).
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
security definer
set search_path = public
as $$
  with cap(inscription_type, capacity) as (
    values ('equipe', 12), ('jeu_libre', 50), ('narratif', 10)
  ),
  -- (1) Payeurs confirmés = vérité AssoConnect
  paid_cte as (
    select inscription_type, count(*)::int as n
      from public.paid_users
      where inscription_type in ('equipe','jeu_libre','narratif')
      group by inscription_type
  ),
  -- (2) Réservations tunnel encore actives (<30 min), pas déjà payées sur AssoConnect
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
  -- Liste d'attente (inchangée : côté tunnel)
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
$$;

grant execute on function public.get_inscription_stock() to anon, authenticated;

-- =========================================================================
-- 2. get_paid_revenue — encaissé réel d'après AssoConnect (paid_users)
--    Renvoie le détail par type + sert à afficher l'encaissé dans l'admin.
-- =========================================================================
create or replace function public.get_paid_revenue()
returns table(
  inscription_type text,
  nb               int,
  total_eur        numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce(inscription_type, '(autre)') as inscription_type,
    count(*)::int                          as nb,
    coalesce(sum(montant_eur), 0)          as total_eur
  from public.paid_users
  group by coalesce(inscription_type, '(autre)')
  order by 1;
$$;

grant execute on function public.get_paid_revenue() to authenticated;

-- =========================================================================
-- Vérif : doit refléter AssoConnect
--   equipe 5/12 (7 libres) · jeu_libre 1/50 (49) · narratif 0/10 (10)
--   encaissé total = 1 690 €
-- =========================================================================
select * from public.get_inscription_stock();
select *, (select sum(total_eur) from public.get_paid_revenue()) as grand_total
  from public.get_paid_revenue();
