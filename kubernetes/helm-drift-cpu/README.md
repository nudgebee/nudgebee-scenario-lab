# Helm drift: a CPU request edited three times with kubectl

Someone is chasing slowness. They don't go through Helm; they edit the CPU
request by hand, three times: 100m → 250m → 500m → `1000`. They meant `1000m`.
`1000` is a thousand cores.

```bash
./run.sh break      # takes ~12 minutes: the edits are spaced out
```

## What it does

1. Installs the Helm release `pricing-engine` (chart in [`../helm-drift-chart`](../helm-drift-chart)), CPU request 100m
2. `kubectl patch` to 250m, waits, to 500m, waits (`STEP_WAIT`, default 240s)
3. `kubectl patch` to `1000`
4. Waits for the new pod's `FailedScheduling`

The rollout keeps the old pod until the new one is Ready, and the new one never
will be. So **the service keeps working** and nothing looks down. The
Deployment reports `ProgressDeadlineExceeded` after two minutes and stays there.

## What makes it interesting

It's a history question. The evidence is spread over time:

- one Helm revision, at 100m
- four ReplicaSets, created minutes apart, with CPU requests 100m, 250m, 500m and 1000
- a Pending pod with `Insufficient cpu`

A good answer reconstructs the sequence, not just the last step.

## The naive answer

> The cluster is out of CPU, add nodes.

No node anywhere has a thousand cores. Adding nodes changes nothing, and on a
cluster with node auto-provisioning it can cost money trying.

## What to do in NudgeBee

> The pricing-engine rollout in nudgebee-demo looks stuck and a pod has been
> Pending for a while. Nobody ran a deploy. What happened?

A good answer:

- says the CPU request was changed with `kubectl`, outside Helm, three times, with the values
- says the last value, `1000`, is a thousand cores, likely meant as `1000m`, so the pod can't be scheduled
- recommends rolling back to the Helm-defined state, not a fourth hand-edit

## Fix

```bash
./run.sh fix
```

Same as the memory scenario: `helm rollback` to the deployed revision, with
`--force-conflicts` on Helm 4.
