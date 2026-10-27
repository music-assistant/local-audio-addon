#!/usr/bin/env python3
"""
A Music Assistant stand-in for the stream-hook checks in scripts/smoke_test.sh.

--hook-start and --hook-stop fire on a stream starting and ending, and nothing else reaches
them: no control-socket command starts a stream, and the player runs one only for a server
that sends it. So the only way to assert that a hook *ran* -- rather than that a container
carrying one came up -- is to be the server that starts the stream.

Since sendspin-cli 0.4 every connection is a Noise KKpsk2 session and an unpaired server may
not play, so this is a real Sendspin server rather than a hand-rolled one: aiosendspin, pinned
in scripts/smoke_requirements.txt. A second protocol implementation in this repository would
be one more thing to keep in step with the spec, and the wrong one to trust.

Pairing uses the player's own token, exactly as a user pasting it into Music Assistant would:
the suite reads it with `sendspin-cli pair-token` and writes it to --token-file, which this
polls. So the token path is exercised end to end on every run.

Each milestone is recorded in --marker, one per line, and the smoke suite asserts what it finds
there -- a check whose player never connected would otherwise assert the absence of a hook's
output and pass:

    connected     the player dialled in and finished its handshake
    paired        a pairing with the token from --token-file succeeded
    stream-start  audio was committed to the paired player's group
    stream-end    the stream was stopped

Runs on the host rather than in a container of its own, the way scripts/fake_supervisor.py
does; the container under test reaches it through `--add-host`.
"""

import argparse
import asyncio
import logging
import socket
from pathlib import Path

from aiosendspin.models.types import PairMethod
from aiosendspin.noise import Identity, InMemoryServerPairingStore, decode_psk_token
from aiosendspin.noise.pairing import PairingAttempt
from aiosendspin.server import AudioFormat, ClientConnectedEvent, SendspinServer

# Silence at CD-ish rates: what the player decodes does not matter, only that a stream ran.
STREAM_FORMAT = AudioFormat(sample_rate=48000, bit_depth=16, channels=2)
CHUNK_MS = 100

POLL_S = 0.2

# Every wait here is generous for a loaded runner, and returns as soon as its condition holds.
WAIT_S = 60


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--marker", required=True, help="file to record each milestone in"
    )
    parser.add_argument(
        "--token-file",
        required=True,
        help="file the suite writes the player's pairing token into; polled until it appears",
    )
    parser.add_argument(
        "--stream-ms",
        type=int,
        default=1000,
        help="how long the stream runs before it is stopped",
    )
    return parser.parse_args()


def free_port():
    # Picked here and handed to the server rather than read back out of it: aiosendspin has no
    # public way to report a port it was asked to choose. The window between the two binds is
    # the only race, and nothing else on a runner is reaching for ephemeral ports in it.
    with socket.socket() as probe:
        probe.bind(("0.0.0.0", 0))
        return probe.getsockname()[1]


async def wait_for(predicate, what):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + WAIT_S
    while not predicate():
        if loop.time() > deadline:
            raise TimeoutError(f"timed out waiting for {what}")
        await asyncio.sleep(POLL_S)


async def run(args):
    def record(outcome):
        with open(args.marker, "a", encoding="utf-8") as handle:
            handle.write(outcome + "\n")
        print(f"fake-server: {outcome}", flush=True)

    loop = asyncio.get_running_loop()
    server = SendspinServer(
        loop,
        Identity.generate(),
        "Smoke Test Server",
        pairing_store=InMemoryServerPairingStore(),
    )

    connected = set()

    def on_event(_server, event):
        if isinstance(event, ClientConnectedEvent):
            connected.add(event.client_id)

    server.add_event_listener(on_event)

    port = free_port()
    await server.start_server(port=port, discover_clients=False)
    print(f"fake-server: listening on port {port}", flush=True)

    token_file = Path(args.token_file)
    await wait_for(lambda: token_file.exists() and token_file.read_text().strip(), "the token")
    token = decode_psk_token(token_file.read_text().strip())

    await wait_for(lambda: token.client_id in connected, "the player to connect")
    record("connected")

    await server.initiate_pairing(
        token.client_id,
        PairingAttempt(
            method=PairMethod.PAIRING_PSK,
            pairing_psk=token.pairing_psk,
            client_id=token.client_id,
        ),
    )
    record("paired")

    client = server.get_client(token.client_id)
    await wait_for(lambda: client.is_connected, "the paired player to reconnect")

    stream = client.group.start_stream()
    silence = bytes(STREAM_FORMAT.sample_rate * CHUNK_MS // 1000 * 2 * STREAM_FORMAT.channels)
    started = False
    for _ in range(max(1, args.stream_ms // CHUNK_MS)):
        stream.prepare_audio(silence, STREAM_FORMAT)
        await stream.commit_audio()
        if not started:
            record("stream-start")
            started = True
        await stream.sleep_to_limit_buffer(500_000)

    client.group.stop_stream()
    record("stream-end")

    # Held open rather than torn down, so the player sees a stream end and not a dropped
    # server. The suite kills this process when the check is done.
    await asyncio.Event().wait()


def main():
    args = parse_args()
    logging.basicConfig(level=logging.INFO, format="fake-server: %(name)s: %(message)s")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
