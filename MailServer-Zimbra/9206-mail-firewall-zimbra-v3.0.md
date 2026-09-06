# Public Mail Server + WireGuard — Netset Firewall

A fourth variant for a box with **no LAN interface** — just loopback and one public NIC (`ens19`, single IP `157.15.61.152`) — plus two WireGuard tunnels (`wg0`, `wg1`) that are **fully trusted and never filtered**. Same Zimbra mail-port set and GeoIP allowlist as your other mail box.

### Contents
- How this differs from the LAN-split build
- WireGuard handling (the interesting part)
- Rule precedence
- Prerequisites
- `manage-netsets.sh` (complete file)
- `geo-update.sh` + systemd units
- Deployment steps
- Regular operational CLI commands
- Day-2 ops & gotchas

---

## How This Differs From the LAN-Split Build

- **No `ens3`/LAN.** Trust doesn't split across interfaces here — there's one public NIC and loopback, nothing else. So the whitelist is a single `whitelist_networks` set (not `whitelist_lan`/`whitelist_wan`), and `add-whitelist`/`remove-whitelist` go back to a single argument.
- **Anti-spoof is simpler but still present.** RFC1918/loopback source addresses arriving on `ens19` are dropped — there's no legitimate internal-interface exception to carve out, because there's no internal interface. (WireGuard's own RFC1918 tunnel addresses arrive on `wg0`/`wg1`, which are accepted before the anti-spoof rules ever apply, so tunnel traffic is untouched.)
- **WireGuard tunnels added as a fully-trusted zone** — the new part, below.
- Everything else — GeoIP allowlist, port-25-ungated, threat-intel blacklists, fail-open safety, `check-overlaps` — carries over unchanged.

---

## WireGuard Handling

You asked for the tunnels to never be filtered at all. That's implemented as three things:

**1. Both tunnel interfaces fully trusted, first thing after loopback.** For each of `wg0`/`wg1`, the ruleset accepts all INPUT (traffic terminating on this box via the tunnel) and all FORWARD in both directions (traffic routed *through* the tunnel — `-i wgN` and `-o wgN`). These rules sit immediately after the loopback accept and before any filtering, so nothing downstream — not GeoIP, not a blacklist, not the default-deny — can ever touch tunnel traffic. This is the core of "don't block anything on wg0/wg1."

**2. The tunnels' own listen ports on the public side, auto-detected.** For a peer to *reach* the tunnel, its handshake packets hit a UDP port on `ens19` first (before they're inside the tunnel). Those ports have to be open. You said peers are already connected and you don't know/don't want to change the ports — so the script **reads them from the running WireGuard config** (`wg show all dump`) at apply-time and opens exactly those, whatever they are. Nothing is hardcoded; the ports can be anything and the script adapts. If you ever change a listen port, a `reload` picks up the new one automatically.

The detection is precise: in `wg`'s dump output, an interface's own line carries its listen port as a bare number in field 4, while peer lines carry an `IP:port` *endpoint* in that field — so filtering for a field that's purely digits (`/^[0-9]+$/`) cleanly selects only the listen ports, never a peer endpoint. Verified against real dump output including the mixed interface+peer case and a non-standard port.

**3. Graceful fallback.** If `wg` isn't installed, or no tunnel is up at apply-time, port detection returns nothing, the script logs that clearly, and opens no UDP port — but the interface-trust rules (step 1) still apply regardless, because they come from a static `WG_IFACES` array, not from detection. And an already-established peer keeps flowing through the `RELATED,ESTABLISHED` accept even in that window; only a *new* handshake would need the port. Tested all of this: tunnels-up, tunnels-down, and `wg`-binary-absent all behave correctly.

`show-wg-ports` and the `status` output both report which ports were detected and opened, so you can confirm at a glance.

---

## Rule Precedence

```
1.  Loopback                                                        -> ACCEPT
2.  WireGuard wg0/wg1 -- FULLY TRUSTED (INPUT + FORWARD both ways)  -> ACCEPT
3.  WireGuard UDP listen port(s) on ens19 (auto-detected)           -> ACCEPT
4.  Anti-spoof (RFC1918/loopback source on ens19)                   -> DROP
5.  whitelist_networks (unrestricted, any port) -- ens19            -> ACCEPT
6.  Established/related connections                                 -> ACCEPT
7.  GeoIP allowlist on GEOBLOCK ports -- ens19 only                 -> DROP (non-allowed countries)
8.  Manual IP blacklist -- ens19 only                               -> DROP
9.  Threat-intel blacklists (11 sources) -- ens19 only              -> DROP
10. Mail/web ports (25 + GEOBLOCK_TCP_PORTS)                        -> ACCEPT
11. ICMP                                                            -> ACCEPT
12. Everything else                                                 -> DROP (default-deny)
```

Traced against the actual generated `iptables` sequence with tunnels up (ports 51820 + a non-standard 51899 correctly detected and opened), tunnels down, and `wg` absent — plus GeoIP database populated and empty. Port 25 lands in the final ACCEPT ungated; the GeoIP rules are `ens19`-only; the WireGuard trust rules always appear regardless of detection.

---

## Prerequisites

Includes the two dependencies a fresh box tends to lack (`libtext-csv-xs-perl` for the GeoIP build, and the `/etc/ipset` directory), plus the sanity checks that surfaced from live deploys.

```bash
apt update
apt install -y iptables ipset curl

# xtables-addons: kernel module (xt_geoip) + xt_geoip_dl/xt_geoip_build helpers
apt install -y xtables-addons-common xtables-addons-dkms "linux-headers-$(uname -r)"

# xt_geoip_build parses CSVs with Text::CSV_XS -- not pulled in by the packages
# above on Ubuntu; without it geo-update.sh fails at the build step.
apt install -y libtext-csv-xs-perl

dkms status | grep -i xtables || echo "check 'dkms status' output above for build errors"

modprobe ip_set xt_set nf_conntrack xt_geoip 2>&1 | grep -v "^$" || echo "modules load cleanly"
lsmod | grep -E "^(ip_set|xt_set|nf_conntrack|xt_geoip)"

# Directory the script saves ipsets into (what `restore` reads at boot). The
# script does not create it; it must exist before the first `update`.
mkdir -p /etc/ipset

systemctl disable netfilter-persistent 2>/dev/null || echo "netfilter-persistent not present as a service -- nothing to disable"

cat > /etc/sysctl.d/99-disable-ipv6.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf

# --- Sanity check before proceeding ---
perl -MText::CSV_XS -e 'print "Text::CSV_XS OK\n"' || echo "MISSING: run 'apt install -y libtext-csv-xs-perl'"
[ -d /etc/ipset ] && echo "/etc/ipset OK" || echo "MISSING: run 'mkdir -p /etc/ipset'"
command -v wg >/dev/null && echo "wg present" || echo "NOTE: 'wg' not found -- WireGuard port auto-detection will no-op (tunnel trust rules still apply)"
```

**IPv6 note for WireGuard:** disabling IPv6 system-wide (above) is consistent with your other boxes and doesn't affect WireGuard — WG tunnels run over IPv4 here, and the tunnel interfaces themselves carry whatever inner protocol you've configured regardless of the host's IPv6 stack. If any of your WG *peers* connect to this box over IPv6, tell me and we'll leave IPv6 up for the WG listener specifically.

---

## `manage-netsets.sh` (complete file)

`bash -n` + `shellcheck` clean (same two pre-existing `SC2155` style warnings, nothing new). Rule sequence generated against mocked `iptables`/`ipset`/`wg` and verified line-by-line for: tunnel-trust-first ordering, dynamic listen-port detection (standard and non-standard ports), the wg-down and wg-absent fallbacks, GeoIP populated/empty, and the single-set whitelist add/remove paths.

```bash
cat > /usr/local/bin/manage-netsets.sh << 'SCRIPT_EOF'
#!/bin/bash

# Netset management script -- public-only mail server with WireGuard tunnels
# Default-deny posture: only loopback, the WireGuard tunnels, whitelisted
# admin/ISP ranges, and the mail/web service ports are reachable; everything
# else is dropped.
#
# This box has NO separate LAN interface -- just loopback and one public NIC:
#   ens19 = public/WAN  -- internet-facing, single public IP 157.15.61.152,
#                          mail/web ports live here, GeoIP allowlist applies here
#   wg0, wg1            -- WireGuard tunnels, FULLY TRUSTED (accept everything,
#                          in and out, plus the tunnels' own forwarded traffic).
#                          The UDP listen ports that peers dial in to on ens19
#                          are auto-detected from the running wg config at
#                          apply-time, so this works no matter what they're set
#                          to and never disturbs already-connected peers.
IPSET_DIR="/etc/ipset"
TEMP_DIR="/tmp/netsets"
LOG_FILE="/var/log/netset-manager.log"

WAN_IFACE="ens19"

# WireGuard interfaces to trust unconditionally. The '+' after 'wg' is an
# iptables wildcard, but we also enumerate explicitly for the trusted-accept
# rules so intent is unambiguous. Adjust if you add/rename tunnels.
WG_IFACES=("wg0" "wg1")

# Port that must stay open to literally anyone in any country: inbound SMTP
# has to accept from arbitrary remote MTAs as well as any globally-distributed
# relay pool (e.g. Microsoft EOP). Deliberately excluded from the GeoIP gate.
SMTP_RELAY_PORT="25"

# --- GeoIP Configuration (ALLOWLIST) ---
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
# GEOBLOCK_TCP_PORTS. This is what gets the final global ACCEPT rule once
# whitelist/blacklist/GeoIP have all had their say.
MAIL_WEB_PORTS="${SMTP_RELAY_PORT},${GEOBLOCK_TCP_PORTS}"

# Global list of all managed ipsets
ALL_NETSETS=("firehol_level1" "firehol_level2" "firehol_level3" "firehol_level4" "spamhaus_drop" "ci_badguys" "et_bl1" "et_bl2" "bl_de1" "bl_agr" "crowdsec_bl" "whitelist_networks" "manual_blacklist")

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

# Function to create and load the whitelist. Single set here (no LAN/WAN split)
# since every trusted source reaches this box over the one public interface or
# via loopback -- there is no separate internal NIC to bind trust to.
create_whitelist() {
    local name="whitelist_networks"
    log_message "Creating whitelist: $name"

    ipset create "$name" hash:net hashsize 1024 maxelem 10000 -exist
    ipset flush "$name"

    local count=0

    # Trusted networks get unrestricted access on any port, bypassing GeoIP and
    # every blacklist. Put admin/ISP ranges here that must reach SSH / Zimbra
    # admin / anything outside the public mail-port set. 127.0.0.0/8 is handled
    # by the dedicated `-i lo` rule, not here.
    local hardcoded_nets=(
        "157.15.61.152/32"      # This box's own public IP -- hairpin-NAT safety
        "157.15.61.0/24"        # Admin/ISP range (adjust to your real admin nets)
        "103.7.248.0/24"        # Admin/ISP range
        "103.169.94.0/24"       # Admin/ISP range
        "8.8.8.8/32"            # Google DNS
        "8.8.4.4/32"            # Google DNS
        "1.1.1.1/32"            # Cloudflare DNS
        "1.0.0.1/32"            # Cloudflare DNS
        "9.9.9.9/32"            # Quad9 DNS
    )

    for network in "${hardcoded_nets[@]}"; do
        if ipset add "$name" "$network" 2>/dev/null; then
            ((count++))
        fi
    done

    ipset save "$name" > "$IPSET_DIR/$name.save"
    log_message "Created whitelist with $count entries"
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

# Function to check for redundant/overlapping CIDR entries within a set.
# Read-only: reports, never modifies.
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

# Function to detect the UDP listen ports WireGuard is actually using, so we
# can open them on the public interface without hardcoding anything. Reads the
# running config via `wg show all dump` (interface lines carry the listen-port
# in field 4 as a bare number; peer lines carry an IP:port endpoint there, so
# the /^[0-9]+$/ filter cleanly selects only interface listen-ports). Prints a
# space-separated list of ports, or nothing if wg isn't available/up.
detect_wg_listen_ports() {
    command -v wg >/dev/null 2>&1 || return 0
    wg show all dump 2>/dev/null | awk -F'\t' '$4 ~ /^[0-9]+$/ {print $4}' | sort -un
}

# Function to open the WireGuard UDP listen ports on the public interface.
# Called from apply_all_rules. Falls back gracefully (opens nothing, logs it)
# if no ports can be detected -- an already-established peer keeps working via
# the conntrack ESTABLISHED rule regardless, but new handshakes need the port.
open_wg_listen_ports() {
    local ports
    ports=$(detect_wg_listen_ports)

    if [[ -z "$ports" ]]; then
        log_message "WireGuard: no listen ports detected (wg not running, or no interfaces up) -- not opening any UDP port. Established peers still flow via ESTABLISHED; new handshakes need the port open."
        return 0
    fi

    local p
    for p in $ports; do
        iptables -A INPUT -i "$WAN_IFACE" -p udp --dport "$p" -j ACCEPT
        log_message "WireGuard: opened UDP listen port $p on $WAN_IFACE"
    done
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

    # 2. WireGuard tunnels -- FULLY TRUSTED, no filtering whatsoever. Accept
    #    everything arriving on the tunnel interfaces, and accept anything the
    #    tunnels forward (INPUT for traffic terminating here, FORWARD for
    #    traffic routed through). This is deliberately the very first thing
    #    after loopback so nothing below can ever interfere with tunnel traffic.
    local wg
    for wg in "${WG_IFACES[@]}"; do
        iptables -A INPUT -i "$wg" -j ACCEPT
        iptables -A FORWARD -i "$wg" -j ACCEPT
        iptables -A FORWARD -o "$wg" -j ACCEPT
        log_message "WireGuard: fully trusting interface $wg (INPUT + FORWARD both directions)"
    done

    # 3. Open the WireGuard UDP listen port(s) on the public interface so peers
    #    can (re)handshake. Auto-detected from the running wg config; never
    #    hardcoded, so already-connected peers are never disturbed.
    open_wg_listen_ports

    # 4. Anti-spoof / martian filtering on the PUBLIC interface. A packet
    #    claiming an RFC1918 or loopback source arriving on ens19 cannot be
    #    legitimate public traffic -- drop it. (WireGuard's own RFC1918 tunnel
    #    IPs arrive on wg0/wg1, already accepted above, so this doesn't touch
    #    them.)
    iptables -A INPUT -i "$WAN_IFACE" -s 127.0.0.0/8 -j DROP
    iptables -A INPUT -i "$WAN_IFACE" -s 10.0.0.0/8 -j DROP
    iptables -A INPUT -i "$WAN_IFACE" -s 172.16.0.0/12 -j DROP
    iptables -A INPUT -i "$WAN_IFACE" -s 192.168.0.0/16 -j DROP

    # 5. Whitelist -- unrestricted access on any port, bypasses GeoIP and every
    #    blacklist below. Scoped to the public interface (the only place these
    #    source IPs legitimately arrive; loopback and wg are already handled).
    if ipset list "whitelist_networks" >/dev/null 2>&1; then
        iptables -A INPUT -i "$WAN_IFACE" -m set --match-set "whitelist_networks" src -j ACCEPT
        log_message "Applied whitelist rules (bound to $WAN_IFACE)"
    fi

    # 6. Established/related early -- short-circuits the bulk of ongoing
    #    sessions before they have to walk GeoIP and the ipset blacklists
    iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

    # 7. GeoIP allowlist -- ahead of the blacklists: one geoip check rejects
    #    most non-allowed-country traffic before walking 11 ipset lookups.
    setup_geoip_rules

    # 8. Manual blacklist -- public interface only
    if ipset list "manual_blacklist" >/dev/null 2>&1; then
        iptables -A INPUT -i "$WAN_IFACE" -m set --match-set "manual_blacklist" src -j DROP
        log_message "Applied manual blacklist rules (bound to $WAN_IFACE)"
    fi

    # 9. Threat-intel blacklists -- public interface only
    local blacklists=("firehol_level1" "firehol_level2" "firehol_level3" "firehol_level4" "spamhaus_drop" "ci_badguys" "et_bl1" "et_bl2" "bl_de1" "bl_agr" "crowdsec_bl")

    for blacklist in "${blacklists[@]}"; do
        if ipset list "$blacklist" >/dev/null 2>&1; then
            iptables -A INPUT -i "$WAN_IFACE" -m set --match-set "$blacklist" src -j DROP
        fi
    done

    # 10. Mail/web ports -- covers SMTP_RELAY_PORT (25, ungated) plus everything
    #     in GEOBLOCK_TCP_PORTS (already GeoIP-filtered above; this ACCEPT is
    #     what admits allowed-country traffic that survived every check above).
    iptables -A INPUT -p tcp -m multiport --dports "$MAIL_WEB_PORTS" -j ACCEPT
    log_message "Opened mail/web ports: $MAIL_WEB_PORTS"

    # 11. ICMP
    iptables -A INPUT -p icmp -j ACCEPT

    # 12. Default deny -- anything not matched above is dropped. Policy stays
    #     ACCEPT and this is an explicit trailing rule instead of `-P INPUT
    #     DROP`, so a script that errors out partway through fails open rather
    #     than locking you out. FORWARD defaults to DROP too, but WireGuard's
    #     FORWARD accepts (step 2) sit above this and still apply.
    iptables -A FORWARD -j DROP
    iptables -A INPUT -j DROP

    log_message "All firewall rules applied successfully"
}

# Function to set up the GeoIP country ALLOWLIST on the configured ports.
# WAN_IFACE only. Fails OPEN if the database is empty/missing (skips the rule
# rather than dropping everyone, since xt_geoip treats an unmappable IP as
# "no match" which the negated allowlist would otherwise drop).
setup_geoip_rules() {
    log_message "Setting up GeoIP allowlist on service ports (allow: $ALLOWED_COUNTRIES)"

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

# Function to add IP/subnet to the whitelist
add_whitelist() {
    local network="$1"

    if [[ -z "$network" ]]; then
        echo "Usage: $0 add-whitelist <network>"
        echo "Example: $0 add-whitelist 203.0.113.5/32"
        exit 1
    fi

    if [[ ! "$network" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        log_message "Invalid network format: $network"
        echo "Error: Invalid network format: $network"
        exit 1
    fi

    ipset create "whitelist_networks" hash:net hashsize 1024 maxelem 10000 -exist

    if ipset add "whitelist_networks" "$network" 2>/dev/null; then
        ipset save "whitelist_networks" > "$IPSET_DIR/whitelist_networks.save"
        log_message "Added $network to whitelist"
        echo "Successfully added $network to whitelist"
        apply_all_rules
    else
        log_message "Failed to add $network to whitelist (may already exist)"
        echo "Network $network already exists in whitelist or invalid format"
    fi
}

# Function to remove IP/subnet from the whitelist
remove_whitelist() {
    local network="$1"

    if [[ -z "$network" ]]; then
        echo "Usage: $0 remove-whitelist <network>"
        exit 1
    fi

    if ipset test "whitelist_networks" "$network" 2>/dev/null; then
        ipset del "whitelist_networks" "$network"
        ipset save "whitelist_networks" > "$IPSET_DIR/whitelist_networks.save"
        log_message "Removed $network from whitelist"
        echo "Successfully removed $network from whitelist"
        apply_all_rules
    else
        log_message "Network $network not found in whitelist"
        echo "Network $network not found in whitelist"
    fi
}

# Function to show whitelist
show_whitelist() {
    echo "Current Whitelist Networks (bound to $WAN_IFACE):"
    if ipset list "whitelist_networks" >/dev/null 2>&1; then
        ipset list "whitelist_networks" | grep -E '^[0-9]+\.' | sort -V
    else
        echo "No whitelist configured"
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

    if ipset test "whitelist_networks" "$ip" 2>/dev/null; then
        echo "✓ WHITELISTED - Unrestricted access on any port via $WAN_IFACE (bypasses GeoIP + all blocks)"
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
        echo "Note: port $SMTP_RELAY_PORT (SMTP) is open to this IP unconditionally -- no GeoIP"
        echo "      gate, since inbound mail must accept from anywhere. Ports $GEOBLOCK_TCP_PORTS"
        echo "      require this IP's country to be in $ALLOWED_COUNTRIES. All other ports"
        echo "      are DROPPED unless this IP is whitelisted. (Traffic arriving over the"
        echo "      WireGuard tunnels wg0/wg1 bypasses all of this -- fully trusted.)"
    fi
}

# -----------------------------------------------------------------------------
## 2. Command Handlers
# -----------------------------------------------------------------------------

# Function to handle the `update` command
handle_update() {
    log_message "Starting netset update"

    create_whitelist
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
        add_whitelist "$2"
        ;;
    "remove-whitelist")
        remove_whitelist "$2"
        ;;
    "show-blocked")
        show_manual_blacklist
        ;;
    "show-whitelist")
        show_whitelist
        ;;
    "check-ip")
        check_ip_status "$2"
        ;;
    "check-overlaps")
        check_overlaps "${2:-manual_blacklist}"
        ;;
    "show-wg-ports")
        ports=$(detect_wg_listen_ports)
        if [[ -n "$ports" ]]; then
            echo "WireGuard listen ports currently detected on the running config:"
            for p in $ports; do echo "  UDP $p (opened on $WAN_IFACE)"; done
        else
            echo "No WireGuard listen ports detected (wg not running, or no interfaces up)."
        fi
        ;;
    "status")
        echo "=== Netset Firewall Status (public mail server + WireGuard) ==="
        echo
        echo "Public interface: $WAN_IFACE (157.15.61.152)"
        echo "WireGuard (fully trusted): ${WG_IFACES[*]}"
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
        echo
        echo "WireGuard listen ports (auto-detected, opened on $WAN_IFACE):"
        wg_ports=$(detect_wg_listen_ports)
        if [[ -n "$wg_ports" ]]; then
            for p in $wg_ports; do echo "  UDP $p"; done
        else
            echo "  <none detected -- wg not running or no interfaces up>"
        fi
        echo
        echo "GeoIP database:"
        geoip_status_count=$(find /usr/share/xt_geoip -mindepth 1 -type f 2>/dev/null | wc -l)
        if [[ "$geoip_status_count" -gt 0 ]]; then
            geoip_newest=$(find /usr/share/xt_geoip -mindepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
            echo "  Populated -- $geoip_status_count files, newest: ${geoip_newest:-unknown}"
        else
            echo "  MISSING/EMPTY -- GeoIP allowlist is NOT being applied (failing open). Run geo-update.sh."
        fi
        echo
        show_whitelist
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
        echo "Usage: $0 {update|reload|restore|block-ip|unblock-ip|add-whitelist|remove-whitelist|show-blocked|show-whitelist|check-ip|check-overlaps|show-wg-ports|status|reset-policy|save}"
        echo
        echo "Commands:"
        echo "  update                    - Download and apply all blacklists, then save"
        echo "  reload                    - Re-apply existing rules, then save"
        echo "  restore                   - Restore ipsets from saved files, then save"
        echo "  block-ip <ip/net>         - Manually block specific IP or network ($WAN_IFACE only)"
        echo "  unblock-ip <ip/net>       - Remove IP/network from manual blacklist"
        echo "  add-whitelist <ip/net>    - Add a trusted network (unrestricted, any port)"
        echo "  remove-whitelist <ip/net> - Remove a network from the whitelist"
        echo "  show-blocked              - Display manually blocked IPs/networks"
        echo "  show-whitelist            - Display current whitelist"
        echo "  check-ip <ip>             - Check if an IP is blocked, whitelisted, or geo-gated"
        echo "  check-overlaps [set]      - Report redundant/overlapping CIDR entries"
        echo "  show-wg-ports             - Show the WireGuard listen ports currently auto-detected"
        echo "  status                    - Show current ipsets, iptables rules, and config"
        echo "  reset-policy              - Reset to allow-all policy"
        echo "  save                      - Manually save current rules to disk"
        echo
        echo "Rule Priority Order:"
        echo "  1. Loopback (always allowed)"
        echo "  2. WireGuard tunnels ${WG_IFACES[*]} -- FULLY TRUSTED (INPUT + FORWARD both ways)"
        echo "  3. WireGuard UDP listen port(s) on $WAN_IFACE -- auto-detected, opened for handshakes"
        echo "  4. Anti-spoof: RFC1918/loopback source on $WAN_IFACE -- DROPPED"
        echo "  5. Whitelist (unrestricted, any port) -- via $WAN_IFACE"
        echo "  6. Established/related connections"
        echo "  7. GeoIP allowlist on $GEOBLOCK_TCP_PORTS/$GEOBLOCK_UDP_PORTS -- $WAN_IFACE only,"
        echo "     allow $ALLOWED_COUNTRIES (fails OPEN if DB empty -- see status)"
        echo "  8. Manual IP blacklist -- $WAN_IFACE only"
        echo "  9. Automated IP blacklists (11 sources) -- $WAN_IFACE only"
        echo "  10. Mail/web ports: $MAIL_WEB_PORTS (port $SMTP_RELAY_PORT ungated)"
        echo "  11. ICMP"
        echo "  12. Everything else: DROPPED (default-deny)"
        echo
        echo "Examples:"
        echo "  $0 update                          # Full update with all protections"
        echo "  $0 show-wg-ports                   # Confirm which WireGuard ports are open"
        echo "  $0 add-whitelist 203.0.113.5/32    # Trust a new admin IP"
        echo "  $0 check-ip 8.8.8.8                # Check an IP's status"
        echo "  $0 status                          # Check current configuration"
        exit 1
        ;;
esac
SCRIPT_EOF
chmod +x /usr/local/bin/manage-netsets.sh
```

---

## `geo-update.sh` + systemd Units

`geo-update.sh` is unchanged from your other boxes (same shared `/usr/share/xt_geoip` database).

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

The `netset-manager.service` is ordered `After=` the WireGuard units so the tunnels exist when rules first apply at boot (though the auto-detection + reload means it self-corrects even if ordering slips):

```bash
cat > /etc/systemd/system/netset-manager.service << 'UNIT_EOF'
[Unit]
Description=Netset Manager (public mail server + WireGuard firewall)
After=network.target wg-quick@wg0.service wg-quick@wg1.service
Wants=network.target

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

All four units pass `systemd-analyze verify`. (The `After=wg-quick@...` reference doesn't require those units to exist — if your tunnels come up via a different mechanism, systemd just ignores the ordering hint.)

---

## Deployment Steps

```bash
# 1. Run the prerequisites block, including its sanity checks -- confirm
#    Text::CSV_XS OK, /etc/ipset OK, and note the wg presence line.

# 2. Install all four systemd units, then manage-netsets.sh and geo-update.sh.

# 3. Confirm WireGuard is up and note its listen ports BEFORE applying, so you
#    can verify the firewall opens the right ones.
wg show
/usr/local/bin/manage-netsets.sh show-wg-ports    # will say "none" until rules run, that's fine

# 4. Populate the GeoIP database before the first netset update.
/usr/local/bin/geo-update.sh

# 5. First netset run (SLOW -- firehol_level4 alone is ~100k entries, whole run
#    can take 20-25 min). Let it finish.
/usr/local/bin/manage-netsets.sh update

# 6. Persist and confirm. Check that show-wg-ports now lists your actual tunnel
#    ports, and that WireGuard peers are still connected (handshakes recent).
/usr/local/bin/manage-netsets.sh save
/usr/local/bin/manage-netsets.sh status
/usr/local/bin/manage-netsets.sh show-wg-ports
wg show    # confirm peers still handshaking after rules applied
```

---

## Regular Operational CLI Commands

**Checking things**
```bash
manage-netsets.sh status                    # ipsets, live rules, WG ports, GeoIP DB health, whitelist/blacklist
manage-netsets.sh show-wg-ports             # which WireGuard listen ports are detected & opened right now
manage-netsets.sh check-ip <ip>             # blocked? whitelisted? geo-gated?
manage-netsets.sh check-overlaps            # redundant CIDR entries in manual_blacklist
manage-netsets.sh show-whitelist            # current whitelist
manage-netsets.sh show-blocked              # current manual_blacklist
wg show                                     # WireGuard peer/handshake status (the source of truth for tunnels)
```

**Making changes**
```bash
manage-netsets.sh block-ip <ip/net>         # add to manual_blacklist, applies immediately, warns if redundant
manage-netsets.sh unblock-ip <ip/net>       # remove from manual_blacklist
manage-netsets.sh add-whitelist <ip/net>    # trust a new admin/ISP IP (unrestricted, any port)
manage-netsets.sh remove-whitelist <ip/net> # revoke trust
manage-netsets.sh update                    # re-download threat-intel lists + rebuild whitelist + apply + save
manage-netsets.sh reload                    # re-apply current rules (also re-detects WG ports) without re-downloading
```

**GeoIP maintenance**
```bash
geo-update.sh                               # manual DB refresh (normally weekly via geoip-update.timer)
systemctl list-timers geoip-update.timer
tail -f /var/log/geoip-update.log
```

**Recovery**
```bash
manage-netsets.sh restore       # rebuild ipsets from last saved .save files, then apply
manage-netsets.sh reset-policy  # emergency allow-all -- use if locked out and you have console access
```

**Underlying system commands**
```bash
iptables -L INPUT -n -v --line-numbers
iptables -L FORWARD -n -v --line-numbers    # confirm the wg FORWARD accepts + default DROP
wg show all dump                            # raw WG state (what the port auto-detection reads)
tail -f /var/log/netset-manager.log
```

## Day-2 Ops & Gotchas

- **WireGuard is trusted at the interface level — that trust is total.** Anything that arrives via `wg0`/`wg1`, or is routed through them, is accepted unconditionally. That's exactly what you asked for, but it means the security boundary for tunnel traffic lives entirely in WireGuard's own peer authentication (keys) and your peers' behaviour — the firewall does nothing to it. Worth keeping in mind: a compromised peer has an unfiltered path here.
- **If you change a WireGuard listen port**, just run `manage-netsets.sh reload` — it re-detects and opens the new port, and the daily timer would catch it anyway. No manual firewall edit needed. `show-wg-ports` confirms what's currently open.
- **If you add a third tunnel** (`wg2`, etc.), add it to the `WG_IFACES=("wg0" "wg1")` array near the top of the script and `reload`. The listen-port detection already covers all interfaces automatically; only the interface-trust array is a fixed list.
- **`After=wg-quick@wg0.service` assumes wg-quick manages your tunnels.** If they come up via systemd-networkd, a container, or something else, that ordering hint is harmless but inert — the auto-detect-and-reload design means rules self-correct on the next `reload`/timer regardless of boot ordering. If you want tight boot ordering under a different tunnel manager, tell me what brings them up and I'll adjust the `After=`.
- **Two fresh-box dependencies**, same as the other boxes: `libtext-csv-xs-perl` (GeoIP build fails without it, but leaves the existing DB untouched) and `/etc/ipset` (missing → rules still apply live, only persistence fails). Both are in the prerequisites now.
- **Run `geo-update.sh` before the first `update`** so the GeoIP layer is live from the start rather than failing open until the first Sunday timer run.
- **This box has no SSH port in the service-port set** — if you administer it over SSH from outside your whitelisted ranges *and* outside `ALLOWED_COUNTRIES`, confirm your admin range is in the whitelist first, or reach it over a WireGuard tunnel (which bypasses all filtering). `reset-policy` from console is the escape hatch.
