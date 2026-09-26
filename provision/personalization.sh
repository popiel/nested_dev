# provision/personalization.sh — shared user identity variables
# Source this file in all build scripts and first-boot scripts.
# Canonical source: specs/05-personalization.md
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "${SCRIPT_DIR}/../provision/personalization.sh"  # adjust relative path

PERSONALIZATION_USERNAME="popiel"
PERSONALIZATION_FULLNAME="T. Alexander Popiel"
PERSONALIZATION_EMAIL="tapopiel@gmail.com"
PERSONALIZATION_UID="1401"
PERSONALIZATION_GID="1401"
PERSONALIZATION_HOME="/home/${PERSONALIZATION_USERNAME}"

# Repository and release reference (used in build manifests and first-boot comments)
# Set to a branch name, tag, or full commit SHA:
#   "main"              — track tip of main branch (latest changes)
#   "some-tag"          — pinned to a specific tag
#   "abc123def456..."   — pinned to an exact commit SHA (most reproducible)
# build-iso.sh resolves this to a SHA for logging; raw GitHub URLs auto-resolve
# branch names and tags, so no extra work is needed at fetch time.
PERSONALIZATION_REPO="popiel/nested_dev"
PERSONALIZATION_REF="main"

# Target disk for the PVE autoinstall answer file: a single quoted bare kernel
# device name (no /dev/ prefix).
#
#   "nvme0n1"   -> install PVE on the NVMe.
#
# This is a PINNED choice, not an ordered preference. The answer file is built
# on one machine and installed on another, so the target cannot be detected
# here, and PVE's schema rejects more than one disk for ext4/xfs
# ("make sure to define only one disk for ext4 and xfs") — validate-answer
# fails, so there is no fallback list to express a preference with. Multi-disk
# entries are only meaningful for ZFS/RAID, where every listed disk joins one
# pool, which is not the same thing as "prefer the fast disk".
#
# The upside is fail-safe: because the disk is named explicitly and nothing
# else is listed, the installer cannot fall back to and wipe a data/spinning
# disk. If the named disk is absent the install stops.
#
# To install on the SATA SSD instead, change this to "sda" and rebuild.
# Names are hardware-specific - re-check on the target before first boot with
#   proxmox-auto-install-assistant device-info -t disk
PERSONALIZATION_TARGET_DISKS='"nvme0n1"'

# Resolve PERSONALIZATION_REF to a full commit SHA for build manifests.
# Accepts a branch, a tag, or an already-full 40-hex SHA (passed through).
# Prints an empty string when the ref cannot be resolved (offline build, or
# git unavailable) — callers decide whether that is fatal. Never fails, so it
# is safe to call from a `set -e` script.
#
# frag/30-create-guests.sh carries its own copy; the two are interchangeable.
resolve_ref_to_sha() {
    local repo="$1" ref="$2"
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s\n' "$ref"
        return 0
    fi
    command -v git >/dev/null 2>&1 || return 0
    local sha=""
    sha=$(git ls-remote "https://github.com/${repo}.git" "refs/heads/${ref}" 2>/dev/null | awk '{print $1}' || true)
    if [ -z "$sha" ]; then
        sha=$(git ls-remote "https://github.com/${repo}.git" "refs/tags/${ref}" 2>/dev/null | awk '{print $1}' || true)
    fi
    printf '%s\n' "$sha"
}
