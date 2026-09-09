# Cilium upgrade diagnostics

Review the [v2-to-v3 datapath warning](../MIGRATION.md#cilium-datapath-migration)
before changing kube-proxy ownership on an existing cluster. These diagnostics
do not constitute a validated in-place datapath migration procedure.

## Device MTU is not route MTU

The module's standard Cilium Helm `MTU: 1450` is the base device MTU, not a
promise that encrypted pod traffic can carry 1450-byte IP packets. The reported
Cilium 1.17.18 version calculates workload device and route MTUs separately. For a 1450
base, WireGuard plus tunneling yields a 1320 route MTU; WireGuard without
tunneling yields 1370. A pod veth showing 1450 alone is not evidence that
the route MTU is wrong. These figures were verified for 1.17.18, not the module's
current default of 1.19.3. Check the calculation and effective routes for your
deployed Cilium version rather than treating these numbers as universal.

Do not subtract these overheads again from the module default: Cilium will
subtract them from the reduced base too. Nor is automatic detection always
equivalent: the original [MTU fix, PR #847](https://github.com/mysticaltech/terraform-hcloud-kube-hetzner/pull/847)
pinned the private-network base because detection selected the public
interface. Explicit Tailscale, public-overlay and Robot MTU paths have
different budgets and must be assessed separately.

For a suspected blackhole, collect the actual merged Helm values and Cilium
version, device MTUs, and `ip route get <destination>` both on the source
node and inside the affected pod. Compare ordinary pod-to-pod traffic with
host-to-pod and any nested bridge/network namespace. Check route MTUs and
capture ICMP fragmentation-needed/packet-too-big messages privately at both
ends. Reducing the Helm MTU may mitigate one path but does not establish why
the original path failed. Recheck existing and newly created pods separately.

Upstream implementation references:
- [Cilium 1.17.18 device and route MTU calculation](https://github.com/cilium/cilium/blob/v1.17.18/pkg/mtu/mtu.go)
- [Cilium CNI route setup](https://github.com/cilium/cilium/blob/v1.17.18/plugins/cilium-cni/cmd/cmd.go)

## K3s agents and kube-proxy

K3s v1.33.13+k3s2 agents read the server's `DisableKubeProxy` setting during
startup. The absence of `--disable-kube-proxy` in `k3s agent --help` does not
make replacement unsupported on agent nodes. Do not pass that server-only
flag to an agent.

When an existing agent still holds port 10256 after a mode change, verify
that all servers have loaded the intended configuration, whether config
restarts were deferred to Kured, and when each agent last started. The module
does not automatically restart static agents merely because
`enable_kube_proxy` changed. Disabling Cilium's health listener only hides the
port collision; it does not establish that kube-proxy has stopped. A fresh
cluster and an in-place transition need separate acceptance tests.

Upstream implementation references:
- [K3s kube-proxy startup](https://github.com/k3s-io/k3s/blob/v1.33.13%2Bk3s2/pkg/daemons/agent/agent.go)
- [Server-provided kube-proxy configuration](https://github.com/k3s-io/k3s/blob/v1.33.13%2Bk3s2/pkg/agent/config/config.go)

For acceptance, verify every control plane and agent, including Robot and
autoscaler nodes where present: kube-proxy process/listener ownership, Cilium
health, NodePort/ClusterIP reachability, masquerading and connectivity.
HAProxy PROXY-protocol trust failures are a separate investigation; a TLS
failure alone does not identify the Cilium datapath as its cause.
