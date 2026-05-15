-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 4 (libération inscription)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Décision orga : on retire le check "email-doit-être-dans-paid_users" pour
-- débloquer les coéquipiers et éviter à l'orga de saisir manuellement chaque
-- nouvel inscrit AssoConnect.
--
-- N'importe qui peut désormais forger un champion avec n'importe quel email.
-- Le tri "qui a vraiment payé" se fait le jour J en croisant côté admin avec
-- la liste AssoConnect.
--
-- Les policies admin et la lecture publique restent inchangées.
-- =========================================================================

-- Suppression des anciennes policies qui exigeaient l'email dans paid_users
drop policy if exists "Anon can insert champion if paid"  on public.champions;
drop policy if exists "Anon can update champion if paid"  on public.champions;

-- Nouvelles policies : INSERT / UPDATE ouverts à tous (anon)
drop policy if exists "Anon can insert champion" on public.champions;
create policy "Anon can insert champion"
  on public.champions for insert to anon
  with check (true);

drop policy if exists "Anon can update champion" on public.champions;
create policy "Anon can update champion"
  on public.champions for update to anon
  using (true) with check (true);

-- (La policy "Anon can read champions" reste active, et la policy admin RLS aussi.)
