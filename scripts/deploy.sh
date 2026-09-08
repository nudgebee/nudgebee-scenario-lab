#!/usr/bin/env bash
# One-command deploy. No arguments, nothing to look up.
#
#   ./scripts/deploy.sh            # lab tier (hosts + alarms)
#   ./scripts/deploy.sh waste      # waste tier (cost/security findings)
#   ./scripts/deploy.sh db         # db tier (a PostgreSQL host + its alarms)
#   ./scripts/deploy.sh both       # lab + waste
#   ./scripts/deploy.sh all        # lab + waste + db
#
# By default the stack creates its own isolated VPC, so you do not need to know
# or choose a network - and the lab cannot land in one you care about.
# To use an existing VPC instead:
#
#   VPC_ID=vpc-123 SUBNET_ID=subnet-456 ./scripts/deploy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
STACK="${SCENARIO_LAB_STACK:-nudgebee-scenario-lab}"
WHAT="${1:-lab}"

c_ok(){ printf '\033[32m%s\033[0m\n' "$1"; }
c_hd(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
c_dim(){ printf '\033[90m%s\033[0m\n' "$1"; }

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found - install AWS CLI v2"; exit 1; }
IDENT=$(aws sts get-caller-identity --output json 2>/dev/null) || {
  echo "Not authenticated. Run 'aws configure' or 'aws sso login' first."; exit 1; }
ACCOUNT=$(echo "$IDENT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["Account"])')
ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null)
[ "$ALIAS" = "None" ] && ALIAS=""

c_hd "Target"
echo "  account : ${ALIAS:+$ALIAS · }$ACCOUNT"
echo "  region  : $REGION"
echo "  stack   : $STACK"
if [ -n "${VPC_ID:-}" ]; then
  echo "  network : existing VPC ${VPC_ID} / ${SUBNET_ID:-<subnet required>}"
  [ -z "${SUBNET_ID:-}" ] && { echo "SUBNET_ID is required when VPC_ID is set"; exit 1; }
else
  echo "  network : a new isolated VPC created by the stack"
fi

printf '\nThese hosts are deliberately degraded by scenarios. Continue? [y/N] '
read -r reply
case "$reply" in [yY]*) ;; *) echo "aborted"; exit 0 ;; esac

overrides=()
[ -n "${VPC_ID:-}" ] && overrides+=("VpcId=${VPC_ID}" "SubnetId=${SUBNET_ID}")

deploy_lab() {
  c_hd "Deploying lab tier (about 4 minutes)"
  aws cloudformation deploy \
    --template-file "$ROOT/infra/cloudformation/lab.yaml" \
    --stack-name "$STACK" \
    --capabilities CAPABILITY_IAM \
    --region "$REGION" \
    ${overrides:+--parameter-overrides "${overrides[@]}"}
  c_ok "lab tier deployed"
  aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`NetworkMode`||OutputKey==`VpcUsed`].[OutputKey,OutputValue]' \
    --output text 2>/dev/null | sed 's/^/  /'
}

deploy_waste() {
  c_hd "Deploying waste tier"
  local woverrides=()
  if [ -n "${VPC_ID:-}" ]; then
    woverrides+=("VpcId=${VPC_ID}" "SubnetId=${SUBNET_ID}")
  else
    # waste.yaml needs a network; reuse whatever the lab stack ended up with
    local vpc sub
    vpc=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
          --query 'Stacks[0].Outputs[?OutputKey==`VpcUsed`].OutputValue' --output text 2>/dev/null)
    sub=$(aws ec2 describe-subnets --region "$REGION" \
          --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    [ -z "$vpc" ] || [ "$vpc" = "None" ] && { echo "Deploy the lab tier first, or set VPC_ID/SUBNET_ID"; return 1; }
    woverrides+=("VpcId=${vpc}" "SubnetId=${sub}")
  fi
  aws cloudformation deploy \
    --template-file "$ROOT/infra/cloudformation/waste.yaml" \
    --stack-name "${STACK}-waste" \
    --region "$REGION" \
    --parameter-overrides "${woverrides[@]}"
  c_ok "waste tier deployed"
  c_dim "  One manual step - CloudFormation cannot create a stopped instance:"
  aws cloudformation describe-stacks --stack-name "${STACK}-waste" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`ManualStepRequired`].OutputValue' --output text 2>/dev/null | sed 's/^/  /'
}

deploy_db() {
  c_hd "Deploying db tier (about 5 minutes)"
  local doverrides=() vpc sub sg
  if [ -n "${VPC_ID:-}" ]; then
    vpc="$VPC_ID"; sub="$SUBNET_ID"
  else
    vpc=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
          --query 'Stacks[0].Outputs[?OutputKey==`VpcUsed`].OutputValue' --output text 2>/dev/null)
    [ -z "$vpc" ] || [ "$vpc" = "None" ] && { echo "Deploy the lab tier first, or set VPC_ID/SUBNET_ID"; return 1; }
    sub=$(aws ec2 describe-subnets --region "$REGION" \
          --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
  fi
  # Give 5432 to the lab hosts only. Empty is fine - every db scenario runs on
  # the database host itself over the local socket, so an unreachable port
  # costs nothing except the cross-host connection scenarios.
  sg=$(aws ec2 describe-security-groups --region "$REGION" \
       --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=${STACK}-hosts" \
       --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  [ "$sg" = "None" ] && sg=""
  doverrides+=("VpcId=${vpc}" "SubnetId=${sub}" "LabStackName=${STACK}")
  [ -n "$sg" ] && doverrides+=("ClientSecurityGroupId=${sg}")
  aws cloudformation deploy \
    --template-file "$ROOT/infra/cloudformation/db.yaml" \
    --stack-name "${STACK}-db" \
    --region "$REGION" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides "${doverrides[@]}"
  c_ok "db tier deployed"
  c_dim "  PostgreSQL takes a further minute to initialise and start publishing metrics."
  aws cloudformation describe-stacks --stack-name "${STACK}-db" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`DbHostId`||OutputKey==`DbPrivateIp`].[OutputKey,OutputValue]' \
    --output text 2>/dev/null | sed 's/^/  /'
}

deploy_services() {
  c_hd "Deploying services tier (about 5 minutes)"
  aws cloudformation deploy \
    --template-file "$ROOT/infra/cloudformation/services.json" \
    --stack-name "${STACK}-services" \
    --region "$REGION" \
    --parameter-overrides "LabStackName=${STACK}"
  c_ok "services tier deployed"
  c_dim "  The three services call each other every 15s; the dependency map needs a few minutes of that traffic."
  aws cloudformation describe-stacks --stack-name "${STACK}-services" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`OrderHostId`||OutputKey==`Topology`].[OutputKey,OutputValue]' \
    --output text 2>/dev/null | sed 's/^/  /'
}

deploy_lb() {
  c_hd "Deploying load balancer tier (about 4 minutes)"
  # The target has to exist before the target group can register it, and the
  # instance id is an output of the services stack rather than something the
  # operator should have to look up and paste.
  local order
  order=$(aws cloudformation describe-stacks --stack-name "${STACK}-services" --region "$REGION" \
          --query 'Stacks[0].Outputs[?OutputKey==`OrderHostId`].OutputValue' --output text 2>/dev/null)
  if [ -z "$order" ] || [ "$order" = "None" ]; then
    echo "Deploy the services tier first: $0 services"
    return 1
  fi
  aws cloudformation deploy \
    --template-file "$ROOT/infra/cloudformation/lb.yaml" \
    --stack-name "${STACK}-lb" \
    --region "$REGION" \
    --parameter-overrides "LabStackName=${STACK}" "OrderInstanceId=${order}"
  c_ok "load balancer tier deployed"
  c_dim "  This one bills whether or not you run a scenario. Delete it when you are done."
  aws cloudformation describe-stacks --stack-name "${STACK}-lb" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`AlbDnsName`].[OutputKey,OutputValue]' \
    --output text 2>/dev/null | sed 's/^/  /'
}

case "$WHAT" in
  lab)      deploy_lab ;;
  waste)    deploy_waste ;;
  db)       deploy_db ;;
  services) deploy_services ;;
  lb)       deploy_lb ;;
  both)     deploy_lab; deploy_waste ;;
  # Order matters: services needs the lab's network, lb needs the order host.
  all)      deploy_lab; deploy_waste; deploy_db; deploy_services; deploy_lb ;;
  *) echo "usage: $0 [lab|waste|db|services|lb|both|all]"; exit 1 ;;
esac

c_hd "Next"
echo "  ./scripts/run-local.sh      then open http://127.0.0.1:8080"
c_dim "  Hosts take a minute or two to register with SSM; the UI enables Start on its own."
c_hd "Teardown"
c_dim "  aws cloudformation delete-stack --stack-name $STACK --region $REGION"
c_dim "  aws cloudformation delete-stack --stack-name ${STACK}-db --region $REGION      # if deployed"
