# Firewall Access Matrix — webmail.fiberathome.net
### `manage-netsets.sh` v5 · latest running configuration
**Generated:** 02 Sep 2026
**Interface:** `ens4` only (public-facing). OPNsense upstream terminates VLANs and **NATs office traffic to `103.229.83.244`**.

---

## Changes since the previous review

| Change | Effect |
|---|---|
| SMTP relay allow moved to **step 8b**, ahead of the feeds | ✅ Fixes the silent drop — relay hosts can now reach port 25 |
| `192.168.77.28/32` added to `ADMIN_NETS` | 5 admin hosts |
| Three GIS servers added to `SMTP_RELAY_NETS` | `192.168.44.43/.175/.50` |
| `103.229.83.240/29` added to `LAN_NETS` | Office NAT gets mail + webmail |
| `bl_tfx` (ThreatFox) added | 14 feeds |
| `VPN_POOL_ON_WAN=0` | Blanket RFC1918 exemption off — correct |

All five `SMTP_RELAY_NETS` entries are now covered by `MARTIAN_FULL_EXEMPT` — verified.

---

## 1. Port groups

| Group | Ports |
|---|---|
| `MAIL_CLIENT_PORTS` | 993 (IMAPS), 995 (POP3S), 465 (SMTPS), 587 (submission) |
| `WEBMAIL_PORTS` | 80, 443 |
| **"mail + webmail"** | **993, 995, 465, 587, 80, 443** — port 25 NOT included |
| `ADMIN_CONSOLE_PORTS` | 7071, 8443 |
| `SSH_PORTS` | 22, 8022 |
| `SMTP_PORT` | 25 (`SMTP_WORLD_OPEN=0`) |
| `BLOCKED_ALWAYS` | 110, 143 — dropped on every interface |
| `HOST_SELF_PORTS` | 7025, 7026, 7072-7074, 22, 7071, 25 |
| `GEOBLOCK_TCP_PORTS` | 587, 465, 995, 993, 80, 443 — Bangladesh only |

---

## 2. What each list does

Two of these grant **nothing** on their own — this is the most common source of confusion.

| List | Mechanism | Grants access? |
|---|---|---|
| `MARTIAN_FULL_EXEMPT` | `RETURN` at top of MARTIAN | **NO** — only survives the anti-spoof drop |
| `MARTIAN_ICMP_EXEMPT` | `RETURN` for ICMP + ACCEPT at 4b | ICMP only |
| `ADMIN_NETS` | ACCEPT step 7 | console + SSH + mail + web |
| `OFFICE_NETS` | ACCEPT step 7 | *(empty)* |
| `VPN_NETS` | ACCEPT step 8 | mail + web |
| `LAN_NETS` | ACCEPT step 8 | mail + web |
| `SMTP_RELAY_NETS` | ACCEPT step **8b** | port 25 |
| `MX_NETS` → `whitelist_mx` | ACCEPT step 11 | port 25 |
| `HOST_SELF_IP` / `IP2` | ACCEPT step 6 | internal service ports |
| `THREAT_LISTS` (14 feeds) | DROP step 14 | denies |

> **An RFC1918 source needs TWO entries:** `MARTIAN_FULL_EXEMPT` to survive step 2, plus `LAN_NETS`/`ADMIN_NETS`/`SMTP_RELAY_NETS` to be granted ports. Exemption alone = ICMP only. Allow alone = dropped at step 2.

---

## 3. Access matrix

| Source | Lists | 22/8022 | 7071/8443 | 993/995/465/587 | 80/443 | 25 | ICMP | 110/143 |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `192.168.77.154` rkarim | ADMIN + EXEMPT | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `192.168.77.155` soiket | ADMIN + EXEMPT | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `192.168.77.157` sumon | ADMIN + EXEMPT | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `192.168.77.28` aion qudrat | ADMIN + EXEMPT | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `172.23.47.54` fidc | ADMIN + LAN + EXEMPT | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| **`103.229.83.240/29`** office NAT | LAN | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `192.168.0.0/16` | VPN + LAN + EXEMPT | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `192.168.77.0/24` | LAN + EXEMPT | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `192.168.42.0/24` | LAN + EXEMPT | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `192.168.4.0/24` | LAN + EXEMPT | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `192.168.44.16` | LAN + EXEMPT | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `172.23.46.150` TaskMGR | LAN + RELAY + EXEMPT | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `172.23.46.136` PRTG | LAN + RELAY + EXEMPT | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `192.168.44.43` GIS | RELAY + EXEMPT | ❌ | ❌ | ✅¹ | ✅¹ | ✅ | ✅ | ❌ |
| `192.168.44.175` GIS | RELAY + EXEMPT | ❌ | ❌ | ✅¹ | ✅¹ | ✅ | ✅ | ❌ |
| `192.168.44.50` GIS | RELAY + EXEMPT | ❌ | ❌ | ✅¹ | ✅¹ | ✅ | ✅ | ❌ |
| `10.15.20.227` | LAN | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `103.7.248.2` VPN gw | VPN | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `103.7.248.11` VPN gw | VPN | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| Microsoft EOP (5 ranges) | whitelist_mx | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ |
| MailPlus (3 ranges) | whitelist_mx | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ |
| `10.17.20.163` host self | HOST_SELF | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ |
| `103.7.248.10` host self | HOST_SELF | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ |
| Bangladesh public | GeoIP pass | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `10.0.0.0/8`, `172.16.0.0/12`, `169.254.0.0/16` | ICMP_EXEMPT | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |
| Rest of world | — | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |
| Any IP in a threat feed | THREAT_LISTS | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

¹ via `192.168.0.0/16` in `LAN_NETS`

**Internal service ports** (7025, 7026, 7072-7074, 7993, 7995, 8080, 7171, 7306, 10663, 23232, 23233, 111, 389, 636, 3310, 8465, 11211, 10024-10032) — dropped for every source except host-self.

---

## 4. Rule order

```
step  rule                                          effect
----  --------------------------------------------  --------------------------------
 1    -i lo                                         ACCEPT
 2    -i ens4 -> MARTIAN chain                      see below
 3    127.0.0.0/8 non-lo, INVALID, stealth flags    DROP
 4    110,143 any interface                         DROP
 4b   ICMP from MARTIAN_ICMP_EXEMPT                 ACCEPT (rate-limited)
 5    RELATED,ESTABLISHED                           ACCEPT
 6    HOST_SELF_IP / IP2 -> HOST_SELF_PORTS         ACCEPT
 7    ADMIN_NETS -> console+ssh, then mail+web      ACCEPT
 8    VPN_NETS + LAN_NETS -> mail+web               ACCEPT
 8b   SMTP_RELAY_NETS -> port 25                    ACCEPT   <-- ahead of feeds
 9    7071,8443,22,8022                             DROP
10    rate limits (smtp/submit/imap/ssh)            DROP if above
11    whitelist_mx -> port 25                       ACCEPT
12    GeoIP != BD on 587,465,995,993,80,443         DROP
13    manual_blacklist                              DROP
14    threat feeds (14 sets)                        DROP
15    port 25                                       DROP
      993,995,465,587,80,443 (GeoIP survivors)      ACCEPT
16    internal ports (ens4 + dead ens3 rules)       DROP
17    ICMP echo, rate-limited                       ACCEPT
18    everything else                               NETSET_DROP
```

### MARTIAN chain (step 2, ens4 only)

```
RETURN  192.168.77.0/24, 172.23.47.0/24, 192.168.42.0/24,
        192.168.4.0/24, 192.168.0.0/16, 172.23.46.0/24    <- FULL_EXEMPT
RETURN  10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
        169.254.0.0/16   (-p icmp only)                   <- ICMP_EXEMPT
DROP    10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
        169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4
```

`RETURN` in a custom chain resumes in INPUT after the jump. (In a built-in chain it falls through to the policy — `ACCEPT` — bypassing everything. That was a real bug in an earlier version.)

---

## 5. Open issues

### 5.1 🔴 No working SSH path

`ADMIN_NETS` holds five RFC1918 `/32`s, but office traffic arrives NATed as `103.229.83.244`. Every SSH allow reads zero packets:

```bash
iptables-legacy -L INPUT -nv --line-numbers | grep -E '22,8022' | awk '$2>0'
```

Existing sessions survive on `RELATED,ESTABLISHED`. Once they drop, **hypervisor console is the only way in**. Confirm console access before disconnecting.

### 5.2 🔴 Per-host admin control is unachievable while NAT is in place

Every office machine presents as `103.229.83.244`. The five `/32` entries can never match. Two fixes:

- **Preferred:** OPNsense no-NAT policy for traffic to `103.7.248.10`, so office sources arrive as `192.168.x`. The existing config then works as written.
- **Alternative:** enforce per-host admin at OPNsense — only the five listed hosts may reach `:22` and `:7071`.

### 5.3 🟠 Verify `mynetworks` matches `SMTP_RELAY_NETS`

The firewall now lets these five reach port 25; Postfix decides whether they may relay. Both must agree:

```bash
su - zimbra -c 'postconf mynetworks'
```

Needs `172.23.46.0/24` and `192.168.44.0/24` (or the specific `/32`s), or Postfix returns "Relay access denied" despite the firewall passing the packet.

### 5.4 🟠 `SMTP_RELAY_NETS` comment is stale

It still says `103.7.248.53 is the NOC alerting system... Removing it silently kills every NOC alert`, but that entry is commented out. Also disabled: pico-erp, FGL alerting, dev server, print manager. Confirm they migrated to 587 with SMTP AUTH:

```bash
for IP in 103.7.248.53 103.118.87.168 103.131.159.158 103.131.159.237 192.168.42.59; do
  echo -n "$IP: "; grep -c "client=.*\[$IP\]" /var/log/zimbra.log
done
```

Non-zero and still growing = that system is failing now.

### 5.5 🟠 `MARTIAN_FULL_EXEMPT` includes `192.168.0.0/16`

Makes the four narrower entries redundant and exempts 65,536 addresses from anti-spoof and the feeds. Combined with the same `/16` in `LAN_NETS`, that whole range gets mail and webmail. List only the VLANs that exist.

### 5.6 🟠 Admin sources bypass the SSH rate limit

`setup_ratelimit_rules` runs at step 10; admin allows at step 7. Move it to just after step 5.

### 5.7 🟡 `binarydefense` still attached as an empty set

Returns HTTP 301 and `curl` has no `-L` (verified: 0 occurrences of `curl -sL`). One useless lookup per packet.

```bash
sed -i 's|curl -s --connect-timeout|curl -sL --connect-timeout|' /usr/local/bin/manage-netsets.sh
```

### 5.8 🟡 `LAN_IFACE="ens3"` no longer exists

Step 16 emits three rules bound to `-i ens3` that match nothing. Set `LAN_IFACE="ens4"` or drop the branch.

### 5.9 🟡 Duplicate `192.168.0.0/16`

Present in both `VPN_NETS` and `LAN_NETS` — identical ACCEPT rules emitted twice.

### 5.10 🟡 Egress unrestricted

`EGRESS_ENABLE=0`. This is the control that addresses the 29 Aug attack path.

---

## 6. Design rule

**Every RFC1918 address is in `firehol_level1`** (bogons). Any allow placed *after* step 14 silently fails for internal sources — it looks like a correct config that does nothing. This is what broke the relay hosts before the 8b fix.

Two ways to remove the trap permanently:

1. Keep all internal allows before step 14 (what 8b now does)
2. Scope the feed rules to public service ports only:

```bash
$IPT -A INPUT -i "$WAN_IFACE" -p tcp \
     -m multiport --dports "${MAIL_CLIENT_PORTS},${WEBMAIL_PORTS},25" \
     -m set --match-set "$bl" src -j NETSET_DROP
```

Option 2 is more robust — a feed false-positive then costs webmail rather than blocking SSH, ICMP and everything else.

---

## 7. Verification

```bash
# Which rules are actually hit
iptables-legacy -L INPUT -nv --line-numbers | awk '$2+0 > 0'

# Relay allow must precede the feeds
iptables-legacy -L INPUT -n --line-numbers | grep -nE '172.23.46|192.168.44.4|firehol_level1'

# MARTIAN order — RETURNs above DROPs
iptables-legacy -S MARTIAN

# Any working SSH path
iptables-legacy -L INPUT -nv --line-numbers | grep -E '22,8022' | awk '$2>0'

fw-report.sh
manage-netsets.sh access
manage-netsets.sh smtp-audit
```

---

## 8. Outside this script

- **No backup exists** — 1,287 mailboxes protected only by hypervisor snapshots
- **Zimbra 10.1.6** — the version exploited on 29 Aug
- **`mynetworks`** grants unauthenticated relay to ~2,300 public addresses
- **memcached on `0.0.0.0`** — firewalled but should be bound to loopback
- **Credential rotation** across 1,287 accounts

## 9. OPNsense boundary

Office ranges arrive as RFC1918 on a public interface, forcing the martian exemptions. Those ranges are spoofable from the internet **unless OPNsense drops WAN packets with RFC1918 sources** (BCP38 ingress filtering). Worth confirming — if it does, the exemptions carry little risk; if not, an attacker bypasses the GeoIP gate and ~250,000 blocked networks by forging a `192.168.77.x` source.