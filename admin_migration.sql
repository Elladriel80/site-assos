-- =========================================================================
-- INTER-TOW 2026 — Migration "Mode Admin"
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
-- Cette migration NE TOUCHE PAS aux policies existantes (forge + carte
-- publique continuent à fonctionner). Elle ajoute uniquement le périmètre
-- admin authentifié.
-- =========================================================================

-- =========================================================================
-- TABLE : admin_users
-- Liste blanche des emails ayant les droits admin.
-- Sécurité : la clé est l'email, ce qui veut dire que tu peux créer le
-- compte Supabase Auth AVANT ou APRÈS avoir inséré l'email ici — l'autorisation
-- se fait via matching email JWT au runtime.
-- =========================================================================
create table if not exists public.admin_users (
  email text primary key,
  added_at timestamptz default now(),
  note text
);

alter table public.admin_users enable row level security;

-- =========================================================================
-- HELPER : is_admin()
-- Fonction `security definer` qui peut lire admin_users en bypassant la RLS.
-- Utilisée dans toutes les policies admin ci-dessous.
-- =========================================================================
create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from public.admin_users
    where email = auth.email()
  );
$$;

-- =========================================================================
-- POLICIES — paid_users
-- Les admins authentifiés peuvent tout faire.
-- (La policy "Anon can read paid_users" existante reste active.)
-- =========================================================================
drop policy if exists "Admins full access paid_users" on public.paid_users;
create policy "Admins full access paid_users"
  on public.paid_users
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- =========================================================================
-- POLICIES — champions
-- Les admins authentifiés peuvent tout faire, y compris DELETE
-- (que les policies anon n'autorisent pas).
-- (Les policies anon existantes restent actives.)
-- =========================================================================
drop policy if exists "Admins full access champions" on public.champions;
create policy "Admins full access champions"
  on public.champions
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- =========================================================================
-- POLICIES — admin_users
-- Seuls les admins eux-mêmes peuvent voir cette table.
-- Personne ne peut s'auto-ajouter : insertion uniquement via SQL Editor
-- (où tu as les droits service_role).
-- =========================================================================
drop policy if exists "Admins can read admin_users" on public.admin_users;
create policy "Admins can read admin_users"
  on public.admin_users
  for select
  to authenticated
  using (public.is_admin());

-- =========================================================================
-- AJOUT DU COMPTE ADMIN (déjà pré-rempli avec ton email)
-- Le compte Supabase Auth correspondant doit exister :
--   Dashboard → Authentication → Users → Add user → Auto Confirm User
-- =========================================================================
insert into public.admin_users (email, note)
values ('jean-sebastien.lefevre@vasa.fr', 'Président LSVM, orga InterRégions 2026')
on conflict (email) do nothing;

-- =========================================================================
-- VÉRIFICATION (optionnel)
-- Après login admin.html, lance ce SELECT dans l'éditeur SQL pour vérifier :
-- =========================================================================
-- select * from public.admin_users;
-- select public.is_admin();  -- doit renvoyer true si tu es authentifié admin
