-- =========================================================================
-- INTER-TOW 2026 - Phase 18 : nettoyage du doublon Nimp'Games dans admin_users
-- A executer UNE FOIS dans : Supabase Dashboard -> SQL Editor -> New query
--
-- La table admin_users contient deux lignes pour Nimp'Games :
--   nimpgames333@gmail.com   (utile)
--   Nimpgames333@gmail.com   (inutile, N majuscule)
-- is_admin() compare auth.email(), qui renvoie toujours du minuscule, donc la
-- ligne majuscule n'accorde aucun droit et brouille la lecture de la liste.
--
-- Idempotent : rejouable sans erreur si le doublon a deja ete supprime.
-- =========================================================================

-- Verification avant (optionnel, a lancer separement) :
-- select email, added_at, note from public.admin_users order by added_at;

delete from public.admin_users
 where email <> lower(email);

-- =========================================================================
-- VERIFICATION APRES
-- =========================================================================
-- select email, added_at, note from public.admin_users order by added_at;
-- Attendu : une seule ligne nimpgames333@gmail.com, et aucun email contenant
-- une majuscule.
