# Setup admin — InterRégions 2026

Procédure de mise en place du mode admin. **Compte 5 minutes.**

Les 2 placeholders du code sont déjà pré-remplis pour toi :
- `SUPABASE_URL` et `SUPABASE_ANON_KEY` dans `admin.html` (recopiés depuis `carte-inscrits.html`)
- Ton email dans le `insert into admin_users` de `admin_migration.sql`

## 1. Appliquer la migration SQL

1. **Supabase Dashboard → SQL Editor → New query**
2. Colle le contenu de `admin_migration.sql`
3. Clique **Run**

Effet : crée la table `admin_users`, la fonction `is_admin()`, et 3 nouvelles policies RLS qui donnent un accès CRUD complet aux admins authentifiés. **Les policies existantes (forge + carte publique) ne sont pas modifiées.**

## 2. Créer ton compte Supabase Auth

1. **Supabase Dashboard → Authentication → Users → Add user → Create new user**
2. Email : `jean-sebastien.lefevre@vasa.fr` (le même que dans `admin_users`)
3. Password : choisis un mot de passe solide
4. ✅ Coche **Auto Confirm User**
5. **Create user**

## 3. Commit + push

```powershell
git add admin.html admin_migration.sql ADMIN_SETUP.md
git commit -m "feat(admin): page admin avec Supabase Auth + RLS admin_users + seed demo"
git push
```

Netlify redéploie tout seul en ~30 sec.

## 4. Tester

```powershell
start https://inter-tow.netlify.app/admin.html
```

Login avec les credentials de l'étape 2. Tu dois voir le tableau de bord avec les stats des 2 vrais inscrits actuels.

**En cas de pépin** :
- Console DevTools (F12) → message d'erreur Supabase ?
- SQL Editor : `select * from public.admin_users;` retourne bien ton email ?
- SQL Editor (après login) : `select public.is_admin();` retourne `true` ?

## 5. Avant la démo équipe

1. Login admin
2. Onglet **Démo** → bouton **« Injecter 8 champions fictifs »**
3. Ouvre `carte-inscrits.html` dans un autre onglet → vérifie que la carte est bien peuplée
4. Fais ta démo
5. Onglet **Démo** → bouton **« Nettoyer les données démo »**

> ⚠️ Si le bouton « Injecter » plante avec une erreur sur la colonne `region`, c'est que les valeurs de `DEMO_REGIONS` (haut du fichier `admin.html`) ne matchent pas ce qu'attend ta base. Édite la constante avec les noms exacts utilisés dans `inscription-champion.html`.

## Sécurité — ce que tu dois retenir

- L'`SUPABASE_ANON_KEY` est **publique par design** (visible dans tous tes fichiers HTML). Ce qui protège tes données admin, c'est la **RLS sur `admin_users`** + la fonction `is_admin()` qui vérifie le JWT.
- N'ajoute **JAMAIS** la `service_role` key dans un fichier HTML — elle bypasse toute la RLS.
- Pour révoquer un admin : `delete from public.admin_users where email = '…';` dans le SQL Editor. Effet immédiat.

## Évolutions possibles (v2)

- Import CSV en masse depuis l'onglet Payeurs
- Export CSV de la liste des champions
- Mode « magic link » au lieu d'email+password
