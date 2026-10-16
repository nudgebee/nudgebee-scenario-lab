#!/usr/bin/env bash
# One-command deploy, Azure. Called by scripts/deploy.sh when CLOUD=azure.
#
#   CLOUD=azure ./scripts/deploy.sh            # lab tier (VMs + alerts)
#   CLOUD=azure ./scripts/deploy.sh waste      # waste tier (cost/security findings)
#   CLOUD=azure ./scripts/deploy.sh both       # lab + waste
#
# Each tier gets a resource group of its own, created here, so nothing lands
# next to resources you care about and teardown is a single `az group delete`.
#
#   AZURE_LOCATION=westeurope            region (default eastus)
#   ACTION_GROUP_ID=/subscriptions/...   notify this action group when an alert
#                                        fires; by default one whose name
#                                        contains "nudgebee" is used if found
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCATION="${AZURE_LOCATION:-eastus}"
STACK="${SCENARIO_LAB_STACK:-nudgebee-scenario-lab}"
MAX_MINUTES="${MAX_SCENARIO_MINUTES:-30}"
WHAT="${1:-lab}"

c_ok(){ printf '\033[32m%s\033[0m\n' "$1"; }
c_hd(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
c_dim(){ printf '\033[90m%s\033[0m\n' "$1"; }

case "$WHAT" in
  lab|waste|both) ;;
  db|lb|services|all) echo "The $WHAT tier is AWS-only for now - on Azure, deploy lab and/or waste."; exit 1 ;;
  *) echo "usage: CLOUD=azure $0 [lab|waste|both]"; exit 1 ;;
esac

command -v az >/dev/null 2>&1 || { echo "az CLI not found - install the Azure CLI"; exit 1; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen not found"; exit 1; }
# an object query, not a list: -o tsv prints a list one value per line
SUB=$(az account show --query '{i:id,n:name,u:user.name}' -o tsv 2>/dev/null | tr '\t' '|') || {
  echo "Not logged in. Run 'az login' (and 'az account set --subscription ...') first."; exit 1; }
IFS='|' read -r SUB_ID SUB_NAME SUB_USER <<<"$SUB"

# Each VM publishes its failed-unit and process counts (service_failure,
# zombie_processes) with Monitoring Metrics Publisher on itself. Granting that
# is a role assignment, which only Owner or User Access Administrator may make;
# anyone else gets the lab without those two alerts instead of a failed deploy.
# PUBLISH_HOST_METRICS=true|false overrides the check.
HOST_METRICS="${PUBLISH_HOST_METRICS:-}"
if [ -z "$HOST_METRICS" ]; then
  ME=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || az ad sp show --id "$SUB_USER" --query id -o tsv 2>/dev/null || true)
  CAN=$(az role assignment list --assignee "$ME" --all --include-inherited --include-groups \
          --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='User Access Administrator'] | length(@)" -o tsv 2>/dev/null || echo 0)
  [ "${CAN:-0}" -gt 0 ] 2>/dev/null && HOST_METRICS=true || HOST_METRICS=false
fi

ACTION_GROUP="${ACTION_GROUP_ID:-}"
if [ -z "$ACTION_GROUP" ]; then
  ACTION_GROUP=$(az monitor action-group list \
    --query "[?contains(name,'nudgebee') || contains(name,'NudgeBee') || contains(name,'Nudgebee')].id | [0]" \
    -o tsv 2>/dev/null || true)
fi

c_hd "Target"
echo "  subscription : $SUB_NAME · $SUB_ID"
echo "  identity     : $SUB_USER"
echo "  location     : $LOCATION"
echo "  resource grp : $STACK$([ "$WHAT" != lab ] && echo " (+ ${STACK}-waste)")"
echo "  network      : a new isolated virtual network created by the deployment"
echo "  alerts to    : ${ACTION_GROUP:-Azure Monitor only (no action group found)}"
if [ "$HOST_METRICS" = "true" ]; then
  echo "  host metrics : on (service-down and proc-high alerts)"
else
  echo "  host metrics : OFF - you cannot assign roles here, so service_failure and"
  echo "                 zombie_processes will run without alerts (PUBLISH_HOST_METRICS=true to force)"
fi

printf '\nThese VMs are deliberately degraded by scenarios. Continue? [y/N] '
read -r reply
case "$reply" in [yY]*) ;; *) echo "aborted"; exit 0 ;; esac

# Azure insists on an admin credential for a Linux VM. Nothing inbound is open
# and scenarios arrive via Run Command, so the lab never uses it: generate a
# key, pass the public half, and throw the private half away.
throwaway_key() { # throwaway_key <resource group>
  # Re-deploying must pass the key the VMs already have - Azure refuses to
  # change an existing VM's admin key - so reuse it if there is one.
  local existing
  existing=$(az vm list --resource-group "$1" \
               --query '[0].osProfile.linuxConfiguration.ssh.publicKeys[0].keyData' -o tsv 2>/dev/null || true)
  if [ -n "$existing" ]; then echo "$existing"; return; fi
  local tmp; tmp=$(mktemp -d)
  ssh-keygen -q -t rsa -b 3072 -N '' -C nudgebee-scenario-lab -f "$tmp/lab"
  cat "$tmp/lab.pub"
  rm -rf "$tmp"
}

ensure_group() { # ensure_group <name>
  # Never re-create an existing group: `az group create` replaces its tags,
  # and the control app keeps running-scenario state in them.
  [ "$(az group exists --name "$1")" = "true" ] && return 0
  az group create --name "$1" --location "$LOCATION" \
    --tags nudgebee-scenario-lab=true nb-max-minutes="$MAX_MINUTES" -o none
}

deploy_lab() {
  c_hd "Deploying lab tier (about 5 minutes)"
  ensure_group "$STACK"
  az deployment group create \
    --resource-group "$STACK" \
    --name lab \
    --template-file "$ROOT/infra/azure/lab.bicep" \
    --parameters sshPublicKey="$(throwaway_key "$STACK")" actionGroupId="$ACTION_GROUP" publishHostMetrics="$HOST_METRICS" \
    -o none
  c_ok "lab tier deployed"
  az vm list --resource-group "$STACK" --query '[].name' -o tsv | sed 's/^/  /'
}

deploy_waste() {
  c_hd "Deploying waste tier"
  ensure_group "${STACK}-waste"
  az deployment group create \
    --resource-group "${STACK}-waste" \
    --name waste \
    --template-file "$ROOT/infra/azure/waste.bicep" \
    --parameters sshPublicKey="$(throwaway_key "${STACK}-waste")" \
    -o none
  c_ok "waste tier deployed"
  c_dim "  One manual step - ARM cannot create a deallocated VM:"
  az deployment group show --resource-group "${STACK}-waste" --name waste \
    --query 'properties.outputs.manualStepRequired.value' -o tsv 2>/dev/null | sed 's/^/  /'
}

case "$WHAT" in
  lab)   deploy_lab ;;
  waste) deploy_waste ;;
  both)  deploy_lab; deploy_waste ;;
esac

c_hd "Next"
echo "  CLOUD=azure ./scripts/run-local.sh      then open http://127.0.0.1:8080"
c_dim "  VMs take a few minutes to finish cloud-init; the UI enables Start on its own."
c_hd "Teardown"
c_dim "  az group delete --name $STACK --yes"
c_dim "  az group delete --name ${STACK}-waste --yes      # if deployed"
