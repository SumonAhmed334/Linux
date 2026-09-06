#!/bin/bash
#==============================================================================
# manage-netsets.sh  --  v4  (adapted for mail.sumonahmed.xyz / fiberathome.net
#                          single-NIC host, post-ransomware incident 29 Aug 2026)
#
# Netset / firewall management -- Zimbra mail storage server
#
# Default-deny posture: only loopback, whitelisted ranges, and the mail/web
# service ports are reachable; everything else is dropped.
#
# HOST TOPOLOGY (v4 change from v3):
#   This box has a SINGLE network interface -- ens18 -- carrying the public
#   IP 103.7.248.5/28. There is no separate office-LAN NIC, so the v3 concept
#   of a trusted LAN_IFACE distinct from WAN_IFACE does not apply here.
#   WAN_IFACE is set to ens18 and LAN_IFACE is left empty; every rule that
#   used to be LAN-only is skipped (guarded on LAN_IFACE being non-empty)
#   rather than silently binding to the same interface as WAN, which would
#   have made whitelist_lan and the RFC1918 anti-spoof drop fight over the
#   same NIC. Trust for administrative access is carried entirely by public
#   source IP ranges in ADMIN_NETS / whitelist_wan, not by which interface
#   traffic arrives on.
#
#   NOTE: v3's ADMIN_NETS included 192.168.77.0/24 (a private range, presumed
#   to be an office-LAN or VPN-client subnet reachable only via the old
#   LAN_IFACE=ens3). That entry has been REMOVED here: on a single public NIC,
#   the anti-spoof step (RFC1918-on-WAN-DROP) would silently discard that
#   traffic before it ever reached the admin-ports ACCEPT rule, since there
#   is only one interface now and it's treated as WAN. If you actually need
#   admin access from a private range (e.g. a Pritunl VPN client subnet),
#   that traffic needs to terminate as a real interface on this host (e.g. a
#   VPN tun/wg interface) with its own trust rule -- add it back explicitly
#   with an -i <vpn_iface> scoped rule rather than re-adding it to ADMIN_NETS
#   as a bare source IP.
#
#------------------------------------------------------------------------------
# CHANGES CARRIED FROM v2/v3 (still all correct and in force)
#------------------------------------------------------------------------------
# [BUG-1 / CRITICAL -- silently dropping inbound mail]
#   Port 25 must never sit in the GeoIP-gated list; foreign MTAs need to
#   deliver mail from any country. It is deliberately excluded here.
#
# [BUG-2 / HIGH -- anti-spoof rule inverted]
#   A packet claiming a loopback (127.0.0.0/8) source on a REAL NIC is
#   spoofed and must be DROPped; only genuine `-i lo` traffic is trusted.
#
# [BUG-3 / HIGH -- anti-spoof disabled]
#   RFC1918 + link-local + multicast/reserved space arriving on the public
#   interface is DROPped (martian filtering).
#
# [NEW] Admin ports (SSH, 7071 admin console, 8443 mailboxd HTTPS) reachable
#       ONLY from ADMIN_NETS, never from the whole country/internet.
# [NEW] Brute-force rate limiting (hashlimit) on SMTP/submission/IMAP/POP/SSH.
# [NEW] Optional egress filtering -- blocks malware payload download and the
#       data exfiltration channel used in the 29 Aug incident.
# [NEW] Drop logging into a dedicated chain, rate-limited.
# [NEW] IPv6 lockdown (estate standard is IPv4-only).
# [NEW] `reload-safe` : auto-rollback if you lose your session applying rules.
# [NEW] `verify` command -- self-check of ruleset sanity.
# [NEW] `listeners` command -- audits live sockets against policy, flags any
#       Zimbra/infra service listening on 0.0.0.0 that should be on loopback
#       (this is what the 29 Aug netstat inventory found: memcached, rpcbind,
#       LMTP, milter, nginx lookup/auth, mailboxd IMAPS/POP3S backends).
# [NEW] Explicit iptables binary selection (legacy per estate standard).
#==============================================================================

set -uo pipefail

IPSET_DIR="/etc/ipset"
TEMP_DIR="/tmp/netsets"
LOG_FILE="/var/log/netset-manager.log"
ROLLBACK_FILE="/var/backups/iptables-rollback.rules"

# Single-NIC host: ens18 carries the public IP 103.7.248.5/28 and is treated
# as WAN. LAN_IFACE is intentionally empty -- there is no separate trusted
# physical LAN segment on this box. Every rule that depended on a distinct
# LAN_IFACE is skipped when LAN_IFACE is empty (search for `-n "$LAN_IFACE"`).
WAN_IFACE="ens18"
LAN_IFACE=""

# Estate standard is iptables-legacy. Fall back to iptables if legacy is absent
# so the script still runs on a host that has migrated to nft.
if command -v iptables-legacy >/dev/null 2>&1; then
    IPT="iptables-legacy"; IPT_SAVE="iptables-legacy-save"; IPT_RESTORE="iptables-legacy-restore"
else
    IPT="iptables";        IPT_SAVE="iptables-save";        IPT_RESTORE="iptables-restore"
fi
IP6T="$(command -v ip6tables-legacy 2>/dev/null || command -v ip6tables 2>/dev/null || true)"

#------------------------------------------------------------------------------
# Port policy  --  derived from the live listener inventory (netstat, 29 Aug)
#------------------------------------------------------------------------------
# PUBLIC (internet-facing, must stay reachable):
#   25 postfix SMTP | 110/143/993/995 nginx POP/IMAP | 443 nginx HTTPS
#   465 SMTPS | 587 submission
# ADMIN ONLY (admin CIDRs):
#   22/8022 sshd | 7071 admin console | 8443 mailboxd HTTPS (nginx proxies 443->8443)
# INTERNAL (were listening on 0.0.0.0 -- now explicitly blocked on WAN):
#   11211 memcached | 111 rpcbind | 7025 LMTP | 7026 milter
#   7072/7073/7074 nginx lookup+auth | 7993/7995 mailboxd IMAPS/POP3S backends
# INTERNAL (already bound to 127.0.0.1 -- belt-and-braces block anyway):
#   53 unbound | 3310 clamd | 7306 mysqld | 7171 zmconfigd | 8080 mailboxd HTTP
#   8465 opendkim | 10024-10032 amavis/postfix | 23232/23233 zmstat | 10663 zmlogger
#   389/636 slapd
#------------------------------------------------------------------------------

# Inbound SMTP must accept from arbitrary remote MTAs worldwide. Deliberately
# excluded from the GeoIP gate -- see BUG-1 above.
SMTP_RELAY_PORT="25"

# ADMIN ports -- reachable ONLY from ADMIN_NETS. Never public, never geo-gated
# (geo-gating to BD still exposes them to the whole country).
#   8443: nginx proxies 443 -> 8443, so direct 8443 access from the internet
#   is unnecessary. If any client connects to :8443 directly, move it back
#   into GEOBLOCK_TCP_PORTS.
ADMIN_PORTS="22,8022,7071,8443"

# Public/admin source ranges only -- see the header note on why the old
# private 192.168.77.0/24 entry was dropped on this single-NIC host.
ADMIN_NETS=(
    "157.15.60.0/23"
    "103.169.94.0/24"
    "103.7.248.0/24"        # covers this host's own subnet (103.7.248.5/28) -- hairpin-safe
    "103.7.249.100/30"
    "103.229.82.56/29"
)

# GeoIP allowlist. ISO 3166-1 alpha-2.
ALLOWED_COUNTRIES="BD"

# Public service ports gated by the GeoIP allowlist.
# 25 excluded (BUG-1). 22 and 8443 excluded -- both are admin ports.
GEOBLOCK_TCP_PORTS="587,465,110,995,143,993,80,443"
GEOBLOCK_UDP_PORTS="443"          # HTTP/3 (QUIC) for webmail; blank to disable

# All publicly reachable service ports.
MAIL_WEB_PORTS="${SMTP_RELAY_PORT},${GEOBLOCK_TCP_PORTS}"

#------------------------------------------------------------------------------
# INTERNAL services -- explicitly DROPped on the public interface.
# Several of these were found listening on 0.0.0.0 by the 29 Aug inventory.
# Firewalling them is the immediate fix; rebinding them to 127.0.0.1 is the
# proper fix (see the 'listeners' command for what still needs rebinding).
#------------------------------------------------------------------------------
# Zimbra internal service ports
INTERNAL_TCP_PORTS="7025,7026,7072,7073,7074,7993,7995,8080,7171,7306,10663,23232,23233"
# Infrastructure ports that must never face the internet
INTERNAL_TCP_PORTS2="111,389,636,3310,8465,11211,10024:10032"
# UDP equivalents
INTERNAL_UDP_PORTS="111,161,11211"

#------------------------------------------------------------------------------
# Rate limiting (brute-force protection) -- 0 to disable a given limit
#------------------------------------------------------------------------------
RATELIMIT_ENABLE=1
SMTP_RATE="30/min";   SMTP_BURST="60"      # inbound MTA connections per source
SUBMIT_RATE="10/min"; SUBMIT_BURST="20"    # 587/465 -- authenticated submission
IMAP_RATE="20/min";   IMAP_BURST="40"      # 143/993/110/995
SSH_RATE="6/min";     SSH_BURST="10"

#------------------------------------------------------------------------------
# Egress filtering -- OFF by default; set to 1 after confirming the allowlist.
# A mail server needs SMTP out, DNS, NTP and repo access. Nothing else.
# This is what stops stage-two payload download and data exfiltration.
#------------------------------------------------------------------------------
EGRESS_ENABLE=0
EGRESS_ALLOW_TCP="25,53,587,465,80,443"    # 80/443 for repos + ClamAV updates
EGRESS_ALLOW_UDP="53,123"

#------------------------------------------------------------------------------
LOG_DROPS=1                 # log dropped packets (rate-limited)
LOG_LIMIT="5/min"

ALL_NETSETS=("firehol_level1" "firehol_level2" "firehol_level3" "firehol_level4" \
             "spamhaus_drop" "ci_badguys" "et_bl1" "et_bl2" "bl_de1" "bl_agr" \
             "crowdsec_bl" "whitelist_lan" "whitelist_wan" "manual_blacklist")

THREAT_LISTS=("firehol_level1" "firehol_level2" "firehol_level3" "firehol_level4" \
              "spamhaus_drop" "ci_badguys" "et_bl1" "et_bl2" "bl_de1" "bl_agr" "crowdsec_bl")

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

require_root() {
    [[ $EUID -ne 0 ]] && { echo "ERROR: must run as root"; exit 1; }
}

# ============================================================================
## 1. Core Logic Functions
# ============================================================================

create_netset() {
    local name="$1" url="$2" description="$3"

    log_message "Processing $name: $description"
    mkdir -p "$TEMP_DIR"

    if curl -s --connect-timeout 30 --max-time 120 "$url" -o "$TEMP_DIR/$name.txt"; then
        # Reject an empty/error download rather than swapping in a blank set --
        # a feed that 404s should leave the previous list intact, not silently
        # wipe protection.
        if [[ ! -s "$TEMP_DIR/$name.txt" ]]; then
            log_message "WARNING: $name downloaded empty -- keeping previous set"
            return 1
        fi

        ipset create "$name" hash:net hashsize 8192 maxelem 256000 -exist
        ipset create "${name}_temp" hash:net hashsize 8192 maxelem 256000 -exist
        ipset flush "${name}_temp"

        local count=0 network
        while read -r line; do
            network=$(echo "$line" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | head -1)
            if [[ -n "$network" ]]; then
                ipset add "${name}_temp" "$network" 2>/dev/null && ((count++))
            fi
        done < "$TEMP_DIR/$name.txt"

        # Sanity gate: a feed that suddenly collapses to a handful of entries is
        # more likely broken upstream than genuinely shrunk. Keep the old set.
        if [[ "$count" -lt 5 ]]; then
            log_message "WARNING: $name parsed only $count entries -- keeping previous set"
            ipset destroy "${name}_temp" 2>/dev/null
            return 1
        fi

        ipset swap "${name}_temp" "$name" 2>/dev/null
        ipset destroy "${name}_temp" 2>/dev/null
        ipset save "$name" > "$IPSET_DIR/$name.save"
        log_message "Loaded $count entries into $name"
    else
        log_message "Failed to download $name from $url"
        return 1
    fi
}

create_whitelists() {
    log_message "Creating whitelists (wan=$WAN_IFACE${LAN_IFACE:+, lan=$LAN_IFACE})"

    # whitelist_lan is kept as an empty set for structural compatibility with
    # the rest of the script (status/show-whitelist commands still reference
    # it), but on this single-NIC host there is no LAN_IFACE to bind it to,
    # so it is never populated and never matched in apply_all_rules.
    ipset create "whitelist_lan" hash:net hashsize 1024 maxelem 10000 -exist
    ipset flush "whitelist_lan"
    ipset create "whitelist_wan" hash:net hashsize 1024 maxelem 10000 -exist
    ipset flush "whitelist_wan"

    ipset save "whitelist_lan" > "$IPSET_DIR/whitelist_lan.save"
    log_message "whitelist_lan left empty -- no LAN_IFACE on this host"

    local wan_count=0
    local wan_nets=(
        "103.7.249.212/30"      # Admin/ISP range
        "103.229.82.56/29"      # Admin/ISP range
        "103.7.249.100/30"      # Admin/ISP range
        "163.47.157.192/28"     # Admin/ISP range
        "103.7.248.0/24"        # Admin/ISP -- also covers this box's own IP, hairpin-NAT safe
        "157.15.60.0/23"        # Admin CIDR (estate standard)
        "103.169.94.0/24"       # Admin CIDR (estate standard)
        "8.8.8.8/32"            # Google DNS
        "8.8.4.4/32"            # Google DNS
        "1.1.1.1/32"            # Cloudflare DNS
        "1.0.0.1/32"            # Cloudflare DNS
        "9.9.9.9/32"            # Quad9 DNS
        "52.101.124.0/24"       # Microsoft EOP
        "52.101.157.0/24"       # Microsoft EOP
        "52.101.137.0/24"       # Microsoft EOP
        "40.80.0.0/12"          # Microsoft
        "154.59.193.0/24"       # MailPlus
        "154.59.104.0/24"       # MailPlus
        "149.13.75.0/24"        # MailPlus
    )
    for network in "${wan_nets[@]}"; do
        ipset add "whitelist_wan" "$network" 2>/dev/null && ((wan_count++))
    done
    ipset save "whitelist_wan" > "$IPSET_DIR/whitelist_wan.save"
    log_message "Created whitelist_wan with $wan_count entries"
}

create_manual_blacklist() {
    local name="manual_blacklist"
    log_message "Creating manual blacklist: $name"

    ipset create "$name" hash:net hashsize 1024 maxelem 50000 -exist

    if [[ -f "$IPSET_DIR/$name.save" ]]; then
        ipset restore -exist < "$IPSET_DIR/$name.save" 2>/dev/null
        local count
        count=$(ipset list "$name" | grep -c '^[0-9]')
        log_message "Restored manual blacklist with $count entries"
    else
        log_message "Manual blacklist initialized (empty)"
    fi
}

check_overlaps() {
    local set_name="${1:-manual_blacklist}"

    if ! ipset list "$set_name" >/dev/null 2>&1; then
        echo "Set $set_name does not exist"; return 1
    fi

    local entries
    entries=$(ipset list "$set_name" | grep -E '^[0-9]+\.')
    [[ -z "$entries" ]] && { echo "No entries in $set_name -- nothing to check"; return 0; }

    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not available -- cannot check for overlaps"; return 1
    fi

    echo "$entries" | python3 -c '
import sys, ipaddress
nets = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: nets.append((line, ipaddress.ip_network(line, strict=False)))
    except ValueError: continue
nets_sorted = sorted(nets, key=lambda x: x[1].prefixlen)
redundant = []
for i, (estr, enet) in enumerate(nets_sorted):
    for bstr, bnet in nets_sorted[:i]:
        if bnet.prefixlen < enet.prefixlen and enet.subnet_of(bnet):
            redundant.append((estr, bstr)); break
if redundant:
    print(f"{len(redundant)} redundant entr" + ("y" if len(redundant)==1 else "ies") + " found in this set:")
    for small, big in redundant: print(f"  {small} is already fully covered by {big}")
else:
    print("No redundant/overlapping entries found.")
'
}

setup_geoip_rules() {
    log_message "Setting up GeoIP allowlist on service ports (allow: $ALLOWED_COUNTRIES)"

    # Fail OPEN if the DB is empty. xt_geoip maps an unmappable IP to "no
    # country match"; combined with the negated allowlist, an empty DB would
    # DROP every source including allowed countries -- a total outage, not
    # "no protection". Skip the rule and log loudly instead.
    local geoip_file_count
    geoip_file_count=$(find /usr/share/xt_geoip -mindepth 1 -type f 2>/dev/null | wc -l)
    if [[ "$geoip_file_count" -eq 0 ]]; then
        log_message "WARNING: /usr/share/xt_geoip empty -- skipping GeoIP allowlist (failing OPEN). Run geo-update.sh. Blacklists still apply."
        return 0
    fi

    $IPT -A INPUT -i "$WAN_IFACE" -p tcp -m multiport --dports "$GEOBLOCK_TCP_PORTS" \
        -m geoip ! --src-cc "$ALLOWED_COUNTRIES" -j NETSET_DROP
    log_message "GeoIP allowlist [$ALLOWED_COUNTRIES] on TCP: $GEOBLOCK_TCP_PORTS ($WAN_IFACE only)"

    if [[ -n "$GEOBLOCK_UDP_PORTS" ]]; then
        $IPT -A INPUT -i "$WAN_IFACE" -p udp -m multiport --dports "$GEOBLOCK_UDP_PORTS" \
            -m geoip ! --src-cc "$ALLOWED_COUNTRIES" -j NETSET_DROP
        log_message "GeoIP allowlist [$ALLOWED_COUNTRIES] on UDP: $GEOBLOCK_UDP_PORTS ($WAN_IFACE only)"
    fi
}

setup_ratelimit_rules() {
    [[ "$RATELIMIT_ENABLE" -ne 1 ]] && return 0
    log_message "Applying brute-force rate limits"

    # Inbound SMTP from arbitrary MTAs -- generous, just clips floods
    $IPT -A INPUT -i "$WAN_IFACE" -p tcp --dport "$SMTP_RELAY_PORT" -m conntrack --ctstate NEW \
        -m hashlimit --hashlimit-above "$SMTP_RATE" --hashlimit-burst "$SMTP_BURST" \
        --hashlimit-mode srcip --hashlimit-name smtp_flood -j NETSET_DROP

    # Authenticated submission -- tighter; this is where credential stuffing lands
    $IPT -A INPUT -i "$WAN_IFACE" -p tcp -m multiport --dports 587,465 -m conntrack --ctstate NEW \
        -m hashlimit --hashlimit-above "$SUBMIT_RATE" --hashlimit-burst "$SUBMIT_BURST" \
        --hashlimit-mode srcip --hashlimit-name submit_bf -j NETSET_DROP

    # IMAP/POP
    $IPT -A INPUT -i "$WAN_IFACE" -p tcp -m multiport --dports 143,993,110,995 -m conntrack --ctstate NEW \
        -m hashlimit --hashlimit-above "$IMAP_RATE" --hashlimit-burst "$IMAP_BURST" \
        --hashlimit-mode srcip --hashlimit-name imap_bf -j NETSET_DROP

    # SSH (admin nets only reach it, but limit anyway)
    $IPT -A INPUT -p tcp -m multiport --dports 22,8022 -m conntrack --ctstate NEW \
        -m hashlimit --hashlimit-above "$SSH_RATE" --hashlimit-burst "$SSH_BURST" \
        --hashlimit-mode srcip --hashlimit-name ssh_bf -j NETSET_DROP

    log_message "Rate limits applied (smtp=$SMTP_RATE submit=$SUBMIT_RATE imap=$IMAP_RATE ssh=$SSH_RATE)"
}

setup_egress_rules() {
    if [[ "$EGRESS_ENABLE" -ne 1 ]]; then
        log_message "Egress filtering DISABLED (EGRESS_ENABLE=0) -- OUTPUT remains ACCEPT"
        $IPT -P OUTPUT ACCEPT
        return 0
    fi

    log_message "Applying egress filtering (OUTPUT default-deny)"
    $IPT -F OUTPUT
    $IPT -A OUTPUT -o lo -j ACCEPT
    $IPT -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    $IPT -A OUTPUT -p tcp -m multiport --dports "$EGRESS_ALLOW_TCP" -j ACCEPT
    $IPT -A OUTPUT -p udp -m multiport --dports "$EGRESS_ALLOW_UDP" -j ACCEPT
    $IPT -A OUTPUT -p icmp -j ACCEPT
    [[ "$LOG_DROPS" -eq 1 ]] && \
        $IPT -A OUTPUT -m limit --limit "$LOG_LIMIT" -j LOG --log-prefix "EGRESS-DROP: " --log-level 4
    $IPT -A OUTPUT -j DROP
    log_message "Egress allowlist: tcp=$EGRESS_ALLOW_TCP udp=$EGRESS_ALLOW_UDP"
}

apply_all_rules() {
    log_message "Applying all firewall rules with correct precedence"

    $IPT -F INPUT
    $IPT -F FORWARD
    $IPT -P INPUT ACCEPT
    $IPT -P FORWARD ACCEPT

    # Dedicated logged-drop chain so every drop reason is greppable in syslog
    $IPT -F NETSET_DROP 2>/dev/null || $IPT -N NETSET_DROP 2>/dev/null
    $IPT -F NETSET_DROP 2>/dev/null
    [[ "$LOG_DROPS" -eq 1 ]] && \
        $IPT -A NETSET_DROP -m limit --limit "$LOG_LIMIT" -j LOG --log-prefix "NETSET-DROP: " --log-level 4
    $IPT -A NETSET_DROP -j DROP

    # ---- 1. Loopback ------------------------------------------------------
    $IPT -A INPUT -i lo -j ACCEPT

    # ---- 2. Anti-spoof / martian filtering ---------------------------------
    # Loopback-space arriving on a real NIC is always spoofed.
    $IPT -A INPUT ! -i lo -s 127.0.0.0/8 -j NETSET_DROP
    # RFC1918 + link-local + multicast/reserved arriving on the PUBLIC iface.
    # This is the only NIC on this host, so these ranges are never legitimate
    # inbound sources here (see the header note re: 192.168.77.0/24).
    $IPT -A INPUT -i "$WAN_IFACE" -s 10.0.0.0/8       -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -s 172.16.0.0/12    -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -s 192.168.0.0/16   -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -s 169.254.0.0/16   -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -s 224.0.0.0/4      -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -s 240.0.0.0/4      -j NETSET_DROP
    # Invalid-state and stealth-scan packets
    $IPT -A INPUT -m conntrack --ctstate INVALID -j NETSET_DROP
    $IPT -A INPUT -p tcp ! --syn -m conntrack --ctstate NEW -j NETSET_DROP
    $IPT -A INPUT -p tcp --tcp-flags ALL NONE -j NETSET_DROP
    $IPT -A INPUT -p tcp --tcp-flags ALL ALL  -j NETSET_DROP

    # ---- 3. Whitelists ------------------------------------------------------
    # whitelist_lan is skipped entirely -- no LAN_IFACE exists on this host.
    if [[ -n "$LAN_IFACE" ]] && ipset list "whitelist_lan" >/dev/null 2>&1; then
        $IPT -A INPUT -i "$LAN_IFACE" -m set --match-set "whitelist_lan" src -j ACCEPT
        log_message "Applied whitelist_lan (bound to $LAN_IFACE)"
    fi
    if ipset list "whitelist_wan" >/dev/null 2>&1; then
        $IPT -A INPUT -i "$WAN_IFACE" -m set --match-set "whitelist_wan" src -j ACCEPT
        log_message "Applied whitelist_wan (bound to $WAN_IFACE)"
    fi

    # ---- 4. Established/related -------------------------------------------
    $IPT -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # ---- 5. ADMIN PORTS -- admin CIDRs only, never public ------------------
    for NET in "${ADMIN_NETS[@]}"; do
        $IPT -A INPUT -s "$NET" -p tcp -m multiport --dports "$ADMIN_PORTS" -j ACCEPT
    done
    $IPT -A INPUT -p tcp -m multiport --dports "$ADMIN_PORTS" -j NETSET_DROP
    log_message "Admin ports $ADMIN_PORTS restricted to: ${ADMIN_NETS[*]}"

    # ---- 6. Rate limiting --------------------------------------------------
    setup_ratelimit_rules

    # ---- 7. GeoIP allowlist ------------------------------------------------
    # Ahead of the blacklists: one geoip check rejects most non-allowed-country
    # traffic before spending cycles on 11 ipset lookups.
    setup_geoip_rules

    # ---- 8. Manual blacklist (WAN only) -----------------------------------
    if ipset list "manual_blacklist" >/dev/null 2>&1; then
        $IPT -A INPUT -i "$WAN_IFACE" -m set --match-set "manual_blacklist" src -j NETSET_DROP
        log_message "Applied manual blacklist (bound to $WAN_IFACE)"
    fi

    # ---- 9. Threat-intel blacklists (WAN only) ----------------------------
    for blacklist in "${THREAT_LISTS[@]}"; do
        if ipset list "$blacklist" >/dev/null 2>&1; then
            $IPT -A INPUT -i "$WAN_IFACE" -m set --match-set "$blacklist" src -j NETSET_DROP
        fi
    done

    # ---- 10. Public mail/web ports ----------------------------------------
    # Port 25 ungated (BUG-1 fix -- must accept from any country); the rest
    # already passed the GeoIP gate above on WAN.
    $IPT -A INPUT -p tcp -m multiport --dports "$MAIL_WEB_PORTS" -j ACCEPT
    log_message "Opened public mail/web ports: $MAIL_WEB_PORTS"

    # ---- 11. Internal services -- explicitly never public -----------------
    # The 29 Aug inventory found memcached (11211), rpcbind (111), LMTP (7025),
    # milter (7026), the nginx lookup/auth handlers (7072-7074) and the mailboxd
    # IMAPS/POP3S backends (7993/7995) all listening on 0.0.0.0. These are hard
    # DROPs regardless of what any later rule would otherwise permit. There is
    # no LAN_IFACE to duplicate these onto -- the single public NIC is covered.
    $IPT -A INPUT -i "$WAN_IFACE" -p tcp -m multiport --dports "$INTERNAL_TCP_PORTS"  -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -p tcp -m multiport --dports "$INTERNAL_TCP_PORTS2" -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -p udp -m multiport --dports "$INTERNAL_UDP_PORTS"  -j NETSET_DROP
    log_message "Internal service ports blocked on $WAN_IFACE"

    # ---- 12. ICMP (rate-limited) ------------------------------------------
    $IPT -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/sec --limit-burst 10 -j ACCEPT
    $IPT -A INPUT -p icmp --icmp-type echo-request -j NETSET_DROP
    $IPT -A INPUT -p icmp -j ACCEPT

    # ---- 13. Default deny --------------------------------------------------
    # Trailing DROP rule rather than `-P INPUT DROP`, so a script that errors
    # out partway through fails open rather than locking you out.
    $IPT -A FORWARD -j DROP
    $IPT -A INPUT -j NETSET_DROP

    # ---- 14. Egress --------------------------------------------------------
    setup_egress_rules

    # ---- 15. IPv6 lockdown -------------------------------------------------
    # Estate standard is IPv4-only with v6 disabled at sysctl. If the stack is
    # ever re-enabled, an empty v6 ruleset would be wide open.
    if [[ -n "$IP6T" ]]; then
        $IP6T -F 2>/dev/null
        $IP6T -P INPUT DROP 2>/dev/null
        $IP6T -P FORWARD DROP 2>/dev/null
        $IP6T -A INPUT -i lo -j ACCEPT 2>/dev/null
        log_message "IPv6 locked down (INPUT/FORWARD DROP)"
    fi

    log_message "All firewall rules applied successfully"
}

save_rules() {
    log_message "Saving current ipset and iptables rules"
    mkdir -p "$IPSET_DIR"
    for set_name in "${ALL_NETSETS[@]}"; do
        if ipset list "$set_name" >/dev/null 2>&1; then
            ipset save "$set_name" > "$IPSET_DIR/$set_name.save"
        fi
    done
    $IPT_SAVE > "$IPSET_DIR/iptables.save"
    log_message "All rules saved to disk"
}

# Snapshot the live ruleset so `apply --safe` can roll back
snapshot_rules() {
    mkdir -p "$(dirname "$ROLLBACK_FILE")"
    $IPT_SAVE > "$ROLLBACK_FILE"
    log_message "Rollback snapshot written to $ROLLBACK_FILE"
}

# Apply with a dead-man switch: if you lose your session and do not confirm
# within N seconds, the previous ruleset is restored automatically.
apply_safe() {
    local wait_secs="${1:-120}"
    snapshot_rules

    log_message "SAFE APPLY -- auto-rollback in ${wait_secs}s unless confirmed"
    ( sleep "$wait_secs"
      if [[ -f /tmp/.netset-confirmed ]]; then
          rm -f /tmp/.netset-confirmed
      else
          $IPT_RESTORE < "$ROLLBACK_FILE"
          logger -t netset-manager "AUTO-ROLLBACK: rules reverted after ${wait_secs}s without confirmation"
      fi
    ) &
    local watchdog=$!

    apply_all_rules

    echo
    echo "Rules applied. Auto-rollback in ${wait_secs}s unless you confirm."
    echo "From a SECOND session, verify you still have access, then run:"
    echo "    $0 confirm"
    echo
    echo "Watchdog PID: $watchdog"
}

verify_rules() {
    echo "=== Ruleset verification ==="
    local problems=0

    echo -n "Default-deny on INPUT ....... "
    if $IPT -L INPUT -n | tail -3 | grep -qE 'NETSET_DROP|DROP'; then echo "OK"
    else echo "MISSING"; ((problems++)); fi

    echo -n "Admin ports restricted ...... "
    if $IPT -L INPUT -n | grep -q "multiport dports ${ADMIN_PORTS//,/,}"; then echo "OK"
    else echo "check manually"; fi

    echo -n "Port 25 NOT geo-gated ....... "
    if [[ ",$GEOBLOCK_TCP_PORTS," == *",25,"* ]]; then
        echo "FAIL -- port 25 is in GEOBLOCK_TCP_PORTS; foreign mail will be dropped"; ((problems++))
    else echo "OK"; fi

    echo -n "Anti-spoof active ........... "
    if $IPT -L INPUT -n | grep -q '127.0.0.0/8'; then echo "OK"
    else echo "MISSING"; ((problems++)); fi

    echo -n "GeoIP database populated .... "
    local n; n=$(find /usr/share/xt_geoip -mindepth 1 -type f 2>/dev/null | wc -l)
    if [[ "$n" -gt 0 ]]; then echo "OK ($n files)"
    else echo "EMPTY -- geo rules skipped (failing open)"; ((problems++)); fi

    echo -n "Threat lists loaded ......... "
    local loaded=0
    for b in "${THREAT_LISTS[@]}"; do ipset list "$b" >/dev/null 2>&1 && ((loaded++)); done
    echo "$loaded/${#THREAT_LISTS[@]}"
    [[ "$loaded" -lt 5 ]] && ((problems++))

    echo -n "Egress filtering ............ "
    [[ "$EGRESS_ENABLE" -eq 1 ]] && echo "ENABLED" || echo "disabled (EGRESS_ENABLE=0)"

    echo -n "IPv6 locked down ............ "
    if [[ -n "$IP6T" ]] && $IP6T -L INPUT -n 2>/dev/null | head -1 | grep -q DROP; then echo "OK"
    else echo "check manually"; fi

    echo -n "memcached not public ........ "
    if ss -4 -tln 2>/dev/null | grep -qE '0\.0\.0\.0:11211'; then
        echo "LISTENING ON 0.0.0.0 -- firewalled, but rebind to 127.0.0.1 (see: $0 listeners)"; ((problems++))
    else echo "OK"; fi

    echo -n "Internal ports blocked ...... "
    if $IPT -L INPUT -n 2>/dev/null | grep -q '11211'; then echo "OK"
    else echo "MISSING -- run '$0 reload'"; ((problems++)); fi

    echo
    [[ "$problems" -eq 0 ]] && echo "No problems detected." || echo "$problems item(s) need attention."
}

# ============================================================================
## Manual IP Blocking Functions
# ============================================================================

add_manual_block() {
    local network="$1"
    [[ -z "$network" ]] && { echo "Usage: $0 block-ip <network>"; exit 1; }

    if [[ ! "$network" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        log_message "Invalid network format: $network"; echo "Error: Invalid network format: $network"; exit 1
    fi

    # Guard: never let an admin range be blocked by accident
    for NET in "${ADMIN_NETS[@]}"; do
        if [[ "$network" == "$NET" ]]; then
            echo "REFUSED: $network is an admin range -- blocking it would lock you out."; exit 1
        fi
    done

    ipset create "manual_blacklist" hash:net hashsize 1024 maxelem 50000 -exist

    if ipset add "manual_blacklist" "$network" 2>/dev/null; then
        ipset save "manual_blacklist" > "$IPSET_DIR/manual_blacklist.save"
        log_message "Added $network to manual blacklist"
        echo "Successfully blocked $network"
        apply_all_rules
        local overlap_result
        overlap_result=$(check_overlaps "manual_blacklist" 2>/dev/null)
        if [[ "$overlap_result" != "No redundant/overlapping entries found." ]]; then
            echo; echo "Note: $overlap_result"
        fi
    else
        log_message "Failed to add $network (may already exist)"
        echo "Network $network already exists in manual blacklist or invalid format"
    fi
}

remove_manual_block() {
    local network="$1"
    [[ -z "$network" ]] && { echo "Usage: $0 unblock-ip <network>"; exit 1; }

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

show_manual_blacklist() {
    echo "Current Manual Blacklist Networks (bound to $WAN_IFACE):"
    if ipset list "manual_blacklist" >/dev/null 2>&1; then
        local entries
        entries=$(ipset list "manual_blacklist" | grep -E '^[0-9]+\.' | sort -V)
        if [[ -n "$entries" ]]; then
            echo "$entries"; echo; echo "Total blocked IPs/networks: $(echo "$entries" | wc -l)"
        else
            echo "No manual blocks configured"
        fi
    else
        echo "No manual blacklist configured"
    fi
}

add_whitelist() {
    local iface_choice="$1" network="$2" set_name
    case "$iface_choice" in
        wan) set_name="whitelist_wan" ;;
        lan)
            if [[ -z "$LAN_IFACE" ]]; then
                echo "This host has no LAN_IFACE (single-NIC) -- use '$0 add-whitelist wan <net>' instead."
                exit 1
            fi
            set_name="whitelist_lan" ;;
        *) echo "Usage: $0 add-whitelist <wan|lan> <network>"; exit 1 ;;
    esac
    [[ -z "$network" ]] && { echo "Usage: $0 add-whitelist <wan|lan> <network>"; exit 1; }

    if [[ ! "$network" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        log_message "Invalid network format: $network"; echo "Error: Invalid network format: $network"; exit 1
    fi

    ipset create "$set_name" hash:net hashsize 1024 maxelem 10000 -exist
    if ipset add "$set_name" "$network" 2>/dev/null; then
        ipset save "$set_name" > "$IPSET_DIR/$set_name.save"
        log_message "Added $network to $set_name"
        echo "Successfully added $network to $set_name"
        apply_all_rules
    else
        echo "Network $network already exists in $set_name or invalid format"
    fi
}

remove_whitelist() {
    local iface_choice="$1" network="$2" set_name
    case "$iface_choice" in
        wan) set_name="whitelist_wan" ;;
        lan) set_name="whitelist_lan" ;;
        *) echo "Usage: $0 remove-whitelist <wan|lan> <network>"; exit 1 ;;
    esac
    [[ -z "$network" ]] && { echo "Usage: $0 remove-whitelist <wan|lan> <network>"; exit 1; }

    if ipset test "$set_name" "$network" 2>/dev/null; then
        ipset del "$set_name" "$network"
        ipset save "$set_name" > "$IPSET_DIR/$set_name.save"
        log_message "Removed $network from $set_name"
        echo "Successfully removed $network from $set_name"
        apply_all_rules
    else
        echo "Network $network not found in $set_name"
    fi
}

show_whitelists() {
    echo "Current whitelist_lan: (none -- no LAN_IFACE on this single-NIC host)"
    echo
    echo "Current whitelist_wan (bound to $WAN_IFACE):"
    ipset list "whitelist_wan" 2>/dev/null | grep -E '^[0-9]+\.' | sort -V || echo "  Not configured"
}

check_ip_status() {
    local ip="$1"
    [[ -z "$ip" ]] && { echo "Usage: $0 check-ip <ip>"; exit 1; }
    [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "Error: Invalid IP format: $ip"; exit 1; }

    echo "Checking status for IP: $ip"
    echo "================================"

    local is_whitelisted=0
    if ipset test "whitelist_wan" "$ip" 2>/dev/null; then
        echo "[+] WHITELISTED (whitelist_wan) -- unrestricted, via $WAN_IFACE"; is_whitelisted=1
    fi
    [[ "$is_whitelisted" -eq 1 ]] && return 0

    if ipset test "manual_blacklist" "$ip" 2>/dev/null; then
        echo "[-] MANUALLY BLOCKED -- every port on $WAN_IFACE"; return 0
    fi

    local blocked_in=""
    for blacklist in "${THREAT_LISTS[@]}"; do
        if ipset list "$blacklist" >/dev/null 2>&1 && ipset test "$blacklist" "$ip" 2>/dev/null; then
            blocked_in="$blocked_in $blacklist"
        fi
    done

    if [[ -n "$blocked_in" ]]; then
        echo "[-] BLOCKED -- found in:$blocked_in (on $WAN_IFACE, including mail/web)"
    else
        echo "[o] NOT BLOCKED"
        echo
        echo "  Port $SMTP_RELAY_PORT (SMTP): OPEN unconditionally -- no GeoIP gate."
        echo "  Ports $GEOBLOCK_TCP_PORTS: require country in [$ALLOWED_COUNTRIES] via $WAN_IFACE."
        echo "  Ports $ADMIN_PORTS (admin): ONLY from ${ADMIN_NETS[*]}."
    fi
}

# Audit live listeners against the intended policy. Anything on 0.0.0.0 that
# is not a declared PUBLIC or ADMIN port is a rebinding candidate -- firewalling
# it works, but binding to 127.0.0.1 is the durable fix.
show_listeners() {
    echo "=== Live listener audit ==="
    echo
    printf "%-8s %-22s %-28s %s\n" "PROTO" "LOCAL ADDRESS" "PROCESS" "VERDICT"
    printf "%-8s %-22s %-28s %s\n" "-----" "-------------" "-------" "-------"

    local public_re="^(25|110|143|443|465|587|993|995)$"
    local admin_re="^(22|8022|7071|8443)$"

    ss -4 -tulpn 2>/dev/null | tail -n +2 | while read -r proto _ _ local _ rest; do
        local port="${local##*:}"
        local addr="${local%:*}"
        local proc
        proc=$(echo "$rest" | grep -oE 'users:\(\("[^"]+"' | head -1 | sed 's/.*"//')
        local verdict

        if [[ "$addr" == "127.0.0.1" || "$addr" == "[::1]" ]]; then
            verdict="OK (loopback)"
        elif [[ "$port" =~ $public_re ]]; then
            verdict="OK (public service)"
        elif [[ "$port" =~ $admin_re ]]; then
            verdict="OK (admin, firewalled to admin CIDRs)"
        elif [[ "$addr" == "0.0.0.0" || "$addr" == "*" ]]; then
            verdict="REBIND -> 127.0.0.1 (firewalled, but should not be on 0.0.0.0)"
        else
            verdict="review ($addr)"
        fi
        printf "%-8s %-22s %-28s %s\n" "$proto" "$local" "${proc:-?}" "$verdict"
    done

    cat <<'NOTE'

Rebinding hints for the common offenders:

  memcached (11211)   -- highest priority: amplification + cache disclosure
      zmlocalconfig -e memcached_bind_address=127.0.0.1
      zmmemcachedctl restart

  rpcbind (111)       -- only needed if this host mounts NFS
      systemctl disable --now rpcbind rpcbind.socket    # if NFS is not used
      # otherwise leave it, the firewall blocks it externally

  mailboxd backends (7025/7026/7072/7073/7074/7993/7995)
      These are Zimbra-internal. On a single-server install they can be bound
      to loopback, but verify the proxy still reaches them before making it
      permanent -- nginx talks to 7072/7073/7074 and 7993/7995.

NOTE
}

# ============================================================================
## 2. Command Handlers
# ============================================================================

handle_update() {
    log_message "Starting netset update"

    create_whitelists
    create_manual_blacklist

    create_netset "firehol_level1" "https://iplists.firehol.org/files/firehol_level1.netset" "FireHOL Level1"
    create_netset "firehol_level2" "https://iplists.firehol.org/files/firehol_level2.netset" "FireHOL Level2"
    create_netset "firehol_level3" "https://iplists.firehol.org/files/firehol_level3.netset" "FireHOL Level3"
    create_netset "firehol_level4" "https://iplists.firehol.org/files/firehol_level4.netset" "FireHOL Level4"
    # NOTE: the plain-text Spamhaus DROP list is deprecated upstream. If this
    # feed starts returning empty, switch to the FireHOL mirror:
    #   https://iplists.firehol.org/files/spamhaus_drop.netset
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

handle_restore() {
    log_message "Restoring ipsets from saved files"
    for file in "$IPSET_DIR"/*.save; do
        [[ -f "$file" ]] || continue
        [[ "$(basename "$file")" == "iptables.save" ]] && continue
        ipset restore -exist < "$file" 2>/dev/null
        log_message "Restored $(basename "$file" .save)"
    done
    apply_all_rules
    save_rules
}

# ============================================================================
## 3. Main Execution
# ============================================================================

case "${1:-}" in
    "update")           require_root; handle_update ;;
    "reload")           require_root; log_message "Reloading firewall rules"; apply_all_rules; save_rules ;;
    "reload-safe")      require_root; apply_safe "${2:-120}" ;;
    "confirm")          touch /tmp/.netset-confirmed; echo "Confirmed -- auto-rollback cancelled." ;;
    "rollback")
        require_root
        if [[ -f "$ROLLBACK_FILE" ]]; then
            $IPT_RESTORE < "$ROLLBACK_FILE"; log_message "Manual rollback applied"
            echo "Previous ruleset restored from $ROLLBACK_FILE"
        else
            echo "No rollback snapshot at $ROLLBACK_FILE"
        fi ;;
    "restore")          require_root; handle_restore ;;
    "verify")           verify_rules ;;
    "listeners")        show_listeners ;;
    "block-ip")         require_root; add_manual_block "${2:-}" ;;
    "unblock-ip")       require_root; remove_manual_block "${2:-}" ;;
    "add-whitelist")    require_root; add_whitelist "${2:-}" "${3:-}" ;;
    "remove-whitelist") require_root; remove_whitelist "${2:-}" "${3:-}" ;;
    "show-blocked")     show_manual_blacklist ;;
    "show-whitelist")   show_whitelists ;;
    "check-ip")         check_ip_status "${2:-}" ;;
    "check-overlaps")   check_overlaps "${2:-manual_blacklist}" ;;
    "status")
        echo "=== Netset Firewall Status (Zimbra mail storage) ==="
        echo
        echo "Backend: $IPT   Interface: $WAN_IFACE (single-NIC host, no separate LAN)"
        echo
        echo "Current IPSets:"; ipset list -t
        echo
        echo "INPUT chain:";  $IPT -L INPUT -n --line-numbers
        echo
        echo "OUTPUT chain:"; $IPT -L OUTPUT -n --line-numbers | head -12
        echo
        echo "Configuration:"
        echo "  SMTP relay port (ungated, worldwide):  $SMTP_RELAY_PORT"
        echo "  GeoIP-gated TCP ($WAN_IFACE only):        $GEOBLOCK_TCP_PORTS"
        echo "  GeoIP-gated UDP ($WAN_IFACE only):        ${GEOBLOCK_UDP_PORTS:-<none>}"
        echo "  Allowed countries:                     $ALLOWED_COUNTRIES"
        echo "  ADMIN ports (admin CIDRs only):        $ADMIN_PORTS"
        echo "  Admin CIDRs:                           ${ADMIN_NETS[*]}"
        echo "  Rate limiting:                         $([[ $RATELIMIT_ENABLE -eq 1 ]] && echo ENABLED || echo disabled)"
        echo "  Egress filtering:                      $([[ $EGRESS_ENABLE -eq 1 ]] && echo ENABLED || echo 'disabled (EGRESS_ENABLE=0)')"
        echo
        echo "GeoIP database:"
        geoip_status_count=$(find /usr/share/xt_geoip -mindepth 1 -type f 2>/dev/null | wc -l)
        if [[ "$geoip_status_count" -gt 0 ]]; then
            geoip_newest=$(find /usr/share/xt_geoip -mindepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
            echo "  Populated -- $geoip_status_count files, newest: ${geoip_newest:-unknown}"
        else
            echo "  MISSING/EMPTY -- GeoIP allowlist NOT applied (failing open). Run geo-update.sh."
        fi
        echo
        show_whitelists; echo; show_manual_blacklist ;;
    "reset-policy")
        require_root
        log_message "Resetting iptables to default ACCEPT policy"
        $IPT -F INPUT; $IPT -F FORWARD; $IPT -F OUTPUT
        $IPT -P INPUT ACCEPT; $IPT -P OUTPUT ACCEPT; $IPT -P FORWARD ACCEPT
        log_message "Firewall reset to allow-all mode"
        echo "WARNING: host is now UNFIREWALLED. Run '$0 reload' to restore protection." ;;
    "save")             require_root; save_rules ;;
    *)
        cat <<USAGE
Usage: $0 {update|reload|reload-safe|confirm|rollback|restore|verify|block-ip|
           unblock-ip|add-whitelist|remove-whitelist|show-blocked|show-whitelist|
           check-ip|check-overlaps|status|reset-policy|save}

Commands:
  update                    - Download and apply all blacklists, then save
  reload                    - Re-apply existing rules, then save
  reload-safe [secs]        - Apply with auto-rollback (default 120s) unless
                              you run '$0 confirm' from another session
  confirm                   - Cancel a pending auto-rollback
  rollback                  - Manually restore the last snapshot
  restore                   - Restore ipsets from saved files, then save
  verify                    - Self-check the live ruleset for common problems
  listeners                 - Audit live listeners vs policy (finds 0.0.0.0 binds)
  block-ip <ip/net>         - Block an IP/network (all ports, $WAN_IFACE only)
  unblock-ip <ip/net>       - Remove from manual blacklist
  add-whitelist wan <net>   - Trust a network on $WAN_IFACE (the only NIC)
  remove-whitelist wan <net> - Untrust a network
  show-blocked              - Display manual blocks
  show-whitelist             - Display the WAN whitelist
  check-ip <ip>             - Is this IP blocked/whitelisted, and where
  check-overlaps [set]      - Report redundant CIDR entries
  status                    - Show ipsets, rules, and configuration
  reset-policy              - Reset to allow-all (emergency use only)
  save                      - Save current rules to disk

Rule Priority Order:
   1. Loopback (-i lo)
   2. Anti-spoof: loopback-space on real NIC, RFC1918/link-local/multicast
      on $WAN_IFACE, INVALID state, stealth-scan flags -- DROPPED
   3. whitelist_wan (any port) -- via $WAN_IFACE only
   4. Established/related
   5. ADMIN ports $ADMIN_PORTS -- ONLY from admin CIDRs, dropped otherwise
   6. Rate limits (SMTP/submission/IMAP/SSH per-source)
   7. GeoIP allowlist [$ALLOWED_COUNTRIES] on $GEOBLOCK_TCP_PORTS -- $WAN_IFACE
      only; fails OPEN if the DB is empty (see status)
   8. Manual blacklist -- $WAN_IFACE only
   9. Threat-intel blacklists (11 feeds) -- $WAN_IFACE only
  10. Public mail/web ports ACCEPT: $MAIL_WEB_PORTS
      (port $SMTP_RELAY_PORT ungated worldwide -- inbound mail must work)
  11. Internal services hard-DROPped (memcached 11211, rpcbind 111, LMTP 7025,
      milter 7026, nginx lookup/auth 7072-7074, mailboxd backends 7993/7995,
      LDAP 389/636, MariaDB 7306, amavis 10024-10032, clamd, opendkim, SNMP)
  12. ICMP echo rate-limited
  13. Everything else -> NETSET_DROP (logged, then dropped)
  14. Egress: $([[ $EGRESS_ENABLE -eq 1 ]] && echo "OUTPUT default-deny" || echo "OUTPUT ACCEPT (set EGRESS_ENABLE=1 to enforce)")

Examples:
  $0 update                          # Full update with all protections
  $0 reload-safe 180                 # Apply with a 3-minute dead-man switch
  $0 verify                          # Sanity-check the live ruleset
  $0 block-ip 203.0.113.0/24         # Block a network
  $0 add-whitelist wan 203.0.113.5   # Trust a new admin IP on $WAN_IFACE
  $0 check-ip 8.8.8.8                # Where does this IP stand
  $0 listeners                       # Which sockets are on 0.0.0.0 and shouldn't be
USAGE
        exit 1 ;;
esac
