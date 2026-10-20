# Validation of upstream descheduler PR #1932

Date: 2026-10-20

PR: https://github.com/kubernetes-sigs/descheduler/pull/1932

Branch: `tiraboschi/prometheus_tls_config`

Commit: `64fecb114cf67b911c4fdc388babb85ca8c87b65`

Image tag: `pr1932-64fecb114`

Built directly from the PR head in a separate worktree, without applying the lab fork's patch. Deployed to the existing `tier-descheduler` deployment with its policy, service-account credentials, and CA bundle unchanged. No explicit `tlsConfig` was added: this tests backward-compatible defaults against the HTTPS endpoint with port 9091.

The PR derives the default TLS server name using `u.Hostname()`. The replacement pod successfully created its authenticated Prometheus client and completed its first balancing cycle:

```text
I1020 19:29:55.954312       1 prom_client_controller.go:134] Creating Prometheus client (with SA token)
I1020 19:29:55.963768       1 descheduler.go:252] "Number of evictions/requests" totalEvicted=0 evictionRequests=0
```

The certificate-name mismatch reproduced with the original `u.Host` implementation did not occur. Zero evictions is the observed cycle result, not a failure: the plugin completed rather than returning a metrics-query error.

The PR's client TLS test passed:

```sh
GOTOOLCHAIN=go1.26.0 go test ./pkg/descheduler/client -count=1
```

The host's Go 1.27.2 could not compile vendored kube-openapi code (`undefined: json.SkipFunc`, `undefined: json.DiscardUnknownMembers`); Go 1.26.0 matches the module's declared version and passed.

Build caveats: the Docker build could not read Git metadata from the worktree's host-relative `.git` pointer. The image tag records the tested commit. The application also logged a minor-version parsing warning because the experimental tag is not a normal descheduler version. Neither prevented the observed Prometheus query or balancing cycle.

The PR image remains deployed. `examples/descheduler-deployment.yaml` records its tag and source commit. This validates the existing authenticated configuration, not every new TLS configuration option in the PR.
