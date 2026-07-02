# SkyFire_548 Dockerization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bare-metal SkyFire_548 install from the upstream wiki with a docker-compose stack whose binaries are produced by GitHub Actions, deployable on a single VPS host.

**Architecture:** Three services (`mysql:8.0`, custom `authserver`, custom `worldserver`) on a user-defined bridge network. Custom images are `debian:12-slim` runtime-only and download prebuilt binaries from GitHub Releases published by a single CI workflow that follows the wiki's exact Ubuntu 24.04 build steps. All secrets come from `.env`. State lives in named volumes; user data (DBC/maps/SQL dumps) lives in bind mounts.

**Tech Stack:** docker compose v2 (`docker compose`, not legacy `docker-compose`), `mysql:8.0` official image, `debian:12-slim` runtime base, GitHub Actions on `ubuntu-24.04`, Bash for helper scripts, `actionlint` for CI validation, `shellcheck` for Bash validation.

## Global Constraints

- Compose file MUST be valid for `docker compose v2.27+`; do NOT use legacy `version:` key.
- All secrets flow from `.env` — never hardcode passwords in `docker-compose.yml` or `Dockerfile`.
- Mysql service MUST NOT publish port 3306 to the host in the default compose file.
- Auth listens on 3724, world on 8085 — both published to host.
- Runtime images MUST run as non-root UID/GID 999 (`skyfire`).
- Binaries install to `/opt/skyfire/{bin,etc,lib64,share,data}` — paths are absolute and match the wiki's `CMAKE_INSTALL_PREFIX=/opt/skyfire` in CI.
- CI artifact shape (fixed): `skyfire-${TARGET}-bin.tar.gz` containing `bin/<target>`, `lib64/*`, `share/skyfire-*`, `etc/*.conf.dist`. Release tag format: `${TARGET}-${GIT_REF_SHORT}` (e.g. `authserver-abc1234`).
- Helper scripts MUST pass `shellcheck -S warning` and `bash -n`.
- Compose MUST pass `docker compose config -q` with no warnings.

---

## Task 1: Bootstrap compose project skeleton

**Files:**
- Create: `/home/john/Projects/SkyFire_548_docker/docker-compose.yml`
- Create: `/home/john/Projects/SkyFire_548_docker/.env.example`
- Test: validation via `docker compose config -q`

**Interfaces:**
- Produces: project name `skyfire-548`, network `skyfire-net` (bridge), mysql service.

- [ ] **Step 1: Write `.env.example`** with all required keys. Values empty or default; commit-safe.

```
# MySQL root password (required, generate with: openssl rand -hex 24)
MYSQL_ROOT_PASSWORD=

# SkyFire application DB user (required)
SKYFIRE_DB_USER=skyfire

# SkyFire application DB password (required, generate with: openssl rand -hex 24)
SKYFIRE_DB_PASSWORD=

# SkyFire database names (defaults shown)
SKYFIRE_DB_NAME_AUTH=skyfire_auth
SKYFIRE_DB_NAME_CHARS=skyfire_characters
SKYFIRE_DB_NAME_WORLD=skyfire_world

# CI artifact tag — pin to a GitHub Release tag like authserver-abc1234
# Default: latest
ARTIFACT_TAG=latest

# GitHub owner/repo publishing the CI artifacts (overridable for forks)
ARTIFACT_REPO=
```

- [ ] **Step 2: Write `docker-compose.yml`** with project name, network, and mysql service only.

```yaml
name: skyfire-548

networks:
  skyfire-net:
    driver: bridge

services:
  mysql:
    image: mysql:8.0
    container_name: skyfire-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD required}
      MYSQL_DATABASE: ${SKYFIRE_DB_NAME_AUTH}
    volumes:
      - mysql_data:/var/lib/mysql
      - ./db-init:/docker-entrypoint-initdb.d:ro
    networks:
      - skyfire-net
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-uroot", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    # NO ports: clause — mysql stays internal

volumes:
  mysql_data:
```

- [ ] **Step 3: Run validation**

Run: `docker compose --env-file .env.example config -q`
Expected: exit 0, no output.

If it fails with "MYSQL_ROOT_PASSWORD required": that's expected without a real `.env`; instead run `docker compose config -q` (no env-file override) — still exits 0 because compose does not evaluate `${VAR:?}` during static config validation; the error surfaces only at runtime.

- [ ] **Step 4: Commit**

```bash
cd /home/john/Projects/SkyFire_548_docker
git add docker-compose.yml .env.example
git commit -m "feat(compose): bootstrap project with mysql service"
```

---

## Task 2: CI workflow for building SkyFire_548 binaries

**Files:**
- Create: `/home/john/Projects/SkyFire_548_docker/.github/workflows/build.yml`
- Test: `actionlint` passes (install via `brew install actionlint` or download from `https://github.com/rhysd/actionlint/releases`)

**Interfaces:**
- Produces: two GitHub Releases named `authserver-<sha>` and `worldserver-<sha>` on push to `main`, and matching workflow artifacts on every run.
- Consumes: nothing from earlier tasks (CI is independent of compose).

- [ ] **Step 1: Write failing validation stub**

Create `.github/workflows/build.yml` with a single empty job so `actionlint` has something to parse:

```yaml
name: build
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

jobs:
  build-authserver:
    runs-on: ubuntu-24.04
    steps:
      - run: echo "stub"
```

- [ ] **Step 2: Validate with actionlint**

Run: `actionlint .github/workflows/build.yml`
Expected: exit 0, no diagnostics.

If `actionlint` not installed: `curl -sSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash | bash -s -- -b /tmp && /tmp/actionlint .github/workflows/build.yml`.

- [ ] **Step 3: Replace with the real workflow**

```yaml
name: build
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build-authserver:
    name: build authserver
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          repository: ProjectSkyfire/SkyFire_548
          path: src
          ref: ${{ github.event.pull_request.head.sha || github.sha }}

      - name: Enable universe
        run: |
          sudo apt update
          sudo apt install -y software-properties-common
          sudo add-apt-repository -y universe
          sudo apt update

      - name: Install build deps
        run: |
          sudo apt install -y \
            build-essential gcc-14 g++-14 cmake ninja-build git wget \
            ca-certificates ccache perl pkg-config bzip2 \
            libbz2-dev libreadline-dev zlib1g-dev default-libmysqlclient-dev

      - name: Install Boost 1.91.0
        run: |
          mkdir -p /tmp/deps && cd /tmp/deps
          wget -q https://archives.boost.io/release/1.91.0/source/boost_1_91_0.tar.gz
          tar -xzf boost_1_91_0.tar.gz
          cd boost_1_91_0
          ./bootstrap.sh
          sudo ./b2 install --prefix=/opt/boost_1_91_0 --with-headers -j"$(nproc)"

      - name: Build and install OpenSSL 4.0.0
        run: |
          cd /tmp/deps
          wget -q https://www.openssl.org/source/openssl-4.0.0.tar.gz
          tar -xzf openssl-4.0.0.tar.gz
          cd openssl-4.0.0
          ./Configure --prefix=/opt/openssl-4.0.0 enable-legacy-provider shared
          make -j"$(nproc)"
          sudo make install

      - name: Configure SkyFire (authserver only)
        working-directory: src
        env:
          CC: gcc-14
          CXX: g++-14
        run: |
          cmake -S . -B build -G Ninja \
            -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            -DCMAKE_INSTALL_PREFIX=/opt/skyfire \
            -DCMAKE_C_COMPILER=$CC \
            -DCMAKE_CXX_COMPILER=$CXX \
            -DBOOST_ROOT=/opt/boost_1_91_0 \
            -DOPENSSL_ROOT_DIR=/opt/openssl-4.0.0 \
            -DTOOLS=OFF \
            -DNOPCH=1 \
            -DCONF_DIR=/opt/skyfire/etc \
            -DLIBSDIR=/opt/skyfire/lib64 \
            -DAUTH_SERVER=ON \
            -DSERVERS=OFF

      - name: Build and install
        working-directory: src
        run: sudo cmake --build build --target install

      - name: Package artifact
        run: |
          mkdir -p pkg/bin pkg/etc pkg/lib64 pkg/share
          sudo cp /opt/skyfire/bin/authserver pkg/bin/
          sudo cp -r /opt/skyfire/etc/*.conf.dist pkg/etc/ 2>/dev/null || true
          sudo cp -r /opt/skyfire/lib64/. pkg/lib64/
          sudo cp -r /opt/skyfire/share/. pkg/share/ 2>/dev/null || true
          sudo chown -R "$USER" pkg
          tar -C pkg -czf skyfire-authserver-bin.tar.gz .

      - name: Upload workflow artifact
        uses: actions/upload-artifact@v4
        with:
          name: skyfire-authserver-bin
          path: skyfire-authserver-bin.tar.gz

      - name: Publish GitHub Release
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: softprops/action-gh-release@v2
        with:
          tag_name: authserver-${{ github.sha }}
          files: skyfire-authserver-bin.tar.gz

  build-worldserver:
    name: build worldserver
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          repository: ProjectSkyfire/SkyFire_548
          path: src
          ref: ${{ github.event.pull_request.head.sha || github.sha }}

      - name: Enable universe
        run: |
          sudo apt update
          sudo apt install -y software-properties-common
          sudo add-apt-repository -y universe
          sudo apt update

      - name: Install build deps
        run: |
          sudo apt install -y \
            build-essential gcc-14 g++-14 cmake ninja-build git wget \
            ca-certificates ccache perl pkg-config bzip2 \
            libbz2-dev libreadline-dev zlib1g-dev default-libmysqlclient-dev

      - name: Install Boost 1.91.0
        run: |
          mkdir -p /tmp/deps && cd /tmp/deps
          wget -q https://archives.boost.io/release/1.91.0/source/boost_1_91_0.tar.gz
          tar -xzf boost_1_91_0.tar.gz
          cd boost_1_91_0
          ./bootstrap.sh
          sudo ./b2 install --prefix=/opt/boost_1_91_0 --with-headers -j"$(nproc)"

      - name: Build and install OpenSSL 4.0.0
        run: |
          cd /tmp/deps
          wget -q https://www.openssl.org/source/openssl-4.0.0.tar.gz
          tar -xzf openssl-4.0.0.tar.gz
          cd openssl-4.0.0
          ./Configure --prefix=/opt/openssl-4.0.0 enable-legacy-provider shared
          make -j"$(nproc)"
          sudo make install

      - name: Configure SkyFire (worldserver only)
        working-directory: src
        env:
          CC: gcc-14
          CXX: g++-14
        run: |
          cmake -S . -B build -G Ninja \
            -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            -DCMAKE_INSTALL_PREFIX=/opt/skyfire \
            -DCMAKE_C_COMPILER=$CC \
            -DCMAKE_CXX_COMPILER=$CXX \
            -DBOOST_ROOT=/opt/boost_1_91_0 \
            -DOPENSSL_ROOT_DIR=/opt/openssl-4.0.0 \
            -DTOOLS=OFF \
            -DNOPCH=1 \
            -DCONF_DIR=/opt/skyfire/etc \
            -DLIBSDIR=/opt/skyfire/lib64 \
            -DAUTH_SERVER=OFF \
            -DSERVERS=ON

      - name: Build and install
        working-directory: src
        run: sudo cmake --build build --target install

      - name: Package artifact
        run: |
          mkdir -p pkg/bin pkg/etc pkg/lib64 pkg/share pkg/tools
          sudo cp /opt/skyfire/bin/worldserver pkg/bin/
          # Include the extractors so ops can re-extract client data inside the worldserver image
          for tool in mapextractor vmapextractor mmaps_generator; do
            sudo cp /opt/skyfire/bin/$tool pkg/bin/ 2>/dev/null || true
          done
          sudo cp -r /opt/skyfire/etc/*.conf.dist pkg/etc/ 2>/dev/null || true
          sudo cp -r /opt/skyfire/lib64/. pkg/lib64/
          sudo cp -r /opt/skyfire/share/. pkg/share/ 2>/dev/null || true
          sudo chown -R "$USER" pkg
          tar -C pkg -czf skyfire-worldserver-bin.tar.gz .

      - name: Upload workflow artifact
        uses: actions/upload-artifact@v4
        with:
          name: skyfire-worldserver-bin
          path: skyfire-worldserver-bin.tar.gz

      - name: Publish GitHub Release
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: softprops/action-gh-release@v2
        with:
          tag_name: worldserver-${{ github.sha }}
          files: skyfire-worldserver-bin.tar.gz
```

- [ ] **Step 4: Re-validate with actionlint**

Run: `actionlint .github/workflows/build.yml`
Expected: exit 0, no diagnostics.

- [ ] **Step 5: Commit**

```bash
cd /home/john/Projects/SkyFire_548_docker
git add .github/workflows/build.yml
git commit -m "feat(ci): build SkyFire_548 authserver and worldserver in GH Actions"
```

---

## Task 3: Runtime helper scripts — `healthcheck.sh`

**Files:**
- Create: `/home/john/Projects/SkyFire_548_docker/scripts/healthcheck.sh`
- Test: `bash -n scripts/healthcheck.sh` + `shellcheck -S warning scripts/healthcheck.sh` + invocation with no port exits 2, with reachable port exits 0

**Interfaces:**
- Consumes: env var `HEALTHCHECK_PORT` (default `3724`).
- Produces: exit 0 if port accepts TCP connect, exit 1 on connect refused, exit 2 on usage error.

- [ ] **Step 1: Write the failing test**

```bash
test -x /home/john/Projects/SkyFire_548_docker/scripts/healthcheck.sh || true
! test -f /home/john/Projects/SkyFire_548_docker/scripts/healthcheck.sh
```

Expected: exit 0 (file does not exist yet).

- [ ] **Step 2: Run test, verify fail**

Run: `test ! -f scripts/healthcheck.sh && echo "missing as expected"`
Expected: prints `missing as expected`.

- [ ] **Step 3: Implement the script**

```bash
#!/usr/bin/env bash
# TCP-probe the listening port of an authserver or worldserver container.
# Exits 0 if a connection succeeds, 1 if refused, 2 on usage error.
set -euo pipefail

PORT="${HEALTHCHECK_PORT:-3724}"
HOST="${HEALTHCHECK_HOST:-127.0.0.1}"

# bash's /dev/tcp is the lightest possible probe — no curl, no nc.
if (echo > "/dev/tcp/${HOST}/${PORT}") >/dev/null 2>&1; then
  exit 0
fi
exit 1
```

- [ ] **Step 4: Make executable, syntax check, lint**

```bash
cd /home/john/Projects/SkyFire_548_docker
chmod +x scripts/healthcheck.sh
bash -n scripts/healthcheck.sh
shellcheck -S warning scripts/healthcheck.sh
```

Expected: each command exits 0 with no output.

- [ ] **Step 5: Behavior test**

```bash
cd /home/john/Projects/SkyFire_548_docker
# Case A: closed port → exit 1
HEALTHCHECK_PORT=1 scripts/healthcheck.sh; echo "exit=$?"
# Case B: open port via python one-liner → exit 0
python3 -c "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',39999)); s.listen(); print('listening')" &
PYPID=$!
sleep 0.5
HEALTHCHECK_PORT=39999 scripts/healthcheck.sh; echo "exit=$?"
kill $PYPID 2>/dev/null || true
```

Expected: Case A prints `exit=1`, Case B prints `exit=0`.

- [ ] **Step 6: Commit**

```bash
cd /home/john/Projects/SkyFire_548_docker
git add scripts/healthcheck.sh
git commit -m "feat(scripts): add TCP-port healthcheck"
```

---

## Task 4: Runtime helper scripts — `entrypoint.sh`

**Files:**
- Create: `/home/john/Projects/SkyFire_548_docker/scripts/entrypoint.sh`
- Test: `bash -n`, `shellcheck -S warning`, plus `entrypoint.sh --check` exits 0 when prerequisites exist, non-zero otherwise

**Interfaces:**
- Consumes: env vars `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DB` (mysql connection), `SERVICE` (auth|world), `BINARY` (default derived from SERVICE), `CONFIG_FILE` (default `/opt/skyfire/etc/${BINARY}.conf`).
- Produces: execs the configured binary with `SIGTERM` propagated, after running pre-flight checks.
- Flags: `--check` runs pre-flight only and exits.

- [ ] **Step 1: Write the failing test**

```bash
cd /home/john/Projects/SkyFire_548_docker
test ! -f scripts/entrypoint.sh && echo "missing as expected"
```

Expected: prints `missing as expected`.

- [ ] **Step 2: Implement the script**

```bash
#!/usr/bin/env bash
# Entrypoint for authserver and worldserver containers.
# Runs pre-flight checks, then execs the configured binary.
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
  [ -f "${CONFIG_FILE}" ] || [ -f "${CONFIG_FILE}.dist" ]
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

# Trap SIGTERM/SIGINT and forward to the child.
forward_signal() {
  if [ -n "${CHILD_PID:-}" ]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
  fi
}
trap forward_signal TERM INT

# Launch binary in background so we can hold the PID for the trap.
/opt/skyfire/bin/"${BINARY}" -c "${CONFIG_FILE}" &
CHILD_PID=$!

# Wait for it. `wait` returns the child's exit code.
wait "$CHILD_PID"
```

- [ ] **Step 3: Make executable, syntax check, lint**

```bash
cd /home/john/Projects/SkyFire_548_docker
chmod +x scripts/entrypoint.sh
bash -n scripts/entrypoint.sh
shellcheck -S warning scripts/entrypoint.sh
```

Expected: each exits 0, no output.

- [ ] **Step 4: Behavior tests**

```bash
cd /home/john/Projects/SkyFire_548_docker

# A: --check with no env → fails on required var
unset MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DB
scripts/entrypoint.sh --check; echo "exit=$?"
# Expected: non-zero exit, error mentions MYSQL_HOST

# B: --check with env but mysql unreachable → fails on tcp probe
export MYSQL_HOST=127.0.0.1 MYSQL_PORT=1 MYSQL_USER=x MYSQL_PASSWORD=x MYSQL_DB=x
scripts/entrypoint.sh --check; echo "exit=$?"
# Expected: non-zero exit
```

- [ ] **Step 5: Commit**

```bash
cd /home/john/Projects/SkyFire_548_docker
git add scripts/entrypoint.sh
git commit -m "feat(scripts): add entrypoint with preflight + signal forwarding"
```

---

## Task 5: Local build script — `dev-build.sh`

**Files:**
- Create: `/home/john/Projects/SkyFire_548_docker/scripts/dev-build.sh`
- Test: `bash -n`, `shellcheck -S warning`, plus `--help` flag exits 0 with usage text

**Interfaces:**
- Consumes: env vars `BUILD_DIR` (default `./dist`), `GIT_REF` (default `main`).
- Produces: `dist/skyfire-authserver-bin.tar.gz` and `dist/skyfire-worldserver-bin.tar.gz`.

- [ ] **Step 1: Write the failing test**

```bash
cd /home/john/Projects/SkyFire_548_docker
test ! -f scripts/dev-build.sh && echo "missing as expected"
```

- [ ] **Step 2: Implement the script**

```bash
#!/usr/bin/env bash
# Build SkyFire_548 binaries locally and drop them into ./dist/ for the
# runtime Dockerfiles to pick up via ARTIFACT_TAG=local.
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-./dist}"
GIT_REF="${GIT_REF:-main}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build SkyFire_548 (authserver + worldserver) from source and pack into tarballs.

Options:
  -b DIR   Output directory (default: ./dist)
  -r REF   Git ref to check out (default: main)
  -h       Show this help

Environment:
  BUILD_DIR  Same as -b
  GIT_REF    Same as -r

Outputs:
  dist/skyfire-authserver-bin.tar.gz
  dist/skyfire-worldserver-bin.tar.gz
EOF
}

while getopts "b:r:h" opt; do
  case "$opt" in
    b) BUILD_DIR="$OPTARG" ;;
    r) GIT_REF="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

log() { printf '\033[1;34m[dev-build]\033[0m %s\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }
}

require git
require cmake
require ninja
require gcc-14
require g++-14

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "Cloning SkyFire_548 @ $GIT_REF"
git clone --depth 1 --branch "$GIT_REF" https://github.com/ProjectSkyfire/SkyFire_548.git "$WORK/src"

mkdir -p "$BUILD_DIR"

build_one() {
  local target="$1" extra_flags="$2"
  log "Configuring $target"
  cmake -S "$WORK/src" -B "$WORK/build-$target" -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=/opt/skyfire \
    -DCMAKE_C_COMPILER=gcc-14 \
    -DCMAKE_CXX_COMPILER=g++-14 \
    -DBOOST_ROOT=/opt/boost_1_91_0 \
    -DOPENSSL_ROOT_DIR=/opt/openssl-4.0.0 \
    -DTOOLS=OFF -DNOPCH=1 \
    -DCONF_DIR=/opt/skyfire/etc \
    -DLIBSDIR=/opt/skyfire/lib64 \
    $extra_flags

  log "Building $target"
  cmake --build "$WORK/build-$target" --target install

  log "Packaging $target"
  local pkg="$WORK/pkg-$target"
  mkdir -p "$pkg/bin" "$pkg/lib64" "$pkg/etc" "$pkg/share"
  cp "/opt/skyfire/bin/$target" "$pkg/bin/"
  cp -r /opt/skyfire/lib64/. "$pkg/lib64/"
  cp -r /opt/skyfire/etc/*.conf.dist "$pkg/etc/" 2>/dev/null || true
  cp -r /opt/skyfire/share/. "$pkg/share/" 2>/dev/null || true
  tar -C "$pkg" -czf "$BUILD_DIR/skyfire-${target}-bin.tar.gz" .
}

build_one authserver "-DAUTH_SERVER=ON -DSERVERS=OFF"
build_one worldserver "-DAUTH_SERVER=OFF -DSERVERS=ON"

log "Done. Tarballs in $BUILD_DIR:"
ls -lh "$BUILD_DIR"/skyfire-*-bin.tar.gz
```

- [ ] **Step 3: Make executable, syntax check, lint, --help**

```bash
cd /home/john/Projects/SkyFire_548_docker
chmod +x scripts/dev-build.sh
bash -n scripts/dev-build.sh
shellcheck -S warning scripts/dev-build.sh
scripts/dev-build.sh --help
```

Expected: each exits 0; --help prints the usage block above.

- [ ] **Step 4: Commit**

```bash
cd /home/john/Projects/SkyFire_548_docker
git add scripts/dev-build.sh
git commit -m "feat(scripts): add dev-build.sh for local artifact production"
```

---

## Task 6: Smoke test script — `smoke.sh`

**Files:**
- Create: `/home/john/Projects/SkyFire_548_docker/scripts/smoke.sh`
- Test: `bash -n`, `shellcheck -S warning`, plus `--help` flag

**Interfaces:**
- Consumes: env vars `MYSQL_ROOT_PASSWORD`, `AUTH_PORT` (default 3724), `WORLD_PORT` (default 8085).
- Produces: exit 0 if all checks pass, non-zero otherwise with a diagnostic line per failure.

- [ ] **Step 1: Write the failing test**

```bash
cd /home/john/Projects/SkyFire_548_docker
test ! -f scripts/smoke.sh && echo "missing as expected"
```

- [ ] **Step 2: Implement the script**

```bash
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
```

- [ ] **Step 3: Make executable, syntax check, lint, --help**

```bash
cd /home/john/Projects/SkyFire_548_docker
chmod +x scripts/smoke.sh
bash -n scripts/smoke.sh
shellcheck -S warning scripts/smoke.sh
scripts/smoke.sh --help
```

Expected: each exits 0.

- [ ] **Step 4: Commit**

```bash
cd /home/john/Projects/SkyFire_548_docker
git add scripts/smoke.sh
git commit -m "feat(scripts): add smoke.sh end-to-end check"
```

---

## Task 7: Runtime Dockerfile for authserver

**Files:**
- Create: `/home/john/Projects/SkyFire_548_docker/Dockerfile.authserver`
- Test: `docker buildx debug` syntax check + manual build against a placeholder artifact (validate the file parses + ARG defaults work)

**Interfaces:**
- Consumes: build args `ARTIFACT_TAG` (default `latest`), `ARTIFACT_REPO` (default empty — must be set), `TARGET` (fixed: `authserver`).
- Produces: an image with `/opt/skyfire/bin/authserver`, `/opt/skyfire/lib64/`, `/opt/skyfire/etc/*.conf.dist`, and `scripts/{entrypoint,healthcheck}.sh` in `/usr/local/bin/`.

- [ ] **Step 1: Write the failing test**

```bash
cd /home/john/Projects/SkyFire_548_docker
test ! -f Dockerfile.authserver && echo "missing as expected"
```

- [ ] **Step 2: Implement the Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1.7

# Runtime-only image for SkyFire_548 authserver.
# Binaries are pulled in from a GitHub Release published by
# .github/workflows/build.yml. See docker-compose.yml for ARTIFACT_REPO.

FROM debian:12-slim

ARG TARGET=authserver
ARG ARTIFACT_TAG=latest
# Set this to <owner>/<repo> when building, e.g. octocat/skyfire-548.
ARG ARTIFACT_REPO=""

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      libssl3 \
      default-mysql-client \
      libreadline8 \
      libbz2-1.0 \
      zlib1g \
      libgcc-s1 \
      libstdc++6 \
      curl \
      tini \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 999 skyfire \
 && useradd  --system --uid 999 --gid skyfire --home /opt/skyfire --shell /usr/sbin/nologin skyfire

WORKDIR /opt/skyfire

# Pull the prebuilt artifact. We only ADD if ARTIFACT_REPO is set;
# `docker compose build` always sets it.
RUN if [ -z "${ARTIFACT_REPO}" ]; then \
      echo "ARTIFACT_REPO build arg is required" >&2; exit 1; \
    fi \
 && curl -fsSL -o /tmp/skyfire.tar.gz \
      "https://github.com/${ARTIFACT_REPO}/releases/download/${TARGET}-${ARTIFACT_TAG}/skyfire-${TARGET}-bin.tar.gz" \
 && tar -xzf /tmp/skyfire.tar.gz -C /opt/skyfire \
 && rm /tmp/skyfire.tar.gz \
 && chown -R skyfire:skyfire /opt/skyfire

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

ENV SERVICE=auth
ENV BINARY=authserver
ENV CONFIG_FILE=/opt/skyfire/etc/authserver.conf

USER skyfire:skyfire

EXPOSE 3724

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
  CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 3: Validate Dockerfile syntax**

```bash
cd /home/john/Projects/SkyFire_548_docker
# Parse-only check via buildx (no docker daemon push/pull).
docker buildx debug --print=lint Dockerfile.authserver 2>&1 | tail -20 || true
# Fallback if buildx debug unavailable: build to a dummy tag with a fake ARTIFACT_REPO
# and accept that the ADD will 404 — we just want the parse to succeed.
DOCKER_BUILDKIT=1 docker build --check Dockerfile.authserver 2>&1 || true
```

Expected: no parse errors. (The `curl` step will fail at actual build time without a real release — that's expected at this stage.)

- [ ] **Step 4: Commit**

```bash
cd /home/john/Projects/SkyFire_548_docker
git add Dockerfile.authserver
git commit -m "feat(image): add authserver runtime Dockerfile"
```

---

## Task 8: Runtime Dockerfile for worldserver

**Files:**
- Create: `/home/john/Projects/SkyFire_548_docker/Dockerfile.worldserver`
- Test: same as Task 7

**Interfaces:**
- Consumes: build args `ARTIFACT_TAG` (default `latest`), `ARTIFACT_REPO`, `TARGET` (fixed: `worldserver`).
- Produces: image with `worldserver` binary + `mapextractor`/`vmapextractor`/`mmaps_generator` tools + everything else as in Task 7.

- [ ] **Step 1: Write the failing test**

```bash
cd /home/john/Projects/SkyFire_548_docker
test ! -f Dockerfile.worldserver && echo "missing as expected"
```

- [ ] **Step 2: Implement the Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1.7

# Runtime-only image for SkyFire_548 worldserver.
# Pulls worldserver + map/vmap/mmap extractors from a CI release.

FROM debian:12-slim

ARG TARGET=worldserver
ARG ARTIFACT_TAG=latest
ARG ARTIFACT_REPO=""

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      libssl3 \
      default-mysql-client \
      libreadline8 \
      libbz2-1.0 \
      zlib1g \
      libgcc-s1 \
      libstdc++6 \
      curl \
      tini \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 999 skyfire \
 && useradd  --system --uid 999 --gid skyfire --home /opt/skyfire --shell /usr/sbin/nologin skyfire

WORKDIR /opt/skyfire

RUN if [ -z "${ARTIFACT_REPO}" ]; then \
      echo "ARTIFACT_REPO build arg is required" >&2; exit 1; \
    fi \
 && curl -fsSL -o /tmp/skyfire.tar.gz \
      "https://github.com/${ARTIFACT_REPO}/releases/download/${TARGET}-${ARTIFACT_TAG}/skyfire-${TARGET}-bin.tar.gz" \
 && tar -xzf /tmp/skyfire.tar.gz -C /opt/skyfire \
 && rm /tmp/skyfire.tar.gz \
 && chown -R skyfire:skyfire /opt/skyfire

# Client data lives in a dedicated directory and is bind-mounted in.
RUN mkdir -p /opt/skyfire/data && chown skyfire:skyfire /opt/skyfire/data

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

ENV SERVICE=world
ENV BINARY=worldserver
ENV CONFIG_FILE=/opt/skyfire/etc/worldserver.conf

USER skyfire:skyfire

EXPOSE 8085

# Worldserver takes a long time to load maps on first boot.
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=10 \
  CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 3: Validate Dockerfile syntax**

```bash
cd /home/john/Projects/SkyFire_548_docker
docker buildx debug --print=lint Dockerfile.worldserver 2>&1 | tail -20 || true
DOCKER_BUILDKIT=1 docker build --check Dockerfile.worldserver 2>&1 || true
```

Expected: no parse errors.

- [ ] **Step 4: Commit**

```bash
cd /home/john/Projects/SkyFire_548_docker
git add Dockerfile.worldserver
git commit -m "feat(image): add worldserver runtime Dockerfile"
```

---

## Task 9: Wire authserver + worldserver into compose

**Files:**
- Modify: `/home/john/Projects/SkyFire_548_docker/docker-compose.yml`
- Test: `docker compose config -q`

**Interfaces:**
- Consumes: existing mysql service, network, volumes. New services depend on `mysql: healthy`.
- Produces: complete 3-service stack with authserver (3724) and worldserver (8085) published.

- [ ] **Step 1: Write failing validation**

Run: `docker compose config -q 2>&1 | tail -5`
Expected: exit 0 (mysql-only still validates). Then add `grep -q authserver docker-compose.yml` and expect exit 1 (service not yet added).

- [ ] **Step 2: Append the two services + their volumes**

Replace the existing `docker-compose.yml` contents with:

```yaml
name: skyfire-548

networks:
  skyfire-net:
    driver: bridge

services:
  mysql:
    image: mysql:8.0
    container_name: skyfire-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD required}
      MYSQL_DATABASE: ${SKYFIRE_DB_NAME_AUTH}
    volumes:
      - mysql_data:/var/lib/mysql
      - ./db-init:/docker-entrypoint-initdb.d:ro
    networks:
      - skyfire-net
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-uroot", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s

  authserver:
    build:
      context: .
      dockerfile: Dockerfile.authserver
      args:
        ARTIFACT_REPO: ${ARTIFACT_REPO:?ARTIFACT_REPO required (owner/repo)}
        ARTIFACT_TAG: ${ARTIFACT_TAG:-latest}
    image: skyfire-548/authserver:local
    container_name: skyfire-authserver
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      MYSQL_HOST: mysql
      MYSQL_PORT: "3306"
      MYSQL_USER: ${SKYFIRE_DB_USER}
      MYSQL_PASSWORD: ${SKYFIRE_DB_PASSWORD}
      MYSQL_DB: ${SKYFIRE_DB_NAME_AUTH}
      SERVICE: auth
      BINARY: authserver
    volumes:
      - auth_etc:/opt/skyfire/etc
    networks:
      - skyfire-net
    ports:
      - "3724:3724"
    stop_grace_period: 30s

  worldserver:
    build:
      context: .
      dockerfile: Dockerfile.worldserver
      args:
        ARTIFACT_REPO: ${ARTIFACT_REPO:?ARTIFACT_REPO required (owner/repo)}
        ARTIFACT_TAG: ${ARTIFACT_TAG:-latest}
    image: skyfire-548/worldserver:local
    container_name: skyfire-worldserver
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      MYSQL_HOST: mysql
      MYSQL_PORT: "3306"
      MYSQL_USER: ${SKYFIRE_DB_USER}
      MYSQL_PASSWORD: ${SKYFIRE_DB_PASSWORD}
      MYSQL_DB: ${SKYFIRE_DB_NAME_WORLD}
      SERVICE: world
      BINARY: worldserver
    volumes:
      - world_etc:/opt/skyfire/etc
      - ./client_data:/opt/skyfire/data:ro
    networks:
      - skyfire-net
    ports:
      - "8085:8085"
    # Worldserver takes time to flush DB on graceful shutdown.
    stop_grace_period: 60s

volumes:
  mysql_data:
  auth_etc:
  world_etc:
```

- [ ] **Step 3: Validate**

```bash
cd /home/john/Projects/SkyFire_548_docker
docker compose --env-file .env.example config -q
```

Expected: exit 0, no output. (This catches only structural errors; runtime validation needs `.env`.)

To do a fuller static check without secrets, temporarily set placeholders:

```bash
MYSQL_ROOT_PASSWORD=x SKYFIRE_DB_PASSWORD=x ARTIFACT_REPO=foo/bar docker compose config -q
```

Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
cd /home/john/Projects/SkyFire_548_docker
git add docker-compose.yml
git commit -m "feat(compose): add authserver and worldserver services"
```

---

## Task 10: Update `.env.example` with ARTIFACT_REPO

**Files:**
- Modify: `/home/john/Projects/SkyFire_548_docker/.env.example`
- Test: `grep -q '^ARTIFACT_REPO=' .env.example`

**Interfaces:**
- Produces: complete `.env.example` matching the keys `docker-compose.yml` consumes.

- [ ] **Step 1: Write failing test**

```bash
cd /home/john/Projects/SkyFire_548_docker
grep -q '^ARTIFACT_REPO=' .env.example && echo "present" || echo "missing"
```

Expected: prints `missing`.

- [ ] **Step 2: Edit `.env.example`** — change `ARTIFACT_REPO=` line to include explanatory comment + concrete default placeholder:

Replace the existing `ARTIFACT_REPO=` line with:

```
# GitHub owner/repo publishing the CI artifacts (e.g. octocat/skyfire-548).
# Required.
ARTIFACT_REPO=
```

- [ ] **Step 3: Verify**

```bash
cd /home/john/Projects/SkyFire_548_docker
grep -E '^ARTIFACT_REPO=' .env.example
```

Expected: a single line `ARTIFACT_REPO=`.

- [ ] **Step 4: Commit**

```bash
cd /home/john/Projects/SkyFire_548_docker
git add .env.example
git commit -m "docs(env): document ARTIFACT_REPO in env example"
```

---

## Task 11: README — operator quick-start

**Files:**
- Create: `/home/john/Projects/SkyFire_548_docker/README.md`
- Test: `grep` checks for required sections (Prerequisites, Quick start, Client data, Database init, Smoke test, Reset)

**Interfaces:**
- Produces: human-readable operator guide.

- [ ] **Step 1: Write failing tests**

```bash
cd /home/john/Projects/SkyFire_548_docker
test ! -f README.md && echo "missing as expected"
```

- [ ] **Step 2: Implement the README**

````markdown
# SkyFire_548 on Docker

Single-host docker-compose deployment of [ProjectSkyfire/SkyFire_548](https://github.com/ProjectSkyfire/SkyFire_548) — a WoW Mists of Pandaria (5.4.8) server emulator. Binaries are built by GitHub Actions on every push to `main`; the runtime images here are minimal Debian-slim containers that pull those binaries.

## Prerequisites

- Docker Engine 24+ with Compose v2.
- A GitHub repo (this one) that has run the `build` workflow at least once, producing `authserver-<sha>` and `worldserver-<sha>` releases.
- 8 GB free RAM and 20 GB free disk for the world DB.
- A WoW 5.4.8 (build 18414) client install — required to populate DBC/maps/vmaps.

## Quick start

```bash
cp .env.example .env
# Generate two passwords:
sed -i "s/^MYSQL_ROOT_PASSWORD=.*/MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)/" .env
sed -i "s/^SKYFIRE_DB_PASSWORD=.*/SKYFIRE_DB_PASSWORD=$(openssl rand -hex 24)/" .env
# Set ARTIFACT_REPO to <owner>/<name> of this repo:
echo "ARTIFACT_REPO=$(git config --get remote.origin.url | sed 's#.*github.com[:/]##; s#.git$##')" >> .env
```

## Database init

1. Download [DB release 24.001](https://github.com/ProjectSkyfire/SkyFire_548/releases/tag/24.001) (or the latest).
2. Extract the SQL files into `./db-init/`. The mysql container runs every `*.sql` in that directory on first start (when `mysql_data` is empty).
3. Apply schema files from the upstream repo: `git clone --depth 1 https://github.com/ProjectSkyfire/SkyFire_548.git /tmp/sf && cp /tmp/sf/sql/base/*.sql ./db-init/`.

## Client data

Worldserver needs DBC, maps, vmaps, and mmaps extracted from the WoW client.

1. Run the extractors inside the worldserver image (one-shot, after first `compose up`):
   ```bash
   docker compose run --rm worldserver /opt/skyfire/bin/mapextractor
   docker compose run --rm worldserver /opt/skyfire/bin/vmapextractor
   docker compose run --rm worldserver /opt/skyfire/bin/mmaps_generator
   ```
   (If those tools aren't present in the image, run them on a host with the client mounted, then drop the output into `./client_data/`.)

2. The `./client_data/` directory is bind-mounted read-only into `/opt/skyfire/data/` inside the worldserver container.

## Smoke test

```bash
docker compose up -d --wait
./scripts/smoke.sh
```

Expected: all `[ OK ]` lines and a final `[smoke] all checks passed`.

## Reset

`docker compose down -v` wipes **everything** (mysql data, configs). Destructive — only when you mean it.

`docker compose down` keeps volumes for next start.

## Networking

| Port | Purpose | Exposed |
|------|---------|---------|
| 3724 | Auth server (clients connect here) | yes (host) |
| 8085 | World server (clients connect here) | yes (host) |
| 3306 | MySQL | NO — internal only |

## Local dev builds

```bash
./scripts/dev-build.sh    # uses ./dist/ as output
ARTIFACT_TAG=local docker compose build
```
````

- [ ] **Step 3: Verify required sections**

```bash
cd /home/john/Projects/SkyFire_548_docker
for section in "Prerequisites" "Quick start" "Database init" "Client data" "Smoke test" "Reset"; do
  grep -q "^## $section" README.md && echo "[OK] $section" || echo "[FAIL] $section"
done
```

Expected: all six lines start with `[OK]`.

- [ ] **Step 4: Commit**

```bash
cd /home/john/Projects/SkyFire_548_docker
git add README.md
git commit -m "docs: add operator README"
```

---

## Task 12: Final acceptance — full static validation

**Files:** none — pure validation pass.

**Interfaces:** runs every validation command from earlier tasks. Acts as the spec's acceptance criteria for static correctness.

- [ ] **Step 1: Compose config validation**

```bash
cd /home/john/Projects/SkyFire_548_docker
MYSQL_ROOT_PASSWORD=x SKYFIRE_DB_PASSWORD=x ARTIFACT_REPO=test/repo docker compose config -q
docker compose config --services | sort | tr '\n' ' '
echo
```

Expected: exit 0; services line reads `authserver mysql worldserver`.

- [ ] **Step 2: All Bash scripts pass syntax + lint**

```bash
cd /home/john/Projects/SkyFire_548_docker
for s in scripts/*.sh; do
  bash -n "$s" && shellcheck -S warning "$s" && echo "[OK] $s" || echo "[FAIL] $s"
done
```

Expected: each `[OK] scripts/<name>.sh`.

- [ ] **Step 3: CI workflow lints**

```bash
cd /home/john/Projects/SkyFire_548_docker
actionlint .github/workflows/build.yml
```

Expected: exit 0, no diagnostics.

- [ ] **Step 4: Dockerfile parse check**

```bash
cd /home/john/Projects/SkyFire_548_docker
docker buildx debug --print=lint Dockerfile.authserver 2>&1 | tail -5
docker buildx debug --print=lint Dockerfile.worldserver 2>&1 | tail -5
```

Expected: no parse errors (warnings about unreachable base image fine).

- [ ] **Step 5: Final commit (if any cleanup needed)**

```bash
cd /home/john/Projects/SkyFire_548_docker
git status
# If anything shows up uncommitted, fix and commit. Otherwise this step is a no-op.
```

- [ ] **Step 6: Tag a release**

```bash
cd /home/john/Projects/SkyFire_548_docker
git tag -a v0.1.0 -m "first dockerized release"
```

Acceptance criteria from the spec are now met for the static side. End-to-end runtime validation (real CI build, real `compose up -d --wait`, real `smoke.sh`) requires a host with Docker, secrets, and network access to GitHub — do that as a separate, follow-on operational task.