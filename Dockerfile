# YesWeSync — couche de déploiement autour d'Airbyte 2.2.0 / abctl
#
# Ce Dockerfile adapte NOTRE déploiement à Airbyte, pas l'inverse.
# Il installe abctl (le gestionnaire officiel Airbyte) et notre entrypoint.
#
# AUCUN code Airbyte n'est modifié — seul abctl est installé pour
# lancer Airbyte 2.2.0 via sa méthode officielle (kind + Helm).
#
# AIRBYTE SOURCE CODE MODIFIED:    NO
# AIRBYTE FRONTEND MODIFIED:       NO
# AIRBYTE BACKEND MODIFIED:        NO
# AIRBYTE BUNDLE PATCHED:          NO
# AIRBYTE ENGINE MODIFIED:         NO
#
# Prérequis Coolify :
#   - Container en mode privilégié (kind nécessite cgroups)
#   - Volume /root/.airbyte → stockage persistant DigitalOcean
#   - Bind mount /var/run/docker.sock

FROM ubuntu:22.04

# Évite les interactions pendant l'installation apt
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

# abctl v0.30.4 — version exacte de notre installation locale
# Ne pas mettre "latest" — la version est liée au Helm chart 2.2.0
ARG ABCTL_VERSION=0.30.4
ARG TARGETARCH=amd64

RUN curl -fsSL \
    "https://github.com/airbytehq/abctl/releases/download/v${ABCTL_VERSION}/abctl_${ABCTL_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xzC /usr/local/bin abctl \
    && chmod +x /usr/local/bin/abctl \
    && abctl version

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Répertoire de données abctl — doit être monté sur un volume persistant
VOLUME ["/root/.airbyte"]

# Ce container ne sert pas lui-même de port HTTP.
# Airbyte est exposé par le container kind sur l'hôte (port AIRBYTE_PORT).
# Coolify reverse proxy → localhost:AIRBYTE_PORT sur l'hôte.

ENTRYPOINT ["/entrypoint.sh"]
