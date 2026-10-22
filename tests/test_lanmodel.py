import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from helpers import LANMODEL


class OcxStub:
    def __init__(self, ids):
        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                data = json.dumps({"object": "list", "data": [{"id": i} for i in ids]}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}/v1/models"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def stop(self):
        self.srv.shutdown()
        self.srv.server_close()


class LanmodelTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.ocx = OcxStub(["a/one", "b/two", "c/three"])
        self.addCleanup(self.ocx.stop)

    def run_cli(self, *args):
        env = dict(os.environ, OCX_LAN_FILTER_HOME=self.home, LANMODEL_OCX_URL=self.ocx.url)
        return subprocess.run([sys.executable, LANMODEL, *args], env=env, capture_output=True, text=True)

    def cfg_path(self):
        return os.path.join(self.home, "config.json")

    def write(self, obj):
        with open(self.cfg_path(), "w") as f:
            json.dump(obj, f)

    def read(self):
        with open(self.cfg_path()) as f:
            return json.load(f)

    def v2(self):
        return {"version": 2, "upstream": {"host": "127.0.0.1", "port": 10100}, "endpoints": [
            {"id": "other", "name": "O", "enabled": True, "host": "127.0.0.1", "port": 10300, "keyFile": "ko",
             "aliases": [{"alias": "o", "model": "a/one"}]},
            {"id": "default", "name": "D", "enabled": True, "host": "0.0.0.0", "port": 10200, "keyFile": "key",
             "aliases": [{"alias": "local-llm", "model": "a/one", "contextLength": 123},
                         {"alias": "fast", "model": "b/two"}]}]}

    def test_v1_show_set(self):
        self.write({"upstream_model": "a/one"})
        self.assertIn("local-llm -> a/one", self.run_cli().stdout)
        r = self.run_cli("set", "2")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read(), {"upstream_model": "b/two"})

    def test_v2_set_preserves_structure_and_mirrors(self):
        self.write(self.v2())
        r = self.run_cli("set", "c/three")
        self.assertEqual(r.returncode, 0, r.stderr)
        cfg = self.read()
        d = next(e for e in cfg["endpoints"] if e["id"] == "default")
        self.assertEqual(d["aliases"][0]["model"], "c/three")
        self.assertEqual(d["aliases"][0]["contextLength"], 123)
        self.assertEqual(d["aliases"][1], {"alias": "fast", "model": "b/two"})
        self.assertEqual(next(e for e in cfg["endpoints"] if e["id"] == "other")["aliases"][0]["model"], "a/one")
        self.assertEqual(cfg["upstream_model"], "c/three")
        self.assertEqual(cfg["version"], 2)
        self.assertEqual([f for f in os.listdir(self.home) if f.endswith(".tmp")], [])

    def test_v2_show_lists_all_aliases(self):
        self.write(self.v2())
        out = self.run_cli().stdout
        self.assertIn("local-llm -> a/one", out)
        self.assertIn("fast -> b/two", out)

    def test_list_marks_current(self):
        self.write(self.v2())
        out = self.run_cli("list").stdout
        self.assertRegex(out, r"\*\s+1\s+a/one")

    def test_unknown_model_rejected_and_config_untouched(self):
        self.write(self.v2())
        before = self.read()
        r = self.run_cli("set", "nope/x")
        self.assertNotEqual(r.returncode, 0)
        r = self.run_cli("set", "99")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.read(), before)


if __name__ == "__main__":
    unittest.main()
