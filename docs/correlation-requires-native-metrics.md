# Correlation only happens on recognised AWS metric namespaces

Measured on the Rackspace environment, 4 September 2026, account `aws-dev`
(`00666e9f-3774-4f5d-b86c-60b201ae18c5`).

## What we saw

Three services with a real dependency between them (`payment` and `inventory`
both call `order`). Stopping `order` failed all three. Three alarms fired,
three events reached NudgeBee, and **no correlations were produced** — not a
wrong parent, no output at all.

Three runs, each fixing a genuine defect the previous run exposed, and the
count stayed at zero. Grouping every event on the account by subject type
showed why:

| subject_type | namespace | events | correlations |
|---|---|---|---|
| `compute-instance` | AmazonEC2 | 35 | **24** |
| `cluster` | AmazonECS | 27 | **20** |
| `alarm` | CloudWatch | 22 | **0** |

Events typed `alarm` never correlate. Events typed as an actual resource do.

## Why

NudgeBee classifies an incoming CloudWatch alarm by the **metric namespace**.
A recognised AWS namespace (`AWS/EC2`, `AWS/ECS`, `AWS/RDS`) yields a subject
typed as the resource — `compute-instance`, `cluster`, `db` — which the
correlation engine can locate in the knowledge graph and traverse.

An unrecognised namespace has no resource type to map to, so the subject falls
back to the alarm itself: `subject_type: alarm`, `subject_namespace:
CloudWatch`. Correlation skips those.

This holds **even when `cloud_resource_id` is populated**. We confirmed that
directly: all three events resolved to real cloud resources, the dependency
graph contained correct `CALLS` edges between exactly those resources, and the
correlation count was still zero. Resolving to a resource is not sufficient —
the type is what gates it.

## Why this matters beyond the lab

Application health is rarely a native AWS metric. A service being up, a queue
depth, a login success rate, a business transaction rate — these are custom
metrics by nature. On the current behaviour none of them can participate in
correlation, no matter how well dimensioned or how accurately they resolve to
a host.

For the Rackspace Phase 1 use cases this is directly load-bearing. The AppOps
scenario is "the application is unreachable, and the cause is underneath it".
If the application-level signal is a custom metric, it will arrive as
`subject_type: alarm` and be excluded from the very correlation the scenario
is meant to demonstrate.

## What the lab does about it

The cascade drives a **native** signal instead. When a service's upstream
fails it retries, and retrying costs CPU — so a dependency failure shows up as
`AWS/EC2 CPUUtilization` on the hosts of the affected services. That is
realistic rather than staged: a service hammering a dead dependency is exactly
what happens in production.

The custom `ServiceHealthy` metric is still published and still alarms. It is
what the control panel reads, and it states the failure precisely. It simply
cannot be the signal correlation works from.

## Two related defects found the same day

**The subject mapper picks between dimensions non-deterministically.** With an
alarm carrying both `Service` and `InstanceId`, three structurally identical
alarms produced two different outcomes: two resolved to the instance, one to
the service name and therefore to no cloud resource at all. The one that lost
was the parent of the cascade. Keying the alarm on a single dimension avoids
it, but the mapper is still choosing arbitrarily for anyone else.

**A custom-namespace alarm gives no signal that it will never correlate.** It
is accepted, stored, displayed and analysed. Nothing reports that it has been
excluded from correlation. From outside, a correctly-configured alarm and one
that can never participate look identical.
