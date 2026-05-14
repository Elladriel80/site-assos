-- =========================================================================
-- INTER-TOW 2026 — Migration "Risk Géant" 2a-bis (territoires Voronoï)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Ajoute 2 colonnes seed_x, seed_y à `cells` pour stocker la position du
-- "point de semence" Voronoï de chaque cellule.
--
-- Ces colonnes sont peuplées par le bouton admin « (Re)Générer les
-- territoires » dans admin.html. Tant qu'elles sont NULL, la carte
-- continue à rendre les hex en cluster (fallback).
-- =========================================================================

alter table public.cells
  add column if not exists seed_x numeric,
  add column if not exists seed_y numeric;

-- =========================================================================
-- RPC : reset_map()
-- Réinitialise la carte avant une régénération des territoires :
--  - remet current_alliance = original_alliance (annule les conquêtes)
--  - remet current_owner_email = cluster_owner_email
--  - efface les seeds (le client va en réécrire des nouveaux derrière)
--  - supprime tout l'historique des batailles
-- Sécurité : SECURITY DEFINER pour bypasser RLS, check is_admin() manuel.
-- =========================================================================
create or replace function public.reset_map()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'reset_map() : admin only';
  end if;
  -- WHERE explicite obligatoire (Supabase bloque les UPDATE/DELETE sans WHERE)
  update public.cells set
    current_alliance = original_alliance,
    current_owner_email = cluster_owner_email,
    seed_x = null,
    seed_y = null
  where id is not null;
  delete from public.battles where id is not null;
end;
$$;

-- =========================================================================
-- VÉRIFICATION (optionnel)
-- =========================================================================
-- select count(*) as cells_with_seeds from public.cells where seed_x is not null;
