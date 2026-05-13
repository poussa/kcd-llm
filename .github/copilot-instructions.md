# Copilot Instructions

## Project Overview

Infrastructure repo for a GKE Autopilot cluster with NVIDIA GPU time-slicing, intended for running LLM workloads. GKE Autopilot handles all node provisioning automatically — no node pool management required.

## Cluster Lifecycle

```bash
# Create cluster (defaults: PROJECT_ID=kcd-llm, CLUSTER_NAME=kcd-llm-cluster, REGION=europe-west4)
./create-gke-cluster.sh

# Override region
REGION=europe-west3 ./create-gke-cluster.sh

# Delete cluster
./create-gke-cluster.sh --delete
```

## Testing GPU

```bash
# Verify GPU is available
kubectl apply -f gpu-test-pod.yaml
kubectl logs gpu-test   # should show nvidia-smi output

# Verify time-slicing (4 pods should land on same node)
kubectl apply -f gpu-timeslice-test.yaml
kubectl get pods -l app=gpu-timeslice-test -o wide
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
kubectl delete -f gpu-timeslice-test.yaml
```

## GPU Time-Slicing Convention

Time-slicing is configured entirely via **pod-level node selectors** — there is no cluster-wide config or DaemonSet. Every workload that needs time-sliced GPU access must include these three node selectors:

```yaml
spec:
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-tesla-t4      # or nvidia-l4
    cloud.google.com/gke-gpu-sharing-strategy: "time-sharing"
    cloud.google.com/gke-max-shared-clients-per-gpu: "16"
  containers:
  - resources:
      limits:
        nvidia.com/gpu: "1"
```

GKE NAP then provisions a node advertising 16 virtual GPU slots automatically.

## Key Constraints

- L4 GPUs are **not** available in `europe-north1` (Finland). Supported regions include `europe-west1/3/4/6`, `us-central1`, `us-east1/4`, `us-west1/4`.
- GPU quota (`NVIDIA_L4_GPUS` limit > 0) must exist in the target region before cluster creation.
- The cluster uses the `regular` release channel.
- CUDA image in use: `nvidia/cuda:12.3.1-base-ubuntu22.04`.
