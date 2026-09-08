# YesWeSync — image utilitaire de déploiement
#
# Ce container installe abctl puis Airbyte via :
#   abctl local install --port 8085 --no-browser
#
# Il NE modifie PAS Airbyte. Airbyte tourne via abctl → kind → Kubernetes.
#
# Usage Coolify / docker run :
#   docker run --rm \
#     --network host --privileged \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v /root/.airbyte:/root/.airbyte \
#     -e AIRBYTE_INITIAL_USER_PASSWORD=... \
#     -e STAGING_PASSWORD=... \
#     yeswesync-tools ./install.sh
#
# AIRBYTE SOURCE CODE MODIFIED: NO
# AIRBYTE FRONTEND MODIFIED:    NO
# AIRBYTE BACKEND MODIFIED:     NO

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl ca-certificates python3 util-linux \
    && rm -rf /var/lib/apt/lists/*

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

# Airbyte est exposé sur le port 8085 de l'hôte par abctl/kind.
# Ce container n'expose aucun port directement.
ENTRYPOINT ["/bin/bash"]
CMD ["./entrypoint.sh"]
