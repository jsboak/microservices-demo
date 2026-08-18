#!/usr/bin/env bash
#
# Tears down everything deployed by eks-online-boutique-cloudformation.yaml.
#
# Why this isn't just `aws cloudformation delete-stack`: once Online Boutique
# is running, its `frontend-external` Service (type: LoadBalancer) causes the
# AWS cloud-controller to provision a real ELB/NLB + security group + ENIs
# that CloudFormation never created and doesn't track. If those are still
# alive when the stack tries to delete the VPC/subnets, the delete hangs in
# DELETE_FAILED because the ENI is still attached. So: kill the k8s-created
# LoadBalancer(s) first, confirm AWS actually removed them, then delete the
# stack.
#
# Usage:
#   ./teardown-eks-online-boutique.sh <stack-name> [region]
#
# Options:
#   --yes           skip the confirmation prompt before deleting the stack
#   --delete-pvcs   also delete any PersistentVolumeClaims found in the
#                   cluster (deletes the backing EBS volumes and their data;
#                   off by default since Online Boutique doesn't use PVCs
#                   out of the box — this only matters if you added something
#                   that does)
#
# Example:
#   ./teardown-eks-online-boutique.sh online-boutique-poc us-east-1

set -euo pipefail

AUTO_YES=false
DELETE_PVCS=false
POSITIONAL=()

for arg in "$@"; do
  case "$arg" in
    --yes) AUTO_YES=true ;;
    --delete-pvcs) DELETE_PVCS=true ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
set -- "${POSITIONAL[@]}"

STACK_NAME="${1:?Usage: $0 <stack-name> [region] [--yes] [--delete-pvcs]}"
REGION="${2:-us-east-1}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

command -v aws >/dev/null || die "aws CLI not found"
command -v kubectl >/dev/null || die "kubectl not found"

log "Reading stack outputs from '$STACK_NAME' ($REGION)"
if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
  die "Stack '$STACK_NAME' not found in $REGION. If it's already gone, there's nothing to tear down."
fi

CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text)
VPC_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text)

[ -n "$CLUSTER_NAME" ] && [ "$CLUSTER_NAME" != "None" ] || die "Could not read ClusterName output from stack. Was the template updated to include it?"
[ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] || die "Could not read VpcId output from stack. Was the template updated to include it?"

log "Cluster: $CLUSTER_NAME  |  VPC: $VPC_ID"

# ---------------------------------------------------------------------------
# Step 1: point kubectl at the cluster (skip cleanly if the cluster is
# already gone, e.g. it was deleted out-of-band)
# ---------------------------------------------------------------------------
CLUSTER_REACHABLE=false
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  log "Configuring kubectl for $CLUSTER_NAME"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null
  if kubectl get nodes >/dev/null 2>&1; then
    CLUSTER_REACHABLE=true
  else
    warn "kubectl can't reach the cluster (network/auth issue) — skipping Kubernetes cleanup steps."
    warn "If Online Boutique's frontend-external LoadBalancer Service is still live, its ELB/NLB"
    warn "will block VPC deletion below. Check the EC2 console for orphaned load balancers if the"
    warn "stack delete gets stuck."
  fi
else
  log "EKS cluster '$CLUSTER_NAME' not found (already deleted?) — skipping Kubernetes cleanup steps."
fi

# ---------------------------------------------------------------------------
# Step 2: delete any LoadBalancer-type Services and wait for AWS to actually
# remove the underlying ELB/NLB
# ---------------------------------------------------------------------------
if [ "$CLUSTER_REACHABLE" = true ]; then
  log "Looking for LoadBalancer-type Services (these provisioned real ELBs/NLBs outside CloudFormation)"
  LB_SVCS=$(kubectl get svc -A -o json \
    | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"')

  if [ -z "$LB_SVCS" ]; then
    echo "None found."
  else
    echo "$LB_SVCS" | while read -r ns name; do
      log "Deleting Service $ns/$name (this tells AWS to delete its ELB/NLB)"
      kubectl delete svc "$name" -n "$ns" --wait=true
    done

    log "Confirming the ELB(s)/NLB(s) in VPC $VPC_ID are actually gone (this can take 1-2 minutes)"
    for i in $(seq 1 30); do
      CLASSIC=$(aws elb describe-load-balancers --region "$REGION" \
        --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text)
      V2=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text)
      if [ -z "$CLASSIC" ] && [ -z "$V2" ]; then
        echo "Confirmed: no load balancers remain in $VPC_ID."
        break
      fi
      echo "  still present, waiting... ($i/30)"
      sleep 10
      if [ "$i" -eq 30 ]; then
        warn "Load balancer(s) still present after 5 minutes. Check the EC2 console before proceeding —"
        warn "deleting the stack now will likely hang in DELETE_FAILED on the VPC or a subnet."
      fi
    done
  fi

  # -------------------------------------------------------------------------
  # Step 3: PersistentVolumeClaims (off by default — Online Boutique doesn't
  # use any, so this only matters if the cluster has been extended)
  # -------------------------------------------------------------------------
  log "Checking for PersistentVolumeClaims"
  PVCS=$(kubectl get pvc -A -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"')
  if [ -z "$PVCS" ]; then
    echo "None found."
  else
    echo "Found PVCs (these back real EBS volumes with real data):"
    echo "$PVCS"
    if [ "$DELETE_PVCS" = true ]; then
      echo "$PVCS" | while read -r ns name; do
        log "Deleting PVC $ns/$name"
        kubectl delete pvc "$name" -n "$ns" --wait=true
      done
    else
      warn "Not deleting PVCs (pass --delete-pvcs to do so). If left behind, the backing EBS volumes"
      warn "will survive stack deletion and keep costing money — clean them up manually via the EC2"
      warn "console if you don't need the data."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: delete the CloudFormation stack itself. CloudFormation handles the
# ordering of everything it created (NodeGroup -> EKS Cluster -> NAT Gateway
# / EIP -> route table associations -> subnets -> IGW attachment -> VPC ->
# IAM roles) automatically — no manual sequencing needed here.
# ---------------------------------------------------------------------------
if [ "$AUTO_YES" != true ]; then
  read -r -p $'\nAbout to delete CloudFormation stack '"$STACK_NAME"$' in '"$REGION"$'. Continue? [y/N] ' REPLY
  [[ "$REPLY" =~ ^[Yy]$ ]] || die "Aborted."
fi

log "Deleting stack $STACK_NAME"
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"

log "Waiting for deletion to complete (this typically takes 10-15 minutes for EKS + NAT Gateway)"
if aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"; then
  log "Done. Stack $STACK_NAME and everything in it has been deleted."
else
  warn "Stack delete did not complete cleanly. Recent failure events:"
  aws cloudformation describe-stack-events --stack-name "$STACK_NAME" --region "$REGION" \
    --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
    --output table
  warn "Common cause: a leftover ELB/ENI from a Kubernetes LoadBalancer Service blocking VPC/subnet"
  warn "deletion. Find and remove the orphaned resource, then re-run this script — CloudFormation"
  warn "resumes a DELETE_FAILED stack from where it left off."
  exit 1
fi
