-- =============================================================================
--  Atelier — MVP « tableau des commandes »
--  Migration initiale : schéma, contraintes, triggers, RLS
--  Cible : PostgreSQL 15+ / Supabase
-- =============================================================================
--  Principes
--   · organisation_id sur toutes les tables + RLS → multi-tenant dès le jour 1
--   · clés étrangères composites (organisation_id, id) → impossible de lier
--     des données de deux boutiques différentes, même par erreur applicative
--   · snapshots (prix, adresse) → une commande passée ne change jamais
--   · un seul point de vérité par axe : préparation (commande.statut),
--     logistique (livraison.statut), paiement (CALCULÉ dans la vue)
--   · soft delete (deleted_at) + anonymisation nLPD pour les clients
-- =============================================================================

create schema if not exists extensions;
create extension if not exists pg_trgm  with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists app;

-- -----------------------------------------------------------------------------
--  Énumérations
-- -----------------------------------------------------------------------------
create type public.role_utilisateur as enum ('gerant', 'vente', 'atelier', 'livreur');
create type public.type_client      as enum ('particulier', 'entreprise');
create type public.canal_commande   as enum ('comptoir', 'telephone', 'web', 'evenement');
create type public.mode_remise      as enum ('retrait', 'livraison');
create type public.statut_commande  as enum ('recue', 'en_preparation', 'prete', 'terminee', 'annulee');
create type public.statut_livraison as enum ('a_planifier', 'planifiee', 'en_route', 'livree', 'echec');
create type public.mode_paiement    as enum ('especes', 'carte', 'twint', 'facture', 'en_ligne');

-- -----------------------------------------------------------------------------
--  Organisation (la boutique = le tenant)
-- -----------------------------------------------------------------------------
create table public.organisation (
  id            uuid primary key default gen_random_uuid(),
  nom           text not null,
  adresse       text,
  telephone     text,
  email         text,
  no_tva        text,                         -- CHE-xxx.xxx.xxx TVA
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
--  Utilisateurs (équipe)
--  auth_user_id : compte Supabase (gérante, ou compte « poste » de la tablette)
--  pin_hash     : code à 4-6 chiffres pour changer d'utilisateur sur la tablette
--                 → jamais stocké en clair (bcrypt via pgcrypto)
-- -----------------------------------------------------------------------------
create table public.utilisateur (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisation(id) on delete cascade,
  auth_user_id    uuid unique,
  nom             text not null,
  role            public.role_utilisateur not null,
  pin_hash        text,
  actif           boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (organisation_id, id)
);

-- -----------------------------------------------------------------------------
--  Clients
-- -----------------------------------------------------------------------------
create table public.client (
  id                uuid primary key default gen_random_uuid(),
  organisation_id   uuid not null references public.organisation(id) on delete cascade,
  type              public.type_client not null default 'particulier',
  nom               text not null,
  prenom            text,
  raison_sociale    text,
  telephone         text,                       -- format E.164 : +41791234567
  email             text,
  langue            text not null default 'fr',
  notes             text,                       -- préférences : « pas de lys », « adore les pivoines »
  consentement_sms  boolean not null default false,
  anonymise_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  unique (organisation_id, id),
  constraint client_telephone_e164 check (telephone is null or telephone ~ '^\+[1-9][0-9]{6,14}$'),
  constraint client_email_format   check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

create index client_org_telephone_idx on public.client (organisation_id, telephone) where deleted_at is null;
create index client_nom_trgm_idx      on public.client using gin (lower(coalesce(prenom,'') || ' ' || nom || ' ' || coalesce(raison_sociale,'')) extensions.gin_trgm_ops);

-- -----------------------------------------------------------------------------
--  Adresses = carnet de destinataires du client
--  (le client paie, le destinataire reçoit)
-- -----------------------------------------------------------------------------
create table public.adresse (
  id                 uuid primary key default gen_random_uuid(),
  organisation_id    uuid not null,
  client_id          uuid,
  libelle            text,                      -- « Maman », « Bureau »
  destinataire_nom   text not null,
  destinataire_tel   text,
  rue                text not null,
  npa                text not null,
  localite           text not null,
  instructions       text,                      -- code porte, étage, « sonner chez la voisine »
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz,
  unique (organisation_id, id),
  foreign key (organisation_id, client_id) references public.client (organisation_id, id) on delete cascade,
  constraint adresse_npa_ch check (npa ~ '^[0-9]{4,5}$'),
  constraint adresse_tel_e164 check (destinataire_tel is null or destinataire_tel ~ '^\+[1-9][0-9]{6,14}$')
);

create index adresse_client_idx on public.adresse (client_id) where deleted_at is null;

-- -----------------------------------------------------------------------------
--  Produits (catalogue OPTIONNEL — le sur-mesure reste du texte libre)
-- -----------------------------------------------------------------------------
create table public.produit (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisation(id) on delete cascade,
  nom             text not null,
  categorie       text,
  prix_base       numeric(10,2) not null check (prix_base >= 0),
  taux_tva        numeric(4,2)  not null default 2.6 check (taux_tva between 0 and 100),
  photo_url       text,
  actif           boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (organisation_id, id)
);

-- -----------------------------------------------------------------------------
--  Commandes (« bons »)
-- -----------------------------------------------------------------------------
create table public.compteur_commande (
  organisation_id uuid not null references public.organisation(id) on delete cascade,
  annee           int  not null,
  dernier         int  not null default 0,
  primary key (organisation_id, annee)
);

create table public.commande (
  id               uuid primary key default gen_random_uuid(),
  organisation_id  uuid not null,
  numero           text not null,                -- généré : 2026-0142
  client_id        uuid not null,
  canal            public.canal_commande  not null default 'comptoir',
  statut           public.statut_commande not null default 'recue',
  mode_remise      public.mode_remise     not null default 'retrait',
  date_souhaitee   date not null,
  creneau          text,                         -- « matin », « 14h-16h », « avant 11h »
  message_carte    text,
  notes_internes   text,
  pris_par         uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz,
  unique (organisation_id, id),
  unique (organisation_id, numero),
  foreign key (organisation_id, client_id) references public.client (organisation_id, id),
  foreign key (organisation_id, pris_par)  references public.utilisateur (organisation_id, id)
);

create index commande_tableau_idx on public.commande (organisation_id, date_souhaitee, statut) where deleted_at is null;
create index commande_client_idx  on public.commande (client_id);

-- -----------------------------------------------------------------------------
--  Lignes de commande (prix et TVA FIGÉS au moment de la commande)
-- -----------------------------------------------------------------------------
create table public.ligne (
  id               uuid primary key default gen_random_uuid(),
  organisation_id  uuid not null,
  commande_id      uuid not null,
  produit_id       uuid,
  description      text not null,               -- « Bouquet champêtre, tons pastel »
  quantite         numeric(10,2) not null default 1 check (quantite > 0),
  prix_unitaire    numeric(10,2) not null check (prix_unitaire >= 0),
  taux_tva         numeric(4,2)  not null default 2.6 check (taux_tva between 0 and 100),
  position         int not null default 0,
  created_at       timestamptz not null default now(),
  foreign key (organisation_id, commande_id) references public.commande (organisation_id, id) on delete cascade,
  foreign key (organisation_id, produit_id)  references public.produit  (organisation_id, id)
);

create index ligne_commande_idx on public.ligne (commande_id);

-- -----------------------------------------------------------------------------
--  Livraisons (0 ou 1 par commande ; adresse COPIÉE en snapshot)
-- -----------------------------------------------------------------------------
create table public.livraison (
  id                uuid primary key default gen_random_uuid(),
  organisation_id   uuid not null,
  commande_id       uuid not null unique,
  adresse_id        uuid,                         -- provenance, pour info
  adresse_snapshot  jsonb not null,               -- ce qui a réellement servi
  livreur_id        uuid,
  date_tournee      date,
  ordre_tournee     int,
  statut            public.statut_livraison not null default 'a_planifier',
  livree_at         timestamptz,
  receptionnaire    text,                         -- « la concierge », « M. Favre »
  photo_url         text,
  motif_echec       text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (organisation_id, commande_id) references public.commande    (organisation_id, id) on delete cascade,
  foreign key (organisation_id, adresse_id)  references public.adresse     (organisation_id, id),
  foreign key (organisation_id, livreur_id)  references public.utilisateur (organisation_id, id),
  constraint livraison_snapshot_complet check (adresse_snapshot ?& array['destinataire_nom','rue','npa','localite']),
  constraint livraison_echec_motif      check (statut <> 'echec' or motif_echec is not null)
);

create index livraison_tournee_idx on public.livraison (organisation_id, date_tournee, livreur_id, ordre_tournee);

-- -----------------------------------------------------------------------------
--  Paiements (le statut de paiement n'est PAS stocké : il est calculé)
-- -----------------------------------------------------------------------------
create table public.paiement (
  id               uuid primary key default gen_random_uuid(),
  organisation_id  uuid not null,
  commande_id      uuid not null,
  montant          numeric(10,2) not null check (montant <> 0),   -- négatif = remboursement
  mode             public.mode_paiement not null,
  date_paiement    timestamptz not null default now(),
  ref_externe      text,                                          -- id Bexio, n° QR-facture…
  encaisse_par     uuid,
  created_at       timestamptz not null default now(),
  foreign key (organisation_id, commande_id)  references public.commande    (organisation_id, id) on delete cascade,
  foreign key (organisation_id, encaisse_par) references public.utilisateur (organisation_id, id)
);

create index paiement_commande_idx on public.paiement (commande_id);

-- -----------------------------------------------------------------------------
--  Historique des statuts (alimenté UNIQUEMENT par trigger)
-- -----------------------------------------------------------------------------
create table public.historique (
  id               uuid primary key default gen_random_uuid(),
  organisation_id  uuid not null,
  commande_id      uuid not null,
  objet            text not null check (objet in ('commande', 'livraison')),
  de_statut        text,
  vers_statut      text not null,
  utilisateur_id   uuid,
  at               timestamptz not null default clock_timestamp(),   -- précis même dans une transaction
  foreign key (organisation_id, commande_id) references public.commande (organisation_id, id) on delete cascade
);

create index historique_commande_idx on public.historique (commande_id, at);

-- -----------------------------------------------------------------------------
--  Occasions récurrentes (fidélisation)
-- -----------------------------------------------------------------------------
create table public.occasion (
  id                  uuid primary key default gen_random_uuid(),
  organisation_id     uuid not null,
  client_id           uuid not null,
  libelle             text not null,                 -- « Anniversaire de sa mère »
  jour                smallint not null check (jour between 1 and 31),
  mois                smallint not null check (mois between 1 and 12),
  adresse_id          uuid,
  rappel_jours_avant  smallint not null default 5 check (rappel_jours_avant between 0 and 60),
  actif               boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  foreign key (organisation_id, client_id)  references public.client  (organisation_id, id) on delete cascade,
  foreign key (organisation_id, adresse_id) references public.adresse (organisation_id, id)
);

-- =============================================================================
--  Fonctions utilitaires
-- =============================================================================

-- Organisations accessibles par le compte connecté
create or replace function app.mes_organisations()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select u.organisation_id from public.utilisateur u
  where u.auth_user_id = auth.uid() and u.actif;
$$;

-- Utilisateur applicatif courant (pour la traçabilité de l'historique).
-- Sur la tablette partagée, l'app envoie l'en-tête HTTP « x-utilisateur »
-- (id choisi après saisie du PIN) ; il n'est accepté que s'il appartient à la
-- même boutique que le compte connecté. Sinon : l'utilisateur lié au compte.
create or replace function app.utilisateur_courant()
returns uuid
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare
  v_header text;
  v_id     uuid;
begin
  begin
    v_header := nullif(current_setting('request.headers', true), '')::json ->> 'x-utilisateur';
  exception when others then
    v_header := null;
  end;

  if v_header ~* '^[0-9a-f-]{36}$' then
    select u.id into v_id from public.utilisateur u
     where u.id = v_header::uuid and u.actif
       and u.organisation_id in (select app.mes_organisations());
    if v_id is not null then
      return v_id;
    end if;
  end if;

  select u.id into v_id from public.utilisateur u
   where u.auth_user_id = auth.uid() and u.actif
   limit 1;
  return v_id;
end;
$$;

create or replace function app.est_gerant(p_org uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.utilisateur u
    where u.auth_user_id = auth.uid() and u.organisation_id = p_org
      and u.role = 'gerant' and u.actif
  );
$$;

-- Vérification du PIN (appelée par l'app au changement d'utilisateur)
create or replace function app.verifier_pin(p_utilisateur uuid, p_pin text)
returns boolean
language sql stable security definer set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.utilisateur u
    where u.id = p_utilisateur and u.actif
      and u.organisation_id in (select app.mes_organisations())
      and u.pin_hash is not null
      and u.pin_hash = crypt(p_pin, u.pin_hash)
  );
$$;

create or replace function app.definir_pin(p_utilisateur uuid, p_pin text)
returns void
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
begin
  if p_pin !~ '^[0-9]{4,6}$' then
    raise exception 'Le PIN doit contenir 4 à 6 chiffres';
  end if;
  update public.utilisateur u
     set pin_hash = crypt(p_pin, gen_salt('bf'))
   where u.id = p_utilisateur
     and app.est_gerant(u.organisation_id);
  if not found then
    raise exception 'Utilisateur introuvable ou droits insuffisants';
  end if;
end;
$$;

-- =============================================================================
--  Triggers
-- =============================================================================

-- updated_at automatique
create or replace function app.tg_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['organisation','utilisateur','client','adresse','produit',
                           'commande','livraison','occasion']
  loop
    execute format('create trigger %I_updated_at before update on public.%I
                    for each row execute function app.tg_updated_at()', t, t);
  end loop;
end $$;

-- Numéro lisible par boutique et par année : 2026-0001, 2026-0002…
create or replace function app.tg_commande_numero()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_annee int := extract(year from coalesce(new.created_at, now()))::int;
  v_seq   int;
begin
  if new.numero is null or new.numero = '' then
    insert into public.compteur_commande as c (organisation_id, annee, dernier)
    values (new.organisation_id, v_annee, 1)
    on conflict (organisation_id, annee) do update set dernier = c.dernier + 1
    returning dernier into v_seq;
    new.numero := v_annee || '-' || lpad(v_seq::text, 4, '0');
  end if;
  if new.pris_par is null then
    new.pris_par := app.utilisateur_courant();
  end if;
  return new;
end;
$$;

create trigger commande_numero before insert on public.commande
  for each row execute function app.tg_commande_numero();

-- Historique : création et changements de statut de la commande
create or replace function app.tg_historique_commande()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' or new.statut is distinct from old.statut then
    insert into public.historique (organisation_id, commande_id, objet, de_statut, vers_statut, utilisateur_id)
    values (new.organisation_id, new.id, 'commande',
            case when tg_op = 'UPDATE' then old.statut::text end,
            new.statut::text, app.utilisateur_courant());
  end if;
  return null;
end;
$$;

create trigger commande_historique after insert or update on public.commande
  for each row execute function app.tg_historique_commande();

-- Livraison : cohérence avec la commande + horodatage
create or replace function app.tg_livraison_avant()
returns trigger language plpgsql as $$
declare v_mode public.mode_remise;
begin
  if tg_op = 'INSERT' then
    select c.mode_remise into v_mode from public.commande c where c.id = new.commande_id;
    if v_mode <> 'livraison' then
      raise exception 'La commande % est en retrait : pas de livraison possible', new.commande_id;
    end if;
  end if;
  if new.statut = 'livree' and new.livree_at is null then
    new.livree_at := now();
  end if;
  if new.livreur_id is not null and new.date_tournee is not null and new.statut = 'a_planifier' then
    new.statut := 'planifiee';
  end if;
  return new;
end;
$$;

create trigger livraison_avant before insert or update on public.livraison
  for each row execute function app.tg_livraison_avant();

-- Livraison : historique + passage de la commande en « terminee » quand livrée
create or replace function app.tg_livraison_apres()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' or new.statut is distinct from old.statut then
    insert into public.historique (organisation_id, commande_id, objet, de_statut, vers_statut, utilisateur_id)
    values (new.organisation_id, new.commande_id, 'livraison',
            case when tg_op = 'UPDATE' then old.statut::text end,
            new.statut::text, app.utilisateur_courant());
  end if;

  if new.statut = 'livree' then
    update public.commande set statut = 'terminee'
     where id = new.commande_id and statut not in ('terminee', 'annulee');
  end if;
  return null;
end;
$$;

create trigger livraison_apres after insert or update on public.livraison
  for each row execute function app.tg_livraison_apres();

-- =============================================================================
--  Vue « tableau des commandes » (paiement CALCULÉ, jamais stocké)
-- =============================================================================
create or replace view public.v_tableau_commandes
with (security_invoker = true) as
with totaux as (
  select l.commande_id,
         round(sum(l.quantite * l.prix_unitaire), 2) as total_ttc
  from public.ligne l
  group by l.commande_id
),
regles as (
  select p.commande_id, sum(p.montant) as total_paye
  from public.paiement p
  group by p.commande_id
)
select
  c.id,
  c.organisation_id,
  c.numero,
  c.date_souhaitee,
  c.creneau,
  c.canal,
  c.mode_remise,
  c.statut                                   as statut_commande,
  lv.statut                                  as statut_livraison,
  lv.livree_at,
  lv.receptionnaire,
  coalesce(t.total_ttc, 0)                   as total_ttc,
  coalesce(r.total_paye, 0)                  as total_paye,
  case
    when coalesce(t.total_ttc, 0) = 0                    then 'a_encaisser'
    when coalesce(r.total_paye, 0) >= t.total_ttc        then 'paye'
    when coalesce(r.total_paye, 0) > 0                   then 'partiel'
    else 'a_encaisser'
  end                                        as statut_paiement,
  cl.id                                      as client_id,
  trim(coalesce(cl.prenom || ' ', '') || cl.nom) as client_nom,
  cl.telephone                               as client_telephone,
  lv.adresse_snapshot ->> 'destinataire_nom' as destinataire,
  lv.adresse_snapshot ->> 'localite'         as localite,
  u.nom                                      as livreur
from public.commande c
join public.client cl        on cl.id = c.client_id
left join public.livraison lv on lv.commande_id = c.id
left join public.utilisateur u on u.id = lv.livreur_id
left join totaux t            on t.commande_id = c.id
left join regles r            on r.commande_id = c.id
where c.deleted_at is null;

-- Occasions à relancer dans les N prochains jours (gère le passage d'année)
create or replace view public.v_occasions_a_relancer
with (security_invoker = true) as
select o.*,
       trim(coalesce(cl.prenom || ' ', '') || cl.nom) as client_nom,
       cl.telephone as client_telephone,
       prochaine.date_occasion
from public.occasion o
join public.client cl on cl.id = o.client_id and cl.deleted_at is null
cross join lateral (
  select min(d)::date as date_occasion
  from (values
    (make_date(extract(year from current_date)::int,
               o.mois, least(o.jour, extract(day from (make_date(extract(year from current_date)::int, o.mois, 1) + interval '1 month - 1 day'))::int))),
    (make_date(extract(year from current_date)::int + 1,
               o.mois, least(o.jour, extract(day from (make_date(extract(year from current_date)::int + 1, o.mois, 1) + interval '1 month - 1 day'))::int)))
  ) v(d)
  where d >= current_date
) prochaine
where o.actif
  and prochaine.date_occasion - current_date <= o.rappel_jours_avant;

-- =============================================================================
--  nLPD : anonymisation d'un client (les commandes restent pour la compta)
-- =============================================================================
create or replace function app.anonymiser_client(p_client uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_org uuid;
begin
  select organisation_id into v_org from public.client where id = p_client;
  if v_org is null or not app.est_gerant(v_org) then
    raise exception 'Client introuvable ou droits insuffisants';
  end if;

  update public.client
     set nom = 'Client anonymisé', prenom = null, raison_sociale = null,
         telephone = null, email = null, notes = null,
         consentement_sms = false, anonymise_at = now(), deleted_at = now()
   where id = p_client;

  update public.adresse
     set destinataire_nom = 'Anonymisé', destinataire_tel = null,
         rue = '—', instructions = null, deleted_at = now()
   where client_id = p_client;

  update public.livraison lv
     set adresse_snapshot = jsonb_build_object(
           'destinataire_nom', 'Anonymisé', 'rue', '—',
           'npa', lv.adresse_snapshot ->> 'npa', 'localite', lv.adresse_snapshot ->> 'localite'),
         receptionnaire = null, photo_url = null
   where lv.commande_id in (select id from public.commande where client_id = p_client);

  update public.commande
     set message_carte = null
   where client_id = p_client;

  delete from public.occasion where client_id = p_client;
end;
$$;

-- =============================================================================
--  Row Level Security
--  MVP : toute l'équipe d'une boutique voit et modifie les données de SA
--  boutique ; suppressions et gestion de l'équipe réservées à la gérance.
-- =============================================================================
do $$
declare t text;
begin
  foreach t in array array['client','adresse','produit','commande','ligne',
                           'livraison','paiement','occasion']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated
                    using (organisation_id in (select app.mes_organisations()))', t || '_lecture', t);
    execute format('create policy %I on public.%I for insert to authenticated
                    with check (organisation_id in (select app.mes_organisations()))', t || '_creation', t);
    execute format('create policy %I on public.%I for update to authenticated
                    using (organisation_id in (select app.mes_organisations()))
                    with check (organisation_id in (select app.mes_organisations()))', t || '_modification', t);
    execute format('create policy %I on public.%I for delete to authenticated
                    using (app.est_gerant(organisation_id))', t || '_suppression', t);
  end loop;
end $$;

-- Organisation : lecture par l'équipe, modification par la gérance
alter table public.organisation enable row level security;
create policy organisation_lecture on public.organisation for select to authenticated
  using (id in (select app.mes_organisations()));
create policy organisation_modification on public.organisation for update to authenticated
  using (app.est_gerant(id)) with check (app.est_gerant(id));

-- Équipe : lecture par tous, gestion par la gérance
alter table public.utilisateur enable row level security;
create policy utilisateur_lecture on public.utilisateur for select to authenticated
  using (organisation_id in (select app.mes_organisations()));
create policy utilisateur_gestion on public.utilisateur for all to authenticated
  using (app.est_gerant(organisation_id)) with check (app.est_gerant(organisation_id));

-- Historique : lecture seule (écrit par triggers security definer)
alter table public.historique enable row level security;
create policy historique_lecture on public.historique for select to authenticated
  using (organisation_id in (select app.mes_organisations()));

-- Compteur : interne, aucun accès direct
alter table public.compteur_commande enable row level security;

-- Droits de base (Supabase les accorde déjà ; explicites pour la portabilité)
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke all on public.compteur_commande from authenticated;
revoke insert, update, delete on public.historique from authenticated;

-- Le hash du PIN ne sort jamais vers le client : lecture colonne par colonne
revoke select on public.utilisateur from authenticated;
grant select (id, organisation_id, auth_user_id, nom, role, actif, created_at, updated_at)
  on public.utilisateur to authenticated;
grant usage on schema app to authenticated;
grant execute on function app.verifier_pin(uuid, text), app.definir_pin(uuid, text),
                         app.anonymiser_client(uuid) to authenticated;
