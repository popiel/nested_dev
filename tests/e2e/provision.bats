#!/usr/bin/env bats
# tests/e2e/provision.bats — the whole provisioning run, asserted as state.
#
# This suite answers the only question that matters: after the provisioning
# process completes, are the accounts and the VMs set up correctly? It runs
# the real rendered bootstrap (provision/host/first-boot.sh with its
# build-time placeholders substituted) against a scratch PVE_ROOT, with the
# outside world stubbed at the boundary:
#
#   stubbed (not ours): the hypervisor (qm), the hardware (lspci/lscpu), the
#     network (wget), the package servers (apt-get answers 401 exactly like
#     the enterprise repository while it is enabled), system services
#     (systemctl, iptables, ...), the account database (useradd et al.), the
#     bootloader/initramfs writers, the clock (sleep).
#   real (ours): every line of first-boot.sh and every fragment, the tarball
#     fetch and extract, every file write, every template substitution.
#
# Nothing here asserts source text or ordering. The one ordering property the
# old suite pinned — apt must work before anything installs — emerges from the
# environment instead: any premature apt call fails the run, which is what
# happens on the real host.
#
# The fixture host mirrors the real one: no subscription, an Intel iGPU alone
# in its IOMMU group, two dGPUs sharing a group with their root ports, and a
# stale all-devices vfio-pci.ids already in GRUB.

load '../lib/helpers'

E2E_DIR="${PROJECT_ROOT}/tests/e2e"

setup_file() {
    WORK="${BATS_SUITE_TMPDIR}/e2e"
    # Start empty even if the suite temp dir is ever reused: every journal in
    # here is appended to, so leftover state from a previous run would silently
    # inflate the counts this suite asserts.
    rm -rf "$WORK"
    ROOT="${WORK}/root"
    MOCKBIN="${WORK}/mockbin"
    STATE="${WORK}/state"
    TEMPLATEDIR="${WORK}/templates"
    mkdir -p "$WORK" "$ROOT" "$MOCKBIN" "$STATE" "$TEMPLATEDIR"

    cp "${E2E_DIR}/stubs/"* "$MOCKBIN/"
    chmod +x "$MOCKBIN"/*

    cp "${E2E_DIR}/fixtures/template-desktop" "$TEMPLATEDIR/desktop"
    cp "${E2E_DIR}/fixtures/template-llm" "$TEMPLATEDIR/llm"
    cp "${E2E_DIR}/fixtures/template-dev" "$TEMPLATEDIR/dev"

    # --- the fixture host, as the installer leaves it ---
    mkdir -p "$ROOT/var/log" "$ROOT/root" \
        "$ROOT/etc/apt/sources.list.d" "$ROOT/etc/default" \
        "$ROOT/proc" "$ROOT/home" \
        "$ROOT/sys/bus/pci/devices" \
        "$ROOT/sys/kernel/iommu_groups/0/devices" \
        "$ROOT/sys/kernel/iommu_groups/2/devices"
    cp "${E2E_DIR}/fixtures/pve-enterprise.sources" \
        "$ROOT/etc/apt/sources.list.d/pve-enterprise.sources"
    cp "${E2E_DIR}/fixtures/ceph.sources" \
        "$ROOT/etc/apt/sources.list.d/ceph.sources"
    cp "${E2E_DIR}/fixtures/debian.sources" \
        "$ROOT/etc/apt/sources.list.d/debian.sources"
    cp "${E2E_DIR}/fixtures/meminfo" "$ROOT/proc/meminfo"
    cp "${E2E_DIR}/fixtures/grub-default" "$ROOT/etc/default/grub"
    cp "${E2E_DIR}/fixtures/fstab" "$ROOT/etc/fstab"
    cp "${E2E_DIR}/fixtures/dnsmasq.conf" "$ROOT/etc/dnsmasq.conf"
    mkdir -p "$ROOT/var/lib/dhcp"
    cp "${E2E_DIR}/fixtures/dhclient.leases" "$ROOT/var/lib/dhcp/dhclient.eno1.leases"

    # sysfs mirroring the measured host: group 0 holds the iGPU alone, group 2
    # holds both dGPUs, both audio functions and both root ports.
    for d in 0000:00:02.0 0000:01:00.0 0000:01:00.1 \
             0000:02:00.0 0000:02:00.1 0000:00:01.0 0000:00:01.1; do
        mkdir -p "$ROOT/sys/bus/pci/devices/$d"
    done
    ln -s ../../../../kernel/iommu_groups/0 \
        "$ROOT/sys/bus/pci/devices/0000:00:02.0/iommu_group"
    for d in 0000:01:00.0 0000:01:00.1 0000:02:00.0 0000:02:00.1 \
             0000:00:01.0 0000:00:01.1; do
        ln -s ../../../../kernel/iommu_groups/2 \
            "$ROOT/sys/bus/pci/devices/$d/iommu_group"
        ln -s ../../../../bus/pci/devices/$d \
            "$ROOT/sys/kernel/iommu_groups/2/devices/$d"
    done
    ln -s ../../../../bus/pci/devices/0000:00:02.0 \
        "$ROOT/sys/kernel/iommu_groups/0/devices/0000:00:02.0"

    # --- the fetchable tree: a snapshot of the live repo, plus the key ---
    STAGE="${WORK}/stage/nested_dev-e2eref"
    mkdir -p "$STAGE/keys"
    cp -r "${PROJECT_ROOT}/provision" "$STAGE/provision"
    printf 'ssh-ed25519 E2ETREEPUBKEY e2e-tree@test\n' \
        > "$STAGE/keys/host_os_ed25519.pub"
    tar -czhf "${WORK}/fetch.tgz" -C "${WORK}/stage" nested_dev-e2eref

    # --- render the bootstrap the way build-iso.sh would ---
    sed -e "s|__GITHUB_REF__|e2eref|g" \
        -e "s|__ADMIN_PUBKEY__|ssh-ed25519 E2EADMINPUBKEY e2e-build@test|g" \
        -e "s|__PERSONALIZATION_USERNAME__|e2eop|g" \
        -e "s|__PERSONALIZATION_FULLNAME__|E2E Operator|g" \
        -e "s|__PERSONALIZATION_UID__|1500|g" \
        -e "s|__PERSONALIZATION_GID__|1500|g" \
        -e "s|__PERSONALIZATION_HOME__|/home/e2eop|g" \
        -e "s|__PERSONALIZATION_PASSWORD_HASH__|E2EHASHSTRING|g" \
        "${PROJECT_ROOT}/provision/host/first-boot.sh" > "${WORK}/first-boot.sh"

    cat > "${WORK}/env" <<EOF
export E2E_WORK="${WORK}"
export E2E_ROOT="${ROOT}"
export E2E_STATE="${STATE}"
EOF

    # --- run the real thing, once ---
    # In an if-condition so a failing run records its status instead of
    # tripping errexit before `echo` runs.
    if PATH="${MOCKBIN}:${PATH}" \
    PVE_ROOT="${ROOT}" \
    PVE_SYSFS="${ROOT}/sys" \
    PVE_PROC="${ROOT}/proc" \
    E2E_STATE="${STATE}" \
    E2E_MOCKBIN="${MOCKBIN}" \
    E2E_TARBALL="${WORK}/fetch.tgz" \
    E2E_TEMPLATES="${TEMPLATEDIR}" \
    bash "${WORK}/first-boot.sh" >"${WORK}/run.out" 2>&1; then
        echo "0" > "${WORK}/exit"
    else
        echo "1" > "${WORK}/exit"
    fi
    if [ "$(cat "${WORK}/exit")" != "0" ]; then
        echo "e2e provisioning run failed; runner output tail:" >&2
        tail -20 "${WORK}/run.out" >&2
        echo "--- provision log tail: ---" >&2
        tail -40 "${ROOT}/var/log/pve-firstboot.log" >&2
        return 1
    fi

    # --- and again, the way a re-provision runs ---
    # The runner short-circuits on the completion marker, so a second
    # provision-host run never happens that way. Remove the marker and run the
    # provisioner directly: every fragment claims idempotency, and here that
    # claim is settled as state — one key entry, one create per guest, clean
    # seeds — instead of by reading the fragment source for guards.
    rm -f "${ROOT}/var/lib/pve-firstboot/complete"
    if PATH="${MOCKBIN}:${PATH}" \
    PVE_ROOT="${ROOT}" \
    PVE_SYSFS="${ROOT}/sys" \
    PVE_PROC="${ROOT}/proc" \
    E2E_STATE="${STATE}" \
    E2E_MOCKBIN="${MOCKBIN}" \
    E2E_TARBALL="${WORK}/fetch.tgz" \
    E2E_TEMPLATES="${TEMPLATEDIR}" \
    bash "${ROOT}/root/provision/host/provision-host.sh" >>"${WORK}/run.out" 2>&1; then
        echo "0" > "${WORK}/exit2"
    else
        echo "1" > "${WORK}/exit2"
    fi
    if [ "$(cat "${WORK}/exit2")" != "0" ]; then
        echo "e2e re-provisioning run failed; provision log tail:" >&2
        tail -40 "${ROOT}/var/log/pve-firstboot.log" >&2
        return 1
    fi

    # The suite temp dir is deleted after the run, so keep the full logs where
    # a failing assertion can be diagnosed afterwards (tests/.timing is
    # gitignored, like the per-test records already kept there).
    TIMING_KEEP="${PROJECT_ROOT}/tests/.timing/e2e-last"
    mkdir -p "$TIMING_KEEP"
    cp "${WORK}/run.out" "$TIMING_KEEP/run.out"
    cp "${ROOT}/var/log/pve-firstboot.log" "$TIMING_KEEP/pve-firstboot.log"
    cp "$STATE/journal" "$TIMING_KEEP/journal"
    cp "$STATE/qm-journal" "$TIMING_KEEP/qm-journal"
    cp "$STATE/apt-journal" "$TIMING_KEEP/apt-journal"
    cp "$STATE/wget-journal" "$TIMING_KEEP/wget-journal"
    cp "$STATE/account-journal" "$TIMING_KEEP/account-journal"
}

e2e() { source "${BATS_SUITE_TMPDIR}/e2e/env"; }

require_run_ok() {
    e2e
    [ "$(cat "$E2E_WORK/exit")" = "0" ] || {
        echo "provisioning run failed; tail of run output:" >&2
        tail -30 "$E2E_WORK/run.out" >&2
        return 1
    }
    [ "$(cat "$E2E_WORK/exit2")" = "0" ] || {
        echo "re-provisioning run failed; tail of run output:" >&2
        tail -30 "$E2E_WORK/run.out" >&2
        return 1
    }
}

# --- the operator account ---

@test "the operator account is created with the rendered identity" {
    require_run_ok
    assert_file_contains "$E2E_STATE/account-journal" "groupadd -g 1500 e2eop"
    assert_file_contains "$E2E_STATE/account-journal" \
        "useradd -u 1500 -g 1500 -d /home/e2eop -s /bin/bash -c E2E Operator e2eop"
}

@test "the rendered password hash reaches the account and its hash file" {
    require_run_ok
    [ "$(cat "$E2E_ROOT/root/.personalization-password-hash")" = "E2EHASHSTRING" ]
    [ "$(stat -c %a "$E2E_ROOT/root/.personalization-password-hash")" = "600" ]
    assert_file_contains "$E2E_STATE/chpasswd-journal" "e2eop:E2EHASHSTRING"
}

@test "the account is granted the sudo group" {
    require_run_ok
    assert_file_contains "$E2E_STATE/account-journal" "groupadd -r sudo"
    assert_file_contains "$E2E_STATE/account-journal" "usermod -aG sudo e2eop"
}

@test "the operator key is installed with restrictive modes" {
    require_run_ok
    [ "$(cat "$E2E_ROOT/home/e2eop/.ssh/authorized_keys")" \
        = "ssh-ed25519 E2EADMINPUBKEY e2e-build@test" ]
    [ "$(stat -c %a "$E2E_ROOT/home/e2eop/.ssh/authorized_keys")" = "600" ]
    [ "$(stat -c %a "$E2E_ROOT/home/e2eop/.ssh")" = "700" ]
}

# --- the package repositories ---

@test "every enterprise source is moved aside and the suite is exact" {
    require_run_ok
    local srcdir="$E2E_ROOT/etc/apt/sources.list.d"
    # Both enterprise files are moved aside under names apt ignores, not
    # deleted: restoring a subscription is moving them back.
    for name in pve-enterprise.sources ceph.sources; do
        [ ! -e "$srcdir/$name" ]
        run cmp "$srcdir/$name.disabled" "${E2E_DIR}/fixtures/$name"
    done
    # The plain Debian source is untouched.
    run cmp "$srcdir/debian.sources" "${E2E_DIR}/fixtures/debian.sources"
    # ...and the no-subscription repository is in place for the detected suite.
    run grep -xF 'deb http://download.proxmox.com/debian/pve trixie pve-no-subscription' \
        "$srcdir/pve-no-subscription.list"
}

@test "no package operation ran against the 401 repositories" {
    require_run_ok
    assert_file_not_contains "$E2E_STATE/apt-journal" "-> 100"
    run grep -c "update" "$E2E_STATE/apt-journal"
    [ "$output" -ge 1 ]
}

@test "sudo ends up available on the host" {
    require_run_ok
    # Either it was installed (a host without the package, like the real one)
    # or it was already present (a dev machine). Both are success; the install
    # branch itself is exercised separately in tests/unit/frag06-sudo.bats with
    # a PATH from which sudo is absent.
    local log="$E2E_ROOT/var/log/pve-firstboot.log"
    if grep -q "install -y sudo" "$E2E_STATE/apt-journal"; then
        assert_file_contains "$log" "sudo installed:"
    else
        assert_file_contains "$log" "sudo already installed"
    fi
}

# --- GPU passthrough ---

@test "the accepted device set is the iGPU alone" {
    require_run_ok
    [ "$(cat "$E2E_ROOT/var/lib/pve-firstboot/passthrough-devices")" = "0000:00:02.0" ]
}

@test "vfio binds the iGPU and nothing else" {
    require_run_ok
    assert_file_contains "$E2E_ROOT/etc/modprobe.d/vfio.conf" \
        "options vfio-pci ids=8086:5912 disable_vga=1"
    assert_file_not_contains "$E2E_ROOT/etc/modprobe.d/vfio.conf" "10de"
}

@test "GRUB carries the narrowed set, not the stale one" {
    require_run_ok
    local grub="$E2E_ROOT/etc/default/grub"
    run grep -c "vfio-pci.ids=" "$grub"
    [ "$output" = "1" ]
    assert_file_contains "$grub" "vfio-pci.ids=8086:5912"
    assert_file_not_contains "$grub" "10de"
    assert_file_contains "$grub" "intel_iommu=on"
    assert_file_contains "$grub" "iommu=pt"
    assert_file_contains "$grub" "disable_vga=1"
    # The variable line itself must be intact: an anchor leaked from a sed
    # pattern once wrote a literal `^` at its start, which update-grub ignores
    # — the tokens were all present on a line the bootloader never read.
    run grep -c '^GRUB_CMDLINE_LINUX_DEFAULT="' "$grub"
    [ "$output" = "1" ]
}

@test "only the passed-through driver is blacklisted" {
    require_run_ok
    assert_file_contains "$E2E_ROOT/etc/modprobe.d/blacklist-gpu.conf" "blacklist i915"
    assert_file_not_contains "$E2E_ROOT/etc/modprobe.d/blacklist-gpu.conf" "nvidia"
    assert_file_not_contains "$E2E_ROOT/etc/modprobe.d/blacklist-gpu.conf" "nouveau"
}

@test "the rejected dGPUs are named in the log with their group" {
    require_run_ok
    local log="$E2E_ROOT/var/log/pve-firstboot.log"
    assert_file_contains "$log" "SKIP: 01:00.0"
    assert_file_contains "$log" "SKIP: 02:00.0"
    assert_file_contains "$log" "00:01.0"
}

# --- the guests ---

@test "the private network is up with DHCP, DNS and egress" {
    require_run_ok
    # The bridge carries its address (verified by the fragment itself before
    # any guest boots — an unapplied interfaces file fails loudly here
    # instead of failing three guests opaquely minutes later).
    assert_file_contains "$E2E_ROOT/etc/network/interfaces" "address 192.168.100.1/24"
    assert_file_contains "$E2E_ROOT/etc/network/interfaces" "auto eno1"
    assert_file_contains "$E2E_ROOT/var/log/pve-firstboot.log" \
        "vmbr0 carries 192.168.100.1/24"
    # bind-dynamic, not bind-interfaces: the bridge has no carrier until
    # guests attach, and bind-interfaces never picks up DHCP on an interface
    # that appears later — dnsmasq ends up answering DNS while deaf on DHCP.
    assert_file_contains "$E2E_ROOT/etc/dnsmasq.d/nested_dev.conf" "bind-dynamic"
    assert_file_not_contains "$E2E_ROOT/etc/dnsmasq.d/nested_dev.conf" "bind-interfaces"
    # The LAN side is re-verified after the reconfiguration: the DHCP renewal
    # races the first apt call, which otherwise fails on every repository.
    assert_file_contains "$E2E_ROOT/var/log/pve-firstboot.log" \
        "upstream connectivity confirmed"
    # dnsmasq serves the segment and guest egress is NATed.
    assert_file_contains "$E2E_STATE/journal" "systemctl enable dnsmasq"
    assert_file_contains "$E2E_STATE/journal" "systemctl restart dnsmasq"
    assert_file_contains "$E2E_STATE/journal" \
        "POSTROUTING -s 192.168.100.0/24 -o eno1 -j MASQUERADE"
    assert_file_contains "$E2E_ROOT/etc/sysctl.d/99-nested-dev.conf" \
        "net.ipv4.ip_forward = 1"
    # Upstream resolvers come from the DHCP lease: nothing on a fresh system
    # creates /run/resolv.conf, and without it dnsmasq forwards into the void.
    run grep -xF "nameserver 192.168.14.254" "$E2E_ROOT/run/resolv.conf"
}

@test "the run reboots once to activate the vfio binding, then resumes" {
    require_run_ok
    # GRUB cmdline, modprobe config and initramfs all take effect at boot, and
    # nothing unbinds the host driver live: a guest started before that reboot
    # fails attaching hardware the host kernel still holds.
    [ -f "$E2E_ROOT/var/lib/pve-firstboot/rebooted" ]
    # Suppressed under PVE_ROOT — the harness observes the marker and the
    # continuation, not an actual reboot of the test machine.
    assert_file_contains "$E2E_ROOT/var/log/pve-firstboot.log" \
        "(reboot suppressed: PVE_ROOT is set)"
}

@test "the desktop is created with the iGPU on the checked bridge and storage" {
    require_run_ok
    local line
    line="$(grep "qm create 100 " "$E2E_STATE/qm-journal")"
    assert_contains "$line" "--name desktop"
    # Option and value as separate argv words with an explicit host= prefix:
    # the previous form glued them into one word ("--hostpci0 0000:..."),
    # which PVE 9 rejects with "Unknown option". This exact substring fails
    # on the glued form.
    assert_contains "$line" "--hostpci0 host=0000:00:02.0,pcie=1,x-vga=0"
    # Installer ISOs ride --ide2 with media=cdrom: --cdrom0 is not a qm
    # option and is rejected the same way.
    assert_contains "$line" "--ide2 $E2E_ROOT/var/lib/vz/template/iso/ubuntu-26.04-desktop-amd64.iso,media=cdrom"
    assert_not_contains "$line" "--cdrom"
    assert_contains "$line" "bridge=vmbr0"
    assert_contains "$line" "local-lvm:40"
    assert_contains "$line" "52:54:00:00:01:00"
    assert_contains "$line" "--memory 8192"
    # Desktop keeps no emulated display: its iGPU is its console.
    assert_contains "$line" "--vga none"
    # Explicit installer-first boot order: PVE passes strict=on, so an order
    # naming only the empty disk parks the guest at a UEFI shell instead of
    # falling through to the CDROM.
    assert_contains "$line" '--boot order=ide2;scsi0'
    # OVMF without an efidisk boots with temporary efivars, so installed
    # guests lose their boot entries on reboot.
    assert_contains "$line" "--efidisk0 local-lvm:1"
    # Uncapped on the 8-core fixture host; the capping branch is covered in
    # tests/unit/frag30-guest-create.bats against a 4-core node.
    assert_contains "$line" "--cores 4"
}

@test "the llm guest is created with no passthrough hardware" {
    require_run_ok
    local line
    line="$(grep "qm create 101 " "$E2E_STATE/qm-journal")"
    assert_contains "$line" "--name llm"
    assert_contains "$line" "local-lvm:500"
    # Server guests keep an emulated display for console access.
    assert_contains "$line" "--vga std"
    assert_contains "$line" '--boot order=ide2;scsi0'
    # The 6-core profile capped at the fixture node's 4-vCPU maximum, with the
    # reason logged — the same capping the real 4-thread host required.
    assert_contains "$line" "--cores 4"
    assert_file_contains "$E2E_ROOT/var/log/pve-firstboot.log" \
        "capping allocation from 6 to 4"
    assert_contains "$line" "--ide2 $E2E_ROOT/var/lib/vz/template/iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom"
    assert_not_contains "$line" "hostpci"
    assert_not_contains "$line" "--cdrom"
    run grep -c "qm set 101" "$E2E_STATE/qm-journal"
    [ "$output" = "0" ]
}

@test "the dev template is created, started and converted" {
    require_run_ok
    local line
    line="$(grep "qm create 102 " "$E2E_STATE/qm-journal")"
    assert_contains "$line" "--name dev-template"
    assert_contains "$line" "--vga std"
    assert_contains "$line" '--boot order=ide2;scsi0'
    assert_contains "$line" "--efidisk0 local-lvm:1"
    for vmid in 100 101 102; do
        run grep -c "qm start $vmid" "$E2E_STATE/qm-journal"
        [ "$output" -ge 1 ]
    done
    run grep -c "qm template 102" "$E2E_STATE/qm-journal"
    [ "$output" = "1" ]
}

@test "guest seeds carry the hash and both keys, and no placeholders survive" {
    require_run_ok
    local seeddir="$E2E_ROOT/var/lib/vz/template/cidata"
    for guest in desktop llm dev; do
        local seed="$seeddir/$guest-user-data"
        assert_file_contains "$seed" "E2EHASHSTRING"
        assert_file_contains "$seed" "ssh-ed25519 E2ETREEPUBKEY e2e-tree@test"
        assert_file_contains "$seed" "E2EPUB-guest_id_ed25519"
        run grep -cE '__[A-Z_]+__' "$seed"
        [ "$output" = "0" ]
        run grep -c "CHANGE_ME" "$seed"
        [ "$output" = "0" ]
        [ -f "$seeddir/$guest-meta-data" ]
    done
    run grep -c "genisoimage" "$E2E_STATE/journal"
    # Once per guest per provisioning run, and the suite provisions twice.
    [ "$output" = "6" ]
    # Seed ISOs are built into the iso content dir, not the seed dir: PVE
    # verifies every drive path against its storages, and template/cidata/
    # belongs to none — a seed ISO built there is rejected with "unable to
    # associate path to any storage".
    for guest in desktop llm dev; do
        run grep -c "template/iso/${guest}-seed.iso" "$E2E_STATE/journal"
        [ "$output" = "2" ]
        # ...and mapped to the exact names NoCloud discovers. Bare file args
        # bake in on-disk basenames (`desktop-user-data`) that cloud-init
        # ignores, leaving the installer interactive forever.
        run grep -c " user-data=.*${guest}-user-data" "$E2E_STATE/journal"
        [ "$output" = "2" ]
        run grep -c " meta-data=.*${guest}-meta-data" "$E2E_STATE/journal"
        [ "$output" = "2" ]
    done
}

@test "re-provisioning changes nothing observable" {
    require_run_ok
    # The guest identity key must appear exactly once no matter how many times
    # the fragments run: the append is guarded by a content check.
    run grep -c "E2EPUB-guest_id_ed25519" "$E2E_ROOT/root/.ssh/authorized_keys"
    [ "$output" = "1" ]
    # No guest is created twice: the second run sees them via qm status.
    for vmid in 100 101 102; do
        run grep -c "qm create $vmid " "$E2E_STATE/qm-journal"
        [ "$output" = "1" ]
    done
    # The fstab swap entry is appended once.
    run grep -c "swapfile none swap" "$E2E_ROOT/etc/fstab"
    [ "$output" = "1" ]
    # And the seeds are still clean after the rebuild.
    run grep -cE '__[A-Z_]+__' "$E2E_ROOT/var/lib/vz/template/cidata/desktop-user-data"
    [ "$output" = "0" ]
}

@test "staged private keys are destroyed and canonical keypairs kept" {
    require_run_ok
    [ ! -e "$E2E_ROOT/root/.nested-dev/vmctl-priv-staged" ]
    [ ! -e "$E2E_ROOT/root/.nested-dev/guest-id-priv-staged" ]
    for key in vmctl/vmctl_ed25519 vmctl/vmctl_ed25519.pub \
               guest-id/guest_id_ed25519 guest-id/guest_id_ed25519.pub; do
        [ -f "$E2E_ROOT/root/.nested-dev/$key" ]
    done
}

@test "the installer ISOs are fetched" {
    require_run_ok
    local isodir="$E2E_ROOT/var/lib/vz/template/iso"
    [ -f "$isodir/ubuntu-26.04-desktop-amd64.iso" ]
    [ -f "$isodir/ubuntu-26.04-live-server-amd64.iso" ]
}

# --- control channel, service, host config ---

@test "the VM inventory names the three guests" {
    require_run_ok
    local inv="$E2E_ROOT/etc/nested-dev/inventory"
    run grep -xF "100  desktop  lychee  192.168.100.100  52:54:00:00:01:00  running  desktop" "$inv"
    run grep -xF "101  llm  lychee-llm  192.168.100.101  52:54:00:00:01:01  running  llm" "$inv"
    run grep -xF "102  dev-template  lychee-dev-template  192.168.100.102  52:54:00:00:01:02  template  dev-template" "$inv"
}

@test "vmctl is a forced-command account carrying the repo's credentials" {
    require_run_ok
    local authkeys="$E2E_ROOT/home/vmctl/.ssh/authorized_keys"
    run cat "$authkeys"
    [ "$output" = 'command="/usr/local/sbin/vmctl-host",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 E2EPUB-vmctl_ed25519 e2e@test' ]
    [ "$(stat -c %a "$authkeys")" = "600" ]
    run cmp "$E2E_ROOT/etc/sudoers.d/vmctl" "${PROJECT_ROOT}/provision/host/vmctl/sudoers"
    run cmp "$E2E_ROOT/usr/local/sbin/vmctl-host" "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host"
}

@test "the guest identity is trusted on the host, pinned to the desktop" {
    require_run_ok
    assert_file_contains "$E2E_ROOT/root/.ssh/authorized_keys" \
        'from="192.168.100.100",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 E2EPUB-guest_id_ed25519'
    [ -f "$E2E_ROOT/etc/dnsmasq.d/zz-dev.conf" ]
}

@test "the first-boot unit is installed and the run is marked complete" {
    require_run_ok
    assert_file_contains "$E2E_ROOT/etc/systemd/system/pve-firstboot.service" \
        "ExecStart=/root/provision/host/provision-host.sh"
    [ -L "$E2E_ROOT/etc/systemd/system/multi-user.target.wants/pve-firstboot.service" ]
    [ -f "$E2E_ROOT/var/lib/pve-firstboot/complete" ]
    assert_file_contains "$E2E_STATE/journal" "systemctl disable --now pve-firstboot"
}

@test "the host network, DNS and firewall land as configured" {
    require_run_ok
    assert_file_contains "$E2E_ROOT/etc/network/interfaces" "address 192.168.100.1/24"
    assert_file_contains "$E2E_ROOT/etc/network/interfaces" "auto eno1"
    run grep -c "dhcp-host=" "$E2E_ROOT/etc/dnsmasq.d/nested_dev.conf"
    [ "$output" = "3" ]
    assert_file_contains "$E2E_ROOT/etc/resolv.conf" "nameserver 127.0.0.1"
    assert_file_contains "$E2E_ROOT/etc/hosts" "192.168.100.100 lychee.wolfskeep.com lychee"
    [ -f "$E2E_ROOT/root/output/MANIFEST" ]
    [ -f "$E2E_ROOT/etc/motd" ]
    assert_file_contains "$E2E_STATE/journal" "iptables -P INPUT DROP"
    assert_file_contains "$E2E_STATE/journal" "-s 192.168.100.100 -j ACCEPT"
    assert_file_contains "$E2E_STATE/journal" "--dport 3389"
    assert_file_contains "$E2E_STATE/journal" "MASQUERADE"
    # LAN ingress to the desktop: DNAT rewrites these destinations in
    # PREROUTING, but the filter still has to admit them.
    assert_file_contains "$E2E_STATE/journal" \
        "-i eno1 -o vmbr0 -p tcp -d 192.168.100.100 --dport 22 -j ACCEPT"
    assert_file_contains "$E2E_STATE/journal" \
        "-i eno1 -o vmbr0 -p tcp -d 192.168.100.100 --dport 3389 -j ACCEPT"
    # The host-service surface guests need: DHCP and DNS to dnsmasq on vmbr0,
    # requests and replies. Without any one of these the guests never get an
    # address and every installer stalls before writing a byte.
    assert_file_contains "$E2E_STATE/journal" "INPUT -i vmbr0 -p udp --dport 67"
    assert_file_contains "$E2E_STATE/journal" "INPUT -i vmbr0 -p udp --dport 53"
    assert_file_contains "$E2E_STATE/journal" "OUTPUT -o vmbr0 -p udp --sport 67 --dport 68"
    assert_file_contains "$E2E_STATE/journal" "OUTPUT -o vmbr0 -p udp --sport 53"
    # Host HTTP egress: the archives are HTTP-only, so without it apt dies
    # past lockdown — which is also what makes the plain-http mirror check
    # a valid end-to-end probe rather than a firewall artifact.
    assert_file_contains "$E2E_STATE/journal" "OUTPUT -p tcp --dport 80 -j ACCEPT"
    # And the template's egress, without which its first boot cannot fetch.
    assert_file_contains "$E2E_STATE/journal" "-s 192.168.100.102 -p tcp --dport 443"
}

@test "memory and swap are configured" {
    require_run_ok
    assert_file_contains "$E2E_ROOT/etc/default/zramswap" "ALGO=zstd"
    run grep -c "swapfile none swap" "$E2E_ROOT/etc/fstab"
    [ "$output" = "1" ]
    assert_file_contains "$E2E_STATE/journal" "systemctl enable --now zramswap"
}
