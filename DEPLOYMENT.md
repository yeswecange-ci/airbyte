# YesWeSync — Guide de déploiement production
## abctl 0.30.4 + Airbyte 2.2.0 sur DigitalOcean

> **Principe** : Le déploiement s'adapte à Airbyte. Airbyte n'est pas modifié.
> Nous reproduisons en production l'architecture Airbyte 2.2.0 déjà validée chez nous avec abctl/kind.

---

## Architecture réelle d'Airbyte 2.2.0

```
abctl v0.30.4  ← gestionnaire officiel (binaire Go autonome)
  └── kind  ← Kubernetes dans Docker (1 container = 1 nœud K8s)
        └── cluster "airbyte-abctl"
              namespace: airbyte-abctl
                server            → API Airbyte (port 8001 interne)
                worker            → gestion workloads
                workload-launcher → crée des PODS K8s pour chaque sync
                manifest-server   → Connector Builder
                temporal          → orchestration des workflows
                cron
                db                → PostgreSQL metadata Airbyte (interne)
                ingress-nginx     → expose sur port 8085 de l'hôte
```

**Point critique** : `WORKER_ENVIRONMENT=kubernetes`. Chaque sync lance des Pods Kubernetes réels. L'architecture ne peut pas être simplifiée en Docker Compose sans modifier Airbyte.

---

## Architecture sur le Droplet DigitalOcean

```
DigitalOcean Droplet Ubuntu 22.04
│
├── Docker Engine
│   ├── airbyte-abctl-control-plane  ← container kind (nœud K8s)
│   │     ├── Pods Airbyte (server, worker, temporal, db...)
│   │     └── Réseau Pod : 10.244.0.0/24
│   │
│   └── yeswesync-staging-db         ← PostgreSQL de staging
│         ├── Réseau Docker normal
│         └── Réseau kind (172.19.0.0/16)  ← ajouté par install.sh
│
├── abctl v0.30.4  (installé sur l'OS, ou dans le container yeswesync-tools)
│
└── Coolify
    ├── Traefik (réseau "coolify")  → domaine + TLS
    └── yeswesync-tools (ce repo, Dockerfile)  ← réseaux "coolify" + "kind"
          └── socat :8085 → airbyte-abctl-control-plane:80 (ingress Airbyte)
```

**Pourquoi un relais socat ?** Traefik ne joint les containers que via le réseau Docker `coolify`.
Airbyte, lui, est exposé par kind sur le port 8085 de l'*hôte* — ni `--network host`
(le container sort du réseau `coolify` → *Bad Gateway*), ni un port du container ne
suffisent. Le container `yeswesync-tools` se connecte donc lui-même au réseau `kind`
(même technique que pour staging-db) et relaie `0.0.0.0:8085 → nœud kind:80`.
Ce relais sert aussi à `abctl`, qui valide l'installation en appelant `http://localhost:8085`.

---

## Networking : comment les Pods accèdent au staging PostgreSQL

C'est le point le plus critique. Voici la réalité prouvée par test :

```
Pod K8s (10.244.0.x)
  → gateway CNI (10.244.0.1 = intérieur du nœud kind)
  → nœud kind (172.19.0.2 sur le réseau Docker "kind")
  → staging-db (172.19.0.x — connecté au réseau "kind" par install.sh)
  → PostgreSQL répond
```

**Pourquoi cette méthode et pas d'autres :**

| Approche | Résultat |
|----------|----------|
| Hostname Docker `staging-db` depuis un Pod | ✗ — CoreDNS K8s ne connaît pas les DNS Docker |
| IP hôte `172.19.0.1` (gateway kind) depuis un Pod | ✗ — sur Docker Desktop Mac (isolation) / à valider sur Linux |
| Container staging-db connecté au réseau `kind` → IP `172.19.x.x` | ✓ — **confirmé par test** |

**install.sh exécute automatiquement :**
```bash
docker network connect kind yeswesync-staging-db
```
et affiche l'IP à utiliser dans Airbyte.

**Attention reboot** : l'IP kind du staging-db peut changer après un reboot. Le service systemd `yeswesync-reboot` la reconnecte et sauvegarde la nouvelle IP dans `/root/.airbyte/staging-kind-ip.env`. Vérifier et mettre à jour la Destination Airbyte si l'IP change.

---

## Persistence des données

| Donnée | Stockage | Chemin hôte | Survit à |
|--------|----------|------------|----------|
| Metadata Airbyte (sources, destinations, connections) | PV Kubernetes → bind mount | `/root/.airbyte/abctl/data/airbyte-volume-db/` | restart, reboot |
| Workspace jobs (artefacts, logs sync) | PV Kubernetes → bind mount | `/root/.airbyte/abctl/data/airbyte-local-pv/` | restart, reboot |
| Connector Builder (manifests) | Metadata DB Airbyte (ci-dessus) | — | restart, reboot |
| Historique jobs | Metadata DB Airbyte (ci-dessus) | — | restart, reboot |
| Staging PostgreSQL (données métier) | Docker volume nommé | `yeswesync-staging-db-data` | restart, reboot |
| kubeconfig kind, Helm state | Fichiers abctl | `/root/.airbyte/abctl/` | restart, reboot |

**Ne jamais :**
```bash
docker volume rm yeswesync-staging-db-data
docker rm airbyte-abctl-control-plane
rm -rf /root/.airbyte/abctl/data/
```

---

## Déploiement initial

### 1. Créer le Droplet DigitalOcean

Minimum recommandé :
- **CPU :** 4 vCPU
- **RAM :** 8 Go (kind + K8s + Airbyte Pods ≈ 4-5 Go au repos)
- **Disque :** 100 Go SSD
- **OS :** Ubuntu 22.04 LTS
- **Région :** celle de YesWeReport (même réseau privé si possible)

### 2. Installer Docker sur le Droplet

```bash
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
```

### 3. Cloner le repository

```bash
git clone https://github.com/yeswecange-ci/airbyte.git /opt/yeswesync
cd /opt/yeswesync
```

### 4. Créer le fichier .env

```bash
cp .env.example .env
nano .env  # remplir les valeurs réelles
```

Variables obligatoires minimum :
```env
AIRBYTE_URL=https://yeswesync.votre-domaine.com
AIRBYTE_INITIAL_USER_PASSWORD=MotDePasseFort
STAGING_USER=staging
STAGING_PASSWORD=AutreMotDePasseFort
```

### 5. Lancer l'installation

```bash
chmod +x install.sh
./install.sh
```

L'installation prend **5 à 15 minutes** (téléchargement images Airbyte).

Résultat attendu en fin de script :
```
[yeswesync] ✓ Airbyte 2.2.0 installé
[yeswesync] ✓ staging-db connecté au réseau kind
[yeswesync] ✓ IP staging-db (réseau kind) : 172.19.0.3
[yeswesync]   Dans Airbyte (Destination PostgreSQL) :
[yeswesync]     Host     : 172.19.0.3
[yeswesync]     Port     : 5432
```

### 6. Configurer le domaine avec Coolify (ou nginx)

**Option A — Coolify (recommandé : déploiement complet depuis ce repo)**

Dans Coolify → New Resource → Public/Private Repository → ce repo, build pack **Dockerfile** :

| Réglage | Valeur |
|---------|--------|
| Domain | `https://airbyte.ywcdigital.com` |
| Ports Exposes | `8085` |
| Storages → Bind mount | `/var/run/docker.sock` → `/var/run/docker.sock` |
| Storages → Bind mount | `/root/.airbyte` → `/root/.airbyte` (même chemin des deux côtés — kind bind-monte ce chemin depuis l'hôte) |
| Custom Docker Options | **vide** — surtout pas `--network host` (sinon *Bad Gateway*) |
| Env | `AIRBYTE_URL=https://airbyte.ywcdigital.com`, `AIRBYTE_INITIAL_USER_PASSWORD`, `STAGING_USER`, `STAGING_PASSWORD` |

Au premier déploiement, `entrypoint.sh` lance `install.sh` : compter **5 à 15 minutes**
pendant lesquelles le domaine répond *Bad Gateway* (normal, Airbyte n'est pas encore up).
Suivre l'avancement dans Coolify → Logs. Attendu à la fin :
```
[yeswesync] relais 0.0.0.0:8085 → 172.19.0.2:80 (ingress Airbyte)
[yeswesync] ✓ install.sh terminé — Airbyte installé
```
Coolify gère Let's Encrypt automatiquement. Les redéploiements suivants sont rapides :
kind est déjà là, le container ne fait que relancer le relais.

**Option B — nginx sur l'OS**
```bash
apt install nginx certbot python3-certbot-nginx -y
# Configurer un vhost qui proxy vers localhost:8085
```

### 7. Ouvrir YesWeSync

```
https://yeswesync.votre-domaine.com
```

Email : `emmanuelykpro@gmail.com` / mot de passe : `AIRBYTE_INITIAL_USER_PASSWORD`

### 8. Configurer la Destination PostgreSQL dans Airbyte

```
UI → Destinations → New Destination → PostgreSQL

Host     : <IP affichée par install.sh — ex: 172.19.0.3>
Port     : 5432
Database : yeswesync_staging
Username : staging
Password : STAGING_PASSWORD
```

### 9. Vérifier le Connector Builder

```
UI → Builder → New Connector
```

Le Builder appelle le `manifest-server` dans le cluster kind. Il doit fonctionner sans configuration supplémentaire.

### 10. Test de sync

```
UI → Connections → New Connection
→ Source : Meta Ads (ou autre)
→ Destination : le staging PostgreSQL configuré à l'étape 8
→ Sync now
```

Vérification des logs :
```bash
export KUBECONFIG=/root/.airbyte/abctl/abctl.kubeconfig
kubectl logs -n airbyte-abctl deployment/airbyte-abctl-worker -f
```

Vous devez voir des Pods de connector être créés dans le namespace `airbyte-abctl`.

---

## Comportement après reboot du Droplet

Au reboot :
1. Docker Engine redémarre
2. Le container `airbyte-abctl-control-plane` (kind) redémarre automatiquement (`unless-stopped` — configuré par install.sh)
3. Kubernetes dans kind recharge depuis ses données persistantes
4. Les Pods Airbyte se réschedulisent
5. Le service systemd `yeswesync-reboot` se lance et reconnecte `staging-db` au réseau kind
   (déploiement Coolify : c'est le container `yeswesync-tools`, redémarré par Coolify, qui s'en charge via `entrypoint.sh`)

**Temps de récupération :** 2 à 5 minutes après reboot.

**Vérification :**
```bash
abctl local status
docker inspect yeswesync-staging-db --format '{{.NetworkSettings.Networks.kind.IPAddress}}'
cat /root/.airbyte/staging-kind-ip.env
```

Si l'IP kind de staging-db a changé : la mettre à jour dans la Destination Airbyte.

---

## Opérations courantes

### Status

```bash
abctl local status
docker ps | grep -E "airbyte|staging"
```

### Logs Airbyte

```bash
export KUBECONFIG=/root/.airbyte/abctl/abctl.kubeconfig

# Server
kubectl logs -n airbyte-abctl deployment/airbyte-abctl-server -f

# Worker
kubectl logs -n airbyte-abctl deployment/airbyte-abctl-worker -f

# Workload Launcher (ce qui lance les Pods connecteurs)
kubectl logs -n airbyte-abctl deployment/airbyte-abctl-workload-launcher -f
```

### Mise à jour de la configuration (values.yaml)

```bash
cd /opt/yeswesync
# Modifier values.yaml ou .env
./install.sh  # idempotent — met à jour sans réinstaller
```

### Rollback Helm

```bash
export KUBECONFIG=/root/.airbyte/abctl/abctl.kubeconfig
helm history airbyte-abctl -n airbyte-abctl
helm rollback airbyte-abctl <REVISION> -n airbyte-abctl
# Les données (PVs) ne sont pas touchées
```

### Vérification manuelle entrypoint

```bash
/opt/yeswesync/entrypoint.sh
```

---

## URL staging pour YesWeReport

YesWeReport accède au staging via l'hôte (pas via kind) :

```env
# Même Droplet que Airbyte :
AIRBYTE_STAGING_DATABASE_URL=postgresql://staging:PASSWORD@localhost:5433/yeswesync_staging

# Droplet séparé (IP privée DigitalOcean recommandée) :
AIRBYTE_STAGING_DATABASE_URL=postgresql://staging:PASSWORD@IP_PRIVEE:5433/yeswesync_staging
```

Le port `5433` est celui exposé sur l'hôte par le container `yeswesync-staging-db`.

---

## Variables à configurer

### Infrastructure

| Variable | Obligatoire | Défaut | Description |
|----------|:-----------:|--------|-------------|
| `ABCTL_VERSION` | Non | `0.30.4` | Version abctl (ne pas changer) |
| `AIRBYTE_VERSION` | Non | `2.2.0` | Version Airbyte Helm chart |
| `AIRBYTE_URL` | **Oui** | — | URL HTTPS publique |
| `AIRBYTE_PORT` | Non | `8085` | Port hôte Airbyte |
| `AIRBYTE_INITIAL_USER_PASSWORD` | Oui | — | Admin Airbyte |
| `AIRBYTE_INSTALLATION_ID` | Non | auto | UUID installation |
| `AIRBYTE_JOB_CPU_LIMIT` | Non | `3` | CPU max/job connecteur |
| `AIRBYTE_JOB_MEMORY_LIMIT` | Non | `4Gi` | RAM max/job connecteur |
| `ABCTL_EXTRA_FLAGS` | Non | — | `--low-resource-mode` si < 8 Go |
| `AIRBYTE_DATA_DIR` | Non | `/root/.airbyte` | Chemin données abctl |

### Staging PostgreSQL

| Variable | Obligatoire | Défaut | Description |
|----------|:-----------:|--------|-------------|
| `STAGING_CONTAINER_NAME` | Non | `yeswesync-staging-db` | Nom container |
| `STAGING_USER` | **Oui** | — | User PostgreSQL |
| `STAGING_PASSWORD` | **Oui** | — | Mot de passe fort |
| `STAGING_DB` | Non | `yeswesync_staging` | Nom de la base |
| `STAGING_PORT` | Non | `5433` | Port hôte |

### YesWeReport

| Variable | Côté | Valeur |
|----------|------|--------|
| `AIRBYTE_STAGING_DATABASE_URL` | YesWeReport | `postgresql://staging:PWD@localhost:5433/yeswesync_staging` |

---

## Bloc `.env` prêt à remplir

```env
ABCTL_VERSION=0.30.4
AIRBYTE_VERSION=2.2.0
AIRBYTE_URL=https://yeswesync.VOTRE_DOMAINE.com
AIRBYTE_PORT=8085
AIRBYTE_INITIAL_USER_PASSWORD=
AIRBYTE_INSTALLATION_ID=
AIRBYTE_JOB_CPU_LIMIT=3
AIRBYTE_JOB_MEMORY_LIMIT=4Gi
ABCTL_EXTRA_FLAGS=
AIRBYTE_DATA_DIR=/root/.airbyte

STAGING_CONTAINER_NAME=yeswesync-staging-db
STAGING_USER=staging
STAGING_PASSWORD=
STAGING_DB=yeswesync_staging
STAGING_PORT=5433
```
