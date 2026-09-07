# YesWeSync — image utilitaire de déploiement (optionnelle)
#
# Ce Dockerfile produit une image contenant abctl et nos scripts.
# Il NE remplace PAS le runtime Airbyte.
#
# Airbyte 2.2.0 tourne via abctl → kind → Kubernetes DIRECTEMENT SUR LE DROPLET.
# Ce n'est pas un container Airbyte. C'est un outil d'installation/vérification.
#
# Usage possible (optionnel — voir DEPLOYMENT.md section "Déploiement direct") :
#
#   docker build -t yeswesync-tools .
#   docker run --rm \
#     --pid=host --network=host --privileged \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v /root/.airbyte:/root/.airbyte \
#     -e STAGING_USER=... \
#     -e STAGING_PASSWORD=... \
#     -e AIRBYTE_URL=... \
#     yeswesync-tools ./install.sh
#
# AIRBYTE SOURCE CODE MODIFIED:    NO
# AIRBYTE FRONTEND MODIFIED:       NO
# AIRBYTE BACKEND MODIFIED:        NO
# AIRBYTE BUNDLE PATCHED:          NO
# AIRBYTE ENGINE MODIFIED:         NO

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl ca-certificates python3 util-linux \
    && rm -rf /var/lib/apt/lists/*

# abctl v0.30.4 — version utilisée et validée avec Airbyte 2.2.0
ARG ABCTL_VERSION=0.30.4
ARG TARGETARCH=amd64

RUN curl -fsSL \
    "https://github.com/airbytehq/abctl/releases/download/v${ABCTL_VERSION}/abctl_${ABCTL_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xzC /usr/local/bin abctl \
    && chmod +x /usr/local/bin/abctl

WORKDIR /yeswesync
COPY install.sh    ./install.sh
COPY entrypoint.sh ./entrypoint.sh
RUN chmod +x install.sh entrypoint.sh

# Ce container ne sert pas de port HTTP.
# Airbyte est exposé par le container kind sur l'hôte (port AIRBYTE_PORT).
ENTRYPOINT ["/bin/bash"]
CMD ["./entrypoint.sh"]
