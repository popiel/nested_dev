# Remediate the 102 golden image (one-time)

The `dev-template` (vm 102) was converted to a template before the
conversion sanitization existed (`shutdown: poweroff` gate era, pre-sanitize
`frag/30`). It carries per-clone identity and rendered private keys that the
fixed automation would never let through. These steps repair that one image
in place. Future conversions sanitize themselves; this file is not a
procedure to repeat.

## Preconditions (check all three)

1. `qm config 102` shows `template: 1` and the VM is `stopped`.
2. No clones of 102 exist yet. If any were made, they carry the same
   material and need the same treatment (or destruction).
3. The host has no other `ubuntu-vg` active. `101`'s data disk carries a
   same-named VG; if `vgs` shows duplicates or confusion, resolve that
   first — never write through an ambiguous VG name.

## 1. Detach the seed ISO

The attached seed carries rendered private keys (`vmctl`, guest-id) that
must never reach a clone:

```bash
qm set 102 --delete ide0
qm config 102 | grep -E "^(template|ide)"
```

Expect `template: 1` and no `ide0` line. If `qm set` refuses a template,
stop here and report back — the fallback (clone, fix, reconvert) is heavier
and not written down yet.

## 2. Mount the base image read-write

LVs were renamed at conversion (`vm-102-disk-N` → `base-102-disk-N`):

```bash
kpartx -av /dev/pve/base-102-disk-1
vgchange -ay ubuntu-vg /dev/mapper/pve-base--102--disk--1p3 2>&1 | tail -1
LV=$(lvs --noheadings -o lv_path ubuntu-vg 2>/dev/null | tr -d ' ' | head -1)
mkdir -p /mnt/t102-fix
mount -o rw "$LV" /mnt/t102-fix
```

The PV-scoped `vgchange` is deliberate: it activates only this disk's VG
even if another `ubuntu-vg` exists elsewhere on the host.

## 3. Preserve build evidence, then sanitize

Cloud logs go to `/root/` (audit trail, root-only); guest-visible copies go:

```bash
cp -a /mnt/t102-fix/var/log/cloud-init*.log /root/ 2>/dev/null
rm -f /mnt/t102-fix/var/log/cloud-init*.log /mnt/t102-fix/var/log/cloud-init-output.log
rm -rf /mnt/t102-fix/var/lib/cloud/instance /mnt/t102-fix/var/lib/cloud/instances
rm -f /mnt/t102-fix/etc/ssh/ssh_host_*
: > /mnt/t102-fix/etc/machine-id
[ ! -L /mnt/t102-fix/var/lib/dbus/machine-id ] && : > /mnt/t102-fix/var/lib/dbus/machine-id || true
rm -f /mnt/t102-fix/var/lib/systemd/random-seed
rm -f /mnt/t102-fix/var/lib/dhcp/*.leases /mnt/t102-fix/var/lib/dhcp/*.lease /mnt/t102-fix/var/lib/systemd/network/*.lease
: > /mnt/t102-fix/root/.bash_history
truncate -s 0 /mnt/t102-fix/home/*/.bash_history 2>/dev/null || true
```

## 4. Verify, then tear down

```bash
echo "--- verify ---"
ls -A /mnt/t102-fix/etc/ssh/
wc -c /mnt/t102-fix/etc/machine-id
ls /mnt/t102-fix/var/lib/cloud/ 2>&1 | head -3
ls /mnt/t102-fix/var/lib/dhcp/ 2>&1 | head -5
umount /mnt/t102-fix
vgchange -an ubuntu-vg 2>&1 | tail -1
kpartx -dv /dev/pve/base-102-disk-1
```

Expect: ssh dir without `ssh_host_*` (client config stays), machine-id
`0` bytes, no `instance` under `/var/lib/cloud`, empty dhcp dir. The
unmount/deactivate/unmap order matters — reversing it strands state, and a
mounted base image must never meet a running clone.

## Deliberately not done here

- Host seed files (`cidata/*`, seed ISOs with rendered keys) stay: root-only,
  regeneration source, rewritten every refresh. Host compromise is total
  anyway; guest-visible copies were the exposure.
- Guest `virtio-rng` (early-boot entropy without a shared seed): noted
  follow-up, not part of this repair.
- Whether `vmctl`-driven clones expect a seed datasource (spec-07
  alignment): open question for fleet work, unaffected by this repair.
