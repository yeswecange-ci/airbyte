# YesWeSync — Guide de déploiement production
## Coolify + DigitalOcean — Airbyte 2.2.0

---

## Architecture

```
DigitalOcean Droplet
└── Coolify
    └── Docker Compose (yeswecange-ci/airbyte)
        ├── proxy          → port 8000 (HTTP, Coolify gère HTTPS/TLS)
        ├── webapp         → UI Airbyte officielle
        ├── server         → API Airbyte (notre wrapper mince)
        ├── worker         → exécution des syncs
        ├── connector-builder-server
        ├── cron
        ├── temporal       → orchestration des workflows
        └── db             → PostgreSQL metadata Airbyte (interne)
        └── staging-db     → PostgreSQL destination (→ YesWeReport)
```

**Principe absolu :** Airbyte est le moteur officiel intact. On déploie autour. On ne modifie pas Airbyte.

---

## Volumes persistants

| Volume | Service | Mount path | Contenu | Critique |
|--------|---------|-----------|---------|----------|
| `airbyte-db-data` | db | `/var/lib/postgresql/data` | Metadata Airbyte (sources, destinations, connections, credentials) | **OUI** |
| `airbyte-workspace` | server, worker | `/tmp/workspace` | Artefacts des jobs de sync | Moyen |
| `airbyte-data` | server, worker | `/data` | Config Airbyte runtime | **OUI** |
| `airbyte-logs` | server, worker | `/tmp/logs` | Logs des syncs | Non |
| `temporal-db-data` | temporal | `/var/lib/postgresql/data` | État des workflows Temporal | **OUI** |
| `yeswesync-staging-db-data` | staging-db | `/var/lib/postgresql/data` | Données de staging (→ YesWeReport) | **OUI** |

> **Ne jamais faire** `docker volume rm`, `docker compose down -v`, ni `docker system prune --volumes`.

---

## Séparation des bases de données

```
Airbyte metadata DB (db)          ← usage Airbyte interne UNIQUEMENT
    airbyte-db-data

Staging DB (staging-db)           ← destination des syncs Meta Ads etc.
    yeswesync-staging-db-data
         ↓
    YesWeReport lit cette base
```

YesWeReport **ne doit jamais lire** la metadata DB Airbyte.

---

## Déploiement initial (étape par étape)

### 1. Serveur DigitalOcean

Minimum recommandé pour Airbyte 2.2.0 :
- **CPU :** 4 vCPU
- **RAM :** 8 Go (16 Go recommandé)
- **Disque :** 100 Go SSD (volumes Docker persistants)
- **OS :** Ubuntu 22.04

### 2. Installer Coolify sur le Droplet

Suivre la documentation officielle : https://coolify.io/docs/installation

### 3. Ouvrir Coolify → Nouveau projet

`Projects` → `New Project` → nommer `yeswesync`

### 4. Ajouter le repository

```
Source: GitHub
Repository: yeswecange-ci/airbyte
Branch: main
```

### 5. Choisir le mode de déploiement

Coolify détectera le `docker-compose.yml` à la racine.

Sélectionner : **Docker Compose**

### 6. Configurer les variables d'environnement

Dans Coolify → Settings → Environment Variables, saisir toutes les variables du bloc ci-dessous.

> Référence complète : [Variables à configurer](#variables-à-configurer-dans-coolify)

### 7. Configurer les volumes

Coolify gère les volumes Docker automatiquement depuis le `docker-compose.yml`.

Vérifier que les volumes nommés sont bien listés dans Coolify → Volumes.

### 8. Configurer le domaine

```
Domain: yeswesync.votre-domaine.com
Port: 8000
HTTPS: activé (Coolify gère Let's Encrypt automatiquement)
```

Le proxy Airbyte écoute sur le port 8000 en HTTP. Coolify terminera le TLS.

### 9. Cliquer Deploy

Coolify va :
1. Cloner le repository
2. Builder l'image `yeswesync-server:2.2.0` depuis le `Dockerfile` racine
3. Démarrer tous les services dans l'ordre (dépendances déclarées dans compose)
4. Attendre les healthchecks

**Ordre de démarrage automatique :**
```
db (healthy)
    → temporal (healthy) + bootloader (migrations)
        → server (healthy)
            → worker + webapp + connector-builder-server + cron
                → proxy (healthy)
```

### 10. Vérifier le démarrage

Dans Coolify → Logs :
```
[yeswesync] Environment OK — starting Airbyte server 2.2.0
```

Puis accéder à : `https://yeswesync.votre-domaine.com`

Identifiants : `BASIC_AUTH_USERNAME` / `BASIC_AUTH_PASSWORD` configurés.

---

## Opérations courantes

### Redéploiement (nouvelle version du compose/config)

```
Coolify → Deployment → Redeploy
```
Les volumes persistent automatiquement. Aucune donnée perdue.

### Restart d'un service

```
Coolify → Services → [service] → Restart
```

### Logs en temps réel

```
Coolify → Logs → [choisir le service]
```

Ou en SSH sur le Droplet :
```bash
docker compose logs -f server
docker compose logs -f worker
```

### Rollback vers une version précédente

1. Dans Coolify → Deployments → choisir un déploiement précédent
2. Cliquer **Redeploy this version**
3. Les volumes (données) ne sont PAS touchés par un rollback applicatif

---

## URL de staging pour YesWeReport

Variable à configurer dans YesWeReport :

```
AIRBYTE_STAGING_DATABASE_URL=postgresql://staging:VOTRE_STAGING_PASSWORD@staging-db:5432/yeswesync_staging
```

Si YesWeReport et YesWeSync sont sur le même réseau Docker Coolify, utiliser le nom de service `staging-db`.

Si séparés, exposer le port ou utiliser un réseau privé DigitalOcean et remplacer `staging-db` par l'IP privée du Droplet.

---

## Branding YesWeSync (optionnel — post-déploiement)

Le déploiement actuel utilise l'UI Airbyte officielle non modifiée.

Si vous souhaitez activer le branding YesWeCange (logo, CSS) ultérieurement, référez-vous au fichier `branding/README.md`. **Cette étape modifie le bundle Airbyte et doit être une décision séparée.**

---

## Variables à configurer dans Coolify

### A. Airbyte core

| Variable | Obligatoire | Exemple | Description |
|----------|:-----------:|---------|-------------|
| `AIRBYTE_VERSION` | Oui | `2.2.0` | Version Airbyte (ne pas changer) |
| `SECRET_PERSISTENCE` | Oui | `TESTING_CONFIG_DB_SECRET` | Stockage des secrets |
| `TRACKING_STRATEGY` | Oui | `logging` | Désactiver la télémétrie Airbyte |
| `AIRBYTE_ROLE` | Non | `community` | |
| `WEBAPP_URL` | Oui | `https://yeswesync.votre-domaine.com` | URL publique |
| `LOG_LEVEL` | Non | `INFO` | |
| `WORKER_ENVIRONMENT` | Oui | `docker` | Mode d'exécution |
| `AUTO_DETECT_SCHEMA` | Non | `true` | |

### B. Airbyte metadata PostgreSQL

| Variable | Obligatoire | Exemple | Description |
|----------|:-----------:|---------|-------------|
| `DATABASE_USER` | Oui | `airbyte` | User metadata DB |
| `DATABASE_PASSWORD` | Oui | `changeme` | **Choisir un mot de passe fort** |
| `DATABASE_DB` | Oui | `airbyte` | Nom de la base |
| `DATABASE_HOST` | Non | `db` | Nom du service (défaut: `db`) |
| `DATABASE_PORT` | Non | `5432` | |

### C. Staging PostgreSQL

| Variable | Obligatoire | Exemple | Description |
|----------|:-----------:|---------|-------------|
| `STAGING_USER` | Oui | `staging` | User staging DB |
| `STAGING_PASSWORD` | Oui | `changeme` | **Choisir un mot de passe fort** |
| `STAGING_DB` | Non | `yeswesync_staging` | Nom de la base staging |

### D. Authentification / Réseau

| Variable | Obligatoire | Exemple | Description |
|----------|:-----------:|---------|-------------|
| `BASIC_AUTH_USERNAME` | Oui | `yeswesync` | Login accès UI |
| `BASIC_AUTH_PASSWORD` | Oui | `changeme` | **Choisir un mot de passe fort** |
| `PROXY_PORT` | Non | `8000` | Port HTTP proxy (Coolify forward) |

### E. YesWeReport (à configurer dans YesWeReport)

| Variable | Obligatoire | Exemple | Description |
|----------|:-----------:|---------|-------------|
| `AIRBYTE_STAGING_DATABASE_URL` | Oui | `postgresql://staging:PWD@staging-db:5432/yeswesync_staging` | URL staging pour YesWeReport |

---

## Bloc `.env` prêt à copier dans Coolify

```env
AIRBYTE_VERSION=2.2.0
SECRET_PERSISTENCE=TESTING_CONFIG_DB_SECRET
TRACKING_STRATEGY=logging
AIRBYTE_ROLE=community
WEBAPP_URL=https://yeswesync.VOTRE_DOMAINE.com
LOG_LEVEL=INFO
WORKER_ENVIRONMENT=docker
AUTO_DETECT_SCHEMA=true

DATABASE_USER=airbyte
DATABASE_PASSWORD=
DATABASE_DB=airbyte
DATABASE_HOST=db
DATABASE_PORT=5432

BASIC_AUTH_USERNAME=yeswesync
BASIC_AUTH_PASSWORD=
PROXY_PORT=8000

STAGING_USER=staging
STAGING_PASSWORD=
STAGING_DB=yeswesync_staging

AIRBYTE_STAGING_DATABASE_URL=postgresql://staging:STAGING_PASSWORD@staging-db:5432/yeswesync_staging
```

> Remplacer toutes les valeurs vides par vos secrets. Ne pas commiter ce fichier rempli.
