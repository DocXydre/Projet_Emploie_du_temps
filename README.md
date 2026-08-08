# Système de planification personnelle et de logistique domestique

API qui croise des emplois du temps hétérogènes (cours IDMC, shifts McDonald's, disponibilités de Lorette), planifie les tâches récurrentes et gère le stock d'uniforme en flux tendu.

Le livrable est **l'API, et rien d'autre** : aucune interface graphique dans ce dépôt. L'usage quotidien passe par le canal de notification à boutons et l'export ICS. Spécification complète : [`cahier-des-charges-planification.md`](cahier-des-charges-planification.md).

**État : lot 1 terminé** — modèle métier des sections 5.1 à 5.3, authentification à deux comptes, CRUD des définitions et occurrences, journal d'événements. Le moteur de planification arrive au lot 3.

## Architecture

```
Caddy (profil prod)  ──►  coeur (Spring Boot 21)  ──►  PostgreSQL 16
                                   │
                                   └──►  collecteurs (FastAPI, réseau interne)
```

Un seul service exposé publiquement : le cœur métier. Les collecteurs sont un service interne, isolé pour qu'un scraper mort ou fuyant ne fasse pas tomber le planificateur.

## Arborescence

```
coeur/                  Cœur métier (Java 21, Spring Boot, Maven)
  src/main/java/fr/thomasmathis/planif/
    commun/             Horloge injectable, erreurs, corrélation
    securite/           JWT, permissions                     ✔ lot 1
    utilisateurs/       Comptes, rôles, amorce               ✔ lot 1
    taches/             Définitions, occurrences, états      ✔ lot 1
    statuts/            Statuts globaux et effets            ✔ lot 1
    journal/            Traçabilité des actions              ✔ lot 1
    contraintes/        Occupations, sources, disponibilités ✔ lot 1 / lot 2
    sante/              Sonde d'infrastructure               ✔ lot 0
    planification/      Interface Planificateur + moteur       lot 3
    notifications/      Canaux, escalade, validation           lot 4
    travail/            Shifts, pointages, synthèse            lot 5
    stock/              Uniforme, linge, projection            lot 6
    sport/              Quota, rotation, duo                   lot 7
    deplacements/       Trajets et statut ABSENT               lot 8
    api/                Erreurs normalisées, OpenAPI
  src/main/resources/db/migration/   Migrations Flyway
collecteurs/            Service de collecte (Python 3.12, FastAPI)
  app/contrat.py        Contrat commun : recuperer / normaliser / publier / sante
infra/
  caddy/Caddyfile       Reverse proxy, HTTPS automatique
  scripts/              Sauvegarde et restauration PostgreSQL
```

Règle de découpage : un module ne dépend jamais des entités internes d'un autre. Il passe par une interface exposée par ce module.

## Démarrage local

```bash
cp .env.example .env
# Renseigner POSTGRES_PASSWORD, PLANIF_SECRET_JWT, PLANIF_CLE_CHIFFREMENT,
# PLANIF_JETON_INTERNE, et les deux mots de passe de compte.
openssl rand -base64 48   # pour générer une clé ou un secret

docker compose up -d --build
```

Les comptes sont créés au premier démarrage à partir de `PLANIF_ADMIN_MOT_DE_PASSE` et `PLANIF_STANDARD_MOT_DE_PASSE`. Sans ces variables, aucun compte n'est créé : il n'existe pas de mot de passe par défaut.

```bash
# Se connecter et appeler un endpoint protégé
JETON=$(curl -s -X POST localhost:8080/api/v1/auth/connexion \
  -H 'Content-Type: application/json' \
  -d '{"identifiant":"thomas","motDePasse":"..."}' | jq -r .jetonAcces)

curl -s -H "Authorization: Bearer $JETON" localhost:8080/api/v1/taches/definitions | jq
curl -s -H "Authorization: Bearer $JETON" localhost:8080/api/v1/taches/occurrences/en-retard | jq
```

| Point d'entrée | URL |
|---|---|
| Santé du cœur | http://localhost:8080/sante |
| Santé versionnée | http://localhost:8080/api/v1/sante |
| OpenAPI (JSON) | http://localhost:8080/openapi.json |
| Documentation interactive | http://localhost:8080/documentation |
| Santé des collecteurs | http://localhost:8000/sante |

Vérification rapide :

```bash
curl -s localhost:8080/sante | jq
# {"service":"planif-coeur","version":"0.1.0","etat":"OK",
#  "dependances":{"postgresql":"OK"},"horodatage":"..."}
```

## Développement hors Docker

```bash
# Base seule
docker compose up -d base

# Cœur métier
cd coeur && mvn spring-boot:run

# Collecteurs
cd collecteurs && pip install -e ".[dev]" && uvicorn app.main:app --reload
```

## Tests

```bash
cd coeur        && mvn verify              # tests unitaires
cd collecteurs  && pytest -q && ruff check .

# Tests d'intégration : exigent un PostgreSQL joignable
docker compose up -d base
cd coeur && DB_HOTE=localhost DB_PORT=5432 mvn -Pintegration verify
```

La couverture n'est pas un objectif en soi. L'effort porte sur les règles qui rendent le système inutilisable si elles cassent : la récurrence recalculée depuis la date de validation réelle, les dépendances sans doublon, les transitions d'état et les permissions.

Les tests d'intégration valident en plus ce qu'aucun test unitaire ne voit : que les migrations Flyway et le mapping JPA restent cohérents. Un écart fait échouer le démarrage, `ddl-auto` étant en `validate`.

## Sauvegarde

```bash
./infra/scripts/sauvegarde.sh                       # dump gzip, rétention 30 jours
./infra/scripts/restauration.sh sauvegardes/xxx.gz  # à tester avant la production
```

## Conventions

- **Temps** : stockage en UTC, affichage en Europe/Paris. Toute date exposée est en ISO 8601 avec fuseau explicite. Aucun appel direct à `Instant.now()` : l'horloge est injectée.
- **Langue** : le domaine métier est nommé en français (`occurrence`, `echeance_max`, `epinglee`) pour coller au vocabulaire contractuel du cahier des charges. Les termes techniques restent en anglais.
- **Erreurs** : format unique `{code, message, detail, correlation, horodatage}`. Chaque requête porte un en-tête `X-Correlation-Id` que l'on retrouve dans les journaux.
- **Versionnement** : préfixe `/api/v1`. Aucune rupture de contrat sans changement de version. `/sante` est hors version : c'est une sonde d'infrastructure.
- **Migrations** : une migration appliquée n'est jamais modifiée.
- **Secrets** : jamais dans le dépôt. Variables d'environnement, puis chiffrement en base pour les identifiants externes.

## Endpoints disponibles

| Domaine | Endpoints |
|---|---|
| Authentification | `POST /api/v1/auth/connexion`, `/auth/rafraichir` |
| Définitions | `GET/POST /api/v1/taches/definitions`, `PATCH`/`DELETE /{id}` |
| Occurrences | `GET/POST /api/v1/taches/occurrences`, `/en-retard`, `/{id}/valider`, `/reporter`, `/refuser`, `/reassigner` |
| Contraintes | `GET/POST /api/v1/occupations`, `GET /api/v1/sources/sante` |
| Statuts | `GET /api/v1/statuts/courant`, `/historique`, `POST /api/v1/statuts`, `/{id}/terminer` |
| Utilisateurs | `GET /api/v1/utilisateurs`, `/moi` |
| Système | `GET /sante`, `/api/v1/journal` (administrateur) |

La validation accepte une date réelle : `POST /taches/occurrences/{id}/valider` avec `{"dateReelle":"..."}`. C'est cette date, et non l'échéance théorique, qui sert de point de départ à la prochaine occurrence.

## Prochaine étape — lot 2 : calendrier consolidé

Collecteur ICS de l'IDMC avec réconciliation par UID, saisie de l'emploi du temps de Lorette, calcul des disponibilités (passe 1 du moteur), export ICS en lecture seule. Critère de sortie : le planning universitaire et les shifts s'affichent dans l'application de calendrier du téléphone.

Décisions du cahier des charges à trancher avant les lots concernés : ICS de l'école de Lorette (lot 2), canal de notification (lot 4), double authentification du portail McDonald's (lot 5), source des horaires de train (lot 8).
