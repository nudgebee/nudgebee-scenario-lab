# Kubernetes scenarios

**Break something in your own cluster and watch NudgeBee work out what happened.**

The rest of this lab builds throwaway EC2 servers for you. These don't. They run
against a cluster you already have, with the NudgeBee agent already installed,
and they only ever touch a namespace they create themselves.

That trade is deliberate. Kubernetes failures are interesting because of what
surrounds them — the workload that owns the pod, the config it reads, the
history of what changed. A cluster spun up sixty seconds ago has none of that.
Your cluster does.

## What you need

- A Kubernetes cluster and `kubectl` pointed at it
- The [NudgeBee agent](https://github.com/nudgebee/k8s-agent) installed and connected
- Permission to create a namespace and a Deployment in it

Use a test or staging cluster. The scenarios are small and self-contained, but
they do deliberately break things, and one of them restarts the agent.

## Scenarios

| Scenario | What it looks like |
|---|---|
| [CrashLoopBackOff](crashloop-backoff/) | A service won't start. It restarts, dies, backs off, and restarts again — and the reason is in a config value nobody looked at |

## How these differ from the AWS scenarios

| | AWS scenarios | Kubernetes scenarios |
|---|---|---|
| Infrastructure | The lab creates it | Yours, already running |
| Trigger | Control app or CLI, over SSM | A script you run with `kubectl` access |
| Signal | CloudWatch alarm | The agent's own event, from the Kubernetes API |
| Cleanup | Self-limiting, plus **Reset everything** | `./run.sh cleanup` deletes the namespace |

There is no countdown and no automatic expiry here: the broken workload stays
broken until you fix it or delete it. That is the point of the scenario — an
alert that closes itself while the problem is still happening teaches you
nothing.
