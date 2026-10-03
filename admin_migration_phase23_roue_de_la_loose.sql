-- =========================================================================
-- INTER-TOW 2026 : Migration Phase 23 (roue de la loose)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Clin d'oeil à la team auxerroise qui a imaginé le concept. Le vaincu
-- déclare sa partie à la tablette comme d'habitude, puis va sur un stand
-- exposant. L'exposant ouvre la roue sur son téléphone avec le lien de son
-- stand, choisit le joueur dans la liste des défaites pas encore tirées et
-- lance la roue : un numéro de 1 à 10, et le stand remet le lot qu'il a
-- défini pour ce numéro.
--
-- Les exposants n'ont pas de compte : chaque stand a un jeton secret dans
-- son lien, et tout passe par des RPC SECURITY DEFINER qui le vérifient.
-- Le tirage est fait PAR LA BASE, l'écran ne fait qu'animer la roue.
-- Un seul tirage par défaite, garanti par un index unique.
-- Rejouable sans erreur.
-- =========================================================================

-- =========================================================================
-- 1. LES STANDS
-- =========================================================================
create table if not exists public.loose_stands (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  token      text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 16),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.loose_stands enable row level security;
drop policy if exists "Admins manage loose stands" on public.loose_stands;
create policy "Admins manage loose stands" on public.loose_stands
  for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.loose_stands to authenticated;

-- =========================================================================
-- 2. LES LOTS : 10 par stand
-- =========================================================================
create table if not exists public.loose_prizes (
  stand_id   uuid not null references public.loose_stands(id) on delete cascade,
  number     int not null check (number between 1 and 10),
  label      text not null default '',
  updated_at timestamptz not null default now(),
  primary key (stand_id, number)
);

alter table public.loose_prizes enable row level security;
drop policy if exists "Admins manage loose prizes" on public.loose_prizes;
create policy "Admins manage loose prizes" on public.loose_prizes
  for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.loose_prizes to authenticated;

-- Chaque nouveau stand reçoit 10 lots à renommer.
create or replace function public.loose_stand_seed_prizes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.loose_prizes (stand_id, number, label)
  select new.id, n, 'Lot n°' || n from generate_series(1, 10) as n
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists trg_loose_stand_seed on public.loose_stands;
create trigger trg_loose_stand_seed after insert on public.loose_stands
  for each row execute function public.loose_stand_seed_prizes();

-- =========================================================================
-- 3. LES TIRAGES : un par défaite
-- =========================================================================
create table if not exists public.loose_spins (
  id           uuid primary key default gen_random_uuid(),
  battle_id    uuid not null references public.battles(id) on delete cascade,
  champion_id  uuid references public.champions(id) on delete set null,
  stand_id     uuid references public.loose_stands(id) on delete set null,
  number       int not null check (number between 1 and 10),
  prize_label  text not null default '',
  round_number int,
  created_at   timestamptz not null default now()
);

create unique index if not exists uq_loose_spins_battle on public.loose_spins(battle_id);

alter table public.loose_spins enable row level security;
drop policy if exists "Admins manage loose spins" on public.loose_spins;
create policy "Admins manage loose spins" on public.loose_spins
  for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.loose_spins to authenticated;

-- =========================================================================
-- 4. RPC appelées par le téléphone de l'exposant (anonyme + jeton)
-- =========================================================================

-- Le stand, ses lots et les défaites pas encore tirées (sans aucun email).
create or replace function public.loose_stand_info(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_stand record;
begin
  select * into v_stand from public.loose_stands where token = p_token and active;
  if not found then raise exception 'Lien de stand invalide ou désactivé. Vois avec un organisateur.'; end if;

  return jsonb_build_object(
    'stand', jsonb_build_object('id', v_stand.id, 'name', v_stand.name),
    'round', public.current_round(),
    'prizes', coalesce((
      select jsonb_agg(jsonb_build_object('number', p.number, 'label', p.label) order by p.number)
        from public.loose_prizes p where p.stand_id = v_stand.id), '[]'::jsonb),
    'pending', coalesce((
      select jsonb_agg(jsonb_build_object(
               'battle_id', b.id, 'round', b.round_number, 'created_at', b.created_at,
               'loser_id', lc.id, 'loser', lc.pseudo, 'loser_region', lc.region,
               'winner', wc.pseudo) order by b.created_at desc)
        from public.battles b
        join public.champions lc on lc.email = b.loser_email
        left join public.champions wc on wc.email = b.winner_email
       where not exists (select 1 from public.loose_spins s where s.battle_id = b.id)), '[]'::jsonb)
  );
end;
$$;

-- L'exposant renomme ses 10 lots.
create or replace function public.loose_save_prizes(p_token text, p_labels text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stand record;
  i int;
begin
  select * into v_stand from public.loose_stands where token = p_token and active;
  if not found then raise exception 'Lien de stand invalide ou désactivé.'; end if;
  if p_labels is null or array_length(p_labels, 1) <> 10 then
    raise exception 'Il faut exactement 10 lots.';
  end if;
  for i in 1..10 loop
    if coalesce(btrim(p_labels[i]), '') = '' then
      raise exception 'Le lot n°% est vide.', i;
    end if;
    insert into public.loose_prizes (stand_id, number, label, updated_at)
    values (v_stand.id, i, left(btrim(p_labels[i]), 80), now())
    on conflict (stand_id, number) do update set label = excluded.label, updated_at = now();
  end loop;
end;
$$;

-- Le tirage.
create or replace function public.spin_loose_wheel(p_token text, p_battle_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stand  record;
  v_b      record;
  v_loser  record;
  v_spin   record;
  v_number int;
  v_label  text;
begin
  select * into v_stand from public.loose_stands where token = p_token and active;
  if not found then raise exception 'Lien de stand invalide ou désactivé.'; end if;

  select * into v_b from public.battles where id = p_battle_id;
  if not found then raise exception 'Défaite introuvable. Le joueur a-t-il déclaré sa partie à la tablette ?'; end if;

  select * into v_loser from public.champions where email = v_b.loser_email;
  if not found then raise exception 'Joueur introuvable'; end if;

  if exists (select 1 from public.loose_spins where battle_id = p_battle_id) then
    raise exception 'La roue a déjà été lancée pour cette défaite.';
  end if;

  v_number := 1 + floor(random() * 10)::int;
  select label into v_label from public.loose_prizes where stand_id = v_stand.id and number = v_number;

  insert into public.loose_spins (battle_id, champion_id, stand_id, number, prize_label, round_number)
  values (p_battle_id, v_loser.id, v_stand.id, v_number, coalesce(v_label, ''), v_b.round_number)
  returning * into v_spin;

  return jsonb_build_object('spin_id', v_spin.id, 'number', v_number,
                            'label', coalesce(v_label, ''), 'loser', v_loser.pseudo);
exception
  when unique_violation then
    raise exception 'La roue a déjà été lancée pour cette défaite.';
end;
$$;

grant execute on function public.loose_stand_info(text) to anon, authenticated;
grant execute on function public.loose_save_prizes(text, text[]) to anon, authenticated;
grant execute on function public.spin_loose_wheel(text, uuid) to anon, authenticated;
