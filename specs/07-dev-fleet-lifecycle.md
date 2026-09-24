# Spec 07 — Dev VM fleet lifecycle and desktop control

Status: Draft (new)
Pinned versions: Ubuntu Server **26.04 LTS (Resolute Raccoon)**, Proxmox VE **9.2**
Depends on: Spec 01 (host), Spec 04 (dev image), Spec 05 (personalization), Spec 06 (guest provisioning)

## 1. Purpose and scope

Defines how per-project dev VMs are created, started, stopped, and removed — and
how the **desktop VM** (bastion) controls this lifecycle **indirectly** through the
host.

The key invariants:

1. Dev VMs are **never auto-started** by the host. Only Desktop (100) and LLM
   (101) auto-start at host first boot.
2. The dev-template (VM 102) is a **PVE template** (can't be started directly)
   and serves as the clone source for all per-project dev VMs.
3. Per-project dev VMs (103+) are **created on demand** via `devctl` from the
   desktop, and remain **stopped until explicitly started**.
4. The control path is **indirect**: desktop → restricted SSH → host `qm` commands.

In scope: `vmctl` host-side control stub, `vmctl` user + SSH key + sudoers
provisioning (frag/25), `vmctl-host` enforcement script, inventory, dnsmasq
runtime registration, `devctl` desktop wrapper, firewall addition, first-start
provisioning gate, template conversion, acceptance. Out of scope: desktop/LLM
VM lifecycle (Spec 02/03), desktop's own first-boot (Spec 02), image rebuild
(Spec 08).

Supersedes: Spec 04 §5.3 (manual `qm clone` block) and the "dev-template runs"
convention from Spec 04 §5.3.

## 2. Design decisions

| Decision | Default | Rationale |
|---|---|---|
| Control channel | Restricted SSH (`vmctl` user, `ForceCommand`, sudoers whitelist) | Matches repo's SSH-centric model; no new services on the host |
| Credential bootstrap | Host generates keypair (frag/25), private half injected into desktop seed via `late-commands` (base64 placeholder) | Consistent with password-hash injection precedent; nothing on GitHub |
| Clone source | PVE template VM 102 (created at host first boot, then converted to template) | `qm template` prevents accidental start; `qm clone` from template is the standard PVE pattern |
| Per-project creation | `devctl add <name>` → `vmctl-host add` (host-side) | On-demand, no pre-registration; desktop remains unaware of future projects |
| IP allocation | `192.168.100.<vmid>` for VMIDs 103–249 | Deterministic, matches existing dnsmasq convention for 100/101/102 |
| MAC allocation | `52:54:00:00:02:XX` where XX = `vmid & 255` (hex) | Deterministic, avoids dnsmasq conflicts |
| Firewall addition | Host INPUT: `--dport 22 -s 192.168.100.100` (desktop only) | Minimal; desktop is the only trusted interactive client |
| Provisioning gate | `qm guest cmd` ping + log tail with bounded timeout before template conversion | Ensures 102 is provisioned before lockdown |
| Template refresh | `refresh-guests.sh` (operator-run on host) | Avoids host-side automation; operator controls REF bump + rebuild |

## 3. Host-side components

### 3.1 `frag/25-desktop-control.sh` — vmctl user + keys + inventory

Runs between frag/20 (memory) and frag/30 (guest creation) in the host first-boot
provisioner. Creates the vmctl account and control keypair.

```bash
#!/usr/bin/env bash
# frag/25-desktop-control.sh — vmctl user, keypair, sudoers, inventory
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" >> /var/log/pve-firstboot.log; }

# --- Inventory directory ---
mkdir -p /etc/nested-dev
cat > /etc/nested-dev/inventory <<'EOF'
# VMID  NAME  HOSTNAME  IP  MAC  STATUS  PROJECT
# 100  desktop  lychee  192.168.100.100  52:54:00:00:01:00  auto-started  desktop
# 101  llm  lychee-llm  192.168.100.101  52:54:00:00:01:01  auto-started  llm
# 102  dev-template  lychee-dev-template  192.168.100.102  52:54:00:00:01:02  template  dev-template
# (103+ per-project dev VMs added by vmctl-host on demand)
EOF
log "Inventory created at /etc/nested-dev/inventory"

# --- vmctl user ---
if ! id vmctl >/dev/null 2>&1; then
    useradd -r -m -s /usr/sbin/nologin -d /home/vmctl vmctl
    log "vmctl user created"
else
    log "vmctl user already exists"
fi

# --- Generate control keypair ---
VMCTL_KEY_DIR="/root/.nested-dev/vmctl"
mkdir -p "$VMCTL_KEY_DIR"
if [ ! -f "${VMCTL_KEY_DIR}/vmctl_ed25519" ]; then
    ssh-keygen -t ed25519 -f "${VMCTL_KEY_DIR}/vmctl_ed25519" -N "" \
        -C "vmctl@nested-dev"
    log "Control keypair generated"
else
    log "Control keypair already exists"
fi

# --- authorized_keys with ForceCommand restriction ---
mkdir -p /home/vmctl/.ssh
chmod 700 /home/vmctl/.ssh
PUB_KEY=$(cat "${VMCTL_KEY_DIR}/vmctl_ed25519.pub")
cat > /home/vmctl/.ssh/authorized_keys <<AUTH_EOF
command="/usr/local/sbin/vmctl-host",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ${PUB_KEY}
AUTH_EOF
chmod 600 /home/vmctl/.ssh/authorized_keys
chown -R vmctl:vmctl /home/vmctl/.ssh
log "authorized_keys written (ForceCommand → vmctl-host)"

# --- sudoers: only vmctl-host via root, no password ---
cat > /etc/sudoers.d/vmctl <<'SUDOERS_EOF'
vmctl ALL=(root) NOPASSWD: /usr/local/sbin/vmctl-host
SUDOERS_EOF
chmod 440 /etc/sudoers.d/vmctl
log "sudoers drop-in written"

# --- Copy vmctl-host script ---
cp /root/provision/vmctl/vmctl-host /usr/local/sbin/vmctl-host
chmod 755 /usr/local/sbin/vmctl-host
log "vmctl-host installed"

# --- Staging path for frag/30 (desktop seed injection) ---
cp "${VMCTL_KEY_DIR}/vmctl_ed25519" /root/.nested-dev/vmctl-priv-staged
chmod 600 /root/.nested-dev/vmctl-priv-staged
log "Private key staged for desktop seed injection"

log "=== desktop-control setup complete ==="
```

### 3.2 `provision/host/vmctl/vmctl-host` — enforcement script (shipped as repo file)

The `ForceCommand` target; validates verbs, VMIDs, and project names; wraps `qm`.

```bash
#!/usr/bin/env bash
# vmctl-host — restricted host-side control for dev VMs
# Called by vmctl@host via ForceCommand; argv: <verb> [args...]
set -euo pipefail

INVENTORY="/etc/nested-dev/inventory"
DEV_MIN=103
DEV_MAX=249

log() { printf '%s %s\n' "$(date -Is)" "$*" >> /var/log/nested-dev-vmctl.log; }

die() { echo "ERROR: $*" >&2; log "REJECT: $*"; exit 1; }

# --- Parse SSH_ORIGINAL_COMMAND or $@ ---
CMD="${SSH_ORIGINAL_COMMAND:-$*}"
set -- $CMD  # re-split into positional

VERB="${1:-}"
shift || true

case "$VERB" in
    list)
        echo "VMID  NAME                HOSTNAME                IP                STATUS"
        echo "----  ----                --------                --                ------"
        # Static entries (always present)
        printf "%-5s %-18s %-24s %-17s %s\n" 100 desktop lychee "192.168.100.100" "running"
        printf "%-5s %-18s %-24s %-17s %s\n" 101 llm lychee-llm "192.168.100.101" "running"
        printf "%-5s %-18s %-24s %-17s %s\n" 102 dev-template lychee-dev-template "192.168.100.102" "template"
        # Dynamic entries from qm
        for vid in $(seq $DEV_MIN $DEV_MAX); do
            if qm status "$vid" >/dev/null 2>&1; then
                STATUS=$(qm status "$vid" 2>/dev/null | awk '{print $2}')
                NAME=$(qm config "$vid" 2>/dev/null | grep '^name:' | awk '{print $2}')
                HOST="${NAME:-dev-${vid}}"
                printf "%-5s %-18s %-24s %-17s %s\n" "$vid" "$NAME" "$HOST" "192.168.100.${vid}" "$STATUS"
            fi
        done
        ;;

    status)
        [ -n "${1:-}" ] || die "usage: status <vmid>"
        VMID="$1"
        [[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID must be numeric"
        [ "$VMID" -ge "$DEV_MIN" ] && [ "$VMID" -le "$DEV_MAX" ] || die "VMID $VMID outside dev range ($DEV_MIN–$DEV_MAX)"
        qm status "$VMID" 2>/dev/null || die "VM $VMID does not exist"
        ;;

    start)
        [ -n "${1:-}" ] || die "usage: start <vmid>"
        VMID="$1"
        [[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID must be numeric"
        [ "$VMID" -ge "$DEV_MIN" ] && [ "$VMID" -le "$DEV_MAX" ] || die "VMID $VMID outside dev range"
        NAME=$(qm config "$VMID" 2>/dev/null | grep '^name:' | awk '{print $2}')
        [[ "$NAME" == dev-* ]] || die "VM $VMID name '$NAME' does not match dev-* pattern"
        STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
        [ "$STATUS" = "stopped" ] || die "VM $VMID is not stopped (status: $STATUS)"
        qm start "$VMID"
        log "START $VMID ($NAME)"
        echo "VM $VMID ($NAME) started"
        ;;

    shutdown)
        [ -n "${1:-}" ] || die "usage: shutdown <vmid>"
        VMID="$1"
        [[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID must be numeric"
        [ "$VMID" -ge "$DEV_MIN" ] && [ "$VMID" -le "$DEV_MAX" ] || die "VMID $VMID outside dev range"
        qm shutdown "$VMID" --forceStop 0 2>/dev/null || qm stop "$VMID" 2>/dev/null
        log "SHUTDOWN $VMID"
        echo "VM $VMID shutting down"
        ;;

    stop)
        [ -n "${1:-}" ] || die "usage: stop <vmid>"
        VMID="$1"
        [[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID must be numeric"
        [ "$VMID" -ge "$DEV_MIN" ] && [ "$VMID" -le "$DEV_MAX" ] || die "VMID $VMID outside dev range"
        qm stop "$VMID" 2>/dev/null || true
        log "STOP $VMID (forced)"
        echo "VM $VMID stopped (forced)"
        ;;

    add)
        [ -n "${1:-}" ] || die "usage: add <project-name>"
        PROJECT="$1"
        [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9_-]{0,30}$ ]] || die "Project name must be lowercase alphanumeric/underscore/hyphen, max 32 chars"
        # Find next available VMID
        NEXT_VID=""
        for vid in $(seq $DEV_MIN $DEV_MAX); do
            if ! qm status "$vid" >/dev/null 2>&1; then
                NEXT_VID="$vid"
                break
            fi
        done
        [ -n "$NEXT_VID" ] || die "No free VMIDs in range $DEV_MIN–$DEV_MAX"

        # Clone template
        FULLNAME="dev-${PROJECT}"
        MAC_SUFFIX=$(printf '%02x' $((NEXT_VID & 255)))
        MAC="52:54:00:00:02:${MAC_SUFFIX}"
        HOSTNAME="lychee-${FULLNAME}"
        IP="192.168.100.${NEXT_VID}"

        qm clone 102 "$NEXT_VID" --name "$FULLNAME" --full
        qm set "$NEXT_VID" --net0 "virtio=${MAC},bridge=vmbr0,firewall=1"
        log "CLONE $NEXT_VID <- 102, name=$FULLNAME, MAC=$MAC"

        # dnsmasq static entry
        cat >> /etc/dnsmasq.d/zz-dev.conf <<DNS_EOF
dhcp-host=${MAC},${HOSTNAME},${IP}
address=/${HOSTNAME}/${IP}
address=/${HOSTNAME}.wolfskeep.com/${IP}
DNS_EOF
        systemctl reload dnsmasq
        log "dnsmasq entry added: ${HOSTNAME} → ${IP}"

        # /etc/hosts entry
        if ! grep -q "^${IP} " /etc/hosts; then
            echo "${IP} ${HOSTNAME}.wolfskeep.com ${HOSTNAME}" >> /etc/hosts
            log "/etc/hosts updated: ${IP} ${HOSTNAME}"
        fi

        # Inventory
        echo "${NEXT_VID}  ${FULLNAME}  ${HOSTNAME}  ${IP}  ${MAC}  stopped  ${PROJECT}" >> "$INVENTORY"
        log "Inventory updated: VMID ${NEXT_VID} = ${PROJECT}"

        echo "VM ${NEXT_VID} (${FULLNAME}) created and stopped. Start with: start ${NEXT_VID}"
        ;;

    log)
        [ -n "${1:-}" ] || die "usage: log <vmid>"
        VMID="$1"
        [[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID must be numeric"
        [ "$VMID" -ge "$DEV_MIN" ] && [ "$VMID" -le "$DEV_MAX" ] || die "VMID $VMID outside dev range"
        # Guest agent required; fall back to serial console
        qm guest exec "$VMID" -- tail -n 50 /var/log/dev-firstboot.log 2>/dev/null \
            || qm guest exec "$VMID" -- cat /var/log/dev-firstboot.log 2>/dev/null \
            || echo "Could not read log (VM may not be running or guest agent not ready)"
        ;;

    *)
        echo "Usage: <command> [args]" >&2
        echo "  list                    — list dev VMs" >&2
        echo "  status <vmid>           — VM status" >&2
        echo "  start <vmid>            — start a dev VM" >&2
        echo "  shutdown <vmid>         — graceful stop" >&2
        echo "  stop <vmid>             — force stop" >&2
        echo "  add <project-name>      — create new dev VM from template" >&2
        echo "  log <vmid>              — tail first-boot log" >&2
        exit 1
        ;;
esac
```

### 3.3 `provision/host/vmctl/sudoers` (shipped as repo file, installed by frag/25)

```
# /etc/sudoers.d/vmctl — vmctl can only run vmctl-host as root
vmctl ALL=(root) NOPASSWD: /usr/local/sbin/vmctl-host
```

## 4. Desktop-side components

### 4.1 `devctl` wrapper (shipped as repo file at `desktop/devctl`, installed by desktop-firstboot)

```bash
#!/usr/bin/env bash
# devctl — desktop-side dev VM control wrapper
# Delegates to vmctl@pvehost via restricted SSH
set -euo pipefail

PVEHOST="pvehost"  # ~/.ssh/config alias → 192.168.100.1
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

usage() {
    echo "Usage: devctl <command> [args]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  list                          List dev VMs" >&2
    echo "  status <name|vmid>            VM status" >&2
    echo "  start <name|vmid>             Start a dev VM" >&2
    echo "  stop <name|vmid>              Graceful stop" >&2
    echo "  kill <name|vmid>              Force stop" >&2
    echo "  add <project-name>            Create new dev VM from template" >&2
    echo "  log <name|vmid>               Tail first-boot log" >&2
    echo "  ssh <name|vmid> [cmd...]      SSH to dev VM directly" >&2
    exit 1
}

[ $# -ge 1 ] || usage

# Resolve name→vmid (names start with "dev-")
resolve() {
    local arg="$1"
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
        echo "$arg"
        return
    fi
    # Look up by name via list
    local line
    line=$(ssh $SSH_OPTS vmctl@${PVEHOST} list 2>/dev/null | grep -E "^[0-9]+\s+${arg}\b" | head -1) || true
    if [ -n "$line" ]; then
        echo "$line" | awk '{print $1}'
    else
        echo ""
    fi
}

case "$1" in
    list)
        ssh $SSH_OPTS vmctl@${PVEHOST} list
        ;;
    status)
        [ $# -ge 2 ] || { echo "Usage: devctl status <name|vmid>" >&2; exit 1; }
        VMID=$(resolve "$2")
        [ -n "$VMID" ] || { echo "Unknown VM: $2" >&2; exit 1; }
        ssh $SSH_OPTS vmctl@${PVEHOST} status "$VMID"
        ;;
    start)
        [ $# -ge 2 ] || { echo "Usage: devctl start <name|vmid>" >&2; exit 1; }
        VMID=$(resolve "$2")
        [ -n "$VMID" ] || { echo "Unknown VM: $2" >&2; exit 1; }
        ssh $SSH_OPTS vmctl@${PVEHOST} start "$VMID"
        echo ""
        echo "First boot may take several minutes. Check with: devctl log ${VMID}"
        ;;
    stop)
        [ $# -ge 2 ] || { echo "Usage: devctl stop <name|vmid>" >&2; exit 1; }
        VMID=$(resolve "$2")
        [ -n "$VMID" ] || { echo "Unknown VM: $2" >&2; exit 1; }
        ssh $SSH_OPTS vmctl@${PVEHOST} shutdown "$VMID"
        ;;
    kill)
        [ $# -ge 2 ] || { echo "Usage: devctl kill <name|vmid>" >&2; exit 1; }
        VMID=$(resolve "$2")
        [ -n "$VMID" ] || { echo "Unknown VM: $2" >&2; exit 1; }
        ssh $SSH_OPTS vmctl@${PVEHOST} stop "$VMID"
        ;;
    add)
        [ $# -ge 2 ] || { echo "Usage: devctl add <project-name>" >&2; exit 1; }
        ssh $SSH_OPTS vmctl@${PVEHOST} add "$2"
        ;;
    log)
        [ $# -ge 2 ] || { echo "Usage: devctl log <name|vmid>" >&2; exit 1; }
        VMID=$(resolve "$2")
        [ -n "$VMID" ] || { echo "Unknown VM: $2" >&2; exit 1; }
        ssh $SSH_OPTS vmctl@${PVEHOST} log "$VMID"
        ;;
    ssh)
        [ $# -ge 2 ] || { echo "Usage: devctl ssh <name|vmid> [cmd...]" >&2; exit 1; }
        VMID=$(resolve "$2")
        [ -n "$VMID" ] || { echo "Unknown VM: $2" >&2; exit 1; }
        shift
        ssh $SSH_OPTS popiel@192.168.100.${VMID} "$@"
        ;;
    *)
        usage
        ;;
esac
```

### 4.2 `~/.ssh/config` (installed by desktop-firstboot.sh)

```
Host pvehost
    HostName 192.168.100.1
    User vmctl
    IdentityFile ~/.ssh/pvehost_vmctl
    StrictHostKeyChecking accept-new
    IdentitiesOnly yes
```

### 4.3 `~/.ssh/pvehost_vmctl` (private key, injected via desktop user-data seed)

Base64-encoded at host build time; decoded and installed by desktop-firstboot.sh or
by `late-commands` in the desktop's NoCloud seed user-data (placeholder
`__VMCTL_PRIV_B64__` in the committed template; real value substituted by host).

## 5. Firewall addition

Host `frag/90-finalize.sh` adds to the INPUT chain (after the existing ESTABLISHED
and LAN rules):

```bash
# SSH to host from desktop only (for vmctl/devctl control)
iptables -A INPUT -p tcp --dport 22 -s 192.168.100.100 -j ACCEPT
```

This goes in `frag/90-finalize.sh` alongside the existing SSH/2222 and 8006 rules.
FORWARD remains unchanged (desktop can already reach any vmbr0 peer).

## 6. First-start provisioning gate

When `devctl add` creates a new clone, the clone boots from a copy of the
template's provisioned disk. If the template was properly provisioned and
`cloud-init clean` was run, the clone boots with a fresh identity — no
first-boot provisioning needed.

However, the dev-template (102) itself must be provisioned exactly **once** at
host first boot. The sequence in `frag/30-create-guests.sh`:

1. Create VM 102 with NoCloud seed + Ubuntu Server ISO.
2. `qm start 102`.
3. Wait for provisioning to complete (poll `qm guest cmd 102 ping` +
   check `/var/log/dev-firstboot.log` via `qm guest exec`, bounded by timeout).
4. `qm guest exec 102 -- cloud-init clean` (clean identity for future clones).
5. `qm guest exec 102 -- /bin/bash -c 'truncate -s 0 /etc/machine-id && rm -f /etc/ssh/ssh_host_*'` (clear host identity).
6. `qm shutdown 102`.
7. `qm template 102` (marks as template; can never be started directly).

If the timeout expires before provisioning completes, `frag/30` logs a warning and
leaves VM 102 running. The operator can then finish provisioning manually and run
`qm template 102` by hand. `frag/90` (firewall lockdown) still runs — the
provisioning network window is the brief time between `qm start 102` in frag/30
and `iptables` application in frag/90.

## 7. Inventory and DNS

### 7.1 Inventory file (`/etc/nested-dev/inventory`)

Maintained by `vmctl-host`; tab-separated:

```
VMID  NAME  HOSTNAME  IP  MAC  STATUS  PROJECT
100  desktop  lychee  192.168.100.100  52:54:00:00:01:00  running  desktop
101  llm  lychee-llm  192.168.100.101  52:54:00:00:01:01  running  llm
102  dev-template  lychee-dev-template  192.168.100.102  52:54:00:00:01:02  template  dev-template
103  dev-nested  lychee-dev-nested  192.168.100.103  52:54:00:00:02:67  stopped  nested
```

### 7.2 dnsmasq drop-in (`/etc/dnsmasq.d/zz-dev.conf`)

Created by `frag/25` (empty header) and appended to by `vmctl-host add`:

```bash
# Per-project dev VMs — added by vmctl-host on demand
# (do not edit manually; managed by vmctl-host)
```

After each `add`, the file gets entries like:

```
dhcp-host=52:54:00:00:02:67,lychee-dev-nested,192.168.100.103
address=/lychee-dev-nested/192.168.100.103
address=/lychee-dev-nested.wolfskeep.com/192.168.100.103
```

`dnsmasq` is reloaded after each addition.

### 7.3 `/etc/hosts`

Appended by `vmctl-host add`; entries like:

```
192.168.100.103 lychee-dev-nested.wolfskeep.com lychee-dev-nested
```

## 8. User-data template change

The desktop `user-data/user-data` gains a placeholder for the vmctl private key
injected by the host at seed build time. This follows the same pattern as the
password-hash injection (Spec 06).

New `late-commands` entry in `desktop/user-data/user-data`:

```yaml
    # vmctl control key for dev fleet management
    - "curtin in-target --target=/target -- sh -c 'echo __VMCTL_PRIV_B64__ | base64 -d > /home/__PERSONALIZATION_USERNAME__/.ssh/pvehost_vmctl && chmod 600 /home/__PERSONALIZATION_USERNAME__/.ssh/pvehost_vmctl && chown __PERSONALIZATION_USERNAME__:__PERSONALIZATION_USERNAME__ /home/__PERSONALIZATION_USERNAME__/.ssh/pvehost_vmctl'"
```

The host substitutes `__VMCTL_PRIV_B64__` with the base64-encoded private key
during seed assembly (same `sed` pass as password hash). The placeholder
`__VMCTL_PRIV_B64__` in the committed file is harmless.

## 9. Security model

| Secret | Where it lives | On GitHub? |
|---|---|---|
| vmctl private key | Host: `/root/.nested-dev/vmctl/vmctl_ed25519` | No |
| | Desktop: `~/.ssh/pvehost_vmctl` (injected via seed) | No |
| vmctl public key | Host: `/home/vmctl/.ssh/authorized_keys` | No (host only) |
| Host root SSH key | Host ISO → `keys/host_os_ed25519.pub` embedded | Pub key: yes |
| Password hash | Host ISO → `/root/.password-hash` | No |

**vmctl is constrained to:**
- Verbs: `list`, `status`, `start`, `shutdown`, `stop`, `add`, `log`
- VMIDs: 103–249 (100/101/102 explicitly rejected by the range check)
- Project names: `dev-*` pattern (validated by name check on `start`)
- No shell, no file access, no forwarding

**Desktop→host INPUT:** TCP/22 from 192.168.100.100 only; vmctl user with
ForceCommand → `vmctl-host`; sudoers restricted to one exact script path.

## 10. Acceptance

* Host first boot: `qm list` shows 100 (running), 101 (running), 102 (template).
  No other VMs.
* `qm status 102` returns template status; `qm start 102` is rejected by PVE.
* Desktop can `ssh pvehost list` and see the three base VMs.
* `devctl add test-project` creates VM 103 (`dev-test-project`, stopped), with
  dnsmasq entry; desktop resolves `lychee-dev-test-project` via DNS.
* `devctl start 103` boots the VM; `devctl log 103` shows first-boot output.
* `devctl stop 103` gracefully shuts it down; `devctl kill 103` force-stops.
* `vmctl-host` rejects VMID 100/101/102 (out of range) and non-`dev-*` names.
* Desktop cannot reach host:22 before frag/90 (no rule yet); can reach after.
* `grep __VMCTL_PRIV_B64__ desktop/user-data/user-data` shows only the placeholder;
  the committed file contains no real key material.
* `/etc/nested-dev/inventory` is maintained with correct entries after `add`.
* `devctl ssh 103 hostname` returns `lychee-dev-nested` (the cloned VM's hostname).
