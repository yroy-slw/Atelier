\set ON_ERROR_STOP 1
\pset footer off
-- Seconde boutique pour tester l'isolation
insert into organisation (id, nom) values ('00000000-0000-0000-0000-00000000f200','Concurrent');
insert into utilisateur (id, organisation_id, auth_user_id, nom, role) values
 ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-00000000f200','33333333-3333-3333-3333-333333333333','Autre','gerant');
insert into client (id, organisation_id, nom, telephone) values
 ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-00000000f200','Secret','+41790000000');

\echo '== T1 : la tablette (vente) saisit une commande téléphone au nom de Léa (PIN)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
set local request.headers = '{"x-utilisateur":"00000000-0000-0000-0000-0000000000a3"}';
insert into commande (organisation_id, client_id, canal, mode_remise, date_souhaitee, creneau, message_carte)
values ('00000000-0000-0000-0000-00000000f100','00000000-0000-0000-0000-0000000000c1','telephone','livraison', current_date + 1, 'matin', 'Bon anniversaire Maman !')
returning numero, statut, (select nom from utilisateur where id = pris_par) as pris_par;
insert into ligne (organisation_id, commande_id, description, quantite, prix_unitaire)
select organisation_id, id, 'Bouquet champêtre, tons pastel', 1, 85 from commande where numero like '%-0001';
insert into ligne (organisation_id, commande_id, description, quantite, prix_unitaire)
select organisation_id, id, 'Frais de livraison Pully', 1, 15 from commande where numero like '%-0001';
insert into paiement (organisation_id, commande_id, montant, mode)
select organisation_id, id, 40, 'twint' from commande where numero like '%-0001';
select numero, total_ttc, total_paye, statut_paiement from v_tableau_commandes;
commit;

\echo '== T2 : livraison (snapshot), planification puis « livrée » → commande terminée'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
set local request.headers = '{"x-utilisateur":"00000000-0000-0000-0000-0000000000a4"}';
insert into livraison (organisation_id, commande_id, adresse_id, adresse_snapshot)
select c.organisation_id, c.id, a.id,
       jsonb_build_object('destinataire_nom',a.destinataire_nom,'rue',a.rue,'npa',a.npa,'localite',a.localite,'instructions',a.instructions)
from commande c, adresse a where c.numero like '%-0001' and a.libelle = 'Maman';
update livraison set livreur_id = '00000000-0000-0000-0000-0000000000a4', date_tournee = current_date + 1;
select statut from livraison;
update livraison set statut = 'en_route';
update livraison set statut = 'livree', receptionnaire = 'la concierge';
select numero, statut_commande, statut_livraison, livree_at is not null as horodatee, receptionnaire, livreur from v_tableau_commandes;
commit;

\echo '== T3 : historique — « où en est la commande ? »'
select h.objet, h.de_statut, h.vers_statut, u.nom as par from historique h left join utilisateur u on u.id = h.utilisateur_id order by h.at, h.id;

\echo '== T4 : commande en retrait → livraison refusée'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into commande (organisation_id, client_id, date_souhaitee) values ('00000000-0000-0000-0000-00000000f100','00000000-0000-0000-0000-0000000000c2', current_date) returning numero;
savepoint s;
\set ON_ERROR_STOP 0
insert into livraison (organisation_id, commande_id, adresse_snapshot)
select organisation_id, id, '{"destinataire_nom":"x","rue":"x","npa":"1000","localite":"x"}' from commande where numero like '%-0002';
\set ON_ERROR_STOP 1
rollback to s;
commit;

\echo '== T5 : isolation entre boutiques (RLS)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as clients_visibles, bool_or(nom = 'Secret') as voit_concurrent from client;
\set ON_ERROR_STOP 0
\echo '-- client d''une autre boutique dans ma commande (doit échouer) :'
insert into commande (organisation_id, client_id, date_souhaitee) values ('00000000-0000-0000-0000-00000000f100','00000000-0000-0000-0000-0000000000e1', current_date);
rollback;
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\echo '-- écrire dans l''autre boutique (doit échouer) :'
insert into client (organisation_id, nom) values ('00000000-0000-0000-0000-00000000f200','Intrus');
rollback;
\echo '== T6 : le hash du PIN est illisible'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select pin_hash from utilisateur;
rollback;
\set ON_ERROR_STOP 1
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select app.verifier_pin('00000000-0000-0000-0000-0000000000a3','4321') as bon_pin,
       app.verifier_pin('00000000-0000-0000-0000-0000000000a3','0000') as mauvais_pin;
\echo '== T7 : en-tête x-utilisateur d''une autre boutique ignoré'
set local request.headers = '{"x-utilisateur":"00000000-0000-0000-0000-0000000000b1"}';
select (select nom from utilisateur where id = app.utilisateur_courant()) as utilisateur_retenu;
rollback;

\echo '== T8 : suppression réservée à la gérance'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
with d as (delete from produit where nom like 'Bouquet de saison S' returning 1) select count(*) as supprimes_par_vente from d;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
with d as (delete from produit where nom like 'Bouquet de saison S' returning 1) select count(*) as supprimes_par_gerante from d;
rollback;

\echo '== T9 : occasions à relancer'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select client_nom, libelle, date_occasion - current_date as dans_jours from v_occasions_a_relancer;
rollback;

\echo '== T10 : anonymisation nLPD (vente refusée, gérante OK, compta intacte)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP 0
select app.anonymiser_client('00000000-0000-0000-0000-0000000000c1');
rollback;
\set ON_ERROR_STOP 1
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select app.anonymiser_client('00000000-0000-0000-0000-0000000000c1');
select nom, telephone, notes from client where id = '00000000-0000-0000-0000-0000000000c1';
select numero, total_ttc, total_paye, destinataire, localite from v_tableau_commandes where numero like '%-0001';
rollback;
