#!/usr/bin/env python3
"""Export the Sigma workbook specs composed by dbt-sigma-workbook, and optionally push them to Sigma.

The dbt package never talks to Sigma: it composes each workbook spec at parse time and stores it on
the model's `meta.sigma_workbook`, so it lands in `target/manifest.json`. This script is the (optional)
last mile - it reads the manifest, writes one JSON file per workbook, and can create or update the
workbooks through Sigma's REST API. Standard library only, so it runs anywhere Python 3.9+ does.

Examples
    dbt parse
    python scripts/export_workbooks.py --out sigma_workbooks/            # write <model>.json files
    python scripts/export_workbooks.py --check                           # validate, write nothing
    python scripts/export_workbooks.py --push --dry-run                  # ask Sigma to validate
    python scripts/export_workbooks.py --push --select sigma_sales_dashboard

Pushing needs SIGMA_API_URL (e.g. https://api.sigmacomputing.com), SIGMA_CLIENT_ID and
SIGMA_CLIENT_SECRET in the environment.

Request shapes (see https://help.sigmacomputing.com/docs/manage-workbooks-as-code):
    contents  spec  ->  POST /v2/workbooks                  (create; add "dryRun": true to validate only)
              spec  ->  PUT  /v2/workbooks/{id}/contents    (update, when the spec carries a workbookId)
    legacy    spec  ->  POST /v2/workbooks/spec             (the deprecated nested-pages shape)
                        PUT  /v2/workbooks/{id}/spec
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

META_KEY = "sigma_workbook"


def load_specs(manifest_path: Path, select: list[str] | None = None) -> dict[str, dict]:
    """Return {model_name: spec} for every model carrying a sigma_workbook spec."""
    manifest = json.loads(manifest_path.read_text())
    specs = {}
    for node in manifest.get("nodes", {}).values():
        if node.get("resource_type") != "model":
            continue
        spec = (node.get("config", {}).get("meta") or {}).get(META_KEY)
        if spec is None:
            spec = (node.get("meta") or {}).get(META_KEY)
        if spec is not None and (not select or node["name"] in select):
            specs[node["name"]] = spec
    return specs


def find_problems(name: str, spec: dict) -> list[str]:
    """Things that would make Sigma reject the spec, checkable without calling Sigma."""
    problems = []
    blob = json.dumps(spec)
    if "unresolved:" in blob:
        problems.append(
            f"{name}: contains an unresolved data model id. Create the data model in Sigma, then record "
            "its id in the `sigma_data_model_ids` project var and re-run `dbt parse`."
        )
    contents = spec.get("contents")
    if contents is None:  # legacy nested shape
        contents = {"pages": spec.get("pages", []), "layout": spec.get("layout", "")}
        element_lists = [p.get("elements", []) for p in spec.get("pages", [])]
    else:
        element_lists = [contents.get("elements", [])]
    if not spec.get("folderId") and not spec.get("workbookId"):
        problems.append(f"{name}: no folderId. Set the `sigma_folder_id` project var (or pass folder_id=).")
    if not contents.get("pages"):
        problems.append(f"{name}: no pages.")
    ids = [e.get("id") for lst in element_lists for e in lst]
    if len(ids) != len(set(ids)):
        problems.append(f"{name}: duplicate element ids.")
    for lst in element_lists:
        for element in lst:
            source = element.get("source") or {}
            if source.get("kind") == "warehouse-table" and not source.get("connectionId"):
                problems.append(f"{name}: element {element.get('id')} has a warehouse source with no connectionId.")
    return problems


def write_specs(specs: dict[str, dict], out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for name, spec in specs.items():
        path = out_dir / f"{name}.json"
        path.write_text(json.dumps(spec, indent=2, sort_keys=False) + "\n")
        written.append(path)
    return written


class SigmaClient:
    def __init__(self, base_url: str, client_id: str, client_secret: str):
        self.base_url = base_url.rstrip("/")
        self.client_id = client_id
        self.client_secret = client_secret
        self._token: str | None = None

    def _request(self, method: str, path: str, body: dict | None = None, form: dict | None = None,
                 token: bool = True) -> dict:
        headers = {"Accept": "application/json"}
        data = None
        if form is not None:
            data = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        elif body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request) as response:
                payload = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise RuntimeError(f"{method} {path} -> HTTP {error.code}: {detail}") from None
        return json.loads(payload) if payload else {}

    @property
    def token(self) -> str:
        if self._token is None:
            response = self._request(
                "POST", "/v2/auth/token", token=False,
                form={"grant_type": "client_credentials", "client_id": self.client_id,
                      "client_secret": self.client_secret},
            )
            self._token = response["access_token"]
        return self._token

    def push(self, spec: dict, dry_run: bool = False) -> dict:
        """Create (or, given a workbookId, update) one workbook. Returns Sigma's response."""
        spec = dict(spec)
        workbook_id = spec.pop("workbookId", None)
        if "contents" in spec:
            if workbook_id:
                if dry_run:
                    raise RuntimeError("--dry-run is only supported when creating a workbook (no workbookId).")
                return self._request("PUT", f"/v2/workbooks/{workbook_id}/contents", {"contents": spec["contents"]})
            if dry_run:
                spec["dryRun"] = True
            return self._request("POST", "/v2/workbooks", spec)
        if workbook_id:
            return self._request("PUT", f"/v2/workbooks/{workbook_id}/spec", spec)
        return self._request("POST", "/v2/workbooks/spec/verify" if dry_run else "/v2/workbooks/spec", spec)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", default="target/manifest.json", help="path to manifest.json (default: %(default)s)")
    parser.add_argument("--out", help="directory to write <model>.json files into")
    parser.add_argument("--select", help="comma-separated model names (default: every workbook model)")
    parser.add_argument("--check", action="store_true", help="validate the specs and exit non-zero on problems")
    parser.add_argument("--push", action="store_true", help="create/update the workbooks in Sigma")
    parser.add_argument("--dry-run", action="store_true", help="with --push: ask Sigma to validate without creating")
    args = parser.parse_args(argv)

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"error: {manifest_path} not found - run `dbt parse` first.", file=sys.stderr)
        return 2
    select = [s.strip() for s in args.select.split(",")] if args.select else None
    specs = load_specs(manifest_path, select)
    if not specs:
        print("error: no models with a sigma_workbook spec found.", file=sys.stderr)
        return 2

    problems = [p for name, spec in specs.items() for p in find_problems(name, spec)]
    for problem in problems:
        print(f"problem: {problem}", file=sys.stderr)
    if args.check:
        if problems:
            return 1
        print(f"ok: {len(specs)} workbook spec(s) passed the offline checks: {', '.join(specs)}")
    if args.out:
        for path in write_specs(specs, Path(args.out)):
            print(f"wrote {path}")
    if args.push:
        if problems:
            print("refusing to push while problems remain.", file=sys.stderr)
            return 1
        missing = [v for v in ("SIGMA_API_URL", "SIGMA_CLIENT_ID", "SIGMA_CLIENT_SECRET") if not os.environ.get(v)]
        if missing:
            print(f"error: set {', '.join(missing)} to push.", file=sys.stderr)
            return 2
        client = SigmaClient(os.environ["SIGMA_API_URL"], os.environ["SIGMA_CLIENT_ID"], os.environ["SIGMA_CLIENT_SECRET"])
        for name, spec in specs.items():
            response = client.push(spec, dry_run=args.dry_run)
            verb = "validated" if args.dry_run else "pushed"
            print(f"{verb} {name}: {response.get('url') or response.get('workbookId') or 'ok'}")
    if not (args.check or args.out or args.push):
        parser.print_usage(sys.stderr)
        print("nothing to do: pass --out, --check and/or --push.", file=sys.stderr)
        return 2
    return 1 if (problems and not args.check) else 0


if __name__ == "__main__":
    sys.exit(main())
