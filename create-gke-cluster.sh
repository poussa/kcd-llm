#!/usr/bin/env bash
set -euo pipefail

# GKE Cluster with NVIDIA L4 GPU (G2 series)
# Supports both Standard and Autopilot modes.
# Autopilot: GKE manages nodes, finds GPU capacity across the region automatically.
# Standard:  You manage node pools; GPU time-slicing configured via setup-gpu-timeslicing.sh.

# ── Project & cluster identity ────────────────────────────────────────────────
PROJECT_ID="${PROJECT_ID:-kcd-llm}"
CLUSTER_NAME="${CLUSTER_NAME:-kcd-llm-cluster}"
REGION="${REGION:-europe-west4}"            # used by Autopilot (regional)
ZONE="${ZONE:-europe-west4-a}"              # used by Standard (zonal); change if stockout

# ── Mode ───────────────────────────────────────────────────────────────────────
# AUTOPILOT=true  → GKE Autopilot (recommended: handles GPU capacity & scheduling)
# AUTOPILOT=false → Standard cluster with manual GPU node pool
AUTOPILOT="${AUTOPILOT:-true}"

# ── GPU node pool (Standard mode only) ────────────────────────────────────────
# g2-standard-4  →  4 vCPU / 16 GB / 1× L4
# g2-standard-8  →  8 vCPU / 32 GB / 1× L4
# g2-standard-12 → 12 vCPU / 48 GB / 1× L4
# g2-standard-16 → 16 vCPU / 64 GB / 1× L4
# g2-standard-32 → 32 vCPU / 128 GB / 1× L4
GPU_MACHINE_TYPE="${GPU_MACHINE_TYPE:-g2-standard-4}"
GPU_TYPE="${GPU_TYPE:-nvidia-l4}"
GPU_COUNT="${GPU_COUNT:-1}"
GPU_POOL_NAME="${GPU_POOL_NAME:-gpu-pool}"
GPU_NODE_COUNT="${GPU_NODE_COUNT:-1}"
GPU_NODE_MIN="${GPU_NODE_MIN:-0}"           # autoscaler minimum (0 = scale to zero)
GPU_NODE_MAX="${GPU_NODE_MAX:-3}"           # autoscaler maximum

# ── System (CPU-only) node pool (Standard mode only) ──────────────────────────
CPU_MACHINE_TYPE="${CPU_MACHINE_TYPE:-e2-standard-2}"
CPU_NODE_COUNT="${CPU_NODE_COUNT:-1}"

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
  if [[ "${AUTOPILOT}" == "true" ]]; then
    echo "==> Deleting Autopilot cluster '${CLUSTER_NAME}' in region '${REGION}'"
    if gcloud container clusters describe "${CLUSTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
      gcloud container clusters delete "${CLUSTER_NAME}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet
      echo "✅ Autopilot cluster '${CLUSTER_NAME}' deleted."
    else
      echo "    Cluster '${CLUSTER_NAME}' not found, nothing to delete."
    fi
  else
    echo "==> Deleting Standard cluster '${CLUSTER_NAME}' in zone '${ZONE}'"
    if gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
      gcloud container clusters delete "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --quiet
      echo "✅ Standard cluster '${CLUSTER_NAME}' deleted."
    else
      echo "    Cluster '${CLUSTER_NAME}' not found, nothing to delete."
    fi
  fi
  exit 0
fi

echo "==> Enabling required APIs"
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  --project="${PROJECT_ID}"

# ── Autopilot mode ─────────────────────────────────────────────────────────────
if [[ "${AUTOPILOT}" == "true" ]]; then
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
  echo "GPU time-slicing is configured per-pod via annotations:"
  echo ""
  echo "  metadata:"
  echo "    annotations:"
  echo "      cloud.google.com/gke-gpu-sharing-strategy: time-sharing"
  echo "      cloud.google.com/gke-max-shared-clients-per-gpu: \"16\""
  echo "  spec:"
  echo "    containers:"
  echo "    - resources:"
  echo "        limits:"
  echo "          nvidia.com/gpu: \"1\""
  echo ""
  echo "No node management needed — GKE provisions GPU nodes on demand."

# ── Standard mode ──────────────────────────────────────────────────────────────
else
  echo "==> Creating GKE Standard cluster in zone '${ZONE}'"
  if gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "    Cluster '${CLUSTER_NAME}' already exists, skipping creation."
  else
    gcloud container clusters create "${CLUSTER_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --release-channel="regular" \
      --machine-type="${CPU_MACHINE_TYPE}" \
      --num-nodes="${CPU_NODE_COUNT}" \
      --workload-pool="${PROJECT_ID}.svc.id.goog" \
      --no-enable-basic-auth \
      --enable-ip-alias \
      --logging=SYSTEM,WORKLOAD \
      --monitoring=SYSTEM
  fi

  echo "==> Adding GPU node pool with NVIDIA L4"
  if gcloud container node-pools describe "${GPU_POOL_NAME}" --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "    Node pool '${GPU_POOL_NAME}' already exists, skipping creation."
  else
    gcloud container node-pools create "${GPU_POOL_NAME}" \
      --cluster="${CLUSTER_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --machine-type="${GPU_MACHINE_TYPE}" \
      --accelerator="type=${GPU_TYPE},count=${GPU_COUNT},gpu-driver-version=latest" \
      --num-nodes="${GPU_NODE_COUNT}" \
      --enable-autoscaling \
      --min-nodes="${GPU_NODE_MIN}" \
      --max-nodes="${GPU_NODE_MAX}" \
      --node-taints="nvidia.com/gpu=present:NoSchedule" \
      --node-labels="cloud.google.com/gke-accelerator=${GPU_TYPE}"
  fi

  echo "==> Fetching cluster credentials"
  gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}"

  echo ""
  echo "✅ Standard cluster '${CLUSTER_NAME}' is ready!"
  echo ""
  echo "GPU nodes are tainted with: nvidia.com/gpu=present:NoSchedule"
  echo "Add this toleration to GPU workloads:"
  echo ""
  echo "  tolerations:"
  echo "  - key: nvidia.com/gpu"
  echo "    operator: Equal"
  echo "    value: present"
  echo "    effect: NoSchedule"
  echo ""
  echo "GPU driver is installed automatically via GKE's built-in driver installer."
  echo "Run ./setup-gpu-timeslicing.sh to configure time-slicing (16 slices per GPU)."
  echo "Verify GPU node is ready:"
  echo "  kubectl get nodes -l cloud.google.com/gke-accelerator=${GPU_TYPE}"
  echo "  kubectl describe node <gpu-node> | grep -A5 'nvidia.com/gpu'"
fi
