#!/usr/bin/env bash
# YesWeSync — abctl bootstrap entrypoint
#
# Adapte NOTRE déploiement à Airbyte 2.2.0 / abctl.
# N'implémente PAS la logique d'Airbyte — appelle abctl officiellement.
#
# Prérequis dans le container Coolify :
#   - /var/run/docker.sock monté (accès au Docker de l'hôte)
#   - container en mode privilégié (kind nécessite cgroups)
#   - volume persistant monté sur /root/.airbyte

set -euo pipefail

log()  { echo "[yeswesync] $*"; }
fail() { echo "[yeswesync] ERROR: $*" >&2; exit 1; }

# ── Validation des variables obligatoires ─────────────────────────────────────
for var in AIRBYTE_URL AIRBYTE_PORT; do
  [[ -z "${!var:-}" ]] && fail "Variable obligatoire manquante : $var"
done

# ── Validation Docker socket ───────────────────────────────────────────────────
[[ -S /var/run/docker.sock ]] || fail "/var/run/docker.sock absent. Monter le socket Docker de l'hôte."

log "Socket Docker OK"
docker info --format '{{.ServerVersion}}' 2>/dev/null | xargs -I{} log "Docker engine hôte : v{}" || fail "Impossible de contacter le Docker daemon"

# ── Génération du fichier values Helm pour abctl ──────────────────────────────
mkdir -p /tmp/yeswesync
cat > /tmp/yeswesync/values.yaml <<YAML
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
postgresql:
  image:
    tag: "1.7.0-17"
server:
  env_vars:
    WEBAPP_URL: "${AIRBYTE_URL}"
YAML

log "values.yaml généré : /tmp/yeswesync/values.yaml"

# ── Fichier de secrets optionnel ──────────────────────────────────────────────
# Si AIRBYTE_INITIAL_USER_PASSWORD est défini, on le passe en secret
if [[ -n "${AIRBYTE_INITIAL_USER_PASSWORD:-}" ]]; then
  cat > /tmp/yeswesync/secrets.yaml <<YAML
global:
  auth:
    instanceAdmin:
      password: "${AIRBYTE_INITIAL_USER_PASSWORD}"
YAML
  SECRET_FLAG="--secret /tmp/yeswesync/secrets.yaml"
  log "Secrets Airbyte configurés"
else
  SECRET_FLAG=""
  log "Aucun secret utilisateur configuré (AIRBYTE_INITIAL_USER_PASSWORD non défini)"
fi

# ── Montage du répertoire de données persistant ───────────────────────────────
# abctl stocke ses données dans ~/.airbyte/abctl/data/
# Ce répertoire doit être sur un volume persistant
if mountpoint -q /root/.airbyte 2>/dev/null || [[ -d /root/.airbyte ]]; then
  log "Répertoire ~/.airbyte disponible"
else
  log "Avertissement : /root/.airbyte n'est pas un point de montage — les données ne persisteront pas"
fi

# ── Vérification si Airbyte est déjà installé ─────────────────────────────────
if abctl local status 2>/dev/null | grep -q "deployed"; then
  log "Cluster Airbyte existant détecté — vérification de l'état"
  abctl local status 2>&1 | grep -E "INFO|SUCCESS|ERROR" | sed 's/\x1b\[[0-9;]*m//g' | while read -r line; do log "$line"; done
  log "Airbyte déjà déployé. Démarrage du monitoring."
else
  log "Installation d'Airbyte 2.2.0 via abctl..."
  abctl local install \
    --chart-version 2.2.0 \
    --port "${AIRBYTE_PORT:-8085}" \
    --no-browser \
    --values /tmp/yeswesync/values.yaml \
    ${SECRET_FLAG} \
    ${ABCTL_EXTRA_FLAGS:-} \
    2>&1 | sed 's/\x1b\[[0-9;]*m//g' | while read -r line; do log "$line"; done

  log "Installation terminée. Airbyte accessible sur le port ${AIRBYTE_PORT:-8085} de l'hôte."
fi

# ── Boucle de monitoring (garde le container actif) ───────────────────────────
log "Monitoring Airbyte en cours (intervalle : 60s)..."
while true; do
  sleep 60
  if ! abctl local status 2>/dev/null | grep -q "deployed"; then
    log "AVERTISSEMENT : Airbyte ne répond plus — tentative de restauration..."
    abctl local install \
      --chart-version 2.2.0 \
      --port "${AIRBYTE_PORT:-8085}" \
      --no-browser \
      --values /tmp/yeswesync/values.yaml \
      ${SECRET_FLAG} \
      ${ABCTL_EXTRA_FLAGS:-} \
      2>&1 | sed 's/\x1b\[[0-9;]*m//g' | while read -r line; do log "$line"; done
  fi
done
