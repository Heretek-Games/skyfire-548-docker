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

# Recognize long --help before getopts (which only knows short flags).
for arg in "$@"; do
  if [ "$arg" = "--help" ]; then
    usage; exit 0
  fi
done

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

  log "Building + installing $target (sudo required for /opt/skyfire)"
  sudo cmake --build "$WORK/build-$target" --target install

  log "Packaging $target"
  local pkg="$WORK/pkg-$target"
  mkdir -p "$pkg/bin" "$pkg/lib64" "$pkg/etc" "$pkg/share"
  sudo cp "/opt/skyfire/bin/$target" "$pkg/bin/"
  sudo cp -r /opt/skyfire/lib64/. "$pkg/lib64/"
  sudo cp -r /opt/skyfire/etc/*.conf.dist "$pkg/etc/" 2>/dev/null || true
  sudo cp -r /opt/skyfire/share/. "$pkg/share/" 2>/dev/null || true
  sudo chown -R "$USER" "$pkg"
  tar -C "$pkg" -czf "$BUILD_DIR/skyfire-${target}-bin.tar.gz" .
}

build_one authserver "-DAUTH_SERVER=ON -DSERVERS=OFF"
build_one worldserver "-DAUTH_SERVER=OFF -DSERVERS=ON"

log "Done. Tarballs in $BUILD_DIR:"
ls -lh "$BUILD_DIR"/skyfire-*-bin.tar.gz
