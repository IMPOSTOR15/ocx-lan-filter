#!/usr/bin/env python3
"""Tiny stand-in for ocx, used by the Swift contract tests. Usage: fake_upstream.py PORT LOGFILE"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, logfile = int(sys.argv[1]), sys.argv[2]


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        with open(logfile, "a") as f:
            f.write(json.dumps({"path": self.path, "model": body.get("model")}) + "\n")
        data = json.dumps({"model": body.get("model"),
                           "choices": [{"message": {"content": "4"}, "finish_reason": "stop"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
