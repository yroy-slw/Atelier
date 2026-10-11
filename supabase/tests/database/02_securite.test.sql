-- =============================================================================
--  Sécurité : isolation entre boutiques (RLS), PIN, droits de la gérance
--  S'appuie sur supabase/seed.sql. Tout est annulé en fin de fichier.
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

-- Seconde boutique, créée hors RLS, pour tester l'isolation
insert into organisation (id, nom) values ('00000000-0000-0000-0000-00000000f200', 'Concurrent');
insert into utilisateur (id, organisation_id, auth_user_id, nom, role) values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000f200',
   '33333333-3333-3333-3333-333333333333', 'Autre', 'gerant');
insert into client (id, organisation_id, nom, telephone) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000f200', 'Secret', '+41790000000');

-- -----------------------------------------------------------------------------
--  Compte « Tablette comptoir » (rôle vente)
-- -----------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

-- Isolation (RLS)
select is((select count(*)::int from client), 2, 'la tablette voit les 2 clients de sa boutique');
select is_empty($$ select 1 from client where nom = 'Secret' $$, 'aucun client de l''autre boutique n''est visible');
select is_empty($$ select 1 from utilisateur where nom = 'Autre' $$, 'aucun membre de l''autre boutique n''est visible');

select throws_ok($$
  insert into commande (organisation_id, client_id, date_souhaitee)
  values ('00000000-0000-0000-0000-00000000f100', '00000000-0000-0000-0000-0000000000e1', current_date)
$$, '23503', null, 'impossible de lier une commande au client d''une autre boutique');

select throws_ok($$
  insert into client (organisation_id, nom) values ('00000000-0000-0000-0000-00000000f200', 'Intrus')
$$, '42501', null, 'impossible d''écrire dans une autre boutique');

-- PIN
select throws_ok($$ select pin_hash from utilisateur $$, '42501', null, 'le hash du PIN est illisible');
select ok(app.verifier_pin('00000000-0000-0000-0000-0000000000a3', '4321'), 'bon PIN accepté');
select ok(not app.verifier_pin('00000000-0000-0000-0000-0000000000a3', '0000'), 'mauvais PIN refusé');
select throws_ok($$ select app.definir_pin('00000000-0000-0000-0000-0000000000a3', '9999') $$,
  'P0001', 'Utilisateur introuvable ou droits insuffisants', 'seule la gérance définit un PIN');

-- En-tête x-utilisateur d'une autre boutique : ignoré, on retombe sur le compte connecté
set local request.headers = '{"x-utilisateur":"00000000-0000-0000-0000-0000000000b1"}';
select is(app.utilisateur_courant(), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'x-utilisateur d''une autre boutique ignoré');
reset request.headers;

-- Historique en lecture seule
select throws_ok($$
  insert into historique (organisation_id, commande_id, objet, vers_statut)
  values ('00000000-0000-0000-0000-00000000f100', gen_random_uuid(), 'commande', 'recue')
$$, '42501', null, 'l''historique ne s''écrit pas à la main');

-- Suppressions et équipe : réservées à la gérance
delete from produit where nom = 'Bouquet de saison S';
select isnt_empty($$ select 1 from produit where nom = 'Bouquet de saison S' $$, 'la vente ne peut pas supprimer');

select throws_ok($$
  insert into utilisateur (organisation_id, nom, role) values ('00000000-0000-0000-0000-00000000f100', 'Nouveau', 'vente')
$$, '42501', null, 'la vente ne gère pas l''équipe');

-- -----------------------------------------------------------------------------
--  Compte de la gérante
-- -----------------------------------------------------------------------------
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

delete from produit where nom = 'Bouquet de saison S';
select is_empty($$ select 1 from produit where nom = 'Bouquet de saison S' $$, 'la gérante peut supprimer');

select lives_ok($$ select app.definir_pin('00000000-0000-0000-0000-0000000000a3', '9999') $$,
  'la gérante définit un PIN');

select * from finish();
rollback;
