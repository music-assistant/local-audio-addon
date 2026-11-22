#!/usr/bin/env bash
#
# Prints the repository's docker-compose.build.yml with `build: .` replaced by the image that was
# published, for attaching to a GitHub Release.
#
# A Docker user who downloads it gets a file that pulls a released image rather than compiling
# the player from source, and gets it with everything the checked-in file already carries: the
# host network namespace, `/dev/snd`, the commented Host-Avahi bind mount and the SENDSPIN_*
# block with its prose. Generated at release time from that one file rather than kept as a second
# copy, so the two cannot drift.
#
# Testable rather than a `sed` inside release.yml, because release.yml runs only on a tag: an
# inline transform is first exercised by a real release, and docker-compose.build.yml is a file that
# ordinary pull requests edit. Turning `build: .` into a block `build:` with a `context:` under
# it is an entirely reasonable change that would leave nothing to substitute, and the pull
# request making it should be the thing that goes red.
#
# Needs: bash, sed and grep.
#
# Usage: scripts/compose_pinned.sh --image REPOSITORY:TAG [--compose PATH]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR

IMAGE=''
COMPOSE="$SCRIPT_DIR/../docker-compose.build.yml"

usage() {
    printf 'usage: %s --image REPOSITORY:TAG [--compose PATH]\n' "$0" >&2
}

die() {
    printf '::error::pinned compose: %s\n' "$1" >&2
    exit 1
}

need_value() {
    [ "$1" -ge 2 ] || {
        usage
        exit 2
    }
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --image)
            need_value "$#"
            IMAGE=$2
            shift 2
            ;;
        --compose)
            need_value "$#"
            COMPOSE=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

[ -n "$IMAGE" ] || {
    usage
    exit 2
}

readonly IMAGE COMPOSE

# The tag is the whole point of the asset: a ref without one resolves to `latest`, which moves
# with every release and so pins nothing. The character set is the registry's own -- lower case
# for the repository, and no `&` or `|`, either of which the substitution below would read as
# syntax rather than as part of a name.
[[ "$IMAGE" =~ ^[a-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] ||
    die "--image $IMAGE is not REPOSITORY:TAG -- an untagged ref pins nothing"

[ -f "$COMPOSE" ] || die "$COMPOSE does not exist -- there is nothing to pin"

# Counted rather than substituted first-match-wins. Nothing downstream would notice a compose
# file that still built from source: it is valid YAML, `docker compose up` works, and the user
# waits half an hour compiling the player instead of pulling the image this release published.
readonly BUILD='^([[:space:]]+)build:[[:space:]]*\.[[:space:]]*$'
matches="$(grep -cE "$BUILD" "$COMPOSE" || true)"
[ "$matches" = 1 ] || die "expected exactly one 'build: .' line in $COMPOSE, found $matches -- the substitution below has nothing to stand in for"

# `|` as the delimiter because the image ref carries slashes. The captured indentation is put
# back, so the key lands at the depth the one it replaces sat at.
pinned="$(sed -E "s|$BUILD|\\1image: $IMAGE|" "$COMPOSE")"

# What was produced, read back rather than assumed from sed having exited 0. Any surviving
# `build:` key -- the one above unreplaced, or a second one in another service -- means the file
# would still compile from source somewhere.
if printf '%s\n' "$pinned" | grep -qE '^[[:space:]]*build:'; then
    die "$COMPOSE still carries a 'build:' key after the substitution -- refusing to attach a compose file that builds from source"
fi

printf '%s\n' "$pinned" | grep -qF "image: $IMAGE" ||
    die "the substitution did not put 'image: $IMAGE' into the output"

printf '%s\n' "$pinned"
