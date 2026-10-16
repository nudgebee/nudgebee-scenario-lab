"""
Azure backend: Linux VMs driven by managed Run Command, Azure Monitor metric
alerts, state in resource-group tags, tiers deployed as Bicep into a dedicated
resource group each.

How the AWS pieces map across:

  CloudFormation stack     -> a resource group holding one deployment
  EC2 + SSM agent          -> VM + Azure VM agent (ships with the image)
  SSM SendCommand          -> managed Run Command, asyncExecution=true
  SSM CancelCommand        -> deleting that Run Command (terminates the script)
  CloudWatch alarm state   -> Azure Monitor fired alerts for the rule
  SSM parameter (state)    -> tags on the lab resource group

Why tags and not a storage account for state: a storage account means data
plane RBAC for every operator and one more thing to deploy. The state is
tiny - which scenario, on which VM, until when - and a tag per running
scenario fits comfortably inside Azure's 256-character tag value limit.
"""

import base64
import fnmatch
import json
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from fastapi import HTTPException

from server.providers.base import cached, forget, now, repo_root

try:
    from azure.core.exceptions import AzureError, HttpResponseError, ResourceNotFoundError
    from azure.identity import DefaultAzureCredential
    from azure.mgmt.authorization import AuthorizationManagementClient
    from azure.mgmt.compute import ComputeManagementClient
    from azure.mgmt.compute.models import (
        VirtualMachineRunCommand,
        VirtualMachineRunCommandScriptSource,
    )
    from azure.mgmt.monitor import MonitorManagementClient
    from azure.mgmt.resource import ResourceManagementClient, SubscriptionClient
except ImportError as exc:  # pragma: no cover - surfaced at startup
    raise RuntimeError(
        "CLOUD=azure needs the Azure SDK: pip install -r control/requirements.txt"
    ) from exc

LAB_TAG = "nudgebee-scenario-lab"
STATE_TAG_PREFIX = "nbs-"          # one resource-group tag per running scenario
MAX_MINUTES_TAG = "nb-max-minutes"
RUN_PREFIX = "nb-"                 # every Run Command this app creates
LABEL_TAG = "nb-label"             # scenario id, "cleanup: <id>" or "reset"
TERMINAL = {"succeeded", "failed", "timedout", "canceled"}

# The catalogue names AWS IAM actions, because that is where it started. The
# Azure equivalents are what a role assignment has to allow.
ACTION_MAP = {
    "ssm:SendCommand": "Microsoft.Compute/virtualMachines/runCommands/write",
}

# The catalogue also names the metric each scenario's alarm watches, in AWS
# terms. Shown in the UI, so say what the Azure alert actually watches.
METRIC_MAP = (
    ("AWS/EC2 CPUUtilization", "Percentage CPU (VM host metric)"),
    ("CWAgent MemoryUtilization", "Available Memory Percentage (VM host metric)"),
    ("CWAgent DiskUtilization",
     "azure.vm.linux.guestmetrics disk/used_percent (needs Azure Monitor Agent)"),
    ("AWS/EC2 NetworkOut", "Network Out Total (VM host metric)"),
    ("AWS/EC2 StatusCheckFailed", "VmAvailabilityMetric (VM host metric)"),
    ("NudgebeeScenarioLab FailedSystemdUnits",
     "NudgebeeScenarioLab FailedSystemdUnits (custom metric published by the VM)"),
    ("NudgebeeScenarioLab ProcessCount",
     "NudgebeeScenarioLab ProcessCount (custom metric published by the VM)"),
)


def _subscription_from_cli() -> str | None:
    """The subscription `az` has selected - the same one deploy.sh used."""
    az = shutil.which("az")
    if not az:
        return None
    try:
        out = subprocess.run(
            [az, "account", "show", "--query", "id", "-o", "tsv"],
            capture_output=True, text=True, timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() or None


def _token_claims(token: str) -> dict:
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except (IndexError, ValueError):
        return {}


def _epoch(dt: datetime) -> int:
    return int(dt.timestamp())


def _iso(epoch: str | int) -> str:
    return datetime.fromtimestamp(int(epoch), tz=timezone.utc).isoformat()


class AzureProvider:
    name = "azure"
    labels = {
        "account": "Azure subscription",
        "agent": "VM agent",
        "stack": "Resource group",
        "permission": "rbac",
        "lab_template": "infra/azure/lab.bicep",
        "waste_template": "infra/azure/waste.bicep",
    }
    # db and services tiers are AWS-only for now
    tiers = ("lab",)
    deploy_actions = (
        "Microsoft.Resources/subscriptions/resourceGroups/write",
        "Microsoft.Resources/deployments/write",
        "Microsoft.Compute/virtualMachines/write",
        "Microsoft.Network/virtualNetworks/write",
        "Microsoft.Network/publicIPAddresses/write",
        "Microsoft.Insights/metricAlerts/write",
        "Microsoft.Insights/dataCollectionRules/write",
    )

    def __init__(self) -> None:
        self.stack = os.environ.get("SCENARIO_LAB_STACK", "nudgebee-scenario-lab")
        self.region = os.environ.get("AZURE_LOCATION", "eastus")
        self.infra_dir = Path(os.environ.get("AZURE_INFRA_DIR", "/app/infra/azure"))
        self.subscription = os.environ.get("AZURE_SUBSCRIPTION_ID") or _subscription_from_cli()
        if not self.subscription:
            raise RuntimeError(
                "no Azure subscription selected - run `az login` (and `az account set`), "
                "or set AZURE_SUBSCRIPTION_ID"
            )
        self.cred = DefaultAzureCredential(exclude_interactive_browser_credential=True)
        sub = self.subscription
        self.rm = ResourceManagementClient(self.cred, sub)
        self.compute = ComputeManagementClient(self.cred, sub)
        self.monitor = MonitorManagementClient(self.cred, sub)
        self.authz = AuthorizationManagementClient(self.cred, sub)

    # ------------------------------------------------------------- naming

    def stack_name_for(self, tier: str) -> str:
        """Each tier is its own resource group, so teardown is one delete."""
        return self.stack if tier == "lab" else f"{self.stack}-{tier}"

    def template_path(self, tier: str) -> Path:
        if tier not in ("lab", "waste"):
            raise HTTPException(400, "tier must be lab or waste")
        for base in (self.infra_dir, repo_root() / "infra" / "azure"):
            p = base / f"{tier}.bicep"
            if p.exists():
                return p
        raise HTTPException(500, f"{tier}.bicep not found - set AZURE_INFRA_DIR")

    def _rg(self):
        try:
            return self.rm.resource_groups.get(self.stack)
        except ResourceNotFoundError:
            return None
        except AzureError:
            return None

    # ------------------------------------------------------------- identity

    def _identity(self) -> dict:
        try:
            token = self.cred.get_token("https://management.azure.com/.default").token
        except AzureError as exc:
            return {"error": str(exc)}
        claims = _token_claims(token)
        name = None
        try:
            name = SubscriptionClient(self.cred).subscriptions.get(self.subscription).display_name
        except AzureError:
            pass
        principal = (claims.get("upn") or claims.get("unique_name")
                     or claims.get("preferred_username") or claims.get("appid") or "unknown")
        return {
            "account": self.subscription,
            "account_alias": name,
            "tenant": claims.get("tid"),
            "principal": principal,
            "object_id": claims.get("oid"),
        }

    def identity(self) -> dict:
        return cached("identity", 300, self._identity)

    def _effective_permissions(self) -> list[tuple[list[str], list[str]]] | None:
        """
        What the caller may do on the lab resource group, as Azure resolves it
        from every role assignment. None when it cannot be evaluated - before
        the resource group exists, or if the caller may not read permissions -
        so the UI fails open, the same as the AWS simulation does.
        """
        if not self._rg():
            return None
        try:
            perms = list(self.authz.permissions.list_for_resource_group(self.stack))
        except AzureError:
            return None
        return [(list(p.actions or []), list(p.not_actions or [])) for p in perms]

    def _check(self, actions: tuple[str, ...]) -> dict[str, bool]:
        effective = self._effective_permissions()
        if effective is None:
            return {}

        def allowed(action: str) -> bool:
            a = action.lower()
            for acts, nots in effective:
                if any(fnmatch.fnmatchcase(a, p.lower()) for p in acts) and not any(
                    fnmatch.fnmatchcase(a, n.lower()) for n in nots
                ):
                    return True
            return False

        return {a: allowed(a) for a in actions}

    def permissions(self, actions: tuple[str, ...]) -> dict[str, bool]:
        return cached("perm:" + ",".join(sorted(actions)), 300, lambda: self._check(actions))

    def can_check_permissions(self) -> bool:
        return self._effective_permissions() is not None

    def scenario_actions(self, scenario: dict) -> list[str]:
        aws = (scenario.get("requires") or {}).get("iam") or []
        return sorted({ACTION_MAP.get(a, a) for a in aws})

    # ------------------------------------------------------------- state

    def max_minutes(self) -> int:
        rg = self._rg()
        try:
            return int((rg.tags or {}).get(MAX_MINUTES_TAG, 30)) if rg else 30
        except ValueError:
            return 30

    def read_state(self) -> dict:
        rg = self._rg()
        if not rg:
            return {}
        out = {}
        for key, value in (rg.tags or {}).items():
            if not key.startswith(STATE_TAG_PREFIX):
                continue
            try:
                vm, cmd, started, expires, seconds = value.split("|")
            except ValueError:
                continue
            out[key[len(STATE_TAG_PREFIX):]] = {
                "command_id": cmd,
                "instance_id": vm,
                "started": _iso(started),
                "expires": _iso(expires),
                "seconds": int(seconds),
            }
        return out

    def write_state(self, state: dict) -> None:
        """
        Rewrite the per-scenario tags on the lab resource group, keeping every
        other tag. Never creates the resource group: before the lab exists
        there are no hosts and so nothing to track.
        """
        rg = self._rg()
        if not rg:
            return
        tags = {k: v for k, v in (rg.tags or {}).items() if not k.startswith(STATE_TAG_PREFIX)}
        for sid, e in state.items():
            started = _epoch(datetime.fromisoformat(e["started"]))
            expires = _epoch(datetime.fromisoformat(e["expires"]))
            tags[STATE_TAG_PREFIX + sid] = (
                f'{e["instance_id"]}|{e["command_id"]}|{started}|{expires}|{e.get("seconds", 0)}'
            )
        try:
            self.rm.resource_groups.update(self.stack, {"tags": tags})
        except AzureError:
            pass

    # ------------------------------------------------------------- hosts

    def _hosts(self) -> list[dict]:
        if not self._rg():
            return []
        try:
            vms = list(self.compute.virtual_machines.list(self.stack))
        except AzureError:
            return []
        out = []
        for vm in vms:
            tags = vm.tags or {}
            if tags.get(LAB_TAG) != "true" or tags.get("nudgebee-finding"):
                continue
            running = agent_ready = False
            try:
                view = self.compute.virtual_machines.instance_view(self.stack, vm.name)
                codes = [s.code or "" for s in (view.statuses or [])]
                running = "PowerState/running" in codes
                agent = view.vm_agent
                if agent and agent.statuses:
                    agent_ready = (agent.statuses[0].display_status or "").lower() == "ready"
            except AzureError:
                pass
            if not running:
                continue
            out.append(
                {
                    "instance_id": vm.name,
                    "name": vm.name,
                    "role": tags.get("scenario-role", "") or tags.get("nb-service", ""),
                    "service": tags.get("nb-service", ""),
                    "type": vm.hardware_profile.vm_size if vm.hardware_profile else None,
                    "az": (vm.zones or [None])[0],
                    "location": vm.location,
                    "private_ip": None,
                    # named for the AWS field the UI already reads; here it
                    # means "the Azure VM agent is ready to take Run Commands"
                    "ssm_online": agent_ready,
                }
            )
        return sorted(out, key=lambda h: h["name"])

    def lab_hosts(self) -> list[dict]:
        # Every UI refresh asks for hosts several times; instance views are
        # one call per VM, so hold the answer for a few seconds.
        return cached("hosts", 5, self._hosts)

    def _fired_rules(self) -> dict[str, str]:
        """
        alert rule name (lower-case) -> when it fired, for rules whose MOST
        RECENT alert is still Fired.

        Only the latest alert per rule counts. An older alert can stay Fired
        indefinitely - Azure never resolves it if the rule's criteria changed
        underneath it, as happens on a redeploy - and treating any Fired alert
        as current would pin the rule at ALARM for good.
        """
        try:
            from azure.mgmt.alertsmanagement import AlertsManagementClient
        except ImportError:
            return {}
        try:
            client = AlertsManagementClient(self.cred, self.subscription)
            latest: dict[str, tuple] = {}
            for a in client.alerts.get_all(target_resource_group=self.stack, time_range="1d"):
                ess = a.properties.essentials
                rule = (ess.alert_rule or "").rstrip("/").split("/")[-1].lower()
                started = ess.start_date_time
                if not started:
                    continue
                if rule not in latest or started > latest[rule][0]:
                    latest[rule] = (started, ess.monitor_condition)
            return {rule: started.isoformat() for rule, (started, cond) in latest.items()
                    if (cond or "").lower() == "fired"}
        except AzureError:
            return {}

    def alarm_map(self) -> dict[str, dict]:
        """alert rule name -> alarm, in the same shape (and states) as CloudWatch."""
        if not self._rg():
            return {}
        try:
            rules = list(self.monitor.metric_alerts.list_by_resource_group(self.stack))
        except AzureError:
            return {}
        fired = self._fired_rules()
        out = {}
        for r in rules:
            if not r.name.startswith(f"{self.stack}-host-"):
                continue
            crit = (getattr(r.criteria, "all_of", None) or [None])[0]
            ns = getattr(crit, "metric_namespace", "") or ""
            metric = getattr(crit, "metric_name", "") or ""
            if not r.enabled:
                state = "INSUFFICIENT_DATA"
            elif r.name.lower() in fired:
                state = "ALARM"
            else:
                state = "OK"
            out[r.name] = {
                "name": r.name,
                "state": state,
                "updated": fired.get(r.name.lower()),
                "metric": f"{ns}/{metric}",
                "threshold": getattr(crit, "threshold", None),
            }
        return out

    def stack_info(self) -> dict:
        if not self._rg():
            return {"deployed": False, "status": None, "healthy": False, "created": None}
        try:
            d = self.rm.deployments.get(self.stack, "lab")
        except AzureError:
            return {"deployed": False, "status": "resource group exists, no lab deployment",
                    "healthy": False, "created": None}
        status = d.properties.provisioning_state
        ts = d.properties.timestamp
        return {
            "deployed": True,
            "status": status,
            "healthy": status == "Succeeded",
            "created": ts.isoformat() if ts else None,
        }

    def _run_commands(self, vm: str) -> list:
        """
        This app's Run Commands on one VM, each with its execution state.

        Listing does NOT return the instance view, whatever `expand` says -
        every item comes back with instance_view None - so each one this app
        created is fetched on its own. Without that, finished commands look
        unfinished, pruning never happens, and the VM hits its cap of 25.
        """
        ops = self.compute.virtual_machine_run_commands
        try:
            names = [rc.name for rc in ops.list_by_virtual_machine(self.stack, vm)
                     if rc.name.startswith(RUN_PREFIX)]
        except AzureError:
            return []
        out = []
        for name in names:
            try:
                out.append(ops.get_by_virtual_machine(self.stack, vm, name, expand="instanceView"))
            except AzureError:
                pass
        return out

    def recent_runs(self) -> dict[str, dict]:
        """Last Run Command per scenario, read back from Azure rather than local state."""
        out: dict[str, dict] = {}
        for host in self.lab_hosts():
            for rc in self._run_commands(host["name"]):
                label = (rc.tags or {}).get(LABEL_TAG, "")
                if not label or ":" in label or label == "reset":
                    continue
                view = rc.instance_view
                started = view.start_time if view else None
                prev = out.get(label)
                if prev and prev["requested_at"] and started and prev["requested_at"] >= started.isoformat():
                    continue
                out[label] = {
                    "command_id": rc.name,
                    "status": (view.execution_state if view else None) or rc.provisioning_state,
                    "requested_at": started.isoformat() if started else None,
                }
        return out

    def metric_warning(self, metric: str) -> str | None:
        if "Azure Monitor Agent" in metric or "CWAgent DiskUtilization" in metric:
            return "alarm depends on the Azure Monitor Agent publishing this metric"
        if "custom metric published by the VM" in metric:
            return ("alarm exists only if the lab was deployed with publishHostMetrics "
                    "(needs a deployer who can assign roles)")
        return None

    # Measured on the lab: CPU pinned from 06:37, alert fired 06:41. Azure
    # alerts trail CloudWatch by about four minutes - a five-minute window
    # (the shortest that is not twitchy) plus metric ingestion. Run long
    # enough that the alert fires while the cause is still there for
    # NudgeBee to find, with three minutes to spare.
    ALERT_LAG = 240
    ALERT_MARGIN = 180

    def timing(self, scenario: dict) -> tuple[int, int | None]:
        """(default run seconds, seconds until the alert), adjusted for Azure's lag."""
        seconds = scenario.get("default_seconds", 300)
        expect = scenario.get("expect_alarm_secs")
        if not expect or not scenario.get("signal"):
            return seconds, expect
        expect += self.ALERT_LAG
        return max(seconds, expect + self.ALERT_MARGIN), expect

    def describe_metric(self, metric: str | None) -> str | None:
        if not metric:
            return metric
        for aws, azure in METRIC_MAP:
            if metric.startswith(aws):
                return azure
        return metric

    # ------------------------------------------------------------- commands

    def _prune(self, vm: str, keep: set[str]) -> None:
        """
        A VM holds at most 25 managed Run Commands, and finished ones are not
        removed automatically. Delete the finished ones this app created so a
        busy demo never hits the cap - except the newest run of each scenario,
        which is the panel's "last run" and the only record of its script once
        it has ended. Fire-and-forget: nothing waits on it.
        """
        commands = self._run_commands(vm)
        newest: dict[str, tuple] = {}
        for rc in commands:
            label = (rc.tags or {}).get(LABEL_TAG, "")
            started = (rc.instance_view.start_time if rc.instance_view else None)
            key = (started.isoformat() if started else "", rc.name)
            if label and (label not in newest or key > newest[label][0]):
                newest[label] = (key, rc.name)
        keep = keep | {name for _, name in newest.values()}
        for rc in commands:
            if rc.name in keep:
                continue
            state = ((rc.instance_view.execution_state if rc.instance_view else "") or "").lower()
            if state in TERMINAL:
                try:
                    self.compute.virtual_machine_run_commands.begin_delete(self.stack, vm, rc.name)
                except AzureError:
                    pass

    def send(self, instance_id: str, script: str, label: str, run_seconds: int = 0) -> str:
        """
        Run a shell script on one VM as a managed Run Command. Async, so the
        call returns once Azure has accepted it rather than when the script
        ends - a scenario sleeps for minutes. Returns the Run Command name,
        which cancel() deletes.
        """
        host = next((h for h in self.lab_hosts() if h["instance_id"] == instance_id), None)
        location = host["location"] if host else self.region
        keep = {e["command_id"] for e in self.read_state().values()}
        self._prune(instance_id, keep)

        slug = "".join(c if c.isalnum() else "-" for c in label).strip("-")[:40]
        name = f"{RUN_PREFIX}{slug}-{_epoch(now())}"
        command = VirtualMachineRunCommand(
            location=location,
            source=VirtualMachineRunCommandScriptSource(script=script),
            async_execution=True,
            # the script bounds itself with `timeout`; this is a backstop
            timeout_in_seconds=(run_seconds + 300) if run_seconds else 600,
            tags={LAB_TAG: "true", LABEL_TAG: label},
        )
        try:
            self.compute.virtual_machine_run_commands.begin_create_or_update(
                self.stack, instance_id, name, command
            )
        except HttpResponseError as exc:
            raise HTTPException(502, f"run command failed: {exc.message}") from exc
        except AzureError as exc:
            raise HTTPException(502, f"run command failed: {exc}") from exc
        return name

    def cancel(self, entry: dict) -> None:
        """
        Deleting a managed Run Command terminates it if it is still running.

        Only delete one that IS still running. At expiry the script has
        normally already ended on its own `timeout`, and deleting it then
        cancels nothing - it only erases the panel's last-run record.
        """
        ops = self.compute.virtual_machine_run_commands
        try:
            rc = ops.get_by_virtual_machine(
                self.stack, entry["instance_id"], entry["command_id"], expand="instanceView"
            )
            state = ((rc.instance_view.execution_state if rc.instance_view else "") or "").lower()
            if state in TERMINAL:
                return
        except AzureError:
            pass  # unknown state: delete, the safe direction for a cancel
        try:
            ops.begin_delete(
                self.stack, entry["instance_id"], entry["command_id"]
            )
        except AzureError:
            pass

    # ------------------------------------------------------------- cloud-config faults
    # No Azure control-plane scenarios yet. The app refuses `kind: aws` ones
    # before they get here; these exist so the interface is the same.

    def apply_action(self, scenario_id: str, action: str, params: dict) -> dict:
        raise HTTPException(412, f"{scenario_id}: no Azure cloud action {action!r}")

    def undo_action(self, action: str, undo: dict) -> None:
        raise HTTPException(412, f"no Azure cloud action {action!r} to undo")

    # ------------------------------------------------------------- findings

    def findings_present(self, tags: list[str]) -> dict[str, list]:
        present: dict[str, list] = {t: [] for t in tags}
        rg = self.stack_name_for("waste")
        try:
            resources = self.rm.resources.list_by_resource_group(
                rg, filter="tagName eq 'nudgebee-finding'"
            )
            for r in resources:
                tag = (r.tags or {}).get("nudgebee-finding")
                if tag in present:
                    present[tag].append({"id": r.name, "state": r.type.split("/")[-1]})
        except AzureError:
            pass
        return present

    # ------------------------------------------------------------- setup / deploy

    def setup_info(self) -> dict:
        return {
            "suggested_vpc": None,
            "suggested_subnet": None,
            "deploy_command": "CLOUD=azure ./scripts/deploy.sh",
            "waste_command": "CLOUD=azure ./scripts/deploy.sh waste",
            "manual_command": (
                f"az group create --name {self.stack} --location {self.region} \\\n"
                f"  --tags {LAB_TAG}=true {MAX_MINUTES_TAG}=30\n"
                f"az deployment group create --resource-group {self.stack} \\\n"
                "  --name lab --template-file infra/azure/lab.bicep \\\n"
                "  --parameters sshPublicKey=\"$(cat ~/.ssh/id_rsa.pub)\""
            ),
            "teardown_command": f"az group delete --name {self.stack} --yes",
            "deploy_summary": "Linux VMs, Azure Monitor alerts and an isolated virtual network",
        }

    def _compile(self, tier: str) -> dict:
        """ARM only accepts JSON; the az CLI carries the Bicep compiler."""
        az = shutil.which("az")
        if not az:
            raise HTTPException(
                412, "deploying from the UI needs the az CLI - or run CLOUD=azure ./scripts/deploy.sh"
            )
        try:
            out = subprocess.run(
                [az, "bicep", "build", "--file", str(self.template_path(tier)), "--stdout"],
                capture_output=True, text=True, timeout=180,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise HTTPException(502, f"bicep build failed: {exc}") from exc
        if out.returncode != 0:
            raise HTTPException(502, f"bicep build failed: {out.stderr.strip()[:500]}")
        return json.loads(out.stdout)

    def _existing_ssh_key(self, rg: str) -> str | None:
        """Re-deploying must reuse the VMs' key: Azure refuses to change it."""
        try:
            for vm in self.compute.virtual_machines.list(rg):
                linux = vm.os_profile.linux_configuration if vm.os_profile else None
                keys = linux.ssh.public_keys if linux and linux.ssh else None
                if keys:
                    return keys[0].key_data
        except AzureError:
            pass
        return None

    @staticmethod
    def _throwaway_ssh_key() -> str:
        """
        Azure requires an admin credential on a Linux VM. Nothing inbound is
        open and scenarios arrive through Run Command, so the lab never needs
        it: generate a key, keep only the public half, discard the private one.
        """
        keygen = shutil.which("ssh-keygen")
        if not keygen:
            raise HTTPException(412, "ssh-keygen not found - needed to satisfy Azure's VM admin key")
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "lab"
            subprocess.run(
                [keygen, "-q", "-t", "rsa", "-b", "3072", "-N", "", "-C", "nudgebee-scenario-lab",
                 "-f", str(key)],
                check=True, capture_output=True, timeout=30,
            )
            return (key.with_suffix(".pub")).read_text().strip()

    def deploy(self, tier: str, vpc_id: str | None, subnet_id: str | None) -> str:
        if vpc_id or subnet_id:
            raise HTTPException(400, "bringing your own network is not supported on Azure yet")
        rg = self.stack_name_for(tier)
        template = self._compile(tier)
        # both tiers create VMs, and both need an admin key Azure will accept
        params = {"sshPublicKey": {"value": self._existing_ssh_key(rg) or self._throwaway_ssh_key()}}
        try:
            self.rm.resource_groups.create_or_update(
                rg, {"location": self.region, "tags": {LAB_TAG: "true", MAX_MINUTES_TAG: "30"}}
            )
            if tier == "lab":
                # The VMs' own metric publishing needs a role assignment, which
                # only a deployer who can assign roles may create. Checked after
                # the group exists: permissions are read at a scope, and the
                # group is that scope. Off when it cannot be confirmed - a
                # deployment that fails on the role is worse than one without
                # those two alerts.
                can_assign = self._check(("Microsoft.Authorization/roleAssignments/write",))
                params["publishHostMetrics"] = {
                    "value": can_assign.get("Microsoft.Authorization/roleAssignments/write") is True
                }
            self.rm.deployments.begin_create_or_update(
                rg, tier,
                {"properties": {"mode": "Incremental", "template": template, "parameters": params}},
            )
        except HttpResponseError as exc:
            raise HTTPException(502, f"deployment failed to start: {exc.message}") from exc
        forget("identity")
        return rg

    def deploy_status(self, tier: str) -> dict:
        rg_name = self.stack_name_for(tier)
        try:
            rg = self.rm.resource_groups.get(rg_name)
        except ResourceNotFoundError:
            return {"exists": False, "status": None, "events": [], "in_progress": False}
        except AzureError:
            return {"exists": False, "status": None, "events": [], "in_progress": False}

        if (rg.properties.provisioning_state or "").lower() == "deleting":
            return {"exists": True, "status": "Deleting", "in_progress": True,
                    "complete": False, "failed": False, "events": []}
        try:
            d = self.rm.deployments.get(rg_name, tier)
        except AzureError:
            return {"exists": True, "status": "Accepted", "in_progress": True,
                    "complete": False, "failed": False, "events": []}

        events = []
        try:
            for op in list(self.rm.deployment_operations.list(rg_name, tier))[:12]:
                p = op.properties
                target = p.target_resource
                msg = None
                if p.status_message is not None:
                    err = getattr(p.status_message, "error", None)
                    msg = getattr(err, "message", None) or str(p.status_message)
                events.append({
                    "time": p.timestamp.isoformat() if p.timestamp else None,
                    "resource": target.resource_name if target else p.provisioning_operation,
                    "type": target.resource_type if target else None,
                    "status": p.provisioning_state,
                    "reason": msg,
                })
        except AzureError:
            pass

        status = d.properties.provisioning_state or ""
        return {
            "exists": True,
            "status": status,
            "in_progress": status in ("Accepted", "Running", "Creating", "Updating", "Validating"),
            "complete": status == "Succeeded",
            "failed": status in ("Failed", "Canceled"),
            "events": events,
        }

    def teardown(self, tier: str) -> str:
        rg = self.stack_name_for(tier)
        try:
            self.rm.resource_groups.begin_delete(rg)
        except AzureError as exc:
            raise HTTPException(502, f"resource group delete failed: {exc}") from exc
        return rg
