#!/usr/bin/env python3
"""Offline saved-plan regressions for issues #2277 and #2283.

Run: uv run scripts/tests/test_migration_network_plan.py
These synthetic plan fixtures exercise the auditor, not a live upgrade.
"""

from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import v2_to_v3_migration_assistant as migration

NETWORK = [
    {
        "network_id": 123,
        "ip": "10.255.0.101",
        "alias_ips": [],
        "mac_address": "02:00:00:00:00:01",
    }
]
PUBLIC_NET = [{"ipv4_enabled": True, "ipv6_enabled": True, "ipv4": 456, "ipv6": 789}]


def resource_change(
    resource_type="hcloud_server", actions=None, before=None, after=None, unknown=None
):
    return {
        "address": f'module.cluster.module.control_planes["0-0-cp"].{resource_type}.server',
        "mode": "managed",
        "type": resource_type,
        "change": {
            "actions": actions or ["update"],
            "before": before,
            "after": after,
            "after_unknown": unknown or {},
        },
    }


class NetworkPlanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.plan = self.root / "plan.json"

    def risks(self, *changes):
        self.plan.write_text(json.dumps({"resource_changes": changes}))
        return migration.collect_plan_risks(self.plan)

    def test_v2_attachment_delete_and_replace_are_blockers(self):
        for actions in (["delete"], ["delete", "create"], ["create", "delete"]):
            with self.subTest(actions=actions):
                risks = self.risks(resource_change("hcloud_server_network", actions))
                self.assertEqual(len(risks), 1)
                self.assertTrue(risks[0].blocker)
                self.assertIn("IP/MAC", risks[0].note)

    def test_inline_attachment_adoption_with_unknown_ip_is_blocker(self):
        risks = self.risks(
            resource_change(
                before={"network": []},
                after={"network": [{"network_id": 123, "alias_ips": []}]},
                unknown={"network": [{"ip": True, "mac_address": True}]},
            )
        )
        self.assertEqual(risks[0].action, "network-update")
        self.assertTrue(risks[0].blocker)

    def test_blind_control_plane_ip_restore_is_blocker(self):
        reassigned = copy.deepcopy(NETWORK)
        reassigned[0]["ip"] = "10.255.0.2"
        risks = self.risks(
            resource_change(before={"network": reassigned}, after={"network": NETWORK})
        )
        self.assertTrue(risks[0].blocker)

    def test_nat_enable_is_blocker_without_server_replacement(self):
        private = [{"ipv4_enabled": False, "ipv6_enabled": False, "ipv4": 0, "ipv6": 0}]
        risks = self.risks(
            resource_change(
                before={"network": NETWORK, "public_net": PUBLIC_NET},
                after={"network": NETWORK, "public_net": private},
            )
        )
        self.assertEqual(risks[0].actions, ("update",))
        self.assertIn("power-cycle", risks[0].note)
        self.assertIn("guest routing", risks[0].note)
        self.assertTrue(risks[0].blocker)

    def test_unknown_network_values_are_not_a_clean_bill(self):
        for field in ("network", "public_net"):
            for mask in (True, [{"ip": True}], [{"alias_ips": [True]}]):
                with self.subTest(field=field, mask=mask):
                    risks = self.risks(
                        resource_change(
                            before={field: NETWORK},
                            after={field: NETWORK},
                            unknown={field: mask},
                        )
                    )
                    self.assertTrue(risks[0].blocker)

    def test_label_only_update_is_not_a_network_blocker(self):
        self.assertEqual(
            self.risks(
                resource_change(
                    before={"network": NETWORK, "public_net": PUBLIC_NET, "labels": {}},
                    after={
                        "network": NETWORK,
                        "public_net": PUBLIC_NET,
                        "labels": {"role": "control-plane"},
                    },
                    unknown={"network": [{"ip": False}], "unrelated": True},
                )
            ),
            [],
        )

    def test_network_set_reordering_is_not_a_change(self):
        blocks = NETWORK + [{"network_id": 321, "ip": "10.1.0.101"}]
        self.assertEqual(
            self.risks(
                resource_change(
                    before={"network": blocks}, after={"network": blocks[::-1]}
                )
            ),
            [],
        )

    def test_alias_ip_set_reordering_is_not_a_change(self):
        before = copy.deepcopy(NETWORK)
        before[0]["alias_ips"] = ["10.255.0.110", "10.255.0.111"]
        after = copy.deepcopy(before)
        after[0]["alias_ips"].reverse()
        self.assertEqual(
            self.risks(
                resource_change(before={"network": before}, after={"network": after})
            ),
            [],
        )

    def test_new_servers_and_noops_are_not_upgrade_blockers(self):
        for actions, before in ((["create"], None), (["no-op"], {"network": NETWORK})):
            with self.subTest(actions=actions):
                self.assertEqual(
                    self.risks(
                        resource_change(
                            actions=actions, before=before, after={"network": NETWORK}
                        )
                    ),
                    [],
                )

    def test_known_empty_blocks_are_equivalent(self):
        self.assertEqual(
            self.risks(
                resource_change(before={}, after={"network": [], "public_net": None})
            ),
            [],
        )

    def test_non_network_update_and_terraform_data_replacement_keep_old_behavior(self):
        self.assertEqual(
            self.risks(
                resource_change(
                    "hcloud_network", before={"name": "a"}, after={"name": "b"}
                )
            ),
            [],
        )
        risks = self.risks(resource_change("terraform_data", ["delete", "create"]))
        self.assertFalse(risks[0].blocker)
        self.assertEqual(risks[0].action, "replace")

    def test_strict_cli_fails_for_attachment_or_nat_but_not_label_only(self):
        for change, expected in (
            (resource_change("hcloud_server_network", ["delete"]), 1),
            (
                resource_change(
                    before={"public_net": PUBLIC_NET}, after={"public_net": []}
                ),
                1,
            ),
            (
                resource_change(
                    before={"network": NETWORK}, after={"network": NETWORK}
                ),
                0,
            ),
        ):
            with self.subTest(change=change):
                self.risks(change)
                result = subprocess.run(
                    [
                        sys.executable,
                        str(Path(migration.__file__)),
                        "--root",
                        str(self.root),
                        "--plan-json",
                        str(self.plan),
                        "--strict",
                        "--json",
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(
                    json.loads(result.stdout)["summary"]["core_resource_plan_blockers"],
                    expected,
                )

    def test_reports_do_not_call_in_place_update_a_destruction(self):
        risks = self.risks(
            resource_change(before={"public_net": PUBLIC_NET}, after={"public_net": []})
        )
        report = json.loads(migration.json_report(self.root, [], [], risks, self.plan))
        self.assertEqual(report["summary"]["destructive_plan_actions"], 0)
        self.assertEqual(report["summary"]["in_place_networking_plan_risks"], 1)
        markdown = migration.markdown_report(self.root, [], [], risks, self.plan)
        self.assertIn("power-cycle", markdown)
        self.assertIn("Do not apply", markdown)


if __name__ == "__main__":
    unittest.main()
