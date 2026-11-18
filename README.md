# NVIDIA GPU Operator on Amazon EKS: Hands-on Lab

Deploy the NVIDIA GPU Operator on Amazon EKS with Helm, run a CUDA workload, share one GPU across pods with time-slicing, and read GPU metrics from DCGM. Everything runs from AWS CloudShell.

## What this covers
- **Cluster:** EKS 1.30 with a managed node group of one `g4dn.xlarge` (NVIDIA Tesla T4, 16 GB), using the `AL2_x86_64_GPU` AMI.
- **GPU Operator (Helm):** device plugin, container toolkit, GPU feature discovery, DCGM exporter, validator.
- **Validation:** a CUDA `vectoradd` pod scheduled onto the GPU (`Test PASSED`).
- **Time-slicing:** a ConfigMap that turns 1 physical GPU into 4 schedulable `nvidia.com/gpu`.
- **Observability:** DCGM exporter metrics such as `DCGM_FI_DEV_GPU_TEMP` and `DCGM_FI_DEV_POWER_USAGE`.
- **Cleanup:** delete the node group, the cluster and the CloudFormation stacks.

## Files
| File | Purpose |
|---|---|
| [LAB_GUIDE.md](LAB_GUIDE.md) | Step-by-step guide, architecture, troubleshooting and lessons learned |
| [commands.sh](commands.sh) | All commands in order |
| [config/cluster.yaml](config/cluster.yaml) | Minimal eksctl cluster config |
| [config/cluster-final.yaml](config/cluster-final.yaml) | Config for an existing VPC and IAM roles, node group created with the AWS CLI |
| [config/time-slicing-config.yaml](config/time-slicing-config.yaml) | GPU time-slicing ConfigMap (4 replicas) |

## Problems I hit and how I fixed them
- **Node group stuck in `CREATE_IN_PROGRESS`:** the account's G-instance vCPU quota (`L-DB2E81BA`) was 0. I requested a quota increase.
- **Device plugin in `CrashLoopBackOff` after enabling time-slicing:** fixed with `kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n gpu-operator`.
- **eksctl node group creation blocked by an organization policy (SCP):** created the node group directly with `aws eks create-nodegroup`.
- **CloudShell quirks:** tools disappear on reconnect and pasted YAML loses its indentation. I wrote files with `echo` and used JSON for the ConfigMap.

## Cost
About $0.50 to $1.00 if you delete everything straight after (g4dn.xlarge is about $0.526/hour and the EKS control plane $0.10/hour). Left running, it costs about $15/day.

## Prerequisites
An AWS account with EKS and EC2 permissions, G-instance vCPU quota of at least 4, plus `eksctl`, `kubectl`, `helm` and the AWS CLI (see the guide for CloudShell installation).
