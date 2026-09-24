# Spec 06 — Guest VM provisioning (host-mediated autoinstall)

Status: Draft (normative; closes the gap between build and running guests)
Depends on: Spec 01 (host), Spec 02 (desktop), Spec 03 (LLM), Spec 04 (Dev),
            Spec 05 (personalization), Spec 07 (dev fleet lifecycle)

## 1. Problem

The build scripts produce custom autoinstall ISOs, but:
- The host's `frag/30-create-guests.sh` expects golden qcow2 files that
  don't exist
- No script converts ISOs to qcow2
- No script transports files to the host
- The user has no local file server and uses USB for the host installer

## 2. Design decisions

1. **Eliminate custom ISOs for guests.** VMs boot with NoCloud seeds
   (user-data + meta-data) attached as cloud-init drives. The host
   assembles these from GitHub-fetched templates.

2. **Password hash stays on the host.** The host ISO carries the hash
   (baked in at build time). The host substitutes it into user-data
   templates at VM creation time. GitHub only ever has the placeholder.

3. **Guests fetch first-boot scripts from GitHub.** The host's FORWARD
   chain does not restrict VM outbound; MASQUERADE provides internet.
   First-boot scripts run after the OS is installed and network is up.

**No custom guest ISOs. No golden qcow2. No virt-sysprep. No file
transport. No password hash on GitHub.**

## 3. How the password hash and vmctl key flow

```
keys/password-hash
       |
       v
provision/host/build-iso.sh
  reads hash, copies to ISO root
  answer-host.toml late-commands:
    writes /root/.password-hash on host
       |
       v
Host disk: /root/.password-hash
       |
       v
frag/25-desktop-control.sh
  generates vmctl keypair at /root/.nested-dev/vmctl/
  stages private key for frag/30
       |
       v
frag/30-create-guests.sh
  reads /root/.password-hash
  reads /root/.nested-dev/vmctl-priv-staged
  fetches user-data template from GitHub (CHANGE_ME_HASHED + __VMCTL_PRIV_B64__)
  sed-replaces placeholders with real values
  writes result as NoCloud seed for each guest
  (desktop seed includes vmctl private key via late-commands)
       |
       v
Guest autoinstall reads NoCloud seed -> real password + vmctl key configured
```

GitHub never sees the hash or the vmctl key. The host is the only place
they exist at runtime.

## 4. How autoinstall user-data reaches the VM

Ubuntu autoinstall supports a NoCloud datasource: a secondary drive
containing `user-data` and `meta-data`. The installer detects it
automatically if attached as a cloud-init drive.

The flow:
1. Host fetches user-data **templates** from GitHub (`main` branch,
   placeholders intact)
2. Host reads password hash from `/root/.password-hash`
3. Host substitutes `CHANGE_ME_HASHED` -> real hash in each template
4. Host writes result as NoCloud seed + `meta-data`
5. `qm create` attaches seed as `-ide2`
6. VM boots, installer detects NoCloud, reads user-data, runs autoinstall
7. First-boot scripts fetch remaining setup from GitHub

## 5. Host-side changes

### 5.1 Host ISO: embed password hash

The host `build-iso.sh` already reads `keys/password-hash`. Add a
`late-command` to the answer file that persists it on the host disk:

```toml
[late-commands]
"persist-password-hash" = "sh -c 'cat /cdrom/password-hash > /target/root/.password-hash && chmod 600 /target/root/.password-hash'"
```

The host `build-iso.sh` copies `keys/password-hash` to the ISO root
alongside the answer file.

After install, the hash lives at `/root/.password-hash` on the host.

### 5.2 `frag/25-desktop-control.sh` — vmctl keypair (runs before frag/30)

Creates the `vmctl` user, generates the control keypair, installs sudoers
and the `vmctl-host` script, and stages the private key for frag/30 to
embed in the desktop seed. Full implementation in Spec 07 §3.1.

### 5.3 `frag/30-create-guests.sh` — NoCloud seeds, guest creation

Runs after frag/25. Reads password hash + staged vmctl private key.
Fetches user-data templates from GitHub, injects placeholders, builds
NoCloud seed ISOs (`genisoimage`), creates VMs with Ubuntu ISO + seed.

```bash
# --- Configuration ---
GITHUB_REPO="${PERSONALIZATION_REPO:-popiel/nested_dev}"
GITHUB_REF="${PERSONALIZATION_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_REF}"
PASSWORD_HASH_FILE="/root/.password-hash"
VMCTL_KEY_FILE="/root/.nested-dev/vmctl-priv-staged"

# --- Read password hash ---
if [ ! -f "$PASSWORD_HASH_FILE" ]; then
    die "Password hash not found: ${PASSWORD_HASH_FILE}"
fi
PASS_HASH="$(cat "$PASSWORD_HASH_FILE")"

# --- Read vmctl private key (base64 for desktop injection) ---
VMCTL_KEY_B64=""
if [ -f "$VMCTL_KEY_FILE" ]; then
    VMCTL_KEY_B64=$(base64 -w0 "$VMCTL_KEY_FILE")
fi

# --- Create NoCloud seed directory ---
SEED_DIR="/var/lib/vz/template/cidata"
mkdir -p "$SEED_DIR"

# --- Fetch templates and inject placeholders ---
for guest in desktop llm dev; do
    TEMPLATE_URL="${BASE_URL}/${guest}/user-data/user-data"
    SEED_FILE="${SEED_DIR}/${guest}-user-data"

    if ! wget -q "$TEMPLATE_URL" -O "${SEED_DIR}/${guest}-template" 2>/dev/null; then
        log "WARNING: Could not fetch ${guest} user-data from GitHub"
        continue
    fi

    # Substitute password hash + vmctl key (desktop only)
    sed -e "s|CHANGE_ME_HASHED|${PASS_HASH}|g" \
        -e "s|__VMCTL_PRIV_B64__|${VMCTL_KEY_B64}|g" \
        "${SEED_DIR}/${guest}-template" > "$SEED_FILE"

    # Write meta-data (empty, required by NoCloud)
    echo "instance-id: ${guest}-$(date +%s)" > "${SEED_DIR}/${guest}-meta-data"

    # Build seed ISO
    GENISOIMAGE_OPTS="-r -V cidata -joliet-long"
    genisoimage $GENISOIMAGE_OPTS -o "${SEED_DIR}/${guest}-seed.iso" \
        "${SEED_FILE}" "${SEED_DIR}/${guest}-meta-data"

    log "NoCloud seed prepared: ${guest}"
done
```

### 5.4 VM creation with NoCloud seed

```bash
# Desktop (VM 100) — started immediately
if ! qm status 100 >/dev/null 2>&1; then
    DESKTOP_HOSTPCI=""
    if [ -n "$IGPU_IDS" ]; then
        DESKTOP_HOSTPCI="--hostpci0 ${IGPU_IDS},pcie=1,x-vga=0"
    fi

    qm create 100 \
        --name desktop \
        --memory 8192 --cores 4 --cpu host \
        --scsihw virtio-scsi-single \
        --net0 virtio=52:54:00:00:01:00,bridge=vmbr0 \
        --bios ovmf --machine q35 --vga none \
        --serial0 socket --agent enabled=1 \
        $DESKTOP_HOSTPCI \
        --ide0 "${SEED_DIR}/desktop-user-data,media=cdrom" \
        --boot order=scsi0
    qm start 100
    log "VM 100 (desktop) created and started"
fi
```

GPU passthrough: `qm set 100 --hostpci0 "${IGPU_IDS},pcie=1,x-vga=0"`
applied inline if detected.

### 5.5 LLM (VM 101) — started immediately

Same pattern as desktop; add GPU passthrough and GeForce workaround.
Data volume: `qm set 101 --scsi1 local-lvm:500,size=500G`.

### 5.6 Dev template (VM 102) — provisioned once, then template

```bash
# Dev template (VM 102) — provisioned once, then converted to template
if ! qm status 102 >/dev/null 2>&1; then
    qm create 102 \
        --name dev-template \
        --memory 8192 --cores 4 --cpu host \
        --scsihw virtio-scsi-single \
        --net0 virtio=52:54:00:00:01:02,bridge=vmbr0,firewall=1 \
        --bios ovmf --machine q35 --vga none \
        --serial0 socket --agent enabled=1 \
        --ide0 "${SEED_DIR}/dev-user-data,media=cdrom" \
        --boot order=scsi0
    qm start 102
    log "VM 102 (dev-template) created and starting for provisioning"
fi

# --- Provisioning gate: wait for first-boot to complete ---
provisioning_timeout=600  # 10 minutes
elapsed=0
while [ $elapsed -lt $provisioning_timeout ]; do
    if qm guest exec 102 -- test -f /var/log/dev-firstboot.log >/dev/null 2>&1; then
        # Check if first-boot script has disabled itself (success marker)
        if qm guest exec 102 -- grep -q "dev first-boot complete" /var/log/dev-firstboot.log >/dev/null 2>&1; then
            log "VM 102 first-boot complete"
            break
        fi
    fi
    sleep 10
    elapsed=$((elapsed + 10))
done

if [ $elapsed -ge $provisioning_timeout ]; then
    log "WARNING: VM 102 provisioning timed out after ${provisioning_timeout}s"
    log "  Complete provisioning manually, then run: qm template 102"
else
    # Clean identity for future clones
    qm guest exec 102 -- cloud-init clean 2>/dev/null || true
    qm guest exec 102 -- /bin/bash -c 'truncate -s 0 /etc/machine-id && rm -f /etc/ssh/ssh_host_*' 2>/dev/null || true
    qm shutdown 102 2>/dev/null || true
    # Wait for shutdown
    sleep 5
    while qm status 102 2>/dev/null | grep -q "running"; do sleep 2; done
    qm template 102
    log "VM 102 converted to template"
fi
```

### 5.7 Per-project dev VMs — created on demand (Spec 07)

Not created by frag/30. Created via `devctl add` from the desktop, which
delegates to `vmctl-host` on the host. All clones are created **stopped**.

### 5.8 Idempotency

- VM 100/101 exist and running → skip
- VM 102 exists as template → skip
- VM doesn't exist → create, seed, start (or template for 102)

## 6. End-to-end flow

```
Workstation                         Host (PVE)
-----------                         ----------
1. build-iso.sh (host only)
   reads keys/password-hash
   bakes into answer-host.toml
   copies hash to ISO root
   -> proxmox-ve_9.2-1_auto.iso

2. USB host ISO to host         -->  3. Boot USB, PVE autoinstall
                                      answer-host.toml baked in
                                      late-commands:
                                        fetch provisioner from GitHub
                                        write /root/.password-hash

                                    4. First boot -> provision-host.sh
                                      10-gpu-passthrough.sh
                                      20-memory-swap.sh
                                      25-desktop-control.sh:
                                        create vmctl user
                                        generate control keypair
                                        install sudoers + vmctl-host
                                      30-create-guests.sh:
                                        read /root/.password-hash
                                        read vmctl private key
                                        fetch user-data templates
                                          from GitHub (placeholders)
                                        substitute hash + vmctl key
                                        build NoCloud seed ISOs
                                        qm create + start (100/101)
                                        qm create + start 102
                                          provisioning gate
                                          cloud-init clean
                                          qm template 102
                                      90-finalize.sh:
                                        networking, firewall, dnsmasq
                                        add INPUT rule for desktop:22
```

Desktop first boot:
```
                                    5. VM 100 autoinstall runs
                                      -> first-boot scripts fetch
                                         from GitHub, install stack
                                      -> installs devctl + vmctl key
                                      -> desktop ready for control
```

Dev VM lifecycle (after host + desktop provisioned):
```
Desktop                             Host (PVE)
-------                             ----------
6. devctl add nested          -->    vmctl-host: clone 102 -> 103
                                     add dnsmasq + hosts + inventory
                                     VM 103 created STOPPED

7. devctl start 103           -->    qm start 103
                                     -> clone boots (provisioned disk)
                                     -> dev-firstboot.sh runs
                                     -> dev-nested-provision.sh runs
                                     -> nested_dev repo cloned
                                     -> Docker images pulled
```

## 7. What comes from where

| Artifact | Source | Transport |
|---|---|---|
| Host installer ISO | Built locally, USB | Manual (one-time) |
| Password hash | Embedded in host ISO | USB (same as host) |
| Host provisioner | GitHub (`<REF>`) | Network (late-commands) |
| Guest user-data templates | GitHub (`<REF>`) | Network (frag/30) |
| Guest first-boot scripts | GitHub (`<REF>`) | Network (guest first-boot) |
| NVIDIA/CUDA/Docker/Ollama | Official upstream repos | Network (guest first-boot) |
| Ubuntu packages | Ubuntu archive | Network (install + first-boot) |

## 8. Security model

| Secret | Where it lives | On GitHub? |
|---|---|---|
| Password hash | Host ISO -> `/root/.password-hash` | No |
| SSH private key | User's workstation only | No |
| SSH public key | Host ISO (baked in answer file) | No |
| `keys/password-hash` | Build workstation (gitignored) | No |
| `keys/host_os_ed25519.pub` | Repo (committed) | Yes (public key) |

## 9. Open questions

- Should `frag/30` cache fetched templates locally (e.g.
  `/root/.cache/cidata/`) to avoid re-fetching on re-runs?
- Should the host serve the NoCloud seeds over HTTP for PXE boot, or
  is direct attachment sufficient?

## 10. Files to create/modify

| File | Change |
|---|---|
| `provision/host/build-iso.sh` | Copy `keys/password-hash` to ISO root |
| `provision/host/answer-host.toml` | Add `persist-password-hash` late-command |
| `provision/host/frag/25-desktop-control.sh` | **New**: vmctl user, keypair, sudoers, staging |
| `provision/host/frag/30-create-guests.sh` | Rewrite: NoCloud seeds, inject hash + vmctl key, create VMs, provisioning gate for 102 |
| `provision/host/frag/90-finalize.sh` | Add INPUT rule for desktop→host SSH (port 22) |
| `provision/host/vmctl/vmctl-host` | **New**: restricted control stub (Spec 07) |
| `provision/host/vmctl/sudoers` | **New**: vmctl sudoers drop-in (Spec 07) |
| `desktop/user-data/user-data` | Add `__VMCTL_PRIV_B64__` late-command placeholder |
| `specs/06-guest-iso-transport.md` | This file |
