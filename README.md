# Music Assistant local audio

Plays Music Assistant audio out of the machine it runs on — through ALSA, or
through a PulseAudio or PipeWire server the host already runs.

This repository is packaging only. The player itself is
[`sendspin-cli`](https://github.com/Sendspin/sendspin-cpp-cli), which lives
upstream and is built here from a pinned ref — it is never forked into this
repository. What this repository adds is a container image, and the Home
Assistant app manifest in `local_audio/` that wraps the same image.

The image runs as root, like the Open Home Foundation's other app images.

Discovery and playback are local-network only. There is no reverse-proxy,
HTTPS or overlay-network story, and deployments other than Docker Compose and
the Home Assistant app are not supported.

## Quickstart with Docker Compose

```sh
docker compose up -d
docker compose logs -f
```

Music Assistant discovers the player over mDNS and connects back in on port
8928, which is why the container needs `network_mode: host`. Once the log reads

```
I cli: sendspin-cli 0.1.5 listening on port 8928 as "Living Room" (output: default, mDNS: dns_sd (avahi-compat))
I mdns: advertising _sendspin._tcp. as "Living Room" on port 8928 (path /sendspin)
```

the player is waiting to be picked up in Music Assistant's Sendspin provider.

This image's own configuration is nine environment variables, all optional:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SENDSPIN_NAME` | `Local Audio` | Name shown in Music Assistant |
| `SENDSPIN_OUTPUT` | `default` | Where the audio goes, see below |
| `SENDSPIN_LOG_LEVEL` | `info` | `none`, `error`, `warn`, `info`, `debug`, `verbose` |
| `SENDSPIN_SERVER` | unset | Dial out to one server instead of being discovered |
| `SENDSPIN_BUFFER_MS` | unset (the player uses 100) | How much audio the output keeps buffered, `10`–`2000` |
| `SENDSPIN_HOOK_START` | unset | A command run when a stream starts |
| `SENDSPIN_HOOK_STOP` | unset | A command run when a stream stops |
| `SENDSPIN_AUDIO_FORMAT` | unset | Pin a preferred `<codec>:<rate>:<depth>:<channels>`, Compose only |
| `SENDSPIN_ID` | derived from the interface MAC | This player's stable identity, Compose only |

`SENDSPIN_BUFFER_MS` is how much audio the backend keeps queued up. Raise it
where the sound breaks up on a busy or slow machine, at the cost of a longer
wait when a track starts or is seeked; the Home Assistant app offers the same
setting as **Audio buffer**. A value that is not a whole number between 10 and
2000 stops the container rather than reaching the player, so a typo here is a
line in the log and, under the restart policy, a container that keeps retrying
it — not a player quietly running on a figure nobody meant.

`SENDSPIN_HOOK_START` and `SENDSPIN_HOOK_STOP` are for switching something on
while the music plays — an amplifier relay, a light. Each is a shell command,
run through `sh -c` inside this container every time a stream starts or ends:

```yaml
SENDSPIN_HOOK_START: curl -fsS -X POST http://192.168.1.20/relay/0?turn=on
SENDSPIN_HOOK_STOP: curl -fsS -X POST http://192.168.1.20/relay/0?turn=off
```

The command runs with what the container has — `curl` and `jq` come with the Home
Assistant base image this is built on, alongside a small Debian userland — not the
host's tools, and not the host's network stack unless the container has
`network_mode: host` as the shipped Compose file does. It does not hold up
playback: the player starts it and carries on, and a command that exits non-zero
is a warning in the log rather than a player that stops. Its output goes to the
log too.

What the event was arrives in the environment:

| Variable | Set when |
| --- | --- |
| `SENDSPIN_EVENT` | always, as `start` or `stop` |
| `SENDSPIN_SERVER_ID`, `SENDSPIN_SERVER_NAME` | the server said who it was |
| `SENDSPIN_SERVER_URL` | this player dialled out, so there is a URL it dialled |
| `SENDSPIN_CLIENT_ID` | `SENDSPIN_ID` was set; the derived default is not exposed |
| `SENDSPIN_CLIENT_NAME` | always, as the player's name |

Anything unknown for an event is unset rather than empty, so `[ -n "$SENDSPIN_SERVER_ID" ]`
means what it looks like. To read one of them inside a command written in
`docker-compose.yml`, double the dollar — `$$SENDSPIN_EVENT`. A single `$` is
expanded by `docker compose` itself before the container starts, so the hook is
handed an empty string, and a command that quietly does nothing is a hard fault to
track down. The Home Assistant app offers the same two as
**Command to run when playback starts** and **…stops**, and its AppArmor profile
had to be widened to let the player exec anything at all before they would work;
the section on the app below covers what that grants.

The last two variables in the table are deliberately Compose-only, and the Home
Assistant app has no field for either.

`SENDSPIN_AUDIO_FORMAT` is for the DAC that will only play one shape properly.
It moves that format to the front of the list this player advertises, so a
server encodes to it in preference to anything else; everything the device takes
is still offered behind it. The sharp edge is that a format the output cannot
advertise is a refusal to start rather than a fallback, and under the shipped
`docker-compose.yml`'s `restart: unless-stopped` that is a container looping on
the same refusal. So check the device with `sendspin-cli -l` before pinning
one. The app has no such DAC to hold: it plays through Home Assistant's
PulseAudio, which converts.

`SENDSPIN_ID` is for running two of these on one machine. They would otherwise
both derive the same identity from the host's network interface MAC, and a
server files volume, group membership and pairing under that identity — so the
two players collide, and each setting lands on whichever of them connected last.
Giving each container its own value separates them. One player per machine, the
app included, has no collision to solve and should leave it unset.

The two sound-server backends also read the environment their own client
libraries define — `PULSE_SERVER`, `PULSE_COOKIE` and `PIPEWIRE_REMOTE` — which
the sections below cover.

## Choosing an output

The image builds five of the player's backends: `null`, `stdout`, `alsa`,
`pulse` and `pipewire`. `SENDSPIN_OUTPUT` is read in the order upstream
documents — a reserved name first, then `<backend>:<device>` split on the first
colon, then anything else as an ALSA PCM name. So `null` discards the audio,
which is useful for checking that discovery works before wiring up a sound card;
`pulse` and `pipewire` reach a sound server on the host; and `default`, `hw:1,0`
or any other unclaimed name is an ALSA PCM.

To see what the container can reach:

```sh
docker exec ma-local-audio sendspin-cli -l
```

It lists the ALSA PCMs, and — where a server is reachable — that server's sinks
or nodes as well, under the `-o pulse:<sink>` and `-o pipewire:<node>` forms
that name them. Set `SENDSPIN_OUTPUT` to one of those names.

### ALSA

The image ships no `/etc/asound.conf`. As a Home Assistant app it gets one
from the Supervisor, which routes `default` to Home Assistant's PulseAudio;
under Compose there is none, so `default` is ALSA's own default over `/dev/snd`
— usually the first card, not whatever the host routes its audio through. Name
the card explicitly if that is not the one you want, for example `hw:1,0`.

### PulseAudio

Bind-mount the host's PulseAudio socket, point `PULSE_SERVER` at where it landed
and set `SENDSPIN_OUTPUT` to `pulse`, or to `pulse:<sink>` for a specific one;
`docker-compose.yml` carries the mount and the environment commented out. A bare
`pulse` follows whichever sink the server calls default, resolved afresh at every
stream.

A per-user socket lives under that user's `XDG_RUNTIME_DIR`, which is `0700`,
and that is usually less of an obstacle than it looks: the bind mount is
resolved by the Docker daemon, which is root, and the container itself runs as
root with `CAP_DAC_OVERRIDE`. Neither the mode nor the uid is what bites. What
does, on a Fedora or RHEL host, is SELinux — a bind mount of a host path needs
`:z` (or `:Z`) on it, or the container is denied the socket with no explanation
worth the name. Under rootless Docker or `userns-remap` the `0700` becomes real,
and there a system-wide PulseAudio is the way out.

The client also needs the cookie that authenticates it, mounted and named in
`PULSE_COOKIE`, unless the socket is configured `auth-anonymous=1`.

### PipeWire

The same shape: bind-mount the host's PipeWire socket, name it in
`PIPEWIRE_REMOTE` — a value starting with `/` is taken as an absolute socket
path rather than a name — and set `SENDSPIN_OUTPUT` to `pipewire`, or
`pipewire:<node>`. Mounting the whole runtime directory and setting
`XDG_RUNTIME_DIR` works too, and is what a bare remote name resolves against;
reach for it if the absolute form is ignored. The SELinux note above applies
here as well.

On a PipeWire host, `pipewire` and `pulse` reach the same server — `pipewire-pulse`
is on every PipeWire desktop, and a libpulse client goes through it. What the
native one adds, in [upstream's own
account](https://github.com/Sendspin/sendspin-cpp-cli#choosing-an-output), is
that only a native client can name a *node*: `pipewire-pulse` presents sinks, which
is a compatibility view of the graph rather than the graph. It also has no
compatibility layer in the audio path at all. The case where it is the only
route is narrower than it sounds — a machine running PipeWire with
`pipewire-pulse` not installed, where a libpulse client has nothing to connect
to.

### Upgrading from 0.1.9 or earlier

Only Compose deployments are affected, and only those setting `SENDSPIN_OUTPUT`
to exactly `pulse` or `pipewire`. Those two names used to fall through to ALSA's
plugin PCMs of the same name; they now select the native backends, which reach
the same server by a different route. The player says so in its log at every
start. Nothing needs changing to keep working, and `alsa:pulse` and
`alsa:pipewire` are the way back to the old behaviour if you want it.

The Home Assistant app is unaffected: it offers no output option, so no value
set there can have changed meaning. Were one to arrive from somewhere else, the
same log line covers it — the check is on the value, not on where it came from.

## Discovery, Avahi and D-Bus

The image bundles `dbus` and `avahi-daemon` so that a plain
`docker compose up` is discoverable with no host setup. Whether they actually
start is decided once, at container start, and the container logs which branch
it took:

- a D-Bus socket is already present at `/var/run/dbus/system_bus_socket`,
  because the host's bus was bind-mounted in — the bundled pair stays down and
  the player advertises through the host's Avahi. Use this when the host already
  runs Avahi, since `network_mode: host` would otherwise put two responders on
  port 5353;
- `SENDSPIN_SERVER` names a plain host or URL — the player dials out and the
  Sendspin spec suppresses the advertisement, so the bundled pair stays down.
  An `mdns:` prefixed value still needs mDNS to resolve the server, so there
  the pair does start;
- otherwise the bundled pair starts.

## State

`/data` holds the player's persistent state — volume, mute, static delay and
the last server it talked to — under `/data/state`. The Compose file keeps it in
a named volume, so a recreated container comes back at the same volume level.

## Bumping the player

`SENDSPIN_CLI_REF` and `SENDSPIN_CLI_SHA` at the top of the `Dockerfile` pin the
upstream ref and the commit it must resolve to. Change both together: the build
compares the clone's `HEAD` against `SENDSPIN_CLI_SHA` and aborts on a mismatch,
so a tag that has been repointed fails the build rather than silently shipping
different code.

The pin is one level deep. Upstream's CMake pulls in the `Sendspin/sendspin-cpp`
core by *tag*, not by commit, so that layer is pinned by upstream rather than
here. The tag in effect for a built image is recorded, along with both ARGs, in
`/usr/share/sendspin-cli/BUILD-INFO.txt`:

```sh
docker exec ma-local-audio cat /usr/share/sendspin-cli/BUILD-INFO.txt
```

`BUILD_FROM` selects the Home Assistant base image and defaults to the amd64
one. Building on another architecture means passing the matching digest, which
is what CI will do per architecture once it lands. The build stage is pinned to Debian's
multi-arch *index* digest so that it resolves to whichever architecture is being
built; replacing it with a per-architecture digest would quietly build the
binary for the wrong one.

## Home Assistant app

`local_audio/` is the app manifest, wrapping this same image, so the runtime
behaviour described above is shared. It reads its `name`, `log_level`, `server`,
`buffer_ms`, `hook_start` and `hook_stop` from the app options instead of the
environment.

The two hooks are the one option here that is code rather than a value, and they
are the reason this app's AppArmor profile grants the player an exec at all. The
player runs a hook by exec'ing the shell, and its child profile in
`local_audio/apparmor.txt` permitted no exec of anything before that — so
without a rule the hooks would be configured, started, and fail — the log
would say the hook exited 127, which is a shell the player could not execute, and
nothing anywhere in the container would say that AppArmor was why. The rule is `/usr/bin/** ix`, which has to reach `/usr/bin/dash` because
that is where `/bin/sh` resolves to in this image and AppArmor mediates the
resolved path — a rule written against `/bin/sh` would load and then deny. It
covers the programs a hook runs as well as the shell, because a hook that could
run only the shell's builtins would not be a feature. `/usr/sbin` is deliberately
not granted beside it.

They are `ix` — the shell and everything it starts run under the player's own
profile — rather than a transition into a profile written for hooks, which would
be the better grant and cannot be expressed. A child profile is reachable only by
name; the one name form that needs none is `cx`, which resolves inside the
profile it is written in, and that profile is already a child. AppArmor allows
one level of child profile and no more: the second level loads and the transition
is then refused at exec with `profile transition not found`. Every other form
needs an absolute profile name, and this file may not use one because the
Supervisor rewrites the top-level name to the installed slug before loading.

What that costs, plainly: someone who takes this player over through the network
can now start a shell, and through it run any program in the image. What it does
not do is widen what any of them may touch — they all run under the same profile,
holding no capability, able to open only the files it lists. No file rule was added
alongside it: a hook writes where the player writes, or nowhere.

The other route to that shell is the one the feature is for, and it is worth being
equally plain about: anyone who can edit this app's options can run a command as
root inside a container with `host_network: true` and Home Assistant's audio mapped
in. That is not a privilege this change creates — someone with app-configuration
access on a Home Assistant machine can already install a terminal app and do more
than that — but it does mean the two fields deserve the same care as any other
root shell on the box.

The app plays through the PulseAudio that Home Assistant maps in, and the sound
card is chosen in the app's own Audio panel — it offers no output option of its
own. It cannot open a card directly: the Supervisor grants an app no cgroup rule
for the sound devices unless the app also asks for every other device on the
machine. Naming an output at all is therefore a Compose-only capability — `hw:`
and `plughw:` PCMs, and the `pulse` and `pipewire` backends alike — which is the
reason to run the container rather than the app for an exclusively-held DAC.

The app reaches Home Assistant's PulseAudio through ALSA's plugin PCM rather
than through the native `pulse` backend, and stays there. That bridge is what
`default` means under the `/etc/asound.conf` the Supervisor renders, it is what
the app's AppArmor profile grants, and it is what the silent-output check below
reads its sink from — libpulse substitutes the *client* default for the plugin's
NULL device, which is why that check reads `default-sink` from `client.conf`.
The native backend would name its own sink and leave the check reporting on one
the player is not using. Nothing about the current path is broken, so it is left
alone.

The app also reads that PulseAudio sink once at start and names it in the log,
with its level and the port it is routed to. If the sink is muted or at zero it
warns with the `ha audio volume output` command that raises it; if the sink is
routed to a port PulseAudio reports as unavailable — a socket with nothing in
it — it says so and points at the Audio panel; and if the selected sink is not
in the list at all, or there are no outputs, it says that too. Each of those is
silence at every Music Assistant volume, and none of them is something the
player can report, since it applies volume as software gain rather than through
a mixer and never opens a mixer to ask. It never writes to the sink: the level
and the routing are shared with every other app and belong to the Audio panel.
The check is app-only: under Compose there is no PulseAudio to ask, and it does
nothing.

## Cutting a release

The version is bumped by the pull request that makes the change, not at release
time: `local_audio/config.yaml` carries it and `local_audio/CHANGELOG.md` gains
its section as part of the work itself. Cutting a release is confirming that
those two say what is about to be published, and then tagging it.

A lightweight `vMAJOR.MINOR.PATCH` tag on a commit on `main` is the only thing
that publishes. `.github/workflows/release.yml` triggers on that and on nothing
else — no branch push, no pull request, no `workflow_dispatch` — so pushing the
tag is the decision, and there is no route to a published image that does not
go through it.

```sh
git tag v0.1.7 <the commit on main> && git push origin v0.1.7
```

The run opens with a preflight, ahead of the matrix so that a mistyped tag
fails in a minute rather than after two half-hour builds. It refuses a tag that
disagrees with the manifest's `version:` — the store card pulls `image:version`,
so a manifest naming a tag nobody pushed is an app that cannot install — and it
refuses anything that is not `vMAJOR.MINOR.PATCH`, which is how `v0.1.7rc1` is
turned away rather than published as `latest` with nobody having decided that
it should be.

Then one leg per architecture builds and pushes its image **by digest**, under
no tag at all, and pulls that digest back to smoke-test the bits that were
pushed rather than the ones that were built. Only with both legs green does the
manifest job tag `:VERSION` and `:latest`, both from one index so that `latest`
cannot come to mean something the version tag does not. A release that fails
halfway therefore leaves nothing installable behind — only unreferenced
digests, which no tag names and nothing will pull.

Last, and only once the manifest is published, the workflow writes the GitHub
Release. Its body is assembled from `local_audio/CHANGELOG.md` by
`scripts/release_notes.sh`: a line naming the image and the two tags it went out
under, then every `## X.Y.Z` section after the previous release's version
through this one. That range is what accounts for a skipped version — not every
bump is tagged, and 0.1.3 and 0.1.4 were bumped and then delivered by `v0.1.5` —
so the accounting is mechanical rather than a convention someone has to
remember, and a tag whose version has no changelog section fails the job instead
of publishing an empty body. A release wanting more than the sections say is
still edited by hand afterwards.

Attached to it is a `docker-compose.yml` pinned to the released image, which
`scripts/compose_pinned.sh` generates from the one in this repository by
replacing `build: .` with the image that was published. It is generated rather
than kept as a second copy so the two cannot drift, and it is never committed.

This lands after `v0.1.8`, so `v0.1.6`, `v0.1.7` and `v0.1.8` have tags and
published images but no Release object; backfilling them is a manual job.

Once the whole workflow succeeds — the Release included —
`.github/workflows/sync-store.yml` mirrors `local_audio/` from the released
commit into the store repository and opens a pull request there; that is the
second half of the flow, and **Store card sync** below covers it. A person
merges that pull request, so between the release finishing and the merge ghcr
carries a version the store does not yet offer. A release job that failed after
the image published therefore holds the store bump back too, and re-running the
workflow is what releases it.

## Store card sync

The card the store offers this app from lives in
[`music-assistant/home-assistant-addon`](https://github.com/music-assistant/home-assistant-addon),
and it names both the image and the version to pull, so it has to be bumped for
every release. `.github/workflows/sync-store.yml` does that: once a release has
published, it mirrors `local_audio/` from the released tag into that repository
and opens a pull request there for somebody to merge. It mirrors the whole
directory rather than the version line, so a release that changed the app's
README, translations or apparmor profile carries those across too. The card's
`icon.png` and `logo.png` belong to the store repository and are left alone —
and if this repository ever starts shipping either, the sync stops and says so
rather than deciding on its own which copy wins.

The sync reads a `STORE_SYNC_TOKEN` secret from this repository: a fine-grained
token scoped to `music-assistant/home-assistant-addon` alone, granting
`contents: write` and `pull-requests: write`. Creating it is a manual step, and
until it exists every release fails its sync and says so. The pull requests it
opens are authored by whatever account owns the token; a machine account keeps
the store's history legible if a personal one reads oddly there. A sync that failed
quietly would have no symptom at all: the store would go on offering the
previous version, every install would keep working, and the release would
simply never arrive.

## Health

The image's `HEALTHCHECK` asks the player over its control socket, and, when the
bundled daemons are running, checks that `avahi-daemon` is alive too — a player
that cannot advertise is undiscoverable, which should be visible rather than
look like an idle instance. To query it by hand:

```sh
docker exec ma-local-audio sendspin-cli status \
    --control-socket /run/sendspin-cli/control.sock
```

The Home Assistant Supervisor ignores `HEALTHCHECK`, so this is for the Compose
audience.

A player that exits with an error stops the whole container rather than being
restarted in place: the config is rendered from the environment or the app
options, so nothing can change between attempts, and a stopped container is
visible where an internal crash loop is not. Compose's `restart: unless-stopped`
is the retry policy.

## Licence

Apache-2.0, see [LICENSE](LICENSE). `sendspin-cli` is Apache-2.0 upstream.
