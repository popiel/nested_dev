#!/bin/sh
# provision/host/first-boot.sh — TEMPLATE, rendered at build time by build-iso.sh
#
# Embedded into the installer ISO via `prepare-iso --on-first-boot` and run
# once, after installation, by the PVE `proxmox-first-boot` package. It is the
# schema-supported replacement for the `[late-commands]` section that older
# versions of this answer file carried (PVE's autoinstall schema has no such
# section — only global, network, disk-setup, post-installation-webhook and
# first-boot).
#
# Responsibilities, in order:
#   1. Persist the personalization password hash to
#      /root/.personalization-password-hash for frag/30, which injects it into
#      the guest NoCloud seeds.
#   2. Create the personalization account on the host and grant it the sudo
#      group. PVE's autoinstall schema has no non-root user field (only
#      root-password / root-password-hashed in [global]), so this is the only
#      place it can be created.
#   3. Fetch the provision/ tree at the pinned REF.
#   4. Install the pve-firstboot.service oneshot unit, then run the provisioner.
#
# This script is deliberately thin: it creates an account and gets out of the
# way. Everything else — package management, repository repair, the sudo
# package, GPU configuration, guest creation — lives in provision/host/frag/,
# which arrives in step 3 and can be corrected by pushing a commit, rather than
# by editing a script baked into an ISO that has to be rebuilt and re-burned to
# reach a host that is already installed.
#
# It carries no package-manager calls for the same reason. It used to install
# sudo itself, along with an inline copy of the PVE no-subscription repository
# repair, which on a host without a subscription meant apt failing here — before
# the tree was fetched, so frag/05 could not run — and the same repair duplicated
# in two files. frag/05 and frag/06 now do both, once.
#
# SECURITY: this rendered file contains the personalization password hash in
# plaintext and is therefore as sensitive as keys/personalization-password-hash
# itself. It is written to output/build-work/ (gitignored) and embedded in the
# ISO. It is never pushed to GitHub — the hash reaches the booted host through
# the installer media only. The *root* password hash is not in this file at all:
# it travels separately, in the answer file's `root-password-hashed`.
#
# REF: __GITHUB_REF__ (baked at build time)

set -eu

REF="__GITHUB_REF__"
REPO="popiel/nested_dev"
# Filesystem root for everything this bootstrap writes. Empty on a real host.
# The end-to-end test points it at a scratch tree and asserts the resulting
# account, keys and fetched tree instead of the script's text.
ROOT="${PVE_ROOT:-}"
PROVISION_DIR="${ROOT}/root/provision"
HASH_FILE="${ROOT}/root/.personalization-password-hash"
UNIT="${ROOT}/etc/systemd/system/pve-firstboot.service"
WANTS_DIR="${ROOT}/etc/systemd/system/multi-user.target.wants"
LOG="${ROOT}/var/log/pve-firstboot-bootstrap.log"

# Personalization identity (§05), substituted at build time. Deliberately
# rendered rather than read from provision/personalization.sh, which does not
# exist yet at this point: the account has to exist even if the GitHub fetch
# below fails.
USER_NAME="__PERSONALIZATION_USERNAME__"
USER_FULLNAME="__PERSONALIZATION_FULLNAME__"
USER_UID="__PERSONALIZATION_UID__"
USER_GID="__PERSONALIZATION_GID__"
USER_HOME="__PERSONALIZATION_HOME__"
USER_SHELL="/bin/bash"
# The build machine's operator key, the same one the answer file trusts for
# root, so the account is reachable without typing a password.
ADMIN_PUBKEY="__ADMIN_PUBKEY__"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

# --- 1. Persist the personalization password hash ---------------------
# The hash is substituted here at build time. frag/30 reads this file and
# substitutes it for the CHANGE_ME_HASHED placeholder in each guest's
# user-data, so it is the same login password the host account below is given.
log "persisting personalization password hash"
umask 077
printf '%s' '__PERSONALIZATION_PASSWORD_HASH__' > "$HASH_FILE"
chmod 600 "$HASH_FILE"

# --- 2. Create the personalization account ----------------------------
# PVE's answer schema cannot create a non-root user, and the installer's
# root-only credential is the wrong thing to hand an operator, so the account
# is built here. Idempotent: a re-run reconciles the account in place.
#
# The reconcile path rewrites the passwd/group entries but does not move an
# existing home directory between paths (usermod -m refuses when the target is
# a non-empty directory). The chown -R below re-owns whatever is at USER_HOME,
# so a UID change leaves no orphaned files; a *path* change on a pre-existing
# account would leave the old contents behind, which only happens when
# PERSONALIZATION_HOME is edited after an install.
log "creating personalization account ${USER_NAME}"
if getent group "$USER_GID" >/dev/null 2>&1; then
    if [ "$(getent group "$USER_GID" | cut -d: -f1)" != "$USER_NAME" ]; then
        die "GID ${USER_GID} is already held by '$(getent group "$USER_GID" | cut -d: -f1)', expected the ${USER_NAME} group"
    fi
elif getent group "$USER_NAME" >/dev/null 2>&1; then
    groupmod -g "$USER_GID" "$USER_NAME"
else
    groupadd -g "$USER_GID" "$USER_NAME"
fi
if getent passwd "$USER_NAME" >/dev/null 2>&1; then
    log "account exists — reconciling identity attributes"
    usermod -u "$USER_UID" -g "$USER_GID" -d "$USER_HOME" -s "$USER_SHELL" \
        -c "$USER_FULLNAME" "$USER_NAME"
else
    if getent passwd "$USER_UID" >/dev/null 2>&1; then
        die "UID ${USER_UID} is already held by '$(getent passwd "$USER_UID" | cut -d: -f1)'; refusing to create a second identity"
    fi
    useradd -u "$USER_UID" -g "$USER_GID" -d "$USER_HOME" -s "$USER_SHELL" \
        -c "$USER_FULLNAME" "$USER_NAME"
    log "account created (uid=${USER_UID} gid=${USER_GID} home=${USER_HOME})"
fi
# Apply the hash verbatim: chpasswd -e takes an already-encrypted password, so
# the same yescrypt string the guests receive is what the host account gets.
printf '%s:%s\n' "$USER_NAME" '__PERSONALIZATION_PASSWORD_HASH__' | chpasswd -e

# --- 2b. Grant the sudo group --------------------------------------------
# `usermod -aG sudo` needs the group to exist, and it does not come from this
# script — but creating a group needs only `groupadd` from the always-present
# shadow-utils, not a working package manager.
#
# The `sudo` *package* is deliberately not installed here. It used to be, along
# with an inline repair for the PVE enterprise repository, which on a host
# without a subscription meant apt-get update failing here — before the provision
# tree was fetched, so frag/05 could not run and repair it. That put roughly
# forty lines of repository logic in this file, duplicated against
# frag/05-apt-repos.sh, where the two copies could disagree and the symptom would
# be a 401 that appeared to come back on its own.
#
# The package is installed by frag/06-sudo.sh instead, in the tree, once. The
# ordering this is careful about is not weakened by the move: the operator
# account, its password and its SSH key are all in place before the fetch is
# attempted, and the answer file independently installs that same operator key
# on root — so root is the *easiest* login on a box where the fetch failed, not
# an inaccessible last resort. There is no window in which the operator is
# locked out.
getent group sudo >/dev/null 2>&1 || groupadd -r sudo

# Administrative access on the host, and password-less SSH with the operator key.
usermod -aG sudo "$USER_NAME"
# The home directory as a filesystem location, as opposed to USER_HOME, which
# is the account attribute handed to useradd/usermod and must stay unprefixed
# even under PVE_ROOT.
USER_HOME_DIR="${ROOT}${USER_HOME}"
mkdir -p "${USER_HOME_DIR}/.ssh"
chmod 700 "${USER_HOME_DIR}/.ssh"
printf '%s\n' "$ADMIN_PUBKEY" > "${USER_HOME_DIR}/.ssh/authorized_keys"
chmod 600 "${USER_HOME_DIR}/.ssh/authorized_keys"
chown -R "${USER_NAME}:${USER_NAME}" "$USER_HOME_DIR"
log "personalization account ready: password set, sudo group, operator key installed"

# --- 3. Fetch the provision/ tree at the pinned REF -------------------
log "fetching provisioner tree at ${REF}"
mkdir -p "$PROVISION_DIR"
TMP="${ROOT}/root/.nested_dev.tar.gz"
if ! wget -qO "$TMP" "https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REF}"; then
    rm -f "$TMP"
    die "failed to fetch provisioner tree for ${REPO}@${REF}"
fi
tar -xzf "$TMP" -C "${ROOT}/root"
rm -f "$TMP"
[ -d "${ROOT}/root/nested_dev-${REF}/provision" ] || die "archive did not contain provision/"

rm -rf "${PROVISION_DIR:?}.old"
[ -d "$PROVISION_DIR" ] && mv "$PROVISION_DIR" "${PROVISION_DIR}.old"
mv "${ROOT}/root/nested_dev-${REF}/provision" "$PROVISION_DIR"

# frag/30 injects the build machine's admin public key into every guest seed,
# but keys/ is not part of the provision tree. Preserve the pubkey out of the
# tarball into the tree that was just put in place. This must happen after the
# swap above, not before: preserving it into the old directory and then moving
# that directory to .old loses the key, and frag/30 aborts on the missing file
# after everything else already succeeded.
#
# Read from the archive rather than from the host's /root/.ssh/authorized_keys
# so that a key added to the host by hand does not silently propagate to every
# guest.
ADMIN_PUBKEY_SRC="${ROOT}/root/nested_dev-${REF}/keys/host_os_ed25519.pub"
[ -f "$ADMIN_PUBKEY_SRC" ] || die "archive did not contain keys/host_os_ed25519.pub"
mkdir -p "${PROVISION_DIR}/keys"
cp "$ADMIN_PUBKEY_SRC" "${PROVISION_DIR}/keys/host_os_ed25519.pub"
chmod 644 "${PROVISION_DIR}/keys/host_os_ed25519.pub"
log "admin public key preserved at ${PROVISION_DIR}/keys/host_os_ed25519.pub"

rm -rf "${ROOT}/root/nested_dev-${REF}"
chmod +x "${PROVISION_DIR}/host/provision-host.sh"
chmod +x "${PROVISION_DIR}/host"/frag/*.sh 2>/dev/null || true

# --- 4. Install the pve-firstboot unit --------------------------------
# NOTE: ExecStart is the path as the booted host sees it, never ${ROOT}-prefixed.
# The unit file runs on the host; the PVE_ROOT prefix is a test-harness
# redirection for where files land, not for what they contain.
log "installing pve-firstboot.service"
mkdir -p "$(dirname "$UNIT")"
cat > "$UNIT" <<UNIT
[Unit]
Description=PVE first boot provisioning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/provision/host/provision-host.sh

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$WANTS_DIR"
ln -sf "$UNIT" "${WANTS_DIR}/pve-firstboot.service"
systemctl daemon-reload
systemctl enable pve-firstboot.service >/dev/null 2>&1 || true

# --- Run the provisioner now ------------------------------------------
# This hook executes during the first boot, so merely enabling the unit would
# defer provisioning to the *second* boot. Install the unit (it stays available
# for manual re-runs and for `systemctl status` diagnostics) but drive the
# provisioner directly. Fragments are idempotent, so a later re-run is safe.
log "running provisioner"
if ! /bin/sh "${PROVISION_DIR}/host/provision-host.sh"; then
    die "provisioner failed — see ${ROOT}/var/log/pve-firstboot.log"
fi

log "=== first-boot bootstrap complete ==="
