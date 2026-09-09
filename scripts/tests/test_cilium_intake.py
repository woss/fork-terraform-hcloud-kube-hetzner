#!/usr/bin/env python3
"""Offline migration-warning regressions and real Terraform Cilium renders.

Run with: uv run scripts/tests/test_cilium_intake.py
No providers, cloud credentials, cluster access or containers are used.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import render_harness as render
import v2_to_v3_migration_assistant as migration


class CiliumMigrationWarnings(unittest.TestCase):
    def warnings_for(self, source: str) -> tuple[list, list, str, dict]:
        with tempfile.TemporaryDirectory(prefix="kh-cilium-migration-") as directory:
            root = Path(directory)
            (root / "main.tf").write_text(source, encoding="utf-8")
            findings = migration.collect_findings(root)
            warnings = migration.collect_topology_warnings(root)
            markdown = migration.markdown_report(root, findings, warnings, [], None)
            report = json.loads(migration.json_report(root, findings, warnings, [], None))
            return findings, warnings, markdown, report

    def test_cilium_without_legacy_inputs_still_warns(self) -> None:
        findings, warnings, markdown, report = self.warnings_for(
            'module "cluster" {\n  cni_plugin = "cilium"\n}\n'
        )
        self.assertEqual(findings, [])
        self.assertEqual(len(warnings), 1)
        self.assertEqual(warnings[0].locations, ("main.tf:2",))
        self.assertIn("v2 input findings: 0", markdown)
        for term in ("kubeProxyReplacement", "bpf.masquerade", "does not restart existing agents"):
            self.assertIn(term, markdown)
            self.assertIn(term, json.dumps(report))

    def test_computed_selection_is_not_assumed_to_be_non_cilium(self) -> None:
        _, warnings, _, _ = self.warnings_for("cni_plugin = var.selected_cni\n")
        self.assertEqual(len(warnings), 1)
        self.assertIn("If this CNI selection resolves to Cilium", warnings[0].note)
        self.assertIn("does not resolve CNI expressions", warnings[0].note)

    def test_explicit_kube_proxy_choice_still_needs_transition_review(self) -> None:
        _, warnings, _, _ = self.warnings_for(
            'cni_plugin = "cilium"\nenable_kube_proxy = false\n'
        )
        self.assertEqual(len(warnings), 1)
        self.assertIn("separately tested transition", warnings[0].note)

    def test_flannel_warning_is_conditional_not_a_blocker(self) -> None:
        findings, warnings, _, _ = self.warnings_for('cni_plugin = "flannel"\n')
        self.assertEqual(findings, [])
        self.assertIn("If this CNI selection resolves to Cilium", warnings[0].note)

    def test_no_cni_and_commented_examples_do_not_warn(self) -> None:
        for source in ("", '# cni_plugin = "cilium"\n', '// cni_plugin = "cilium"\n'):
            with self.subTest(source=source):
                self.assertEqual(self.warnings_for(source)[1], [])


class CiliumRendering(unittest.TestCase):
    def test_current_major_modes_are_preserved(self) -> None:
        body = render.extract_heredoc("cilium_values_default")
        for distribution in ("k3s", "rke2"):
            for kube_proxy in (True, False):
                for routing in ("native", "tunnel"):
                    for wireguard in (False, True):
                        with self.subTest(distribution=distribution, kube_proxy=kube_proxy,
                                          routing=routing, wireguard=wireguard):
                            values = render.base_render_vars()
                            values["var"]["enable_kube_proxy"] = kube_proxy
                            values["local"].update(
                                kubernetes_distribution=distribution,
                                cilium_routing_mode_effective=routing,
                                cilium_wireguard_effective=wireguard,
                            )
                            with tempfile.TemporaryDirectory(prefix="kh-cilium-render-") as directory:
                                scratch = render.TerraformScratch(Path(directory), values)
                                document = scratch.render_yaml(scratch.write_template("cilium", body))
                            self.assertIs(document["kubeProxyReplacement"], not kube_proxy)
                            self.assertIs(document["bpf"]["masquerade"], not kube_proxy)
                            self.assertEqual(document["MTU"], 1450)
                            self.assertEqual(document["routingMode"], routing)
                            self.assertEqual(document.get("tunnelProtocol"),
                                             "geneve" if routing == "tunnel" and wireguard else None)
                            self.assertEqual("encryption" in document, wireguard)
                            self.assertEqual(document.get("kubeProxyReplacementHealthzBindAddr"),
                                             None if kube_proxy else "0.0.0.0:10256")
                            self.assertEqual(document["k8sServicePort"],
                                             "6444" if distribution == "k3s" else "6443")


if __name__ == "__main__":
    unittest.main(verbosity=2)
