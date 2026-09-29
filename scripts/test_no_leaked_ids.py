"""Guards against environment-specific values being committed.

The repository must not contain real Sigma ids, real email addresses, non-public Sigma hosts or local
paths. Real values are supplied at run time (see the `SIGMA_*` variables in
integration_tests/dbt_project.yml); what is committed is placeholders only.

    python -m unittest scripts/test_no_leaked_ids.py

`find_leaks` is the scanner; the last test runs it over this repository, and the others prove it can
actually find each kind of leak, so it can't pass by looking at nothing.
"""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", ".claude", "target", "dbt_packages", "logs", "duckdb", "__pycache__", ".venv", "node_modules"}
SKIP_SUFFIXES = {".gz", ".duckdb", ".wal", ".pyc", ".png", ".jpg", ".ico"}

UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.IGNORECASE)
# The only UUIDs allowed: 00000000-0000-0000-0000-0000000000NN, the placeholder defaults.
PLACEHOLDER_UUID = re.compile(r"^00000000-0000-0000-0000-0000000000[0-9a-f]{2}$", re.IGNORECASE)
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)")
ALLOWED_EMAIL_DOMAINS = {"example.com"}
SIGMA_HOST = re.compile(r"\b([a-z0-9-]+(?:\.[a-z0-9-]+)*)\.sigmacomputing\.com\b", re.IGNORECASE)
PUBLIC_SIGMA_HOSTS = {"help", "assets", "api", "app"}
LOCAL_PATH = re.compile(r"(?:/Users|/home)/[A-Za-z0-9._-]+/|C:\\Users\\[A-Za-z0-9._-]+")


def _tracked(root: Path):
    """The files git tracks under `root`, or None when it is not a git checkout."""
    try:
        out = subprocess.run(["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return [root / name for name in out.decode().split("\0") if name]


def _files(root: Path):
    # Only tracked files matter: an untracked or ignored local file (dbt's .user.yml, a build directory)
    # is never committed. Outside a git checkout, fall back to walking the tree.
    tracked = _tracked(root)
    for path in sorted(tracked if tracked is not None else root.rglob("*")):
        if not path.is_file() or path.suffix in SKIP_SUFFIXES:
            continue
        if any(part in SKIP_DIRS for part in path.relative_to(root).parts):
            continue
        yield path


def find_leaks(root: Path) -> list[str]:
    """`path:line: what` for every value that must not be committed."""
    leaks = []
    for path in _files(root):
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        rel = path.relative_to(root)
        for number, line in enumerate(text.splitlines(), start=1):
            for match in UUID.finditer(line):
                if not PLACEHOLDER_UUID.match(match.group(0)):
                    leaks.append(f"{rel}:{number}: id {match.group(0)} (only 00000000-0000-0000-0000-0000000000NN placeholders are allowed)")
            for match in EMAIL.finditer(line):
                if match.group(1).lower() not in ALLOWED_EMAIL_DOMAINS:
                    leaks.append(f"{rel}:{number}: email address {match.group(0)}")
            for match in SIGMA_HOST.finditer(line):
                if match.group(1).lower() not in PUBLIC_SIGMA_HOSTS:
                    leaks.append(f"{rel}:{number}: Sigma host {match.group(0)} (only help., assets., api. and app. are public)")
            for match in LOCAL_PATH.finditer(line):
                leaks.append(f"{rel}:{number}: local path {match.group(0)}")
    return leaks


# Deliberately fake leaks for the scanner tests. They are assembled at run time, because this file is
# itself scanned: a literal fake id, address or path here would be reported as a real one.
FAKE_ID = "-".join(["0a1b2c3d", "4e5f", "4a6b", "8c7d", "9e0f1a2b3c4d"])
LONG_PLACEHOLDER_ID = "-".join(["00000000", "0000", "0000", "0000", "000000123456"])
FAKE_EMAIL = "someone" + "@" + "corp.io"
FAKE_SIGMA_HOST = "internal-tools" + ".sigmacomputing" + ".com"
FAKE_MAC_PATH = "/" + "Users/someone/repos/x"
FAKE_LINUX_PATH = "/" + "home/someone/x"


class ScannerFindsLeaks(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)

    def scan(self, name, text):
        (self.root / name).write_text(text)
        return find_leaks(self.root)

    def test_a_real_looking_uuid_is_a_leak(self):
        (leak,) = self.scan("a.yml", f"folder: {FAKE_ID}\n")
        self.assertIn("a.yml:1", leak)

    def test_placeholder_uuids_are_allowed(self):
        self.assertEqual(self.scan("a.yml", "id: 00000000-0000-0000-0000-000000000001\nid: 00000000-0000-0000-0000-0000000000ab\n"), [])

    def test_only_two_digit_placeholder_suffixes_are_allowed(self):
        self.assertEqual(len(self.scan("a.yml", f"id: {LONG_PLACEHOLDER_ID}\n")), 1)

    def test_email_addresses_are_a_leak_unless_example_com(self):
        self.assertEqual(len(self.scan("a.md", f"contact {FAKE_EMAIL}\n")), 1)
        self.assertEqual(self.scan("a.md", "contact data@example.com\n"), [])

    def test_non_public_sigma_hosts_are_a_leak(self):
        self.assertEqual(len(self.scan("a.md", f"see https://{FAKE_SIGMA_HOST}/x\n")), 1)
        self.assertEqual(self.scan("a.md", "see https://help.sigmacomputing.com/docs and https://api.sigmacomputing.com\n"), [])

    def test_mac_local_paths_are_a_leak(self):
        self.assertEqual(len(self.scan("a.md", f"at {FAKE_MAC_PATH}\n")), 1)

    def test_linux_local_paths_are_a_leak(self):
        self.assertEqual(len(self.scan("a.md", f"at {FAKE_LINUX_PATH}\n")), 1)

    def test_untracked_files_are_not_scanned_in_a_git_checkout(self):
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        (self.root / "tracked.md").write_text("fine\n")
        (self.root / "ignored.md").write_text(FAKE_ID + "\n")
        subprocess.run(["git", "add", "tracked.md"], cwd=self.root, check=True)
        self.assertEqual(find_leaks(self.root), [])
        subprocess.run(["git", "add", "ignored.md"], cwd=self.root, check=True)
        self.assertEqual(len(find_leaks(self.root)), 1)

    def test_skipped_directories_and_binary_files_are_ignored(self):
        (self.root / "target").mkdir()
        (self.root / "target" / "manifest.json").write_text(FAKE_ID)
        (self.root / "schema.json.gz").write_bytes(b"\x1f\x8b\x08")
        self.assertEqual(find_leaks(self.root), [])


class RepositoryIsClean(unittest.TestCase):
    def test_no_environment_specific_values_are_committed(self):
        leaks = find_leaks(REPO_ROOT)
        self.assertEqual(leaks, [], "environment-specific values found:\n  " + "\n  ".join(leaks))


if __name__ == "__main__":
    unittest.main()
