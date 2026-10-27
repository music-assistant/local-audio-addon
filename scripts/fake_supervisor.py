#!/usr/bin/env python3
"""
A stand-in for the Home Assistant Supervisor, for the add-on half of scripts/smoke_test.sh.

The image reads its add-on options through bashio, which fetches GET
/addons/self/options/config and takes the object under `.data`. It also publishes the
player's pairing token with POST /discovery, and withdraws it with DELETE /discovery/<uuid>
on the way down. Those are all this answers; anything else gets a 404 rather than an empty
object, which would be indistinguishable from an add-on whose options are all unset.

The last discovery body is written to --discovery-body for the suite to take apart, and
--discovery-status makes the POST fail, for the check that a Supervisor refusing it costs
the player nothing.

Every request is recorded in --marker, one outcome per line, and the smoke suite asserts what
it finds there: a container that never forwarded its token would otherwise be served its
options anyway and pass.

Runs on the host rather than in a container of its own, so there is no second image to pin
and no docker network to stand up; the container under test reaches it through
`--add-host supervisor:host-gateway`.
"""

import argparse
import json
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RESOURCE = "/addons/self/options/config"
DISCOVERY = "/discovery"


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token", required=True, help="the token a request must carry")
    parser.add_argument(
        "--marker", required=True, help="file to record the outcome of every request in"
    )
    parser.add_argument(
        "--port",
        type=int,
        default=0,
        help="port to listen on; 0 lets the OS choose a free one",
    )
    parser.add_argument(
        "--option",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="an add-on option to serve; repeatable, and an empty value is left out "
        "the way the Supervisor leaves out an option nobody set",
    )
    parser.add_argument(
        "--discovery-body", help="file to write the body of each POST /discovery to"
    )
    parser.add_argument(
        "--discovery-status",
        type=int,
        default=200,
        help="the HTTP status to answer POST /discovery with",
    )
    return parser.parse_args()


def build_options(pairs):
    options = {}
    for pair in pairs:
        key, separator, value = pair.partition("=")
        if not separator:
            raise SystemExit(f"--option needs KEY=VALUE, got {pair!r}")
        if value != "":
            options[key] = value
    return options


def make_handler(options, token, marker, discovery_body, discovery_status):
    def record(outcome):
        with open(marker, "a", encoding="utf-8") as handle:
            handle.write(outcome + "\n")

    issued = set()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def reply(self, status, payload):
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def carried_token(self):
            """The name of the header the token arrived in, or None."""
            # Any header carrying the token, rather than one named header: bashio has
            # moved between `Authorization: Bearer` and `X-Hassio-Key` across versions,
            # and which one this bashio uses is not what the smoke suite is testing.
            for name, value in self.headers.items():
                if value == token or value == f"Bearer {token}":
                    return name
            return None

        def read_body(self):
            # bashio calls curl with `--request GET -d {}`, so even a GET carries a body. It
            # has to be read before the reply goes out, or curl finds the connection closed
            # on its request rather than answered -- which shows up as an intermittent
            # failure rather than a consistent one.
            length = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(length) if length else b""

        def authenticated(self):
            """The header the token arrived in, or None having answered 401."""
            header = self.carried_token()
            if header is None:
                record("unauthenticated")
                self.reply(401, {"result": "error", "message": "no header carried the token"})
            return header

        def not_found(self):
            record(f"unexpected-path {self.command} {self.path}")
            self.reply(404, {"result": "error", "message": f"no such resource {self.path}"})

        def do_GET(self):  # noqa: N802 -- the name BaseHTTPRequestHandler dispatches to
            self.read_body()
            header = self.authenticated()
            if header is None:
                return
            if self.path != RESOURCE:
                self.not_found()
                return
            record(f"ok {header} GET {self.path}")
            self.reply(200, {"result": "ok", "data": options})

        def do_POST(self):  # noqa: N802
            body = self.read_body()
            header = self.authenticated()
            if header is None:
                return
            if self.path != DISCOVERY:
                self.not_found()
                return
            if discovery_status != 200:
                record(f"refused {header} POST {self.path}")
                self.reply(discovery_status, {"result": "error", "message": "refused"})
                return
            if discovery_body:
                with open(discovery_body, "wb") as handle:
                    handle.write(body)
            message = uuid.uuid4().hex
            issued.add(message)
            record(f"ok {header} POST {self.path}")
            self.reply(200, {"result": "ok", "data": {"uuid": message}})

        def do_DELETE(self):  # noqa: N802
            self.read_body()
            header = self.authenticated()
            if header is None:
                return
            # Recorded without the uuid itself, so the suite can match the line exactly, and
            # only once it is known to be the one this handed out.
            if self.path.removeprefix(DISCOVERY + "/") not in issued:
                self.not_found()
                return
            record(f"ok {header} DELETE {DISCOVERY}/<uuid>")
            self.reply(200, {"result": "ok", "data": {}})

        def log_message(self, fmt, *args):
            # Onto stdout beside the listening line below, which is where the smoke suite
            # already looks when a check fails. The default writes to stderr unbuffered
            # through a different path and interleaves badly with it.
            print("fake-supervisor: " + fmt % args, flush=True)

    return Handler


def main():
    args = parse_args()
    options = build_options(args.option)

    # 0.0.0.0 rather than localhost: the point of this is to be reachable from a container,
    # whose host-gateway address is not the loopback one. On a CI runner that is an
    # ephemeral VM; on a laptop it is a port open for as long as one smoke run takes.
    handler = make_handler(
        options, args.token, args.marker, args.discovery_body, args.discovery_status
    )
    server = ThreadingHTTPServer(("0.0.0.0", args.port), handler)

    # Printed rather than assumed, because --port 0 means the caller does not know it yet.
    print(f"fake-supervisor: listening on port {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
