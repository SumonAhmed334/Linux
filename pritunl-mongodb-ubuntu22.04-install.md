# Pritunl VPN Server Installation with MongoDB on Ubuntu 22.04

A complete, production-ready guide for deploying Pritunl (OpenVPN/WireGuard/IPsec management server) backed by MongoDB on Ubuntu 22.04 LTS.

---

## 1. Overview

| Component | Role |
|---|---|
| **Pritunl** | VPN server + web management console (supports OpenVPN, WireGuard, IPsec) |
| **MongoDB** | Backend database that stores Pritunl's configuration, users, and server state |
| **Ubuntu 22.04** | Host OS |

Pritunl does **not** bundle MongoDB — you install and run MongoDB separately, and Pritunl connects to it (locally or remotely) via a Mongo connection URI.

---

## 2. Prerequisites

- A fresh Ubuntu 22.04 server (VM or bare metal), minimum **1 vCPU / 1GB RAM** (2GB+ recommended for production)
- Root or sudo access
- A public IP or reachable IP for VPN clients
- Open the following ports on your firewall/security group **before** you start:
  - `443/tcp` — Pritunl web console (HTTPS)
  - `1194/udp` — OpenVPN default (adjust if you change it)
  - `51820/udp` — WireGuard (if used)
  - `500/udp`, `4500/udp` — IPsec (if used)

```bash
sudo apt update && sudo apt upgrade -y
sudo timedatectl set-ntp on
```

---

## 3. Install MongoDB

Pritunl officially supports MongoDB **4.4, 5.0, or 6.0**. MongoDB 7.x has had compatibility issues reported with some Pritunl versions, so **MongoDB 6.0** is the safe, recommended choice as of this writing.

### 3.1 Import the MongoDB GPG key and repo

```bash
sudo apt install -y gnupg curl

curl -fsSL https://pgp.mongodb.com/server-6.0.asc | \
  sudo gpg -o /usr/share/keyrings/mongodb-server-6.0.gpg --dearmor

echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-6.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list
```

### 3.2 Install and start MongoDB

```bash
sudo apt update
sudo apt install -y mongodb-org

sudo systemctl enable --now mongod
sudo systemctl status mongod --no-pager
```

### 3.3 Verify MongoDB is listening

```bash
mongosh --eval "db.runCommand({ ping: 1 })"
```

By default MongoDB binds to `127.0.0.1:27017`, which is exactly what a single-node Pritunl setup needs. Do **not** expose 27017 publicly unless you're building a multi-node Pritunl cluster with a remote Mongo — if you do, secure it with authentication and TLS (see §7).

---

## 4. Install Pritunl

### 4.1 Add the Pritunl repository

`apt-key` is deprecated on Ubuntu 22.04, so use the modern `signed-by` keyring method. Run these **one command at a time** (not pasted as a block) so you can confirm each step succeeds.

**Step 1 — Add the repo entry:**
```bash
sudo tee /etc/apt/sources.list.d/pritunl.list << EOF
deb [ signed-by=/usr/share/keyrings/pritunl.gpg ] https://repo.pritunl.com/stable/apt jammy main
EOF
```

**Step 2 — Make sure gnupg is installed:**
```bash
sudo apt install -y gnupg
```

**Step 3 — Download the signing key to a file (more reliable than piping directly into gpg):**
```bash
curl -fsSL https://raw.githubusercontent.com/pritunl/pgp/master/pritunl_repo_pub.asc -o /tmp/pritunl.asc
```

**Step 4 — Confirm it actually downloaded content:**
```bash
cat /tmp/pritunl.asc
```
This should print a block starting with `-----BEGIN PGP PUBLIC KEY BLOCK-----` and ending with `-----END PGP PUBLIC KEY BLOCK-----`. Don't proceed until you see this — piping `curl | gpg` directly can silently produce a 0-byte keyring file in some shell sessions, so downloading to a file first and verifying it is the reliable method.

**Step 5 — Dearmor the key from the saved file into the keyring:**
```bash
sudo rm -f /usr/share/keyrings/pritunl.gpg
sudo gpg -o /usr/share/keyrings/pritunl.gpg --dearmor /tmp/pritunl.asc
```

**Step 6 — Confirm the key file was created correctly and is non-empty:**
```bash
ls -la /usr/share/keyrings/pritunl.gpg
gpg --show-keys /usr/share/keyrings/pritunl.gpg
```

### 4.2 Install Pritunl

```bash
sudo apt update
sudo apt install -y pritunl
```

This also pulls in `wireguard-tools` and `openvpn` as dependencies.

### 4.3 Enable and start services

```bash
sudo systemctl enable --now mongod
sudo systemctl enable --now pritunl

sudo systemctl status pritunl --no-pager
```

---

## 5. Firewall Configuration (UFW)

```bash
sudo ufw allow 443/tcp        # Web console
sudo ufw allow 1194/udp       # OpenVPN
sudo ufw allow 51820/udp      # WireGuard (optional)
sudo ufw allow 500/udp        # IPsec (optional)
sudo ufw allow 4500/udp       # IPsec NAT-T (optional)
sudo ufw allow OpenSSH
sudo ufw enable
sudo ufw status verbose
```

> **Note:** Pritunl manages its own `iptables` NAT/forwarding rules dynamically once servers are attached — don't hand-edit `iptables` rules for VPN traffic, let Pritunl own that.

---

## 6. Initial Setup

### 6.1 Get the setup key and default admin password

```bash
sudo pritunl setup-key
sudo pritunl default-password
```

- `setup-key` gives you a key used **only** if you need to point Pritunl at a non-default/remote MongoDB during first-run setup.
- `default-password` gives you the auto-generated initial admin username/password.

### 6.2 Access the web console

Open a browser to:

```
https://<your-server-ip>
```

You'll hit a self-signed cert warning on first load — that's expected; Pritunl generates its own cert initially (replace with a real one in §7.2).

### 6.3 Complete the setup wizard

1. Log in with the credentials from `pritunl default-password`.
2. On first login you'll be prompted to confirm the **MongoDB URI** — for a local install this is simply:
   ```
   mongodb://localhost:27017/pritunl
   ```
3. Set a new admin username/password.
4. Set the public IP/domain Pritunl should advertise to clients.

---
7. Restoring Pritunl MongoDB from a Previous Server

Step-by-step sequence used to restore a mongodump backup from a previous Pritunl server into a new VM.

7.1 Check current Pritunl service status
bash
systemctl status pritunl --no-pager
7.2 Stop Pritunl before restoring

So it isn't writing to the database mid-restore:

bash
systemctl stop pritunl
7.3 Confirm it has stopped
bash
systemctl status pritunl
7.4 Confirm mongorestore is available
bash
which mongorestore
7.5 Go to the folder containing the dump
bash
cd /root/pritunl-20260804-213611
7.6 Restore the dump into the pritunl database

--drop clears the new VM's fresh/auto-created data first, avoiding a mixed state:

bash
mongorestore --db=pritunl --drop pritunl/
7.7 Verify the restored collections exist
bash
mongosh pritunl --eval "db.getCollectionNames()"
7.8 Verify restored user count
bash
mongosh pritunl --eval "db.users.countDocuments()"
7.9 Verify restored server count
bash
mongosh pritunl --eval "db.servers.countDocuments()"
7.10 Verify restored organization count
bash
mongosh pritunl --eval "db.organizations.countDocuments()"
7.11 Start Pritunl again
bash
sudo systemctl start pritunl
7.12 Confirm it's running cleanly
bash
sudo systemctl status pritunl --no-pager
7.13 Try the default password command

Expected to fail on a restored/non-fresh database:

bash
sudo pritunl default-password
7.14 Reset the admin password

Since the restored database already has an admin account and default-password only works on fresh installs:

bash
pritunl reset-password

Notes:

Stopping Pritunl before restoring prevents it from writing to the database mid-restore.
--drop wipes the new VM's fresh/auto-created pritunl database before loading the old data, avoiding a mixed state.
After restoring, the imported hosts collection still references the old server's host identity — go to Administration → Hosts in the web console and remove the stale host, then re-attach the new VM as the host for each server before VPN servers will start correctly.
sudo pritunl default-password only generates a password for a fresh install with no admin yet — on a restored database it returns No default password available, use reset-password, exactly as expected. sudo pritunl reset-password is the correct command to reset the restored admin account and print new login credentials.
8. Production Hardening (Recommended)
8.1 Enable MongoDB authentication
bash
mongosh
javascript
use admin
db.createUser({
  user: "pritunl_admin",
  pwd: "USE_A_STRONG_PASSWORD_HERE",
  roles: [ { role: "root", db: "admin" } ]
})
exit

Enable auth in /etc/mongod.conf:

yaml
security:
  authorization: enabled
bash
sudo systemctl restart mongod

Update Pritunl's Mongo URI accordingly (via pritunl set-mongodb or the web console → Settings):

bash
sudo pritunl set-mongodb mongodb://pritunl_admin:USE_A_STRONG_PASSWORD_HERE@localhost:27017/pritunl?authSource=admin
sudo systemctl restart pritunl
8.2 Replace the self-signed certificate

Use Let's Encrypt (via a reverse proxy is not typical here since Pritunl serves HTTPS directly on 443). You can either:

Upload a cert/key pair under Administrators → Settings → SSL Certificate in the web console, or
Use certbot in standalone mode (stop Pritunl briefly to free port 443, issue the cert, then point Pritunl at the resulting files).
8.3 Enable two-factor authentication

Settings → Administrators → enable Google Authenticator / Duo for all admin accounts.

8.4 Regular MongoDB backups
bash
sudo mkdir -p /backup/mongodb
mongodump --uri="mongodb://pritunl_admin:PASSWORD@localhost:27017/pritunl?authSource=admin" \
  --out=/backup/mongodb/$(date +%F)

Automate with a cron job and rotate old backups.

9. Useful Pritunl CLI Commands
Command	Purpose
sudo pritunl version	Show installed version
sudo pritunl default-password	Show/reset default admin password
sudo pritunl reset-password	Force-reset admin password
sudo pritunl set-mongodb <uri>	Change MongoDB connection string
sudo pritunl reset-mongodb	Reset Mongo URI to default
sudo systemctl restart pritunl	Restart the service
sudo journalctl -u pritunl -f	Live-tail Pritunl logs
sudo journalctl -u mongod -f	Live-tail MongoDB logs
10. Troubleshooting

Pritunl web UI unreachable on 443

bash
sudo systemctl status pritunl
sudo ss -tulpn | grep 443
sudo ufw status

Pritunl can't connect to MongoDB

bash
sudo systemctl status mongod
mongosh --eval "db.runCommand({ ping: 1 })"
# Check auth if enabled:
sudo tail -f /var/log/mongodb/mongod.log

VPN clients connect but no internet (no NAT)

Confirm IP forwarding is enabled:
bash
sysctl net.ipv4.ip_forward
# Should return 1; if not:
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
Confirm the Pritunl server's routed/NAT network settings match your intended client subnet.

Version mismatch / upgrade issues

bash
sudo apt update
sudo apt install --only-upgrade pritunl mongodb-org
sudo systemctl restart mongod pritunl
11. Quick Reference — Full Install (Copy/Paste)
bash
# System prep
sudo apt update && sudo apt upgrade -y

# MongoDB 6.0
sudo apt install -y gnupg curl
curl -fsSL https://pgp.mongodb.com/server-6.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-6.0.gpg --dearmor
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-6.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list
sudo apt update && sudo apt install -y mongodb-org
sudo systemctl enable --now mongod

# Pritunl
sudo tee /etc/apt/sources.list.d/pritunl.list << EOF
deb [ signed-by=/usr/share/keyrings/pritunl.gpg ] https://repo.pritunl.com/stable/apt jammy main
EOF
sudo apt install -y gnupg
curl -fsSL https://raw.githubusercontent.com/pritunl/pgp/master/pritunl_repo_pub.asc -o /tmp/pritunl.asc
cat /tmp/pritunl.asc   # confirm it shows a PGP key block before continuing
sudo gpg -o /usr/share/keyrings/pritunl.gpg --dearmor /tmp/pritunl.asc
ls -la /usr/share/keyrings/pritunl.gpg   # confirm non-zero size
sudo apt update && sudo apt install -y pritunl
sudo systemctl enable --now pritunl

# Firewall
sudo ufw allow 443/tcp
sudo ufw allow 1194/udp
sudo ufw allow OpenSSH
sudo ufw enable

# Get credentials
sudo pritunl default-password

Then open https://<server-ip> and complete the setup wizard.
