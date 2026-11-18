# GPU on Amazon EKS — Hands-On Lab Guide

## What You'll Build

Deploy NVIDIA GPU Operator on EKS, run a real CUDA workload, configure GPU time-slicing for multi-tenancy, and verify DCGM GPU metrics — all from AWS CloudShell.

**One-liner for resume/blog:**
> Deployed NVIDIA GPU Operator on EKS via Helm, ran CUDA workloads, configured GPU time-slicing for multi-tenant GPU sharing, and validated DCGM observability metrics.

---

## Cost & Time

| Item | Value |
|------|-------|
| **Total time** | ~30-40 minutes (if no issues) |
| **Total cost** | ~$0.50-$1.00 (delete immediately after) |
| **Instance** | g4dn.xlarge — $0.526/hr |
| **EKS control plane** | $0.10/hr |
| ⚠️ **If you forget to delete** | ~$15/day |

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│              AWS Account                         │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │          VPC (auto-created by eksctl)       │  │
│  │                                             │  │
│  │  ┌───────────────────────────────────────┐  │  │
│  │  │     EKS Cluster: gpu-lab (v1.30)      │  │  │
│  │  │                                       │  │  │
│  │  │  ┌─────────────────────────────────┐  │  │  │
│  │  │  │  Node Group: gpu-workers        │  │  │  │
│  │  │  │  Instance: g4dn.xlarge          │  │  │  │
│  │  │  │  GPU: NVIDIA Tesla T4 (16GB)    │  │  │  │
│  │  │  │  AMI: AL2_x86_64_GPU           │  │  │  │
│  │  │  │  Driver: 570.195.03            │  │  │  │
│  │  │  └─────────────────────────────────┘  │  │  │
│  │  │                                       │  │  │
│  │  │  ┌─────────────────────────────────┐  │  │  │
│  │  │  │  NVIDIA GPU Operator (Helm)     │  │  │  │
│  │  │  │  ├── Device Plugin              │  │  │  │
│  │  │  │  ├── DCGM Exporter             │  │  │  │
│  │  │  │  ├── Container Toolkit          │  │  │  │
│  │  │  │  ├── GPU Feature Discovery      │  │  │  │
│  │  │  │  └── Operator Validator         │  │  │  │
│  │  │  └─────────────────────────────────┘  │  │  │
│  │  └───────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

---

## Prerequisites — READ BEFORE STARTING

### 1. GPU Quota (CRITICAL — check this FIRST)

New AWS accounts have **0 vCPU quota** for GPU instances by default. You MUST request this in advance.

**Check your current quota:**
```bash
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-DB2E81BA \
  --region us-east-1 \
  --query "Quota.Value" --output text
```

You need **at least 4** (g4dn.xlarge = 4 vCPUs). If it shows `0`:

**Request an increase:**
```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-DB2E81BA \
  --desired-value 8 \
  --region us-east-1
```

Or go to: **Service Quotas Console → EC2 → "All G and VT instances"** → Request increase to 8.

> ⚠️ **This can take minutes to hours for approval.** Do this the day before your lab. Request a small value (4-8) for faster approval.

**Check multiple regions** — pick whichever has quota:
```bash
for region in us-east-1 us-east-2 us-west-2; do
  echo -n "$region: "
  aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --region $region --query "Quota.Value" --output text
done
```

### 2. GPU Instance Availability

Verify g4dn.xlarge is available in your chosen region:
```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=g4dn.xlarge \
  --region us-east-1 \
  --query "InstanceTypeOfferings[].Location" --output text
```

### 3. CloudShell Limitations (Know Before You Start)

| Issue | Impact | Workaround |
|-------|--------|------------|
| **Tools reset on disconnect** | eksctl, helm disappear after idle timeout | Re-install (commands below) |
| **20-min idle timeout** | Session disconnects | Keep tab active or reconnect |
| **Heredoc paste issues** | YAML files get wrong indentation | Use `echo` line-by-line or `printf` |
| **CloudFormation survives disconnect** | Cluster keeps creating even if shell dies | Just reconnect and check status |

### 4. Tool Installation (CloudShell)

CloudShell has `kubectl` and `aws` pre-installed but NOT `eksctl` or `helm`. Install them:

**eksctl:**
```bash
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz"
tar xz -f eksctl_Linux_amd64.tar.gz
rm eksctl_Linux_amd64.tar.gz
chmod +x eksctl
export PATH=$HOME:$PATH
eksctl version
```

**helm:**
```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

> 💡 **If CloudShell reconnects mid-lab**, run `export PATH=$HOME:$PATH` to get eksctl back. Helm installs to `/usr/local/bin` which persists.

---

## Step 1 — Verify Tools & Identity

```bash
eksctl version
kubectl version --client
helm version
aws sts get-caller-identity
```

Confirm you see your account ID and a role with sufficient permissions (AdministratorAccess or EKS-related policies).

---

## Step 2 — Create Cluster Configuration

**⚠️ CloudShell heredoc issue:** Pasting multi-line YAML often breaks indentation. Use this approach instead:

```bash
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
```

**Verify the file looks correct:**
```bash
cat cluster.yaml
```

Expected output:
```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: gpu-lab
  region: us-east-1
  version: "1.30"
managedNodeGroups:
  - name: gpu-workers
    instanceType: g4dn.xlarge
    minSize: 1
    desiredCapacity: 1
    maxSize: 1
    volumeSize: 100
    amiFamily: AmazonLinux2
```

**Why this config is simple:**
- No custom VPC — eksctl creates one automatically
- No existing IAM roles needed — eksctl creates them
- No mandatory tags — only needed if your org has SCPs enforcing them
- `AmazonLinux2` with GPU instance = EKS picks `AL2_x86_64_GPU` AMI automatically

> 💡 **If your organization has SCPs** requiring tags, add them under `metadata.tags`. See the Troubleshooting section.

---

## Step 3 — Create the EKS Cluster

```bash
eksctl create cluster -f cluster.yaml
```

**Expected time:** ~15-20 minutes (control plane ~10 min + node group ~5 min)

**If CloudShell disconnects:** Don't panic. The cluster creation continues via CloudFormation. Reconnect and run:
```bash
export PATH=$HOME:$PATH
aws eks update-kubeconfig --name gpu-lab --region us-east-1
kubectl get nodes
```

**Monitor progress (optional):**
```bash
aws cloudformation describe-stacks \
  --stack-name eksctl-gpu-lab-cluster \
  --region us-east-1 \
  --query "Stacks[0].StackStatus" --output text
```

**When complete, verify the node is Ready:**
```bash
kubectl get nodes
```

Expected:
```
NAME                            STATUS   ROLES    AGE   VERSION
ip-192-168-xx-xx.ec2.internal   Ready    <none>   2m    v1.30.x-eks-xxxxx
```

> 📸 **PROOF: Screenshot kubectl get nodes showing Ready status**

---

## Step 4 — Install NVIDIA GPU Operator

```bash
helm repo add nvidia https://nvidia.github.io/gpu-operator
helm repo update
helm install gpu-operator nvidia/gpu-operator \
  -n gpu-operator --create-namespace --wait
```

**Expected time:** ~2-3 minutes

**Verify all pods are running:**
```bash
kubectl get pods -n gpu-operator
```

All pods should show `Running` or `Completed`:
```
gpu-feature-discovery-xxxxx                    1/1     Running     0     2m
gpu-operator-xxxxx                             1/1     Running     0     2m
nvidia-container-toolkit-daemonset-xxxxx       1/1     Running     0     2m
nvidia-cuda-validator-xxxxx                    0/1     Completed   0     2m
nvidia-dcgm-exporter-xxxxx                     1/1     Running     0     2m
nvidia-device-plugin-daemonset-xxxxx           1/1     Running     0     2m
nvidia-operator-validator-xxxxx                1/1     Running     0     2m
```

> 📸 **PROOF #1: Screenshot of kubectl get pods -n gpu-operator showing all Running/Completed**

---

## Step 5 — Verify GPU Device Plugin

```bash
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
```

Expected output: `1`

This confirms:
- NVIDIA Tesla T4 GPU is detected
- Kubernetes scheduler can assign GPU workloads
- Device plugin registered the GPU as an allocatable resource

> 📸 **PROOF #2: Screenshot showing nvidia.com/gpu: 1**

---

## Step 6 — Run a CUDA Test Workload

```bash
kubectl run cuda-test --restart=Never \
  --image=nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04 \
  --overrides='{"spec":{"containers":[{"name":"cuda-test","image":"nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04","resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}'
```

Wait 30 seconds (image pull), then check logs:
```bash
kubectl logs cuda-test
```

Expected output:
```
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

**What this proves:**
- CUDA runtime works inside containers
- GPU memory allocation works (host → device → host)
- CUDA kernel execution works (196 blocks × 256 threads)
- Kubernetes scheduler correctly assigned the GPU to the pod

Clean up:
```bash
kubectl delete pod cuda-test
```

> 📸 **PROOF #3: Screenshot of "Test PASSED" output**

---

## Step 7 — Configure GPU Time-Slicing

Time-slicing lets multiple pods share one physical GPU by time-multiplexing access.

**Create the ConfigMap** (using JSON to avoid YAML indentation issues in CloudShell):
```bash
echo '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"time-slicing-config","namespace":"gpu-operator"},"data":{"any":"version: v1\nsharing:\n  timeSlicing:\n    resources:\n    - name: nvidia.com/gpu\n      replicas: 4\n"}}' | kubectl apply -f -
```

**Apply to GPU Operator:**
```bash
helm upgrade gpu-operator nvidia/gpu-operator -n gpu-operator \
  --set devicePlugin.config.name=time-slicing-config \
  --set devicePlugin.config.default=any \
  --reuse-values
```

**Restart the device plugin:**
```bash
kubectl rollout restart -n gpu-operator daemonset/nvidia-device-plugin-daemonset
```

**Wait and verify** (~40 seconds for plugin to restart):
```bash
sleep 40
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
```

Expected output: `4`

**What this proves:**
- 1 physical Tesla T4 now exposed as 4 virtual GPU slots
- Up to 4 pods can simultaneously use the GPU
- Time-slicing provides fair scheduling of GPU compute
- This is multi-tenancy for T4 GPUs (MIG not supported on T4)

> 📸 **PROOF #4: Screenshot showing nvidia.com/gpu: 4**

---

## Step 8 — DCGM GPU Metrics

```bash
kubectl port-forward -n gpu-operator svc/nvidia-dcgm-exporter 9400:9400 &
sleep 3
curl -s localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL
```

Expected output:
```
# HELP DCGM_FI_DEV_GPU_UTIL GPU utilization (in %).
# TYPE DCGM_FI_DEV_GPU_UTIL gauge
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-xxx",device="nvidia0",modelName="Tesla T4",...} 0
```

**Additional metrics:**
```bash
curl -s localhost:9400/metrics | grep -E "DCGM_FI_DEV_GPU_TEMP|DCGM_FI_DEV_POWER_USAGE" | grep -v "^#"
```

Expected:
```
DCGM_FI_DEV_GPU_TEMP{...modelName="Tesla T4"...} 35       (GPU Temperature: 35°C)
DCGM_FI_DEV_POWER_USAGE{...modelName="Tesla T4"...} 14.5   (Power Draw: ~15W idle)
```

**What this proves:**
- DCGM exporter collects real-time GPU telemetry
- Metrics in Prometheus format — ready for Grafana dashboards
- GPU utilization, temperature, and power metrics available
- Same observability pipeline used in production GPU clusters

Stop port-forward:
```bash
kill %1
```

> 📸 **PROOF #5: Screenshot of DCGM metrics output**

---

## Step 9 — CLEANUP (DO NOT SKIP!)

⚠️ **g4dn.xlarge costs ~$12.60/day. Delete immediately after screenshots.**

```bash
helm uninstall gpu-operator -n gpu-operator
eksctl delete cluster --name gpu-lab --region us-east-1
```

**Verify everything is gone** (~5-10 min for full deletion):
```bash
aws eks list-clusters --region us-east-1
aws ec2 describe-instances \
  --filters "Name=instance-type,Values=g4dn.xlarge" "Name=instance-state-name,Values=running" \
  --region us-east-1 \
  --query "Reservations[].Instances[].[InstanceId]" --output text
```

Both should return empty. If the cluster is still deleting, wait and check again.

---

## Summary of Proofs

| # | Proof | Evidence |
|---|-------|----------|
| 1 | GPU Operator deployed | All pods Running/Completed |
| 2 | GPU registered | `nvidia.com/gpu: 1` |
| 3 | CUDA works | vectoradd "Test PASSED" |
| 4 | Time-slicing active | `nvidia.com/gpu: 4` |
| 5 | GPU observability | DCGM metrics (util, temp, power) |

---

## Key Technical Details

| Property | Value |
|----------|-------|
| EKS Version | 1.30 |
| Node AMI | AL2_x86_64_GPU (Amazon Linux 2) |
| GPU | NVIDIA Tesla T4 (16GB GDDR6) |
| NVIDIA Driver | 570.195.03 |
| CUDA Runtime | 12.x |
| GPU Operator | Latest (via Helm) |
| Time-Slicing Replicas | 4 |
| Instance Cost | ~$0.53/hr |

---

## Troubleshooting

### Issue: GPU Quota is 0 (nodegroup stuck in CREATING)

**Symptom:** Nodegroup stays in `CREATE_IN_PROGRESS` for 20+ minutes, no EC2 instance launches.

**Cause:** Your account has 0 vCPU quota for G-family instances in that region.

**How to check:**
```bash
aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-DB2E81BA \
  --region us-east-1 --query "Quota.Value" --output text
```

**Fix:** Request a quota increase (need at least 4 vCPUs for g4dn.xlarge). Do this the day before.

**Alternative:** Try a different region that already has quota.

---

### Issue: CloudShell Disconnects During Cluster Creation

**Symptom:** Terminal closes, you lose your session.

**Impact:** None — CloudFormation continues server-side.

**Fix:** Reconnect to CloudShell, then:
```bash
export PATH=$HOME:$PATH
aws eks update-kubeconfig --name gpu-lab --region us-east-1
kubectl get nodes
```

---

### Issue: eksctl/helm Not Found After Reconnect

**Symptom:** `-bash: eksctl: command not found`

**Cause:** CloudShell resets PATH and temp storage on disconnect.

**Fix:**
```bash
# eksctl (if installed to $HOME)
export PATH=$HOME:$PATH
eksctl version

# helm (re-install if needed)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

### Issue: YAML Indentation Errors from CloudShell Paste

**Symptom:** `error converting YAML to JSON: yaml: line X: did not find expected key`

**Cause:** CloudShell adds/removes spaces when pasting multi-line content. Heredocs (`cat << EOF`) are especially affected.

**Fix:** Use `echo` line-by-line (as shown in Step 2) or `printf` with explicit `\n`.

**Verify fix:** `cat -A cluster.yaml` — check all lines have correct spacing.

---

### Issue: Organization SCP Blocking Cluster Creation

**Symptom:** `explicit deny in a service control policy`

**Cause:** Your organization requires mandatory tags on all resources.

**Fix:** Add required tags to cluster config:
```yaml
metadata:
  name: gpu-lab
  region: us-east-1
  tags:
    application: YOUR_APP_TAG
    creator: your-username
    owner: your-username
```

Find required tags from existing resources:
```bash
aws ec2 describe-tags --filters "Name=resource-id,Values=<existing-instance-id>"
```

---

### Issue: Time-Slicing ConfigMap Indentation Wrong

**Symptom:** `nvidia-device-plugin-daemonset` in `CrashLoopBackOff` after applying time-slicing.

**Cause:** The YAML inside the ConfigMap has wrong indentation (common with CloudShell paste).

**Fix:** Use JSON format to create the ConfigMap (avoids YAML nesting issues):
```bash
echo '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"time-slicing-config","namespace":"gpu-operator"},"data":{"any":"version: v1\nsharing:\n  timeSlicing:\n    resources:\n    - name: nvidia.com/gpu\n      replicas: 4\n"}}' | kubectl apply -f -
```

**Verify the content is correct:**
```bash
kubectl get configmap time-slicing-config -n gpu-operator -o yaml
```

The `data.any` field should look like:
```
version: v1
sharing:
  timeSlicing:
    resources:
    - name: nvidia.com/gpu
      replicas: 4
```

(`sharing` must be at same level as `version`, NOT indented under it)

---

### Issue: Custom AMI Node Not Joining Cluster

**Symptom:** Instance runs but `kubectl get nodes` shows nothing.

**Cause:** If you specify an explicit AMI ID, EKS sets `amiType: CUSTOM` and does NOT inject bootstrap userdata.

**Fix:** Don't use custom AMIs. Let EKS pick the AMI:
- Use `amiFamily: AmazonLinux2` in eksctl config
- Or `--ami-type AL2_x86_64_GPU` in direct API calls

---

### Issue: Nodegroup Stuck in DELETING (30+ minutes)

**Symptom:** Nodegroup stays in `DELETING` forever.

**Cause:** If the node never joined the cluster, EKS can't drain it. ASG lifecycle hooks add 30-min waits.

**Fix:**
```bash
# Find the ASG name
aws eks describe-nodegroup --cluster-name gpu-lab --nodegroup-name gpu-workers \
  --region us-east-1 --query "nodegroup.resources.autoScalingGroups[0].name" --output text

# Force scale to 0
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "<ASG_NAME>" \
  --min-size 0 --desired-capacity 0

# After instance terminates, force-delete ASG
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name "<ASG_NAME>" --force-delete
```

---

## Lessons Learned

1. **Check GPU quota FIRST** — this is the #1 blocker. New accounts have 0. Request increase the day before.
2. **Pick region based on quota** — don't assume us-east-1. Check where you actually have capacity.
3. **CloudShell is fragile** — tools disappear on reconnect, YAML paste breaks indentation. Use `echo` for files, `export PATH=$HOME:$PATH` to recover.
4. **Keep it simple** — let eksctl create VPC/roles automatically. Only use custom VPC/roles if your org requires it.
5. **Don't use custom AMIs** — `AL2_x86_64_GPU` handles GPU drivers and cluster bootstrap automatically.
6. **Use JSON for ConfigMaps** — avoids YAML-in-YAML indentation nightmares in CloudShell.
7. **Delete immediately** — GPU instances cost real money. Set a timer if needed.

---
