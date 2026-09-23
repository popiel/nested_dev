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
PERSONALIZATION_UID="1000"
PERSONALIZATION_GID="1000"
PERSONALIZATION_HOME="/home/${PERSONALIZATION_USERNAME}"
