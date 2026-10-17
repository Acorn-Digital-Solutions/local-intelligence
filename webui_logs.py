#!/usr/bin/env python3
"""Serve `docker logs open-webui` over HTTP for the Caddy /logs/webui route.

Loopback-only by design: Caddy (same host) is the LAN entry point, so no
additional port is exposed to the network. Managed by phase5.sh via the
org.local-intel.webui-logs launchd service; see webui-logs.launchd.plist.

  GET /[?tail=N]  -> text/plain, `docker logs --timestamps --tail N`
                     (default 500, clamped to 1..5000). Any path works;
                     this server has the one job.
"""

import argparse
import os
import shutil
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONTAINER = "open-webui"
DEFAULT_TAIL = 500
MAX_TAIL = 5000
TIMEOUT = 20


def docker_bin():
    """Absolute docker path. launchd services get a minimal PATH without it,
    so fall back through the standard install locations."""
    candidates = [
        shutil.which("docker"),
        "/usr/local/bin/docker",
        os.path.expanduser("~/.docker/bin/docker"),
        "/opt/homebrew/bin/docker",
    ]
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def docker_logs(tail):
    """Return (status, body) for the requested tail of the container log."""
    binary = docker_bin()
    if binary is None:
        return 500, "docker CLI not found (PATH, /usr/local/bin, ~/.docker/bin)\n"
    try:
        n = int(tail)
    except (TypeError, ValueError):
        n = DEFAULT_TAIL
    n = max(1, min(MAX_TAIL, n))
    try:
        out = subprocess.run(
            [binary, "logs", "--timestamps", "--tail", str(n), CONTAINER],
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return 504, "docker logs timed out\n"
    if out.returncode != 0:
        return 502, out.stderr[-2000:] or f"docker logs failed (exit {out.returncode})\n"
    return 200, out.stdout + out.stderr


class Handler(BaseHTTPRequestHandler):
    server_version = "webui-logs/1"

    def do_GET(self):  # noqa: N802 (stdlib handler naming)
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        status, body = docker_logs(query.get("tail", [None])[0])
        data = body.encode("utf-8", "replace")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):  # noqa: ANN002, ANN003 - stderr, kept quiet
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8013)
    args = ap.parse_args()
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
