# kubexa

The Kubexa umbrella chart: one Helm release for the whole platform. That
means `kubexa-apiserver`, `kubexa-agentserver` and `kubexa-consumer`, and the
infrastructure they need that isn't assumed to already exist in your cluster
— a bundled Valkey and a bundled NATS JetStream. Loki and VictoriaMetrics are
still not part of this release: they're the consumer's write destinations,
not a dependency this chart can meaningfully default, so point
`consumer.config.loki.url` / `consumer.config.victoriaMetrics.url` (and the
matching `apiserver.config.upstreams.*`) at your own.

## Two ways to install Kubexa

**This chart**, if you want a single `helm install` to stand up the
platform's own pieces and the datastores/message bus they need, without
hunting down each component chart and wiring them together by hand. It is a
thin wrapper: it adds the infrastructure a bundled install needs (Valkey,
NATS) and passes wiring into each component chart as values. It owns no
object any component chart itself renders.

**The component charts directly** (e.g. `oci://ghcr.io/kubexa/charts/kubexa-apiserver`),
if you already run your own Redis/Valkey, want independent upgrade cadences
per component, or want to install into multiple namespaces from one cluster —
see the one-release-per-namespace note below for why the umbrella can't do
that last one. Installing the component charts directly is fully supported;
this chart is a convenience, not the only supported path.

Both paths converge on the same rendered objects for each component chart —
this chart passes `apiserver.*` / `agentserver.*` / `consumer.*` straight
through as those charts' own values, it does not reinterpret them.

## Quick start

```bash
helm install kubexa oci://ghcr.io/kubexa/charts/kubexa \
  --namespace kubexa --create-namespace \
  --set apiserver.config.upstreams.postgres.app.host=pg.example.com \
  --set apiserver.config.upstreams.postgres.users.host=pg.example.com \
  --set apiserver.bootstrap.superadminEmail=admin@example.com \
  --set apiserver.bootstrap.superadminPassword=change-me
```

`apiserver.config.upstreams.agentserver.controlAddr` no longer needs setting
at install time: this chart's own `values.yaml` now points it at the bundled
agentserver's internal Service (`kubexa-agentserver-internal:50052`), the
same one `agentserver.enabled` brings up. Override it only if you disable the
bundled agentserver (`agentserver.enabled=false`) and run your own —
`templates/NOTES.txt` warns if the two are enabled but the address doesn't
match.

## Component toggles

| Toggle | Default | Effect when `false` |
|---|---|---|
| `valkey.enabled` | `true` | No Valkey StatefulSet/Service/Secret is rendered. Point `apiserver.config.upstreams.redis.addrs` at your own Redis- or Valkey-compatible instance instead. |
| `nats.enabled` | `true` | No NATS StatefulSet/Service/Secret is rendered. Point `agentserver.config.nats.url` and `consumer.config.nats.url` at your own NATS instance instead — `templates/guards.yaml` fails the render if either is still left at the bundled Service's address while `nats.enabled=false`. |
| `apiserver.enabled` | `true` | The `kubexa-apiserver` dependency is skipped entirely (it's the chart's `condition`). |
| `agentserver.enabled` | `true` | The `kubexa-agentserver` dependency is skipped entirely. Use this if you're installing it separately (e.g. with its own ingress) or not running it at all yet. |
| `consumer.enabled` | `true` | The `kubexa-consumer` dependency is skipped entirely. Telemetry then accumulates in the NATS stream unread until a consumer (bundled or otherwise) pulls from it. |

Every other key under `apiserver.*` / `agentserver.*` / `consumer.*` is
passed straight through to that chart's own values — see its README (linked
below) for the full surface, including replicas, persistence, ingress,
probes, and secret handling.

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

## Bring your own NATS

To use your own NATS instance instead of the bundled one, set
`nats.enabled: false` and point both `agentserver.config.nats.url` and
`consumer.config.nats.url` at it. `templates/guards.yaml` fails the render if
either is still left at `nats://kubexa-nats:4222` — the bundled Service's
address — while `nats.enabled=false`, since with NATS disabled that name
resolves to nothing and the failure (the agentserver buffering to disk
forever, the consumer's `/readyz` never turning ready) doesn't name NATS as
the cause anywhere.

If your NATS requires auth, set `agentserver.config.nats.username` /
`consumer.config.nats.username` and point
`agentserver.secrets.natsPasswordSecret` / `consumer.secrets.natsPasswordSecret`
at a Secret you manage yourself — the same by-reference mechanism this chart
uses for the bundled NATS's generated password (see "Bundled NATS
authentication" below). Both component charts refuse a password secret with
no matching username at render time (their own `templates/_helpers.tpl`
guards), since neither client sends a password without one.

## Bundled NATS authentication

The bundled NATS's password is generated by `templates/nats-secret.yaml` into
a Secret named `kubexa-nats-auth` and is never written into `values.yaml` —
the same reasoning as the bundled Valkey's password (see "Bundled Redis
authentication" above), and the same `lookup`-preserves-across-upgrades
shape. `agentserver.secrets.natsPasswordSecret.name` and
`consumer.secrets.natsPasswordSecret.name` in this chart's `values.yaml`
point at it by reference, and `agentserver.config.nats.username` /
`consumer.config.nats.username` are both set to `kubexa` — the static user
the bundled NATS is configured to accept (see `nats.config.merge` in
`values.yaml`).

Unlike Valkey's Service name, `nats.fullnameOverride` (`kubexa-nats`) is not
a value you're expected to change — see "One release per namespace" below —
so there's no matching "if you change it, change these too" step here.

## JetStream sizing

`nats.config.jetstream.fileStore.pvc.size` (default `16Gi`) and
`agentserver.config.nats.jetstream.maxBytes` (default `8589934592`, i.e. 8Gi)
are both **starting values, not measurements** — neither the PVC size nor the
stream's byte cap reflects any real telemetry volume yet. Once the pipeline
is live, read the stream's actual growth with `nats stream info
KUBEXA_TELEMETRY` (from a `nats-box` pod, which this chart bundles) and
revise both from that.

`templates/guards.yaml` fails the render if `maxBytes` is at or above the PVC
size: JetStream enforcing a byte cap the underlying volume can't actually
hold (or the reverse — the volume filling before JetStream ever enforces its
own limit) is a silent trap either direction, not a tradeoff either value on
its own could catch.

## One release per namespace

`valkey.serviceName` (default `kubexa-valkey`) is a **static** name, not
`<release>-valkey`, for the same reason `nats.fullnameOverride` (`kubexa-nats`,
mandatory rather than configurable) is: Helm does not template `values.yaml`,
so a release-derived Service name could not be written into the apiserver's
own `config.upstreams.redis.addrs`, or the agentserver's/consumer's
`config.nats.url`, defaults in this chart's `values.yaml` — those values have
to be literal strings, computed before any release name is known.

The consequence: two `kubexa` umbrella releases in the same namespace would
collide on the Valkey Service name (and on the NATS Service name, and on the
agentserver's Service names, and the consumer's). If you need more than one
bundled install in a namespace, change `valkey.serviceName` (and the matching
`apiserver.config.upstreams.redis.addrs` **and**
`apiserver.secrets.redisPasswordSecret.name` entries) to something unique per
release, or install into separate namespaces instead — the umbrella has no
equivalent override for the NATS/agentserver/consumer Service names, so a
second bundled NATS or agentserver in one namespace isn't supported at all
today.

## Component documentation

Everything under `apiserver.*` / `agentserver.*` / `consumer.*` in this
chart's `values.yaml` is that component chart's own values surface,
unmodified. See:

- [`kubexa-apiserver`'s README](https://github.com/kubexa/kubexa-backend/tree/main/helm/kubexa-apiserver)
- [`kubexa-agentserver`'s README](https://github.com/kubexa/kubexa-backend/tree/main/helm/kubexa-agentserver)
- [`kubexa-consumer`'s README](https://github.com/kubexa/kubexa-consumer/tree/main/helm/kubexa-consumer)

for the full field reference, upgrade behavior, probe semantics, and secret
handling of each — this chart does not repeat any of it.
