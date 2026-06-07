#!/usr/bin/env bash
# aws-deploy.sh — Full AWS deployment for Daystrom Mini workshop
#
# Prerequisites: aws-cli, kubectl, helm, docker, jq
# Usage:
#   export AWS_PROFILE=your-profile   (or configure credentials another way)
#   export DT_ENDPOINT=https://<env>.live.dynatrace.com/api/v2/otlp
#   export DT_API_TOKEN=<your-token>
#   ./scripts/aws-deploy.sh
#
# Optional overrides:
#   AWS_REGION      — default: us-east-1
#   DB_PASSWORD     — default: randomly generated, printed at end
#   NODE_TYPE       — default: m5.xlarge
#   CLUSTER_NAME    — default: daystrom-mini

set -euo pipefail

# ── Load config file ──────────────────────────────────────────────────────────
# Looks for deploy.local.env (your personal values, gitignored) next to this
# script or in the repo root. Environment variables already set take precedence.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for config_file in \
  "${SCRIPT_DIR}/../deploy.local.env" \
  "${SCRIPT_DIR}/deploy.local.env"
do
  if [[ -f "$config_file" ]]; then
    echo "[INFO]  Loading config from $config_file"
    # Only set variables that aren't already in the environment
    set -a
    # shellcheck source=/dev/null
    source "$config_file"
    set +a
    break
  fi
done

# ── Configuration ─────────────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-daystrom-mini}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NODE_TYPE="${NODE_TYPE:-m5.xlarge}"
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
DT_ENDPOINT="${DT_ENDPOINT:-}"
DT_API_TOKEN="${DT_API_TOKEN:-}"

# ── Existing VPC mode ─────────────────────────────────────────────────────────
# Set USE_EXISTING_VPC=true and supply subnet/VPC IDs to skip creating a new VPC.
# Useful when at the 5-VPC-per-region limit.
#
#   export USE_EXISTING_VPC=true
#   export EXISTING_VPC_ID=vpc-xxxxxxxx
#   export EXISTING_PUBLIC_SUBNET_1=subnet-xxxxxxxx
#   export EXISTING_PUBLIC_SUBNET_2=subnet-xxxxxxxx
#   export EXISTING_PRIVATE_SUBNET_1=subnet-xxxxxxxx
#   export EXISTING_PRIVATE_SUBNET_2=subnet-xxxxxxxx
USE_EXISTING_VPC="${USE_EXISTING_VPC:-false}"
EXISTING_VPC_ID="${EXISTING_VPC_ID:-}"
EXISTING_PUBLIC_SUBNET_1="${EXISTING_PUBLIC_SUBNET_1:-}"
EXISTING_PUBLIC_SUBNET_2="${EXISTING_PUBLIC_SUBNET_2:-}"
# Note: private subnets are created by 00-existing-vpc.yaml, not passed as env vars

STACK_NET="${CLUSTER_NAME}-networking"
STACK_EKS="${CLUSTER_NAME}-eks"
STACK_DATA="${CLUSTER_NAME}-data"
STACK_ECR="${CLUSTER_NAME}-ecr"
STACK_SECRETS="${CLUSTER_NAME}-secrets"

CFN_DIR="$(cd "$(dirname "$0")/../cfn/stacks" && pwd)"
K8S_OVERLAY="$(cd "$(dirname "$0")/../k8s/overlays/aws" && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Helpers ────────────────────────────────────────────────────────────────────
info()    { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()     { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

cfn_deploy() {
  local stack=$1 template=$2
  shift 2
  info "Deploying stack: $stack"
  aws cloudformation deploy \
    --region "$AWS_REGION" \
    --stack-name "$stack" \
    --template-file "$template" \
    --capabilities CAPABILITY_NAMED_IAM \
    "$@"
  success "Stack ready: $stack"
}

cfn_output() {
  local stack=$1 key=$2
  aws cloudformation describe-stacks \
    --region "$AWS_REGION" \
    --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text
}

wait_for_stack() {
  local stack=$1 event=$2
  info "Waiting for $stack ($event)..."
  aws cloudformation wait "stack-${event}-complete" \
    --region "$AWS_REGION" \
    --stack-name "$stack"
}

# ── 0. Prerequisite checks ─────────────────────────────────────────────────────
info "Checking prerequisites..."
for cmd in aws kubectl helm docker jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed"
done

AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
info "AWS Account: $AWS_ACCOUNT  |  Region: $AWS_REGION  |  Cluster: $CLUSTER_NAME"
info "Node type: $NODE_TYPE  |  DB password: (set)"
[[ -z "$DT_ENDPOINT" ]] && warn "DT_ENDPOINT not set — OTel will use debug exporter only"

if [[ "$USE_EXISTING_VPC" == "true" ]]; then
  [[ -z "$EXISTING_VPC_ID" ]]          && die "USE_EXISTING_VPC=true requires EXISTING_VPC_ID"
  [[ -z "$EXISTING_PUBLIC_SUBNET_1" ]] && die "USE_EXISTING_VPC=true requires EXISTING_PUBLIC_SUBNET_1"
  [[ -z "$EXISTING_PUBLIC_SUBNET_2" ]] && die "USE_EXISTING_VPC=true requires EXISTING_PUBLIC_SUBNET_2"
fi

# ── 1. Networking ──────────────────────────────────────────────────────────────
if [[ "$USE_EXISTING_VPC" == "true" ]]; then
  info "Using existing VPC $EXISTING_VPC_ID (skipping new VPC creation)"
  cfn_deploy "$STACK_NET" "$CFN_DIR/00-existing-vpc.yaml" \
    --parameter-overrides \
      ClusterName="$CLUSTER_NAME" \
      VpcId="$EXISTING_VPC_ID" \
      PublicSubnet1="$EXISTING_PUBLIC_SUBNET_1" \
      PublicSubnet2="$EXISTING_PUBLIC_SUBNET_2"
else
  cfn_deploy "$STACK_NET" "$CFN_DIR/01-networking.yaml" \
    --parameter-overrides ClusterName="$CLUSTER_NAME"
fi

# ── 2. EKS cluster ─────────────────────────────────────────────────────────────
cfn_deploy "$STACK_EKS" "$CFN_DIR/02-eks.yaml" \
  --parameter-overrides \
    ClusterName="$CLUSTER_NAME" \
    NetworkingStack="$STACK_NET" \
    NodeInstanceType="$NODE_TYPE"

# EKS takes ~15 min; CFN deploy already waits, but let's confirm nodes are Ready
info "Updating kubeconfig..."
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME"

info "Waiting for EKS nodes to be Ready..."
kubectl wait nodes --all --for=condition=Ready --timeout=600s

# ── 3. Data + ECR (can run in parallel) ───────────────────────────────────────
info "Deploying data stack (Redis, RDS, EFS)..."
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$STACK_DATA" \
  --template-file "$CFN_DIR/03-data.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ClusterName="$CLUSTER_NAME" \
    NetworkingStack="$STACK_NET" \
    DBPassword="$DB_PASSWORD" &
DATA_PID=$!

info "Deploying ECR repositories..."
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$STACK_ECR" \
  --template-file "$CFN_DIR/04-ecr.yaml" \
  --parameter-overrides ClusterName="$CLUSTER_NAME" &
ECR_PID=$!

wait $DATA_PID && success "Data stack ready" || die "Data stack failed"
wait $ECR_PID  && success "ECR stack ready"  || die "ECR stack failed"

# ── 4. Secrets ─────────────────────────────────────────────────────────────────
cfn_deploy "$STACK_SECRETS" "$CFN_DIR/05-secrets.yaml" \
  --parameter-overrides \
    ClusterName="$CLUSTER_NAME" \
    DataStack="$STACK_DATA" \
    DBPassword="$DB_PASSWORD" \
    DynatraceEndpoint="$DT_ENDPOINT" \
    DynatraceApiToken="$DT_API_TOKEN"

# ── 5. AWS Load Balancer Controller ───────────────────────────────────────────
ALB_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
ALB_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT}:policy/${ALB_POLICY_NAME}"

if ! aws iam get-policy --policy-arn "$ALB_POLICY_ARN" >/dev/null 2>&1; then
  info "Creating ALB controller IAM policy..."
  curl -sSLo /tmp/alb-iam-policy.json \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.1/docs/install/iam_policy.json
  aws iam create-policy \
    --policy-name "$ALB_POLICY_NAME" \
    --policy-document file:///tmp/alb-iam-policy.json \
    --region "$AWS_REGION" >/dev/null
  success "ALB controller IAM policy created"
else
  info "ALB controller IAM policy already exists, skipping"
fi

ALB_CONTROLLER_ROLE_ARN=$(cfn_output "$STACK_EKS" ALBControllerRoleArn)
aws iam attach-role-policy \
  --role-name "${CLUSTER_NAME}-alb-controller-role" \
  --policy-arn "$ALB_POLICY_ARN" 2>/dev/null || true

info "Installing AWS Load Balancer Controller via Helm..."
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

kubectl apply -k \
  "https://github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master" \
  2>/dev/null || true

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ALB_CONTROLLER_ROLE_ARN" \
  --set region="$AWS_REGION" \
  --set vpcId="$(cfn_output "$STACK_NET" VpcId)" \
  --wait
# Explicit subnet IDs are injected into the Ingress annotation below (step 7),
# avoiding the need to tag the existing public subnets.

success "AWS Load Balancer Controller installed"

# ── 6. Read CFN outputs for k8s overlay substitution ─────────────────────────
REDIS_ENDPOINT=$(cfn_output "$STACK_DATA" RedisEndpoint)
POSTGRES_ENDPOINT=$(cfn_output "$STACK_DATA" PostgresEndpoint)
EFS_ID=$(cfn_output "$STACK_DATA" EFSFileSystemId)
REGISTRY_URL=$(cfn_output "$STACK_ECR" RegistryUrl)

info "Redis:    $REDIS_ENDPOINT"
info "Postgres: $POSTGRES_ENDPOINT"
info "EFS:      $EFS_ID"
info "Registry: $REGISTRY_URL"

# ── 7. Patch kustomize overlay with actual endpoints ──────────────────────────
info "Patching kustomize overlay with AWS endpoints..."

PUBLIC_SUBNET_1=$(cfn_output "$STACK_NET" PublicSubnet1)
PUBLIC_SUBNET_2=$(cfn_output "$STACK_NET" PublicSubnet2)

# EFS filesystem ID into StorageClass
sed -i.bak "s|PLACEHOLDER_EFS_ID|${EFS_ID}|g" "$K8S_OVERLAY/efs-storage.yaml"

# Redis + Postgres hosts into ConfigMap patch
sed -i.bak \
  -e "s|PLACEHOLDER_REDIS_HOST|${REDIS_ENDPOINT}|g" \
  -e "s|PLACEHOLDER_POSTGRES_HOST|${POSTGRES_ENDPOINT}|g" \
  "$K8S_OVERLAY/app-config-patch.yaml"

# ECR image URIs into kustomization.yaml
sed -i.bak "s|PLACEHOLDER_REGISTRY|${REGISTRY_URL}|g" "$K8S_OVERLAY/kustomization.yaml"

# Public subnet IDs into Ingress (avoids needing to tag existing subnets)
sed -i.bak "s|PLACEHOLDER_PUBLIC_SUBNETS|${PUBLIC_SUBNET_1},${PUBLIC_SUBNET_2}|g" \
  "$K8S_OVERLAY/ingress.yaml"

# ── 8. Build and push images to ECR ──────────────────────────────────────────
info "Logging into ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY_URL"

build_and_push() {
  local svc_name=$1 context_path=$2 image_name=$3
  local uri="${REGISTRY_URL}/${CLUSTER_NAME}/${image_name}:latest"
  info "Building $svc_name..."
  docker build --platform linux/amd64 -t "$uri" "$REPO_ROOT/$context_path"
  info "Pushing $svc_name..."
  docker push "$uri"
  success "Pushed: $uri"
}

build_and_push "web-app"               "services/typescript/web-app"       "web-app"
build_and_push "request-orchestrator"  "services/java/request-orchestrator" "request-orchestrator"
build_and_push "prompt-cache"          "services/java/prompt-cache"         "prompt-cache"
build_and_push "inference-pool"        "services/java/inference-pool"       "inference-pool"
build_and_push "model-router"          "services/python/model-router"       "model-router"
build_and_push "safety-gateway"        "services/python/safety-gateway"     "safety-gateway"
build_and_push "mock-server"           "services/python/mock-server"        "mock-server"

# ── 9. Create k8s namespace + secrets from Secrets Manager ───────────────────
info "Applying namespace..."
kubectl apply -f "$REPO_ROOT/k8s/base/namespace.yaml"

info "Creating k8s secret: app-secrets (DB credentials from Secrets Manager)..."
DB_CREDS=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "/${CLUSTER_NAME}/db-credentials" \
  --query SecretString --output text)
DB_PASS=$(echo "$DB_CREDS" | jq -r '.password')

kubectl create secret generic app-secrets \
  --namespace daystrom-mini \
  --from-literal=POSTGRES_PASSWORD="$DB_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Creating k8s secret: dt-credentials (Dynatrace from Secrets Manager)..."
DT_CREDS=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "/${CLUSTER_NAME}/dt-credentials" \
  --query SecretString --output text)
DT_EP=$(echo "$DT_CREDS" | jq -r '.DT_ENDPOINT')
DT_TOK=$(echo "$DT_CREDS" | jq -r '.DT_API_TOKEN')

kubectl create secret generic dt-credentials \
  --namespace daystrom-mini \
  --from-literal=DT_ENDPOINT="$DT_EP" \
  --from-literal=DT_API_TOKEN="$DT_TOK" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 10. Deploy k8s workloads ───────────────────────────────────────────────────
info "Deploying workloads via kustomize..."
kubectl apply -k "$K8S_OVERLAY"

# Enable pgvector extension (runs once; idempotent)
info "Enabling pgvector extension on RDS..."
kubectl run pgvector-init \
  --namespace daystrom-mini \
  --image=postgres:16 \
  --restart=Never \
  --rm \
  --env="PGPASSWORD=${DB_PASS}" \
  --command -- psql \
    -h "$POSTGRES_ENDPOINT" -U daystrom -d daystrom \
    -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || true

# ── 11. Wait and print URL ─────────────────────────────────────────────────────
info "Waiting for all pods to be Ready..."
kubectl wait pods \
  --namespace daystrom-mini \
  --all \
  --for=condition=Ready \
  --timeout=600s \
  --field-selector=status.phase!=Succeeded 2>/dev/null || true

info "Waiting for ALB to be provisioned (up to 5 min)..."
for i in $(seq 1 30); do
  ALB_URL=$(kubectl get ingress daystrom-ingress -n daystrom-mini \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$ALB_URL" ]] && break
  sleep 10
done

echo ""
echo "════════════════════════════════════════════════════════════"
success "Daystrom Mini deployed to AWS!"
echo ""
echo "  Chat UI:  http://${ALB_URL}"
echo "  Cluster:  $CLUSTER_NAME ($AWS_REGION)"
echo "  Registry: $REGISTRY_URL"
echo ""
echo "  DB password saved to: Secrets Manager /${CLUSTER_NAME}/db-credentials"
echo ""
echo "  kubectl get pods -n daystrom-mini"
echo "════════════════════════════════════════════════════════════"
