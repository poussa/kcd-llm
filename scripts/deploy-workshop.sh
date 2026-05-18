#!/usr/bin/env bash
# deploy-workshop.sh — deploy or delete llm-d across NUM_GROUPS namespaces
set -euo pipefail

GAIE_VERSION=${GAIE_VERSION:-v1.5.0}
LLMD_VERSION=${LLMD_VERSION:-main}
NUM_GROUPS=${NUM_GROUPS:-4}
GATEWAY_TYPE=${GATEWAY_TYPE:-external}   # external | internal
HF_TOKEN=${HF_TOKEN:-}                   # optional HuggingFace token
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARNING: $*" >&2; }

# ── Argument parsing ──────────────────────────────────────────────────────────
DELETE_MODE=false
for arg in "$@"; do
  case "$arg" in
    --delete) DELETE_MODE=true ;;
    --hf-token=*) HF_TOKEN="${arg#--hf-token=}" ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# ── Delete mode ───────────────────────────────────────────────────────────────
if [[ "${DELETE_MODE}" == "true" ]]; then
  log "Deleting all ${NUM_GROUPS} workshop groups…"
  for i in $(seq 1 "$NUM_GROUPS"); do
    NS="group-${i}"
    log "  Cleaning ${NS}…"
    # Uninstall Helm release first (removes finalizers on router resources)
    helm uninstall optimized-baseline -n "${NS}" --ignore-not-found 2>/dev/null || true
    # Delete gateway explicitly to trigger GCP LB cleanup before namespace delete
    kubectl delete gateway llm-d-inference-gateway -n "${NS}" --ignore-not-found 2>/dev/null || true
    # Delete model server
    kubectl delete -n "${NS}" -k "${REPO_ROOT}/guides/optimized-baseline/modelserver/gpu/vllm/gke/" \
      --ignore-not-found 2>/dev/null || true
  done
  log "Waiting 15s for GCP load balancer cleanup to start…"
  sleep 15
  for i in $(seq 1 "$NUM_GROUPS"); do
    NS="group-${i}"
    kubectl delete namespace "${NS}" --ignore-not-found
    log "  Namespace ${NS} deleted."
  done
  log "All groups deleted. NAP GPU nodes will scale down automatically."
  exit 0
fi

# ── CRDs (once) ─────────────────────────────────────────────────────────────
log "Applying Gateway API Inference Extension CRDs (${GAIE_VERSION})…"
kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=${GAIE_VERSION}"

# ── Per-group deployment ─────────────────────────────────────────────────────
for i in $(seq 1 "$NUM_GROUPS"); do
    NS="group-${i}"
    log "━━━ Group ${i} / ${NUM_GROUPS}  (namespace: ${NS}) ━━━"

    # Namespace
    kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

    # HuggingFace token secret (optional — speeds up model downloads)
    if [[ -n "${HF_TOKEN}" ]]; then
        kubectl create secret generic hf-token \
            --from-literal=token="${HF_TOKEN}" \
            -n "${NS}" \
            --dry-run=client -o yaml | kubectl apply -f -
        log "  HuggingFace token secret created."
    fi

    # Router (Helm) — upgrade if already installed
    if helm status optimized-baseline -n "${NS}" &>/dev/null; then
        log "  Helm release exists — upgrading…"
        helm upgrade optimized-baseline \
            oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
            -f "https://raw.githubusercontent.com/llm-d/llm-d/${LLMD_VERSION}/guides/recipes/scheduler/base.values.yaml" \
            -f "https://raw.githubusercontent.com/llm-d/llm-d/${LLMD_VERSION}/guides/optimized-baseline/scheduler/optimized-baseline.values.yaml" \
            --set provider.name=gke \
            --set experimentalHttpRoute.enabled=true \
            --set experimentalHttpRoute.inferenceGatewayName=llm-d-inference-gateway \
            --set epp.resources.requests.cpu=500m \
            --set epp.sidecar.resources.requests.cpu=500m \
            -n "${NS}" --version "${GAIE_VERSION}"
    else
        log "  Installing Helm release…"
        helm install optimized-baseline \
            oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
            -f "https://raw.githubusercontent.com/llm-d/llm-d/${LLMD_VERSION}/guides/recipes/scheduler/base.values.yaml" \
            -f "https://raw.githubusercontent.com/llm-d/llm-d/${LLMD_VERSION}/guides/optimized-baseline/scheduler/optimized-baseline.values.yaml" \
            --set provider.name=gke \
            --set experimentalHttpRoute.enabled=true \
            --set experimentalHttpRoute.inferenceGatewayName=llm-d-inference-gateway \
            --set epp.resources.requests.cpu=500m \
            --set epp.sidecar.resources.requests.cpu=500m \
            -n "${NS}" --version "${GAIE_VERSION}"
    fi

    # Model server
    log "  Deploying model server…"
    kubectl apply -n "${NS}" -k "${REPO_ROOT}/guides/optimized-baseline/modelserver/gpu/vllm/gke/"

    # Gateway
    log "  Deploying ${GATEWAY_TYPE} gateway…"
    kubectl apply -n "${NS}" -k "${REPO_ROOT}/guides/gateway/${GATEWAY_TYPE}/"

    # Stagger model server startups to avoid concurrent GPU memory profiling
    # (vLLM crashes when free memory changes between init snapshot and profiling)
    if [[ "${i}" -lt "${NUM_GROUPS}" ]]; then
        log "  Waiting 90s before next group (GPU memory profiling stagger)…"
        sleep 90
    fi
done

log "All ${NUM_GROUPS} groups submitted.  Waiting for gateways to get IPs…"
echo ""
echo "Watch progress:"
echo "  kubectl get gateway llm-d-inference-gateway -A -w"
echo ""
echo "Once ready, collect IPs with:"
echo "  for i in \$(seq 1 ${NUM_GROUPS}); do"
echo "    echo -n \"group-\$i: \""
echo "    kubectl get gateway llm-d-inference-gateway -n group-\$i -o jsonpath='{.status.addresses[0].value}'"
echo "    echo"
echo "  done"
