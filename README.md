# kcd-llm

GKE cluster setup with NVIDIA L4 GPU time-slicing for running LLM workloads.

## Prerequisites

- [`gcloud`](https://cloud.google.com/sdk/docs/install) CLI installed and authenticated
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/) installed
- [`jq`](https://stedolan.github.io/jq/) installed (for quota checks)
- A GCP project with billing enabled

## Authentication

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

## Check GPU Quota

Before creating the cluster, verify you have L4 GPU quota in `europe-west4`:

```bash
gcloud compute regions describe europe-west4 \
  --project=$PROJECT_ID \
  --format="json" \
  | jq '.quotas[] | select(.metric | contains("L4"))'
```

You need `NVIDIA_L4_GPUS` limit > 0. If not, request a quota increase at:
**https://console.cloud.google.com/iam-admin/quotas** → filter "NVIDIA L4".

## Create GKE Cluster

The script supports two modes, controlled by the `AUTOPILOT` env var (default: `true`).

### Autopilot (Recommended)

GKE manages all nodes automatically — no node pool configuration needed. GKE finds available GPU capacity across zones in the region automatically, handles driver installation, and scales to zero when idle.

```bash
./create-gke-cluster.sh
```

GPU time-slicing is configured per-pod via **node selectors** (no cluster-level setup needed):

```yaml
spec:
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-tesla-t4   # or nvidia-l4
    cloud.google.com/gke-gpu-sharing-strategy: "time-sharing"
    cloud.google.com/gke-max-shared-clients-per-gpu: "16"
  containers:
  - resources:
      limits:
        nvidia.com/gpu: "1"
```

GKE NAP provisions a node advertising 16 virtual GPU slots, allowing up to 16 pods to share one physical GPU.

See [`gpu-timeslice-test.yaml`](gpu-timeslice-test.yaml) for a working 4-pod example.

### Standard Mode

Manually managed node pools. Useful when you need more control over node configuration. Run `setup-gpu-timeslicing.sh` separately to configure time-slicing.

```bash
AUTOPILOT=false ./create-gke-cluster.sh
```

### Configuration

All settings can be overridden via environment variables:

| Variable           | Default              | Mode      | Description                            |
|--------------------|----------------------|-----------|----------------------------------------|
| `PROJECT_ID`       | `kcd-llm`            | Both      | GCP project ID                         |
| `CLUSTER_NAME`     | `kcd-llm-cluster`    | Both      | GKE cluster name                       |
| `AUTOPILOT`        | `true`               | Both      | `true` = Autopilot, `false` = Standard |
| `REGION`           | `europe-west4`       | Autopilot | GCP region                             |
| `ZONE`             | `europe-west4-a`     | Standard  | GCP zone (must support L4 GPUs)        |
| `GPU_MACHINE_TYPE` | `g2-standard-4`      | Standard  | GPU node machine type                  |
| `GPU_NODE_COUNT`   | `1`                  | Standard  | Initial GPU node count                 |
| `GPU_NODE_MIN`     | `0`                  | Standard  | Autoscaler minimum (0 = scale to zero) |
| `GPU_NODE_MAX`     | `3`                  | Standard  | Autoscaler maximum                     |
| `CPU_MACHINE_TYPE` | `e2-standard-2`      | Standard  | CPU node machine type                  |
| `CPU_NODE_COUNT`   | `1`                  | Standard  | CPU node count                         |

### Delete Cluster

```bash
# Autopilot
./create-gke-cluster.sh --delete

# Standard
AUTOPILOT=false CLUSTER_NAME=dev ZONE=europe-west4-a ./create-gke-cluster.sh --delete
```

## Configure GPU Time-Slicing (Standard mode only)

> In Autopilot mode, time-slicing is configured per-pod via node selectors (see above). This section applies to Standard mode only.

The GPU node pool autoscales from 0, so no GPU node exists until a workload requests one or you scale it manually. Before running the time-slicing setup, ensure a GPU node is present:

```bash
gcloud container clusters resize <CLUSTER_NAME> \
  --node-pool=gpu-pool \
  --num-nodes=1 \
  --zone=europe-west4-a \
  --project=$PROJECT_ID

# Wait for the GPU node to become Ready
kubectl get nodes -w
```

Once the GPU node is `Ready`, configure the NVIDIA device plugin to expose 16 virtual GPUs per physical L4:

```bash
./setup-gpu-timeslicing.sh
```

Override the number of slices:
```bash
REPLICAS=8 ./setup-gpu-timeslicing.sh
```

### Verify

```bash
kubectl get nodes -o json \
  | jq '.items[].status.allocatable | with_entries(select(.key | contains("nvidia")))'
# Expected: { "nvidia.com/gpu": "16" }
```

## Testing

### Verify GPU is available

```bash
kubectl apply -f gpu-test-pod.yaml
kubectl get pod gpu-test -w
kubectl logs gpu-test   # should show nvidia-smi output
kubectl delete pod gpu-test
```

### Verify time-slicing (Autopilot)

```bash
kubectl apply -f gpu-timeslice-test.yaml

# All 4 pods should land on the same node
kubectl get pods -l app=gpu-timeslice-test -o wide

# Node should advertise 16 GPU slots
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

kubectl delete -f gpu-timeslice-test.yaml
```

## GPU Workloads (Standard mode)

GPU nodes are tainted — add this toleration to your workload manifests:

```yaml
tolerations:
- key: nvidia.com/gpu
  operator: Equal
  value: present
  effect: NoSchedule
resources:
  limits:
    nvidia.com/gpu: "1"
```
