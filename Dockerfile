# YesWeSync — image utilitaire de déploiement
#
# Ce container installe abctl puis Airbyte via :
#   abctl local install --port 8085 --no-browser
#
# Il NE modifie PAS Airbyte. Airbyte tourne via abctl → kind → Kubernetes.
#
# Rôle réseau : le container sert de relais pour Coolify/Traefik.
#   Traefik (réseau "coolify") → ce container :8085 (socat)
#     → airbyte-abctl-control-plane:80 (réseau "kind" = ingress-nginx Airbyte)
#   Le container se connecte lui-même au réseau kind (docker network connect).
#   PAS de --network host : Traefik ne peut pas joindre un container hors du
#   réseau "coolify" (→ Bad Gateway).
#
# Configuration Coolify (Dockerfile build pack) :
#   Ports Exposes        : 8085
#   Storages (bind)      : /var/run/docker.sock → /var/run/docker.sock
#                          /root/.airbyte       → /root/.airbyte
#   Custom Docker Options: (aucune — surtout pas --network host)
#   Env                  : AIRBYTE_URL, AIRBYTE_INITIAL_USER_PASSWORD,
#                          STAGING_USER, STAGING_PASSWORD
#
# Usage docker run équivalent :
#   docker run -d -p 8085:8085 \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v /root/.airbyte:/root/.airbyte \
#     -e AIRBYTE_INITIAL_USER_PASSWORD=... -e STAGING_PASSWORD=... -e STAGING_USER=... \
#     yeswesync-tools
#
# AIRBYTE SOURCE CODE MODIFIED: NO
# AIRBYTE FRONTEND MODIFIED:    NO
# AIRBYTE BACKEND MODIFIED:     NO

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl ca-certificates python3 util-linux procps socat \
    && rm -rf /var/lib/apt/lists/*

# CLI docker (binaire statique, sans daemon) : requis par entrypoint.sh / install.sh
# pour piloter le Docker de l'hôte via /var/run/docker.sock.
ARG DOCKER_CLI_VERSION=27.5.1
RUN ARCH=$(uname -m) \
    && curl -fsSL "https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" \
       | tar -xz -C /usr/local/bin --strip-components=1 docker/docker \
    && docker --version

# Install abctl v0.30.4 via the official Airbyte installer script.
# RELEASE_TAG pins the version. TELEMETRY_ENABLED=0 suppresses analytics.
ARG ABCTL_VERSION=v0.30.4
RUN curl -LsfS https://get.airbyte.com -o /tmp/abctl-install.sh \
    && RELEASE_TAG=${ABCTL_VERSION} TELEMETRY_ENABLED=0 bash /tmp/abctl-install.sh \
    && rm /tmp/abctl-install.sh

WORKDIR /yeswesync
COPY install.sh    ./install.sh
COPY entrypoint.sh ./entrypoint.sh
RUN chmod +x install.sh entrypoint.sh

# Port du relais socat vers l'ingress Airbyte (cible du routage Coolify/Traefik).
ENV PROXY_PORT=8085
EXPOSE 8085

ENTRYPOINT ["/bin/bash"]
CMD ["./entrypoint.sh"]
