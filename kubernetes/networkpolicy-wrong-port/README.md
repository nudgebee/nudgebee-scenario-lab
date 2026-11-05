# NetworkPolicy on the wrong port — a failure nothing alerts on

Someone locks a service down with a NetworkPolicy: only the web shop may call
the cart API, on port 80. It looks right. Port 80 is the port in the Service.

From then on every request from the web shop hangs. But every pod is Running
and Ready, the Service has its endpoints, nothing restarts, and there are no
warning events. No alert fires. The first person to notice is a user.

```bash
./run.sh break
```

## What it does

1. Deploys `web-shop`, which calls `cart-api` every 10 seconds, and confirms the call works
2. Applies a NetworkPolicy that allows only `web-shop` into `cart-api`, on TCP port 80
3. Confirms the calls now time out, and stops if they don't (see below)

## Why port 80 is wrong

The Service listens on 80 and forwards to 8080 on the pod. A NetworkPolicy is
checked against the port the packet arrives on *at the pod*, after the Service
has translated it, so the rule has to say 8080. Nothing allows 8080, and
because a policy now selects `cart-api`, anything not allowed is dropped.

Finding that means putting three objects side by side: the policy (80), the
Service (80 → 8080) and the container (8080). Each one looks fine on its own.

## The naive answer

> A NetworkPolicy is blocking the traffic. Delete it.

Half right, and the fix throws away the lockdown somebody wanted. The useful
answer names the port and keeps the policy.

## What to do in NudgeBee

There is no alert, so ask, the way a user would report it:

> web-shop in nudgebee-demo can't load the cart, requests to cart-api just
> hang. All the pods look healthy. What's going on?

A good answer:

- points at the policy `allow-web-shop-to-cart-api`, though nothing is failing
- says it allows port 80 (the Service port) while `cart-api` listens on 8080
- recommends allowing 8080, or the named port `http`, rather than deleting the policy

Then fix it, or let NudgeBee:

```bash
./run.sh fix
```

## Needs

A CNI that enforces NetworkPolicy: Calico, Cilium, GKE Dataplane V2 and most
managed defaults do; plain flannel and kindnet don't. `break` checks: if traffic
still flows after the policy is applied, it removes the policy and stops, rather
than leave you a scenario where the "fault" does nothing.

`cleanup` deletes only this scenario's resources, not the namespace, which other
scenarios share.
