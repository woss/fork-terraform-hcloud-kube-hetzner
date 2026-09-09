Kube-Hetzner requires you to have a recent version of OpenSSH (>=6.5) installed on your client, and the use of a key-pair generated with either of the following algorithms:

- ssh-ed25519 (preferred, and most simple to use without passphrase)
- rsa-sha2-512
- rsa-sha2-256

If your key-pair is of the `ssh-ed25519` sort (useful command `ssh-keygen -t ed25519`), and without of passphrase, you do not need to do anything else. Just set `public_key` and `private_key` to their respective path values in your kube.tf file.

---

Otherwise, for a key-pair with passphrase or a device like a Yubikey, make sure you have an SSH agent running and your key is loaded with:

```bash
eval ssh-agent $SHELL
ssh-add ~/.ssh/my_private-key_id
```

Verify it is loaded with:

```bash
ssh-add -l
```

Then set `private_key = null` in your kube.tf file, as it will be read from the ssh-agent automatically.

---

## SSH port lifecycle

Choose `ssh_port` before creating nodes. It configures sshd and the SELinux
custom-port label through first-boot cloud-init. Existing static nodes ignore
changes to that cloud-init data, while Terraform's SSH connections and the
managed firewall rule use the newly configured port. Changing the variable
alone is **not an in-place SSH-port migration**: it can remove public SSH access
or fail partway through an apply. Extra firewall rules or private/overlay access
may preserve an old-port path; do not assume every path is lost or still usable.

The NAT router is not an exception that safely migrates in place: changing its
SSH connection contract triggers router replacement. This does not migrate
existing control-plane or agent listeners behind it. Existing autoscaler nodes
also keep their old configuration; nodes created after an updated autoscaler
configuration is deployed can use the new port, leaving a mixed-port fleet.

If you changed the port unintentionally:

1. Restore the original `ssh_port` value in your Terraform configuration and
   generate and review a fresh plan. Do not reuse a plan saved with the new port.
2. Check that the planned firewall rule matches the port the affected nodes
   still listen on, retaining the intended source CIDRs. Review all other
   actions, especially NAT-router replacements and partially completed changes,
   before deciding whether to apply. If planning fails on SSH-dependent work,
   stop and use a separately verified management/recovery path; do not force a
   full apply or blindly edit state.
3. Inventory nodes created or manually changed while the new value was active,
   including autoscaled nodes. Restoring the old rule may help unchanged nodes
   but can strand new-port nodes. Verify reachability per node; **restoring the
   variable does not automatically recover every node**.

An intentional migration requires coordinated old/new firewall allowances and
listeners, persistent SELinux configuration, verification on the new port,
rollback, and coverage of NAT bastions and autoscaled nodes before retiring
the old port. Do not remove the server `user_data` lifecycle ignore or replay
arbitrary cloud-init commands as a shortcut. This warning mitigates the risk;
it does not resolve the migration defect tracked in
[#2285](https://github.com/mysticaltech/terraform-hcloud-kube-hetzner/issues/2285).

## Firewall SSH source and changing IPs

SSH access is controlled by the Hetzner Cloud firewall, and the module configures it via the `firewall_ssh_source` input. This is a list of CIDR blocks that are allowed to connect to the nodes over SSH (for a single IPv4 address, use a `/32`, for IPv6 a `/128`).

If your IP changes, you are not locked out permanently:

- Update `firewall_ssh_source` in your `kube.tf` (or the corresponding variable in Terraform Cloud).
- Run `terraform plan` and `terraform apply`.

Terraform updates the firewall through the Hetzner API, so SSH access is not required to make this change. If you need access immediately, you can temporarily add a wider CIDR (for example `0.0.0.0/0` and/or `::/0`), apply, and then tighten it again once you are connected. A static IP or a VPN with a fixed egress IP also avoids future changes.

## Ephemeral SSH access (open only during apply, closed at rest)

If you want the firewall to expose **no SSH port at all** day-to-day, and open it only while Terraform provisions or upgrades nodes, use a two-apply wrapper around `firewall_ssh_source` instead of a module flag. A single-apply toggle cannot exist cleanly in the declarative model: the firewall ruleset is one resource applied once per run, provisioning itself needs SSH mid-apply, and any imperative rule-stripping step would leave a perpetual `terraform plan` diff and fail open if an apply is interrupted (see the discussion in issue #2224).

The wrapper pattern — open to your current IP, do the work, close:

```bash
#!/usr/bin/env bash
set -euo pipefail

MY_IP="$(curl -4 -s https://ifconfig.me)/32"

# 1. Open SSH to your current IP only, for the duration of the run
terraform apply -auto-approve -var "firewall_ssh_source=[\"$MY_IP\"]"

# 2. Close SSH again (empty list = no SSH rule at the firewall)
terraform apply -auto-approve -var 'firewall_ssh_source=[]'
```

Declare the variable pass-through in your `kube.tf`:

```tf
variable "firewall_ssh_source" {
  type    = list(string)
  default = [] # closed at rest
}

module "kube-hetzner" {
  # ...
  firewall_ssh_source = var.firewall_ssh_source
}
```

Notes:

- Both applies produce clean plans — there is no perpetual drift, because the firewall always matches the last-applied variable value.
- If a run is interrupted between the two applies, SSH stays open **only to your own IP**; re-run step 2 (or use `hcloud firewall` from the CLI) to close it.
- In CI, replace `MY_IP` with the runner's egress IP and run step 2 in an `always()`/`trap`-style cleanup step so the close happens even on failure.
- Kubernetes API access is separate (`firewall_kube_api_source`); this pattern only concerns the SSH rule.
