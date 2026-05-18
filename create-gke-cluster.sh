#!/usr/bin/env bash
set -euo pipefail

# GKE Standard cluster for the KCD LLM workshop.
# Creates a pre-provisioned GPU node pool with time-slicing so all group pods
# land on the same node regardless of when each group deploys.
#
# Usage:
#   ./create-gke-cluster.sh                    # T4 GPU (default)
#   ./create-gke-cluster.sh --gpu=l4           # L4 GPU
#   ./create-gke-cluster.sh --delete           # delete cluster

# ── Configuration ─────────────────────────────────────────────────────────────
PROJECT_ID="${PROJECT_ID:-kcd-llm}"
CLUSTER_NAME="${CLUSTER_NAME:-kcd-llm-cluster}"
REGION="${REGION:-europe-west4}"
NETWORK="${NETWORK:-default}"
NUM_GROUPS="${NUM_GROUPS:-4}"   # number of time-slice slots to advertise

# System node pool — runs gateway, router, and Kubernetes system components
SYSTEM_MACHINE="${SYSTEM_MACHINE:-e2-standard-4}"
SYSTEM_NODES="${SYSTEM_NODES:-1}"

# Proxy-only subnet for GKE Gateway (L7 LB)
PROXY_SUBNET_NAME="${PROXY_SUBNET_NAME:-proxy-only-subnet-${REGION}}"
case "${REGION}" in
  europe-west4) PROXY_SUBNET_RANGE="${PROXY_SUBNET_RANGE:-10.0.2.0/23}" ;;
  europe-west1) PROXY_SUBNET_RANGE="${PROXY_SUBNET_RANGE:-10.0.4.0/23}" ;;
  europe-west3) PROXY_SUBNET_RANGE="${PROXY_SUBNET_RANGE:-10.0.6.0/23}" ;;
  *)            PROXY_SUBNET_RANGE="${PROXY_SUBNET_RANGE:-10.0.0.0/23}" ;;
esac

# ── Argument parsing ───────────────────────────────────────────────────────────
DELETE_MODE=false
GPU_TYPE="t4"
for arg in "$@"; do
  case "$arg" in
    --delete)   DELETE_MODE=true ;;
    --gpu=t4)   GPU_TYPE="t4" ;;
    --gpu=l4)   GPU_TYPE="l4" ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# GPU-specific settings
case "${GPU_TYPE}" in
  t4)
    GPU_ACCELERATOR="nvidia-tesla-t4"
    GPU_MACHINE="${GPU_MACHINE:-n1-standard-8}"  # 8 vCPU, 30GB — fits 4×2Gi pods comfortably
    GPU_NODE_POOL="gpu-t4-pool"
    ;;
  l4)
    GPU_ACCELERATOR="nvidia-l4"
    GPU_MACHINE="${GPU_MACHINE:-g2-standard-8}"  # L4 requires g2 machine family
    GPU_NODE_POOL="gpu-l4-pool"
    ;;
esac

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "Setting active project: ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

# ── Delete mode ────────────────────────────────────────────────────────────────
if [[ "${DELETE_MODE}" == "true" ]]; then
  log "Deleting cluster '${CLUSTER_NAME}' in region '${REGION}'…"
  if gcloud container clusters describe "${CLUSTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud container clusters delete "${CLUSTER_NAME}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}" \
      --quiet
    log "✅ Cluster '${CLUSTER_NAME}' deleted."
  else
    log "Cluster '${CLUSTER_NAME}' not found, nothing to delete."
  fi
  exit 0
fi

# ── Enable APIs ────────────────────────────────────────────────────────────────
log "Enabling required APIs…"
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  networkservices.googleapis.com \
  --project="${PROJECT_ID}"

# ── Create cluster ─────────────────────────────────────────────────────────────
log "Creating GKE Standard cluster '${CLUSTER_NAME}' in region '${REGION}'…"
if gcloud container clusters describe "${CLUSTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  log "Cluster already exists, skipping creation."
else
  gcloud container clusters create "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --release-channel="regular" \
    --machine-type="${SYSTEM_MACHINE}" \
    --num-nodes="${SYSTEM_NODES}" \
    --enable-autoscaling --min-nodes=1 --max-nodes=4 \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --enable-ip-alias \
    --network="${NETWORK}"
  log "✅ Cluster created."
fi

# ── Enable Gateway API ─────────────────────────────────────────────────────────
log "Enabling Gateway API on cluster (installs HTTPRoute, GCPBackendPolicy CRDs)…"
gcloud container clusters update "${CLUSTER_NAME}" \
  --gateway-api=standard \
  --region="${REGION}" \
  --project="${PROJECT_ID}"
log "✅ Gateway API enabled."

# ── Create GPU node pool ───────────────────────────────────────────────────────
log "Creating ${GPU_TYPE^^} GPU node pool '${GPU_NODE_POOL}' (time-slicing ×${NUM_GROUPS})…"
if gcloud container node-pools describe "${GPU_NODE_POOL}" \
    --cluster="${CLUSTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  log "GPU node pool already exists, skipping."
else
  gcloud container node-pools create "${GPU_NODE_POOL}" \
    --cluster="${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --node-locations="${REGION}-b" \
    --machine-type="${GPU_MACHINE}" \
    --accelerator="type=${GPU_ACCELERATOR},count=1,gpu-sharing-strategy=time-sharing,max-shared-clients-per-gpu=${NUM_GROUPS}" \
    --num-nodes=1 \
    --enable-autoscaling --min-nodes=1 --max-nodes=2 \
    --node-taints="nvidia.com/gpu=present:NoSchedule" \
    --node-labels="cloud.google.com/gke-accelerator=${GPU_ACCELERATOR}"
  log "✅ GPU node pool '${GPU_NODE_POOL}' created with ${NUM_GROUPS} time-slice slots."
fi

# ── Proxy-only subnet ──────────────────────────────────────────────────────────
log "Creating proxy-only subnet for GKE Gateway…"
if gcloud compute networks subnets describe "${PROXY_SUBNET_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  log "Proxy-only subnet already exists, skipping."
else
  gcloud compute networks subnets create "${PROXY_SUBNET_NAME}" \
    --project="${PROJECT_ID}" \
    --network="${NETWORK}" \
    --region="${REGION}" \
    --range="${PROXY_SUBNET_RANGE}" \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE
  log "✅ Proxy-only subnet '${PROXY_SUBNET_NAME}' created (${PROXY_SUBNET_RANGE})."
fi

# ── Fetch credentials ──────────────────────────────────────────────────────────
log "Fetching cluster credentials…"
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}"

echo ""
echo "✅ Cluster '${CLUSTER_NAME}' is ready!"
echo ""
echo "   GPU type      : ${GPU_TYPE^^} (${GPU_ACCELERATOR})"
echo "   Machine type  : ${GPU_MACHINE}"
echo "   Time-slices   : ${NUM_GROUPS} (1 per group)"
echo ""
echo "GPU time-slicing is pre-configured on the node pool."
echo "Pods only need to request the GPU and tolerate the node taint:"
echo ""
echo "  spec:"
echo "    tolerations:"
echo "    - key: nvidia.com/gpu"
echo "      operator: Exists"
echo "      effect: NoSchedule"
echo "    containers:"
echo "    - resources:"
echo "        limits:"
echo "          nvidia.com/gpu: \"1\""
echo ""
echo "To create with L4 GPUs instead:"
echo "  ./create-gke-cluster.sh --gpu=l4"
