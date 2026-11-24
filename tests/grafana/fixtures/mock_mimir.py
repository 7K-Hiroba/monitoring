#!/usr/bin/env python3
"""Minimal local Mimir-compatible read-only query fixture for Grafana tests."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time
from urllib.parse import parse_qs, urlparse


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            return self.respond(200, {"status": "ok"})
        if parsed.path != "/api/v1/query":
            return self.respond(404, {"error": "not found"})
        query = parse_qs(parsed.query).get("query", [""])[0]
        if query == "invalid":
            return self.respond(400, {"status": "error", "error": "invalid query"})
        self.respond(200, {
            "status": "success",
            "data": {
                "resultType": "vector",
                "result": [{"metric": {"job": "mimir", "cluster": "kind-ci"}, "value": [time.time(), "1"]}],
            },
        })

    def respond(self, status, value):
        raw = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *_):
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
