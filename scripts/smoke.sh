#!/usr/bin/env bash
# Smoke-test a running skyfire-548 stack. Exits non-zero on first failure.
set -euo pipefail

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD required}"
AUTH_PORT="${AUTH_PORT:-3724}"
WORLD_PORT="${WORLD_PORT:-8085}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

End-to-end smoke test. Requires:
  - a running stack (\`docker compose up -d --wait\`)
  - MYSQL_ROOT_PASSWORD set in env or .env

Checks:
  1. mysql is healthy and skyfire_auth schema has tables
  2. skyfire_world schema has tables
  3. auth port (3724) accepts TCP
  4. world port (8085) accepts TCP
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage; exit 0
fi

fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m[ OK]\033[0m %s\n' "$*"; }

probe_tcp() {
  local port="$1"
  (echo > "/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

AUTH_TABLES=$(docker compose exec -T mysql \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -N -B -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='skyfire_auth';" 2>/dev/null || echo 0)

[ "${AUTH_TABLES}" -gt 0 ] || fail "skyfire_auth has no tables (init SQL not loaded?)"
ok "skyfire_auth has ${AUTH_TABLES} tables"

WORLD_TABLES=$(docker compose exec -T mysql \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -N -B -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='skyfire_world';" 2>/dev/null || echo 0)

[ "${WORLD_TABLES}" -gt 0 ] || fail "skyfire_world has no tables"
ok "skyfire_world has ${WORLD_TABLES} tables"

probe_tcp "${AUTH_PORT}"  || fail "auth port ${AUTH_PORT} not listening"
ok "auth port ${AUTH_PORT} reachable"

probe_tcp "${WORLD_PORT}" || fail "world port ${WORLD_PORT} not listening"
ok "world port ${WORLD_PORT} reachable"

printf '\033[1;32m[smoke] all checks passed\033[0m\n'