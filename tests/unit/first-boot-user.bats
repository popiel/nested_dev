#!/usr/bin/env bats
# tests/unit/first-boot-user.bats — the personalization account on the PVE host
#
# The host was installed with only a root account: PVE's autoinstall schema has
# no non-root user field, so the operator's account has to be created by the
# first-boot bootstrap. Nothing in the repo created it, and nothing tested the
# credential split that made it necessary:
#
#   D4  host root and the personalization account shared one hash, read from
#       keys/password-hash and fed to BOTH answer-host.toml's
#       root-password-hashed and the first-boot bootstrap. A leak of the
#       personalization login to the host's most privileged account was
#       therefore structural, not accidental.
#   D5  /root/.password-hash was named after root but held the login hash that
#       frag/30 injected into the guest seeds. After the split the filename
#       would have described a credential that no longer passes through it.
#   D6  the account, once created, had no sudo membership and no authorized_keys,
#       so the only way in was the keyboard of a headless host.
#
# These are structural assertions: the block lives at the top level of a
# `#!/bin/sh` script that PVE executes directly, so it is not sourceable
# without running the whole bootstrap. The rendering of the values it consumes
# is covered behaviourally in tests/unit/build-iso.bats.

load '../lib/helpers'

FIRSTBOOT="${PROJECT_ROOT}/provision/host/first-boot.sh"
FRAG30="${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh"
ANSWER="${PROJECT_ROOT}/provision/host/answer-host.toml"
BUILDISO="${PROJECT_ROOT}/provision/host/build-iso.sh"
NESTED="${PROJECT_ROOT}/dev/tools/nested"

# --- D4: two distinct credentials, never interchanged ---

@test "D4: build-iso reads each hash from its own file" {
    # The root hash goes to the installer, the login hash to the host operator
    # account. One shared source file made a leak of the second to the first
    # structural rather than accidental.
    assert_file_contains "$BUILDISO" 'ROOT_PASSWORD_HASH_FILE="${REPO_ROOT}/keys/root-password-hash"'
    assert_file_contains "$BUILDISO" \
        'PERSONALIZATION_PASSWORD_HASH_FILE="${REPO_ROOT}/keys/personalization-password-hash"'
}

@test "D4: each hash file missing produces a distinct build error" {
    # One shared "Missing: keys/*-hash" message would let an operator satisfy
    # one die by creating the other, and the build would still be one hash short.
    assert_file_contains "$BUILDISO" "Missing: \${ROOT_PASSWORD_HASH_FILE}"
    assert_file_contains "$BUILDISO" "Missing: \${PERSONALIZATION_PASSWORD_HASH_FILE}"
}

# That each carrier receives the *right* hash is asserted behaviourally on the
# rendered output in tests/unit/build-iso.bats ("root hash reaches the answer
# file, login hash reaches the bootstrap"), which is stronger than matching the
# placeholder names here.

@test "D4: the host account is given the login hash, never the root hash" {
    # chpasswd -e takes the already-encrypted password, so this is the exact
    # yescrypt string the guests receive — no hashing, no plaintext on disk.
    # Literal: the needle contains \n and $USER_NAME, which a regex would read
    # as an anchor and a character class.
    assert_file_contains "$FIRSTBOOT" \
        "printf '%s:%s\n' \"\$USER_NAME\" '__PERSONALIZATION_PASSWORD_HASH__' | chpasswd -e"
}

@test "D4: the bootstrap never creates or re-credentials root" {
    # Root's credential belongs to the installer alone. A usermod/chpasswd
    # against root here would be the third writer of the root password.
    # Regex, not literal: the rule is "chpasswd -e anywhere on a line that
    # also mentions root", which no fixed substring can express.
    assert_file_not_matches "$FIRSTBOOT" 'useradd .*root'
    assert_file_not_matches "$FIRSTBOOT" 'chpasswd -e.*root'
    assert_file_not_contains "$FIRSTBOOT" 'passwd root'
}

# --- Account creation (the schema cannot do it) ---

@test "the bootstrap creates the account with the configured UID, GID, home and shell" {
    assert_file_contains "$FIRSTBOOT" 'USER_UID="__PERSONALIZATION_UID__"'
    assert_file_contains "$FIRSTBOOT" 'USER_GID="__PERSONALIZATION_GID__"'
    assert_file_contains "$FIRSTBOOT" 'USER_HOME="__PERSONALIZATION_HOME__"'
    assert_file_contains "$FIRSTBOOT" 'USER_NAME="__PERSONALIZATION_USERNAME__"'
    assert_file_contains "$FIRSTBOOT" 'USER_SHELL="/bin/bash"'
    assert_file_contains "$FIRSTBOOT" 'groupadd -g "$USER_GID" "$USER_NAME"'
    assert_file_contains "$FIRSTBOOT" \
        'useradd -u "$USER_UID" -g "$USER_GID" -d "$USER_HOME" -s "$USER_SHELL"'
}

@test "the account carries the real name, not the username" {
    # Without -c the GECOS field is empty and `ls` / `finger` / some GUIs show
    # a bare login name for the human-facing account of the whole deployment.
    assert_file_contains "$FIRSTBOOT" '-c "$USER_FULLNAME"'
}

@test "account creation is idempotent and refuses to shadow an existing UID" {
    assert_file_contains "$FIRSTBOOT" 'if getent passwd "$USER_NAME" >/dev/null 2>&1; then'
    assert_file_contains "$FIRSTBOOT" 'usermod -u "$USER_UID" -g "$USER_GID"'
    # A UID held by a different login means /etc/passwd would gain a second
    # identity for one operator: refuse rather than create it.
    assert_file_contains "$FIRSTBOOT" 'UID ${USER_UID} is already held by'
    assert_file_contains "$FIRSTBOOT" 'GID ${USER_GID} is already held by'
}

@test "the account gets sudo membership and the operator SSH key" {
    assert_file_contains "$FIRSTBOOT" 'usermod -aG sudo "$USER_NAME"'
    assert_file_contains "$FIRSTBOOT" 'ADMIN_PUBKEY="__ADMIN_PUBKEY__"'
    assert_file_contains "$FIRSTBOOT" \
        'printf '"'"'%s\n'"'"' "$ADMIN_PUBKEY" > "${USER_HOME}/.ssh/authorized_keys"'
}

@test "the account's .ssh is created with restrictive modes and correct ownership" {
    assert_file_contains "$FIRSTBOOT" 'chmod 700 "${USER_HOME}/.ssh"'
    assert_file_contains "$FIRSTBOOT" 'chmod 600 "${USER_HOME}/.ssh/authorized_keys"'
    assert_file_contains "$FIRSTBOOT" 'chown -R "${USER_NAME}:${USER_NAME}" "$USER_HOME"'
}

@test "the account is created before the provision tree is fetched" {
    # provision/personalization.sh arrives with the tarball, so the account must
    # not depend on it — and a failed fetch must still leave a usable host.
    local create fetch
    create=$(grep -n 'creating personalization account' "$FIRSTBOOT" | head -1 | cut -d: -f1)
    fetch=$(grep -n 'fetching provisioner tree' "$FIRSTBOOT" | head -1 | cut -d: -f1)
    [ -n "$create" ]
    [ -n "$fetch" ]
    [ "$create" -lt "$fetch" ]
}

# --- D5: the host-side hash file names the credential it holds ---

@test "D5: the persisted login hash is named for the login, not for root" {
    assert_file_contains "$FIRSTBOOT" 'HASH_FILE="/root/.personalization-password-hash"'
    assert_file_not_contains "$FIRSTBOOT" '/root/.password-hash'
}

@test "D5: frag/30 reads the same renamed path" {
    # A mismatch here does not fail the build: it fails on the host, at first
    # boot, with the seed ISOs already half-written.
    assert_file_contains "$FRAG30" 'PERSONALIZATION_HASH_FILE="/root/.personalization-password-hash"'
    assert_file_contains "$FRAG30" 'die "Personalization password hash not found: ${PERSONALIZATION_HASH_FILE}"'
    assert_file_not_contains "$FRAG30" '/root/.password-hash'
}

@test "D5: the persisted hash is not world-readable" {
    assert_file_contains "$FIRSTBOOT" 'chmod 600 "$HASH_FILE"'
}

# --- Guests: root must have no password ---

@test "every guest seed locks root and does nothing else to it" {
    # subiquity already leaves root locked, but nothing said so. Relying on that
    # default means a future identity block change could add a root credential
    # with nothing in the repo noticing.
    #
    # Asserted on the executed commands only, not on prose: the comment above the
    # lock mentions keys/root-password-hash by name. Any other curtin line
    # touching root would be a second writer of the guest root credential.
    local guest unexpected
    for guest in desktop llm dev; do
        assert_file_contains "${PROJECT_ROOT}/${guest}/user-data/user-data" \
            'passwd -l root'
        run grep -E 'curtin.*root' "${PROJECT_ROOT}/${guest}/user-data/user-data"
        unexpected=$(printf '%s\n' "$output" | grep -v 'passwd -l root' || true)
        if [ -n "$unexpected" ]; then
            echo "${guest} user-data touches root beyond locking it:" >&2
            echo "$unexpected" >&2
            return 1
        fi
    done
}

# --- The dev-VM build path carries both secrets ---

@test "dev/tools/nested keys-status checks both password hashes" {
    # The dev VM builds the host ISO, so a single-hash check would report ready
    # and then fail inside build-iso.sh for the other one.
    assert_file_contains "$NESTED" 'personalization-password-hash root-password-hash'
    assert_file_not_contains "$NESTED" 'secrets/password-hash'
}
