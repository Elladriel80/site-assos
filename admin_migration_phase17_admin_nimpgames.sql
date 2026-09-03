-- =========================================================================
-- INTER-TOW 2026 - Phase 17 : compte admin Nimp'Games
-- A executer dans : Supabase Dashboard -> SQL Editor -> New query
--
-- Ajoute Nimp'Games a la liste blanche admin_users (droits admin complets,
-- identiques a ceux du compte president). Aucune modification de policy :
-- is_admin() lit admin_users, donc l'ajout suffit.
--
-- PREREQUIS : creer le compte Supabase Auth correspondant
--   Dashboard -> Authentication -> Users -> Add user -> Create new user
--   Email    : nimpgames333@gmail.com   (STRICTEMENT le meme qu'ici, en minuscules)
--   Password : mot de passe solide, a transmettre a Nimp'Games
--   Cocher   : Auto Confirm User
-- =========================================================================

insert into public.admin_users (email, note)
values (
  lower(trim('nimpgames333@gmail.com')),
  'Nimp''Games - animation axe narratif InterRegions 2026'
)
on conflict (email) do nothing;

-- =========================================================================
-- VERIFICATION
-- =========================================================================
-- select * from public.admin_users order by added_at;

-- =========================================================================
-- REVOCATION (apres l'evenement, ou en cas de besoin)
-- Effet immediat cote RLS. Penser aussi a supprimer / desactiver le compte
-- dans Authentication -> Users.
-- =========================================================================
-- delete from public.admin_users where email = lower('nimpgames333@gmail.com');
