# HAProxy PROXY protocol and intermittent TLS

The default non-Klipper HAProxy values enable PROXY protocol on the Hetzner load
balancer and configure HAProxy to require it from `127.0.0.1/32`, `10.0.0.0/8`,
and `haproxy_additional_proxy_protocol_ips`. The latter defaults to `[]`.
Klipper does not render this setting. `haproxy_values` replaces the defaults;
`haproxy_merge_values` can override them, so inspect the effective values too.

## What the source list means

The list matches the **TCP socket peer before the PROXY header is decoded**,
not the client address carried inside that header or an HTTP forwarded header.
The pinned chart 1.52.1 uses ingress controller 3.2.12, whose
[rule generator](https://github.com/haproxytech/kubernetes-ingress/blob/v3.2.12/pkg/haproxy/rules/reqProxyProtocol.go)
produces a conditional `tcp-request connection expect-proxy layer4` rule.

| Socket peer | PROXY preamble before TLS | Ordinary TLS |
| --- | --- | --- |
| Matches a configured CIDR | Accepted; supplied client address is trusted | Rejected: required preamble is missing |
| Does not match | Rejected: preamble reaches the TLS listener as non-TLS data | Accepted by this protocol gate |

Other TLS, ingress and access-control checks still apply. See the upstream
[proxy-protocol reference](https://www.haproxy.com/documentation/kubernetes-ingress/community/configuration-reference/configmap/#proxy-protocol).

## Diagnose the failing path

In [#2288's follow-up](https://github.com/mysticaltech/terraform-hcloud-kube-hetzner/issues/2288#issuecomment-5584145883),
the reporter isolated a same-node path using a public node address as the socket
source. PROXY-prefixed requests failed, while binding the same request to a
private node address succeeded. Adding the observed public node `/32` peers
resolved their tests. This is separate from the K3s kube-proxy restart issue;
it does not establish that every intermittent TLS failure has this cause.

Before changing configuration, have the cluster operator:

1. Inspect the effective Helm values, controller ConfigMap and generated HAProxy
   source map. Check overrides and whether the load balancer sends PROXY protocol.
2. Correlate failing requests with LB target, ingress pod and same-node versus
   cross-node delivery. Observe the socket source at the ingress pod before
   HAProxy decodes the header; do not infer it from an HTTP access-log client IP.
3. On an authorized node, compare a PROXY-prefixed request to the same pod TLS
   port using default source selection versus an explicitly bound private source.
   For example, use `curl --haproxy-protocol --interface <private-node-ip>` with
   the application's correct hostname, certificate validation and pod endpoint.
   Repeat without the interface override. Record actual source IPs, not secrets
   or full production payloads.
4. Check ordinary requests from that source too, including host-network workloads
   and HTTP/TLS probes. A TCP-only health check does not demonstrate TLS success.

## Bounded mitigation

If the unlisted peer is controlled, expected to send PROXY protocol, and does
not also need ordinary traffic to these listeners, add only its observed address:

```hcl
haproxy_additional_proxy_protocol_ips = [
  "203.0.113.10/32", # Replace with a verified IPv4 transport peer.
  "2001:db8::10/128", # Only if a verified IPv6 transport peer is also needed.
]
```

These are documentation placeholders, not a universal node list. Recheck all
LB targets and ingress placements, direct HTTP/TLS callers, client-IP-dependent
access controls, and rescheduling/autoscaling after the change. Remove entries
when those peer addresses are no longer controlled by the cluster.

Do not add all public addresses, CDN/client ranges or wide networks to make the
symptom disappear. An admitted peer can assert a different client IP, and adding
it also changes ordinary traffic from that peer from accepted to rejected.
When the same source carries both traffic forms, this source-only setting cannot
distinguish them. Investigate source preservation, separate listeners or paths
with the operator instead. Changing `externalTrafficPolicy` to `Local` changes
forwarding and health-target behavior and needs its own deployment validation.

## Verification boundary

`uv run scripts/tests/test_haproxy_proxy_protocol.py` renders the actual module
values without providers and exercises the controller's rule with native
HAProxy, a generated certificate and loopback sockets. It covers default trusted
IPv4, unlisted IPv6, an added exact IPv6 peer and unrelated exact CIDRs. This
proves protocol-gate behavior, not Hetzner/Cilium source selection. A live
same-node/cross-node matrix and ingress rollout remain necessary to validate
the mitigation for a particular cluster. Module defaults are unchanged.
