#!/usr/bin/env python3
"""
A stand-in for the Home Assistant Supervisor, for the add-on half of scripts/smoke_test.sh.

The image reads its add-on options through bashio, which fetches GET
/addons/self/options/config and takes the object under `.data`. That one route is all this
answers; anything else gets a 404 rather than an empty object, which would be
indistinguishable from an add-on whose options are all unset.

Every request is recorded in --marker, one outcome per line, and the smoke suite asserts what
it finds there: a container that never forwarded its token would otherwise be served its
options anyway and pass.

Runs on the host rather than in a container of its own, so there is no second image to pin
and no docker network to stand up; the container under test reaches it through
`--add-host supervisor:host-gateway`.
"""

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RESOURCE = "/addons/self/options/config"


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


def make_handler(options, token, marker):
    def record(outcome):
        with open(marker, "a", encoding="utf-8") as handle:
            handle.write(outcome + "\n")

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

        def do_GET(self):  # noqa: N802 -- the name BaseHTTPRequestHandler dispatches to
            # bashio calls curl with `--request GET -d {}`, so this GET carries a body. It
            # has to be read before the reply goes out, or curl finds the connection closed
            # on its request rather than answered -- which shows up as an intermittent
            # failure rather than a consistent one.
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)

            header = self.carried_token()
            if header is None:
                record("unauthenticated")
                self.reply(401, {"result": "error", "message": "no header carried the token"})
            elif self.path != RESOURCE:
                record(f"unexpected-path {self.path}")
                self.reply(404, {"result": "error", "message": f"no such resource {self.path}"})
            else:
                record(f"ok {header}")
                self.reply(200, {"result": "ok", "data": options})

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
    handler = make_handler(options, args.token, args.marker)
    server = ThreadingHTTPServer(("0.0.0.0", args.port), handler)

    # Printed rather than assumed, because --port 0 means the caller does not know it yet.
    print(f"fake-supervisor: listening on port {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
