#!/usr/bin/env bash
# YesWeSync — vérification et démarrage post-reboot
#
# Rôle : appelable manuellement ou via systemd pour vérifier que
# l'installation Airbyte est opérationnelle et la réparer si nécessaire.
# NE réinstalle PAS Airbyte si le cluster kind est déjà running.
# NE modifie PAS Airbyte.
set -euo pipefail

log()  { echo "[$(date '+%H:%M:%S')] [yeswesync] $*"; }
fail() { echo "[$(date '+%H:%M:%S')] [yeswesync] ERREUR : $*" >&2; exit 1; }
ok()   { echo "[$(date '+%H:%M:%S')] [yeswesync] ✓ $*"; }

STAGING_CONTAINER="${STAGING_CONTAINER_NAME:-yeswesync-staging-db}"

# ── Vérification Docker ────────────────────────────────────────────────────────
docker info > /dev/null 2>&1 || fail "Docker non disponible"
ok "Docker disponible"

# ── Vérification container kind (nœud Kubernetes Airbyte) ────────────────────
KIND_CONTAINER=$(docker ps --filter "name=airbyte-abctl-control-plane" --format "{{.Names}}" | head -1 || echo "")
if [[ -z "${KIND_CONTAINER}" ]]; then
  log "Container kind non running. Vérification s'il est arrêté..."
  STOPPED=$(docker ps -a --filter "name=airbyte-abctl-control-plane" --format "{{.Names}}" | head -1 || echo "")
  if [[ -n "${STOPPED}" ]]; then
    log "Container kind arrêté — démarrage..."
    docker start "${STOPPED}"
    sleep 10
    ok "Container kind redémarré : ${STOPPED}"
  else
    log "AVERTISSEMENT : container kind introuvable. Airbyte n'est peut-être pas installé."
    log "Lancer install.sh pour effectuer l'installation initiale."
    exit 0
  fi
else
  ok "Container kind running : ${KIND_CONTAINER}"
fi

# ── Vérification staging-db ────────────────────────────────────────────────────
STAGING_STATUS=$(docker inspect "${STAGING_CONTAINER}" --format '{{.State.Status}}' 2>/dev/null || echo "absent")
if [[ "${STAGING_STATUS}" != "running" ]]; then
  log "staging-db non running (status: ${STAGING_STATUS}) — démarrage..."
  docker start "${STAGING_CONTAINER}" 2>/dev/null || log "AVERTISSEMENT : impossible de démarrer staging-db"
else
  ok "staging-db running"
fi

# ── Reconnexion staging-db au réseau kind ─────────────────────────────────────
if docker network inspect kind > /dev/null 2>&1; then
  ALREADY=$(docker inspect "${STAGING_CONTAINER}" \
    --format '{{json .NetworkSettings.Networks}}' 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'kind' in d else 'no')" 2>/dev/null || echo "no")

  if [[ "${ALREADY}" == "no" ]]; then
    docker network connect kind "${STAGING_CONTAINER}" && ok "staging-db reconnecté au réseau kind"
  else
    ok "staging-db déjà sur le réseau kind"
  fi

  STAGING_KIND_IP=$(docker inspect "${STAGING_CONTAINER}" \
    --format '{{.NetworkSettings.Networks.kind.IPAddress}}' 2>/dev/null || echo "")
  ok "IP staging-db (réseau kind) : ${STAGING_KIND_IP}"
  echo "STAGING_KIND_IP=${STAGING_KIND_IP}" > /root/.airbyte/staging-kind-ip.env 2>/dev/null || true
fi

# ── Vérification Airbyte via abctl ────────────────────────────────────────────
log "Vérification de l'état Airbyte..."
abctl local status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "INFO|SUCCESS|ERROR|Chart|Status" | while read -r line; do
  log "  ${line}"
done

log "Vérification terminée."
