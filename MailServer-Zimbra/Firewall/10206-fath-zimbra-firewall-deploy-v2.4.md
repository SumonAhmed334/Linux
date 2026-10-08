# Zimbra Mail Storage Server — Merged with GeoIP Reference Script

Confirmed: the script you just pasted is the same one from earlier in this thread — your GeoIP allowlist box's `manage-netsets.sh`, `geo-update.sh`, and systemd units. This build folds that script's features (GeoIP country allowlisting, live whitelist CLI management) into the Zimbra box, adjusted for its actual ports, interfaces, and traffic patterns. Full rebuild — supersedes the previous version of this file.

### Contents
- The one deliberate deviation from your reference: port 25
- What came over from the reference script
- Updated rule precedence
- Prerequisites (packages, directories, sanity checks)
- `manage-netsets.sh` (complete file)
- `geo-update.sh` + both systemd timer pairs
- Deployment steps
- Regular operational CLI commands
- Day-2 ops & gotchas

---

## The One Deliberate Deviation: Port 25

Your reference script's `GEOBLOCK_TCP_PORTS` includes 25 alongside the rest. I left it out here, on purpose: inbound mail for this box arrives via `fiberathome-net.mail.protection.outlook.com`, and Microsoft's Exchange Online Protection relay pool is spread across datacenters globally — it is not confined to `SG,BD,US,AE,IN,KR,MY,TH,PH,JP`. Geo-gating port 25 risks silently dropping legitimate inbound mail from your own connector whenever Microsoft happens to relay a message from an IP outside that list.

Everything else from the reference script's `GEOBLOCK_TCP_PORTS` — submission, IMAP/POP, webmail/admin — is geo-gated as designed, since those are ports your actual mailbox users and admin sessions hit, and that traffic genuinely should be concentrated in your allowed countries. Port 25 gets its own always-open lane (`SMTP_RELAY_PORT`), protected only by the blacklists, same as it needs to be.

If you know your Outlook/EOP routing is actually pinned to a specific, stable set of source IPs (some tenants configure this), geo-gating 25 too becomes safe — just say so and I'll move it.

## What Came Over From the Reference Script

- **`ALLOWED_COUNTRIES`, `GEOBLOCK_TCP_PORTS`, `GEOBLOCK_UDP_PORTS`, `WAN_IFACE`-scoped `setup_geoip_rules()`** — same country list as your GeoIP box, same allowlist mechanism, ported onto `ens4` here instead of `ens18`.
- **The fail-open safety check** — this wasn't in your original reference script; I added it there in an earlier pass after finding that `xt_geoip`'s negated-allowlist behavior means an empty country database drops *everyone*, not just non-allowed countries. Since GeoIP is new to this box, that same risk applies here from day one, so the check comes with it.
- **`geo-update.sh` and `geoip-update.timer`** — the hardened version (atomic staging, verified build, locking) from your GeoIP box, unchanged. Same database, same maintenance script, works identically here.
- **Live whitelist CLI management** (`add-whitelist`/`remove-whitelist`) — your reference script has this; the Zimbra build didn't (whitelist entries could only be changed by editing the array and rerunning `update`). Ported over, adjusted to take a `wan`/`lan` argument since trust here is interface-bound.

## Updated Rule Precedence

GeoIP slots in right after the interface-bound whitelists, ahead of the blacklists — matching your reference script's own stated ordering (whitelist → geoip → blacklists), and for the same reason: one GeoIP check rejects most non-allowed-country traffic before spending cycles walking 11 separate ipset lookups.

```
1.  Loopback                                                        -> ACCEPT
2.  Anti-spoof (RFC1918 on ens4, loopback-space on any real NIC)    -> DROP
3.  whitelist_lan (unrestricted, any port)         -- ens3 only     -> ACCEPT
4.  whitelist_wan (unrestricted, any port)         -- ens4 only     -> ACCEPT
5.  Established/related connections                                 -> ACCEPT
6.  GeoIP allowlist on GEOBLOCK_TCP/UDP_PORTS      -- ens4 only     -> DROP (non-allowed countries)
7.  Manual IP blacklist                            -- ens4 only     -> DROP
8.  Threat-intel blacklists (11 sources)           -- ens4 only     -> DROP
9.  Mail/web ports (port 25 + GEOBLOCK_TCP_PORTS), both interfaces  -> ACCEPT
10. ICMP                                                            -> ACCEPT
11. Everything else                                                 -> DROP (default-deny)
```

I traced this against the actual generated `iptables` rule sequence (not just the design) with the GeoIP database both populated and empty, confirmed the fail-open path skips the GeoIP rules entirely and logs a warning rather than dropping the world, and confirmed port 25 sits correctly inside the final mail/web ACCEPT alongside the geo-gated ports.

---

## Prerequisites

Packages, kernel modules, the two directories the scripts write into, IPv6 disable, and retiring `iptables-persistent`. Two entries here (`libtext-csv-xs-perl` and the `/etc/ipset` directory) were added after a live deploy surfaced them — see the notes inline.

```bash
apt update
apt install -y iptables ipset curl

# xtables-addons: kernel module (xt_geoip) + the xt_geoip_dl/xt_geoip_build
# helper scripts. DKMS needs matching headers to build the module.
apt install -y xtables-addons-common xtables-addons-dkms "linux-headers-$(uname -r)"

# xt_geoip_build is a Perl script that parses the country CSVs with
# Text::CSV_XS. The xtables-addons packages do NOT pull this in on Ubuntu, so
# without it geo-update.sh fails at the build step (correctly leaving the
# existing DB untouched, but never producing a new one). Install it explicitly.
apt install -y libtext-csv-xs-perl

dkms status | grep -i xtables || echo "check 'dkms status' output above for build errors"

modprobe ip_set xt_set nf_conntrack xt_geoip 2>&1 | grep -v "^$" || echo "modules load cleanly"
lsmod | grep -E "^(ip_set|xt_set|nf_conntrack|xt_geoip)"

# Directories the scripts write into. manage-netsets.sh saves every ipset to
# /etc/ipset/*.save (this is what `restore` reads back at boot); geo-update.sh
# logs to /var/log. Neither script creates /etc/ipset itself, so it must exist
# before the first `update` -- otherwise the sets still load into the kernel
# and rules apply fine, but nothing persists for a reboot.
mkdir -p /etc/ipset

systemctl disable netfilter-persistent 2>/dev/null || echo "netfilter-persistent not present as a service -- nothing to disable"

cat > /etc/sysctl.d/99-disable-ipv6.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf

# --- Sanity check before proceeding: confirm the two things a fresh box most
#     often lacks are actually in place ---
perl -MText::CSV_XS -e 'print "Text::CSV_XS OK\n"' || echo "MISSING: run 'apt install -y libtext-csv-xs-perl'"
[ -d /etc/ipset ] && echo "/etc/ipset OK" || echo "MISSING: run 'mkdir -p /etc/ipset'"
```

---

## `manage-netsets.sh` (complete file)

`bash -n` and `shellcheck` clean (same two pre-existing `SC2155` warnings, nothing new across every change in this pass). Full rule sequence generated against mocked `iptables`/`ipset` and checked line-by-line against the precedence table above, both with the GeoIP database populated and empty. `add-whitelist`/`remove-whitelist` tested for both `wan` and `lan`, including add, remove, and invalid-interface-argument handling — caught and fixed a bug in my own test mock along the way (a grep exit-code quirk that made a removal look like it silently failed); the real `remove_whitelist` function itself was correct throughout, calling the actual `ipset del`, not my simplified stand-in.

```bash
cat > /usr/local/bin/manage-netsets.sh << 'SCRIPT_EOF'
#!/bin/bash

# Netset management script -- Zimbra mail storage server
# Default-deny posture: only loopback, interface-bound whitelisted ranges, and
# the mail/web service ports are reachable; everything else is dropped.
#
# Two physical interfaces are trusted differently:
#   ens4 = public/WAN  -- internet-facing, mail/web ports live here, plus the
#                          ISP admin ranges that manage this box remotely
#   ens3 = local-office LAN -- internal network only
# Trust is bound to the interface a range is *expected* to arrive on, not
# just the claimed source IP -- a spoofed 192.168.x.x source arriving on the
# public interface no longer gets treated as trusted internal traffic, and
# vice versa for public admin ranges arriving on the LAN side.
IPSET_DIR="/etc/ipset"
TEMP_DIR="/tmp/netsets"
LOG_FILE="/var/log/netset-manager.log"

WAN_IFACE="ens4"
LAN_IFACE="ens3"

# Port that must stay open to literally anyone in any country: inbound SMTP
# has to accept from arbitrary remote MTAs as well as Microsoft's Exchange
# Online Protection relay pool (fiberathome-net.mail.protection.outlook.com),
# which is globally distributed across datacenters, not confined to
# ALLOWED_COUNTRIES below. Deliberately excluded from the GeoIP gate.
SMTP_RELAY_PORT="25"

# --- GeoIP Configuration (ALLOWLIST) -- ported from your reference script ---
# Only these countries may reach the ports in GEOBLOCK_TCP_PORTS/UDP_PORTS.
# Everyone else is DROPPED on those ports (WAN_IFACE only -- see
# setup_geoip_rules). ISO 3166-1 alpha-2 codes: AE = United Arab Emirates.
ALLOWED_COUNTRIES="SG,BD,US,AE,IN,KR,MY,TH,PH,JP"

# Ports gated by the GeoIP allowlist: submission, IMAP/POP, webmail/admin.
# Port 25 is intentionally NOT here -- see SMTP_RELAY_PORT above.
GEOBLOCK_TCP_PORTS="587,465,110,995,143,993,8443,80,443"
# UDP map (optional): 443 -> HTTP/3 (QUIC) for webmail. Leave empty to disable.
GEOBLOCK_UDP_PORTS="443"

# All service ports combined -- SMTP_RELAY_PORT + everything in
# GEOBLOCK_TCP_PORTS. This is what gets the final global ACCEPT rule on both
# interfaces once whitelist/blacklist/GeoIP have all had their say.
MAIL_WEB_PORTS="${SMTP_RELAY_PORT},${GEOBLOCK_TCP_PORTS}"

# Global list of all managed ipsets
ALL_NETSETS=("firehol_level1" "firehol_level2" "firehol_level3" "firehol_level4" "spamhaus_drop" "ci_badguys" "et_bl1" "et_bl2" "bl_de1" "bl_agr" "crowdsec_bl" "whitelist_lan" "whitelist_wan" "manual_blacklist")

# Logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
## 1. Core Logic Functions
# -----------------------------------------------------------------------------

# Function to create and load a netset (blacklist) from URL
create_netset() {
    local name="$1"
    local url="$2"
    local description="$3"

    log_message "Processing $name: $description"
    mkdir -p "$TEMP_DIR"

    if curl -s --connect-timeout 30 --max-time 120 "$url" -o "$TEMP_DIR/$name.txt"; then

        ipset create "$name" hash:net hashsize 8192 maxelem 256000 -exist
        ipset create "${name}_temp" hash:net hashsize 8192 maxelem 256000 -exist

        local count=0
        while read -r line; do
            network=$(echo "$line" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | head -1)
            if [[ -n "$network" ]]; then
                ipset add "${name}_temp" "$network" 2>/dev/null && ((count++))
            fi
        done < "$TEMP_DIR/$name.txt"

        ipset swap "${name}_temp" "$name" 2>/dev/null
        ipset destroy "${name}_temp" 2>/dev/null

        ipset save "$name" > "$IPSET_DIR/$name.save"

        log_message "Loaded $count entries into $name"
    else
        log_message "Failed to download $name from $url"
        return 1
    fi
}

# Function to create and load the interface-bound whitelists.
# whitelist_lan is only ever matched against traffic arriving on LAN_IFACE;
# whitelist_wan only against traffic arriving on WAN_IFACE. Splitting these
# (rather than one set matched on any interface) is what makes the
# anti-spoofing property below actually hold.
create_whitelists() {
    log_message "Creating interface-bound whitelists (lan=$LAN_IFACE, wan=$WAN_IFACE)"

    ipset create "whitelist_lan" hash:net hashsize 1024 maxelem 10000 -exist
    ipset flush "whitelist_lan"
    ipset create "whitelist_wan" hash:net hashsize 1024 maxelem 10000 -exist
    ipset flush "whitelist_wan"

    # Internal office network -- only legitimate arriving via LAN_IFACE.
    # (127.0.0.0/8 deliberately NOT included here -- loopback traffic is
    # handled by the dedicated `-i lo` rule below; a packet claiming a
    # loopback source on a real NIC is spoofed and should never be trusted.)
    local lan_count=0
    local lan_nets=(
        "192.168.0.0/16"        # Internal network
    )
    for network in "${lan_nets[@]}"; do
        if ipset add "whitelist_lan" "$network" 2>/dev/null; then
            ((lan_count++))
        fi
    done
    ipset save "whitelist_lan" > "$IPSET_DIR/whitelist_lan.save"
    log_message "Created whitelist_lan with $lan_count entries"

    # ISP admin ranges + DNS-resolver safety entries -- only legitimate
    # arriving via WAN_IFACE. 103.7.248.52/30 and a separate /32 for this
    # box's own public IP are deliberately omitted: both are fully covered
    # by 103.7.248.0/24, which is already in this list (see check-overlaps).
    local wan_count=0
    local wan_nets=(
        "103.7.249.212/30"      # Admin/ISP range
        "103.229.82.56/29"      # Admin/ISP range
        "103.7.249.100/30"      # Admin/ISP range
        "163.47.157.192/28"     # Admin/ISP range
        "103.7.248.0/24"        # Admin/ISP range -- also covers this box's own public IP (103.7.248.10), hairpin-NAT safe
        "8.8.8.8/32"            # Google DNS
        "8.8.4.4/32"            # Google DNS
        "1.1.1.1/32"            # Cloudflare DNS
        "1.0.0.1/32"            # Cloudflare DNS
        "9.9.9.9/32"            # Quad9 DNS
    )
    for network in "${wan_nets[@]}"; do
        if ipset add "whitelist_wan" "$network" 2>/dev/null; then
            ((wan_count++))
        fi
    done
    ipset save "whitelist_wan" > "$IPSET_DIR/whitelist_wan.save"
    log_message "Created whitelist_wan with $wan_count entries"
}

# Function to create and initialize manual blacklist
create_manual_blacklist() {
    local name="manual_blacklist"
    log_message "Creating manual blacklist: $name"

    ipset create "$name" hash:net hashsize 1024 maxelem 50000 -exist

    if [[ -f "$IPSET_DIR/$name.save" ]]; then
        ipset restore < "$IPSET_DIR/$name.save" 2>/dev/null
        local count=$(ipset list "$name" | grep -c '^[0-9]')
        log_message "Restored manual blacklist with $count entries"
    else
        log_message "Manual blacklist initialized (empty)"
    fi
}

# Function to check for redundant/overlapping CIDR entries within a set --
# an entry that's already a subset of a broader entry in the same set adds
# no coverage, just clutter (and, over time, confusion about what's actually
# blocking what). Read-only: reports, never modifies.
check_overlaps() {
    local set_name="${1:-manual_blacklist}"

    if ! ipset list "$set_name" >/dev/null 2>&1; then
        echo "Set $set_name does not exist"
        return 1
    fi

    local entries
    entries=$(ipset list "$set_name" | grep -E '^[0-9]+\.')

    if [[ -z "$entries" ]]; then
        echo "No entries in $set_name -- nothing to check"
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not available -- cannot check for overlaps"
        return 1
    fi

    echo "$entries" | python3 -c '
import sys
import ipaddress

nets = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        nets.append((line, ipaddress.ip_network(line, strict=False)))
    except ValueError:
        continue

nets_sorted = sorted(nets, key=lambda x: x[1].prefixlen)
redundant = []
for i, (estr, enet) in enumerate(nets_sorted):
    for bstr, bnet in nets_sorted[:i]:
        if bnet.prefixlen < enet.prefixlen and enet.subnet_of(bnet):
            redundant.append((estr, bstr))
            break

if redundant:
    print(f"{len(redundant)} redundant entr" + ("y" if len(redundant) == 1 else "ies") + " found in this set:")
    for small, big in redundant:
        print(f"  {small} is already fully covered by {big}")
else:
    print("No redundant/overlapping entries found.")
'
}

# Function to set up the GeoIP country ALLOWLIST on the configured ports.
# WAN_IFACE only -- LAN traffic is already interface-bound via whitelist_lan,
# and RFC1918 addresses have no GeoIP country mapping anyway (an attempt to
# geo-check them would read as "no match" and get dropped under the negated
# allowlist below, which would be wrong for legitimate LAN traffic).
setup_geoip_rules() {
    log_message "Setting up GeoIP allowlist on service ports (allow: $ALLOWED_COUNTRIES)"

    # Safety check -- do NOT insert a GeoIP rule against an empty/missing
    # database. xt_geoip resolves an IP it can't map to "no country match".
    # Combined with the negated allowlist (! --src-cc), an empty DB means
    # EVERY source -- including legitimate traffic from allowed countries --
    # fails the match and gets DROPPED: a total outage on every port below,
    # not "no protection". Failing OPEN here instead: skip the geoip rule,
    # keep going, log it loudly. manual_blacklist and the threat-intel lists
    # still apply either way.
    local geoip_file_count
    geoip_file_count=$(find /usr/share/xt_geoip -mindepth 1 -type f 2>/dev/null | wc -l)
    if [[ "$geoip_file_count" -eq 0 ]]; then
        log_message "WARNING: /usr/share/xt_geoip has no data files -- skipping GeoIP allowlist (failing OPEN, not closed). Run geo-update.sh to repopulate it. Blacklists still apply."
        return 0
    fi

    iptables -A INPUT -i "$WAN_IFACE" -p tcp -m multiport --dports "$GEOBLOCK_TCP_PORTS" \
        -m geoip ! --src-cc "$ALLOWED_COUNTRIES" -j DROP
    log_message "Allowlist [$ALLOWED_COUNTRIES] applied on TCP ports: $GEOBLOCK_TCP_PORTS ($WAN_IFACE only, other countries dropped)"

    if [[ -n "$GEOBLOCK_UDP_PORTS" ]]; then
        iptables -A INPUT -i "$WAN_IFACE" -p udp -m multiport --dports "$GEOBLOCK_UDP_PORTS" \
            -m geoip ! --src-cc "$ALLOWED_COUNTRIES" -j DROP
        log_message "Allowlist [$ALLOWED_COUNTRIES] applied on UDP ports: $GEOBLOCK_UDP_PORTS ($WAN_IFACE only, other countries dropped)"
    fi
}

# Function to apply all iptables rules from existing ipsets
apply_all_rules() {
    log_message "Applying all firewall rules with correct precedence"

    iptables -F INPUT
    iptables -F FORWARD
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT

    # 1. Loopback
    iptables -A INPUT -i lo -j ACCEPT

    # 2. Anti-spoof / martian filtering. A packet claiming an RFC1918 source
    #    arriving on the PUBLIC interface, or a loopback-space source
    #    arriving on ANY real interface, cannot be legitimate -- drop it
    #    before it ever gets a chance to be evaluated against anything else.
    iptables -A INPUT -s 127.0.0.0/8 -j DROP
    iptables -A INPUT -i "$WAN_IFACE" -s 10.0.0.0/8 -j DROP
    iptables -A INPUT -i "$WAN_IFACE" -s 172.16.0.0/12 -j DROP
    iptables -A INPUT -i "$WAN_IFACE" -s 192.168.0.0/16 -j DROP

    # 3. Whitelists -- unrestricted access on any port, but each only valid
    #    on the interface it's supposed to arrive on. Bypasses GeoIP and
    #    every blacklist below, same as your reference script's model.
    if ipset list "whitelist_lan" >/dev/null 2>&1; then
        iptables -A INPUT -i "$LAN_IFACE" -m set --match-set "whitelist_lan" src -j ACCEPT
        log_message "Applied whitelist_lan (bound to $LAN_IFACE)"
    fi
    if ipset list "whitelist_wan" >/dev/null 2>&1; then
        iptables -A INPUT -i "$WAN_IFACE" -m set --match-set "whitelist_wan" src -j ACCEPT
        log_message "Applied whitelist_wan (bound to $WAN_IFACE)"
    fi

    # 4. Established/related early -- short-circuits the bulk of ongoing mail
    #    session traffic before it has to walk GeoIP and the ipset blacklists
    iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

    # 5. GeoIP allowlist -- deliberately ahead of the blacklists below: a
    #    single geoip check rejects most non-allowed-country traffic before
    #    spending cycles walking 11 separate ipset lookups, matching your
    #    reference script's own ordering (whitelist -> geoip -> blacklists).
    setup_geoip_rules

    # 6. Manual blacklist -- scoped to WAN_IFACE: these are public-internet
    #    threat ranges and have no legitimate reason to affect the LAN side
    if ipset list "manual_blacklist" >/dev/null 2>&1; then
        iptables -A INPUT -i "$WAN_IFACE" -m set --match-set "manual_blacklist" src -j DROP
        log_message "Applied manual blacklist rules (bound to $WAN_IFACE)"
    fi

    # 7. Threat-intel blacklists -- same reasoning, WAN_IFACE only
    local blacklists=("firehol_level1" "firehol_level2" "firehol_level3" "firehol_level4" "spamhaus_drop" "ci_badguys" "et_bl1" "et_bl2" "bl_de1" "bl_agr" "crowdsec_bl")

    for blacklist in "${blacklists[@]}"; do
        if ipset list "$blacklist" >/dev/null 2>&1; then
            iptables -A INPUT -i "$WAN_IFACE" -m set --match-set "$blacklist" src -j DROP
        fi
    done

    # 8. Mail/web ports open on either interface -- covers SMTP_RELAY_PORT
    #    (25, ungated -- has to accept from anywhere) plus everything in
    #    GEOBLOCK_TCP_PORTS (already filtered by GeoIP above on WAN_IFACE;
    #    this ACCEPT is what actually admits allowed-country/LAN traffic
    #    that survived every check above it). Not restricted by interface
    #    since local office mail clients need these too.
    iptables -A INPUT -p tcp -m multiport --dports "$MAIL_WEB_PORTS" -j ACCEPT
    log_message "Opened mail/web ports on both interfaces: $MAIL_WEB_PORTS"

    # 9. ICMP
    iptables -A INPUT -p icmp -j ACCEPT

    # 10. Default deny -- anything not explicitly matched above is dropped.
    #    Policy stays ACCEPT and this is an explicit trailing rule instead of
    #    `-P INPUT DROP`, so a script that errors out partway through fails
    #    open rather than locking you out entirely.
    iptables -A FORWARD -j DROP
    iptables -A INPUT -j DROP

    log_message "All firewall rules applied successfully"
}

# Function to save current ipset and iptables rules to file
save_rules() {
    log_message "Saving current ipset and iptables rules"
    for set_name in "${ALL_NETSETS[@]}"; do
        if ipset list "$set_name" >/dev/null 2>&1; then
            ipset save "$set_name" > "$IPSET_DIR/$set_name.save"
        fi
    done
    iptables-save > "$IPSET_DIR/iptables.save"
    log_message "All rules saved to disk"
}

# -----------------------------------------------------------------------------
## Manual IP Blocking Functions
# -----------------------------------------------------------------------------

# Function to add IP/subnet to manual blacklist
add_manual_block() {
    local network="$1"

    if [[ -z "$network" ]]; then
        echo "Usage: $0 block-ip <network>"
        echo "Example: $0 block-ip 192.168.1.100"
        echo "Example: $0 block-ip 203.0.113.0/24"
        exit 1
    fi

    if [[ ! "$network" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        log_message "Invalid network format: $network"
        echo "Error: Invalid network format: $network"
        exit 1
    fi

    ipset create "manual_blacklist" hash:net hashsize 1024 maxelem 50000 -exist

    if ipset add "manual_blacklist" "$network" 2>/dev/null; then
        ipset save "manual_blacklist" > "$IPSET_DIR/manual_blacklist.save"
        log_message "Added $network to manual blacklist"
        echo "Successfully blocked $network"
        apply_all_rules

        # Quick heads-up if this entry (or an existing one) is now redundant
        # -- doesn't block the add, just tells you
        local overlap_result
        overlap_result=$(check_overlaps "manual_blacklist" 2>/dev/null)
        if [[ "$overlap_result" != "No redundant/overlapping entries found." ]]; then
            echo
            echo "Note: $overlap_result"
        fi
    else
        log_message "Failed to add $network to manual blacklist (may already exist)"
        echo "Network $network already exists in manual blacklist or invalid format"
    fi
}

# Function to remove IP/subnet from manual blacklist
remove_manual_block() {
    local network="$1"

    if [[ -z "$network" ]]; then
        echo "Usage: $0 unblock-ip <network>"
        echo "Example: $0 unblock-ip 192.168.1.100"
        exit 1
    fi

    if ipset test "manual_blacklist" "$network" 2>/dev/null; then
        ipset del "manual_blacklist" "$network"
        ipset save "manual_blacklist" > "$IPSET_DIR/manual_blacklist.save"
        log_message "Removed $network from manual blacklist"
        echo "Successfully unblocked $network"
        apply_all_rules
    else
        log_message "Network $network not found in manual blacklist"
        echo "Network $network not found in manual blacklist"
    fi
}

# Function to show manual blacklist
show_manual_blacklist() {
    echo "Current Manual Blacklist Networks (bound to $WAN_IFACE):"
    if ipset list "manual_blacklist" >/dev/null 2>&1; then
        local entries=$(ipset list "manual_blacklist" | grep -E '^[0-9]+\.' | sort -V)
        if [[ -n "$entries" ]]; then
            echo "$entries"
            echo
            echo "Total blocked IPs/networks: $(echo "$entries" | wc -l)"
        else
            echo "No manual blocks configured"
        fi
    else
        echo "No manual blacklist configured"
    fi
}

# Function to add IP/subnet to a whitelist -- ported from your reference
# script's add-whitelist, adapted to require choosing lan or wan since trust
# is interface-bound here (see apply_all_rules)
add_whitelist() {
    local iface_choice="$1"
    local network="$2"
    local set_name

    case "$iface_choice" in
        wan) set_name="whitelist_wan" ;;
        lan) set_name="whitelist_lan" ;;
        *)
            echo "Usage: $0 add-whitelist <wan|lan> <network>"
            echo "Example: $0 add-whitelist wan 203.0.113.5/32"
            echo "Example: $0 add-whitelist lan 192.168.50.0/24"
            exit 1
            ;;
    esac

    if [[ -z "$network" ]]; then
        echo "Usage: $0 add-whitelist <wan|lan> <network>"
        exit 1
    fi

    if [[ ! "$network" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        log_message "Invalid network format: $network"
        echo "Error: Invalid network format: $network"
        exit 1
    fi

    ipset create "$set_name" hash:net hashsize 1024 maxelem 10000 -exist

    if ipset add "$set_name" "$network" 2>/dev/null; then
        ipset save "$set_name" > "$IPSET_DIR/$set_name.save"
        log_message "Added $network to $set_name"
        echo "Successfully added $network to $set_name"
        apply_all_rules
    else
        log_message "Failed to add $network to $set_name (may already exist)"
        echo "Network $network already exists in $set_name or invalid format"
    fi
}

# Function to remove IP/subnet from a whitelist
remove_whitelist() {
    local iface_choice="$1"
    local network="$2"
    local set_name

    case "$iface_choice" in
        wan) set_name="whitelist_wan" ;;
        lan) set_name="whitelist_lan" ;;
        *)
            echo "Usage: $0 remove-whitelist <wan|lan> <network>"
            exit 1
            ;;
    esac

    if [[ -z "$network" ]]; then
        echo "Usage: $0 remove-whitelist <wan|lan> <network>"
        exit 1
    fi

    if ipset test "$set_name" "$network" 2>/dev/null; then
        ipset del "$set_name" "$network"
        ipset save "$set_name" > "$IPSET_DIR/$set_name.save"
        log_message "Removed $network from $set_name"
        echo "Successfully removed $network from $set_name"
        apply_all_rules
    else
        log_message "Network $network not found in $set_name"
        echo "Network $network not found in $set_name"
    fi
}

# Function to show whitelists
show_whitelists() {
    echo "Current whitelist_lan (bound to $LAN_IFACE):"
    if ipset list "whitelist_lan" >/dev/null 2>&1; then
        ipset list "whitelist_lan" | grep -E '^[0-9]+\.' | sort -V
    else
        echo "  Not configured"
    fi
    echo
    echo "Current whitelist_wan (bound to $WAN_IFACE):"
    if ipset list "whitelist_wan" >/dev/null 2>&1; then
        ipset list "whitelist_wan" | grep -E '^[0-9]+\.' | sort -V
    else
        echo "  Not configured"
    fi
}

# Function to check if an IP is blocked
check_ip_status() {
    local ip="$1"

    if [[ -z "$ip" ]]; then
        echo "Usage: $0 check-ip <ip>"
        echo "Example: $0 check-ip 192.168.1.100"
        exit 1
    fi

    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: Invalid IP format: $ip"
        exit 1
    fi

    echo "Checking status for IP: $ip"
    echo "================================"

    local is_whitelisted=0
    if ipset test "whitelist_lan" "$ip" 2>/dev/null; then
        echo "✓ WHITELISTED (whitelist_lan) - Unrestricted access, but ONLY when arriving via $LAN_IFACE"
        is_whitelisted=1
    fi
    if ipset test "whitelist_wan" "$ip" 2>/dev/null; then
        echo "✓ WHITELISTED (whitelist_wan) - Unrestricted access, but ONLY when arriving via $WAN_IFACE"
        is_whitelisted=1
    fi
    if [[ "$is_whitelisted" -eq 1 ]]; then
        return 0
    fi

    if ipset test "manual_blacklist" "$ip" 2>/dev/null; then
        echo "✗ MANUALLY BLOCKED - blocked from every port on $WAN_IFACE, including mail/web"
        return 0
    fi

    local blocked_in=""
    local blacklists=("firehol_level1" "firehol_level2" "firehol_level3" "firehol_level4" "spamhaus_drop" "ci_badguys" "et_bl1" "et_bl2" "bl_de1" "bl_agr" "crowdsec_bl")

    for blacklist in "${blacklists[@]}"; do
        if ipset list "$blacklist" >/dev/null 2>&1 && ipset test "$blacklist" "$ip" 2>/dev/null; then
            blocked_in="$blocked_in $blacklist"
        fi
    done

    if [[ -n "$blocked_in" ]]; then
        echo "✗ BLOCKED - Found in blacklists:$blocked_in (blocked on $WAN_IFACE, including mail/web)"
    else
        echo "○ NOT BLOCKED"
        echo "Note: port $SMTP_RELAY_PORT (SMTP) is open to this IP from either interface,"
        echo "      unconditionally -- no GeoIP gate, since inbound mail has to accept from"
        echo "      anywhere. Ports $GEOBLOCK_TCP_PORTS require this IP's country to be in"
        echo "      $ALLOWED_COUNTRIES when arriving via $WAN_IFACE (no geo restriction on"
        echo "      $LAN_IFACE). All other ports are DROPPED unless whitelisted."
    fi
}

# -----------------------------------------------------------------------------
## 2. Command Handlers
# -----------------------------------------------------------------------------

# Function to handle the `update` command
handle_update() {
    log_message "Starting netset update"

    create_whitelists
    create_manual_blacklist

    create_netset "firehol_level1" "https://iplists.firehol.org/files/firehol_level1.netset" "FireHOL Level1"
    create_netset "firehol_level2" "https://iplists.firehol.org/files/firehol_level2.netset" "FireHOL Level2"
    create_netset "firehol_level3" "https://iplists.firehol.org/files/firehol_level3.netset" "FireHOL Level3"
    create_netset "firehol_level4" "https://iplists.firehol.org/files/firehol_level4.netset" "FireHOL Level4"
    create_netset "spamhaus_drop" "https://www.spamhaus.org/drop/drop.txt" "Spamhaus DROP"
    create_netset "ci_badguys" "https://cinsscore.com/list/ci-badguys.txt" "CI-Badguys"
    create_netset "et_bl1" "https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt" "ET BLOCK1"
    create_netset "et_bl2" "https://rules.emergingthreats.net/blockrules/compromised-ips.txt" "ET Compro"
    create_netset "bl_de1" "https://lists.blocklist.de/lists/all.txt" "Blsites DE"
    create_netset "bl_agr" "https://feodotracker.abuse.ch/downloads/ipblocklist_aggressive.txt" "BL Aggr"
    create_netset "crowdsec_bl" "http://crowdsecabl.inetsecurity.net:41412/security/blocklist?ipv4only" "CrowdSec BL"

    apply_all_rules
    save_rules

    log_message "Netset update completed"
}

# Function to handle the `restore` command
handle_restore() {
    log_message "Restoring ipsets from saved files"
    for file in "$IPSET_DIR"/*.save; do
        if [[ -f "$file" ]]; then
            ipset restore < "$file"
            log_message "Restored $(basename "$file" .save)"
        fi
    done

    apply_all_rules
    save_rules
}

# -----------------------------------------------------------------------------
## 3. Main Execution
# -----------------------------------------------------------------------------

case "$1" in
    "update")
        handle_update
        ;;
    "reload")
        log_message "Reloading firewall rules"
        apply_all_rules
        save_rules
        ;;
    "restore")
        handle_restore
        ;;
    "block-ip")
        add_manual_block "$2"
        ;;
    "unblock-ip")
        remove_manual_block "$2"
        ;;
    "add-whitelist")
        add_whitelist "$2" "$3"
        ;;
    "remove-whitelist")
        remove_whitelist "$2" "$3"
        ;;
    "show-blocked")
        show_manual_blacklist
        ;;
    "show-whitelist")
        show_whitelists
        ;;
    "check-ip")
        check_ip_status "$2"
        ;;
    "check-overlaps")
        check_overlaps "${2:-manual_blacklist}"
        ;;
    "status")
        echo "=== Netset Firewall Status (Zimbra mail storage) ==="
        echo
        echo "Interfaces: WAN=$WAN_IFACE  LAN=$LAN_IFACE"
        echo
        echo "Current IPSets:"
        ipset list -t
        echo
        echo "IPTables rules with ipsets:"
        echo "INPUT chain:"
        iptables -L INPUT -n --line-numbers
        echo
        echo "FORWARD chain:"
        iptables -L FORWARD -n --line-numbers
        echo
        echo "Configuration:"
        echo "  SMTP relay port (always open, no geo gate): $SMTP_RELAY_PORT"
        echo "  GeoIP-gated TCP ports ($WAN_IFACE only):     $GEOBLOCK_TCP_PORTS"
        echo "  GeoIP-gated UDP ports ($WAN_IFACE only):     ${GEOBLOCK_UDP_PORTS:-<none>}"
        echo "  Allowed countries:                          $ALLOWED_COUNTRIES"
        echo "  All other ports: DROPPED unless source is whitelisted for the arriving interface"
        echo
        echo "GeoIP database:"
        geoip_status_count=$(find /usr/share/xt_geoip -mindepth 1 -type f 2>/dev/null | wc -l)
        if [[ "$geoip_status_count" -gt 0 ]]; then
            geoip_newest=$(find /usr/share/xt_geoip -mindepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
            echo "  Populated -- $geoip_status_count files, newest: ${geoip_newest:-unknown}"
        else
            echo "  MISSING/EMPTY -- GeoIP allowlist is NOT being applied (failing open, see setup_geoip_rules). Run geo-update.sh."
        fi
        echo
        show_whitelists
        echo
        show_manual_blacklist
        ;;
    "reset-policy")
        log_message "Resetting iptables to default ACCEPT policy"
        iptables -F INPUT
        iptables -F FORWARD
        iptables -P INPUT ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -P FORWARD ACCEPT
        log_message "Firewall reset to allow-all mode"
        ;;
    "save")
        save_rules
        ;;
    *)
        echo "Usage: $0 {update|reload|restore|block-ip|unblock-ip|add-whitelist|remove-whitelist|show-blocked|show-whitelist|check-ip|check-overlaps|status|reset-policy|save}"
        echo
        echo "Commands:"
        echo "  update                    - Download and apply all blacklists, then save"
        echo "  reload                    - Re-apply existing rules, then save"
        echo "  restore                   - Restore ipsets from saved files, then save"
        echo "  block-ip <ip/net>         - Manually block specific IP or network (all ports, $WAN_IFACE only)"
        echo "  unblock-ip <ip/net>       - Remove IP/network from manual blacklist"
        echo "  add-whitelist <wan|lan> <net>    - Add a trusted network, bound to that interface"
        echo "  remove-whitelist <wan|lan> <net> - Remove a network from that interface's whitelist"
        echo "  show-blocked              - Display manually blocked IPs/networks"
        echo "  show-whitelist            - Display both whitelist_lan and whitelist_wan"
        echo "  check-ip <ip>             - Check if an IP is blocked, whitelisted, and on which interface"
        echo "  check-overlaps [set]      - Report redundant/overlapping CIDR entries (default: manual_blacklist)"
        echo "  status                    - Show current ipsets, iptables rules, and config"
        echo "  reset-policy              - Reset to allow-all policy"
        echo "  save                      - Manually save current rules to disk"
        echo
        echo "Rule Priority Order:"
        echo "  1. Loopback (always allowed)"
        echo "  2. Anti-spoof: RFC1918 on $WAN_IFACE, loopback-space on any real NIC -- DROPPED"
        echo "  3. whitelist_lan (unrestricted, any port) -- ONLY via $LAN_IFACE"
        echo "  4. whitelist_wan (unrestricted, any port) -- ONLY via $WAN_IFACE"
        echo "  5. Established/related connections"
        echo "  6. GeoIP allowlist on $GEOBLOCK_TCP_PORTS/$GEOBLOCK_UDP_PORTS -- $WAN_IFACE only,"
        echo "     allow $ALLOWED_COUNTRIES, others dropped (fails OPEN if the DB is empty --"
        echo "     see status). Refreshed by geo-update.sh / geoip-update.timer."
        echo "  7. Manual IP blacklist -- $WAN_IFACE only (blocked from every port there)"
        echo "  8. Automated IP blacklists (11 threat intelligence sources) -- $WAN_IFACE only"
        echo "  9. Mail/web ports ACCEPT on both interfaces: $MAIL_WEB_PORTS"
        echo "     (port $SMTP_RELAY_PORT ungated; the rest already passed GeoIP/blacklists above)"
        echo "  10. ICMP"
        echo "  11. Everything else: DROPPED (default-deny)"
        echo
        echo "Examples:"
        echo "  $0 update                          # Full update with all protections"
        echo "  $0 block-ip 192.168.1.100          # Block specific IP manually"
        echo "  $0 add-whitelist wan 203.0.113.5   # Trust a new admin IP arriving on $WAN_IFACE"
        echo "  $0 check-ip 8.8.8.8                # Check if IP is blocked"
        echo "  $0 check-overlaps                  # Look for redundant blacklist entries"
        echo "  $0 status                          # Check current configuration"
        exit 1
        ;;
esac
SCRIPT_EOF
chmod +x /usr/local/bin/manage-netsets.sh
```

---

## `geo-update.sh` + Both systemd Timer Pairs

`geo-update.sh` is unchanged from your GeoIP box — it maintains the shared `/usr/share/xt_geoip` database format, so it works identically here with no Zimbra-specific changes needed.

```bash
cat > /usr/local/bin/geo-update.sh << 'SCRIPT_EOF'
#!/bin/bash
# geo-update.sh
# Refreshes the xt_geoip country database that manage-netsets.sh's GeoIP allowlist
# depends on. Builds into a staging directory and only swaps it into
# /usr/share/xt_geoip if the download and build both actually succeeded --
# the previous version rebuilt in place with no verification, so a failed
# download or a partial build could leave the live database empty or corrupt
# while iptables rules were still actively querying it.

set -uo pipefail

WORK_DIR="/tmp/xt_geoip_dl.$$"
STAGE_DIR="/usr/share/xt_geoip.staging.$$"
LIVE_DIR="/usr/share/xt_geoip"
LOCK_FILE="/var/run/geo-update.lock"
LOG_FILE="/var/log/geoip-update.log"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

cleanup() {
    rm -rf "$WORK_DIR" "$STAGE_DIR"
}
trap cleanup EXIT

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log_message "Another geo-update.sh run is already in progress -- exiting"
    exit 1
fi

for bin in /usr/libexec/xtables-addons/xt_geoip_dl /usr/libexec/xtables-addons/xt_geoip_build; do
    if [[ ! -x "$bin" ]]; then
        log_message "ERROR: required tool missing or not executable: $bin"
        exit 1
    fi
done

log_message "Starting GeoIP database update"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR" || { log_message "ERROR: cannot cd to $WORK_DIR"; exit 1; }

log_message "Downloading country CSV data"
if ! /usr/libexec/xtables-addons/xt_geoip_dl; then
    log_message "ERROR: xt_geoip_dl failed -- leaving existing database untouched"
    exit 1
fi

if ! compgen -G "*.csv" >/dev/null; then
    log_message "ERROR: download produced no CSV files -- leaving existing database untouched"
    exit 1
fi

log_message "Building database into staging area"
mkdir -p "$STAGE_DIR"
if ! /usr/libexec/xtables-addons/xt_geoip_build -D "$STAGE_DIR" ./*.csv; then
    log_message "ERROR: xt_geoip_build failed -- leaving existing database untouched"
    exit 1
fi

# Sanity check: staged output must be non-empty before we trust it enough to go live
staged_count=$(find "$STAGE_DIR" -mindepth 1 -type f 2>/dev/null | wc -l)
if [[ "$staged_count" -eq 0 ]]; then
    log_message "ERROR: staged build produced no output files -- leaving existing database untouched"
    exit 1
fi
log_message "Staged build looks sane ($staged_count files)"

# Drop the raw CSV from the staged tree before it goes live -- matches the original
# script's cleanup of dbip-country-lite.csv from the live dir; only the compiled
# lookup files are needed at runtime.
find "$STAGE_DIR" -maxdepth 1 -name '*.csv' -delete

log_message "Swapping staged database into place"
rm -rf "${LIVE_DIR}.previous"
if [[ -d "$LIVE_DIR" ]]; then
    mv "$LIVE_DIR" "${LIVE_DIR}.previous"
fi
mv "$STAGE_DIR" "$LIVE_DIR"
rm -rf "${LIVE_DIR}.previous"

log_message "GeoIP database updated successfully ($staged_count files live in $LIVE_DIR)"

log_message "Reloading firewall rules"
if /usr/local/bin/manage-netsets.sh reload; then
    log_message "Reload completed"
else
    log_message "WARNING: manage-netsets.sh reload exited non-zero -- check firewall state manually"
fi

log_message "Done"
SCRIPT_EOF
chmod +x /usr/local/bin/geo-update.sh
```

Two independent systemd timer pairs: one refreshes threat-intel blacklists + reapplies rules daily, the other refreshes the GeoIP country database weekly. Staggered so they never contend for the iptables lock.

```bash
cat > /etc/systemd/system/netset-manager.service << 'UNIT_EOF'
[Unit]
Description=Netset Manager (Zimbra mail storage firewall)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/manage-netsets.sh update
ExecReload=/usr/local/bin/manage-netsets.sh update
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /etc/systemd/system/netset-manager.timer << 'UNIT_EOF'
[Unit]
Description=Update netsets every day at 2:30am
Requires=netset-manager.service

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT_EOF

cat > /etc/systemd/system/geoip-update.service << 'UNIT_EOF'
[Unit]
Description=Refresh xt_geoip country database (GeoIP allowlist source data)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/geo-update.sh
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /etc/systemd/system/geoip-update.timer << 'UNIT_EOF'
[Unit]
Description=Weekly refresh of the xt_geoip country database
Requires=geoip-update.service

[Timer]
OnCalendar=Sun *-*-* 03:15:00
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
UNIT_EOF

systemctl daemon-reload
systemctl enable --now netset-manager.timer
systemctl enable --now geoip-update.timer
```

All four units pass `systemd-analyze verify` together.

---

## Deployment Steps

```bash
# 1. Run the prerequisites block first. Do NOT skip its two sanity-check lines
#    at the end -- a fresh box commonly lacks libtext-csv-xs-perl (geo-update.sh
#    build step fails without it) and /etc/ipset (nothing persists without it).
#    Both must print "OK" before you continue.

# 2. Install all four systemd units, then manage-netsets.sh and geo-update.sh

# 3. Populate the GeoIP database BEFORE the first netset update, so the GeoIP
#    rule is active from the start rather than failing open. Watch for it to
#    get past "Building database into staging area" -> "Staged build looks
#    sane (N files)" -> "GeoIP database updated successfully".
/usr/local/bin/geo-update.sh

# 4. First netset run -- downloads threat-intel lists, builds the interface-
#    bound whitelists, initializes an empty manual_blacklist. This is SLOW on
#    first run: firehol_level4 alone is ~100k entries and can take 10-15 min;
#    the whole run may take 20-25 min. Subsequent runs reuse the same sets and
#    are faster. Let it finish rather than interrupting mid-list.
/usr/local/bin/manage-netsets.sh update

# 5. Seed manual_blacklist -- deduplicated (185.236.228.0/22 already covers
#    the two /32s from your original ruleset)
for net in 185.236.228.0/22 23.94.82.0/24 23.95.86.0/24 172.245.93.0/24; do
    /usr/local/bin/manage-netsets.sh block-ip "$net"
done

# 6. Persist everything to disk, then confirm. `save` writes all ipsets plus
#    iptables.save to /etc/ipset/ (this is what survives a reboot); `status`
#    should show the GeoIP database as "Populated", not "MISSING/EMPTY".
/usr/local/bin/manage-netsets.sh save
/usr/local/bin/manage-netsets.sh status
/usr/local/bin/manage-netsets.sh check-overlaps
```

---

## Regular Operational CLI Commands

**Checking things**
```bash
manage-netsets.sh status                    # ipsets, live rules, GeoIP DB health, whitelist/blacklist contents
manage-netsets.sh check-ip <ip>             # blocked? whitelisted? which interface? subject to GeoIP?
manage-netsets.sh check-overlaps            # redundant CIDR entries in manual_blacklist
manage-netsets.sh show-whitelist            # both whitelist_lan and whitelist_wan
manage-netsets.sh show-blocked              # full manual_blacklist contents
```

**Making changes**
```bash
manage-netsets.sh block-ip <ip/net>              # add to manual_blacklist, applies immediately, warns if redundant
manage-netsets.sh unblock-ip <ip/net>            # remove from manual_blacklist
manage-netsets.sh add-whitelist wan <ip/net>     # trust a new admin/ISP IP arriving on ens4
manage-netsets.sh add-whitelist lan <ip/net>     # trust a new internal range arriving on ens3
manage-netsets.sh remove-whitelist wan <ip/net>  # revoke trust (same for lan)
manage-netsets.sh update                         # re-download threat-intel lists + rebuild whitelists + apply + save
manage-netsets.sh reload                         # re-apply current rules without re-downloading (fast)
```

**GeoIP maintenance**
```bash
geo-update.sh                                    # manual database refresh (normally weekly via geoip-update.timer)
systemctl list-timers geoip-update.timer         # when it last ran, when it runs next
journalctl -u geoip-update.service -f            # live log of a refresh in progress
tail -f /var/log/geoip-update.log                # refresh history
```

**Recovery**
```bash
manage-netsets.sh restore       # rebuild ipsets from last saved .save files, then apply
manage-netsets.sh reset-policy  # emergency allow-all -- use if locked out and you have console access
```

**Underlying system commands**
```bash
iptables -L INPUT -n -v --line-numbers
ipset list whitelist_wan
systemctl list-timers netset-manager.timer geoip-update.timer
tail -f /var/log/netset-manager.log
ss -tn state established '( dport = :25 or dport = :587 or dport = :993 )'
```

## Day-2 Ops & Gotchas

- **Two fresh-box dependencies the xtables-addons packages don't pull in.** On first deploy you'll likely hit both of these — the prerequisites block now covers them, but worth knowing what the symptoms look like:
  - `Can't locate Text/CSV_XS.pm` during `geo-update.sh` means `libtext-csv-xs-perl` is missing. The script's staging design contains this cleanly: the build fails, the *existing* database is left untouched (no outage), and it logs `ERROR: xt_geoip_build failed`. Install the package and re-run.
  - `/etc/ipset/*.save: No such file or directory` during `update` means `/etc/ipset` doesn't exist. This one is non-fatal by nature: the sets still load into the kernel and `apply_all_rules` builds live rules from them, so the firewall is *working* — only the on-disk backups (what `restore` reads at boot) fail to write. `mkdir -p /etc/ipset`, re-run `update`, then `save`.
- **Run `geo-update.sh` before the first `update`.** Otherwise the GeoIP rule fails open (correctly, safely) until the timer's first Sunday run — fine, just not the protection you're expecting in the meantime.
- **Test from a whitelisted session before you're fully committed** — same warning as last pass, doubly true now that GeoIP is layered on top. If you administer this box from somewhere outside `whitelist_wan`/`whitelist_lan` *and* outside `ALLOWED_COUNTRIES`, you could lock yourself out of the geo-gated ports specifically. `reset-policy` is the escape hatch if you have console access.
- **Revisit the port-25 decision if your Outlook/EOP routing ever changes.** If you switch to a setup with a fixed, known set of relay IPs, geo-gating 25 becomes safe and you'd get one more layer of protection on the busiest port. Worth a re-check if that routing changes.
- **`add-whitelist`/`remove-whitelist` require the `wan`/`lan` argument now** — this is a behavior change from your reference script's single-set version, made necessary by the interface split. Scripts or muscle memory built around the old two-argument form will need the interface added.
- **Same fail-open logic as your GeoIP box**: an empty `/usr/share/xt_geoip` skips the GeoIP rule rather than dropping all non-whitelisted traffic. `status` shows the database's populated/missing state at a glance.
