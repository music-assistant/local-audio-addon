#!/usr/bin/env bash
#
# Unit checks for scripts/compose_pinned.sh.
#
# The asset it prints is generated on a tag and downloaded by people who are not watching CI, so
# a wrong one is quiet twice over: it is valid YAML that `docker compose up` accepts, and the
# only symptom is a user compiling the player from source instead of pulling the image the
# release published. These run on every pull request, against the real docker-compose.yml, so
# that a change to that file which leaves nothing to substitute is caught by the pull request
# making it rather than by the next release.
#
# Needs: bash, diff, grep, cut and mktemp.
#
# Usage: scripts/compose_pinned_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR
readonly PIN="$SCRIPT_DIR/compose_pinned.sh"
readonly REAL_COMPOSE="$SCRIPT_DIR/../docker-compose.yml"
readonly IMAGE=ghcr.io/music-assistant/local-audio-addon:0.1.8

FAILURES=0
SCRATCH_ROOT=""

pass() {
    printf '  ok   %s\n' "$1"
}

fail() {
    printf '  FAIL %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

step() {
    printf '\n%s\n' "$1"
}

assert_equal() {
    local want=$1 got=$2 what=$3
    if [ "$want" = "$got" ]; then
        pass "$what"
    else
        fail "$what"
        printf '    want: %q\n    got:  %q\n' "$want" "$got" >&2
    fi
}

pinned_of() {
    local out=''
    if ! out="$("$PIN" --image "$IMAGE" --compose "$1" 2>/dev/null)"; then
        printf 'error'
        return
    fi
    printf '%s' "$out"
}

assert_refuses() {
    local want=$1 what=$2
    shift 2
    local status=0
    "$PIN" "$@" >/dev/null 2>&1 || status=$?
    assert_equal "$want" "$status" "$what"
}

check_the_shipped_compose_file() {
    step 'the compose file as it stands'

    local pinned
    pinned="$(pinned_of "$REAL_COMPOSE")"
    if [ "$pinned" = error ]; then
        fail 'the repository docker-compose.yml pins -- the rest of this section cannot run'
        return
    fi
    pass 'the repository docker-compose.yml pins'

    # The indentation the replaced key sat at, put back. A flush-left `image:` would be a key on
    # the services mapping rather than on this service, and the file would not load at all.
    assert_equal "    image: $IMAGE" \
        "$(printf '%s\n' "$pinned" | grep -n 'image:' | cut -d: -f2- | head -1)" \
        'the image key lands at the depth the build key sat at'

    # One line changed and no other, which is the whole claim this script makes about the rest
    # of the file: the host network namespace, /dev/snd, the commented Host-Avahi bind mount and
    # every line of prose in the SENDSPIN_* block survive because nothing touched them. diff
    # prints one `<` and one `>` for a single replaced line.
    local changed
    changed="$(diff "$REAL_COMPOSE" <(printf '%s\n' "$pinned") | grep -c '^[<>]' || true)"
    assert_equal 2 "$changed" 'exactly one line differs from the file in the repository'

    assert_equal '    build: .' \
        "$(diff "$REAL_COMPOSE" <(printf '%s\n' "$pinned") | sed -n 's/^< //p')" \
        'the line that differs is the build line'

    # Named rather than left to the line count above, because these are the lines a Docker user
    # actually needs and the ones a careless rewrite would drop.
    local line
    for line in 'network_mode: host' '- /dev/snd:/dev/snd' \
        '# - /var/run/dbus:/var/run/dbus:ro' 'SENDSPIN_OUTPUT: default' \
        '# SENDSPIN_SERVER: 192.168.1.10:8927'; do
        if printf '%s\n' "$pinned" | grep -qF -- "$line"; then
            pass "the asset still carries '$line'"
        else
            fail "the asset still carries '$line'"
        fi
    done
}

check_it_refuses_a_file_it_cannot_pin() {
    step 'compose files with nothing to substitute'

    # The drift this script exists to catch on the pull request rather than on the tag: turning
    # `build: .` into a block to add a `dockerfile:` or `args:` is an entirely reasonable change,
    # and it leaves the release with nothing to replace.
    local block="$SCRATCH_ROOT/block-build.yml"
    cat >"$block" <<'COMPOSE'
services:
  local-audio:
    build:
      context: .
    container_name: ma-local-audio
COMPOSE
    assert_refuses 1 'a block-form build: is refused rather than passed through' \
        --image "$IMAGE" --compose "$block"

    local none="$SCRATCH_ROOT/no-build.yml"
    cat >"$none" <<'COMPOSE'
services:
  local-audio:
    image: ghcr.io/music-assistant/local-audio-addon:latest
    container_name: ma-local-audio
COMPOSE
    assert_refuses 1 'a file with no build: at all is refused' \
        --image "$IMAGE" --compose "$none"

    # Two would make the substitution a choice between them, and a file that pinned one service
    # and went on compiling the other is the failure this counts to prevent.
    local two="$SCRATCH_ROOT/two-builds.yml"
    cat >"$two" <<'COMPOSE'
services:
  local-audio:
    build: .
  sidecar:
    build: .
COMPOSE
    assert_refuses 1 'two build: lines are refused rather than half-replaced' \
        --image "$IMAGE" --compose "$two"

    # A second service built from source alongside the one that pins: the count above is
    # satisfied, and the read-back is what catches it.
    local mixed="$SCRATCH_ROOT/mixed.yml"
    cat >"$mixed" <<'COMPOSE'
services:
  local-audio:
    build: .
  sidecar:
    build:
      context: ./sidecar
COMPOSE
    assert_refuses 1 'a surviving build: key elsewhere is refused' \
        --image "$IMAGE" --compose "$mixed"

    assert_refuses 1 'a compose file that does not exist is refused' \
        --image "$IMAGE" --compose "$SCRATCH_ROOT/nowhere.yml"
}

check_the_image_it_is_asked_to_pin_to() {
    step 'the image ref'

    assert_refuses 1 'an untagged ref is refused -- it would resolve to latest and pin nothing' \
        --image ghcr.io/music-assistant/local-audio-addon --compose "$REAL_COMPOSE"

    # `&` is the whole match in a sed replacement and `|` is the delimiter, so either would be
    # read as syntax rather than as part of a name.
    assert_refuses 1 'a ref carrying an ampersand is refused' \
        --image 'ghcr.io/x/y:0.1.8&' --compose "$REAL_COMPOSE"
    assert_refuses 1 'a ref carrying the substitution delimiter is refused' \
        --image 'ghcr.io/x/y:0.1.8|z' --compose "$REAL_COMPOSE"

    # release.yml derives the repository from `github.repository`, so a fork under an owner whose
    # name carries capitals reaches here with one. The registry takes lower case only, and being
    # told so beats attaching a compose file naming an image that cannot be pulled.
    assert_refuses 1 'an owner with capitals in it is refused, as the registry would refuse it' \
        --image ghcr.io/Music-Assistant/local-audio-addon:0.1.8 --compose "$REAL_COMPOSE"

    assert_refuses 2 'a missing --image is a usage error' --compose "$REAL_COMPOSE"
    assert_refuses 2 'a flag left without its value is a usage error' --image
    assert_refuses 2 'an unknown flag is a usage error' \
        --image "$IMAGE" --output /dev/null
}

main() {
    printf 'pinned compose: checking %s\n' "$PIN"

    [ -x "$PIN" ] || {
        printf 'pinned compose: %s is not executable\n' "$PIN" >&2
        exit 1
    }

    SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/compose-pinned-test.XXXXXX")"
    # shellcheck disable=SC2064  # the path is wanted as it is now, not at trap time.
    trap "rm -rf -- '$SCRATCH_ROOT'" EXIT

    check_the_shipped_compose_file
    check_it_refuses_a_file_it_cannot_pin
    check_the_image_it_is_asked_to_pin_to

    if [ "$FAILURES" -ne 0 ]; then
        printf '\npinned compose: %d check(s) failed\n' "$FAILURES" >&2
        exit 1
    fi
    printf '\npinned compose: every check passed\n'
}

main
