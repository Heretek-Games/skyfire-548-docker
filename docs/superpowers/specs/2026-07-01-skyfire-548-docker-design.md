# SkyFire_548 Dockerization — Design Spec

**Date:** 2026-07-01
**Target:** Production-ish single-host deployment of ProjectSkyfire/SkyFire_548 (WoW 5.4.8 emulator) on a VPS via docker-compose, with binaries produced by GitHub Actions.

## Goal

Replace the bare-metal Ubuntu 24.04 install described in the upstream wiki with a reproducible docker-compose stack. Binaries are produced in CI from the wiki's exact build steps; the runtime images are minimal and ship only what is needed to run.

## Non-goals

- Multi-host / Kubernetes orchestration.
- Bundling copyrighted WoW client data inside the image. Operators must supply DBC/maps/vmaps from their own client install via a bind mount.
- Web-based admin UI. Out of scope.
- Automated client-data extraction. Out of scope; user runs mapextractor/vmapextractor/mmap extractor locally.

## Architecture

Three services in one docker-compose project on a user-defined bridge network `skyfire-net`:

| Service      | Image base         | Binary                           | Exposed port | Persistence                          |
| ------------ | ------------------ | -------------------------------- | ------------ | ------------------------------------ |
| `mysql`      | `mysql:8.0`        | `mysqld`                         | 3306 (internal only, not published) | volume `mysql_data`, init SQL mount  |
| `authserver` | `debian:12-slim`   | `/opt/skyfire/bin/authserver`    | 3724 → host  | volume `auth_etc` (configs)          |
| `worldserver`| `debian:12-slim`   | `/opt/skyfire/bin/worldserver`   | 8085 → host  | volume `world_etc`, bind `client_data` |

`authserver` and `worldserver` declare `depends_on: { mysql: { condition: service_healthy } }`. Compose `restart: unless-stopped` on every service.

## Repository layout

```
.
├── docker-compose.yml
├── .env.example                    # MYSQL_*, SKYFIRE_* secrets (committed)
├── README.md                       # operator quick-start
├── Dockerfile.authserver
├── Dockerfile.worldserver
├── .github/workflows/build.yml     # CI: compile, publish artifacts
├── scripts/
│   ├── entrypoint.sh               # pre-flight + exec wrapper
│   ├── healthcheck.sh              # TCP probe for auth/world
│   ├── smoke.sh                    # end-to-end smoke test
│   └── dev-build.sh                # local build → dist/ for ARTIFACT_TAG=local
├── client_data/                    # bind-mount source (user-populated, gitignored)
├── db-init/                        # bind-mount source (user-populated, gitignored)
└── docs/
    └── superpowers/specs/2026-07-01-skyfire-548-docker-design.md
```

## Build pipeline (GitHub Actions)

Workflow `.github/workflows/build.yml`:

- Trigger: push to `main`, pull request, manual `workflow_dispatch`.
- Runs on `ubuntu-24.04` (matches the wiki's host).
- Two parallel jobs: `build-authserver`, `build-worldserver`. Each follows the wiki's `Installation (Ubuntu 24.04 LTS)` page literally:
  1. `apt` universe enabled, `gcc-14`, `g++-14`, `cmake`, `ninja-build`, `git`, `wget`, `ca-certificates`, `ccache`, `perl`, `pkg-config`, `bzip2`, `libbz2-dev`, `libreadline-dev`, `zlib1g-dev`, `default-libmysqlclient-dev` installed.
  2. Boost 1.91.0 downloaded from `https://archives.boost.io/release/1.91.0/source/`, installed with `b2 install --prefix=/opt/boost_1_91_0 --with-headers`.
  3. OpenSSL 4.0.0 built and installed into `/opt/openssl-4.0.0` with the legacy provider enabled (per the wiki troubleshooting section).
  4. `git clone https://github.com/ProjectSkyfire/SkyFire_548.git`, `git checkout ${{ github.sha }}` on main push.
  5. cmake configure — `cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/opt/skyfire -DCMAKE_C_COMPILER=gcc-14 -DCMAKE_CXX_COMPILER=g++-14 -DBOOST_ROOT=/opt/boost_1_91_0 -DOPENSSL_ROOT_DIR=/opt/openssl-4.0.0 -DTOOLS=OFF -DNOPCH=1 -DCONF_DIR=/opt/skyfire/etc -DLIBSDIR=/opt/skyfire/lib64`. Per-job flags:
     - `build-authserver` job adds `-DAUTH_SERVER=ON -DSERVERS=OFF`.
     - `build-worldserver` job adds `-DAUTH_SERVER=OFF -DSERVERS=ON`.
  6. `cmake --build build --target install`.
- Artifact packaging: tar `bin/<target>` + `lib64/*` + `share/skyfire-*` into `skyfire-<target>-bin.tar.gz` and upload as workflow artifact on PRs, GitHub Release on main pushes (release tag `authserver-<sha>` / `worldserver-<sha>`).

## Runtime images

`Dockerfile.authserver` and `Dockerfile.worldserver` are sibling files, same shape. Pattern:

1. `FROM debian:12-slim` — install runtime libs only (`libssl3`, `libmysqlclient21`, `libreadline8`, `libbz2-1.0`, `zlib1g`, `libgcc-s1`, `libstdc++6`, `ca-certificates`).
2. `ARG ARTIFACT_TAG=latest` — pin to a CI release tag.
3. `ARG TARGET=authserver` — distinguishes which binary to extract.
4. `ARG ARTIFACT_REPO=<this-repo-owner>/<this-repo-name>` — overridable for forks.
5. `ADD https://github.com/${ARTIFACT_REPO}/releases/download/${TARGET}-${ARTIFACT_TAG}/skyfire-${TARGET}-bin.tar.gz /tmp/`
6. `RUN tar -xzf /tmp/skyfire-${TARGET}-bin.tar.gz -C /opt && rm /tmp/skyfire-${TARGET}-bin.tar.gz`
7. `COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh` — wraps binary with `exec`, traps SIGTERM, runs pre-flight checks.
8. `COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh`
9. `USER skyfire:skyfire` (UID/GID 999). Binaries installed with matching ownership.
10. `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`
11. `HEALTHCHECK CMD /usr/local/bin/healthcheck.sh`

Run as non-root. All filesystem paths under `/opt/skyfire`. Configs in `/opt/skyfire/etc`.

## Data flow

```
WoW 5.4.8 client ──TCP/3724──> authserver ──SQL──> mysql (skyfire_auth DB)
                ──TCP/8085──> worldserver ──SQL──> mysql (skyfire_characters DB)
                                          ──SQL──> mysql (skyfire_world DB)
                                          ──FS───> /opt/skyfire/data (DBC, maps, vmaps, mmaps — bind mount)
```

Startup order:

1. mysql — official `mysql:8.0` healthcheck passes once `mysqladmin ping` returns success.
2. authserver — entrypoint waits for mysql to be reachable, then execs the binary.
3. worldserver — entrypoint waits for mysql + a populated `skyfire_world` schema, then execs.

## Configuration & secrets

`.env` (gitignored) holds all secrets. `.env.example` (committed) lists every key:

```
MYSQL_ROOT_PASSWORD=
SKYFIRE_DB_USER=skyfire
SKYFIRE_DB_PASSWORD=
SKYFIRE_DB_NAME_AUTH=skyfire_auth
SKYFIRE_DB_NAME_CHARS=skyfire_characters
SKYFIRE_DB_NAME_WORLD=skyfire_world
ARTIFACT_TAG=latest
GIT_REF=main
```

`worldserver.conf.dist` and `authserver.conf.dist` are baked into the images. On first start, the entrypoint copies them to `/opt/skyfire/etc/<service>.conf` if missing and substitutes `${VAR}` references with values from `.env`. Operators can `docker exec -it <service> vi /opt/skyfire/etc/<service>.conf` to customize; the change persists in the `auth_etc` / `world_etc` volume.

DB init SQL: `docker-entrypoint-initdb.d/` mount contains the schema files from `https://github.com/ProjectSkyfire/SkyFire_548/tree/main/sql` plus the public SQL dump release (DB release 24.001). User is responsible for downloading the dump tarball and dropping the SQL files into `db-init/` before first start. Init runs only when `mysql_data` is empty.

## Persistence

| Volume / mount | Type | Purpose                                  | Lifecycle                       |
| -------------- | ---- | ---------------------------------------- | ------------------------------- |
| `mysql_data`   | managed volume | mysqld datadir                  | survives `compose down`; only `compose down -v` wipes it |
| `auth_etc`     | managed volume | `authserver.conf` + runtime state | same as above |
| `world_etc`    | managed volume | `worldserver.conf` + runtime state | same as above |
| `client_data`  | bind mount from `./client_data` on host | DBC, maps, vmaps, mmaps | user-managed |
| `db-init`      | bind mount from `./db-init` on host | SQL files applied on first start | user-managed |

`docker-compose down` keeps all data. `docker-compose down -v` is a destructive reset documented in the README as such.

## Error handling & health

- **mysql**: official `mysql:8.0` healthcheck (`mysqladmin ping`).
- **authserver / worldserver**: `scripts/healthcheck.sh` does a TCP `connect()` against the listening port. Interval 10s, timeout 5s, `start_period: 60s` for worldserver (map loading).
- compose `restart: unless-stopped`.
- Entrypoint traps SIGTERM and forwards to the child PID; worldserver gets `stop_grace_period: 60s` to flush DB writes.
- Entrypoint runs pre-flight checks: verifies mysql reachable, verifies config file present, verifies `client_data` populated if worldserver.
- Failure logs go to stderr; compose captures them via the default json driver. README documents `docker compose logs --tail=200 -f <service>`.

## Testing

`scripts/smoke.sh` (committed):

1. `docker compose up -d --wait` (waits for all healthchecks).
2. `docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e 'SHOW TABLES FROM skyfire_auth;'` — verifies schema loaded.
3. `docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e 'SHOW TABLES FROM skyfire_world;'` — verifies world DB loaded.
4. `bash -c '</dev/tcp/localhost/3724'` — TCP probe auth port.
5. `bash -c '</dev/tcp/localhost/8085'` — TCP probe world port.
6. Exit non-zero on any failure; print a diagnostic pointing to the failing check.

`scripts/dev-build.sh` (committed): clones SkyFire_548, builds locally following the wiki steps, drops tarballs into `dist/`, then sets `ARTIFACT_TAG=local` so the runtime Dockerfiles pick them up via a local-path build arg rather than fetching from GitHub.

## CI workflow file

`.github/workflows/build.yml` — single workflow file, two parallel jobs. Matrix is unnecessary since the two builds differ in cmake flags only.

```
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
```

## Open questions / deferred decisions

- Whether to add an optional reverse proxy (caddy / traefik) in front of worldserver's SOAP port. Deferred — operators can add their own.
- Whether to expose the mysql port externally for ad-hoc DBA work. **Default: no.** Documented as a docker-compose override example in the README.
- Auto-update via watchtower. **Default: no.** Operators opt in.

## Acceptance criteria

- `docker compose up -d --wait` on a clean host produces a healthy mysql, authserver, and worldserver.
- `scripts/smoke.sh` exits 0.
- A WoW 5.4.8 client can authenticate and select a realm.
- Re-running `docker compose down && docker compose up -d` preserves all data.
- `docker compose down -v && docker compose up -d` re-initializes the DB from `db-init/` SQL.