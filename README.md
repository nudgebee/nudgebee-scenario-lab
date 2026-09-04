# NudgeBee Scenario Lab

**See what NudgeBee does during a real incident — without waiting for one.**

This sets up a few small, throwaway servers in your own AWS account, then lets
you break them on purpose. High CPU. Full disk. A service that won't start.
NudgeBee notices, investigates, and explains what happened — and you get to
watch it work on a problem you created thirty seconds ago.

Everything is temporary. Every scenario stops by itself, one button puts
everything back, and deleting the lab takes one command.

![Starting a scenario and watching the alarm fire](docs/media/scenario-lab-demo.gif)

*Pick a scenario, press Start, and the alarm goes red about three minutes
later — the same alarm NudgeBee picks up and investigates.*

---

## Is this safe?

Yes, with one rule: **use a test or sandbox AWS account, not production.**

The scenarios deliberately overload the servers they run on. That's the point.
But they only ever touch the servers this lab creates, and:

- Every scenario stops on its own after a few minutes
- **Reset everything** stops them all immediately and cleans up
- Nothing is opened to the internet — no inbound access at all
- Nothing here reads or touches anything else in your account

## What it costs

About **$19 a month** if you leave it running — roughly the price of two
coffees. Most of that is two small servers.

You'll almost certainly delete it the same day. A few hours costs cents.

---

## Getting started

You'll need someone who can run commands on a Mac or Linux machine and has
access to your AWS account. It takes about ten minutes.

### 1. Check your account is ready

```bash
./scripts/preflight.sh
```

This only looks — it changes nothing. It tells you whether your AWS account
has the permissions the lab needs, and whether NudgeBee is set up to receive
alerts from it.

### 2. Create the lab

```bash
./scripts/deploy.sh
```

Takes about four minutes. It asks nothing and needs no configuration — it
builds its own private network so it can't land anywhere near your real
systems.

### 3. Open the control panel

```bash
./scripts/run-local.sh
```

Then open **http://127.0.0.1:8080** in your browser.

The panel runs on your own machine, using your own AWS access. Nothing is
hosted by NudgeBee and nothing is sent anywhere.

### 4. Break something

Pick a scenario, press **Start**. Then watch NudgeBee.

An alarm appears in about three minutes. The event shows up in NudgeBee
shortly after, and it starts investigating on its own.

### 5. Put it back

Press **Reset everything**. Or just wait — scenarios expire by themselves.

### 6. Delete the lab when you're done

```bash
aws cloudformation delete-stack --stack-name nudgebee-scenario-lab
```

Everything the lab created disappears. Nothing is left behind and billing stops.

---

## What you can break

| Scenario | What it looks like |
|---|---|
| CPU saturation | The server is pinned at 100% and everything on it slows down |
| Memory pressure | Memory runs out, but nothing crashes — it just degrades |
| Disk fill | The disk fills up until things start failing |
| Disk I/O saturation | The disk is so busy the server looks overloaded |
| Network spike | The server floods its network connection |
| Runaway scheduled job | A job fires every minute and keeps burning CPU |
| Service failure | A service fails to start and keeps retrying forever |
| Zombie processes | Hundreds of stuck processes pile up |

**The interesting part isn't whether NudgeBee spots the alarm.** Any monitoring
tool does that. It's whether it can tell you *why*.

Each scenario has an obvious wrong answer. "High CPU" usually gets diagnosed as
"the server is too small — make it bigger", when the real cause was a command
someone ran two minutes earlier. The runaway scheduled job is the clearest
example: the cause isn't a process at all, it's a schedule, and no amount of
looking at what's running right now will find it.

That's what you're evaluating.

---

## The waste tier (optional)

```bash
./scripts/deploy.sh waste
```

This creates deliberately wasteful and misconfigured resources — an unused
disk, an oversized server, a security group left wide open. Nothing needs to be
triggered; the problem *is* that they exist. NudgeBee should find them on its
own within a sync cycle.

It's the quicker demo of the two: no scenarios to run, just deploy and look.

One thing to know: the oversized-server finding needs a few days of history
before it appears. That's expected, not a fault.

---

## Two things people get wrong

**Connecting your AWS account to NudgeBee isn't enough.** Alert forwarding has
to be switched on separately, or alarms fire in AWS and never reach NudgeBee.
`preflight.sh` checks this and tells you if it's missing.

**Servers take a minute or two to come online** after the lab is created. The
control panel enables the Start buttons by itself once they're ready — you
don't need to do anything.

---

## For the technically minded

- `infra/cloudformation/` — what gets created in AWS
- `scenarios/catalogue.yaml` — the scenarios; adding one is a few lines of YAML
- `control/` — the local control panel (Python, no external services)
- `nudgebee/` — automations and a knowledge-base article to import into NudgeBee
- `scripts/verify-scenarios.sh` — checks every scenario still actually works

Full detail lives in each of those directories.
