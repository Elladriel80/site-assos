-- =========================================================================
-- INTER-TOW 2026 - Phase 22 : retrait des droits admin de Chexwiki
-- A executer UNE FOIS dans : Supabase Dashboard -> SQL Editor -> New query
--
-- Chexwiki (chexwiki@gmail.com, ex-responsable tournoi competitif) quitte
-- l'organisation. is_admin() ne s'appuie que sur admin_users : supprimer la
-- ligne retire tous les droits admin (lecture et ecriture) immediatement,
-- y compris sur une session deja ouverte.
--
-- Idempotent : rejouable sans erreur.
-- =========================================================================

delete from public.admin_users
 where lower(email) = 'chexwiki@gmail.com';

-- =========================================================================
-- VERIFICATION APRES
-- =========================================================================
select email, added_at, note from public.admin_users order by added_at;
-- Attendu : plus aucune ligne chexwiki@gmail.com.
