# YesWeSync — deployment wrapper for Airbyte 2.2.0 server
#
# This Dockerfile adds ONLY our entrypoint validation layer on top of the
# official Airbyte server image. No Airbyte source code, frontend, backend,
# connectors, workers, or any internal logic is modified.
#
# AIRBYTE SOURCE CODE MODIFIED: NO
# AIRBYTE BUNDLE PATCHED: NO
# AIRBYTE FRONTEND MODIFIED: NO
FROM airbyte/server:2.2.0

# Copy our thin entrypoint wrapper
COPY entrypoint.sh /yeswesync-entrypoint.sh
RUN chmod +x /yeswesync-entrypoint.sh

# Standard Airbyte server port
EXPOSE 8001

# Our entrypoint validates env vars then exec's the official Airbyte process.
# It does NOT replace or reimplement Airbyte server logic.
ENTRYPOINT ["/yeswesync-entrypoint.sh"]
