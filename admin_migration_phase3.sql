-- =========================================================================
-- INTER-TOW 2026 — Migration Phase 3 (invitations d'équipe par tokens)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Permet à un capitaine d'équipe (= un paid_user) de générer des liens
-- d'invitation pour ses coéquipiers, qui pourront forger leur champion
-- sans avoir leur propre email dans paid_users.
--
-- Pas de limite sur le nombre d'invitations par capitaine (laissé libre).
-- Traçabilité conservée : on connaît qui a invité qui, et l'email du
-- coéquipier est obligatoire au moment de la forge via token.
-- =========================================================================

-- =========================================================================
-- 1. Colonne sur champions pour tracer le lien capitaine ↔ coéquipier
-- =========================================================================
alter table public.champions
  add column if not exists invited_by_email text;

-- =========================================================================
-- 2. Table team_invites
-- =========================================================================
create table if not exists public.team_invites (
  token text primary key default gen_random_uuid()::text,
  inviter_email text not null references public.paid_users(email) on delete cascade,
  used_by_email text,
  used_at timestamptz,
  notes text,
  created_at timestamptz default now()
);
create index if not exists idx_team_invites_inviter on public.team_invites(inviter_email);
create index if not exists idx_team_invites_used on public.team_invites(used_by_email);

alter table public.team_invites enable row level security;

-- Lecture publique : le token étant un UUID aléatoire, il n'est pas
-- exploitable par bruteforce. Le check d'utilisation se fait côté RPC.
drop policy if exists "Anon can read team_invites" on public.team_invites;
create policy "Anon can read team_invites"
  on public.team_invites for select to anon using (true);

-- Admin : full CRUD
drop policy if exists "Admins full access invites" on public.team_invites;
create policy "Admins full access invites"
  on public.team_invites for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- =========================================================================
-- 3. RPC : generate_invite(inviter_email) → token
-- Le capitaine appelle cette fonction depuis la forge pour créer 1 token.
-- Pas d'auth requise, juste la vérification que l'email du capitaine
-- existe dans paid_users (= a bien payé).
-- =========================================================================
create or replace function public.generate_invite(p_inviter_email text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
begin
  if p_inviter_email is null or p_inviter_email = '' then
    raise exception 'Email du capitaine obligatoire';
  end if;
  if not exists (select 1 from public.paid_users where email = lower(p_inviter_email)) then
    raise exception 'Capitaine inconnu : % (vérifie que tu as bien payé via AssoConnect)', p_inviter_email;
  end if;
  v_token := gen_random_uuid()::text;
  insert into public.team_invites (token, inviter_email)
  values (v_token, lower(p_inviter_email));
  return v_token;
end;
$$;

-- =========================================================================
-- 4. RPC : forge_with_token(...)
-- Insère un champion via un token d'invitation valide. Bypass de la
-- contrainte email-dans-paid_users grâce à SECURITY DEFINER.
-- =========================================================================
create or replace function public.forge_with_token(
  p_token  text,
  p_email  text,
  p_pseudo text,
  p_faction text,
  p_region text,
  p_is_parisian_redistributed boolean,
  p_blason jsonb,
  p_story  text,
  p_heroes text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite record;
  v_champion_id uuid;
begin
  if p_token is null or p_token = '' then
    raise exception 'Token obligatoire';
  end if;
  if p_email is null or p_email = '' then
    raise exception 'Email obligatoire (pour identifier ton inscription)';
  end if;
  if p_pseudo is null or p_pseudo = '' then
    raise exception 'Pseudo obligatoire';
  end if;
  if p_region is null or p_region = '' then
    raise exception 'Région obligatoire';
  end if;

  select * into v_invite from public.team_invites where token = p_token;
  if not found then
    raise exception 'Lien d''invitation introuvable';
  end if;
  if v_invite.used_at is not null then
    raise exception 'Ce lien d''invitation a déjà été utilisé';
  end if;

  -- INSERT du champion (avec lien vers le capitaine)
  insert into public.champions (
    email, pseudo, faction, region, is_parisian_redistributed,
    blason, story, heroes, invited_by_email
  ) values (
    lower(p_email), p_pseudo, p_faction, p_region,
    coalesce(p_is_parisian_redistributed, false),
    p_blason, p_story, coalesce(p_heroes, '{}'::text[]), v_invite.inviter_email
  )
  returning id into v_champion_id;

  -- Marquer le token utilisé
  update public.team_invites
    set used_by_email = lower(p_email),
        used_at = now()
    where token = p_token;

  return v_champion_id;
end;
$$;

-- =========================================================================
-- 5. VÉRIFICATIONS (optionnel)
-- =========================================================================
-- select count(*) as total_invites from public.team_invites;
-- select inviter_email, count(*) as invites, count(used_at) as used
--   from public.team_invites
--   group by inviter_email order by invites desc;
