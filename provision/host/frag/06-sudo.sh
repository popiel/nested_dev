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
    # No `apt-get update` here: frag/05 has just run it, and a second one would
    # re-fetch every index for no reason.
    apt-get install -y sudo \
        || die "failed to install sudo; the operator account would have no administrative access on the host"

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
