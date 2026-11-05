# Helm drift: a memory limit changed with kubectl

The release says 128Mi. Someone runs `kubectl patch` and makes it 24Mi. Helm
isn't told: its revision doesn't change, and `helm get values` still says
128Mi. The pod is OOMKilled on every start.

```bash
./run.sh break
```

## What it does

1. Installs the Helm release `recommendation` (chart in [`../helm-drift-chart`](../helm-drift-chart)),
   memory limit 128Mi, process holds ~40Mi, and waits for it to be healthy
2. `kubectl patch` sets the limit to 24Mi
3. Waits until the pod has been OOMKilled at least twice

The release uses `Recreate`, so the bad pod replaces the good one: the service
is down, not just degraded.

## What makes it interesting

The OOMKill is loud, so finding *that* something is wrong is easy. The
question is *what changed*, and nobody ran a deploy. The evidence:

- `helm history`: still one revision, nothing new
- `helm get values` / `helm get manifest`: 128Mi
- the live Deployment: 24Mi
- `metadata.managedFields`: `limits.memory` owned by `kubectl-patch`, set seconds after Helm's apply

## The naive answers

> The app needs more memory, raise the limit.

It had enough. Somebody took it away.

> `kubectl patch` the limit back to 128Mi.

Fixes the pod, but leaves a second hand-edit on top of the first, and the next
person still finds the cluster and the release disagreeing about who owns the
field. Put it back through Helm.

## What to do in NudgeBee

1. **Did it notice on its own?** The OOMKill raises an alert: look under
   Troubleshoot → Pod Errors for `recommendation`, and read the investigation.
2. **Ask it:**

   > recommendation in nudgebee-demo keeps getting OOMKilled. It was fine this
   > morning and nobody deployed. What happened?

A good answer:

- says the memory limit was changed from 128Mi to 24Mi with `kubectl`, outside Helm
- backs that with the release (still 128Mi, same revision) against the live object
- recommends rolling back to the Helm-defined state, not another `kubectl` edit

## Fix

```bash
./run.sh fix
```

This runs `helm rollback` to the deployed revision. **On Helm 4 a plain
rollback fails**: Helm 4 applies server-side, `kubectl` now owns the limit, and
the apply stops on that field conflict. `fix` adds `--force-conflicts` on Helm 4.
Helm 3's three-way merge restores the field without it.

After the rollback, `managedFields` show `helm` owning the limit again and the
`kubectl-patch` entry gone, so the next `helm upgrade` applies cleanly.
