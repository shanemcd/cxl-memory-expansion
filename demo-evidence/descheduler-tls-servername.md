# Descheduler Prometheus TLS hostname reproduction

Date: 2026-10-20

## Change under test

In `pkg/descheduler/client/client.go`, temporarily replace `ServerName: u.Hostname()` with the original `ServerName: u.Host`. Build a separate image tagged `v0.37.0-tls-repro` and change only the descheduler deployment's image. Keep the policy, service-account token, CA bundle, and Prometheus endpoint unchanged.

Endpoint: `https://thanos-querier.openshift-monitoring.svc:9091`

## Observed failure

The reverted build started and remained Running, but its first balancing cycle failed:

```text
E1020 19:25:04.454385       1 descheduler.go:300] "running balance extension point failed with error" err="plugin \"LowNodeUtilization\" finished with error: error getting node usage: unable to capture prometheus metrics: Post \"https://thanos-querier.openshift-monitoring.svc:9091/api/v1/query\": tls: failed to verify certificate: x509: certificate is valid for thanos-querier.openshift-monitoring.svc, thanos-querier.openshift-monitoring.svc.cluster.local, not thanos-querier.openshift-monitoring.svc:9091" profile="tier-aware-rebalance"
```

Go's URL `Host` field includes the port. TLS `ServerName` identifies the certificate's expected host, not the network address including its port. The service certificate contains the correct DNS names, but neither includes `:9091`. `Hostname()` removes the port while the URL still sends the request to port 9091. Certificate verification remains enabled.

This is a certificate-name mismatch, not an untrusted-CA or service-account authorization failure. The descheduler cannot obtain utilization metrics, so the affected balancing plugin fails even though the pod is Running.

## Restoration

Restore `v0.37.0-tlsfix` and the local source line. The replacement pod logged creation of the authenticated Prometheus client at 19:25:23 and completed its first balancing cycle at 19:25:23.935793 with zero evictions and no metrics error. The descheduler checkout was clean afterward. No revert was committed to the fork.
