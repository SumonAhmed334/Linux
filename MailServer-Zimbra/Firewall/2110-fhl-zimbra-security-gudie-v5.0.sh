root@webmail:~# cat /usr/local/bin/manage-netsets.sh
#!/bin/bash
#==============================================================================
# manage-netsets.sh  --  v5
# Zimbra mail server firewall -- role-based access control
# webmail.fiberathome.net   ens4 = WAN (public)   ens3 = LAN (office)
#
# v5 CHANGES
#   * Port 25 is NO LONGER world-open. MX is 0 fiberathome-net.mail.protection
#     .outlook.com, so ALL external inbound arrives via M365 split delivery.
#     Port 25 now: MX partners + host itself + SMTP_RELAY_NETS only.
#   * MX_NETS corrected. Log analysis found deliveries from 104.47.23.239/241,
#     which the v4 set did NOT cover -- that mail would have been dropped
#     silently. Full EOP ranges added.
#   * SMTP_RELAY_NETS added for internal systems that relay via mynetworks
#     without SMTP AUTH (NOC alerting from 103.7.248.53 -- 3,939 msgs seen).
#   * `smtp-audit` command: shows who actually connects to 25, and flags
#     mynetworks entries that are dangerously wide.
#==============================================================================
#
#  ACCESS MATRIX  (what v5 enforces)
#  ---------------------------------------------------------------------------
#  SOURCE                      25   993/995   80/443  7071  22/8022  110/143
#                                   465/587
#  ---------------------------------------------------------------------------
#  World (any country)         NO     -         -       -      -       NO
#  Bangladesh (GeoIP)          NO    YES       YES      -      -       NO
#  MX partners (MS/MailPlus)   YES    -         -       -      -       NO
#  SMTP relay nets             YES    -         -       -      -       NO
#  VPN users                   NO    YES       YES      -      -       NO
#  LAN (ens3)                  NO    YES       YES      -      -       NO
#  Office 192.168.77.0/24      NO    YES       YES     YES    YES      NO
#  Admin nets                  NO    YES       YES     YES    YES      NO
#  Host itself (loopback path) 25 + saslauthd 7072-7074 + RemoteManager 22
#  ---------------------------------------------------------------------------
#
#  Port 25 is reachable ONLY by MX partners, SMTP_RELAY_NETS and the host
#  itself, because the MX record points at M365:
#      dig +short MX fiberathome.net
#      -> 0 fiberathome-net.mail.protection.outlook.com
#  Ordinary clients send mail via 587/465 with SMTP AUTH, not via 25.
#  If the MX is ever repointed at this server, set SMTP_WORLD_OPEN=1 or ALL
#  inbound mail is silently dropped. `verify` and `smtp-audit` both check this.
#  ---------------------------------------------------------------------------
#
#  DESIGN NOTES
#  ---------------------------------------------------------------------------
#  * 110 (POP3) and 143 (IMAP) are cleartext. Blocked on EVERY interface,
#    ahead of all allow rules. Users must use 993 / 995.
#
#  * Private addresses never match a GeoIP country. LAN and VPN sources
#    therefore need explicit allow rules -- the BD gate cannot cover them.
#
#  * The VPN pool is RFC1918. If VPN traffic arrives ROUTED (client IP intact)
#    on the WAN interface, the anti-spoof martian rule would drop it before any
#    allow rule. VPN_POOL_ON_WAN=1

# RFC1918 ranges permitted to send ICMP on the WAN interface (ping/traceroute
# for reachability checks). Only ICMP -- all other traffic from these ranges is
# still dropped by the martian rules below.
#    VPN_POOL_ON_WAN=1 inserts an exemption. Set it to 0 if your
#    VPN NATs clients to 103.7.248.x -- keeping martian filtering intact is
#    preferable when you can.
#
#  * The host reaches ITSELF over a real interface: saslauthd authenticates
#    against https://<fqdn>:7073, and RemoteManager (Mail Queues) uses SSH to
#    <fqdn>:22. Scoping the host's own IP too tightly breaks SMTP AUTH for
#    every user. See HOST_SELF_PORTS.
#
#  * Whitelists in v3 matched ALL PORTS, which gave Microsoft's 40.80.0.0/12
#    (1,048,576 addresses) a path to 7071, LDAP, MariaDB and memcached. v4
#    replaces every blanket whitelist with a port-scoped rule.
#
#  * Public DNS resolvers (8.8.8.8 etc.) were whitelisted inbound in v3. They
#    never need it -- their replies return via the ESTABLISHED rule. Removed.
#
#  * Let's Encrypt HTTP-01 validation comes from US/EU servers and cannot pass
#    the BD GeoIP gate. `le-open` opens port 80 worldwide for a bounded window
#    and closes it automatically. See the LE RENEWAL section at the bottom.
#==============================================================================

set -uo pipefail

IPSET_DIR="/etc/ipset"
TEMP_DIR="/tmp/netsets"
LOG_FILE="/var/log/netset-manager.log"
ROLLBACK_FILE="/var/backups/iptables-rollback.rules"
LE_STATE="/run/netset-le-window"

WAN_IFACE="ens4"
LAN_IFACE="ens3"

#==============================================================================
# BACKEND
# iptables-legacy and nft-backed iptables are SEPARATE stores and BOTH filter.
# Use whichever already holds the live ruleset so an upgrade never splits the
# firewall in half. Override with FORCE_IPT_BACKEND=legacy|nft.
#==============================================================================
FORCE_IPT_BACKEND="${FORCE_IPT_BACKEND:-auto}"

detect_backend() {
    local legacy_rules=0 nft_rules=0
    command -v iptables-legacy >/dev/null 2>&1 && \
        legacy_rules=$(iptables-legacy -S INPUT 2>/dev/null | grep -cvE '^-P INPUT')
    nft_rules=$(iptables -S INPUT 2>/dev/null | grep -cvE '^-P INPUT')
    case "$FORCE_IPT_BACKEND" in
        legacy) echo "legacy"; return ;;
        nft)    echo "nft";    return ;;
    esac
    if   [[ "$legacy_rules" -gt "$nft_rules" ]]; then echo "legacy"
    elif [[ "$nft_rules"    -gt 0 ]];            then echo "nft"
    elif command -v iptables-legacy >/dev/null 2>&1; then echo "legacy"
    else echo "nft"; fi
}

BACKEND="$(detect_backend)"
if [[ "$BACKEND" == "legacy" ]]; then
    IPT="iptables-legacy"; IPT_SAVE="iptables-legacy-save"; IPT_RESTORE="iptables-legacy-restore"
    IP6T="$(command -v ip6tables-legacy 2>/dev/null || true)"
else
    IPT="iptables";        IPT_SAVE="iptables-save";        IPT_RESTORE="iptables-restore"
    IP6T="$(command -v ip6tables 2>/dev/null || true)"
fi

check_dual_ruleset() {
    local l=0 n=0
    command -v iptables-legacy >/dev/null 2>&1 && l=$(iptables-legacy -S INPUT 2>/dev/null | grep -cvE '^-P INPUT')
    # Count the nft store DIRECTLY, not via `iptables` -- update-alternatives may
    # point `iptables` at the legacy binary, which would count legacy rules twice
    # and report a split that does not exist.
    if command -v iptables-nft >/dev/null 2>&1; then
        n=$(iptables-nft -S INPUT 2>/dev/null | grep -cvE '^-P INPUT')
    else
        n=$(iptables -S INPUT 2>/dev/null | grep -cvE '^-P INPUT')
    fi
    if [[ "$l" -gt 0 && "$n" -gt 0 ]]; then
        echo "*** WARNING: rules exist in BOTH iptables stores ***"
        echo "    iptables-legacy INPUT: $l    iptables(nft) INPUT: $n"
        echo "    Both filter traffic. Clear the unused one:"
        [[ "$BACKEND" == "legacy" ]] \
            && echo "      iptables -F INPUT; iptables -F FORWARD; iptables -F OUTPUT" \
            || echo "      iptables-legacy -F INPUT; iptables-legacy -F FORWARD; iptables-legacy -F OUTPUT"
        return 1
    fi
    return 0
}

#==============================================================================
# NETWORK GROUPS  --  edit these
#==============================================================================

# ADMIN -- full admin console + SSH. Smallest possible set.
ADMIN_NETS=(
#    "103.7.248.53/32"        # rkarim (public)
#    "103.229.83.240/29"      # admin/ISP range
    "192.168.77.154/32"      # office rkarim
    "192.168.77.155/32"      # office soiket
    "192.168.77.157/32"      # office sumon
    "172.23.47.54/32"        # office fidc rkarim
)

# OFFICE -- admin console + SSH, same rights as admin, separate list so you
# can revoke the floor without touching the ISP ranges.
OFFICE_NETS=()           # empty -- admin is per-host in ADMIN_NETS

# VPN -- mail + webmail, NO admin console, NO SSH.
#   The two /32s are the VPN concentrator public addresses.
#   The pool is what clients are assigned.
VPN_NETS=(
    "103.7.248.2/32"         # VPN gateway
    "103.7.248.11/32"        # VPN gateway
    "192.168.0.0/16"         # VPN client pool
)
# Does VPN traffic arrive on WAN with the client's RFC1918 address intact?
#   1 = yes, routed  -> exempt the pool from the martian drop
#   0 = no,  NATed   -> keep martian filtering fully intact  (preferred)
VPN_POOL_ON_WAN=0

# RFC1918 ranges permitted to send ICMP on the WAN interface (ping/traceroute).
# ICMP only -- all other traffic from these ranges is still dropped by MARTIAN.
MARTIAN_ICMP_EXEMPT="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16"

# RFC1918 ranges that legitimately arrive on the WAN interface because they are
# ROUTED to this host (see `ip route`). Fully exempt from martian filtering AND
# from the threat feeds -- FireHOL level1 includes bogons, which cover RFC1918,
# so a feed rule would otherwise drop all traffic from these ranges.
MARTIAN_FULL_EXEMPT="192.168.77.0/24 172.23.47.0/24 192.168.42.0/24 192.168.4.0/24 192.168.0.0/16 172.23.46.0/24"
# LAN -- office network reachable on ens3. Mail + webmail, no admin.
LAN_NETS=(
    "103.229.83.240/29"      # office NAT egress via OPNsense -- mail+webmail only
    "192.168.77.0/24"        # office -- mail + webmail only
    "192.168.42.0/24"
    "192.168.4.0/24"
    "192.168.44.16/32"
    "192.168.0.0/16"
    "172.23.46.150/32"
    "172.23.46.136/32"
    "172.23.47.54/32"
    "10.15.20.227/32"
)

# MX PARTNERS -- inbound SMTP only. Purpose is to exempt them from the
# threat-intel feeds, NOT to grant service access.
#   Microsoft = split delivery inbound from M365
#   MailPlus  = outbound relay; only needs 25 inbound for bounces/DSNs
# Verified against /var/log/zimbra.log delivery history on 01 Sep 2026.
# Observed sources: 40.93.129.50-123 and 104.47.23.239/241.
# 104.47.0.0/17 was MISSING from v4 -- mail from it would have been dropped
# with no bounce and no log entry, because the packet never arrives.
MX_NETS=(
    "40.80.0.0/12"           # Microsoft  (covers observed 40.93.129.x)
    "40.92.0.0/15"           # Microsoft EOP
    "40.107.0.0/16"          # Microsoft EOP
    "52.100.0.0/14"          # Microsoft EOP (covers observed 52.101.x)
    "104.47.0.0/17"          # Microsoft EOP -- ADDED v5, seen in live logs
    "154.59.193.0/24"        # MailPlus  (outbound relay; inbound = bounces/DSN)
    "154.59.104.0/24"        # MailPlus
    "149.13.75.0/24"         # MailPlus
)

# Internal systems that relay through port 25 WITHOUT SMTP AUTH, i.e. hosts
# covered by Postfix `mynetworks`. Keep in sync with `postconf mynetworks`:
#   - a host in mynetworks but NOT here  -> firewall blocks it, mail stops
#   - a host here but NOT in mynetworks  -> Postfix rejects it (relay denied)
# 103.7.248.53 is the NOC alerting / ticketing system (www-data@, swd@),
# ~3,939 messages observed. Removing it silently kills every NOC alert.
SMTP_RELAY_NETS=(
   "172.23.46.150/32"         # Forhad-TaskMGR App
   "172.23.46.136/32"         # Forhad-PRTG-Report-AAA Auth
#    "192.168.0.0/16"         # NOC alerting / ticketing

)

#SMTP_RELAY_NETS=(
#    "103.7.248.53/32"        # NOC alerting / ticketing
#    "103.118.87.168/32"      # pico-erp
#    "103.131.159.158/32"     # FGL alerting
#    "103.131.159.237/32"     # dev server (dev1@, root@)
#    "192.168.42.59/32"       # print manager
#)



# The server's own address. saslauthd and RemoteManager loop back via the FQDN,
# so this traffic traverses a real interface and hits the INPUT chain.
HOST_SELF_IP="10.17.20.163"
HOST_SELF_IP2="103.7.248.10"

#==============================================================================
# PORT GROUPS
#==============================================================================
SMTP_PORT="25"
# 0 = port 25 restricted to MX partners + host + SMTP_RELAY_NETS  (v5 default,
#     correct while MX points at M365)
# 1 = port 25 open worldwide  -- REQUIRED if the MX record is ever changed to
#     point directly at this server, or if you host a domain that receives
#     mail directly. Verify with: dig +short MX <domain>
SMTP_WORLD_OPEN=0
MAIL_CLIENT_PORTS="993,995,465,587"     # IMAPS, POP3S, SMTPS, submission
WEBMAIL_PORTS="80,443"                  # 80 unused today (mailMode https)
ADMIN_CONSOLE_PORTS="7071,8443"         # 8443 = mailboxd HTTPS behind nginx
SSH_PORTS="22,8022"
MX_PORTS="25"

# Cleartext -- blocked on every interface, ahead of every allow rule.
BLOCKED_ALWAYS="110,143"

# Ports the host must reach on itself:
#   7072/7073/7074 = nginx lookup + SASL auth  (breaking these breaks SMTP AUTH)
#   22             = RemoteManager / Mail Queues
#   7071           = admin console self-reference
HOST_SELF_PORTS="7025,7026,7072,7073,7074,22,7071,25"

# Public ports behind the GeoIP allowlist (WAN only).
GEOBLOCK_TCP_PORTS="587,465,995,993,80,443"
GEOBLOCK_UDP_PORTS="443"
ALLOWED_COUNTRIES="BD"

# Internal services -- hard DROP on both interfaces, after all allows.
INTERNAL_TCP_PORTS="7025,7026,7072,7073,7074,7993,7995,8080,7171,7306,10663,23232,23233"
INTERNAL_TCP_PORTS2="111,389,636,3310,8465,11211,10024:10032"
INTERNAL_UDP_PORTS="111,161,11211"
BLOCK_INTERNAL_ON_LAN=1

#==============================================================================
# RATE LIMITING / EGRESS / LOGGING
#==============================================================================
RATELIMIT_ENABLE=1
SMTP_RATE="90/min";   SMTP_BURST="120"
SUBMIT_RATE="30/min"; SUBMIT_BURST="60"
IMAP_RATE="90/min";   IMAP_BURST="99"
SSH_RATE="6/min";     SSH_BURST="10"

EGRESS_ENABLE=0
EGRESS_ALLOW_TCP="25,53,587,465,80,443"
EGRESS_ALLOW_UDP="53,123"


LOG_DROPS=1
LOG_LIMIT="5/min"


ALL_NETSETS=("firehol_level1" "firehol_level2" "firehol_level3" "firehol_level4" \
             "spamhaus_drop" "ci_badguys" "et_bl1" "et_bl2" "bl_de1" "bl_tfx" "bl_agr" \
             "crowdsec_bl" "greensnow" "binarydefense" "whitelist_mx" "manual_blacklist")
# whitelist_lan/whitelist_wan removed in v5 -- replaced by per-role -s rules

THREAT_LISTS=("firehol_level1" "firehol_level2" "firehol_level3" "firehol_level4" \
              "spamhaus_drop" "ci_badguys" "et_bl1" "et_bl2" "bl_de1" "bl_tfx" "bl_agr" "crowdsec_bl" "greensnow" "binarydefense")

log_message() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }
require_root() { [[ $EUID -ne 0 ]] && { echo "ERROR: must run as root"; exit 1; }; return 0; }

#==============================================================================
# IPSET MANAGEMENT
#==============================================================================
create_netset() {
    local name="$1" url="$2" description="$3"
    log_message "Processing $name: $description"
    mkdir -p "$TEMP_DIR"

    if curl -s --connect-timeout 30 --max-time 120 "$url" -o "$TEMP_DIR/$name.txt"; then
        # A feed that 404s must leave the previous list intact, never wipe it.
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
            [[ -n "$network" ]] && ipset add "${name}_temp" "$network" 2>/dev/null && ((count++))
        done < "$TEMP_DIR/$name.txt"

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

create_mx_whitelist() {
    ipset create "whitelist_mx" hash:net hashsize 1024 maxelem 10000 -exist
    ipset flush "whitelist_mx"
    local n=0
    for network in "${MX_NETS[@]}"; do
        ipset add "whitelist_mx" "$network" 2>/dev/null && ((n++))
    done
    ipset save "whitelist_mx" > "$IPSET_DIR/whitelist_mx.save"
    log_message "Created whitelist_mx with $n entries (port(s) $MX_PORTS only)"
}

create_manual_blacklist() {
    ipset create "manual_blacklist" hash:net hashsize 1024 maxelem 50000 -exist
    if [[ -f "$IPSET_DIR/manual_blacklist.save" ]]; then
        ipset restore -exist < "$IPSET_DIR/manual_blacklist.save" 2>/dev/null
        log_message "Restored manual blacklist with $(ipset list manual_blacklist | grep -c '^[0-9]') entries"
    else
        log_message "Manual blacklist initialized (empty)"
    fi
}

#==============================================================================
# RULE HELPERS
#==============================================================================
# allow_group <-name-> <port-list> <nets...>   -- port-scoped ACCEPT, no iface
allow_group() {
    local label="$1" ports="$2"; shift 2
    local net
    for net in "$@"; do
        $IPT -A INPUT -s "$net" -p tcp -m multiport --dports "$ports" -j ACCEPT
    done
    log_message "  $label -> ports $ports : $*"
}

setup_geoip_rules() {
    # Fail OPEN when the DB is empty: an empty xt_geoip DB matches nothing, so
    # a negated allowlist would DROP every source including BD -- a total
    # outage rather than "no protection". Skip and log loudly instead.
    local n
    n=$(find /usr/share/xt_geoip -mindepth 1 -type f 2>/dev/null | wc -l)
    if [[ "$n" -eq 0 ]]; then
        log_message "WARNING: xt_geoip empty -- GeoIP allowlist SKIPPED (failing open)"
        return 0
    fi
    $IPT -A INPUT -i "$WAN_IFACE" -p tcp -m multiport --dports "$GEOBLOCK_TCP_PORTS" \
        -m geoip ! --src-cc "$ALLOWED_COUNTRIES" -j NETSET_DROP
    [[ -n "$GEOBLOCK_UDP_PORTS" ]] && \
        $IPT -A INPUT -i "$WAN_IFACE" -p udp -m multiport --dports "$GEOBLOCK_UDP_PORTS" \
            -m geoip ! --src-cc "$ALLOWED_COUNTRIES" -j NETSET_DROP
    log_message "GeoIP allowlist [$ALLOWED_COUNTRIES] on $GEOBLOCK_TCP_PORTS ($WAN_IFACE)"
}

setup_ratelimit_rules() {
    [[ "$RATELIMIT_ENABLE" -ne 1 ]] && return 0
    $IPT -A INPUT -i "$WAN_IFACE" -p tcp --dport "$SMTP_PORT" -m conntrack --ctstate NEW \
        -m hashlimit --hashlimit-above "$SMTP_RATE" --hashlimit-burst "$SMTP_BURST" \
        --hashlimit-mode srcip --hashlimit-name smtp_flood -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -p tcp -m multiport --dports 587,465 -m conntrack --ctstate NEW \
        -m hashlimit --hashlimit-above "$SUBMIT_RATE" --hashlimit-burst "$SUBMIT_BURST" \
        --hashlimit-mode srcip --hashlimit-name submit_bf -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -p tcp -m multiport --dports 993,995 -m conntrack --ctstate NEW \
        -m hashlimit --hashlimit-above "$IMAP_RATE" --hashlimit-burst "$IMAP_BURST" \
        --hashlimit-mode srcip --hashlimit-name imap_bf -j NETSET_DROP
    $IPT -A INPUT -p tcp -m multiport --dports "$SSH_PORTS" -m conntrack --ctstate NEW \
        -m hashlimit --hashlimit-above "$SSH_RATE" --hashlimit-burst "$SSH_BURST" \
        --hashlimit-mode srcip --hashlimit-name ssh_bf -j NETSET_DROP
    log_message "Rate limits: smtp=$SMTP_RATE submit=$SUBMIT_RATE imap=$IMAP_RATE ssh=$SSH_RATE"
}

setup_egress_rules() {
    if [[ "$EGRESS_ENABLE" -ne 1 ]]; then
        $IPT -P OUTPUT ACCEPT
        log_message "Egress filtering DISABLED -- OUTPUT remains ACCEPT"
        return 0
    fi
    $IPT -F OUTPUT
    $IPT -A OUTPUT -o lo -j ACCEPT
    $IPT -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    $IPT -A OUTPUT -p tcp -m multiport --dports "$EGRESS_ALLOW_TCP" -j ACCEPT
    $IPT -A OUTPUT -p udp -m multiport --dports "$EGRESS_ALLOW_UDP" -j ACCEPT
    $IPT -A OUTPUT -p icmp -j ACCEPT
    [[ "$LOG_DROPS" -eq 1 ]] && \
        $IPT -A OUTPUT -m limit --limit "$LOG_LIMIT" -j LOG --log-prefix "EGRESS-DROP: "
    $IPT -A OUTPUT -j DROP
    log_message "Egress allowlist: tcp=$EGRESS_ALLOW_TCP udp=$EGRESS_ALLOW_UDP"
}

#==============================================================================
# MAIN RULESET
#==============================================================================
apply_all_rules() {
    log_message "=== applying ruleset (v5, role-based) ==="

    $IPT -F INPUT; $IPT -F FORWARD
    $IPT -P INPUT ACCEPT; $IPT -P FORWARD ACCEPT

    $IPT -N NETSET_DROP 2>/dev/null; $IPT -F NETSET_DROP
    [[ "$LOG_DROPS" -eq 1 ]] && \
        $IPT -A NETSET_DROP -m limit --limit "$LOG_LIMIT" -j LOG --log-prefix "NETSET-DROP: "
    $IPT -A NETSET_DROP -j DROP

    # -- 1. Loopback ---------------------------------------------------------
    $IPT -A INPUT -i lo -j ACCEPT

    # -- 2/3. Anti-spoof / martians, in a CUSTOM chain ----------------------
    #
    # The martian checks live in their own chain for one specific reason: the
    # VPN pool is RFC1918 and must be exempted from the 192.168.0.0/16 drop.
    #
    # An exemption CANNOT use `-j RETURN` in the built-in INPUT chain -- in a
    # built-in chain RETURN falls through to the chain POLICY, which is ACCEPT
    # here, so the exempted source would bypass every later rule including the
    # cleartext block and the admin-port DROP. Inside a custom chain, RETURN
    # correctly resumes evaluation in INPUT at the rule after the jump.
    #
    $IPT -N MARTIAN 2>/dev/null; $IPT -F MARTIAN

    if [[ "$VPN_POOL_ON_WAN" -eq 1 ]]; then
        for net in "${VPN_NETS[@]}"; do
            case "$net" in
                10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*)
                    $IPT -A MARTIAN -s "$net" -j RETURN
                    log_message "VPN pool $net exempted from martian drop on $WAN_IFACE" ;;
            esac
        done
    fi

    # Allow ICMP from the VPN/office RFC1918 space for reachability testing,
    # while still dropping all other RFC1918 traffic on the public interface.
    if [[ -n "${MARTIAN_ICMP_EXEMPT:-}" ]]; then
        for _n in $MARTIAN_ICMP_EXEMPT; do
            $IPT -A MARTIAN -s "$_n" -p icmp -j RETURN
            log_message "MARTIAN: ICMP exempted for $_n on $WAN_IFACE"
        done
    fi

    # RFC1918 + link-local + multicast/reserved arriving on the PUBLIC iface
    $IPT -A MARTIAN -s 10.0.0.0/8     -j NETSET_DROP
    $IPT -A MARTIAN -s 172.16.0.0/12  -j NETSET_DROP
    $IPT -A MARTIAN -s 192.168.0.0/16 -j NETSET_DROP
    $IPT -A MARTIAN -s 169.254.0.0/16 -j NETSET_DROP
    $IPT -A MARTIAN -s 224.0.0.0/4    -j NETSET_DROP
    $IPT -A MARTIAN -s 240.0.0.0/4    -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -j MARTIAN

    # Loopback space on a real NIC is always spoofed, on any interface
    $IPT -A INPUT ! -i lo -s 127.0.0.0/8 -j NETSET_DROP
    # Invalid state and stealth-scan packets
    $IPT -A INPUT -m conntrack --ctstate INVALID -j NETSET_DROP
    $IPT -A INPUT -p tcp ! --syn -m conntrack --ctstate NEW -j NETSET_DROP
    $IPT -A INPUT -p tcp --tcp-flags ALL NONE -j NETSET_DROP
    $IPT -A INPUT -p tcp --tcp-flags ALL ALL  -j NETSET_DROP

    # -- 4. CLEARTEXT PORTS -- blocked everywhere, ahead of every allow -----
    # 110/143 transmit credentials in the clear. No source, on any interface,
    # may reach them. Encrypted equivalents 993/995 remain open.
    $IPT -A INPUT ! -i lo -p tcp -m multiport --dports "$BLOCKED_ALWAYS" -j NETSET_DROP
    log_message "Cleartext ports $BLOCKED_ALWAYS BLOCKED on all interfaces"

    # -- 4a. Routed RFC1918 -- full exemption from martians AND feeds --------
    if [[ -n "${MARTIAN_FULL_EXEMPT:-}" ]]; then
        for _n in $MARTIAN_FULL_EXEMPT; do
            $IPT -I MARTIAN 1 -s "$_n" -j RETURN
            log_message "MARTIAN: full exemption for routed range $_n"
        done
    fi

    # -- 4b. ICMP from RFC1918 -- accepted here, ahead of the threat feeds ---
    # The feed rules match ALL protocols, and FireHOL level1 includes bogons
    # (which contain RFC1918). Without this, ICMP that passed MARTIAN is still
    # dropped by the feeds. Rate-limited, same as public ICMP.
    if [[ -n "${MARTIAN_ICMP_EXEMPT:-}" ]]; then
        for _n in $MARTIAN_ICMP_EXEMPT; do
            $IPT -A INPUT -s "$_n" -p icmp --icmp-type echo-request \
                 -m limit --limit 5/sec --limit-burst 10 -j ACCEPT
        done
        log_message "ICMP accepted from: $MARTIAN_ICMP_EXEMPT (ahead of feeds)"
    fi

    # -- 5. Established / related -------------------------------------------
    $IPT -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # -- 6. Host itself (saslauthd + RemoteManager) -------------------------
    # saslauthd authenticates against https://<fqdn>:7073 -- NOT loopback.
    # Removing this breaks SMTP AUTH for every user.
    # The FQDN resolves to the PUBLIC address, so LMTP (7025), saslauthd (7073)
    # and RemoteManager (22) all loop back via 103.7.248.10, not the internal IP.
    # Missing 7025 here stalls ALL local mail delivery.
    for _self in "$HOST_SELF_IP" "${HOST_SELF_IP2:-}"; do
        [[ -z "$_self" ]] && continue
        $IPT -A INPUT -s "$_self" -p tcp -m multiport --dports "$HOST_SELF_PORTS" -j ACCEPT
        log_message "Host self $_self -> $HOST_SELF_PORTS"
    done

    # -- 7. ADMIN + OFFICE : console, SSH, mail, webmail --------------------
    log_message "Admin/office access:"
    allow_group "ADMIN  console+ssh" "${ADMIN_CONSOLE_PORTS},${SSH_PORTS}" "${ADMIN_NETS[@]}"
    allow_group "OFFICE console+ssh" "${ADMIN_CONSOLE_PORTS},${SSH_PORTS}" "${OFFICE_NETS[@]}"
    allow_group "ADMIN  mail+web"    "${MAIL_CLIENT_PORTS},${WEBMAIL_PORTS}" "${ADMIN_NETS[@]}"
    allow_group "OFFICE mail+web"    "${MAIL_CLIENT_PORTS},${WEBMAIL_PORTS}" "${OFFICE_NETS[@]}"

    # -- 8. VPN + LAN : mail and webmail only, NO admin console, NO SSH -----
    log_message "VPN/LAN access:"
    allow_group "VPN mail+web" "${MAIL_CLIENT_PORTS},${WEBMAIL_PORTS}" "${VPN_NETS[@]}"
    allow_group "LAN mail+web" "${MAIL_CLIENT_PORTS},${WEBMAIL_PORTS}" "${LAN_NETS[@]}"

    # -- 9. Admin ports closed to everyone else -----------------------------
    # Placed AFTER the allows above so listed sources already matched.
    $IPT -A INPUT -p tcp -m multiport --dports "${ADMIN_CONSOLE_PORTS},${SSH_PORTS}" -j NETSET_DROP
    log_message "Admin ports ${ADMIN_CONSOLE_PORTS},${SSH_PORTS} closed to all other sources"

    # -- 10. Rate limiting ---------------------------------------------------
    setup_ratelimit_rules

    # -- 11. MX partners : port 25 only -------------------------------------
    # Ahead of the threat feeds so a false positive cannot block M365 mail.
    if ipset list "whitelist_mx" >/dev/null 2>&1; then
        $IPT -A INPUT -i "$WAN_IFACE" -m set --match-set "whitelist_mx" src \
             -p tcp -m multiport --dports "$MX_PORTS" -j ACCEPT
        log_message "MX partners -> port(s) $MX_PORTS only (feed-exempt)"
    fi

    # -- 12. GeoIP allowlist -------------------------------------------------
    setup_geoip_rules

    # -- 13. Manual blacklist (WAN) -----------------------------------------
    ipset list "manual_blacklist" >/dev/null 2>&1 && \
        $IPT -A INPUT -i "$WAN_IFACE" -m set --match-set "manual_blacklist" src -j NETSET_DROP

    # -- 14. Threat-intel feeds (WAN) ---------------------------------------
    for bl in "${THREAT_LISTS[@]}"; do
        ipset list "$bl" >/dev/null 2>&1 && \
            $IPT -A INPUT -i "$WAN_IFACE" -m set --match-set "$bl" src -j NETSET_DROP
    done

    # -- 15. Public services -------------------------------------------------
    # PORT 25 IS NOT WORLD-OPEN in v5.
    #   dig MX fiberathome.net -> 0 fiberathome-net.mail.protection.outlook.com
    # All external inbound therefore arrives via M365 split delivery, which was
    # already permitted at step 11. Internal relays are allowed here, then 25
    # is closed to everything else.
    #
    # WARNING: if the MX record ever changes to point directly at this host,
    # this DROP silently blocks ALL inbound mail. Re-check with `smtp-audit`
    # before and after any MX change.
    if [[ "$SMTP_WORLD_OPEN" -eq 1 ]]; then
        $IPT -A INPUT -p tcp --dport "$SMTP_PORT" -j ACCEPT
        log_message "Port $SMTP_PORT: WORLD-OPEN (SMTP_WORLD_OPEN=1)"
    else
        allow_group "SMTP relay" "$SMTP_PORT" "${SMTP_RELAY_NETS[@]}"
        $IPT -A INPUT -p tcp --dport "$SMTP_PORT" -j NETSET_DROP
        log_message "Port $SMTP_PORT: MX partners + host self + SMTP_RELAY_NETS only"
    fi

    # The rest already passed the BD GeoIP gate at step 12.
    $IPT -A INPUT -p tcp -m multiport --dports "${MAIL_CLIENT_PORTS},${WEBMAIL_PORTS}" -j ACCEPT
    log_message "Public: ${MAIL_CLIENT_PORTS},${WEBMAIL_PORTS} via GeoIP [$ALLOWED_COUNTRIES]"

    # -- 16. Internal services -- hard DROP ---------------------------------
    $IPT -A INPUT -i "$WAN_IFACE" -p tcp -m multiport --dports "$INTERNAL_TCP_PORTS"  -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -p tcp -m multiport --dports "$INTERNAL_TCP_PORTS2" -j NETSET_DROP
    $IPT -A INPUT -i "$WAN_IFACE" -p udp -m multiport --dports "$INTERNAL_UDP_PORTS"  -j NETSET_DROP
    if [[ "$BLOCK_INTERNAL_ON_LAN" -eq 1 ]]; then
        $IPT -A INPUT -i "$LAN_IFACE" -p tcp -m multiport --dports "$INTERNAL_TCP_PORTS"  -j NETSET_DROP
        $IPT -A INPUT -i "$LAN_IFACE" -p tcp -m multiport --dports "$INTERNAL_TCP_PORTS2" -j NETSET_DROP
        $IPT -A INPUT -i "$LAN_IFACE" -p udp -m multiport --dports "$INTERNAL_UDP_PORTS"  -j NETSET_DROP
    fi
    log_message "Internal ports blocked on $WAN_IFACE and $LAN_IFACE"

    # -- 17. ICMP (rate-limited) ---------------------------------------------
    $IPT -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/sec --limit-burst 10 -j ACCEPT
    $IPT -A INPUT -p icmp --icmp-type echo-request -j NETSET_DROP
    $IPT -A INPUT -p icmp -j ACCEPT

    # -- 18. Default deny ----------------------------------------------------
    # Trailing rule rather than -P INPUT DROP: a script that dies midway then
    # fails OPEN instead of locking you out of a remote box.
    $IPT -A FORWARD -j DROP
    $IPT -A INPUT -j NETSET_DROP

    # -- 19. Egress ----------------------------------------------------------
    setup_egress_rules

    # -- 20. IPv6 lockdown ---------------------------------------------------
    if [[ -n "$IP6T" ]]; then
        $IP6T -F 2>/dev/null
        $IP6T -P INPUT DROP 2>/dev/null
        $IP6T -P FORWARD DROP 2>/dev/null
        $IP6T -A INPUT -i lo -j ACCEPT 2>/dev/null
        log_message "IPv6 locked down"
    fi

    # Re-assert an open LE window if one is active
    [[ -f "$LE_STATE" ]] && le_insert_rule

    log_message "=== ruleset applied ==="
}

#==============================================================================
# LET'S ENCRYPT RENEWAL WINDOW
#------------------------------------------------------------------------------
# HTTP-01 validation originates from Let's Encrypt servers in the US and EU.
# Those sources cannot pass the BD GeoIP gate, so port 80 must be opened
# worldwide for the duration of the challenge.
#
#   le-open [minutes]   open port 80 to the world, auto-close after N (default 15)
#   le-close            close it immediately
#   le-status           is a window currently open, and for how much longer
#
# The rule is inserted at the TOP of INPUT so it precedes the GeoIP drop.
# A state file under /run means the window does not survive a reboot.
#
# NOTE: DNS-01 validation needs none of this. If you move to the PowerDNS API
# method, port 80 stays closed permanently. This exists for manual HTTP-01.
#==============================================================================
le_insert_rule() {
    $IPT -C INPUT -p tcp --dport 80 -m comment --comment "LE-WINDOW" -j ACCEPT 2>/dev/null \
      || $IPT -I INPUT 1 -p tcp --dport 80 -m comment --comment "LE-WINDOW" -j ACCEPT
}

le_remove_rule() {
    while $IPT -C INPUT -p tcp --dport 80 -m comment --comment "LE-WINDOW" -j ACCEPT 2>/dev/null; do
        $IPT -D INPUT -p tcp --dport 80 -m comment --comment "LE-WINDOW" -j ACCEPT
    done
}

le_open() {
    local mins="${1:-15}"
    le_insert_rule
    date -d "+${mins} minutes" +%s > "$LE_STATE"
    log_message "LE WINDOW OPEN -- port 80 world-reachable for ${mins} minutes"

    # Detached auto-close so a dropped SSH session cannot leave port 80 open
    setsid bash -c "sleep $((mins*60)); \
        if [[ -f '$LE_STATE' ]]; then \
            $IPT -D INPUT -p tcp --dport 80 -m comment --comment 'LE-WINDOW' -j ACCEPT 2>/dev/null; \
            rm -f '$LE_STATE'; \
            logger -t netset-manager 'LE WINDOW auto-closed after ${mins} minutes'; \
        fi" >/dev/null 2>&1 &

    cat <<BANNER

  Port 80 is now open worldwide. Auto-closes in ${mins} minutes.

  Run the renewal now, then close early:
      certbot renew --standalone
      $0 le-close

BANNER
}

le_close() {
    le_remove_rule
    rm -f "$LE_STATE"
    log_message "LE WINDOW CLOSED -- port 80 back under GeoIP control"
}

le_status() {
    if [[ -f "$LE_STATE" ]]; then
        local left=$(( $(cat "$LE_STATE") - $(date +%s) ))
        if [[ "$left" -gt 0 ]]; then
            echo "LE window OPEN -- $((left/60))m $((left%60))s remaining"
        else
            echo "LE window expired but rule may remain -- run: $0 le-close"
        fi
    else
        echo "LE window closed (port 80 under GeoIP control)"
    fi
    $V -S INPUT 2>/dev/null | grep -c 'LE-WINDOW' | xargs -I{} echo "LE rule count: {}"
}

#==============================================================================
# SAVE / RESTORE / ROLLBACK
#==============================================================================
save_rules() {
    mkdir -p "$IPSET_DIR"
    for s in "${ALL_NETSETS[@]}"; do
        if ipset list "$s" >/dev/null 2>&1; then
            # Never overwrite a good save file with an empty set
            if [[ "$(ipset list "$s" | grep -c '^[0-9]')" -gt 0 ]]; then
                ipset save "$s" > "$IPSET_DIR/$s.save"
            else
                log_message "WARNING: $s is empty -- keeping previous save file"
            fi
        fi
    done
    $IPT_SAVE > "$IPSET_DIR/iptables.save"
    log_message "Rules saved to disk"
}

snapshot_rules() {
    mkdir -p "$(dirname "$ROLLBACK_FILE")"
    $IPT_SAVE > "$ROLLBACK_FILE"
    log_message "Rollback snapshot -> $ROLLBACK_FILE"
}

apply_safe() {
    local wait_secs="${1:-300}"
    rm -f /tmp/.netset-confirmed
    snapshot_rules
    log_message "SAFE APPLY -- auto-rollback in ${wait_secs}s unless confirmed"
    ( sleep "$wait_secs"
      if [[ -f /tmp/.netset-confirmed ]]; then
          rm -f /tmp/.netset-confirmed
          logger -t netset-manager "SAFE APPLY confirmed"
      else
          $IPT_RESTORE < "$ROLLBACK_FILE"
          logger -t netset-manager "AUTO-ROLLBACK after ${wait_secs}s"
      fi ) &
    local wd=$!
    apply_all_rules
    cat <<BANNER

===============================================================
  RULES APPLIED -- NOT YET PERMANENT
===============================================================
  Auto-rollback in ${wait_secs}s unless you confirm.

  From a SECOND session verify:
    - SSH still works
    - https://webmail.fiberathome.net:7071 loads
    - SMTP AUTH:  tail -f /var/log/zimbra.log | grep auth_zimbra
    - Mail flows: tail -f /var/log/zimbra.log | grep postfix/smtpd

  Then run:   $0 confirm
===============================================================
  Watchdog PID: $wd
BANNER
}

handle_update() {
    log_message "Starting netset update"
    create_mx_whitelist
    create_manual_blacklist
    create_netset "firehol_level1" "https://iplists.firehol.org/files/firehol_level1.netset" "FireHOL Level1"
    create_netset "firehol_level2" "https://iplists.firehol.org/files/firehol_level2.netset" "FireHOL Level2"
    create_netset "firehol_level3" "https://iplists.firehol.org/files/firehol_level3.netset" "FireHOL Level3"
    create_netset "firehol_level4" "https://iplists.firehol.org/files/firehol_level4.netset" "FireHOL Level4"
    create_netset "spamhaus_drop"  "https://www.spamhaus.org/drop/drop.txt" "Spamhaus DROP"
    create_netset "ci_badguys"     "https://cinsscore.com/list/ci-badguys.txt" "CI-Badguys"
    create_netset "et_bl1"         "https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt" "ET BLOCK1"
    create_netset "et_bl2"         "https://rules.emergingthreats.net/blockrules/compromised-ips.txt" "ET Compro"
    create_netset "bl_de1"         "https://lists.blocklist.de/lists/all.txt" "Blocklist DE"
    create_netset "bl_agr"         "https://feodotracker.abuse.ch/downloads/ipblocklist_aggressive.txt" "BL Aggr"
    create_netset "bl_tfx"         "https://raw.githubusercontent.com/elliotwutingfeng/ThreatFox-IOC-IPs/refs/heads/main/ips.txt" "BL TFX"    
    create_netset "crowdsec_bl"    "http://crowdsecabl.inetsecurity.net:41412/security/blocklist?ipv4only" "CrowdSec BL"
    create_netset "greensnow"      "https://blocklist.greensnow.co/greensnow.txt" "GreenSnow bruteforce"
    create_netset "binarydefense"  "https://www.binarydefense.com/banlist.txt" "Binary Defense"
    apply_all_rules
    save_rules
    log_message "Netset update completed"
}

handle_restore() {
    log_message "Restoring ipsets from saved files"
    for f in "$IPSET_DIR"/*.save; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == "iptables.save" ]] && continue
        ipset restore -exist < "$f" 2>/dev/null
        log_message "Restored $(basename "$f" .save)"
    done
    create_mx_whitelist          # rebuilt from config, never from a stale file
    apply_all_rules
    save_rules
}

#==============================================================================
# VERIFY / AUDIT
#==============================================================================
verify_rules() {
    local V
    if [ "$(iptables-legacy -S INPUT 2>/dev/null | grep -cv '^-P')" -gt 0 ]; then
        V=iptables-legacy
    else
        V=iptables-nft
    fi
    # $IPT may be the alternatives wrapper, which prints a legacy-tables warning
    # on stdout and corrupts every pipeline below. Read the store directly.
    echo "=== Ruleset verification (v5) ==="
    echo "Backend: $IPT   (FORCE_IPT_BACKEND=$FORCE_IPT_BACKEND)"
    echo
    local problems=0
    check_dual_ruleset || ((problems++))

    printf "%-34s" "Default-deny on INPUT ......."
    $V -S INPUT 2>/dev/null | tail -1 | grep -q 'NETSET_DROP' && echo "OK" || { echo "MISSING"; ((problems++)); }

    printf "%-34s" "Cleartext 110/143 blocked ..."
    $V -S INPUT 2>/dev/null | grep -q -- "--dports $BLOCKED_ALWAYS" && echo "OK" || { echo "MISSING"; ((problems++)); }

    printf "%-34s" "Anti-spoof active ..........."
    if $V -S INPUT 2>/dev/null | grep -q '127.0.0.0/8' && $V -S MARTIAN 2>/dev/null | grep -q '192.168.0.0/16'; then echo "OK"
    else echo "MISSING"; ((problems++)); fi

    printf "%-34s" "No RETURN leak in INPUT ....."
    # RETURN in a built-in chain falls through to the policy (ACCEPT) and would
    # bypass every later rule. It must only ever appear inside MARTIAN.
    if $V -S INPUT 2>/dev/null | grep -q -- '-j RETURN'; then
        echo "FAIL -- RETURN in INPUT bypasses all later rules"; ((problems++))
    else echo "OK"; fi

    printf "%-34s" "Admin ports restricted ......"
    $V -S INPUT 2>/dev/null | grep -q "dports ${ADMIN_CONSOLE_PORTS//,/,}.*NETSET_DROP" && echo "OK" || echo "check manually"

    printf "%-34s" "Port 25 NOT geo-gated ......."
    [[ ",$GEOBLOCK_TCP_PORTS," == *",25,"* ]] && { echo "FAIL -- foreign mail would drop"; ((problems++)); } || echo "OK"

    printf "%-34s" "Host-self SASL path ........."
     $V -S INPUT 2>/dev/null | grep -q "$HOST_SELF_IP" && echo "OK" || { echo "MISSING -- SMTP AUTH will fail"; ((problems++)); }

    printf "%-34s" "Port 25 policy .............."
    if [[ "$SMTP_WORLD_OPEN" -eq 1 ]]; then echo "world-open"
    elif dig +short MX fiberathome.net 2>/dev/null | grep -qi 'protection.outlook.com'; then
        echo "restricted (MX -> M365, correct)"
    else
        echo "RESTRICTED but MX is NOT M365 -- inbound mail will drop"; ((problems++))
    fi

    printf "%-34s" "MX partners port-scoped ....."
    if $V -S INPUT 2>/dev/null | grep -q 'whitelist_mx'; then
        $V -S INPUT 2>/dev/null | grep 'whitelist_mx' | grep -q -- '--dports' && echo "OK" \
            || { echo "UNSCOPED -- grants all ports"; ((problems++)); }
    else echo "not loaded"; fi

    printf "%-34s" "GeoIP database .............."
    local n; n=$(find /usr/share/xt_geoip -mindepth 1 -type f 2>/dev/null | wc -l)
    [[ "$n" -gt 0 ]] && echo "OK ($n files)" || { echo "EMPTY -- failing open"; ((problems++)); }

    printf "%-34s" "Threat lists ................"
    local loaded=0
    for b in "${THREAT_LISTS[@]}"; do ipset list "$b" >/dev/null 2>&1 && ((loaded++)); done
    echo "$loaded/${#THREAT_LISTS[@]}"
    [[ "$loaded" -lt 5 ]] && ((problems++))

    printf "%-34s" "memcached not public ........"
    ss -4 -tln 2>/dev/null | grep -qE '0\.0\.0\.0:11211' \
        && { echo "on 0.0.0.0 -- rebind to 127.0.0.1"; ((problems++)); } || echo "OK"

    printf "%-34s" "LE window ..................."
    [[ -f "$LE_STATE" ]] && echo "OPEN -- port 80 world-reachable" || echo "closed"

    printf "%-34s" "Egress filtering ............"
    [[ "$EGRESS_ENABLE" -eq 1 ]] && echo "ENABLED" || echo "disabled"

    echo
    [[ "$problems" -eq 0 ]] && echo "No problems detected." || echo "$problems item(s) need attention."
}

show_access_matrix() {
    cat <<MATRIX
=== Effective access (from current configuration) ===

ADMIN            ${ADMIN_NETS[*]}
  -> console ${ADMIN_CONSOLE_PORTS}, ssh ${SSH_PORTS}, mail ${MAIL_CLIENT_PORTS}, web ${WEBMAIL_PORTS}

OFFICE           ${OFFICE_NETS[*]}
  -> console ${ADMIN_CONSOLE_PORTS}, ssh ${SSH_PORTS}, mail ${MAIL_CLIENT_PORTS}, web ${WEBMAIL_PORTS}

VPN              ${VPN_NETS[*]}
  -> mail ${MAIL_CLIENT_PORTS}, web ${WEBMAIL_PORTS}    (NO console, NO ssh)
     martian exemption on ${WAN_IFACE}: $([[ $VPN_POOL_ON_WAN -eq 1 ]] && echo ENABLED || echo disabled)

LAN (${LAN_IFACE})       ${LAN_NETS[*]}
  -> mail ${MAIL_CLIENT_PORTS}, web ${WEBMAIL_PORTS}    (NO console, NO ssh)

MX PARTNERS      $(ipset list whitelist_mx 2>/dev/null | grep -c '^[0-9]') networks
  -> port ${MX_PORTS} ONLY, exempt from threat feeds

HOST SELF        ${HOST_SELF_IP}
  -> ${HOST_SELF_PORTS}   (saslauthd 7073 + RemoteManager 22)

SMTP RELAY       ${SMTP_RELAY_NETS[*]}
  -> port ${SMTP_PORT} (relays via Postfix mynetworks, no SMTP AUTH)

PUBLIC
  -> port ${SMTP_PORT}: $([[ $SMTP_WORLD_OPEN -eq 1 ]] && echo "OPEN worldwide" || echo "CLOSED -- MX partners only (MX points at M365)")
  -> ${GEOBLOCK_TCP_PORTS} from [${ALLOWED_COUNTRIES}] only

BLOCKED FOR ALL  ${BLOCKED_ALWAYS} (cleartext POP3/IMAP), all internal ports
MATRIX
}

# Who actually connects to port 25, and is mynetworks dangerously wide?
smtp_audit() {
    echo "=== SMTP / port 25 audit ==="
    echo
    echo "MX record:"
    dig +short MX fiberathome.net 2>/dev/null | sed 's/^/  /'
    echo
    if dig +short MX fiberathome.net 2>/dev/null | grep -qi 'protection.outlook.com'; then
        echo "  -> M365 split delivery. Restricting port 25 is CORRECT."
    else
        echo "  -> *** MX does NOT point at M365. Set SMTP_WORLD_OPEN=1 or"
        echo "         inbound mail will be silently dropped. ***"
    fi
    echo
    echo "Firewall policy for port 25:"
    [[ "$SMTP_WORLD_OPEN" -eq 1 ]] \
        && echo "  WORLD-OPEN" \
        || echo "  Restricted: MX partners + $HOST_SELF_IP + ${SMTP_RELAY_NETS[*]}"
    echo
    echo "Sources seen delivering on 25 (from zimbra.log):"
    grep -hoE 'client=[^ ]*\[[0-9]{1,3}(\.[0-9]{1,3}){3}\]' /var/log/zimbra.log 2>/dev/null \
      | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sort | uniq -c | sort -rn | head -20 \
      | while read -r count ip; do
            local verdict="NOT COVERED -- would be blocked"
            ipset test whitelist_mx "$ip" >/dev/null 2>&1 && verdict="covered (MX partner)"
            [[ "$ip" == "127.0.0.1" || "$ip" == "$HOST_SELF_IP" ]] && verdict="covered (host self)"
            for n in "${SMTP_RELAY_NETS[@]}"; do
                [[ "$ip" == "${n%/*}" ]] && verdict="covered (SMTP_RELAY_NETS)"
            done
            printf "  %8s  %-16s %s\n" "$count" "$ip" "$verdict"
        done
    echo
    echo "Postfix mynetworks (relay WITHOUT authentication):"
    local mynets
    mynets=$(su - zimbra -c 'postconf -h mynetworks' 2>/dev/null)
    echo "  $mynets"
    echo
    echo "  Public ranges in mynetworks -- each address here can relay mail"
    echo "  as any sender, with no password:"
    local found=0
    for n in $mynets; do
        case "$n" in
            127.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|\[*|"") continue ;;
        esac
        local bits="${n#*/}"; [[ "$bits" == "$n" ]] && bits=32
        printf "    %-22s ~%s addresses\n" "$n" "$(( 2 ** (32 - bits) ))"
        found=1
    done
    [[ "$found" -eq 0 ]] && echo "    (none -- good)"
    echo
    echo "  Narrow these to the specific hosts that appear above."
}

show_listeners() {
    echo "=== Live listener audit ==="
    printf "%-6s %-24s %-20s %s\n" "PROTO" "LOCAL" "PROCESS" "VERDICT"
    ss -4 -tulpn 2>/dev/null | tail -n +2 | while read -r netid state recvq sendq local peer rest; do
        local port="${local##*:}" addr="${local%:*}" proc verdict
        [[ "$netid" == "udp" && "$port" -gt 20000 ]] && continue
        proc=$(echo "$rest" | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p')
        if [[ "$addr" == "127.0.0.1" ]]; then verdict="OK (loopback)"
        elif [[ ",${SMTP_PORT},${MAIL_CLIENT_PORTS},${WEBMAIL_PORTS}," == *",$port,"* ]]; then verdict="OK (public service)"
        elif [[ ",${ADMIN_CONSOLE_PORTS},${SSH_PORTS}," == *",$port,"* ]]; then verdict="OK (admin, firewalled)"
        elif [[ ",${BLOCKED_ALWAYS}," == *",$port,"* ]]; then verdict="BLOCKED by firewall -- consider disabling in Zimbra"
        elif [[ "$addr" == "0.0.0.0" ]]; then verdict="REBIND -> 127.0.0.1"
        else verdict="review ($addr)"; fi
        printf "%-6s %-24s %-20s %s\n" "$netid" "$local" "${proc:-?}" "$verdict"
    done
}

add_manual_block() {
    local n="$1"
    [[ -z "$n" ]] && { echo "Usage: $0 block-ip <ip/net>"; exit 1; }
    [[ ! "$n" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] && { echo "Invalid: $n"; exit 1; }
    for net in "${ADMIN_NETS[@]}" "${OFFICE_NETS[@]}" "${VPN_NETS[@]}"; do
        [[ "$n" == "$net" ]] && { echo "REFUSED: $n is an admin/office/VPN range"; exit 1; }
    done
    ipset create manual_blacklist hash:net -exist
    ipset add manual_blacklist "$n" 2>/dev/null && {
        ipset save manual_blacklist > "$IPSET_DIR/manual_blacklist.save"
        log_message "Blocked $n"; echo "Blocked $n"; apply_all_rules; }
}

remove_manual_block() {
    local n="$1"
    ipset test manual_blacklist "$n" 2>/dev/null && {
        ipset del manual_blacklist "$n"
        ipset save manual_blacklist > "$IPSET_DIR/manual_blacklist.save"
        log_message "Unblocked $n"; echo "Unblocked $n"; apply_all_rules; } \
        || echo "$n not in manual blacklist"
}

#==============================================================================
case "${1:-}" in
    update)       require_root; check_dual_ruleset; handle_update ;;
    reload)       require_root; check_dual_ruleset; apply_all_rules; save_rules ;;
    reload-safe)  require_root; check_dual_ruleset; apply_safe "${2:-300}" ;;
    confirm)      touch /tmp/.netset-confirmed; echo "Confirmed -- rollback cancelled."
                  echo "Verify with: $0 verify" ;;
    rollback)     require_root
                  [[ -f "$ROLLBACK_FILE" ]] && { $IPT_RESTORE < "$ROLLBACK_FILE"; echo "Restored."; } \
                                            || echo "No snapshot at $ROLLBACK_FILE" ;;
    restore)      require_root; handle_restore ;;
    verify)       verify_rules ;;
    access)       show_access_matrix ;;
    listeners)    show_listeners ;;
    smtp-audit)   smtp_audit ;;
    backend)      echo "Backend: $BACKEND ($IPT)"
                  command -v iptables-legacy >/dev/null 2>&1 && \
                    echo "legacy INPUT rules: $(iptables-legacy -S INPUT | grep -cv '^-P')"
                  echo "nft    INPUT rules: $(iptables -S INPUT | grep -cv '^-P')"
                  check_dual_ruleset && echo "Single ruleset -- OK." ;;
    le-open)      require_root; le_open "${2:-15}" ;;
    le-close)     require_root; le_close; echo "LE window closed." ;;
    le-status)    le_status ;;
    block-ip)     require_root; add_manual_block "${2:-}" ;;
    unblock-ip)   require_root; remove_manual_block "${2:-}" ;;
    show-blocked) ipset list manual_blacklist 2>/dev/null | grep -E '^[0-9]' | sort -V || echo "none" ;;
    status)       echo "=== Netset Firewall v5 ==="; echo
                  echo "Backend: $IPT   WAN=$WAN_IFACE   LAN=$LAN_IFACE"; echo
                  show_access_matrix; echo
                  echo "INPUT chain:"; $IPT -L INPUT -n --line-numbers ;;
    save)         require_root; save_rules ;;
    reset-policy) require_root
                  $IPT -F INPUT; $IPT -F FORWARD; $IPT -F OUTPUT
                  $IPT -F MARTIAN 2>/dev/null; $IPT -X MARTIAN 2>/dev/null
                  $IPT -P INPUT ACCEPT; $IPT -P OUTPUT ACCEPT; $IPT -P FORWARD ACCEPT
                  echo "WARNING: host is now UNFIREWALLED. Run '$0 reload'." ;;
    *)
        cat <<USAGE
manage-netsets.sh v5 -- role-based Zimbra firewall

  update           Download feeds, rebuild sets, apply, save
  reload           Re-apply rules from current config
  reload-safe [s]  Apply with auto-rollback (default 300s)
  confirm          Cancel a pending auto-rollback
  rollback         Restore the last snapshot
  restore          Restore ipsets from disk, then apply   <- use at boot
  verify           Self-check the live ruleset
  access           Print the effective access matrix
  listeners        Audit live sockets against policy
  smtp-audit       Who connects on 25, MX check, mynetworks exposure
  backend          Which iptables store is in use
  block-ip <net>   Add to manual blacklist
  unblock-ip <net> Remove from manual blacklist
  show-blocked     List manual blocks
  status           Full status
  save             Save current rules
  reset-policy     Emergency allow-all

LET'S ENCRYPT (manual HTTP-01 renewal):
  le-open [mins]   Open port 80 worldwide, auto-close (default 15 min)
  le-close         Close immediately
  le-status        Is a window open

  Typical renewal:
      $0 le-open 15
      certbot renew --standalone
      $0 le-close
      $0 verify

RULE ORDER:
   1 loopback
   2 VPN pool martian exemption (if VPN_POOL_ON_WAN=1)
   3 anti-spoof / martians / stealth flags
   4 CLEARTEXT 110,143 DROP -- all interfaces, ahead of every allow
   5 established / related
   6 host self -> saslauthd + RemoteManager
   7 ADMIN + OFFICE -> console, ssh, mail, web
   8 VPN + LAN -> mail, web only
   9 admin ports DROP for everyone else
  10 rate limits
  11 MX partners -> port 25 only (feed-exempt)
  12 GeoIP allowlist [BD]
  13 manual blacklist
  14 threat-intel feeds
  15 port 25 -> relays only (or worldwide if SMTP_WORLD_OPEN=1); rest via GeoIP
  16 internal ports DROP (both interfaces)
  17 ICMP rate-limited
  18 default deny
USAGE
        exit 1 ;;
esac
root@webmail:~# 
