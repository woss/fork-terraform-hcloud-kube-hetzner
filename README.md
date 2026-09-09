<div align="center">

<img src="https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/raw/master/.images/kube-hetzner-logo.png" alt="Kube-Hetzner logo" width="120" height="120">

# Kube-Hetzner

### Production-ready Kubernetes on Hetzner Cloud

**HA by default | Auto-upgrading | Cost-optimized**

<img src="https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/raw/master/.images/kubectl-pod-all-17022022.png" alt="A healthy kube-hetzner cluster with Kubernetes system workloads running" width="900">

A highly optimized, easy-to-operate Kubernetes cluster powered by k3s or RKE2 on openSUSE Leap Micro, deployed on [Hetzner Cloud](https://hetzner.com).

**Go from an empty Hetzner project to a running cluster in four steps.**

[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.10.1-844FBA?style=flat-square&logo=terraform)](https://terraform.io)&nbsp;&nbsp;
[![OpenTofu](https://img.shields.io/badge/OpenTofu-Compatible-FFDA18?style=flat-square&logo=opentofu)](https://opentofu.org)&nbsp;&nbsp;
[![HCloud Provider](https://img.shields.io/badge/hcloud-%3E%3D1.62.0-00ADEF?style=flat-square)](https://registry.terraform.io/providers/hetznercloud/hcloud/latest)&nbsp;&nbsp;
[![K3s](https://img.shields.io/badge/K3s-v1.36-FFC61C?style=flat-square&logo=k3s)](https://k3s.io)&nbsp;&nbsp;
[![Docs](https://img.shields.io/badge/Docs-index-2F80ED?style=flat-square)](docs/index.md)&nbsp;&nbsp;
[![License](https://img.shields.io/github/license/kube-hetzner/terraform-hcloud-kube-hetzner?style=flat-square&color=blue)](LICENSE)&nbsp;&nbsp;
[![GitHub Stars](https://img.shields.io/github/stars/kube-hetzner/terraform-hcloud-kube-hetzner?style=flat-square&logo=github)](https://github.com/mysticaltech/terraform-hcloud-kube-hetzner)

</div>

---

## Highlights

- **Production-ready defaults:** private networking, firewalls, CSI storage, ingress, certificate management, OS updates, and Kubernetes upgrades are integrated.
- **k3s or RKE2:** k3s is the lightweight default; RKE2 is a first-class option for heavier and compliance-oriented environments.
- **Highly available and elastic:** odd control-plane quorum, multi-location pools, static agents, and Cluster Autoscaler nodepools.
- **Immutable openSUSE nodes:** Leap Micro is the default; MicroOS remains supported for existing clusters and explicit nodepool selection.
- **Flexible networking:** Flannel, Calico, or Cilium; private-only NAT; dual-stack; Tailscale transport; Gateway API; and advanced multinetwork designs.
- **Plan-time guardrails:** invalid topology and cross-variable combinations fail before infrastructure is created.
- **Evidence-backed releases:** release claims are tied to live apply, upgrade, health, and destroy evidence in [`docs/v3-release-evidence.md`](docs/v3-release-evidence.md).

**Current release:** [v3.2.1 release notes](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/releases/tag/v3.2.1) | [Changelog](CHANGELOG.md) | [3.x upgrade guide](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/issues/2232) | [v2 to v3 migration](MIGRATION.md)

## Quick Start

1. Install [OpenTofu](https://opentofu.org/docs/intro/install/) or [Terraform](https://developer.hashicorp.com/terraform/install), [Packer 1.16.0](https://releases.hashicorp.com/packer/1.16.0/), [kubectl](https://kubernetes.io/docs/tasks/tools/), and [hcloud](https://github.com/hetznercloud/cli). With Homebrew, install the other tools in one command:

   ```sh
   brew install opentofu kubectl hcloud
   ```

2. Create a [Hetzner Cloud project](https://console.hetzner.cloud/), create a Read & Write API token, and generate a passphrase-less SSH key (`ssh-keygen -t ed25519`).

3. Run `createkh`. It creates your project folder, `kube.tf`, and the required Leap Micro images.

   Bash/Zsh:

   ```sh
   (tmp_script=$(mktemp) && trap 'rm -f "$tmp_script"' EXIT && curl -fsSL -o "$tmp_script" https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/scripts/create.sh && chmod +x "$tmp_script" && env -u KH_SOURCE_DIRECTORY "$tmp_script")
   ```

   Fish:

   ```fish
   set tmp_script (mktemp); curl -fsSL -o "$tmp_script" https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/scripts/create.sh; and chmod +x "$tmp_script"; and env -u KH_SOURCE_DIRECTORY bash "$tmp_script"; set run_status $status; rm -f "$tmp_script"; test $run_status -eq 0
   ```

4. Edit `kube.tf`, remove example node pools you do not need, then deploy:

   ```sh
   cd <your-project-folder>
   tofu init --upgrade
   tofu plan
   tofu apply
   ```

   Use `terraform` instead of `tofu` if that is what you installed. Every option is listed in the [generated configuration reference](docs/terraform.md).

## Choose a Topology

| Need | Recommended starting point |
| --- | --- |
| Small development cluster | One control plane, one agent pool, automatic upgrades disabled. |
| Normal production HA | Three control planes, two or more agents, one private Hetzner Network, restricted API and SSH sources. |
| Private-only cluster | NAT router plus a private control-plane load balancer. |
| Secure operator access | Tailscale node transport with public API and SSH sources closed. |
| More than 100 cloud nodes | Tailscale multinetwork with explicit primary/external network scopes. |
| Cilium Gateway API | Cilium, kube-proxy disabled, and `cilium_gateway_api_enabled = true`. |
| Heavy image-pull pressure | `embedded_registry_mirror.enabled = true` on a mutually trusted cluster. |

Read the [topology recommendations](docs/v3-topology-recommendations.md) and [support matrix](docs/support-matrix.md) before choosing an advanced path.

Cloudflare Access/Tunnel is a documented external boundary for operator and application access. Cloudflare Mesh/WARP is not supported as kube-hetzner node transport. See the [Cloudflare external-access example](examples/external-overlay-cloudflare-access/README.md). For Gateway API, start with the [Cilium example](examples/cilium-gateway-api/README.md).

## Documentation

[`docs/index.md`](docs/index.md) is the complete documentation map. Start with the path that matches your task:

| Task | Read this |
| --- | --- |
| Configure a cluster | [`kube.tf.example`](kube.tf.example), [Terraform inputs and outputs](docs/terraform.md), [operator reference](docs/llms.md) |
| Operate a cluster | [Day-2 operations](docs/operations.md), [SSH and access](docs/ssh.md), [backup and restore](docs/backup_restore.md) |
| Upgrade Kubernetes, the OS, or the module | [Upgrades](docs/upgrades.md) |
| Debug a broken cluster or expired certificates | [Troubleshooting](docs/troubleshooting.md) |
| Copy a working configuration pattern | [Recipes](docs/recipes.md) and [`examples/`](examples/) |
| Design networking or private egress | [Topology recommendations](docs/v3-topology-recommendations.md), [private-network egress](docs/private-network-egress.md) |
| Review security and artifact trust | [SELinux](docs/selinux.md), [installation supply chain](docs/kubernetes-installation-supply-chain.md) |
| Add a Hetzner Robot server | [Dedicated server integration](docs/add-robot-server.md) |

## Upgrading from v2

Do not blind-apply a v2 to v3 upgrade. Start with [`MIGRATION.md`](MIGRATION.md) for the compatibility contract and variable map, then follow the [step-by-step migration guide](docs/v2-to-v3-migration.md). Back up state and reject any plan with unexplained destroy or replacement actions.

The fastest assisted path is `/migrate-v2-to-v3`, which rewrites the configuration and runs the protected-infrastructure plan gate without applying changes.

## AI-Assisted Operations

Install the project skills in Claude Code, Codex, Cursor, or another skills-compatible agent:

```sh
npx skills add kube-hetzner/terraform-hcloud-kube-hetzner
```

| Skill | Purpose |
| --- | --- |
| `/kh-assistant` | Configuration and troubleshooting help grounded in the current repository. |
| `/migrate-v2-to-v3 <terraform-root>` | Guided migration with protected-infrastructure plan review. |
| `/upgrade-cluster <terraform-root>` | Safety-first module and Kubernetes upgrade workflow. |
| `/debug-node <server>` | Rescue workflow for unreachable nodes, SSH, cloud-init, and provisioning failures. |
| `/test-changes` | Repository-native Terraform/OpenTofu validation gates. |

## Remove a Cluster

Use the state-aware destroy wrapper first. It handles known dependency races and reports possible Hetzner orphans without deleting them outside Terraform:

```sh
(tmp_script=$(mktemp) && trap 'rm -f "$tmp_script"' EXIT && curl -fsSL -o "$tmp_script" https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/scripts/destroy.sh && chmod +x "$tmp_script" && "$tmp_script")
```

Forceful cleanup fallback:

```sh
(tmp_script=$(mktemp) && trap 'rm -f "$tmp_script"' EXIT && curl -fsSL -o "$tmp_script" https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/scripts/cleanup.sh && chmod +x "$tmp_script" && "$tmp_script")
```

> [!WARNING]
> `cleanup.sh` resolves the Terraform HCloud token, activates the matching cluster-named context, and treats that project as dedicated to the cluster. Its dry run includes unrelated runtime resources in the same project; volumes, snapshots, DNS zones, and Storage Boxes require separate opt-in. If Terraform was applied with `-var="hcloud_token=..."`, export that same value as `TF_VAR_hcloud_token` or pass it through `--var-file` before cleanup. Review the plan before typing the cluster name to confirm. `--yes` skips that typed confirmation and is intended only for controlled automation.

<details>
<summary><strong>Fish shell version</strong></summary>

```fish
set tmp_script (mktemp); curl -fsSL -o "$tmp_script" https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/scripts/cleanup.sh; and chmod +x "$tmp_script"; and bash "$tmp_script"; set run_status $status; rm -f "$tmp_script"; test $run_status -eq 0
```

</details>

<details>
<summary><strong>Save as <code>cleanupkh</code> (Bash/Zsh)</strong></summary>

```sh
cleanupkh() { (tmp_script=$(mktemp) && trap 'rm -f "$tmp_script"' EXIT && curl -fsSL -o "$tmp_script" https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/scripts/cleanup.sh && chmod +x "$tmp_script" && "$tmp_script" "$@"); }
```

</details>

## Why Kube-Hetzner

[Hetzner Cloud](https://hetzner.com) provides high-value infrastructure across Europe and the US. Kube-Hetzner combines it with:

- [openSUSE Leap Micro](https://en.opensuse.org/Portal:LeapMicro), an immutable OS with transactional updates and BTRFS rollback.
- [k3s](https://k3s.io), a lightweight certified Kubernetes distribution with integrated operational components.
- [RKE2](https://docs.rke2.io), a hardened Kubernetes distribution for heavier deployments.
- Terraform and OpenTofu, keeping infrastructure explicit, reviewable, and reproducible.

Kube-Hetzner is not affiliated with Hetzner.

## Community

Questions, ideas, and community support belong in [GitHub Discussions](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/discussions). Issues and pull requests are welcome. For contribution setup and repository gates, read [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Support This Project

<div align="center">

Kube-Hetzner is free and open source. If it saves you engineering time or infrastructure cost, please help fund its continued development.

<a href="https://github.com/sponsors/mysticaltech">
<img src="https://img.shields.io/badge/Sponsor_on_GitHub-%E2%9D%A4-EA4AAA?style=for-the-badge&logo=github-sponsors" alt="Sponsor Kube-Hetzner on GitHub">
</a>

<br><br>

Sponsorship directly supports **issue response**, **new capabilities**, **documentation**, **security maintenance**, and **real-cluster release testing**.

**Every contribution helps keep Kube-Hetzner reliable, current, and available to everyone.**

</div>

---

## Acknowledgements

- [k-andy](https://github.com/StarpTech/k-andy), the starting point for this project.
- [Rancher](https://www.rancher.com), for k3s and RKE2.
- [openSUSE](https://www.opensuse.org), for Leap Micro and MicroOS.
- [HashiCorp](https://www.hashicorp.com) and [OpenTofu](https://opentofu.org), for the infrastructure tooling ecosystem.
- The contributors and operators who report issues, improve the module, and test real upgrades.

<div align="center">

<a href="https://www.hetzner.com"><img src="https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/raw/master/.images/hetzner-logo.svg" alt="Hetzner - Server, Cloud, Hosting" height="80"></a>

<br><br>

Thanks to **[Hetzner](https://www.hetzner.com)** for supporting Kube-Hetzner with cloud credits.

</div>

---

## License

Released under the [MIT License](LICENSE).

<div align="center">

**[Back to top](#kube-hetzner)**

</div>
