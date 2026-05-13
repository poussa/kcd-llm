# kcd-llm

GKE Autopilot cluster setup with NVIDIA GPU time-slicing for running LLM workloads, including a working [llm-d](https://github.com/llm-d/llm-d) deployment with prefix-cache-aware and load-aware routing.

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

The script also enables the required GCP APIs (`container`, `compute`, `networkservices`) and creates a proxy-only subnet needed for GKE Gateway (internal and external LBs).

### Configuration

| Variable             | Default                    | Description                          |
|----------------------|----------------------------|--------------------------------------|
| `PROJECT_ID`         | `kcd-llm`                  | GCP project ID                       |
| `CLUSTER_NAME`       | `kcd-llm-cluster`          | GKE cluster name                     |
| `REGION`             | `europe-west4`             | GCP region                           |
| `NETWORK`            | `default`                  | VPC network                          |
| `PROXY_SUBNET_NAME`  | `proxy-only-subnet`        | Proxy-only subnet name for GKE LB    |
| `PROXY_SUBNET_RANGE` | `10.0.0.0/23`              | CIDR range for proxy-only subnet     |

```bash
# Example: use Frankfurt region
REGION=europe-west3 ./create-gke-cluster.sh
```

### Delete Cluster

```bash
./create-gke-cluster.sh --delete
```

## GPU Time-Slicing

Time-slicing is configured per-pod via **node selectors**. GKE NAP automatically provisions a node advertising 8 virtual GPU slots, allowing up to 8 pods to share one physical GPU.

```yaml
spec:
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-tesla-t4   # or nvidia-l4
    cloud.google.com/gke-gpu-sharing-strategy: "time-sharing"
    cloud.google.com/gke-max-shared-clients-per-gpu: "8"
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

# Node should advertise 8 GPU slots
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

kubectl delete -f gpu-timeslice-test.yaml
```

## llm-d Deployment

This repo includes a local Kustomize overlay for deploying [llm-d optimized-baseline](https://github.com/llm-d/llm-d/tree/main/guides/optimized-baseline) on GKE Autopilot with GPU time-slicing.

### Prerequisites

```bash
export GAIE_VERSION=v1.5.0
export NAMESPACE=llm-d-optimized-baseline

kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=${GAIE_VERSION}"
kubectl create namespace ${NAMESPACE}
```

### 1. Deploy the llm-d Router

```bash
# Clone llm-d repo (needed for Helm values files)
git clone https://github.com/llm-d/llm-d.git && cd llm-d

helm install optimized-baseline \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
    -f guides/recipes/scheduler/base.values.yaml \
    -f guides/optimized-baseline/scheduler/optimized-baseline.values.yaml \
    --set provider.name=gke \
    --set experimentalHttpRoute.enabled=true \
    --set experimentalHttpRoute.inferenceGatewayName=llm-d-inference-gateway \
    -n ${NAMESPACE} --version ${GAIE_VERSION}

cd ..
```

### 2. Deploy the Model Server

The local overlay patches the upstream llm-d GKE config to add GKE Autopilot time-slicing node selectors, set `replicas: 1`, `nvidia.com/gpu: 1`, `--tensor-parallel-size=1`, and `--max-model-len=8192` for T4 memory constraints.

```bash
kubectl apply -n ${NAMESPACE} -k guides/optimized-baseline/modelserver/gpu/vllm/gke/
```

### 3. Deploy the Gateway

Choose internal (VPC-only) or external (public internet):

```bash
# Internal load balancer — private VPC IP only
kubectl apply -n ${NAMESPACE} -k guides/gateway/internal/

# External load balancer — public IP, accessible from anywhere
kubectl apply -n ${NAMESPACE} -k guides/gateway/external/
```

Wait for the gateway to get an IP:

```bash
kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} -w
```

### 4. Send a Test Request

```bash
export IP=$(kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} \
  -o jsonpath='{.status.addresses[0].value}')

curl -X POST http://${IP}/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-0.6B","prompt":"Hello, what are you?","max_tokens":50}' | jq
```

### Cleanup

```bash
helm uninstall optimized-baseline -n ${NAMESPACE}
kubectl delete -n ${NAMESPACE} -k guides/optimized-baseline/modelserver/gpu/vllm/gke/
kubectl delete -n ${NAMESPACE} -k guides/gateway/internal/   # or external/
kubectl delete namespace ${NAMESPACE}
```

