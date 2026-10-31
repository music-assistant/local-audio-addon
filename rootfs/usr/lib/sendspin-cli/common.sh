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

sendspin::log() {
    printf '%s\n' "$*" >&2
}

# Populate SENDSPIN_NAME, SENDSPIN_OUTPUT, SENDSPIN_LOG_LEVEL, SENDSPIN_SERVER,
# SENDSPIN_BUFFER_MS, SENDSPIN_AUDIO_FORMAT, SENDSPIN_ALLOW_UNPAIRED, SENDSPIN_INPUT,
# SENDSPIN_HOOK_START and SENDSPIN_HOOK_STOP. Only the source differs between an
# add-on and a plain container; the defaults below are applied to both so the
# two cannot drift.
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

    # Read from the environment in both branches because it is not an add-on
    # option. A pinned `audio-format` the output cannot advertise refuses to
    # start the player, and the add-on plays through Home Assistant's
    # PulseAudio, which converts -- there is no DAC behind it to hold at one
    # shape.
    SENDSPIN_AUDIO_FORMAT="${SENDSPIN_AUDIO_FORMAT:-}"

    SENDSPIN_ALLOW_UNPAIRED="${SENDSPIN_ALLOW_UNPAIRED:-}"
    SENDSPIN_INPUT="${SENDSPIN_INPUT:-}"

    # Empty rather than defaulted, like the three above: the run script writes
    # only the keys that have a value, so a hook nobody set is absent from the
    # rendered config rather than sitting in it as a key with nothing after it.
    # There is no default a hook could sensibly have.
    SENDSPIN_HOOK_START="${SENDSPIN_HOOK_START:-}"
    SENDSPIN_HOOK_STOP="${SENDSPIN_HOOK_STOP:-}"

    # A newline in a value would add config keys of the caller's choosing, and
    # an injected `server` turns the mDNS advertisement off without saying so.
    #
    # The two hooks are in here for that reason and that reason only. Their
    # values are shell commands by design, so there is nothing to sanitise
    # within a line: whoever may set an option may already run what they like.
    for name in SENDSPIN_NAME SENDSPIN_OUTPUT SENDSPIN_LOG_LEVEL SENDSPIN_SERVER \
        SENDSPIN_BUFFER_MS SENDSPIN_AUDIO_FORMAT SENDSPIN_ALLOW_UNPAIRED SENDSPIN_INPUT \
        SENDSPIN_HOOK_START SENDSPIN_HOOK_STOP; do
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
}

# Upstream refuses `id =` now that identity is the keypair in the state dir, but
# an old Compose file setting SENDSPIN_ID is no reason not to start.
sendspin::warn_if_id_is_set() {
    [ -n "${SENDSPIN_ID:-}" ] || return 0
    sendspin::log 'SENDSPIN_ID is ignored: the player now identifies itself by the keypair in /data/state, so give each player its own /data volume instead.'
}

# Whether this container runs its own dbus and avahi-daemon, recorded once by
# the sendspin-init oneshot before any of them start. The answer comes from
# configuration alone: a runtime reachability probe is not used because both of
# its wrong answers are silent, giving either two responders competing on port
# 5353 or a player that runs but is never discovered.
sendspin::decide_daemons() {
    sendspin::read_options

    mkdir -p "${SENDSPIN_RUN_DIR}"

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

# Whether the player should capture SENDSPIN_INPUT, saying why not. A bare `pulse`
# is the Audio panel's input, where a monitor is never a choice the user made:
# the panel offers none, so it can only be PulseAudio's fallback for a machine
# with no input. Bounded by sendspin::pactl, and a PulseAudio that cannot answer
# reads as no.
sendspin::app_input_is_usable() {
    local name=${SENDSPIN_INPUT#pulse} sources='' sinks='' info='' own_sink='' panel=''
    local reason='Home Assistant audio could not be asked'

    name=${name#:}

    if [ -S "${PULSE_SOCKET}" ] && sources=$(sendspin::pactl list short sources) \
        && sinks=$(sendspin::pactl list short sinks) && info=$(sendspin::pactl info); then
        if [ -r "${PULSE_CLIENT_CONF}" ]; then
            own_sink=$(sendspin::pulse_conf_default_sink < "${PULSE_CLIENT_CONF}")
            panel=$(sendspin::pulse_conf_default_source < "${PULSE_CLIENT_CONF}")
        fi
        : "${own_sink:=$(sendspin::pulse_info_default_sink <<< "${info}")}"

        if [ "${SENDSPIN_INPUT}" = pulse ]; then
            name=${panel:-$(sendspin::pulse_info_default_source <<< "${info}")}
        fi

        if [ "${SENDSPIN_INPUT}" = pulse ] && [ "${name}" != "${name%.monitor}" ]; then
            reason='this machine has no audio input to use'
        else
            reason=$(sendspin::input_refusal "${name}" "${sources}" "${sinks}" "${own_sink}")
        fi
    fi

    if [ -n "${reason}" ]; then
        sendspin::log "The audio input is not available: ${reason}, so this player is not offering an input."
        if [ -n "${sources}${sinks}" ]; then
            sendspin::log "PulseAudio lists these sources and sinks: $(sendspin::pulse_short_names <<< "${sources}"$'\n'"${sinks}")"
        fi
        return 1
    fi
}
