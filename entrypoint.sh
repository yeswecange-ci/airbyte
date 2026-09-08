#!/usr/bin/env bash
# YesWeSync — démarrage et supervision (CMD du container Coolify)
#
# Rôle :
#   1. Relais réseau      → socat 0.0.0.0:PROXY_PORT → airbyte-abctl-control-plane:80
#                           (ingress-nginx Airbyte, via le réseau Docker "kind")
#                           C'est ce port que Coolify/Traefik route pour airbyte.ywcdigital.com.
#                           Le relais sert aussi à abctl, qui vérifie l'ingress via localhost:PORT.
#   2. Premier démarrage  → lance install.sh si Airbyte n'est pas installé
#   3. Après reboot       → redémarre kind + reconnecte staging-db au réseau kind
#   4. Toujours           → boucle de monitoring (kind running, relais à jour)
#
# Architecture réseau :
#   Traefik (réseau coolify) → ce container:8085 (socat)
#     → ce container est AUSSI connecté au réseau "kind" (docker network connect)
#     → airbyte-abctl-control-plane:80 = ingress-nginx = Airbyte
#   Pas de --network host (Traefik ne pourrait pas joindre le container).
#
# NE modifie PAS Airbyte.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGING_CONTAINER="${STAGING_CONTAINER_NAME:-yeswesync-staging-db}"
KIND_NODE="airbyte-abctl-control-plane"
PROXY_PORT="${PROXY_PORT:-8085}"

log()  { echo "[$(date '+%H:%M:%S')] [yeswesync] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] [yeswesync] ✓ $*"; }
warn() { echo "[$(date '+%H:%M:%S')] [yeswesync] ⚠ $*"; }

# ── Helpers ────────────────────────────────────────────────────────────────────
kind_running() {
  [[ -n "$(docker ps --filter "name=${KIND_NODE}" --format '{{.Names}}' | head -1)" ]]
}

kind_node_ip() {
  docker inspect "${KIND_NODE}" --format '{{.NetworkSettings.Networks.kind.IPAddress}}' 2>/dev/null || true
}

on_kind_network() {  # $1 = container
  docker inspect "$1" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'kind' in d else 1)" 2>/dev/null
}

# ID de CE container (le hostname Docker = ID court par défaut ; sinon via mountinfo)
self_container_id() {
  local h; h="$(hostname)"
  if docker inspect --format '{{.Id}}' "$h" 2>/dev/null; then return 0; fi
  grep -oE '/containers/[0-9a-f]{64}' /proc/self/mountinfo | head -1 | awk -F/ '{print $NF}'
}

# Connecte CE container au réseau kind pour pouvoir joindre l'ingress Airbyte.
join_kind_network() {
  docker network inspect kind > /dev/null 2>&1 || return 1
  local self; self="$(self_container_id)"
  [[ -n "${self}" ]] || { warn "ID du container introuvable — impossible de rejoindre le réseau kind"; return 1; }
  on_kind_network "${self}" && return 0
  docker network connect kind "${self}" 2>/dev/null \
    && ok "container relais connecté au réseau kind" \
    || { warn "connexion au réseau kind échouée"; return 1; }
}

# Relais socat (tourne en arrière-plan). Attend que kind soit créé avant d'écouter :
# abctl vérifie que PROXY_PORT est libre AVANT de créer le cluster (installation initiale).
PROXY_TARGET_FILE="/tmp/yeswesync-proxy-target"
proxy_loop() {
  while true; do
    if kind_running && join_kind_network; then
      local target; target="$(kind_node_ip)"
      if [[ -n "${target}" ]]; then
        echo "${target}" > "${PROXY_TARGET_FILE}"
        log "relais 0.0.0.0:${PROXY_PORT} → ${target}:80 (ingress Airbyte)"
        socat TCP-LISTEN:"${PROXY_PORT}",fork,reuseaddr TCP:"${target}":80 || true
        warn "relais arrêté — redémarrage dans 5s"
      fi
    fi
    sleep 5
  done
}

# ── Attendre Docker (peut prendre quelques secondes après démarrage container) ──
log "Attente de Docker..."
for i in $(seq 1 60); do
  docker info > /dev/null 2>&1 && break
  [[ $i -eq 60 ]] && { log "ERREUR : Docker non disponible après 60s (docker.sock monté ?)"; exit 1; }
  sleep 2
done
ok "Docker disponible"

# ── Démarrer le relais (en arrière-plan, s'active dès que kind existe) ─────────
proxy_loop &
PROXY_LOOP_PID=$!
trap 'kill "${PROXY_LOOP_PID}" 2>/dev/null; pkill socat 2>/dev/null; exit 0' TERM INT

# ── Vérification / installation du cluster kind ────────────────────────────────
if kind_running; then
  ok "Container kind running : ${KIND_NODE}"
else
  STOPPED=$(docker ps -a --filter "name=${KIND_NODE}" --format "{{.Names}}" | head -1 || echo "")
  if [[ -n "${STOPPED}" ]]; then
    log "Container kind arrêté (reboot ?) — redémarrage..."
    docker start "${STOPPED}"
    sleep 15
    ok "Container kind redémarré : ${STOPPED}"
  else
    log "Airbyte non installé — lancement de install.sh (5 à 15 min)..."
    bash "${SCRIPT_DIR}/install.sh"
    ok "install.sh terminé — Airbyte installé"
  fi
fi

# ── Reconnexion staging-db au réseau kind ─────────────────────────────────────
if docker network inspect kind > /dev/null 2>&1; then
  if on_kind_network "${STAGING_CONTAINER}"; then
    ok "staging-db déjà sur le réseau kind"
  else
    docker network connect kind "${STAGING_CONTAINER}" 2>/dev/null \
      && ok "staging-db reconnecté au réseau kind" \
      || warn "reconnexion staging-db échouée (peut-être pas encore créé)"
  fi

  STAGING_KIND_IP=$(docker inspect "${STAGING_CONTAINER}" \
    --format '{{.NetworkSettings.Networks.kind.IPAddress}}' 2>/dev/null || echo "")
  [[ -n "${STAGING_KIND_IP}" ]] && ok "IP staging-db (réseau kind) : ${STAGING_KIND_IP}" || true
  echo "STAGING_KIND_IP=${STAGING_KIND_IP}" > /root/.airbyte/staging-kind-ip.env 2>/dev/null || true
fi

# ── État Airbyte ───────────────────────────────────────────────────────────────
log "État Airbyte :"
abctl local status 2>&1 \
  | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -E "INFO|SUCCESS|ERROR|Chart|Status|Running|deployed|installed" \
  | while read -r line; do log "  ${line}"; done \
  || true

ok "Airbyte servi via le relais container:${PROXY_PORT} → ${KIND_NODE}:80"
log "  Coolify/Traefik route le domaine vers ce container, port ${PROXY_PORT}."
log ""

# ── Boucle de monitoring ───────────────────────────────────────────────────────
while true; do
  sleep 60
  if ! kind_running; then
    warn "Container kind non running — tentative de redémarrage..."
    docker start "${KIND_NODE}" 2>/dev/null \
      && log "Container kind redémarré" \
      || warn "Impossible de redémarrer kind — vérifier l'état Docker"
    continue
  fi
  # Si l'IP du nœud kind a changé (recréation), relancer socat sur la nouvelle cible
  CURRENT_IP="$(kind_node_ip)"
  PROXIED_IP="$(cat "${PROXY_TARGET_FILE}" 2>/dev/null || echo "")"
  if [[ -n "${CURRENT_IP}" && -n "${PROXIED_IP}" && "${CURRENT_IP}" != "${PROXIED_IP}" ]]; then
    warn "IP du nœud kind changée (${PROXIED_IP} → ${CURRENT_IP}) — redémarrage du relais"
    pkill -f "socat TCP-LISTEN:${PROXY_PORT}" 2>/dev/null || true
  fi
done
