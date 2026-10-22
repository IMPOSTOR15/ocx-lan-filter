import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import filter as flt  # noqa: E402

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "validation.json")


class MigrationTests(unittest.TestCase):
    def test_p01_v1_becomes_default_endpoint(self):  # P-01
        cfg, issues = flt.normalize({"upstream_model": "provider/x"})
        self.assertEqual(issues, [])
        ep = cfg["endpoints"][0]
        self.assertEqual(ep["id"], "default")
        self.assertEqual(ep["keyFile"], "key")
        self.assertEqual(ep["aliases"], [{"alias": "local-llm", "model": "provider/x", "contextLength": 1_000_000}])

    def test_v1_without_model_uses_default(self):
        cfg, _ = flt.normalize({})
        self.assertEqual(cfg["endpoints"][0]["aliases"][0]["model"], flt.DEFAULT_UPSTREAM_MODEL)

    def test_p02_v2_roundtrip(self):  # P-02
        raw = {"version": 2, "upstream": {"host": "127.0.0.1", "port": 10100}, "endpoints": [
            {"id": "a", "name": "A", "enabled": True, "host": "0.0.0.0", "port": 10200, "keyFile": "key",
             "aliases": [{"alias": "x", "model": " m1 "}, {"alias": "y", "model": "m2", "contextLength": 5}]},
            {"id": "b", "name": "B", "enabled": False, "host": "127.0.0.1", "port": 10201, "keyFile": "keys/b.key",
             "aliases": [{"alias": "z", "model": "m3"}]}]}
        cfg, issues = flt.normalize(raw)
        self.assertEqual(issues, [])
        a = cfg["endpoints"][0]["aliases"]
        self.assertEqual(a[0]["model"], "m1")  # trimmed
        self.assertEqual(a[0]["contextLength"], 1_000_000)  # defaulted
        self.assertEqual(a[1]["contextLength"], 5)
        self.assertEqual(len(cfg["endpoints"]), 2)


class ValidationFixtureTests(unittest.TestCase):
    def test_shared_fixtures(self):  # P-03 / S-03 shared with Swift
        with open(FIXTURES) as f:
            cases = json.load(f)
        self.assertGreater(len(cases), 20)
        for c in cases:
            with self.subTest(c["name"]):
                issues = flt.validate(c["config"])
                self.assertEqual(issues == [], c["valid"], issues)


class ConfigCacheTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "config.json")
        self.cache = flt.ConfigCache(self.path)

    def put(self, text):
        tmp = self.path + ".t"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, self.path)

    def v2(self, model):
        return json.dumps({"version": 2, "upstream": {"host": "127.0.0.1", "port": 10100}, "endpoints": [
            {"id": "a", "name": "A", "enabled": True, "host": "127.0.0.1", "port": 12000, "keyFile": "key",
             "aliases": [{"alias": "x", "model": model}]}]})

    def test_missing_file_fails_closed_to_v1_defaults(self):
        cfg = self.cache.get()
        self.assertEqual(cfg["endpoints"][0]["id"], "default")

    def test_p04_bad_json_keeps_last_good(self):  # P-04
        self.put(self.v2("one"))
        self.assertEqual(self.cache.get()["endpoints"][0]["aliases"][0]["model"], "one")
        self.put("{ this is not json")
        self.assertEqual(self.cache.get()["endpoints"][0]["aliases"][0]["model"], "one")
        self.assertIn("cannot read config", self.cache.error)

    def test_invalid_config_keeps_last_good_and_reports(self):  # P-03
        self.put(self.v2("one"))
        self.cache.get()
        bad = json.loads(self.v2("two"))
        bad["endpoints"][0]["host"] = "10.0.0.1"
        self.put(json.dumps(bad))
        self.assertEqual(self.cache.get()["endpoints"][0]["aliases"][0]["model"], "one")
        self.assertIn("host", self.cache.error)

    def test_recovers_after_fix(self):
        self.put("garbage")
        self.cache.get()
        self.assertIsNotNone(self.cache.error)
        self.put(self.v2("fixed"))
        cfg = self.cache.get()
        self.assertIsNone(self.cache.error)
        self.assertEqual(cfg["endpoints"][0]["aliases"][0]["model"], "fixed")


if __name__ == "__main__":
    unittest.main()
