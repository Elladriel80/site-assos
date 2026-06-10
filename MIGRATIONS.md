# Migrations Supabase — Inter-Tow 2026

Ce repo n'utilise pas d'outil de migration automatique (pas de `supabase migrations`, pas de Prisma). Chaque évolution du schéma est un fichier SQL idempotent à exécuter à la main dans le **SQL Editor** du Dashboard Supabase.

## Ordre d'application (reconstruction depuis zéro)

Pour rejouer la base sur un projet Supabase vierge, exécuter les fichiers **dans cet ordre** :

| # | Fichier | Phase | Apporte |
|---|---|---|---|
| 1 | `supabase_schema.sql` | Foundation | Tables `paid_users`, `champions` + RLS de base + GeoJSON régions |
| 2 | `admin_migration.sql` | Phase 1 — Admin | Table `admin_users`, fonction `is_admin()`, policies admin |
| 3 | `admin_migration_phase2.sql` | Phase 2a — Risk Géant foundation | Tables `cells` + `battles`, fonction `region_to_alliance()`, trigger 5 cells/champion |
| 4 | `admin_migration_phase2bis.sql` | Phase 2a-bis — Voronoï | Colonnes `seed_x`/`seed_y` sur `cells`, RPC `reset_map()` |
| 5 | `admin_migration_phase2b.sql` | Phase 2b — Batailles | RPCs `record_battle()` + `undo_last_battle()` |
| 6 | `admin_migration_phase3.sql` | Phase 3 — Invitations équipe | RPCs `generate_invite()` + `forge_with_token()`, colonne `champions.invited_by_email` |
| 7 | `admin_migration_phase4.sql` | Phase 4 — Libération forge | Suppression du check `paid_users` côté forge anon (le tri se fait côté admin) |
| 8 | `admin_migration_phase5.sql` | Phase 5 — Import AssoConnect | Colonnes enrichies sur `paid_users` (`transaction_id`, `inscription_type`, `acheteur_email`, `expected_champions`, `pseudo_assoconnect`, `montant_eur`) |
| 9 | `admin_migration_phase5_fix.sql` | Fix Phase 5 | Trigger `create_cells_for_champion()` en `SECURITY DEFINER` (sinon les anons libérés en phase 4 ne peuvent plus créer leurs cells) |
| … | `admin_migration_phase11_fix_is_waitlist_ambiguous.sql` | Phase 11 — Fix réservation | Qualifie les références `is_waitlist` dans `create_inscription` (bug « column reference "is_waitlist" is ambiguous » à la réservation) |
| … | `admin_migration_phase12_narratif_capacity_16.sql` | Phase 12 — Capacité narratif | Passe la capacité narratif de 10 à 16 places dans le CTE `cap` de `get_inscription_stock()` |

## Procédure pour appliquer une nouvelle migration

1. Créer un nouveau fichier `admin_migration_phaseN.sql` à la racine du repo.
2. En-tête commentée standardisée :
   ```sql
   -- =========================================================================
   -- INTER-TOW 2026 — Migration Phase N (titre court)
   -- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
   --
   -- Description courte du pourquoi et du quoi.
   -- =========================================================================
   ```
3. Écrire idempotent : `create table if not exists`, `create or replace function`, `drop policy if exists ... ; create policy ...`. Tout le monde doit pouvoir re-jouer le fichier sans erreur si déjà appliqué.
4. **Tester sur la DB de prod**, puis ajouter une ligne dans le tableau ci-dessus avec la nouvelle phase + description.
5. Commit + push.

## Notes garde-fou

- Les `UPDATE` / `DELETE` sur la table `cells` **doivent toujours** avoir un `WHERE` explicite — Supabase bloque sinon (RLS safety).
- Tous les RPC qui font des inserts/updates côté forge anon doivent être `SECURITY DEFINER` (cf. fix Phase 5). Sinon les RLS bloquent l'auteur de la requête.
- L'admin et l'anon partagent la même base : le check d'autorisation passe par `is_admin()` dans les policies, pas par des bases séparées.
