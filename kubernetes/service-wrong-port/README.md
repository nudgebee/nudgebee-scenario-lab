# Service pointing at the wrong port — refused, while everything looks up

A Service says traffic on port 80 goes to port 8081 on the pod. The pod listens
on 8080. Every call is refused instantly, but the pods are Running and Ready,
the Service has endpoints, and there are no warning events. No alert fires.

```bash
./run.sh break
```

## What it does

1. Deploys `order-worker`, which calls `inventory-api` every 10 seconds, and confirms the call works
2. Changes the Service's `targetPort` from 8080 to 8081, the kind of edit a "standardise our ports" change makes
3. Confirms the calls now fail

## Why it's easy to miss

The usual "Service is broken" check is *does it have endpoints?* It does: the
endpoint is the right pod, on port 8081. Readiness doesn't catch it either,
because the probe (if any) talks to the container directly, not through the
Service. The answer is in comparing two numbers on two objects: the Service's
`targetPort` and the container's port.

## The naive answer

> The app isn't listening, restart it.

The app is listening, on 8080. A restart changes nothing.

## What to do in NudgeBee

There is no alert, so ask:

> order-worker in nudgebee-demo keeps failing its stock checks against
> inventory-api with connection refused. The pods are all up. What's wrong?

A good answer:

- says the Service `inventory-api` forwards to `targetPort` 8081
- says the container listens on 8080, so connections are refused even though endpoints exist
- recommends setting `targetPort` to 8080, or to the named port `http` so this can't drift again

Then fix it, or let NudgeBee:

```bash
./run.sh fix
```
