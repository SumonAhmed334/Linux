# Nextcloud 34 + Collabora Online + Docker + HTTPS + Nginx Reverse Proxy

## 1. Overview

This guide deploys the following stack on a single Ubuntu 24.04 VM:

```text
Internet
   |
   | HTTPS 443
   v
+----------------------+
| Nginx Reverse Proxy  |
+----------+-----------+
           |
     +-----+------+
     |            |
     v            v
Nextcloud       Collabora
:8080           :9980
Docker          Docker
     |            |
     +-----+------+
           |
        Docker
```

Recommended DNS names:

- Nextcloud: `cloud.example.com`
- Collabora: `office.example.com`

Replace both names with your real FQDNs.

> Important: Use a separate hostname for Collabora. Nextcloud's documentation recommends a subdomain/second domain for the Collabora server.

---

## 2. Prerequisites

### Server

Recommended starting point:

- Ubuntu Server 24.04 LTS
- 4+ CPU cores
- 8 GB+ RAM
- 50 GB+ SSD for a small deployment
- Static public IP
- DNS access
- Ports TCP `80` and `443` reachable from the Internet

### DNS

Create:

```text
cloud.example.com   A   <PUBLIC_IP>
office.example.com  A   <PUBLIC_IP>
```

Verify:

```bash
dig +short cloud.example.com
dig +short office.example.com
```

Both should return your public IP.

---

## 3. Install Docker

Update the server:

```bash
sudo apt update
sudo apt upgrade -y
```

Install prerequisites:

```bash
sudo apt install -y ca-certificates curl gnupg
```

Add Docker's official repository:

```bash
sudo install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

Install Docker:

```bash
sudo apt update

sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

Enable Docker:

```bash
sudo systemctl enable --now docker
```

Check:

```bash
docker --version
docker compose version
sudo systemctl status docker --no-pager
```

---

## 4. Create Project Directory

```bash
sudo mkdir -p /opt/nextcloud
cd /opt/nextcloud
```

Create directories:

```bash
sudo mkdir -p \
  nextcloud/html \
  nextcloud/db \
  nextcloud/config \
  nextcloud/custom_apps \
  nextcloud/data \
  collabora
```

Set ownership for Nextcloud data:

```bash
sudo chown -R 33:33 /opt/nextcloud/nextcloud
```

---

# 5. Create Docker Compose File

Create:

```bash
sudo nano /opt/nextcloud/docker-compose.yml
```

Use:

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
      - --skip-innodb-read-only-compressed

    environment:
      MYSQL_ROOT_PASSWORD: CHANGE_THIS_ROOT_PASSWORD
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: CHANGE_THIS_DB_PASSWORD

    volumes:
      - ./nextcloud/db:/var/lib/mysql

    networks:
      - nextcloud


  nextcloud:
    image: nextcloud:34-apache
    container_name: nextcloud
    restart: unless-stopped

    depends_on:
      - db

    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: CHANGE_THIS_DB_PASSWORD

    volumes:
      - ./nextcloud/html:/var/www/html
      - ./nextcloud/config:/var/www/html/config
      - ./nextcloud/custom_apps:/var/www/html/custom_apps
      - ./nextcloud/data:/var/www/html/data

    ports:
      - "127.0.0.1:8080:80"

    networks:
      - nextcloud


  collabora:
    image: collabora/code:latest
    container_name: collabora
    restart: unless-stopped

    cap_add:
      - MKNOD

    environment:
      aliasgroup1: https://cloud.example.com:443
      username: admin
      password: CHANGE_THIS_COLLABORA_ADMIN_PASSWORD
      extra_params: >-
        --o:ssl.enable=false
        --o:ssl.termination=true
        --o:welcome.enable=false

    ports:
      - "127.0.0.1:9980:9980"

    networks:
      - nextcloud


networks:
  nextcloud:
    driver: bridge
```

### Replace these values

Change:

```text
cloud.example.com
CHANGE_THIS_ROOT_PASSWORD
CHANGE_THIS_DB_PASSWORD
CHANGE_THIS_COLLABORA_ADMIN_PASSWORD
```

Use long random passwords.

Generate one with:

```bash
openssl rand -base64 32
```

Check the Compose file:

```bash
cd /opt/nextcloud
sudo docker compose config
```

If there are no errors, continue.

---

# 6. Start Nextcloud and Collabora

Start the stack:

```bash
cd /opt/nextcloud

sudo docker compose up -d
```

Check:

```bash
sudo docker compose ps
```

Expected:

```text
nextcloud-db
nextcloud
collabora
```

Check logs:

```bash
sudo docker compose logs -f
```

Press:

```text
CTRL+C
```

---

# 7. Test Nextcloud Locally

From the server:

```bash
curl -I http://127.0.0.1:8080
```

You should receive an HTTP response.

Test Collabora:

```bash
curl http://127.0.0.1:9980/hosting/capabilities
```

You should receive JSON containing Collabora Online capabilities.

Example:

```json
{
  "productName": "Collabora Online Development Edition"
}
```

---

# 8. Configure Nginx

Install Nginx:

```bash
sudo apt install -y nginx
```

Remove the default site:

```bash
sudo rm -f /etc/nginx/sites-enabled/default
```

---

# 9. Nextcloud Nginx Reverse Proxy

Create:

```bash
sudo nano /etc/nginx/sites-available/nextcloud.conf
```

Add:

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name cloud.example.com;

    client_max_body_size 10G;

    location / {
        proxy_pass http://127.0.0.1:8080;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_http_version 1.1;

        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }
}
```

Enable:

```bash
sudo ln -s /etc/nginx/sites-available/nextcloud.conf \
  /etc/nginx/sites-enabled/nextcloud.conf
```

---

# 10. Collabora Nginx Reverse Proxy

Create:

```bash
sudo nano /etc/nginx/sites-available/collabora.conf
```

Add:

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name office.example.com;

    location ^~ /browser {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
    }

    location ^~ /hosting/discovery {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
    }

    location ^~ /hosting/capabilities {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
    }

    location ^~ /cool/adminws {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
    }

    location ~ ^/cool/(.*)/ws$ {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;

        proxy_read_timeout 36000s;
        proxy_send_timeout 36000s;
    }

    location ^~ /cool {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location ^~ /lool {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
    }
}
```

Enable:

```bash
sudo ln -s /etc/nginx/sites-available/collabora.conf \
  /etc/nginx/sites-enabled/collabora.conf
```

---

# 11. Test Nginx

Run:

```bash
sudo nginx -t
```

Expected:

```text
syntax is ok
test is successful
```

Restart:

```bash
sudo systemctl restart nginx
```

Enable Nginx:

```bash
sudo systemctl enable nginx
```

---

# 12. Configure Firewall

If UFW is being used:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

Check:

```bash
sudo ufw status
```

Do NOT expose:

```text
8080
9980
```

to the Internet.

They are bound to `127.0.0.1`.

---

# 13. Install Certbot

Install:

```bash
sudo apt install -y certbot python3-certbot-nginx
```

Request certificates:

```bash
sudo certbot --nginx \
  -d cloud.example.com \
  -d office.example.com
```

Certbot should automatically configure HTTPS in Nginx.

When asked about HTTP → HTTPS redirection, select:

```text
2: Redirect
```

---

# 14. Verify HTTPS

Test:

```bash
curl -I https://cloud.example.com
```

And:

```bash
curl -I https://office.example.com
```

Test Collabora discovery:

```bash
curl https://office.example.com/hosting/discovery
```

It should return XML.

Test capabilities:

```bash
curl https://office.example.com/hosting/capabilities
```

---

# 15. Complete Nextcloud Initial Setup

Open:

```text
https://cloud.example.com
```

Create the administrator account.

For database:

```text
Database user:     nextcloud
Database password: YOUR_DB_PASSWORD
Database name:     nextcloud
Database host:     db
```

Then click:

```text
Install
```

---

# 16. Configure Nextcloud Trusted Domains

Enter the Nextcloud container:

```bash
sudo docker exec -it nextcloud bash
```

Check:

```bash
php occ config:system:get trusted_domains
```

Add your domain:

```bash
php occ config:system:set trusted_domains 1 \
  --value=cloud.example.com
```

Set overwrite protocol:

```bash
php occ config:system:set overwriteprotocol \
  --value=https
```

Set trusted proxy:

```bash
php occ config:system:set trusted_proxies 0 \
  --value=172.16.0.0/12
```

Exit:

```bash
exit
```

> Replace the trusted proxy value with the actual Docker/Nginx network if your deployment uses a different network layout. Do not blindly trust a broad proxy range in a hardened production deployment.

---

# 17. Install Nextcloud Office

Login to:

```text
https://cloud.example.com
```

Go to:

```text
Apps
    ↓
Office & text
```

Install:

```text
Nextcloud Office
```

Nextcloud Office is the Nextcloud integration for Collabora Online.

---

# 18. Configure Collabora Server in Nextcloud

Go to:

```text
Administration settings
    ↓
Office
```

Select:

```text
Use your own server
```

Enter:

```text
https://office.example.com
```

Save.

Do NOT enter:

```text
http://127.0.0.1:9980
```

The URL must be the externally reachable HTTPS URL that Nextcloud uses to communicate with Collabora.

---

# 19. Test Document Editing

Create a test file:

```text
Files
  ↓
New
  ↓
New document
```

For example:

```text
test.docx
```

Open it.

You should see the Collabora Online editor.

Test:

- Create text
- Save
- Close
- Reopen
- Edit from another browser
- Upload DOCX
- Upload XLSX
- Upload PPTX

---

# 20. Verify WebSocket

Collabora uses WebSocket connections for live editing.

Check Nginx logs:

```bash
sudo tail -f /var/log/nginx/access.log
```

Open a document and look for requests under:

```text
/cool/.../ws
```

Also check:

```bash
sudo docker logs -f collabora
```

---

# 21. Common Troubleshooting

## Problem: 502 Bad Gateway

Check:

```bash
sudo docker ps
```

Then:

```bash
curl http://127.0.0.1:8080
```

For Collabora:

```bash
curl http://127.0.0.1:9980/hosting/capabilities
```

Check Nginx:

```bash
sudo nginx -t
sudo journalctl -u nginx -n 100 --no-pager
```

---

## Problem: Collabora server cannot be reached

Check:

```bash
curl https://office.example.com/hosting/discovery
```

If this fails, check:

```bash
sudo docker logs collabora
```

And:

```bash
sudo nginx -t
```

---

## Problem: Document opens but editing does not work

This is commonly related to WebSocket proxying.

Verify this block exists:

```nginx
location ~ ^/cool/(.*)/ws$ {
    proxy_pass http://127.0.0.1:9980;

    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";

    proxy_read_timeout 36000s;
}
```

Reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

---

## Problem: WOPI error

Check:

```bash
curl https://office.example.com/hosting/discovery
```

Then verify that Nextcloud Office is configured with:

```text
https://office.example.com
```

Also check:

```bash
sudo docker logs nextcloud
sudo docker logs collabora
```

---

# 22. Container Health Checks

Run:

```bash
sudo docker compose ps
```

Check Nextcloud:

```bash
sudo docker exec -u www-data nextcloud php occ status
```

Check Collabora:

```bash
curl http://127.0.0.1:9980/hosting/capabilities
```

Check database:

```bash
sudo docker exec nextcloud-db \
  mariadb -u root -p -e "SHOW DATABASES;"
```

---

# 23. Useful Docker Commands

View containers:

```bash
docker ps
```

View all containers:

```bash
docker ps -a
```

View logs:

```bash
docker logs nextcloud
docker logs collabora
docker logs nextcloud-db
```

Follow logs:

```bash
docker logs -f collabora
```

Restart:

```bash
cd /opt/nextcloud
docker compose restart
```

Stop:

```bash
cd /opt/nextcloud
docker compose down
```

Start:

```bash
cd /opt/nextcloud
docker compose up -d
```

---

# 24. Backup

At minimum, back up:

```text
/opt/nextcloud/nextcloud/db
/opt/nextcloud/nextcloud/config
/opt/nextcloud/nextcloud/data
/opt/nextcloud/docker-compose.yml
```

Example:

```bash
mkdir -p /backup/nextcloud

tar -czf \
  /backup/nextcloud/nextcloud-$(date +%F).tar.gz \
  /opt/nextcloud/nextcloud \
  /opt/nextcloud/docker-compose.yml
```

For production, use a proper database dump rather than relying only on filesystem copies.

Example:

```bash
docker exec nextcloud-db \
  mariadb-dump -u root -p'YOUR_ROOT_PASSWORD' nextcloud \
  > /backup/nextcloud/nextcloud-db-$(date +%F).sql
```

Store backups on a separate storage system.

---

# 25. Updating

Before updating:

```bash
cd /opt/nextcloud
docker compose pull
```

Check the downloaded images:

```bash
docker images
```

Then:

```bash
docker compose up -d
```

Check:

```bash
docker compose ps
```

Check Nextcloud:

```bash
docker exec -u www-data nextcloud php occ status
```

> Do not blindly update major Nextcloud versions in production. Follow the supported upgrade path and take a tested backup first.

For Collabora:

```bash
docker pull collabora/code:latest
docker compose up -d collabora
```

---

# 26. Production Security Checklist

Before production use:

- [ ] Use strong passwords
- [ ] Enable HTTPS
- [ ] Enable automatic certificate renewal
- [ ] Expose only TCP 80/443 and SSH as required
- [ ] Keep ports 8080 and 9980 private
- [ ] Configure trusted domains
- [ ] Configure trusted proxies correctly
- [ ] Keep Docker updated
- [ ] Keep Nextcloud updated
- [ ] Keep Collabora updated
- [ ] Configure regular backups
- [ ] Store backups outside the VM
- [ ] Test restoration
- [ ] Enable 2FA for administrators
- [ ] Use a separate admin account
- [ ] Monitor disk usage
- [ ] Monitor RAM/CPU
- [ ] Monitor Docker containers
- [ ] Monitor Nginx logs
- [ ] Monitor Nextcloud logs
- [ ] Monitor Collabora logs

---

# 27. Final Architecture

The completed setup should look like:

```text
                         INTERNET
                            |
                      TCP 80 / 443
                            |
                    +---------------+
                    |     NGINX     |
                    | Reverse Proxy |
                    +-------+-------+
                            |
             +--------------+--------------+
             |                             |
             |                             |
             v                             v
     cloud.example.com             office.example.com
             |                             |
             v                             v
      127.0.0.1:8080              127.0.0.1:9980
             |                             |
             v                             v
     +---------------+             +---------------+
     |  Nextcloud 34 |             |  Collabora    |
     |    Docker     |             |    CODE       |
     +-------+-------+             +---------------+
             |
             v
     +---------------+
     |    MariaDB    |
     |    Docker     |
     +---------------+
```

## Expected result

You will have:

```text
https://cloud.example.com
        |
        +-- Nextcloud 34
        |
        +-- Files
        +-- Users
        +-- Sharing
        +-- Nextcloud Office
                 |
                 v
        https://office.example.com
                 |
                 v
          Collabora Online
```

Users can then open and collaboratively edit:

```text
DOC / DOCX
XLS / XLSX
PPT / PPTX
ODT / ODS / ODP
```

directly from Nextcloud.

## References

- Nextcloud 34 Office documentation:
  https://docs.nextcloud.com/server/34/admin_manual/office/

- Nextcloud 34 Docker installation example:
  https://docs.nextcloud.com/server/34/admin_manual/office/example-docker.html

- Nextcloud 34 reverse proxy documentation:
  https://docs.nextcloud.com/server/34/admin_manual/office/proxy.html

- Collabora Online documentation:
  https://sdk.collaboraonline.com/
