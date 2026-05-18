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
export PROJECT_ID=my-gcp-project   # set once
PROJECT_ID=$PROJECT_ID CLUSTER_NAME=kcd-llm-cluster ./create-gke-cluster.sh
```

The script enables required GCP APIs (`container`, `compute`, `networkservices`), creates a system node pool, a pre-provisioned GPU node pool with time-slicing, and a proxy-only subnet for GKE Gateway.

### Configuration

| Variable             | Default                      | Description                              |
|----------------------|------------------------------|------------------------------------------|
| `PROJECT_ID`         | `kcd-llm`                    | GCP project ID                           |
| `CLUSTER_NAME`       | `kcd-llm-cluster`            | GKE cluster name                         |
| `REGION`             | `europe-west4`               | GCP region                               |
| `NUM_GROUPS`         | `4`                          | GPU time-slice slots (1 per group)       |
| `NETWORK`            | `default`                    | VPC network                              |
| `PROXY_SUBNET_NAME`  | `proxy-only-subnet-{REGION}` | Proxy-only subnet name for GKE LB        |
| `PROXY_SUBNET_RANGE` | `10.0.0.0/23`                | CIDR range for proxy-only subnet         |

```bash
# T4 GPU (default)
PROJECT_ID=$PROJECT_ID CLUSTER_NAME=kcd-llm-cluster REGION=europe-west4 ./create-gke-cluster.sh

# L4 GPU
PROJECT_ID=$PROJECT_ID CLUSTER_NAME=kcd-llm-cluster REGION=europe-west4 ./create-gke-cluster.sh --gpu=l4

# Different region
PROJECT_ID=$PROJECT_ID CLUSTER_NAME=kcd-llm-cluster REGION=europe-west3 ./create-gke-cluster.sh
```

### Delete Cluster

```bash
PROJECT_ID=$PROJECT_ID CLUSTER_NAME=kcd-llm-cluster REGION=europe-west4 ./create-gke-cluster.sh --delete
```

## GPU Time-Slicing

Time-slicing is configured per-pod via **node selectors**. GKE NAP automatically provisions a node advertising 8 virtual GPU slots, allowing up to 8 pods to share one physical GPU.

```yaml
spec:
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-l4             # or nvidia-tesla-t4
    cloud.google.com/gke-gpu-sharing-strategy: "time-sharing"
    cloud.google.com/gke-max-shared-clients-per-gpu: "4"
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
export LLMD_VERSION=main

helm install optimized-baseline \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
    -f https://raw.githubusercontent.com/llm-d/llm-d/${LLMD_VERSION}/guides/recipes/scheduler/base.values.yaml \
    -f https://raw.githubusercontent.com/llm-d/llm-d/${LLMD_VERSION}/guides/optimized-baseline/scheduler/optimized-baseline.values.yaml \
    --set provider.name=gke \
    --set experimentalHttpRoute.enabled=true \
    --set experimentalHttpRoute.inferenceGatewayName=llm-d-inference-gateway \
    -n ${NAMESPACE} --version ${GAIE_VERSION}
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
kubectl get gateway -A -w
```

### 4. Send a Test Request

```bash
export IP=$(kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} \
  -o jsonpath='{.status.addresses[0].value}')

curl -X POST http://${IP}/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-0.6B","prompt":"Hello, what are you?","max_tokens":50}' | jq
```

## Workshop: Multi-Group Deployment

### Deploy All Groups at Once

The `scripts/deploy-workshop.sh` script deploys llm-d to multiple namespaces (`group-1` … `group-N`) in one shot.

```bash
# Deploy 8 groups (default) with external gateways
./scripts/deploy-workshop.sh

# Custom number of groups or gateway type
NUM_GROUPS=4 GATEWAY_TYPE=internal ./scripts/deploy-workshop.sh
```

| Variable       | Default    | Description                                |
|----------------|------------|--------------------------------------------|
| `NUM_GROUPS`   | `4`        | Number of namespaces to deploy             |
| `GATEWAY_TYPE` | `external` | `external` or `internal`                   |
| `GAIE_VERSION` | `v1.5.0`   | Gateway API Inference Extension version    |
| `LLMD_VERSION` | `main`     | llm-d branch/tag for Helm values           |

### Load Test & KPI Measurement

The `scripts/load-test.py` script sends concurrent chat requests to every group simultaneously and reports GPU time-slicing performance KPIs.

```bash
pip install aiohttp

# Auto-discover IPs from kubectl and test all 8 groups concurrently
python3 scripts/load-test.py

# Custom load
python3 scripts/load-test.py --requests 40 --concurrency 8

# Specific groups only
python3 scripts/load-test.py --groups group-1 group-2 group-3

# Manual IP override (no kubectl needed)
python3 scripts/load-test.py --ips group-1=34.90.1.2 group-2=34.90.1.3
```

**Metrics reported per group:**

| Metric    | Description                                   |
|-----------|-----------------------------------------------|
| TTFT p50/p95 | Time To First Token — streaming latency    |
| LAT p50/p95  | End-to-end request latency                 |
| TOK/S     | Generation throughput (tokens/sec)            |
| ERR       | Error count                                   |

### Cleanup

```bash
# Single group
helm uninstall optimized-baseline -n ${NAMESPACE}
kubectl delete -n ${NAMESPACE} -k guides/optimized-baseline/modelserver/gpu/vllm/gke/
kubectl delete -n ${NAMESPACE} -k guides/gateway/external/   # or internal/
kubectl delete namespace ${NAMESPACE}

# All workshop groups
for i in $(seq 1 4); do
  NS="group-${i}"
  helm uninstall optimized-baseline -n ${NS} --ignore-not-found 2>/dev/null || true
  kubectl delete namespace ${NS} --ignore-not-found
done
```

