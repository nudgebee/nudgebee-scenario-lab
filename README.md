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

With the database tier deployed, six more:

| Scenario | What it looks like |
|---|---|
| Database connection saturation | The database runs out of connection slots |
| Leaked connection pool | Connections are held open inside transactions and never returned |
| Blocking chain | One transaction holds a lock and everything queues behind it |
| Database stopped | The database is down and refuses connections outright |
| Database port filtered | Connections hang — the database is fine, the packets aren't arriving |
| Authentication failures | The password is rejected, over and over |

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

## The database tier (optional)

```bash
./scripts/deploy.sh db
```

Adds one small PostgreSQL server (~$15/mo) so the database scenarios have
something real to break. Deploy the lab tier first — this reuses its network,
and opens port 5432 to the lab servers and nothing else.

Everything runs on the database server itself over a local connection, so no
scenario needs a password and no credential ever leaves the host.

**Why a server and not RDS.** These scenarios are about the self-managed case.
A managed database comes with its own alarms and its own performance tooling;
a database you run yourself has none of that, so the things that actually go
wrong — running out of connections, a blocking chain, a leaked pool — raise no
alert at all until something publishes them. That publisher is installed for
you, which is what turns a database problem into an alert rather than something
a person has to notice first.

**Two of the six raise no alarm, on purpose.** A filtered port and a rejected
password are invisible to every host metric — the server looks perfectly
healthy the whole time. That is precisely why connection failures get blamed on
the database. They are there to be diagnosed, not detected, and inventing an
alarm that half-worked would teach the wrong lesson.

The clearest pair to run back to back is **Database stopped** and **Database
port filtered**. Both look like "can't connect". One refuses instantly, the
other hangs until it times out — and that single difference is what separates a
database problem from a network problem. Any answer that calls both of them
"unreachable" has thrown away the only bit that decides who fixes it.

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
