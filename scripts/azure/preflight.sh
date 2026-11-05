#!/usr/bin/env bash
# NudgeBee Scenario Lab - preflight, Azure. Called by scripts/preflight.sh
# when CLOUD=azure.
#
# Verifies you can actually deploy and run the lab BEFORE anything is created.
# Read-only: creates nothing, changes nothing.
#
# Azure has no equivalent of IAM's policy simulator, so permissions are read
# from your role assignments: Owner or Contributor on the subscription covers
# everything the lab does. Anything narrower is reported as a warning, not a
# failure - a custom role may well be enough, it just cannot be proven here.
#
#   CLOUD=azure ./scripts/preflight.sh              # check deploy + runtime
#   CLOUD=azure ./scripts/preflight.sh --runtime    # skip deploy checks
set -uo pipefail

LOCATION="${AZURE_LOCATION:-eastus}"
STACK="${SCENARIO_LAB_STACK:-nudgebee-scenario-lab}"
VM_SIZE="${LAB_VM_SIZE:-Standard_B1s}"
MODE="${1:-all}"
FAIL=0; WARN=0

ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn()  { printf '  \033[33m!\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
note()  { printf '    \033[90m%s\033[0m\n' "$1"; }

# ------------------------------------------------------------------ identity

head_ "Identity"
command -v az >/dev/null 2>&1 || { bad "az CLI not found - install the Azure CLI"; exit 1; }

# an object query, not a list: -o tsv prints a list one value per line
ACCT=$(az account show --query '{i:id,n:name,u:user.name,t:user.type}' -o tsv 2>/dev/null | tr '\t' '|') || {
  bad "az account show failed - run 'az login' (and 'az account set --subscription ...')"
  exit 1
}
IFS='|' read -r SUB_ID SUB_NAME USER_NAME USER_TYPE <<<"$ACCT"
ok "$USER_NAME ($USER_TYPE)"
note "subscription $SUB_NAME · $SUB_ID, location $LOCATION"

# ------------------------------------------------------------------ permissions

head_ "Permissions"
if [ "$USER_TYPE" = "user" ]; then
  ASSIGNEE=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
else
  ASSIGNEE=$(az ad sp show --id "$USER_NAME" --query id -o tsv 2>/dev/null || true)
fi
if [ -z "$ASSIGNEE" ]; then
  warn "could not resolve your object ID - role assignments not checked"
else
  ROLES=$(az role assignment list --assignee "$ASSIGNEE" --all --include-inherited --include-groups \
            --query "[?scope=='/subscriptions/$SUB_ID' || starts_with(scope, '/subscriptions/$SUB_ID/resourceGroups/$STACK')].roleDefinitionName" \
            -o tsv 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
  case ",$ROLES," in
    *,Owner,*|*,Contributor,*)
      ok "role: ${ROLES}" ;;
    *)
      if [ "$MODE" = "--runtime" ] && echo "$ROLES" | grep -q "Virtual Machine Contributor"; then
        ok "role: ${ROLES} (enough to run scenarios)"
      else
        warn "no Owner or Contributor role on the subscription (found: ${ROLES:-none})"
        note "deploying needs resource group, VM, network and Azure Monitor write access;"
        note "running scenarios needs Microsoft.Compute/virtualMachines/runCommands/write"
      fi ;;
  esac
fi

# ------------------------------------------------------------------ subscription readiness

head_ "Subscription readiness"
for ns in Microsoft.Compute Microsoft.Network Microsoft.Insights Microsoft.AlertsManagement; do
  STATE=$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo unknown)
  if [ "$STATE" = "Registered" ]; then
    ok "$ns registered"
  else
    warn "$ns is $STATE"
    note "az provider register --namespace $ns"
  fi
done

if [ "$MODE" != "--runtime" ]; then
  # one row - "<size>\t<restriction or None>" - or nothing if the size is not offered.
  # This call is slow (tens of seconds), so it is made once.
  SKU=$(az vm list-skus --location "$LOCATION" --size "$VM_SIZE" --resource-type virtualMachines \
          --query "[?name=='$VM_SIZE'].[name, restrictions[0].reasonCode]" -o tsv 2>/dev/null | head -1)
  RESTRICTED=$(printf '%s' "$SKU" | cut -f2)
  if [ -z "$SKU" ]; then
    bad "$VM_SIZE is not offered in $LOCATION"
    note "pick another region with AZURE_LOCATION, or another size with the vmSize parameter"
  elif [ -n "$RESTRICTED" ] && [ "$RESTRICTED" != "None" ]; then
    bad "$VM_SIZE is restricted in $LOCATION for this subscription ($RESTRICTED)"
  else
    ok "$VM_SIZE available in $LOCATION"
  fi
fi

# ------------------------------------------------------------------ lab

head_ "Scenario Lab resource group"
if [ "$(az group exists --name "$STACK" 2>/dev/null)" = "true" ]; then
  ok "resource group '$STACK' exists"
  VMS=$(az vm list -d --resource-group "$STACK" \
          --query "[?tags.\"nudgebee-scenario-lab\"=='true' && powerState=='VM running'].name" -o tsv 2>/dev/null)
  COUNT=$(printf '%s' "$VMS" | grep -c . || true)
  if [ "${COUNT:-0}" -gt 0 ]; then
    ok "$COUNT scenario VM(s) running"
    READY=0
    for vm in $VMS; do
      S=$(az vm get-instance-view --resource-group "$STACK" --name "$vm" \
            --query 'instanceView.vmAgent.statuses[0].displayStatus' -o tsv 2>/dev/null)
      [ "$S" = "Ready" ] && READY=$((READY+1))
    done
    if [ "$READY" -gt 0 ]; then
      ok "$READY VM agent(s) ready for Run Command"
    else
      bad "no VM agent is ready"
      note "VMs report ready a few minutes after boot; check boot diagnostics if it persists"
    fi
  else
    warn "no running scenario VMs yet"
  fi
else
  [ "$MODE" = "--runtime" ] && bad "resource group '$STACK' not found" \
                            || warn "resource group '$STACK' not created yet (expected before first deploy)"
fi

# ------------------------------------------------------------------ nudgebee

head_ "NudgeBee alert delivery"
AG=$(az monitor action-group list \
       --query "[?contains(name,'nudgebee') || contains(name,'NudgeBee') || contains(name,'Nudgebee')].name" \
       -o tsv 2>/dev/null || true)
if [ -n "$AG" ]; then
  ok "action group(s): $(echo "$AG" | tr '\n' ' ')"
  note "deploy.sh wires the lab alerts to the first one"
else
  warn "no action group with 'nudgebee' in its name"
  note "Connect this subscription to NudgeBee first. Alerts still fire in Azure"
  note "Monitor, but if your NudgeBee integration relies on an action group, pass"
  note "ACTION_GROUP_ID=... to deploy.sh or the alerts will not reach it."
fi

head_ "Control UI"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ok "docker is running"
else
  warn "docker unavailable - run the UI with ./scripts/run-local.sh instead"
fi

# ------------------------------------------------------------------ summary

printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\033[31m%d check(s) failed' "$FAIL"
  [ "$WARN" -gt 0 ] && printf ', %d warning(s)' "$WARN"
  printf '\033[0m\n\nFix these before deploying.\n'
  exit 1
fi
printf '\033[32mReady'
[ "$WARN" -gt 0 ] && printf ' (%d warning(s))' "$WARN"
printf '\033[0m\n'
