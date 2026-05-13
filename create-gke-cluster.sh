#!/usr/bin/env bash
set -euo pipefail

# GKE Autopilot cluster with NVIDIA GPU support.
# GKE manages nodes automatically — finds GPU capacity across zones in the region,
# installs drivers, and scales to zero when idle.

# ── Project & cluster identity ────────────────────────────────────────────────
PROJECT_ID="${PROJECT_ID:-kcd-llm}"
CLUSTER_NAME="${CLUSTER_NAME:-kcd-llm-cluster}"
REGION="${REGION:-europe-west4}"

# ── Argument parsing ───────────────────────────────────────────────────────────
DELETE_MODE=false
for arg in "$@"; do
  case "$arg" in
    --delete) DELETE_MODE=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

echo "==> Setting active project"
gcloud config set project "${PROJECT_ID}"

# ── Delete mode ────────────────────────────────────────────────────────────────
if [[ "${DELETE_MODE}" == "true" ]]; then
  echo "==> Deleting Autopilot cluster '${CLUSTER_NAME}' in region '${REGION}'"
  if gcloud container clusters describe "${CLUSTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud container clusters delete "${CLUSTER_NAME}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}" \
      --quiet
    echo "✅ Cluster '${CLUSTER_NAME}' deleted."
  else
    echo "    Cluster '${CLUSTER_NAME}' not found, nothing to delete."
  fi
  exit 0
fi

echo "==> Enabling required APIs"
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  --project="${PROJECT_ID}"

echo "==> Creating GKE Autopilot cluster in region '${REGION}'"
echo "    (GKE will find available GPU capacity across zones automatically)"
if gcloud container clusters describe "${CLUSTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "    Cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  gcloud container clusters create-auto "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --release-channel="regular"
fi

echo "==> Fetching cluster credentials"
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}"

echo ""
echo "✅ Autopilot cluster '${CLUSTER_NAME}' is ready!"
echo ""
echo "GPU time-slicing is configured per-pod via nodeSelector:"
echo ""
echo "  spec:"
echo "    nodeSelector:"
echo "      cloud.google.com/gke-accelerator: nvidia-tesla-t4"
echo "      cloud.google.com/gke-gpu-sharing-strategy: time-sharing"
echo "      cloud.google.com/gke-max-shared-clients-per-gpu: \"16\""
echo "    containers:"
echo "    - resources:"
echo "        limits:"
echo "          nvidia.com/gpu: \"1\""
echo ""
echo "No node management needed — GKE provisions GPU nodes on demand."
