-- =============================================================================
--  Clients : occasions à relancer et anonymisation nLPD
--  S'appuie sur supabase/seed.sql. Tout est annulé en fin de fichier.
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

-- Une commande livrée et partiellement payée pour Hélène Dupuis (hors RLS)
insert into commande (id, organisation_id, client_id, mode_remise, date_souhaitee, message_carte)
values ('00000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-00000000f100',
        '00000000-0000-0000-0000-0000000000c1', 'livraison', current_date, 'Bon anniversaire Maman !');
insert into ligne (organisation_id, commande_id, description, prix_unitaire)
values ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-00000000c001', 'Bouquet', 100);
insert into paiement (organisation_id, commande_id, montant, mode)
values ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-00000000c001', 40, 'twint');
insert into livraison (organisation_id, commande_id, adresse_id, adresse_snapshot)
values ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-00000000c001',
        '00000000-0000-0000-0000-0000000000d1',
        '{"destinataire_nom":"Mme Jeanne Dupuis","rue":"Avenue du Lac 12","npa":"1009","localite":"Pully"}');

-- Une occasion lointaine, hors de la fenêtre de rappel
insert into occasion (organisation_id, client_id, libelle, jour, mois, rappel_jours_avant)
values ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-0000000000c1', 'Fête lointaine',
        extract(day from current_date + 30)::int, extract(month from current_date + 30)::int, 5);

-- -----------------------------------------------------------------------------
--  Occasions à relancer (compte tablette)
-- -----------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

select is(
  (select date_occasion - current_date from v_occasions_a_relancer where libelle = 'Anniversaire de sa mère'),
  3, 'l''occasion dans 3 jours est à relancer'
);
select is_empty(
  $$ select 1 from v_occasions_a_relancer where libelle = 'Fête lointaine' $$,
  'une occasion hors fenêtre n''est pas listée'
);

-- -----------------------------------------------------------------------------
--  Anonymisation nLPD
-- -----------------------------------------------------------------------------
select throws_ok(
  $$ select app.anonymiser_client('00000000-0000-0000-0000-0000000000c1') $$,
  'P0001', 'Client introuvable ou droits insuffisants', 'la vente ne peut pas anonymiser'
);

set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select lives_ok(
  $$ select app.anonymiser_client('00000000-0000-0000-0000-0000000000c1') $$,
  'la gérante anonymise le client'
);

select is((select nom from client where id = '00000000-0000-0000-0000-0000000000c1'),
  'Client anonymisé', 'nom effacé');
select is((select telephone from client where id = '00000000-0000-0000-0000-0000000000c1'),
  null, 'téléphone effacé');
select isnt((select deleted_at from client where id = '00000000-0000-0000-0000-0000000000c1'),
  null, 'client marqué supprimé (soft delete)');
select is_empty($$ select 1 from occasion where client_id = '00000000-0000-0000-0000-0000000000c1' $$,
  'occasions supprimées');
select is((select destinataire from v_tableau_commandes where id = '00000000-0000-0000-0000-00000000c001'),
  'Anonymisé', 'destinataire de la livraison effacé');
select is((select localite from v_tableau_commandes where id = '00000000-0000-0000-0000-00000000c001'),
  'Pully', 'localité conservée');
select results_eq(
  $$ select total_ttc, total_paye from v_tableau_commandes where id = '00000000-0000-0000-0000-00000000c001' $$,
  $$ values (100.00::numeric, 40.00::numeric) $$,
  'montants conservés (obligation comptable)'
);

select * from finish();
rollback;
