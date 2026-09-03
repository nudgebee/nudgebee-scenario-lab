# NudgeBee Scenario Lab

Deploy a small, disposable AWS environment, inject realistic infrastructure
incidents on demand, and watch NudgeBee detect, triage and explain them.

> **These scenarios deliberately degrade the hosts they run on.** Deploy into a
> sandbox or non-production account. Every scenario stops on its own, and
> **Reset everything** stops them immediately.

## Quickstart

```bash
./scripts/preflight.sh     # is this account ready? (read-only)
./scripts/deploy.sh        # deploy the lab   (~4 min, no parameters)
./scripts/run-local.sh     # start the UI  -> http://127.0.0.1:8080
```

**No VPC or subnet to look up.** The stack creates its own isolated VPC by
default, which also means the lab cannot land in a network you care about. To
use an existing one instead:

```bash
VPC_ID=vpc-123 SUBNET_ID=subnet-456 ./scripts/deploy.sh
```

Docker is optional — `run-local.sh` uses a Python virtualenv. If you prefer
containers: `cd control && docker compose up`.

## Two things to deploy

| Stack | What it is | Demonstrates |
|---|---|---|
| `lab.yaml` | hosts + alarms, scenarios injected on demand | incident detection and investigation |
| `waste.yaml` | deliberately wasteful/misconfigured resources | cost, rightsizing and security findings |

`waste.yaml` needs no fault injection at all — the finding *is* the resource
existing. Deploy it and NudgeBee should surface real findings within a sync
cycle. It is the faster demo of the two.

## What gets deployed (lab tier)

| Resource | Why |
|---|---|
| 1–4 × t3.micro EC2 | the hosts scenarios run on |
| IAM role + instance profile | SSM Run Command + CloudWatch agent |
| Security group | egress only — no inbound is opened |
| CloudWatch alarms | CPU, memory, disk, network, status check |
| SSM parameters | scenario state and the safety ceiling |

Roughly **$15/month** if left running. Tear down with
`aws cloudformation delete-stack --stack-name nudgebee-scenario-lab`.

## Scenarios

Defined in [`scenarios/catalogue.yaml`](scenarios/catalogue.yaml) — adding one
is a YAML entry, not a code change.

| Scenario | Trips | What it teaches |
|---|---|---|
| `cpu_high` | CPU alarm | attribute a spike to an operator command, not "undersized instance" |
| `memory_pressure` | memory alarm | exhaustion with no OOM kill — degradation without a crash |
| `disk_fill` | disk alarm | find the file and the writer, not just percent-used |
| `disk_io_saturation` | CPU alarm | I/O wait masquerading as CPU load |
| `network_spike` | network alarm | tie egress to the responsible process |
| `runaway_cron` | CPU alarm (recurring) | **the cause is a schedule, not a process** |
| `service_failure` | status check | a unit that fails and stays failed |
| `zombie_processes` | CPU alarm | fork pressure with no single culprit |

Each carries a `naive_answer` — the plausible-but-wrong conclusion. Those are
the interesting ones: a scenario whose obvious answer is correct proves the
pipeline works, not that the product is useful.

## Safety

Four independent layers, in order:

1. Every scenario command is wrapped in `timeout` — it dies on its own
2. The API refuses any duration above the stack's `MaxScenarioMinutes`
3. A sweeper cancels anything that outlives its expiry
4. **Reset everything** cancels all commands and runs per-scenario cleanup

The control app binds to `127.0.0.1` and uses your own AWS credentials.
Nothing is hosted by NudgeBee; nothing inbound is opened to your VPC.

## Waste tier

```bash
./scripts/deploy.sh waste     # or: ./scripts/deploy.sh both
```

| Finding | Resource created | Cost impact |
|---|---|---|
| unattached EBS volume | 20 GB gp3, no attachment | ~$1.60/mo |
| unencrypted EBS volume | 1 GB, encryption off | negligible |
| over-permissive SG | 22 + 3389 open, **attached to nothing** | none |
| oversized instance | m5.xlarge near-idle | **~$140/mo** |
| stopped instance | t3.small + 30 GB EBS | ~$2.40/mo |
| idle load balancer | ALB, no targets (off by default) | ~$16/mo |

Two things to know:

- **The open security group is attached to nothing.** It exists so security
  scanning has something to find; it opens no actual access.
- **The oversized-instance finding needs history.** Rightsizing is based on
  days of CloudWatch utilisation data, so it will not appear immediately after
  deploying. That is expected, not a failure.
- **One manual step:** CloudFormation cannot create an instance in the stopped
  state. Run the `stop-instances` command from the stack outputs afterwards.

The `oversized_instance` finding dominates the cost. Set
`CreateOversizedInstance=false` if you only want the free findings.

## NudgeBee integration

[`nudgebee/`](nudgebee/) ships an automation and a knowledge-base article that
turn "an alarm fired" into "here is what caused it". Import both — see
[`nudgebee/README.md`](nudgebee/README.md).

**The prerequisite people miss:** onboarding the AWS account is not enough.
EventBridge forwarding must be enabled or alarms fire in CloudWatch and never
reach NudgeBee. `preflight.sh` checks this explicitly.

## Docs

- `docs/01-prerequisites.md`
- `docs/02-deploy.md`
- `docs/03-connect-nudgebee.md`
- `docs/04-run-scenarios.md`
- `docs/05-what-to-look-for.md` — expected NudgeBee output per scenario
- `docs/06-teardown.md`
- `docs/07-cost.md`
- `docs/08-troubleshooting.md`
