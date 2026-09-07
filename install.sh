#!/usr/bin/env bash
# YesWeSync — Installation d'Airbyte 2.2.0 sur un Droplet DigitalOcean
#
# Ce script adapte NOTRE déploiement à Airbyte. Il ne modifie pas Airbyte.
# Il automatise exactement ce que l'on ferait manuellement :
#   1. Vérifications prérequis
#   2. Installation de abctl v0.30.4 (pinnée)
#   3. Démarrage du staging PostgreSQL
#   4. Installation d'Airbyte 2.2.0 via abctl
#   5. Configuration de la persistence (restart policy)
#   6. Connexion staging-db au réseau kind (pour que les Pods y accèdent)
#   7. Vérification finale
#
# IDEMPOTENT : peut être relancé sans danger sur une installation existante.
# AUCUN code Airbyte n'est modifié.
set -euo pipefail

# ── Variables (depuis l'environnement ou .env) ────────────────────────────────
if [[ -f "$(dirname "$0")/.env" ]]; then
  set -a; source "$(dirname "$0")/.env"; set +a
fi

ABCTL_VERSION="${ABCTL_VERSION:-0.30.4}"
AIRBYTE_CHART_VERSION="${AIRBYTE_VERSION:-2.2.0}"
AIRBYTE_PORT="${AIRBYTE_PORT:-8085}"
AIRBYTE_URL="${AIRBYTE_URL:-http://localhost:${AIRBYTE_PORT}}"
STAGING_CONTAINER="${STAGING_CONTAINER_NAME:-yeswesync-staging-db}"
STAGING_USER="${STAGING_USER:?Variable STAGING_USER obligatoire}"
STAGING_PASSWORD="${STAGING_PASSWORD:?Variable STAGING_PASSWORD obligatoire}"
STAGING_DB="${STAGING_DB:-yeswesync_staging}"
STAGING_HOST_PORT="${STAGING_PORT:-5433}"
AIRBYTE_DATA_DIR="${AIRBYTE_DATA_DIR:-/root/.airbyte}"
VALUES_FILE="$(dirname "$0")/values.yaml"

log()  { echo "[$(date '+%H:%M:%S')] [yeswesync] $*"; }
fail() { echo "[$(date '+%H:%M:%S')] [yeswesync] ERREUR : $*" >&2; exit 1; }
ok()   { echo "[$(date '+%H:%M:%S')] [yeswesync] ✓ $*"; }

log "=== YesWeSync install.sh — Airbyte ${AIRBYTE_CHART_VERSION} + abctl ${ABCTL_VERSION} ==="

# ── 1. Vérifications système ──────────────────────────────────────────────────
log "Vérification du système..."

[[ "$(uname -s)" == "Linux" ]] || fail "Ce script cible Linux (Droplet DigitalOcean). OS détecté : $(uname -s)"

# RAM disponible
TOTAL_RAM_GB=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)
if (( TOTAL_RAM_GB < 7 )); then
  log "AVERTISSEMENT : ${TOTAL_RAM_GB} Go RAM détectés. Minimum recommandé : 8 Go."
  log "Utiliser ABCTL_EXTRA_FLAGS=--low-resource-mode si nécessaire."
else
  ok "RAM : ${TOTAL_RAM_GB} Go"
fi

# Docker
docker info > /dev/null 2>&1 || fail "Docker n'est pas disponible. Installer Docker : https://docs.docker.com/engine/install/ubuntu/"
DOCKER_VERSION=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
ok "Docker ${DOCKER_VERSION}"

# ── 2. Installation de abctl (version pinnée) ─────────────────────────────────
INSTALLED_ABCTL_VERSION=$(abctl version 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || echo "")

if [[ "${INSTALLED_ABCTL_VERSION}" == "v${ABCTL_VERSION}" ]]; then
  ok "abctl ${ABCTL_VERSION} déjà installé"
else
  log "Installation de abctl v${ABCTL_VERSION}..."
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  ABCTL_ARCH="amd64" ;;
    aarch64) ABCTL_ARCH="arm64" ;;
    *)       fail "Architecture non supportée : $ARCH" ;;
  esac

  TMP_DIR=$(mktemp -d)
  curl -fsSL \
    "https://github.com/airbytehq/abctl/releases/download/v${ABCTL_VERSION}/abctl_${ABCTL_VERSION}_linux_${ABCTL_ARCH}.tar.gz" \
    | tar -xzC "${TMP_DIR}" abctl
  install -m 755 "${TMP_DIR}/abctl" /usr/local/bin/abctl
  rm -rf "${TMP_DIR}"
  ok "abctl v${ABCTL_VERSION} installé"
fi

# ── 3. Démarrage du staging PostgreSQL ───────────────────────────────────────
log "Vérification du container staging PostgreSQL..."

if docker inspect "${STAGING_CONTAINER}" > /dev/null 2>&1; then
  STAGING_STATUS=$(docker inspect "${STAGING_CONTAINER}" --format '{{.State.Status}}')
  if [[ "${STAGING_STATUS}" != "running" ]]; then
    log "Container staging existant mais arrêté — redémarrage..."
    docker start "${STAGING_CONTAINER}"
  fi
  ok "Container staging-db déjà présent (status: ${STAGING_STATUS})"
else
  log "Création du container staging PostgreSQL..."
  docker run -d \
    --name "${STAGING_CONTAINER}" \
    --restart unless-stopped \
    -e POSTGRES_USER="${STAGING_USER}" \
    -e POSTGRES_PASSWORD="${STAGING_PASSWORD}" \
    -e POSTGRES_DB="${STAGING_DB}" \
    -p "127.0.0.1:${STAGING_HOST_PORT}:5432" \
    -v "yeswesync-staging-db-data:/var/lib/postgresql/data" \
    postgres:15-alpine
  ok "Container staging-db créé"
fi

# Attendre que PostgreSQL soit prêt
log "Attente readiness staging-db..."
for i in $(seq 1 30); do
  if docker exec "${STAGING_CONTAINER}" pg_isready -U "${STAGING_USER}" -d "${STAGING_DB}" > /dev/null 2>&1; then
    ok "staging-db prêt"
    break
  fi
  [[ $i -eq 30 ]] && fail "staging-db n'est pas prêt après 30s"
  sleep 1
done

# ── 4. Génération du fichier values Helm ─────────────────────────────────────
log "Génération de values.yaml..."
cat > "${VALUES_FILE}" <<YAML
# YesWeSync — values Helm pour abctl / Airbyte 2.2.0
# Généré par install.sh. Vérifier avant modification.
global:
  airbyteUrl: "${AIRBYTE_URL}"
  auth:
    enabled: true
  env_vars:
    AIRBYTE_INSTALLATION_ID: "${AIRBYTE_INSTALLATION_ID:-}"
  jobs:
    resources:
      limits:
        cpu: "${AIRBYTE_JOB_CPU_LIMIT:-3}"
        memory: "${AIRBYTE_JOB_MEMORY_LIMIT:-4Gi}"
  storage:
    type: local
airbyte-bootloader:
  env_vars:
    PLATFORM_LOG_FORMAT: "json"
postgresql:
  image:
    tag: "1.7.0-17"
server:
  env_vars:
    WEBAPP_URL: "${AIRBYTE_URL}"
YAML
ok "values.yaml généré"

# Fichier secrets optionnel
if [[ -n "${AIRBYTE_INITIAL_USER_PASSWORD:-}" ]]; then
  cat > "$(dirname "$0")/secrets.yaml" <<YAML
global:
  auth:
    instanceAdmin:
      password: "${AIRBYTE_INITIAL_USER_PASSWORD}"
YAML
  SECRET_FLAG="--secret $(dirname "$0")/secrets.yaml"
  ok "secrets.yaml généré"
else
  SECRET_FLAG=""
  log "AIRBYTE_INITIAL_USER_PASSWORD non défini — mot de passe admin auto-généré par Airbyte"
fi

# ── 5. Installation ou mise à jour d'Airbyte via abctl ───────────────────────
if abctl local status 2>/dev/null | grep -q "deployed"; then
  log "Installation Airbyte existante détectée — mise à jour des valeurs..."
  ABCTL_ACTION="update"
else
  log "Nouvelle installation Airbyte 2.2.0..."
  ABCTL_ACTION="fresh"
fi

abctl local install \
  --chart-version "${AIRBYTE_CHART_VERSION}" \
  --port "${AIRBYTE_PORT}" \
  --no-browser \
  --values "${VALUES_FILE}" \
  ${SECRET_FLAG} \
  ${ABCTL_EXTRA_FLAGS:-}

ok "Airbyte ${AIRBYTE_CHART_VERSION} installé (${ABCTL_ACTION})"

# ── 6. Persistence : changer la restart policy du container kind ──────────────
log "Configuration restart policy du nœud kind..."
KIND_CONTAINER=$(docker ps --filter "name=airbyte-abctl-control-plane" --format "{{.Names}}" | head -1)
if [[ -n "${KIND_CONTAINER}" ]]; then
  docker update --restart=unless-stopped "${KIND_CONTAINER}"
  ok "Restart policy du container kind : unless-stopped"
else
  log "AVERTISSEMENT : container kind non trouvé — restart policy non modifiée"
fi

# ── 7. Réseau : connecter staging-db au réseau kind ──────────────────────────
# CRITIQUE : les Pods Kubernetes dans kind ne peuvent pas résoudre
# les hostnames Docker des autres réseaux. La seule méthode prouvée est
# de connecter staging-db directement au réseau "kind".
# Après connexion, staging-db obtient une IP sur 172.19.0.0/16,
# accessible depuis les Pods via le routage du nœud kind.
log "Connexion de staging-db au réseau kind..."
if docker network inspect kind > /dev/null 2>&1; then
  # Connecter seulement si pas déjà connecté
  ALREADY_CONNECTED=$(docker inspect "${STAGING_CONTAINER}" \
    --format '{{json .NetworkSettings.Networks}}' 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'kind' in d else 'no')" 2>/dev/null || echo "no")

  if [[ "${ALREADY_CONNECTED}" == "yes" ]]; then
    ok "staging-db déjà connecté au réseau kind"
  else
    docker network connect kind "${STAGING_CONTAINER}"
    ok "staging-db connecté au réseau kind"
  fi

  STAGING_KIND_IP=$(docker inspect "${STAGING_CONTAINER}" \
    --format '{{.NetworkSettings.Networks.kind.IPAddress}}' 2>/dev/null)
  ok "IP staging-db sur le réseau kind : ${STAGING_KIND_IP}"
  log ""
  log "  ┌─────────────────────────────────────────────────────────────────"
  log "  │  ADRESSE À UTILISER DANS AIRBYTE (Destination PostgreSQL) :"
  log "  │  Host : ${STAGING_KIND_IP}"
  log "  │  Port : 5432"
  log "  │  User : ${STAGING_USER}"
  log "  │  DB   : ${STAGING_DB}"
  log "  └─────────────────────────────────────────────────────────────────"
  log ""
  # Sauvegarder dans un fichier pour le script de reboot
  echo "STAGING_KIND_IP=${STAGING_KIND_IP}" > "${AIRBYTE_DATA_DIR}/staging-kind-ip.env"
else
  log "AVERTISSEMENT : réseau kind non trouvé. Relancer install.sh après que abctl ait créé le réseau."
fi

# ── 8. Service systemd pour survivre au reboot ───────────────────────────────
log "Installation du service systemd pour la persistance au reboot..."
cat > /etc/systemd/system/yeswesync-reboot.service <<'SYSTEMD'
[Unit]
Description=YesWeSync — reconnexion réseau staging-db après reboot
After=docker.service network-online.target
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/yeswesync-reboot.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SYSTEMD

cat > /usr/local/bin/yeswesync-reboot.sh <<'REBOOT_SCRIPT'
#!/usr/bin/env bash
# Appelé par systemd après chaque reboot pour reconnecter staging-db au réseau kind.
# Pas de réinstallation Airbyte — le container kind redémarre automatiquement (unless-stopped).
set -euo pipefail
log() { echo "[yeswesync-reboot] $*"; }

STAGING_CONTAINER="${STAGING_CONTAINER_NAME:-yeswesync-staging-db}"

# Attendre que Docker soit prêt
for i in $(seq 1 30); do
  docker info > /dev/null 2>&1 && break
  [[ $i -eq 30 ]] && { log "Docker non disponible après 30s"; exit 1; }
  sleep 2
done

# Attendre que le container kind soit démarré
KIND_CONTAINER=$(docker ps --filter "name=airbyte-abctl-control-plane" --format "{{.Names}}" | head -1 || echo "")
for i in $(seq 1 60); do
  KIND_CONTAINER=$(docker ps --filter "name=airbyte-abctl-control-plane" --format "{{.Names}}" | head -1 || echo "")
  [[ -n "${KIND_CONTAINER}" ]] && break
  [[ $i -eq 60 ]] && { log "Container kind non trouvé après 60s. Airbyte n'a peut-être pas démarré."; exit 0; }
  sleep 2
done
log "Container kind détecté : ${KIND_CONTAINER}"

# Reconnecter staging-db au réseau kind (la connexion ne persiste pas après reboot du container)
if docker network inspect kind > /dev/null 2>&1; then
  ALREADY_CONNECTED=$(docker inspect "${STAGING_CONTAINER}" \
    --format '{{json .NetworkSettings.Networks}}' 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'kind' in d else 'no')" 2>/dev/null || echo "no")

  if [[ "${ALREADY_CONNECTED}" == "no" ]]; then
    docker network connect kind "${STAGING_CONTAINER}" && log "staging-db reconnecté au réseau kind"
  else
    log "staging-db déjà connecté au réseau kind"
  fi

  NEW_IP=$(docker inspect "${STAGING_CONTAINER}" \
    --format '{{.NetworkSettings.Networks.kind.IPAddress}}' 2>/dev/null || echo "")
  [[ -n "${NEW_IP}" ]] && echo "STAGING_KIND_IP=${NEW_IP}" > /root/.airbyte/staging-kind-ip.env
  log "IP staging-db sur réseau kind : ${NEW_IP}"
  log "IMPORTANT : si l'IP a changé depuis la dernière installation, mettre à jour"
  log "la Destination PostgreSQL dans Airbyte avec la nouvelle IP : ${NEW_IP}"
fi
REBOOT_SCRIPT

chmod +x /usr/local/bin/yeswesync-reboot.sh
systemctl daemon-reload
systemctl enable yeswesync-reboot.service
ok "Service systemd yeswesync-reboot installé et activé"

# ── 9. Résumé ─────────────────────────────────────────────────────────────────
log ""
log "════════════════════════════════════════════════════"
log "  INSTALLATION TERMINÉE"
log "════════════════════════════════════════════════════"
log ""
log "  Airbyte ${AIRBYTE_CHART_VERSION} : http://localhost:${AIRBYTE_PORT}"
log "  abctl status   : abctl local status"
log "  Logs server    : KUBECONFIG=~/.airbyte/abctl/abctl.kubeconfig kubectl logs -n airbyte-abctl deployment/airbyte-abctl-server -f"
log ""
log "  staging-db :"
FINAL_KIND_IP=$(docker inspect "${STAGING_CONTAINER}" \
  --format '{{.NetworkSettings.Networks.kind.IPAddress}}' 2>/dev/null || echo "IP non disponible")
log "    IP réseau kind : ${FINAL_KIND_IP}"
log "    Port (hôte)    : localhost:${STAGING_HOST_PORT}"
log "    User / DB      : ${STAGING_USER} / ${STAGING_DB}"
log ""
log "  Dans Airbyte (Destination PostgreSQL) :"
log "    Host     : ${FINAL_KIND_IP}"
log "    Port     : 5432"
log "    Database : ${STAGING_DB}"
log "    User     : ${STAGING_USER}"
log ""
log "  Dans YesWeReport :"
log "    AIRBYTE_STAGING_DATABASE_URL=postgresql://${STAGING_USER}:<PASSWORD>@localhost:${STAGING_HOST_PORT}/${STAGING_DB}"
log ""
log "  IMPORTANT après reboot :"
log "    L'IP kind de staging-db peut changer. Vérifier avec :"
log "    docker inspect ${STAGING_CONTAINER} --format '{{.NetworkSettings.Networks.kind.IPAddress}}'"
log "    Et mettre à jour la Destination dans Airbyte si nécessaire."
log ""
