# Nessus Docker Container

[![Docker](https://img.shields.io/badge/docker-ready-brightgreen)](https://www.docker.com/)
[![Docker Compose](https://img.shields.io/badge/docker--compose-ready-brightgreen)](https://docs.docker.com/compose/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-linux%20amd64-lightgrey)](https://www.debian.org/)

Docker image for Tenable Nessus with feed patching (lab / educational use).

## Features

- Install Nessus on first run (Tenable API or `NESSUS_DEB_URL`)
- Patch `plugin_feed_info.inc` / `.plugin_feed_info.inc` and sync to `lib/nessus/plugins`
- `chattr +i` on feed files and plugin tree when `LINUX_IMMUTABLE` is available; avoids feed metadata being overwritten after plugin compile
- Admin user from environment
- Plugin update script and optional interval updates
- Cached plugin set when `plugins.php` is unreachable
- `nessusd.rules` default accept for remote scans
- Optional HTTP/HTTPS/SOCKS proxy for Tenable and plugin downloads (`NESSUS_*`); omit for direct outbound from the scripts’ perspective

## Quick Start

```bash
cp env.example .env
# Edit .env: credentials, NESSUS_UPDATE_URL, optional NESSUS_CERT_SAN, optional NESSUS_* proxy

docker compose up -d
```

Open `https://localhost:8834` (accept the self-signed certificate unless you use `NESSUS_CERT_SAN`).

## First Run (sequence)

1. Download and install the `.deb` (via API or `NESSUS_DEB_URL`).
2. Initialize `global.db` or apply patch if the DB already exists.
3. TLS rules / optional custom cert (`NESSUS_CERT_SAN`).
4. Start Nessus, create admin from `NESSUS_USERNAME` / `NESSUS_PASSWORD`.
5. Run `configure-nessus.sh` (telemetry, auto-update off, etc.).
6. If `NESSUS_UPDATE_URL` is set and `.update_completed` is missing, run `update.sh` once (download, `nessuscli update`, patch, repatch after compile only if immutable lock did not apply).

First run often takes 5–15 minutes depending on plugin compile.

## Configuration

| Variable | Description |
|----------|-------------|
| `NESSUS_USERNAME` | Admin login (default: `admin`) |
| `NESSUS_PASSWORD` | Admin password |
| `NESSUS_UPDATE_URL` | Full URL for `all-2.0.tar.gz` plugin feed |
| `NESSUS_DEB_URL` | Direct `.deb` URL; skips `www.tenable.com` API |
| `NESSUS_AUTO_UPDATE_INTERVAL` | Run `update.sh` every *N* hours (optional) |
| `NESSUS_CERT_SAN` | Comma-separated IPs/hostnames for the server cert; first value is used in the ready banner URL |
| `NESSUS_PROXY` | Optional: used as both HTTP and HTTPS proxy if the specific vars below are unset |
| `NESSUS_HTTP_PROXY` | Optional: `http_proxy` / `HTTP_PROXY` for tools in the image |
| `NESSUS_HTTPS_PROXY` | Optional: `https_proxy` / `HTTPS_PROXY` (API, `.deb`, `plugins.nessus.org`, plugin download) |
| `NESSUS_ALL_PROXY` | Optional: e.g. `socks5h://host:1080` for curl’s `all_proxy` |
| `NESSUS_NO_PROXY` | Optional: bypass list when a proxy is active; default always includes `localhost` / `127.0.0.1` / `::1` so local Nessus checks are not proxied |

If you set none of `NESSUS_PROXY`, `NESSUS_HTTP_PROXY`, `NESSUS_HTTPS_PROXY`, or `NESSUS_ALL_PROXY`, the entrypoint / `patch.sh` / `update.sh` do not add outbound proxy env. If the container already has `HTTP_PROXY`/`HTTPS_PROXY` from Docker Desktop or the host, `nessus-proxy.sh` still sets `no_proxy` for localhost so `curl` to `https://localhost:8834` works.

**Compose**

- Volume: `nessus_data:/opt/nessus`
- Port: `8834`
- `cap_add: LINUX_IMMUTABLE` — needed for `chattr +i` in `patch.sh`. Without it, the patch still applies; `update.sh` may run an extra repatch after compile.

## Commands

```bash
docker compose logs -f nessus
docker exec -it nessus /usr/local/bin/update.sh
docker exec -it nessus /bin/bash
curl -k https://localhost:8834/server/status
```

## Removing the data volume

`patch.sh` may set the immutable attribute (`chattr +i`) on the plugin tree. Docker then cannot delete those files, and `docker compose down -v` fails with `operation not permitted` on `.nasl` paths.

1. Stop the stack (container must not be using the volume):

   ```bash
   docker compose down
   ```

2. Mount the same volume once and clear immutable flags (needs `LINUX_IMMUTABLE` from the service, same as normal runs):

   ```bash
   docker compose run --rm --no-deps nessus /usr/local/bin/patch.sh --feed-unlock
   ```

3. Remove the volume:

   ```bash
   docker compose down -v
   ```

   Or: `docker volume rm nessus-test_nessus_data` (name may differ; use `docker volume ls`).

If Compose warns that the volume *already exists but was not created by Compose*, the volume was left from a failed removal. After step 2, remove it with `docker volume rm …` and run `docker compose up -d` again so Compose creates a labeled volume.

## Docker (without Compose)

```bash
docker build -t nessus .
docker run -d --name nessus -p 8834:8834 \
  --cap-add LINUX_IMMUTABLE \
  -e NESSUS_USERNAME=admin -e NESSUS_PASSWORD=yourpassword \
  -v nessus_data:/opt/nessus --restart always nessus
```

Add `-e NESSUS_HTTPS_PROXY=...` or `-e NESSUS_PROXY=...` when you need a proxy.

## Adding Users

Admin is created from the environment. For more users:

```bash
docker exec -it nessus /bin/bash
/opt/nessus/sbin/nessuscli adduser
```

## Updating Plugins

Manual:

```bash
docker exec -it nessus /usr/local/bin/update.sh
```

Custom URL:

```bash
docker exec -it nessus /usr/local/bin/update.sh "https://plugins.nessus.org/v2/nessus.php?f=all-2.0.tar.gz&u=USER&p=PASS"
```

Automatic: set `NESSUS_AUTO_UPDATE_INTERVAL=24` in `.env`.

## API

Session token:

```bash
TOKEN=$(curl -s -k -X POST "https://localhost:8834/session" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"yourpassword"}' \
  | grep -oP '"token":"\K[^"]+')
curl -s -k -X GET "https://localhost:8834/scans" -H "X-Cookie: token=$TOKEN"
```

API keys (Nessus UI: My Account → API Keys):

```bash
curl -s -k -X GET "https://localhost:8834/scans" \
  -H "X-ApiKeys: accessKey=KEY; secretKey=SECRET"
```

## Project Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Image build |
| `docker-compose.yml` | Stack, caps, env |
| `docker-entrypoint.sh` | Install, DB, patch, user, updates, health loop |
| `nessus-proxy.sh` | Optional proxy env for entrypoint / patch / update |
| `patch.sh` | Feed files, optional immutable lock |
| `update.sh` | Plugin tarball download and `nessuscli update` |
| `configure-nessus.sh` | Nessus CLI fixes (theme, telemetry, updates) |
| `env.example` | Environment template |

## Logging

Startup and `[update]` lines are full sentences; errors and warnings use the `Error:` / `Warning:` prefix where relevant.
