#!/usr/bin/env bash
# aws-teardown.sh — Tear down all AWS resources for Daystrom Mini
#
# WARNING: This deletes ALL stacks and ALL data (RDS, Redis, EFS, ECR images).
# Usage:
#   AWS_REGION=us-east-1 CLUSTER_NAME=daystrom-mini ./scripts/aws-teardown.sh

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-daystrom-mini}"
AWS_REGION="${AWS_REGION:-us-east-1}"

STACK_NET="${CLUSTER_NAME}-networking"
STACK_EKS="${CLUSTER_NAME}-eks"
STACK_DATA="${CLUSTER_NAME}-data"
STACK_ECR="${CLUSTER_NAME}-ecr"
STACK_SECRETS="${CLUSTER_NAME}-secrets"

info()    { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

delete_stack() {
  local stack=$1
  if aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$stack" >/dev/null 2>&1; then
    info "Deleting stack: $stack"
    aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$stack"
    aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$stack"
    success "Deleted: $stack"
  else
    warn "Stack not found, skipping: $stack"
  fi
}

echo ""
warn "This will permanently delete all AWS resources for cluster: $CLUSTER_NAME"
warn "Region: $AWS_REGION"
echo ""
read -r -p "Type the cluster name to confirm: " CONFIRM
[[ "$CONFIRM" != "$CLUSTER_NAME" ]] && echo "Cancelled." && exit 1

# ── 1. Delete k8s workloads first (removes ALB, target groups, etc.) ──────────
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  info "Updating kubeconfig..."
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" 2>/dev/null || true

  info "Deleting k8s ingress (deprovisions ALB)..."
  kubectl delete ingress daystrom-ingress -n daystrom-mini --ignore-not-found=true
  info "Waiting 60s for ALB to deprovision..."
  sleep 60

  info "Deleting all workloads in daystrom-mini namespace..."
  kubectl delete all --all -n daystrom-mini --ignore-not-found=true
fi

# ── 2. Empty ECR repos before deleting (CFN can't delete non-empty repos) ─────
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
for svc in web-app request-orchestrator prompt-cache model-router safety-gateway mock-server inference-pool; do
  REPO="${CLUSTER_NAME}/${svc}"
  info "Purging ECR repo: $REPO"
  IMAGES=$(aws ecr list-images \
    --region "$AWS_REGION" \
    --repository-name "$REPO" \
    --query 'imageIds[*]' \
    --output json 2>/dev/null || echo "[]")
  if [[ "$IMAGES" != "[]" && "$IMAGES" != "" ]]; then
    aws ecr batch-delete-image \
      --region "$AWS_REGION" \
      --repository-name "$REPO" \
      --image-ids "$IMAGES" >/dev/null 2>&1 || true
  fi
done

# ── 3. Delete ALB controller IAM policy ───────────────────────────────────────
ALB_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT}:policy/AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
if aws iam get-policy --policy-arn "$ALB_POLICY_ARN" >/dev/null 2>&1; then
  info "Detaching and deleting ALB controller IAM policy..."
  aws iam detach-role-policy \
    --role-name "${CLUSTER_NAME}-alb-controller-role" \
    --policy-arn "$ALB_POLICY_ARN" 2>/dev/null || true
  aws iam delete-policy --policy-arn "$ALB_POLICY_ARN" 2>/dev/null || true
fi

# ── 4. Delete stacks (reverse order of creation, secrets/ecr in parallel) ─────
delete_stack "$STACK_SECRETS" &
delete_stack "$STACK_ECR" &
wait

delete_stack "$STACK_DATA"
delete_stack "$STACK_EKS"
delete_stack "$STACK_NET"

# ── 5. Restore kustomize overlay placeholders (for future fresh deploy) ────────
K8S_OVERLAY="$(cd "$(dirname "$0")/../k8s/overlays/aws" && pwd)"
if ls "$K8S_OVERLAY"/*.bak >/dev/null 2>&1; then
  info "Restoring kustomize overlay files from .bak..."
  for f in "$K8S_OVERLAY"/*.bak; do
    mv "$f" "${f%.bak}"
  done
fi

echo ""
success "All AWS resources for $CLUSTER_NAME deleted."
