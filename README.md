# InterRegions 2026 — The Old World

Site et outils de campagne pour le tournoi inter-régions Warhammer The Old World.

**Événement** : 7-8 novembre 2026 · Troyes
**Organisateurs** : Les Stratèges du Vieux Monde × Fédération France The Old World
**Site live** : https://inter-tow.netlify.app/

## Contenu du repo

| Fichier | Rôle |
|---|---|
| `index.html` | Page d'accueil de l'événement |
| `inscription-champion.html` | Formulaire d'inscription post-paiement (forge du champion + blason) |
| `carte-inscrits.html` | Carte de France publique des champions inscrits, avec live update |
| `supabase_schema.sql` | Schéma de la base de données Supabase (tables `paid_users` + `champions`) |
| `mesnil_panorama_clean.png` | Image de carte (legacy, conservée pour compatibilité) |

## Architecture

```
Paiement AssoConnect
   ↓ (lien dans email de confirmation)
inscription-champion.html (forge)
   ↓ (insert)
Supabase (paid_users whitelist + champions)
   ↑ (read)
carte-inscrits.html (carte publique live)
```

## Stack

- **Frontend** : HTML/CSS/JS vanilla, pas de build, pas de framework
- **Backend** : [Supabase](https://supabase.com) (PostgreSQL + Row Level Security)
- **Hosting** : [Netlify](https://www.netlify.com) (auto-deploy depuis ce repo)
- **Géo** : projection Lambert Conique Conforme implémentée en JS pur, GeoJSON régions pré-2016 embarqué inline (œuvre de [Grégoire David](https://github.com/gregoiredavid/france-geojson))

## Mécanique

- **22 régions** françaises pré-2016, regroupées en **4 alliances** (A/B/C/D) + Île-de-France neutre
- Chaque région conquérable contient **5 cellules**
- Les **parisiens sont redistribués** à la création vers l'une des 3 alliances les moins peuplées
- La **whitelist `paid_users`** est alimentée par export CSV de l'onglet INSCRITS d'AssoConnect
- L'authentification est faite par **matching email** : seuls les emails ayant payé peuvent enregistrer un champion

## Setup côté admin

1. Créer un projet Supabase
2. Lancer le SQL de `supabase_schema.sql` dans le SQL Editor
3. Renseigner les constantes `SUPABASE_URL` et `SUPABASE_ANON_KEY` dans `inscription-champion.html` et `carte-inscrits.html`
4. Configurer Netlify pour déployer ce repo (build vide, branch `main`)
5. Personnaliser l'email de confirmation AssoConnect avec le lien vers `inscription-champion.html`
