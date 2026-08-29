# Nextcloud 34 + Euro-Office on a Single Ubuntu 24.04 VM behind Pangolin

**Production runbook v2 — field-verified, built to run for years**

| | |
|---|---|
| VM | `192.168.42.22` (private, no public IP, no inbound service ports) |
| Nextcloud | `https://ecloud.fiberathome.net` |
| Euro-Office | `https://eoffice.fiberathome.net` |
| Pangolin gateway | `https://urlsec.fiberathome.net` |
| OS | Ubuntu 24.04 LTS · 12 vCPU / 12 GB RAM |
| Status | Deployed, tuned, reboot-tested — August 2026 |

Every command here was run on the real host. §14 is an incident log of things that actually broke, not hypotheticals. **v2 adds:** HSTS placement, the `--force-recreate` rule, opcache sizing, the NC 34.0.3 previews bug, SMTP, and setup-warning triage.

---

## 1. Read this first — six things that will break your build

### 1.1 `X-Forwarded-Proto: https` is mandatory on both Pangolin resources

**The single most important line in this document.**

Pangolin forwards `X-Forwarded-Proto: http` by default. The Euro-Office Document Server reads that header to construct its own asset URLs, so it emits:

```
"Editor.bin": "http://eoffice.fiberathome.net/cache/files/data/..."
```

The browser is on `https://`, blocks those as mixed content, and the editor reports **"Download failed."** Server-side everything succeeds — the document is fetched, converted, and served. Nothing is logged as an error. You will chase JWT secrets, file permissions, private-IP filters, and startup races for hours before finding it.

Fix: custom **request** header on **both** resources (§10.3).

### 1.2 Switch the iptables backend *before* installing Docker

Ubuntu 24.04 defaults to `iptables-nft`. Install `docker-ce` first and dockerd immediately writes its chains — including `FORWARD` policy `DROP` — into the **nft** backend. Switching to `iptables-legacy` afterwards makes Docker rebuild in legacy, but **the stale nft rules remain live in the kernel** and silently drop all container-to-container traffic.

Symptom: `PDOException: SQLSTATE[HY000] [2002] Connection timed out` during install, while `iptables-legacy -S FORWARD` looks perfect. DNS still resolves (handled inside the container namespace, never crosses FORWARD), which makes it look like a database fault.

Fix: `update-alternatives` before `apt-get install docker-ce` (§4).

### 1.3 The Euro-Office container takes no bind mounts

The fork rebranded every path: `/var/log/euro-office/`, `/etc/euro-office/`, `/var/www/euro-office/`. Mounting old OnlyOffice paths does nothing. Mounting the *new* ones breaks it three different ways:

- Empty bind mount over the log dir → supervisord can't create subdirectories → DS never starts.
- The entrypoint **generates `local.json` itself**, writing a `.tmp` then `mv`-ing it. A read-only mount makes that `mv` fail with `Device or resource busy` → crash loop.
- `App_Data` doesn't exist at the path older docs suggest.

Fix: declare the service with **no `volumes:` key at all** (§8). Everything under those paths is generated at startup or regenerable cache.

### 1.4 The Document Server needs 60–90 seconds to start

With no volumes it regenerates fonts, presentation themes, and JS caches on every start. Its nginx accepts connections long before docservice binds port 8000, so anything arriving in that window gets `502 Bad Gateway` or `connection refused` **from the upstream**.

Any check run too early looks like a hard failure. Wait for `Express server listening on port 8000` in the docservice log before believing a failure is real.

### 1.5 Nextcloud logs in UTC; your containers are in Dhaka

`TZ=Asia/Dhaka` governs the containers, but `occ log:tail` timestamps are **UTC**. The 6-hour offset makes stale errors look current. During this build, two separate rabbit holes came from treating a `13:19:54Z` entry as new when it was 19:19:54 local — from before the container had restarted.

Convert before concluding an error is live. Better: clear the log, reproduce, then read.

### 1.6 Mounted config edits need `--force-recreate`

Editing a file that's bind-mounted into a container changes nothing on its own. `docker compose up -d` only recreates when the **service definition** changes — a modified mounted file doesn't count, so the old process keeps running with the old settings.

This cost a debugging cycle when opcache tuning appeared not to apply: the `.ini` said `64`, PHP still reported `32`.

```bash
docker compose up -d --force-recreate app cron
```

Applies to `zz-tuning.ini`, `hsts.conf`, and anything else mounted from `config-php/`.

---

## 2. Architecture

```
  browser ──https──► ecloud.fiberathome.net   ─┐
  browser ──https──► eoffice.fiberathome.net  ─┤
                                               │  DNS → Pangolin public IP
                                               ▼
                       Pangolin @ urlsec.fiberathome.net
              Traefik + Let's Encrypt · SSO OFF · X-Forwarded-Proto: https
                                               │
                                    WireGuard, outbound-initiated
                                               ▼
                            Newt  (host network, on this VM)
                                 │                      │
                     127.0.0.1:8080            127.0.0.1:6233
                                 ▼                      ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  docker network nc-net · 172.28.0.0/16                        │
   │                                                               │
   │      app  ◄──────────── internal ───────────►  eurooffice     │
   │   (NC 34.0.3)   NC→DS  http://eurooffice/      (DS v9.3.1)    │
   │       │         DS→NC  http://app/                            │
   │       ▼                                                       │
   │      db (MariaDB 11.4)     redis      cron                    │
   └──────────────────────────────────────────────────────────────┘
```

Only browser traffic uses the public names. Internal hops stay on the Docker bridge — one DNS lookup, no proxy, no tunnel, no hairpin NAT.

**Security posture:** Newt dials out; nothing on this VM listens publicly. Both services bind `127.0.0.1`, so the kernel refuses externally-sourced packets to them by construction. The only inbound port is SSH.

---

## 3. Parameters

| Item | Value |
|---|---|
| Stack dir | `/docker/nextcloud` |
| Newt dir | `/docker/newt` (separate stack, deliberately) |
| Nextcloud | `nextcloud:34.0.3-apache` → `127.0.0.1:8080` |
| Euro-Office DS | `ghcr.io/euro-office/documentserver:v9.3.1` → `127.0.0.1:6233` |
| MariaDB | `mariadb:11.4` (LTS, EOL May 2029) |
| Redis | `redis:7.4-alpine` |
| Newt | `fosrl/newt:1.16.0` |
| Docker subnet | `172.28.0.0/16` (pinned — `trusted_proxies` depends on it) |
| SSH | `8022`, admin CIDRs only |
| Timezone | `Asia/Dhaka` |

Nextcloud **34 = Hub 26 Spring** (released 9 June 2026, same day as Euro-Office GA). Nextcloud 33 is Hub 26 Winter — don't confuse them. NC 34 is supported until **June 2027**.

**Sizing.** The DS is the heavy component. 4 vCPU / 8 GB is the practical floor. Budget roughly: DS 3–4 GB, MariaDB 3 GB, Nextcloud PHP 2 GB, Redis small.

---

## 4. OS and Docker

Order matters — see §1.2.

```bash
sudo apt-get update && sudo apt-get -y upgrade
sudo timedatectl set-timezone Asia/Dhaka
sudo apt-get -y install ca-certificates curl gnupg openssl iptables iptables-persistent jq
sudo systemctl disable --now ufw 2>/dev/null || true
sudo apt-get -y purge ufw 2>/dev/null || true
```

IPv4-only:

```bash
sudo tee /etc/sysctl.d/99-disable-ipv6.conf >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sudo sysctl --system
```

Swap (protects the DS from OOM during conversion bursts):

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

**Switch the iptables backend BEFORE Docker exists:**

```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
iptables --version    # must say (legacy)
```

Now install Docker:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "ipv6": false,
  "ip6tables": false,
  "userland-proxy": false,
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  }
}
EOF

sudo systemctl restart docker
docker --version && docker compose version
```

**Verify no split backend** — five seconds, saves an hour:

```bash
sudo iptables-legacy -S FORWARD | head -3
sudo iptables-nft     -S FORWARD | head -3
```

The nft side must **not** show `-P FORWARD DROP` or `DOCKER*` chains. If it does:

```bash
sudo iptables-nft -P FORWARD ACCEPT
sudo iptables-nft -F
sudo iptables-nft -t nat -F
sudo systemctl restart docker
```

---

## 5. Secrets

```bash
sudo mkdir -p /docker/nextcloud/config-php
cd /docker/nextcloud

DB_ROOT=$(openssl rand -hex 16)
DB_PASS=$(openssl rand -hex 16)
NC_ADMIN_PASS=$(openssl rand -hex 12)
EO_JWT=$(openssl rand -hex 24)
printf 'DB_ROOT=%s\nDB_PASS=%s\nNC_ADMIN_PASS=%s\nEO_JWT=%s\n' \
  "$DB_ROOT" "$DB_PASS" "$NC_ADMIN_PASS" "$EO_JWT"
```

> **JWT must be ≥32 characters.** Euro-Office requires it; shorter secrets fail the connector handshake with an opaque connection error. `openssl rand -hex 24` gives 48 hex chars.

Vault all four now.

---

## 6. `.env`

```bash
cd /docker/nextcloud
cat > .env <<EOF
# ---- Images (pinned; upgrades are a deliberate edit here) ----
NC_IMAGE=nextcloud:34.0.3-apache
EO_IMAGE=ghcr.io/euro-office/documentserver:v9.3.1
DB_IMAGE=mariadb:11.4
REDIS_IMAGE=redis:7.4-alpine

# ---- Database ----
MYSQL_ROOT_PASSWORD=${DB_ROOT}
MYSQL_PASSWORD=${DB_PASS}
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud

# ---- Nextcloud bootstrap (install-time only) ----
NEXTCLOUD_ADMIN_USER=ncadmin
NEXTCLOUD_ADMIN_PASSWORD=${NC_ADMIN_PASS}
NEXTCLOUD_TRUSTED_DOMAINS=ecloud.fiberathome.net app localhost

# ---- Reverse proxy (RUNTIME - read on every request) ----
NC_TRUSTED_PROXIES=172.28.0.0/16
NC_HOST=ecloud.fiberathome.net

# ---- Limits ----
PHP_UPLOAD_LIMIT=2G

# ---- Euro-Office ----
EO_JWT_SECRET=${EO_JWT}

# ---- Host bindings (loopback only) ----
NC_BIND=127.0.0.1:8080
EO_BIND=127.0.0.1:6233

TZ=Asia/Dhaka
EOF

chmod 600 .env
```

`NEXTCLOUD_TRUSTED_DOMAINS` is **space-separated** and must include `app` — the Document Server fetches files from Nextcloud using that internal hostname, and Nextcloud rejects untrusted Host headers.

> **Never also set the reverse-proxy values via `occ`.** They're read at runtime from the environment by the image's `reverse-proxy.config.php`. Setting them in both places creates two sources of truth that drift. If you accidentally do, remove the `config.php` copy:
> ```bash
> nc-occ config:system:delete overwrite.cli.url
> nc-occ config:system:get overwrite.cli.url   # still returns the env value
> ```

---

## 7. Mounted config files

**PHP tuning** — sized for 12 GB / 12 cores. Note `interned_strings_buffer=64`; the default 32 triggers a Nextcloud warning that the buffer is nearly full.

```bash
cat > /docker/nextcloud/config-php/zz-tuning.ini <<'EOF'
memory_limit=1024M
opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=64
opcache.max_accelerated_files=20000
opcache.memory_consumption=256
opcache.save_comments=1
opcache.revalidate_freq=60
apc.shm_size=256M
apc.enable_cli=1
EOF
```

**HSTS** — see §10.4 for why this lives in Apache and not in Pangolin.

```bash
cat > /docker/nextcloud/config-php/hsts.conf <<'EOF'
Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
EOF
```

---

## 8. `docker-compose.yml`

```bash
cat > /docker/nextcloud/docker-compose.yml <<'EOF'
---
services:
  db:
    image: ${DB_IMAGE}
    container_name: nc-db
    restart: unless-stopped
    command:
      - --transaction-isolation=READ-COMMITTED
      - --log-bin=binlog
      - --binlog-format=ROW
      - --expire-logs-days=7
      - --innodb-file-per-table=1
      - --innodb-buffer-pool-size=2G
      - --innodb-log-file-size=512M
      - --innodb-flush-method=O_DIRECT
    environment:
      - MARIADB_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MARIADB_PASSWORD=${MYSQL_PASSWORD}
      - MARIADB_DATABASE=${MYSQL_DATABASE}
      - MARIADB_USER=${MYSQL_USER}
      - MARIADB_AUTO_UPGRADE=1
      - TZ=${TZ}
    volumes:
      - ./data/db:/var/lib/mysql
    healthcheck:
      test:
        - CMD
        - healthcheck.sh
        - --connect
        - --innodb_initialized
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 60s
    networks:
      - nc-net

  redis:
    image: ${REDIS_IMAGE}
    container_name: nc-redis
    restart: unless-stopped
    command:
      - redis-server
      - --save
      - "60"
      - "1"
    volumes:
      - ./data/redis:/data
    healthcheck:
      test:
        - CMD
        - redis-cli
        - ping
      interval: 15s
      timeout: 5s
      retries: 5
    networks:
      - nc-net

  app:
    image: ${NC_IMAGE}
    container_name: nc-app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      - "${NC_BIND}:80"
    environment:
      - MYSQL_HOST=db
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - REDIS_HOST=redis
      - NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=${NEXTCLOUD_TRUSTED_DOMAINS}
      - TRUSTED_PROXIES=${NC_TRUSTED_PROXIES}
      - OVERWRITEPROTOCOL=https
      - OVERWRITEHOST=${NC_HOST}
      - OVERWRITECLIURL=https://${NC_HOST}
      - PHP_UPLOAD_LIMIT=${PHP_UPLOAD_LIMIT}
      - PHP_MEMORY_LIMIT=1024M
      - TZ=${TZ}
    volumes:
      - ./data/nextcloud:/var/www/html
      - ./config-php/zz-tuning.ini:/usr/local/etc/php/conf.d/zz-tuning.ini:ro
      - ./config-php/hsts.conf:/etc/apache2/conf-enabled/hsts.conf:ro
    networks:
      - nc-net

  cron:
    image: ${NC_IMAGE}
    container_name: nc-cron
    restart: unless-stopped
    entrypoint: /cron.sh
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      - TZ=${TZ}
    volumes:
      - ./data/nextcloud:/var/www/html
      - ./config-php/zz-tuning.ini:/usr/local/etc/php/conf.d/zz-tuning.ini:ro
    networks:
      - nc-net

  eurooffice:
    image: ${EO_IMAGE}
    container_name: nc-eurooffice
    restart: unless-stopped
    ports:
      - "${EO_BIND}:80"
    environment:
      - JWT_ENABLED=true
      - JWT_SECRET=${EO_JWT_SECRET}
      - JWT_HEADER=Authorization
      - TZ=${TZ}
    networks:
      - nc-net

networks:
  nc-net:
    name: nc-net
    ipam:
      config:
        - subnet: 172.28.0.0/16
EOF
```

Notes:
- `eurooffice` has **no `volumes:` key**. Deliberate and load-bearing — §1.3.
- `hsts.conf` mounts to `app` only; `cron` serves no HTTP.
- MariaDB `READ-COMMITTED` + `binlog-format=ROW` are Nextcloud **requirements**, not preferences. `MARIADB_AUTO_UPGRADE=1` runs `mariadb-upgrade` after an image bump — the step people forget.

```bash
cd /docker/nextcloud
docker compose config > /dev/null && echo VALID
```

---

## 9. First start

```bash
cd /docker/nextcloud
docker compose pull
docker compose up -d
docker compose logs -f app
```

Wait for `Nextcloud was successfully installed` and `Initializing finished`.

> **If the install fails partway** (e.g. §1.2), the entrypoint has already written `version.php`. On the next start it sees that file, assumes Nextcloud is installed, skips the install, and starts Apache against an empty database — a silent half-state. Fix the underlying problem, then wipe:
> ```bash
> docker compose down
> sudo rm -rf data/nextcloud data/db data/redis
> docker compose up -d
> ```

Install the `occ` helper:

```bash
sudo tee /usr/local/bin/nc-occ >/dev/null <<'EOF'
#!/usr/bin/env bash
exec docker compose -f /docker/nextcloud/docker-compose.yml exec -T --user www-data app php occ "$@"
EOF
sudo chmod 755 /usr/local/bin/nc-occ
```

Local verification:

```bash
curl -sI http://127.0.0.1:8080/            | head -1   # 302
curl -s  http://127.0.0.1:6233/healthcheck              # true
```

To reach the UI before Pangolin exists, tunnel rather than expose:

```bash
ssh -p 8022 -L 8080:127.0.0.1:8080 <user>@192.168.42.22
# browse http://localhost:8080
```

Baseline settings — note `background:cron`, **not** `background:job:mode` (renamed in NC 34):

```bash
nc-occ background:cron
nc-occ config:app:get core backgroundjobs_mode     # cron
nc-occ config:system:set default_phone_region --value=BD
nc-occ config:system:set maintenance_window_start --type=integer --value=20
nc-occ db:add-missing-indices

# 4-byte UTF-8 — cheap now on an empty DB, disruptive later
nc-occ config:system:get mysql.utf8mb4 || {
  nc-occ config:system:set mysql.utf8mb4 --type=boolean --value=true
}

# Mimetype migrations — fast on an empty instance, slow once populated. Do it now.
nc-occ maintenance:repair --include-expensive
```

---

## 10. Pangolin

### 10.1 Newt tunnel

Dashboard → **Sites → Add Site** → **Newt Tunnel**. Copy Endpoint, ID, Secret.

On the VM, as a **separate stack** so a Nextcloud `down` never drops the tunnel:

```bash
sudo mkdir -p /docker/newt
cd /docker/newt

cat > .env <<'EOF'
NEWT_IMAGE=fosrl/newt:1.16.0
PANGOLIN_ENDPOINT=https://urlsec.fiberathome.net
NEWT_ID=REPLACE_ME
NEWT_SECRET=REPLACE_ME
EOF
chmod 600 .env

cat > docker-compose.yml <<'EOF'
---
services:
  newt:
    image: ${NEWT_IMAGE}
    container_name: newt
    restart: unless-stopped
    network_mode: host
    environment:
      - PANGOLIN_ENDPOINT=${PANGOLIN_ENDPOINT}
      - NEWT_ID=${NEWT_ID}
      - NEWT_SECRET=${NEWT_SECRET}
EOF

docker compose config > /dev/null && echo VALID
docker compose up -d
docker inspect newt --format '{{.HostConfig.NetworkMode}}'   # MUST print: host
docker ps --format '{{.Names}}\t{{.Ports}}' | grep newt      # PORTS must be EMPTY
docker logs -f newt
```

> **`network_mode: host` is mandatory.** Newt must reach `127.0.0.1:8080` and `127.0.0.1:6233`. On a bridge network, `localhost` is Newt's own namespace and both targets resolve to nothing — the classic "site Online but resource 502s". **If `docker ps` shows any port for newt, host networking did not apply.**

Expect: `Tunnel connection to server established successfully!`, then `Started tcp proxy to 127.0.0.1:8080` and `...:6233`.

Newt needs outbound HTTPS to the gateway plus outbound WireGuard UDP (commonly 51820/21820). Keep the pinned version at or near the gateway's own version — a much older Newt may warn or misbehave.

### 10.2 The two resources

| Field | Nextcloud | Euro-Office |
|---|---|---|
| Name | `Nextcloud` | `Euro-Office` |
| Domain | `ecloud.fiberathome.net` | `eoffice.fiberathome.net` |
| Type | HTTP | HTTP |
| Target method | `http` | `http` |
| Target host | `127.0.0.1` | `127.0.0.1` |
| Target port | `8080` | `6233` |
| **Platform SSO** | **OFF** | **OFF** |

**SSO must be off on both.** On the Nextcloud resource it breaks every desktop client, mobile app, WebDAV mount and CalDAV/CardDAV sync — none can render an interactive login page. On the Euro-Office resource it breaks the editor entirely, because the browser loads DS assets as sub-resources that can't be redirected through a login. For edge access control use Pangolin source-IP rules instead.

### 10.3 Custom request headers — the critical step

On **both** resources, in **Custom Request Headers**:

```
x-forwarded-proto: https
```

Without this the DS emits `http://` asset URLs and the editor fails with "Download failed" (§1.1). Nextcloud survives without it only because `OVERWRITEPROTOCOL=https` compensates — set it on both anyway.

### 10.4 HSTS goes in Apache, not Pangolin

Pangolin's **Custom Request Headers** field sends headers *downstream to your targets* — its own hint says so. HSTS is a **response** header that must reach the browser, so putting it there does nothing but send a meaningless header to Nextcloud.

If your Pangolin build exposes a separate **response headers** or security-headers option, use it. Otherwise set it in Apache via the mount from §7 — which is what this build does:

```bash
docker exec nc-app apachectl -M 2>/dev/null | grep headers   # headers_module (shared)
curl -sI https://ecloud.fiberathome.net/ | grep -i strict
```

> `includeSubDomains` commits every `*.fiberathome.net` host to HTTPS-only for six months in browsers that have seen the header. Drop that directive if you run plain-HTTP hosts on that domain.

### 10.5 Block the DS admin panel

The Document Server exposes `/admin/` on its hostname. It ships with `adminpanel` stopped, so the page is an inert shell today — but if a future version starts that service, an unclaimed admin panel becomes publicly claimable.

Add a Pangolin path rule on the `eoffice` resource denying `/admin`:

```bash
curl -sI https://eoffice.fiberathome.net/admin/ | head -1    # expect 403/404
```

### 10.6 DNS

Point both names at the Pangolin gateway's public IP. Pangolin issues Let's Encrypt certificates automatically. Behind Cloudflare, set both records to **DNS-only (grey cloud)** or the ACME challenge fails.

### 10.7 Upload limits

`PHP_UPLOAD_LIMIT=2G` is what users see. Nextcloud **chunks** uploads, so Pangolin never sees a 2 GB body from the web UI or desktop client — a gateway limit only affects single-shot uploads (WebDAV, curl, some mobile apps). If Pangolin exposes a body-size setting, set it slightly **above** your PHP limit (e.g. `2200M`) so Nextcloud returns a real error rather than the proxy returning a bare 413.

Optional, for flaky links:

```bash
nc-occ config:system:set max_chunk_size --type=integer --value=52428800   # 50MB
```

---

## 11. Verify reverse-proxy config

Applied via environment. **Verify, don't duplicate:**

```bash
nc-occ config:system:get trusted_proxies      # 172.28.0.0/16
nc-occ config:system:get overwritehost        # ecloud.fiberathome.net
nc-occ config:system:get overwriteprotocol    # https
nc-occ config:system:get trusted_domains      # includes ecloud... and app
docker exec nc-app env | grep -E 'TRUSTED|OVERWRITE'
```

---

## 12. Euro-Office connector

```bash
cd /docker/nextcloud
nc-occ app:install eurooffice
nc-occ app:enable eurooffice

# Browser-facing (through Pangolin):
nc-occ config:app:set eurooffice DocumentServerUrl --value="https://eoffice.fiberathome.net/"
# Internal, stays on the Docker bridge:
nc-occ config:app:set eurooffice DocumentServerInternalUrl --value="http://eurooffice/"
nc-occ config:app:set eurooffice StorageUrl --value="http://app/"
# Shared JWT:
nc-occ config:app:set eurooffice jwt_secret --value="$(grep '^EO_JWT_SECRET=' .env | cut -d= -f2)"
nc-occ config:app:set eurooffice jwt_header --value="Authorization"

nc-occ eurooffice:documentserver --check
```

Expect: `Document server https://eoffice.fiberathome.net/ version 9.3.1.37 is successfully connected`.

**Why the URL split:** leave the internal URLs blank and both hops fall back to the public name, so NC→DS and DS→NC traffic leaves the VM, climbs the tunnel to Pangolin, and comes back down. Slow at best, broken if the LAN can't hairpin.

**ODF formats.** `.odt`/`.ods`/`.odp` download instead of opening until enabled. The connector writes no format keys by default — configure them in the admin UI, **not** by guessing `occ` keys (invented keys are accepted silently and do nothing):

```
https://ecloud.fiberathome.net/settings/admin/eurooffice
```

Then record what actually got written:

```bash
nc-occ config:list eurooffice
```

---

## 13. Firewall

Loopback binding means there's nothing to filter for the services. Only SSH is inbound.

```bash
sudo tee /usr/local/sbin/nc-fw.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# Nextcloud + Euro-Office VM firewall (iptables only)
# Services bind 127.0.0.1 and publish via the outbound Pangolin/Newt tunnel,
# so no inbound service ports exist. INPUT covers SSH and ICMP only.
set -euo pipefail
IPT=/usr/sbin/iptables

SSH_PORT=8022
ADMIN_NETS=("157.15.60.0/23" "103.229.83.0/24" "103.7.248.0/24")
LAN_NETS=("192.168.42.0/24")

$IPT -P INPUT DROP
$IPT -F INPUT
$IPT -A INPUT -i lo -j ACCEPT
$IPT -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPT -A INPUT -m conntrack --ctstate INVALID -j DROP
$IPT -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/s -j ACCEPT
for net in "${ADMIN_NETS[@]}" "${LAN_NETS[@]}"; do
  $IPT -A INPUT -p tcp -s "$net" --dport "$SSH_PORT" -m conntrack --ctstate NEW -j ACCEPT
done
$IPT -A INPUT -m limit --limit 3/min -j LOG --log-prefix "FW-INPUT-DROP: " --log-level 4

# Safety net: published ports bypass INPUT and land here.
$IPT -F DOCKER-USER
$IPT -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
$IPT -A DOCKER-USER -s 172.16.0.0/12 -j RETURN
for net in "${ADMIN_NETS[@]}"; do
  $IPT -A DOCKER-USER -s "$net" -j RETURN
done
$IPT -A DOCKER-USER -i lo -j RETURN
$IPT -A DOCKER-USER -j DROP

echo "nc-fw: applied"
EOF

sudo chmod 750 /usr/local/sbin/nc-fw.sh
bash -n /usr/local/sbin/nc-fw.sh && echo SYNTAX_OK
```

The unit needs `PartOf=docker.service` — Docker rebuilds `DOCKER-USER` from scratch on every daemon start, and a plain `oneshot` won't re-run:

```bash
sudo tee /etc/systemd/system/nc-fw.service >/dev/null <<'EOF'
[Unit]
Description=Nextcloud VM iptables firewall
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/nc-fw.sh

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
```

**Confirm SSH is on 8022 before enabling**, and keep your current session open:

```bash
sudo ss -ltnp | grep sshd
sudo systemctl enable --now nc-fw.service
sudo iptables -S DOCKER-USER

# prove it survives a Docker restart
sudo systemctl restart docker && sleep 5
sudo iptables -S DOCKER-USER      # rules present, not a bare -N
```

---

## 14. Incident log — what actually went wrong

Every entry happened during this deployment.

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `PDOException ... Connection timed out` on install; DNS fine | Split iptables backend: stale nft `FORWARD DROP` alongside legacy | §1.2 / §4 |
| 2 | Install "succeeds" but no tables; Apache starts with no DB | Failed install left `version.php`; entrypoint skipped reinstall | Wipe `data/{nextcloud,db,redis}` |
| 3 | `Command "background:job:mode" is not defined` | NC 34 renamed it | `nc-occ background:cron` |
| 4 | Firewall rules vanish after `systemctl restart docker` | oneshot unit doesn't re-run; Docker rebuilds chains | `PartOf=docker.service` |
| 5 | Newt: `connection refused` to `127.0.0.1:6233` | Newt on bridge network, not host | `network_mode: host`; PORTS column must be empty |
| 6 | DS log directory empty; `/var/log/onlyoffice` unused | Fork rebranded paths to `/var/log/euro-office/` | Read real paths; don't mount them |
| 7 | DS crash-loop: `mv: ... local.json: Device or resource busy` | Entrypoint generates `local.json`; read-only mount blocks its `mv` | Remove the mount |
| 8 | DS won't start: `directory ... adminpanel/out.log does not exist` | Empty bind mount shadowed the log tree | Remove all bind mounts from DS |
| 9 | `--check` returns 502 right after restart | DS needs 60–90s to regenerate fonts/caches | Wait for `Express server listening` |
| 10 | Stale errors mistaken for live ones, twice | NC logs UTC; containers Dhaka (+6) | Clear log, reproduce, then read |
| 11 | **"Download failed"; nothing logged as error** | **Pangolin sent `X-Forwarded-Proto: http`; DS emitted `http://` asset URLs; browser blocked mixed content** | **`x-forwarded-proto: https` on both resources** |
| 12 | `.odt`/`.ods` download instead of opening | ODF not in the connector's editable set | Configure in `/settings/admin/eurooffice` |
| 13 | opcache tuning appears not to apply | `up -d` doesn't recreate on a mounted-file edit | `--force-recreate` (§1.6) |
| 14 | HSTS warning persists after adding header to Pangolin | That field sends **request** headers downstream; HSTS is a response header | Apache mount (§10.4) |

**Benign warnings — ignore:**

- `Sharp module failed to load ... EACCES /root/.cache` — upstream packaging issue in the fork; degrades image processing only.
- `io_uring_queue_init() failed with EPERM ... falling back to libaio` — normal on container hosts.
- `apache2: Could not reliably determine the server's fully qualified domain name` — cosmetic, permanent.
- `reaped unknown pid ... (terminated by SIGUSR1)` every 60s in the DS — its internal health cron.

**Where the DS actually logs:**

```bash
docker exec nc-eurooffice tail -60 /var/log/euro-office/documentserver/docservice/out.log
docker exec nc-eurooffice tail -40 /var/log/euro-office/documentserver/converter/out.log
docker exec nc-eurooffice tail -20 /var/log/euro-office/documentserver/nginx.error.log
```

Raise verbosity when debugging (default `WARN`):

```bash
docker exec nc-eurooffice sh -c \
  "sed -i 's/\"level\": \"WARN\"/\"level\": \"DEBUG\"/' /etc/euro-office/documentserver/log4js/production.json"
docker exec nc-eurooffice supervisorctl restart docservice converter
```

Reading `getBaseUrlByConnection ... x-forwarded-proto=` in the docservice log is how incident #11 was finally identified. Set back to `WARN` when done.

---

## 15. Post-deployment tuning and hardening

### 15.1 Two-factor authentication

```bash
nc-occ app:install twofactor_totp
nc-occ app:enable twofactor_totp
```

Enrol via **Personal settings → Security → Two-Factor Authentication**. Save the backup codes.

To enforce for all users:

```bash
nc-occ app:install twofactor_enforcement
nc-occ app:enable twofactor_enforcement
```

Scope under **Administration → Security**.

> **Enrol yourself before enabling enforcement.** With one admin account, enforcing first locks you out. Recovery is `nc-occ twofactor:disable ncadmin`, but avoid the scramble.

### 15.2 Landing page and interface

```bash
nc-occ config:system:set defaultapp --value="files"
nc-occ app:disable dashboard
nc-occ config:app:set text workspace_available --value=0   # no rendered Readme.md header
```

The recommended-files strip is per-user: **Files → settings (bottom of sidebar) → Show recommended files**.

### 15.3 SMTP — do this before onboarding users

Without it, password resets and share notifications fail silently, and cron-scheduled mail throws `Symfony\Component\Mailer\Exception\TransportException` repeatedly, flooding the log.

Configure under **Administration → Basic settings**, pointing at an existing relay, then use the **Send email** button to verify. Or via CLI:

```bash
nc-occ config:system:set mail_smtpmode --value="smtp"
nc-occ config:system:set mail_smtphost --value="<relay-host>"
nc-occ config:system:set mail_smtpport --type=integer --value=587
nc-occ config:system:set mail_smtpsecure --value="tls"
nc-occ config:system:set mail_from_address --value="nextcloud"
nc-occ config:system:set mail_domain --value="fiberathome.net"
```

### 15.4 Credential hygiene

Rotate anything that has appeared in a terminal transcript:

```bash
# Newt secret: delete and recreate the site in Pangolin, then
cd /docker/newt && vim .env && docker compose up -d

# Euro-Office JWT (rotate BOTH ends together, in a maintenance window)
cd /docker/nextcloud
NEW_JWT=$(openssl rand -hex 24)
sed -i "s|^EO_JWT_SECRET=.*|EO_JWT_SECRET=${NEW_JWT}|" .env
docker compose up -d eurooffice
sleep 90                                   # DS startup, §1.4
nc-occ config:app:set eurooffice jwt_secret --value="${NEW_JWT}"
nc-occ eurooffice:documentserver --check

# Admin password (env value is install-time only; safe to blank afterwards)
nc-occ user:resetpassword ncadmin
```

---

## 16. Setup-warning triage

Administration → Overview. Which of these matter:

| Warning | Priority | Action |
|---|---|---|
| **PHP opcache buffer nearly full** | Performance | Raise `interned_strings_buffer` to 64 (or 128), then `--force-recreate` |
| **Mimetype migrations available** | One-off | `nc-occ maintenance:repair --include-expensive` — fast now, slow later |
| **HSTS not set** | Security | §10.4 |
| **Errors in the log** | Depends | Read them (`nc-occ log:tail`) before clearing — see §17 |
| AppAPI deploy daemon | Informational | Only needed for External Apps (Ex-Apps). Ignore. |
| Configuration server ID | Informational | Multi-server setups only. Ignore. |
| Second factor not enforced | Informational | §15.1, once real users exist |
| Email not configured | **Real** | §15.3 |

**Reading and resetting the log baseline:**

```bash
nc-occ log:tail -n 50 | grep -iE 'error|fatal' | tail -15
# once the causes are understood/fixed:
docker exec -u www-data nc-app sh -c ': > /var/www/html/data/nextcloud.log'
docker exec nc-app ls -l /var/www/html/data/nextcloud.log   # 0 bytes
```

The count doesn't drop until the file is truncated, and Overview caches results for a few minutes.

---

## 17. Known issues — track these

### 17.1 Preview generation broken on NC 34.0.3

**Status: open upstream. Previews disabled on this instance.**

```
SQLSTATE[23000]: Integrity constraint violation: 1052
Column 'file_id' in WHERE is ambiguous
```

The preview mapper joins `oc_previews`, `oc_preview_locations` and `oc_preview_versions`, then filters on a bare `file_id` without a table alias. More than one of those tables has that column, so MariaDB rejects the query. The previews-in-database schema is new in NC 34, and this is a missing-alias bug in Nextcloud's own code — not fixable from configuration.

Impact: thumbnails fail (generic icons instead). No data loss. Log noise on every affected file.

Current mitigation:

```bash
nc-occ config:system:set enable_previews --type=boolean --value=false
```

**Re-test after 34.0.4 (due 10 September 2026):**

```bash
nc-occ config:system:set enable_previews --type=boolean --value=true
# browse a folder of images, then:
nc-occ log:tail -n 20 | grep -i dbal
```

Clean → leave enabled. Still failing → disable again and check `github.com/nextcloud/server` issues.

### 17.2 Euro-Office is young

GA'd 9 June 2026; the DS is v9.3.1 and the connector 11.0.2. Expect rough edges — the missing `local.json` mount path, the `sharp` packaging bug, and undocumented config keys were all encountered here. Read the connector changelog before upgrading, and re-verify `X-Forwarded-Proto` behaviour after any DS upgrade; it's the thing most likely to regress silently.

---

## 18. Acceptance test

After the build, and after any major change.

```bash
# Infrastructure
docker compose -f /docker/nextcloud/docker-compose.yml ps
docker logs --tail 5 newt
docker inspect newt --format '{{.HostConfig.NetworkMode}}'   # host
sudo iptables -S DOCKER-USER | head -3

# Local
curl -sI http://127.0.0.1:8080/ | head -1              # 302
curl -s  http://127.0.0.1:6233/healthcheck             # true

# Public
curl -sI https://ecloud.fiberathome.net/ | head -1
curl -s  https://eoffice.fiberathome.net/healthcheck   # true
curl -sI https://ecloud.fiberathome.net/ | grep -i strict     # HSTS present
curl -sI https://eoffice.fiberathome.net/admin/ | head -1     # 403/404

# Integration
nc-occ status
nc-occ eurooffice:documentserver --check
docker exec nc-app php -i | grep interned_strings_buffer      # 64
```

In the browser:

- [ ] Login; lands on **Files**
- [ ] Administration → Overview: only informational items
- [ ] `+ New → Document` opens the editor
- [ ] `.docx`, `.xlsx`, `.odt`, `.ods` all open, edit, persist after reload
- [ ] Same document in two browsers — cursors sync (WebSocket path)
- [ ] Desktop sync client connects (proves SSO is off)
- [ ] 2FA prompt on next login

**Reboot test — before real data lands:**

```bash
sudo reboot
# after it returns:
docker ps
sudo iptables -S DOCKER-USER | head -3
docker logs --tail 5 newt
nc-occ eurooffice:documentserver --check
```

---

## 19. Routine operations

### Daily / weekly

```bash
cd /docker/nextcloud
docker compose ps
docker stats --no-stream
nc-occ status
nc-occ log:tail -n 20          # remember: UTC
df -h / && free -h
```

### Monthly

```bash
nc-occ db:add-missing-indices
nc-occ app:update --all
docker system prune -f
sudo systemctl status nc-backup.timer
```

Check Overview for new warnings after any update.

### Maintenance calendar

| When | What |
|---|---|
| ~10th of each month | Nextcloud maintenance release — review changelog, plan the bump |
| 10 Sept 2026 | 34.0.4 — **re-test previews** (§17.1) |
| ~Oct 2026 | Nextcloud 35 (Hub 27) — majors ship every 4 months |
| June 2027 | NC 34 EOL — must be on 35+ before this |
| May 2029 | MariaDB 11.4 EOL |

### Upgrades

Every upgrade is a deliberate `.env` edit, never a blind `pull`.

```bash
cd /docker/nextcloud

# Nextcloud minor (34.0.3 -> 34.0.4)
sed -i 's|^NC_IMAGE=.*|NC_IMAGE=nextcloud:34.0.4-apache|' .env
docker compose pull app cron && docker compose up -d app cron
nc-occ upgrade && nc-occ db:add-missing-indices

# Euro-Office
docker exec nc-eurooffice documentserver-prepare4shutdown.sh
sed -i 's|^EO_IMAGE=.*|EO_IMAGE=ghcr.io/euro-office/documentserver:v9.4.0|' .env
docker compose pull eurooffice && docker compose up -d eurooffice
sleep 90
nc-occ eurooffice:documentserver --check

# Newt
cd /docker/newt
sed -i 's|^NEWT_IMAGE=.*|NEWT_IMAGE=fosrl/newt:1.17.0|' .env
docker compose pull && docker compose up -d
docker inspect newt --format '{{.HostConfig.NetworkMode}}'   # still host
```

**Multi-year rules:**

- Nextcloud majors **one at a time** (34 → 35 → 36). Skipping is unsupported and unrecoverable without a restore.
- Land on the latest minor of the current major before moving to the next major.
- Majors ship every 4 months, supported 12 months, monthly maintenance releases. Plan two upgrade windows a year.
- **Back up before every major.**
- MariaDB 11.4 supported to May 2029. Move to the next LTS in its own window, never alongside a Nextcloud major.

### Backup

```bash
sudo mkdir -p /backup/nextcloud
sudo tee /usr/local/sbin/nc-backup.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STACK=/docker/nextcloud
DEST=/backup/nextcloud
KEEP=14
STAMP=$(date +%F_%H%M)
cd "$STACK"

trap 'docker compose exec -T --user www-data app php occ maintenance:mode --off || true' EXIT

docker compose exec -T --user www-data app php occ maintenance:mode --on

docker exec -i nc-db mariadb-dump \
  -u root -p"$(grep ^MYSQL_ROOT_PASSWORD "$STACK/.env" | cut -d= -f2)" \
  --single-transaction --routines --triggers --default-character-set=utf8mb4 \
  nextcloud | gzip > "$DEST/db-$STAMP.sql.gz"

tar -czf "$DEST/data-$STAMP.tar.gz" -C "$STACK/data" nextcloud
cp "$STACK/.env" "$DEST/env-$STAMP.bak"
cp "$STACK/docker-compose.yml" "$DEST/compose-$STAMP.bak"
tar -czf "$DEST/config-php-$STAMP.tar.gz" -C "$STACK" config-php

docker compose exec -T --user www-data app php occ maintenance:mode --off
trap - EXIT

find "$DEST" -type f -mtime +$KEEP -delete
echo "nc-backup: completed $STAMP"
EOF

sudo chmod 750 /usr/local/sbin/nc-backup.sh
bash -n /usr/local/sbin/nc-backup.sh && echo SYNTAX_OK

sudo tee /etc/systemd/system/nc-backup.service >/dev/null <<'EOF'
[Unit]
Description=Nextcloud backup
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nc-backup.sh
EOF

sudo tee /etc/systemd/system/nc-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Nightly Nextcloud backup
[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now nc-backup.timer
systemctl list-timers nc-backup.timer
```

The `trap` guarantees maintenance mode lifts even if the dump fails — otherwise a failed 02:30 backup leaves the instance offline until someone notices.

**Push `/backup` offsite** (rclone/rsync). A backup on the same VM is not a backup.

### Restore rehearsal

Do this once, on a scratch VM, before you trust it:

```bash
cd /docker/nextcloud
docker compose down
sudo rm -rf data/nextcloud data/db
mkdir -p data/nextcloud data/db
tar -xzf /backup/nextcloud/data-YYYY-MM-DD_HHMM.tar.gz -C data/
docker compose up -d db
sleep 60
zcat /backup/nextcloud/db-YYYY-MM-DD_HHMM.sql.gz | \
  docker exec -i nc-db mariadb -u root -p"$(grep ^MYSQL_ROOT_PASSWORD .env | cut -d= -f2)" nextcloud
docker compose up -d
sleep 90
nc-occ status
nc-occ maintenance:mode --off
nc-occ files:scan --all
```

---

## 20. Deliberately not included

Decisions, not omissions:

- **notify_push (High Performance Backend).** Removes client polling; worth adding once you have real users. Needs port `7867` exposed — a third Pangolin resource (`epush.fiberathome.net`), since path routing at the gateway is unreliable.
- **Collabora.** NC 34 supports it alongside Euro-Office, but running both doubles the RAM footprint. Pick one unless deliberately comparing.
- **Full-text search, preview generation, imaginary.** Each is another container. Previews are moot while §17.1 stands.
- **S3 primary storage.** Changing later is a migration, not a config edit. Decide before onboarding users.
- **DS log persistence.** Every bind mount on that container broke it. If you need logs to survive restarts, use a named volume seeded from the image, not an empty bind mount.

---

## 21. Quick reference

```bash
# Health
nc-occ status
nc-occ eurooffice:documentserver --check
curl -s http://127.0.0.1:6233/healthcheck

# Logs
nc-occ log:tail -n 30                                                    # UTC!
docker exec nc-eurooffice tail -40 /var/log/euro-office/documentserver/docservice/out.log
docker exec nc-eurooffice tail -20 /var/log/euro-office/documentserver/nginx.error.log
docker logs --tail 20 newt

# Apply a mounted-config change
docker compose -f /docker/nextcloud/docker-compose.yml up -d --force-recreate app cron

# Restart
docker compose -f /docker/nextcloud/docker-compose.yml restart app
docker compose -f /docker/nextcloud/docker-compose.yml up -d eurooffice   # then wait 90s

# Config
nc-occ config:list system
nc-occ config:list eurooffice
docker exec nc-app env | grep -E 'TRUSTED|OVERWRITE'

# Emergency
nc-occ maintenance:mode --on|--off
nc-occ user:resetpassword ncadmin
nc-occ twofactor:disable ncadmin
```

**Key URLs**

| What | Where |
|---|---|
| Nextcloud | `https://ecloud.fiberathome.net` |
| Euro-Office connector settings (format list) | `https://ecloud.fiberathome.net/settings/admin/eurooffice` |
| Setup warnings | `https://ecloud.fiberathome.net/settings/admin/overview` |
| Basic settings (SMTP) | `https://ecloud.fiberathome.net/settings/admin` |

**File locations**

| What | Where |
|---|---|
| Stack | `/docker/nextcloud/{.env,docker-compose.yml}` |
| Nextcloud config | `/docker/nextcloud/data/nextcloud/config/config.php` |
| PHP tuning / HSTS | `/docker/nextcloud/config-php/{zz-tuning.ini,hsts.conf}` |
| Newt | `/docker/newt/{.env,docker-compose.yml}` |
| Firewall | `/usr/local/sbin/nc-fw.sh`, `/etc/systemd/system/nc-fw.service` |
| Backup | `/usr/local/sbin/nc-backup.sh`, `nc-backup.timer` |
| DS config (in container) | `/etc/euro-office/documentserver/local.json` — **entrypoint-owned, never mount** |

---

## 22. Final checklist

- [ ] iptables backend switched **before** Docker install; no stale nft `FORWARD DROP`
- [ ] `docker compose config` VALID on both stacks
- [ ] `.env` files `chmod 600`; secrets vaulted; exposed ones rotated
- [ ] `eurooffice` service has **no volumes**
- [ ] Newt in its own stack, `network_mode: host`, empty PORTS column
- [ ] Two Pangolin resources → `127.0.0.1:8080` / `127.0.0.1:6233`, **SSO OFF on both**
- [ ] **`x-forwarded-proto: https` on both resources**
- [ ] HSTS present in the response (`curl -sI ... | grep -i strict`)
- [ ] `/admin/` blocked on the `eoffice` resource
- [ ] `trusted_domains` includes `ecloud.fiberathome.net` **and** `app`
- [ ] Reverse-proxy settings from `.env` only, not duplicated in `occ`
- [ ] JWT ≥32 chars, identical in `.env` and connector
- [ ] `--check` passes; docx/xlsx/odt/ods all open and save
- [ ] opcache `interned_strings_buffer` = 64 and **verified in `php -i`**
- [ ] Mimetype migrations run
- [ ] SMTP configured and test mail sent
- [ ] 2FA enrolled **before** enforcement enabled
- [ ] `defaultapp=files`, dashboard disabled
- [ ] Firewall survives `systemctl restart docker`
- [ ] Backup timer enabled, offsite copy configured, **restore rehearsed**
- [ ] Full reboot test passed
- [ ] Calendar reminder set for 34.0.4 previews re-test (§17.1)