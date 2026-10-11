-- =============================================================================
--  Données de démonstration (boutique fictive) — à NE PAS lancer en production
--  Chargé automatiquement par « supabase db reset ».
--  Les tests pgTAP (supabase/tests/database) s'appuient sur ces identifiants.
-- =============================================================================
insert into public.organisation (id, nom, adresse, telephone, email)
values ('00000000-0000-0000-0000-00000000f100', 'Atelier Floral Démo',
        'Rue de Bourg 1, 1003 Lausanne', '+41210000000', 'demo@example.ch');

insert into public.utilisateur (id, organisation_id, auth_user_id, nom, role, pin_hash) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000f100',
   '11111111-1111-1111-1111-111111111111', 'Gérante',  'gerant',  extensions.crypt('1234', extensions.gen_salt('bf'))),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000f100',
   '22222222-2222-2222-2222-222222222222', 'Tablette comptoir', 'vente', null),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-00000000f100',
   null, 'Léa (atelier)', 'atelier', extensions.crypt('4321', extensions.gen_salt('bf'))),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-00000000f100',
   null, 'Marco (livraison)', 'livreur', extensions.crypt('5678', extensions.gen_salt('bf')));

insert into public.client (id, organisation_id, type, nom, prenom, telephone, notes, consentement_sms) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000f100', 'particulier',
   'Dupuis', 'Hélène', '+41791110001', 'Adore les pivoines, pas de lys', true),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-00000000f100', 'entreprise',
   'Accueil', null, '+41215550002', 'Hall d''entrée, renouvellement chaque lundi', false);

update public.client set raison_sociale = 'Hôtel Démo SA' where id = '00000000-0000-0000-0000-0000000000c2';

insert into public.adresse (id, organisation_id, client_id, libelle, destinataire_nom, destinataire_tel, rue, npa, localite, instructions) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-0000000000c1',
   'Maman', 'Mme Jeanne Dupuis', '+41791110009', 'Avenue du Lac 12', '1009', 'Pully', 'Code 4512, 3e étage'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-0000000000c2',
   'Réception', 'Réception Hôtel Démo', null, 'Quai d''Ouchy 3', '1006', 'Lausanne', 'Livrer avant 9h, entrée de service');

insert into public.produit (organisation_id, nom, categorie, prix_base) values
  ('00000000-0000-0000-0000-00000000f100', 'Bouquet de saison S', 'bouquet', 45),
  ('00000000-0000-0000-0000-00000000f100', 'Bouquet de saison M', 'bouquet', 75),
  ('00000000-0000-0000-0000-00000000f100', 'Composition hall (hebdo)', 'entreprise', 180);

insert into public.occasion (organisation_id, client_id, libelle, jour, mois, adresse_id, rappel_jours_avant)
values ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-0000000000c1',
        'Anniversaire de sa mère', extract(day from current_date + 3)::int, extract(month from current_date + 3)::int,
        '00000000-0000-0000-0000-0000000000d1', 5);

