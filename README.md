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
ARTIFACT_REPO_VAL=$(git config --get remote.origin.url | sed 's#.*github.com[:/]##; s#.git$##')
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
