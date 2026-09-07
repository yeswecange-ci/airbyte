#!/usr/bin/env bash
# YesWeSync / Airbyte 2.2.0 — startup entrypoint
# Validates required environment variables, then hands off to the
# official Airbyte server process. No Airbyte logic is reimplemented here.
set -euo pipefail

log() { echo "[yeswesync] $*"; }

# ── Required variable validation ───────────────────────────────────────────────
REQUIRED_VARS=(
  DATABASE_USER
  DATABASE_PASSWORD
  DATABASE_DB
  DATABASE_HOST
  SECRET_PERSISTENCE
)

missing=0
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    log "ERROR: required variable $var is not set"
    missing=1
  fi
done
[[ $missing -eq 1 ]] && { log "Aborting: missing required variables."; exit 1; }

# ── Derived DATABASE_URL if not explicitly set ─────────────────────────────────
export DATABASE_URL="${DATABASE_URL:-jdbc:postgresql://${DATABASE_HOST}:${DATABASE_PORT:-5432}/${DATABASE_DB}}"
log "DATABASE_URL=${DATABASE_URL}"

log "Environment OK — starting Airbyte server 2.2.0"

# ── Hand off to the official Airbyte server entrypoint ────────────────────────
# The airbyte/server image sets ENTRYPOINT ["/bin/bash", "-c"] and
# CMD ["start-process.sh"]. We exec it directly.
exec /bin/bash /start-process.sh
