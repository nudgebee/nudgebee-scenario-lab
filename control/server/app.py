"""
NudgeBee Scenario Lab - control app.

Runs locally, uses the operator's own AWS credentials, binds to loopback.
Nothing is hosted by NudgeBee and nothing inbound is opened to the VPC.

Safety model, in order of precedence:
  1. every scenario command is wrapped in `timeout`, so it dies on its own
  2. the API refuses a duration above the stack's max_minutes ceiling
  3. a background sweeper cancels anything that outlived its expiry
  4. /api/reset cancels everything and runs the per-scenario cleanup

The API deliberately reports *readiness* per scenario rather than just offering
a button: which account it will run against, whether the caller holds the IAM
actions, whether the host is reachable, and whether the metric the alarm needs
is actually being published. A greyed-out button with a reason beats a run that
fails halfway.
"""

import json
import os
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import boto3
import yaml
from botocore.config import Config
from botocore.exceptions import ClientError, NoCredentialsError
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

STACK = os.environ.get("SCENARIO_LAB_STACK", "nudgebee-scenario-lab")
REGION = os.environ.get("AWS_REGION", "us-east-1")
CATALOGUE = Path(os.environ.get("CATALOGUE_PATH", "/app/scenarios/catalogue.yaml"))
WEB_DIR = Path(os.environ.get("WEB_DIR", "/app/web"))
INFRA_DIR = Path(os.environ.get("INFRA_DIR", "/app/infra/cloudformation"))

DEPLOY_ACTIONS = (
    "cloudformation:CreateStack", "cloudformation:DeleteStack",
    "ec2:RunInstances", "ec2:CreateVpc", "iam:CreateRole", "iam:PassRole",
    "cloudwatch:PutMetricAlarm", "ssm:PutParameter",
)


def template_path(tier: str) -> Path:
    if tier not in ("lab", "waste"):
        raise HTTPException(400, "tier must be lab or waste")
    for base in (INFRA_DIR, Path(__file__).resolve().parents[2] / "infra" / "cloudformation"):
        p = base / f"{tier}.yaml"
        if p.exists():
            return p
    raise HTTPException(500, f"{tier}.yaml not found - set INFRA_DIR")


def stack_name_for(tier: str) -> str:
    return STACK if tier == "lab" else f"{STACK}-waste"

# The page polls /api/setup, /api/scenarios, /api/alarms and /api/findings on a
# timer, and most of those make two AWS calls each. FastAPI runs these sync
# handlers on a 40-thread pool, but botocore defaults to 10 pooled connections
# per client - so past ~10 concurrent calls the rest queue on the connection
# pool and the UI looks dead while the process is healthy and idle. Raising the
# pool to match the thread pool is the fix; the timeouts stop a single wedged
# AWS call from holding a connection forever.
_boto = Config(
    region_name=REGION,
    max_pool_connections=50,
    connect_timeout=5,
    read_timeout=20,
    retries={"max_attempts": 3, "mode": "standard"},
)

ssm = boto3.client("ssm", config=_boto)
ec2 = boto3.client("ec2", config=_boto)
cw = boto3.client("cloudwatch", config=_boto)
sts = boto3.client("sts", config=_boto)
iam = boto3.client("iam", config=_boto)
cfn = boto3.client("cloudformation", config=_boto)

app = FastAPI(title="NudgeBee Scenario Lab")

STATE_PARAM = f"/nudgebee-scenario-lab/{STACK}/active"
MAX_PARAM = f"/nudgebee-scenario-lab/{STACK}/max_minutes"
CMD_PREFIX = "nudgebee-scenario-lab:"

_cache: dict = {}
_cache_lock = threading.Lock()


def cached(key: str, ttl: int, producer):
    """Small TTL cache - IAM simulation and identity lookups are slow and static."""
    with _cache_lock:
        hit = _cache.get(key)
        if hit and time.time() - hit[0] < ttl:
            return hit[1]
    value = producer()
    with _cache_lock:
        _cache[key] = (time.time(), value)
    return value


def now() -> datetime:
    return datetime.now(timezone.utc)


# ----------------------------------------------------------------- identity

def _identity() -> dict:
    try:
        ident = sts.get_caller_identity()
    except (ClientError, NoCredentialsError) as exc:
        return {"error": str(exc)}
    arn = ident["Arn"]
    account = ident["Account"]

    alias = None
    try:
        aliases = iam.list_account_aliases().get("AccountAliases", [])
        alias = aliases[0] if aliases else None
    except ClientError:
        pass

    # SimulatePrincipalPolicy wants the role ARN, not the assumed-role session.
    policy_arn = arn
    if ":assumed-role/" in arn:
        role = arn.split("/")[1]
        policy_arn = f"arn:aws:iam::{account}:role/{role}"

    return {
        "account": account,
        "account_alias": alias,
        "arn": arn,
        "policy_source_arn": policy_arn,
        "principal": arn.split("/")[-1],
    }


def identity() -> dict:
    return cached("identity", 300, _identity)


def _simulate(actions: tuple[str, ...]) -> dict[str, bool]:
    """True/False per action. Fails open with None if simulation is denied."""
    ident = identity()
    src = ident.get("policy_source_arn")
    if not src:
        return {}
    try:
        res = iam.simulate_principal_policy(
            PolicySourceArn=src, ActionNames=list(actions)
        )["EvaluationResults"]
    except ClientError:
        return {}
    return {r["EvalActionName"]: r["EvalDecision"] == "allowed" for r in res}


def permissions(actions: tuple[str, ...]) -> dict[str, bool]:
    return cached("perm:" + ",".join(sorted(actions)), 300, lambda: _simulate(actions))


# ----------------------------------------------------------------- catalogue

def load_doc() -> dict:
    with CATALOGUE.open() as fh:
        return yaml.safe_load(fh)


def load_catalogue() -> dict:
    return {s["id"]: s for s in load_doc().get("scenarios", [])}


def load_findings() -> list:
    return load_doc().get("findings", [])


def max_minutes() -> int:
    try:
        return int(ssm.get_parameter(Name=MAX_PARAM)["Parameter"]["Value"])
    except ClientError:
        return 30


def read_state() -> dict:
    try:
        raw = ssm.get_parameter(Name=STATE_PARAM)["Parameter"]["Value"]
        return json.loads(raw or "{}")
    except (ClientError, json.JSONDecodeError):
        return {}


def write_state(state: dict) -> None:
    """
    Update the state parameter, but NEVER create it.

    The parameter is declared by lab.yaml. If this app creates it first -
    which it will, if anyone opens the UI before deploying - CloudFormation's
    AWS::EarlyValidation::ResourceExistenceCheck refuses the whole stack with
    "Validation failed with 1 error(s)" and rolls back, having created nothing.
    That failure names no resource, so it is genuinely hard to diagnose.

    Before the stack exists there are no hosts and therefore no scenarios to
    track, so skipping the write costs nothing.
    """
    try:
        ssm.get_parameter(Name=STATE_PARAM)
    except ClientError:
        return  # not deployed yet - do not create it
    try:
        ssm.put_parameter(
            Name=STATE_PARAM, Value=json.dumps(state), Type="String", Overwrite=True
        )
    except ClientError:
        pass


# ----------------------------------------------------------------- hosts

def lab_hosts() -> list[dict]:
    try:
        resp = ec2.describe_instances(
            Filters=[
                {"Name": "tag:nudgebee-scenario-lab", "Values": ["true"]},
                {"Name": "instance-state-name", "Values": ["running"]},
            ]
        )
    except ClientError:
        return []
    online = set()
    try:
        for i in ssm.describe_instance_information().get("InstanceInformationList", []):
            if i.get("PingStatus") == "Online":
                online.add(i["InstanceId"])
    except ClientError:
        pass

    out = []
    for res in resp.get("Reservations", []):
        for inst in res.get("Instances", []):
            tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
            # waste-tier resources are tagged too - only include scenario hosts
            if tags.get("nudgebee-finding"):
                continue
            iid = inst["InstanceId"]
            out.append(
                {
                    "instance_id": iid,
                    "name": tags.get("Name", iid),
                    # services-tier hosts carry nb-service (order, payment,
                    # inventory, database); the original lab hosts carry neither
                    "role": tags.get("scenario-role", "") or tags.get("nb-service", ""),
                    # Two tiers spell the same idea differently: services.json
                    # tags nb-service, db.yaml tags scenario-role. Both are kept
                    # SEPARATE on purpose. Collapsing them into one field made
                    # both database hosts answer to target_service: database, and
                    # start() takes the first match in describe_instances order -
                    # which is not stable. database_outage then stopped PostgreSQL
                    # on the lab database, which nothing depends on, so the
                    # cascade it exists to demonstrate never happened and the
                    # incident's impact was legitimately empty.
                    "service": tags.get("nb-service", ""),
                    "service_alias": tags.get("scenario-role", ""),
                    "type": inst.get("InstanceType"),
                    "az": inst.get("Placement", {}).get("AvailabilityZone"),
                    "private_ip": inst.get("PrivateIpAddress"),
                    "ssm_online": iid in online,
                }
            )
    return sorted(out, key=lambda h: h["name"])


def alarm_map() -> dict[str, dict]:
    """signal-suffix -> alarm, for the host prefix used by the lab stack."""
    try:
        alarms = cw.describe_alarms(AlarmNamePrefix=f"{STACK}-host-", MaxRecords=100)
    except ClientError:
        return {}
    out = {}
    for a in alarms.get("MetricAlarms", []):
        out[a["AlarmName"]] = {
            "name": a["AlarmName"],
            "state": a["StateValue"],
            "updated": a["StateUpdatedTimestamp"].isoformat()
            if a.get("StateUpdatedTimestamp")
            else None,
            "metric": f'{a.get("Namespace","")}/{a.get("MetricName","")}',
            "threshold": a.get("Threshold"),
        }
    return out


def stack_info() -> dict:
    try:
        s = cfn.describe_stacks(StackName=STACK)["Stacks"][0]
        return {
            "deployed": True,
            "status": s["StackStatus"],
            "created": s["CreationTime"].isoformat(),
        }
    except ClientError:
        return {"deployed": False, "status": None, "created": None}


def recent_runs() -> dict[str, dict]:
    """Last SSM invocation per scenario, read back from AWS rather than local state."""
    out: dict[str, dict] = {}
    try:
        cmds = ssm.list_commands(MaxResults=50).get("Commands", [])
    except ClientError:
        return out
    for c in cmds:
        comment = c.get("Comment") or ""
        if not comment.startswith(CMD_PREFIX):
            continue
        sid = comment[len(CMD_PREFIX):].strip()
        if sid in out:
            continue  # list_commands is newest-first
        out[sid] = {
            "command_id": c.get("CommandId"),
            "status": c.get("Status"),
            "requested_at": c["RequestedDateTime"].isoformat()
            if c.get("RequestedDateTime")
            else None,
        }
    return out


# ----------------------------------------------------------------- readiness

def readiness(scenario: dict, hosts: list[dict], perms: dict[str, bool],
              alarms: dict[str, dict], host_id: str | None) -> dict:
    """Everything the UI needs to say 'you can run this' or exactly why not."""
    blockers: list[str] = []
    warnings: list[str] = []

    req = scenario.get("requires") or {}
    for action in req.get("iam") or []:
        if perms.get(action) is False:
            blockers.append(f"missing IAM permission: {action}")

    if not hosts:
        blockers.append("no scenario hosts deployed")
    else:
        host = next((h for h in hosts if h["instance_id"] == host_id), hosts[0])
        if not host["ssm_online"]:
            blockers.append(f"{host['name']} is not reachable via SSM")

    for b in req.get("binaries") or []:
        warnings.append(f"needs `{b}` on the host (installed by the lab AMI bootstrap)")

    metric = req.get("metric")
    if metric and "CWAgent" in metric:
        warnings.append("alarm depends on the CloudWatch agent publishing this metric")
    if req.get("egress"):
        warnings.append("host needs outbound internet for this scenario")

    signal = scenario.get("signal")
    matched = [a for n, a in alarms.items() if signal and n.endswith(signal)]
    return {
        "ready": not blockers,
        "blockers": blockers,
        "warnings": warnings,
        "alarm": matched[0] if matched else None,
        "alarm_count": len(matched),
    }


# ----------------------------------------------------------------- API

class StartRequest(BaseModel):
    scenario_id: str
    instance_id: str | None = None
    seconds: int | None = None


@app.get("/api/context")
def context():
    ident = identity()
    hosts = lab_hosts()
    return {
        "stack": STACK,
        "region": REGION,
        "identity": ident,
        "stack_info": stack_info(),
        "hosts": hosts,
        "max_minutes": max_minutes(),
        "can_simulate": bool(permissions(("sts:GetCallerIdentity",))),
    }


@app.get("/api/scenarios")
def list_scenarios(host: str | None = None):
    cat = load_catalogue()
    state = read_state()
    hosts = lab_hosts()
    alarms = alarm_map()
    runs = recent_runs()

    all_actions = tuple(
        sorted({a for s in cat.values() for a in ((s.get("requires") or {}).get("iam") or [])})
    )
    perms = permissions(all_actions) if all_actions else {}

    out = []
    for sid, s in cat.items():
        running = state.get(sid)
        r = readiness(s, hosts, perms, alarms, host)
        out.append(
            {
                "id": sid,
                "name": s["name"],
                "tier": s.get("tier", "lab"),
                "signal": s.get("signal"),
                "default_seconds": s.get("default_seconds", 300),
                "expect_alarm_secs": s.get("expect_alarm_secs"),
                "teaches": (s.get("teaches") or "").strip(),
                "naive_answer": s.get("naive_answer"),
                "requires": s.get("requires") or {},
                "running": bool(running),
                "started": running.get("started") if running else None,
                "expires": running.get("expires") if running else None,
                "host": running.get("instance_id") if running else None,
                "last_run": runs.get(sid),
                **r,
            }
        )

    return {
        "stack": STACK,
        "region": REGION,
        "identity": identity(),
        "stack_info": stack_info(),
        "max_minutes": max_minutes(),
        "hosts": hosts,
        "permissions": perms,
        "scenarios": sorted(out, key=lambda s: s["name"]),
        "findings": load_findings(),
    }


@app.get("/api/alarms")
def alarms_endpoint():
    return {"alarms": sorted(alarm_map().values(), key=lambda a: a["name"])}


@app.get("/api/findings")
def findings_endpoint():
    """Waste-tier resources actually present in the account, matched to the catalogue."""
    declared = {f["tag"]: f for f in load_findings()}
    present: dict[str, list] = {t: [] for t in declared}
    try:
        resp = ec2.describe_instances(
            Filters=[{"Name": "tag:nudgebee-finding", "Values": list(declared)}]
        )
        for res in resp.get("Reservations", []):
            for inst in res.get("Instances", []):
                tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
                tag = tags.get("nudgebee-finding")
                if tag in present:
                    present[tag].append(
                        {"id": inst["InstanceId"], "state": inst["State"]["Name"]}
                    )
    except ClientError:
        pass
    try:
        vols = ec2.describe_volumes(
            Filters=[{"Name": "tag:nudgebee-finding", "Values": list(declared)}]
        )
        for v in vols.get("Volumes", []):
            tags = {t["Key"]: t["Value"] for t in v.get("Tags", [])}
            tag = tags.get("nudgebee-finding")
            if tag in present:
                present[tag].append({"id": v["VolumeId"], "state": v["State"]})
    except ClientError:
        pass
    try:
        sgs = ec2.describe_security_groups(
            Filters=[{"Name": "tag:nudgebee-finding", "Values": list(declared)}]
        )
        for g in sgs.get("SecurityGroups", []):
            tags = {t["Key"]: t["Value"] for t in g.get("Tags", [])}
            tag = tags.get("nudgebee-finding")
            if tag in present:
                present[tag].append({"id": g["GroupId"], "state": "present"})
    except ClientError:
        pass

    return {
        "findings": [
            {**f, "deployed": bool(present.get(f["tag"])), "resources": present.get(f["tag"], [])}
            for f in load_findings()
        ]
    }


def lab_security_group(name_suffix: str) -> str:
    """Resolve a lab security group by its Name tag. Returns the group id.

    Looked up rather than configured because the stack is redeployable: a hardcoded
    id survives exactly until someone rebuilds the lab, and then the scenario
    revokes a rule on a group that no longer exists - or worse, on one that has been
    reissued to something else.
    """
    resp = ec2.describe_security_groups(
        Filters=[
            {"Name": "tag:nudgebee-scenario-lab", "Values": ["true"]},
            {"Name": "tag:Name", "Values": [name_suffix]},
        ]
    )
    groups = resp.get("SecurityGroups", [])
    if len(groups) != 1:
        raise HTTPException(
            412,
            f"expected exactly one security group tagged Name={name_suffix}, found "
            f"{len(groups)} - is the load balancer tier deployed "
            f"(infra/cloudformation/lb.yaml)?",
        )
    return groups[0]["GroupId"]


def revoke_alb_ingress(params: dict) -> dict:
    """Remove the ALB -> service ingress rule and return what is needed to restore it.

    The undo is computed BEFORE the change and stored in state, not reconstructed at
    cleanup time. Reconstructing it means re-reading a group whose rule has already
    been deleted and guessing what it used to be; if that guess is wrong the lab is
    left broken in a way nobody notices until the next demo.
    """
    host_sg = lab_security_group(params.get("host_sg_name", f"{STACK}-hosts"))
    alb_sg = lab_security_group(params.get("alb_sg_name", f"{STACK}-alb"))
    port = int(params.get("port", 8081))

    permission = {
        "IpProtocol": "tcp",
        "FromPort": port,
        "ToPort": port,
        "UserIdGroupPairs": [{"GroupId": alb_sg}],
    }
    try:
        ec2.revoke_security_group_ingress(GroupId=host_sg, IpPermissions=[permission])
    except ClientError as exc:
        raise HTTPException(502, f"failed to revoke ALB ingress: {exc}") from exc

    return {"host_sg": host_sg, "alb_sg": alb_sg, "port": port}


def restore_alb_ingress(undo: dict) -> None:
    """Put the rule back. Idempotent: a duplicate rule is success, not a failure."""
    # Description belongs to the group PAIR, not to the permission. At the
    # permission level botocore rejects it as an unknown parameter, and the
    # failure surfaces as a 500 on stop - which is the one code path that must
    # not fail, because nothing else puts the rule back.
    permission = {
        "IpProtocol": "tcp",
        "FromPort": undo["port"],
        "ToPort": undo["port"],
        "UserIdGroupPairs": [
            {
                "GroupId": undo["alb_sg"],
                "Description": "ALB to order service - restored by scenario cleanup",
            }
        ],
    }
    try:
        ec2.authorize_security_group_ingress(
            GroupId=undo["host_sg"], IpPermissions=[permission]
        )
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "InvalidPermission.Duplicate":
            return
        raise


# Cloud-config faults, by name. Each returns the state needed to undo it.
CLOUD_SCENARIOS = {
    "revoke_alb_ingress": (revoke_alb_ingress, restore_alb_ingress),
}


def start_cloud_scenario(scenario_id: str, scenario: dict, seconds: int, state: dict):
    action = scenario.get("action")
    if action not in CLOUD_SCENARIOS:
        raise HTTPException(400, f"{scenario_id}: unknown cloud action {action!r}")
    apply_fn, _ = CLOUD_SCENARIOS[action]

    undo = apply_fn(scenario.get("params") or {})

    started = now()
    state[scenario_id] = {
        "kind": "aws",
        "action": action,
        "undo": undo,
        # No instance: the fault is in the network, not on a machine. Recorded
        # explicitly so the sweeper and /api/stop do not try to cancel an SSM
        # command that was never sent.
        "instance_id": None,
        "command_id": None,
        "started": started.isoformat(),
        "expires": (started + timedelta(seconds=seconds + 60)).isoformat(),
        "seconds": seconds,
    }
    write_state(state)
    return {"started": scenario_id, "instance_id": None, "seconds": seconds, "kind": "aws"}


@app.post("/api/start")
def start(req: StartRequest):
    cat = load_catalogue()
    if req.scenario_id not in cat:
        raise HTTPException(404, f"unknown scenario {req.scenario_id}")
    scenario = cat[req.scenario_id]

    seconds = int(req.seconds or scenario.get("default_seconds", 300))
    ceiling = max_minutes() * 60
    if seconds > ceiling:
        raise HTTPException(400, f"duration {seconds}s exceeds the lab ceiling of {ceiling}s")

    hosts = lab_hosts()
    if not hosts:
        raise HTTPException(412, "no scenario hosts found - is the lab stack deployed?")
    # Cascade scenarios only make sense on one specific host - stopping "order"
    # has to happen on the order host, whatever is selected in the UI. Those
    # scenarios declare target_service and we resolve the host ourselves.
    target = scenario.get("target_service")
    if target:
        # nb-service wins over scenario-role, and it is not a style preference:
        # the services tier is the one with real dependents, so a cascade
        # scenario has to land there. Falling back to scenario-role keeps the
        # standalone database tier addressable when no services tier exists.
        exact = [h for h in hosts if h.get("service") == target]
        match = exact[0] if exact else None
        if not match:
            aliased = [h for h in hosts if h.get("service_alias") == target]
            if len(aliased) > 1:
                names = ", ".join(sorted(h["name"] for h in aliased))
                raise HTTPException(
                    409,
                    f"{req.scenario_id} targets '{target}' and {len(aliased)} hosts claim it "
                    f"({names}). Pass instance_id to say which - guessing would run the fault "
                    f"on an arbitrary one.",
                )
            match = aliased[0] if aliased else None
        if not match:
            raise HTTPException(
                412,
                f"{req.scenario_id} needs the '{target}' host - deploy the services tier "
                f"(infra/cloudformation/services.json)",
            )
        instance_id = match["instance_id"]
    else:
        instance_id = req.instance_id or hosts[0]["instance_id"]
    host = next((h for h in hosts if h["instance_id"] == instance_id), None)
    if not host:
        raise HTTPException(400, f"{instance_id} is not a scenario-lab host")
    if not host["ssm_online"]:
        raise HTTPException(412, f"{instance_id} is not reachable via SSM")

    state = read_state()
    if req.scenario_id in state:
        raise HTTPException(409, f"{req.scenario_id} is already running")

    # A cloud-config fault is not something a host can do to itself, and it should
    # not be. Breaking a security group from inside the instance would mean giving
    # every lab host permission to rewrite the network it sits in - a genuinely bad
    # pattern to leave lying around in an environment customers look at, and one
    # that would be the most alarming thing in the template.
    #
    # These run here instead, against the control plane's own credentials: the same
    # place a human would make the change, and the same audit trail.
    if scenario.get("kind") == "aws":
        return start_cloud_scenario(req.scenario_id, scenario, seconds, state)

    body = scenario["command"].replace("{{seconds}}", str(seconds))
    try:
        sent = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Comment=f"{CMD_PREFIX} {req.scenario_id}",
            Parameters={"commands": [body]},
            TimeoutSeconds=60,
        )
    except ClientError as exc:
        raise HTTPException(502, f"ssm send-command failed: {exc}") from exc

    started = now()
    state[req.scenario_id] = {
        "command_id": sent["Command"]["CommandId"],
        "instance_id": instance_id,
        "started": started.isoformat(),
        "expires": (started + timedelta(seconds=seconds + 60)).isoformat(),
        "seconds": seconds,
    }
    write_state(state)
    return {"started": req.scenario_id, "instance_id": instance_id, "seconds": seconds}


def run_cleanup(scenario_id: str, instance_id: str) -> bool:
    """
    Undo one scenario on one host.

    Cancelling an SSM command is not enough. Several scenarios change state
    and undo it at the end of their own script - disk_fill removes its file,
    runaway_cron removes /etc/cron.d/nudgebee-scenario, service_failure
    removes its unit. cancel_command kills the script where it stands, so
    those trailing lines never run and the damage outlives the scenario with
    nothing left in the UI to show for it. A cancelled runaway_cron would
    burn CPU every minute forever.

    So every stop path runs the scenario's own cleanup afterwards. It is
    per-scenario rather than the global sweep because another scenario may
    still be running on the same host, and the global sweep would kill it.
    """
    scenario = load_catalogue().get(scenario_id)
    if not scenario or not scenario.get("cleanup"):
        return False
    try:
        ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Comment=f"{CMD_PREFIX} cleanup: {scenario_id}",
            Parameters={"commands": [scenario["cleanup"]]},
            TimeoutSeconds=60,
        )
        return True
    except ClientError:
        return False


@app.post("/api/stop/{scenario_id}")
def stop(scenario_id: str):
    state = read_state()
    entry = state.pop(scenario_id, None)
    if not entry:
        raise HTTPException(404, f"{scenario_id} is not running")

    # A cloud fault has no SSM command to cancel and no host to clean up; its undo
    # is the stored inverse of what was applied. Writing state back only after the
    # undo succeeds matters here in a way it does not for the SSM path: an SSM
    # scenario self-terminates on its own timer even if we lose track of it, but a
    # revoked security group stays revoked forever. Dropping it from state while
    # the rule is still missing would strand the lab silently.
    if entry.get("kind") == "aws":
        _, undo_fn = CLOUD_SCENARIOS[entry["action"]]
        undo_fn(entry["undo"])
        write_state(state)
        return {"stopped": scenario_id, "cleanup_dispatched": True, "kind": "aws"}

    try:
        ssm.cancel_command(CommandId=entry["command_id"], InstanceIds=[entry["instance_id"]])
    except ClientError:
        pass
    cleaned = run_cleanup(scenario_id, entry["instance_id"])
    write_state(state)
    return {"stopped": scenario_id, "cleanup_dispatched": cleaned}


def full_cleanup() -> str:
    """
    The reset sweep: every scenario's own cleanup, concatenated.

    Built from the catalogue rather than hand-maintained here. The previous
    hardcoded version had already drifted - it never touched zombie_processes -
    and a second copy of the cleanup logic is exactly the kind of thing that
    silently rots. Adding a scenario stays a YAML entry, not a code change.
    """
    parts = ["echo 'scenario-lab: resetting'"]
    for s in load_catalogue().values():
        if s.get("cleanup"):
            parts.append(f"# --- {s['id']}")
            parts.append(s["cleanup"].rstrip())
    parts.append("echo 'scenario-lab reset complete'")
    return "\n".join(parts)


@app.post("/api/reset")
def reset():
    state = read_state()
    stopped = []
    for sid, entry in list(state.items()):
        # Reset means "put the lab back", and the host sweep below cannot do that
        # for a fault that is not on a host. Without this, Reset reports success
        # while the security group stays revoked - the lab looks clean and is not.
        if entry.get("kind") == "aws":
            try:
                _, undo_fn = CLOUD_SCENARIOS[entry["action"]]
                undo_fn(entry["undo"])
            except Exception:
                pass
            stopped.append(sid)
            continue
        # command_id/instance_id are None for cloud entries, and passing None
        # raises ParamValidationError rather than ClientError - which the handler
        # below would not catch, taking the whole reset down with it.
        try:
            ssm.cancel_command(CommandId=entry["command_id"], InstanceIds=[entry["instance_id"]])
        except ClientError:
            pass
        stopped.append(sid)
    for host in lab_hosts():
        if not host["ssm_online"]:
            continue
        try:
            ssm.send_command(
                InstanceIds=[host["instance_id"]],
                DocumentName="AWS-RunShellScript",
                Comment=f"{CMD_PREFIX} reset",
                Parameters={"commands": [full_cleanup()]},
                TimeoutSeconds=60,
            )
        except ClientError:
            pass
    write_state({})
    return {"stopped": stopped, "cleanup_dispatched": True}


@app.get("/api/setup")
def setup():
    """
    When the lab is not deployed the UI should say how to deploy it, with the
    account's own VPC and subnet filled in - not a placeholder the operator has
    to go and look up.
    """
    si = stack_info()
    hosts = lab_hosts()
    vpc = subnet = None
    try:
        vpcs = ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])["Vpcs"]
        if not vpcs:
            vpcs = ec2.describe_vpcs()["Vpcs"]
        if vpcs:
            vpc = vpcs[0]["VpcId"]
            subs = ec2.describe_subnets(
                Filters=[
                    {"Name": "vpc-id", "Values": [vpc]},
                    {"Name": "map-public-ip-on-launch", "Values": ["true"]},
                ]
            )["Subnets"]
            if not subs:
                subs = ec2.describe_subnets(
                    Filters=[{"Name": "vpc-id", "Values": [vpc]}]
                )["Subnets"]
            if subs:
                subnet = subs[0]["SubnetId"]
    except ClientError:
        pass

    cmd = "./scripts/deploy.sh"
    waste = "./scripts/deploy.sh waste"
    manual = (
        "aws cloudformation deploy \\\n"
        "  --template-file infra/cloudformation/lab.yaml \\\n"
        f"  --stack-name {STACK} \\\n"
        "  --capabilities CAPABILITY_IAM \\\n"
        f"  --region {REGION}"
    )
    perms = permissions(DEPLOY_ACTIONS)
    missing = [a for a, ok in perms.items() if not ok]
    return {
        "can_deploy": bool(perms) and not missing,
        "missing_deploy_permissions": missing,
        "permissions_checked": bool(perms),
        "needs_deploy": not si["deployed"] or not hosts,
        "stack_deployed": si["deployed"],
        "stack_status": si["status"],
        "host_count": len(hosts),
        "suggested_vpc": vpc,
        "suggested_subnet": subnet,
        "deploy_command": cmd,
        "waste_command": waste,
        "manual_command": manual,
    }


# ----------------------------------------------------------------- deploy

class DeployRequest(BaseModel):
    tier: str = "lab"
    vpc_id: str | None = None
    subnet_id: str | None = None
    confirm: bool = False


@app.post("/api/deploy")
def deploy(req: DeployRequest):
    """
    Create the stack from the UI. Deliberately requires confirm=true: this
    creates billable resources and, for the lab tier, hosts that scenarios
    will degrade.
    """
    if not req.confirm:
        raise HTTPException(400, "confirm=true is required - this creates billable resources")

    name = stack_name_for(req.tier)
    body = template_path(req.tier).read_text()

    params = []
    if req.vpc_id:
        params.append({"ParameterKey": "VpcId", "ParameterValue": req.vpc_id})
        if not req.subnet_id:
            raise HTTPException(400, "subnet_id is required when vpc_id is given")
        params.append({"ParameterKey": "SubnetId", "ParameterValue": req.subnet_id})
    elif req.tier == "waste":
        # waste.yaml has no network of its own - reuse the lab's
        vpc = subnet = None
        try:
            outs = cfn.describe_stacks(StackName=STACK)["Stacks"][0].get("Outputs", [])
            vpc = next((o["OutputValue"] for o in outs if o["OutputKey"] == "VpcUsed"), None)
        except ClientError:
            pass
        if vpc:
            try:
                subs = ec2.describe_subnets(
                    Filters=[{"Name": "vpc-id", "Values": [vpc]}]
                )["Subnets"]
                subnet = subs[0]["SubnetId"] if subs else None
            except ClientError:
                pass
        if not vpc or not subnet:
            raise HTTPException(412, "deploy the lab tier first, or supply vpc_id and subnet_id")
        params = [
            {"ParameterKey": "VpcId", "ParameterValue": vpc},
            {"ParameterKey": "SubnetId", "ParameterValue": subnet},
        ]

    try:
        cfn.create_stack(
            StackName=name,
            TemplateBody=body,
            Parameters=params,
            Capabilities=["CAPABILITY_IAM"],
            Tags=[{"Key": "nudgebee-scenario-lab", "Value": "true"}],
            OnFailure="ROLLBACK",
        )
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "AlreadyExistsException":
            raise HTTPException(409, f"stack {name} already exists") from exc
        raise HTTPException(502, f"create_stack failed: {exc}") from exc

    _cache.pop("identity", None)
    return {"deploying": name, "tier": req.tier}


@app.get("/api/deploy/status")
def deploy_status(tier: str = "lab"):
    """Stack status plus the most recent events, so the UI can show progress."""
    name = stack_name_for(tier)
    try:
        st = cfn.describe_stacks(StackName=name)["Stacks"][0]
    except ClientError:
        return {"exists": False, "status": None, "events": [], "in_progress": False}

    events = []
    try:
        for e in cfn.describe_stack_events(StackName=name)["StackEvents"][:12]:
            events.append(
                {
                    "time": e["Timestamp"].isoformat(),
                    "resource": e.get("LogicalResourceId"),
                    "type": e.get("ResourceType"),
                    "status": e.get("ResourceStatus"),
                    "reason": e.get("ResourceStatusReason"),
                }
            )
    except ClientError:
        pass

    status = st["StackStatus"]
    return {
        "exists": True,
        "status": status,
        "in_progress": status.endswith("_IN_PROGRESS"),
        "complete": status in ("CREATE_COMPLETE", "UPDATE_COMPLETE"),
        "failed": "ROLLBACK" in status or "FAILED" in status,
        "events": events,
    }


class TeardownRequest(BaseModel):
    tier: str = "lab"
    confirm_name: str


@app.post("/api/teardown")
def teardown(req: TeardownRequest):
    """Delete the stack. The caller must type the stack name back to confirm."""
    name = stack_name_for(req.tier)
    if req.confirm_name != name:
        raise HTTPException(400, f"type the stack name '{name}' to confirm deletion")
    try:
        cfn.delete_stack(StackName=name)
    except ClientError as exc:
        raise HTTPException(502, f"delete_stack failed: {exc}") from exc
    return {"deleting": name}


@app.get("/api/health")
def health():
    hosts = lab_hosts()
    return {
        "stack": STACK,
        "region": REGION,
        "hosts": len(hosts),
        "hosts_ssm_online": sum(1 for h in hosts if h["ssm_online"]),
        "active_scenarios": list(read_state().keys()),
    }


# ----------------------------------------------------------------- sweeper

def sweeper() -> None:
    while True:
        try:
            state = read_state()
            changed = False
            for sid, entry in list(state.items()):
                expires = entry.get("expires")
                if expires and now() >= datetime.fromisoformat(expires):
                    # A cloud fault has no self-terminating command behind it. An SSM
                    # scenario ends on its own timer even if this sweeper never runs;
                    # a revoked security group does not. This is the only thing that
                    # puts the rule back if the operator closes the tab, so it drops
                    # the entry only once the undo has actually succeeded - otherwise
                    # a transient AWS error would lose the undo and strand the lab.
                    if entry.get("kind") == "aws":
                        try:
                            _, undo_fn = CLOUD_SCENARIOS[entry["action"]]
                            undo_fn(entry["undo"])
                        except Exception:
                            continue
                        state.pop(sid, None)
                        changed = True
                        continue
                    try:
                        ssm.cancel_command(
                            CommandId=entry["command_id"],
                            InstanceIds=[entry["instance_id"]],
                        )
                    except ClientError:
                        pass
                    # Cancelling stops the script mid-flight, so the undo at
                    # the end of it never runs. Without this the safety net
                    # leaves the damage in place at expiry.
                    run_cleanup(sid, entry["instance_id"])
                    state.pop(sid, None)
                    changed = True
            if changed:
                write_state(state)
        except Exception:
            pass
        time.sleep(30)


@app.on_event("startup")
def start_sweeper() -> None:
    threading.Thread(target=sweeper, daemon=True).start()


@app.get("/")
def index():
    return FileResponse(WEB_DIR / "index.html")


app.mount("/static", StaticFiles(directory=str(WEB_DIR)), name="static")
