#!/usr/bin/env python3
"""LAN filter in front of a loopback-only ocx.

Exposes exactly one model (ALIAS) and maps it to the model named in config.json. Everything else is refused.
Auth: the key in KEY_FILE, sent as `Authorization: Bearer`, `x-api-key` or `x-opencodex-api-key`.
"""
import hashlib
import hmac
import http.client
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FILTER_VERSION = 2
BASE_DIR = os.environ.get("OCX_LAN_FILTER_HOME") or os.path.expanduser("~/.local/share/ocx-lan-filter")
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
RUNTIME_FILE = os.path.join(BASE_DIR, "runtime.json")
KEY_FILE = os.path.join(BASE_DIR, "key")

# Defaults used for a v1 config ({"upstream_model": ...}) and when no config exists.
DEFAULT_HOST = os.environ.get("FILTER_HOST", "0.0.0.0")
DEFAULT_PORT = int(os.environ.get("FILTER_PORT", "10200"))
DEFAULT_UPSTREAM_PORT = int(os.environ.get("UPSTREAM_PORT", "10100"))
DEFAULT_CONTEXT_LENGTH = 1_000_000  # advertised to clients only; the real limit is the upstream model's
ALIAS = "local-llm"
DEFAULT_UPSTREAM_MODEL = "unset/choose-a-model"  # placeholder until a model is picked (app or `lanmodel set`)
RECONCILE_INTERVAL = float(os.environ.get("FILTER_RECONCILE_INTERVAL", "1.0"))

MAX_BODY = 32 * 1024 * 1024
# Cap for draining an oversized body before refusing it: read and discard so
# the close is clean, otherwise a client still uploading gets RST instead of
# the 413 JSON (Bun reports it as a dropped connection).
MAX_DRAIN = 64 * 1024 * 1024
# Only data-plane endpoints that carry a `model`; anything else is refused.
ALLOWED_POST = {"/v1/chat/completions", "/v1/responses"}

# Diagnostic response dump: while the marker file exists, full upstream
# response bodies (capped) are saved to /tmp/opencode/dump-*.bin alongside
# the log line. Temporary debugging aid, off by default.
DUMP_MARKER = "/tmp/opencode/dump-on"
DUMP_CAP = 200 * 1024

# Last-seen response markers, scanned per chunk with a small overlap so a
# marker split across two chunks is still caught. Used only for the log line.
_FINISH_RE = re.compile(rb'"finish_reason"\s*:\s*"([a-z_]+)"')
_USAGE_RE = re.compile(rb'"usage"\s*:\s*\{.*?"prompt_tokens"\s*:\s*(\d+).*?"completion_tokens"\s*:\s*(\d+)')
_DONE_RE = re.compile(rb'\[DONE\]')
_CHUNK_TAIL = 200

_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
_ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
ALLOWED_HOSTS = ("0.0.0.0", "127.0.0.1")


def log(msg: str) -> None:
    sys.stderr.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    sys.stderr.flush()


# ---------------------------------------------------------------- config

def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def migrate(raw):
    """v1 ({"upstream_model": ...}) -> v2. Anything else is returned unchanged."""
    if isinstance(raw, dict) and raw.get("version") is None and "endpoints" not in raw:
        model = raw.get("upstream_model")
        if not (isinstance(model, str) and model.strip()):
            model = DEFAULT_UPSTREAM_MODEL
        return {
            "version": 2,
            "upstream": {"host": "127.0.0.1", "port": DEFAULT_UPSTREAM_PORT},
            "endpoints": [{
                "id": "default", "name": "default", "enabled": True,
                "host": DEFAULT_HOST, "port": DEFAULT_PORT, "keyFile": "key",
                "aliases": [{"alias": ALIAS, "model": model.strip(),
                             "contextLength": DEFAULT_CONTEXT_LENGTH}],
            }],
        }
    return raw


def validate(cfg) -> list:
    """Return a list of (path, message); empty means valid. Mirrors ConfigValidator.swift."""
    issues = []
    if not isinstance(cfg, dict):
        return [("", "config must be an object")]
    if cfg.get("version") != 2 or not _is_int(cfg.get("version")):
        issues.append(("version", "must be 2"))
    up = cfg.get("upstream")
    if not isinstance(up, dict):
        issues.append(("upstream", "required"))
        up_port = None
    else:
        if up.get("host") != "127.0.0.1":
            issues.append(("upstream.host", "must be 127.0.0.1"))
        up_port = up.get("port")
        if not _is_int(up_port) or not 1 <= up_port <= 65535:
            issues.append(("upstream.port", "must be 1..65535"))
            up_port = None
    eps = cfg.get("endpoints")
    if not isinstance(eps, list):
        issues.append(("endpoints", "must be a list"))
        return issues
    seen_ids, seen_ports = set(), set()
    for i, ep in enumerate(eps):
        p = f"endpoints[{i}]"
        if not isinstance(ep, dict):
            issues.append((p, "must be an object"))
            continue
        eid = ep.get("id")
        if not isinstance(eid, str) or not _ID_RE.match(eid):
            issues.append((p + ".id", "must match ^[a-z0-9][a-z0-9-]{0,31}$"))
        elif eid in seen_ids:
            issues.append((p + ".id", "duplicate id"))
        else:
            seen_ids.add(eid)
        name = ep.get("name")
        if not isinstance(name, str) or not 1 <= len(name) <= 64:
            issues.append((p + ".name", "must be 1..64 characters"))
        if not isinstance(ep.get("enabled"), bool):
            issues.append((p + ".enabled", "must be a boolean"))
        if ep.get("host") not in ALLOWED_HOSTS:
            issues.append((p + ".host", "must be 0.0.0.0 or 127.0.0.1"))
        port = ep.get("port")
        if not _is_int(port) or not 1024 <= port <= 65535:
            issues.append((p + ".port", "must be 1024..65535"))
        elif port in seen_ports:
            issues.append((p + ".port", "duplicate port"))
        elif up_port is not None and port == up_port:
            issues.append((p + ".port", "conflicts with the upstream port"))
        else:
            seen_ports.add(port)
        kf = ep.get("keyFile")
        if (not isinstance(kf, str) or not kf or "\0" in kf or kf.startswith("/")
                or ".." in kf.split("/") or kf.endswith("/")):
            issues.append((p + ".keyFile", "must be a relative path inside the state directory"))
        als = ep.get("aliases")
        if not isinstance(als, list) or not als:
            issues.append((p + ".aliases", "at least one alias required"))
            continue
        seen_aliases = set()
        for j, a in enumerate(als):
            ap = f"{p}.aliases[{j}]"
            if not isinstance(a, dict):
                issues.append((ap, "must be an object"))
                continue
            al = a.get("alias")
            if not isinstance(al, str) or not _ALIAS_RE.match(al):
                issues.append((ap + ".alias", "must match ^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"))
            elif al in seen_aliases:
                issues.append((ap + ".alias", "duplicate alias"))
            else:
                seen_aliases.add(al)
            m = a.get("model")
            if not isinstance(m, str) or not m.strip() or len(m) > 200:
                issues.append((ap + ".model", "must be 1..200 characters"))
            cl = a.get("contextLength", DEFAULT_CONTEXT_LENGTH)
            if not _is_int(cl) or not 1 <= cl <= 10_000_000:
                issues.append((ap + ".contextLength", "must be 1..10000000"))
    return issues


def normalize(raw):
    """Migrate, validate and fill defaults. Returns (config | None, issues)."""
    cfg = migrate(raw)
    issues = validate(cfg)
    if issues:
        return None, issues
    for ep in cfg["endpoints"]:
        for a in ep["aliases"]:
            a.setdefault("contextLength", DEFAULT_CONTEXT_LENGTH)
            a["model"] = a["model"].strip()
    return cfg, []


class ConfigCache:
    """Reload config.json when it changes; keep the last good one on any error."""

    def __init__(self, path: str):
        self.path = path
        self._lock = threading.Lock()
        self._sig = None
        # Fail closed: until a valid config has been read, nothing is served.
        self.config = {"version": 2, "upstream": {"host": "127.0.0.1", "port": DEFAULT_UPSTREAM_PORT},
                       "endpoints": []}
        self.error = None
        self.mtime = 0.0

    def get(self):
        try:
            st = os.stat(self.path)
            sig = (st.st_mtime_ns, st.st_size, st.st_ino)
        except FileNotFoundError:
            sig = "missing"
        except OSError:
            return self.config
        with self._lock:
            if sig == self._sig:
                return self.config
            self._sig = sig
            if sig == "missing":
                cfg, issues = normalize({})
                self.error = None
                self.mtime = 0.0
            else:
                self.mtime = st.st_mtime
                try:
                    with open(self.path, "r") as f:
                        raw = json.load(f)
                    cfg, issues = normalize(raw)
                except (OSError, ValueError) as e:
                    cfg, issues = None, [("", f"cannot read config: {e}")]
                if issues:
                    self.error = "; ".join(f"{p or '<root>'}: {m}" for p, m in issues[:5])
                    log(f"config rejected, keeping last good: {self.error}")
                else:
                    self.error = None
            if cfg is not None:
                self.config = cfg
            return self.config


CONFIG = ConfigCache(CONFIG_FILE)


def find_endpoint(cfg, endpoint_id):
    for ep in (cfg or {}).get("endpoints", []):
        if ep["id"] == endpoint_id:
            return ep
    return None


def key_path(ep) -> str:
    return os.path.join(BASE_DIR, ep["keyFile"])


def load_key(ep) -> bytes:
    with open(key_path(ep), "r") as f:
        return f.read().strip().encode()


def upstream_model() -> str:
    """Model behind the first alias of the first endpoint (legacy helper for logs and /healthz)."""
    cfg = CONFIG.get()
    try:
        return cfg["endpoints"][0]["aliases"][0]["model"]
    except (TypeError, KeyError, IndexError):
        return DEFAULT_UPSTREAM_MODEL


class Server(ThreadingHTTPServer):
    request_queue_size = 128  # the default of 5 resets connections during bursts
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    server_version = "ocx-lan-filter"
    protocol_version = "HTTP/1.0"  # body is delimited by close, so streaming needs no chunk framing

    def log_message(self, fmt, *args):  # quiet default access log
        pass

    def _json(self, status: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _err(self, status: int, message: str, code: str) -> None:
        self._json(status, {"error": {"message": message, "type": code, "code": code}})

    def _endpoint(self):
        return find_endpoint(CONFIG.get(), self.server.endpoint_id)

    def _authorized(self, ep) -> bool:
        if ep is None:
            return False
        supplied = (
            self.headers.get("x-opencodex-api-key")
            or self.headers.get("x-api-key")
            or (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
            or ""
        ).strip().encode()
        try:
            return bool(supplied) and hmac.compare_digest(supplied, load_key(ep))
        except OSError:
            return False

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        ep = self._endpoint()
        if not self._authorized(ep):
            return self._err(401, "invalid or missing API key", "unauthorized")
        if path == "/v1/models":
            return self._json(200, {
                "object": "list",
                "data": [{"id": a["alias"], "object": "model", "created": 0, "owned_by": "local",
                          "context_length": a["contextLength"],
                          "capabilities": {"context_length": a["contextLength"]}}
                         for a in ep["aliases"]],
            })
        if path == "/healthz":
            first = ep["aliases"][0]
            return self._json(200, {"ok": True, "endpoint": ep["id"],
                                    "aliases": {a["alias"]: a["model"] for a in ep["aliases"]},
                                    "alias": first["alias"], "upstream": first["model"]})
        return self._err(404, "not found", "not_found")

    def _drain(self, n: int) -> None:
        """Discard n request-body bytes so the connection can close cleanly."""
        try:
            remaining = n
            while remaining > 0:
                chunk = self.rfile.read(min(65536, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
        except (OSError, ValueError):
            pass

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        ep = self._endpoint()
        if not self._authorized(ep):
            return self._err(401, "invalid or missing API key", "unauthorized")
        if path not in ALLOWED_POST:
            return self._err(404, "endpoint not available", "not_found")
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return self._err(400, "bad Content-Length", "bad_request")
        if length <= 0:
            return self._err(400, "bad body size", "bad_request")
        if length > MAX_BODY:
            self._drain(min(length, MAX_DRAIN))
            log(f"{self.client_address[0]} POST {path} -> 413 (body {length}b over {MAX_BODY}b limit)")
            return self._err(413, f"body {length}b exceeds {MAX_BODY}b limit", "bad_request")
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except ValueError:
            return self._err(400, "body must be JSON", "bad_request")
        requested = payload.get("model") if isinstance(payload, dict) else None
        mapping = next((a for a in ep["aliases"] if a["alias"] == requested), None) if isinstance(requested, str) else None
        if mapping is None:
            names = ", ".join(f"'{a['alias']}'" for a in ep["aliases"])
            return self._err(403, f"only model(s) {names} available", "model_not_allowed")
        target = mapping["model"]
        payload["model"] = target
        body = json.dumps(payload).encode()
        try:
            messages = payload.get("messages") or []
            n_images = sum(
                1 for m in messages
                if isinstance(m, dict)
                for b in (m.get("content") if isinstance(m.get("content"), list) else [])
                if isinstance(b, dict) and b.get("type") == "image_url"
            )
            n_msgs = len(messages)
        except Exception:
            n_images, n_msgs = -1, -1
        req_meta = (f"max_tokens={payload.get('max_tokens', '-')}, "
                    f"max_completion_tokens={payload.get('max_completion_tokens', '-')}, "
                    f"msgs={n_msgs}, images={n_images}")

        up = (CONFIG.get() or {}).get("upstream") or {"host": "127.0.0.1", "port": DEFAULT_UPSTREAM_PORT}
        conn = http.client.HTTPConnection(up["host"], up["port"], timeout=900)
        try:
            conn.request("POST", path, body=body, headers={
                "Content-Type": "application/json",
                "Content-Length": str(len(body)),
                "Accept": self.headers.get("Accept", "*/*"),
            })
            resp = conn.getresponse()
        except (OSError, http.client.HTTPException) as e:
            log(f"upstream error: {e}")
            return self._err(502, "upstream unavailable", "bad_gateway")

        self.send_response(resp.status)
        resp_ct = resp.getheader("Content-Type", "")
        streaming = "text/event-stream" in resp_ct
        self.send_header("Content-Type", resp.getheader("Content-Type", "application/json"))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        started = time.time()
        resp_bytes = 0
        finish, prompt_tok, compl_tok, done_seen = "-", "-", "-", False
        tail = b""
        dumping = os.path.exists(DUMP_MARKER)
        dump_fh = None
        dump_name = ""
        dump_saved = 0
        if dumping:
            try:
                stamp = time.strftime("%H%M%S")
                req_name = f"/tmp/opencode/dump-{stamp}.req.json"
                with open(req_name, "wb") as rq:
                    rq.write(body[:DUMP_CAP])
                dump_name = f"/tmp/opencode/dump-{stamp}.bin"
                dump_fh = open(dump_name, "wb")
            except OSError:
                dump_fh = None
        try:
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                resp_bytes += len(chunk)
                probe = tail + chunk
                for m in _FINISH_RE.finditer(probe):
                    finish = m.group(1).decode()
                for m in _USAGE_RE.finditer(probe):
                    prompt_tok, compl_tok = m.group(1).decode(), m.group(2).decode()
                if _DONE_RE.search(probe):
                    done_seen = True
                tail = probe[-_CHUNK_TAIL:]
                if dump_fh is not None and dump_saved < DUMP_CAP:
                    dump_fh.write(chunk[:DUMP_CAP - dump_saved])
                    dump_saved += min(len(chunk), DUMP_CAP - dump_saved)
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            if dump_fh is not None:
                dump_fh.close()
            conn.close()
        elapsed = time.time() - started
        log(f"{self.client_address[0]} POST {path} endpoint={ep['id']} {requested}->[{target}] -> {resp.status} "
            f"(req {len(body)}b, resp {resp_bytes}b, {elapsed:.1f}s, finish={finish}, "
            f"done={done_seen if streaming else '-'}, "
            f"prompt={prompt_tok} completion={compl_tok}, {req_meta}" +
            (f", dumped {dump_name} ({dump_saved}b)" if dump_fh is not None else "") + ")")


def write_json_atomic(path: str, obj) -> None:
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2)
    os.replace(tmp, path)


class Supervisor:
    """Keeps the set of listening sockets equal to the enabled endpoints in config.json."""

    def __init__(self):
        self.servers = {}   # endpoint id -> (ThreadingHTTPServer, host, port)
        self.errors = {}    # endpoint id -> (host, port, message), retried every cycle
        self.started_at = time.strftime("%Y-%m-%dT%H:%M:%S")
        self._last_runtime = None

    def _stop(self, eid):
        srv, host, port = self.servers.pop(eid)
        srv.shutdown()
        srv.server_close()
        log(f"endpoint {eid}: stopped {host}:{port}")

    def _start(self, ep):
        eid, host, port = ep["id"], ep["host"], ep["port"]
        try:
            load_key(ep)
        except OSError as e:
            self.errors[eid] = (host, port, f"key file unreadable ({ep['keyFile']}): {e.strerror or e}")
            return
        try:
            srv = Server((host, port), Handler)
        except OSError as e:
            self.errors[eid] = (host, port, e.strerror or str(e))
            return
        srv.daemon_threads = True
        srv.endpoint_id = eid
        threading.Thread(target=srv.serve_forever, name=f"ep-{eid}", daemon=True).start()
        self.servers[eid] = (srv, host, port)
        self.errors.pop(eid, None)
        first = ep["aliases"][0]
        log(f"endpoint {eid}: listening on {host}:{port}, {first['alias']} -> {first['model']} (+{len(ep['aliases']) - 1} more)")

    def reconcile(self):
        cfg = CONFIG.get()
        wanted = {ep["id"]: ep for ep in cfg["endpoints"] if ep["enabled"]}
        for eid in list(self.servers):
            ep = wanted.get(eid)
            _, host, port = self.servers[eid]
            if ep is None or (ep["host"], ep["port"]) != (host, port):
                self._stop(eid)
        for eid in list(self.errors):
            ep = wanted.get(eid)
            if ep is None or (ep["host"], ep["port"]) != self.errors[eid][:2]:
                del self.errors[eid]
        for eid, ep in wanted.items():
            if eid not in self.servers:
                prev = self.errors.get(eid)
                self._start(ep)
                now = self.errors.get(eid)
                if now and (not prev or prev[2] != now[2]):
                    log(f"endpoint {eid}: cannot listen on {ep['host']}:{ep['port']}: {now[2]}")
        self.write_runtime(cfg)

    def write_runtime(self, cfg):
        eps = {}
        for ep in cfg["endpoints"]:
            eid = ep["id"]
            entry = {"host": ep["host"], "port": ep["port"], "state": "disabled", "error": None}
            if eid in self.servers:
                entry["state"] = "listening"
            elif eid in self.errors:
                entry["state"], entry["error"] = "error", self.errors[eid][2]
            eps[eid] = entry
        doc = {"filterVersion": FILTER_VERSION, "pid": os.getpid(), "startedAt": self.started_at,
               "configMtime": CONFIG.mtime, "configError": CONFIG.error, "endpoints": eps}
        if doc != self._last_runtime:
            try:
                write_json_atomic(RUNTIME_FILE, doc)
                self._last_runtime = doc
            except OSError as e:
                log(f"cannot write runtime.json: {e}")

    def run(self):
        while True:
            try:
                self.reconcile()
            except Exception as e:  # never let the supervisor die
                log(f"reconcile error: {e!r}")
            time.sleep(RECONCILE_INTERVAL)


if __name__ == "__main__":
    log(f"ocx-lan-filter v{FILTER_VERSION}, state dir {BASE_DIR}")
    Supervisor().run()
