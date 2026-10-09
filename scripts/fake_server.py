#!/usr/bin/env python3
"""
A stand-in for a Music Assistant server, for the stream-hook checks in scripts/smoke_test.sh.

--hook-start and --hook-stop fire on a stream starting and ending, and nothing else reaches
them: no control-socket command starts a stream, and the player runs one only for a server
that sends it. So the only way to assert that a hook *ran* -- rather than that a container
carrying one came up -- is to be the server that starts the stream.

This is deliberately not a Sendspin server, and not a WebSocket implementation either. It
speaks the four messages that get a player from connected to streaming and back:

    server/hello   the half of the handshake the player waits for before it is established
    client/hello   waited for, so the stream below is sent to a player that is listening
    stream/start   what fires on_stream_start, and with it the start hook
    stream/end     and what fires the stop hook

No audio follows the stream/start and none is needed: the stream lifecycle callback fires on
the message rather than on the first chunk. `client/time` is answered because the player asks
until it is; everything else it sends is read and dropped.

Out of scope of the RFC 6455 handling below, because nothing on this connection produces any
of it: frame fragmentation and continuation frames, extensions, close negotiation, and
payloads past 64 KiB in either direction. A binary frame is read and dropped; a fragmented
text one would be handed to the JSON parser in pieces and end the connection, which is the
honest failure for a file that is trying not to be a second protocol implementation.

Every connection is recorded in --marker, one outcome per line, and the smoke suite asserts
what it finds there: a check whose player never connected would otherwise assert the absence
of a hook's output and pass.

Runs on the host rather than in a container of its own, the way scripts/fake_supervisor.py
does. It initiates a WebSocket connection to the player's published port: the Sendspin server
is the WebSocket client, and the player needs no fixed-address server option.
"""

import argparse
import base64
import hashlib
import json
import os
import select
import socket
import struct
import time

# RFC 6455's handshake constant. The accept key is the client's key concatenated with this,
# hashed and base64'd, and a client that gets a different answer drops the connection.
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OPCODE_TEXT = 0x1
OPCODE_CLOSE = 0x8
OPCODE_PING = 0x9
OPCODE_PONG = 0xA

# The protocol version the player's own client/hello carries.
PROTOCOL_VERSION = 1

# What the player is told to expect. CD audio, and not negotiated against what the client/hello
# advertised: the stream lifecycle fires on any codec the player can build a header for, so
# picking a format here would be describing a negotiation this does not do.
STREAM_FORMAT = {"codec": "pcm", "sample_rate": 44100, "bit_depth": 16, "channels": 2}

# How often the loop looks at the stream deadline while no frame is arriving, and how long one
# frame's own reads may take once it has started.
POLL_S = 0.2
FRAME_TIMEOUT_S = 5

# The largest frame this will read, and the largest it can write -- the two-byte length field is
# the widest it encodes. The longest thing it sends is a server/hello of a couple of hundred
# bytes, and the longest the player sends is a client/hello of a few thousand.
MAX_FRAME_BYTES = 65535

# How long a stream runs before stream/end, in milliseconds. Long enough that the start hook has
# certainly run by the time the stop hook is asked for, short enough not to pad every check.
STREAM_MS = 1000


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--marker", required=True, help="file to record the outcome of every connection in"
    )
    parser.add_argument(
        "--port",
        type=int,
        required=True,
        help="the player's published WebSocket port on localhost",
    )
    parser.add_argument(
        "--connect-timeout",
        type=float,
        default=60,
        help="seconds to wait for the player to start listening",
    )
    return parser.parse_args()


def log(message):
    print(f"fake-server: {message}", flush=True)


def receive_exactly(connection, count):
    """`count` bytes from the socket, or None if it closed before they arrived."""
    chunks = []
    while count:
        chunk = connection.recv(count)
        if not chunk:
            return None
        chunks.append(chunk)
        count -= len(chunk)
    return b"".join(chunks)


def receive_frame(connection):
    """The next frame as (opcode, payload), or None once the peer has gone."""
    header = receive_exactly(connection, 2)
    if header is None:
        return None
    opcode = header[0] & 0x0F
    masked = bool(header[1] & 0x80)
    length = header[1] & 0x7F

    if length in (126, 127):
        width = 2 if length == 126 else 8
        extended = receive_exactly(connection, width)
        if extended is None:
            return None
        length = struct.unpack("!H" if width == 2 else "!Q", extended)[0]

    # The peer controls the declared length. Nothing the player sends comes near this bound.
    if length > MAX_FRAME_BYTES:
        log(f"refusing a frame declaring {length} bytes")
        return None

    mask = b""
    if masked:
        mask = receive_exactly(connection, 4)
        if mask is None:
            return None

    payload = b"" if length == 0 else receive_exactly(connection, length)
    if payload is None:
        return None
    if masked:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return opcode, payload


def send_frame(connection, opcode, payload):
    """One masked frame: this Sendspin server is the WebSocket client.

    The two-byte length is the widest this encodes, which is MAX_FRAME_BYTES above.
    """
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    else:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", length))
    mask = os.urandom(4)
    payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    connection.sendall(bytes(header) + mask + payload)


def send_message(connection, message):
    send_frame(connection, OPCODE_TEXT, json.dumps(message).encode())


def complete_handshake(connection, port):
    """Requests and verifies an upgrade without consuming any following WebSocket frame."""
    key = base64.b64encode(os.urandom(16)).decode()
    connection.sendall(
        (
            "GET /sendspin HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
    )
    buffer = b""
    while b"\r\n\r\n" not in buffer:
        # The player may send client/hello in the same packet as the upgrade response.
        chunk = connection.recv(1)
        if not chunk:
            return False
        buffer += chunk
        if len(buffer) > 16384:
            return False

    lines = buffer.decode("latin-1").split("\r\n")
    if lines[0].split()[:2] != ["HTTP/1.1", "101"]:
        return False
    headers = {}
    for line in lines[1:]:
        name, separator, value = line.partition(":")
        if separator:
            headers[name.strip().lower()] = value.strip()
    accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
    return (
        headers.get("sec-websocket-accept") == accept
        and headers.get("upgrade", "").lower() == "websocket"
        and "upgrade" in [
            token.strip().lower() for token in headers.get("connection", "").split(",")
        ]
    )


def now_us():
    return time.monotonic_ns() // 1000


class PlayerSession:
    """One player connection: handshake, hello, stream, end, then read until it goes."""

    def __init__(self, marker, port):
        self.marker = marker
        self.port = port

    def record(self, outcome):
        with open(self.marker, "a", encoding="utf-8") as handle:
            handle.write(outcome + "\n")

    def serve(self, connection):
        connection.settimeout(FRAME_TIMEOUT_S)
        if not complete_handshake(connection, self.port):
            self.record("no-websocket-handshake")
            log("a connection did not complete the WebSocket handshake")
            raise ValueError("the player refused the WebSocket upgrade")

        # Sent without waiting for the client/hello: the player's handshake completes when its
        # own hello has gone out and this one has arrived, in either order.
        send_message(
            connection,
            {
                "type": "server/hello",
                "payload": {
                    "server_id": "smoke-test-server",
                    "name": "Smoke Test Server",
                    "version": PROTOCOL_VERSION,
                    "active_roles": ["player"],
                    "connection_reason": "playback",
                },
            },
        )

        ends_at = None
        while True:
            if ends_at is not None and time.monotonic() >= ends_at:
                send_message(connection, {"type": "stream/end", "payload": {}})
                self.record("stream-end")
                log("sent stream/end")
                ends_at = None

            # Polled rather than blocked on, so that the stream/end above goes out on time
            # whether or not the player happens to be saying anything.
            if not select.select([connection], [], [], POLL_S)[0]:
                continue

            frame = receive_frame(connection)
            if frame is None:
                return
            opcode, payload = frame
            if opcode == OPCODE_CLOSE:
                return
            if opcode == OPCODE_PING:
                send_frame(connection, OPCODE_PONG, payload)
                continue
            if opcode != OPCODE_TEXT:
                continue

            message = json.loads(payload.decode())
            kind = message.get("type")

            if kind == "client/time":
                # Answered because the player asks until it is. The figures are this process's
                # own clock, which is enough for a player that is never sent any audio.
                send_message(
                    connection,
                    {
                        "type": "server/time",
                        "payload": {
                            "client_transmitted": message.get("payload", {}).get(
                                "client_transmitted", 0
                            ),
                            "server_received": now_us(),
                            "server_transmitted": now_us(),
                        },
                    },
                )
            elif kind == "client/hello":
                self.record("client-hello")
                log("client/hello received, starting a stream")
                send_message(
                    connection,
                    {"type": "stream/start", "payload": {"player": STREAM_FORMAT}},
                )
                self.record("stream-start")
                ends_at = time.monotonic() + STREAM_MS / 1000


def main():
    args = parse_args()

    deadline = time.monotonic() + args.connect_timeout
    while True:
        try:
            connection = socket.create_connection(
                ("127.0.0.1", args.port), timeout=FRAME_TIMEOUT_S
            )
            break
        except OSError as error:
            if time.monotonic() >= deadline:
                log(f"could not connect to the player: {error}")
                return 1
            time.sleep(POLL_S)

    try:
        with connection:
            PlayerSession(args.marker, args.port).serve(connection)
    except (OSError, ValueError) as error:
        log(f"connection ended: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
