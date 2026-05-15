-- =========================================================================
-- INTER-TOW 2026 — Fix Phase 5 (trigger cells en SECURITY DEFINER)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Problème : depuis qu'on a libéré la forge (phase 4), n'importe quel
-- utilisateur anon peut INSERT dans champions. Mais le trigger automatique
-- qui crée 5 cellules dans `cells` à chaque INSERT champion s'exécutait
-- avec les droits de l'appelant (anon), qui n'a pas la permission RLS
-- pour INSERT dans cells → erreur "new row violates row-level security
-- policy for table cells".
--
-- Fix : passer la fonction en SECURITY DEFINER pour qu'elle bypass la RLS.
-- =========================================================================

create or replace function public.create_cells_for_champion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ally text := public.region_to_alliance(new.region);
begin
  if ally is null or ally = 'IDF' then
    return new;
  end if;

  insert into public.cells (
    id, cluster_owner_email, cluster_index,
    current_alliance, current_owner_email, original_alliance
  )
  select
    new.email || '#' || gs::text,
    new.email,
    gs,
    ally,
    new.email,
    ally
  from generate_series(0, 4) as gs
  on conflict (id) do nothing;

  return new;
end;
$$;

-- Le trigger existant (champions_create_cells) reste accroché à la fonction
-- mise à jour, pas besoin de le recréer.
