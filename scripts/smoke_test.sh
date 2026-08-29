#!/usr/bin/env bash
#
# Boot-level checks for a built local-audio image: that it comes up, renders the configuration
# its options asked for, runs its bundled daemons only where they serve a purpose, keeps
# credentials out of what it logs, and fails loudly rather than quietly. The `check_*` functions
# below carry the detail.
#
# The suite runs once per option source, because where the options come from is the riskiest
# logic in the image. `--mode standalone` delivers them as SENDSPIN_* environment variables,
# which is what a Compose user does; `--mode addon` serves them from a stand-in Supervisor over
# the API bashio reads, which is what the add-on does. Every check below is written once and both
# modes deliver to it, so the two paths cannot end up held to different standards.
#
# Needs: docker, and python3 for the two stand-ins it runs on the host -- a Supervisor in add-on
# mode, and a Music Assistant server for the checks that need a stream to have happened. Two
# checks confine a container with the add-on's own AppArmor profile, and need a kernel that
# enforces one plus apparmor_parser and the privilege to load it; without those they say so and
# are skipped, unless --require-apparmor is given, which makes that a failure instead.
#
# Usage: scripts/smoke_test.sh <image-ref> [--mode standalone|addon] [--require-apparmor]

set -euo pipefail

MODE=standalone
IMAGE=''
REQUIRE_APPARMOR=false

usage() {
    printf 'usage: %s <image-ref> [--mode standalone|addon] [--require-apparmor]\n' "$0" >&2
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --mode)
            # A bare trailing --mode must refuse with the usage line: without
            # this, `MODE=$2` trips `set -u` and the script dies on an unbound
            # variable having printed nothing that says what was wrong.
            [ "$#" -ge 2 ] || {
                usage
                exit 2
            }
            MODE=$2
            shift 2
            ;;
        --require-apparmor)
            REQUIRE_APPARMOR=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            IMAGE=$1
            shift
            ;;
    esac
done

if [ -z "$IMAGE" ]; then
    usage
    exit 2
fi

case $MODE in
    standalone | addon) ;;
    *)
        usage
        exit 2
        ;;
esac

readonly MODE IMAGE REQUIRE_APPARMOR

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR
readonly FAKE_SUPERVISOR="$SCRIPT_DIR/fake_supervisor.py"
readonly FAKE_SERVER="$SCRIPT_DIR/fake_server.py"

# The add-on's own AppArmor profile. The name it is loaded under is APPARMOR_SLUG, below.
readonly APPARMOR_SOURCE="$SCRIPT_DIR/../local_audio/apparmor.txt"

# The option values the checks ask for. A space in the name is deliberate: it is the one option
# whose value reaches both the config file and the mDNS advertisement, and quoting it wrongly is
# the mistake that would show up there. `debug` rather than the default, so that the config
# asserted below proves the level was delivered rather than defaulted.
readonly PLAYER_NAME='Smoke Test Player'
readonly PLAYER_LOG_LEVEL=debug

# TEST-NET-1 (RFC 5737), so a dial-out player has somewhere to aim that no real host answers.
readonly UNREACHABLE_SERVER=192.0.2.1:8927
readonly CREDENTIALLED_SERVER='ws://user:s3cr3t@192.0.2.1:8927/sendspin'
readonly CREDENTIAL=s3cr3t

# Only the add-on path uses this. It is what the Supervisor injects, what the image keys the
# add-on branch off, and what the stand-in refuses a request without -- so a token the container
# failed to forward fails the run rather than passing unnoticed.
readonly SUPERVISOR_TOKEN=smoke-supervisor-token

# What the stream-hook checks ask a hook to print, and it is written the way it is on purpose.
#
# `%s` rather than the word, so that the line asserted below can only have come from a hook
# that ran: the player logs the command itself at debug level, and a hook echoing a fixed
# string would be matched by that log line whether or not the exec ever happened.
#
# /usr/bin/printf rather than printf, because printf is one of dash's builtins -- so the bare
# name would prove the shell started and nothing about whether the shell can run a program.
# The absolute path is a second exec, from inside the hook, which is what an amplifier relay's
# `curl` needs and what the profile's second rule grants.
# shellcheck disable=SC2016  # $SENDSPIN_EVENT is for the hook's shell, not for this one.
readonly HOOK_COMMAND='/usr/bin/printf "the %s hook ran\n" "$SENDSPIN_EVENT"'

# The alias a player reaches the stand-in server on, resolved to the host with --add-host. The
# stand-in binds a port the OS picks, which lands in SERVER_PORT when it starts.
readonly SERVER_HOST=sendspin-server

# `supervisor` is the host the real Supervisor answers on, and the one bashio's default URL
# names. Only the port is test-specific -- the stand-in cannot have 80 on the runner -- so
# SUPERVISOR_API is set to carry it, and bashio's default port is the one thing this cannot
# cover. The image hard-codes neither, so there is nothing left there for it to get wrong.
readonly SUPERVISOR_HOST=supervisor

# Sized for a loaded shared CI runner rather than a laptop: being generous costs nothing unless
# something is already wrong, and every wait returns as soon as its condition holds. The health
# timeout is long because it is waiting on Docker's own schedule: the HEALTHCHECK has a 30s start
# period and a 30s interval.
readonly BOOT_TIMEOUT_S=60
readonly EXIT_TIMEOUT_S=60
readonly HEALTH_TIMEOUT_S=150

# The one deadline that is not ours to choose. It is handed to `docker stop`, so it is the grace
# period the s6 shutdown is held to rather than a deadline on a poll. 10 is the Supervisor's own
# add-on `timeout` option, which defaults to 10 and which local_audio/config.yaml does not set.
# Anything more generous here passes a shutdown that real Home Assistant kills, which is exactly
# how the 137 on every stop went unnoticed.
readonly STOP_TIMEOUT_S=10

# What the shutdown is held to, as against the grace above it, and not a number chosen here: it
# is the worst case the image computes for itself in the Dockerfile's S6_KILL_GRACETIME comment
# -- three longruns at 2000ms of `timeout-kill` each, plus the 2000ms tail. Every service can
# wedge and still come in under it.
#
# So a stop that exceeds this is one whose bounds are not holding, whatever the grace period
# happens to allow. This is the one deadline here that is deliberately tight where the waits
# above are deliberately generous, and the difference is what each bounds: those bound a loaded
# runner, this bounds the image, and the image's own arithmetic does not slow down under load. A
# healthy stop measures two to three seconds.
#
# `SECONDS` counts whole seconds and rounds down, so what this refuses in practice is nine and
# over. A red here is a shutdown that has lost its bound; raising the number would only hide the
# next one.
readonly STOP_BUDGET_S=8

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR

# Every container this run creates is named from this, so a run that died without sweeping up
# leaves nothing a later one can collide with.
readonly RUN_PREFIX="sendspin-smoke-$$"

# A loaded profile is machine state rather than this run's own, and the two modes run one after
# the other on the same host. Unique for the same reason RUN_PREFIX is: without it a second run
# replaces and then unloads the profile the first is still confining a container with. The shape
# is the Supervisor's -- a prefix, then the add-on slug.
readonly APPARMOR_SLUG="smoke$$_local_audio"

CONTAINERS=()
PLAYER=''
APPARMOR_LOADED=''
APPARMOR_SUDO=()
APPARMOR_UNAVAILABLE=''
SUPERVISOR_PID=''
SUPERVISOR_PORT=''
SUPERVISOR_MARKER=''
SERVER_PID=''
SERVER_PORT=''
SERVER_MARKER=''
CHECKS=0

fail() {
    printf 'smoke: FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'smoke: ok -- %s\n' "$*"
}

# For a check the runner cannot host, as against one that failed. `--require-apparmor` turns it
# into a refusal, which CI passes, so that nowhere able to run a check reports green without
# having run it. Counted either way and reported at the end, so a developer on a laptop is told
# what went uncovered rather than left to read a partial run as a full pass.
SKIPPED=0

skip() {
    if [ "$REQUIRE_APPARMOR" = true ]; then
        fail "$* (refused rather than skipped, because --require-apparmor was given)"
    fi
    SKIPPED=$((SKIPPED + 1))
    printf 'smoke: SKIP -- %s\n' "$*" >&2
}

step() {
    CHECKS=$((CHECKS + 1))
    printf '\nsmoke: %s (%s mode)\n' "$1" "$MODE"
}

stop_supervisor() {
    if [ -n "$SUPERVISOR_PID" ]; then
        kill "$SUPERVISOR_PID" 2>/dev/null || true
        wait "$SUPERVISOR_PID" 2>/dev/null || true
    fi
    SUPERVISOR_PID=''
    SUPERVISOR_PORT=''
}

stop_server() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    SERVER_PID=''
    SERVER_PORT=''
}

cleanup() {
    local container
    stop_supervisor
    stop_server
    for container in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do
        docker rm --force --volumes "$container" >/dev/null 2>&1 || true
    done
    # After the containers, so nothing is still running under the profile as it is unloaded. The
    # kernel keeps it otherwise, and a later run would confine against whatever this one left. A
    # no-op where the check unloaded it itself, which is the ordinary path.
    unload_apparmor_profile
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ==============================================================================
# Reading a container
# ==============================================================================
#
# Nothing here pipes `docker logs` into grep: `grep -q` exits at its first match, `docker logs`
# then dies of SIGPIPE, and under `set -o pipefail` the shell reads a *successful* match as a
# failed pipeline. Every assertion below therefore dumps the logs to a file first and greps the
# file.

# Writes a container's combined output to a file and echoes the path. Not an error if the
# container has already exited -- that is the subject of three of the checks.
logs_of() {
    local container=$1
    local path="$WORK_DIR/${container}.log"
    docker logs "$container" >"$path" 2>&1 || true
    printf '%s\n' "$path"
}

# Prints what a container said, labelled, for a failure message. The logs are the only evidence
# a CI run leaves behind.
show_logs() {
    local container=$1
    printf '\n---- %s ----\n' "$container" >&2
    cat "$(logs_of "$container")" >&2
    printf -- '---- end %s ----\n' "$container" >&2
    # Only ever on the way to a failure. A denial is what a confined container fails on and the
    # container's own log never mentions it, so a red CI run has to carry it out or the evidence
    # is gone with the runner. Asserting on it instead would be a check that passes on an empty
    # buffer, which the kernel is free to hand back.
    if [ -n "$APPARMOR_LOADED" ]; then
        printf -- '---- recent AppArmor denials ----\n' >&2
        ${APPARMOR_SUDO[@]+"${APPARMOR_SUDO[@]}"} dmesg 2>/dev/null |
            grep -F 'apparmor="DENIED"' | tail -20 >&2 || true
        printf -- '---- end AppArmor denials ----\n' >&2
    fi
    if [ -n "$SUPERVISOR_PID" ]; then
        printf -- '---- stand-in Supervisor ----\n' >&2
        cat "$WORK_DIR/supervisor.log" >&2
        printf -- '---- end stand-in Supervisor ----\n' >&2
    fi
    if [ -n "$SERVER_PID" ]; then
        printf -- '---- stand-in server ----\n' >&2
        cat "$WORK_DIR/server.log" >&2
        printf -- '---- end stand-in server ----\n' >&2
    fi
}

# Waits until `text` -- a fixed string, not a pattern -- appears in a container's output, or
# `limit` seconds pass.
wait_for_log() {
    local container=$1 text=$2 limit=$3
    local waited=0
    while [ "$waited" -lt "$((limit * 10))" ]; do
        if grep -F -e "$text" "$(logs_of "$container")" >/dev/null; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

assert_log() {
    local container=$1 text=$2 what=$3
    if ! wait_for_log "$container" "$text" "$BOOT_TIMEOUT_S"; then
        show_logs "$container"
        fail "$what -- no '$text' in the container log"
    fi
    pass "$what"
}

# The mirror of assert_log, for lines that must not appear. What the caller waited for before
# calling this is what makes the absence mean anything: nothing here can prove a line will never
# arrive, only that it has not yet.
refute_log() {
    local container=$1 text=$2 what=$3
    if grep -F -e "$text" "$(logs_of "$container")" >/dev/null; then
        show_logs "$container"
        fail "$what -- '$text' is in the container log and should not be"
    fi
    pass "$what"
}

wait_for_exit() {
    local container=$1 limit=$2
    local waited=0
    while [ "$waited" -lt "$((limit * 10))" ]; do
        if [ "$(docker inspect --format '{{.State.Running}}' "$container")" = false ]; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

assert_exit_code() {
    local container=$1 expected=$2 what=$3
    local code
    code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
    if [ "$code" != "$expected" ]; then
        show_logs "$container"
        fail "$what -- the container exited $code, not $expected"
    fi
    pass "$what"
}

# Writes the rendered player configuration to a file and echoes the path. `docker cp` rather
# than `docker exec cat`, because some of what is worth asserting about a rendered config is on
# a container the player has since halted, and exec needs one that is still up. Docker's own
# error is carried into the failure: a cp that failed because the container was removed is a
# different fault from one that found no file, and collapsing the two sends a reader looking in
# the wrong place.
config_of() {
    local container=$1
    local path="$WORK_DIR/${container}.conf"
    local err
    err=$(docker cp "$container:/run/sendspin-cli/sendspin-cli.conf" "$path" 2>&1) ||
        fail "could not read /run/sendspin-cli/sendspin-cli.conf out of the container -- $err"
    printf '%s\n' "$path"
}

assert_config_line() {
    local container=$1 pattern=$2 what=$3
    local path
    path=$(config_of "$container")
    if ! grep -E -e "$pattern" "$path" >/dev/null; then
        printf '\n---- rendered config ----\n' >&2
        cat "$path" >&2
        fail "$what -- no line matching /$pattern/ in the rendered config"
    fi
    pass "$what"
}

refute_config_line() {
    local container=$1 pattern=$2 what=$3
    local path
    path=$(config_of "$container")
    if grep -E -e "$pattern" "$path" >/dev/null; then
        printf '\n---- rendered config ----\n' >&2
        cat "$path" >&2
        fail "$what -- a line matching /$pattern/ is in the rendered config and should not be"
    fi
    pass "$what"
}

# `docker top` runs on the host, so it cannot be defeated by an image that ships no `ps` -- this
# one does not -- and is not something a broken container can answer wrongly. Matching is on the
# daemon binaries' own names, which neither `s6-supervise avahi` nor the `s6-pause` standing in
# for a service left down contains.
processes_of() {
    local container=$1
    local path="$WORK_DIR/${container}.procs"
    docker top "$container" >"$path" || fail 'could not read the container process list'
    printf '%s\n' "$path"
}

assert_process() {
    local container=$1 name=$2 what=$3
    local path
    path=$(processes_of "$container")
    if ! grep -F -e "$name" "$path" >/dev/null; then
        printf '\n---- container processes ----\n' >&2
        cat "$path" >&2
        fail "$what -- '$name' is not running"
    fi
    pass "$what"
}

refute_process() {
    local container=$1 name=$2 what=$3
    local path
    path=$(processes_of "$container")
    if grep -F -e "$name" "$path" >/dev/null; then
        printf '\n---- container processes ----\n' >&2
        cat "$path" >&2
        fail "$what -- '$name' is running and should not be"
    fi
    pass "$what"
}

# ==============================================================================
# The stand-in Supervisor
# ==============================================================================

# Starts the stand-in on a port the OS picks, serving the options given as `key=value` pairs. The
# stand-in leaves an empty value out, the way the Supervisor leaves out an option nobody set.
#
# Pairs rather than positional parameters so that a new option is one more argument at the call
# site instead of a signature every caller has to be walked through in step.
start_supervisor() {
    local pair
    local log="$WORK_DIR/supervisor.log"
    local waited=0
    local -a options

    for pair in "$@"; do
        options+=(--option "$pair")
    done

    stop_supervisor
    SUPERVISOR_MARKER="$WORK_DIR/supervisor-requests-${CHECKS}"
    : >"$log"

    python3 "$FAKE_SUPERVISOR" \
        --token "$SUPERVISOR_TOKEN" \
        --marker "$SUPERVISOR_MARKER" \
        ${options[@]+"${options[@]}"} \
        >"$log" 2>&1 &
    SUPERVISOR_PID=$!

    # Waited for rather than assumed: bashio's fetch does not retry, and the oneshot that makes
    # it is on a 30s timeout, so a stand-in still binding its port when the player asks would
    # fail the run for the wrong reason.
    while [ "$waited" -lt "$((BOOT_TIMEOUT_S * 10))" ]; do
        if grep -F -e 'listening on port ' "$log" >/dev/null 2>&1; then
            SUPERVISOR_PORT=$(sed -n 's/.*listening on port \([0-9]*\).*/\1/p' "$log" | head -1)
            [ -n "$SUPERVISOR_PORT" ] || fail 'the stand-in Supervisor printed no port'
            return 0
        fi
        if ! kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
            cat "$log" >&2
            fail 'the stand-in Supervisor died before it was listening'
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    cat "$log" >&2
    fail 'the stand-in Supervisor never reported a port'
}

# Every request the stand-in answered since it was started, one outcome per line. `ok <header>`
# is an authenticated fetch of the one route it serves; anything else is a request that should
# not have happened.
assert_supervisor_requests() {
    local what=$1
    local unexpected

    [ -s "$SUPERVISOR_MARKER" ] || fail "$what -- the stand-in Supervisor was never asked"
    unexpected=$(grep -c -v -e '^ok ' "$SUPERVISOR_MARKER" || true)
    if [ "$unexpected" != 0 ]; then
        cat "$SUPERVISOR_MARKER" >&2
        fail "$what -- $unexpected request(s) arrived unauthenticated or off-route"
    fi
    pass "$what: $(head -1 "$SUPERVISOR_MARKER")"
}

# ==============================================================================
# The stand-in Music Assistant server
# ==============================================================================
#
# Only the stream-hook checks need one. Every other check here is about a player that has been
# started and configured, which needs no server at all -- and the two connection-mode checks
# deliberately aim at an address nothing answers on.

# Starts the stand-in on a port the OS picks and leaves it in SERVER_PORT. The player is pointed
# at it by `server=$SERVER_HOST:$SERVER_PORT`, which start_player turns into an --add-host.
start_server() {
    local log="$WORK_DIR/server.log"
    local waited=0

    stop_server
    SERVER_MARKER="$WORK_DIR/server-connections-${CHECKS}"
    : >"$log"

    python3 "$FAKE_SERVER" --marker "$SERVER_MARKER" >"$log" 2>&1 &
    SERVER_PID=$!

    while [ "$waited" -lt "$((BOOT_TIMEOUT_S * 10))" ]; do
        if grep -F -e 'listening on port ' "$log" >/dev/null 2>&1; then
            SERVER_PORT=$(sed -n 's/.*listening on port \([0-9]*\).*/\1/p' "$log" | head -1)
            [ -n "$SERVER_PORT" ] || fail 'the stand-in server printed no port'
            return 0
        fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            cat "$log" >&2
            fail 'the stand-in server died before it was listening'
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    cat "$log" >&2
    fail 'the stand-in server never reported a port'
}

# That the stand-in got as far as `outcome` with the player under test. It is what keeps the
# hook assertions honest about which half failed: without it, a player that never reached the
# stand-in at all -- a container with no route to the host, a stream that was refused -- reads
# as a hook that did not run, and the failure names the wrong thing.
assert_server_reached() {
    local outcome=$1 what=$2
    local waited=0

    while [ "$waited" -lt "$((BOOT_TIMEOUT_S * 10))" ]; do
        if grep -F -x -e "$outcome" "$SERVER_MARKER" >/dev/null 2>&1; then
            pass "$what"
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    printf '\n---- stand-in server ----\n' >&2
    cat "$WORK_DIR/server.log" >&2
    printf -- '---- end stand-in server ----\n' >&2
    fail "$what -- the stand-in server never recorded '$outcome'"
}

# ==============================================================================
# Starting a player
# ==============================================================================

# Removes the player, and stops the stand-ins, of the check before this one. The checks run
# strictly in sequence and never want two players at once.
retire_player() {
    if [ -n "$PLAYER" ]; then
        docker rm --force --volumes "$PLAYER" >/dev/null 2>&1 || true
    fi
    PLAYER=''
    stop_supervisor
    stop_server
}

# Starts a player with the given options and leaves its container name in $PLAYER. Options are
# named key=value pairs, and an option left out is one the user did not set -- so the image's own
# default applies, which is worth being able to test.
#
# This is the only place the two --mode paths differ, so a check says what it wants and never how
# it is delivered.
#
# The name comes back in a global rather than on stdout because a command substitution would run
# all of this in a subshell, where the container it started is tracked for cleanup in a copy of
# the list that dies with it.
start_player() {
    local name='' output='' log_level='' server='' apparmor='' stream=''
    local buffer_ms='' audio_format='' id='' hook_start='' hook_stop=''
    local pair key value
    local -a args

    for pair in "$@"; do
        key=${pair%%=*}
        value=${pair#*=}
        case $key in
            name) name=$value ;;
            output) output=$value ;;
            log_level) log_level=$value ;;
            server) server=$value ;;
            buffer_ms) buffer_ms=$value ;;
            audio_format) audio_format=$value ;;
            id) id=$value ;;
            hook_start) hook_start=$value ;;
            hook_stop) hook_stop=$value ;;
            stream) stream=$value ;;
            apparmor) apparmor=$value ;;
            *) fail "start_player: unknown option '$key'" ;;
        esac
    done

    retire_player
    PLAYER="${RUN_PREFIX}-player-${CHECKS}"
    args=(--detach --name "$PLAYER")

    # `stream=yes` asks for a player a stream will actually run on, which is a stand-in server
    # to dial out to. It is spelled as a want rather than as a server value for the same reason
    # every other pair here is: the check says what it needs, not how it is wired up.
    if [ -n "$stream" ]; then
        [ -z "$server" ] || fail 'start_player: stream= and server= both name a server'
        start_server
        server="${SERVER_HOST}:${SERVER_PORT}"
        args+=(--add-host "${SERVER_HOST}:host-gateway")
    fi

    # The one argument here that is not a player option: it is a `docker run` flag, and it is
    # delivered the same way in both modes because it has nothing to do with where the options
    # came from. It lives here rather than in the caller so that a check still says what it wants
    # and never how the container is started.
    if [ -n "$apparmor" ]; then
        args+=(--security-opt "apparmor=$apparmor")
    fi

    # `audio_format` and `id` are served here too, though they are not add-on options: a check
    # can then assert that the add-on does not take them even when a Supervisor offers them,
    # which is a stronger statement about the split than never offering them would be.
    if [ "$MODE" = addon ]; then
        start_supervisor "name=$name" "output=$output" "log_level=$log_level" \
            "server=$server" "buffer_ms=$buffer_ms" "audio_format=$audio_format" "id=$id" \
            "hook_start=$hook_start" "hook_stop=$hook_stop"
        args+=(--add-host "${SUPERVISOR_HOST}:host-gateway")
        args+=(--env "SUPERVISOR_TOKEN=$SUPERVISOR_TOKEN")
        args+=(--env "SUPERVISOR_API=http://${SUPERVISOR_HOST}:${SUPERVISOR_PORT}")
    else
        if [ -n "$name" ]; then args+=(--env "SENDSPIN_NAME=$name"); fi
        if [ -n "$output" ]; then args+=(--env "SENDSPIN_OUTPUT=$output"); fi
        if [ -n "$log_level" ]; then args+=(--env "SENDSPIN_LOG_LEVEL=$log_level"); fi
        if [ -n "$server" ]; then args+=(--env "SENDSPIN_SERVER=$server"); fi
        if [ -n "$buffer_ms" ]; then args+=(--env "SENDSPIN_BUFFER_MS=$buffer_ms"); fi
        if [ -n "$audio_format" ]; then args+=(--env "SENDSPIN_AUDIO_FORMAT=$audio_format"); fi
        if [ -n "$id" ]; then args+=(--env "SENDSPIN_ID=$id"); fi
        if [ -n "$hook_start" ]; then args+=(--env "SENDSPIN_HOOK_START=$hook_start"); fi
        if [ -n "$hook_stop" ]; then args+=(--env "SENDSPIN_HOOK_STOP=$hook_stop"); fi
    fi

    CONTAINERS+=("$PLAYER")
    docker run "${args[@]}" "$IMAGE" >/dev/null || fail "could not start $IMAGE"
}

# Waits for Docker to report the container healthy, or `limit` seconds pass. This is the
# HEALTHCHECK instruction's own verdict rather than a direct run of the script it names: a
# malformed CMD leaves a container `starting` forever, and nothing invoking the script by hand
# would notice.
wait_for_health() {
    local container=$1 limit=$2
    local waited=0
    while [ "$waited" -lt "$((limit * 10))" ]; do
        if [ "$(docker inspect --format '{{.State.Health.Status}}' "$container")" = healthy ]; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

# Runs the health check script directly and returns its exit status. Where the wait above asserts
# Docker's verdict, this asserts the script's -- which is the only way to get one out of a
# container Docker has not got round to probing yet.
healthcheck() {
    docker exec "$1" /usr/bin/container-healthcheck
}

wait_for_healthcheck() {
    local container=$1 limit=$2
    local waited=0
    while [ "$waited" -lt "$((limit * 10))" ]; do
        if healthcheck "$container" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

# Stops a player the way the Supervisor stops the add-on, and asserts it got there under its own
# power. Three things have to hold and they fail differently: the container's exit code says
# whether it beat the grace period, the time it took says whether it beat it with anything to
# spare, and the s6 shutdown's own running commentary says whether every service went down or the
# list stopped part-way through on one that would not answer.
#
# Every daemon decision runs this, not just the advertise one. The `s6-pause` decisions bring a
# different set of processes down, and nothing else in this suite ever stops them.
assert_clean_stop() {
    local container=$1
    local log service elapsed

    SECONDS=0
    docker stop --timeout "$STOP_TIMEOUT_S" "$container" >/dev/null ||
        fail "docker stop exited $? -- s6 did not shut the services down"
    elapsed=$SECONDS

    # `docker stop` returns 0 even where it gave up waiting and sent SIGKILL, so its own status
    # proves nothing. The container's does: a killed one reports 137.
    assert_exit_code "$container" 0 'the container stops cleanly within the grace period'

    # Beating the deadline is not the same as beating it with room to spare: a shutdown that has
    # crept most of the way to the grace passes the line above and takes a 137 on the first host
    # slower than this one. The margin is asserted rather than left to be met by luck.
    if [ "$elapsed" -gt "$STOP_BUDGET_S" ]; then
        show_logs "$container"
        fail "the shutdown took ${elapsed}s, past the ${STOP_BUDGET_S}s budget -- it is inside the ${STOP_TIMEOUT_S}s grace by luck rather than by design"
    fi
    pass "the shutdown took ${elapsed}s, inside the ${STOP_BUDGET_S}s budget"

    # The container has exited, so its log is complete -- a line that is not there now never
    # arrives, and there is nothing to wait for.
    log=$(logs_of "$container")
    for service in sendspin-cli avahi dbus; do
        if ! grep -F -e "service ${service} successfully stopped" "$log" >/dev/null; then
            show_logs "$container"
            fail "the s6 shutdown never brought ${service} down -- it ended part-way through"
        fi
        pass "the ${service} service stopped on request rather than being killed"
    done
}

# ==============================================================================
# The add-on's own AppArmor profile
# ==============================================================================
#
# Nothing else in this repository ever runs a process under the profile. Every `docker run` above
# is unconfined, which is what a Compose user gets, and apparmor_check.sh only compiles the file
# and throws the result away. The installed add-on is confined on every start, so a rule that
# denies part of the shutdown fails there while the whole of this suite stays green -- which is
# exactly how a 137 on every Stop survived three releases.

# Whether this runner can confine anything at all, leaving why it cannot in APPARMOR_UNAVAILABLE
# for the caller to skip on. Nothing here refuses on its own: `--require-apparmor` is the single
# switch that turns any of these into a failure, so a developer who did not ask for strictness
# gets told what is missing rather than a red run.
apparmor_available() {
    [ -f "$APPARMOR_SOURCE" ] || fail "no profile at $APPARMOR_SOURCE"
    APPARMOR_UNAVAILABLE=''

    if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" != Y ]; then
        APPARMOR_UNAVAILABLE='this kernel enforces no AppArmor profile'
        return 1
    fi

    if ! command -v apparmor_parser >/dev/null; then
        APPARMOR_UNAVAILABLE='this kernel has AppArmor but apparmor_parser is not installed -- install the apparmor package'
        return 1
    fi

    # Loading a profile needs CAP_MAC_ADMIN. Already held where a runner runs the suite as root,
    # so sudo is reached for only when it is not.
    if [ "$(id -u)" -ne 0 ]; then
        if ! { command -v sudo >/dev/null && sudo -n true 2>/dev/null; }; then
            APPARMOR_UNAVAILABLE='loading a profile needs root, and passwordless sudo is not available here'
            return 1
        fi
        APPARMOR_SUDO=(sudo -n)
    fi

    # Stated rather than inherited from whatever the last command above happened to return: a
    # line appended here could otherwise turn availability into a skip with no reason to print.
    return 0
}

# Loads the profile into the kernel under a Supervisor-style slug, and records it for cleanup.
#
# The rename is not cosmetic: install_apparmor() rewrites the name to the installed slug before
# loading, so the profile is never in force under the name it is written with. Loading it as
# written would test a name the add-on never runs as.
load_apparmor_profile() {
    local original rendered="$WORK_DIR/$APPARMOR_SLUG"

    original="$(awk '{ sub(/\r$/, "") } /^profile [^ ]+/ { print $2; exit }' "$APPARMOR_SOURCE")"
    [ -n "$original" ] || fail "no top-level profile in $APPARMOR_SOURCE"

    # Keyed on the name, not on the indentation: awk strips leading blanks, so `$1` is
    # "profile" on the three child profiles too, and only `$2` tells the top-level one apart.
    awk -v from="$original" -v to="$APPARMOR_SLUG" \
        '{ sub(/\r$/, "") } $1 == "profile" && $2 == from { $2 = to } { print }' \
        "$APPARMOR_SOURCE" >"$rendered"
    grep -q "^profile $APPARMOR_SLUG " "$rendered" ||
        fail "rewriting '$original' to '$APPARMOR_SLUG' did not take"

    ${APPARMOR_SUDO[@]+"${APPARMOR_SUDO[@]}"} apparmor_parser --replace "$rendered" ||
        fail "apparmor_parser could not load the profile as '$APPARMOR_SLUG'"
    APPARMOR_LOADED=$rendered
    pass "the add-on profile is loaded and enforcing as $APPARMOR_SLUG"
}

# Unloaded as soon as the confined check is done rather than left to the trap, so that a failure
# in one of the unconfined checks after it does not print a denials block it has nothing to do
# with. The trap calls this too, for a failure part-way through the check itself, so nothing is
# left in the kernel either way.
unload_apparmor_profile() {
    [ -n "$APPARMOR_LOADED" ] || return 0
    ${APPARMOR_SUDO[@]+"${APPARMOR_SUDO[@]}"} apparmor_parser --remove "$APPARMOR_LOADED" \
        >/dev/null 2>&1 || true
    APPARMOR_LOADED=''
}

# ==============================================================================
# The checks
# ==============================================================================

# The default connection mode, and the one the add-on ships: no server configured, so the player
# advertises itself and waits to be found. Everything the image exists for is on this path -- the
# bundled dbus, avahi-daemon, and the avahi-compat shim the player registers through -- so it is
# asserted end to end as well as by its parts.
check_advertise_mode() {
    local container mode status_out devices_out
    step 'advertise mode'
    start_player "name=$PLAYER_NAME" 'output=null' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER

    assert_log "$container" \
        'Starting the bundled dbus and avahi-daemon to advertise this player over mDNS.' \
        'the daemon decision is recorded and says to start them'
    assert_log "$container" "Advertising \"${PLAYER_NAME}\" over mDNS" \
        'the connection mode is logged, with the name quoted as given'
    assert_log "$container" 'listening on port 8928' \
        'the player came up on its port'

    # `mdns: ` and the lower-case verb are both load-bearing. The player's line for the opposite
    # case reads `mdns: Not advertising _sendspin._tcp`, so the bare verb and the service name
    # appear in the log whether or not anything was ever advertised.
    assert_log "$container" 'mdns: advertising _sendspin._tcp' \
        'the player registered its service with the bundled avahi-daemon'

    # The player warns and retries rather than failing when a registration is refused, so the
    # line above can arrive on a second attempt with the first having gone wrong. Nothing about
    # a slow-but-working daemon should read the same as a broken one.
    refute_log "$container" 'could not register' \
        'the registration was not refused on the way there'

    # Neither mode delivers a PulseAudio, so the silent-output check has no socket to find and
    # has to stay quiet. The player being up above is what makes this absence mean something.
    refute_log "$container" 'The Home Assistant audio output this player plays through' \
        'no PulseAudio means the silent-output check says nothing at all'

    # The check also names the output on every start now, which is the line most likely to leak
    # out from under the socket guard, since it does not wait for anything to be wrong first.
    refute_log "$container" 'Playing through sink #' \
        'and it does not name an output it never found either'

    # Nothing else in the image uses `pactl`, so a dropped Dockerfile line would take the
    # warning with it and leave every other check green.
    docker exec "$container" sh -c 'command -v pactl' >/dev/null 2>&1 ||
        fail 'pactl is not in the image -- the silent-output check could never run'
    pass 'pactl is in the image for the silent-output check'

    # `avahi-browse` would be the other half of this -- resolving the record from outside the
    # player -- but the image ships no avahi-utils, and installing them into the container under
    # test would change the subject of the test. The register line above is the daemon's own
    # answer back over D-Bus, so the compat shim, the bus and avahi are all proven by it; what is
    # left unproven is the wire, which a runner with no multicast cannot answer for anyway.
    assert_process "$container" avahi-daemon 'the bundled avahi-daemon is running'
    assert_process "$container" dbus-daemon 'the bundled dbus-daemon is running'

    assert_config_line "$container" "^name = ${PLAYER_NAME}\$" \
        'the name reached the rendered config intact'
    assert_config_line "$container" '^output = null$' \
        'the output reached the rendered config'
    assert_config_line "$container" "^log-level = ${PLAYER_LOG_LEVEL}\$" \
        'the log level reached the rendered config'
    refute_config_line "$container" '^server' \
        'an unset server is left out of the config rather than written empty'

    # The same rule as `server`, for the three keys whose default is upstream's own. A number or
    # a shape written here would be this repo's to keep in step with upstream's for good, so the
    # absence is the assertion that matters -- and it is asserted on the player nothing was
    # configured on, which is the one every user who never opened the settings is running.
    refute_config_line "$container" '^buffer-ms' \
        'an unset buffer is left out, so the player keeps its own default'
    refute_config_line "$container" '^audio-format' \
        'an unset audio format is left out rather than pinning a shape nobody asked for'
    refute_config_line "$container" '^id = ' \
        'an unset client id is left out, so the player derives its own'

    # Written on every start from neither deployment's configuration, so they are asserted on the
    # unconfigured player: an image that only reported itself properly when configured would be
    # reporting the library's identity to nearly everybody.
    assert_config_line "$container" '^manufacturer = Music Assistant$' \
        'the device list is told this image made the player, not the library it is built on'
    assert_config_line "$container" '^product-name = Local Audio$' \
        'and told what the product is'

    # Read with exec rather than through config_of above: the mode belongs to the container's own
    # copy, and `docker cp` writes a host file whose permissions are the runner's business.
    mode=$(docker exec "$container" stat -c %a /run/sendspin-cli/sendspin-cli.conf)
    [ "$mode" = 600 ] || fail "the rendered config is mode $mode, not 600"
    pass 'the rendered config is readable only by root'

    status_out="$WORK_DIR/${container}.status"
    docker exec "$container" \
        sendspin-cli status --control-socket /run/sendspin-cli/control.sock >"$status_out" 2>&1 ||
        fail "sendspin-cli status exited $? -- $(cat "$status_out")"
    if ! grep -F -e 'output: null' "$status_out" >/dev/null; then
        cat "$status_out" >&2
        fail 'the control socket did not report the configured output'
    fi
    pass 'the control socket answers and reports the configured output'

    # The list the binary itself reports, as against the one the Dockerfile grepped out of a
    # configure log in a stage that no longer exists. It is compile-time information either way
    # -- what it adds is that this is the binary that shipped, in the image that shipped, so a
    # COPY that took the wrong artifact is caught here and nowhere else. `-l` prints it as part
    # of explaining how -o reads its argument.
    devices_out="$WORK_DIR/${container}.devices"
    docker exec "$container" sendspin-cli -l >"$devices_out" 2>&1 ||
        fail "sendspin-cli -l exited $? -- $(cat "$devices_out")"
    if ! grep -F -e 'null, stdout, alsa, pulse, pipewire' "$devices_out" >/dev/null; then
        cat "$devices_out" >&2
        fail 'the shipped player does not offer all five backends this image builds'
    fi
    pass 'the shipped player offers null, stdout, alsa, pulse and pipewire'

    # And the runtime half, which the list above genuinely cannot answer for: every backend
    # library is linked rather than dlopened, so a runtime stage missing one gives a binary that
    # does not start at all -- and `ldd` is the only thing here that says which one, rather than
    # leaving a reader with every check in the suite red and no cause.
    if docker exec "$container" ldd /usr/bin/sendspin-cli 2>&1 | grep -F -e 'not found'; then
        fail 'the shipped player has an unresolved shared library -- a runtime-stage package is missing'
    fi
    pass 'every library the player links resolves in the image that shipped'

    # The ALSA half of the listing. A container with no sound card still has ALSA's own plugin
    # PCMs, `null` among them, so the section is never legitimately empty here.
    if ! grep -E -e '^ALSA PCMs on this host' "$devices_out" >/dev/null; then
        cat "$devices_out" >&2
        fail 'sendspin-cli -l listed no ALSA PCMs at all'
    fi
    pass 'sendspin-cli -l lists the ALSA PCMs'

    healthcheck "$container" >/dev/null || fail "the health check exited $?"
    pass 'the health check passes'

    wait_for_health "$container" "$HEALTH_TIMEOUT_S" || {
        show_logs "$container"
        fail "docker reports the container $(docker inspect \
            --format '{{.State.Health.Status}}' "$container"), not healthy"
    }
    pass 'docker reports the container healthy, so the HEALTHCHECK instruction runs'

    assert_clean_stop "$container"
}

# The name a user who never opened the configuration screen ends up with. It is a fixed string
# now rather than the host's name, so nothing outside the image decides it -- which is what makes
# it worth asserting in both modes: add-on mode reaches the same default through an empty `name`
# option rather than through an unset variable.
check_default_name() {
    local container
    step 'the default player name'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER

    assert_log "$container" 'Advertising "Local Audio" over mDNS' \
        'a player nobody named advertises itself as Local Audio'
    assert_config_line "$container" '^name = Local Audio$' \
        'and that is the name the rendered config carries'
}

# An `mdns:` server is the third of the four daemon decisions and the odd one out: a server is
# configured, so the player does not advertise, and yet the daemons are needed anyway because
# mDNS is how that server's name gets resolved. Leaving them down here would give a player that
# can never find the thing it was told to connect to.
check_mdns_server_mode() {
    local container
    step 'mDNS-resolved server'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL" 'server=mdns:Living Room'
    container=$PLAYER

    assert_log "$container" \
        'Starting the bundled dbus and avahi-daemon: the mdns: server value needs mDNS to resolve the server.' \
        'the daemon decision is recorded and says to start them for the lookup'
    assert_log "$container" \
        'Resolving the Music Assistant server over mDNS (mdns:Living Room); this player is not advertised.' \
        'the connection mode is logged as resolving over mDNS'
    assert_log "$container" 'listening on port 8928' 'the player came up on its port'
    assert_process "$container" avahi-daemon 'the bundled avahi-daemon is running for the lookup'
    refute_log "$container" 'mdns: advertising _sendspin._tcp' \
        'the player advertises nothing when it has a server to reach'

    assert_clean_stop "$container"
}

# A fixed server suppresses the mDNS advertisement, which makes the bundled daemons dead weight
# -- so they are never started, and the health check must not go asking for one that is not
# there. The server is unreachable on purpose: what is under test is the decision, not a
# handshake.
check_dial_out_mode() {
    local container
    step 'dial-out mode'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL" "server=$UNREACHABLE_SERVER"
    container=$PLAYER

    assert_log "$container" \
        'A fixed server is configured, which suppresses the mDNS advertisement: the bundled dbus and avahi-daemon stay down.' \
        'the daemon decision is recorded and says to keep them down'
    assert_log "$container" "Dialling out to ${UNREACHABLE_SERVER}; this player is not advertised." \
        'the connection mode is logged as dialling out'

    wait_for_healthcheck "$container" "$BOOT_TIMEOUT_S" || {
        show_logs "$container"
        fail 'the health check never passed in dial-out mode'
    }
    pass 'the health check passes without a bundled avahi to ask'

    assert_config_line "$container" "^server = ${UNREACHABLE_SERVER}\$" \
        'the server reached the rendered config'
    assert_log "$container" 'mdns: Not advertising _sendspin._tcp' \
        'the player says it is not advertising, and why'
    refute_log "$container" 'mdns: advertising _sendspin._tcp' \
        'the player advertises nothing when it has a server to dial'
    refute_process "$container" avahi-daemon 'no avahi-daemon is running'
    refute_process "$container" dbus-daemon 'no dbus-daemon is running'

    assert_clean_stop "$container"
}

# A server value can carry credentials, and the connection-mode line is the first thing that gets
# pasted into a support thread -- so that line is written with the userinfo stripped out.
#
# That line only. The player logs the URL it was handed in full, at info level, and that is
# upstream behaviour in a component this repo builds rather than owns; asserting the credential
# appears nowhere in the log would be asserting something this image cannot deliver. What it can
# deliver is its own line, and a config file only root can read.
check_credentials_are_kept_out_of_the_mode_line() {
    local container
    step 'credentials in a server value'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL" "server=$CREDENTIALLED_SERVER"
    container=$PLAYER

    assert_log "$container" \
        'Dialling out to ws://192.0.2.1:8927/sendspin; this player is not advertised.' \
        'the connection mode is logged with the userinfo stripped'
    refute_log "$container" "Dialling out to ws://user:${CREDENTIAL}" \
        'the line this image writes carries no credentials'
    assert_config_line "$container" "^server = ${CREDENTIALLED_SERVER}\$" \
        'the credentials still reach the player, which needs them'
}

# The one option value that could rewrite the configuration rather than fill it in: a newline
# turns one option into two config keys, and an injected `server` flips the connection mode and
# takes the advertisement with it without saying so. Refused rather than escaped, and the refusal
# has to stop the container -- a player started on a config somebody else wrote is worse than one
# that never started at all.
check_newline_in_an_option() {
    local container
    step 'a newline in an option value'
    start_player "name=x
server = evil" 'output=null'
    container=$PLAYER

    wait_for_exit "$container" "$EXIT_TIMEOUT_S" || {
        show_logs "$container"
        fail 'an option carrying a newline left the container running'
    }
    pass 'an option carrying a newline stops the container'

    assert_exit_code "$container" 1 'the container exits 1 on a refused option'
    assert_log "$container" \
        'SENDSPIN_NAME contains a newline, which would inject configuration keys.' \
        'the log names the option it refused, and why'
    refute_log "$container" 'listening on port 8928' \
        'no player was started on the injected config'
}

# The one tuning value both deployments offer, so it is asserted in both. The range is the
# player's own, and the refusal is the half that earns its keep: the add-on's schema holds a value
# to that range before it ever arrives, and Compose has nothing at all in front of it, so the
# shared read is the only place the two are held to the same standard.
check_buffer_ms() {
    local container case value message

    step 'a configured audio buffer'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL" 'buffer_ms=250'
    container=$PLAYER
    assert_log "$container" 'listening on port 8928' 'the player came up on its port'
    assert_config_line "$container" '^buffer-ms = 250$' \
        'the buffer reached the rendered config under the key the player reads'

    # Refused here rather than passed on, because a value the player rejects is a container that
    # restarts into the same rejection, reported in the player's words about a config file the
    # user never wrote rather than in ours about the value they did set.
    #
    # One case per reason the guard has to refuse, because they are separate branches of it. The
    # last is the one the length test exists for and the only case that would still pass without
    # it: past 64 bits the shell's own arithmetic wraps, so 2^64 + 100 reads as an obedient 100.
    for case in \
        'abc|SENDSPIN_BUFFER_MS is "abc", which is not a whole number of milliseconds.' \
        '9|SENDSPIN_BUFFER_MS is 9, outside the 10 to 2000 milliseconds the player accepts.' \
        '2001|SENDSPIN_BUFFER_MS is 2001, outside the 10 to 2000 milliseconds the player accepts.' \
        '18446744073709551716|SENDSPIN_BUFFER_MS is 18446744073709551716, outside the 10 to 2000 milliseconds the player accepts.'; do
        value=${case%%|*}
        message=${case#*|}

        step "the audio buffer ${value}"
        start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL" "buffer_ms=${value}"
        container=$PLAYER

        wait_for_exit "$container" "$EXIT_TIMEOUT_S" || {
            show_logs "$container"
            fail "a buffer of ${value} left the container running"
        }
        assert_exit_code "$container" 1 "the container exits 1 on a buffer of ${value}"
        assert_log "$container" "$message" 'the log names the value it refused, and why'
        refute_log "$container" 'listening on port 8928' \
            'no player was started on a buffer the player would have refused anyway'
    done
}

# The two values Compose has and the add-on deliberately does not. Add-on mode is served both by
# the stand-in Supervisor and has to ignore them, which says "not an option here" far more firmly
# than never offering them would. The format is one a device-less sink advertises, so what is
# under test is the plumbing rather than a player refusing a shape it could not honour.
check_compose_only_options() {
    local container

    step 'the Compose-only options'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL" \
        'audio_format=flac:48000:24:2' 'id=smoke-test-player'
    container=$PLAYER
    assert_log "$container" 'listening on port 8928' 'the player came up on its port'

    if [ "$MODE" = addon ]; then
        refute_config_line "$container" '^audio-format' \
            'an audio format is not an add-on option, even with a Supervisor serving one'
        refute_config_line "$container" '^id = ' \
            'nor is a client id, for the same reason'
    else
        assert_config_line "$container" '^audio-format = flac:48000:24:2$' \
            'the audio format reached the rendered config under the key the player reads'
        assert_config_line "$container" '^id = smoke-test-player$' \
            'and so did the client id'
    fi
}

# An output the host cannot open is the likeliest way for this image to be misconfigured, and the
# one failure a user cannot see: the Supervisor calls a running container a healthy add-on
# whatever is crash-looping inside it. So the player's error exit halts the container, and that
# is what is asserted -- a stopped add-on with a reason in the log.
check_crash_visibility() {
    local container
    step 'crash visibility'
    start_player 'output=hw:99,0' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER

    wait_for_exit "$container" "$EXIT_TIMEOUT_S" || {
        show_logs "$container"
        fail 'a player that cannot open its output left the container running'
    }
    pass 'a player that cannot open its output stops the container'

    assert_exit_code "$container" 1 "the container carries the player's exit code out"
    assert_log "$container" 'sendspin-cli exited 1; stopping the container.' \
        'the halt says which exit code stopped the container'
}

# The two option values whose *meaning* changed rather than their handling. `pulse` and
# `pipewire` used to fall through to ALSA's plugin PCMs of the same name; now that this image
# builds the native backends, they select those instead. Both routes end at the same server, so
# nothing fails and nothing but the log would ever say the route moved -- which is the whole
# reason the line exists, and why an image that dropped it would look perfectly healthy.
#
# The value has to survive untouched. Rewriting it to `alsa:pulse` on the way to the config would
# pin every existing user to the legacy route for good, and the report above would be describing
# something that had not happened.
#
# Nothing here waits on what the player does with the value, which is why the config read below
# is anchored on the connection-mode line: that is logged after the config is written and before
# the player is exec'd, so it holds whether the player goes on to run or to give up on a server
# that is not there.
check_output_names_that_changed_meaning() {
    local container backend server

    for backend in pulse pipewire; do
        case $backend in
            pulse) server=PulseAudio ;;
            pipewire) server=PipeWire ;;
        esac

        step "the output name $backend"
        start_player "output=$backend" "log_level=$PLAYER_LOG_LEVEL"
        container=$PLAYER

        assert_log "$container" \
            "The output ${backend} now selects this player's native ${server} backend" \
            "the log says ${backend} now means the native ${server} backend"
        assert_log "$container" "alsa:${backend} is that previous behaviour." \
            "and names alsa:${backend} as the way back to what it used to mean"

        # Logged immediately after the config is written and before the player is exec'd, so it
        # is what makes the read below race-free without waiting on the player's own fate.
        assert_log "$container" 'over mDNS, waiting for a Music Assistant server to connect.' \
            'the player was started, so its config has been rendered'
        assert_config_line "$container" "^output = ${backend}\$" \
            "the value reached the config unaltered rather than rewritten to alsa:${backend}"
    done
}

# The mirror of the check above, on the two values every deployment actually runs: nothing about
# them changed, and a line telling their users their audio moved would be worse than no line at
# all. Each refusal waits on a line the run script logs *after* the point the warning would have
# been logged at, which is what makes the absence mean something rather than merely not-yet.
check_output_names_that_did_not() {
    local container

    step 'the output name null'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER
    assert_log "$container" 'listening on port 8928' 'the player came up on its port'
    refute_log "$container" 'now selects this player' \
        'a player on null is told nothing about a backend name that changed meaning'

    step 'the output name default'
    start_player 'output=default' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER
    assert_log "$container" 'over mDNS, waiting for a Music Assistant server to connect.' \
        'the player was started on the default output'
    refute_log "$container" 'now selects this player' \
        'nor is a player on default, which is what both deployments run on'

    # The documented way back, and the value a prefix or substring match would wrongly claim.
    # Only an exact match on the two bare names is right, and this is what says so.
    step 'the output name alsa:pulse'
    start_player 'output=alsa:pulse' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER
    assert_log "$container" 'over mDNS, waiting for a Music Assistant server to connect.' \
        'the player was started on the escape hatch'
    refute_log "$container" 'now selects this player' \
        'the alsa: form carries no warning -- it is what the warning points at'
    assert_config_line "$container" '^output = alsa:pulse$' \
        'and it reaches the config as written'
}

# The stop the add-on actually performs: every service running, under the profile the Supervisor
# installs. The unconfined stops above cannot see this one, because what fails here is a kernel
# denial that only exists once the profile is in force.
#
# The boot is as load-bearing as the stop. A profile that denies avahi its netlink socket leaves
# the daemon restarting once a second, and a stop that lands between two restarts finds nothing
# to bring down and reports every service stopped -- passing while asserting nothing. So the
# player is held until it has advertised, and both daemons are read off the process list, before
# anything is stopped.
#
# The container is on the default bridge, where every other check here is; the add-on runs with
# `host_network: true`. So this covers the profile, not the profile in the network namespace the
# add-on actually has. Asking for the host's namespace in CI would put the player's port on the
# runner, which is a collision this suite has no way to arbitrate.
check_confined_stop() {
    local container
    step 'stopping under the add-on AppArmor profile'

    if ! apparmor_available; then
        skip "$APPARMOR_UNAVAILABLE, so the confined stop ran nowhere -- the installed add-on is confined on every start"
        return
    fi

    load_apparmor_profile
    start_player "name=$PLAYER_NAME" 'output=null' "log_level=$PLAYER_LOG_LEVEL" \
        "apparmor=$APPARMOR_SLUG"
    container=$PLAYER

    assert_log "$container" 'listening on port 8928' 'the player came up confined'
    assert_log "$container" 'mdns: advertising _sendspin._tcp' \
        'avahi answered the player, so the daemons are up rather than restarting'

    assert_process "$container" 'avahi-daemon' 'avahi-daemon is running at the moment of the stop'
    assert_process "$container" 'dbus-daemon' 'dbus-daemon is running at the moment of the stop'

    # The health check reaches into both daemons -- the player's control socket, then
    # `avahi-daemon --check` -- and Docker calls the add-on unhealthy if it fails. Unconfined it
    # is asserted nowhere else, and confined is the only way it could fail on a profile rule.
    healthcheck "$container" >/dev/null ||
        fail 'the health check does not pass confined -- Docker would call the add-on unhealthy'
    pass 'the health check passes under the profile'

    # Both daemons have dropped to their own users by now, which is the whole of what makes this
    # stop different: signalling them is a CAP_KILL the outer profile has to grant.
    assert_clean_stop "$container"
    unload_apparmor_profile
}

# The two options that are a command rather than data. Both halves are asserted: that an unset
# hook is absent from the rendered config, which is the rule every optional key here follows,
# and that a set one arrives under the key the player reads and is then really run when a
# stream starts and ends.
#
# Running one needs a stream, and a stream needs a server, which is what scripts/fake_server.py
# is. Nothing else in this suite has ever needed one: every other check is about a player that
# has been configured and started, and the two connection-mode checks deliberately aim at an
# address nothing answers on.
check_stream_hooks() {
    local container

    step 'no stream hooks configured'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER
    assert_log "$container" 'listening on port 8928' 'the player came up on its port'
    refute_config_line "$container" '^hook-start' \
        'an unset start hook is absent from the rendered config rather than empty'
    refute_config_line "$container" '^hook-stop' \
        'and so is an unset stop hook'

    step 'the stream hooks'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL" 'stream=yes' \
        "hook_start=$HOOK_COMMAND" "hook_stop=$HOOK_COMMAND"
    container=$PLAYER

    # Logged after the config is written and before the player is exec'd, so it is what makes
    # the two reads below race-free rather than a guess at how far the start has got.
    assert_log "$container" 'Dialling out to' \
        'the player was started, so its config has been rendered'
    assert_config_line "$container" '^hook-start = ' \
        'the start hook reached the rendered config under the key the player reads'
    assert_config_line "$container" '^hook-stop = ' \
        'and so did the stop hook'

    assert_server_reached 'stream-start' 'the stand-in server started a stream on the player'
    assert_log "$container" 'the start hook ran' \
        'the start hook was run, and its output reached the log'
    assert_server_reached 'stream-end' 'the stand-in server ended the stream'
    assert_log "$container" 'the stop hook ran' \
        'the stop hook was run when the stream ended'
}

# The same thing under the profile the Supervisor installs, and the check this whole change
# turns on. Running a hook is the only exec the player's child profile has, and an AppArmor
# denial of it is invisible everywhere else: the container starts, the config renders, the
# player streams, and the only symptom is a hook that silently does not run. The unconfined
# check above cannot see it, because the rules it depends on are not in force there.
#
# That profile permitted no exec of anything before this change, so deleting its one
# `/usr/bin/** ix` line from local_audio/apparmor.txt is what proves this check tests the grant
# rather than passing regardless: the player then reports the hook as having exited 127, its
# own account of an execve() that failed, and the assertions below go red. The hook runs
# /usr/bin/printf rather than the shell builtin of the same name so that the same one line is
# load-bearing twice over -- for the shell the player execs, and for the program the shell
# execs after it, which is what an amplifier relay's `curl` would be.
check_confined_stream_hooks() {
    local container
    step 'running a stream hook under the add-on AppArmor profile'

    if ! apparmor_available; then
        skip "$APPARMOR_UNAVAILABLE, so the confined hook ran nowhere -- the installed add-on is confined on every start, and the hook exec is the one thing its profile has to permit"
        return
    fi

    load_apparmor_profile
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL" 'stream=yes' \
        "hook_start=$HOOK_COMMAND" "hook_stop=$HOOK_COMMAND" "apparmor=$APPARMOR_SLUG"
    container=$PLAYER

    assert_server_reached 'stream-start' 'the confined player connected and was streamed to'
    assert_log "$container" 'the start hook ran' \
        'the profile lets the player execute the hook shell'
    assert_server_reached 'stream-end' 'the stand-in server ended the stream'
    assert_log "$container" 'the stop hook ran' \
        'and the stop hook runs under it too'

    # 127 is what the player reports for a hook whose execve() failed, which is what an
    # AppArmor denial of the exec looks like from inside the container -- there is no other
    # symptom, and the denial itself is only in the host's kernel log. Refuted after the
    # assertions above, so the absence means the exec succeeded rather than not-yet.
    #
    # Just the exit code and not the whole sentence: the player's line is `The start hook
    # [113] exited 127`, with a pid in the middle of it, so a match written around the word
    # `hook` would be an assertion that can never fail.
    refute_log "$container" 'exited 127' \
        'no hook was refused its exec, so nothing was denied and quietly retried'

    unload_apparmor_profile
}

# That the options the checks above asserted really did come over the API, authenticated. Without
# this, add-on mode would still pass on an image that ignored the Supervisor entirely and fell
# through to its defaults -- `null` is not one of those defaults, but a check that never looks at
# who answered cannot say so.
check_supervisor_was_asked() {
    local container
    step 'the options came from the Supervisor'
    start_player "name=$PLAYER_NAME" 'output=null' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER

    assert_log "$container" 'listening on port 8928' 'the player came up on its port'
    assert_supervisor_requests 'the stand-in Supervisor was asked, and only for its one route'
    assert_config_line "$container" "^name = ${PLAYER_NAME}\$" \
        'the name in the config came from the API rather than the default'
    assert_config_line "$container" '^output = null$' \
        'an output of null survived the fetch as a value rather than becoming a default'
}

# The add-on path's own failure mode, and the reason the options are fetched once rather than per
# key: a Supervisor that cannot be reached must stop the container, not let every option fall
# through to a default and run a player nobody configured.
#
# Unreachable here means refused, from inside the container, which needs nothing of the host and
# happens at once. A black-holed address would instead prove the oneshot's `timeout-up`, at the
# cost of thirty seconds a run; either asserts the same failure.
check_supervisor_unreachable() {
    local container
    step 'unreachable Supervisor'
    retire_player
    container="${RUN_PREFIX}-player-${CHECKS}"
    PLAYER=$container
    CONTAINERS+=("$container")
    docker run --detach --name "$container" \
        --env "SUPERVISOR_TOKEN=$SUPERVISOR_TOKEN" \
        --env 'SUPERVISOR_API=http://127.0.0.1:1' \
        "$IMAGE" >/dev/null || fail "could not start $IMAGE"

    wait_for_exit "$container" "$EXIT_TIMEOUT_S" || {
        show_logs "$container"
        fail 'an add-on that cannot reach the Supervisor left the container running'
    }
    pass 'an add-on that cannot reach the Supervisor stops the container'

    assert_log "$container" 'Could not read the add-on options from the Supervisor.' \
        'the log says the options could not be read'
    refute_log "$container" 'listening on port 8928' \
        'no player was started on defaults nobody chose'
}

main() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 ||
        fail "no such image '$IMAGE' -- build it first, or pass one that exists"

    # The stand-in server runs in both modes -- a stream is not something either option source
    # changes -- so python3 is needed in both, and is checked here rather than inside the
    # add-on branch below where it used to be the stand-in Supervisor's requirement alone.
    [ -f "$FAKE_SERVER" ] || fail "no stand-in server at '$FAKE_SERVER'"
    command -v python3 >/dev/null ||
        fail 'the stream-hook checks need python3 for the stand-in Music Assistant server'

    if [ "$MODE" = addon ]; then
        [ -f "$FAKE_SUPERVISOR" ] || fail "no stand-in Supervisor at '$FAKE_SUPERVISOR'"
    fi

    printf 'smoke: testing %s in %s mode\n' "$IMAGE" "$MODE"

    check_advertise_mode
    check_default_name
    check_mdns_server_mode
    check_dial_out_mode
    check_credentials_are_kept_out_of_the_mode_line
    check_newline_in_an_option
    check_output_names_that_changed_meaning
    check_output_names_that_did_not
    check_buffer_ms
    check_compose_only_options
    check_crash_visibility
    check_stream_hooks
    check_confined_stop
    check_confined_stream_hooks
    if [ "$MODE" = addon ]; then
        check_supervisor_was_asked
        check_supervisor_unreachable
    fi

    if [ "$SKIPPED" -ne 0 ]; then
        printf '\nsmoke: every check that ran passed, %s skipped (%s mode)\n' "$SKIPPED" "$MODE"
        return
    fi
    printf '\nsmoke: every check passed (%s mode)\n' "$MODE"
}

main
