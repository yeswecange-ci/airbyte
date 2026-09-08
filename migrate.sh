#!/usr/bin/env bash
# YesWeSync — restauration d'une instance Airbyte existante sur un nouveau Droplet
#
# Prérequis (à transférer dans le même répertoire que ce script) :
#   - airbyte-metadata.dump  (pg_dump custom du db-airbyte local)
#   - staging.dump           (pg_dump custom de la staging DB locale)
#   - k8s-secret-airbyte.yaml  (kubectl get secret airbyte-abctl-airbyte-secrets -o yaml)
#   - k8s-secret-auth.yaml     (kubectl get secret airbyte-auth-secrets -o yaml)
#   - values.yaml              (Helm values de l'installation source)
#
# Usage :
#   scp -r ~/yeswesync-migration/backup root@DROPLET_IP:/root/migration/
#   scp migrate.sh root@DROPLET_IP:/root/migration/
#   ssh root@DROPLET_IP "cd /root/migration && bash migrate.sh"
#
# AIRBYTE SOURCE CODE MODIFIED: NO. AIRBYTE BACKEND MODIFIED: NO.
set -euo pipefail

log()  { echo "[$(date '+%H:%M:%S')] [migrate] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] [migrate] ✓ $*"; }
fail() { echo "[$(date '+%H:%M:%S')] [migrate] ERREUR : $*" >&2; exit 1; }
step() { echo; echo "══════════════════════════════════════════════"; echo "[$(date '+%H:%M:%S')] [migrate] ÉTAPE : $*"; echo "══════════════════════════════════════════════"; }

ABCTL_VERSION="0.30.4"
AIRBYTE_VERSION="2.2.0"
AIRBYTE_PORT="${AIRBYTE_PORT:-8085}"
STAGING_CONTAINER="${STAGING_CONTAINER_NAME:-yeswesync-staging-db}"
STAGING_USER="${STAGING_USER:-staging}"
STAGING_PASSWORD="${STAGING_PASSWORD:?STAGING_PASSWORD requis}"
STAGING_DB="${STAGING_DB:-yeswesync_staging}"
STAGING_PORT="${STAGING_PORT:-5433}"
MIGRATION_DIR="$(cd "$(dirname "$0")" && pwd)"
KUBECONFIG_PATH="/root/.airbyte/abctl/abctl.kubeconfig"

# ── Vérifications préalables ───────────────────────────────────────────────────
step "Vérifications préalables"

[[ "$(uname)" == "Linux" ]] || fail "Ce script doit tourner sur Linux (Droplet Ubuntu 22.04)"

for f in airbyte-metadata.dump staging.dump k8s-secret-airbyte.yaml k8s-secret-auth.yaml; do
  [[ -f "${MIGRATION_DIR}/${f}" ]] || fail "Fichier manquant : ${MIGRATION_DIR}/${f}"
done
ok "Tous les fichiers de migration présents"

RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
[[ "${RAM_GB}" -ge 7 ]] || fail "RAM insuffisante : ${RAM_GB}GB (minimum 8GB)"
ok "RAM : ${RAM_GB}GB"

# ── Installation Docker ────────────────────────────────────────────────────────
step "Installation Docker"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  ok "Docker installé"
else
  ok "Docker déjà présent : $(docker --version)"
fi

# ── Installation abctl ─────────────────────────────────────────────────────────
step "Installation abctl v${ABCTL_VERSION}"
if ! command -v abctl &>/dev/null || ! abctl version 2>/dev/null | grep -q "${ABCTL_VERSION}"; then
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64)  ARCH_SLUG="amd64" ;;
    aarch64) ARCH_SLUG="arm64" ;;
    *)        fail "Architecture non supportée : ${ARCH}" ;;
  esac
  curl -fsSL \
    "https://github.com/airbytehq/abctl/releases/download/v${ABCTL_VERSION}/abctl-v${ABCTL_VERSION}-linux-${ARCH_SLUG}.tar.gz" \
    | tar -xzC /usr/local/bin abctl
  chmod +x /usr/local/bin/abctl
  ok "abctl v${ABCTL_VERSION} installé"
else
  ok "abctl déjà présent : $(abctl version 2>/dev/null | head -1)"
fi

# ── Installation initiale Airbyte (schéma vide) ───────────────────────────────
step "Installation Airbyte ${AIRBYTE_VERSION} (schéma vide — sera écrasé)"
log "Cette étape installe un Airbyte neuf pour créer le schéma et les migrations"
log "Durée estimée : 5 à 15 minutes"

VALUES_SRC="${MIGRATION_DIR}/values.yaml"
VALUES_DEST="/root/yeswesync-values.yaml"
if [[ -f "${VALUES_SRC}" ]]; then
  cp "${VALUES_SRC}" "${VALUES_DEST}"
  log "values.yaml copié depuis migration/"
else
  cat > "${VALUES_DEST}" << 'YAML'
global:
  auth:
    enabled: true
  storage:
    type: local
  jobs:
    resources:
      limits:
        cpu: "3"
        memory: "4Gi"
postgresql:
  image:
    tag: "1.7.0-17"
YAML
  log "values.yaml minimal généré"
fi

abctl local install \
  --chart-version "${AIRBYTE_VERSION}" \
  --port "${AIRBYTE_PORT}" \
  --no-browser \
  --values "${VALUES_DEST}" \
  || fail "abctl install échoué"

ok "Airbyte ${AIRBYTE_VERSION} installé (schéma vide)"

# ── Attente bootloader ─────────────────────────────────────────────────────────
step "Attente du bootloader Airbyte"
export KUBECONFIG="${KUBECONFIG_PATH}"

log "Attente que le bootloader termine les migrations..."
for i in $(seq 1 30); do
  STATUS=$(kubectl get pods -n airbyte-abctl --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | grep -c "airbyte-abctl-server" || echo 0)
  if [[ "${STATUS}" -ge 1 ]]; then
    ok "Server Airbyte running après ${i} checks"
    break
  fi
  log "Check ${i}/30 — server pas encore running, attente 20s..."
  sleep 20
done

# ── Scale down server (garder DB running) ─────────────────────────────────────
step "Arrêt du server Airbyte (la DB reste active)"
kubectl scale deployment airbyte-abctl-server -n airbyte-abctl --replicas=0
kubectl scale deployment airbyte-abctl-worker -n airbyte-abctl --replicas=0
kubectl scale deployment airbyte-abctl-workload-launcher -n airbyte-abctl --replicas=0 2>/dev/null || true
kubectl scale deployment airbyte-abctl-temporal -n airbyte-abctl --replicas=0 2>/dev/null || true
sleep 10
ok "Server arrêté, DB toujours running"

# ── Restauration metadata DB ───────────────────────────────────────────────────
step "Restauration de la metadata DB Airbyte"
DB_POD=$(kubectl get pods -n airbyte-abctl -l app.kubernetes.io/name=postgresql \
  --no-headers -o custom-columns=":metadata.name" | head -1)
[[ -n "${DB_POD}" ]] || fail "Pod PostgreSQL introuvable"
log "Pod DB : ${DB_POD}"

log "Copie du dump dans le pod..."
kubectl cp "${MIGRATION_DIR}/airbyte-metadata.dump" \
  "airbyte-abctl/${DB_POD}:/tmp/airbyte-metadata.dump"

log "Drop + recréation de la base (schéma vide → restauration propre)..."
kubectl exec -n airbyte-abctl "${DB_POD}" -- \
  psql -U airbyte -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='db-airbyte' AND pid<>pg_backend_pid();"

kubectl exec -n airbyte-abctl "${DB_POD}" -- \
  psql -U airbyte -d postgres -c "DROP DATABASE IF EXISTS \"db-airbyte\";"

kubectl exec -n airbyte-abctl "${DB_POD}" -- \
  psql -U airbyte -d postgres -c "CREATE DATABASE \"db-airbyte\" OWNER airbyte;"

log "Restauration pg_restore..."
kubectl exec -n airbyte-abctl "${DB_POD}" -- \
  pg_restore -U airbyte -d "db-airbyte" --no-owner --role=airbyte \
  --exit-on-error /tmp/airbyte-metadata.dump

ok "Metadata DB restaurée"

# ── Application des secrets K8s ───────────────────────────────────────────────
step "Application des secrets Kubernetes"
kubectl apply -f "${MIGRATION_DIR}/k8s-secret-airbyte.yaml"
kubectl apply -f "${MIGRATION_DIR}/k8s-secret-auth.yaml"
ok "Secrets K8s appliqués"

# ── Redémarrage server Airbyte ────────────────────────────────────────────────
step "Redémarrage du server Airbyte"
kubectl scale deployment airbyte-abctl-server -n airbyte-abctl --replicas=1
kubectl scale deployment airbyte-abctl-worker -n airbyte-abctl --replicas=1
kubectl scale deployment airbyte-abctl-workload-launcher -n airbyte-abctl --replicas=1 2>/dev/null || true
kubectl scale deployment airbyte-abctl-temporal -n airbyte-abctl --replicas=1 2>/dev/null || true

log "Attente server..."
for i in $(seq 1 20); do
  STATUS=$(kubectl get pods -n airbyte-abctl --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | grep -c "airbyte-abctl-server" || echo 0)
  [[ "${STATUS}" -ge 1 ]] && { ok "Server running"; break; }
  log "Check ${i}/20 — attente 15s..."; sleep 15
done

# ── Staging DB ────────────────────────────────────────────────────────────────
step "Démarrage staging PostgreSQL"
if ! docker ps --format '{{.Names}}' | grep -q "^${STAGING_CONTAINER}$"; then
  docker run -d \
    --name "${STAGING_CONTAINER}" \
    --restart unless-stopped \
    -e POSTGRES_USER="${STAGING_USER}" \
    -e POSTGRES_PASSWORD="${STAGING_PASSWORD}" \
    -e POSTGRES_DB="${STAGING_DB}" \
    -p "${STAGING_PORT}:5432" \
    -v "${STAGING_CONTAINER}-data:/var/lib/postgresql/data" \
    postgres:15-alpine
  sleep 5
  ok "${STAGING_CONTAINER} démarré"
else
  ok "${STAGING_CONTAINER} déjà running"
fi

log "Restauration staging dump..."
docker cp "${MIGRATION_DIR}/staging.dump" "${STAGING_CONTAINER}:/tmp/staging.dump"
docker exec "${STAGING_CONTAINER}" \
  pg_restore -U "${STAGING_USER}" -d "${STAGING_DB}" \
  --no-owner --clean --if-exists --exit-on-error \
  /tmp/staging.dump
ok "Staging DB restaurée"

# ── Connexion staging au réseau kind ──────────────────────────────────────────
step "Connexion staging-db au réseau kind"
docker network connect kind "${STAGING_CONTAINER}" 2>/dev/null || \
  docker network connect kind "${STAGING_CONTAINER}" || true

STAGING_KIND_IP=$(docker inspect "${STAGING_CONTAINER}" \
  --format '{{.NetworkSettings.Networks.kind.IPAddress}}' 2>/dev/null || echo "")
ok "IP staging-db sur réseau kind : ${STAGING_KIND_IP}"
mkdir -p /root/.airbyte
echo "STAGING_KIND_IP=${STAGING_KIND_IP}" > /root/.airbyte/staging-kind-ip.env

# ── Persistence reboot ────────────────────────────────────────────────────────
step "Configuration restart policies"
docker update --restart=unless-stopped airbyte-abctl-control-plane 2>/dev/null || true
docker update --restart=unless-stopped "${STAGING_CONTAINER}" 2>/dev/null || true
ok "restart=unless-stopped configuré"

# ── Résumé final ──────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         MIGRATION YESWESYNC TERMINÉE                    ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Airbyte :   http://localhost:${AIRBYTE_PORT}                     ║"
echo "║  staging-db IP kind : ${STAGING_KIND_IP}                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo
echo "  → Ouvrir Airbyte et vérifier les 40 connections"
echo "  → Vérifier la Destination PostgreSQL : mettre l'IP ${STAGING_KIND_IP}"
echo "  → Lancer un Sync now pour valider"
echo
echo "  Si l'IP kind du staging change après reboot :"
echo "  cat /root/.airbyte/staging-kind-ip.env"
echo "  → Mettre à jour la Destination dans Airbyte UI"
