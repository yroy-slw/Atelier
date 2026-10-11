# Atelier — base de données du MVP « tableau des commandes »

Socle de données pour un outil de gestion de commerce artisanal : commandes, clients, destinataires, livraisons, paiements et traçabilité.
Premier cas d'usage : un magasin de fleurs à Lausanne (6 personnes).

- **Cible** : PostgreSQL 15+ / Supabase
- **Nom de la base en local** : `atelier`
- **Promesse du MVP** : n'importe qui dans l'équipe sait en 5 secondes où en est n'importe quelle commande.

---

## Sommaire

1. [Fichiers](#fichiers)
2. [Installation sur Mac](#installation-sur-mac)
3. [Créer et remplir la base](#créer-et-remplir-la-base)
4. [Repartir de zéro (drop)](#repartir-de-zéro-drop)
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
├── package.json                      # scripts npm run db:reset / db:test
├── docs/
└── supabase/
    ├── migrations/
    │   └── 001_schema.sql
    ├── 002_seed_demo.sql
    └── tests/
        ├── 000_stub_auth_local.sql
        └── 003_tests_scenarios.sql
```

| Fichier | Rôle | Local | Supabase |
|---|---|:---:|:---:|
| `supabase/tests/000_stub_auth_local.sql` | Simule `auth.uid()` et les rôles `anon` / `authenticated` de Supabase | ✅ | ❌ jamais |
| `supabase/migrations/001_schema.sql` | **La migration** : tables, enums, triggers, vues, RLS | ✅ | ✅ |
| `supabase/002_seed_demo.sql` | Boutique fictive, 4 utilisateurs, 2 clients, 1 occasion | ✅ | dev uniquement |
| `supabase/tests/003_tests_scenarios.sql` | 10 scénarios métier rejouables | ✅ | ❌ |

> Les fichiers sont numérotés : on les lance **toujours dans l'ordre** (000 → 001 → 002, puis 003).

---

## Installation sur Mac

`psql` n'est que le client. Il faut aussi un serveur Postgres.

```bash
# Homebrew (si absent)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Postgres 16
brew install postgresql@16
brew services start postgresql@16

# Rendre psql, createdb, dropdb accessibles
echo 'export PATH="$(brew --prefix postgresql@16)/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Vérifier
psql --version
```

Commandes utiles du serveur :

```bash
brew services list                    # état
brew services stop postgresql@16      # arrêter
brew services restart postgresql@16   # redémarrer
```

---

## Créer et remplir la base

Depuis la racine du dépôt :

```bash
createdb atelier
psql -d atelier -v ON_ERROR_STOP=1 \
  -f supabase/tests/000_stub_auth_local.sql \
  -f supabase/migrations/001_schema.sql \
  -f supabase/002_seed_demo.sql
```

Lancer les scénarios de test :

```bash
psql -d atelier -f supabase/tests/003_tests_scenarios.sql
```

> ⚠️ Toujours préciser `-d atelier`. Sans cela, `psql` cherche une base au nom de ton utilisateur macOS et échoue.

Les **5 erreurs affichées par les tests sont attendues** : ce sont les garde-fous qui refusent ce qu'ils doivent refuser (livraison sur un retrait, accès à une autre boutique, lecture du PIN, etc.).

Ouvrir une console interactive :

```bash
psql -d atelier
```

Dans la console : `\dt` liste les tables, `\d commande` décrit une table, `\dv` liste les vues, `\q` quitte.

---

## Repartir de zéro (drop)

Le script de test **écrit des données** (seconde boutique, commandes). Pour le relancer proprement, il faut recréer la base.

### Réinitialisation complète

```bash
dropdb atelier && createdb atelier
psql -d atelier -v ON_ERROR_STOP=1 \
  -f supabase/tests/000_stub_auth_local.sql \
  -f supabase/migrations/001_schema.sql \
  -f supabase/002_seed_demo.sql
```

### Scripts npm (recommandé)

Depuis la racine du dépôt :

```bash
npm run db:reset   # supprime, recrée et remplit la base atelier (stub + schéma + seed)
npm run db:test    # db:reset puis lance les scénarios de test
```

Aucune dépendance à installer : les scripts appellent simplement `dropdb`, `createdb` et `psql`.

### Alias pratique (pour lancer depuis n'importe quel dossier)

À ajouter dans `~/.zshrc` (adapter le chemin du dossier) :

```bash
alias atelier-reset='npm --prefix ~/chemin/vers/atelier run db:reset'
alias atelier-test='npm --prefix ~/chemin/vers/atelier run db:test'
```

Puis `source ~/.zshrc`, et ensuite simplement `atelier-reset` ou `atelier-test`.

### Si `dropdb` refuse (« database is being accessed by other users »)

Une connexion est encore ouverte (console `psql`, client graphique…). La fermer, ou forcer :

```bash
dropdb --force atelier
```

### Renommer une base existante

```bash
psql -d postgres -c 'ALTER DATABASE ancien_nom RENAME TO atelier;'
```

> Les rôles `anon` et `authenticated` sont créés au niveau du **serveur**, pas de la base : ils survivent à un `dropdb`. Le stub le gère (création seulement s'ils n'existent pas).

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

Dans `psql`, pour reproduire ce que fera l'application :

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

1. Créer un projet (région Europe).
2. **SQL Editor** → coller `supabase/migrations/001_schema.sql` → *Run*.
3. Optionnel en dev : coller `supabase/002_seed_demo.sql` → *Run*.
4. Ne **jamais** lancer `supabase/tests/000_stub_auth_local.sql` : Supabase fournit déjà `auth.uid()` et les rôles.

À moyen terme, utiliser la CLI Supabase (`brew install supabase/tap/supabase`, puis `supabase start`, avec Docker) ; les migrations sont déjà rangées dans `supabase/migrations/`. La CLI attend toutefois des noms horodatés (`20260101000000_schema.sql`) et un seed dans `supabase/seed.sql` : il faudra renommer ces fichiers à ce moment-là.

---

## Limites connues

- **PIN = traçabilité, pas sécurité** : un employé pourrait techniquement envoyer l'identifiant d'un collègue de la même boutique dans l'en-tête `x-utilisateur`. Acceptable pour une petite équipe de confiance ; sinon, passer par une Edge Function qui revérifie le PIN à chaque action.
- **Arrondi à 5 centimes** non géré : les totaux sont au centime.
- **Pas encore inclus** : événements, recettes (nomenclatures), stock périssable par lots, fournisseurs. Le modèle est prévu pour les greffer sans casser l'existant (`commande.canal = 'evenement'` + table dédiée, etc.).
