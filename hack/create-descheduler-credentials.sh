#!/usr/bin/env bash
# Create the tier-descheduler-sa-credentials Secret that
# examples/descheduler-deployment.yaml mounts over the standard
# service-account path.
#
# Why this exists: the descheduler's Prometheus client verifies TLS
# against whatever CA bundle sits at
# /var/run/secrets/kubernetes.io/serviceaccount/ca.crt, and its
# Kubernetes client reads its token from the same directory. The
# platform monitoring endpoint (Thanos Querier) presents a certificate
# signed by the service-serving signer, while the API server presents
# one signed by the cluster CA — so the bundle needs BOTH chains, and
# the token needs to be one the monitoring API accepts. Upstream
# descheduler offers no way to point at separate paths, so we mount one
# Secret carrying both.
#
# Idempotent: safe to re-run (also refreshes the token — bound tokens
# expire; re-run before the duration below lapses).
set -euo pipefail

NS="${NS:-cxl-observability}"
SA="tier-descheduler"
SECRET="tier-descheduler-sa-credentials"
# One year; the descheduler does not rotate tokens itself.
TOKEN_DURATION="${TOKEN_DURATION:-8760h}"

# 1. The service account (no-op if the deployment manifests already
#    created it).
oc create serviceaccount "${SA}" -n "${NS}" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null

# 2. The service-serving CA: every namespace carries a ConfigMap
#    openshift-service-ca.crt holding the service-serving signer's
#    bundle (kept fresh by the service-ca operator). Thanos Querier's
#    serving certificate chains to this signer.

# 3. Assemble the bundle: cluster CA (from the kubeconfig) + service
#    CA, plus a bound token for the descheduler service account.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
oc config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > "${WORK}/ca.crt"
oc get cm openshift-service-ca.crt -n "${NS}" \
  -o jsonpath='{.data.service-ca\.crt}' >> "${WORK}/ca.crt"
oc create token "${SA}" -n "${NS}" --duration="${TOKEN_DURATION}" > "${WORK}/token"

oc create secret generic "${SECRET}" -n "${NS}" \
  --from-file=token="${WORK}/token" \
  --from-file=ca.crt="${WORK}/ca.crt" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null

echo "secret ${NS}/${SECRET} created (token duration ${TOKEN_DURATION})"
