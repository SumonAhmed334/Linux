# Let's Encrypt Renewal Runbook — Zimbra
### webmail.fiberathome.net · Zimbra 10.1.6 FOSS · Ubuntu 22.04.5
**Method:** HTTP-01 standalone, with a bounded firewall window
**Run as:** root
**Duration:** ~10 minutes, including one Zimbra restart

---

## Why a firewall window is needed

The firewall applies a GeoIP allowlist of **Bangladesh only** to ports 80 and 443. Let's Encrypt validates from servers in the **US and Europe**, so an HTTP-01 challenge is dropped by your own firewall before it arrives.

`manage-netsets.sh le-open` opens **only port 80**, worldwide, for a bounded period, and closes it automatically. Every other rule stays enforced.

> **Do not use `reset-policy` or a manual `iptables -F` for this.** That leaves the entire host unfiltered for the duration — the whole ruleset, not one port. `le-open` exists precisely to avoid that.

---

## Certificate facts

| | |
|---|---|
| Domain | `webmail.fiberathome.net` (single host, **not** a wildcard) |
| Lifetime | 90 days |
| Renewal window | certbot acts within 30 days of expiry |
| Cert path | `/etc/letsencrypt/live/webmail.fiberathome.net/` |
| Deployed to | `/opt/zimbra/ssl/zimbra/commercial/` |
| Backups | `/opt/zimbra/ssl/zimbra.bak-<timestamp>` |

Anything else under `fiberathome.net` that relied on the old Sectigo wildcard is **not** covered by this certificate.

---

## Phase 0 — Pre-flight

```bash
# What is live now, and how long is left
echo | openssl s_client -connect localhost:443 2>/dev/null \
  | openssl x509 -noout -dates -subject

# Snapshot the ruleset and the certificate directory
manage-netsets.sh save
cp -a /opt/zimbra/ssl/zimbra /opt/zimbra/ssl/zimbra.bak-$(date +%F-%H%M)

# Nothing should already be open
manage-netsets.sh le-status

# Baseline: expect 19
su - zimbra -c 'zmcontrol status' | grep -c Running
```

---

## Phase 1 — Open the window

```bash
manage-netsets.sh le-open 15
manage-netsets.sh le-status          # confirm OPEN
```

**Open a second terminal** and leave this running for the whole procedure:

```bash
tail -f /var/log/syslog | grep -E 'NETSET-DROP|LE-WINDOW'
```

The window auto-closes after 15 minutes even if your SSH session drops. That is a backstop, not the normal path — you close it manually in Phase 2.

---

## Phase 2 — Obtain the certificate

Zimbra's proxy holds ports 80 and 443, so it must be stopped for `--standalone`.

```bash
su - zimbra -c 'zmproxyctl stop'

certbot certonly -d webmail.fiberathome.net --standalone \
  --agree-tos --register-unsafely-without-email

su - zimbra -c 'zmproxyctl start'
```

> Webmail and IMAP/POP are offline while the proxy is down — roughly 30 seconds.

**Close the window immediately:**

```bash
manage-netsets.sh le-close
manage-netsets.sh le-status          # must say closed
```

---

## Phase 3 — Apply the certificate

### 3.1 Determine which ISRG root you need

This is the step that silently goes wrong. The root must match the certificate's key type.

```bash
openssl x509 -noout -text -in /etc/letsencrypt/live/webmail.fiberathome.net/cert.pem \
  | grep 'Public Key Algorithm'
```

| Output | Root | URL |
|---|---|---|
| `rsaEncryption` | ISRG Root **X1** | `https://letsencrypt.org/certs/isrgrootx1.pem` |
| `id-ecPublicKey` | ISRG Root **X2** | `https://letsencrypt.org/certs/isrg-root-x2.pem` |

Certbot issues RSA by default, so **X1 is the usual answer** unless you passed `--key-type ecdsa`.

### 3.2 Build the three files

`zmcertmgr verifycrt` walks the chain to a self-signed root. Let's Encrypt's `chain.pem` stops at the intermediate, so the root must be appended or verification fails.

```bash
LE=/etc/letsencrypt/live/webmail.fiberathome.net
COMM=/opt/zimbra/ssl/zimbra/commercial

# Fetch the root matching 3.1 — swap the URL if ECDSA
wget -qO /tmp/isrg-root.pem https://letsencrypt.org/certs/isrgrootx1.pem

install -o zimbra -g zimbra -m 640 "$LE/privkey.pem" "$COMM/commercial.key"
install -o zimbra -g zimbra -m 640 "$LE/cert.pem"    "$COMM/commercial.crt"
cat "$LE/chain.pem" /tmp/isrg-root.pem > "$COMM/commercial_ca.crt"
chown zimbra:zimbra "$COMM/commercial_ca.crt"
chmod 640 "$COMM/commercial_ca.crt"
```

### 3.3 Verify before deploying

```bash
# Two identical hashes = key matches cert
openssl x509 -noout -modulus -in "$COMM/commercial.crt" | openssl md5
openssl rsa  -noout -modulus -in "$COMM/commercial.key" | openssl md5

# Chain must validate
su - zimbra -c "/opt/zimbra/bin/zmcertmgr verifycrt comm \
  $COMM/commercial.key $COMM/commercial.crt $COMM/commercial_ca.crt"
```

> **Stop here if `verifycrt` fails.** Nothing has been deployed yet, so the running service is untouched. The usual cause is the wrong ISRG root — go back to 3.1.

### 3.4 Deploy

```bash
su - zimbra -c "/opt/zimbra/bin/zmcertmgr deploycrt comm \
  $COMM/commercial.crt $COMM/commercial_ca.crt"

su - zimbra -c 'zmcontrol restart'
```

---

## Phase 4 — Check status

### 4.1 Services

```bash
su - zimbra -c 'zmcontrol status'
```

Amavis has failed to start after a restart on this host before. If anything reads Stopped:

```bash
su - zimbra -c '/opt/zimbra/bin/zmamavisdctl start'
su - zimbra -c '/opt/zimbra/bin/zmantivirusctl start'
su - zimbra -c '/opt/zimbra/bin/zmantispamctl start'
su - zimbra -c '/opt/zimbra/bin/zmmtactl start'
su - zimbra -c 'zmcontrol status'
```

If amavis still refuses, check the two things that broke it on 29 Aug:

```bash
ls -la /opt/zimbra/conf/amavisd.conf                    # must be root:root
grep inet_socket_bind /opt/zimbra/conf/amavisd.conf     # must be 127.0.0.1
```

### 4.2 Certificate on every service port

Zimbra deploys to nginx, mailboxd and Postfix — check all four.

```bash
for P in 443 993 995 465; do
  echo "=== $P ==="
  echo | openssl s_client -connect webmail.fiberathome.net:$P \
    -servername webmail.fiberathome.net 2>/dev/null \
    | openssl x509 -noout -dates -issuer
done
```

Issuer should read Let's Encrypt, with a ~90 day window.

### 4.3 Chain completeness

```bash
echo | openssl s_client -connect webmail.fiberathome.net:443 \
  -servername webmail.fiberathome.net 2>/dev/null | grep 'Verify return'
```

`Verify return code: 0 (ok)` is required. Anything else means desktop mail clients will warn even if browsers do not.

### 4.4 Mail flow

```bash
mailq | grep -c '^[A-F0-9]'
tail -20 /var/log/zimbra.log | grep -E 'status=sent|auth_zimbra'
```

---

## Phase 5 — Firewall back to normal

```bash
manage-netsets.sh reload
manage-netsets.sh verify
manage-netsets.sh le-status

# No stray window rule left behind
iptables-legacy -S INPUT | grep -c LE-WINDOW      # expect 0
```

### Lock down the certificate tree

`certbot` may reset ownership on renewal. These keys must **not** be reachable by the `zimbra` account — that is the account a Zimbra RCE lands in, and the ownership pattern the 29 Aug ransomware exploited.

```bash
chown -R root:root /etc/letsencrypt
chmod 700 /etc/letsencrypt/archive /etc/letsencrypt/live
chmod 600 /etc/letsencrypt/archive/*/privkey*.pem
ls -la /etc/letsencrypt/live/webmail.fiberathome.net/
```

Zimbra does not need access there — `deploycrt` copies what it needs into `/opt/zimbra/ssl/zimbra/commercial/`.

---

## Rollback

The previous certificate is backed up in Phase 0 and remains valid.

```bash
ls -dt /opt/zimbra/ssl/zimbra.bak-* | head -3

BAK=/opt/zimbra/ssl/zimbra.bak-<timestamp>
cp -a "$BAK"/* /opt/zimbra/ssl/zimbra/
chown -R zimbra:zimbra /opt/zimbra/ssl/zimbra

su - zimbra -c "/opt/zimbra/bin/zmcertmgr deploycrt comm \
  /opt/zimbra/ssl/zimbra/commercial/commercial.crt \
  /opt/zimbra/ssl/zimbra/commercial/commercial_ca.crt"
su - zimbra -c 'zmcontrol restart'
```

---

## Quick reference

```
Phase 0   manage-netsets.sh save
          cp -a /opt/zimbra/ssl/zimbra /opt/zimbra/ssl/zimbra.bak-$(date +%F-%H%M)

Phase 1   manage-netsets.sh le-open 15
          (second terminal) tail -f /var/log/syslog | grep -E 'NETSET-DROP|LE-WINDOW'

Phase 2   su - zimbra -c 'zmproxyctl stop'
          certbot certonly -d webmail.fiberathome.net --standalone \
            --agree-tos --register-unsafely-without-email
          su - zimbra -c 'zmproxyctl start'
          manage-netsets.sh le-close

Phase 3   openssl x509 -noout -text -in $LE/cert.pem | grep 'Public Key Algorithm'
          wget -qO /tmp/isrg-root.pem <X1 or X2 URL>
          install key + cert; cat chain.pem + root > commercial_ca.crt
          zmcertmgr verifycrt comm ...        <-- gate, stop on failure
          zmcertmgr deploycrt comm ...
          zmcontrol restart

Phase 4   zmcontrol status
          check 443 / 993 / 995 / 465
          Verify return code: 0

Phase 5   manage-netsets.sh reload && manage-netsets.sh verify
          chown -R root:root /etc/letsencrypt
```

---

## Failure points

| Symptom | Cause | Fix |
|---|---|---|
| certbot times out on challenge | LE window not open, or already closed | `manage-netsets.sh le-status`, reopen |
| `Address already in use` on 80 | proxy still running | `su - zimbra -c 'zmproxyctl stop'` |
| `verifycrt` reports invalid chain | wrong ISRG root appended | Re-check Phase 3.1, X1 for RSA |
| Modulus hashes differ | key and cert are from different issuances | Re-copy both from the same `live/` dir |
| Services Stopped after restart | amavis start ordering | Phase 4.1 recovery sequence |
| Browsers fine, mail clients warn | incomplete chain | Root missing from `commercial_ca.crt` |
| `too many certificates already issued` | rate limit, 5 duplicates/week | Wait, or use `--dry-run` for testing |

---

## Renewal schedule

90 days from issuance. Set the expiry alarm so a missed renewal does not surprise you:

```bash
cat > /usr/local/sbin/check-cert-expiry.sh <<'EOF'
#!/bin/bash
END=$(echo | openssl s_client -connect localhost:443 2>/dev/null \
      | openssl x509 -noout -enddate | cut -d= -f2)
DAYS=$(( ( $(date -d "$END" +%s) - $(date +%s) ) / 86400 ))
if [[ "$DAYS" -lt 21 ]]; then
    echo "Certificate on $(hostname -f) expires in $DAYS days ($END).
Run the Let's Encrypt renewal runbook." \
      | mail -s "WARNING: SSL expires in $DAYS days" rkarim@fiberathome.net
fi
EOF
chmod +x /usr/local/sbin/check-cert-expiry.sh
echo '0 7 * * * root /usr/local/sbin/check-cert-expiry.sh' > /etc/cron.d/cert-expiry
```

21 days against a 30-day renewal window leaves three weeks to act.

---

## Note on automating this

This runbook is manual because HTTP-01 needs the firewall window and a proxy restart. **DNS-01 validation avoids both** — validation happens over DNS, nothing connects to the server, port 80 stays closed permanently, and it can issue a wildcard.

If you move to DNS-01 via the PowerDNS API, Phases 1, 2 and 5 disappear entirely and renewal becomes a cron job. Worth doing once you have run this cycle manually a couple of times.