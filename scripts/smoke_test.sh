#!/usr/bin/env bash
# Smoke test of the Helm chart on a new local cluster (k3d in CI, or k3s).
# It installs the chart with values-local.yaml and a local image, runs "helm test", then calls
# the MLflow REST API through a port-forward: health, experiment create and search, artifact
# upload and download.
#
# Usage: TAG=<tag of the local image> scripts/smoke_test.sh
#   IMAGE_REPOSITORY   name of the local image (default: mlflow-k8s-helm)
#   LOCAL_PORT         local port of the port-forward (default: 5000)
#   SMOKE_ANY_CONTEXT  set to 1 to run on a kubectl context that is not a k3d cluster
set -euo pipefail

: "${TAG:?set TAG to the tag of the local image, for example TAG=dev}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-mlflow-k8s-helm}"
LOCAL_PORT="${LOCAL_PORT:-5000}"
RELEASE=mlflow
SECRET=mlflow-credentials
CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)/charts/mlflow"
BASE_URL="http://localhost:${LOCAL_PORT}"

log() { printf '==> %s\n' "$*" >&2; }

context="$(kubectl config current-context)"
if [[ "$context" != k3d-* && "${SMOKE_ANY_CONTEXT:-}" != 1 ]]; then
  echo "error: the kubectl context is '$context', not a k3d cluster." >&2
  echo "Set SMOKE_ANY_CONTEXT=1 to run the smoke test on this cluster." >&2
  exit 2
fi
if (exec 3<>"/dev/tcp/127.0.0.1/${LOCAL_PORT}") 2>/dev/null; then
  echo "error: local port ${LOCAL_PORT} is in use. Set LOCAL_PORT to a free port." >&2
  exit 2
fi
log "kubectl context: $context"

tmp_dir="$(mktemp -d)"
port_forward_pid=""
cleanup() {
  local status=$?
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
  if [[ $status -ne 0 ]]; then
    echo "smoke test failed (exit $status). Cluster state:" >&2
    kubectl get all,events -o wide >&2 || true
    kubectl logs -l "app.kubernetes.io/instance=${RELEASE}" --all-containers --prefix --tail=200 >&2 || true
  fi
}
trap cleanup EXIT

# Keep an existing Secret: the database keeps the password of its first start.
if ! kubectl get secret "$SECRET" >/dev/null 2>&1; then
  log "create Secret $SECRET"
  kubectl create secret generic "$SECRET" \
    --from-literal=postgres-password="$(openssl rand -hex 24)" \
    --from-literal=aws-access-key-id=smoke-test \
    --from-literal=aws-secret-access-key=smoke-test
fi

log "helm install $RELEASE (image ${IMAGE_REPOSITORY}:${TAG})"
helm install "$RELEASE" "$CHART_DIR" \
  -f "$CHART_DIR/values-local.yaml" \
  --set image.repository="$IMAGE_REPOSITORY" \
  --set image.tag="$TAG" \
  --set image.pullPolicy=Never \
  --wait --timeout 10m

log "helm test $RELEASE"
helm test "$RELEASE" --logs

log "port-forward svc/$RELEASE to localhost:$LOCAL_PORT"
kubectl port-forward "svc/$RELEASE" "${LOCAL_PORT}:5000" >&2 &
port_forward_pid=$!

log "GET /health"
curl -fsS --retry 30 --retry-delay 2 --retry-all-errors "$BASE_URL/health"
echo

log "create experiment ci-smoke"
curl -fsS -X POST -H "Content-Type: application/json" \
  -d '{"name": "ci-smoke"}' "$BASE_URL/api/2.0/mlflow/experiments/create"
echo
search="$(curl -fsS -X POST -H "Content-Type: application/json" \
  -d '{"max_results": 100}' "$BASE_URL/api/2.0/mlflow/experiments/search")"
if ! grep -Eq '"name": *"ci-smoke"' <<<"$search"; then
  echo "error: experiments/search does not return ci-smoke: $search" >&2
  exit 1
fi
log "experiment ci-smoke found"

log "upload and download an artifact"
artifact_url="$BASE_URL/api/2.0/mlflow-artifacts/artifacts/ci-smoke/hello.txt"
printf 'hello from the smoke test\n' >"$tmp_dir/hello.txt"
curl -fsS -X PUT -H "Content-Type: application/octet-stream" \
  --data-binary "@$tmp_dir/hello.txt" "$artifact_url"
echo
curl -fsS -o "$tmp_dir/hello.out" "$artifact_url"
cmp "$tmp_dir/hello.txt" "$tmp_dir/hello.out"
log "artifact content matches"

log "smoke test passed"
