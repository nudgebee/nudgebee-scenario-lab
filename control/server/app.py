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
from botocore.exceptions import ClientError, NoCredentialsError
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

STACK = os.environ.get("SCENARIO_LAB_STACK", "nudgebee-scenario-lab")
REGION = os.environ.get("AWS_REGION", "us-east-1")
CATALOGUE = Path(os.environ.get("CATALOGUE_PATH", "/app/scenarios/catalogue.yaml"))
WEB_DIR = Path(os.environ.get("WEB_DIR", "/app/web"))

ssm = boto3.client("ssm", region_name=REGION)
ec2 = boto3.client("ec2", region_name=REGION)
cw = boto3.client("cloudwatch", region_name=REGION)
sts = boto3.client("sts", region_name=REGION)
iam = boto3.client("iam", region_name=REGION)
cfn = boto3.client("cloudformation", region_name=REGION)

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
    try:
        ssm.put_parameter(
            Name=STATE_PARAM, Value=json.dumps(state), Type="String", Overwrite=True
        )
    except ClientError:
        pass  # stack may not be deployed yet; state is best-effort


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
                    "role": tags.get("scenario-role", ""),
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
    instance_id = req.instance_id or hosts[0]["instance_id"]
    host = next((h for h in hosts if h["instance_id"] == instance_id), None)
    if not host:
        raise HTTPException(400, f"{instance_id} is not a scenario-lab host")
    if not host["ssm_online"]:
        raise HTTPException(412, f"{instance_id} is not reachable via SSM")

    state = read_state()
    if req.scenario_id in state:
        raise HTTPException(409, f"{req.scenario_id} is already running")

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


@app.post("/api/stop/{scenario_id}")
def stop(scenario_id: str):
    state = read_state()
    entry = state.pop(scenario_id, None)
    if not entry:
        raise HTTPException(404, f"{scenario_id} is not running")
    try:
        ssm.cancel_command(CommandId=entry["command_id"], InstanceIds=[entry["instance_id"]])
    except ClientError:
        pass
    write_state(state)
    return {"stopped": scenario_id}


CLEANUP = (
    "pkill -f 'while :; do :; done' 2>/dev/null || true; "
    "pkill stress-ng 2>/dev/null || true; "
    "rm -f /var/tmp/nudgebee-scenario-fill.bin /var/tmp/nb-io.tmp 2>/dev/null || true; "
    "rm -f /etc/cron.d/nudgebee-scenario 2>/dev/null || true; "
    "systemctl stop nudgebee-scenario-broken 2>/dev/null || true; "
    "systemctl disable nudgebee-scenario-broken 2>/dev/null || true; "
    "rm -f /etc/systemd/system/nudgebee-scenario-broken.service 2>/dev/null || true; "
    "systemctl daemon-reload 2>/dev/null || true; "
    "echo scenario-lab reset complete"
)


@app.post("/api/reset")
def reset():
    state = read_state()
    stopped = []
    for sid, entry in list(state.items()):
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
                Parameters={"commands": [CLEANUP]},
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

    cmd = (
        "aws cloudformation deploy \\\n"
        "  --template-file infra/cloudformation/lab.yaml \\\n"
        f"  --stack-name {STACK} \\\n"
        "  --capabilities CAPABILITY_IAM \\\n"
        f"  --region {REGION} \\\n"
        f"  --parameter-overrides VpcId={vpc or '<vpc-id>'} SubnetId={subnet or '<subnet-id>'}"
    )
    waste = (
        "aws cloudformation deploy \\\n"
        "  --template-file infra/cloudformation/waste.yaml \\\n"
        f"  --stack-name {STACK}-waste \\\n"
        f"  --region {REGION} \\\n"
        f"  --parameter-overrides VpcId={vpc or '<vpc-id>'} SubnetId={subnet or '<subnet-id>'}"
    )
    return {
        "needs_deploy": not si["deployed"] or not hosts,
        "stack_deployed": si["deployed"],
        "stack_status": si["status"],
        "host_count": len(hosts),
        "suggested_vpc": vpc,
        "suggested_subnet": subnet,
        "deploy_command": cmd,
        "waste_command": waste,
    }


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
                    try:
                        ssm.cancel_command(
                            CommandId=entry["command_id"],
                            InstanceIds=[entry["instance_id"]],
                        )
                    except ClientError:
                        pass
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
