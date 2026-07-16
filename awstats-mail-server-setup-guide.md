# AWStats Mail Log Analysis — Setup Guide

**Server:** mail.sumonahmed.xyz (Ubuntu, Postfix + Zimbra)
**Goal:** Analyze Postfix mail logs with AWStats and view reports as static HTML pages.

---

## 1. Install AWStats

```bash
apt update
apt install -y awstats
```

This installs the core AWStats package. Some helper scripts (like `maillogconvert.pl` and `awstats_buildstaticpages.pl`) are included but not placed on `$PATH` by default — this is addressed in Step 3 and Step 7.

---

## 2. Identify the Mail Log

Postfix logs on Debian/Ubuntu are usually at:

```bash
ls -la /var/log/mail.log
```

---

## 3. Locate and Prepare the Log Converter

AWStats' native mail log parser expects a specific structured format. Raw Postfix syslog output is multi-line per message, so it needs to be converted first using `maillogconvert.pl`, which ships with the AWStats package documentation:

```bash
find / -iname "maillogconvert*" 2>/dev/null
```

Typically found at:
```
/usr/share/doc/awstats/examples/maillogconvert.pl
```

Run it to convert the raw log into AWStats-compatible format:

```bash
perl /usr/share/doc/awstats/examples/maillogconvert.pl standard < /var/log/mail.log > /var/log/mail.log.awstats
```

Verify the output looks like clean, single-line records:

```bash
tail -20 /var/log/mail.log.awstats
```

Example line:
```
2026-07-07 09:48:03 admin@mail.sumonahmed.xyz admin@mail.sumonahmed.xyz mail.sumonahmed.xyz 127.0.0.1 SMTP - 1 559
```

---

## 4. Create the AWStats Mail Config

Copy the default config as a starting point:

```bash
cp /etc/awstats/awstats.conf /etc/awstats/awstats.mail.conf
```

Edit `/etc/awstats/awstats.mail.conf`:

```bash
vim /etc/awstats/awstats.mail.conf
```

Set the following values:

```
LogFile="/var/log/mail.log.awstats"
LogType=M
LogFormat="%time2 %email %email_r %host %host_r %method %url %code %bytesd"
DNSLookup=0
SiteDomain="mail.sumonahmed.xyz"
HostAliases="localhost 127.0.0.1 mail.sumonahmed.xyz"
```

### Why this LogFormat string

| Field # | Example value | Token | Meaning |
|---|---|---|---|
| 1–2 | `2026-07-07 09:48:03` | `%time2` | Date + time (yyyy-mm-dd hh:mm:ss) |
| 3 | `admin@mail.sumonahmed.xyz` | `%email` | Sender email |
| 4 | `admin@mail.sumonahmed.xyz` | `%email_r` | Receiver email |
| 5 | `mail.sumonahmed.xyz` | `%host` | Sender host |
| 6 | `127.0.0.1` | `%host_r` | Receiver host |
| 7 | `SMTP` | `%method` | Delivery method |
| 8 | `-` | `%url` | Placeholder field (AWStats requires either `%methodurl` or `%url` present; `%url` matches plain unquoted text, `%methodurl` requires a quoted `"GET /path"`-style value which doesn't fit mail logs) |
| 9 | `1` | `%code` | Status code placeholder |
| 10 | `559` | `%bytesd` | Message size in bytes |

**Key lesson learned:** AWStats' mail tokens are `%email` / `%email_r` (not `%email_sender` / `%email_receiver`), and `%methodurl` requires quoted text — using `%url` instead avoids that mismatch while still satisfying AWStats' mandatory field check.

---

## 5. Symlink AWStats Binaries to PATH

The core scripts aren't on `$PATH` by default. Create convenient symlinks:

```bash
ln -s /usr/lib/cgi-bin/awstats.pl /usr/local/bin/awstats.pl
ln -s /usr/share/awstats/tools/awstats_buildstaticpages.pl /usr/local/bin/awstats_buildstaticpages.pl
```

---

## 6. Build the Initial Statistics Database

```bash
awstats.pl -config=mail -update
```

Expected healthy output:
```
Found 0 corrupted records,
Found 0 old records,
Found 29 new qualified records.
```

If you see corrupted records, re-check the `LogFormat` string against your actual log fields using:
```bash
awstats.pl -config=mail -update -showcorrupted
```
This prints the exact lines that failed to parse.

---

## 7. Generate Static HTML Reports

Create the output directory:
```bash
mkdir -p /var/www/html/awstats-mail
```

Build the static pages:
```bash
awstats_buildstaticpages.pl -config=mail -dir=/var/www/html/awstats-mail -lang=en
```

Copy icon assets so charts/images render correctly:
```bash
cp -r /usr/share/awstats/icon /var/www/html/awstats-mail/
```

---

## 8. Serve the Reports via a Web Server

Check what's already listening on ports 80/443:
```bash
ss -tlnp | grep -E ':80|:443'
```

On a Zimbra server, Zimbra's own nginx proxy typically owns port 443, while port 80 is often free. If nothing is listening on port 80, install Apache to serve it:

```bash
apt install -y apache2
systemctl enable --now apache2
```

Allow the port through the firewall if needed:
```bash
ufw allow 80/tcp
```

Access the report at:
```
http://mail.sumonahmed.xyz/awstats-mail/awstats.mail.html
```

> Note: Since Zimbra's nginx holds port 443, plain Apache on port 80 only serves HTTP — use `http://`, not `https://`, unless you configure a separate SSL vhost.

---

## 9. Restrict Access (Recommended)

The mail report page displays real sender/receiver email addresses. Lock it down before leaving it publicly reachable.

**Option A — Restrict by IP** (edit `/etc/apache2/sites-available/000-default.conf`):
```apache
<Directory /var/www/html/awstats-mail>
    Require ip YOUR.OFFICE.IP.HERE
</Directory>
```

**Option B — Basic Auth:**
```bash
apt install -y apache2-utils
htpasswd -c /etc/apache2/.htpasswd admin
```
```apache
<Directory /var/www/html/awstats-mail>
    AuthType Basic
    AuthName "Restricted"
    AuthUserFile /etc/apache2/.htpasswd
    Require valid-user
</Directory>
```

Reload Apache after changes:
```bash
systemctl reload apache2
```

---

## 10. Automate with Cron

Create a single script that runs the full pipeline (convert → update stats → rebuild static pages):

```bash
cat > /usr/local/bin/awstats-mail-update.sh << 'EOF'
#!/bin/bash
perl /usr/share/doc/awstats/examples/maillogconvert.pl standard < /var/log/mail.log > /var/log/mail.log.awstats
awstats.pl -config=mail -update
awstats_buildstaticpages.pl -config=mail -dir=/var/www/html/awstats-mail -lang=en
EOF
chmod +x /usr/local/bin/awstats-mail-update.sh
```

Schedule it every 30 minutes:
```bash
crontab -e
```
```
*/30 * * * * /usr/local/bin/awstats-mail-update.sh > /var/log/awstats-mail-update.log 2>&1
```

---

## 11. Log Rotation Consideration

If `/var/log/mail.log` is rotated (e.g., daily via `logrotate`), the conversion step must run **before** rotation truncates the file, or data will be lost between cron runs. Check the current rotation schedule:

```bash
cat /etc/logrotate.d/rsyslog 2>/dev/null | grep -A5 mail
```

If rotation happens more frequently than your cron interval, either:
- Increase cron frequency to run before each rotation, or
- Add a `prerotate` hook in the logrotate config that runs the conversion/update script before the log is rotated.

---

## Summary of Final Working Config

```ini
LogFile="/var/log/mail.log.awstats"
LogType=M
LogFormat="%time2 %email %email_r %host %host_r %method %url %code %bytesd"
DNSLookup=0
SiteDomain="mail.sumonahmed.xyz"
HostAliases="localhost 127.0.0.1 mail.sumonahmed.xyz"
```

**Report URL:** `http://mail.sumonahmed.xyz/awstats-mail/awstats.mail.html`
**Update automation:** `/usr/local/bin/awstats-mail-update.sh` via cron every 30 minutes
