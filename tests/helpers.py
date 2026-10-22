import http.client
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILTER = os.path.join(ROOT, "filter.py")
LANMODEL = os.path.join(ROOT, "lanmodel")


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class FakeUpstream:
    """Stands in for ocx. Records every request; modes: echo | sse | cut | 500."""

    def __init__(self):
        self.port = free_port()
        self.requests = []
        self.mode = "echo"
        outer = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"

            def log_message(self, *a):
                pass

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
                outer.requests.append({"path": self.path, "body": body})
                if outer.mode == "500":
                    data = b'{"error":"boom"}'
                    self.send_response(500)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                elif outer.mode == "sse":
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    for i in range(3):
                        self.wfile.write(f'data: {{"choices":[{{"delta":{{"content":"c{i}"}}}}]}}\n\n'.encode())
                        self.wfile.flush()
                        time.sleep(0.15)
                    self.wfile.write(b'data: {"choices":[{"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
                else:
                    data = json.dumps({"model": body.get("model"), "echo": True,
                                       "choices": [{"message": {"content": "4"}, "finish_reason": "stop"}]}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

        class S(ThreadingHTTPServer):
            request_queue_size = 128

        self.server = S(("127.0.0.1", self.port), H)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def make_config(upstream_port, endpoints):
    return {"version": 2, "upstream": {"host": "127.0.0.1", "port": upstream_port}, "endpoints": endpoints}


def make_endpoint(eid="default", port=None, aliases=None, key_file="key", host="127.0.0.1",
                  enabled=True, name=None):
    return {"id": eid, "name": name or eid, "enabled": enabled, "host": host,
            "port": port or free_port(), "keyFile": key_file,
            "aliases": aliases or [{"alias": "local-llm", "model": "real/model-a", "contextLength": 1000000}]}


class FilterCase(unittest.TestCase):
    """Runs the real filter.py in a temp state dir against a fake upstream."""

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ocxlan-")
        self.up = FakeUpstream()
        self.proc = None
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        self.stop_filter()
        self.up.stop()
        shutil.rmtree(self.home, ignore_errors=True)

    # files
    def write_key(self, name="key", value="lan_testkey"):
        path = os.path.join(self.home, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(value)
        os.chmod(path, 0o600)
        return value

    def write_config(self, cfg):
        path = os.path.join(self.home, "config.json")
        tmp = path + ".t"
        with open(tmp, "w") as f:
            if isinstance(cfg, str):
                f.write(cfg)
            else:
                json.dump(cfg, f)
        os.replace(tmp, path)

    def read_runtime(self):
        try:
            with open(os.path.join(self.home, "runtime.json")) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    # process
    def start_filter(self, extra_env=None):
        env = dict(os.environ, OCX_LAN_FILTER_HOME=self.home, FILTER_RECONCILE_INTERVAL="0.2")
        env.update(extra_env or {})
        self.log = open(os.path.join(self.home, "filter.log"), "w")
        self.proc = subprocess.Popen([sys.executable, FILTER], env=env, stderr=self.log, stdout=self.log)

    def stop_filter(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None
        if getattr(self, "log", None) and not self.log.closed:
            self.log.close()

    def log_text(self):
        if not self.log.closed:
            self.log.flush()
        with open(os.path.join(self.home, "filter.log")) as f:
            return f.read()

    def wait_for(self, cond, timeout=6.0, msg="condition"):
        end = time.time() + timeout
        while time.time() < end:
            try:
                if cond():
                    return
            except Exception:
                pass
            time.sleep(0.05)
        self.fail(f"timeout waiting for {msg}\n--- filter.log ---\n{self.log_text()}")

    def wait_listening(self, port, timeout=6.0):
        def ok():
            with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                return True
        self.wait_for(ok, timeout, f"port {port} open")

    def wait_closed(self, port, timeout=6.0):
        def closed():
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                    return False
            except OSError:
                return True
        self.wait_for(closed, timeout, f"port {port} closed")

    # http
    def request(self, port, method, path, body=None, key="lan_testkey", headers=None, raw=None):
        h = dict(headers or {})
        if key is not None:
            h.setdefault("Authorization", f"Bearer {key}")
        data = raw
        if body is not None:
            data = json.dumps(body).encode()
            h.setdefault("Content-Type", "application/json")
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
        conn.request(method, path, body=data, headers=h)
        r = conn.getresponse()
        payload = r.read()
        conn.close()
        try:
            parsed = json.loads(payload)
        except ValueError:
            parsed = payload
        return r.status, parsed

    def chat(self, port, model="local-llm", **kw):
        return self.request(port, "POST", "/v1/chat/completions",
                            {"model": model, "messages": [{"role": "user", "content": "hi"}]}, **kw)
