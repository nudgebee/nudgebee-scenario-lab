# Ingress with a typo in the host — 404 for everyone, nothing wrong anywhere

Someone edits an Ingress and the host becomes `catalog.exmaple.test`. Users
keep asking for `catalog.example.test`, the controller has no rule for that
name, and answers with its default 404. The app is fine, the Service is fine,
the Ingress class is right. No alert fires.

```bash
./run.sh break
```

## What it does

1. Deploys `catalog-web` behind an Ingress for `catalog.example.test`, plus
   `catalog-probe`, which calls the site by that name through the ingress
   controller the way a browser would, and confirms it works
2. Changes the rule's host to `catalog.exmaple.test`
3. Confirms the probe now gets 404

## Why it's easy to miss

A 404 points at the app ("the route is missing"), and the app's own logs show
nothing, because the request never reaches it. Everything you'd check for a
broken backend is green. The answer is a two-letter swap in a hostname, and
you only see it if you compare the host users ask for with the hosts the
Ingress actually serves.

## The naive answer

> The app is returning 404, check its routes.

The app never sees the request.

## What to do in NudgeBee

There is no alert, so ask:

> Users get a 404 on http://catalog.example.test/ since this morning.
> catalog-web in nudgebee-demo looks healthy. What's going on?

A good answer:

- says the Ingress `catalog-web` serves `catalog.exmaple.test`, not `catalog.example.test`
- says the 404 comes from the ingress controller's default backend, not from the app
- recommends correcting the rule's host

Then fix it, or let NudgeBee:

```bash
./run.sh fix
```

## Needs

An ingress controller. Defaults to ingress-nginx (`INGRESS_CLASS=nginx`,
`INGRESS_URL=http://ingress-nginx-controller.ingress-nginx.svc.cluster.local`);
set both for Traefik or another controller. `break` checks the site works
through the controller before breaking it, so a wrong `INGRESS_URL` stops
there instead of giving you a scenario that was never healthy.
