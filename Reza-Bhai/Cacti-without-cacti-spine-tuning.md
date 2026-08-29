# Cacti Performance Tuning Guide (cmd.php / No-Spine) — GP-CACTI

## Environment

- Host: GP-CACTI (KVM VM inside Proxmox)
- vCPU: 20 cores
- RAM: 20 GB
- Disk: SSD
- OS: Ubuntu 22.04
- Cacti: 1.2.23
- MariaDB: 10.6.22
- PHP: 8.1.2
- Poller: **cmd.php (spine installed at `/usr/local/spine/bin/spine` but NOT in use — `poller_type=1`)**
- Device count: ~2000+ SNMP-polled devices
- Timezone: Asia/Dhaka (UTC+6)

This guide tunes the **cmd.php poller path only**. Spine remains installed as a future option but is intentionally left disabled per current operational decision. Do not re-enable `poller_type=2` without a dedicated maintenance window — see Gotchas.

---

## Table of Contents

### Poller Tuning
- [1. Poller Concurrency (concurrent_processes / max_threads)](#1-poller-concurrency)
- [2. Availability Method & Timeouts](#2-availability-method--timeouts)
- [3. SNMP Bulk Get Size](#3-snmp-bulk-get-size)

### Write-Back Pipeline
- [4. RRDCached](#4-rrdcached)
- [5. Boost Tuning](#5-boost-tuning)

### PHP & Logging
- [6. PHP CLI OPcache](#6-php-cli-opcache)
- [7. Log Verbosity](#7-log-verbosity)

### Database Layer
- [8. MariaDB Configuration (already applied)](#8-mariadb-configuration-already-applied)

### Scheduling & Resilience
- [9. Cron Overlap Protection](#9-cron-overlap-protection)
- [10. Systemd Resilience for MariaDB](#10-systemd-resilience-for-mariadb)
- [11. Memory Pressure Monitoring & Cache Management](#11-memory-pressure-monitoring--cache-management)

### Verification
- [12. Testing Methodology](#12-testing-methodology)
- [13. Gotchas / Incident Log](#13-gotchas--incident-log)

---

## 1. Poller Concurrency

cmd.php forks one PHP process per batch of hosts (not threaded like spine), so per-process overhead is higher. Ramp changes incrementally — do not jump straight to a high value.

**Check current values:**
```bash
mysql -ucacti -p -e "SELECT name,value FROM cacti.settings WHERE name IN ('concurrent_processes','max_threads','poller_type');"
```

**Baseline for this environment:** `concurrent_processes=4`, `max_threads=4`, `poller_type=1`

**Ramp step 1 (test for one full cycle before going further):**
```bash
mysql -ucacti -p -e "UPDATE cacti.settings SET value=6 WHERE name='concurrent_processes';"
```

**Verify after one cycle — watch actual completion time, not just absence of timeout messages:**
```bash
grep -i "maximum runtime\|total time" /var/www/html/cacti/log/cacti.log | tail -10
```

**Ramp step 2 (only if step 1 is stable and comfortably under the runtime ceiling):**
```bash
mysql -ucacti -p -e "UPDATE cacti.settings SET value=8 WHERE name='concurrent_processes';"
```

Do not touch `max_threads` for cmd.php — that setting is spine-specific and has no effect on the cmd.php code path.

**After any concurrency change, always force a cache rebuild** — Cacti does not auto-migrate existing host-to-process cache assignments:
```bash
php /var/www/html/cacti/poller.php --force
```

---

## 2. Availability Method & Timeouts

**Check current setting:**
```bash
mysql -ucacti -p -e "SELECT name,value FROM cacti.settings WHERE name IN ('availability_method','ping_timeout','ping_retries');"
```

`availability_method=2` (SNMP uptime check) adds an extra SNMP round-trip per host, per cycle, before polling even starts. At 2000+ hosts this is real overhead if most hosts are reliably reachable.

**Switch to ping-only availability check:**
```bash
mysql -ucacti -p -e "UPDATE cacti.settings SET value=0 WHERE name='availability_method';"
```

**Reduce ping timeout** (400ms default is generous for hub-routed WireGuard infrastructure with low internal latency):
```bash
mysql -ucacti -p -e "UPDATE cacti.settings SET value=200 WHERE name='ping_timeout';"
```

**Caution:** if any devices sit behind genuinely high-latency links (satellite, congested last-mile), lowering the global timeout can cause false-down flags for those specific hosts. Check per-device override if needed rather than raising the global value back up for everyone:
```bash
mysql -ucacti -p -e "SELECT id,description,availability_method FROM cacti.host WHERE availability_method != (SELECT value FROM cacti.settings WHERE name='availability_method');"
```

---

## 3. SNMP Bulk Get Size

Fewer SNMP round-trips per host = faster cycles, especially for high-interface-count devices.

**Check current value:**
```bash
mysql -ucacti -p -e "SELECT name,value FROM cacti.settings WHERE name='max_get_size';"
```

**Raise it** (safe to increase given low-latency internal network path):
```bash
mysql -ucacti -p -e "UPDATE cacti.settings SET value=40 WHERE name='max_get_size';"
```

If any SNMP agents on older/embedded devices reject large bulk requests, watch for new SNMP errors after this change:
```bash
grep -i "snmp.*error\|too big\|bulk" /var/www/html/cacti/log/cacti.log | tail -20
```

---

## 4. RRDCached

Batches RRD writes instead of issuing an individual file write (with fsync) per data source per cycle. This is the single biggest lever available without spine, because it reduces disk I/O load at the write-back stage regardless of how fast collection itself runs.

**Install:**
```bash
apt update
apt install rrdcached -y
```

**Create dedicated data/socket directories:**
```bash
mkdir -p /var/lib/rrdcached/db /var/lib/rrdcached/journal
chown -R www-data:www-data /var/lib/rrdcached
```

**Systemd override for tuned flush intervals:**
```bash
mkdir -p /etc/systemd/system/rrdcached.service.d
cat > /etc/systemd/system/rrdcached.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/rrdcached -s www-data -m 0660 \
  -l unix:/var/run/rrdcached.sock \
  -w 300 -z 300 -f 3600 \
  -j /var/lib/rrdcached/journal \
  -F -b /var/lib/rrdcached/db -B
EOF
```

Flag meanings:
- `-w 300` — write cached data to disk every 300s (matches poll interval)
- `-z 300` — spread writes randomly over up to 300s to avoid I/O burst at exact poll boundary
- `-f 3600` — flush stale/inactive files every hour
- `-j` — journal directory for crash recovery (RRDCached replays this on restart, so writes aren't lost even if it's killed mid-batch)
- `-b` — base directory RRD paths are relative to
- `-B` — restrict writes to files under the base directory (safety)

**Enable and start:**
```bash
systemctl daemon-reload
systemctl enable --now rrdcached
systemctl status rrdcached
```

**Point Cacti at it:**
```bash
mysql -ucacti -p -e "UPDATE cacti.settings SET value='unix:/var/run/rrdcached.sock' WHERE name='path_rrdtool';" 2>/dev/null
```
If that setting name doesn't exist in this Cacti build, set it via Console → **Settings → Path Variables → RRDCached Server Path** → `unix:/var/run/rrdcached.sock`, then save.

**Verify it's receiving writes after one poll cycle:**
```bash
rrdtool flushcached --daemon unix:/var/run/rrdcached.sock /var/www/html/cacti/rra/<any_rrd_file>.rrd
```

---

## 5. Boost Tuning

**Check current settings:**
```bash
mysql -ucacti -p -e "SELECT name,value FROM cacti.settings WHERE name LIKE 'boost_%';"
```

**Confirm Boost is actually draining, not backing up** — sample twice a minute apart:
```bash
mysql -ucacti -p -e "SELECT COUNT(*) FROM cacti.poller_output;"
sleep 60
mysql -ucacti -p -e "SELECT COUNT(*) FROM cacti.poller_output;"
```
A static or climbing count across samples (not just a normal mid-cycle snapshot) indicates Boost isn't keeping pace — check the Boost cron job frequency:
```bash
crontab -l | grep -i boost
cat /etc/cron.d/cacti | grep -i boost
```

For 2000+ devices, Boost's flush cron should run every 1–2 minutes, not the default 5, so it never queues a full cycle's worth of output before draining.

---

## 6. PHP CLI OPcache

cmd.php forks a fresh PHP process per batch — without CLI opcache, every fork re-parses and re-compiles the same PHP source on every single invocation, every 5 minutes, across every fork.

**Check current state:**
```bash
php -i | grep -i opcache.enable_cli
```

**Enable it:**
```bash
cat > /etc/php/8.1/cli/conf.d/10-opcache.ini << 'EOF'
opcache.enable_cli=1
opcache.memory_consumption=256
opcache.max_accelerated_files=10000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
EOF
```

`validate_timestamps=1` + `revalidate_freq=60` means opcache still picks up Cacti code changes/updates within 60 seconds — safe default, not a risk of serving stale code indefinitely.

**Verify:**
```bash
php -i | grep -i opcache.enable_cli
```

---

## 7. Log Verbosity

**Check current level:**
```bash
mysql -ucacti -p -e "SELECT name,value FROM cacti.settings WHERE name='log_verbosity';"
```

Debug-level logging (`5`+) adds meaningful per-poll I/O across thousands of hosts. Set to normal operational level unless actively troubleshooting:
```bash
mysql -ucacti -p -e "UPDATE cacti.settings SET value=3 WHERE name='log_verbosity';"
```

Raise it temporarily to a higher value only during active incident investigation, then set it back to `3` afterward — don't leave verbose logging on permanently.

---

## 8. MariaDB Configuration (already applied)

These fixes were already deployed following a table-corruption incident and are documented here for reference only — **do not revert any of the following**, they are independent of poller/spine tuning:

```ini
# /etc/mysql/mariadb.conf.d/50-server.cnf
innodb_doublewrite=ON
innodb_buffer_pool_size=8000M
join_buffer_size=4M
tmp_table_size=128M
max_heap_table_size=128M
```

Tables converted from MyISAM (crash-prone, no recovery log) to InnoDB:
```sql
ALTER TABLE cacti.graph_templates_item ENGINE=InnoDB;
ALTER TABLE cacti.host_snmp_cache ENGINE=InnoDB;
ALTER TABLE cacti.data_input_data ENGINE=InnoDB;
```

Note: `cacti.poller_output` is intentionally MEMORY engine — this is correct Boost architecture, not a table to convert. Losing its contents on restart is an accepted tradeoff (at most one poll cycle of pending, not-yet-boosted data).

Transparent Huge Pages disabled (known InnoDB latency/memory-spike cause):
```bash
cat /sys/kernel/mm/transparent_hugepage/enabled
# should show [never]
```

---

## 9. Cron Overlap Protection

**Current cron entry** (`/etc/cron.d/cacti`):
```bash
*/5 * * * * www-data /usr/bin/flock -n /var/lock/cacti-poller.lock -c "php /var/www/html/cacti/poller.php" > /dev/null 2>&1
```

`flock -n` (non-blocking) guarantees a new poll cycle skips cleanly if a previous one is still running, instead of stacking a second process on top — this is what prevents memory pile-up from overlapping runs.

**Verify the lock is healthy and not stuck:**
```bash
lsattr /var/lock/cacti-poller.lock
# should show no 'i' (immutable) flag
```
If the immutable attribute is ever set on this file (blocks access for all users including root):
```bash
chattr -i /var/lock/cacti-poller.lock
```

**Confirm no skipped cycles are silently accumulating:**
```bash
grep -i cron /var/log/syslog | grep -i cacti | tail -20
```
Each `*/5` mark should show exactly one CRON invocation of the flock line — repeated entries at the same minute, or gaps longer than 5 minutes, indicate a problem worth investigating.

---

## 10. Systemd Resilience for MariaDB

```bash
mkdir -p /etc/systemd/system/mariadb.service.d
cat > /etc/systemd/system/mariadb.service.d/override.conf << 'EOF'
[Service]
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=300
StartLimitBurst=3
OOMScoreAdjust=-800
MemoryHigh=10G
MemoryMax=12G
EOF
systemctl daemon-reload
systemctl restart mariadb
```

**Verify:**
```bash
systemctl show mariadb -p Restart -p RestartUSec -p OOMScoreAdjust -p MemoryHigh -p MemoryMax
```

`OOMScoreAdjust=-800` reduces the odds the kernel picks mariadb as an OOM-kill target first. `MemoryHigh`/`MemoryMax` give a soft-then-hard ceiling so mariadb throttles before being force-killed.

---

## 11. Memory Pressure Monitoring & Cache Management

**Important context first:** `free -h`'s "used" percentage counts reclaimable page cache (`buff/cache`) as used memory, which routinely makes a healthy box look like it's near a ceiling it isn't actually near. The kernel already reclaims this cache automatically, before it OOM-kills anything — manually forcing `echo 3 > /proc/sys/vm/drop_caches` on a schedule doesn't free memory that wasn't already reclaimable on demand, it just discards useful cache and causes avoidable disk I/O on the next read. It also does **not** touch the anon-rss actually held by running processes (mariadb, php-cli, spine) — which is what caused the real OOM kills on this box previously. Don't run this reactively as a blind fix; use it only as an instrumented safety net while you confirm what's actually happening.

**Check real available memory, not raw usage:**
```bash
awk '/MemAvailable/ {print $2/1024" MB available"}' /proc/meminfo
```
`MemAvailable` already accounts for reclaimable cache — this is the number that tells you whether you have a real problem, not `%used` from `free`.

**Instrumented safety-net script** — checks real pressure via `MemAvailable`, logs every trigger with before/after state, drops only page cache (`echo 1`, not `echo 3` — no reason to also evict dentries/inodes), and alerts via Telegram if configured:

```bash
mkdir -p /etc/cacti-scripts
cat > /usr/local/bin/mem-pressure-check.sh << 'EOF'
#!/bin/bash
source /etc/cacti-scripts/.env 2>/dev/null

THRESHOLD_PCT=90
LOGFILE=/var/log/mem-pressure.log
HOST=$(hostname)

TOTAL_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
AVAIL_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
USED_PCT=$(( 100 - (AVAIL_KB * 100 / TOTAL_KB) ))

if [ "$USED_PCT" -ge "$THRESHOLD_PCT" ]; then
    echo "$(date): Real memory pressure detected (${USED_PCT}% based on MemAvailable) - dropping page cache" >> "$LOGFILE"
    free -h >> "$LOGFILE"

    sync
    echo 1 > /proc/sys/vm/drop_caches

    sleep 2
    NEW_AVAIL_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    NEW_USED_PCT=$(( 100 - (NEW_AVAIL_KB * 100 / TOTAL_KB) ))
    echo "$(date): Post-drop usage: ${NEW_USED_PCT}%" >> "$LOGFILE"

    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
          -d chat_id="${TELEGRAM_CHAT_ID}" \
          -d text="⚠️ MEMORY PRESSURE — ${HOST}
Real usage (MemAvailable-based): ${USED_PCT}%
Cache dropped. Post-drop: ${NEW_USED_PCT}%
If this recurs frequently, it's a real leak/sizing issue, not a caching one — investigate, don't just keep dropping caches." \
          > /dev/null
    fi
fi
EOF
chmod +x /usr/local/bin/mem-pressure-check.sh
```

Requires the shared credentials file from the migration/automation runbook (`/etc/cacti-scripts/.env`, chmod 600) for the Telegram alert — the script runs fine without it, just skips the alert step silently if the file or token is absent.

**Schedule via cron:**
```bash
cat >> /etc/cron.d/cacti-automation << 'EOF'
*/5 * * * *   root     /usr/local/bin/mem-pressure-check.sh
EOF
```

**What to actually do with this data — this is the point of the script, not the drop_caches line itself:**
```bash
tail -50 /var/log/mem-pressure.log
```
- **Rarely/never fires** → confirms the 90% you were seeing elsewhere was mostly reclaimable cache, not a real problem. No further action needed.
- **Fires repeatedly, post-drop usage barely improves** → the memory being consumed is real process usage (poller forks, mariadb buffer pool), not cache. In that case the fix is capacity/sizing — revisit `concurrent_processes` (Section 1), MariaDB buffer pool sizing (Section 8), or actual RAM headroom on the VM — not repeated cache drops. Don't let this script run indefinitely as a silent workaround if the log shows this pattern; treat it as an open incident and size up instead.

---

## 12. Testing Methodology

Change **one setting at a time**. After each change:

```bash
# wait for at least one full poll cycle
sleep 320

# check actual completion time, not just absence of the timeout message
grep -i "maximum runtime\|total time" /var/www/html/cacti/log/cacti.log | tail -10

# confirm RRDs are updating fleet-wide
find /var/www/html/cacti/rra -name "*.rrd" -mmin -10 | wc -l

# confirm no new SNMP or DB errors introduced
tail -50 /var/www/html/cacti/log/cacti.log | grep -i -E "error|fail|fatal"
```

Target: comfortable completion well under 298s (aim for under half — 120–150s), not just barely under.

---

## 13. Gotchas / Incident Log

- **`poller_type` UPDATE takes effect immediately but host-to-process cache assignments do not auto-migrate.** Always follow any `concurrent_processes`/`max_threads`/`process_leveling` change with `php poller.php --force` to rebuild the cache. A missed rebuild caused one host's RRD to go stale (NaN) after a concurrency change during initial tuning.

- **cmd.php process count in `ps aux` should roughly match `concurrent_processes`.** If it doesn't, `process_leveling=on` may be redistributing hosts by polling weight rather than a flat split — this is expected behavior, not a bug, but worth knowing before assuming a setting "didn't take."

- **Spine is installed (`/usr/local/spine/bin/spine`, version 1.2.23) and fully configured (`path_spine` set correctly) but intentionally NOT in use** (`poller_type=1`). Do not switch this back to `2` outside a planned maintenance window — a same-session switch during an active incident previously produced ambiguous log state (spine-tagged log lines appearing while settings showed cmd.php values) that took time to untangle under time pressure.

- **A separate, unrelated SNMP ifIndex mismatch exists on host_id 3357** (`TenGigE0/0/0/17`) — Cacti's cached `snmp_index` (8, mapped to a stale `Optics0/0/0/5` label) does not match the device's live ifIndex (54). This causes that one interface's RRD to go NaN despite the poller itself running fine. Fix via Console → Devices → host 3357 → **Reload Query** on the SNMP Interface Data Query, or:
  ```bash
  php /var/www/html/cacti/cli/recache.php --host-id=3357
  ```
  Not urgent — isolated to this device, does not affect fleet-wide polling health.

- **Original root cause of the Tuesday OOM/table-crash incident was MariaDB configuration** (`innodb_doublewrite=OFF` + oversized per-connection buffers `join_buffer_size=256M`/`tmp_table_size=786M`/`max_heap_table_size=2400M` + `innodb_buffer_pool_size=12000M` on a 19–20GB host), **not poller concurrency.** Poller/spine tuning was a reasonable line of investigation given the memory-pressure graph but turned out to be unrelated — keep this in mind before re-chasing poller settings if memory pressure recurs; check MariaDB config drift first.

- **`echo 3 > /proc/sys/vm/drop_caches` on a naive `free -h`-based threshold is not a real fix for memory pressure** — `%used` from `free` counts reclaimable page cache as "used," which the kernel already reclaims automatically before OOM-killing anything. The Section 11 script checks `MemAvailable` instead (the kernel's own reclaimable-aware estimate) and logs before/after state specifically so a recurring, non-improving pattern gets caught and treated as a real capacity issue — not silently papered over by a cron job dropping cache every 5 minutes indefinitely.

- **`debian-sys-maint` access-denied errors appear on every mariadb restart** (`Access denied for user 'root'@'localhost'`). This is expected and accepted in this environment — root password reset is not permitted on this production server, and this only affects `debian-start`'s automatic `mysql_upgrade` housekeeping step, not actual database operation. Not a cause for concern; do not spend time chasing it.