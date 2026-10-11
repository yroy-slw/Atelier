-- =============================================================================
--  Cycle de vie d'une commande : saisie, totaux, livraison, historique
--  S'appuie sur supabase/seed.sql. Tout est annulé en fin de fichier.
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

-- -----------------------------------------------------------------------------
--  Saisie au comptoir : compte « Tablette comptoir », Léa choisie après son PIN
-- -----------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
set local request.headers = '{"x-utilisateur":"00000000-0000-0000-0000-0000000000a3"}';

select lives_ok($$
  insert into commande (id, organisation_id, client_id, canal, mode_remise, date_souhaitee, creneau, message_carte)
  values ('00000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-00000000f100',
          '00000000-0000-0000-0000-0000000000c1', 'telephone', 'livraison',
          current_date + 1, 'matin', 'Bon anniversaire Maman !')
$$, 'la tablette saisit une commande téléphone');

select matches(
  (select numero from commande where id = '00000000-0000-0000-0000-00000000c001'),
  '^' || extract(year from now())::int || '-[0-9]{4}$',
  'numéro lisible généré : AAAA-NNNN'
);
select is(
  (select statut::text from commande where id = '00000000-0000-0000-0000-00000000c001'),
  'recue', 'une nouvelle commande est « recue »'
);
select is(
  (select pris_par from commande where id = '00000000-0000-0000-0000-00000000c001'),
  '00000000-0000-0000-0000-0000000000a3'::uuid,
  'pris_par = Léa (en-tête x-utilisateur), pas le compte tablette'
);

insert into ligne (organisation_id, commande_id, description, quantite, prix_unitaire) values
  ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-00000000c001', 'Bouquet champêtre, tons pastel', 1, 85),
  ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-00000000c001', 'Frais de livraison Pully', 1, 15);
insert into paiement (organisation_id, commande_id, montant, mode) values
  ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-00000000c001', 40, 'twint');

select is(
  (select total_ttc from v_tableau_commandes where id = '00000000-0000-0000-0000-00000000c001'),
  100.00::numeric, 'total TTC = somme des lignes'
);
select is(
  (select total_paye from v_tableau_commandes where id = '00000000-0000-0000-0000-00000000c001'),
  40.00::numeric, 'total payé = somme des paiements'
);
select is(
  (select statut_paiement from v_tableau_commandes where id = '00000000-0000-0000-0000-00000000c001'),
  'partiel', 'paiement calculé : partiel'
);

-- -----------------------------------------------------------------------------
--  Livraison : Marco prend la main sur la tablette
-- -----------------------------------------------------------------------------
set local request.headers = '{"x-utilisateur":"00000000-0000-0000-0000-0000000000a4"}';

select lives_ok($$
  insert into livraison (organisation_id, commande_id, adresse_id, adresse_snapshot)
  select '00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-00000000c001', a.id,
         jsonb_build_object('destinataire_nom', a.destinataire_nom, 'rue', a.rue, 'npa', a.npa,
                            'localite', a.localite, 'instructions', a.instructions)
  from adresse a where a.id = '00000000-0000-0000-0000-0000000000d1'
$$, 'livraison créée avec un snapshot de l''adresse « Maman »');

select is(
  (select statut::text from livraison where commande_id = '00000000-0000-0000-0000-00000000c001'),
  'a_planifier', 'une nouvelle livraison est « a_planifier »'
);

update livraison set livreur_id = '00000000-0000-0000-0000-0000000000a4', date_tournee = current_date + 1
 where commande_id = '00000000-0000-0000-0000-00000000c001';
select is(
  (select statut::text from livraison where commande_id = '00000000-0000-0000-0000-00000000c001'),
  'planifiee', 'livreur + date de tournée → « planifiee » automatiquement'
);

-- Le carnet d'adresses change : le snapshot de la livraison ne bouge pas
update adresse set rue = 'Chemin Nouveau 1' where id = '00000000-0000-0000-0000-0000000000d1';
select is(
  (select adresse_snapshot ->> 'rue' from livraison where commande_id = '00000000-0000-0000-0000-00000000c001'),
  'Avenue du Lac 12', 'le snapshot d''adresse est figé'
);

update livraison set statut = 'en_route' where commande_id = '00000000-0000-0000-0000-00000000c001';
update livraison set statut = 'livree', receptionnaire = 'la concierge'
 where commande_id = '00000000-0000-0000-0000-00000000c001';

select isnt(
  (select livree_at from livraison where commande_id = '00000000-0000-0000-0000-00000000c001'),
  null, 'livree_at horodaté automatiquement'
);
select is(
  (select statut::text from commande where id = '00000000-0000-0000-0000-00000000c001'),
  'terminee', 'livraison « livree » → commande « terminee »'
);
select is(
  (select livreur from v_tableau_commandes where id = '00000000-0000-0000-0000-00000000c001'),
  'Marco (livraison)', 'le tableau affiche le livreur'
);

-- -----------------------------------------------------------------------------
--  Historique : « où en est la commande ? »
-- -----------------------------------------------------------------------------
select results_eq(
  $$ select h.objet, h.de_statut, h.vers_statut, u.nom
       from historique h left join utilisateur u on u.id = h.utilisateur_id
      where h.commande_id = '00000000-0000-0000-0000-00000000c001'
      order by h.at, h.id $$,
  $$ values ('commande',  null,          'recue',       'Léa (atelier)'),
            ('livraison', null,          'a_planifier', 'Marco (livraison)'),
            ('livraison', 'a_planifier', 'planifiee',   'Marco (livraison)'),
            ('livraison', 'planifiee',   'en_route',    'Marco (livraison)'),
            ('livraison', 'en_route',    'livree',      'Marco (livraison)'),
            ('commande',  'recue',       'terminee',    'Marco (livraison)') $$,
  'chaque changement de statut est tracé, avec son auteur'
);

-- -----------------------------------------------------------------------------
--  Garde-fous de la livraison
-- -----------------------------------------------------------------------------
select lives_ok($$
  insert into commande (id, organisation_id, client_id, mode_remise, date_souhaitee)
  values ('00000000-0000-0000-0000-00000000c002', '00000000-0000-0000-0000-00000000f100',
          '00000000-0000-0000-0000-0000000000c2', 'retrait', current_date)
$$, 'commande en retrait créée');

select throws_ok($$
  insert into livraison (organisation_id, commande_id, adresse_snapshot)
  values ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-00000000c002',
          '{"destinataire_nom":"x","rue":"x","npa":"1000","localite":"x"}')
$$, 'P0001', null, 'pas de livraison sur une commande en retrait');

select lives_ok($$
  insert into commande (id, organisation_id, client_id, mode_remise, date_souhaitee)
  values ('00000000-0000-0000-0000-00000000c003', '00000000-0000-0000-0000-00000000f100',
          '00000000-0000-0000-0000-0000000000c2', 'livraison', current_date)
$$, 'commande en livraison créée');

select throws_ok($$
  insert into livraison (organisation_id, commande_id, adresse_snapshot)
  values ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-00000000c003',
          '{"destinataire_nom":"x"}')
$$, '23514', null, 'le snapshot d''adresse doit être complet');

select lives_ok($$
  insert into livraison (organisation_id, commande_id, adresse_snapshot)
  values ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-00000000c003',
          '{"destinataire_nom":"x","rue":"x","npa":"1000","localite":"x"}')
$$, 'livraison créée');

select throws_ok($$
  insert into livraison (organisation_id, commande_id, adresse_snapshot)
  values ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-00000000c003',
          '{"destinataire_nom":"x","rue":"x","npa":"1000","localite":"x"}')
$$, '23505', null, 'au plus une livraison par commande');

select throws_ok($$
  update livraison set statut = 'echec' where commande_id = '00000000-0000-0000-0000-00000000c003'
$$, '23514', null, 'un échec de livraison exige un motif');

select * from finish();
rollback;
