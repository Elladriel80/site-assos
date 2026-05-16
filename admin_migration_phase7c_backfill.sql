-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 7c (backfill paid_users → pending_inscriptions)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Recopie les payeurs déjà enregistrés (équipe / jeu_libre / narratif) dans
-- la nouvelle table `pending_inscriptions` au statut "paid", pour que le
-- compteur d'inscriptions reflète immédiatement les inscriptions historiques
-- (1 équipe + 1 jeu libre actuellement).
--
-- Idempotent : la clause NOT EXISTS empêche les doublons si tu re-runs.
-- =========================================================================

insert into public.pending_inscriptions (
  nom,
  prenom,
  email,
  telephone,
  inscription_type,
  team_name,
  role,
  amount_eur,
  payment_status,
  paid_at,
  admin_notes
)
select
  coalesce(nullif(btrim(p.nom),    ''), '—')               as nom,
  coalesce(nullif(btrim(p.prenom), ''), '—')               as prenom,
  lower(btrim(p.email))                                    as email,
  null::text                                               as telephone,
  p.inscription_type,
  nullif(btrim(p.pseudo_assoconnect), '')                  as team_name,
  case when p.inscription_type = 'equipe' then 'capitaine' end as role,
  coalesce(p.montant_eur, 65.0)                            as amount_eur,
  'paid'                                                   as payment_status,
  p.imported_at                                            as paid_at,
  'Backfill phase 7c — depuis paid_users · '
    || coalesce('tx=' || p.transaction_id, 'tx=manuel')    as admin_notes
from public.paid_users p
where p.inscription_type in ('equipe', 'jeu_libre', 'narratif')
  and not exists (
    select 1
      from public.pending_inscriptions pi
      where lower(pi.email) = lower(p.email)
        and pi.inscription_type = p.inscription_type
  );

-- Vérif rapide : compte ce qui a été inséré
-- (les résultats apparaissent après le RUN dans le panneau Result)
select inscription_type, count(*) as backfilled
  from public.pending_inscriptions
  where payment_status = 'paid'
    and admin_notes like 'Backfill phase 7c%'
  group by inscription_type
  order by 1;
