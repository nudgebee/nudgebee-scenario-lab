# Upstream rate limit — checkout fails, and the cause is a job in another namespace

A shop: `storefront` → `checkout` → `payments-gateway`. The card processor
behind `payments-gateway` allows 20 calls a second for the whole account,
shared by everyone who calls it. A batch job in another namespace,
`ledger-reconcile`, is changed from 1 worker to 20 to get it done sooner. It
now takes most of the processor's limit. `payments-gateway` answers
`429 Too Many Requests` to whatever goes over, and `checkout` turns each 429
into a 503 for shoppers. About half the orders fail.

Two alarms fire, one on `checkout` and one on `payments-gateway`. Every pod is
Running and Ready, nothing restarts, and there are no warning events. The cause
is a change in a namespace neither alarm points at.

```bash
./run.sh deploy   # healthy; give NudgeBee's service map time to see the calls
./run.sh break    # later
```

## What it does

1. `deploy` starts `storefront` (5 orders a second), `checkout` and
   `payments-gateway` in `nudgebee-demo`, and `ledger-reconcile` (1 worker,
   2 calls a second) in `nudgebee-demo-batch`. It confirms orders go through,
   then adds two alarm rules and a scrape of the services' request counts
2. `break` changes `ledger-reconcile` from 1 worker to 20, so 40 calls a second
   against a limit of 20, and confirms that `checkout` now fails orders

| | Calls a second to `payments-gateway` | Refused | `checkout` orders failing |
|---|---|---|---|
| Healthy | ~7 (checkout 5, ledger-reconcile 2) | none | none |
| After `break` | ~45 (checkout 5, ledger-reconcile 40) | ~25 | about half |

## Deploy first, break later

What this scenario tests is whether NudgeBee connects the `checkout` alarm to
the `payments-gateway` alarm, and both to a change in another namespace. It
links alarms through its service map, which learns that `checkout` calls
`payments-gateway` from live traffic. So run `deploy`, wait until the map shows
`checkout` → `payments-gateway` (up to an hour), then `break`. `break` on its
own deploys first, but the alarms may then arrive before the map knows the link.

## The alarms

| Alarm | Fires when | After `break` |
|---|---|---|
| `PaymentsGatewayRateLimited` | `payments-gateway` refuses more than 1 call a second, for a minute | ~2 minutes |
| `CheckoutErrorRateHigh` | more than 10% of `checkout` orders fail with a 5xx, for 2 minutes | ~3 minutes |

`deploy` creates them as a `VMRule` (VictoriaMetrics operator) or a
`PrometheusRule` (Prometheus operator), whichever the cluster has, with a
`VMPodScrape` or `PodMonitor` for the request counts. They reach NudgeBee the
way your other alerts do: Alertmanager sends them to the NudgeBee agent. Each
carries a `deployment` label, so NudgeBee files it under the right workload.
Alertmanager groups the two, so the second can reach NudgeBee a few minutes
after it fires (its `group_interval`, often 5 minutes).

| Variable | Default | Change it when |
|---|---|---|
| `SEVERITY` | `warning` | your Alertmanager sends only some severities to NudgeBee, or pages people on `warning` |
| `MONITOR_LABELS` | none | your Prometheus only picks up rules and monitors with a label, e.g. `release=kube-prometheus-stack` |
| `ALERTS` | `auto` | `vm` or `prometheus` to choose; `none` for no alarms, and you ask NudgeBee instead |
| `LIMIT`, `WORKERS` | `20`, `20` | the processor's calls a second, and `ledger-reconcile`'s workers after `break` (2 calls a second each) |

## Why it's easy to miss

The alarm is on `checkout`, and `checkout`'s logs only say `payments-gateway`
answered 429. `payments-gateway` is healthy too: it is doing exactly what the
limit says. The question that finds the cause is *who is using the limit?*
`payments-gateway`'s logs name its callers, and `ledger-reconcile`, in a
different namespace, makes about 8 of every 9 calls. Then: what changed? Its
Deployment went from 1 worker to 20 a couple of minutes before the first alarm.

## The naive answer

> checkout is failing. Restart it, or add replicas.

`checkout` is fine, and more replicas make the same calls. Or:

> payments-gateway is overloaded. Scale it.

The limit is the processor's, for the whole account. More gateway replicas
share the same 20 calls a second.

## What to do in NudgeBee

Open the `CheckoutErrorRateHigh` alarm and investigate it, or ask:

> checkout in nudgebee-demo started failing orders with 503 a few minutes
> ago. Its pods look fine. What's wrong?

A good answer:

- says `checkout`'s 503s are `payments-gateway` answering 429, and links the two alarms
- says the processor's 20 calls a second are shared, and names `ledger-reconcile` in `nudgebee-demo-batch` as the caller using most of them
- ties it to the change on `ledger-reconcile`, `WORKERS` 1 → 20, just before the alarms
- recommends taking `ledger-reconcile` back down, or giving it a budget of its own, not restarting or scaling `checkout`

Then fix it, or let NudgeBee:

```bash
./run.sh fix   # ledger-reconcile back to 1 worker; orders go through again
```

## Needs

- Permission to create namespaces, Deployments, Services and ConfigMaps, and to
  `exec` into pods: `run.sh` reads the services' counts from inside the
  `storefront` pod. Everything goes in `nudgebee-demo`, shared with the other
  scenarios, except `ledger-reconcile`, which gets `nudgebee-demo-batch`.
  `cleanup` deletes only what carries this scenario's label, and the batch
  namespace only if `deploy` created it. `NS` and `BATCH_NS` change the names
- The `python:3.12-alpine` image; `IMAGE` overrides it. All four services are
  one standard-library Python file, [`shop.py`](shop.py)
- For the alarms: permission to create a `VMRule` and `VMPodScrape`
  (VictoriaMetrics operator) or a `PrometheusRule` and `PodMonitor` (Prometheus
  operator), and Alertmanager sending alerts to the NudgeBee agent
- For NudgeBee to link the alarms: a service map that sees pod-to-pod calls,
  from the agent's eBPF node agent or from traces

```bash
./run.sh status    # orders, refusals, worker count, last log lines
./run.sh cleanup
```
