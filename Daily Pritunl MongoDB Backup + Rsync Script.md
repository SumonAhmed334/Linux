# Daily Pritunl MongoDB Local Backup — Full Setup

## 1. Backup location

The backup will be stored only on the Pritunl server.

Main directory:

```bash
/var/backups/pritunl/
```

Each day gets its own date directory:

```text
/var/backups/pritunl/
├── 2026-08-23/
├── 2026-08-24/
├── 2026-08-25/
└── ...
```

The script creates these directories automatically. You do not need to create them manually.

## 2. Create the backup script

Run:

```bash
vi /root/pritunl-backup.sh
```

Paste:

```bash
#!/bin/bash

# ============================================================
# Pritunl Daily Local MongoDB Backup
# Backup time: Every day at 20:00
# ============================================================

set -e

MONGO_HOST="127.0.0.1"
MONGO_PORT="27075"
MONGO_DB="pritunl"

# Main backup directory
BACKUP_BASE="/var/backups/pritunl"

# Today's date
DATE=$(date +"%Y-%m-%d")
BACKUP_DIR="${BACKUP_BASE}/${DATE}"

# Backup log
LOG_FILE="/var/log/pritunl-backup.log"

# Send script output to the log file
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "Pritunl backup started: $(date)"
echo "============================================================"

# Create main/date backup directory if it does not exist
mkdir -p "$BACKUP_DIR"

echo "[INFO] Starting MongoDB dump..."

mongodump \
    --host="${MONGO_HOST}:${MONGO_PORT}" \
    --db="$MONGO_DB" \
    --out="$BACKUP_DIR"

echo "[INFO] MongoDB dump completed."
echo "[INFO] Backup stored at: $BACKUP_DIR"
echo "[INFO] Backup size: $(du -sh "$BACKUP_DIR" | awk '{print $1}')"

echo "============================================================"
echo "Pritunl backup completed successfully: $(date)"
echo "============================================================"
echo
```

Save and exit.

## 3. Make the script executable

```bash
chmod +x /root/pritunl-backup.sh
```

Check:

```bash
ls -lh /root/pritunl-backup.sh
```

You should see executable permission such as:

```text
-rwxr-xr-x
```

## 4. Check that mongodump exists

Run:

```bash
which mongodump
```

Also check the Pritunl MongoDB port:

```bash
ss -lntp | grep 27075
```

The script expects MongoDB to be available on:

```text
127.0.0.1:27075
```

## 5. Run a manual backup test

Before configuring cron, run the script manually:

```bash
/root/pritunl-backup.sh
```

Check the backup:

```bash
ls -lah /var/backups/pritunl/
```

Then:

```bash
find /var/backups/pritunl/ -maxdepth 2 -type f -ls
```

Check the log:

```bash
tail -50 /var/log/pritunl-backup.log
```

If the backup is successful, you should see today's date directory, for example:

```text
/var/backups/pritunl/2026-08-23/
```

## 6. Configure cron for 8:00 PM every day

Edit root's crontab:

```bash
crontab -e
```

Add this line:

```cron
0 20 * * * /root/pritunl-backup.sh
```

This means:

```text
0   = minute 0
20  = 20:00 / 8 PM
*   = every day of the month
*   = every month
*   = every day of the week
```

So the backup will run every day at exactly **8:00 PM server time**.

## 7. Verify cron

Run:

```bash
crontab -l
```

You should see:

```cron
0 20 * * * /root/pritunl-backup.sh
```

Check the server timezone:

```bash
timedatectl
```

Cron uses the server's local timezone.

## 8. How the daily backup will look

For example:

```text
/var/backups/pritunl/
├── 2026-08-23/
│   └── pritunl/
├── 2026-08-24/
│   └── pritunl/
├── 2026-08-25/
│   └── pritunl/
└── 2026-08-26/
    └── pritunl/
```

The main directory `/var/backups/pritunl/` remains the same. A new date directory is created for each day's backup.

## 9. Check backup size

```bash
du -sh /var/backups/pritunl/
```

For a specific date:

```bash
du -sh /var/backups/pritunl/2026-08-23/
```

## 10. Check cron execution logs

On Ubuntu/Debian:

```bash
grep CRON /var/log/syslog | tail -20
```

And check the backup script log:

```bash
tail -100 /var/log/pritunl-backup.log
```

## 11. Important behavior

* Backup runs only on the Pritunl server.
* No SSH or rsync is used.
* No remote server is involved.
* The main backup directory is `/var/backups/pritunl/`.
* The script automatically creates the date directory.
* Local backups are retained; the script does not delete them.
* Cron runs the backup every day at 8:00 PM.
* The backup time follows the Pritunl server's configured timezone.

## 12. Send the local backup to the remote server at 8:30 PM

The local backup will remain on the Pritunl server, and a second copy will be synchronized to the remote server every day at 20:30.

Remote server:

```text
192.168.102.37
```

Remote backup directory:

```text
/root/pritunl-248.2/
```

The remote directory will contain the same date-wise structure:

```text
/root/pritunl-248.2/
├── 2026-08-23/
│   └── pritunl/
├── 2026-08-24/
│   └── pritunl/
└── ...
```

### 12.1 Configure SSH key authentication

On the Pritunl server, run:

```bash
ssh-keygen -t ed25519
```

Copy the key to the remote server:

```bash
ssh-copy-id root@192.168.102.37
```

Test passwordless SSH:

```bash
ssh root@192.168.102.37
```

It should connect without asking for the root password.

### 12.2 Create the rsync script

Create:

```bash
vi /root/pritunl-rsync.sh
```

Paste:

```bash
#!/bin/bash

# ============================================================
# Pritunl Backup - Incremental Rsync to Remote Server
# Run time: Every day at 20:30
# ============================================================

set -e

LOCAL_BACKUP="/var/backups/pritunl/"

REMOTE_USER="root"
REMOTE_HOST="192.168.102.37"
REMOTE_BACKUP="/root/pritunl-248.2/"

LOG_FILE="/var/log/pritunl-rsync.log"

# Send script output to the log file
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "Pritunl rsync started: $(date)"
echo "============================================================"

# Make sure the remote backup directory exists
ssh "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p '${REMOTE_BACKUP}'"

echo "[INFO] Starting incremental rsync..."

rsync -a \
    --partial \
    --info=stats2 \
    "${LOCAL_BACKUP}" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BACKUP}"

echo "[INFO] Rsync completed successfully."

echo "============================================================"
echo "Pritunl rsync completed: $(date)"
echo "============================================================"
echo
```

Make it executable:

```bash
chmod +x /root/pritunl-rsync.sh
```

### 12.3 Test rsync manually

Run:

```bash
/root/pritunl-rsync.sh
```

Then check the remote server:

```bash
ssh root@192.168.102.37
```

Check:

```bash
ls -lah /root/pritunl-248.2/
```

You should see the local date-wise backup copied to the remote server.

### 12.4 Why this is incremental

The command uses:

```bash
rsync -a
```

Rsync compares the source and destination and transfers only new or changed files. It does not re-transfer unchanged `.bson` and `.metadata.json` files every day.

For example, if the remote server already has:

```text
/root/pritunl-248.2/2026-08-23/
```

the next run will not normally copy those unchanged files again. When the new local backup directory appears:

```text
/var/backups/pritunl/2026-08-24/
```

rsync transfers the new files to:

```text
/root/pritunl-248.2/2026-08-24/
```

### 12.5 Configure cron for 8:30 PM

Edit root's crontab:

```bash
crontab -e
```

Keep the existing local backup cron:

```cron
0 20 * * * /root/pritunl-backup.sh
```

Add the rsync cron below it:

```cron
30 20 * * * /root/pritunl-rsync.sh
```

So the final schedule is:

```cron
# Local MongoDB backup - 8:00 PM
0 20 * * * /root/pritunl-backup.sh

# Incremental remote sync - 8:30 PM
30 20 * * * /root/pritunl-rsync.sh
```

### 12.6 Verify cron

```bash
crontab -l
```

### 12.7 Check rsync log

```bash
tail -50 /var/log/pritunl-rsync.log
```

### 12.8 Final backup flow

```text
20:00
   │
   ▼
Pritunl MongoDB
   │
   │ mongodump
   ▼
/var/backups/pritunl/2026-08-24/pritunl/
   │
   │ Local backup remains here
   │
20:30
   │
   │ rsync - incremental
   ▼
192.168.102.37:/root/pritunl-248.2/2026-08-24/pritunl/
```

The local backup is never deleted by the rsync script, and unchanged files are not unnecessarily transferred again.
