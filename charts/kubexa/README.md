# kubexa

The Kubexa umbrella chart: one Helm release for the whole platform. That
means `kubexa-apiserver`, `kubexa-agentserver`, `kubexa-consumer` and
`kubexa-app` (the web UI), and the datastores and message bus they need that
aren't assumed to already exist in your cluster — bundled Postgres, Valkey,
VictoriaMetrics, Loki, and NATS JetStream. Every one of them can be turned
off and pointed at an instance you already run instead; see "What this chart
bundles" below for the exact flags.

## What this chart bundles

| Store | Values key | Default | Turn it off with |
|---|---|---|---|
| Postgres | `postgres` | bundled, 1 replica, 20Gi | `postgres.enabled=false` + `apiserver.config.upstreams.postgres.{app,users}.host`, `sslMode`, and both password Secret refs; `consumer.config.{postgres,usersDb}` |
| Valkey | `valkey` | bundled, 1Gi | `valkey.enabled=false` + `apiserver.config.upstreams.redis.addrs` and `apiserver.secrets.redisPassword*` |
| VictoriaMetrics | `victoriaMetrics` | bundled, 30d, 20Gi | `victoriaMetrics.enabled=false` + `consumer.config.victoriaMetrics.url`, `apiserver.config.upstreams.victoriametrics.url` |
| Loki | `loki` | bundled, 720h, 20Gi | `loki.enabled=false` + `consumer.config.loki.url`, `apiserver.config.upstreams.loki.url` |
| NATS | `nats` | bundled | `nats.enabled=false` + `agentserver.config.nats.url`, `consumer.config.nats.url`, and both `natsPasswordSecret` refs |

Every one of those "turn it off with" lists is enforced: `templates/guards.yaml`
fails the render if a store is disabled and something is still pointed at the
name its template would have produced.

The bundled Postgres is a single replica with no failover. An install that
needs failover should turn it off and point at a managed instance or a
CloudNativePG cluster instead. It does have an optional nightly logical
backup — see "Nightly backups" below.

## Two ways to install Kubexa

**This chart**, if you want a single `helm install` to stand up the
platform's own pieces and the datastores/message bus they need, without
hunting down each component chart and wiring them together by hand. It is a
thin wrapper: it adds the infrastructure a bundled install needs (Postgres,
Valkey, VictoriaMetrics, Loki, NATS) and passes wiring into each component
chart as values. It owns no object any component chart itself renders.

**The component charts directly** (e.g. `oci://ghcr.io/kubexa/charts/kubexa-apiserver`),
if you already run your own Redis/Valkey, want independent upgrade cadences
per component, or want to install into multiple namespaces from one cluster —
see the one-release-per-namespace note below for why the umbrella can't do
that last one. Installing the component charts directly is fully supported;
this chart is a convenience, not the only supported path.

Both paths converge on the same rendered objects for each component chart —
this chart passes `apiserver.*` / `agentserver.*` / `consumer.*` / `app.*`
straight through as those charts' own values, it does not reinterpret them.

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
| `postgres.enabled` | `true` | No Postgres StatefulSet/Service/Secret is rendered. Point `apiserver.config.upstreams.postgres.{app,users}.host` and `consumer.config.{postgres,usersDb}` at your own instance instead — `templates/guards.yaml` fails the render if either is still left pointed at the bundled Service while `postgres.enabled=false`. |
| `valkey.enabled` | `true` | No Valkey StatefulSet/Service/Secret is rendered. Point `apiserver.config.upstreams.redis.addrs` at your own Redis- or Valkey-compatible instance and move `apiserver.secrets.redisPasswordSecret.name` off the bundled Secret instead — `templates/guards.yaml` fails the render if either is still left pointed at the bundled Service while `valkey.enabled=false`. |
| `victoriaMetrics.enabled` | `true` | No VictoriaMetrics StatefulSet/Service is rendered. Point `consumer.config.victoriaMetrics.url` and `apiserver.config.upstreams.victoriametrics.url` at your own instance instead — `templates/guards.yaml` fails the render if either is still left pointed at the bundled Service while `victoriaMetrics.enabled=false`. |
| `loki.enabled` | `true` | No Loki StatefulSet/Service is rendered. Point `consumer.config.loki.url` and `apiserver.config.upstreams.loki.url` at your own instance instead — `templates/guards.yaml` fails the render if either is still left pointed at the bundled Service while `loki.enabled=false`. |
| `nats.enabled` | `true` | No NATS StatefulSet/Service/Secret is rendered. Point `agentserver.config.nats.url` and `consumer.config.nats.url` at your own NATS instance, and move both `natsPasswordSecret.name` refs off the bundled Secret, instead — `templates/guards.yaml` fails the render if any of the four is still left at the bundled Service's name while `nats.enabled=false`. |
| `apiserver.enabled` | `true` | The `kubexa-apiserver` dependency is skipped entirely (it's the chart's `condition`). |
| `agentserver.enabled` | `true` | The `kubexa-agentserver` dependency is skipped entirely. Use this if you're installing it separately (e.g. with its own ingress) or not running it at all yet. |
| `consumer.enabled` | `true` | The `kubexa-consumer` dependency is skipped entirely. Telemetry then accumulates in the NATS stream unread until a consumer (bundled or otherwise) pulls from it. |
| `app.enabled` | `true` | The `kubexa-app` dependency is skipped entirely. Use this if you're serving the web UI some other way, or not yet. |

Every other key under `apiserver.*` / `agentserver.*` / `consumer.*` / `app.*`
is passed straight through to that chart's own values — see its README
(linked below) for the full surface, including replicas, persistence,
ingress, probes, and secret handling.

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

## The agentserver↔consumer NATS contract

Three values must agree between `agentserver.config.nats.*` and
`consumer.config.nats.*` / `consumer.config.backpressure.*` for a message to
travel from the agentserver to the consumer at all — the stream name, the
subject prefix, and the backpressure subject. `templates/guards.yaml` checks
all three by equality and `fail`s the render on any mismatch, including the
likely real-world one: one side left at its chart default while only the
other is overridden (e.g. `--set consumer.config.nats.subjectPrefix=telemetry`
with nothing said about the agentserver side). Without this guard that
combination renders and installs cleanly, every pod reports Ready, and
telemetry silently accumulates in the stream until it prunes at `max_bytes` —
nothing else in the pipeline would have named the cause.

The backpressure-subject check only runs while
`consumer.config.backpressure.enabled` is `true` (the chart default): with it
`false` the consumer publishes no leases at all, which is a deliberate
degraded state, not a mismatch to fail on.

## Loki / VictoriaMetrics / Postgres agreement

`apiserver.config.upstreams.loki.url` (what the log API reads) and
`consumer.config.loki.url` (what the consumer writes) must be the same
instance, or the log UI returns an empty result set while `/readyz` still
reports `loki: ok` — readiness only checks that the configured URL answers,
never that it's the URL anything writes to. The same applies to
`apiserver.config.upstreams.victoriametrics.url` /
`consumer.config.victoriaMetrics.url`. `templates/guards.yaml` fails the
render on either pair differing, in either direction — including exactly one
side left empty while the other is set, which is worse than two different
non-empty values, since one component then looks fully configured and
healthy while the other never receives anything to serve. Both sides empty is
deliberately not guarded: that is the legitimate "this install does not use
Loki/VictoriaMetrics at all" state, and neither chart defaults either URL, so
a stock install starts in exactly that state.

A similarly-shaped guard covers Postgres, the third store both components
share: `apiserver.config.upstreams.postgres.app.host` must agree with
`consumer.config.postgres.host` (both are the telemetry/application
database), and `apiserver.config.upstreams.postgres.users.host` must agree
with `consumer.config.usersDb.host` (both are the identity/users registry).
With either pair apart, every pod stays Ready while the apiserver serves
from one Postgres and the consumer writes telemetry into another — every
telemetry screen returns empty, with nothing naming the cause. Unlike the
`postgres.enabled=false` guards above (which only catch a pointer left at
the bundled Service's *name*), this one catches two *different* external
instances too, and it applies whether or not `postgres.enabled` is `true`.

The "both sides empty" exemption above does NOT apply here, and can't: the
apiserver's two Postgres hosts are mandatory in `kubexa-apiserver`'s
`values.schema.json`, so that side is never empty. Instead, an empty
**consumer** side is read as the deliberate disabled state its own chart
documents — `consumer.config.postgres.host` empty disables the telemetry
writer, `consumer.config.usersDb.host` empty disables the cluster registry
(required whenever `consumer.config.loki.url` is set; see the
loki-url-without-usersDb guard above) — so each pair is only checked while
the consumer side is non-empty.

## Bundling the web UI

`app.enabled` (default `true`) brings in the `kubexa-app` chart — the React
SPA, served by nginx. A bundled install exposes the UI and the API on **one
hostname**: the app's Ingress claims `/` and the apiserver's claims
`/api/v1`, both routed by the same nginx controller. That is not a
convenience — the image is built once against the relative API base
`/api/v1`, and the service worker's `/api` rules (`navigateFallbackDenylist`,
`NetworkOnly` in `vite.config.ts`) are path-based. Split the two across
hostnames and the app starts serving `index.html` for API navigations,
caching API responses, and making cross-origin requests that need CORS.

The three values an operator sets for a bundled install with Ingress:

```bash
--set app.ingress.enabled=true \
--set app.ingress.host=kubexa.example.com \
--set apiserver.ingress.enabled=true \
--set apiserver.ingress.host=kubexa.example.com \
--set apiserver.config.corsAllowedOrigins[0]=https://kubexa.example.com
```

`app.ingress.host` and `apiserver.ingress.host` must be the same value.
`apiserver.config.corsAllowedOrigins` matters even same-origin: same-origin
removes CORS from the browser's path, but not the server's —
`internal/config/apiserver.go`'s `ApplyAPIServerDefaults` turns an empty list
into `["*"]`, so leaving it unset serves `Access-Control-Allow-Origin: *` to
every caller.

The **app Ingress owns TLS** for the shared host — `apiserver.ingress.tls.enabled`
is left `false` by default. Two Ingress objects declaring TLS for one host
make cert-manager open two Certificates against a single Secret, and
`templates/guards.yaml` fails the render if both are turned on for the same
host. It also fails the render if `apiserver.ingress.path` is left at `/`
while both Ingresses are enabled on the same host: nginx resolves a shared
host by longest prefix, so `apiserver.ingress.path` needs to stay `/api/v1`
(the default) for the apiserver's rule to win over the app's `/`.

Set `app.enabled=false` to skip the `kubexa-app` dependency entirely — e.g.
if you're serving the UI some other way, or not yet.

## Nightly backups

`backup.enabled` (default `false`) adds a `CronJob` that runs the
`kubexa-backup` image on a schedule (default `0 2 * * *`) and takes an
encrypted logical dump of both the app and users databases.

It carries **no connection settings of its own** — it reads
`apiserver.config.upstreams.postgres` (rendered into a config Secret) and the
two `apiserver.secrets.postgres{App,Users}PasswordSecret` refs the apiserver
itself uses. A backup with its own copy of those settings would keep dumping
the database the apiserver has since moved off, and report success every
night while protecting nothing — the same reasoning behind the
Loki/VictoriaMetrics/Postgres agreement guards above, applied to a third
consumer of the same connection.

Turning it on requires two more values, and `templates/guards.yaml` fails the
render if either is missing:

- `backup.encryption.existingSecret.name` — a Secret (created outside this
  chart) holding the encryption key at `backup.encryption.existingSecret.key`
  (default key name `encryption-key`). Unconditional: an unencrypted dump
  carries password hashes, sealed secrets and tokens, and this chart will not
  render one.
- `backup.destination.driver` (`s3` or `filesystem`) and that driver's own
  required fields — `bucket` + `existingSecret.name` for `s3`,
  `existingClaim` for `filesystem`.

The rest is left at sensible defaults and rarely needs changing:

- `backup.retention.keep` (default `14`) — how many dump generations the
  binary keeps at the destination before pruning older ones.
- `backup.workDir.sizeLimit` (default `10Gi`) — the `emptyDir` size limit for
  `/work`, where the dump is staged (compressed and encrypted) before upload.
  Too small for the actual database size and the job fails mid-run rather
  than mid-upload.
- `backup.victoriaMetrics.url` (default `""`, disabled) — where the job pushes
  its own run metrics (success/failure, duration, size). Point it at the
  bundled instance (`http://kubexa-victoriametrics:8428`) or your own, or
  leave it empty to run without job-level metrics.
- `backup.resources` (default `1 CPU` / `1Gi` limits, `100m` / `128Mi`
  requests) — the CronJob container's own `resources` block, passed straight
  through.

```yaml
backup:
  enabled: true
  encryption:
    existingSecret:
      name: kubexa-backup-encryption
  destination:
    driver: s3
    s3:
      bucket: kubexa-backups
      region: us-east-1
      existingSecret:
        name: kubexa-backup-s3-credentials
```

The CronJob's pod runs as uid/gid 70 (the `postgres` user in the image's
`postgres:17-alpine` base, which also owns `/work`) and sets
`securityContext.fsGroup: 70` at the pod level — the `emptyDir` mounted over
`/work` for dump staging arrives root-owned otherwise, and the uid-70 process
could not write to it.

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

## Testing

`charts/kubexa/tests/render.sh` renders this chart under every profile in
`charts/kubexa/tests/profiles/` and asserts against each render — that the
stores this chart is supposed to bundle actually rendered, that the wiring
between components matches what each guard above claims to enforce, and that
every `half-thrown-*` profile (one store's pointers deliberately left behind)
fails to render with that guard's own message, not some other guard's.

```bash
helm dependency update charts/kubexa   # only needed if charts/kubexa/charts/ is empty
charts/kubexa/tests/render.sh          # every profile
charts/kubexa/tests/render.sh default  # one profile
```

Requires `helm` 3 and [`kubeconform`](https://github.com/yannh/kubeconform)
on `PATH`. It also works under `/bin/bash` 3.2 (macOS's own, not Homebrew's)
as well as a modern bash — it deliberately avoids bash-4-only constructs like
`declare -A`, since this is the only place the half-thrown/guard mapping is
defined. `.github/workflows/umbrella-release.yaml` runs it on every push to
`main` that touches this chart, before packaging — a chart that fails this
script never reaches GHCR.

`default`, `external-stores`, `backup-s3` and `backup-filesystem` are the
profiles expected to render cleanly; every `half-thrown-*` profile is
expected to fail, and the script checks that it failed for the *right*
reason, not merely that it failed.

## Component documentation

Everything under `apiserver.*` / `agentserver.*` / `consumer.*` / `app.*` in
this chart's `values.yaml` is that component chart's own values surface,
unmodified. See:

- [`kubexa-apiserver`'s README](https://github.com/kubexa/kubexa-backend/tree/main/helm/kubexa-apiserver)
- [`kubexa-agentserver`'s README](https://github.com/kubexa/kubexa-backend/tree/main/helm/kubexa-agentserver)
- [`kubexa-consumer`'s README](https://github.com/kubexa/kubexa-consumer/tree/main/helm/kubexa-consumer)
- [`kubexa-app`'s README](https://github.com/kubexa/kubexa-app/tree/main/helm/kubexa-app)

for the full field reference, upgrade behavior, probe semantics, and secret
handling of each — this chart does not repeat any of it.
