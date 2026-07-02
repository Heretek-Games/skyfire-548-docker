#!/usr/bin/env bash
# TCP-probe the listening port of an authserver or worldserver container.
# Exits 0 if a connection succeeds, 1 if refused, 2 on usage error.
set -euo pipefail

if ! [[ "${HEALTHCHECK_PORT}" =~ ^[0-9]+$ ]] || [ "${HEALTHCHECK_PORT}" -lt 1 ] || [ "${HEALTHCHECK_PORT}" -gt 65535 ]; then
  echo "healthcheck: invalid HEALTHCHECK_PORT='${HEALTHCHECK_PORT}'" >&2
  exit 2
fi

PORT="${HEALTHCHECK_PORT:-3724}"
HOST="${HEALTHCHECK_HOST:-127.0.0.1}"

# bash's /dev/tcp is the lightest possible probe — no curl, no nc.
if (echo > "/dev/tcp/${HOST}/${PORT}") >/dev/null 2>&1; then
  exit 0
fi
exit 1
