# Spec 06 — Guest VM provisioning (host-mediated autoinstall)

Status: Draft (new; closes the gap between build and running guests)
Depends on: Spec 01 (host), Spec 02 (desktop), Spec 03 (LLM), Spec 04 (Dev),
            Spec 05 (personalization)

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

## 3. How the password hash flows

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
frag/30-create-guests.sh
  reads /root/.password-hash
  fetches user-data template from GitHub (CHANGE_ME_HASHED)
  sed-replaces placeholder with real hash
  writes result as NoCloud seed for each guest
       |
       v
Guest autoinstall reads NoCloud seed -> real password configured
```

GitHub never sees the hash. The host is the only place it exists at
runtime.

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

### 5.2 `frag/30-create-guests.sh` — fetch template + inject hash

```bash
# --- Configuration ---
GITHUB_REPO="${PERSONALIZATION_REPO:-popiel/nested_dev}"
GITHUB_TAG="${PERSONALIZATION_TAG:-host_os_v0.1}"
BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_TAG}"
PASSWORD_HASH_FILE="/root/.password-hash"

# --- Read password hash ---
if [ ! -f "$PASSWORD_HASH_FILE" ]; then
    die "Password hash not found: ${PASSWORD_HASH_FILE}"
fi
PASS_HASH="$(cat "$PASSWORD_HASH_FILE")"

# --- Create NoCloud seed directory ---
SEED_DIR="/var/lib/vz/template/cidata"
mkdir -p "$SEED_DIR"

# --- Fetch templates and inject password hash ---
for guest in desktop llm dev; do
    TEMPLATE_URL="${BASE_URL}/${guest}/user-data/user-data"
    SEED_FILE="${SEED_DIR}/${guest}-user-data"

    if ! wget -q "$TEMPLATE_URL" -O "$SEED_FILE" 2>/dev/null; then
        log "WARNING: Could not fetch ${guest} user-data from GitHub"
        continue
    fi

    # Substitute password hash (templates have CHANGE_ME_HASHED)
    sed -i "s|CHANGE_ME_HASHED|${PASS_HASH}|g" "$SEED_FILE"

    # Write meta-data (empty, required by NoCloud)
    echo "instance-id: ${guest}-$(date +%s)" > "${SEED_DIR}/${guest}-meta-data"

    log "NoCloud seed prepared: ${guest}"
done
```

### 5.3 VM creation with NoCloud seed

```bash
# Desktop (VM 100)
if ! qm status 100 >/dev/null 2>&1; then
    qm create 100 \
        --name desktop \
        --memory 8192 --cores 4 --cpu host \
        --scsihw virtio-scsi-single \
        --scsi0 local-lvm:8 \
        --net0 virtio=52:54:00:00:01:00,bridge=vmbr0 \
        --bios ovmf --machine q35 --vga none \
        --serial0 socket --agent enabled=1 \
        --ide2 "${SEED_DIR}/desktop-user-data,media=cdrom" \
        --boot order=scsi0
    # GPU passthrough applied if detected (see 5.4)
    qm start 100
    log "VM 100 (desktop) created and started"
fi
```

### 5.4 GPU passthrough

Apply inline at creation time (current `frag/30` already detects GPUs):

```bash
if [ -n "$IGPU_IDS" ]; then
    qm set 100 --hostpci0 "${IGPU_IDS},pcie=1,x-vga=0"
fi
```

### 5.5 LLM data volume

```bash
if ! qm status 101 >/dev/null 2>&1; then
    qm create 101 \
        --name llm \
        ... (same pattern as desktop) \
        --ide2 "${SEED_DIR}/llm-user-data,media=cdrom" \
        --boot order=scsi0
    qm set 101 --scsi1 local-lvm:500,size=500G
    # GPU passthrough + GeForce workaround
    qm start 101
fi
```

### 5.6 Idempotency

- VM exists and running -> skip
- VM exists, stopped, autoinstall complete -> start
- VM doesn't exist -> create, seed, start

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
                                      30-create-guests.sh:
                                        read /root/.password-hash
                                        fetch user-data templates
                                          from GitHub (placeholders)
                                        substitute hash -> NoCloud seeds
                                        qm create + qm start
                                        -> autoinstall runs
                                        -> first-boot scripts fetch
                                           from GitHub, install stack
                                      90-finalize.sh
```

## 7. What comes from where

| Artifact | Source | Transport |
|---|---|---|
| Host installer ISO | Built locally, USB | Manual (one-time) |
| Password hash | Embedded in host ISO | USB (same as host) |
| Host provisioner | GitHub (`<REF>` tag) | Network (late-commands) |
| Guest user-data templates | GitHub (`main` branch) | Network (frag/30) |
| Guest first-boot scripts | GitHub (`<REF>` tag) | Network (guest first-boot) |
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

## 9. Air-gapped fallback

If GitHub is unreachable:
- Host: provisioner scripts embedded on ISO (current behavior)
- Guests: custom ISOs with baked-in user-data (built optionally via
  `build-iso.sh`), SCP to host, attach as CD-ROM, boot manually

## 10. Files to create/modify

| File | Change |
|---|---|
| `provision/host/build-iso.sh` | Copy `keys/password-hash` to ISO root |
| `provision/host/answer-host.toml` | Add `persist-password-hash` late-command |
| `provision/host/frag/30-create-guests.sh` | Rewrite: fetch templates, inject hash, create with NoCloud, start VMs |
| `specs/06-guest-iso-transport.md` | This file |

## 11. Open questions

- Should `frag/30` cache fetched templates locally (e.g.
  `/root/.cache/cidata/`) to avoid re-fetching on re-runs?
- Should there be a `--offline` flag that falls back to local ISOs?
- Should the host serve the NoCloud seeds over HTTP for PXE boot, or
  is direct attachment sufficient?
