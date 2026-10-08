#!/usr/bin/env bats
# tests/static/guest-seeds.bats — the live guest templates, as content.
#
# The end-to-end suite feeds frag/30 canned templates over the stubbed network,
# so it cannot see these files. What it proves instead is that every
# substitution expression works and no placeholder survives. What is pinned
# here is the other half of that contract: the live templates draw only on the
# placeholder vocabulary the substitution covers. A template that introduces a
# placeholder frag/30 does not know would pass the e2e (whose canned templates
# would not have it) and then fail on the host after the seeds are half-written.
#
# Nothing here pins provisioning order or fragment source text — only what the
# guests will contain.

load '../lib/helpers'

# Every placeholder frag/30 substitutes, one per line, sorted.
EXPECTED_VOCABULARY="CHANGE_ME_HASHED
__ADMIN_PUBKEY__
__GITHUB_REF__
__GUEST_ID_PRIV_B64__
__GUEST_ID_PUBKEY__
__PERSONALIZATION_FULLNAME__
__PERSONALIZATION_GID__
__PERSONALIZATION_UID__
__PERSONALIZATION_USERNAME__
__VMCTL_PRIV_B64__"

@test "guest templates draw only on the substituted placeholder vocabulary" {
    # Subset, not equality: the substitution covers two private-half
    # placeholders the live templates currently do not use, and using one must
    # stay legal. What must fail is the reverse — a template carrying a
    # placeholder the substitution does not know, which would survive into the
    # seed and fail the guest at boot.
    for guest in desktop llm dev; do
        local template="${PROJECT_ROOT}/${guest}/user-data/user-data"
        [ -f "$template" ] || { echo "missing template for $guest" >&2; return 1; }
        local actual unexpected
        actual="$(grep -oh '__[A-Z_]*__\|CHANGE_ME_HASHED' "$template" | sort -u)"
        unexpected="$(comm -23 <(printf '%s\n' "$actual") \
            <(printf '%s\n' "$EXPECTED_VOCABULARY"))"
        [ -z "$unexpected" ] || {
            echo "$guest template uses placeholders frag/30 does not substitute:" >&2
            echo "$unexpected" >&2
            echo >&2
            echo "Teach frag/30 the new placeholder and extend the e2e canned" >&2
            echo "templates, or remove it from the template." >&2
            return 1
        }
    done
}

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

@test "every guest user-data declares ssh_authorized_keys with both keys" {
    # allow-pw: false means ssh_authorized_keys is not optional — without it a
    # guest has no working SSH authentication method at all.
    local label file
    for label in desktop llm dev; do
        file="${PROJECT_ROOT}/${label}/user-data/user-data"
        assert_file_contains "$file" 'ssh_authorized_keys:'
        assert_file_contains "$file" '- "__ADMIN_PUBKEY__"'
        assert_file_contains "$file" '- "__GUEST_ID_PUBKEY__"'
        assert_file_contains "$file" 'allow-pw: false'
    done
}

assert_key_write_creates_ssh_dir_first() {
    # $1 = user-data file, $2 = key filename. Everything before the first '>'
    # is the setup that must run before the redirect into ~/.ssh.
    local file="$1" key="$2" cmd head
    cmd=$(grep -o "sh -c '[^']*${key}[^']*'" "$file" || true)
    if [ -z "$cmd" ]; then
        echo "no late-command writing ${key} found in ${file}" >&2
        return 1
    fi
    head="${cmd%%'>'*}"
    case "$head" in
        *"mkdir -p /home/__PERSONALIZATION_USERNAME__/.ssh"*)
            return 0
            ;;
        *)
            echo "mkdir -p ~/.ssh must precede the redirect into it." >&2
            echo "  before redirect: ${head}" >&2
            return 1
            ;;
    esac
}

@test "desktop user-data creates ~/.ssh before writing the vmctl key" {
    assert_key_write_creates_ssh_dir_first \
        "${PROJECT_ROOT}/desktop/user-data/user-data" "pvehost_vmctl"
}

@test "desktop user-data creates ~/.ssh before writing the guest identity key" {
    assert_key_write_creates_ssh_dir_first \
        "${PROJECT_ROOT}/desktop/user-data/user-data" "nested-dev-id"
}

@test "desktop user-data no longer suppresses key-write errors" {
    # 2>/dev/null on the redirect is what let a failed key write go unnoticed.
    assert_file_not_contains "${PROJECT_ROOT}/desktop/user-data/user-data" \
        'pvehost_vmctl 2>/dev/null'
    assert_file_not_contains "${PROJECT_ROOT}/desktop/user-data/user-data" \
        'nested-dev-id 2>/dev/null'
}

@test "desktop user-data chmods the key files to 600" {
    assert_file_contains "${PROJECT_ROOT}/desktop/user-data/user-data" \
        'chmod 600 /home/__PERSONALIZATION_USERNAME__/.ssh/pvehost_vmctl'
    assert_file_contains "${PROJECT_ROOT}/desktop/user-data/user-data" \
        'chmod 600 /home/__PERSONALIZATION_USERNAME__/.ssh/nested-dev-id'
}

@test "the dev seed fetches both dev/tools scripts into the tools directory" {
    assert_file_contains "${PROJECT_ROOT}/dev/user-data/user-data" \
        'dev/tools/nested -O nested'
    assert_file_contains "${PROJECT_ROOT}/dev/user-data/user-data" \
        'dev/tools/dev-refresh-images -O dev-refresh-images'
    assert_file_contains "${PROJECT_ROOT}/dev/user-data/user-data" \
        'mkdir -p /opt/nested-dev/tools'
}

@test "the tools are fetched at the same reference as the first-boot script" {
    # One reference for the whole guest. Two references means the script that
    # installs the wrappers and the wrappers themselves can come from different
    # commits, invisibly.
    local fetches
    fetches="$(grep -oE 'raw\.githubusercontent\.com/[^/]+/[^/]+/[^/]+' \
        "${PROJECT_ROOT}/dev/user-data/user-data" | sort -u)"
    [ -n "$fetches" ]
    local count
    count="$(printf '%s\n' "$fetches" | wc -l | tr -d ' ')"
    [ "$count" -eq 1 ] || {
        echo "dev seed fetches from $count different references:" >&2
        printf '%s\n' "$fetches" >&2
        return 1
    }
}

@test "the guest pins its own PERSONALIZATION_REF to the reference it was built from" {
    # personalization.sh still carries the branch name. A guest that fetched
    # its Dockerfiles and tools with ${PERSONALIZATION_REF:-main} would resolve
    # against a moving branch, so the template's images could come from a newer
    # commit than the script that installed them.
    assert_file_contains "${PROJECT_ROOT}/dev/user-data/user-data" \
        's/^PERSONALIZATION_REF=.*/PERSONALIZATION_REF=__GITHUB_REF__/'
}

@test "install-time package lists carry no build tools nothing at install time consumes" {
    # fakeroot sat in the dev seed's packages list and failed curtin
    # system-install twice: install-time requests resolve against the
    # installer's minimal sources, while first-boot runs against the full
    # ones. A package nothing at install time needs must be installed by the
    # first-boot script, not requested from the installer.
    #
    # Asserted as the concrete relocation, not a component map the repo cannot
    # maintain: no seed requests fakeroot, and dev-firstboot installs it.
    local guest
    for guest in desktop llm dev; do
        if grep -q '^[[:space:]]*-[[:space:]]*fakeroot[[:space:]]*$' \
            "${PROJECT_ROOT}/${guest}/user-data/user-data"; then
            echo "$guest seed requests fakeroot at install time" >&2
            return 1
        fi
    done
    assert_file_contains "${PROJECT_ROOT}/dev/dev-firstboot.sh" \
        'fakeroot'
}

@test "llm first-boot evicts nouveau before the NVIDIA driver" {
    # The proprietary driver refuses to bind while nouveau holds the card
    # (NVRM: already bound), so without this the bake completes driver-blind
    # on passthrough hardware. Same pinning style as the test above.
    assert_file_contains "${PROJECT_ROOT}/llm/llm-firstboot.sh" \
        'blacklist nouveau'
}

@test "llm network fetches retry instead of dying on blips" {
    # Two bare curl|gpg pipes under set -euo pipefail died the whole bake on
    # one transient CDN answer (gpg exit 2 on an error page, curl SIGPIPEd).
    # wget retries by default; these curls must too — both of them.
    run grep -c "retry-all-errors" "${PROJECT_ROOT}/llm/llm-firstboot.sh"
    [ "$output" = "2" ]
}

@test "gpg dearmor never needs a terminal" {
    # gpg opens /dev/tty for potential prompts; under systemd (or docker
    # build) there is none, so every run dies deterministically — not
    # transiently. Both dearmor pipes in the tree run batch.
    assert_file_contains "${PROJECT_ROOT}/llm/llm-firstboot.sh" \
        'gpg --batch --yes --dearmor'
    assert_file_contains \
        "${PROJECT_ROOT}/provision/host/Dockerfile.autoinstall-assistant" \
        'gpg --batch --yes --dearmor'
}

@test "all seeds power off at end of install" {
    # With ide2-first boot order a reboot re-enters the installer and
    # reinstalls over the top forever; a parked stopped VM is the completion
    # signal the provisioner waits on. Server Subiquity honors shutdown:
    # poweroff — and so does the desktop seed: its installer is the same
    # Subiquity core, and the wallpaper-sit was the same missing flag, never
    # proof otherwise. The manual-install era was triage, not a finding.
    for guest in desktop llm dev; do
        assert_file_contains "${PROJECT_ROOT}/${guest}/user-data/user-data" \
            'shutdown: poweroff'
    done
}
