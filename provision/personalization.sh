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
