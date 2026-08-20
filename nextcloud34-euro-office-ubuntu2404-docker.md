# Nextcloud 34 + Euro-Office on a Single Ubuntu 24.04 VM with Docker

## 1. Target architecture

This guide builds a single Ubuntu 24.04 LTS VM with:

- Nextcloud 34
- MariaDB
- Redis
- Euro-Office Document Server
- Nginx Proxy Manager (NPM) for HTTPS/reverse proxy
- Docker Compose
- Persistent Docker volumes
- Nextcloud cron
- JWT authentication between Nextcloud Office and Euro-Office

Recommended DNS:

- `cloud.example.com` → Nextcloud
- `office.example.com` → Euro-Office

Replace these example domains with your real DNS names.

> Production note: Nextcloud's documentation supports Ubuntu 24.04, and the Docker image is intended for containerized deployments. Euro-Office's official Docker documentation requires Docker Engine 20.10+ and at least 4 GB RAM; Nextcloud's Euro-Office guide recommends HTTPS and a reverse proxy for production deployments.

---

## 2. Recommended VM sizing

For a small R&D or office deployment:

| Resource | Recommended |
|---|---:|
| CPU | 8 vCPU |
| RAM | 16 GB |
| OS disk | 100 GB+ |
| Data disk | 500 GB+ |
| OS | Ubuntu Server 24.04 LTS |
| Network | Static IP |
| Internet | Required |

Euro-Office alone requires at least 4 GB RAM and 10 GB free disk according to the current official documentation. For multiple simultaneous office users, 16 GB RAM is a much better starting point.

---

## 3. Network plan

Example:

```text
Ubuntu VM
├── Nextcloud
│   └── https://cloud.example.com
│
├── Euro-Office
│   └── https://office.example.com
│
└── Nginx Proxy Manager
    ├── :80
    └── :443
```

Only expose these ports to the Internet:

```text
80/tcp
443/tcp
```

Do NOT expose MariaDB, Redis, Nextcloud's internal HTTP port, or Euro-Office's internal HTTP port publicly.

---

# Part 1 — Prepare Ubuntu 24.04

## 4. Update Ubuntu

```bash
sudo apt update
sudo apt upgrade -y
sudo reboot
```

After reboot:

```bash
uname -a
cat /etc/os-release
```

Confirm Ubuntu 24.04.

---

## 5. Set hostname

Example:

```bash
sudo hostnamectl set-hostname nextcloud01
hostnamectl
```

---

## 6. Configure timezone

For Bangladesh:

```bash
sudo timedatectl set-timezone Asia/Dhaka
timedatectl
```

---

## 7. Create an administration user

If you already have a sudo user, skip this section.

```bash
sudo adduser sysadmin
sudo usermod -aG sudo sysadmin
```

Verify:

```bash
id sysadmin
```

Use the normal sudo user for administration instead of doing routine work directly as root.

---

# Part 2 — Install Docker

## 8. Remove conflicting old Docker packages

```bash
sudo apt remove -y \
  docker.io \
  docker-doc \
  docker-compose \
  podman-docker \
  containerd \
  runc
```

---

## 9. Install Docker from Docker's official repository

Install prerequisites:

```bash
sudo apt update

sudo apt install -y \
  ca-certificates \
  curl \
  gnupg
```

Create keyring:

```bash
sudo install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

Add repository:

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

Install Docker Engine and Compose:

```bash
sudo apt update

sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

Check:

```bash
sudo systemctl enable --now docker

docker --version
docker compose version
```

---

## 10. Allow the administrator to use Docker

```bash
sudo usermod -aG docker $USER
```

Log out and log in again, or:

```bash
newgrp docker
```

Test:

```bash
docker run --rm hello-world
```

---

# Part 3 — Create project directories

## 11. Create the Docker project

```bash
sudo mkdir -p /opt/nextcloud
sudo chown -R $USER:$USER /opt/nextcloud

cd /opt/nextcloud
```

Create directories:

```bash
mkdir -p nginx-proxy-manager
mkdir -p backup
mkdir -p scripts
```

---

# Part 4 — Create Docker network

## 12. Create the shared network

```bash
docker network create nextcloud-net
```

Check:

```bash
docker network ls
```

The network should show:

```text
nextcloud-net
```

---

# Part 5 — Create secrets

## 13. Generate database passwords

Run:

```bash
openssl rand -hex 32
```

Run it several times and save the generated values securely.

You need:

- MariaDB root password
- Nextcloud database password
- Euro-Office JWT secret

Generate JWT secret:

```bash
openssl rand -hex 32
```

Keep this secret. The same JWT secret must be configured on both sides of the Euro-Office integration.

---

# Part 6 — Create .env

## 14. Create the environment file

```bash
cd /opt/nextcloud
nano .env
```

Use:

```dotenv
MYSQL_ROOT_PASSWORD=CHANGE_THIS_ROOT_PASSWORD
MYSQL_PASSWORD=CHANGE_THIS_NEXTCLOUD_DB_PASSWORD

MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud

NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=CHANGE_THIS_ADMIN_PASSWORD

JWT_SECRET=CHANGE_THIS_WITH_OPENSSL_OUTPUT

NEXTCLOUD_DOMAIN=cloud.example.com
EUROOFFICE_DOMAIN=office.example.com
```

Protect it:

```bash
chmod 600 .env
```

Never commit `.env` to Git.

---

# Part 7 — Create Nextcloud + MariaDB + Redis + Euro-Office Compose

## 15. Create compose.yaml

```bash
nano /opt/nextcloud/compose.yaml
```

Paste:

```yaml
services:

  db:
    image: mariadb:11.4
    container_name: nextcloud-db
    restart: unless-stopped
    command:
      - --transaction-isolation=READ-COMMITTED
      - --binlog-format=ROW
      - --innodb-file-per-table=1
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - nextcloud_db:/var/lib/mysql
    networks:
      - nextcloud-net

  redis:
    image: redis:7-alpine
    container_name: nextcloud-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - nextcloud_redis:/data
    networks:
      - nextcloud-net

  nextcloud:
    image: nextcloud:34-apache
    container_name: nextcloud
    restart: unless-stopped
    depends_on:
      - db
      - redis
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      REDIS_HOST: redis
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: ${NEXTCLOUD_DOMAIN}
      OVERWRITEPROTOCOL: https
      OVERWRITEHOST: ${NEXTCLOUD_DOMAIN}
    volumes:
      - nextcloud_data:/var/www/html
    ports:
      - "127.0.0.1:8080:80"
    networks:
      - nextcloud-net

  euro-office:
    image: ghcr.io/euro-office/documentserver:latest
    container_name: euro-office
    restart: unless-stopped
    environment:
      JWT_ENABLED: "true"
      JWT_SECRET: ${JWT_SECRET}
    volumes:
      - eurooffice_data:/var/lib/euro-office/documentserver
      - eurooffice_logs:/var/log/euro-office/documentserver
      - eurooffice_config:/etc/euro-office/documentserver
    ports:
      - "127.0.0.1:8890:80"
    networks:
      - nextcloud-net

volumes:
  nextcloud_db:
  nextcloud_redis:
  nextcloud_data:
  eurooffice_data:
  eurooffice_logs:
  eurooffice_config:

networks:
  nextcloud-net:
    external: true
```

---

# Part 8 — Start the stack

## 16. Validate Compose

```bash
cd /opt/nextcloud
docker compose config
```

If there is no error, continue.

---

## 17. Pull images

```bash
docker compose pull
```

---

## 18. Start containers

```bash
docker compose up -d
```

Check:

```bash
docker compose ps
```

Expected containers:

```text
nextcloud-db
nextcloud-redis
nextcloud
euro-office
```

---

# Part 9 — Verify Nextcloud

## 19. Check Nextcloud

```bash
curl -I http://127.0.0.1:8080
```

You should receive an HTTP response.

Check logs:

```bash
docker logs --tail 100 nextcloud
```

---

## 20. Verify Nextcloud installation

```bash
docker exec -u www-data nextcloud php occ status
```

Expected:

```text
installed: true
```

Check version:

```bash
docker exec -u www-data nextcloud php occ -V
```

It should report Nextcloud 34.x.

---

# Part 10 — Verify Euro-Office

## 21. Health check

```bash
curl http://127.0.0.1:8890/healthcheck
```

Expected:

```text
true
```

If it does not return true:

```bash
docker logs --tail 200 euro-office
```

---

# Part 11 — Install Nginx Proxy Manager

## 22. Create NPM Compose

```bash
cd /opt/nextcloud/nginx-proxy-manager
nano compose.yaml
```

Use:

```yaml
services:

  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped

    ports:
      - "80:80"
      - "81:81"
      - "443:443"

    volumes:
      - npm_data:/data
      - npm_letsencrypt:/etc/letsencrypt

    networks:
      - nextcloud-net

volumes:
  npm_data:
  npm_letsencrypt:

networks:
  nextcloud-net:
    external: true
```

Start:

```bash
docker compose up -d
```

Check:

```bash
docker compose ps
```

---

# Part 12 — Configure DNS

Create DNS records:

```text
cloud.example.com   A   YOUR_PUBLIC_IP
office.example.com  A   YOUR_PUBLIC_IP
```

If your provider gives you two public IPs, use the appropriate address according to your network design.

Verify:

```bash
dig +short cloud.example.com
dig +short office.example.com
```

Both should resolve to the public address that reaches this VM.

---

# Part 13 — Firewall

## 23. Configure UFW

If UFW is used:

```bash
sudo apt install -y ufw
```

Allow SSH:

```bash
sudo ufw allow 22/tcp
```

Allow HTTP/HTTPS:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

Enable:

```bash
sudo ufw enable
```

Check:

```bash
sudo ufw status verbose
```

Do not open:

```text
8080
8890
3306
6379
81
```

to the public Internet.

Port 81 is the Nginx Proxy Manager administration interface and should ideally be restricted to your management network/VPN.

---

# Part 14 — Configure Nginx Proxy Manager

Open:

```text
http://SERVER-IP:81
```

Log in with the initial credentials supplied by the Nginx Proxy Manager documentation/image.

Immediately change the default administrator credentials.

---

## 24. Create Nextcloud Proxy Host

In NPM:

```text
Hosts
→ Proxy Hosts
→ Add Proxy Host
```

Domain:

```text
cloud.example.com
```

Forward hostname/IP:

```text
nextcloud
```

Forward port:

```text
80
```

Enable:

```text
Websockets Support
Block Common Exploits
```

Request SSL:

```text
Request a new SSL Certificate
```

Enable:

```text
Force SSL
HTTP/2 Support
```

Save.

---

# Part 15 — Configure Euro-Office Proxy Host

Create another Proxy Host.

Domain:

```text
office.example.com
```

Forward hostname/IP:

```text
euro-office
```

Forward port:

```text
80
```

Enable:

```text
Websockets Support
Block Common Exploits
```

Request SSL certificate.

Enable:

```text
Force SSL
HTTP/2 Support
```

Save.

Euro-Office requires HTTPS in a production deployment, and its browser/WebSocket traffic must work through the reverse proxy.

---

# Part 16 — Nextcloud trusted proxy configuration

Because NPM is in Docker, determine its IP:

```bash
docker inspect nginx-proxy-manager \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

Example:

```text
172.18.0.5
```

Then add it as a trusted proxy:

```bash
docker exec -u www-data nextcloud php occ config:system:set trusted_proxies 0 --value=172.18.0.5
```

Check:

```bash
docker exec -u www-data nextcloud php occ config:system:get trusted_proxies
```

If the NPM container IP can change after recreation, use the Docker network's controlled design or configure the trusted proxy appropriately for your environment rather than blindly adding broad CIDRs.

---

# Part 17 — Configure Nextcloud Office / Euro-Office

## 25. Install the Nextcloud Office connector

Open Nextcloud:

```text
https://cloud.example.com
```

Log in as administrator.

Go to:

```text
Apps
→ Office & text
```

Install:

```text
Nextcloud Office
```

The Euro-Office connector is available with Nextcloud 34 and newer.

You can also check the installed apps:

```bash
docker exec -u www-data nextcloud php occ app:list
```

---

## 26. Configure the Office server

Go to:

```text
Administration settings
→ Office
```

Set the document server URL:

```text
https://office.example.com
```

Set the JWT secret to exactly the same value as:

```text
JWT_SECRET
```

from:

```text
/opt/nextcloud/.env
```

Save.

---

# Part 18 — Test Euro-Office integration

## 27. Create a test document

In Nextcloud:

```text
Files
→ New
→ Text Document
```

or create/open:

```text
.docx
.xlsx
.pptx
```

The document should open in the Euro-Office editor.

---

# Part 19 — Configure Nextcloud cron

Nextcloud recommends cron for background jobs.

Create a cron container:

Add this service to `/opt/nextcloud/compose.yaml`:

```yaml
  cron:
    image: nextcloud:34-apache
    container_name: nextcloud-cron
    restart: unless-stopped
    depends_on:
      - nextcloud
    volumes:
      - nextcloud_data:/var/www/html
    entrypoint: /cron.sh
    networks:
      - nextcloud-net
```

Then:

```bash
docker compose up -d
```

Check:

```bash
docker logs --tail 50 nextcloud-cron
```

In Nextcloud:

```text
Administration settings
→ Basic settings
→ Background jobs
→ Cron
```

---

# Part 20 — Redis configuration

Set Redis locking:

```bash
docker exec -u www-data nextcloud php occ config:system:set memcache.local \
  --value='\OC\Memcache\APCu'
```

Set Redis:

```bash
docker exec -u www-data nextcloud php occ config:system:set memcache.locking \
  --value='\OC\Memcache\Redis'
```

```bash
docker exec -u www-data nextcloud php occ config:system:set redis host \
  --value='redis'
```

```bash
docker exec -u www-data nextcloud php occ config:system:set redis port \
  --type=integer \
  --value=6379
```

Verify:

```bash
docker exec -u www-data nextcloud php occ config:system:get memcache.local
docker exec -u www-data nextcloud php occ config:system:get memcache.locking
```

---

# Part 21 — PHP / Nextcloud maintenance

Check status:

```bash
docker exec -u www-data nextcloud php occ status
```

Check maintenance mode:

```bash
docker exec -u www-data nextcloud php occ maintenance:mode
```

Run database maintenance:

```bash
docker exec -u www-data nextcloud php occ db:add-missing-indices
```

Run:

```bash
docker exec -u www-data nextcloud php occ db:add-missing-columns
```

Run:

```bash
docker exec -u www-data nextcloud php occ db:add-missing-primary-keys
```

---

# Part 22 — Docker health and troubleshooting

## 28. Check all containers

```bash
docker ps
```

Detailed:

```bash
docker compose ps
```

---

## 29. Nextcloud logs

```bash
docker logs --tail 200 nextcloud
```

---

## 30. MariaDB logs

```bash
docker logs --tail 200 nextcloud-db
```

---

## 31. Redis logs

```bash
docker logs --tail 200 nextcloud-redis
```

---

## 32. Euro-Office logs

```bash
docker logs --tail 200 euro-office
```

---

## 33. NPM logs

```bash
docker logs --tail 200 nginx-proxy-manager
```

---

# Part 23 — Important checks

Run:

```bash
curl -I https://cloud.example.com
```

Run:

```bash
curl -I https://office.example.com
```

Run:

```bash
curl http://127.0.0.1:8890/healthcheck
```

Run:

```bash
docker exec -u www-data nextcloud php occ status
```

Run:

```bash
docker compose ps
```

All critical containers should be running.

---

# Part 24 — Backup strategy

Do NOT rely only on Docker volumes.

You need backups of:

1. Nextcloud files
2. MariaDB database
3. Nextcloud configuration
4. Euro-Office configuration/data where required
5. NPM configuration and certificates

List volumes:

```bash
docker volume ls
```

Example:

```text
nextcloud_db
nextcloud_redis
nextcloud_data
eurooffice_data
eurooffice_logs
eurooffice_config
npm_data
npm_letsencrypt
```

---

## 34. Database backup

Create:

```bash
mkdir -p /opt/nextcloud/backup
```

Dump MariaDB:

```bash
docker exec nextcloud-db \
  mariadb-dump \
  -u root \
  -p"${MYSQL_ROOT_PASSWORD}" \
  --single-transaction \
  --routines \
  --triggers \
  nextcloud \
  > /opt/nextcloud/backup/nextcloud-$(date +%F).sql
```

Do not store the database password directly in shell history for production. A dedicated backup script with a protected environment/config file is preferable.

---

# Part 25 — Upgrade procedure

Before upgrades:

```bash
docker compose ps
```

Create a database backup first.

Then:

```bash
docker compose pull
```

For a controlled update:

```bash
docker compose up -d
```

Check:

```bash
docker compose ps
```

Then:

```bash
docker exec -u www-data nextcloud php occ status
```

Do not blindly jump across unsupported Nextcloud major versions. Upgrade one major release at a time when required.

---

# Part 26 — Security hardening checklist

- [ ] Use SSH keys instead of password-only SSH
- [ ] Disable direct root SSH login
- [ ] Restrict SSH to VPN/management networks where possible
- [ ] Expose only TCP 80/443 publicly
- [ ] Restrict NPM port 81
- [ ] Use HTTPS
- [ ] Use strong Nextcloud admin password
- [ ] Use strong MariaDB passwords
- [ ] Keep `.env` permission at `600`
- [ ] Keep JWT secret private
- [ ] Enable Nextcloud 2FA
- [ ] Configure automated backups
- [ ] Keep Docker images updated
- [ ] Monitor disk usage
- [ ] Monitor MariaDB
- [ ] Monitor Redis
- [ ] Monitor Euro-Office
- [ ] Monitor Nextcloud logs
- [ ] Test restore procedures
- [ ] Do not expose MariaDB/Redis directly to the Internet

---

# Part 27 — Final architecture

```text
                         Internet
                            |
                       TCP 80/443
                            |
                  +-------------------+
                  | Nginx Proxy Mgr   |
                  | Docker Container  |
                  +---------+---------+
                            |
             +--------------+--------------+
             |                             |
             v                             v
     cloud.example.com             office.example.com
             |                             |
             v                             v
       +------------+              +---------------+
       | Nextcloud  |              | Euro-Office   |
       | 34 Apache  |              | DocumentServer|
       +-----+------+              +-------+-------+
             |                             |
             |                             |
       +-----+------+                      |
       |            |                      |
       v            v                      |
   MariaDB        Redis <-----------------+
```

All services run on the same Ubuntu 24.04 VM but remain isolated as Docker containers.

---

# Part 28 — Quick command reference

### Start

```bash
cd /opt/nextcloud
docker compose up -d
cd /opt/nextcloud/nginx-proxy-manager
docker compose up -d
```

### Stop

```bash
cd /opt/nextcloud
docker compose down
cd /opt/nextcloud/nginx-proxy-manager
docker compose down
```

### Status

```bash
docker ps
docker compose ps
```

### Logs

```bash
docker logs --tail 100 nextcloud
docker logs --tail 100 euro-office
docker logs --tail 100 nextcloud-db
docker logs --tail 100 nextcloud-redis
docker logs --tail 100 nginx-proxy-manager
```

### Nextcloud OCC

```bash
docker exec -u www-data nextcloud php occ status
docker exec -u www-data nextcloud php occ -V
docker exec -u www-data nextcloud php occ app:list
```

### Euro-Office health

```bash
curl http://127.0.0.1:8890/healthcheck
```

Expected:

```text
true
```

---

# Important note about this design

This is a single-VM deployment. It is simple and suitable for an R&D/small-office environment, but it is not highly available.

For production, keep backups on separate storage/server and consider separating:

- Nextcloud application
- Database
- Redis
- Euro-Office
- Reverse proxy

The current design intentionally keeps everything on one Ubuntu 24.04 VM as requested.
