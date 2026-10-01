#!/usr/bin/env bash
# frag/06-sudo.sh — ensure the sudo package is present on the host
#
# Runs after frag/05-apt-repos.sh, which is what makes apt usable on a host
# without a PVE subscription. The ordering is the whole reason this is a
# fragment and not part of the first-boot bootstrap: on such a host
# enterprise.proxmox.com answers 401, so an `apt-get install sudo` attempted
# before the repository is repaired fails on the repository and reports nothing
# about sudo.
#
# Two things on the host need the package rather than just the group:
#   - the operator account's administrative access, granted by first-boot.sh via
#     `usermod -aG sudo`
#   - the sudoers drop-in written by frag/25, which lands in /etc/sudoers.d, a
#     directory the package owns
#
# first-boot.sh creates the sudo *group* with groupadd, which needs no package
# manager, so group membership is correct before this runs.

set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
die() { log "FATAL: $*"; exit 1; }

log "=== sudo package setup ==="

if command -v sudo >/dev/null 2>&1; then
    log "sudo already installed"
else
    log "sudo not installed — installing it"
    export DEBIAN_FRONTEND=noninteractive
    # The install is attempted first and the lists refreshed only if it fails:
    # frag/05 has normally just run apt-get update, and re-fetching every index
    # unconditionally would slow every re-provision for no reason. But "frag/05
    # ran" is an ordering fact, not a guarantee — a no-op frag/05 on a host
    # whose lists were never fetched leaves install failing on empty lists, as
    # observed, so the retry heals exactly that case instead of dying on it.
    if ! apt-get install -y sudo; then
        log "install failed — refreshing package lists and retrying once"
        apt-get update -qq \
            || die "apt-get update failed; cannot install sudo"
        apt-get install -y sudo \
            || die "failed to install sudo; the operator account would have no administrative access on the host"
    fi

    # `command -v` succeeding is the only claim that matters. apt can exit 0 with
    # a diverted binary, and a host where sudo is not actually on PATH produces
    # "permission denied" for the operator with nothing in the log to explain it.
    command -v sudo >/dev/null 2>&1 \
        || die "apt-get reported success but sudo is still not on PATH; check for a diversion"
    log "sudo installed: $(command -v sudo)"
fi

# The group is created by first-boot.sh, but a re-provision on a host provisioned
# by an older ISO can reach here without it.
getent group sudo >/dev/null 2>&1 || groupadd -r sudo

log "=== sudo package setup complete ==="
