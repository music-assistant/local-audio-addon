# shellcheck shell=bash
# Paths, option reading and the bundled-daemon decision, shared by the s6
# services and the container health check.

readonly SENDSPIN_RUN_DIR=/run/sendspin-cli
readonly SENDSPIN_CONF=/run/sendspin-cli/sendspin-cli.conf
readonly SENDSPIN_STATE_DIR=/data/state
readonly SENDSPIN_CONTROL_SOCKET=/run/sendspin-cli/control.sock
readonly SENDSPIN_DAEMON_DECISION=/run/sendspin-cli/bundled-daemons
readonly SYSTEM_BUS_DIR=/var/run/dbus
readonly SYSTEM_BUS_SOCKET=/var/run/dbus/system_bus_socket
readonly AVAHI_SOCKET=/run/avahi-daemon/socket
readonly PULSE_SOCKET=/run/audio/pulse.sock
readonly PULSE_CLIENT_CONF=/etc/pulse/client.conf
# Home Assistant OS's hassio bridge, which only the host and its containers can
# reach. Music Assistant fetches the pairing token from here and nowhere else.
readonly HASSIO_ADDRESS=172.30.32.1
readonly LOCAL_PAIRING_DEFAULT_PORT=8929

sendspin::log() {
    printf '%s\n' "$*" >&2
}

# Populate SENDSPIN_NAME, SENDSPIN_OUTPUT, SENDSPIN_LOG_LEVEL, SENDSPIN_SERVER,
# SENDSPIN_BUFFER_MS, SENDSPIN_AUDIO_FORMAT, SENDSPIN_ALLOW_UNPAIRED, SENDSPIN_INPUT,
# SENDSPIN_INPUT_CARD_PROFILE,
# SENDSPIN_HOOK_START, SENDSPIN_HOOK_STOP, SENDSPIN_LOCAL_PAIRING,
# SENDSPIN_LOCAL_PAIRING_ADDRESS, SENDSPIN_LOCAL_PAIRING_PORT,
# SENDSPIN_KEEP_OUTPUT_ALIVE, SENDSPIN_RELEASE_DEVICE, SENDSPIN_ALSA_MIXER and
# SENDSPIN_ALSA_MIXER_CURVE. Only the source differs between an add-on and a
# plain container; the defaults below are applied to both so the two cannot
# drift.
#
# Stops the container on a value that would inject configuration keys, and on a
# buffer the player would reject, rather than returning either to the caller.
sendspin::read_options() {
    local config name value

    # SUPERVISOR_TOKEN is injected by the Supervisor, and it is what bashio
    # needs: bashio reads the options from the Supervisor API, not from
    # /data/options.json.
    if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
        source /usr/lib/bashio/bashio.sh

        # One fetch, so that an unreachable Supervisor stops the container
        # rather than letting every key fall through to a default below.
        config=$(bashio::addon.config) \
            || bashio::exit.nok 'Could not read the add-on options from the Supervisor.'

        SENDSPIN_NAME=$(sendspin::option "${config}" 'name')
        # Not settable from the add-on any more: absent from the Supervisor's
        # config it falls through to the default below. The read stays so the
        # stand-in Supervisor in scripts/smoke_test.sh can still deliver one.
        SENDSPIN_OUTPUT=$(sendspin::option "${config}" 'output')
        SENDSPIN_LOG_LEVEL=$(sendspin::option "${config}" 'log_level')
        SENDSPIN_SERVER=$(sendspin::option "${config}" 'server')
        SENDSPIN_BUFFER_MS=$(sendspin::option "${config}" 'buffer_ms')
        # A JSON false reads as empty here, which is the same as unset.
        SENDSPIN_ALLOW_UNPAIRED=$(sendspin::option "${config}" 'allow_unpaired')
        SENDSPIN_HOOK_START=$(sendspin::option "${config}" 'hook_start')
        SENDSPIN_HOOK_STOP=$(sendspin::option "${config}" 'hook_stop')
        # Not through sendspin::option: jq's `//` takes false for missing too,
        # which would turn an explicit off back into the default of on.
        SENDSPIN_LOCAL_PAIRING=$(jq -r 'if .local_pairing == null then true else .local_pairing end' \
            <<< "${config}")
        SENDSPIN_LOCAL_PAIRING_PORT=$(sendspin::option "${config}" 'local_pairing_port')
        # Not an add-on option: only the smoke suite sets it, because its
        # containers have no hassio bridge to bind to.
        : "${SENDSPIN_LOCAL_PAIRING_ADDRESS:=${HASSIO_ADDRESS}}"

        # The dropdown's words, in the player's terms. A bare `pulse` names no
        # source, so libpulse captures from the client.conf default-source the
        # Audio panel sets; a named one can be a source or a sink, whose monitor
        # is then what is captured. The run script checks either one first.
        case $(sendspin::option "${config}" 'input') in
            audio_panel) SENDSPIN_INPUT=pulse ;;
            named_source) SENDSPIN_INPUT="pulse:$(sendspin::option "${config}" 'input_source')" ;;
            test_tone) SENDSPIN_INPUT=tone ;;
            *) SENDSPIN_INPUT='' ;;
        esac
        SENDSPIN_INPUT_CARD_PROFILE=$(sendspin::option "${config}" 'input_card_profile')

        # Home Assistant's audio is always a PulseAudio server, so the add-on
        # talks to it natively. `default` reaches the same server through ALSA's
        # pulse plugin, whose poll pipe can be left full with nothing to drain it,
        # spinning a core until the add-on restarts (#37). A bare `pulse` names no
        # sink, so libpulse still plays to the client.conf default-sink the Audio
        # panel sets.
        : "${SENDSPIN_OUTPUT:=pulse}"
    fi

    # A fixed name rather than the host's: `homeassistant` said nothing about
    # what the player is, and reading it cost the host's UTS namespace.
    : "${SENDSPIN_NAME:=Local Audio}"
    : "${SENDSPIN_OUTPUT:=default}"
    : "${SENDSPIN_LOG_LEVEL:=info}"
    SENDSPIN_SERVER="${SENDSPIN_SERVER:-}"

    # Left empty rather than given a default, because the run script writes only
    # the keys that have a value: an unset one is then absent from the rendered
    # config and upstream's own default stands. A number written here would be
    # this repo's to keep in step with upstream's for good.
    SENDSPIN_BUFFER_MS="${SENDSPIN_BUFFER_MS:-}"

    # Left empty for the same reason: the run script writes `port` only when it has a
    # value, so the player's own default (8928) stands. Not an add-on option: the app
    # shares the host's network with a fixed port, and the add-on's schema has no field
    # for it.
    SENDSPIN_PORT="${SENDSPIN_PORT:-}"

    # Read from the environment in both branches because it is not an add-on
    # option. A pinned `audio-format` the output cannot advertise refuses to
    # start the player, and the add-on plays through Home Assistant's
    # PulseAudio, which converts -- there is no DAC behind it to hold at one
    # shape.
    SENDSPIN_AUDIO_FORMAT="${SENDSPIN_AUDIO_FORMAT:-}"

    SENDSPIN_ALLOW_UNPAIRED="${SENDSPIN_ALLOW_UNPAIRED:-}"
    SENDSPIN_INPUT="${SENDSPIN_INPUT:-}"
    # Add-on only: switching a card changes it for every app on the host, which
    # is not a container's to do to a desktop it shares.
    SENDSPIN_INPUT_CARD_PROFILE="${SENDSPIN_INPUT_CARD_PROFILE:-}"

    # Not add-on options, like SENDSPIN_AUDIO_FORMAT: all four act on an ALSA
    # output only, and the add-on always plays through PulseAudio.
    SENDSPIN_KEEP_OUTPUT_ALIVE="${SENDSPIN_KEEP_OUTPUT_ALIVE:-}"
    SENDSPIN_RELEASE_DEVICE="${SENDSPIN_RELEASE_DEVICE:-}"
    SENDSPIN_ALSA_MIXER="${SENDSPIN_ALSA_MIXER:-}"
    SENDSPIN_ALSA_MIXER_CURVE="${SENDSPIN_ALSA_MIXER_CURVE:-}"

    # Empty rather than defaulted, like the three above: the run script writes
    # only the keys that have a value, so a hook nobody set is absent from the
    # rendered config rather than sitting in it as a key with nothing after it.
    # There is no default a hook could sensibly have.
    SENDSPIN_HOOK_START="${SENDSPIN_HOOK_START:-}"
    SENDSPIN_HOOK_STOP="${SENDSPIN_HOOK_STOP:-}"

    # Off outside the add-on: a plain container has no address that only Music
    # Assistant's host can reach, so whoever turns it on has to name one.
    : "${SENDSPIN_LOCAL_PAIRING:=false}"
    SENDSPIN_LOCAL_PAIRING_ADDRESS="${SENDSPIN_LOCAL_PAIRING_ADDRESS:-}"
    : "${SENDSPIN_LOCAL_PAIRING_PORT:=${LOCAL_PAIRING_DEFAULT_PORT}}"

    # A newline in a value would add config keys of the caller's choosing, and
    # an injected `server` turns the mDNS advertisement off without saying so.
    #
    # The two hooks are in here for that reason and that reason only. Their
    # values are shell commands by design, so there is nothing to sanitise
    # within a line: whoever may set an option may already run what they like.
    for name in SENDSPIN_NAME SENDSPIN_OUTPUT SENDSPIN_LOG_LEVEL SENDSPIN_SERVER \
        SENDSPIN_BUFFER_MS SENDSPIN_PORT SENDSPIN_AUDIO_FORMAT SENDSPIN_ALLOW_UNPAIRED SENDSPIN_INPUT \
        SENDSPIN_INPUT_CARD_PROFILE SENDSPIN_HOOK_START SENDSPIN_HOOK_STOP SENDSPIN_LOCAL_PAIRING \
        SENDSPIN_LOCAL_PAIRING_ADDRESS SENDSPIN_LOCAL_PAIRING_PORT \
        SENDSPIN_KEEP_OUTPUT_ALIVE SENDSPIN_RELEASE_DEVICE SENDSPIN_ALSA_MIXER \
        SENDSPIN_ALSA_MIXER_CURVE; do
        value="${!name}"
        if [ "${value}" != "${value%%$'\n'*}" ]; then
            sendspin::log "${name} contains a newline, which would inject configuration keys."
            exit 1
        fi
    done

    # The same range as the add-on's `buffer_ms` schema in local_audio/config.yaml,
    # which both have to be moved together. That schema refuses a bad value before
    # it can reach here at all, so this is Compose's copy of a check the add-on
    # already has -- and it is why the message names the environment variable:
    # everyone who ever sees it really did set one. Left unchecked, the value
    # renders into the config and comes back as an upstream parse error on a
    # container that restarts into the same one.
    #
    # More than four digits is out of range whatever it reads, and is rejected
    # before the arithmetic rather than by it: `[ -gt ]` on a value past 64 bits
    # wraps silently, so 2^64 + 100 would otherwise be accepted as 100. `10#`
    # for the neighbouring trap, a leading zero read as octal.
    if [ -n "${SENDSPIN_BUFFER_MS}" ]; then
        case ${SENDSPIN_BUFFER_MS} in
            *[!0-9]*)
                sendspin::log "SENDSPIN_BUFFER_MS is \"${SENDSPIN_BUFFER_MS}\", which is not a whole number of milliseconds."
                exit 1
                ;;
        esac
        if [ "${#SENDSPIN_BUFFER_MS}" -gt 4 ] \
            || [ "$((10#${SENDSPIN_BUFFER_MS}))" -lt 10 ] \
            || [ "$((10#${SENDSPIN_BUFFER_MS}))" -gt 2000 ]; then
            sendspin::log "SENDSPIN_BUFFER_MS is ${SENDSPIN_BUFFER_MS}, outside the 10 to 2000 milliseconds the player accepts."
            exit 1
        fi
    fi

    # Upstream takes exactly these two spellings; the add-on's schema already does.
    case ${SENDSPIN_ALLOW_UNPAIRED} in
        '' | true | false) ;;
        *)
            sendspin::log "SENDSPIN_ALLOW_UNPAIRED is \"${SENDSPIN_ALLOW_UNPAIRED}\", which is neither true nor false."
            exit 1
            ;;
    esac

    # Upstream's range, checked here for the same reason as the buffer above.
    if [ -n "${SENDSPIN_KEEP_OUTPUT_ALIVE}" ]; then
        case ${SENDSPIN_KEEP_OUTPUT_ALIVE} in
            *[!0-9]*)
                sendspin::log "SENDSPIN_KEEP_OUTPUT_ALIVE is \"${SENDSPIN_KEEP_OUTPUT_ALIVE}\", which is not a whole number of seconds."
                exit 1
                ;;
        esac
        if [ "${#SENDSPIN_KEEP_OUTPUT_ALIVE}" -gt 4 ] \
            || [ "$((10#${SENDSPIN_KEEP_OUTPUT_ALIVE}))" -gt 3600 ]; then
            sendspin::log "SENDSPIN_KEEP_OUTPUT_ALIVE is ${SENDSPIN_KEEP_OUTPUT_ALIVE}, outside the 0 to 3600 seconds the player accepts."
            exit 1
        fi
    fi

    case ${SENDSPIN_RELEASE_DEVICE} in
        '' | true | false) ;;
        *)
            sendspin::log "SENDSPIN_RELEASE_DEVICE is \"${SENDSPIN_RELEASE_DEVICE}\", which is neither true nor false."
            exit 1
            ;;
    esac

    # SENDSPIN_ALSA_MIXER itself is left to upstream, which refuses it without an
    # ALSA output and says so in terms of the output it was given.
    case ${SENDSPIN_ALSA_MIXER_CURVE} in
        '' | spec | cubic) ;;
        *)
            sendspin::log "SENDSPIN_ALSA_MIXER_CURVE is \"${SENDSPIN_ALSA_MIXER_CURVE}\", which is neither spec nor cubic."
            exit 1
            ;;
    esac

    case ${SENDSPIN_LOCAL_PAIRING} in
        true | false) ;;
        *)
            sendspin::log "SENDSPIN_LOCAL_PAIRING is \"${SENDSPIN_LOCAL_PAIRING}\", which is neither true nor false."
            exit 1
            ;;
    esac

    # The same range as the add-on's `local_pairing_port` schema. The player
    # refuses a port below 1024, which Music Assistant would never fetch from;
    # the length test is the same 64-bit wrap guard as the buffer check above.
    case ${SENDSPIN_LOCAL_PAIRING_PORT} in
        '' | *[!0-9]*)
            sendspin::log "SENDSPIN_LOCAL_PAIRING_PORT is \"${SENDSPIN_LOCAL_PAIRING_PORT}\", which is not a port number."
            exit 1
            ;;
    esac
    if [ "${#SENDSPIN_LOCAL_PAIRING_PORT}" -gt 5 ] \
        || [ "$((10#${SENDSPIN_LOCAL_PAIRING_PORT}))" -lt 1024 ] \
        || [ "$((10#${SENDSPIN_LOCAL_PAIRING_PORT}))" -gt 65535 ]; then
        sendspin::log "SENDSPIN_LOCAL_PAIRING_PORT is ${SENDSPIN_LOCAL_PAIRING_PORT}, outside 1024 to 65535."
        exit 1
    fi

    # The player's own port: the same shape and range as the pairing port above, for the
    # same reasons (the 64-bit wrap guard, `10#` against a leading zero read as octal).
    # Below 1024 only root may listen, and this image does not always run as root.
    if [ -n "${SENDSPIN_PORT}" ]; then
        case ${SENDSPIN_PORT} in
            *[!0-9]*)
                sendspin::log "SENDSPIN_PORT is \"${SENDSPIN_PORT}\", which is not a port number."
                exit 1
                ;;
        esac
        if [ "${#SENDSPIN_PORT}" -gt 5 ] \
            || [ "$((10#${SENDSPIN_PORT}))" -lt 1024 ] \
            || [ "$((10#${SENDSPIN_PORT}))" -gt 65535 ]; then
            sendspin::log "SENDSPIN_PORT is ${SENDSPIN_PORT}, outside 1024 to 65535."
            exit 1
        fi

        # Two listeners cannot share a port: the pairing token endpoint is served on its own.
        if [ "${SENDSPIN_LOCAL_PAIRING}" = true ] \
            && [ "$((10#${SENDSPIN_PORT}))" -eq "$((10#${SENDSPIN_LOCAL_PAIRING_PORT}))" ]; then
            sendspin::log "SENDSPIN_PORT and SENDSPIN_LOCAL_PAIRING_PORT are both ${SENDSPIN_PORT}, but they are two listeners."
            exit 1
        fi
    fi

    if [ "${SENDSPIN_LOCAL_PAIRING}" = true ] && [ -z "${SENDSPIN_LOCAL_PAIRING_ADDRESS}" ]; then
        sendspin::log 'SENDSPIN_LOCAL_PAIRING is true but SENDSPIN_LOCAL_PAIRING_ADDRESS is empty: name the one address Music Assistant fetches the pairing token from.'
        exit 1
    fi
}

# Whether $1 is an IPv4 address of this network namespace. The add-on shares
# the host's, so this is how it tells a Home Assistant OS host, which has the
# hassio bridge, from one that does not.
sendspin::has_local_address() {
    awk -v want="$1" '
        /\|--/ { address = $2 }
        /\/32 host LOCAL/ && address == want { found = 1 }
        END { exit !found }
    ' /proc/net/fib_trie
}

# The `pairing-token-endpoint` value, or nothing when local pairing stays off.
# The hassio address missing is a host without the bridge, not a mistake, so it
# turns the endpoint off with a line instead of a player that cannot start; an
# address named outright is passed on, and the player refuses one it cannot
# bind.
sendspin::local_pairing_endpoint() {
    local address=${SENDSPIN_LOCAL_PAIRING_ADDRESS}

    [ "${SENDSPIN_LOCAL_PAIRING}" = true ] || return 0

    if [ "${address}" = "${HASSIO_ADDRESS}" ] && ! sendspin::has_local_address "${address}"; then
        sendspin::log "Local pairing is off: ${address} is not an address of this host, so there is no Home Assistant OS network to serve the pairing token on."
        return 0
    fi

    case ${address} in
        *:*) address="[${address}]" ;;
    esac
    printf '%s:%s\n' "${address}" "$((10#${SENDSPIN_LOCAL_PAIRING_PORT}))"
}

# Upstream refuses `id =` now that identity is the keypair in the state dir, but
# an old Compose file setting SENDSPIN_ID is no reason not to start.
sendspin::warn_if_id_is_set() {
    [ -n "${SENDSPIN_ID:-}" ] || return 0
    sendspin::log 'SENDSPIN_ID is ignored: the player now identifies itself by the keypair in /data/state, so give each player its own /data volume instead.'
}

# The mount point $1 lives on: the longest mountinfo target that is $1 or one
# of its parents. Read from mountinfo rather than with `mountpoint`, which has
# to stat the target and is refused on a socket file bind-mounted from another
# SELinux context. mountinfo lists targets with symlinks resolved, so /var/run
# is compared as /run.
sendspin::mount_point_of() {
    local target
    target=$(readlink -m "$1")
    awk -v want="${target}" '
        $5 == want || $5 == "/" || index(want, $5 "/") == 1 {
            if (length($5) > length(best)) best = $5
        }
        END { print best }
    ' /proc/self/mountinfo
}

# The host's bus only ever reaches the container through a mount: of its
# directory, of the socket alone, or of a parent such as /run. A socket on the
# container's own root filesystem is one our bundled dbus left in the writable
# layer before a `docker stop`, and `docker start` reuses that layer; read as
# the host's, it would keep the daemons down and the player unadvertised.
sendspin::clear_stale_bus_socket() {
    [ -S "${SYSTEM_BUS_SOCKET}" ] || return 0
    [ "$(sendspin::mount_point_of "${SYSTEM_BUS_SOCKET}")" = / ] || return 0

    rm -f "${SYSTEM_BUS_SOCKET}" "${SYSTEM_BUS_DIR}/pid"
    sendspin::log "Cleared the D-Bus socket left at ${SYSTEM_BUS_SOCKET} by this container's previous run: no host bus is mounted there."
}

# Whether this container runs its own dbus and avahi-daemon, recorded once by
# the sendspin-init oneshot before any of them start. The answer comes from
# configuration alone: a runtime reachability probe is not used because both of
# its wrong answers are silent, giving either two responders competing on port
# 5353 or a player that runs but is never discovered.
sendspin::decide_daemons() {
    sendspin::read_options

    mkdir -p "${SENDSPIN_RUN_DIR}"

    sendspin::clear_stale_bus_socket

    if [ -S "${SYSTEM_BUS_SOCKET}" ]; then
        printf 'no\n' > "${SENDSPIN_DAEMON_DECISION}"
        sendspin::log "Host D-Bus socket present at ${SYSTEM_BUS_SOCKET}: advertising through the host's Avahi, the bundled dbus and avahi-daemon stay down."
    elif [ -n "${SENDSPIN_SERVER}" ] && ! sendspin::server_is_mdns "${SENDSPIN_SERVER}"; then
        printf 'no\n' > "${SENDSPIN_DAEMON_DECISION}"
        sendspin::log 'A fixed server is configured, which suppresses the mDNS advertisement: the bundled dbus and avahi-daemon stay down.'
    elif [ -n "${SENDSPIN_SERVER}" ]; then
        printf 'yes\n' > "${SENDSPIN_DAEMON_DECISION}"
        sendspin::log 'Starting the bundled dbus and avahi-daemon: the mdns: server value needs mDNS to resolve the server.'
    else
        printf 'yes\n' > "${SENDSPIN_DAEMON_DECISION}"
        sendspin::log 'Starting the bundled dbus and avahi-daemon to advertise this player over mDNS.'
    fi
}

# The decision the oneshot recorded, as `yes` or `no`. Callers assign it to a
# variable rather than testing this in a condition, because errexit is
# suspended inside a condition and an absent file -- the oneshot never
# finished -- would then read as a quiet "no".
sendspin::daemon_decision() {
    cat "${SENDSPIN_DAEMON_DECISION}"
}

# s6-rc guarantees only that a dependency has been started, not that it is
# listening. The D-Bus wait is load-bearing: avahi-daemon exits without a bus
# and would be restarted until it won the race. The Avahi wait is not, since
# the player retries its registration anyway; it is there to keep a failed
# first attempt out of the log. Avahi is reached over D-Bus, so its socket is
# a stand-in for "avahi finished starting" rather than the player's own path
# to it. Either wait running out is survivable, so both return 0.
sendspin::wait_for_socket() {
    local i

    for ((i = 0; i < 100; i++)); do
        if [ -S "$1" ]; then
            break
        fi
        sleep 0.1
    done

    return 0
}

# An unset option reads as an empty string. bashio::config is not used for the
# read because it cannot tell the JSON null of an unset option from the string
# "null", which is a valid value for output.
sendspin::option() {
    jq -r --arg key "$2" '.[$key] // empty' <<< "$1"
}

# `pulse` and `pipewire` are reserved backend names in upstream's -o grammar, and
# this image builds both of those backends -- so either name selects the native
# backend. A value written for 0.1.9 or earlier meant ALSA's plugin PCM of the
# same name, which bridges to the same server by a different route. One line at
# start rather than only in the release notes, because the value is still
# accepted, still reaches the same server, and the change is otherwise invisible.
#
# The value is passed through untouched. Rewriting it to `alsa:pulse` would keep
# every existing user on the legacy route for good and hide the change instead of
# reporting it.
#
# This earns its place only while an upgrade from 0.1.9 is a thing that happens.
# Once the 0.1.x line is behind us it is a note about a name that is simply
# correct, and should go.
sendspin::warn_if_output_changed_meaning() {
    local server

    # The add-on picks `pulse` itself; nobody there wrote the name to be told
    # it changed meaning.
    [ -z "${SUPERVISOR_TOKEN:-}" ] || return 0

    case ${SENDSPIN_OUTPUT} in
        pulse) server=PulseAudio ;;
        pipewire) server=PipeWire ;;
        *) return 0 ;;
    esac

    sendspin::log "The output ${SENDSPIN_OUTPUT} now selects this player's native ${server} backend rather than ALSA's ${SENDSPIN_OUTPUT} plugin PCM, which it used to mean; alsa:${SENDSPIN_OUTPUT} is that previous behaviour."
}

# The mdns: prefix is reserved before the first colon in upstream's -s grammar;
# everything else is a host, host:port or ws URL.
sendspin::server_is_mdns() {
    [ "${1#mdns:}" != "$1" ]
}

# A server value may carry userinfo, and the connection-mode line is the first
# thing that gets pasted into a support issue.
sendspin::redact_server() {
    printf '%s\n' "$1" | sed -e 's|://[^/@]*@|://|' -e 's|^[^:/@]*:[^/@]*@||'
}

# ==============================================================================
# The silent-output check
#
# The player applies Music Assistant's volume as software gain and opens no
# mixer, and module-device-restore makes a sink level outlive a reboot. So a
# sink another add-on left at zero, or routed at a port with nothing plugged
# into it, is silence at every slider position with nothing able to say so.
# Reported, never corrected: the level and the port are the Audio panel's, and
# writing either would override a deliberate choice on every start.
# ==============================================================================

# Bounded, so a PulseAudio that is up but not answering costs three seconds
# rather than the oneshot's whole 30s timeout-up. LC_ALL=C because pactl's
# output is translated, and the keys parsed below with it.
sendspin::pactl() {
    LC_ALL=C PULSE_SERVER="unix:${PULSE_SOCKET}" timeout 3 pactl "$@" 2> /dev/null
}

# A key from a client.conf on stdin. The Supervisor renders that file per add-on
# from the Audio panel selection, so `default-sink` and `default-source` are the
# devices the user picked. Last assignment wins, as it does for PulseAudio itself.
sendspin::pulse_conf_value() {
    awk -v key="$1" '
        /^[[:space:]]*[;#]/ { next }
        $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
            sub(/^[^=]*=[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            value = $0
        }
        END { if (value != "") print value }
    '
}

sendspin::pulse_conf_default_sink() {
    sendspin::pulse_conf_value default-sink
}

sendspin::pulse_conf_default_source() {
    sendspin::pulse_conf_value default-source
}

# The daemon's default sink, from `pactl info` on stdin. Only a fallback: the
# ALSA pulse plugin connects with a NULL device and libpulse then substitutes
# the *client* default, so client.conf wins whenever it carries one.
sendspin::pulse_info_default_sink() {
    sed -n 's/^Default Sink:[[:space:]]*//p' | tail -n 1
}

# The daemon's default source, from `pactl info` on stdin. As with the sink, only
# a fallback for a client.conf that names none.
sendspin::pulse_info_default_source() {
    sed -n 's/^Default Source:[[:space:]]*//p' | tail -n 1
}

# Every sink name in `pactl list sinks` on stdin, one per line.
sendspin::pulse_sink_names() {
    awk '
        /^\tName:/ {
            sub(/^[^:]*:[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            print
        }
    '
}

# Index, name, description, mute, level, and then the active port's id,
# description and availability for the sink named "$1", one field per line, from
# `pactl list sinks` on stdin. Prints nothing unless the first five parsed, so a
# pactl whose format has moved reads as "no answer" rather than as a healthy
# sink.
#
# The port fields sit outside that guard: a sink with no `Ports:` block is
# legitimate, and folding them in would turn the mute and level warning off for
# every sink like it. They come back empty, which the caller reads as unknown.
sendspin::pulse_sink_state() {
    awk -v target="$1" '
        function value(line) {
            sub(/^[^:]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            return line
        }

        # The loudest channel decides: a sink is silent only when every channel
        # of it is, and one quiet channel is a balance setting. Empty means no
        # percentage was there to read.
        function loudest(line,   best, pct) {
            best = ""
            while (match(line, /[0-9]+%/)) {
                pct = substr(line, RSTART, RLENGTH - 1) + 0
                if (best == "" || pct > best) best = pct
                line = substr(line, RSTART + RLENGTH)
            }
            return best
        }

        # The last one, so a description carrying brackets of its own --
        # `Headphones (unplugged)` -- keeps them.
        function last_bracket(s,   i, at) {
            at = 0
            for (i = 1; i <= length(s); i++)
                if (substr(s, i, 1) == "(") at = i
            return at
        }

        # `\t\t<id>: <description> (<...>, <availability>)`. The availability
        # closes the bracket whether or not `type:` and `availability group:`
        # are in front of it, so the last comma-separated part fits both shapes.
        function port_line(line,   at, id, rest, bracket, n, part) {
            sub(/^\t\t/, "", line)
            sub(/[[:space:]]+$/, "", line)
            at = index(line, ":")
            if (at == 0) return
            id = substr(line, 1, at - 1)
            rest = substr(line, at + 1)
            sub(/^[[:space:]]+/, "", rest)

            port_description[block, id] = rest
            port_availability[block, id] = ""

            if (rest !~ /\)$/) return
            at = last_bracket(rest)
            if (at == 0) return

            bracket = substr(rest, at + 1, length(rest) - at - 1)
            rest = substr(rest, 1, at - 1)
            sub(/[[:space:]]+$/, "", rest)
            n = split(bracket, part, ",")
            sub(/^[[:space:]]+/, "", part[n])
            sub(/[[:space:]]+$/, "", part[n])

            port_description[block, id] = rest
            port_availability[block, id] = part[n]
        }

        function emit(   description, availability) {
            if (done || name != target \
                || idx == "" || sink_description == "" || mute == "" || level == "")
                return
            description = ""
            availability = ""
            if (port != "") {
                description = port_description[block, port]
                availability = port_availability[block, port]
            }
            print idx; print name; print sink_description; print mute; print level
            print port; print description; print availability
            done = 1
        }

        /^Sink #/ {
            emit()
            # Keyed per sink rather than cleared: whole-array `delete` is not
            # in every awk this may meet.
            block++
            idx = ""; name = ""; sink_description = ""; mute = ""; level = ""
            port = ""; in_ports = 0
            if (match($0, /[0-9]+/)) idx = substr($0, RSTART, RLENGTH)
            next
        }
        # `Properties:` and `Formats:` are indented the same as port lines, so
        # only the block a line sits in keeps them apart.
        /^\tPorts:/  { in_ports = 1; next }
        /^\t[^\t]/   { in_ports = 0 }
        # One tab exactly: properties and ports are indented further, and
        # `Base Volume:` -- the hardware reference level -- does not start its
        # key at the tab.
        /^\tName:/        { name = value($0); next }
        /^\tDescription:/ { sink_description = value($0); next }
        /^\tMute:/        { mute = value($0); next }
        /^\tVolume:/      { level = loudest($0); next }
        /^\tActive Port:/ { port = value($0); next }

        in_ports && /^\t\t[^\t]/ { port_line($0); next }

        END { emit() }
    '
}

# Says nothing for an audible sink: naming a healthy one is report_output's job.
# Kept apart from the reading above so that scripts/pactl_parse_test.sh can
# exercise both.
sendspin::warn_if_sink_is_silent() {
    local idx=$1 name=$2 description=$3 mute=$4 level=$5
    local state

    case ${level} in
        '' | *[!0-9]*) return 0 ;;
    esac

    if [ "${mute}" = yes ] && [ "${level}" -eq 0 ]; then
        state='muted and turned down to zero'
    elif [ "${mute}" = yes ]; then
        state='muted'
    elif [ "${level}" -eq 0 ]; then
        state='turned down to zero'
    else
        return 0
    fi

    sendspin::log "The Home Assistant audio output this player plays through is ${state}, so nothing it plays will be heard."
    sendspin::log "That output is sink #${idx}, ${name} (${description})."
    sendspin::log 'Music Assistant volume cannot raise it: that is applied to the audio this player sends, not to the output it sends to.'
    sendspin::log 'Raise it from the Home Assistant host console, or a terminal add-on:'
    sendspin::log "    ha audio volume output --index ${idx} --unmute"
    sendspin::log "    ha audio volume output --index ${idx} --volume 85"
    sendspin::log 'The level is shared with every other add-on on this machine, which is why this one will not set it for you.'
}

# Only the literal `not available` may warn. `availability unknown` is what a
# card with no jack detection reports for every port it has -- most line-outs --
# and warning about a working one would be worse than the silence this explains.
sendspin::warn_if_port_is_unavailable() {
    local idx=$1 name=$2 port=$3 description=$4 availability=$5
    local port_text

    [ "${availability}" = 'not available' ] || return 0

    port_text="${port}"
    if [ -n "${description}" ]; then
        port_text="${description} (${port})"
    fi

    sendspin::log "The Home Assistant audio output this player plays through is routed to a socket with nothing plugged into it, so nothing it plays will be heard."
    sendspin::log "That output is sink #${idx}, ${name}, and it is playing out of ${port_text}, which PulseAudio reports as not available."
    sendspin::log 'Music Assistant volume cannot fix it: the audio is reaching an empty socket whatever the level is set to.'
    sendspin::log 'Plug into that socket, or pick an output that is plugged in from the Home Assistant Audio panel.'
    sendspin::log 'The routing is shared with every other add-on on this machine, which is why this one will not change it for you.'
}

# One line at every start, healthy or not: a silent healthy start is why the
# report this was written from had nothing in the log to go on.
sendspin::report_output() {
    local idx=$1 name=$2 description=$3 level=$4 port=$5 port_description=$6
    local out

    out="Playing through sink #${idx}, ${name} (${description}), at ${level}%"
    if [ -n "${port_description}" ] && [ -n "${port}" ]; then
        out="${out}, out of ${port_description} (${port})"
    elif [ -n "${port}" ]; then
        out="${out}, out of ${port}"
    fi
    sendspin::log "${out}."
}

# Everything the check has to say about a sink list. Split from the pactl calls
# that fetch it so scripts/pactl_parse_test.sh can put a fixture through it.
sendspin::report_on_sinks() {
    local target=$1 sinks=$2
    local state name
    local -a field names

    if [ -z "${sinks}" ]; then
        sendspin::log 'PulseAudio lists no audio outputs at all, so nothing this player plays will be heard.'
        sendspin::log 'Check that the Home Assistant host has a sound card, and that an output is selected in its Audio panel.'
        return 0
    fi

    [ -n "${target}" ] || return 0

    state=$(sendspin::pulse_sink_state "${target}" <<< "${sinks}") || return 0
    if [ -z "${state}" ]; then
        mapfile -t names < <(sendspin::pulse_sink_names <<< "${sinks}")

        # The sink being in the list means pactl's format could not be read,
        # not that the Audio panel selection was wrong.
        for name in "${names[@]}"; do
            if [ "${name}" = "${target}" ]; then
                sendspin::log "The Home Assistant audio output this player plays through, ${target}, is listed by PulseAudio but could not be read."
                sendspin::log 'That is this add-on failing to parse pactl, not a fault with the output, and it means nothing here can say whether the output is audible.'
                return 0
            fi
        done

        sendspin::log "The Home Assistant audio output this player is set to play through, ${target}, is not among the outputs PulseAudio lists."
        sendspin::log 'PulseAudio falls back to its own default when that happens, so the audio is going to some other device, or to nowhere.'
        if [ "${#names[@]}" -gt 0 ]; then
            sendspin::log 'The outputs it does list are:'
            for name in "${names[@]}"; do
                sendspin::log "    ${name}"
            done
            sendspin::log 'Pick one of them for this player in the Home Assistant Audio panel.'
        fi
        return 0
    fi

    # Command substitution strips trailing newlines, so empty port fields arrive
    # as missing elements rather than as eight.
    mapfile -t field <<< "${state}"
    [ "${#field[@]}" -ge 5 ] && [ "${#field[@]}" -le 8 ] || return 0

    sendspin::report_output "${field[0]}" "${field[1]}" "${field[2]}" "${field[4]}" \
        "${field[5]:-}" "${field[6]:-}"
    sendspin::warn_if_sink_is_silent \
        "${field[0]}" "${field[1]}" "${field[2]}" "${field[3]}" "${field[4]}"
    sendspin::warn_if_port_is_unavailable \
        "${field[0]}" "${field[1]}" "${field[5]:-}" "${field[6]:-}" "${field[7]:-}"
}

# Advisory, so every path here returns success: the oneshot runs under
# `set -euo pipefail`, and a PulseAudio that cannot be reached must be a shrug
# rather than a container that never starts.
sendspin::check_output_is_audible() {
    local sinks info target

    # Compose has no PulseAudio at all, so there is no sink to have an opinion
    # about. Saying nothing is the whole behaviour here, not a fallback.
    [ -S "${PULSE_SOCKET}" ] || return 0

    sinks=$(sendspin::pactl list sinks) || return 0

    target=''
    if [ -r "${PULSE_CLIENT_CONF}" ]; then
        target=$(sendspin::pulse_conf_default_sink < "${PULSE_CLIENT_CONF}") || return 0
    fi
    if [ -z "${target}" ] && [ -n "${sinks}" ]; then
        info=$(sendspin::pactl info) || return 0
        target=$(sendspin::pulse_info_default_sink <<< "${info}") || return 0
    fi

    sendspin::report_on_sinks "${target}" "${sinks}"
}

# ==============================================================================
# The add-on's PulseAudio input.
#
# Capturing the sink this player plays to sends Music Assistant its own audio
# back, and playing that input here would feed back on itself. The player opens
# such a source without complaint. A name PulseAudio does not list stops the player
# at startup instead. Neither is worth losing playback over, so both leave the
# player running with no input and say why.
# ==============================================================================

# Why this source or sink cannot be streamed, or nothing if it can. $2 and $3 are
# `pactl list short sources` and `sinks`, whose second column is the name, and $4
# is the sink this player plays to. Another sink's monitor is a fair choice: that
# is how the output of another app, or of a Bluetooth device, gets captured.
sendspin::input_refusal() {
    local name=$1 sources=$2 sinks=$3 own_sink=$4

    if [ -z "${name}" ]; then
        printf '%s\n' 'no input is named'
        return 0
    fi

    if [ "${name}" = "${own_sink}" ] || [ "${name}" = "${own_sink}.monitor" ]; then
        printf '%s\n' "${name} is the output this player plays to, which would send Music Assistant its own audio"
        return 0
    fi

    if ! awk -F '\t' -v name="${name}" '$2 == name { found = 1 } END { exit !found }' \
        <<< "${sources}"$'\n'"${sinks}"; then
        printf '%s\n' "${name} is not among the sources and sinks PulseAudio lists"
    fi
}

# The names in `pactl list short` output on stdin, on one line.
sendspin::pulse_short_names() {
    awk -F '\t' 'NF > 1 { printf "%s%s", separator, $2; separator = ", " } END { print "" }'
}

# Why the player should not capture the add-on input $1, or nothing when it may.
# The rest is what PulseAudio said: `pactl list short sources`, `... sinks`,
# `pactl info`, and the client.conf text, empty when there is none. Kept apart
# from the pactl calls so the decision can be tested on canned output.
#
# A bare `pulse` is the Audio panel's input, where a monitor is never a choice
# the user made: the panel offers none, so it can only be PulseAudio's fallback
# for a machine with no input.
sendspin::app_input_refusal() {
    local input=$1 sources=$2 sinks=$3 info=$4 conf=$5
    local name=${input#pulse} own_sink panel

    name=${name#:}
    own_sink=$(sendspin::pulse_conf_default_sink <<< "${conf}")
    panel=$(sendspin::pulse_conf_default_source <<< "${conf}")
    : "${own_sink:=$(sendspin::pulse_info_default_sink <<< "${info}")}"

    if [ "${input}" = pulse ]; then
        name=${panel:-$(sendspin::pulse_info_default_source <<< "${info}")}
        if [ "${name}" != "${name%.monitor}" ]; then
            printf '%s\n' 'this machine has no audio input to use'
            return 0
        fi
    fi

    sendspin::input_refusal "${name}" "${sources}" "${sinks}" "${own_sink}"
}

# Whether the player should capture SENDSPIN_INPUT, saying why not. Bounded by
# sendspin::pactl, and a PulseAudio that cannot answer reads as no.
sendspin::app_input_is_usable() {
    local sources='' sinks='' info='' conf=''
    local reason='Home Assistant audio could not be asked'

    if [ -S "${PULSE_SOCKET}" ] && sources=$(sendspin::pactl list short sources) \
        && sinks=$(sendspin::pactl list short sinks) && info=$(sendspin::pactl info); then
        if [ -r "${PULSE_CLIENT_CONF}" ]; then
            conf=$(< "${PULSE_CLIENT_CONF}")
        fi
        reason=$(sendspin::app_input_refusal "${SENDSPIN_INPUT}" "${sources}" "${sinks}" \
            "${info}" "${conf}")
    fi

    if [ -n "${reason}" ]; then
        sendspin::log "The audio input is not available: ${reason}, so this player is not offering an input."
        if [ -n "${sources}${sinks}" ]; then
            sendspin::log "PulseAudio lists these sources and sinks: $(sendspin::pulse_short_names <<< "${sources}"$'\n'"${sinks}")"
        fi
        return 1
    fi
}

# ==============================================================================
# The input card profile.
#
# With nothing plugged into a line-in or mic, its ports lose their priority and
# the card starts on an output-only profile with no source at all. A duplex
# profile stays available while its output works, and once active an unplug only
# marks the source's port not available. PulseAudio switches to any profile it is
# asked for, including one that is not available or that drops the sink, so the
# guarding is ours. Never sticky: that would stop automatic switching, headphones
# included, for every app on the host.
# ==============================================================================

# From `pactl list cards` on stdin, the card named $1 as tab-separated lines:
# `active <profile>`, then `profile <name> <sinks> <sources> <available>` per
# profile. Prints nothing when that card is not listed.
sendspin::pulse_card_profiles() {
    awk -v target="$1" '
        function value(line) {
            sub(/^[^:]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            return line
        }

        /^Card #/ { in_card = 0; section = ""; next }
        /^\tName:/ { in_card = (value($0) == target); next }
        !in_card { next }

        /^\t[^\t]/ {
            section = $0
            sub(/^\t/, "", section)
            sub(/:.*/, "", section)
            if (section == "Active Profile") print "active\t" value($0)
            next
        }

        # Profile names carry colons of their own, but never one followed by a
        # space. The counts are in the last bracket, as a description can have
        # brackets too.
        section == "Profiles" && /^\t\t[^\t]/ {
            line = $0
            sub(/^\t\t/, "", line)
            at = index(line, ": ")
            if (!at) next
            name = substr(line, 1, at - 1)
            stats = line
            while ((at = index(stats, "(")) > 0) stats = substr(stats, at + 1)
            sinks = sources = available = ""
            if (match(stats, /sinks: [0-9]+/)) sinks = substr(stats, RSTART + 7, RLENGTH - 7)
            if (match(stats, /sources: [0-9]+/)) sources = substr(stats, RSTART + 9, RLENGTH - 9)
            if (match(stats, /available: [a-z]+/)) available = substr(stats, RSTART + 11, RLENGTH - 11)
            print "profile\t" name "\t" sinks "\t" sources "\t" available
        }
    '
}

# The `output:` (or, with $1 = input, `input:`) half of the mixer profile name
# $2, empty for none. Fails for a name outside that grammar -- a UCM verb such as
# `HiFi` -- whose output side cannot be told from its name.
sendspin::profile_side() {
    local want=$1 name=$2 part side=''
    local -a parts

    [ "${name}" = off ] && return 0
    IFS=+ read -r -a parts <<< "${name}"
    for part in "${parts[@]}"; do
        case ${part} in
            output:?* | input:?*) ;;
            *) return 1 ;;
        esac
        if [ "${part%%:*}" = "${want}" ]; then
            side="${side:+${side}+}${part}"
        fi
    done
    printf '%s\n' "${side}"
}

# What to do about switching card $1 to profile $2, given `pactl list cards` in
# $3: `switch`, `already`, or `refuse` and the reason on the next line. Kept
# apart from the pactl calls so the decision can be tested on canned output.
sendspin::card_profile_plan() {
    local card=$1 profile=$2 cards=$3
    local parsed active='' kind name sinks sources available
    local found='' want_sources='' want_available='' active_out want_out want_in

    parsed=$(sendspin::pulse_card_profiles "${card}" <<< "${cards}")
    if [ -z "${parsed}" ]; then
        printf 'refuse\n%s\n' "${card} is not among the cards PulseAudio lists"
        return 0
    fi

    while IFS=$'\t' read -r kind name sinks sources available; do
        case ${kind} in
            active) active=${name} ;;
            profile)
                if [ "${name}" = "${profile}" ]; then
                    found=1 want_sources=${sources} want_available=${available}
                fi
                ;;
        esac
    done <<< "${parsed}"

    if [ -z "${found}" ]; then
        printf 'refuse\n%s\n' "${card} has no profile called ${profile}"
        return 0
    fi
    if [ -z "${active}" ]; then
        printf 'refuse\n%s\n' "the profile ${card} is on now could not be read"
        return 0
    fi
    if [ "${profile}" = "${active}" ]; then
        printf 'already\n'
        return 0
    fi
    if [ "${want_available}" = no ]; then
        printf 'refuse\n%s\n' "${profile} is not available on ${card}"
        return 0
    fi

    if ! want_out=$(sendspin::profile_side output "${profile}") \
        || ! want_in=$(sendspin::profile_side input "${profile}") \
        || ! active_out=$(sendspin::profile_side output "${active}"); then
        printf 'refuse\n%s\n' "there is no telling from the names whether ${profile} keeps the output ${card} is on now, ${active:-unknown}"
        return 0
    fi
    if [ -z "${want_in}" ] || [ "${want_sources}" = 0 ]; then
        printf 'refuse\n%s\n' "${profile} has no input"
        return 0
    fi
    if [ "${want_out}" != "${active_out}" ]; then
        printf 'refuse\n%s\n' "${profile} would change the output ${card} plays to from ${active_out:-none} to ${want_out:-none}"
        return 0
    fi

    printf 'switch\n'
}

# The active profile of card $1, from `pactl list cards` on stdin.
sendspin::card_active_profile() {
    sendspin::pulse_card_profiles "$1" | awk -F '\t' '$1 == "active" { print $2 }'
}

# The profiles card $1 could be switched to, from `pactl list cards` in $2, on one line.
sendspin::card_profile_candidates() {
    local card=$1 cards=$2 name out=''
    local -a names

    mapfile -t names < <(sendspin::pulse_card_profiles "${card}" <<< "${cards}" \
        | awk -F '\t' '$1 == "profile" { print $2 }')
    for name in "${names[@]}"; do
        if [ "$(sendspin::card_profile_plan "${card}" "${name}" "${cards}")" = switch ]; then
            out="${out:+${out}, }${name}"
        fi
    done
    printf '%s\n' "${out}"
}

# Switches a card to SENDSPIN_INPUT_CARD_PROFILE, `<card>:<profile>`, when that is
# safe, and logs why not otherwise. Card names cannot hold a colon -- PulseAudio's
# namereg replaces one with `_` -- so the first colon is the separator. Advisory,
# like the output check: every path returns success.
sendspin::apply_input_card_profile() {
    local value=${SENDSPIN_INPUT_CARD_PROFILE} card profile cards plan reason candidates after

    [ -n "${value}" ] || return 0

    card=${value%%:*}
    profile=${value#*:}
    if [ "${card}" = "${value}" ] || [ -z "${card}" ] || [ -z "${profile}" ]; then
        sendspin::log "Not switching a card for the audio input: ${value} is not <card>:<profile>."
        return 0
    fi

    if ! [ -S "${PULSE_SOCKET}" ] || ! cards=$(sendspin::pactl list cards); then
        sendspin::log "Not switching ${card} to ${profile} for the audio input: Home Assistant audio could not be asked."
        return 0
    fi

    plan=$(sendspin::card_profile_plan "${card}" "${profile}" "${cards}")
    case ${plan} in
        already)
            sendspin::log "${card} is already on ${profile}, the profile set for the audio input."
            return 0
            ;;
        refuse*)
            reason=${plan#refuse$'\n'}
            sendspin::log "Not switching ${card} to ${profile} for the audio input: ${reason}."
            candidates=$(sendspin::card_profile_candidates "${card}" "${cards}")
            if [ -n "${candidates}" ]; then
                sendspin::log "Profiles on ${card} that keep its output and add an input: ${candidates}"
            fi
            return 0
            ;;
    esac

    sendspin::log "Switching ${card} from $(sendspin::card_active_profile "${card}" <<< "${cards}") to ${profile} for the audio input. This changes the card for every app on this machine; the Audio panel can switch it back."
    if ! sendspin::pactl set-card-profile "${card}" "${profile}" > /dev/null; then
        sendspin::log "PulseAudio refused to switch ${card} to ${profile}."
    fi
    after=''
    if cards=$(sendspin::pactl list cards); then
        after=$(sendspin::card_active_profile "${card}" <<< "${cards}")
    fi
    sendspin::log "${card} is now on ${after:-a profile that could not be read}."
}
