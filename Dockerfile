# The player lives upstream and is built here from a pinned ref; this repo never
# forks it. Bump both ARGs together: the SHA is checked against the clone, so a
# repointed tag fails the build instead of quietly shipping different code.
ARG SENDSPIN_CLI_REF=v0.1.6
ARG SENDSPIN_CLI_SHA=6b20f8582ffe7ff4fe467d5c4cd23dea0264a835

# ghcr.io/home-assistant/amd64-base-debian:trixie, which ships s6-overlay v3 and
# bashio. CI overrides this with the digest for the architecture it is building;
# those per-arch digests live in .github/workflows/build.yml and release.yml, and
# a bump must move all three files together, staying on one Debian release.
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian@sha256:9281ee991c28532ddae10114ac84750f4aca287a496f6e19583f3a750ad5e786

# debian:trixie-slim, by multi-arch index digest rather than a per-architecture
# one, so that a cross-build resolves this stage to the target's architecture.
# Must stay on the same release as BUILD_FROM above: the binary built here is
# linked against that image's libc.
FROM debian@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132 AS build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG SENDSPIN_CLI_REF
ARG SENDSPIN_CLI_SHA

# PortAudio is deliberately absent: the route it takes to a Linux sound card is
# ALSA, which this image already has, so it would be a second way to reach the
# same devices. libpulse-dev and libpipewire-0.3-dev build the two native
# sound-server backends, which reach the same servers ALSA's plugin PCMs do but
# not through a plugin -- see the runtime stage below for what that buys and
# what it costs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        git \
        libasound2-dev \
        libavahi-compat-libdnssd-dev \
        libpipewire-0.3-dev \
        libpulse-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --depth 1 --branch "${SENDSPIN_CLI_REF}" \
        https://github.com/Sendspin/sendspin-cpp-cli.git . \
    && cloned="$(git rev-parse --verify HEAD)" \
    && if [ "${cloned}" != "${SENDSPIN_CLI_SHA}" ]; then \
        echo "sendspin-cli ${SENDSPIN_CLI_REF} is ${cloned}, expected ${SENDSPIN_CLI_SHA}" >&2; \
        exit 1; \
    fi

# The flags state intent and the greps enforce it; neither does the other's job.
# Upstream auto-detects every backend, so a flag left off would make this image's
# shape a property of whatever the build host had installed -- but asking is not
# getting, and `=ON` is only a request: a missing -dev dependency does not fail
# the configure step, it drops the backend and carries on. The greps are what
# turns that into a failed build. They are the only guard in this stage;
# scripts/smoke_test.sh asserts the same five off the binary that shipped.
RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DSENDSPIN_CLI_WITH_MDNS=ON \
        -DSENDSPIN_CLI_WITH_PORTAUDIO=OFF \
        -DSENDSPIN_CLI_WITH_PULSE=ON \
        -DSENDSPIN_CLI_WITH_PIPEWIRE=ON \
        -DSENDSPIN_CLI_BUILD_TESTS=OFF \
        | tee configure.log \
    && grep -qE '^-- sendspin-cli audio backends: null, stdout, alsa, pulse, pipewire$' configure.log \
    && grep -qE '^-- sendspin-cli mDNS: dns_sd \(.*libdns_sd\.so.*\)$' configure.log

RUN cmake --build build -j"$(nproc)"

RUN DESTDIR=/stage cmake --install build --component sendspin-cli

# SENDSPIN_GIT_TAG is the Sendspin/sendspin-cpp tag upstream's CMake pulls in via
# FetchContent, so it is the transitive pin this image inherits.
RUN core_tag="$(sed -n 's/^set(SENDSPIN_GIT_TAG "\([^"]*\)".*/\1/p' CMakeLists.txt)" \
    && test -n "${core_tag}" \
    && printf 'SENDSPIN_CLI_REF=%s\nSENDSPIN_CLI_SHA=%s\nSENDSPIN_GIT_TAG=%s\n' \
        "${SENDSPIN_CLI_REF}" "${SENDSPIN_CLI_SHA}" "${core_tag}" \
        > /build-info.txt


FROM ${BUILD_FROM}

ARG SENDSPIN_CLI_REF

LABEL \
    org.opencontainers.image.source="https://github.com/music-assistant/local-audio-addon" \
    org.opencontainers.image.version="${SENDSPIN_CLI_REF}" \
    org.opencontainers.image.licenses="Apache-2.0"

# libasound2-plugins carries the ALSA-to-Pulse bridge, which is what makes the
# `default` output work on Home Assistant OS, where /etc/asound.conf routes
# `default` to Home Assistant's PulseAudio. libstdc++6 is already present in any
# image with apt, but the player links it, so it is named rather than inherited.
#
# pulseaudio-utils is `pactl`, which sendspin-init uses to read the selected
# sink's level and warn if it is silent. Two packages for that check --
# libasound2-plugins already brings libpulse0 -- and no Supervisor permission,
# where the /audio API route would have needed one.
#
# What the two native backends buy over reaching the same servers through ALSA's
# `pulse` and `pipewire` plugin PCMs, which is the route that was already here:
# `-l` can enumerate the server's sinks and nodes, so `-o` can name one where
# the plugin route needs PULSE_SINK or an .asoundrc; the host's mixer sees a
# stream called sendspin-cli rather than one more "ALSA plug-in"; and the
# playout timing is the server's own. That last one is why this is not cosmetic
# for this player: through the plugin, snd_pcm_delay() reports the plugin's
# buffering rather than the server's, and a synchronised multi-room player is
# exactly the thing that cannot afford a sync figure about the wrong buffer.
#
# The native PulseAudio backend costs nothing at runtime -- libpulse0 is already
# here, brought in above. libpipewire-0.3-0t64 is the whole price of the PipeWire
# one, and it is not small: it hard-depends on libspa-0.2-modules of the same
# version, whose own dependencies bring an LV2 host and a resampler with it.
# Twelve packages in all -- libpipewire-0.3-0t64 and libspa-0.2-modules
# themselves, then libabsl20240722, libebur128-1, libfftw3-single3, liblilv-0-0,
# libmysofa1, libserd-0-0, libsord-0-0, libsratom-0-0, libwebrtc-audio-processing-1-3
# and libzix-0-0 -- for about 16.6 MB, measured as the difference over the set
# above on debian:trixie-slim. libsndfile1 is a dependency of that set too and
# is absent from this list only because pulseaudio-utils already brought it.
#
# Upstream is clear that PipeWire reaches no host libpulse cannot, since
# pipewire-pulse is on every PipeWire desktop. What it buys is node selection --
# pipewire-pulse presents sinks, a compatibility view of the graph rather than
# the graph -- and no compatibility layer in the audio path at all. The hosts it
# adds outright are the narrow case: a machine running PipeWire with no
# pipewire-pulse installed, where a libpulse client finds nothing to connect to.
#
# Note the t64 suffix: there is no plain libpipewire-0.3-0 in trixie. Trixie
# ships PipeWire 1.4.2, well past the 0.3.64 upstream requires for the node
# targeting that makes `-o pipewire:<node>` name a node rather than be ignored.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        avahi-daemon \
        dbus \
        libasound2-plugins \
        libasound2t64 \
        libavahi-compat-libdnssd1 \
        libpipewire-0.3-0t64 \
        libstdc++6 \
        pulseaudio-utils \
    && rm -rf /var/lib/apt/lists/*

# The base image sets this too, but the s6-overlay default is to carry on: the
# sendspin-init oneshot reports a Supervisor it cannot reach by failing, and
# that has to stop the container rather than leave the services to flounder.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# The Supervisor stops an add-on with the grace its `timeout` option asks for and
# calls a container that overruns it a failure. That option defaults to 10s and
# config.yaml does not set it, so the shutdown needs a budget it cannot exceed.
# Raising `timeout` instead would buy silence rather than a clean stop, and the
# add-on would still be sitting there not shutting down.
#
# The three longruns come down in sequence, each bounded by its own
# `timeout-kill` of 2000ms, and this is what bounds the tail after them: 3 * 2000
# + 2000 = 8s worst case, measured at 8.2s with all three deliberately wedged.
#
# The other two gracetimes s6-overlay documents are deliberately absent. They
# look relevant and are not: S6_SERVICES_GRACETIME only bounds the v2-style
# services under /etc/services.d, and S6_KILL_FINISH_MAXTIME only bounds
# /etc/cont-finish.d scripts. This image ships neither directory.
ENV S6_KILL_GRACETIME=2000

COPY --from=build /stage/usr/local/bin/sendspin-cli /usr/bin/sendspin-cli
COPY --from=build /build-info.txt /usr/share/sendspin-cli/BUILD-INFO.txt
COPY rootfs/ /

# No ENTRYPOINT or CMD: the base image's /init runs s6, which starts the
# services in rootfs/etc/s6-overlay.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD ["/usr/bin/container-healthcheck"]
