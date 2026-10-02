#!/usr/bin/env bash
# frag/28-network.sh — private network up before any guest boots
# Routed network: $PHYS_NIC = LAN (DHCP), vmbr0 = private (192.168.100.1/24)
# dnsmasq on host serves DHCP/DNS to VMs on vmbr0.
#
# This exists separately from frag/90-finalize.sh, and runs before
# frag/30-create-guests.sh, for one reason: guests configure networking by
# DHCP and fetch packages and first-boot scripts from the internet while they
# install. The installer-time network provides no DHCP server, no resolver on
# the private segment, and no route. A guest that boots before this fragment
# stalls without an address and fails its provisioning gate after the timeout —
# which is exactly what happened to the dev template on the first host this
# ran on. The firewall itself (filter rules, DROP defaults) stays in frag/90,
# after the guests: during the install window the bridge is host-internal with
# no physical ports, so there is nothing to filter yet.
#
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

ROOT="${PVE_ROOT:-}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "${ROOT}/var/log/pve-firstboot.log"; }
die() { log "FATAL: $*"; exit 1; }

# --- Pure functions (testable via source-guard) ---

ensure_dhcp_renewals() {
    # The LAN address comes from dhclient, whose AppArmor profile denies the
    # unix sockets it retries on: renewals fail in a loop and the lease
    # eventually expires, taking the host off the LAN hours after a
    # successful install. Best effort only — day-one connectivity does not
    # depend on renewals (the initial lease outlives the install), so failure
    # warns instead of aborting.
    if command -v aa-complain >/dev/null 2>&1; then
        if aa-complain /usr/sbin/dhclient >/dev/null 2>&1; then
            log "dhclient AppArmor profile set to complain mode (renewals survive)"
        else
            log "WARNING: could not set dhclient complain mode; DHCP renewals may fail at lease expiry"
        fi
    else
        log "WARNING: aa-complain not installed; DHCP renewals may fail at lease expiry (install apparmor-utils and complain /usr/sbin/dhclient)"
    fi
}

populate_upstream_resolvers() {
    # dnsmasq forwards external queries to ${ROOT}/run/resolv.conf, but
    # nothing on a fresh system ever creates that file: without it dnsmasq
    # answers guest and host DNS with nothing, and every fetch fails at
    # lookup while the network itself is fine. Build it from the DHCP
    # leases' name servers; an empty server list aborts instead of starting
    # dnsmasq deaf.
    local f servers
    servers="$(for f in "${ROOT}/var/lib/dhcp/"*.leases "${ROOT}/var/lib/dhclient/"*.leases; do
        [ -f "$f" ] || continue
        grep -h "option domain-name-servers" "$f" 2>/dev/null || true
    done | awk '{ line=$0; gsub(/;/, " ", line); gsub(/,/, " ", line);
        n=split(line, parts, /[ \t]+/);
        for (i=1; i<=n; i++) if (parts[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !seen[parts[i]]++) print parts[i] }')"
    [ -n "$servers" ] || die "no upstream name servers in any DHCP lease; refusing to start dnsmasq deaf (check the LAN DHCP on ${PHYS_NIC:-unknown})"
    mkdir -p "${ROOT}/run"
    {
        printf '# Upstream resolvers, from the DHCP lease (frag/28). dnsmasq reads this file.\n'
        printf '%s\n' "$servers" | while IFS= read -r server; do
            [ -n "$server" ] || continue
            printf 'nameserver %s\n' "$server"
        done
    } > "${ROOT}/run/resolv.conf"
    log "upstream resolvers written"
}

wait_for_upstream() {
    # The LAN NIC was just reconfigured, so its DHCP lease is renewing and the
    # first apt call below races it: every repository fails at once ("no longer
    # has a Release file") even though the configuration is correct. Gate on a
    # default route plus a working resolver instead of assuming instant link.
    # Timeout in seconds; polls every 5. Returns nonzero on timeout — the
    # caller decides whether to solicit a lease or die.
    local timeout="$1" waited=0
    log "waiting for upstream connectivity (default route + DNS)"
    while [ "$waited" -lt "$timeout" ]; do
        if ip route show default 2>/dev/null | grep -q . \
            && getent hosts deb.debian.org >/dev/null 2>&1; then
            log "upstream connectivity confirmed"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    log "no upstream connectivity after ${timeout}s"
    return 1
}

solicit_dhcp() {
    # Actively (re)solicit a DHCP lease on the LAN NIC. Waiting alone is not
    # enough: after the reconfiguration there is repeatedly an address but no
    # route and no client still running to renew it — only asking produces the
    # lease. Output flows to the provision log like every other fragment
    # command.
    local nic="$1"
    if command -v dhclient >/dev/null 2>&1; then
        log "soliciting DHCP lease on ${nic} (dhclient)"
        dhclient -v "$nic" || return 1
    elif command -v dhcpcd >/dev/null 2>&1; then
        log "soliciting DHCP lease on ${nic} (dhcpcd)"
        dhcpcd "$nic" || return 1
    elif command -v udhcpc >/dev/null 2>&1; then
        log "soliciting DHCP lease on ${nic} (udhcpc)"
        udhcpc -i "$nic" || return 1
    else
        log "no DHCP client found; cannot solicit a lease"
        return 1
    fi
}

main() {
    log "=== Private network setup ==="

    # --- 1. Detect physical NIC ---
    PHYS_NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E 'lo|vmbr|docker|veth|br-' | head -1)
    [ -n "$PHYS_NIC" ] \
        || die "no physical NIC detected; cannot build the private network"
    log "Physical NIC: $PHYS_NIC"

    # --- 2. Write network config and apply it — routed architecture ---
    mkdir -p "${ROOT}/etc/network"
    cat > "${ROOT}/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

# Physical NIC — LAN-facing, DHCP from external server
auto ${PHYS_NIC}
iface ${PHYS_NIC} inet dhcp

# Private bridge — VM-facing, static IP, dnsmasq serves DHCP/DNS
auto vmbr0
iface vmbr0 inet static
    address 192.168.100.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
    log "Network config written: ${PHYS_NIC} (DHCP) + vmbr0 (192.168.100.1/24)"

    # Writing the file is not bringing the network up: until the address is
    # assigned, dnsmasq below binds nothing and every guest that boots has no
    # gateway and no resolver. Prefer the differential apply; fall back to the
    # full restart where ifupdown2 is absent. Either way the address is verified
    # afterwards — an unapplied file fails this fragment loudly instead of
    # failing three guests opaquely minutes later.
    if command -v ifreload >/dev/null 2>&1; then
        ifreload -a || die "ifreload failed to apply the network config"
    else
        systemctl restart networking || die "networking restart failed"
    fi

    if ! ip -o addr show dev vmbr0 2>/dev/null | grep -q '192\.168\.100\.1/24'; then
        die "vmbr0 has no 192.168.100.1/24 after applying the network config; guests would boot with no gateway or DNS"
    fi
    log "vmbr0 carries 192.168.100.1/24"

    # --- 2b. Ensure upstream connectivity before any apt call ---
    # A short passive wait first (a healthy renew lands on its own), then one
    # active solicitation: the renew repeatedly does not re-fire by itself
    # after the reconfiguration. Dying here names the area; dying later in
    # apt names repositories.
    if ! wait_for_upstream 60; then
        solicit_dhcp "$PHYS_NIC" || die "no upstream connectivity; check the LAN DHCP on ${PHYS_NIC}"
        wait_for_upstream 120 || die "no upstream connectivity; check the LAN DHCP on ${PHYS_NIC}"
    fi

    # --- 3. Install and configure dnsmasq ---
    if ! dpkg -l dnsmasq 2>/dev/null | grep -q '^ii'; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq
        log "dnsmasq installed"
    fi

    # Write dnsmasq config (static leases + DNS for VMs)
    mkdir -p "${ROOT}/etc/dnsmasq.d"
    cat > "${ROOT}/etc/dnsmasq.d/nested_dev.conf" <<'DNSMASQ_EOF'
# dnsmasq config for nested_dev — served on vmbr0 (192.168.100.0/24)
interface=vmbr0
# Dynamic binding, not bind-at-startup: the bridge has no address and no
# carrier when dnsmasq first starts (no guest taps attached yet), and a
# bind-at-startup mode never picks up DHCP on an interface that appears
# later — leaving dnsmasq answering DNS while deaf on DHCP, with every guest
# installer stalled pre-storage and no log line saying why.
bind-dynamic

# DHCP range for ad-hoc / future VMs
dhcp-range=192.168.100.110,192.168.100.200,255.255.255.0,12h

# Default gateway and DNS for DHCP clients
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,192.168.100.1

# --- Static leases (MACs match frag/30 qm create --net0) ---
dhcp-host=52:54:00:00:01:00,lychee,192.168.100.100
dhcp-host=52:54:00:00:01:01,lychee-llm,192.168.100.101
dhcp-host=52:54:00:00:01:02,lychee-dev-template,192.168.100.102

# --- DNS: short names + FQDNs ---
address=/lychee-host/192.168.100.1
address=/lychee-host.wolfskeep.com/192.168.100.1
address=/lychee/192.168.100.100
address=/lychee.wolfskeep.com/192.168.100.100
address=/lychee-llm/192.168.100.101
address=/lychee-llm.wolfskeep.com/192.168.100.101
address=/lychee-dev-template/192.168.100.102
address=/lychee-dev-template.wolfskeep.com/192.168.100.102

# Upstream DNS from host's DHCP-provided resolv.conf
resolv-file=/run/resolv.conf
DNSMASQ_EOF

    # Disable dnsmasq's own resolv.conf management (we provide upstream via resolv-file)
    sed -i 's|^#resolv-file=.*|resolv-file=/run/resolv.conf|' "${ROOT}/etc/dnsmasq.conf" 2>/dev/null || true

    populate_upstream_resolvers

    # Restart unconditionally, not enable --now: --now is a no-op on an
    # already-active service, so a changed config file would never take
    # effect on re-runs (leases persist across the ~1s blip; clients retry
    # transparently). A silently stale dnsmasq is how DHCP dies with the
    # service still "active".
    systemctl enable dnsmasq
    systemctl restart dnsmasq
    log "dnsmasq configured and started"

    # --- 4. Enable IP forwarding and guest egress ---
    mkdir -p "${ROOT}/etc/sysctl.d"
    cat > "${ROOT}/etc/sysctl.d/99-nested-dev.conf" <<'SYSCTL_EOF'
# Enable IPv4 forwarding for routed VM network
net.ipv4.ip_forward = 1
SYSCTL_EOF
    sysctl -w net.ipv4.ip_forward=1
    log "IP forwarding enabled"

    # MASQUERADE now; the filter table (including DROP defaults) is frag/90's,
    # after the guests. Guarded rather than flushed: this runs on every
    # re-provision and must not stack duplicate rules.
    iptables -t nat -C POSTROUTING -s 192.168.100.0/24 -o "$PHYS_NIC" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o "$PHYS_NIC" -j MASQUERADE
    log "Guest egress NAT in place"

    ensure_dhcp_renewals

    log "=== Private network setup complete ==="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
