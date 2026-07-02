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
# Create host bind-mount source dirs so docker compose doesn't choke on
# the first run:
mkdir -p db-init client_data
# Generate two passwords:
sed -i "s/^MYSQL_ROOT_PASSWORD=.*/MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)/" .env
sed -i "s/^SKYFIRE_DB_PASSWORD=.*/SKYFIRE_DB_PASSWORD=$(openssl rand -hex 24)/" .env
# Set ARTIFACT_REPO to <owner>/<name> of this repo:
ARTIFACT_REPO_VAL=$(git config --get remote.origin.url | sed -E 's#^(git@|https?://)github.com[:/]##; s#\.git$##')
sed -i "s|^ARTIFACT_REPO=.*|ARTIFACT_REPO=${ARTIFACT_REPO_VAL}|" .env
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

`docker compose down -v` wipes **everything** — mysql data **and** the named volumes `auth_etc` / `world_etc`, which on first start were seeded from the in-image `*.conf.dist` templates. The next `compose up` will re-copy the .dist files and re-substitute env values, so any operator edits you made to `authserver.conf` / `worldserver.conf` will be lost. Destructive — only run this when you actually want to start from scratch and re-edit your configs.

`docker compose down` (no `-v`) keeps all volumes, so configs and mysql data survive. Use this for routine restarts.

## Networking

| Port | Purpose | Exposed |
|------|---------|---------|
| 3724 | Auth server (clients connect here) | yes (host) |
| 8085 | World server (clients connect here) | yes (host) |
| 3306 | MySQL | NO — internal only |

## Local dev builds

`scripts/dev-build.sh` builds SkyFire_548 from source and produces
`dist/skyfire-authserver-bin.tar.gz` and `dist/skyfire-worldserver-bin.tar.gz`
on the host. Useful for `tar -xzf … -C /opt/skyfire` on a host that already
has the toolchain, or for swapping a tarball into a custom Dockerfile.

The Dockerfiles in this repo always `curl` from a GitHub Release tagged
`authserver-${ARTIFACT_TAG}` / `worldserver-${ARTIFACT_TAG}` and do **not**
consume the `./dist/` output. Setting `ARTIFACT_TAG=local` in `.env` will
make `docker compose build` 404 against the GitHub Releases API — if you want
the local tarball, extract it into `/opt/skyfire` yourself or build a custom
image that does the copy.
