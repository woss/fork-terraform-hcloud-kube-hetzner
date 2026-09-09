#!/usr/bin/env python3
"""Provider-free rendering and native loopback HAProxy protocol regressions.

Run: uv run scripts/tests/test_haproxy_proxy_protocol.py
Requires terraform, haproxy and openssl. No cluster access is used.
"""

from contextlib import contextmanager
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import render_harness as render


def controller_config(additional=(), klipper=False):
    values = render.base_render_vars()
    values["var"]["haproxy_additional_proxy_protocol_ips"] = list(additional)
    values["local"]["using_klipper_lb"] = klipper
    with tempfile.TemporaryDirectory(prefix="kh-haproxy-render-") as directory:
        scratch = render.TerraformScratch(Path(directory), values)
        return scratch.render_yaml(scratch.write_template(
            "haproxy", render.extract_heredoc("haproxy_values_default")
        ))["controller"]


class HAProxyProtocol(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for executable in ("haproxy", "openssl"):
            if not shutil.which(executable):
                raise RuntimeError(f"Install {executable} to run the native protocol tests")

    @contextmanager
    def listener(self, config, ipv6=True):
        family = socket.AF_INET6 if ipv6 else socket.AF_INET
        host = "::1" if ipv6 else "127.0.0.1"
        with tempfile.TemporaryDirectory(prefix="kh-haproxy-native-") as directory:
            root = Path(directory)
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
                "-days", "1", "-subj", "/CN=localhost",
            ], check=True, capture_output=True)
            pem = root / "combined.pem"
            pem.write_bytes((root / "cert.pem").read_bytes() + (root / "key.pem").read_bytes())
            peers = root / "peers.lst"
            peers.write_text("\n".join(config["config"]["proxy-protocol"].split(", ")) + "\n")
            with socket.socket(family) as reservation:
                reservation.bind((host, 0))
                port = reservation.getsockname()[1]
            address = f"[{host}]:{port}" if ipv6 else f"{host}:{port}"
            cfg = root / "haproxy.cfg"
            # Pinned controller v3.2.12 emits this conditional expect-proxy rule
            # in pkg/haproxy/rules/reqProxyProtocol.go for its source-IP map.
            cfg.write_text(f"""global
  maxconn 32
  nbthread 1
defaults
  mode http
  timeout connect 1s
  timeout client 2s
  timeout server 2s
frontend ingress
  bind {address} ssl crt {pem}
  tcp-request connection expect-proxy layer4 if {{ src -f {peers} }}
  http-request return status 200 content-type text/plain lf-string "%[src]"
""")
            with (root / "process.log").open("w+") as log:
                process = subprocess.Popen(["haproxy", "-db", "-f", str(cfg)], stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 5
                    while True:
                        if process.poll() is not None:
                            log.seek(0)
                            self.fail(log.read())
                        try:
                            with socket.create_connection((host, port), timeout=0.2):
                                break
                        except OSError:
                            if time.monotonic() >= deadline:
                                self.fail("HAProxy loopback listener did not start")
                            time.sleep(0.02)
                    yield host, port
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)

    def request(self, address, proxy):
        # Verification is disabled only for this generated loopback certificate.
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        with socket.create_connection(address, timeout=3) as connection:
            if proxy:
                connection.sendall(b"PROXY TCP4 198.51.100.55 198.51.100.80 45678 443\r\n")
            with context.wrap_socket(connection, server_hostname="localhost") as tls:
                tls.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                chunks = []
                while chunk := tls.recv(4096):
                    chunks.append(chunk)
                return b"".join(chunks)

    def test_render_preserves_defaults_and_appends_exact_peers(self):
        self.assertEqual(controller_config()["config"]["proxy-protocol"], "127.0.0.1/32, 10.0.0.0/8")
        self.assertEqual(controller_config(["203.0.113.10/32", "2001:db8::10/128"])["config"]["proxy-protocol"],
                         "127.0.0.1/32, 10.0.0.0/8, 203.0.113.10/32, 2001:db8::10/128")
        self.assertNotIn("proxy-protocol", controller_config(klipper=True)["config"])

    def test_native_trusted_and_untrusted_transport_sources(self):
        cases = [
            ("default_ipv4", (), False, True),
            ("default_ipv6", (), True, False),
            ("exact_ipv6_peer", ("::1/128",), True, True),
            ("unrelated_exact_peers", ("203.0.113.10/32", "2001:db8::10/128"), True, False),
        ]
        for name, additional, ipv6, expects_proxy in cases:
            with self.subTest(name=name), self.listener(controller_config(additional), ipv6) as address:
                for proxy in (False, True):
                    with self.subTest(proxy=proxy):
                        if proxy != expects_proxy:
                            with self.assertRaises((ssl.SSLError, ConnectionError, TimeoutError)):
                                self.request(address, proxy)
                        else:
                            response = self.request(address, proxy)
                            self.assertIn(b"200 OK", response)
                            expected_source = b"198.51.100.55" if proxy else address[0].encode()
                            self.assertEqual(response.split(b"\r\n\r\n", 1)[1], expected_source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
