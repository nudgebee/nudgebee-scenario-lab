# The NudgeBee side of the lab

The lab breaks things. These are what NudgeBee uses to investigate them:

- `automations/` — six automations, exported from the environment they were
  built and demoed in
- `knowledge-base/` — one article that tells the assistant when to reach for
  them and how to read what comes back

None of it is required to see an alarm fire. It is what turns "an alarm went
red" into "here is what happened, and here is the evidence".

## Importing an automation

Each file is a whole automation — name, definition, and the AI setting —
not just the task graph. In NudgeBee: **Automations → new automation → the JSON
panel → paste the file → Apply → Save.** The same JSON is the body
`POST /workflows` takes, if you would rather script it.

Two things to set after the first import:

- **The AWS account.** Automations that take an `account_id` ship without a
  default on purpose, so nothing points at somebody else's account by
  accident. Pick yours.
- **"Allow the AI assistant to run this automation"** (automation settings, AI
  Assistant). It is `ai_invocable: true` in every file here, but it only has an
  effect on tenants where AI tools are switched on. If the assistant never
  offers to run one of these, check this first.

Anything else with a blank default is listed under "What to fill in" below.

## What's here

| File | What it does | Trigger | Needs |
|---|---|---|---|
| `ec2-investigation.json` | Metric datapoints, SSM command history, and a read-only inspection of the host, for one EC2 instance over a window | EC2 alarm, or manual | lab tier |
| `aws-resource-investigation.json` | Metric datapoints and CloudTrail activity for any resource with a CloudWatch metric — RDS, Lambda, ECS, ALB, DynamoDB, ElastiCache | manual | any AWS resource |
| `application-diagnostic-check.json` | First-level application triage: instance state, alarms, CPU, load balancer target health, application logs, on-host evidence, dependency probes | manual | lab tier, load balancer tier for the target-health checks |
| `db-diagnostics-postgresql-ec2.json` | Six-category PostgreSQL check — connectivity, resource use, blocking sessions, replication, storage, database errors | `pg_*` alarm, or manual | db tier + database integration |
| `db-connection-troubleshooting-postgresql-ec2.json` | Why a client cannot connect: DNS and TCP from the client, security group and NACL rules, server availability, connection headroom, authentication failures — ranked into a likely cause | `pg_*` alarm, or manual | db tier + database integration; SSH integration optional |
| `db-log-analysis-postgresql-ec2.json` | PostgreSQL log errors for the incident window, grouped by SQLSTATE and compared against a baseline | `pg_*` alarm, or manual | db tier |

The event triggers match the alarms this lab actually raises: the EC2 one on
`CPUUtilization`, `StatusCheckFailed*`, `mem_used_percent`, `disk_used_percent`
and `NetworkOut`; the database ones on `pg_up`, `pg_connections_pct` and
`pg_blocked_sessions`, which are the three the db tier publishes. Nothing fires
on an alarm the lab cannot produce.

## What to fill in

Values specific to one deployment were stripped from these exports, so they
are blank and the automation asks for them. Every one comes from a stack
output — `aws cloudformation describe-stacks --stack-name <stack> --query
'Stacks[0].Outputs'`:

| Input | Where it comes from |
|---|---|
| `db_host` | `DbPrivateIp`, db stack |
| `db_instance_id` | `DbHostId`, db stack |
| `client_instance_id` | `Host1Id`, lab stack — the host that talks to the database |
| `integration_name` | the database integration you create below |
| `log_group` (db log analysis) | already defaults to `/nudgebee-scenario-lab/postgresql`, which is what the db tier creates |

## The database automations need a database integration

Two of the three run SQL, and NudgeBee runs SQL through an integration rather
than through the AWS API. Create one against the lab database:

| Field | Value |
|---|---|
| Type | PostgreSQL |
| Host | the db stack's `DbPrivateIp` |
| Port | `5432` |
| Database | `labdb` |
| User | `labapp` |
| Password | `labapp-not-a-secret` |

That password is a fixed lab throwaway, written into
`infra/cloudformation/db.yaml` and printed here on purpose — the role owns one
toy table with two rows in it and nothing else.

Then put the integration's **name** in the `integration_name` input. It is
resolved by name, not id.

**The query runs from your NudgeBee agent**, not from NudgeBee's servers, so
the agent needs to reach that private address. If it cannot, the query tasks
fail with a connection error and the automation says so — which looks exactly
like the database being down, so rule this out first when every check fails at
once.

`db-log-analysis-postgresql-ec2.json` needs no integration: it reads
CloudWatch Logs through the AWS account you already connected.

## The knowledge-base article

`knowledge-base/AWS_alarm_investigation.txt` goes in as a knowledge-base
document scoped to the AWS agent. It is the part that stops "CPU is high"
becoming "the instance is too small": it tells the assistant to fetch evidence
before concluding, which automation to use for which resource, how to choose
the window, and how to read a result honestly — including that an empty result
is not proof that nothing happened.

Import it against your AWS cloud account, not globally.

## Keeping these in step

These are exports of live automations, so they drift the moment somebody edits
one in the UI. The definitions came from the `workflows` table; if you change
one in NudgeBee and want the change kept, re-export it into the matching file
here rather than editing both by hand.
