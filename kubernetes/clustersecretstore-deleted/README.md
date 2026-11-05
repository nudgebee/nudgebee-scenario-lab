# Deleted ClusterSecretStore: three outages, one cause

Four services get their credentials from External Secrets, all through one
cluster-wide store. Someone deletes the store. Nothing happens: the Secrets
are already written, and running pods keep them. Later the credentials are
rotated and the pods restart, and three services in two namespaces fail to
start, each complaining about a different missing Secret.

```bash
./run.sh break
```

Needs [External Secrets Operator](https://external-secrets.io) (the
`external-secrets.io/v1` API, v0.17 or later). The store uses ESO's built-in
`fake` provider, so no Vault or cloud secret manager is involved.

## What it does

1. Creates ClusterSecretStore `shop-secrets` and four ExternalSecrets that read
   from it: `checkout-db`, `payment-gateway`, `orders-db` (in `nudgebee-demo`)
   and `invoice-smtp` (in `nudgebee-demo-billing`). Starts `checkout-api`,
   `orders-api` and `invoice-worker` on those Secrets, and waits until all of
   them are synced and running
2. Also starts `catalog-api`, whose Secret comes from a namespaced SecretStore,
   not the cluster one. It stays healthy throughout
3. Deletes the ClusterSecretStore and waits until the four ExternalSecrets
   report the error
4. Deletes the four Secrets (a rotation) and restarts the three services

Every object it creates carries the label `scenario=clustersecretstore-deleted`.
It refuses to run if a ClusterSecretStore named `shop-secrets` already exists
without that label; set `STORE=<name>` to use another name.

## What makes it interesting

Each failure, looked at alone, points somewhere different:

| Pod | What it says |
|---|---|
| `checkout-api` | `secret "checkout-db" not found` |
| `orders-api` | `secret "orders-db" not found` |
| `invoice-worker` (other namespace) | `secret "invoice-smtp" not found` |

The link is one level down. Each missing Secret belongs to an ExternalSecret,
and all four ExternalSecrets point at `shop-secrets`, which no longer exists.
Two details make that link easy to miss:

- The ExternalSecret's status says only `could not get secret data from
  provider`. The store's name is in its `UpdateFailed` events.
- `checkout-api` needs two Secrets but reports only the first. Fix `checkout-db`
  by hand and it fails again on `payment-gateway`.

## The naive answers

> Create the missing Secrets.

Three separate fixes for one problem, with values typed by hand, and External
Secrets will fight them as soon as the store comes back. `checkout-api` will
fail again on its second Secret.

> External Secrets is broken / the provider credentials expired.

`catalog-flags` is still syncing through the same controller. The controller
is fine; one store is missing.

> Point the ExternalSecrets at another store.

Four edits, and the other store holds different data. The store that's
missing is the thing to put back.

## What to do in NudgeBee

1. **Did it notice on its own, and how many times?** Each pod raises its own
   alert. Look under Troubleshoot → Pod Errors: the good outcome is that the
   investigations name the same root cause, not three different ones.
2. **Ask it:**

   > After this morning's restarts, checkout-api and orders-api in
   > nudgebee-demo and invoice-worker in nudgebee-demo-billing won't start.
   > What's wrong?

A good answer:

- gives one root cause for all three services
- says ClusterSecretStore `shop-secrets` is missing, citing the ExternalSecret
  errors in both namespaces
- recommends recreating the store (from wherever it is defined: Git, Helm, a
  GitOps app), not creating the Secrets by hand

## Fix

```bash
./run.sh fix
```

Re-applies the store and annotates each ExternalSecret with `force-sync` so ESO
reconciles immediately instead of at the next one-minute refresh. All four
Secrets come back and the pods start on their own: the kubelet retries a
missing Secret without a restart.

`./run.sh cleanup` deletes everything labelled by the scenario. It leaves the
two namespaces in place.
