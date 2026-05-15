-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 5 (import Excel AssoConnect)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Enrichit paid_users avec les colonnes nécessaires pour traquer le type
-- d'inscription (équipe vs solo), le numéro de transaction AssoConnect
-- (clé d'idempotence à l'import), et le nombre de champions attendus.
-- =========================================================================

alter table public.paid_users
  add column if not exists transaction_id      text,
  add column if not exists inscription_type    text check (inscription_type in ('equipe','jeu_libre','narratif','autre')),
  add column if not exists acheteur_email      text,
  add column if not exists expected_champions  int default 1,
  add column if not exists pseudo_assoconnect  text,
  add column if not exists montant_eur         numeric;

create index if not exists idx_paid_users_tx on public.paid_users(transaction_id);

-- Note : pas de UNIQUE sur transaction_id car les paid_users créés à la main
-- (avant l'import Excel) n'en ont pas. La déduplication à l'import se fait
-- côté JS (clé : transaction_id si présent, fallback email).
