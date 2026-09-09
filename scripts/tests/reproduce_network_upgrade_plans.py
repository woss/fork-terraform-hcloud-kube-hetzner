#!/usr/bin/env python3
"""Generate offline provider plans from fabricated existing-server state.

Run: uv run scripts/tests/reproduce_network_upgrade_plans.py
Downloads the public provider, but uses dummy credentials, loopback endpoints,
no data sources, no refresh, no provisioners, and never applies. This isolates
provider planning behavior; it does not certify a full-module or live upgrade.
"""

from __future__ import annotations

import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from v2_to_v3_migration_assistant import collect_plan_risks

HEADER = """
terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.68.0"
    }
  }
}
provider "hcloud" {
  token            = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  endpoint         = "http://127.0.0.1:1/v1"
  endpoint_hetzner  = "http://127.0.0.1:1/v1"
}
"""


def main():
    terraform = shutil.which("terraform")
    if not terraform:
        raise SystemExit("terraform must be installed")
    root = Path(tempfile.mkdtemp(prefix="kh-network-upgrade-offline-"))
    home = root / "home"
    home.mkdir()
    # Do not inherit provider credentials, Terraform CLI configuration, or flags.
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(home),
        "TMPDIR": tempfile.gettempdir(),
        "CHECKPOINT_DISABLE": "1",
        "TF_IN_AUTOMATION": "1",
    }

    def run(*args):
        result = subprocess.run(
            [terraform, *args],
            cwd=root,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise RuntimeError(
                f"terraform {' '.join(args)} failed in {root}:\n{result.stdout}\n{result.stderr}"
            )
        return result.stdout

    (root / "main.tf").write_text(HEADER)
    run("fmt")
    run("init", "-backend=false", "-input=false", "-no-color")
    provider = 'provider["registry.terraform.io/hetznercloud/hcloud"]'
    network = {
        "network_id": 123,
        "subnet_id": "123-10.255.0.0/16",
        "ip": "10.255.0.101",
        "alias_ips": [],
        "mac_address": "02:00:00:00:00:01",
    }
    server = {
        "mode": "managed",
        "type": "hcloud_server",
        "name": "node",
        "provider": provider,
        "instances": [
            {
                "schema_version": 0,
                "attributes": {
                    "id": "1001",
                    "name": "offline-cp",
                    "image": "100",
                    "server_type": "cx23",
                    "location": "nbg1",
                    "network": [network],
                    "public_net": [
                        {
                            "ipv4_enabled": True,
                            "ipv6_enabled": True,
                            "ipv4": 456,
                            "ipv6": 789,
                        }
                    ],
                    "labels": {},
                    "backups": False,
                    "keep_disk": False,
                    "delete_protection": False,
                    "rebuild_protection": False,
                    "shutdown_before_deletion": False,
                    "ignore_remote_firewall_ids": False,
                    "firewall_ids": [],
                    "ssh_keys": [],
                    "user_data": "",
                    "placement_group_id": 0,
                },
            }
        ],
    }
    attachment = {
        "mode": "managed",
        "type": "hcloud_server_network",
        "name": "server",
        "provider": provider,
        "instances": [
            {
                "schema_version": 0,
                "attributes": dict(network, id="1001-123", server_id=1001),
            }
        ],
    }
    results = []
    for name, old_inline, old_attachment, pin_ip, public_enabled, forget in (
        ("steady-v3", True, False, False, True, False),
        ("v2-attachment-migration", False, True, False, True, False),
        ("v2-pinned-attachment-migration", False, True, True, True, False),
        ("v3-blind-ip-restore", True, False, True, True, False),
        ("enable-nat", True, False, False, False, False),
        ("forget-attachment-empty-inline-state", False, True, False, True, True),
        ("forget-attachment-populated-inline-state", True, True, False, True, True),
    ):
        current = copy.deepcopy(server)
        if not old_inline:
            current["instances"][0]["attributes"]["network"] = []
        if name == "v3-blind-ip-restore":
            current["instances"][0]["attributes"]["network"][0]["ip"] = "10.255.0.2"
        resources = [current] + ([attachment] if old_attachment else [])
        (root / "terraform.tfstate").write_text(
            json.dumps(
                {
                    "version": 4,
                    "terraform_version": "1.15.0",
                    "serial": 1,
                    "lineage": "a4a71366-d7a1-4ff8-9528-9a28b5d15c83",
                    "outputs": {},
                    "resources": resources,
                }
            )
        )
        pin = 'ip = "10.255.0.101"' if pin_ip else ""
        enabled = str(public_enabled).lower()
        removal = (
            "removed {\n from = hcloud_server_network.server\n lifecycle { destroy = false }\n}\n"
            if forget
            else ""
        )
        (root / "main.tf").write_text(
            HEADER
            + f"""
resource "hcloud_server" "node" {{
  name        = "offline-cp"
  image       = "100"
  server_type = "cx23"
  location    = "nbg1"
  public_net {{
    ipv4_enabled = {enabled}
    ipv6_enabled = {enabled}
  }}
  network {{
    network_id = 123
    alias_ips  = []
    {pin}
  }}
  lifecycle {{ ignore_changes = [location, ssh_keys, user_data, image] }}
}}
"""
            + removal
        )
        run("fmt")
        shutil.copyfile(root / "main.tf", root / f"{name}.tf.fixture")
        shutil.copyfile(root / "terraform.tfstate", root / f"{name}.state.fixture")
        run(
            "plan",
            "-refresh=false",
            "-input=false",
            "-lock=false",
            "-no-color",
            f"-out={name}.tfplan",
        )
        plan_path = root / f"{name}.json"
        plan_path.write_text(run("show", "-json", f"{name}.tfplan"))
        plan = json.loads(plan_path.read_text())
        changes = {
            r["address"]: r["change"]["actions"] for r in plan["resource_changes"]
        }
        risks = collect_plan_risks(plan_path)
        if old_attachment and not forget:
            assert changes["hcloud_server_network.server"] == ["delete"], changes
            assert any(
                r.resource_type == "hcloud_server_network" and r.blocker for r in risks
            ), risks
        if name in ("enable-nat", "v3-blind-ip-restore"):
            assert changes["hcloud_server.node"] == ["update"], changes
            assert any(r.action == "network-update" and r.blocker for r in risks), risks
        if name == "steady-v3":
            assert changes["hcloud_server.node"] == ["no-op"], changes
            assert not risks, risks
        if forget:
            assert changes["hcloud_server_network.server"] == ["forget"], changes
            if old_inline:
                assert changes["hcloud_server.node"] == ["no-op"], changes
                assert not risks, risks
            else:
                assert changes["hcloud_server.node"] == ["update"], changes
                assert any(r.action == "network-update" and r.blocker for r in risks), (
                    risks
                )
        results.append(
            {
                "scenario": name,
                "actions": changes,
                "blockers": [r.action for r in risks if r.blocker],
            }
        )
    (root / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps({"artifact_root": str(root), "results": results}, indent=2))


if __name__ == "__main__":
    main()
