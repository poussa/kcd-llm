#!/usr/bin/env bash
# Workshop setup: create namespaces and deploy vLLM production stack for each group.
# Usage:
#   ./guides/vllm-production-stack/setup-workshop.sh           # deploy all groups
#   ./guides/vllm-production-stack/setup-workshop.sh --delete  # tear down all groups
set -euo pipefail

NUM_GROUPS="${NUM_GROUPS:-5}"
RELEASE_NAME="${RELEASE_NAME:-vllm-stack}"
VALUES_FILE="${VALUES_FILE:-guides/vllm-production-stack/values-gke-workshop.yaml}"
HELM_REPO="https://vllm-project.github.io/production-stack"
CHART="vllm/vllm-stack"
CHART_VERSION="${CHART_VERSION:-0.1.11}"

DELETE_MODE=false
for arg in "$@"; do
  case "$arg" in
    --delete) DELETE_MODE=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

echo "==> Adding Helm repo"
helm repo add vllm "${HELM_REPO}" --force-update
helm repo update vllm

for i in $(seq 1 "${NUM_GROUPS}"); do
  NAMESPACE="group-${i}"

  if [[ "${DELETE_MODE}" == "true" ]]; then
    echo "==> Deleting group-${i}"
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --ignore-not-found
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found
  else
    echo "==> Deploying group-${i} → namespace '${NAMESPACE}'"
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install "${RELEASE_NAME}" "${CHART}" \
      --version "${CHART_VERSION}" \
      --namespace "${NAMESPACE}" \
      -f "${VALUES_FILE}" \
      --wait --timeout 5m
    echo "    ✅ group-${i} deployed"
  fi
done

if [[ "${DELETE_MODE}" == "false" ]]; then
  echo ""
  echo "✅ Workshop deployed for ${NUM_GROUPS} groups."
  echo ""
  echo "Each group can reach their endpoint via:"
  echo "  kubectl port-forward svc/vllm-stack-router-service 8080:80 -n group-N"
  echo "  curl http://localhost:8080/v1/completions ..."
fi
