#!/usr/bin/env sh
set -eu

exec /usr/local/bin/codexport-relay \
  --listen-host "${CODEXPORT_RELAY_LISTEN_HOST:-0.0.0.0}" \
  --port "${CODEXPORT_RELAY_PORT:-8080}"
