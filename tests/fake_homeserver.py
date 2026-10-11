#!/usr/bin/env python3

#
# SPDX-License-Identifier: GPL-3.0-or-later
#

"""Minimal Matrix homeserver stand-in for the module tests.

Answers /account/whoami and logs "<method> <path> <Authorization>" of every
request to LOG_FILE, so a test can see that the bridge started with the
configured homeserver URL and access token. Usage: PORT LOG_FILE
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG_FILE = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self):
        with open(LOG_FILE, "a", encoding="utf-8") as log:
            log.write(f"{self.command} {self.path} {self.headers.get('Authorization', '-')}\n")
        if self.path.startswith("/_matrix/client/v3/account/whoami"):
            self._reply(200, {"user_id": "@voicebot:example.org"})
        else:
            self._reply(404, {"errcode": "M_NOT_FOUND", "error": "fake homeserver"})

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
