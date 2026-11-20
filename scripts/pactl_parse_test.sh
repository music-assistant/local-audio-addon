#!/usr/bin/env bash
#
# Unit checks for the silent-output check in rootfs/usr/lib/sendspin-cli/common.sh.
#
# `pactl`'s output format is not this repo's to keep stable, and a format that moved would turn
# the warnings off with no symptom anywhere -- on an image that still builds and still boots. So
# it is pinned here against canned output rather than left to be noticed in a log.
#
# The fixtures are real `pactl` output, trimmed of the blocks that follow every sink except
# where a check is about the ports in them, or about them not being mistaken for sink fields.
#
# Needs: bash and awk. No docker, no image, no PulseAudio.
#
# Usage: scripts/pactl_parse_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../rootfs/usr/lib/sendspin-cli/common.sh
source "$SCRIPT_DIR/../rootfs/usr/lib/sendspin-cli/common.sh"

FAILURES=0

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

# Every assertion goes through here, so a mismatch prints both sides rather than just the name
# of the check that went red.
assert_equal() {
    local want=$1 got=$2 what=$3
    if [ "$want" = "$got" ]; then
        pass "$what"
    else
        fail "$what"
        printf '    want: %q\n    got:  %q\n' "$want" "$got" >&2
    fi
}

# ==============================================================================
# The fixtures
# ==============================================================================

# Two sinks, so picking the right one is asserted rather than assumed: the HDMI sink is first
# and healthy, the analog one the add-on plays to is second and silent. Both carry the
# `Base Volume:` line, which reads exactly like the level being looked for.
readonly TWO_SINKS='Sink #0
	State: SUSPENDED
	Name: alsa_output.pci-0000_00_1f.3.hdmi-stereo
	Description: Built-in Audio Digital Stereo (HDMI)
	Driver: PipeWire
	Sample Specification: s32le 2ch 48000Hz
	Channel Map: front-left,front-right
	Owner Module: 4294967295
	Mute: no
	Volume: front-left: 48497 /  74% / -7.85 dB,   front-right: 48497 /  74% / -7.85 dB
	        balance 0.00
	Base Volume: 65536 / 100% / 0.00 dB
	Monitor Source: alsa_output.pci-0000_00_1f.3.hdmi-stereo.monitor
	Latency: 0 usec, configured 0 usec
	Flags: HARDWARE DECIBEL_VOLUME LATENCY
	Properties:
		alsa.card_name = "HDA Intel PCH"
		device.description = "Built-in Audio Digital Stereo (HDMI)"
	Ports:
		hdmi-output-0: HDMI / DisplayPort (type: HDMI, priority: 5900, not available)
	Active Port: hdmi-output-0
	Formats:
		pcm
Sink #7
	State: SUSPENDED
	Name: alsa_output.usb-Topping_D10s-00.analog-stereo
	Description: D10s Analog Stereo
	Driver: PipeWire
	Sample Specification: s32le 2ch 48000Hz
	Channel Map: front-left,front-right
	Owner Module: 4294967295
	Mute: no
	Volume: front-left: 0 /   0% / -inf dB,   front-right: 0 /   0% / -inf dB
	        balance 0.00
	Base Volume: 65536 / 100% / 0.00 dB
	Monitor Source: alsa_output.usb-Topping_D10s-00.analog-stereo.monitor
	Latency: 0 usec, configured 0 usec
	Flags: HARDWARE HW_MUTE_CTRL HW_VOLUME_CTRL DECIBEL_VOLUME LATENCY
	Properties:
		alsa.card_name = "D10s"
		device.description = "D10s Analog Stereo"
	Ports:
		analog-output: Analog Output (type: Analog, priority: 9900, availability unknown)
	Active Port: analog-output
	Formats:
		pcm'

readonly PACTL_INFO='Server String: /run/audio/pulse.sock
Library Protocol Version: 35
Server Protocol Version: 35
Is Local: yes
Client Index: 121
Tile Size: 65472
User Name: root
Host Name: homeassistant
Server Name: pulseaudio
Server Version: 17.0
Default Sample Specification: s16le 2ch 44100Hz
Default Channel Map: front-left,front-right
Default Sink: alsa_output.pci-0000_00_1f.3.hdmi-stereo
Default Source: alsa_output.pci-0000_00_1f.3.hdmi-stereo.monitor
Cookie: 2966:8795'

# `pactl list cards` from a Home Assistant OS host (PulseAudio 17.0) with nothing plugged into
# its onboard HDA card: on an output-only profile, so there is no input source, while the duplex
# profile is available and the input-only one is not. Trimmed to the analog profiles, one HDMI
# pair, and a port of each kind -- their `Part of profile(s)` lines name profiles too, and must
# not be read as the profile list.
readonly CARDS_HDA_UNPLUGGED='Card #0
	Name: alsa_card.pci-0000_00_1f.3
	Driver: module-alsa-card.c
	Owner Module: 6
	Properties:
		alsa.card_name = "HDA Intel PCH"
		device.description = "Built-in Audio"
	Profiles:
		input:analog-stereo: Analog Stereo Input (sinks: 0, sources: 1, priority: 65, available: no)
		output:analog-stereo: Analog Stereo Output (sinks: 1, sources: 0, priority: 39268, available: yes)
		output:analog-stereo+input:analog-stereo: Analog Stereo Duplex (sinks: 1, sources: 1, priority: 6565, available: yes)
		output:hdmi-stereo: Digital Stereo (HDMI) Output (sinks: 1, sources: 0, priority: 5900, available: no)
		output:hdmi-stereo+input:analog-stereo: Digital Stereo (HDMI) Output + Analog Stereo Input (sinks: 1, sources: 1, priority: 5965, available: no)
		off: Off (sinks: 0, sources: 0, priority: 0, available: yes)
	Active Profile: output:analog-stereo
	Ports:
		analog-input-headset-mic: Headset Microphone (type: Headset, priority: 8800, latency offset: 0 usec, availability group: Legacy 1, not available)
			Properties:
				device.icon_name = "audio-input-microphone"
			Part of profile(s): input:analog-stereo, output:analog-stereo+input:analog-stereo, output:hdmi-stereo+input:analog-stereo
		analog-output-speaker: Speakers (type: Speaker, priority: 10000, latency offset: 0 usec, availability unknown)
			Properties:
				device.icon_name = "audio-speakers"
			Part of profile(s): output:analog-stereo, output:analog-stereo+input:analog-stereo'

# The same host with a USB adapter hotplugged and a headset in the HDA jack, so two cards and
# the one asked for second. The adapter's analog jacks are empty: its analog duplex is not
# available, while its S/PDIF output with the analog input is.
readonly CARDS_USB_AND_HDA='Card #1
	Name: alsa_card.usb-Generic_CUBILUX_CA7-00
	Driver: module-alsa-card.c
	Owner Module: 15
	Properties:
		alsa.card_name = "CUBILUX CA7"
		device.description = "CUBILUX CA7"
	Profiles:
		input:analog-stereo: Analog Stereo Input (sinks: 0, sources: 1, priority: 65, available: no)
		input:iec958-stereo: Digital Stereo (IEC958) Input (sinks: 0, sources: 1, priority: 32823, available: yes)
		output:analog-stereo: Analog Stereo Output (sinks: 1, sources: 0, priority: 6500, available: no)
		output:analog-stereo+input:analog-stereo: Analog Stereo Duplex (sinks: 1, sources: 1, priority: 6565, available: no)
		output:analog-stereo+input:iec958-stereo: Analog Stereo Output + Digital Stereo (IEC958) Input (sinks: 1, sources: 1, priority: 6555, available: yes)
		output:iec958-stereo: Digital Stereo (IEC958) Output (sinks: 1, sources: 0, priority: 38268, available: yes)
		output:iec958-stereo+input:analog-stereo: Digital Stereo (IEC958) Output + Analog Stereo Input (sinks: 1, sources: 1, priority: 5565, available: yes)
		output:iec958-stereo+input:iec958-stereo: Digital Stereo Duplex (IEC958) (sinks: 1, sources: 1, priority: 38323, available: yes)
		off: Off (sinks: 0, sources: 0, priority: 0, available: yes)
	Active Profile: output:iec958-stereo+input:iec958-stereo
	Ports:
		analog-input-mic: Microphone (type: Mic, priority: 8700, latency offset: 0 usec, not available)
			Part of profile(s): input:analog-stereo, output:analog-stereo+input:analog-stereo, output:iec958-stereo+input:analog-stereo

Card #2
	Name: alsa_card.pci-0000_00_1f.3
	Driver: module-alsa-card.c
	Owner Module: 16
	Properties:
		alsa.card_name = "HDA Intel PCH"
		device.description = "Built-in Audio"
	Profiles:
		input:analog-stereo: Analog Stereo Input (sinks: 0, sources: 1, priority: 32833, available: yes)
		output:analog-stereo: Analog Stereo Output (sinks: 1, sources: 0, priority: 39268, available: yes)
		output:analog-stereo+input:analog-stereo: Analog Stereo Duplex (sinks: 1, sources: 1, priority: 39333, available: yes)
		off: Off (sinks: 0, sources: 0, priority: 0, available: yes)
	Active Profile: output:analog-stereo+input:analog-stereo
	Ports:
		analog-input-headset-mic: Headset Microphone (type: Headset, priority: 8800, latency offset: 0 usec, availability group: Legacy 1, availability unknown)
			Part of profile(s): input:analog-stereo, output:analog-stereo+input:analog-stereo'

# ==============================================================================
# Which sink gets looked at
# ==============================================================================

check_client_conf_default_sink() {
    local conf out

    step 'the sink comes from client.conf'

    # The shape the Supervisor renders, around the commented-out defaults PulseAudio ships.
    # `;` is PulseAudio's comment character.
    conf='# Home Assistant audio configuration
default-server = unix:/run/audio/pulse.sock
; default-sink = something-else
default-sink = alsa_output.usb-Topping_D10s-00.analog-stereo
; default-source =
autospawn = no'
    out=$(sendspin::pulse_conf_default_sink <<< "$conf")
    assert_equal 'alsa_output.usb-Topping_D10s-00.analog-stereo' "$out" \
        'default-sink is read, and a commented-out one is not'

    conf='default-server = unix:/run/audio/pulse.sock
; default-sink =
autospawn = no'
    out=$(sendspin::pulse_conf_default_sink <<< "$conf")
    assert_equal '' "$out" 'no default-sink reads as no answer, not as an empty sink name'

    # The key with nothing after it, which is what an unset Audio panel selection renders as.
    # It has to read as no answer, because that is the whole trigger for the server fallback.
    conf='default-server = unix:/run/audio/pulse.sock
default-sink =
autospawn = no'
    out=$(sendspin::pulse_conf_default_sink <<< "$conf")
    assert_equal '' "$out" 'an empty default-sink reads as no answer'

    conf='default-server = unix:/run/audio/pulse.sock
default-sink =   alsa_output.usb-Topping_D10s-00.analog-stereo   
autospawn = no'
    out=$(sendspin::pulse_conf_default_sink <<< "$conf")
    assert_equal 'alsa_output.usb-Topping_D10s-00.analog-stereo' "$out" \
        'the sink name comes back without the whitespace around it'

    out=$(sendspin::pulse_conf_default_sink < /dev/null)
    assert_equal '' "$out" 'an empty client.conf reads as no answer'
}

check_server_default_sink() {
    local out

    step 'the server default is the fallback'

    out=$(sendspin::pulse_info_default_sink <<< "$PACTL_INFO")
    assert_equal 'alsa_output.pci-0000_00_1f.3.hdmi-stereo' "$out" \
        "the daemon's default sink is read from pactl info"

    # `Default Source:` is the very next line and its name is the sink's plus a suffix, so a
    # loose match would inspect the monitor source instead.
    out=$(sendspin::pulse_info_default_sink <<< 'Default Source: alsa_output.hdmi.monitor')
    assert_equal '' "$out" 'Default Source is not mistaken for Default Sink'
}

# ==============================================================================
# The Audio panel's input
# ==============================================================================

check_input_source() {
    local out conf sources sinks own

    step 'the input comes from client.conf, with the server default as the fallback'

    conf='default-sink = alsa_output.usb-Topping_D10s-00.analog-stereo
; default-source = something-else
default-source = alsa_input.usb-Line_In-00.analog-stereo'
    out=$(sendspin::pulse_conf_default_source <<< "$conf")
    assert_equal 'alsa_input.usb-Line_In-00.analog-stereo' "$out" \
        'default-source is read, and neither default-sink nor a commented-out one is'

    out=$(sendspin::pulse_conf_default_source <<< 'default-sink = alsa_output.hdmi')
    assert_equal '' "$out" 'no default-source reads as no answer'

    out=$(sendspin::pulse_info_default_source <<< 'Default Sink: alsa_output.hdmi
Default Source: alsa_output.hdmi.monitor')
    assert_equal 'alsa_output.hdmi.monitor' "$out" "the daemon's default source is read from pactl info"

    step 'which sources may be streamed'

    # Real `pactl list short` output: tab-separated, the name second, monitors among them.
    own=alsa_output.pci-0000_00_1f.3.analog-stereo
    sources=$'0\talsa_output.pci-0000_00_1f.3.analog-stereo.monitor\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tIDLE
1\talsa_input.usb-Line_In-00.analog-stereo\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tSUSPENDED
2\tbluez_sink.AA_BB.a2dp_sink.monitor\tmodule-bluez5-device.c\ts16le 2ch 44100Hz\tIDLE'
    sinks=$'0\talsa_output.pci-0000_00_1f.3.analog-stereo\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tIDLE
1\tbluez_sink.AA_BB.a2dp_sink\tmodule-bluez5-device.c\ts16le 2ch 44100Hz\tIDLE'

    out=$(sendspin::input_refusal alsa_input.usb-Line_In-00.analog-stereo "$sources" "$sinks" "$own")
    assert_equal '' "$out" 'a real input that PulseAudio lists is accepted'

    out=$(sendspin::input_refusal bluez_sink.AA_BB.a2dp_sink "$sources" "$sinks" "$own")
    assert_equal '' "$out" 'another sink is accepted by its own name'

    out=$(sendspin::input_refusal bluez_sink.AA_BB.a2dp_sink.monitor "$sources" "$sinks" "$own")
    assert_equal '' "$out" "and by its monitor's: it is not what this player plays to"

    out=$(sendspin::input_refusal "$own.monitor" "$sources" "$sinks" "$own")
    assert_equal "$own.monitor is the output this player plays to, which would send Music Assistant its own audio" \
        "$out" "this player's own monitor is refused even though it is listed"

    out=$(sendspin::input_refusal "$own" "$sources" "$sinks" "$own")
    assert_equal "$own is the output this player plays to, which would send Music Assistant its own audio" \
        "$out" 'and so is its own sink by name, which captures the same thing'

    out=$(sendspin::input_refusal alsa_input.usb-Gone-00.analog-stereo "$sources" "$sinks" "$own")
    assert_equal 'alsa_input.usb-Gone-00.analog-stereo is not among the sources and sinks PulseAudio lists' \
        "$out" 'a name that is not there is refused, by name'

    # A name that only occurs as part of another must not pass for the whole one.
    out=$(sendspin::input_refusal alsa_input.usb-Line_In-00 "$sources" "$sinks" "$own")
    assert_equal 'alsa_input.usb-Line_In-00 is not among the sources and sinks PulseAudio lists' \
        "$out" 'a partial name is not a match'

    out=$(sendspin::input_refusal '' "$sources" "$sinks" "$own")
    assert_equal 'no input is named' "$out" 'no name at all is refused'

    # The fallback a sink that cannot be worked out reads as, with the check still meaningful.
    out=$(sendspin::input_refusal '.monitor' "$sources" "$sinks" '')
    assert_equal '.monitor is the output this player plays to, which would send Music Assistant its own audio' \
        "$out" 'an unknown own sink matches nothing a real name could be'

    out=$(sendspin::pulse_short_names <<< "$sources"$'\n'"$sinks")
    assert_equal "$own.monitor, alsa_input.usb-Line_In-00.analog-stereo, bluez_sink.AA_BB.a2dp_sink.monitor, $own, bluez_sink.AA_BB.a2dp_sink" \
        "$out" 'the names to choose from are listed on one line'
}

# The whole decision the run script makes before writing an input, from what PulseAudio and
# client.conf say: which name a bare `pulse` resolves to, and which sink counts as this player's.
check_app_input() {
    local out sources sinks info conf hdmi analog line_in bt
    hdmi=alsa_output.pci-0000_00_1f.3.hdmi-stereo
    analog=alsa_output.pci-0000_00_1f.3.analog-stereo
    line_in=alsa_input.usb-Line_In-00.analog-stereo
    bt=bluez_sink.AA_BB.a2dp_sink

    sources=$'0\t'"$hdmi"$'.monitor\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tIDLE
1\t'"$analog"$'.monitor\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tIDLE
2\t'"$line_in"$'\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tSUSPENDED
3\t'"$bt"$'.monitor\tmodule-bluez5-device.c\ts16le 2ch 44100Hz\tIDLE'
    sinks=$'0\t'"$hdmi"$'\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tIDLE
1\t'"$analog"$'\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tIDLE
2\t'"$bt"$'\tmodule-bluez5-device.c\ts16le 2ch 44100Hz\tIDLE'
    # The daemon's defaults are HDMI and its monitor, which is what a machine with no input
    # reports as its default source.
    info=${PACTL_INFO}

    step 'the Audio panel input, resolved'

    conf="default-sink = $analog
default-source = $line_in"
    out=$(sendspin::app_input_refusal pulse "$sources" "$sinks" "$info" "$conf")
    assert_equal '' "$out" "client.conf's default-source is captured, over the daemon's monitor"

    out=$(sendspin::app_input_refusal pulse "$sources" "$sinks" \
        "${info/Default Source: $hdmi.monitor/Default Source: $line_in}" "default-sink = $analog")
    assert_equal '' "$out" "with none in client.conf, the daemon's default source is captured"

    out=$(sendspin::app_input_refusal pulse "$sources" "$sinks" "$info" "default-sink = $analog")
    assert_equal 'this machine has no audio input to use' "$out" \
        "the daemon's fallback monitor is refused, though it is not this player's sink"

    out=$(sendspin::app_input_refusal pulse "$sources" "$sinks" "$info" \
        "default-sink = $analog
default-source = $bt.monitor")
    assert_equal 'this machine has no audio input to use' "$out" \
        'so is a monitor in client.conf: the panel never offers one'

    out=$(sendspin::app_input_refusal pulse "$sources" "$sinks" "$info" \
        "default-sink = $analog
default-source = alsa_input.usb-Gone-00.analog-stereo")
    assert_equal 'alsa_input.usb-Gone-00.analog-stereo is not among the sources and sinks PulseAudio lists' \
        "$out" 'a panel input that has gone is refused, by name'

    out=$(sendspin::app_input_refusal pulse '' '' '' '')
    assert_equal 'no input is named' "$out" 'nothing anywhere names an input'

    step "a named input, against this player's own sink"

    out=$(sendspin::app_input_refusal "pulse:$analog.monitor" "$sources" "$sinks" "$info" \
        "default-sink = $analog")
    assert_equal "$analog.monitor is the output this player plays to, which would send Music Assistant its own audio" \
        "$out" "client.conf's default-sink is this player's own"

    out=$(sendspin::app_input_refusal "pulse:$hdmi" "$sources" "$sinks" "$info" \
        "default-sink = $analog")
    assert_equal '' "$out" "and the daemon's default is then just another sink"

    out=$(sendspin::app_input_refusal "pulse:$hdmi.monitor" "$sources" "$sinks" "$info" '')
    assert_equal "$hdmi.monitor is the output this player plays to, which would send Music Assistant its own audio" \
        "$out" "with no client.conf, the daemon's default sink is this player's own"

    out=$(sendspin::app_input_refusal "pulse:$bt" "$sources" "$sinks" "$info" \
        "default-sink = $analog
default-source = $line_in")
    assert_equal '' "$out" "a named input ignores the panel's default-source"

    out=$(sendspin::app_input_refusal "pulse:$line_in" "$sources" "$sinks" "$info" \
        "default-sink = $analog")
    assert_equal '' "$out" 'a named source is captured by its own name'
}

# ==============================================================================
# Reading a sink's state
# ==============================================================================

check_sink_state() {
    local out want

    step 'a sink reads back field by field'

    want='7
alsa_output.usb-Topping_D10s-00.analog-stereo
D10s Analog Stereo
no
0
analog-output
Analog Output
availability unknown'
    out=$(sendspin::pulse_sink_state 'alsa_output.usb-Topping_D10s-00.analog-stereo' <<< "$TWO_SINKS")
    assert_equal "$want" "$out" 'index, name, description, mute, level and the active port all parse'

    # Reading the first sink's 74% rather than the second's 0% proves the target name selects
    # the block, and the `Base Volume: ... 100%` under it proves the level came from `Volume:`.
    want='0
alsa_output.pci-0000_00_1f.3.hdmi-stereo
Built-in Audio Digital Stereo (HDMI)
no
74
hdmi-output-0
HDMI / DisplayPort
not available'
    out=$(sendspin::pulse_sink_state 'alsa_output.pci-0000_00_1f.3.hdmi-stereo' <<< "$TWO_SINKS")
    assert_equal "$want" "$out" 'the named sink is the one read, and Base Volume is not its level'

    out=$(sendspin::pulse_sink_state 'alsa_output.no-such-card' <<< "$TWO_SINKS")
    assert_equal '' "$out" 'a sink that is not in the list reads as no answer'
}

check_mute_and_level() {
    local out sink

    step 'the mute flag and the level'

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: yes
	Volume: front-left: 65536 / 100% / 0.00 dB,   front-right: 65536 / 100% / 0.00 dB
	Base Volume: 65536 / 100% / 0.00 dB'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 4p)
    assert_equal 'yes' "$out" 'a muted sink reports its mute flag'

    # The loudest channel decides: one channel down is a balance setting, not silence.
    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 0 /   0% / -inf dB,   front-right: 39321 /  60% / -13.33 dB
	Base Volume: 65536 / 100% / 0.00 dB'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 5p)
    assert_equal '60' "$out" 'the loudest channel is the level'

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 0 /   0% / -inf dB,   front-right: 0 /   0% / -inf dB
	Base Volume: 65536 / 100% / 0.00 dB'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 5p)
    assert_equal '0' "$out" 'every channel down is a level of zero'

    # PulseAudio allows a sink above 100%, and three digits must not read as some other number.
    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 98304 / 150% / 7.04 dB,   front-right: 98304 / 150% / 7.04 dB
	Base Volume: 65536 / 100% / 0.00 dB'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 5p)
    assert_equal '150' "$out" 'a level above 100% parses whole'
}

check_garbage_is_no_answer() {
    local out sink

    step 'unparseable output reads as no answer'

    out=$(sendspin::pulse_sink_state sink < /dev/null)
    assert_equal '' "$out" 'empty pactl output reads as no answer'

    out=$(sendspin::pulse_sink_state sink <<< 'Connection failure: Connection refused')
    assert_equal '' "$out" 'an error message reads as no answer'

    # The one field the whole check turns on: losing it must read as "could not tell", never
    # as an audible sink.
    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Base Volume: 65536 / 100% / 0.00 dB'
    out=$(sendspin::pulse_sink_state sink <<< "$sink")
    assert_equal '' "$out" 'a sink with no Volume line reads as no answer'

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: unavailable'
    out=$(sendspin::pulse_sink_state sink <<< "$sink")
    assert_equal '' "$out" 'a Volume line with no percentage in it reads as no answer'

    # Properties are indented deeper than sink fields, which is the only thing keeping a
    # property called `Name` out of the answer.
    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 65536 / 100% / 0.00 dB
	Properties:
		Name: not-the-sink
		Mute: yes'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 4p)
    assert_equal 'no' "$out" 'a property is not mistaken for a sink field'
}

# ==============================================================================
# The active port
# ==============================================================================

check_active_port() {
    local out sink

    step 'the active port'

    # A modern pactl carries `type:` and an `availability group:`; an older one carries neither.
    # The availability closes the bracket in both, which is why it is read from the end.
    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 52428 /  80% / -1.94 dB
	Ports:
		analog-output-lineout: Line Out (type: Line, priority: 9000, availability group: Legacy 1, not available)
		analog-output-headphones: Headphones (type: Headphones, priority: 9900, available)
	Active Port: analog-output-lineout'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n '6,8p')
    assert_equal 'analog-output-lineout
Line Out
not available' "$out" 'the long port-line format parses, id, description and availability'

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 52428 /  80% / -1.94 dB
	Ports:
		analog-output: Analog Output (priority: 9900, not available)
	Active Port: analog-output'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n '6,8p')
    assert_equal 'analog-output
Analog Output
not available' "$out" 'the short port-line format parses too'

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 52428 /  80% / -1.94 dB
	Ports:
		analog-output: Analog Output (type: Analog, priority: 9900, available)
	Active Port: analog-output'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 8p)
    assert_equal 'available' "$out" 'an available port reads as available'

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 52428 /  80% / -1.94 dB
	Ports:
		analog-output: Analog Output (type: Analog, priority: 9900, availability unknown)
	Active Port: analog-output'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 8p)
    assert_equal 'availability unknown' "$out" 'a card with no jack detection reads as unknown'

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 52428 /  80% / -1.94 dB
	Ports:
		hp: Headphones (unplugged) (type: Headphones, priority: 9900, not available)
	Active Port: hp'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n '7,8p')
    assert_equal 'Headphones (unplugged)
not available' "$out" 'brackets inside a port description are kept, and the last one is read'

    # Folding the port fields into the all-or-nothing emit guard would turn the mute and level
    # warning off for every null sink, which has no `Ports:` block at all.
    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: yes
	Volume: front-left: 0 /   0% / -inf dB'
    out=$(sendspin::pulse_sink_state sink <<< "$sink")
    assert_equal '3
sink
A sink
yes
0' "$out" 'a sink with no Ports block still reads back its five original fields'

    out=$(sendspin::warn_if_sink_is_silent 3 sink 'A sink' yes 0 2>&1)
    case $out in
        *'is muted and turned down to zero,'*) pass 'and it still gets the mute and level warning' ;;
        *) fail 'and it still gets the mute and level warning' ;;
    esac

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 52428 /  80% / -1.94 dB
	Ports:
		analog-output: Analog Output (type: Analog, priority: 9900, not available)
	Active Port: hdmi-output-0'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n '6,8p')
    assert_equal 'hdmi-output-0' "$out" \
        'an active port absent from the Ports block reads as unknown, not as unavailable'

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 52428 /  80% / -1.94 dB
	Properties:
		analog-output: not a port (priority: 1, not available)
	Ports:
		analog-output: Analog Output (type: Analog, priority: 9900, available)
	Active Port: analog-output
	Formats:
		pcm'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n '7,8p')
    assert_equal 'Analog Output
available' "$out" 'a property shaped like a port line is not read as one'
}

# ==============================================================================
# What gets said
# ==============================================================================

# What a user reads in the log is the point of the check, so the message is asserted and not
# only the numbers behind it.
check_the_warning() {
    local out

    step 'the warning'

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' no 74 2>&1)
    assert_equal '' "$out" 'an audible sink is not mentioned at all'

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' no 100 2>&1)
    assert_equal '' "$out" 'a sink at full is not mentioned at all'

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' no 0 2>&1)
    case $out in
        *'turned down to zero, so nothing it plays will be heard.'*) pass 'a zeroed sink is called zeroed' ;;
        *) fail 'a zeroed sink is called zeroed' ;;
    esac
    case $out in
        *'That output is sink #7, a-sink (A Sink).'*) pass 'the warning names the index, name and description' ;;
        *) fail 'the warning names the index, name and description' ;;
    esac
    case $out in
        *'Music Assistant volume cannot raise it'*) pass "the warning says Music Assistant's volume will not fix it" ;;
        *) fail "the warning says Music Assistant's volume will not fix it" ;;
    esac

    # The two lines a user is meant to paste, pinned exactly: a remedy that has to be worked
    # out is the dead end this warning exists to end.
    case $out in
        *'    ha audio volume output --index 7 --unmute'*) pass 'the unmute command is spelled out with the index' ;;
        *) fail 'the unmute command is spelled out with the index' ;;
    esac
    case $out in
        *'    ha audio volume output --index 7 --volume 85'*) pass 'the volume command is spelled out with the index' ;;
        *) fail 'the volume command is spelled out with the index' ;;
    esac

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' yes 74 2>&1)
    case $out in
        *'is muted, so nothing it plays will be heard.'*) pass 'a muted sink at a normal level is still silent' ;;
        *) fail 'a muted sink at a normal level is still silent' ;;
    esac

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' yes 0 2>&1)
    case $out in
        *'is muted and turned down to zero,'*) pass 'both at once are named together' ;;
        *) fail 'both at once are named together' ;;
    esac

    # Nothing downstream validates the reading, so a level the parser could not make sense of
    # must not warn about a sink that may be perfectly audible.
    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' no '' 2>&1)
    assert_equal '' "$out" 'an unparseable level says nothing'

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' no 'n/a' 2>&1)
    assert_equal '' "$out" 'a non-numeric level says nothing'
}

# No `ha audio` verb moves a port, so the words are the whole remedy and are pinned as literally
# as the `ha audio volume output` lines above.
check_the_port_warning() {
    local out

    step 'the unavailable-port warning'

    out=$(sendspin::warn_if_port_is_unavailable 7 a-sink analog-output-lineout 'Line Out' 'not available' 2>&1)
    case $out in
        *'routed to a socket with nothing plugged into it, so nothing it plays will be heard.'*)
            pass 'an unavailable port is called out' ;;
        *) fail 'an unavailable port is called out'; printf '    got: %q\n' "$out" >&2 ;;
    esac
    case $out in
        *'That output is sink #7, a-sink, and it is playing out of Line Out (analog-output-lineout),'*)
            pass 'the warning names the sink index, the sink name and the port' ;;
        *) fail 'the warning names the sink index, the sink name and the port' ;;
    esac
    case $out in
        *'Music Assistant volume cannot fix it'*)
            pass "the warning says Music Assistant's volume will not fix it" ;;
        *) fail "the warning says Music Assistant's volume will not fix it" ;;
    esac
    case $out in
        *'Plug into that socket, or pick an output that is plugged in from the Home Assistant Audio panel.'*)
            pass 'the remedy is spelled out' ;;
        *) fail 'the remedy is spelled out' ;;
    esac

    # The crux. `availability unknown` is what a card with no jack detection reports for every
    # port it has, so warning on it would go off on most working line-outs.
    out=$(sendspin::warn_if_port_is_unavailable 7 a-sink analog-output 'Analog Output' 'available' 2>&1)
    assert_equal '' "$out" 'an available port says nothing'

    out=$(sendspin::warn_if_port_is_unavailable 7 a-sink analog-output 'Analog Output' 'availability unknown' 2>&1)
    assert_equal '' "$out" 'an unknown availability says nothing'

    out=$(sendspin::warn_if_port_is_unavailable 7 a-sink analog-output 'Analog Output' '' 2>&1)
    assert_equal '' "$out" 'a sink with no port at all says nothing'

    out=$(sendspin::warn_if_port_is_unavailable 7 a-sink analog-output 'Analog Output' 'nicht verfugbar' 2>&1)
    assert_equal '' "$out" 'an unrecognised availability string says nothing'

    out=$(sendspin::warn_if_port_is_unavailable 7 a-sink analog-output 'Analog Output' 'not available yet' 2>&1)
    assert_equal '' "$out" 'only the exact string warns, not anything containing it'

    out=$(sendspin::warn_if_port_is_unavailable 7 a-sink analog-output '' 'not available' 2>&1)
    case $out in
        *'playing out of analog-output, which PulseAudio reports as not available.'*)
            pass 'a port with no description is named by its id alone' ;;
        *)
            fail 'a port with no description is named by its id alone'
            printf '    got: %q\n' "$out" >&2 ;;
    esac
}

# The line every start prints, healthy or not: a silent healthy start is why the report this was
# written from had nothing in the log to go on.
check_the_report_line() {
    local out

    step 'naming the output on every start'

    out=$(sendspin::report_output 7 a-sink 'A Sink' 74 analog-output-lineout 'Line Out' 2>&1)
    assert_equal 'Playing through sink #7, a-sink (A Sink), at 74%, out of Line Out (analog-output-lineout).' \
        "$out" 'the line names index, name, description, level and active port'

    out=$(sendspin::report_output 7 a-sink 'A Sink' 74 analog-output-lineout 'Line Out' 2>&1 | wc -l)
    assert_equal '1' "$out" 'it is exactly one line'

    out=$(sendspin::report_output 7 a-sink 'A Sink' 74 '' '' 2>&1)
    assert_equal 'Playing through sink #7, a-sink (A Sink), at 74%.' "$out" \
        'a sink with no port is still named, without a trailing fragment'

    out=$(sendspin::report_output 7 a-sink 'A Sink' 74 hdmi-output-0 '' 2>&1)
    assert_equal 'Playing through sink #7, a-sink (A Sink), at 74%, out of hdmi-output-0.' "$out" \
        'a port with no description falls back to its id'
}

# The two cases the check used to return from without a word, each of them the fault itself.
check_the_bail_outs() {
    local out

    step 'the silent bail-outs'

    out=$(sendspin::report_on_sinks alsa_output.usb-Topping_D10s-00.analog-stereo '' 2>&1)
    case $out in
        *'PulseAudio lists no audio outputs at all'*) pass 'an empty sink list is reported' ;;
        *) fail 'an empty sink list is reported'; printf '    got: %q\n' "$out" >&2 ;;
    esac

    out=$(sendspin::report_on_sinks alsa_output.usb-gone-00.analog-stereo "$TWO_SINKS" 2>&1)
    case $out in
        *'alsa_output.usb-gone-00.analog-stereo, is not among the outputs PulseAudio lists.'*)
            pass 'a default-sink that is not in the list is reported, by name' ;;
        *)
            fail 'a default-sink that is not in the list is reported, by name'
            printf '    got: %q\n' "$out" >&2 ;;
    esac
    case $out in
        *'    alsa_output.pci-0000_00_1f.3.hdmi-stereo'*'    alsa_output.usb-Topping_D10s-00.analog-stereo'*)
            pass 'and the outputs that are there are listed, so the right one can be picked' ;;
        *) fail 'and the outputs that are there are listed, so the right one can be picked' ;;
    esac

    # The same empty reading for the opposite reason: the sink is listed, so what failed was
    # reading it, and a wrong Audio panel selection is the wrong thing to send the reader after.
    out=$(sendspin::report_on_sinks alsa_output.usb-Topping_D10s-00.analog-stereo \
        'Sink #7
	Name: alsa_output.usb-Topping_D10s-00.analog-stereo
	Description: D10s Analog Stereo
	Mute: no' 2>&1)
    case $out in
        *'is listed by PulseAudio but could not be read.'*)
            pass 'a sink that is listed but unreadable is not called missing' ;;
        *)
            fail 'a sink that is listed but unreadable is not called missing'
            printf '    got: %q\n' "$out" >&2 ;;
    esac
    case $out in
        *'Pick one of them'*)
            fail 'and it does not tell the reader to pick a different output' ;;
        *) pass 'and it does not tell the reader to pick a different output' ;;
    esac

    # `Name:` is on the monitor source line too, and on properties, so a loose match would list
    # devices that are not outputs at all.
    out=$(sendspin::pulse_sink_names <<< "$TWO_SINKS")
    assert_equal 'alsa_output.pci-0000_00_1f.3.hdmi-stereo
alsa_output.usb-Topping_D10s-00.analog-stereo' "$out" 'the sink names are exactly the sinks'

    # A boot must not turn on whether PulseAudio answered, including on the paths that now log.
    sendspin::report_on_sinks '' '' > /dev/null 2>&1
    pass 'no sinks and no target still returns success'
    sendspin::report_on_sinks alsa_output.usb-gone-00.analog-stereo "$TWO_SINKS" > /dev/null 2>&1
    pass 'a missing sink still returns success'
    sendspin::report_on_sinks alsa_output.usb-Topping_D10s-00.analog-stereo "$TWO_SINKS" > /dev/null 2>&1
    pass 'a sink it warns about still returns success'
    sendspin::report_on_sinks sink 'Connection failure: Connection refused' > /dev/null 2>&1
    pass 'unreadable pactl output still returns success'
}

# ==============================================================================
# End to end, against the fixtures
# ==============================================================================

# Wired together the way the oneshot wires them, so a change that breaks the seam between them
# fails here rather than in someone's log.
check_end_to_end() {
    local out state
    local -a field

    step 'reading and warning together'

    state=$(sendspin::pulse_sink_state \
        "$(sendspin::pulse_conf_default_sink <<< 'default-sink = alsa_output.usb-Topping_D10s-00.analog-stereo')" \
        <<< "$TWO_SINKS")
    mapfile -t field <<< "$state"
    out=$(sendspin::warn_if_sink_is_silent "${field[0]}" "${field[1]}" "${field[2]}" \
        "${field[3]}" "${field[4]}" 2>&1)
    case $out in
        *'ha audio volume output --index 7 --volume 85'*)
            pass 'the sink client.conf names is the one warned about, with its own index' ;;
        *)
            fail 'the sink client.conf names is the one warned about, with its own index'
            printf '    got: %q\n' "$out" >&2 ;;
    esac

    out=$(sendspin::warn_if_port_is_unavailable "${field[0]}" "${field[1]}" \
        "${field[5]}" "${field[6]}" "${field[7]}" 2>&1)
    assert_equal '' "$out" 'its unknown port availability adds nothing to that warning'

    out=$(sendspin::report_output "${field[0]}" "${field[1]}" "${field[2]}" "${field[4]}" \
        "${field[5]}" "${field[6]}" 2>&1)
    assert_equal 'Playing through sink #7, alsa_output.usb-Topping_D10s-00.analog-stereo (D10s Analog Stereo), at 0%, out of Analog Output (analog-output).' \
        "$out" 'the same sink is the one named on the start line'

    # The same list with the server default selected instead. It resolves to the healthy sink,
    # so preferring this path over client.conf would warn about nothing while the add-on played
    # to silence.
    state=$(sendspin::pulse_sink_state \
        "$(sendspin::pulse_info_default_sink <<< "$PACTL_INFO")" <<< "$TWO_SINKS")
    mapfile -t field <<< "$state"
    out=$(sendspin::warn_if_sink_is_silent "${field[0]}" "${field[1]}" "${field[2]}" \
        "${field[3]}" "${field[4]}" 2>&1)
    assert_equal '' "$out" 'the server default resolves to the healthy sink and says nothing'

    # Healthy on level and mute, but its HDMI port is `not available` -- the cable is out, which
    # is exactly the gap the sink warning cannot see.
    out=$(sendspin::warn_if_port_is_unavailable "${field[0]}" "${field[1]}" \
        "${field[5]}" "${field[6]}" "${field[7]}" 2>&1)
    case $out in
        *'playing out of HDMI / DisplayPort (hdmi-output-0), which PulseAudio reports as not available.'*)
            pass 'an audible sink routed at an unplugged port is still called out' ;;
        *)
            fail 'an audible sink routed at an unplugged port is still called out'
            printf '    got: %q\n' "$out" >&2 ;;
    esac
}

# ==============================================================================
# The input card profile
# ==============================================================================

# One line per plan, so a whole decision is one assertion.
plan_of() {
    sendspin::card_profile_plan "$1" "$2" "$3" | paste -sd '|'
}

check_card_profiles() {
    local hda=alsa_card.pci-0000_00_1f.3 usb=alsa_card.usb-Generic_CUBILUX_CA7-00

    step 'reading a card'

    assert_equal "profile	input:analog-stereo	0	1	no
profile	output:analog-stereo	1	0	yes
profile	output:analog-stereo+input:analog-stereo	1	1	yes
profile	output:hdmi-stereo	1	0	no
profile	output:hdmi-stereo+input:analog-stereo	1	1	no
profile	off	0	0	yes
active	output:analog-stereo" "$(sendspin::pulse_card_profiles "$hda" <<< "$CARDS_HDA_UNPLUGGED")" \
        'every profile, with counts and availability, and not the ports naming them'

    assert_equal 'output:analog-stereo+input:analog-stereo' \
        "$(sendspin::card_active_profile "$hda" <<< "$CARDS_USB_AND_HDA")" \
        'the active profile is the named card'"'"'s, not the first card'"'"'s'
    assert_equal '' "$(sendspin::pulse_card_profiles alsa_card.gone <<< "$CARDS_USB_AND_HDA")" \
        'a card that is not listed reads as nothing'

    step 'profile names'

    assert_equal 'output:analog-stereo' \
        "$(sendspin::profile_side output output:analog-stereo+input:analog-stereo)" 'the output side of a duplex'
    assert_equal 'input:analog-stereo' \
        "$(sendspin::profile_side input output:analog-stereo+input:analog-stereo)" 'and its input side'
    assert_equal '' "$(sendspin::profile_side output input:analog-stereo)" 'an input-only profile has no output side'
    assert_equal '' "$(sendspin::profile_side output off)" 'and off has neither'
    if sendspin::profile_side output HiFi > /dev/null; then
        fail 'a UCM verb is not read as having no output'
    else
        pass 'a UCM verb is not read as having no output'
    fi

    step 'deciding a switch'

    assert_equal 'switch' "$(plan_of "$hda" output:analog-stereo+input:analog-stereo "$CARDS_HDA_UNPLUGGED")" \
        'unplugged, the duplex profile is available and keeps the output'
    assert_equal "refuse|input:analog-stereo is not available on $hda" \
        "$(plan_of "$hda" input:analog-stereo "$CARDS_HDA_UNPLUGGED")" \
        'the input-only profile is not available, which PulseAudio would switch to anyway'
    assert_equal "refuse|output:hdmi-stereo+input:analog-stereo is not available on $hda" \
        "$(plan_of "$hda" output:hdmi-stereo+input:analog-stereo "$CARDS_HDA_UNPLUGGED")" \
        'an unavailable profile is refused before what it would do to the output is weighed'
    assert_equal 'already' "$(plan_of "$hda" output:analog-stereo "$CARDS_HDA_UNPLUGGED")" \
        'the profile the card is on needs no switch'
    assert_equal 'refuse|off has no input' "$(plan_of "$hda" off "$CARDS_HDA_UNPLUGGED")" \
        'a profile with no input is no use to the input'
    assert_equal "refuse|$hda has no profile called output:analog-stereo+input:nope" \
        "$(plan_of "$hda" output:analog-stereo+input:nope "$CARDS_HDA_UNPLUGGED")" \
        'a profile that does not exist is refused by name'
    assert_equal 'refuse|alsa_card.gone is not among the cards PulseAudio lists' \
        "$(plan_of alsa_card.gone output:analog-stereo+input:analog-stereo "$CARDS_HDA_UNPLUGGED")" \
        'so is a card that does not exist'

    assert_equal 'switch' "$(plan_of "$usb" output:iec958-stereo+input:analog-stereo "$CARDS_USB_AND_HDA")" \
        'on the USB adapter, adding the analog input to the S/PDIF output it is on'
    assert_equal "refuse|output:analog-stereo+input:iec958-stereo would change the output $usb plays to from output:iec958-stereo to output:analog-stereo" \
        "$(plan_of "$usb" output:analog-stereo+input:iec958-stereo "$CARDS_USB_AND_HDA")" \
        'an available profile that moves the output is refused'
    assert_equal "refuse|input:iec958-stereo would change the output $usb plays to from output:iec958-stereo to none" \
        "$(plan_of "$usb" input:iec958-stereo "$CARDS_USB_AND_HDA")" \
        'so is one that drops it'
    assert_equal 'already' "$(plan_of "$hda" output:analog-stereo+input:analog-stereo "$CARDS_USB_AND_HDA")" \
        'the second card is judged on its own active profile'

    assert_equal 'output:analog-stereo+input:analog-stereo' \
        "$(sendspin::card_profile_candidates "$hda" "$CARDS_HDA_UNPLUGGED")" \
        'the profiles a refusal suggests are exactly the ones that would switch'
    assert_equal 'output:iec958-stereo+input:analog-stereo' \
        "$(sendspin::card_profile_candidates "$usb" "$CARDS_USB_AND_HDA")" \
        'on the adapter too'
}

main() {
    printf 'pactl parse: checking %s\n' "$SCRIPT_DIR/../rootfs/usr/lib/sendspin-cli/common.sh"

    check_client_conf_default_sink
    check_server_default_sink
    check_input_source
    check_app_input
    check_card_profiles
    check_sink_state
    check_mute_and_level
    check_garbage_is_no_answer
    check_active_port
    check_the_warning
    check_the_port_warning
    check_the_report_line
    check_the_bail_outs
    check_end_to_end

    if [ "$FAILURES" -ne 0 ]; then
        printf '\npactl parse: %d check(s) failed\n' "$FAILURES" >&2
        exit 1
    fi
    printf '\npactl parse: every check passed\n'
}

main
