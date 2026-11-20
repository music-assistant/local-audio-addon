#!/bin/sh
#
# A stand-in `pactl` for scripts/smoke_test.sh, mounted over the image's own so the input card
# profile can be exercised without a PulseAudio. It answers as Home Assistant's audio plugin did
# on real HDA hardware with nothing plugged in: an output-only profile and no input source.
#
# Every invocation is appended to /tmp/fake-pactl.calls, which the suite reads back to prove what
# was and was not asked. A `set-card-profile` is remembered in /tmp/fake-pactl.profile, so the
# read-back after a switch sees it the way the real card would.

readonly CARD=alsa_card.pci-0000_00_1f.3
readonly SINK=alsa_output.pci-0000_00_1f.3.analog-stereo
readonly PROFILE_FILE=/tmp/fake-pactl.profile

printf '%s\n' "$*" >> /tmp/fake-pactl.calls

active=output:analog-stereo
[ -r "$PROFILE_FILE" ] && active=$(cat "$PROFILE_FILE")

case "$*" in
    'list cards')
        printf 'Card #0\n'
        printf '\tName: %s\n' "$CARD"
        printf '\tDriver: module-alsa-card.c\n'
        printf '\tProfiles:\n'
        printf '\t\tinput:analog-stereo: Analog Stereo Input (sinks: 0, sources: 1, priority: 65, available: no)\n'
        printf '\t\toutput:analog-stereo: Analog Stereo Output (sinks: 1, sources: 0, priority: 39268, available: yes)\n'
        printf '\t\toutput:analog-stereo+input:analog-stereo: Analog Stereo Duplex (sinks: 1, sources: 1, priority: 6565, available: yes)\n'
        printf '\t\toff: Off (sinks: 0, sources: 0, priority: 0, available: yes)\n'
        printf '\tActive Profile: %s\n' "$active"
        ;;
    'list short sources')
        printf '0\t%s.monitor\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tIDLE\n' "$SINK"
        case $active in
            *input:*) printf '1\talsa_input.pci-0000_00_1f.3.analog-stereo\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tIDLE\n' ;;
        esac
        ;;
    'list short sinks')
        printf '0\t%s\tmodule-alsa-card.c\ts16le 2ch 44100Hz\tIDLE\n' "$SINK"
        ;;
    'list sinks')
        printf 'Sink #0\n\tName: %s\n\tDescription: Built-in Audio Analog Stereo\n\tMute: no\n' "$SINK"
        printf '\tVolume: front-left: 52057 /  79%% / -6.00 dB,   front-right: 52057 /  79%% / -6.00 dB\n'
        ;;
    info)
        printf 'Server Name: pulseaudio\nDefault Sink: %s\nDefault Source: %s.monitor\n' "$SINK" "$SINK"
        ;;
    "set-card-profile $CARD "*)
        printf '%s\n' "${3}" > "$PROFILE_FILE"
        ;;
    set-card-profile*)
        printf 'Failure: No such entity\n' >&2
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
