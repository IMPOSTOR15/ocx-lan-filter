import json
import os
import socket
import threading
import time
import unittest

from helpers import FilterCase, free_port, make_config, make_endpoint


class AuthAndRouting(FilterCase):
    def boot(self, endpoints):
        for ep in endpoints:
            if not os.path.exists(os.path.join(self.home, ep["keyFile"])):
                self.write_key(ep["keyFile"], "lan_testkey")
        self.write_config(make_config(self.up.port, endpoints))
        self.start_filter()
        for ep in endpoints:
            if ep["enabled"]:
                self.wait_listening(ep["port"])

    def test_p05_auth(self):  # P-05
        a = make_endpoint("a", key_file="keys/a.key")
        b = make_endpoint("b", key_file="keys/b.key")
        self.write_key("keys/a.key", "lan_AAA")
        self.write_key("keys/b.key", "lan_BBB")
        self.boot([a, b])
        self.assertEqual(self.chat(a["port"], key=None)[0], 401)
        self.assertEqual(self.chat(a["port"], key="wrong")[0], 401)
        self.assertEqual(self.chat(a["port"], key="lan_BBB")[0], 401)  # other endpoint's key
        self.assertEqual(self.chat(a["port"], key="lan_AAA")[0], 200)
        self.assertEqual(self.chat(b["port"], key="lan_BBB")[0], 200)
        self.assertEqual(self.request(a["port"], "GET", "/v1/models", key=None)[0], 401)
        self.assertEqual(self.request(a["port"], "POST", "/v1/chat/completions", key=None,
                                      headers={"x-api-key": "lan_AAA"},
                                      body={"model": "local-llm", "messages": []})[0], 200)

    def test_p06_model_is_substituted(self):  # P-06
        ep = make_endpoint()
        self.boot([ep])
        status, body = self.chat(ep["port"])
        self.assertEqual(status, 200)
        self.assertEqual(self.up.requests[-1]["body"]["model"], "real/model-a")
        self.assertEqual(body["model"], "real/model-a")

    def test_p07_other_models_forbidden(self):  # P-07
        ep = make_endpoint()
        self.boot([ep])
        for model in ("real/model-a", "other", "", None, 5):
            with self.subTest(model=model):
                status, body = self.chat(ep["port"], model=model)
                self.assertEqual(status, 403)
                self.assertEqual(body["error"]["code"], "model_not_allowed")
        self.assertEqual(self.up.requests, [])

    def test_p08_two_aliases_route_separately(self):  # P-08
        ep = make_endpoint(aliases=[
            {"alias": "smart", "model": "real/big", "contextLength": 200000},
            {"alias": "fast", "model": "real/small", "contextLength": 8000}])
        self.boot([ep])
        self.chat(ep["port"], model="smart")
        self.chat(ep["port"], model="fast")
        self.assertEqual([r["body"]["model"] for r in self.up.requests], ["real/big", "real/small"])

    def test_alias_is_per_endpoint(self):
        a = make_endpoint("a", key_file="ka", aliases=[{"alias": "only-a", "model": "m-a"}])
        b = make_endpoint("b", key_file="kb", aliases=[{"alias": "only-b", "model": "m-b"}])
        self.boot([a, b])
        self.assertEqual(self.chat(a["port"], model="only-b")[0], 403)
        self.assertEqual(self.chat(b["port"], model="only-b")[0], 200)

    def test_p09_models_lists_only_aliases(self):  # P-09
        ep = make_endpoint(aliases=[
            {"alias": "smart", "model": "real/big", "contextLength": 200000},
            {"alias": "fast", "model": "real/small", "contextLength": 8000}])
        self.boot([ep])
        status, body = self.request(ep["port"], "GET", "/v1/models")
        self.assertEqual(status, 200)
        self.assertEqual([m["id"] for m in body["data"]], ["smart", "fast"])
        self.assertEqual(body["data"][1]["context_length"], 8000)
        self.assertNotIn("real/big", json.dumps(body))

    def test_p10_other_paths_404(self):  # P-10
        ep = make_endpoint()
        self.boot([ep])
        for m, p in (("GET", "/api/keys"), ("POST", "/api/keys"), ("POST", "/v1/embeddings"),
                     ("GET", "/"), ("GET", "/v1/models/x"), ("POST", "/v1/messages")):
            with self.subTest(p=p, m=m):
                body = {"model": "local-llm"} if m == "POST" else None
                self.assertEqual(self.request(ep["port"], m, p, body)[0], 404)
        self.assertEqual(self.up.requests, [])

    def test_responses_path_allowed(self):
        ep = make_endpoint()
        self.boot([ep])
        status, _ = self.request(ep["port"], "POST", "/v1/responses", {"model": "local-llm", "input": "x"})
        self.assertEqual(status, 200)
        self.assertEqual(self.up.requests[-1]["path"], "/v1/responses")

    def test_healthz(self):
        ep = make_endpoint()
        self.boot([ep])
        status, body = self.request(ep["port"], "GET", "/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(body["aliases"], {"local-llm": "real/model-a"})
        self.assertEqual(body["alias"], "local-llm")  # legacy fields
        self.assertEqual(body["upstream"], "real/model-a")

    def test_bad_requests(self):
        ep = make_endpoint()
        self.boot([ep])
        self.assertEqual(self.request(ep["port"], "POST", "/v1/chat/completions", raw=b"not json",
                                      headers={"Content-Type": "application/json"})[0], 400)
        self.assertEqual(self.request(ep["port"], "POST", "/v1/chat/completions", raw=b"")[0], 400)
        self.assertEqual(self.request(ep["port"], "POST", "/v1/chat/completions", raw=b"[1,2]")[0], 403)


class HotReload(FilterCase):
    def test_p11_model_change_between_requests(self):  # P-11
        ep = make_endpoint()
        self.write_key()
        cfg = make_config(self.up.port, [ep])
        self.write_config(cfg)
        self.start_filter()
        self.wait_listening(ep["port"])
        self.chat(ep["port"])
        cfg["endpoints"][0]["aliases"][0]["model"] = "real/model-b"
        self.write_config(cfg)
        self.chat(ep["port"])
        self.assertEqual([r["body"]["model"] for r in self.up.requests], ["real/model-a", "real/model-b"])
        self.assertEqual(self.proc.poll(), None)

    def test_p12_alias_rename(self):  # P-12
        ep = make_endpoint()
        self.write_key()
        cfg = make_config(self.up.port, [ep])
        self.write_config(cfg)
        self.start_filter()
        self.wait_listening(ep["port"])
        self.assertEqual(self.chat(ep["port"])[0], 200)
        cfg["endpoints"][0]["aliases"][0]["alias"] = "renamed"
        self.write_config(cfg)
        self.assertEqual(self.chat(ep["port"], model="local-llm")[0], 403)
        self.assertEqual(self.chat(ep["port"], model="renamed")[0], 200)

    def test_p13_endpoint_added(self):  # P-13
        a = make_endpoint("a", key_file="ka")
        self.write_key("ka")
        cfg = make_config(self.up.port, [a])
        self.write_config(cfg)
        self.start_filter()
        self.wait_listening(a["port"])
        b = make_endpoint("b", key_file="kb")
        self.write_key("kb", "lan_testkey")
        cfg["endpoints"].append(b)
        t0 = time.time()
        self.write_config(cfg)
        self.wait_listening(b["port"], timeout=3)
        self.assertLess(time.time() - t0, 3)
        self.wait_for(lambda: self.read_runtime()["endpoints"]["b"]["state"] == "listening", msg="runtime b")
        self.assertEqual(self.chat(b["port"])[0], 200)

    def test_p14_disabled_and_removed(self):  # P-14
        a = make_endpoint("a", key_file="ka")
        b = make_endpoint("b", key_file="kb")
        self.write_key("ka")
        self.write_key("kb")
        cfg = make_config(self.up.port, [a, b])
        self.write_config(cfg)
        self.start_filter()
        self.wait_listening(a["port"])
        self.wait_listening(b["port"])
        cfg["endpoints"][1]["enabled"] = False
        self.write_config(cfg)
        self.wait_closed(b["port"])
        self.assertEqual(self.chat(a["port"])[0], 200)
        self.assertEqual(self.read_runtime()["endpoints"]["b"]["state"], "disabled")
        cfg["endpoints"][1]["enabled"] = True
        self.write_config(cfg)
        self.wait_listening(b["port"])
        del cfg["endpoints"][0]
        self.write_config(cfg)
        self.wait_closed(a["port"])
        self.assertEqual(self.chat(b["port"])[0], 200)
        self.assertNotIn("a", self.read_runtime()["endpoints"])

    def test_p15_port_change(self):  # P-15
        ep = make_endpoint()
        self.write_key()
        cfg = make_config(self.up.port, [ep])
        self.write_config(cfg)
        self.start_filter()
        old_port = ep["port"]
        self.wait_listening(old_port)
        new_port = free_port()
        cfg["endpoints"][0]["port"] = new_port
        self.write_config(cfg)
        self.wait_listening(new_port)
        self.wait_closed(old_port)
        self.assertEqual(self.chat(new_port)[0], 200)

    def test_p16_port_in_use_isolated_and_retried(self):  # P-16
        blocker = socket.socket()
        blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        blocker.bind(("127.0.0.1", 0))
        blocker.listen(1)
        busy = blocker.getsockname()[1]
        a = make_endpoint("a", key_file="ka")
        b = make_endpoint("b", key_file="kb", port=busy)
        self.write_key("ka")
        self.write_key("kb")
        self.write_config(make_config(self.up.port, [a, b]))
        self.start_filter()
        self.wait_listening(a["port"])
        self.wait_for(lambda: self.read_runtime()["endpoints"]["b"]["state"] == "error", msg="b error")
        self.assertIn("in use", self.read_runtime()["endpoints"]["b"]["error"].lower())
        self.assertEqual(self.chat(a["port"])[0], 200)
        blocker.close()
        self.wait_for(lambda: self.read_runtime()["endpoints"]["b"]["state"] == "listening", timeout=8, msg="b retry")
        self.assertEqual(self.chat(busy)[0], 200)

    def test_p17_missing_key_fails_closed(self):  # P-17
        ep = make_endpoint(key_file="nokey")
        self.write_config(make_config(self.up.port, [ep]))
        self.start_filter()
        self.wait_for(lambda: (self.read_runtime() or {}).get("endpoints", {}).get("default", {}).get("state") == "error",
                      msg="error state")
        self.assertIn("key", self.read_runtime()["endpoints"]["default"]["error"])
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", ep["port"]), timeout=0.5)
        self.write_key("nokey")
        self.wait_listening(ep["port"])

    def test_p21_key_rotation_without_restart(self):  # P-21
        ep = make_endpoint()
        self.write_key(value="lan_old")
        self.write_config(make_config(self.up.port, [ep]))
        self.start_filter()
        self.wait_listening(ep["port"])
        self.assertEqual(self.chat(ep["port"], key="lan_old")[0], 200)
        self.write_key(value="lan_new")
        self.assertEqual(self.chat(ep["port"], key="lan_old")[0], 401)
        self.assertEqual(self.chat(ep["port"], key="lan_new")[0], 200)

    def test_p04_garbage_config_keeps_serving(self):  # P-04 end-to-end
        ep = make_endpoint()
        self.write_key()
        self.write_config(make_config(self.up.port, [ep]))
        self.start_filter()
        self.wait_listening(ep["port"])
        self.write_config("{ nope")
        self.wait_for(lambda: self.read_runtime()["configError"] is not None, msg="configError")
        self.assertEqual(self.chat(ep["port"])[0], 200)
        self.assertEqual(self.read_runtime()["endpoints"]["default"]["state"], "listening")

    def test_p22_runtime_json(self):  # P-22
        ep = make_endpoint()
        self.write_key()
        self.write_config(make_config(self.up.port, [ep]))
        self.start_filter()
        self.wait_listening(ep["port"])
        self.wait_for(lambda: self.read_runtime() is not None, msg="runtime.json")
        rt = self.read_runtime()
        self.assertEqual(rt["filterVersion"], 2)
        self.assertEqual(rt["pid"], self.proc.pid)
        self.assertIsNone(rt["configError"])
        self.assertEqual(rt["endpoints"]["default"]["port"], ep["port"])
        self.assertEqual([f for f in os.listdir(self.home) if ".tmp." in f], [])

    def test_v1_config_end_to_end(self):  # P-23 legacy
        port = free_port()
        self.write_key()
        self.write_config({"upstream_model": "legacy/model"})
        self.start_filter({"FILTER_PORT": str(port), "FILTER_HOST": "127.0.0.1", "UPSTREAM_PORT": str(self.up.port)})
        self.wait_listening(port)
        self.assertEqual(self.chat(port)[0], 200)
        self.assertEqual(self.up.requests[-1]["body"]["model"], "legacy/model")
        self.assertEqual(self.chat(port, model="legacy/model")[0], 403)
        status, body = self.request(port, "GET", "/v1/models")
        self.assertEqual([m["id"] for m in body["data"]], ["local-llm"])
        self.write_config({"upstream_model": "legacy/model-2"})
        self.chat(port)
        self.assertEqual(self.up.requests[-1]["body"]["model"], "legacy/model-2")

    def test_no_config_serves_nothing(self):
        self.write_key()
        self.start_filter({"FILTER_PORT": str(free_port()), "FILTER_HOST": "127.0.0.1", "UPSTREAM_PORT": str(self.up.port)})
        self.wait_for(lambda: self.read_runtime() is not None, msg="runtime")


class Streaming(FilterCase):
    def setUp(self):
        super().setUp()
        self.ep = make_endpoint()
        self.write_key()
        self.write_config(make_config(self.up.port, [self.ep]))
        self.start_filter()
        self.wait_listening(self.ep["port"])

    def test_p18_sse_streams_incrementally(self):  # P-18
        import http.client
        self.up.mode = "sse"
        conn = http.client.HTTPConnection("127.0.0.1", self.ep["port"], timeout=10)
        conn.request("POST", "/v1/chat/completions", body=json.dumps({"model": "local-llm", "stream": True}),
                     headers={"Authorization": "Bearer lan_testkey", "Content-Type": "application/json"})
        r = conn.getresponse()
        self.assertIn("text/event-stream", r.getheader("Content-Type"))
        t0 = time.time()
        first = r.read1(65536)
        t_first = time.time() - t0
        rest = r.read()
        total = time.time() - t0
        self.assertIn(b"c0", first)
        self.assertLess(t_first, total - 0.2, "first chunk must arrive before the stream ends")
        self.assertIn(b"[DONE]", first + rest)
        time.sleep(0.2)
        self.assertIn("done=True", self.log_text())

    def test_p19_oversized_body(self):  # P-19
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.ep["port"], timeout=20)
        size = 33 * 1024 * 1024
        conn.putrequest("POST", "/v1/chat/completions")
        conn.putheader("Authorization", "Bearer lan_testkey")
        conn.putheader("Content-Length", str(size))
        conn.endheaders()
        chunk = b"x" * 65536
        sent = 0
        while sent < size:
            conn.sock.sendall(chunk[:min(65536, size - sent)])
            sent += 65536
        r = conn.getresponse()
        self.assertEqual(r.status, 413)
        self.assertEqual(json.loads(r.read())["error"]["code"], "bad_request")
        self.assertEqual(self.up.requests, [])

    def test_p20_upstream_down(self):  # P-20
        self.up.stop()
        status, body = self.chat(self.ep["port"])
        self.assertEqual(status, 502)
        self.assertEqual(body["error"]["code"], "bad_gateway")

    def test_upstream_500_passthrough(self):
        self.up.mode = "500"
        self.assertEqual(self.chat(self.ep["port"])[0], 500)

    def test_concurrent_requests(self):
        results = []
        def go():
            results.append(self.chat(self.ep["port"])[0])
        ts = [threading.Thread(target=go) for _ in range(12)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        self.assertEqual(results, [200] * 12)

    def test_log_has_endpoint_and_no_key(self):
        self.chat(self.ep["port"])
        time.sleep(0.2)
        text = self.log_text()
        self.assertIn("endpoint=default local-llm->[real/model-a]", text)
        self.assertNotIn("lan_testkey", text)


if __name__ == "__main__":
    unittest.main()
