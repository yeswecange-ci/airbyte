# YesWeSync — Guide de déploiement production
## abctl 0.30.4 + Airbyte 2.2.0 sur DigitalOcean + Coolify

---

## Architecture réelle d'Airbyte 2.2.0

```
abctl v0.30.4  ← binaire Go qui orchestre tout
  └── kind (Kubernetes dans Docker)
        └── cluster "airbyte-abctl"  ← 1 container Docker = 1 nœud K8s
              namespace: airbyte-abctl
                server            → API Airbyte
                worker            → gestion des workloads
                workload-launcher → crée des Pods K8s pour chaque sync
                manifest-server   → Connector Builder
                temporal          → orchestration
                cron
                db                → PostgreSQL metadata (interne Airbyte)
                ingress-nginx     → expose le port sur l'hôte
```

**WORKER_ENVIRONMENT=kubernetes** : chaque sync crée de vrais Pods Kubernetes.
Ce n'est pas du Docker Compose. Ce n'est pas configurable autrement sans modifier Airbyte.

---

## Ce que fait ce repository

Ce repository adapte NOTRE déploiement à Airbyte 2.2.0. Il ne modifie pas Airbyte.

```
Dockerfile
  └── installe abctl v0.30.4 (gestionnaire officiel Airbyte)

entrypoint.sh
  └── génère les valeurs Helm depuis les variables d'environnement
  └── appelle : abctl local install --chart-version 2.2.0
  └── supervise Airbyte (monitoring + restart)

docker-compose.yml
  ├── airbyte-manager  ← container qui exécute abctl
  └── staging-db       ← PostgreSQL de staging (→ YesWeReport)
```

---

## Architecture de déploiement sur DigitalOcean

```
DigitalOcean Droplet (Ubuntu 22.04, 8 Go RAM min)
│
├── Coolify (reverse proxy Traefik)
│   ├── yeswesync.votre-domaine.com → localhost:8085 (Airbyte via kind)
│   └── Docker Compose (ce repo)
│       ├── airbyte-manager  [privileged, Docker socket]
│       │     └── abctl → crée/supervise le cluster kind
│       └── staging-db       [PostgreSQL 15, port 5433]
│
└── Containers Docker créés par abctl (visibles dans "docker ps")
    └── airbyte-abctl-control-plane  ← nœud kind, expose :8085
```

---

## Volumes persistants

| Volume | Contenu | Critique |
|--------|---------|----------|
| `yeswesync-abctl-home` → `/root/.airbyte` | kubeconfig kind, données Helm, PVs K8s (metadata Airbyte, workspace) | **OUI** |
| `yeswesync-staging-db-data` → `/var/lib/postgresql/data` | Données de staging (sources, destinations) | **OUI** |

Les PVs Kubernetes d'Airbyte sont à l'intérieur du volume `yeswesync-abctl-home` :
```
/root/.airbyte/abctl/data/
  airbyte-local-pv/    → workspace jobs, logs
  airbyte-volume-db/   → PostgreSQL metadata Airbyte
```

> **Ne jamais faire** `docker volume rm yeswesync-abctl-home`.

---

## Séparation des bases de données

```
Metadata DB Airbyte
  → dans le cluster kind (airbyte-db-svc:5432, interne)
  → dans /root/.airbyte/abctl/data/airbyte-volume-db/
  → USAGE AIRBYTE UNIQUEMENT — YesWeReport ne touche jamais cette base

Staging DB (ce repo)
  → staging-db container (localhost:5433)
  → dans yeswesync-staging-db-data
  → YesWeReport lit CETTE base uniquement
```

---

## Déploiement initial (étape par étape)

### 1. Créer le Droplet DigitalOcean

Minimum recommandé :
- **CPU :** 4 vCPU
- **RAM :** 8 Go (16 Go recommandé — abctl + kind + Pods K8s)
- **Disque :** 100 Go SSD
- **OS :** Ubuntu 22.04

> kind (Kubernetes) consomme ~3-4 Go de RAM au repos.

### 2. Installer Coolify sur le Droplet

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

Accéder à Coolify : `http://IP_DROPLET:8000`

### 3. Configurer le projet dans Coolify

```
Projects → New Project → "yeswesync"
```

### 4. Ajouter le repository

```
New Resource → Docker Compose → From Git Repository
Repository: https://github.com/yeswecange-ci/airbyte
Branch: main
```

### 5. Configurer le container `airbyte-manager` comme privilégié

Dans Coolify → Service `airbyte-manager` → Advanced :
- **Privileged: ON** (requis pour kind/cgroups)
- **Docker socket: /var/run/docker.sock** (déjà dans le compose)

> Si Coolify ne permet pas le mode privilégié, voir la section "Déploiement direct" ci-dessous.

### 6. Saisir les variables d'environnement

Dans Coolify → Environment Variables, saisir le bloc ci-dessous.

### 7. Configurer les volumes

Coolify crée automatiquement les volumes Docker.
Optionnellement : mapper `yeswesync-abctl-home` vers un volume DigitalOcean Block Storage pour la persistance entre recréations de Droplet.

### 8. Configurer le domaine et le reverse proxy

Dans Coolify → Domains :
```
Domain: yeswesync.votre-domaine.com
Target: localhost:8085
Protocol: HTTP → HTTPS (Let's Encrypt auto)
```

> **Important :** Coolify doit proxyfier vers `localhost:8085` sur l'hôte — pas vers le port du container `airbyte-manager`. Airbyte est exposé directement sur l'hôte par le container kind.

### 9. Cliquer Deploy

Coolify va :
1. Builder l'image `yeswesync-manager:0.30.4`
2. Démarrer `airbyte-manager` (container privilégié avec Docker socket)
3. Démarrer `staging-db`
4. L'entrypoint lance `abctl local install --chart-version 2.2.0`
5. abctl crée le cluster kind + déploie Airbyte via Helm
6. Airbyte devient accessible sur `localhost:8085` de l'hôte

### 10. Vérifier le démarrage

Temps d'installation initial : **5-15 minutes**.

Logs dans Coolify → airbyte-manager :
```
[yeswesync] Socket Docker OK
[yeswesync] Docker engine hôte : v28.x.x
[yeswesync] Installation d'Airbyte 2.2.0 via abctl...
[yeswesync] SUCCESS Cluster 'airbyte-abctl' créé
[yeswesync] SUCCESS Airbyte Chart installé
[yeswesync] Airbyte accessible sur le port 8085 de l'hôte.
```

Vérification sur le Droplet :
```bash
docker ps | grep airbyte-abctl-control-plane
# → kindest/node:v1.32.2  0.0.0.0:8085->80/tcp  Up
```

### 11. Ouvrir YesWeSync

```
https://yeswesync.votre-domaine.com
```

Identifiants : email `emmanuelykpro@gmail.com` / `AIRBYTE_INITIAL_USER_PASSWORD`

### 12. Vérifier le Connector Builder

```
UI → Builder → Créer un connecteur → Tester
```

Le Builder utilise le `manifest-server` dans le cluster kind — il doit fonctionner normalement.

### 13. Vérifier un Sync

```
UI → Connections → New Connection → Source → Destination → Sync now
```

Les logs doivent montrer des Pods Kubernetes démarrés dans le cluster kind.

---

## Déploiement direct (sans container Coolify pour abctl)

Si Coolify ne supporte pas les containers privilégiés, une alternative est de faire tourner abctl directement sur l'OS du Droplet.

Sur le Droplet, en SSH :

```bash
# Installer abctl
curl -fsSL https://github.com/airbytehq/abctl/releases/download/v0.30.4/abctl_0.30.4_linux_amd64.tar.gz \
  | tar -xzC /usr/local/bin abctl

# Créer le fichier values.yaml
cat > /opt/yeswesync/values.yaml <<'EOF'
global:
  airbyteUrl: "https://yeswesync.votre-domaine.com"
  auth:
    enabled: true
  jobs:
    resources:
      limits:
        cpu: "3"
        memory: "4Gi"
  storage:
    type: local
postgresql:
  image:
    tag: "1.7.0-17"
EOF

# Installer Airbyte
abctl local install \
  --chart-version 2.2.0 \
  --port 8085 \
  --no-browser \
  --values /opt/yeswesync/values.yaml
```

Dans ce cas, Coolify gère uniquement `staging-db` et le reverse proxy.

---

## Opérations courantes

### Logs Airbyte

```bash
# Sur le Droplet :
export KUBECONFIG=~/.airbyte/abctl/abctl.kubeconfig
kubectl logs -n airbyte-abctl deployment/airbyte-abctl-server -f
kubectl logs -n airbyte-abctl deployment/airbyte-abctl-worker -f
```

Ou via Coolify → Logs → airbyte-manager.

### Status Airbyte

```bash
abctl local status
```

### Redéploiement (config/variables changées)

```
Coolify → Redeploy
```

abctl détecte l'installation existante et met à jour la configuration. Les données sont préservées.

### Rollback

Airbyte déployé via abctl est versionné par Helm.

```bash
export KUBECONFIG=~/.airbyte/abctl/abctl.kubeconfig
helm history airbyte-abctl -n airbyte-abctl
helm rollback airbyte-abctl <REVISION> -n airbyte-abctl
```

Les données (PVs) ne sont pas touchées par un rollback Helm.

---

## URL staging pour YesWeReport

```
AIRBYTE_STAGING_DATABASE_URL=postgresql://staging:MOT_DE_PASSE@IP_PRIVEE_DROPLET:5433/yeswesync_staging
```

Si YesWeReport tourne sur le même Droplet :
```
AIRBYTE_STAGING_DATABASE_URL=postgresql://staging:MOT_DE_PASSE@localhost:5433/yeswesync_staging
```

---

## Variables à configurer dans Coolify

### Infrastructure / Airbyte

| Variable | Obligatoire | Exemple | Description |
|----------|:-----------:|---------|-------------|
| `AIRBYTE_URL` | **Oui** | `https://yeswesync.domain.com` | URL publique HTTPS |
| `AIRBYTE_PORT` | Non | `8085` | Port hôte pour Airbyte |
| `AIRBYTE_INITIAL_USER_PASSWORD` | **Oui** | `motdepasse` | Admin initial |
| `AIRBYTE_INSTALLATION_ID` | Non | `uuid` | Auto-généré si vide |
| `AIRBYTE_JOB_CPU_LIMIT` | Non | `3` | CPU max par job |
| `AIRBYTE_JOB_MEMORY_LIMIT` | Non | `4Gi` | RAM max par job |
| `ABCTL_EXTRA_FLAGS` | Non | `--low-resource-mode` | Pour Droplets < 8 Go |

### Staging PostgreSQL

| Variable | Obligatoire | Exemple | Description |
|----------|:-----------:|---------|-------------|
| `STAGING_USER` | **Oui** | `staging` | User DB staging |
| `STAGING_PASSWORD` | **Oui** | `motdepasse` | Mot de passe fort |
| `STAGING_DB` | Non | `yeswesync_staging` | Nom de la base |
| `STAGING_PORT` | Non | `5433` | Port hôte |

### YesWeReport (à configurer dans YesWeReport)

| Variable | Obligatoire | Exemple |
|----------|:-----------:|---------|
| `AIRBYTE_STAGING_DATABASE_URL` | **Oui** | `postgresql://staging:PWD@localhost:5433/yeswesync_staging` |

---

## Bloc `.env` prêt à copier dans Coolify

```env
AIRBYTE_URL=https://yeswesync.VOTRE_DOMAINE.com
AIRBYTE_PORT=8085
AIRBYTE_INITIAL_USER_PASSWORD=
AIRBYTE_INSTALLATION_ID=
AIRBYTE_JOB_CPU_LIMIT=3
AIRBYTE_JOB_MEMORY_LIMIT=4Gi
ABCTL_EXTRA_FLAGS=

STAGING_USER=staging
STAGING_PASSWORD=
STAGING_DB=yeswesync_staging
STAGING_PORT=5433
```

---

## Contrainte Coolify importante à communiquer au lead

Le container `airbyte-manager` nécessite **le mode privilégié** (`--privileged`) parce que kind (Kubernetes dans Docker) a besoin d'accès aux cgroups du système hôte.

Dans Coolify, vérifier que :
1. L'option "Privileged" est disponible pour les Docker services
2. Le bind mount `/var/run/docker.sock` est autorisé

Si Coolify ne le permet pas → utiliser le **déploiement direct** (abctl sur l'OS, section ci-dessus). Dans ce cas, Coolify ne gère que `staging-db` et le reverse proxy.
