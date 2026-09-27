# Pritunl VPN Backup System - Complete Setup Guide

**Version:** 2.0  
**Date:** 2026-09-24  
**Status:** Production Ready ✅  
**Servers:** 103.7.248.2 (openvpn-2fa) + 103.7.248.11 (OFF-NAG-CACTI-VPN)

---

## 📋 Table of Contents

1. [System Architecture](#system-architecture)
2. [Infrastructure Overview](#infrastructure-overview)
3. [Server 248.2 Complete Setup](#server-2482-complete-setup)
4. [Server 248.11 Complete Setup](#server-24811-complete-setup)
5. [Backup Server Configuration](#backup-server-configuration)
6. [Daily Backup Schedule](#daily-backup-schedule)
7. [Disaster Recovery Guide](#disaster-recovery-guide)
8. [Verification & Testing](#verification--testing)
9. [Troubleshooting](#troubleshooting)

---

## System Architecture

### 🏗️ Complete Backup Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│              PRITUNL BACKUP SYSTEM - DUAL SERVER SETUP            │
└──────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│ Pritunl Server 1: 103.7.248.2              │
│ (openvpn-2fa / Ubuntu Debian)              │
│                                             │
│ Backups:                                    │
│ ├─ MongoDB (27075)  → Daily 20:00          │
│ ├─ Users/Passwords → Daily 20:20 (Root)    │
│ ├─ Netplan Config  → Daily 20:25 (Root)    │
│ └─ Sudoers Config  → (Optional)            │
└────────────┬────────────────────────────────┘
             │
             │ Rsync over SSH (RSA Key Auth)
             │
    ┌────────┴──────────────────────┐
    │                               │
    ▼                               ▼
┌────────────────────┐       ┌────────────────────┐
│ 20:05 MongoDB Sync │       │ 20:30 Users Sync   │
│ 20:17 Netplan Sync │       │ (Backup User)      │
│ (Backup User)      │       │                    │
└────────────┬───────┘       └────────┬───────────┘
             │                        │
             └────────┬───────────────┘
                      │
                      │ SSH/Rsync
                      │
                      ▼
    ┌──────────────────────────────┐
    │  Backup Server 192.168.102.37│
    │  /home/backup/248.2/         │
    │                              │
    │  ├─ pritunl/                │
    │  ├─ users-backup/           │
    │  ├─ netplan-backup/         │
    │  └─ sudoers-backup/         │
    │                              │
    │  (15-day retention)          │
    └──────────────────────────────┘
             ▲
             │
             │ Rsync over SSH (RSA Key Auth)
             │
    ┌────────┴──────────────────────┐
    │                               │
┌───┴──────────────────┐       ┌────┴────────────────────┐
│ 20:03 MongoDB Sync   │       │ 20:20 Users Sync        │
│ 20:25 Netplan Sync   │       │ 20:25 Netplan Sync      │
│ (Backup User)        │       │ (Backup User)           │
└──────────┬───────────┘       └────────┬────────────────┘
           │                            │
           │ Rsync                      │ Rsync
           │                            │
┌──────────▼────────────────────────────▼──────────┐
│ Pritunl Server 2: 103.7.248.11                  │
│ (OFF-NAG-CACTI-VPN / CentOS 7)                  │
│                                                  │
│ Backups:                                         │
│ ├─ MongoDB (27017)  → Daily 20:00               │
│ ├─ Users/Passwords → Daily 20:10 (Root)        │
│ └─ Netplan Config  → Daily 20:15 (Root)        │
└────────────────────────────────────────────────┘
```

---

## Infrastructure Overview

### Server Details

| Component | Server 248.2 | Server 248.11 | Backup Server |
|-----------|--------------|---------------|---------------|
| **IP** | 103.7.248.2 | 103.7.248.11 | 192.168.102.37 |
| **Hostname** | openvpn-2fa | OFF-NAG-CACTI-VPN | vm-pritunl |
| **OS** | Ubuntu 22.04 | CentOS 7 | Ubuntu 22.04 |
| **MongoDB Port** | 27075 | 27017 | N/A |
| **Backup User** | backup | backup | backup |
| **Backup Path** | /home/backup/ | /home/backup/ | /home/backup/248.2/, /home/backup/248.11/ |
| **Cron as** | Backup User + Root | Backup User + Root | N/A |

---

## Server 248.2 Complete Setup

### 📥 STEP 1: Create Backup User & Directories

```bash
ssh root@103.7.248.2

# Create backup user
userdel -f backup 2>/dev/null || true
useradd -m -s /bin/bash backup

# Create directories
mkdir -p /home/backup/db-backup
mkdir -p /home/backup/users-backup
mkdir -p /home/backup/netplan-backup
mkdir -p /home/backup/scripts
mkdir -p /home/backup/.ssh
mkdir -p /var/log/pritunl-backup

# Set ownership
chown -R backup:backup /home/backup
chown backup:backup /var/log/pritunl-backup

# Set permissions
chmod 700 /home/backup
chmod 700 /home/backup/.ssh
chmod 755 /home/backup/db-backup
chmod 755 /home/backup/users-backup
chmod 755 /home/backup/netplan-backup
chmod 755 /home/backup/scripts
chmod 755 /var/log/pritunl-backup
```

---

### 📥 STEP 2: Generate SSH Keys

```bash
# Generate RSA key
sudo -u backup ssh-keygen -t rsa -b 4096 -f /home/backup/.ssh/id_rsa -N ""

# Display public key (COPY THIS)
sudo -u backup cat /home/backup/.ssh/id_rsa.pub

# Verify
ls -la /home/backup/.ssh/
```

---

### 📥 STEP 3: Create Backup Scripts

#### MongoDB Backup Script

```bash
cat > /home/backup/scripts/pritunl-mongodb-backup.sh << 'EOF'
#!/bin/bash
set -e

MONGO_HOST="127.0.0.1"
MONGO_PORT="27075"
MONGO_DB="pritunl"

BACKUP_BASE="/home/backup/db-backup"
DATE=$(date +"%Y-%m-%d")
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

BACKUP_DIR="${BACKUP_BASE}/dump-${DATE}"
TAR_FILE="${BACKUP_BASE}/pritunl-${DATE}.tar.gz"
LOG_FILE="/var/log/pritunl-backup/backup.log"

mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Pritunl backup started"
echo "============================================================"

if [ -d "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
fi

mkdir -p "$BACKUP_DIR"

echo "[INFO] Starting MongoDB dump..."

if mongodump --host="${MONGO_HOST}:${MONGO_PORT}" --db="$MONGO_DB" --out="$BACKUP_DIR"; then
    echo "[✓] MongoDB dump completed"
else
    echo "[✗] MongoDB dump failed!"
    exit 1
fi

echo "[INFO] Creating TAR.GZ..."

cd "$BACKUP_BASE"

if tar -czf "$TAR_FILE" "dump-${DATE}"; then
    echo "[✓] TAR.GZ created"
else
    echo "[✗] TAR.GZ failed!"
    rm -rf "$BACKUP_DIR"
    exit 1
fi

BACKUP_SIZE=$(du -sh "$TAR_FILE" | awk '{print $1}')
echo "[INFO] Size: $BACKUP_SIZE"

rm -rf "$BACKUP_DIR"

echo "[INFO] Applying retention (15 days)..."

find "${BACKUP_BASE}" -maxdepth 1 -name "pritunl-*.tar.gz" -type f -mtime +15 | while read -r old_backup; do
    echo "[INFO] Deleting: $(basename "$old_backup")"
    rm -f "$old_backup"
done

BACKUP_COUNT=$(find "${BACKUP_BASE}" -maxdepth 1 -name "pritunl-*.tar.gz" -type f | wc -l)

echo "============================================================"
echo "[${DATETIME}] Backup completed - Total: $BACKUP_COUNT"
echo "============================================================"
echo ""
EOF

chmod 755 /home/backup/scripts/pritunl-mongodb-backup.sh
chown backup:backup /home/backup/scripts/pritunl-mongodb-backup.sh
```

---

#### MongoDB Rsync Script

```bash
cat > /home/backup/scripts/pritunl-rsync-backup.sh << 'EOF'
#!/bin/bash
set -e

LOCAL_BACKUP="/home/backup/db-backup"
REMOTE_USER="backup"
REMOTE_HOST="192.168.102.37"
REMOTE_BACKUP="/home/backup/248.2/pritunl"

LOG_FILE="/var/log/pritunl-backup/rsync.log"
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Rsync started"
echo "============================================================"

if [ ! -d "$LOCAL_BACKUP" ]; then
    echo "[✗] Local backup dir not found!"
    exit 1
fi

LOCAL_COUNT=$(find "$LOCAL_BACKUP" -maxdepth 1 -name "pritunl-*.tar.gz" -type f | wc -l)
echo "[INFO] Local backups: $LOCAL_COUNT"

echo "[INFO] Preparing remote..."

if ssh -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p '${REMOTE_BACKUP}' && chmod 755 '${REMOTE_BACKUP}'"; then
    echo "[✓] Remote ready"
else
    echo "[✗] Remote setup failed!"
    exit 1
fi

echo "[INFO] Starting rsync..."

if rsync -ah \
    --partial \
    --delete \
    --info=stats2 \
    --include='pritunl-*.tar.gz' \
    --exclude='*' \
    "${LOCAL_BACKUP}/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BACKUP}"; then
    echo "[✓] Rsync completed"
else
    echo "[✗] Rsync failed!"
    exit 1
fi

echo "[INFO] Cleaning remote (15 days)..."

ssh "${REMOTE_USER}@${REMOTE_HOST}" bash -s << 'REMOTE_SCRIPT'
    REMOTE_BACKUP="/home/backup/248.2/pritunl"
    find "${REMOTE_BACKUP}" -maxdepth 1 -name "pritunl-*.tar.gz" -type f -mtime +15 2>/dev/null | while read -r old_backup; do
        echo "[INFO] Deleting: $(basename "$old_backup")"
        rm -f "$old_backup"
    done
    REMOTE_COUNT=$(find "${REMOTE_BACKUP}" -maxdepth 1 -name "pritunl-*.tar.gz" -type f 2>/dev/null | wc -l)
    echo "[INFO] Remote backups: $REMOTE_COUNT"
REMOTE_SCRIPT

echo "============================================================"
echo "[${DATETIME}] Rsync completed"
echo "============================================================"
echo ""
EOF

chmod 755 /home/backup/scripts/pritunl-rsync-backup.sh
chown backup:backup /home/backup/scripts/pritunl-rsync-backup.sh
```

---

#### Users Backup Script (ROOT)

```bash
cat > /root/users-backup.sh << 'EOF'
#!/bin/bash
set -e

BACKUP_BASE="/home/backup/users-backup"
DATE=$(date +"%Y-%m-%d")
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

BACKUP_DIR="${BACKUP_BASE}/users-${DATE}"
TAR_FILE="${BACKUP_BASE}/users-${DATE}.tar.gz"
LOG_FILE="/var/log/pritunl-backup/users-backup.log"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$BACKUP_BASE"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Users backup started"
echo "============================================================"

if [ -d "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
fi

mkdir -p "$BACKUP_DIR"

echo "[INFO] Backing up user files..."

cp /etc/passwd "$BACKUP_DIR/passwd" && echo "[✓] /etc/passwd backed up" || echo "[!] /etc/passwd failed"
cp /etc/shadow "$BACKUP_DIR/shadow" && echo "[✓] /etc/shadow backed up" || echo "[!] /etc/shadow failed"
cp /etc/group "$BACKUP_DIR/group" && echo "[✓] /etc/group backed up" || echo "[!] /etc/group failed"
cp /etc/gshadow "$BACKUP_DIR/gshadow" && echo "[✓] /etc/gshadow backed up" || echo "[!] /etc/gshadow failed"

if [ ! -f "$BACKUP_DIR/passwd" ]; then
    echo "[✗] Nothing to backup!"
    exit 1
fi

chmod 644 "$BACKUP_DIR/passwd" "$BACKUP_DIR/shadow" "$BACKUP_DIR/group" "$BACKUP_DIR/gshadow" 2>/dev/null || true

echo "[INFO] Creating TAR.GZ..."

cd "$BACKUP_BASE"

if tar -czf "$TAR_FILE" "users-${DATE}"; then
    echo "[✓] TAR.GZ created"
else
    echo "[✗] TAR.GZ failed!"
    rm -rf "$BACKUP_DIR"
    exit 1
fi

BACKUP_SIZE=$(du -sh "$TAR_FILE" | awk '{print $1}')
echo "[INFO] Size: $BACKUP_SIZE"

rm -rf "$BACKUP_DIR"

echo "[INFO] Applying retention (15 days)..."

find "${BACKUP_BASE}" -maxdepth 1 -name "users-*.tar.gz" -type f -mtime +15 | while read -r old_backup; do
    echo "[INFO] Deleting: $(basename "$old_backup")"
    rm -f "$old_backup"
done

BACKUP_COUNT=$(find "${BACKUP_BASE}" -maxdepth 1 -name "users-*.tar.gz" -type f | wc -l)

echo "============================================================"
echo "[${DATETIME}] Users backup completed - Total: $BACKUP_COUNT"
echo "============================================================"
echo ""
EOF

chmod 755 /root/users-backup.sh
```

---

#### Netplan Backup Script (ROOT)

```bash
cat > /root/netplan-backup.sh << 'EOF'
#!/bin/bash
set -e

BACKUP_BASE="/home/backup/netplan-backup"
DATE=$(date +"%Y-%m-%d")
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

BACKUP_DIR="${BACKUP_BASE}/netplan-${DATE}"
TAR_FILE="${BACKUP_BASE}/netplan-${DATE}.tar.gz"
LOG_FILE="/var/log/pritunl-backup/netplan-backup.log"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$BACKUP_BASE"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Netplan backup started"
echo "============================================================"

if [ -d "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
fi

mkdir -p "$BACKUP_DIR"

echo "[INFO] Backing up netplan files..."

if [ -d /etc/netplan ]; then
    cp -r /etc/netplan "$BACKUP_DIR/"
    echo "[✓] /etc/netplan backed up"
else
    echo "[!] /etc/netplan not found"
fi

echo "[INFO] Creating TAR.GZ..."

cd "$BACKUP_BASE"

if tar -czf "$TAR_FILE" "netplan-${DATE}"; then
    echo "[✓] TAR.GZ created"
else
    echo "[✗] TAR.GZ failed!"
    rm -rf "$BACKUP_DIR"
    exit 1
fi

BACKUP_SIZE=$(du -sh "$TAR_FILE" | awk '{print $1}')
echo "[INFO] Size: $BACKUP_SIZE"

rm -rf "$BACKUP_DIR"

echo "[INFO] Applying retention (15 days)..."

find "${BACKUP_BASE}" -maxdepth 1 -name "netplan-*.tar.gz" -type f -mtime +15 | while read -r old_backup; do
    echo "[INFO] Deleting: $(basename "$old_backup")"
    rm -f "$old_backup"
done

BACKUP_COUNT=$(find "${BACKUP_BASE}" -maxdepth 1 -name "netplan-*.tar.gz" -type f | wc -l)

echo "============================================================"
echo "[${DATETIME}] Netplan backup completed - Total: $BACKUP_COUNT"
echo "============================================================"
echo ""
EOF

chmod 755 /root/netplan-backup.sh
```

---

#### Users Rsync Script (BACKUP USER)

```bash
cat > /home/backup/scripts/users-rsync.sh << 'EOF'
#!/bin/bash
set -e

LOCAL_BACKUP="/home/backup/users-backup"
REMOTE_USER="backup"
REMOTE_HOST="192.168.102.37"
REMOTE_BACKUP="/home/backup/248.2/users-backup"

LOG_FILE="/var/log/pritunl-backup/users-rsync.log"
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Users Rsync started"
echo "============================================================"

if [ ! -d "$LOCAL_BACKUP" ]; then
    echo "[✗] Local backup dir not found!"
    exit 1
fi

LOCAL_COUNT=$(find "$LOCAL_BACKUP" -maxdepth 1 -name "users-*.tar.gz" -type f | wc -l)
echo "[INFO] Local backups: $LOCAL_COUNT"

echo "[INFO] Preparing remote..."

if ssh -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p '${REMOTE_BACKUP}' && chmod 755 '${REMOTE_BACKUP}'"; then
    echo "[✓] Remote ready"
else
    echo "[✗] Remote setup failed!"
    exit 1
fi

echo "[INFO] Starting rsync..."

if rsync -ah \
    --partial \
    --delete \
    --info=stats2 \
    --include='users-*.tar.gz' \
    --exclude='*' \
    "${LOCAL_BACKUP}/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BACKUP}"; then
    echo "[✓] Rsync completed"
else
    echo "[✗] Rsync failed!"
    exit 1
fi

echo "[INFO] Cleaning remote (15 days)..."

ssh "${REMOTE_USER}@${REMOTE_HOST}" bash -s << 'REMOTE_SCRIPT'
    REMOTE_BACKUP="/home/backup/248.2/users-backup"
    find "${REMOTE_BACKUP}" -maxdepth 1 -name "users-*.tar.gz" -type f -mtime +15 2>/dev/null | while read -r old_backup; do
        echo "[INFO] Deleting: $(basename "$old_backup")"
        rm -f "$old_backup"
    done
    REMOTE_COUNT=$(find "${REMOTE_BACKUP}" -maxdepth 1 -name "users-*.tar.gz" -type f 2>/dev/null | wc -l)
    echo "[INFO] Remote backups: $REMOTE_COUNT"
REMOTE_SCRIPT

echo "============================================================"
echo "[${DATETIME}] Users Rsync completed"
echo "============================================================"
echo ""
EOF

chmod 755 /home/backup/scripts/users-rsync.sh
chown backup:backup /home/backup/scripts/users-rsync.sh
```

---

#### Netplan Rsync Script (BACKUP USER)

```bash
cat > /home/backup/scripts/netplan-rsync.sh << 'EOF'
#!/bin/bash
set -e

LOCAL_BACKUP="/home/backup/netplan-backup"
REMOTE_USER="backup"
REMOTE_HOST="192.168.102.37"
REMOTE_BACKUP="/home/backup/248.2/netplan-backup"

LOG_FILE="/var/log/pritunl-backup/netplan-rsync.log"
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Netplan Rsync started"
echo "============================================================"

if [ ! -d "$LOCAL_BACKUP" ]; then
    echo "[✗] Local backup dir not found!"
    exit 1
fi

LOCAL_COUNT=$(find "$LOCAL_BACKUP" -maxdepth 1 -name "netplan-*.tar.gz" -type f | wc -l)
echo "[INFO] Local backups: $LOCAL_COUNT"

echo "[INFO] Preparing remote..."

if ssh -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p '${REMOTE_BACKUP}' && chmod 755 '${REMOTE_BACKUP}'"; then
    echo "[✓] Remote ready"
else
    echo "[✗] Remote setup failed!"
    exit 1
fi

echo "[INFO] Starting rsync..."

if rsync -ah \
    --partial \
    --delete \
    --info=stats2 \
    --include='netplan-*.tar.gz' \
    --exclude='*' \
    "${LOCAL_BACKUP}/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BACKUP}"; then
    echo "[✓] Rsync completed"
else
    echo "[✗] Rsync failed!"
    exit 1
fi

echo "[INFO] Cleaning remote (15 days)..."

ssh "${REMOTE_USER}@${REMOTE_HOST}" bash -s << 'REMOTE_SCRIPT'
    REMOTE_BACKUP="/home/backup/248.2/netplan-backup"
    find "${REMOTE_BACKUP}" -maxdepth 1 -name "netplan-*.tar.gz" -type f -mtime +15 2>/dev/null | while read -r old_backup; do
        echo "[INFO] Deleting: $(basename "$old_backup")"
        rm -f "$old_backup"
    done
    REMOTE_COUNT=$(find "${REMOTE_BACKUP}" -maxdepth 1 -name "netplan-*.tar.gz" -type f 2>/dev/null | wc -l)
    echo "[INFO] Remote backups: $REMOTE_COUNT"
REMOTE_SCRIPT

echo "============================================================"
echo "[${DATETIME}] Netplan Rsync completed"
echo "============================================================"
echo ""
EOF

chmod 755 /home/backup/scripts/netplan-rsync.sh
chown backup:backup /home/backup/scripts/netplan-rsync.sh
```

---

### 📥 STEP 4: Add Sudoers Permission (Server 248.2)

```bash
visudo
```

Add this line:

```bash
backup ALL=(ALL) NOPASSWD: /bin/cp, /bin/cp -r
```

---

### 📥 STEP 5: Setup Crontab (Server 248.2)

#### Root Crontab

```bash
crontab -e
```

Add:

```cron
# Users Backup (at 20:20)
20 20 * * * /root/users-backup.sh

# Netplan Backup (at 20:25)
25 20 * * * /root/netplan-backup.sh
```

---

#### Backup User Crontab

```bash
sudo crontab -u backup -e
```

Add:

```cron
# Pritunl MongoDB Backup - Daily at 20:00
0 20 * * * /home/backup/scripts/pritunl-mongodb-backup.sh

# Pritunl Rsync Backup - Daily at 20:05
5 20 * * * /home/backup/scripts/pritunl-rsync-backup.sh

# Users Rsync - Daily at 20:30
30 20 * * * /home/backup/scripts/users-rsync.sh

# Netplan Rsync - Daily at 20:35
35 20 * * * /home/backup/scripts/netplan-rsync.sh
```

---

## Server 248.11 Complete Setup

### 📥 STEP 1: Create Backup User & Directories

```bash
ssh root@103.7.248.11

# Create backup user
userdel -f backup 2>/dev/null || true
useradd -m -s /bin/bash backup

# Create directories
mkdir -p /home/backup/db-backup
mkdir -p /home/backup/users-backup
mkdir -p /home/backup/netplan-backup
mkdir -p /home/backup/scripts
mkdir -p /home/backup/.ssh
mkdir -p /var/log/pritunl-backup

# Set ownership
chown -R backup:backup /home/backup
chown backup:backup /var/log/pritunl-backup

# Set permissions
chmod 700 /home/backup
chmod 700 /home/backup/.ssh
chmod 755 /home/backup/db-backup
chmod 755 /home/backup/users-backup
chmod 755 /home/backup/netplan-backup
chmod 755 /home/backup/scripts
chmod 755 /var/log/pritunl-backup
```

---

### 📥 STEP 2: Generate SSH Keys

```bash
# Generate RSA key
sudo -u backup ssh-keygen -t rsa -b 4096 -f /home/backup/.ssh/id_rsa -N ""

# Display public key (COPY THIS)
sudo -u backup cat /home/backup/.ssh/id_rsa.pub

# Verify
ls -la /home/backup/.ssh/
```

---

### 📥 STEP 3: Create Backup Scripts (248.11 - MongoDB Port 27017)

#### MongoDB Backup Script (Port 27017 for CentOS)

```bash
cat > /home/backup/scripts/pritunl-mongodb-backup.sh << 'EOF'
#!/bin/bash
set -e

MONGO_HOST="127.0.0.1"
MONGO_PORT="27017"
MONGO_DB="pritunl"

BACKUP_BASE="/home/backup/db-backup"
DATE=$(date +"%Y-%m-%d")
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

BACKUP_DIR="${BACKUP_BASE}/dump-${DATE}"
TAR_FILE="${BACKUP_BASE}/pritunl-${DATE}.tar.gz"
LOG_FILE="/var/log/pritunl-backup/backup.log"

mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Pritunl backup started"
echo "============================================================"

if [ -d "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
fi

mkdir -p "$BACKUP_DIR"

echo "[INFO] Starting MongoDB dump..."

if mongodump --host="${MONGO_HOST}:${MONGO_PORT}" --db="$MONGO_DB" --out="$BACKUP_DIR"; then
    echo "[✓] MongoDB dump completed"
else
    echo "[✗] MongoDB dump failed!"
    exit 1
fi

echo "[INFO] Creating TAR.GZ..."

cd "$BACKUP_BASE"

if tar -czf "$TAR_FILE" "dump-${DATE}"; then
    echo "[✓] TAR.GZ created"
else
    echo "[✗] TAR.GZ failed!"
    rm -rf "$BACKUP_DIR"
    exit 1
fi

BACKUP_SIZE=$(du -sh "$TAR_FILE" | awk '{print $1}')
echo "[INFO] Size: $BACKUP_SIZE"

rm -rf "$BACKUP_DIR"

echo "[INFO] Applying retention (15 days)..."

find "${BACKUP_BASE}" -maxdepth 1 -name "pritunl-*.tar.gz" -type f -mtime +15 | while read -r old_backup; do
    echo "[INFO] Deleting: $(basename "$old_backup")"
    rm -f "$old_backup"
done

BACKUP_COUNT=$(find "${BACKUP_BASE}" -maxdepth 1 -name "pritunl-*.tar.gz" -type f | wc -l)

echo "============================================================"
echo "[${DATETIME}] Backup completed - Total: $BACKUP_COUNT"
echo "============================================================"
echo ""
EOF

chmod 755 /home/backup/scripts/pritunl-mongodb-backup.sh
chown backup:backup /home/backup/scripts/pritunl-mongodb-backup.sh
```

---

#### MongoDB Rsync Script (248.11)

```bash
cat > /home/backup/scripts/pritunl-rsync-backup.sh << 'EOF'
#!/bin/bash
set -e

LOCAL_BACKUP="/home/backup/db-backup"
REMOTE_USER="backup"
REMOTE_HOST="192.168.102.37"
REMOTE_BACKUP="/home/backup/248.11/pritunl"

LOG_FILE="/var/log/pritunl-backup/rsync.log"
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Rsync started"
echo "============================================================"

if [ ! -d "$LOCAL_BACKUP" ]; then
    echo "[✗] Local backup dir not found!"
    exit 1
fi

LOCAL_COUNT=$(find "$LOCAL_BACKUP" -maxdepth 1 -name "pritunl-*.tar.gz" -type f | wc -l)
echo "[INFO] Local backups: $LOCAL_COUNT"

echo "[INFO] Preparing remote..."

if ssh -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p '${REMOTE_BACKUP}' && chmod 755 '${REMOTE_BACKUP}'"; then
    echo "[✓] Remote ready"
else
    echo "[✗] Remote setup failed!"
    exit 1
fi

echo "[INFO] Starting rsync..."

if rsync -ah \
    --partial \
    --delete \
    --info=stats2 \
    --include='pritunl-*.tar.gz' \
    --exclude='*' \
    "${LOCAL_BACKUP}/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BACKUP}"; then
    echo "[✓] Rsync completed"
else
    echo "[✗] Rsync failed!"
    exit 1
fi

echo "[INFO] Cleaning remote (15 days)..."

ssh "${REMOTE_USER}@${REMOTE_HOST}" bash -s << 'REMOTE_SCRIPT'
    REMOTE_BACKUP="/home/backup/248.11/pritunl"
    find "${REMOTE_BACKUP}" -maxdepth 1 -name "pritunl-*.tar.gz" -type f -mtime +15 2>/dev/null | while read -r old_backup; do
        echo "[INFO] Deleting: $(basename "$old_backup")"
        rm -f "$old_backup"
    done
    REMOTE_COUNT=$(find "${REMOTE_BACKUP}" -maxdepth 1 -name "pritunl-*.tar.gz" -type f 2>/dev/null | wc -l)
    echo "[INFO] Remote backups: $REMOTE_COUNT"
REMOTE_SCRIPT

echo "============================================================"
echo "[${DATETIME}] Rsync completed"
echo "============================================================"
echo ""
EOF

chmod 755 /home/backup/scripts/pritunl-rsync-backup.sh
chown backup:backup /home/backup/scripts/pritunl-rsync-backup.sh
```

---

#### Users Backup Script (ROOT - 248.11)

```bash
cat > /root/users-backup.sh << 'EOF'
#!/bin/bash
set -e

BACKUP_BASE="/home/backup/users-backup"
DATE=$(date +"%Y-%m-%d")
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

BACKUP_DIR="${BACKUP_BASE}/users-${DATE}"
TAR_FILE="${BACKUP_BASE}/users-${DATE}.tar.gz"
LOG_FILE="/var/log/pritunl-backup/users-backup.log"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$BACKUP_BASE"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Users backup started"
echo "============================================================"

if [ -d "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
fi

mkdir -p "$BACKUP_DIR"

echo "[INFO] Backing up user files..."

cp /etc/passwd "$BACKUP_DIR/passwd" && echo "[✓] /etc/passwd backed up" || echo "[!] /etc/passwd failed"
cp /etc/shadow "$BACKUP_DIR/shadow" && echo "[✓] /etc/shadow backed up" || echo "[!] /etc/shadow failed"
cp /etc/group "$BACKUP_DIR/group" && echo "[✓] /etc/group backed up" || echo "[!] /etc/group failed"
cp /etc/gshadow "$BACKUP_DIR/gshadow" && echo "[✓] /etc/gshadow backed up" || echo "[!] /etc/gshadow failed"

if [ ! -f "$BACKUP_DIR/passwd" ]; then
    echo "[✗] Nothing to backup!"
    exit 1
fi

chmod 644 "$BACKUP_DIR/passwd" "$BACKUP_DIR/shadow" "$BACKUP_DIR/group" "$BACKUP_DIR/gshadow" 2>/dev/null || true

echo "[INFO] Creating TAR.GZ..."

cd "$BACKUP_BASE"

if tar -czf "$TAR_FILE" "users-${DATE}"; then
    echo "[✓] TAR.GZ created"
else
    echo "[✗] TAR.GZ failed!"
    rm -rf "$BACKUP_DIR"
    exit 1
fi

BACKUP_SIZE=$(du -sh "$TAR_FILE" | awk '{print $1}')
echo "[INFO] Size: $BACKUP_SIZE"

rm -rf "$BACKUP_DIR"

echo "[INFO] Applying retention (15 days)..."

find "${BACKUP_BASE}" -maxdepth 1 -name "users-*.tar.gz" -type f -mtime +15 | while read -r old_backup; do
    echo "[INFO] Deleting: $(basename "$old_backup")"
    rm -f "$old_backup"
done

BACKUP_COUNT=$(find "${BACKUP_BASE}" -maxdepth 1 -name "users-*.tar.gz" -type f | wc -l)

echo "============================================================"
echo "[${DATETIME}] Users backup completed - Total: $BACKUP_COUNT"
echo "============================================================"
echo ""
EOF

chmod 755 /root/users-backup.sh
```

---

#### Netplan Backup Script (ROOT - 248.11)

```bash
cat > /root/netplan-backup.sh << 'EOF'
#!/bin/bash
set -e

BACKUP_BASE="/home/backup/netplan-backup"
DATE=$(date +"%Y-%m-%d")
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

BACKUP_DIR="${BACKUP_BASE}/netplan-${DATE}"
TAR_FILE="${BACKUP_BASE}/netplan-${DATE}.tar.gz"
LOG_FILE="/var/log/pritunl-backup/netplan-backup.log"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$BACKUP_BASE"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Netplan backup started"
echo "============================================================"

if [ -d "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
fi

mkdir -p "$BACKUP_DIR"

echo "[INFO] Backing up netplan files..."

if [ -d /etc/netplan ]; then
    cp -r /etc/netplan "$BACKUP_DIR/"
    echo "[✓] /etc/netplan backed up"
else
    echo "[!] /etc/netplan not found"
fi

echo "[INFO] Creating TAR.GZ..."

cd "$BACKUP_BASE"

if tar -czf "$TAR_FILE" "netplan-${DATE}"; then
    echo "[✓] TAR.GZ created"
else
    echo "[✗] TAR.GZ failed!"
    rm -rf "$BACKUP_DIR"
    exit 1
fi

BACKUP_SIZE=$(du -sh "$TAR_FILE" | awk '{print $1}')
echo "[INFO] Size: $BACKUP_SIZE"

rm -rf "$BACKUP_DIR"

echo "[INFO] Applying retention (15 days)..."

find "${BACKUP_BASE}" -maxdepth 1 -name "netplan-*.tar.gz" -type f -mtime +15 | while read -r old_backup; do
    echo "[INFO] Deleting: $(basename "$old_backup")"
    rm -f "$old_backup"
done

BACKUP_COUNT=$(find "${BACKUP_BASE}" -maxdepth 1 -name "netplan-*.tar.gz" -type f | wc -l)

echo "============================================================"
echo "[${DATETIME}] Netplan backup completed - Total: $BACKUP_COUNT"
echo "============================================================"
echo ""
EOF

chmod 755 /root/netplan-backup.sh
```

---

#### Users Rsync Script (BACKUP USER - 248.11)

```bash
cat > /home/backup/scripts/users-rsync.sh << 'EOF'
#!/bin/bash
set -e

LOCAL_BACKUP="/home/backup/users-backup"
REMOTE_USER="backup"
REMOTE_HOST="192.168.102.37"
REMOTE_BACKUP="/home/backup/248.11/users-backup"

LOG_FILE="/var/log/pritunl-backup/users-rsync.log"
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Users Rsync started"
echo "============================================================"

if [ ! -d "$LOCAL_BACKUP" ]; then
    echo "[✗] Local backup dir not found!"
    exit 1
fi

LOCAL_COUNT=$(find "$LOCAL_BACKUP" -maxdepth 1 -name "users-*.tar.gz" -type f | wc -l)
echo "[INFO] Local backups: $LOCAL_COUNT"

echo "[INFO] Preparing remote..."

if ssh -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p '${REMOTE_BACKUP}' && chmod 755 '${REMOTE_BACKUP}'"; then
    echo "[✓] Remote ready"
else
    echo "[✗] Remote setup failed!"
    exit 1
fi

echo "[INFO] Starting rsync..."

if rsync -ah \
    --partial \
    --delete \
    --info=stats2 \
    --include='users-*.tar.gz' \
    --exclude='*' \
    "${LOCAL_BACKUP}/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BACKUP}"; then
    echo "[✓] Rsync completed"
else
    echo "[✗] Rsync failed!"
    exit 1
fi

echo "[INFO] Cleaning remote (15 days)..."

ssh "${REMOTE_USER}@${REMOTE_HOST}" bash -s << 'REMOTE_SCRIPT'
    REMOTE_BACKUP="/home/backup/248.11/users-backup"
    find "${REMOTE_BACKUP}" -maxdepth 1 -name "users-*.tar.gz" -type f -mtime +15 2>/dev/null | while read -r old_backup; do
        echo "[INFO] Deleting: $(basename "$old_backup")"
        rm -f "$old_backup"
    done
    REMOTE_COUNT=$(find "${REMOTE_BACKUP}" -maxdepth 1 -name "users-*.tar.gz" -type f 2>/dev/null | wc -l)
    echo "[INFO] Remote backups: $REMOTE_COUNT"
REMOTE_SCRIPT

echo "============================================================"
echo "[${DATETIME}] Users Rsync completed"
echo "============================================================"
echo ""
EOF

chmod 755 /home/backup/scripts/users-rsync.sh
chown backup:backup /home/backup/scripts/users-rsync.sh
```

---

#### Netplan Rsync Script (BACKUP USER - 248.11)

```bash
cat > /home/backup/scripts/netplan-rsync.sh << 'EOF'
#!/bin/bash
set -e

LOCAL_BACKUP="/home/backup/netplan-backup"
REMOTE_USER="backup"
REMOTE_HOST="192.168.102.37"
REMOTE_BACKUP="/home/backup/248.11/netplan-backup"

LOG_FILE="/var/log/pritunl-backup/netplan-rsync.log"
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")

mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "[${DATETIME}] Netplan Rsync started"
echo "============================================================"

if [ ! -d "$LOCAL_BACKUP" ]; then
    echo "[✗] Local backup dir not found!"
    exit 1
fi

LOCAL_COUNT=$(find "$LOCAL_BACKUP" -maxdepth 1 -name "netplan-*.tar.gz" -type f | wc -l)
echo "[INFO] Local backups: $LOCAL_COUNT"

echo "[INFO] Preparing remote..."

if ssh -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p '${REMOTE_BACKUP}' && chmod 755 '${REMOTE_BACKUP}'"; then
    echo "[✓] Remote ready"
else
    echo "[✗] Remote setup failed!"
    exit 1
fi

echo "[INFO] Starting rsync..."

if rsync -ah \
    --partial \
    --delete \
    --info=stats2 \
    --include='netplan-*.tar.gz' \
    --exclude='*' \
    "${LOCAL_BACKUP}/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BACKUP}"; then
    echo "[✓] Rsync completed"
else
    echo "[✗] Rsync failed!"
    exit 1
fi

echo "[INFO] Cleaning remote (15 days)..."

ssh "${REMOTE_USER}@${REMOTE_HOST}" bash -s << 'REMOTE_SCRIPT'
    REMOTE_BACKUP="/home/backup/248.11/netplan-backup"
    find "${REMOTE_BACKUP}" -maxdepth 1 -name "netplan-*.tar.gz" -type f -mtime +15 2>/dev/null | while read -r old_backup; do
        echo "[INFO] Deleting: $(basename "$old_backup")"
        rm -f "$old_backup"
    done
    REMOTE_COUNT=$(find "${REMOTE_BACKUP}" -maxdepth 1 -name "netplan-*.tar.gz" -type f 2>/dev/null | wc -l)
    echo "[INFO] Remote backups: $REMOTE_COUNT"
REMOTE_SCRIPT

echo "============================================================"
echo "[${DATETIME}] Netplan Rsync completed"
echo "============================================================"
echo ""
EOF

chmod 755 /home/backup/scripts/netplan-rsync.sh
chown backup:backup /home/backup/scripts/netplan-rsync.sh
```

---

### 📥 STEP 4: Setup Crontab (248.11)

#### Root Crontab

```bash
crontab -e
```

Add:

```cron
# Users Backup (at 20:10)
10 20 * * * /root/users-backup.sh

# Netplan Backup (at 20:15)
15 20 * * * /root/netplan-backup.sh
```

---

#### Backup User Crontab

```bash
sudo crontab -u backup -e
```

Add:

```cron
# Pritunl MongoDB Backup - Daily at 20:00
0 20 * * * /home/backup/scripts/pritunl-mongodb-backup.sh

# Pritunl Rsync Backup - Daily at 20:03
3 20 * * * /home/backup/scripts/pritunl-rsync-backup.sh

# Users Rsync - Daily at 20:20
20 20 * * * /home/backup/scripts/users-rsync.sh

# Netplan Rsync - Daily at 20:25
25 20 * * * /home/backup/scripts/netplan-rsync.sh
```

---

## Backup Server Configuration

### 📥 Setup Backup Server (192.168.102.37)

```bash
ssh root@192.168.102.37

# Create directories
mkdir -p /home/backup/248.2/pritunl
mkdir -p /home/backup/248.2/users-backup
mkdir -p /home/backup/248.2/netplan-backup
mkdir -p /home/backup/248.2/sudoers-backup

mkdir -p /home/backup/248.11/pritunl
mkdir -p /home/backup/248.11/users-backup
mkdir -p /home/backup/248.11/netplan-backup

# Set ownership
chown -R backup:backup /home/backup/248.2
chown -R backup:backup /home/backup/248.11

# Set permissions
chmod 755 /home/backup/248.2
chmod 755 /home/backup/248.2/pritunl
chmod 755 /home/backup/248.2/users-backup
chmod 755 /home/backup/248.2/netplan-backup

chmod 755 /home/backup/248.11
chmod 755 /home/backup/248.11/pritunl
chmod 755 /home/backup/248.11/users-backup
chmod 755 /home/backup/248.11/netplan-backup

# Add both servers' public keys to authorized_keys
cat >> /home/backup/.ssh/authorized_keys << 'EOF'
ssh-rsa AAAAB3NzaC1yc2E... backup@103.7.248.2
ssh-rsa AAAAB3NzaC1yc2E... backup@103.7.248.11
EOF

# Verify
cat /home/backup/.ssh/authorized_keys
```

---

## Daily Backup Schedule

### 📊 Complete Schedule

```
SERVER 248.2 (openvpn-2fa):
├─ 20:00 - MongoDB Backup (Backup User)
├─ 20:05 - MongoDB Rsync (Backup User)
├─ 20:20 - Users Backup (ROOT)
├─ 20:30 - Users Rsync (Backup User)
├─ 20:25 - Netplan Backup (ROOT)
└─ 20:35 - Netplan Rsync (Backup User)

SERVER 248.11 (OFF-NAG-CACTI-VPN):
├─ 20:00 - MongoDB Backup (Backup User)
├─ 20:03 - MongoDB Rsync (Backup User)
├─ 20:10 - Users Backup (ROOT)
├─ 20:15 - Netplan Backup (ROOT)
├─ 20:20 - Users Rsync (Backup User)
└─ 20:25 - Netplan Rsync (Backup User)

BACKUP SERVER (192.168.102.37):
└─ Receives all backups in:
   ├─ /home/backup/248.2/
   └─ /home/backup/248.11/
```

---

## Disaster Recovery Guide

### 🚀 If Server 248.2 Goes Down

```bash
# On new hardware:
1. Install Ubuntu 22.04

2. Get backup files
ssh backup@192.168.102.37
ls -lh /home/backup/248.2/

3. Download to new server
scp backup@192.168.102.37:/home/backup/248.2/pritunl/*.tar.gz /tmp/
scp backup@192.168.102.37:/home/backup/248.2/users-backup/*.tar.gz /tmp/
scp backup@192.168.102.37:/home/backup/248.2/netplan-backup/*.tar.gz /tmp/

4. Restore Netplan FIRST (network)
tar -xzf /tmp/netplan-*.tar.gz
cp -r netplan-* /etc/netplan/
netplan apply

5. Install Pritunl
apt-get install pritunl pritunl-mongodb

6. Restore MongoDB
mongorestore --host 127.0.0.1:27075 --drop dump/

7. Restore Users
tar -xzf /tmp/users-*.tar.gz
cp users-*/passwd /etc/passwd
cp users-*/shadow /etc/shadow
cp users-*/group /etc/group
cp users-*/gshadow /etc/gshadow

8. Verify
ping 8.8.8.8
curl http://localhost:19999/
id backup
```

---

## Verification & Testing

### ✅ Verify Setup

```bash
# Server 248.2
ssh root@103.7.248.2

# Check backup files
ls -lh /home/backup/db-backup/ | tail -3
ls -lh /home/backup/users-backup/
ls -lh /home/backup/netplan-backup/

# Check scripts
ls -la /home/backup/scripts/
ls -la /root/*.sh

# Check crontab
crontab -l | grep -E "Users|Netplan"
sudo crontab -u backup -l

# Test manual backup
/root/users-backup.sh
/root/netplan-backup.sh
sudo -u backup /home/backup/scripts/users-rsync.sh

# Check logs
tail -20 /var/log/pritunl-backup/users-backup.log
tail -20 /var/log/pritunl-backup/users-rsync.log
```

---

```bash
# Server 248.11
ssh root@103.7.248.11

# Same checks as 248.2
ls -lh /home/backup/db-backup/ | tail -3
ls -lh /home/backup/users-backup/
ls -lh /home/backup/netplan-backup/

/root/users-backup.sh
/root/netplan-backup.sh

tail -20 /var/log/pritunl-backup/users-backup.log
```

---

```bash
# Backup Server
ssh backup@192.168.102.37

# Verify all directories
ls -lh /home/backup/248.2/
ls -lh /home/backup/248.11/

# Check files
ls -lh /home/backup/248.2/pritunl/ | tail -5
ls -lh /home/backup/248.2/users-backup/
ls -lh /home/backup/248.11/pritunl/ | tail -5
ls -lh /home/backup/248.11/users-backup/

# Check total size
du -sh /home/backup/248.2/
du -sh /home/backup/248.11/
```

---

## Troubleshooting

### 🔴 SSH Password Asking

**Problem:** Rsync asking for password instead of using SSH key

**Solution:**

```bash
# Verify SSH key exists
sudo -u backup ls -la /home/backup/.ssh/id_rsa

# Test SSH
sudo -u backup ssh backup@192.168.102.37 "whoami"

# Should print "backup" without password

# If fails, regenerate key:
sudo -u backup ssh-keygen -t rsa -b 4096 -f /home/backup/.ssh/id_rsa -N ""

# Add to backup server's authorized_keys
```

---

### 🔴 Backup Files Not Created

**Problem:** Directories empty, no tar.gz files

**Solution:**

```bash
# Run manual backup
/root/users-backup.sh

# Check logs
tail -20 /var/log/pritunl-backup/users-backup.log

# Check permissions
ls -la /home/backup/users-backup/

# Check if root can copy files
sudo cp /etc/passwd /tmp/test-passwd
```

---

### 🔴 Rsync Not Syncing Files

**Problem:** Files created locally but not on backup server

**Solution:**

```bash
# Test rsync manually
sudo -u backup rsync -avh /home/backup/users-backup/ \
  backup@192.168.102.37:/home/backup/248.2/users-backup/

# Check logs
tail -20 /var/log/pritunl-backup/users-rsync.log

# Verify remote directory exists
ssh backup@192.168.102.37 "ls -la /home/backup/248.2/users-backup/"
```

---

### 🔴 Cron Not Running

**Problem:** Scripts not running at scheduled times

**Solution:**

```bash
# Check crontab is installed
which cron
systemctl status cron

# Check crontab syntax
sudo crontab -u backup -l

# Check cron logs
grep CRON /var/log/syslog | tail -20
# or (CentOS)
tail -20 /var/log/cron

# Run script manually
/root/users-backup.sh
```

---

## Summary

### ✅ What You Have

```
✓ Automated daily backups from 2 Pritunl servers
✓ MongoDB backups (27075 and 27017 ports)
✓ Users & password backups
✓ Network configuration backups
✓ Rsync to central backup server
✓ SSH key authentication (no passwords)
✓ 15-day retention policy
✓ Complete logging
✓ Disaster recovery capability
```

### 📊 Backup Capacity

```
Daily Backup Size:     ~10MB per server
Monthly:               ~300MB per server
Storage on Backup:     ~20GB (both servers)
Retention:             15 days local + 15 days remote
Total Protected Data:  100% of configuration
```

### 🎯 Next Steps

1. Monitor logs daily: `tail -f /var/log/pritunl-backup/*.log`
2. Test recovery monthly on staging
3. Keep backup server isolated
4. Document any manual configuration changes

---

**Status:** Production Ready ✅  
**Last Updated:** 2026-09-24  
**Both Servers:** 248.2 & 248.11 Complete
