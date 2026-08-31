# Seafile 6.2.2 Troubleshooting & Recovery Runbook

## Server Information

- **Hostname:** FHL-SMB-SEA
- **OS:** CentOS Linux 7 (Core)
- **Server IP:** `192.168.42.14`
- **Seafile Version:** `6.2.2`
- **Installation Root:** `/opt/seafile/install`
- **Seafile Application:** `/opt/seafile/install/seafile-server-6.2.2`
- **Latest Symlink:** `/opt/seafile/install/seafile-server-latest`
- **Seafile GUI:** `http://192.168.42.14:8000`
- **MySQL:** `127.0.0.1:3306`

> **Purpose:** Troubleshoot and recover the existing Seafile installation without unnecessarily reinstalling Seafile or modifying existing libraries/data.

---

# 1. Current Installation Structure

Expected structure:

```text
/opt/seafile/install/
├── ccnet/
├── conf/
├── logs/
├── pids/
├── seafile-data/
├── seafile-server-6.2.2/
├── seafile-server-latest -> seafile-server-6.2.2
└── seahub-data/
```

Backup application copy:

```text
/var/backup/seafile/install/seafile-server-6.2.2/
```

Do not use the backup copy for production startup unless the primary installation is confirmed damaged.

---

# 2. Initial Service Check

## Check systemd

```bash
systemctl status seafile
systemctl status seahub
```

For this older Seafile installation, it is possible that these services do not exist as systemd units.

If you receive:

```text
Unit seafile.service could not be found.
Unit seahub.service could not be found.
```

this does **not** necessarily mean Seafile is missing.

The installation may use the supplied `seafile.sh` and `seahub.sh` scripts directly.

---

# 3. Check Running Seafile Processes

```bash
ps -ef | grep -iE "seafile|seahub|gunicorn" | grep -v grep
```

If no output is returned, Seafile/Seahub is not currently running.

More specific:

```bash
ps -ef | grep -iE "seaf-server|seafile" | grep -v grep
```

```bash
ps -ef | grep -iE "seahub|gunicorn" | grep -v grep
```

---

# 4. Check Listening Ports

Full port list:

```bash
ss -tulpn
```

Seafile-specific:

```bash
ss -lntp | grep -E ':80|:443|:8000|:8082'
```

For this installation, port `8000` is important because the configuration contains:

```text
SERVICE_URL = http://192.168.42.14:8000
```

Check specifically:

```bash
ss -lntp | grep ':8000'
```

If there is no output, Seahub is not listening on port 8000.

---

# 5. Locate Seafile Installation

If the installation location is unknown:

```bash
find / -type f \( -name "seafile.sh" -o -name "seahub.sh" \) 2>/dev/null
```

For this server the primary installation is:

```text
/opt/seafile/install/seafile-server-6.2.2/seafile.sh
/opt/seafile/install/seafile-server-6.2.2/seahub.sh
```

Check:

```bash
ls -lah /opt/seafile/
ls -lah /opt/seafile/install/
ls -lah /opt/seafile/install/seafile-server-6.2.2/
```

---

# 6. Verify Seafile Data Directories

Check:

```bash
ls -ld /opt/seafile/install/ccnet
ls -ld /opt/seafile/install/conf
ls -ld /opt/seafile/install/seafile-data
ls -ld /opt/seafile/install/seahub-data
```

Check data size:

```bash
du -sh /opt/seafile/install/seafile-data
```

Check directory structure:

```bash
find /opt/seafile/install/seafile-data -maxdepth 2 -type d | head -50
```

Do **not** delete or recreate:

```text
/opt/seafile/install/seafile-data
/opt/seafile/install/ccnet
/opt/seafile/install/seahub-data
```

---

# 7. Configuration Files

Configuration directory:

```text
/opt/seafile/install/conf/
```

List:

```bash
ls -lah /opt/seafile/install/conf/
```

Important files:

```text
ccnet.conf
seafile.conf
seafdav.conf
seahub_settings.py
```

Read Seafile configuration:

```bash
cat /opt/seafile/install/conf/seafile.conf
```

Read CCNet configuration:

```bash
cat /opt/seafile/install/conf/ccnet.conf
```

Read Seahub configuration:

```bash
cat /opt/seafile/install/conf/seahub_settings.py
```

---

# 8. Important Existing Configuration

The existing `ccnet.conf` contains the following important values:

```ini
[General]
USER_NAME = FHL-SMB-SEA
ID = <server-id>
NAME = FHL-SMB-SEA
SERVICE_URL = http://192.168.42.14:8000

[Client]
PORT = 13419

[Database]
ENGINE = mysql
HOST = 127.0.0.1
PORT = 3306
USER = seafile
PASSWD = <password>
DB = ccnet-db
CONNECTION_CHARSET = utf8
```

The Seahub configuration uses:

```text
Database: seahub-db
DB User: seafile
DB Host: 127.0.0.1
DB Port: 3306
```

---

# 9. MySQL Checks

Check MySQL:

```bash
systemctl status mysqld
```

Check port:

```bash
ss -lntp | grep ':3306'
```

Check databases:

```bash
mysql -e "SHOW DATABASES;"
```

Check the Seafile database account:

```bash
mysql -e "SELECT User,Host FROM mysql.user WHERE User='seafile';"
```

Check Seahub tables:

```bash
mysql -e "USE seahub-db; SHOW TABLES;"
```

If the database name is different in your configuration, use the configured database name.

---

# 10. Linux Service User / UID Check

Check Seafile-related users:

```bash
getent passwd | grep -iE "seafile|sea"
```

Check UID 500:

```bash
getent passwd 500
```

Check GID 500:

```bash
getent group 500
```

On the recovered server, Seafile application files were observed with numeric ownership such as:

```text
500:500
```

while:

```bash
getent passwd 500
```

returned no user.

This can indicate that the original service account was removed during restoration.

## Important

Do **not** immediately run:

```bash
chown -R seafile:seafile /opt/seafile/install
```

First determine the original UID/GID and intended service account.

---

# 11. Check Existing Ownership

```bash
ls -ld /opt/seafile/install
ls -ld /opt/seafile/install/ccnet
ls -ld /opt/seafile/install/conf
ls -ld /opt/seafile/install/seafile-data
ls -ld /opt/seafile/install/seahub-data
```

Check application ownership:

```bash
ls -lah /opt/seafile/install/seafile-server-6.2.2/
```

Find files owned by UID 500:

```bash
find /opt/seafile/install -uid 500 -ls | head -50
```

Find root-owned files:

```bash
find /opt/seafile/install -user root -ls | head -50
```

---

# 12. Check for Existing Startup Configuration

Search for systemd/init files:

```bash
grep -RniE "seafile|seahub|ccnet" /etc/systemd/system /usr/lib/systemd/system /etc/init.d 2>/dev/null
```

If nothing is returned, Seafile may have been started manually.

Check shell history:

```bash
history | grep -iE "seafile|seahub|mysql|nginx|httpd"
```

---

# 13. Seafile 6.2.2 Start/Stop Commands

Change directory:

```bash
cd /opt/seafile/install/seafile-server-6.2.2
```

Start Seafile:

```bash
./seafile.sh start
```

Stop:

```bash
./seafile.sh stop
```

Restart:

```bash
./seafile.sh restart
```

### Note

Seafile 6.2.2 does not provide a normal `status` argument for `seafile.sh`.

Therefore:

```bash
./seafile.sh status
```

may only display:

```text
seafile.sh { start | stop | restart }
```

This is normal for this version.

---

# 14. Start Seahub

Start Seahub on port 8000:

```bash
./seahub.sh start 8000
```

Stop:

```bash
./seahub.sh stop 8000
```

Restart:

```bash
./seahub.sh restart 8000
```

Default port is normally 8000 if no port is supplied.

---

# 15. Recommended Manual Startup Sequence

After confirming MySQL and configuration:

```bash
cd /opt/seafile/install/seafile-server-6.2.2
```

Start Seafile:

```bash
./seafile.sh start
```

Check:

```bash
ps -ef | grep -iE "seafile|seaf-server" | grep -v grep
```

Start Seahub:

```bash
./seahub.sh start 8000
```

Check:

```bash
ps -ef | grep -iE "seahub|gunicorn" | grep -v grep
```

Check port:

```bash
ss -lntp | grep ':8000'
```

---

# 16. Test the Web GUI Locally

Test localhost:

```bash
curl -I http://127.0.0.1:8000
```

Test server IP:

```bash
curl -I http://192.168.42.14:8000
```

If working, open:

```text
http://192.168.42.14:8000
```

from a browser.

---

# 17. Seahub Troubleshooting

Check Seahub log:

```bash
tail -100 /opt/seafile/install/logs/seahub.log
```

Follow live:

```bash
tail -f /opt/seafile/install/logs/seahub.log
```

Search errors:

```bash
grep -iE "error|fatal|failed|exception|traceback|mysql|database|permission" /opt/seafile/install/logs/seahub.log | tail -100
```

---

# 18. Seafile Troubleshooting

Check:

```bash
tail -100 /opt/seafile/install/logs/seafile.log
```

Search:

```bash
grep -iE "error|fatal|failed|exception|database|mysql|permission" /opt/seafile/install/logs/seafile.log | tail -100
```

List logs:

```bash
ls -lah /opt/seafile/install/logs/
```

---

# 19. Check PID Files

```bash
ls -lah /opt/seafile/install/pids/
```

Check processes:

```bash
ps -ef | grep -iE "seafile|seahub|gunicorn" | grep -v grep
```

Do not delete PID files until you confirm that the corresponding processes are not running.

---

# 20. Check Firewall

CentOS 7:

```bash
systemctl status firewalld
```

Show firewall configuration:

```bash
firewall-cmd --list-all
```

Show open ports:

```bash
firewall-cmd --list-ports
```

If direct port 8000 access is intentionally required:

```bash
firewall-cmd --permanent --add-port=8000/tcp
firewall-cmd --reload
```

Verify:

```bash
firewall-cmd --list-ports
```

Only expose port 8000 directly if that matches the network/security design.

---

# 21. Check iptables

```bash
iptables -L -n -v
```

Look for rules affecting:

```text
8000/tcp
80/tcp
443/tcp
```

Do not flush iptables rules during troubleshooting.

Avoid:

```bash
iptables -F
```

unless you have a controlled recovery procedure.

---

# 22. Check SELinux

Check status:

```bash
getenforce
```

Check recent AVC messages:

```bash
ausearch -m avc -ts recent 2>/dev/null | tail -50
```

Do not permanently disable SELinux just to make Seafile start.

---

# 23. Nginx / Apache Reverse Proxy

Check Nginx:

```bash
systemctl status nginx
```

Check Apache:

```bash
systemctl status httpd
```

Check ports:

```bash
ss -lntp | grep -E ':80|:443'
```

Nginx configuration test:

```bash
nginx -t
```

Search Nginx configuration:

```bash
grep -Rni "8000\|seafile" /etc/nginx/ 2>/dev/null
```

Search Apache configuration:

```bash
grep -Rni "8000\|seafile" /etc/httpd/ 2>/dev/null
```

---

# 24. Troubleshooting by Symptom

## Symptom: GUI does not open

Check:

```bash
ss -lntp | grep ':8000'
```

If empty:

```bash
ps -ef | grep -iE "seahub|gunicorn" | grep -v grep
```

Then:

```bash
tail -100 /opt/seafile/install/logs/seahub.log
```

---

## Symptom: Seafile does not start

Check:

```bash
./seafile.sh start
```

Then:

```bash
tail -100 /opt/seafile/install/logs/seafile.log
```

Check:

```bash
systemctl status mysqld
```

---

## Symptom: Seahub does not start

Run:

```bash
./seahub.sh start 8000
```

Then:

```bash
tail -100 /opt/seafile/install/logs/seahub.log
```

Look for:

```text
Traceback
MySQL
Database
Permission denied
Address already in use
ImportError
```

---

## Symptom: MySQL connection failure

Check:

```bash
systemctl status mysqld
```

```bash
ss -lntp | grep ':3306'
```

```bash
mysql -e "SHOW DATABASES;"
```

Verify the database settings in:

```text
/opt/seafile/install/conf/ccnet.conf
/opt/seafile/install/conf/seahub_settings.py
```

---

## Symptom: Permission denied

Check:

```bash
ls -ld /opt/seafile/install/*
```

Search logs:

```bash
grep -Ri "permission denied" /opt/seafile/install/logs/ 2>/dev/null | tail -50
```

Verify the intended Linux user before changing ownership.

Do **not** use:

```bash
chmod -R 777 /opt/seafile
```

---

## Symptom: Local GUI works but remote GUI does not

Run on the server:

```bash
curl -I http://127.0.0.1:8000
```

```bash
curl -I http://192.168.42.14:8000
```

Then check:

```bash
firewall-cmd --list-all
iptables -L -n -v
```

Also check upstream firewall/network ACLs.

---

# 25. Backup and Restore Checks

Existing application backup:

```text
/var/backup/seafile/install/seafile-server-6.2.2/
```

Check:

```bash
ls -lah /var/backup/seafile/
```

Compare configuration if needed:

```bash
diff -u /opt/seafile/install/conf/seafile.conf /var/backup/seafile/install/seafile-server-6.2.2/conf/seafile.conf
```

Do not overwrite production configuration without reviewing the differences.

---

# 26. Do NOT Run These During Initial Recovery

Avoid these commands until the existing installation has been verified:

```bash
./setup-seafile.sh
```

```bash
./setup-seafile-mysql.sh
```

Do not recreate existing databases.

Do not delete:

```text
seafile-data
ccnet
seahub-data
```

Do not blindly run:

```bash
chown -R ...
```

Do not blindly run:

```bash
chmod -R 777 ...
```

Do not run filesystem repair or garbage collection until the database/data state has been verified.

---

# 27. Seafile Data Verification

Check size:

```bash
du -sh /opt/seafile/install/seafile-data
```

Check:

```bash
find /opt/seafile/install/seafile-data -maxdepth 2 -type d | head -50
```

The existence of `seafile-data` does not by itself guarantee that the database and filesystem are consistent.

---

# 28. Systemd Startup

If the existing installation is confirmed working manually, configure automatic startup.

Before creating a systemd service, determine the correct service account.

Example structure:

```ini
[Unit]
Description=Seafile Server
After=network.target mysqld.service

[Service]
Type=forking
User=seafile
Group=seafile
WorkingDirectory=/opt/seafile/install
ExecStart=/opt/seafile/install/seafile-server-latest/seafile.sh start
ExecStop=/opt/seafile/install/seafile-server-latest/seafile.sh stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Save as:

```text
/etc/systemd/system/seafile.service
```

Then:

```bash
systemctl daemon-reload
systemctl enable seafile
systemctl start seafile
systemctl status seafile
```

> **Important:** The `User=seafile` example is only an example. Use the actual service account/UID from the original deployment.

Seahub should also be configured according to the actual deployment architecture rather than blindly copying a generic unit.

---

# 29. Security After Recovery

The server previously experienced a ransomware incident.

After Seafile is restored, review:

```text
- Local Linux users
- sudo permissions
- SSH keys
- Cron jobs
- Systemd services
- Unexpected startup scripts
- Nginx/Apache configuration
- MySQL users
- Firewall rules
- Recently modified files
- Backup integrity
```

Check recent cron jobs:

```bash
crontab -l
```

For all users:

```bash
for u in $(cut -d: -f1 /etc/passwd); do
    crontab -u "$u" -l 2>/dev/null
done
```

Check enabled services:

```bash
systemctl list-unit-files --state=enabled
```

Check recently modified files in the installation:

```bash
find /opt/seafile/install -type f -mtime -7 -ls | head -100
```

---

# 30. Credential Security

The Seafile configuration contains:

- MySQL password
- Django `SECRET_KEY`

Do not share these credentials in tickets, chat, documentation, or scripts unnecessarily.

If credentials have been exposed, plan to rotate:

1. Seafile MySQL password
2. Corresponding Seafile configuration
3. Django `SECRET_KEY` where appropriate and after understanding its impact
4. Any other credentials exposed during the incident

Do not rotate credentials blindly while the service is being recovered; coordinate the change so the configuration and database account remain synchronized.

---

# 31. Upgrade Planning

Seafile `6.2.2` is an old release.

After the service is stable, plan an upgrade to a supported Seafile release.

Before upgrading:

```text
1. Full backup of seafile-data
2. Full backup of all Seafile databases
3. Backup configuration
4. Verify backup integrity
5. Verify restore procedure
6. Review supported upgrade path
7. Test on a separate system if possible
8. Schedule maintenance window
9. Perform upgrade
10. Validate users, libraries, uploads and downloads
```

Do not jump directly from 6.2.2 to a current release without checking the supported upgrade path.

---

# 32. Complete Diagnostic Bundle

Use this command to collect basic troubleshooting information:

```bash
echo "===== OS ====="
cat /etc/os-release

echo "===== HOSTNAME ====="
hostname

echo "===== IP ====="
ip addr

echo "===== PROCESSES ====="
ps -ef | grep -iE "seafile|seahub|gunicorn" | grep -v grep

echo "===== PORTS ====="
ss -lntp

echo "===== MYSQL ====="
systemctl is-active mysqld

echo "===== SEAFILE DIRECTORY ====="
ls -ld /opt/seafile/install

echo "===== CONFIGURATION ====="
ls -lah /opt/seafile/install/conf/

echo "===== LOGS ====="
ls -lah /opt/seafile/install/logs/

echo "===== PIDS ====="
ls -lah /opt/seafile/install/pids/

echo "===== UID 500 ====="
getent passwd 500

echo "===== SEAFILE USERS ====="
getent passwd | grep -iE "seafile|sea"

echo "===== FIREWALL ====="
firewall-cmd --list-all 2>/dev/null
```

---

# 33. Final Verification Checklist

After recovery:

```text
[ ] MySQL is running
[ ] Seafile process is running
[ ] Seahub/Gunicorn is running
[ ] Port 8000 is listening
[ ] curl to 127.0.0.1:8000 works
[ ] curl to 192.168.42.14:8000 works
[ ] Browser GUI opens
[ ] Login works
[ ] Existing users are visible
[ ] Existing libraries are visible
[ ] Existing files are visible
[ ] File download works
[ ] File upload works
[ ] WebDAV works if required
[ ] No critical errors in seafile.log
[ ] No critical errors in seahub.log
[ ] Firewall permits required traffic
[ ] Automatic startup is configured
[ ] Backups are verified
```

---

# 34. Quick Recovery Flow

```text
Check OS
   |
   v
Locate Seafile installation
   |
   v
Verify seafile-data / ccnet / seahub-data
   |
   v
Verify configuration
   |
   v
Verify MySQL
   |
   v
Verify Seafile MySQL databases
   |
   v
Verify Linux service account / UID
   |
   v
Verify permissions
   |
   v
Start Seafile
   |
   v
Start Seahub on 8000
   |
   v
Check processes
   |
   v
Check port 8000
   |
   v
curl localhost
   |
   v
curl 192.168.42.14
   |
   v
Open Web GUI
   |
   v
Check firewall / reverse proxy
   |
   v
Configure automatic startup
   |
   v
Plan supported upgrade
```

---

## Recovery Principle

Do not reinstall Seafile merely because:

```bash
systemctl status seafile
```

returns:

```text
Unit seafile.service could not be found.
```

The Seafile application can exist without a systemd unit.

For this server, the existing installation was found at:

```text
/opt/seafile/install/seafile-server-6.2.2/
```

with existing:

```text
/opt/seafile/install/seafile-data
/opt/seafile/install/ccnet
/opt/seafile/install/seahub-data
/opt/seafile/install/conf
```

The original service URL is:

```text
http://192.168.42.14:8000
```

The safest recovery approach is therefore:

```text
Existing installation
        ↓
Existing configuration
        ↓
Existing database
        ↓
Existing data
        ↓
Correct permissions/user
        ↓
Manual startup
        ↓
Web GUI verification
        ↓
Automatic startup
        ↓
Security review
        ↓
Supported upgrade
```
