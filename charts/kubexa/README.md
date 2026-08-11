# kubexa

The Kubexa umbrella chart: one Helm release for the whole platform. Today
that means the `kubexa-apiserver` component and the datastore it needs to run
that isn't assumed to already exist in your cluster — a bundled Valkey. The
agentserver and the telemetry pipeline (Loki, VictoriaMetrics) are not part
of this release yet; install and wire them separately.

## Two ways to install Kubexa

**This chart**, if you want a single `helm install` to stand up the
platform's own pieces and the datastore they need, without hunting down each
component chart and wiring them together by hand. It is a thin wrapper: it
adds the infrastructure a bundled install needs (Valkey) and passes wiring
into the component chart as values. It owns no object the component chart
itself renders.

**The component charts directly** (e.g. `oci://ghcr.io/kubexa/charts/kubexa-apiserver`),
if you already run your own Redis/Valkey, want independent upgrade cadences
per component, or want to install into multiple namespaces from one cluster —
see the one-release-per-namespace note below for why the umbrella can't do
that last one. Installing the component charts directly is fully supported;
this chart is a convenience, not the only supported path.

Both paths converge on the same rendered objects for `kubexa-apiserver` —
this chart passes `apiserver.*` straight through as that chart's values, it
does not reinterpret them.

## Quick start

```bash
helm install kubexa oci://ghcr.io/kubexa/charts/kubexa \
  --namespace kubexa --create-namespace \
  --set apiserver.config.upstreams.postgres.app.host=pg.example.com \
  --set apiserver.config.upstreams.postgres.users.host=pg.example.com \
  --set apiserver.config.upstreams.agentserver.controlAddr=agentserver.example.com:50052 \
  --set apiserver.bootstrap.superadminEmail=admin@example.com \
  --set apiserver.bootstrap.superadminPassword=change-me
```

`apiserver.config.upstreams.agentserver.controlAddr` must be set at install
time — `kubexa-apiserver`'s `values.schema.json` requires it and this
umbrella deliberately ships no default for it (see "Component toggles"
below). It may point at an agentserver Service that does not exist yet: the
gateway client dials lazily and the readiness check for it is soft, so the
apiserver comes up and serves everything else while that dependency is
missing. A later release of this chart will set it for you once the
agentserver chart joins the bundle.

## Component toggles

| Toggle | Default | Effect when `false` |
|---|---|---|
| `valkey.enabled` | `true` | No Valkey StatefulSet/Service/Secret is rendered. Point `apiserver.config.upstreams.redis.addrs` at your own Redis- or Valkey-compatible instance instead. |
| `apiserver.enabled` | `true` | The `kubexa-apiserver` dependency is skipped entirely (it's the chart's `condition`). Use this if you're installing the apiserver separately and only want this chart for the datastore. |

Every other key under `apiserver.*` is passed straight through to the
`kubexa-apiserver` chart's own values — see its README (linked below) for the
full surface, including replicas, persistence, ingress, probes, and secret
handling.

## Bring your own Redis

The bundled datastore is **Valkey**, not Redis: protocol-compatible, so the
apiserver's client neither knows nor cares which one it's talking to, but
BSD-licensed under the Linux Foundation rather than RSALv2/SSPL, and shipped
with maintained images that aren't behind a vendor subscription.

To use your own Redis- or Valkey-compatible instance instead of the bundled
one, set `valkey.enabled: false`, point `apiserver.config.upstreams.redis.addrs`
at it, and clear `apiserver.secrets.redisPasswordSecret.name` — its default
(`kubexa-valkey-auth`) names the Secret `templates/valkey-secret.yaml` would
have generated for the bundled Valkey, and with `valkey.enabled: false` that
Secret is never rendered. `kubexa-apiserver`'s `secretKeyRef` for it is
deliberately non-optional, so leaving the default in place is not a
degraded-but-working install: `templates/guards.yaml` in this chart `fail`s
the render for exactly this combination (valkey disabled, apiserver enabled,
`redisPasswordSecret.name` still naming the Secret this chart would have
created) rather than letting it reach the cluster as
`CreateContainerConfigError: secret "kubexa-valkey-auth" not found`.

The complete, working flag list — if your Redis needs no password:

```bash
--set valkey.enabled=false \
--set apiserver.config.upstreams.redis.addrs={redis.example.com:6379} \
--set apiserver.secrets.redisPasswordSecret.name=""
```

If it does, supply the credential one of two ways: either
`apiserver.secrets.redisPassword` directly (the value travels into the
apiserver's own keys Secret):

```bash
--set valkey.enabled=false \
--set apiserver.config.upstreams.redis.addrs={redis.example.com:6379} \
--set apiserver.secrets.redisPasswordSecret.name="" \
--set apiserver.secrets.redisPassword=<password>
```

or `apiserver.secrets.redisPasswordSecret.name`/`.key` pointing at a Secret
you manage yourself (read by reference, the same mechanism this chart uses
for the bundled Valkey's generated password — see "Bundled Redis
authentication" below):

```bash
--set valkey.enabled=false \
--set apiserver.config.upstreams.redis.addrs={redis.example.com:6379} \
--set apiserver.secrets.redisPasswordSecret.name=my-redis-auth \
--set apiserver.secrets.redisPasswordSecret.key=password
```

## Bundled Redis authentication

The bundled Valkey's password is generated by `templates/valkey-secret.yaml`
into a Secret named `<valkey.serviceName>-auth` (default `kubexa-valkey-auth`)
and is never written into `values.yaml` — a value generated inside a template
at render time cannot travel through values into a sibling chart. Instead,
`apiserver.secrets.redisPasswordSecret.name` in this chart's `values.yaml`
points at that Secret by reference, and the `kubexa-apiserver` chart reads it
directly (see its README's "Key handling" section).

This default (`kubexa-valkey-auth`) is only correct for the default
`valkey.serviceName` (`kubexa-valkey`). If you change `valkey.serviceName`,
change `apiserver.secrets.redisPasswordSecret.name` to `<new-name>-auth` in
the same install — the same "change it together" rule that already applies
to `apiserver.config.upstreams.redis.addrs` (see "One release per namespace"
below). `helm install`/`helm upgrade` warns in `NOTES.txt` if the two drift
apart while valkey is enabled, since the failure mode (NOAUTH against Redis)
is silent otherwise: `/readyz` treats Redis as a soft dependency, so the pod
stays Ready while rate limiting, notification fan-out and demand-driven watch
leases quietly stop working.

## One release per namespace

`valkey.serviceName` (default `kubexa-valkey`) is a **static** name, not
`<release>-valkey`. Helm does not template `values.yaml`, so a
release-derived Service name could not be written into the apiserver's own
`config.upstreams.redis.addrs` default in this chart's `values.yaml` — that
value has to be a literal string, computed before any release name is known.

The consequence: two `kubexa` umbrella releases in the same namespace would
collide on the Valkey Service name. If you need more than one bundled install
in a namespace, change `valkey.serviceName` (and the matching
`apiserver.config.upstreams.redis.addrs` **and**
`apiserver.secrets.redisPasswordSecret.name` entries) to something unique per
release, or install into separate namespaces instead.

## Component documentation

Everything under `apiserver.*` in this chart's `values.yaml` is the
`kubexa-apiserver` chart's own values surface, unmodified. See
[`kubexa-apiserver`'s README](https://github.com/kubexa/kubexa-backend/tree/main/helm/kubexa-apiserver)
for the full field reference, upgrade behavior, probe semantics, and secret
handling — this chart does not repeat it.
