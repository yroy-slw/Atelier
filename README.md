# Atelier — base de données du MVP « tableau des commandes »

Socle de données pour un outil de gestion de commerce artisanal : commandes, clients, destinataires, livraisons, paiements et traçabilité.
Premier cas d'usage : un magasin de fleurs à Lausanne (6 personnes).

- **Cible** : PostgreSQL 15+ / Supabase (Postgres 17 en local)
- **Base locale** : stack Supabase dans Docker, `postgresql://postgres:postgres@127.0.0.1:54322/postgres`
- **Promesse du MVP** : n'importe qui dans l'équipe sait en 5 secondes où en est n'importe quelle commande.

---

## Sommaire

1. [Fichiers](#fichiers)
2. [Installation sur Mac](#installation-sur-mac)
3. [Lancer la base en local](#lancer-la-base-en-local)
4. [Tests (pgTAP)](#tests-pgtap)
5. [Traçabilité : l'historique des statuts](#traçabilité--lhistorique-des-statuts)
6. [Requêtes utiles](#requêtes-utiles)
7. [Modèle de données](#modèle-de-données)
8. [Sécurité et multi-boutique](#sécurité-et-multi-boutique)
9. [Déployer sur Supabase](#déployer-sur-supabase)
10. [Limites connues](#limites-connues)

---

## Fichiers

```
atelier/
├── CLAUDE.md                              # contexte et conventions pour Claude Code
├── package.json                           # raccourcis npm vers la CLI Supabase
├── docs/                                  # décisions produit, flows, specs
└── supabase/
    ├── config.toml                        # configuration de la stack locale
    ├── migrations/
    │   └── 20261011000000_schema_initial.sql
    ├── seed.sql                           # données de démo (dev uniquement)
    └── tests/
        └── database/                      # tests pgTAP
            ├── 01_cycle_commande.test.sql
            ├── 02_securite.test.sql
            └── 03_clients.test.sql
```

| Fichier | Rôle | Local | Production |
|---|---|:---:|:---:|
| `supabase/migrations/*.sql` | Le schéma : tables, enums, triggers, vues, RLS. **1 fichier = 1 changement**, jamais modifié une fois appliqué | ✅ | ✅ |
| `supabase/seed.sql` | Boutique fictive, 4 utilisateurs, 2 clients, 1 occasion | ✅ | ❌ |
| `supabase/tests/database/*.test.sql` | Tests pgTAP (48 assertions) | ✅ | ❌ |

> Une nouvelle évolution du schéma = une nouvelle migration : `supabase migration new <nom>`.

---

## Installation sur Mac

Il faut **Docker Desktop** (lancé) et la **CLI Supabase**.

```bash
# Homebrew (si absent)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# CLI Supabase
brew install supabase/tap/supabase
supabase --version

# Docker Desktop : https://www.docker.com/products/docker-desktop/ — puis le lancer
open -a Docker
```

`psql` (client seul) est pratique pour la console, mais pas obligatoire : `brew install libpq`.

---

## Lancer la base en local

Depuis la racine du dépôt :

| Commande | Équivalent CLI | Effet |
|---|---|---|
| `npm run db:start` | `supabase start` | Démarre la stack locale (le premier lancement télécharge les images) |
| `npm run db:reset` | `supabase db reset` | Recrée la base : rejoue les migrations puis le seed |
| `npm run db:test` | `supabase db reset && supabase test db` | Reset complet puis tests pgTAP |
| `npm run db:stop` | `supabase stop` | Arrête la stack |

Aucune dépendance npm : les scripts ne font qu'appeler la CLI Supabase.

- **Studio** (interface web) : http://127.0.0.1:54323
- **Console SQL** :

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
```

Dans la console : `\dt` liste les tables, `\d commande` décrit une table, `\dv` liste les vues, `\q` quitte.

### Alias pratique (pour lancer depuis n'importe quel dossier)

À ajouter dans `~/.zshrc` (adapter le chemin du dossier) :

```bash
alias atelier-reset='npm --prefix ~/chemin/vers/atelier run db:reset'
alias atelier-test='npm --prefix ~/chemin/vers/atelier run db:test'
```

Puis `source ~/.zshrc`, et ensuite simplement `atelier-reset` ou `atelier-test`.

---

## Tests (pgTAP)

```bash
npm run db:test
```

Résultat attendu : `All tests successful. Files=3, Tests=48` puis `Result: PASS`.

| Fichier | Ce qui est vérifié |
|---|---|
| `01_cycle_commande` | Saisie sur la tablette au nom de Léa (PIN), numéro `AAAA-NNNN`, totaux et paiement calculé, livraison (snapshot figé, `planifiee` auto, `livree_at`, commande `terminee`), historique complet avec auteurs, garde-fous (pas de livraison sur un retrait, une seule livraison, motif d'échec, snapshot complet) |
| `02_securite` | Isolation entre boutiques (RLS + clés composites), hash du PIN illisible, vérification et définition du PIN, en-tête `x-utilisateur` d'une autre boutique ignoré, historique en lecture seule, suppressions et équipe réservées à la gérance |
| `03_clients` | Occasions à relancer (dans et hors fenêtre), anonymisation nLPD (refusée à la vente, données effacées, montants conservés) |

Chaque fichier tourne dans une transaction annulée à la fin (`rollback`) : les tests ne modifient pas la base. Ils s'appuient sur les identifiants de `supabase/seed.sql`.

Pour écrire un nouveau test : copier un fichier existant, ajuster `select plan(n)` au nombre d'assertions. Les principales : `is`, `ok`, `lives_ok`, `throws_ok` (avec le code SQLSTATE : `42501` droits/RLS, `23503` clé étrangère, `23514` contrainte check, `P0001` exception métier), `is_empty`, `results_eq`.

---

## Traçabilité : l'historique des statuts

C'est la réponse directe à la douleur principale (« impossible de savoir où en est une livraison »).

### Principe

Chaque changement de statut est enregistré **automatiquement** dans la table `historique`, par des triggers. L'application n'a rien à écrire elle-même, et l'équipe ne peut ni modifier ni supprimer l'historique (lecture seule via la RLS).

| Colonne | Contenu |
|---|---|
| `objet` | `commande` ou `livraison` |
| `de_statut` | statut précédent (vide à la création) |
| `vers_statut` | nouveau statut |
| `utilisateur_id` | qui a fait l'action |
| `at` | horodatage précis (`clock_timestamp()`, fiable même dans une transaction) |

### Ce qui est tracé

**Commande** (`commande.statut`) :

```
recue → en_preparation → prete → terminee
                                  annulee
```

**Livraison** (`livraison.statut`) :

```
a_planifier → planifiee → en_route → livree
                                     echec  (motif obligatoire)
```

Automatismes :
- assigner un livreur **et** une date de tournée → passage auto en `planifiee`
- passage en `livree` → `livree_at` horodaté automatiquement
- livraison `livree` → la commande passe en `terminee`

Toutes ces transitions automatiques sont aussi tracées.

### Qui a fait l'action ?

La fonction `app.utilisateur_courant()` détermine l'auteur :

1. **Tablette partagée** : l'application envoie l'en-tête HTTP `x-utilisateur` (id de la personne choisie après saisie de son PIN). Il n'est accepté que si cette personne appartient à la même boutique que le compte connecté.
2. **Sinon** : l'utilisateur lié au compte Supabase connecté.

Le PIN se vérifie avec `app.verifier_pin(utilisateur_id, pin)` et se définit (gérante uniquement) avec `app.definir_pin(utilisateur_id, pin)`. Il est stocké en bcrypt et n'est jamais lisible côté client.

### Simuler un utilisateur en local

Dans la console SQL (`psql` ou Studio), pour reproduire ce que fera l'application (c'est aussi ce que font les tests) :

```sql
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';          -- compte « Tablette comptoir »
set local request.headers = '{"x-utilisateur":"00000000-0000-0000-0000-0000000000a3"}';  -- Léa, après son PIN

-- … actions …

commit;
```

Comptes de démo :

| Compte (`auth_user_id`) | Utilisateur | Rôle | PIN |
|---|---|---|---|
| `1111…1111` | Gérante | gerant | 1234 |
| `2222…2222` | Tablette comptoir | vente | — |
| — | Léa (atelier) | atelier | 4321 |
| — | Marco (livraison) | livreur | 5678 |

---

## Requêtes utiles

### « Où en est la commande 2026-0001 ? »

```sql
select h.at::timestamp(0) as quand, h.objet, h.de_statut, h.vers_statut, u.nom as par
from historique h
join commande c on c.id = h.commande_id
left join utilisateur u on u.id = h.utilisateur_id
where c.numero = '2026-0001'
order by h.at;
```

### Retrouver une commande par le téléphone du client

```sql
select numero, date_souhaitee, statut_commande, statut_livraison, statut_paiement, destinataire
from v_tableau_commandes
where client_telephone = '+41791110001'
order by date_souhaitee desc;
```

### Le tableau du jour (vue atelier)

```sql
select numero, creneau, client_nom, mode_remise, statut_commande, statut_livraison, livreur
from v_tableau_commandes
where date_souhaitee = current_date
order by creneau nulls last, numero;
```

### Livraisons en cours ou en échec

```sql
select numero, destinataire, localite, statut_livraison, livreur
from v_tableau_commandes
where statut_livraison in ('en_route', 'echec');
```

### Activité d'une personne aujourd'hui

```sql
select h.at::time(0) as heure, c.numero, h.objet, h.vers_statut
from historique h
join commande c on c.id = h.commande_id
join utilisateur u on u.id = h.utilisateur_id
where u.nom = 'Marco (livraison)' and h.at::date = current_date
order by h.at;
```

### Commandes en retard (date passée, pas terminées)

```sql
select numero, date_souhaitee, client_nom, statut_commande
from v_tableau_commandes
where date_souhaitee < current_date
  and statut_commande not in ('terminee', 'annulee');
```

### Paiements à encaisser

```sql
select numero, client_nom, total_ttc, total_paye, total_ttc - total_paye as reste
from v_tableau_commandes
where statut_paiement <> 'paye' and statut_commande <> 'annulee';
```

### Occasions à relancer (fidélisation)

```sql
select client_nom, client_telephone, libelle, date_occasion
from v_occasions_a_relancer
order by date_occasion;
```

---

## Modèle de données

```
organisation ─┬─ utilisateur
              ├─ client ─┬─ adresse (carnet de destinataires)
              │          ├─ occasion (dates récurrentes)
              │          └─ commande ─┬─ ligne ── produit (optionnel)
              │                       ├─ livraison (0..1, adresse en snapshot)
              │                       ├─ paiement (0..n)
              │                       └─ historique (auto, lecture seule)
              └─ compteur_commande (interne)
```

### Principes

- **Le client n'est pas le destinataire** : `adresse` est un carnet rattaché au client (« Maman », « Bureau »).
- **Snapshots** : `ligne.prix_unitaire` / `taux_tva` et `livraison.adresse_snapshot` figent ce qui a servi. Une commande passée ne change jamais.
- **Produit optionnel** : `ligne.description` est du texte libre, le sur-mesure reste possible.
- **Un seul point de vérité par axe** :
  - préparation → `commande.statut`
  - logistique → `livraison.statut`
  - paiement → **calculé** dans `v_tableau_commandes` (`a_encaisser` · `partiel` · `paye`), jamais stocké
- **Numéro lisible** généré par boutique et par année : `2026-0001`.
- **Soft delete** (`deleted_at`) sur clients, adresses et commandes.
- **TVA par défaut** : 2,6 % (taux réduit). À valider avec la fiduciaire.

### Vues

| Vue | Usage |
|---|---|
| `v_tableau_commandes` | Le tableau de suivi : statuts, totaux, paiement calculé, destinataire, livreur |
| `v_occasions_a_relancer` | Occasions dans la fenêtre de rappel (gère le passage d'année et le 29 février) |

---

## Sécurité et multi-boutique

- **`organisation_id` partout** + Row Level Security : chaque compte ne voit que sa boutique.
- **Clés étrangères composites** `(organisation_id, id)` : impossible de lier une commande au client d'une autre boutique, même en cas de bug applicatif.
- **Droits** :
  - toute l'équipe lit, crée et modifie les données de sa boutique ;
  - suppressions, gestion de l'équipe et anonymisation : **gérante uniquement** ;
  - `historique` : lecture seule ;
  - `utilisateur.pin_hash` : jamais lisible côté client.
- **nLPD** : `app.anonymiser_client(client_id)` efface les données personnelles mais conserve commandes et montants (obligation de conservation comptable de 10 ans).

---

## Déployer sur Supabase

1. Créer un projet (région Europe, de préférence Zurich pour la nLPD).
2. Lier le dépôt au projet, puis pousser les migrations :

```bash
supabase login
supabase link --project-ref <ref-du-projet>
supabase db push          # applique les migrations pas encore appliquées
```

`supabase db push` n'envoie **pas** le seed : les données de démo restent locales.

---

## Limites connues

- **PIN = traçabilité, pas sécurité** : un employé pourrait techniquement envoyer l'identifiant d'un collègue de la même boutique dans l'en-tête `x-utilisateur`. Acceptable pour une petite équipe de confiance ; sinon, passer par une Edge Function qui revérifie le PIN à chaque action.
- **Arrondi à 5 centimes** non géré : les totaux sont au centime.
- **Pas encore inclus** : événements, recettes (nomenclatures), stock périssable par lots, fournisseurs. Le modèle est prévu pour les greffer sans casser l'existant (`commande.canal = 'evenement'` + table dédiée, etc.).
