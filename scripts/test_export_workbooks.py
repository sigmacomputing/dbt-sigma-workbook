"""Offline tests for export_workbooks.py, including the push flow against a local fake Sigma API.

    python -m unittest scripts/test_export_workbooks.py
"""
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import export_workbooks as ex  # noqa: E402

CONTENTS_SPEC = {
    "name": "WB",
    "folderId": "folder-1",
    "contents": {
        "schemaVersion": 1,
        "kind": "workbook",
        "pages": [{"id": "p1", "name": "Page"}],
        "elements": [
            {"id": "e1", "kind": "table", "source": {"kind": "warehouse-table", "connectionId": "c", "path": ["a", "b", "c"]}},
        ],
        "layout": "<Page/>",
    },
}


def manifest_with(**specs):
    return {
        "nodes": {
            f"model.p.{name}": {"resource_type": "model", "name": name, "config": {"meta": {"sigma_workbook": spec}}}
            for name, spec in specs.items()
        }
        | {"model.p.plain": {"resource_type": "model", "name": "plain", "config": {"meta": {}}}}
    }


class FakeSigma(BaseHTTPRequestHandler):
    calls: list = []

    def log_message(self, *args):  # keep test output quiet
        pass

    def _reply(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        FakeSigma.calls.append({"method": self.command, "path": self.path, "auth": self.headers.get("Authorization"),
                                "type": self.headers.get("Content-Type"), "body": raw})
        if self.path == "/v2/auth/token":
            return self._reply({"access_token": "tok"})
        if self.path == "/v2/workbooks/boom":
            return self._reply({"message": "nope"}, 400)
        return self._reply({"workbookId": "wb-1", "url": "https://sigma.example/wb-1"})

    do_POST = do_PUT = _handle


class LoadAndCheck(unittest.TestCase):
    def test_load_specs_picks_only_workbook_models(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "manifest.json"
            path.write_text(json.dumps(manifest_with(a=CONTENTS_SPEC, b=CONTENTS_SPEC)))
            self.assertEqual(sorted(ex.load_specs(path)), ["a", "b"])
            self.assertEqual(sorted(ex.load_specs(path, ["b"])), ["b"])

    def test_clean_spec_has_no_problems(self):
        self.assertEqual(ex.find_problems("a", CONTENTS_SPEC), [])

    def test_unresolved_data_model_id_is_a_problem(self):
        spec = json.loads(json.dumps(CONTENTS_SPEC))
        spec["contents"]["elements"][0]["source"] = {"kind": "data-model", "dataModelId": "unresolved:m", "elementId": "x"}
        self.assertTrue(any("unresolved" in p for p in ex.find_problems("a", spec)))

    def test_missing_folder_and_duplicate_ids_are_problems(self):
        spec = json.loads(json.dumps(CONTENTS_SPEC))
        del spec["folderId"]
        spec["contents"]["elements"].append(dict(spec["contents"]["elements"][0]))
        problems = " ".join(ex.find_problems("a", spec))
        self.assertIn("folderId", problems)
        self.assertIn("duplicate element ids", problems)

    def test_update_by_workbook_id_needs_no_folder(self):
        spec = json.loads(json.dumps(CONTENTS_SPEC))
        del spec["folderId"]
        spec["workbookId"] = "wb-9"
        self.assertEqual(ex.find_problems("a", spec), [])

    def test_write_specs(self):
        with tempfile.TemporaryDirectory() as d:
            paths = ex.write_specs({"a": CONTENTS_SPEC}, Path(d) / "out")
            self.assertEqual(json.loads(paths[0].read_text()), CONTENTS_SPEC)


class PushFlow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), FakeSigma)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.client = ex.SigmaClient(f"http://127.0.0.1:{cls.server.server_port}", "id", "secret")

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        FakeSigma.calls.clear()

    def test_create_posts_the_spec_to_v2_workbooks(self):
        response = self.client.push(CONTENTS_SPEC)
        self.assertEqual(response["workbookId"], "wb-1")
        token_call, create_call = FakeSigma.calls[-2:]
        self.assertEqual(token_call["path"], "/v2/auth/token")
        self.assertIn("grant_type=client_credentials", token_call["body"])
        self.assertEqual((create_call["method"], create_call["path"]), ("POST", "/v2/workbooks"))
        self.assertEqual(create_call["auth"], "Bearer tok")
        self.assertEqual(json.loads(create_call["body"]), CONTENTS_SPEC)

    def test_dry_run_sets_the_flag_without_mutating_the_spec(self):
        self.client.push(CONTENTS_SPEC, dry_run=True)
        self.assertTrue(json.loads(FakeSigma.calls[-1]["body"])["dryRun"])
        self.assertNotIn("dryRun", CONTENTS_SPEC)

    def test_update_puts_only_contents(self):
        spec = dict(CONTENTS_SPEC, workbookId="wb-7")
        self.client.push(spec)
        call = FakeSigma.calls[-1]
        self.assertEqual((call["method"], call["path"]), ("PUT", "/v2/workbooks/wb-7/contents"))
        self.assertEqual(json.loads(call["body"]), {"contents": CONTENTS_SPEC["contents"]})

    def test_dry_run_of_an_update_is_refused(self):
        with self.assertRaises(RuntimeError):
            self.client.push(dict(CONTENTS_SPEC, workbookId="wb-7"), dry_run=True)

    def test_legacy_nested_spec_uses_the_spec_endpoints(self):
        legacy = {"name": "L", "schemaVersion": 1, "folderId": "f", "pages": [{"id": "p", "name": "P", "elements": []}]}
        self.client.push(legacy)
        self.assertEqual(FakeSigma.calls[-1]["path"], "/v2/workbooks/spec")
        self.client.push(legacy, dry_run=True)
        self.assertEqual(FakeSigma.calls[-1]["path"], "/v2/workbooks/spec/verify")
        self.client.push(dict(legacy, workbookId="wb-2"))
        self.assertEqual((FakeSigma.calls[-1]["method"], FakeSigma.calls[-1]["path"]), ("PUT", "/v2/workbooks/wb-2/spec"))

    def test_http_errors_surface_the_response_body(self):
        client = ex.SigmaClient(f"http://127.0.0.1:{self.server.server_port}", "id", "secret")
        with self.assertRaises(RuntimeError) as ctx:
            client._request("POST", "/v2/workbooks/boom", {})
        self.assertIn("HTTP 400", str(ctx.exception))
        self.assertIn("nope", str(ctx.exception))


class Cli(unittest.TestCase):
    def test_check_fails_on_problems_and_passes_when_clean(self):
        bad = json.loads(json.dumps(CONTENTS_SPEC))
        del bad["folderId"]
        with tempfile.TemporaryDirectory() as d:
            good_path, bad_path = Path(d) / "good.json", Path(d) / "bad.json"
            good_path.write_text(json.dumps(manifest_with(a=CONTENTS_SPEC)))
            bad_path.write_text(json.dumps(manifest_with(a=bad)))
            self.assertEqual(ex.main(["--manifest", str(good_path), "--check"]), 0)
            self.assertEqual(ex.main(["--manifest", str(bad_path), "--check"]), 1)
            self.assertEqual(ex.main(["--manifest", str(Path(d) / "missing.json"), "--check"]), 2)

    def test_push_is_refused_while_problems_remain(self):
        bad = json.loads(json.dumps(CONTENTS_SPEC))
        del bad["folderId"]
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "m.json"
            path.write_text(json.dumps(manifest_with(a=bad)))
            self.assertEqual(ex.main(["--manifest", str(path), "--push"]), 1)


if __name__ == "__main__":
    unittest.main()
