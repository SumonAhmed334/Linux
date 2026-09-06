# Pritunl MongoDB Backup and Rsync Setup

## 1. Overview

This document describes the complete setup for taking a daily MongoDB
backup of Pritunl, compressing it as `TAR.GZ`, keeping the backup
locally, and synchronizing the backup to a remote backup server using
`rsync` over passwordless SSH.

### Backup flow

``` text
Pritunl MongoDB
      |
      | mongodump
      v
Local Server: 103.XX.XXX.XX
      |
      | /var/backups/pritunl/
      | pritunl-YYYY-MM-DD.tar.gz
      |
      | rsync at 20:30
      v
Remote Server: 192.XXX.XXX.XX
      |
      | /root/pritunl-248.2/
      | pritunl-YYYY-MM-DD.tar.gz
```

### Schedule

  Task                      Time Script
  ---------------- ------------- ---------------------------
  MongoDB backup     20:00 daily `/root/pritunl-backup.sh`
  Remote rsync       20:30 daily `/root/pritunl-rsync.sh`

------------------------------------------------------------------------

# 2. Server Details

## Source / Pritunl Server

-   IP: `103.XXX.XX.XX`
-   MongoDB host: `127.0.0.1`
-   MongoDB port: `27075`
-   MongoDB database: `pritunl`
-   Local backup directory: `/var/backups/pritunl/`

## Remote Backup Server

-   IP: `192.XXX.XXX.XX`
-   SSH user: `root`
-   Remote backup directory: `/root/pritunl-248.2/`

------------------------------------------------------------------------

# 3. Backup Format

The backup is stored as:

``` text
pritunl-YYYY-MM-DD.tar.gz
```

Example:

``` text
pritunl-2026-09-03.tar.gz
```

`tar.gz` is used because it is a standard Linux archive/compression
format and is convenient for backup and restore operations.

------------------------------------------------------------------------

# 4. Check MongoDB

First confirm that MongoDB is listening on the expected port.

``` bash
ss -tulpn | grep 27075
```

Expected:

``` text
127.0.0.1:27075
```

Also verify the Pritunl database exists:

``` bash
mongosh --host 127.0.0.1 --port 27075
```

On older MongoDB installations, use:

``` bash
mongo --host 127.0.0.1 --port 27075
```

Then:

``` javascript
show dbs
```

Confirm that:

``` text
pritunl
```

is present.

Exit:

``` javascript
exit
```

------------------------------------------------------------------------

# 5. Check `mongodump`

Check whether `mongodump` is installed:

``` bash
which mongodump
```

or:

``` bash
mongodump --version
```

If it is installed, continue.

If it is not installed, install the MongoDB Database Tools package
appropriate for the operating system and MongoDB version.

------------------------------------------------------------------------

# 6. Create Local Backup Directory

Create the local backup directory:

``` bash
mkdir -p /var/backups/pritunl
chmod 700 /var/backups/pritunl
```

Verify:

``` bash
ls -ld /var/backups/pritunl
```

------------------------------------------------------------------------

# 7. Create the Pritunl Backup Script

Create:

``` bash
vi /root/pritunl-backup.sh
```

Put the following content into the file:

``` bash
#!/bin/bash

# ============================================================
# Pritunl Daily MongoDB Backup
# Backup time: Every day at 20:00
# Backup format: TAR.GZ
# ============================================================

set -e

MONGO_HOST="127.0.0.1"
MONGO_PORT="27075"
MONGO_DB="pritunl"

BACKUP_BASE="/var/backups/pritunl"
DATE=$(date +"%Y-%m-%d")

# Temporary MongoDB dump directory
BACKUP_DIR="${BACKUP_BASE}/${DATE}"

# Final TAR.GZ file
TAR_FILE="${BACKUP_BASE}/pritunl-${DATE}.tar.gz"

# Log file
LOG_FILE="/var/log/pritunl-backup.log"

# Send script output to log
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "Pritunl backup started: $(date)"
echo "============================================================"

mkdir -p "$BACKUP_BASE"

# Remove temporary directory if it already exists
rm -rf "$BACKUP_DIR"

# Create temporary dump directory
mkdir -p "$BACKUP_DIR"

echo "[INFO] Starting MongoDB dump..."

mongodump \
    --host="${MONGO_HOST}:${MONGO_PORT}" \
    --db="$MONGO_DB" \
    --out="$BACKUP_DIR"

echo "[INFO] MongoDB dump completed successfully."

# Remove existing TAR.GZ for the same date
rm -f "$TAR_FILE"

echo "[INFO] Creating TAR.GZ archive..."

cd "$BACKUP_BASE"

tar -czvf "$TAR_FILE" "$DATE"

echo "[INFO] TAR.GZ archive created successfully."
echo "[INFO] Backup file: $TAR_FILE"
echo "[INFO] Backup size: $(du -sh "$TAR_FILE" | awk '{print $1}')"

# Remove uncompressed MongoDB dump
echo "[INFO] Removing temporary uncompressed dump..."

rm -rf "$BACKUP_DIR"

echo "[INFO] Temporary dump removed."

echo "============================================================"
echo "Pritunl backup completed successfully: $(date)"
echo "TAR.GZ: $TAR_FILE"
echo "============================================================"
echo
```

Save the file.

Make it executable:

``` bash
chmod +x /root/pritunl-backup.sh
```

Verify:

``` bash
ls -l /root/pritunl-backup.sh
```

------------------------------------------------------------------------

# 8. Test the Local Backup Manually

Run:

``` bash
/root/pritunl-backup.sh
```

Check the backup:

``` bash
ls -lh /var/backups/pritunl/
```

Expected:

``` text
pritunl-2026-09-03.tar.gz
```

Check the log:

``` bash
tail -50 /var/log/pritunl-backup.log
```

The log should show:

``` text
MongoDB dump completed successfully.
TAR.GZ archive created successfully.
Pritunl backup completed successfully.
```

------------------------------------------------------------------------

# 9. Verify the TAR.GZ Archive

List the contents without extracting:

``` bash
tar -tzvf /var/backups/pritunl/pritunl-2026-09-03.tar.gz
```

The archive should contain the MongoDB dump files.

For a simple integrity test:

``` bash
tar -tzf /var/backups/pritunl/pritunl-2026-09-03.tar.gz > /dev/null
echo $?
```

Expected:

``` text
0
```

A return code of `0` means the archive can be read successfully.

------------------------------------------------------------------------

# 10. Configure SSH Key-Based Authentication

The rsync process must run automatically from cron, so it should not
require a password.

From the Pritunl server:

``` bash
ssh root@192.XXX.XX.XX
```

Confirm that SSH access works.

Exit:

``` bash
exit
```

If passwordless authentication has not already been configured, run:

``` bash
ssh-keygen -t ed25519
```

Press Enter through the prompts if the default location is acceptable.

Then copy the public key:

``` bash
ssh-copy-id root@192.XXX.XXX.XX
```

Enter the remote root password when requested.

Test:

``` bash
ssh root@192.XXX.XXX.XX
```

If it logs in without asking for a password, passwordless SSH is
working.

Exit:

``` bash
exit
```

------------------------------------------------------------------------

# 11. Create Remote Backup Directory

From the Pritunl server:

``` bash
ssh root@192.XXX.XXX.XX "mkdir -p /root/pritunl-248.2 && chmod 700 /root/pritunl-248.2"
```

Verify:

``` bash
ssh root@192.XXX.XXX.XX "ls -ld /root/pritunl-248.2"
```

------------------------------------------------------------------------

# 12. Check Rsync

Check whether rsync is installed:

``` bash
which rsync
```

Expected:

``` text
/usr/bin/rsync
```

If necessary, install it using the package manager appropriate for the
OS.

------------------------------------------------------------------------

# 13. Create the Rsync Script

Create:

``` bash
vi /root/pritunl-rsync.sh
```

Put the following content into the file:

``` bash
#!/bin/bash

# ============================================================
# Pritunl TAR.GZ Backup - Rsync to Remote Server
# Run time: Every day at 20:30
# ============================================================

set -e

LOCAL_BACKUP="/var/backups/pritunl/"

REMOTE_USER="root"
REMOTE_HOST="192.XXX.XXX.XX"
REMOTE_BACKUP="/root/pritunl-248.2/"

LOG_FILE="/var/log/pritunl-rsync.log"

SSH="/usr/bin/ssh"
RSYNC="/usr/bin/rsync"

# Send output to log
exec >> "$LOG_FILE" 2>&1

echo "============================================================"
echo "Pritunl TAR.GZ rsync started: $(date)"
echo "============================================================"

# Make sure remote directory exists
"$SSH" "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p '${REMOTE_BACKUP}' && chmod 700 '${REMOTE_BACKUP}'"

echo "[INFO] Starting TAR.GZ backup rsync..."

# Sync only TAR.GZ files
"$RSYNC" -ah \
    --partial \
    --info=stats2 \
    --include='*.tar.gz' \
    --exclude='*' \
    "${LOCAL_BACKUP}" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BACKUP}"

echo "[INFO] TAR.GZ backup rsync completed successfully."

echo "============================================================"
echo "Pritunl TAR.GZ rsync completed: $(date)"
echo "============================================================"
echo
```

Save the file.

Make it executable:

``` bash
chmod +x /root/pritunl-rsync.sh
```

Verify:

``` bash
ls -l /root/pritunl-rsync.sh
```

------------------------------------------------------------------------

# 14. Test Rsync Manually

Run:

``` bash
/root/pritunl-rsync.sh
```

Check the rsync log:

``` bash
tail -50 /var/log/pritunl-rsync.log
```

Check the remote server:

``` bash
ssh root@192.XXX.XXX.XX "ls -lh /root/pritunl-248.2/"
```

Expected:

``` text
pritunl-2026-09-03.tar.gz
```

------------------------------------------------------------------------

# 15. Verify Remote Backup Integrity

Run:

``` bash
ssh root@192.XXX.XXX.XX \
"tar -tzf /root/pritunl-248.2/pritunl-2026-09-03.tar.gz > /dev/null && echo 'Backup OK'"
```

Expected:

``` text
Backup OK
```

------------------------------------------------------------------------

# 16. Configure Cron

The required schedule is:

-   20:00 --- create MongoDB backup
-   20:30 --- rsync backup to remote server

Edit root cron:

``` bash
crontab -e
```

Add:

``` cron
0 20 * * * /root/pritunl-backup.sh
30 20 * * * /root/pritunl-rsync.sh
```

Verify:

``` bash
crontab -l
```

The relevant entries should be:

``` text
0 20 * * * /root/pritunl-backup.sh
30 20 * * * /root/pritunl-rsync.sh
```

------------------------------------------------------------------------

# 17. Remove the Old Invalid Cron Entry

If the following old entry exists:

``` cron
20 00 * * * root pritunl-backup_run.sh
```

remove it.

Reason: `/root/pritunl-backup_run.sh` does not exist, so that cron entry
is invalid.

The correct backup command is:

``` cron
0 20 * * * /root/pritunl-backup.sh
```

Do not keep both entries.

------------------------------------------------------------------------

# 18. Important Cron Note

The backup cron must execute before the rsync cron.

Correct:

``` text
20:00  -> MongoDB dump + TAR.GZ creation
20:30  -> rsync TAR.GZ to remote server
```

The 30-minute gap gives the backup script enough time to complete before
rsync starts.

------------------------------------------------------------------------

# 19. Complete Backup Process

Every day at 20:00:

### Step 1 --- Create temporary dump directory

``` text
/var/backups/pritunl/YYYY-MM-DD/
```

### Step 2 --- Run `mongodump`

The script dumps:

``` text
MongoDB database: pritunl
MongoDB host: 127.0.0.1
MongoDB port: 27075
```

### Step 3 --- Create TAR.GZ

Example:

``` text
/var/backups/pritunl/pritunl-2026-09-03.tar.gz
```

### Step 4 --- Remove temporary uncompressed dump

The temporary:

``` text
/var/backups/pritunl/2026-09-03/
```

is removed after the archive is successfully created.

Therefore the local directory normally contains only the compressed
backup files.

### Step 5 --- At 20:30, rsync runs

The rsync script copies only:

``` text
*.tar.gz
```

to:

``` text
root@192.XXX.XXX.XX:/root/pritunl-248.2/
```

------------------------------------------------------------------------

# 20. Local Backup Verification

List local backups:

``` bash
ls -lh /var/backups/pritunl/
```

Check backup log:

``` bash
tail -100 /var/log/pritunl-backup.log
```

Check the latest backup:

``` bash
ls -lht /var/backups/pritunl/ | head
```

------------------------------------------------------------------------

# 21. Remote Backup Verification

List remote backups:

``` bash
ssh root@192.XXX.XXX.XX "ls -lh /root/pritunl-248.2/"
```

Check the latest remote backup:

``` bash
ssh root@192.XXX.XXX.XX "ls -lht /root/pritunl-248.2/ | head"
```

Check rsync log:

``` bash
tail -100 /var/log/pritunl-rsync.log
```

------------------------------------------------------------------------

# 22. Restore / Extract a Backup

Create a temporary restore directory:

``` bash
mkdir -p /tmp/pritunl-restore
```

Extract:

``` bash
tar -xzvf /var/backups/pritunl/pritunl-2026-09-03.tar.gz \
-C /tmp/pritunl-restore
```

Check extracted files:

``` bash
ls -lah /tmp/pritunl-restore/
```

The extracted directory will contain the MongoDB dump.

------------------------------------------------------------------------

# 23. MongoDB Restore

Do not restore directly into production without first checking the
backup and confirming the required restore point.

Example restore command:

``` bash
mongorestore \
    --host="127.0.0.1:27075" \
    --db="pritunl" \
    /tmp/pritunl-restore/2026-09-03/pritunl
```

The exact restore path may vary depending on the directory structure
inside the archive.

Before production restoration:

1.  Stop or isolate the relevant application if required.
2.  Take a current backup.
3.  Confirm the restore point/date.
4.  Verify MongoDB compatibility.
5.  Test the restored data.
6.  Start/validate Pritunl services.

------------------------------------------------------------------------

# 24. Check Backup Archive Structure

If you are unsure about the restore path, first run:

``` bash
tar -tzvf /var/backups/pritunl/pritunl-2026-09-03.tar.gz
```

This shows the exact directory structure.

------------------------------------------------------------------------

# 25. Useful Troubleshooting Commands

## Check Pritunl

``` bash
systemctl status pritunl
```

## Check MongoDB port

``` bash
ss -tulpn | grep 27075
```

## Check mongodump

``` bash
which mongodump
mongodump --version
```

## Test MongoDB dump manually

``` bash
mongodump \
    --host="127.0.0.1:27075" \
    --db="pritunl" \
    --out="/tmp/pritunl-test"
```

## Check local disk space

``` bash
df -h
```

## Check backup directory size

``` bash
du -sh /var/backups/pritunl/
```

## Check remote disk space

``` bash
ssh root@192.XXX.XXX.XX "df -h"
```

## Check remote backup directory size

``` bash
ssh root@192.XXX.XXX.XX "du -sh /root/pritunl-248.2/"
```

------------------------------------------------------------------------

# 26. Troubleshooting: SSH

Test:

``` bash
ssh -v root@192.XXX.XXX.XX
```

Check public key:

``` bash
cat /root/.ssh/id_ed25519.pub
```

Check authorized keys on remote server:

``` bash
ssh root@192.XXX.XXX.XX "cat /root/.ssh/authorized_keys"
```

Check SSH permissions:

``` bash
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
```

------------------------------------------------------------------------

# 27. Troubleshooting: Rsync

Check:

``` bash
which rsync
```

Test rsync manually:

``` bash
rsync -av \
/var/backups/pritunl/ \
root@192.168.102.37:/root/pritunl-248.2/
```

Check the rsync log:

``` bash
cat /var/log/pritunl-rsync.log
```

------------------------------------------------------------------------

# 28. Troubleshooting: Cron

Check cron service:

``` bash
systemctl status crond
```

On systems using `cron`:

``` bash
systemctl status cron
```

Check root cron:

``` bash
crontab -l
```

Check cron-related logs:

``` bash
grep -i cron /var/log/cron | tail -50
```

If `/var/log/cron` does not exist, check the system's journal:

``` bash
journalctl -u crond --since today
```

------------------------------------------------------------------------

# 29. Test Cron Commands Without Waiting

You can manually run exactly what cron will execute:

``` bash
/root/pritunl-backup.sh
```

Then:

``` bash
/root/pritunl-rsync.sh
```

This is useful for validating the complete process before waiting for
the scheduled time.

------------------------------------------------------------------------

# 30. Expected Final Directory Structure

## Local Pritunl server

``` text
/root/
├── pritunl-backup.sh
└── pritunl-rsync.sh

/var/backups/pritunl/
├── pritunl-2026-09-01.tar.gz
├── pritunl-2026-09-02.tar.gz
└── pritunl-2026-09-03.tar.gz
```

Logs:

``` text
/var/log/pritunl-backup.log
/var/log/pritunl-rsync.log
```

## Remote backup server

``` text
/root/pritunl-248.2/
├── pritunl-2026-09-01.tar.gz
├── pritunl-2026-09-02.tar.gz
└── pritunl-2026-09-03.tar.gz
```

------------------------------------------------------------------------

# 31. Retention Policy

The current scripts intentionally do **not** delete old backups.

Local:

``` text
/var/backups/pritunl/
```

Remote:

``` text
/root/pritunl-248.2/
```

Both locations retain the backups until they are manually removed or a
separate retention policy is implemented.

If a retention policy is required later, it can be added separately
after deciding how many days of backups should be retained.

Example policy:

``` text
Keep last 30 days
Delete backups older than 30 days
```

Do not add automatic deletion until the required retention period is
confirmed.

------------------------------------------------------------------------

# 32. Security Considerations

The backup contains Pritunl MongoDB data and should be protected.

Recommended permissions:

``` bash
chmod 700 /var/backups/pritunl
chmod 700 /root/pritunl-248.2
```

Backup files should not be world-readable.

Check:

``` bash
ls -lah /var/backups/pritunl/
```

The remote backup server should also be protected because the backup may
contain sensitive VPN/application configuration data.

------------------------------------------------------------------------

# 33. Final Cron Configuration

The final required cron configuration is:

``` cron
0 20 * * * /root/pritunl-backup.sh
30 20 * * * /root/pritunl-rsync.sh
```

Meaning:

``` text
Every day 20:00
    |
    +--> mongodump
    |
    +--> create pritunl-YYYY-MM-DD.tar.gz
    |
    +--> keep backup locally
    |
    v
Every day 20:30
    |
    +--> rsync *.tar.gz
    |
    +--> remote server 192.XXX.XXX.XX
    |
    +--> /root/pritunl-248.2/
```

------------------------------------------------------------------------

# 34. Final Verification Checklist

Run the following commands to confirm the entire setup.

### Local backup script

``` bash
ls -l /root/pritunl-backup.sh
```

### Rsync script

``` bash
ls -l /root/pritunl-rsync.sh
```

### MongoDB

``` bash
ss -tulpn | grep 27075
```

### Local backups

``` bash
ls -lh /var/backups/pritunl/
```

### Local archive integrity

``` bash
tar -tzf /var/backups/pritunl/pritunl-2026-09-03.tar.gz > /dev/null
echo $?
```

Expected:

``` text
0
```

### Passwordless SSH

``` bash
ssh root@192.XXX.XXX.XX "hostname"
```

### Remote backups

``` bash
ssh root@192.XXX.XXX.XX "ls -lh /root/pritunl-248.2/"
```

### Remote archive integrity

``` bash
ssh root@192.XXX.XXX.XX \
"tar -tzf /root/pritunl-248.2/pritunl-2026-09-03.tar.gz > /dev/null && echo 'Backup OK'"
```

### Backup log

``` bash
tail -50 /var/log/pritunl-backup.log
```

### Rsync log

``` bash
tail -50 /var/log/pritunl-rsync.log
```

### Cron

``` bash
crontab -l
```

Required:

``` cron
0 20 * * * /root/pritunl-backup.sh
30 20 * * * /root/pritunl-rsync.sh
```

------------------------------------------------------------------------

# 35. Final Status

The completed solution provides:

-   Daily Pritunl MongoDB backup at **20:00**
-   MongoDB database: `pritunl`
-   MongoDB port: `27075`
-   Backup format: **TAR.GZ**
-   Local backup storage: `/var/backups/pritunl/`
-   Daily remote synchronization at **20:30**
-   Remote server: `192.XXX.XXX.XX`
-   Remote storage: `/root/pritunl-248.2/`
-   Passwordless SSH authentication
-   Rsync synchronization
-   Local backup retention
-   Remote backup retention
-   Separate backup and rsync logs
-   Manual integrity verification
-   Restore/extraction procedure

This is the final working backup architecture.
