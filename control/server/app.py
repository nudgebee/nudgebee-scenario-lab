"""
NudgeBee Scenario Lab - control app.

Runs locally, uses the operator's own cloud credentials, binds to loopback.
Nothing is hosted by NudgeBee and nothing inbound is opened to the lab network.

CLOUD selects the backend (aws by default, or azure). This module is
cloud-neutral; everything that talks to a cloud lives in server/providers/.

Safety model, in order of precedence:
  1. every scenario command is wrapped in `timeout`, so it dies on its own
  2. the API refuses a duration above the lab's max_minutes ceiling
  3. a background sweeper cancels anything that outlived its expiry
  4. /api/reset cancels everything and runs the per-scenario cleanup

The API deliberately reports *readiness* per scenario rather than just offering
a button: which account it will run against, whether the caller holds the
permissions, whether the host is reachable, and whether the metric the alarm
needs is actually being published. A greyed-out button with a reason beats a
run that fails halfway.
"""

import os
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

import yaml
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from server.providers import load_provider
from server.providers.base import now

CATALOGUE = Path(os.environ.get("CATALOGUE_PATH", "/app/scenarios/catalogue.yaml"))
WEB_DIR = Path(os.environ.get("WEB_DIR", "/app/web"))

cloud = load_provider()
STACK = cloud.stack
REGION = cloud.region

app = FastAPI(title="NudgeBee Scenario Lab")


# ----------------------------------------------------------------- catalogue

def load_doc() -> dict:
    with CATALOGUE.open() as fh:
        return yaml.safe_load(fh)


def for_this_cloud(entry: dict) -> bool:
    """Entries without `clouds` apply everywhere; the rest name where they apply."""
    clouds = entry.get("clouds")
    return not clouds or cloud.name in clouds


def for_cloud(entry: dict) -> dict:
    """An entry with this cloud's `overrides` applied: `requires` merged, the rest replaced."""
    over = (entry.get("overrides") or {}).get(cloud.name)
    if not over:
        return entry
    merged = {**entry, **{k: v for k, v in over.items() if k != "requires"}}
    if "requires" in over:
        merged["requires"] = {**(entry.get("requires") or {}), **over["requires"]}
    return merged


def load_catalogue() -> dict:
    return {s["id"]: for_cloud(s) for s in load_doc().get("scenarios", []) if for_this_cloud(s)}


def load_findings() -> list:
    return [f for f in load_doc().get("findings", []) if for_this_cloud(f)]


# ----------------------------------------------------------------- readiness

def readiness(scenario: dict, hosts: list[dict], perms: dict[str, bool],
              alarms: dict[str, dict], host_id: str | None) -> dict:
    """Everything the UI needs to say 'you can run this' or exactly why not."""
    blockers: list[str] = []
    warnings: list[str] = []

    tier = scenario.get("tier", "lab")
    if tier not in cloud.tiers:
        blockers.append(f"the {tier} tier is not available on {cloud.name} yet")
    kind = scenario.get("kind")
    if kind and kind != cloud.name:
        blockers.append(f"changes {kind} configuration directly - needs CLOUD={kind}")

    req = scenario.get("requires") or {}
    for action in cloud.scenario_actions(scenario):
        if perms.get(action) is False:
            blockers.append(f"missing permission: {action}")

    agent = cloud.labels["agent"]
    if not hosts:
        blockers.append("no scenario hosts deployed")
    else:
        host = next((h for h in hosts if h["instance_id"] == host_id), hosts[0])
        if not host["ssm_online"]:
            blockers.append(f"{host['name']} is not reachable via {agent}")

    for b in req.get("binaries") or []:
        warnings.append(f"needs `{b}` on the host (installed by the lab bootstrap)")

    metric = cloud.describe_metric(req.get("metric"))
    if metric:
        hint = cloud.metric_warning(metric)
        if hint:
            warnings.append(hint)
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


def required_actions(cat: dict) -> tuple[str, ...]:
    return tuple(sorted({a for s in cat.values() for a in cloud.scenario_actions(s)}))


# ----------------------------------------------------------------- API

class StartRequest(BaseModel):
    scenario_id: str
    instance_id: str | None = None
    seconds: int | None = None


def describe_cloud() -> dict:
    return {"cloud": cloud.name, "labels": cloud.labels}


@app.get("/api/context")
def context():
    return {
        "stack": STACK,
        "region": REGION,
        **describe_cloud(),
        "identity": cloud.identity(),
        "stack_info": cloud.stack_info(),
        "hosts": cloud.lab_hosts(),
        "max_minutes": cloud.max_minutes(),
        "can_simulate": cloud.can_check_permissions(),
    }


@app.get("/api/scenarios")
def list_scenarios(host: str | None = None):
    cat = load_catalogue()
    state = cloud.read_state()
    hosts = cloud.lab_hosts()
    alarms = cloud.alarm_map()
    runs = cloud.recent_runs()

    actions = required_actions(cat)
    perms = cloud.permissions(actions) if actions else {}

    out = []
    for sid, s in cat.items():
        running = state.get(sid)
        r = readiness(s, hosts, perms, alarms, host)
        default_seconds, expect_alarm = cloud.timing(s)
        out.append(
            {
                "id": sid,
                "name": s["name"],
                "tier": s.get("tier", "lab"),
                "signal": s.get("signal"),
                "default_seconds": default_seconds,
                "expect_alarm_secs": expect_alarm,
                "teaches": (s.get("teaches") or "").strip(),
                "naive_answer": s.get("naive_answer"),
                "requires": {
                    **(s.get("requires") or {}),
                    "iam": cloud.scenario_actions(s),
                    "metric": cloud.describe_metric((s.get("requires") or {}).get("metric")),
                },
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
        **describe_cloud(),
        "identity": cloud.identity(),
        "stack_info": cloud.stack_info(),
        "max_minutes": cloud.max_minutes(),
        "hosts": hosts,
        "permissions": perms,
        "scenarios": sorted(out, key=lambda s: s["name"]),
        "findings": load_findings(),
    }


@app.get("/api/alarms")
def alarms_endpoint():
    return {"alarms": sorted(cloud.alarm_map().values(), key=lambda a: a["name"])}


@app.get("/api/findings")
def findings_endpoint():
    """Waste-tier resources actually present in the account, matched to the catalogue."""
    findings = load_findings()
    present = cloud.findings_present([f["tag"] for f in findings])
    return {
        "findings": [
            {**f, "deployed": bool(present.get(f["tag"])), "resources": present.get(f["tag"], [])}
            for f in findings
        ]
    }


@app.post("/api/start")
def start(req: StartRequest):
    cat = load_catalogue()
    if req.scenario_id not in cat:
        raise HTTPException(404, f"unknown scenario {req.scenario_id}")
    scenario = cat[req.scenario_id]

    tier = scenario.get("tier", "lab")
    if tier not in cloud.tiers:
        raise HTTPException(412, f"the {tier} tier is not available on {cloud.name} yet")

    seconds = int(req.seconds or cloud.timing(scenario)[0])
    ceiling = cloud.max_minutes() * 60
    if seconds > ceiling:
        raise HTTPException(400, f"duration {seconds}s exceeds the lab ceiling of {ceiling}s")

    hosts = cloud.lab_hosts()
    if not hosts:
        raise HTTPException(412, "no scenario hosts found - is the lab deployed?")
    # Cascade scenarios only make sense on one specific host - stopping "order"
    # has to happen on the order host, whatever is selected in the UI. Those
    # scenarios declare target_service and we resolve the host ourselves.
    target = scenario.get("target_service")
    if target:
        match = next((h for h in hosts if h.get("service") == target), None)
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
        raise HTTPException(412, f"{instance_id} is not reachable via {cloud.labels['agent']}")

    state = cloud.read_state()
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
    if scenario.get("kind"):
        return start_cloud_scenario(req.scenario_id, scenario, seconds, state)

    body = scenario["command"].replace("{{seconds}}", str(seconds))
    command_id = cloud.send(instance_id, body, req.scenario_id, run_seconds=seconds)

    started = now()
    state[req.scenario_id] = {
        "command_id": command_id,
        "instance_id": instance_id,
        "started": started.isoformat(),
        "expires": (started + timedelta(seconds=seconds + 60)).isoformat(),
        "seconds": seconds,
    }
    cloud.write_state(state)
    return {"started": req.scenario_id, "instance_id": instance_id, "seconds": seconds}


def start_cloud_scenario(scenario_id: str, scenario: dict, seconds: int, state: dict):
    kind = scenario["kind"]
    if kind != cloud.name:
        raise HTTPException(412, f"{scenario_id} changes {kind} configuration directly - needs CLOUD={kind}")
    action = scenario.get("action")
    undo = cloud.apply_action(scenario_id, action, scenario.get("params") or {})

    started = now()
    state[scenario_id] = {
        "kind": kind,
        "action": action,
        "undo": undo,
        # No instance: the fault is in the network, not on a machine. Recorded
        # explicitly so the sweeper and /api/stop do not try to cancel a remote
        # command that was never sent.
        "instance_id": None,
        "command_id": None,
        "started": started.isoformat(),
        "expires": (started + timedelta(seconds=seconds + 60)).isoformat(),
        "seconds": seconds,
    }
    cloud.write_state(state)
    return {"started": scenario_id, "instance_id": None, "seconds": seconds, "kind": kind}


def run_cleanup(scenario_id: str, instance_id: str) -> bool:
    """
    Undo one scenario on one host.

    Cancelling the remote command is not enough. Several scenarios change
    state and undo it at the end of their own script - disk_fill removes its
    file, runaway_cron removes /etc/cron.d/nudgebee-scenario, service_failure
    removes its unit. Cancelling kills the script where it stands, so those
    trailing lines never run and the damage outlives the scenario with nothing
    left in the UI to show for it. A cancelled runaway_cron would burn CPU
    every minute forever.

    So every stop path runs the scenario's own cleanup afterwards. It is
    per-scenario rather than the global sweep because another scenario may
    still be running on the same host, and the global sweep would kill it.
    """
    scenario = load_catalogue().get(scenario_id)
    if not scenario or not scenario.get("cleanup"):
        return False
    try:
        cloud.send(instance_id, scenario["cleanup"], f"cleanup: {scenario_id}")
        return True
    except HTTPException:
        return False


@app.post("/api/stop/{scenario_id}")
def stop(scenario_id: str):
    state = cloud.read_state()
    entry = state.pop(scenario_id, None)
    if not entry:
        raise HTTPException(404, f"{scenario_id} is not running")

    # A cloud fault has no remote command to cancel and no host to clean up; its
    # undo is the stored inverse of what was applied. Writing state back only
    # after the undo succeeds matters here in a way it does not for the host
    # path: a host scenario self-terminates on its own timer even if we lose
    # track of it, but a revoked security group stays revoked forever. Dropping
    # it from state while the rule is still missing would strand the lab silently.
    if entry.get("kind"):
        cloud.undo_action(entry["action"], entry["undo"])
        cloud.write_state(state)
        return {"stopped": scenario_id, "cleanup_dispatched": True, "kind": entry["kind"]}

    cloud.cancel(entry)
    cleaned = run_cleanup(scenario_id, entry["instance_id"])
    cloud.write_state(state)
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
    state = cloud.read_state()
    stopped = []
    for sid, entry in list(state.items()):
        # Reset means "put the lab back", and the host sweep below cannot do that
        # for a fault that is not on a host. Without this, Reset reports success
        # while the security group stays revoked - the lab looks clean and is not.
        if entry.get("kind"):
            try:
                cloud.undo_action(entry["action"], entry["undo"])
            except Exception:
                pass
            stopped.append(sid)
            continue
        cloud.cancel(entry)
        stopped.append(sid)
    for host in cloud.lab_hosts():
        if not host["ssm_online"]:
            continue
        try:
            cloud.send(host["instance_id"], full_cleanup(), "reset")
        except HTTPException:
            pass
    cloud.write_state({})
    return {"stopped": stopped, "cleanup_dispatched": True}


@app.get("/api/setup")
def setup():
    si = cloud.stack_info()
    hosts = cloud.lab_hosts()
    perms = cloud.permissions(cloud.deploy_actions)
    missing = [a for a, ok in perms.items() if not ok]
    return {
        **describe_cloud(),
        "can_deploy": bool(perms) and not missing,
        "missing_deploy_permissions": missing,
        "permissions_checked": bool(perms),
        "needs_deploy": not si["deployed"] or not hosts,
        "stack_deployed": si["deployed"],
        "stack_status": si["status"],
        "stack_name_lab": cloud.stack_name_for("lab"),
        "stack_name_waste": cloud.stack_name_for("waste"),
        "host_count": len(hosts),
        **cloud.setup_info(),
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
    Create the tier from the UI. Deliberately requires confirm=true: this
    creates billable resources and, for the lab tier, hosts that scenarios
    will degrade.
    """
    if not req.confirm:
        raise HTTPException(400, "confirm=true is required - this creates billable resources")
    if req.tier not in ("lab", "waste"):
        raise HTTPException(400, "tier must be lab or waste")
    name = cloud.deploy(req.tier, req.vpc_id, req.subnet_id)
    return {"deploying": name, "tier": req.tier}


@app.get("/api/deploy/status")
def deploy_status(tier: str = "lab"):
    """Deployment status plus the most recent events, so the UI can show progress."""
    return cloud.deploy_status(tier)


class TeardownRequest(BaseModel):
    tier: str = "lab"
    confirm_name: str


@app.post("/api/teardown")
def teardown(req: TeardownRequest):
    """Delete a tier. The caller must type its name back to confirm."""
    name = cloud.stack_name_for(req.tier)
    if req.confirm_name != name:
        raise HTTPException(400, f"type the name '{name}' to confirm deletion")
    return {"deleting": cloud.teardown(req.tier)}


@app.get("/api/health")
def health():
    hosts = cloud.lab_hosts()
    return {
        "cloud": cloud.name,
        "stack": STACK,
        "region": REGION,
        "hosts": len(hosts),
        "hosts_ssm_online": sum(1 for h in hosts if h["ssm_online"]),
        "active_scenarios": list(cloud.read_state().keys()),
    }


# ----------------------------------------------------------------- sweeper

def sweeper() -> None:
    while True:
        try:
            state = cloud.read_state()
            changed = False
            for sid, entry in list(state.items()):
                expires = entry.get("expires")
                if expires and now() >= datetime.fromisoformat(expires):
                    # A cloud fault has no self-terminating command behind it. A
                    # host scenario ends on its own timer even if this sweeper
                    # never runs; a revoked security group does not. This is the
                    # only thing that puts the rule back if the operator closes
                    # the tab, so it drops the entry only once the undo has
                    # actually succeeded - otherwise a transient cloud error would
                    # lose the undo and strand the lab.
                    if entry.get("kind"):
                        try:
                            cloud.undo_action(entry["action"], entry["undo"])
                        except Exception:
                            continue
                        state.pop(sid, None)
                        changed = True
                        continue
                    cloud.cancel(entry)
                    # Cancelling stops the script mid-flight, so the undo at
                    # the end of it never runs. Without this the safety net
                    # leaves the damage in place at expiry.
                    run_cleanup(sid, entry["instance_id"])
                    state.pop(sid, None)
                    changed = True
            if changed:
                cloud.write_state(state)
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
