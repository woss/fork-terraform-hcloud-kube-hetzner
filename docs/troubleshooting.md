# Troubleshooting

Start with the fast health checks below, then narrow the failure to Hetzner infrastructure, SSH and cloud-init, the Kubernetes service, or cluster controllers. For an unreachable node, the `/debug-node` agent skill follows the repository's rescue-mode workflow.

[Documentation index](index.md) | [Day-2 operations](operations.md) | [SSH guide](ssh.md)

## Quick Status Check

```sh
hcloud context create Kube-hetzner  # First time only
hcloud server list                   # Check nodes
hcloud network describe k3s          # Check network
hcloud loadbalancer describe k3s-traefik  # Check LB
```

## HAProxy TLS Failures

For intermittent TLS failures with HAProxy behind a PROXY-protocol load balancer,
see [HAProxy transport-peer diagnosis](haproxy-proxy-protocol.md). Verify the
socket source address before changing trusted CIDRs or Cilium settings.

## SSH Troubleshooting

```sh
ssh root@<control-plane-ip> -i /path/to/private_key -o StrictHostKeyChecking=no

# View k3s logs
journalctl -u k3s          # Control plane
journalctl -u k3s-agent    # Agent nodes

# Check config
cat /etc/rancher/k3s/config.yaml

# Check uptime
last reboot
uptime
```

## K3s certificate expiry: `kubectl` works but controllers do not reconcile

If `kubectl` can still read and patch objects but rollouts never progress, check
whether K3s component certificates expired on the control-plane nodes. One
common symptom is a Deployment whose spec was accepted, but whose
`observedGeneration` never catches up:

```sh
kubectl get deploy <name> -o jsonpath='generation={.metadata.generation} observed={.status.observedGeneration} updated={.status.updatedReplicas} ready={.status.readyReplicas} replicas={.status.replicas}{"\n"}'
```

Other useful checks:

```sh
kubectl get events --sort-by=.lastTimestamp | grep CertificateExpirationWarning

ssh root@<control-plane-ip> -i /path/to/private_key -o IdentitiesOnly=yes
k3s certificate check --output table
journalctl -u k3s -n 100 --no-pager | grep -E 'certificate has expired|tls: bad certificate|leaderelection'
```

Typical log lines include `tls: failed to verify certificate: x509: certificate
has expired` from `leaderelection.go`, or etcd peer messages such as
`remote error: tls: bad certificate`. In that state, the API server may still
answer some requests, while the scheduler/controller-manager/etcd leadership
path is unhealthy.

K3s renews expired or near-expiry leaf certificates on service startup. Restart
the control-plane nodes one at a time, wait for each node to return, and restart
the node used by your current kubeconfig endpoint last if possible. Then check
that `k3s certificate check --output table` no longer shows expired leaf
certificates. `WARNING` rows for certs that are near expiry can remain; `EXPIRED`
rows should be gone.

```sh
for host in <control-plane-ip-1> <control-plane-ip-2> <control-plane-ip-3>; do
  ssh root@"${host}" -i /path/to/private_key -o IdentitiesOnly=yes \
    'systemctl restart k3s'
  ssh root@"${host}" -i /path/to/private_key -o IdentitiesOnly=yes \
    'systemctl is-active k3s && k3s certificate check --output table | grep -E "EXPIRED|WARNING" || true'
done
```

If automatic renewal on restart is not enough, use the
[K3s manual rotation flow](https://docs.k3s.io/cli/certificate) on each server
(`systemctl stop k3s`, `k3s certificate rotate`, `systemctl start k3s`). Rotate
servers first, then agents.

The admin kubeconfig contains client certificates too. After renewal or
rotation, fetch a fresh copy from any healthy control-plane node, replace its
loopback API address with the endpoint you use to reach the cluster, and verify
it before atomically replacing your local copy:

```sh
control_plane_ip=203.0.113.10
reachable_api_host=api.example.com
private_key=/path/to/private_key
kubeconfig=clustername_kubeconfig.yaml
(
  set -eu
  umask 077
  tmp_kubeconfig=$(mktemp "$(dirname "$kubeconfig")/.k3s-kubeconfig.tmp.XXXXXX")
  trap 'rm -f "$tmp_kubeconfig"' EXIT
  ssh "root@$control_plane_ip" -i "$private_key" \
    'cat /etc/rancher/k3s/k3s.yaml' > "$tmp_kubeconfig" || exit 1
  kubectl config set-cluster default \
    --server="https://$reachable_api_host:6443" \
    --kubeconfig="$tmp_kubeconfig" || exit 1
  kubectl --kubeconfig="$tmp_kubeconfig" get nodes || exit 1
  mv "$tmp_kubeconfig" "$kubeconfig" || exit 1
  trap - EXIT
)
```

After the controller manager observes the pending Deployment generation, rerun
the rollout check:

```sh
kubectl rollout status deploy/<name> --timeout=300s
kubectl get pods -l app=<label> -o wide
```
