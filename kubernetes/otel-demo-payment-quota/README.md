# Payment quota on the OpenTelemetry demo — checkout fails, and the cause is a new batch job

This scenario runs on the [OpenTelemetry demo](https://opentelemetry.io/docs/demo/)
(the Astronomy Shop), not on workloads of its own. It is the same story as
[Upstream rate limit](../upstream-rate-limit/), told with a real
multi-language app and its traces instead of a small Python shop.

`checkout` charges every order through `payment`. A card processor allows a
merchant account a number of calls a second, shared by everything that calls it;
`setup` adds that quota to the demo, 5 calls/s in front of `payment`. Normal
demo traffic is far below it. `break` starts a settlement batch that also
charges through `payment`, at 20 calls/s. The quota is gone: `payment` refuses
about three calls in four with `RESOURCE_EXHAUSTED`, whoever made them, and
`checkout` fails the orders whose charge was refused.

Two alarms fire, on `checkout` and on `payment`. Every pod is Running and
Ready. The cause is neither of them: it is a workload that started sharing the
quota.

```bash
./run.sh setup    # the quota and two alarm rules; then wait at least 2 hours
./run.sh break    # the batch; it stops by itself after 14 minutes
```

## Unlike the other scenarios, this changes your demo

`setup` adds a sidecar, `processor-gateway` (Envoy, from the demo's own
`frontend-proxy` image), to the demo's `payment` Deployment. It takes payment's
port and forwards to the service on the next port, so the Service, checkout's
`PAYMENT_ADDR` and every service-map edge stay the same. Its counters go
through the demo's own collector, so they reach your metrics backend the way
the demo's do. That gives `payment` RPC metrics: the stock service reports
only its transaction count and Node.js runtime metrics.

`cleanup` removes the sidecar again, but only if `setup` added it. The fork at
[nudgebee/opentelemetry-demo](https://github.com/nudgebee/opentelemetry-demo)
installs the same sidecar from its Helm values, as fault `mj-06`, and
`cleanup` leaves that one alone.

## Wait before you break it

If the sidecar is the newest change on `payment` when the alarms fire, an
investigation blames that change ("a restrictive quota was just added") and
never asks who is using the quota. The first run did exactly that, with the
sidecar 19 minutes old. A real processor limit has been there for months.

So `break` refuses to run until `payment` last changed at least
`MIN_AGE_MINUTES` ago (120 by default). `FORCE=1` overrides it, for testing
the mechanics only.

## What it does

1. `setup` adds the sidecar unless it is already there, then the two alarm
   rules, and a route for them if you set `ALERT_WEBHOOK`
2. `break` starts Job `mj-06`, a `settlement-sync` batch of 8 workers charging
   at 20 calls/s in total, and waits until the quota refuses calls. The Job
   carries the same id and label as the fork's fault, so its `fault.sh status`
   and `stop` see it too
3. The batch exits by itself after `DURATION` (14 minutes), so the Job
   completes rather than fails

| | Calls a second to `payment` | Refused | `checkout` orders failing |
|---|---|---|---|
| Normal | under 1 (checkout) | none | none |
| During `break` | ~20 (the batch) + checkout | ~15 | about two in three |

Measured on the first run: the gateway let 5.0 calls/s through and refused
14.9, and 67% of `PlaceOrder` calls failed. The checkout alarm fired 1.6
minutes after the start.

## The alarms

| Alarm | On | Fires when |
|---|---|---|
| `OtelDemoGRPCServerErrorRate` | `checkout` | more than 1% of `PlaceOrder` calls fail, for a minute |
| `OtelDemoPaymentQuotaExhausted` | `payment` | the quota refuses more than 0.5 calls/s, for a minute |

They have the same names as the rules in the fork's alert pack. Each carries a
`deployment` label, which is what NudgeBee files the alarm under.

| Variable | Default | Change it when |
|---|---|---|
| `NS` | `demo` | the demo runs in another namespace |
| `IMAGE_BASE` | from `payment`'s image, e.g. `ghcr.io/open-telemetry/demo:3.0.0` | your demo's images do not follow `<repo>:<version>-<service>`; the sidecar and the batch use `<IMAGE_BASE>-frontend-proxy` and `-recommendation` |
| `SEVERITY` | `warning` | your Alertmanager sends only some severities to NudgeBee, or pages people on `warning` |
| `ALERT_WEBHOOK` | none | your Alertmanager does not already send these alarms to NudgeBee: set it to the agent's `http://<runner service>.<namespace>.svc/api/alerts`, and `setup` adds a route for just these two alarms |
| `MONITOR_LABELS` | none | your Prometheus only picks up rules with a label, e.g. `release=kube-prometheus-stack` |
| `ALERTS` | `auto` | `vm` or `prometheus` to choose; `none` for no alarms, and you ask NudgeBee instead |
| `LIMIT`, `RATE`, `WORKERS`, `DURATION` | `5`, `20`, `8`, `840` | the quota, the batch's calls a second, its threads, and how long it runs (seconds) |
| `MIN_AGE_MINUTES`, `FORCE` | `120`, unset | how old payment's last change must be for `break`; `FORCE=1` skips the check |

If your Alertmanager's top-level routes stop on your severity before reaching
namespace routes, the `ALERT_WEBHOOK` route never sees the alarms. Pick a
`SEVERITY` those routes do not match.

## The naive answers

> payment just got a rate limiter. Roll it back, or raise the limit.

The limit is the processor's; it was fine for months. The batch is new.

> checkout is failing. Restart it, or add replicas.

`checkout` is healthy, and more replicas make the same calls.

## What to do in NudgeBee

Open the `OtelDemoGRPCServerErrorRate` alarm on `checkout` and investigate it.
A good answer:

- says checkout's failures are `payment` refusing calls with `RESOURCE_EXHAUSTED`, and links the payment alarm as their cause
- says the quota is shared by every caller, and names the `settlement-sync` batch (Job `mj-06`) as the caller using most of it. The sidecar's log names the caller of every refused call
- recommends stopping or slowing the batch, or giving it a quota of its own, not rolling back `payment`

Then fix it, or let NudgeBee:

```bash
./run.sh fix       # stops the batch now
```

## Needs

- The OpenTelemetry demo, installed with its Helm chart (tested with 3.0.0),
  with its collector shipping metrics to the backend NudgeBee reads
- Permission to patch the demo's `payment` Deployment and to create a Job and
  ConfigMaps in its namespace
- For the alarms: permission to create a `VMRule` (VictoriaMetrics operator)
  or a `PrometheusRule` (Prometheus operator), plus the matching Alertmanager
  config kind if you set `ALERT_WEBHOOK`
- For NudgeBee to link the alarms: a service map that sees checkout calling
  payment, from the agent's eBPF node agent or from traces

```bash
./run.sh status    # quota, refusals in the last minute, the batch
./run.sh cleanup   # the batch, the rules, the route, and the sidecar if setup added it
```
