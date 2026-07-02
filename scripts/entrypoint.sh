#!/usr/bin/env bash
# Entrypoint for authserver and worldserver containers.
# Runs pre-flight checks, materialises the operator config from the .dist
# template shipped in the artifact, substitutes env references, then
# execs the configured binary.
set -euo pipefail

SERVICE="${SERVICE:-auth}"
BINARY="${BINARY:-${SERVICE}server}"
CONFIG_FILE="${CONFIG_FILE:-/opt/skyfire/etc/${BINARY}.conf}"

# --- pre-flight ---
check_mysql() {
  : "${MYSQL_HOST:?MYSQL_HOST required}"
  : "${MYSQL_PORT:?MYSQL_PORT required}"
  : "${MYSQL_USER:?MYSQL_USER required}"
  : "${MYSQL_PASSWORD:?MYSQL_PASSWORD required}"
  : "${MYSQL_DB:?MYSQL_DB required}"
  # bash /dev/tcp probe — same idiom as healthcheck.sh
  (echo > "/dev/tcp/${MYSQL_HOST}/${MYSQL_PORT}") >/dev/null 2>&1
}

check_binary() {
  command -v "${BINARY}" >/dev/null 2>&1 \
    || [ -x "/opt/skyfire/bin/${BINARY}" ]
}

check_config() {
  # Either the operator has already produced a config, or the
  # image-provided .dist template exists so we can materialise one.
  [ -f "${CONFIG_FILE}" ] || [ -f "${CONFIG_FILE}.dist" ]
}

materialize_config() {
  # Copy from .dist on first boot (named volume is empty).
  if [ ! -f "${CONFIG_FILE}" ] && [ -f "${CONFIG_FILE}.dist" ]; then
    cp "${CONFIG_FILE}.dist" "${CONFIG_FILE}"
  fi
}

substitute_config_env() {
  # In-place ${VAR} -> env-value substitution. The .dist configs only
  # reference the well-known MYSQL_* variables below; we skip any that
  # are unset rather than writing empty strings into connection fields.
  if [ ! -f "${CONFIG_FILE}" ]; then
    return 0
  fi
  local var val esc
  for var in MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DB; do
    val="${!var:-}"
    [ -z "$val" ] && continue
    # Escape sed-replacement metacharacters: & \ and the | delimiter.
    esc=$(printf '%s' "$val" | sed -e 's/[&|\\]/\\&/g')
    sed -i "s|\${${var}}|${esc}|g" "${CONFIG_FILE}"
  done
}

run_checks() {
  check_mysql
  check_binary
  check_config
}

# --- main ---
case "${1:-}" in
  --check)
    run_checks && echo "preflight OK" || { echo "preflight FAILED" >&2; exit 1; }
    exit 0
    ;;
esac

run_checks
materialize_config
substitute_config_env

# Trap SIGTERM/SIGINT and forward to the child.
forward_signal() {
  if [ -n "${CHILD_PID:-}" ]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
  fi
}
trap forward_signal TERM INT

# Launch binary in background so we can hold the PID for the trap.
"/opt/skyfire/bin/${BINARY}" -c "${CONFIG_FILE}" &
CHILD_PID=$!

# Wait for it. `wait` returns the child's exit code.
wait "$CHILD_PID"
