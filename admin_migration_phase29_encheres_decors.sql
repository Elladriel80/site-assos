-- =========================================================================
-- INTER-TOW 2026 : Migration Phase 29 (vente aux enchères des décors)
-- À exécuter UNE FOIS dans : Supabase Dashboard → SQL Editor → New query
--
-- Couscous met en vente 9 lots de décors (2 tables complètes, 7 décors
-- seuls) au profit de l'événement : 15 % du total des ventes reviennent à
-- l'association, qui encaisse et reverse 85 % à Couscous.
--
-- Offres sous enveloppe : le public voit seulement les lots et la mise à
-- prix, rien sur les offres (ni montant ni nombre), révélées à la clôture.
-- Une offre par personne et par lot, la personne étant identifiée par son
-- téléphone : une nouvelle offre remplace la précédente. Clôture le dimanche 8 novembre 2026 à 16 h.
-- En cas d'égalité en tête, l'admin ouvre un 2e tour réservé aux ex aequo.
--
-- Tout passe par la RPC SECURITY DEFINER place_auction_bid() ; les tables
-- ne sont lisibles que par les admins. Rejouable sans erreur.
-- =========================================================================

-- =========================================================================
-- 1. RÉGLAGES (une seule ligne)
-- =========================================================================
create table if not exists public.auction_settings (
  id         int primary key default 1 check (id = 1),
  closes_at  timestamptz not null default '2026-11-08 16:00:00+01',
  updated_at timestamptz not null default now()
);
insert into public.auction_settings (id) values (1) on conflict do nothing;

alter table public.auction_settings enable row level security;
drop policy if exists "Admins manage auction settings" on public.auction_settings;
create policy "Admins manage auction settings" on public.auction_settings
  for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.auction_settings to authenticated;

-- =========================================================================
-- 2. LES LOTS
-- =========================================================================
create table if not exists public.auction_lots (
  id              text primary key,
  position        int not null default 0,
  category        text not null check (category in ('table', 'decor')),
  name            text not null,
  description     text not null default '',
  min_price       int not null check (min_price >= 0),
  photos          text[] not null default '{}',
  active          boolean not null default true,
  round           int not null default 1 check (round >= 1),
  round_closes_at timestamptz,
  updated_at      timestamptz not null default now()
);

alter table public.auction_lots enable row level security;
drop policy if exists "Admins manage auction lots" on public.auction_lots;
create policy "Admins manage auction lots" on public.auction_lots
  for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.auction_lots to authenticated;

-- Les 9 lots de Couscous. Rejouer le fichier remet nom, prix et photos,
-- mais ne touche ni au tour en cours ni à l'activation.
insert into public.auction_lots (id, position, category, name, description, min_price, photos) values
  ('marais-du-desespoir', 1, 'table', 'Marais du Désespoir',
   'Table complète : tapis et décors (mares, passerelles, arbres morts, collines).', 100,
   array['assets/encheres/marais-1.jpg', 'assets/encheres/marais-2.jpg']),
  ('baghar', 2, 'table', 'Baghar',
   'Table complète : tapis et décors du désert (bâtiments, ruines à colonnes, palmiers, rochers).', 200,
   array['assets/encheres/baghar-1.jpg', 'assets/encheres/baghar-2.jpg', 'assets/encheres/baghar-3.jpg']),
  ('tour-d-arkhan', 3, 'decor', 'Tour d''Arkhan',
   'La grande tour noire et violette, avec son nuage lumineux.', 300,
   array['assets/encheres/tour-1.jpg', 'assets/encheres/tour-2.jpg']),
  ('phare-de-zandri', 4, 'decor', 'Phare de Zandri et ses quais',
   'Le phare sur son îlot, avec ses quais.', 120,
   array['assets/encheres/phare-1.jpg', 'assets/encheres/phare-2.jpg']),
  ('temple-des-terres-brisees', 5, 'decor', 'Temple des Terres Brisées',
   'Temple taillé dans la roche.', 45,
   array['assets/encheres/terres-brisees-1.jpg', 'assets/encheres/terres-brisees-2.jpg']),
  ('statues-de-cobra', 6, 'decor', 'Statues de cobra',
   'Groupe de statues de cobra sur socle.', 30,
   array['assets/encheres/cobra-1.jpg']),
  ('statues-d-arkhan', 7, 'decor', 'Statues d''Arkhan',
   'Groupe de statues d''Arkhan sur socle.', 30,
   array['assets/encheres/arkhan-1.jpg']),
  ('minaret', 8, 'decor', 'Minaret',
   'Minaret à coupoles vertes.', 20,
   array['assets/encheres/minaret-1.jpg']),
  ('temple-satanique', 9, 'decor', 'Temple satanique (étoile bleue)',
   'Photo à venir.', 10,
   '{}'::text[])
on conflict (id) do update set
  position = excluded.position, category = excluded.category, name = excluded.name,
  description = excluded.description, min_price = excluded.min_price,
  photos = case when cardinality(excluded.photos) > 0 then excluded.photos else public.auction_lots.photos end,
  updated_at = now();

-- =========================================================================
-- 3. LES OFFRES (jamais lisibles par le public)
-- =========================================================================
create table if not exists public.auction_bids (
  id         uuid primary key default gen_random_uuid(),
  lot_id     text not null references public.auction_lots(id) on delete cascade,
  round      int not null default 1,
  full_name  text not null,
  pseudo     text not null default '',
  email      text not null,
  phone      text not null,
  amount     int not null check (amount > 0),
  delivery   text not null check (delivery in ('retrait', 'envoi')),
  postcode   text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Le téléphone identifie l'enchérisseur : chiffres seuls, +33 ramené à 0.
create or replace function public.auction_phone_norm(p text)
returns text
language sql
immutable
as $$
  select case
    when d ~ '^0033[1-9][0-9]{8}$' then '0' || substr(d, 5)
    when d ~ '^33[1-9][0-9]{8}$'   then '0' || substr(d, 3)
    else d end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x
$$;

drop index if exists public.uq_auction_bids_lot_email_round;
create unique index if not exists uq_auction_bids_lot_phone_round
  on public.auction_bids (lot_id, public.auction_phone_norm(phone), round);

alter table public.auction_bids enable row level security;
drop policy if exists "Admins manage auction bids" on public.auction_bids;
create policy "Admins manage auction bids" on public.auction_bids
  for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.auction_bids to authenticated;

-- =========================================================================
-- 4. VUE PUBLIQUE : les lots, sans aucun montant d'offre
-- =========================================================================
drop view if exists public.auction_lots_public;
create view public.auction_lots_public as
  select l.id, l.position, l.category, l.name, l.description, l.min_price, l.photos,
         l.round, l.round_closes_at,
         s.closes_at
    from public.auction_lots l
    cross join public.auction_settings s
   where l.active;

grant select on public.auction_lots_public to anon, authenticated;

-- =========================================================================
-- 5. RPC : déposer (ou remplacer) une offre, appelable en anonyme
-- =========================================================================
create or replace function public.place_auction_bid(
  p_lot_id    text,
  p_full_name text,
  p_pseudo    text,
  p_email     text,
  p_phone     text,
  p_amount    int,
  p_delivery  text,
  p_postcode  text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lot       record;
  v_closes    timestamptz;
  v_email     text := lower(btrim(coalesce(p_email, '')));
  v_phone     text := public.auction_phone_norm(p_phone);
  v_prev_max  int;
  v_replaced  boolean := false;
begin
  select * into v_lot from public.auction_lots where id = p_lot_id and active;
  if not found then raise exception 'Ce lot n''existe pas ou n''est plus en vente.'; end if;

  if coalesce(btrim(p_full_name), '') = '' then raise exception 'Indique ton nom et ton prénom.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Adresse email invalide.'; end if;
  if length(v_phone) < 9 then
    raise exception 'Numéro de téléphone invalide.';
  end if;
  if p_delivery not in ('retrait', 'envoi') then raise exception 'Choisis le retrait sur place ou l''envoi.'; end if;
  if p_amount is null or p_amount > 100000 then raise exception 'Montant invalide.'; end if;

  if v_lot.round = 1 then
    select closes_at into v_closes from public.auction_settings where id = 1;
    if now() >= v_closes then raise exception 'Les offres sont closes.'; end if;
    if p_amount < v_lot.min_price then
      raise exception 'L''offre minimum pour ce lot est de % €.', v_lot.min_price;
    end if;
  else
    -- 2e tour (ou suivant) : réservé aux ex aequo du tour précédent.
    if v_lot.round_closes_at is null or now() >= v_lot.round_closes_at then
      raise exception 'Le tour de départage de ce lot est clos.';
    end if;
    select max(amount) into v_prev_max from public.auction_bids
     where lot_id = v_lot.id and round = v_lot.round - 1;
    if not exists (select 1 from public.auction_bids
                    where lot_id = v_lot.id and round = v_lot.round - 1
                      and public.auction_phone_norm(phone) = v_phone and amount = v_prev_max) then
      raise exception 'Ce tour de départage est réservé aux personnes à égalité. Utilise le téléphone de ta première offre.';
    end if;
    if p_amount < v_prev_max then
      raise exception 'Ta nouvelle offre doit être d''au moins % €.', v_prev_max;
    end if;
  end if;

  update public.auction_bids
     set full_name = btrim(p_full_name), pseudo = btrim(coalesce(p_pseudo, '')),
         email = v_email, phone = btrim(p_phone), amount = p_amount, delivery = p_delivery,
         postcode = btrim(coalesce(p_postcode, '')), updated_at = now()
   where lot_id = v_lot.id and round = v_lot.round and public.auction_phone_norm(phone) = v_phone;
  v_replaced := found;

  if not v_replaced then
    insert into public.auction_bids (lot_id, round, full_name, pseudo, email, phone, amount, delivery, postcode)
    values (v_lot.id, v_lot.round, btrim(p_full_name), btrim(coalesce(p_pseudo, '')), v_email,
            btrim(p_phone), p_amount, p_delivery, btrim(coalesce(p_postcode, '')));
  end if;

  return jsonb_build_object('replaced', v_replaced, 'lot', v_lot.name, 'amount', p_amount, 'round', v_lot.round);
end;
$$;

revoke all on function public.place_auction_bid(text, text, text, text, text, int, text, text) from public;
grant execute on function public.place_auction_bid(text, text, text, text, text, int, text, text) to anon, authenticated;
