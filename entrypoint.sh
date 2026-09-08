#!/usr/bin/env bash
# YesWeSync — démarrage et supervision (CMD du container Coolify)
#
# Rôle :
#   1. Premier démarrage  → lance install.sh si Airbyte n'est pas installé
#   2. Après reboot       → redémarre kind + reconnecte staging-db au réseau kind
#   3. Toujours           → reste vivant en boucle de monitoring pour que
#                           Coolify/Traefik route airbyte.ywcdigital.com → port 8085
#
# Architecture mémoire :
#   container (--network host) → partage le réseau de l'hôte
#   → kind expose Airbyte sur hôte:8085
#   → container "port 8085" = hôte:8085 = Airbyte
#   → Coolify/Traefik route vers ce port sans proxy supplémentaire
#
# NE modifie PAS Airbyte.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGING_CONTAINER="${STAGING_CONTAINER_NAME:-yeswesync-staging-db}"

log()  { echo "[$(date '+%H:%M:%S')] [yeswesync] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] [yeswesync] ✓ $*"; }
warn() { echo "[$(date '+%H:%M:%S')] [yeswesync] ⚠ $*"; }

# ── Attendre Docker (peut prendre quelques secondes après démarrage container) ──
log "Attente de Docker..."
for i in $(seq 1 60); do
  docker info > /dev/null 2>&1 && break
  [[ $i -eq 60 ]] && { log "ERREUR : Docker non disponible après 60s"; exit 1; }
  sleep 2
done
ok "Docker disponible"

# ── Vérification / installation du cluster kind ────────────────────────────────
KIND_CONTAINER=$(docker ps --filter "name=airbyte-abctl-control-plane" --format "{{.Names}}" | head -1 || echo "")

if [[ -z "${KIND_CONTAINER}" ]]; then
  STOPPED=$(docker ps -a --filter "name=airbyte-abctl-control-plane" --format "{{.Names}}" | head -1 || echo "")
  if [[ -n "${STOPPED}" ]]; then
    log "Container kind arrêté (reboot ?) — redémarrage..."
    docker start "${STOPPED}"
    sleep 15
    ok "Container kind redémarré : ${STOPPED}"
  else
    log "Airbyte non installé — lancement de install.sh..."
    bash "${SCRIPT_DIR}/install.sh"
    ok "install.sh terminé — Airbyte installé"
  fi
else
  ok "Container kind running : ${KIND_CONTAINER}"
fi

# ── Reconnexion staging-db au réseau kind ─────────────────────────────────────
if docker network inspect kind > /dev/null 2>&1; then
  ALREADY=$(docker inspect "${STAGING_CONTAINER}" \
    --format '{{json .NetworkSettings.Networks}}' 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'kind' in d else 'no')" 2>/dev/null \
    || echo "no")

  if [[ "${ALREADY}" == "no" ]]; then
    docker network connect kind "${STAGING_CONTAINER}" 2>/dev/null \
      && ok "staging-db reconnecté au réseau kind" \
      || warn "reconnexion staging-db échouée (peut-être pas encore créé)"
  else
    ok "staging-db déjà sur le réseau kind"
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

ok "Airbyte accessible sur port 8085 (via kind → hôte)"
log ""
log "  Le container reste actif — Coolify/Traefik route le domaine vers le port 8085."
log "  (container --network host → port 8085 container = port 8085 hôte = Airbyte)"
log ""

# ── Boucle de monitoring — garde le container vivant pour Coolify/Traefik ──────
while true; do
  sleep 60
  KIND_RUNNING=$(docker ps --filter "name=airbyte-abctl-control-plane" --format "{{.Names}}" | head -1 || echo "")
  if [[ -z "${KIND_RUNNING}" ]]; then
    warn "Container kind non running — tentative de redémarrage..."
    docker start airbyte-abctl-control-plane 2>/dev/null \
      && log "Container kind redémarré" \
      || warn "Impossible de redémarrer kind — vérifier l'état Docker"
  fi
done
