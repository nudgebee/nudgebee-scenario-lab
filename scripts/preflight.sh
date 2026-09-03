#!/usr/bin/env bash
# NudgeBee Scenario Lab - preflight
#
# Verifies you can actually deploy and run the lab BEFORE anything is created.
# Read-only: creates nothing, changes nothing.
#
# Permissions are checked with iam:SimulatePrincipalPolicy where available -
# it evaluates your real identity policies, resource policies, permission
# boundaries and SCPs without performing the action. If that call is itself
# denied, we fall back to live probes of the read-only APIs and warn that the
# write permissions could not be verified.
#
#   ./scripts/preflight.sh              # check deploy + runtime
#   ./scripts/preflight.sh --runtime    # skip deploy checks (already deployed)
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK="${SCENARIO_LAB_STACK:-nudgebee-scenario-lab}"
MODE="${1:-all}"
FAIL=0; WARN=0

ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn()  { printf '  \033[33m!\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
note()  { printf '    \033[90m%s\033[0m\n' "$1"; }

# Actions needed to CREATE the lab
DEPLOY_ACTIONS=(
  cloudformation:CreateStack cloudformation:DescribeStacks
  cloudformation:CreateChangeSet cloudformation:ExecuteChangeSet
  cloudformation:DeleteStack
  ec2:RunInstances ec2:TerminateInstances ec2:CreateTags
  ec2:DescribeInstances ec2:DescribeImages ec2:DescribeSubnets ec2:DescribeVpcs
  ec2:CreateSecurityGroup ec2:DeleteSecurityGroup
  ec2:AuthorizeSecurityGroupEgress ec2:DescribeSecurityGroups
  iam:CreateRole iam:DeleteRole iam:GetRole iam:TagRole
  iam:AttachRolePolicy iam:DetachRolePolicy iam:PassRole
  iam:CreateInstanceProfile iam:DeleteInstanceProfile
  iam:AddRoleToInstanceProfile iam:RemoveRoleFromInstanceProfile
  cloudwatch:PutMetricAlarm cloudwatch:DeleteAlarms
  ssm:PutParameter ssm:DeleteParameter ssm:AddTagsToResource
)

# Actions needed to RUN scenarios
RUNTIME_ACTIONS=(
  ssm:SendCommand ssm:CancelCommand ssm:ListCommands
  ssm:GetCommandInvocation ssm:DescribeInstanceInformation
  ssm:GetParameter ssm:PutParameter
  ec2:DescribeInstances
  cloudwatch:DescribeAlarms cloudwatch:GetMetricStatistics
)

# ------------------------------------------------------------------ identity

head_ "Identity"
command -v aws >/dev/null 2>&1 || { bad "aws CLI not found - install AWS CLI v2"; exit 1; }
command -v python3 >/dev/null 2>&1 || { bad "python3 not found (used to parse AWS JSON)"; exit 1; }

IDENT=$(aws sts get-caller-identity --output json 2>/dev/null) || {
  bad "aws sts get-caller-identity failed - configure credentials (aws configure / aws sso login)"
  exit 1
}
ACCOUNT=$(echo "$IDENT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["Account"])')
CALLER=$(echo "$IDENT"  | python3 -c 'import sys,json;print(json.load(sys.stdin)["Arn"])')
ok "$CALLER"
note "account $ACCOUNT, region $REGION"

# SimulatePrincipalPolicy needs the ROLE arn, not the assumed-role session arn.
POLICY_ARN="$CALLER"
case "$CALLER" in
  *:assumed-role/*)
    ROLE_NAME=$(echo "$CALLER" | awk -F/ '{print $2}')
    POLICY_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
    note "simulating against $POLICY_ARN"
    ;;
esac

# ------------------------------------------------------------------ simulate

simulate() { # simulate <label> <action...>
  local label="$1"; shift
  local out denied
  out=$(aws iam simulate-principal-policy \
          --policy-source-arn "$POLICY_ARN" \
          --action-names "$@" \
          --output json 2>/dev/null) || return 2

  denied=$(echo "$out" | python3 -c '
import sys, json
res = json.load(sys.stdin)["EvaluationResults"]
bad = [r["EvalActionName"] for r in res if r["EvalDecision"] != "allowed"]
print(" ".join(bad))
')
  if [ -z "$denied" ]; then
    ok "$label — all ${#} action(s) allowed"
    return 0
  fi
  bad "$label — denied:"
  for a in $denied; do note "$a"; done
  return 1
}

SIM_OK=1
head_ "Permissions"
if ! aws iam simulate-principal-policy --policy-source-arn "$POLICY_ARN" \
       --action-names sts:GetCallerIdentity --output json >/dev/null 2>&1; then
  SIM_OK=0
  warn "iam:SimulatePrincipalPolicy is not permitted for this identity"
  note "Falling back to live probes. Write permissions CANNOT be verified in advance;"
  note "if the deploy fails on AccessDenied, that is why."
fi

if [ "$SIM_OK" = "1" ]; then
  if [ "$MODE" != "--runtime" ]; then
    simulate "deploy permissions" "${DEPLOY_ACTIONS[@]}"
  fi
  simulate "runtime permissions" "${RUNTIME_ACTIONS[@]}"
else
  probe() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$l"; else bad "$l"; fi; }
  probe "ec2:DescribeInstances"           aws ec2 describe-instances --max-items 1 --region "$REGION"
  probe "cloudwatch:DescribeAlarms"       aws cloudwatch describe-alarms --max-records 1 --region "$REGION"
  probe "ssm:DescribeInstanceInformation" aws ssm describe-instance-information --max-results 1 --region "$REGION"
  probe "cloudformation:ListStacks"       aws cloudformation list-stacks --region "$REGION"
  warn "write permissions (RunInstances, CreateRole, PutMetricAlarm, SendCommand) unverified"
fi

# ------------------------------------------------------------------ quotas / env

head_ "Account readiness"
if RUNNING=$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=instance-state-name,Values=running" \
      --query 'length(Reservations[].Instances[])' --output text 2>/dev/null); then
  ok "can list EC2 instances (${RUNNING} running in $REGION)"
else
  bad "cannot list EC2 instances in $REGION"
fi

if aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --region "$REGION" --query 'Parameters[0].Value' --output text >/dev/null 2>&1; then
  ok "Amazon Linux 2023 AMI parameter resolvable"
else
  bad "cannot read the public AL2023 AMI SSM parameter - the template resolves its AMI from it"
fi

# ------------------------------------------------------------------ stack

head_ "Scenario Lab stack"
if aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" >/dev/null 2>&1; then
  ok "stack '$STACK' exists"
  HOSTS=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:nudgebee-scenario-lab,Values=true" "Name=instance-state-name,Values=running" \
    --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)
  if [ "${HOSTS:-0}" -gt 0 ] 2>/dev/null; then
    ok "$HOSTS scenario host(s) running"
    ONLINE=$(aws ssm describe-instance-information --region "$REGION" \
      --query "length(InstanceInformationList[?PingStatus=='Online'])" --output text 2>/dev/null || echo 0)
    if [ "${ONLINE:-0}" -gt 0 ] 2>/dev/null; then
      ok "$ONLINE instance(s) registered with SSM"
    else
      bad "no instances registered with SSM"
      note "check the instance profile is attached and the subnet reaches the SSM endpoints"
      note "(internet route, NAT, or com.amazonaws.<region>.ssm / .ssmmessages / .ec2messages VPC endpoints)"
    fi
  else
    warn "no running scenario hosts yet"
  fi
else
  [ "$MODE" = "--runtime" ] && bad "stack '$STACK' not found" \
                            || warn "stack '$STACK' not deployed yet (expected before first deploy)"
fi

# ------------------------------------------------------------------ nudgebee

head_ "NudgeBee event delivery"
RULE_NAMES=$(aws events list-rules --region "$REGION" --query 'Rules[].Name' --output text 2>/dev/null | tr '\t' '\n' | grep -i nudgebee || true)
if [ -z "$RULE_NAMES" ]; then
  bad "no NudgeBee EventBridge rules in $REGION"
  note "Onboard this AWS account in NudgeBee first. Without event forwarding the"
  note "alarms fire in CloudWatch and never reach NudgeBee - scenarios will look"
  note "like they did nothing."
else
  COUNT=$(echo "$RULE_NAMES" | wc -l | tr -d ' ')
  ok "$COUNT NudgeBee EventBridge rule(s) found"
  ENABLED_WITH_TARGET=0
  for r in $RULE_NAMES; do
    STATE=$(aws events describe-rule --name "$r" --region "$REGION" --query State --output text 2>/dev/null)
    TGT=$(aws events list-targets-by-rule --rule "$r" --region "$REGION" --query 'length(Targets)' --output text 2>/dev/null || echo 0)
    [ "$STATE" = "ENABLED" ] && [ "${TGT:-0}" -gt 0 ] 2>/dev/null && ENABLED_WITH_TARGET=$((ENABLED_WITH_TARGET+1))
  done
  if [ "$ENABLED_WITH_TARGET" -gt 0 ]; then
    ok "$ENABLED_WITH_TARGET rule(s) enabled with a delivery target"
  else
    bad "NudgeBee rules exist but none is both ENABLED and has a target"
    note "alarms will not reach NudgeBee"
  fi
fi

head_ "Control UI"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ok "docker is running"
else
  warn "docker unavailable - the UI needs it (scenarios can still be driven by AWS CLI)"
fi

# ------------------------------------------------------------------ summary

printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\033[31m%d check(s) failed' "$FAIL"
  [ "$WARN" -gt 0 ] && printf ', %d warning(s)' "$WARN"
  printf '\033[0m\n\nFix these before deploying - see docs/01-prerequisites.md\n'
  exit 1
fi
printf '\033[32mReady'
[ "$WARN" -gt 0 ] && printf ' (%d warning(s))' "$WARN"
printf '\033[0m\n'
