# AGENT.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Docker HTTPS reverse-proxy gateway — nginx + acme.sh (freessl.cn ACME) with Tencent DNS validation. Issues a wildcard cert (`*.${DOMAIN}`) so any subdomain added later in `conf.d/` shares the same cert.

## Files

| File                  | Role                                                                                                                                                           |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `entrypoint.sh`       | Container entrypoint — cert lifecycle (self-signed bootstrap → ACME issue → 1h renew), conf.d + cert change watcher (60s poll → `nginx -t && nginx -s reload`) |
| `nginx.conf`          | `envsubst` template — HTTP→HTTPS redirect, root domain static page, `include /etc/nginx/dynamic.d/*.conf` for subdomain server blocks                          |
| `.env`                | ACME server URL, EAB credentials, `DOMAIN`                                                                                                                     |
| `docker-compose.yaml` | Docker Compose service definition with volume mounts and env vars                                                                                              |
| `Dockerfile`          | Custom image based on `nginx:latest` with acme.sh + Debian packages (openssl, curl, socat, bash, procps, cron) baked in                                        |
| `build.sh`            | Build, tag, and push image to private registry (follows `server-rs/build.sh` pattern)                                                                          |
| `conf.d/`             | Volume-mapped — drop `.conf` files here to add subdomain → upstream routes                                                                                     |

## How certs work

1. On first start: generates a 1-day self-signed cert so nginx can boot
2. Background: acme.sh registers account with EAB, issues cert for `${DOMAIN}` + `*.${DOMAIN}` via `dns_tencent` plugin (needs `TENCENT_SECRET_ID` / `TENCENT_SECRET_KEY` env vars)
3. Renewal check every hour via `acme.sh --renew --force`
4. Certs land in `/certs/${DOMAIN}/`, copied to `/etc/nginx/ssl/${DOMAIN}/` for nginx

## Key gotchas

-   **osxfs glob SIGSEGV**: nginx `include /etc/nginx/conf.d/*.conf;` segfaults on macOS Docker Desktop bind mounts. Workaround: nginx includes from `/etc/nginx/dynamic.d/*.conf` (native Linux dir), and `entrypoint.sh` syncs `conf.d` → `dynamic.d` via `cp`.
-   **conf.d only for subdomain upstreams**: do NOT put root-domain server blocks in `conf.d/` — they're already in `nginx.conf`. `conf.d/` files must define their own `ssl_certificate` / `ssl_certificate_key` pointing to `/etc/nginx/ssl/${DOMAIN}/`.
-   **ACME stale state**: freessl.cn caches authorizations. `issue_certificate()` cleans `/root/.acme.sh/${DOMAIN}_ecc` before issuing with `--force --dnssleep 60` to get fresh authorizations.

## Run

```bash
# Build and push the image first
cd gateway-dev
./build.sh

# Then deploy
cd gateway-dev
docker compose up -d
```

Uses custom `nginx-with-acme` image built from `Dockerfile`. acme.sh and Debian packages are baked into the image — no runtime bootstrap needed. Build and push via `build.sh`.

## conf.d usage

Drop a `.conf` file into `conf.d/`, the 60s poller picks it up:

```nginx
# conf.d/api.conf
server {
    listen 443 ssl http2;
    server_name api.${DOMAIN};

    ssl_certificate /etc/nginx/ssl/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}/key.pem;

    location / {
        proxy_pass http://some-backend:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

The watcher runs `nginx -t` before reload — a broken conf is safely skipped.
