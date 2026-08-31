# Seafile 6.2.2 — Status & Troubleshooting

**Server:** FHL-SMB-SEA  
**IP:** 192.168.42.14  
**OS:** CentOS 7  
**Seafile:** 6.2.2  
**Installation:** `/opt/seafile/install/seafile-server-6.2.2`  
**Web GUI:** `http://192.168.42.14:8000`

---

## 1. Go to Seafile Directory

```bash
cd /opt/seafile/install/seafile-server-6.2.2
```

---

## 2. Check Seafile Status

Seafile 6.2.2 does not support `status` directly.

Use:

```bash
ps -ef | grep -iE "seafile|seaf-server" | grep -v grep
```

If there is no output, Seafile is not running.

---

## 3. Check Seahub Status

```bash
ps -ef | grep -iE "seahub|gunicorn" | grep -v grep
```

If there is no output, Seahub/web GUI is not running.

---

## 4. Check Web Port

```bash
ss -lntp | grep ':8000'
```

Expected when Seahub is running:

```text
LISTEN ... :8000 ...
```

---

## 5. Check MySQL

```bash
systemctl is-active mysqld
```

Expected:

```text
active
```

Check MySQL port:

```bash
ss -lntp | grep ':3306'
```

---

## 6. Check Seafile Configuration

```bash
cat /opt/seafile/install/conf/ccnet.conf
```

```bash
cat /opt/seafile/install/conf/seafile.conf
```

```bash
cat /opt/seafile/install/conf/seahub_settings.py
```

Check the configured service URL:

```bash
grep -n "SERVICE_URL" /opt/seafile/install/conf/ccnet.conf
```

Expected:

```text
SERVICE_URL = http://192.168.42.14:8000
```

---

## 7. Check Seafile Data

```bash
ls -ld /opt/seafile/install/ccnet
ls -ld /opt/seafile/install/seafile-data
ls -ld /opt/seafile/install/seahub-data
```

---

## 8. Check Logs

Seafile:

```bash
tail -100 /opt/seafile/install/logs/seafile.log
```

Seahub:

```bash
tail -100 /opt/seafile/install/logs/seahub.log
```

Search for errors:

```bash
grep -iE "error|fatal|failed|exception|traceback|permission|mysql|database" /opt/seafile/install/logs/*.log | tail -100
```

---

# 9. Start Seafile

```bash
cd /opt/seafile/install/seafile-server-6.2.2
./seafile.sh start
```

Check:

```bash
ps -ef | grep -iE "seafile|seaf-server" | grep -v grep
```

---

# 10. Start Seahub

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

# 11. Verify Web GUI

Test locally:

```bash
curl -I http://127.0.0.1:8000
```

Test server IP:

```bash
curl -I http://192.168.42.14:8000
```

Then open:

```text
http://192.168.42.14:8000
```

---

# 12. If Seafile Start Fails

Run:

```bash
./seafile.sh start
```

Immediately check:

```bash
tail -100 /opt/seafile/install/logs/seafile.log
```

Check process:

```bash
ps -ef | grep -iE "seafile|seaf-server" | grep -v grep
```

---

# 13. If Seahub Start Fails

Run:

```bash
./seahub.sh start 8000
```

Immediately check:

```bash
tail -100 /opt/seafile/install/logs/seahub.log
```

Check process:

```bash
ps -ef | grep -iE "seahub|gunicorn" | grep -v grep
```

Check port:

```bash
ss -lntp | grep ':8000'
```

---

# 14. Restart Seafile

```bash
cd /opt/seafile/install/seafile-server-6.2.2
./seafile.sh restart
```

Then:

```bash
./seahub.sh restart 8000
```

Verify:

```bash
ps -ef | grep -iE "seafile|seaf-server" | grep -v grep
```

```bash
ps -ef | grep -iE "seahub|gunicorn" | grep -v grep
```

```bash
ss -lntp | grep ':8000'
```

---

# 15. Stop Seafile

```bash
cd /opt/seafile/install/seafile-server-6.2.2
./seahub.sh stop 8000
./seafile.sh stop
```

Verify:

```bash
ps -ef | grep -iE "seafile|seahub|gunicorn" | grep -v grep
```

---

# 16. Quick Status Check

Use this whenever you need to check whether Seafile is running:

```bash
echo "===== MYSQL ====="
systemctl is-active mysqld

echo
echo "===== SEAFILE ====="
ps -ef | grep -iE "seafile|seaf-server" | grep -v grep || echo "NOT RUNNING"

echo
echo "===== SEAHUB ====="
ps -ef | grep -iE "seahub|gunicorn" | grep -v grep || echo "NOT RUNNING"

echo
echo "===== PORT 8000 ====="
ss -lntp | grep ':8000' || echo "NOT LISTENING"

echo
echo "===== HTTP TEST ====="
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://127.0.0.1:8000
```

---

# 17. Quick Recovery

If the GUI is not working:

```bash
cd /opt/seafile/install/seafile-server-6.2.2
```

```bash
systemctl is-active mysqld
```

```bash
./seafile.sh start
```

```bash
./seahub.sh start 8000
```

```bash
ps -ef | grep -iE "seafile|seahub|gunicorn" | grep -v grep
```

```bash
ss -lntp | grep ':8000'
```

```bash
curl -I http://127.0.0.1:8000
```

Then access:

```text
http://192.168.42.14:8000
```

---

## Important

Do not use:

```bash
./seafile.sh status
./seahub.sh status
```

For this Seafile 6.2.2 installation, use:

```bash
ps -ef | grep -iE "seafile|seaf-server" | grep -v grep
ps -ef | grep -iE "seahub|gunicorn" | grep -v grep
ss -lntp | grep ':8000'
```

These are the actual status checks for this installation.
