# Kubexa Helm charts

This repository is two things at once:

* **the source of the umbrella chart** (`charts/kubexa`) — the one release that
  installs the whole platform: API server, agent gateway, telemetry consumer,
  web console, and the datastores and message bus they need;
* **an HTTP chart repository** — the packaged `kubexa-agent` archives at the
  root, served from GitHub Pages and indexed by `index.yaml`.

## Installing

The umbrella chart is published to a container registry, not to this HTTP
repository:

```sh
helm install kubexa oci://ghcr.io/kubexa/charts/kubexa \
  --namespace kubexa --create-namespace -f my-values.yaml
```

The agent chart is served from here:

```sh
helm repo add kubexa https://kubexa.github.io/helm-charts
helm upgrade --install kubexa-agent kubexa/kubexa-agent --namespace kubexa
```

Read the docs before either command — the umbrella has prerequisites, and a
successful `helm install` does not by itself prove telemetry is flowing:

* <https://kubexa.dev/docs/self-hosting/requirements/>
* <https://kubexa.dev/docs/self-hosting/install/>
* <https://kubexa.dev/docs/agent/install-the-agent/>

## Licensing

Kubexa is **not** a single-license project. Four different sets of terms apply
depending on which part you are looking at, and mixing them up is easy, so here
is the whole map in one place.

| What | Where | License |
| --- | --- | --- |
| Umbrella chart source | `charts/` in this repository | Apache License 2.0 — see [`LICENSE`](LICENSE) |
| Kubexa agent (source, image and chart) | `github.com/kubexa/kubexa-agent`, `ghcr.io/kubexa/kubexa-agent`, `kubexa-agent-*.tgz` here | GNU GPL v3.0 |
| Kubexa server images | `ghcr.io/kubexa/kubexa-{backend,app,consumer,backup}` | Proprietary — see [`EULA.md`](EULA.md) |
| Everything else the chart deploys | PostgreSQL, Valkey, NATS, VictoriaMetrics, Grafana Loki | Each vendor's own license |

Two consequences worth stating plainly, because they are the questions a
reviewer asks first:

**You may run Kubexa for your own clusters, free of charge and without asking
us.** That is what the EULA grants. What it does not grant is offering Kubexa
to other organisations as a hosted or managed service — that needs a separate
agreement. The agent is the exception in the other direction: it is GPL-3.0,
and you have the full freedoms of that license in it.

**The charts deploy third-party software under licenses we do not control, and
at least one of them is copyleft.** If you are assembling a compliance
statement for your own organisation, read those licenses at their source rather
than relying on this table — the components and their versions change between
chart releases, and `charts/kubexa/Chart.yaml` plus
`charts/kubexa/charts/*.tgz` are the only authoritative record of what a given
release pulls in.

## Where the rest of the source lives

The umbrella's Kubexa subcharts (`kubexa-apiserver`, `kubexa-agentserver`,
`kubexa-consumer`, `kubexa-app`) are published to `oci://ghcr.io/kubexa/charts`
from their own repositories and vendored into `charts/kubexa/charts/` as
archives. Only the agent's source is public.
