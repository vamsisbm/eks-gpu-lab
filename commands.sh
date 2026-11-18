#!/bin/bash
# GPU EKS Lab — All Commands (Quick Reference)
# Region: us-east-1 (change if your quota is in another region)
# Time: ~30-40 minutes | Cost: ~$0.50-$1.00

# ============================================================
# PRE-REQUISITES (do this the day before!)
# ============================================================

# Check GPU quota (need at least 4 vCPUs)
aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-DB2E81BA \
  --region us-east-1 --query "Quota.Value" --output text

# If 0, request increase:
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-DB2E81BA \
  --desired-value 8 --region us-east-1

# Check g4dn.xlarge availability
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=g4dn.xlarge \
  --region us-east-1 \
  --query "InstanceTypeOfferings[].Location" --output text

# ============================================================
# TOOL INSTALLATION (CloudShell)
# ============================================================

# eksctl
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz"
tar xz -f eksctl_Linux_amd64.tar.gz && rm eksctl_Linux_amd64.tar.gz
chmod +x eksctl && export PATH=$HOME:$PATH
eksctl version

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# ============================================================
# STEP 1 — VERIFY TOOLS & AUTH
# ============================================================
eksctl version
kubectl version --client
helm version
aws sts get-caller-identity

# ============================================================
# STEP 2 — CREATE CLUSTER CONFIG
# ============================================================
# Using echo to avoid CloudShell heredoc indentation issues
echo 'apiVersion: eksctl.io/v1alpha5' > cluster.yaml
echo 'kind: ClusterConfig' >> cluster.yaml
echo 'metadata:' >> cluster.yaml
echo '  name: gpu-lab' >> cluster.yaml
echo '  region: us-east-1' >> cluster.yaml
echo '  version: "1.30"' >> cluster.yaml
echo 'managedNodeGroups:' >> cluster.yaml
echo '  - name: gpu-workers' >> cluster.yaml
echo '    instanceType: g4dn.xlarge' >> cluster.yaml
echo '    minSize: 1' >> cluster.yaml
echo '    desiredCapacity: 1' >> cluster.yaml
echo '    maxSize: 1' >> cluster.yaml
echo '    volumeSize: 100' >> cluster.yaml
echo '    amiFamily: AmazonLinux2' >> cluster.yaml

cat cluster.yaml

# ============================================================
# STEP 3 — CREATE EKS CLUSTER (~15-20 min)
# ============================================================
eksctl create cluster -f cluster.yaml

# If CloudShell disconnects, reconnect and run:
# export PATH=$HOME:$PATH
# aws eks update-kubeconfig --name gpu-lab --region us-east-1
# kubectl get nodes

# Verify node is Ready
kubectl get nodes

# ============================================================
# STEP 4 — INSTALL NVIDIA GPU OPERATOR (~2-3 min)
# ============================================================
helm repo add nvidia https://nvidia.github.io/gpu-operator
helm repo update
helm install gpu-operator nvidia/gpu-operator \
  -n gpu-operator --create-namespace --wait

# PROOF #1 — Verify all pods running
kubectl get pods -n gpu-operator

# ============================================================
# STEP 5 — VERIFY GPU DEVICE PLUGIN
# ============================================================
# PROOF #2 — Check GPU registered on node
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
# Expected: 1

# ============================================================
# STEP 6 — RUN CUDA TEST WORKLOAD
# ============================================================
kubectl run cuda-test --restart=Never \
  --image=nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04 \
  --overrides='{"spec":{"containers":[{"name":"cuda-test","image":"nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04","resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}'

# Wait 30 seconds for image pull, then:
# PROOF #3 — Check CUDA output
kubectl logs cuda-test
# Expected: "Test PASSED"

kubectl delete pod cuda-test

# ============================================================
# STEP 7 — CONFIGURE GPU TIME-SLICING
# ============================================================
# Create ConfigMap (using JSON to avoid YAML-in-YAML issues)
echo '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"time-slicing-config","namespace":"gpu-operator"},"data":{"any":"version: v1\nsharing:\n  timeSlicing:\n    resources:\n    - name: nvidia.com/gpu\n      replicas: 4\n"}}' | kubectl apply -f -

# Apply to GPU operator
helm upgrade gpu-operator nvidia/gpu-operator -n gpu-operator \
  --set devicePlugin.config.name=time-slicing-config \
  --set devicePlugin.config.default=any \
  --reuse-values

# Restart device plugin
kubectl rollout restart -n gpu-operator daemonset/nvidia-device-plugin-daemonset

# Wait and verify
sleep 40

# PROOF #4 — Verify 4 GPUs (time-sliced)
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
# Expected: 4

# ============================================================
# STEP 8 — DCGM GPU METRICS
# ============================================================
kubectl port-forward -n gpu-operator svc/nvidia-dcgm-exporter 9400:9400 &
sleep 3

# PROOF #5 — GPU metrics
curl -s localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL
curl -s localhost:9400/metrics | grep -E "DCGM_FI_DEV_GPU_TEMP|DCGM_FI_DEV_POWER_USAGE" | grep -v "^#"

kill %1

# ============================================================
# STEP 9 — CLEANUP (DO NOT SKIP!)
# ============================================================
helm uninstall gpu-operator -n gpu-operator
eksctl delete cluster --name gpu-lab --region us-east-1

# Verify cleanup
aws eks list-clusters --region us-east-1
aws ec2 describe-instances \
  --filters "Name=instance-type,Values=g4dn.xlarge" "Name=instance-state-name,Values=running" \
  --region us-east-1 \
  --query "Reservations[].Instances[].[InstanceId]" --output text
