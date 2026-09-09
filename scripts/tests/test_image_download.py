#!/usr/bin/env python3
"""Exercise the production download functions with GNU Wget and loopback fixtures."""

import contextlib
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
VERIFIERS = ("leapmicro", "microos")
BODY = b"first burst\nlast burst\n"


class Mirror(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/missing":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        try:
            self.wfile.write(BODY[:12])
            self.wfile.flush()
            time.sleep(7)  # Healthy progress resumes after the old five-second budget.
            self.wfile.write(BODY[12:])
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass


@contextlib.contextmanager
def mirror():
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mirror) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}"
        finally:
            server.shutdown()
            thread.join()


def download_function(name):
    source = (ROOT / f"packer-template/scripts/verify-{name}-image.sh").read_text()
    # Test the actual function, without running unrelated key/import validation.
    _before, marker, after = source.partition("\ndownload() {\n")
    if not marker or "\n}\n" not in after:
        raise AssertionError(f"Cannot isolate {name} download function")
    return "download() {\n" + after.split("\n}\n", 1)[0] + "\n}\n"


class Downloads(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        wgetrc = self.work / "wgetrc"
        wgetrc.write_text("use_proxy = off\n")
        self.env = dict(os.environ, WGETRC=str(wgetrc), no_proxy="127.0.0.1")
        for key in tuple(self.env):
            if key.lower().endswith("_proxy"):
                self.env.pop(key)
        self.env["no_proxy"] = "127.0.0.1"

    def invoke(self, name, url, custom=0, authenticated=False):
        config = self.work / "wget.conf"
        config.write_text("header = Authorization: synthetic-secret\n" if authenticated else "")
        config.chmod(0o600)
        script = """set -eu
umask 077
fail() { printf 'ERROR: %s\\n' "$1" >&2; exit 1; }
wget_config="$1/wget.conf"
wget_input="$1/wget.input"
CUSTOM_IMAGE="$3"
""" + download_function(name) + '\ndownload "fixture appliance" "$2" "$1/image"\n'
        return subprocess.run(
            ["sh", "-c", script, "test", str(self.work), url, str(custom)],
            env=self.env, capture_output=True, text=True, timeout=30,
        )

    def test_legacy_timeout_rejects_healthy_pause(self):
        with mirror() as url:
            result = subprocess.run(
                ["wget", "-q", "--timeout=5", "--tries=1", "-O",
                 str(self.work / "legacy"), url + "/slow"],
                env=self.env, capture_output=True, timeout=15,
            )
        self.assertEqual(result.returncode, 4)
        self.assertNotEqual((self.work / "legacy").read_bytes(), BODY)

    def test_production_functions_survive_healthy_pause(self):
        with mirror() as url:
            for name in VERIFIERS:
                with self.subTest(verifier=name):
                    result = self.invoke(name, url + "/slow", custom=1)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((self.work / "image").read_bytes(), BODY)

    def test_real_http_error_is_classified(self):
        with mirror() as url:
            for name in VERIFIERS:
                with self.subTest(verifier=name):
                    result = self.invoke(name, url + "/missing")
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("wget exit 8: server error response", result.stderr)
                    self.assertNotIn(url, result.stderr)

    def test_every_mode_preserves_flags_and_sanitizes_errors(self):
        fake_bin = self.work / "bin"
        fake_bin.mkdir()
        fake_wget = fake_bin / "wget"
        fake_wget.write_text('''#!/bin/sh
printf '%s\\n' "$@" > "$ARGUMENTS"
printf 'https://redirect.invalid/?synthetic-secret Authorization: synthetic-secret\\n' >&2
exit "$STATUS"
''')
        fake_wget.chmod(0o700)
        self.env["PATH"] = str(fake_bin) + os.pathsep + self.env["PATH"]
        self.env["ARGUMENTS"] = str(self.work / "arguments")
        categories = {
            1: "download error", 2: "option parsing error", 3: "file I/O error",
            4: "network failure (including timeouts)",
            5: "TLS certificate verification failure", 6: "authentication failure",
            7: "protocol error", 8: "server error response", 42: "download error",
        }
        for name in VERIFIERS:
            for custom, authenticated in ((0, False), (1, False), (1, True)):
                for status in (0, *categories):
                    with self.subTest(verifier=name, custom=custom, auth=authenticated, status=status):
                        self.env["STATUS"] = str(status)
                        result = self.invoke(name, "https://mirror.invalid/?synthetic-secret", custom, authenticated)
                        self.assertEqual(result.returncode, int(status != 0), result.stderr)
                        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)
                        if status:
                            self.assertIn(f"wget exit {status}: {categories[status]}", result.stderr)
                        args = (self.work / "arguments").read_text().splitlines()
                        for flag in ("--dns-timeout=10", "--connect-timeout=15", "--read-timeout=60",
                                     "--waitretry=5", "--tries=5", "--retry-connrefused", "--inet4-only", "-q"):
                            self.assertIn(flag, args)
                        self.assertFalse(any(arg.startswith("--timeout=") for arg in args))
                        self.assertFalse(any("synthetic-secret" in arg for arg in args))
                        self.assertEqual("--max-redirect=0" in args, authenticated or (name == "microos" and custom == 1))
                        self.assertEqual(any(arg.startswith("--config=") for arg in args), authenticated)


if __name__ == "__main__":
    if not shutil.which("wget"):
        raise SystemExit("GNU Wget is required")
    unittest.main(verbosity=2)
