# kcd-llm

GKE Autopilot cluster setup with NVIDIA GPU time-slicing for running LLM workloads.

GKE Autopilot manages all nodes automatically — finds GPU capacity across zones in the region, installs drivers, and scales to zero when idle. No node pool management needed.

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

Before creating the cluster, verify you have GPU quota in your target region:

```bash
gcloud compute regions describe europe-west4 \
  --project=$PROJECT_ID \
  --format="json" \
  | jq '.quotas[] | select(.metric | contains("L4"))'
```

You need `NVIDIA_L4_GPUS` limit > 0. If not, request a quota increase at:
**https://console.cloud.google.com/iam-admin/quotas** → filter "NVIDIA L4".

> **Note:** L4 GPUs are available in `europe-west1/3/4/6`, `us-central1`, `us-east1/4`, `us-west1/4`, and others — but **not** in `europe-north1` (Finland). Check availability with:
> ```bash
> gcloud compute machine-types list --filter="name=g2-standard-4" --format="value(zone)" | sed 's/-[abcdf]$//' | sort -u
> ```

## Create Cluster

```bash
./create-gke-cluster.sh
```

### Configuration

| Variable       | Default           | Description        |
|----------------|-------------------|--------------------|
| `PROJECT_ID`   | `kcd-llm`         | GCP project ID     |
| `CLUSTER_NAME` | `kcd-llm-cluster` | GKE cluster name   |
| `REGION`       | `europe-west4`    | GCP region         |

```bash
# Example: use Frankfurt region
REGION=europe-west3 ./create-gke-cluster.sh
```

### Delete Cluster

```bash
./create-gke-cluster.sh --delete
```

## GPU Time-Slicing

Time-slicing is configured per-pod via **node selectors**. GKE NAP automatically provisions a node advertising 16 virtual GPU slots, allowing up to 16 pods to share one physical GPU.

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

See [`gpu-timeslice-test.yaml`](gpu-timeslice-test.yaml) for a working 4-pod example.

## Testing

### Verify GPU is available

```bash
kubectl apply -f gpu-test-pod.yaml
kubectl get pod gpu-test -w
kubectl logs gpu-test   # should show nvidia-smi output with GPU info
kubectl delete pod gpu-test
```

### Verify time-slicing

```bash
kubectl apply -f gpu-timeslice-test.yaml

# All 4 pods should land on the same node
kubectl get pods -l app=gpu-timeslice-test -o wide

# Node should advertise 16 GPU slots
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

kubectl delete -f gpu-timeslice-test.yaml
```

