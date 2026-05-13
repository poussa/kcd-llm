#!/usr/bin/env bash
set -euo pipefail

# Configures NVIDIA GPU time-slicing (16 slices per L4 GPU) on GKE.
# GKE installs the NVIDIA device plugin automatically; this script
# just applies the time-slicing ConfigMap and restarts the plugin.

REPLICAS="${REPLICAS:-16}"
NAMESPACE="kube-system"
CONFIGMAP_NAME="time-slicing-config"
DAEMONSET_NAME="nvidia-gpu-device-plugin"

echo "==> Applying GPU time-slicing ConfigMap (${REPLICAS} replicas)"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIGMAP_NAME}
  namespace: ${NAMESPACE}
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        resources:
        - name: nvidia.com/gpu
          replicas: ${REPLICAS}
EOF

echo "==> Patching device plugin DaemonSet to use time-slicing config"
kubectl patch daemonset "${DAEMONSET_NAME}" \
  -n "${NAMESPACE}" \
  --type=json \
  -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/env/-",
      "value": {
        "name": "CONFIG_FILE",
        "value": "/etc/nvidia/config"
      }
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/volumeMounts/-",
      "value": {
        "name": "time-slicing-config",
        "mountPath": "/etc/nvidia"
      }
    },
    {
      "op": "add",
      "path": "/spec/template/spec/volumes/-",
      "value": {
        "name": "time-slicing-config",
        "configMap": {
          "name": "time-slicing-config",
          "items": [{"key": "any", "path": "config"}]
        }
      }
    }
  ]'

echo "==> Waiting for DaemonSet rollout"
kubectl rollout status daemonset/"${DAEMONSET_NAME}" -n "${NAMESPACE}" --timeout=120s

echo ""
echo "✅ Time-slicing configured: each L4 GPU exposes ${REPLICAS} virtual GPUs"
echo ""
echo "Verify with:"
echo "  kubectl get nodes -o json | jq '.items[].status.allocatable | with_entries(select(.key | contains(\"nvidia\")))'"
