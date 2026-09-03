"""
NudgeBee Scenario Lab - control app.

Runs locally, uses the operator's own AWS credentials, and binds to loopback.
Nothing is hosted by NudgeBee and nothing inbound is opened to the VPC.

Safety model, in order of precedence:
  1. every scenario command is wrapped in `timeout`, so it dies on its own
  2. the API refuses a duration above the stack's max_minutes ceiling
  3. a background sweeper cancels anything that outlived its expiry
  4. /reset cancels everything and runs the per-scenario cleanup
"""

import os
import re
import json
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import boto3
import yaml
from botocore.exceptions import ClientError
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

app = FastAPI(title="NudgeBee Scenario Lab")

STATE_PARAM = f"/nudgebee-scenario-lab/{STACK}/active"
MAX_PARAM = f"/nudgebee-scenario-lab/{STACK}/max_minutes"


# ----------------------------------------------------------------- helpers

def load_catalogue() -> dict:
    with CATALOGUE.open() as fh:
        doc = yaml.safe_load(fh)
    return {s["id"]: s for s in doc.get("scenarios", [])}


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
    ssm.put_parameter(
        Name=STATE_PARAM, Value=json.dumps(state), Type="String", Overwrite=True
    )


def lab_hosts() -> list[dict]:
    """Scenario hosts are discovered by tag, so the app never hardcodes ids."""
    resp = ec2.describe_instances(
        Filters=[
            {"Name": "tag:nudgebee-scenario-lab", "Values": ["true"]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    out = []
    for res in resp.get("Reservations", []):
        for inst in res.get("Instances", []):
            tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
            out.append(
                {
                    "instance_id": inst["InstanceId"],
                    "name": tags.get("Name", inst["InstanceId"]),
                    "role": tags.get("scenario-role", ""),
                }
            )
    return sorted(out, key=lambda h: h["name"])


def ssm_online(instance_id: str) -> bool:
    try:
        info = ssm.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
        )["InstanceInformationList"]
        return bool(info) and info[0].get("PingStatus") == "Online"
    except (ClientError, IndexError):
        return False


def render(command: str, seconds: int) -> str:
    return command.replace("{{seconds}}", str(seconds))


def now() -> datetime:
    return datetime.now(timezone.utc)


# ----------------------------------------------------------------- API

class StartRequest(BaseModel):
    scenario_id: str
    instance_id: str | None = None
    seconds: int | None = None


@app.get("/api/scenarios")
def list_scenarios():
    cat = load_catalogue()
    state = read_state()
    hosts = lab_hosts()
    out = []
    for sid, s in cat.items():
        running = state.get(sid)
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
                "running": bool(running),
                "started": running.get("started") if running else None,
                "expires": running.get("expires") if running else None,
                "host": running.get("instance_id") if running else None,
            }
        )
    return {
        "stack": STACK,
        "region": REGION,
        "max_minutes": max_minutes(),
        "hosts": hosts,
        "scenarios": sorted(out, key=lambda s: s["name"]),
    }


@app.get("/api/alarms")
def alarms():
    """Live alarm state so the operator can watch a scenario trip without leaving."""
    try:
        resp = cw.describe_alarms(AlarmNamePrefix=f"{STACK}-host-", MaxRecords=100)
    except ClientError as exc:
        raise HTTPException(502, f"cloudwatch: {exc}") from exc
    return {
        "alarms": [
            {
                "name": a["AlarmName"],
                "state": a["StateValue"],
                "updated": a.get("StateUpdatedTimestamp").isoformat()
                if a.get("StateUpdatedTimestamp")
                else None,
            }
            for a in sorted(resp.get("MetricAlarms", []), key=lambda a: a["AlarmName"])
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
        raise HTTPException(
            400, f"duration {seconds}s exceeds the lab ceiling of {ceiling}s"
        )

    hosts = lab_hosts()
    if not hosts:
        raise HTTPException(
            412, "no scenario hosts found - is the CloudFormation stack deployed?"
        )
    instance_id = req.instance_id or hosts[0]["instance_id"]
    if instance_id not in {h["instance_id"] for h in hosts}:
        raise HTTPException(400, f"{instance_id} is not a scenario-lab host")
    if not ssm_online(instance_id):
        raise HTTPException(
            412,
            f"{instance_id} is not reachable via SSM. Check the instance profile "
            "and that the subnet can reach the SSM endpoints.",
        )

    state = read_state()
    if req.scenario_id in state:
        raise HTTPException(409, f"{req.scenario_id} is already running")

    body = render(scenario["command"], seconds)
    try:
        sent = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Comment=f"nudgebee-scenario-lab: {req.scenario_id}",
            Parameters={"commands": [body]},
            TimeoutSeconds=60,
        )
    except ClientError as exc:
        raise HTTPException(502, f"ssm send-command failed: {exc}") from exc

    command_id = sent["Command"]["CommandId"]
    started = now()
    state[req.scenario_id] = {
        "command_id": command_id,
        "instance_id": instance_id,
        "started": started.isoformat(),
        "expires": (started + timedelta(seconds=seconds + 60)).isoformat(),
        "seconds": seconds,
    }
    write_state(state)
    return {
        "started": req.scenario_id,
        "instance_id": instance_id,
        "command_id": command_id,
        "seconds": seconds,
        "expect_alarm_secs": scenario.get("expect_alarm_secs"),
        "note": "The command self-terminates. Use /api/reset to stop everything early.",
    }


@app.post("/api/stop/{scenario_id}")
def stop(scenario_id: str):
    state = read_state()
    entry = state.pop(scenario_id, None)
    if not entry:
        raise HTTPException(404, f"{scenario_id} is not running")
    try:
        ssm.cancel_command(
            CommandId=entry["command_id"], InstanceIds=[entry["instance_id"]]
        )
    except ClientError:
        pass  # already finished; clearing state is what matters
    write_state(state)
    return {"stopped": scenario_id}


@app.post("/api/reset")
def reset():
    """Cancel everything and run cleanup. Safe to call at any time."""
    state = read_state()
    stopped = []
    for sid, entry in list(state.items()):
        try:
            ssm.cancel_command(
                CommandId=entry["command_id"], InstanceIds=[entry["instance_id"]]
            )
        except ClientError:
            pass
        stopped.append(sid)

    cleanup = (
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
    for host in lab_hosts():
        if not ssm_online(host["instance_id"]):
            continue
        try:
            ssm.send_command(
                InstanceIds=[host["instance_id"]],
                DocumentName="AWS-RunShellScript",
                Comment="nudgebee-scenario-lab: reset",
                Parameters={"commands": [cleanup]},
                TimeoutSeconds=60,
            )
        except ClientError:
            pass

    write_state({})
    return {"stopped": stopped, "cleanup_dispatched": True}


@app.get("/api/health")
def health():
    hosts = lab_hosts()
    return {
        "stack": STACK,
        "region": REGION,
        "hosts": len(hosts),
        "hosts_ssm_online": sum(1 for h in hosts if ssm_online(h["instance_id"])),
        "active_scenarios": list(read_state().keys()),
    }


# ----------------------------------------------------------------- sweeper

def sweeper() -> None:
    """Backstop for anything that outlived its expiry - see safety model above."""
    while True:
        try:
            state = read_state()
            changed = False
            for sid, entry in list(state.items()):
                expires = entry.get("expires")
                if not expires:
                    continue
                if now() >= datetime.fromisoformat(expires):
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
        except Exception:  # never let the sweeper die
            pass
        time.sleep(30)


@app.on_event("startup")
def start_sweeper() -> None:
    threading.Thread(target=sweeper, daemon=True).start()


# ----------------------------------------------------------------- static

@app.get("/")
def index():
    return FileResponse(WEB_DIR / "index.html")


app.mount("/static", StaticFiles(directory=str(WEB_DIR)), name="static")
