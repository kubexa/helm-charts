#!/usr/bin/env bash
# Renders the umbrella under each profile in tests/profiles/ and runs every
# assertion below against the result. Run from anywhere:
#
#   charts/kubexa/tests/render.sh              # every profile
#   charts/kubexa/tests/render.sh default      # one profile
#
# Requires: helm 3, kubeconform. The chart's dependencies must be present --
# run `helm dependency update charts/kubexa` first if charts/ is empty.
set -euo pipefail
cd "$(dirname "$0")/../../.."
CHART=charts/kubexa
PROFILES_DIR="$CHART/tests/profiles"
FAILURES=0

fail() { echo "  FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "  ok: $*"; }

render_profile() {
  helm template kubexa "$CHART" -f "$PROFILES_DIR/$1.yaml" 2>&1
}

# Slices ONE document out of a full `helm template` render, keyed on its
# "# Source: <path>" marker line -- the one Helm writes immediately above
# every document. Needed because a plain `grep` against the whole render
# passes on a property that belongs to a completely different object: this
# chart bundles a Postgres StatefulSet that also sets fsGroup: 70, an
# apiserver Deployment that also carries KUBEXA_APISERVER_POSTGRES_APP_
# PASSWORD, and the backup config Secret's own name contains the substring
# "kubexa-backup" too. An assertion scoped to the source's own document can't
# pass on any of those.
#
# awk, not `yq`: yq is not a declared dependency of this script, and the
# marker-line approach needs nothing more than line-oriented matching. Reads
# from stdin via a herestring at the call site, same as every other
# assertion here, to avoid the SIGPIPE-under-pipefail trap documented above
# assert_bundled_vm.
extract_source() {
  local out=$1 source=$2
  awk -v marker="# Source: $source" '
    $0 == marker { grab=1; next }
    /^# Source:/ { grab=0 }
    grab { print }
  ' <<< "$out"
}

# ── assertions ──────────────────────────────────────────────────────────────
# Each takes the rendered manifest on stdin as "$1" (a variable, not a pipe,
# so several assertions can read the same render) and the profile name as $2.

assert_kubeconform() {
  local out=$1 profile=$2
  # Herestrings, not `echo "$out" | ...`: see assert_bundled_vm for the
  # SIGPIPE/pipefail mechanism this avoids.
  if kubeconform -strict -ignore-missing-schemas -summary <<< "$out" >/dev/null 2>&1; then
    ok "$profile: kubeconform"
  else
    fail "$profile: kubeconform rejected the render"
    kubeconform -strict -ignore-missing-schemas -summary <<< "$out" || true
  fi
}

assert_no_empty_documents() {
  local out=$1 profile=$2
  # A template whose whole body is inside an {{- if }} that is false renders
  # as a bare "---" with nothing after it. Harmless to kubectl, but it means
  # a guard fired that the profile did not intend.
  if awk '
    BEGIN{RS="---"}
    {
      body=0
      n=split($0, lines, "\n")
      for (i=1; i<=n; i++) {
        line=lines[i]
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line == "") continue
        if (line ~ /^#/) continue
        body=1
        break
      }
      if (!body && NF) found=1
    }
    END{exit !found}
  ' <<< "$out"; then
    fail "$profile: an empty document was rendered"
  else
    ok "$profile: no empty documents"
  fi
}

assert_bundled_postgres() {
  local out=$1 profile=$2
  [ "$profile" = "default" ] || return 0
  grep -q 'name: kubexa-postgres$' <<< "$out" \
    || { fail "$profile: no kubexa-postgres Service/StatefulSet rendered"; return; }
  grep -q 'name: kubexa-postgres-auth' <<< "$out" \
    || { fail "$profile: no kubexa-postgres-auth Secret rendered"; return; }
  grep -q 'CREATE DATABASE kubexa_app' <<< "$out" \
    || { fail "$profile: the init script does not create kubexa_app"; return; }
  grep -q 'CREATE DATABASE kubexa_users' <<< "$out" \
    || { fail "$profile: the init script does not create kubexa_users"; return; }
  # The auth Secret must outlive the release, because the password it holds is
  # part of the data on data-kubexa-postgres-0, not part of the release.
  # Without this annotation `helm uninstall` deletes the Secret, leaves the PVC
  # Bound, and the next install generates passwords the surviving roles do not
  # have -- measured on 2026-10-12: STATUS deployed, --wait exit 0, six pods
  # Ready, and FATAL: password authentication failed on the first connection
  # over the Service. The probe is `pg_isready -h 127.0.0.1`, which the image's
  # pg_hba answers over a trust line, so nothing in the install can see it.
  grep -q 'helm.sh/resource-policy: keep' <<< "$out" \
    || { fail "$profile: the postgres auth Secret is not kept across uninstall"; return; }
  ok "$profile: bundled postgres"
}

assert_postgres_absent_when_disabled() {
  local out=$1 profile=$2
  [ "$profile" = "external-stores" ] || return 0
  if grep -q 'kubexa-postgres' <<< "$out"; then
    fail "$profile: postgres objects rendered with postgres.enabled=false"
  else
    ok "$profile: postgres absent when disabled"
  fi
}

assert_postgres_wiring() {
  local out=$1 profile=$2
  [ "$profile" = "default" ] || return 0
  # The apiserver's and consumer's rendered config Secrets hold apiserver.yaml
  # / consumer.yaml; grep the rendered manifest for the host rather than
  # decoding it -- the value is written in stringData, not base64. Both
  # subcharts render their own config through a Go struct with yaml tags, so
  # the key is snake_case (ssl_mode, not sslMode) and go-yaml quotes every
  # plain string scalar -- host: "kubexa-postgres", not host: kubexa-postgres.
  [ "$(grep -c 'host: "kubexa-postgres"' <<< "$out")" -ge 4 ] \
    || { fail "$profile: expected >=4 postgres hosts (apiserver app+users, consumer postgres+usersDb), got $(grep -c 'host: "kubexa-postgres"' <<< "$out")"; return; }
  grep -q 'name: kubexa-postgres-auth' <<< "$out" \
    || { fail "$profile: nothing references the kubexa-postgres-auth Secret"; return; }
  grep -q 'ssl_mode: "disable"' <<< "$out" \
    || { fail "$profile: the bundled Postgres carries no TLS; ssl_mode must be disable"; return; }
  ok "$profile: postgres wiring"
}

# The vmalert rules ConfigMap must carry the apiserver's fail-open alerts. With
# vmalert default off, no other profile renders it, so a rule missing from
# values.yaml (or from the chart's rule list) was invisible to the harness.
# Sliced to the ConfigMap's OWN document (extract_source): the rule names
# appear in values.yaml comments and annotations elsewhere, and a whole-render
# grep proves nothing about which object carries them. Herestrings, not pipes:
# see assert_bundled_vm.
assert_vmalert_rules() {
  local out=$1 profile=$2
  [ "$profile" = "vmalert" ] || return 0
  local doc
  doc=$(extract_source "$out" "kubexa/charts/vmalert/templates/alert-configmap.yaml")
  if [ -z "$doc" ]; then
    fail "$profile: no vmalert alert-configmap.yaml document found in the render"
    return
  fi
  # KubexaAgentExportStalled and KubexaAgentSendStalled are pinned here for the
  # same reason the three above are, with one difference worth stating: they are
  # the only rules that can report an agent which has stopped delivering
  # altogether. Every other agent rule reads a figure relayed through a
  # heartbeat, so all of them describe an agent that is still talking. Delete
  # these two and the install goes back to the state apexcrawl was in on
  # 2026-10-26, where an export stalled for 9.6 days and nothing anywhere held a
  # number that said so.
  #
  # KubexaConsumerNotDraining and LokiRuntimeConfigRejected join them for the
  # same structural reason, one hop further down the pipeline. Every OTHER
  # consumer rule reads a counter the consumer itself increments, so each one
  # describes a consumer that is running and unhappy; a consumer that has
  # stopped consuming increments nothing and reads as healthy. And a Loki that
  # rejects its per-tenant limits document keeps the last good one, logs nothing
  # a caller can see, and silently falls back to the most generous global
  # limits. Both failures are invisible by construction, so these two rules are
  # the only thing that reports them -- removing either restores a silence,
  # which is exactly what this assertion exists to make loud.
  #
  # KubexaBackupNotRunning is pinned for the same reason and one it earned the
  # hard way: it is the rule that reports that nothing is reporting -- a CronJob
  # deleted, unschedulable, or unable to pull its image produces no pod, no log
  # and no failure event, so every other backup rule reads a scope that is
  # absent rather than broken. It has ALREADY disappeared once, commented out
  # between 2026-09-26 and 2026-10-11 to stop a false page, which is precisely
  # the move this assertion exists to catch: silencing the reporter is not
  # fixing the report. The false page was fixed on 2026-11-08 by gating its
  # absence fallback; there is no longer a reason to reach for the comment
  # character. Note this pin is independent of backup.enabled -- the rules
  # ConfigMap carries every rule regardless of whether this install deploys a
  # CronJob at all.
  # KubexaAgentTokenPoolUnseeded belongs here for the same reason and is the
  # starkest case of it: an agentserver whose token pool was never seeded is
  # up, ready, scraped and entirely healthy by every other measure, while NO
  # agent on the install can complete a handshake. Every agent-side rule reads
  # a figure relayed through a heartbeat, and there are no heartbeats, so this
  # rule is the only thing anywhere that reports a silent fleet. It was also
  # created by narrowing KubexaHandshakeRejections on 2026-11-08 -- deleting it
  # would leave that exclusion in place and the exclusion alone, which is
  # strictly worse than before the split.
  for rule in KubexaPasswordBreachCheckFailing KubexaSessionGateFailing KubexaSessionGateErroring \
    KubexaAgentExportStalled KubexaAgentSendStalled \
    KubexaConsumerNotDraining LokiRuntimeConfigRejected \
    KubexaBackupNotRunning KubexaAgentTokenPoolUnseeded; do
    if grep -qE "^[[:space:]]*- alert: $rule$" <<< "$doc"; then
      ok "$profile: vmalert rule $rule"
    else
      fail "$profile: vmalert rules ConfigMap lacks $rule"
    fi
  done
}

# The preflight profile is the only one that renders these. Herestrings, not
# pipes: see assert_bundled_vm for the SIGPIPE/pipefail mechanism this avoids.
#
# extract_source returns ALL SIX documents of preflight.yaml as one blob: Helm
# writes one `# Source:` marker per document, so a six-document template has six
# identical consecutive markers and the awk keeps grabbing across them. No other
# umbrella template is multi-document, so do not assume it returns one object.
#
# The property greps are anchored to a YAML key at the start of a line, because
# the template's own comments name these same words (ttlSecondsAfterFinished,
# optional) and Helm passes comments through to the render.
assert_preflight_objects() {
  local out=$1 profile=$2
  [ "$profile" = "preflight" ] || return 0
  local doc
  doc=$(extract_source "$out" "kubexa/templates/preflight.yaml")
  if [ -z "$doc" ]; then
    fail "$profile: no preflight.yaml document found in the render"
    return 0
  fi
  local kind
  for kind in ServiceAccount ClusterRole ClusterRoleBinding Role RoleBinding Job; do
    if grep -q "^kind: $kind\$" <<< "$doc"; then
      ok "$profile: preflight renders a $kind"
    else
      fail "$profile: preflight renders no $kind"
    fi
  done
  # The optional flag is load-bearing: without it a missing input Secret
  # blocks the pod from starting and the "no rendered release" report can
  # never be produced. It is one word in a volume, so it gets its own
  # assertion rather than riding along with the Job's existence.
  # Counted, not merely found: checked across the whole document, a second
  # optional: true elsewhere would keep this green after the input Secret
  # volume lost its own.
  # "|| true": grep -c exits 1 when the count is 0, which under set -e kills
  # the whole suite silently instead of reporting a failure. Measured.
  local opts
  opts=$(grep -cE '^[[:space:]]+optional: true$' <<< "$doc" || true)
  if [ "$opts" = "1" ]; then
    ok "$profile: the input secret volume is optional"
  else
    fail "$profile: expected exactly one 'optional: true' (the input Secret volume) and found $opts -- without it a missing Secret would block the pod and suppress the no-input report"
  fi
  if grep -qE '^[[:space:]]+backoffLimit: 0$' <<< "$doc"; then
    ok "$profile: backoffLimit is 0"
  else
    fail "$profile: backoffLimit is not 0 -- a retry would re-run the live PVC proof and print a second report"
  fi
  if grep -qE '^[[:space:]]*ttlSecondsAfterFinished:' <<< "$doc"; then
    fail "$profile: the Job sets ttlSecondsAfterFinished -- it would delete itself and take its logs, which are the deliverable, with it"
  else
    ok "$profile: no ttlSecondsAfterFinished"
  fi
}

# The preflight image must equal the apiserver's in the SAME render. The two
# come from independent sources -- preflight.image.tag in this chart's values,
# and the apiserver subchart's own default via its appVersion -- so this is a
# real comparison rather than a tautology. It is here rather than in a
# reviewer's memory because this repo has already run two components on two
# different images for four releases.
#
# The subchart is pulled under the alias `apiserver`, and Helm writes the alias
# into the Source marker. The deployment carries two image: lines (the
# container and the migrate initContainer); sort -u collapses them while they
# agree, and if they ever diverge the comparison fails, which is right.
assert_preflight_image_matches_apiserver() {
  local out=$1 profile=$2
  [ "$profile" = "preflight" ] || return 0
  local pf api pf_img api_img
  pf=$(extract_source "$out" "kubexa/templates/preflight.yaml")
  api=$(extract_source "$out" "kubexa/charts/apiserver/templates/deployment.yaml")
  pf_img=$(grep -E '^[[:space:]]+image:' <<< "$pf" | awk '{print $2}' | tr -d '"' | sort -u)
  api_img=$(grep -E '^[[:space:]]+image:' <<< "$api" | awk '{print $2}' | tr -d '"' | sort -u)
  # One line per value so a multi-valued side reads as a list, not a broken sentence.
  pf_img=${pf_img//$'\n'/ | }
  api_img=${api_img//$'\n'/ | }
  if [ -z "$pf_img" ] || [ -z "$api_img" ]; then
    fail "$profile: could not read both images (preflight=[$pf_img] apiserver=[$api_img])"
    return 0
  fi
  if [ "$pf_img" = "$api_img" ]; then
    ok "$profile: preflight and apiserver run the same image ($pf_img)"
  else
    fail "$profile: preflight runs [$pf_img] but the apiserver renders [$api_img] -- either preflight.image.tag has drifted from the apiserver subchart's appVersion, or the apiserver's own container and migrate initContainer no longer agree. Whichever it is, this release's render would be checked by a different release's binary"
  fi
}

# The two kubexa-backend processes must run ONE image. 0.8.21's note ended by
# saying nothing asserted this, so the next drift would be as quiet as the one
# 0.7.13 exists to repair -- the agentserver had silently fallen four releases
# behind, and it was found by a human rendering the chart and reading the two
# image lines side by side. This is that reading, automated. It runs on the
# default profile, so it is checked on every suite run rather than only when
# some optional Job is turned on.
#
# A deliberate divergence is still possible -- 0.8.21 made one on a specific,
# argued basis -- but it now has to come here and say so.
assert_agentserver_image_matches_apiserver() {
  local out=$1 profile=$2
  [ "$profile" = "default" ] || return 0
  local api agent api_img agent_img
  api=$(extract_source "$out" "kubexa/charts/apiserver/templates/deployment.yaml")
  agent=$(extract_source "$out" "kubexa/charts/agentserver/templates/deployment.yaml")
  api_img=$(grep -E '^[[:space:]]+image:' <<< "$api" | awk '{print $2}' | tr -d '"' | sort -u)
  agent_img=$(grep -E '^[[:space:]]+image:' <<< "$agent" | awk '{print $2}' | tr -d '"' | sort -u)
  api_img=${api_img//$'\n'/ | }
  agent_img=${agent_img//$'\n'/ | }
  if [ -z "$api_img" ] || [ -z "$agent_img" ]; then
    fail "$profile: could not read both images (apiserver=[$api_img] agentserver=[$agent_img])"
    return 0
  fi
  if [ "$api_img" = "$agent_img" ]; then
    ok "$profile: apiserver and agentserver run the same image ($api_img)"
  else
    fail "$profile: the apiserver renders [$api_img] but the agentserver renders [$agent_img] -- the two subchart pins name different kubexa-backend releases. If that is deliberate, say so in the umbrella Chart.yaml note and change this assertion; if it is not, one of the two pins was forgotten, which is exactly how 0.7.13 came to be"
  fi
}

# ── self-test assertions ────────────────────────────────────────────────────
# All of these run against the `selftest` profile except the two that prove the
# opposite (nothing by default, unknown key rejected). Each reads the Job and
# the thing it must agree with from the SAME render, because the template
# rebuilds names and ports parent-side and only a comparison against the
# rendered Deployments proves the copy is right rather than merely plausible.

# The Job's image must equal the apiserver's. Twin of the preflight assertion,
# for the same reason: two components here once ran different images.
assert_selftest_image_matches_apiserver() {
  local out=$1 profile=$2
  [ "$profile" = "selftest" ] || return 0
  local st api st_img api_img
  st=$(extract_source "$out" "kubexa/templates/selftest.yaml")
  api=$(extract_source "$out" "kubexa/charts/apiserver/templates/deployment.yaml")
  st_img=$(grep -E '^[[:space:]]+image:' <<< "$st" | awk '{print $2}' | tr -d '"' | sort -u)
  api_img=$(grep -E '^[[:space:]]+image:' <<< "$api" | awk '{print $2}' | tr -d '"' | sort -u)
  st_img=${st_img//$'\n'/ | }
  api_img=${api_img//$'\n'/ | }
  if [ -z "$st_img" ] || [ -z "$api_img" ]; then
    fail "$profile: could not read both images (selftest=[$st_img] apiserver=[$api_img])"
    return 0
  fi
  if [ "$st_img" = "$api_img" ]; then
    ok "$profile: selftest and apiserver run the same image ($st_img)"
  else
    fail "$profile: selftest runs [$st_img] but the apiserver renders [$api_img] -- selftest.image.tag has drifted from the apiserver subchart's appVersion, so the binary under test is a different release from the one it tests"
  fi
}

# The config Secret names the Job mounts must equal the ones the Deployments
# mount. The template builds them with kubexa.subchartFullname, a COPY of each
# subchart's fullname logic; this is the only thing that notices the copy and
# the original part ways.
assert_selftest_mounts_the_deployments_secrets() {
  local out=$1 profile=$2
  [ "$profile" = "selftest" ] || return 0
  local st api agent
  st=$(extract_source "$out" "kubexa/templates/selftest.yaml")
  api=$(extract_source "$out" "kubexa/charts/apiserver/templates/deployment.yaml")
  agent=$(extract_source "$out" "kubexa/charts/agentserver/templates/deployment.yaml")
  local st_api st_agent dep_api dep_agent
  # The Job's volume is keyed by its name; the Deployments' by `name: config`.
  # The Job's volumeMounts reuse the same names, so a mountPath resets the scan.
  st_api=$(awk '/^[[:space:]]+- name: apiserver-config$/ {g=1; next} g && /mountPath:/ {g=0} g && /secretName:/ {print $2; exit}' <<< "$st")
  st_agent=$(awk '/^[[:space:]]+- name: agentserver-config$/ {g=1; next} g && /mountPath:/ {g=0} g && /secretName:/ {print $2; exit}' <<< "$st")
  dep_api=$(awk '/^[[:space:]]+- name: config$/ {g=1; next} g && /mountPath:/ {g=0} g && /secretName:/ {print $2; exit}' <<< "$api")
  dep_agent=$(awk '/^[[:space:]]+- name: config$/ {g=1; next} g && /mountPath:/ {g=0} g && /secretName:/ {print $2; exit}' <<< "$agent")
  if [ -z "$st_api" ] || [ -z "$st_agent" ] || [ -z "$dep_api" ] || [ -z "$dep_agent" ]; then
    fail "$profile: could not read all four Secret names (job apiserver=[$st_api] agentserver=[$st_agent]; deployments apiserver=[$dep_api] agentserver=[$dep_agent])"
    return 0
  fi
  if [ "$st_api" = "$dep_api" ]; then
    ok "$profile: selftest mounts the apiserver's config Secret ($st_api)"
  else
    fail "$profile: selftest mounts [$st_api] but the apiserver Deployment mounts [$dep_api] -- kubexa.subchartFullname no longer matches the subchart's fullname"
  fi
  if [ "$st_agent" = "$dep_agent" ]; then
    ok "$profile: selftest mounts the agentserver's config Secret ($st_agent)"
  else
    fail "$profile: selftest mounts [$st_agent] but the agentserver Deployment mounts [$dep_agent] -- kubexa.subchartFullname no longer matches the subchart's fullname"
  fi
}

# --agentserver-target must be the agent-facing gRPC port. Both listeners
# register grpc_health_v1, so a target on the admin port passes the gate check
# while the door an agent knocks on is shut. The flag is a Service address, so it is compared with the
# rendered Services' own `port:` (service.yaml for agents, service-internal.yaml
# for admin), not a Deployment containerPort or values, and the admin port is asserted
# against explicitly.
assert_selftest_targets_the_agent_port() {
  local out=$1 profile=$2
  [ "$profile" = "selftest" ] || return 0
  local st agent adminsvc target port grpc admin
  st=$(extract_source "$out" "kubexa/templates/selftest.yaml")
  agent=$(extract_source "$out" "kubexa/charts/agentserver/templates/service.yaml")
  adminsvc=$(extract_source "$out" "kubexa/charts/agentserver/templates/service-internal.yaml")
  target=$(grep -E '^[[:space:]]+- --agentserver-target=' <<< "$st" | head -n 1 || true)
  port=${target##*:}
  grpc=$(awk '/^[[:space:]]+- name: grpc$/ {g=1; next} g && /^[[:space:]]+port:/ {print $2; exit}' <<< "$agent")
  admin=$(awk '/^[[:space:]]+- name: admin$/ {g=1; next} g && /^[[:space:]]+port:/ {print $2; exit}' <<< "$adminsvc")
  if [ -z "$target" ] || [ -z "$grpc" ] || [ -z "$admin" ]; then
    fail "$profile: could not read target/Service ports (target=[$target] grpc=[$grpc] admin=[$admin])"
    return 0
  fi
  if [ "$grpc" = "$admin" ]; then
    fail "$profile: the agentserver's grpc and admin Service ports are both $grpc -- this assertion cannot tell them apart"
    return 0
  fi
  if [ "$port" = "$admin" ]; then
    fail "$profile: --agentserver-target names the ADMIN port $admin -- its health server answers SERVING while the agent-facing port $grpc may be shut"
  elif [ "$port" = "$grpc" ]; then
    ok "$profile: --agentserver-target names the agent-facing port $grpc, not admin $admin"
  else
    fail "$profile: --agentserver-target port is [$port], expected the agent-facing port $grpc"
  fi
}

# A Kubernetes Job defaults to backoffLimit 6: one failing run would become
# seven, each publishing synthetic telemetry that cannot be deleted.
assert_selftest_backoff_limit_zero() {
  local out=$1 profile=$2
  [ "$profile" = "selftest" ] || return 0
  local st
  st=$(extract_source "$out" "kubexa/templates/selftest.yaml")
  if grep -qE '^[[:space:]]+backoffLimit: 0$' <<< "$st"; then
    ok "$profile: selftest backoffLimit is 0"
  else
    fail "$profile: selftest backoffLimit is not 0 -- a failing run would be retried up to six times, each publishing synthetic telemetry that cannot be deleted"
  fi
}

# An empty --apiserver-url makes four checks SKIP and the run exit 2 while
# looking as if it ran.
assert_selftest_apiserver_url_present() {
  local out=$1 profile=$2
  [ "$profile" = "selftest" ] || return 0
  local st line val
  st=$(extract_source "$out" "kubexa/templates/selftest.yaml")
  line=$(grep -E '^[[:space:]]+- --apiserver-url=' <<< "$st" | head -n 1 || true)
  val=${line#*--apiserver-url=}
  if [ -n "$line" ] && [ -n "$val" ]; then
    ok "$profile: --apiserver-url is set ($val)"
  else
    fail "$profile: --apiserver-url is missing or empty (line=[$line]) -- four checks would SKIP and the run would exit 2 while appearing to have run"
  fi
}

# The chart reads the durable from the consumer's VALUES rather than mounting
# its Secret, so this is the drift pin that choice depends on: compare the
# flag with the durable name in the consumer's rendered config.
assert_selftest_durable_matches_consumer() {
  local out=$1 profile=$2
  [ "$profile" = "selftest" ] || return 0
  local st cons flag rendered
  st=$(extract_source "$out" "kubexa/templates/selftest.yaml")
  cons=$(extract_source "$out" "kubexa/charts/consumer/templates/secret.yaml")
  flag=$(grep -E '^[[:space:]]+- --consumer-durable=' <<< "$st" | head -n 1 || true)
  flag=${flag#*--consumer-durable=}
  rendered=$(awk '/^[[:space:]]+consumer:$/ {g=1; next} g && /^[[:space:]]+name:/ {print $2; exit}' <<< "$cons" | tr -d '"')
  if [ -z "$flag" ] || [ -z "$rendered" ]; then
    fail "$profile: could not read both durables (flag=[$flag] consumer config=[$rendered])"
    return 0
  fi
  if [ "$flag" = "$rendered" ]; then
    ok "$profile: --consumer-durable matches the consumer's rendered durable ($flag)"
  else
    fail "$profile: --consumer-durable=[$flag] but the consumer's rendered config names [$rendered] -- the self-test would watch a durable that does not exist and report a dead consumer"
  fi
}

# The self-test's RBAC is the security boundary of this Job, so it is pinned
# tightly. The self-test document must hold exactly ServiceAccount, Role,
# RoleBinding and Job; the Role must be a namespaced Role with `list` as its
# only verb on exactly the five workload kinds; no ClusterRole(Binding) may
# carry a selftest name; and the Job must run as that ServiceAccount with
# SELFTEST_NAMESPACE from the downward API. A Role that quietly gains get,
# watch or a write verb, a sixth resource, or a cluster scope is what this
# exists to catch. Herestrings only: see assert_bundled_vm for the SIGPIPE trap.
assert_selftest_rbac_is_namespaced_and_list_only() {
  local out=$1 profile=$2
  [ "$profile" = "selftest" ] || return 0
  local st kinds role verbs groups resources cluster sa job_sa ref
  st=$(extract_source "$out" "kubexa/templates/selftest.yaml")
  kinds=$(grep -E '^kind:' <<< "$st" | awk '{print $2}' | sort | tr '\n' ' ')
  if [ "$kinds" != "Job Role RoleBinding ServiceAccount " ]; then
    fail "$profile: selftest.yaml renders [$kinds], expected exactly Job Role RoleBinding ServiceAccount -- a ClusterRole or extra object would widen the self-test's authority"
    return 0
  fi
  # Anywhere in the render, not just this file: a ClusterRole smuggled in from
  # another template under the self-test's name is the same widening.
  cluster=$(awk '/^---$/ { if (k ~ /^ClusterRole(Binding)?$/ && n ~ /selftest/) print k " " n; k=""; n=""; m=0; next }
    /^kind:/ { k=$2 } /^metadata:/ { m=1; next } /^[a-zA-Z]/ { m=0 } m && /^  name:/ && n=="" { n=$2 }
    END { if (k ~ /^ClusterRole(Binding)?$/ && n ~ /selftest/) print k " " n }' <<< "$out")
  if [ -n "$cluster" ]; then
    fail "$profile: cluster-scoped RBAC named for the self-test (${cluster//$'\n'/ | }) -- the Role must stay namespaced"
    return 0
  fi
  role=$(awk '/^kind: Role$/ {f=1} /^---$/ {f=0} f' <<< "$st")
  verbs=$(grep -E '^[[:space:]]+verbs:' <<< "$role" | sed 's/^[[:space:]]*verbs:[[:space:]]*//' | sort -u || true)
  if [ "$verbs" != '["list"]' ]; then
    fail "$profile: the self-test Role's verbs are [${verbs//$'\n'/ | }], expected only [\"list\"] -- get/watch/write would let a pod holding every platform credential read or change more than the one thing the installed-image check needs"
    return 0
  fi
  groups=$(grep -E '^[[:space:]]+- apiGroups:' <<< "$role" | sed 's/^[[:space:]]*- apiGroups:[[:space:]]*//' | sort -u || true)
  if [ "$groups" != $'["apps"]\n["batch"]' ]; then
    fail "$profile: the self-test Role's apiGroups are [${groups//$'\n'/ | }], expected exactly [\"apps\"] and [\"batch\"] -- a wildcard or extra group widens what the same resource names match"
    return 0
  fi
  resources=$(grep -E '^[[:space:]]+resources:' <<< "$role" | sed 's/^[[:space:]]*resources:[[:space:]]*//' | tr -d '[]" ' | tr ',' '\n' | sort | tr '\n' ' ')
  if [ "$resources" != "cronjobs daemonsets deployments jobs statefulsets " ]; then
    fail "$profile: the self-test Role's resources are [$resources], expected exactly cronjobs daemonsets deployments jobs statefulsets -- a new resource (secrets above all) is a grant the check does not need"
    return 0
  fi
  ref=$(awk '/^roleRef:/ {f=1; next} /^[a-zA-Z]/ {f=0} f' <<< "$st")
  if ! grep -qE '^[[:space:]]+kind: Role$' <<< "$ref"; then
    fail "$profile: the RoleBinding's roleRef is not kind: Role"
    return 0
  fi
  sa=$(awk '/^kind: ServiceAccount$/ {f=1} f && /^  name:/ {print $2; exit}' <<< "$st")
  job_sa=$(grep -E '^[[:space:]]+serviceAccountName:' <<< "$st" | awk '{print $2}')
  if [ -z "$sa" ] || [ "$sa" != "$job_sa" ]; then
    fail "$profile: the Job runs as [$job_sa] but the ServiceAccount is [$sa]"
    return 0
  fi
  if ! grep -A3 'name: SELFTEST_NAMESPACE' <<< "$st" | grep -qF 'fieldPath: metadata.namespace'; then
    fail "$profile: SELFTEST_NAMESPACE is not taken from fieldRef metadata.namespace -- a templated value would be the chart's opinion of the namespace, not the pod's"
    return 0
  fi
  ok "$profile: self-test RBAC is a namespaced Role, list-only on the five workload kinds, bound to the Job's ServiceAccount; SELFTEST_NAMESPACE from fieldRef"
}

# selftest.rbac.create=false must render coherently: the ServiceAccount and
# the Job, no Role, no RoleBinding (a RoleBinding would dangle on a Role that
# is not there), and the Job still runs as the ServiceAccount that exists.
# Renders independently of $out, once, on the selftest profile.
assert_selftest_rbac_create_false_is_coherent() {
  local out=$1 profile=$2
  [ "$profile" = "selftest" ] || return 0
  local res st kinds sa job_sa
  if ! res=$(helm template kubexa "$CHART" -f "$PROFILES_DIR/selftest.yaml" --set selftest.rbac.create=false 2>&1); then
    fail "$profile: --set selftest.rbac.create=false failed to render: ${res:0:300}"
    return 0
  fi
  st=$(extract_source "$res" "kubexa/templates/selftest.yaml")
  kinds=$(grep -E '^kind:' <<< "$st" | awk '{print $2}' | sort | tr '\n' ' ')
  if [ "$kinds" != "Job ServiceAccount " ]; then
    fail "$profile: with selftest.rbac.create=false selftest.yaml renders [$kinds], expected exactly Job ServiceAccount -- a Role or RoleBinding the installer was told not to create"
    return 0
  fi
  sa=$(awk '/^kind: ServiceAccount$/ {f=1} f && /^  name:/ {print $2; exit}' <<< "$st")
  job_sa=$(grep -E '^[[:space:]]+serviceAccountName:' <<< "$st" | awk '{print $2}')
  if [ -z "$sa" ] || [ "$sa" != "$job_sa" ]; then
    fail "$profile: with selftest.rbac.create=false the Job runs as [$job_sa] but the ServiceAccount is [$sa]"
    return 0
  fi
  ok "$profile: selftest.rbac.create=false renders only the Job and its ServiceAccount (no dangling binding)"
}

# The default must render nothing for the self-test: a default-on Job holding
# the union of the platform's credentials is a defect.
assert_no_selftest_unless_asked() {
  local out=$1 profile=$2
  [ "$profile" = "selftest" ] && return 0
  if grep -qF '# Source: kubexa/templates/selftest.yaml' <<< "$out"; then
    fail "$profile: selftest.yaml rendered a document with selftest.enabled unset -- the self-test Job would ship into a normal install holding the platform's credentials"
    return 0
  fi
  if grep -q 'kubexa-selftest' <<< "$out"; then
    fail "$profile: selftest.yaml rendered nothing, but something else in this render names kubexa-selftest"
    return 0
  fi
  ok "$profile: no selftest objects"
}

# The schema must reject an unknown selftest key. A non-strict loader once let
# a camelCase key vanish here, and a rule that lost its filter collected ~9 GiB
# a day. Run once, on the default profile; it renders independently of $out.
assert_selftest_schema_rejects_unknown_key() {
  local out=$1 profile=$2
  [ "$profile" = "default" ] || return 0
  local res
  if res=$(helm template kubexa "$CHART" -f "$PROFILES_DIR/default.yaml" --set selftest.enabledd=true 2>&1); then
    fail "$profile: --set selftest.enabledd=true rendered successfully -- the schema no longer rejects unknown selftest keys"
  elif grep -qF 'enabledd' <<< "$res"; then
    ok "$profile: the schema rejects an unknown selftest key"
  else
    fail "$profile: --set selftest.enabledd=true failed, but not on the key itself: ${res:0:300}"
  fi
}

# ── support-bundle assertions ───────────────────────────────────────────────
# All of these run against the `supportbundle` profile except the two that prove
# the opposite (nothing by default, unknown key / wrong type rejected). An
# assertion that never runs prints nothing and the script still passes, so each
# one prints an `ok:` line that the run must show. Herestrings only: see
# assert_bundled_vm for the SIGPIPE trap.

# Same drift this product shipped twice: the Job's image must equal the
# apiserver's.
assert_supportbundle_image_matches_apiserver() {
  local out=$1 profile=$2
  [ "$profile" = "supportbundle" ] || return 0
  local sb api sb_img api_img
  sb=$(extract_source "$out" "kubexa/templates/supportbundle.yaml")
  api=$(extract_source "$out" "kubexa/charts/apiserver/templates/deployment.yaml")
  sb_img=$(grep -E '^[[:space:]]+image:' <<< "$sb" | awk '{print $2}' | tr -d '"' | sort -u || true)
  api_img=$(grep -E '^[[:space:]]+image:' <<< "$api" | awk '{print $2}' | tr -d '"' | sort -u || true)
  sb_img=${sb_img//$'\n'/ | }
  api_img=${api_img//$'\n'/ | }
  if [ -z "$sb_img" ] || [ -z "$api_img" ]; then
    fail "$profile: could not read both images (supportbundle=[$sb_img] apiserver=[$api_img])"
    return 0
  fi
  if [ "$sb_img" = "$api_img" ]; then
    ok "$profile: supportbundle and apiserver run the same image ($sb_img)"
  else
    fail "$profile: supportbundle runs [$sb_img] but the apiserver renders [$api_img] -- supportBundle.image.tag has drifted from the apiserver subchart's appVersion"
  fi
}

# The config Secrets the Job mounts must be the ones the Deployments mount,
# read-only and optional.
assert_supportbundle_mounts_the_deployments_secrets() {
  local out=$1 profile=$2
  [ "$profile" = "supportbundle" ] || return 0
  local sb api agent sb_api sb_agent dep_api dep_agent
  sb=$(extract_source "$out" "kubexa/templates/supportbundle.yaml")
  api=$(extract_source "$out" "kubexa/charts/apiserver/templates/deployment.yaml")
  agent=$(extract_source "$out" "kubexa/charts/agentserver/templates/deployment.yaml")
  sb_api=$(awk '/^[[:space:]]+- name: apiserver-config$/ {g=1; next} g && /mountPath:/ {g=0} g && /secretName:/ {print $2; exit}' <<< "$sb")
  sb_agent=$(awk '/^[[:space:]]+- name: agentserver-config$/ {g=1; next} g && /mountPath:/ {g=0} g && /secretName:/ {print $2; exit}' <<< "$sb")
  dep_api=$(awk '/^[[:space:]]+- name: config$/ {g=1; next} g && /mountPath:/ {g=0} g && /secretName:/ {print $2; exit}' <<< "$api")
  dep_agent=$(awk '/^[[:space:]]+- name: config$/ {g=1; next} g && /mountPath:/ {g=0} g && /secretName:/ {print $2; exit}' <<< "$agent")
  if [ -z "$sb_api" ] || [ -z "$sb_agent" ] || [ -z "$dep_api" ] || [ -z "$dep_agent" ]; then
    fail "$profile: could not read all four Secret names (job apiserver=[$sb_api] agentserver=[$sb_agent]; deployments apiserver=[$dep_api] agentserver=[$dep_agent])"
    return 0
  fi
  if [ "$sb_api" != "$dep_api" ] || [ "$sb_agent" != "$dep_agent" ]; then
    fail "$profile: supportbundle mounts [$sb_api] [$sb_agent] but the Deployments mount [$dep_api] [$dep_agent] -- kubexa.subchartFullname no longer matches the subchart's fullname"
    return 0
  fi
  # Counted inside the volumes block only. This used to count the whole
  # document and expect 2, which was right only while nothing else in the Job
  # was optional -- the two credential secretKeyRefs added in chart 0.8.26 are
  # also optional: true, and a document-wide count read 4 and failed on a
  # correct render. Scope the count to what the assertion is about.
  local volumes optional ro
  volumes=$(awk '/^      volumes:$/ {v=1} v' <<< "$sb")
  optional=$(grep -cE '^[[:space:]]+optional: true$' <<< "$volumes" || true)
  ro=$(grep -cE '^[[:space:]]+readOnly: true$' <<< "$sb" || true)
  if [ "$optional" != "2" ] || [ "$ro" != "2" ]; then
    fail "$profile: expected both config Secret volumes optional: true and both mounts readOnly: true, found optional=$optional (in volumes) readOnly=$ro"
    return 0
  fi
  ok "$profile: supportbundle mounts the Deployments' config Secrets ($sb_api, $sb_agent), read-only and optional"
}

# The two credentials the Job is given, and the fact that it is given no
# others. Three separate claims, each of which has its own failure:
#
#   - both are present: without them the database readings section cannot
#     connect on a default install and three of nine sections lose their value.
#   - both are optional: a non-optional secretKeyRef whose Secret is absent
#     fails the pod with CreateContainerConfigError, so the command written to
#     explain a broken install would be the thing that will not start.
#   - there is no THIRD credential: this Job's whole masking design rests on
#     default-deny, and an env var nobody reviewed is how that gets undone.
#
# The names are read from the apiserver's own Deployment rather than written
# here, for the same reason the config-Secret assertion does it: a literal
# would stay green if the chart started pointing the two at different Secrets.
assert_supportbundle_credentials() {
  local out=$1 profile=$2
  [ "$profile" = "supportbundle" ] || return 0
  local sb api env_block
  sb=$(extract_source "$out" "kubexa/templates/supportbundle.yaml")
  api=$(extract_source "$out" "kubexa/charts/apiserver/templates/deployment.yaml")
  env_block=$(awk '/^          env:$/ {e=1; next} e && /^          [a-z]/ {e=0} e' <<< "$sb")

  # Initialized explicitly, and that is load-bearing: `local x` leaves x UNSET
  # on bash 4.4+ (the CI runner), so the first `x="$x ..."` append below dies
  # with "unbound variable" under `set -u`. macOS ships bash 3.2, where the
  # same declaration yields a set-but-empty variable -- so this assertion ran
  # green on a developer machine and could never run at all in CI.
  local sb_names="" dep_names="" v
  for v in KUBEXA_APISERVER_POSTGRES_APP_PASSWORD KUBEXA_APISERVER_POSTGRES_USERS_PASSWORD; do
    # The var's own block, so "declared but not optional" and "not declared at
    # all" are two different findings with two different messages. They were one
    # message in the first draft of this assertion, which reported a missing
    # optional as a missing variable -- true that something was wrong, wrong
    # about what.
    local block name key optional
    block=$(awk -v want="- name: $v" '
      index($0, want) {g=1; next}
      g && /- name: / {exit}
      g' <<< "$env_block")
    if [ -z "$block" ]; then
      fail "$profile: the Job declares no $v at all -- the database readings section cannot connect without it, and the bundle's cross-field HMAC comparison has nothing to compare"
      return 0
    fi
    name=$(awk '/name:/ {print $2; exit}' <<< "$block")
    key=$(awk '/key:/ {print $2; exit}' <<< "$block")
    optional=$(awk '/optional:/ {print $2; exit}' <<< "$block")
    if [ -z "$name" ] || [ -z "$key" ]; then
      fail "$profile: $v is declared but names no Secret and key (name=[$name] key=[$key])"
      return 0
    fi
    if [ "$optional" != "true" ]; then
      fail "$profile: $v has optional=[$optional], expected true -- a non-optional secretKeyRef whose Secret is absent fails this pod with CreateContainerConfigError, which would mean the one command written to explain a broken install is itself the thing that will not start"
      return 0
    fi
    sb_names="$sb_names $name/$key"
    local dep
    dep=$(awk -v want="- name: $v" '
      index($0, want) {g=1; next}
      g && /- name: / {exit}
      g && /name:/ {n=$2}
      g && /key:/ {print n "/" $2; exit}' <<< "$api")
    if [ -z "$dep" ]; then
      fail "$profile: the apiserver Deployment declares no $v, so this assertion cannot compare the Job against it"
      return 0
    fi
    dep_names="$dep_names $dep"
  done

  if [ "$sb_names" != "$dep_names" ]; then
    fail "$profile: the Job reads [$sb_names] but the apiserver Deployment reads [$dep_names] -- the two are pointed at different Secrets, so the bundle would read a credential the apiserver does not use"
    return 0
  fi

  # "no third credential" is asserted by assert_supportbundle_job_shape, which
  # pins the exact env name list -- stronger than a count and already there.
  ok "$profile: the Job is given exactly the two Postgres passwords the apiserver uses, both optional, and nothing else"
}

# The Role, to the letter: a namespaced Role, exactly the five rules plus
# pods/log get, no secrets, no write verb, no pods/exec; the binding names the
# Role and the ServiceAccount; the Job runs as that ServiceAccount.
assert_supportbundle_rbac_is_namespaced_and_read_only() {
  local out=$1 profile=$2
  [ "$profile" = "supportbundle" ] || return 0
  local sb kinds role rules expected cluster sa job_sa ref subj
  sb=$(extract_source "$out" "kubexa/templates/supportbundle.yaml")
  kinds=$(grep -E '^kind:' <<< "$sb" | awk '{print $2}' | sort | tr '\n' ' ' || true)
  if [ "$kinds" != "Job Role RoleBinding ServiceAccount " ]; then
    fail "$profile: supportbundle.yaml renders [$kinds], expected exactly Job Role RoleBinding ServiceAccount"
    return 0
  fi
  cluster=$(awk '/^---$/ { if (k ~ /^ClusterRole(Binding)?$/ && n ~ /support-bundle/) print k " " n; k=""; n=""; m=0; next }
    /^kind:/ { k=$2 } /^metadata:/ { m=1; next } /^[a-zA-Z]/ { m=0 } m && /^  name:/ && n=="" { n=$2 }
    END { if (k ~ /^ClusterRole(Binding)?$/ && n ~ /support-bundle/) print k " " n }' <<< "$out")
  if [ -n "$cluster" ]; then
    fail "$profile: cluster-scoped RBAC named for the support bundle (${cluster//$'\n'/ | }) -- the Role must stay namespaced"
    return 0
  fi
  role=$(awk '/^kind: Role$/ {f=1} /^---$/ {f=0} f' <<< "$sb")
  rules=$(grep -E '^[[:space:]]+(- )?(apiGroups|resources|verbs):' <<< "$role" | sed -E 's/^[[:space:]]+(- )?//' || true)
  expected='apiGroups: ["apps"]
resources: ["deployments", "statefulsets", "daemonsets"]
verbs: ["list"]
apiGroups: ["batch"]
resources: ["jobs", "cronjobs"]
verbs: ["list"]
apiGroups: [""]
resources: ["pods"]
verbs: ["list"]
apiGroups: [""]
resources: ["pods/log"]
verbs: ["get"]
apiGroups: [""]
resources: ["events"]
verbs: ["list"]'
  if [ "$rules" != "$expected" ]; then
    fail "$profile: the support-bundle Role's rules differ from the five list rules plus get pods/log. Got: ${rules//$'\n'/ ; }"
    return 0
  fi
  if grep -qE 'pods/exec|secrets|"(create|update|patch|delete|deletecollection|watch|\*)"' <<< "$role"; then
    fail "$profile: the support-bundle Role mentions pods/exec, secrets, watch, a wildcard or a write verb"
    return 0
  fi
  ref=$(awk '/^roleRef:/ {f=1; next} /^[a-zA-Z]/ {f=0} f' <<< "$sb")
  sa=$(awk '/^kind: ServiceAccount$/ {f=1} f && /^  name:/ {print $2; exit}' <<< "$sb")
  job_sa=$(grep -E '^[[:space:]]+serviceAccountName:' <<< "$sb" | awk '{print $2}' || true)
  subj=$(awk '/^subjects:/ {f=1; next} /^[a-zA-Z]/ {f=0} f' <<< "$sb")
  if ! grep -qE '^[[:space:]]+kind: Role$' <<< "$ref" || ! grep -qF "name: kubexa-support-bundle" <<< "$ref"; then
    fail "$profile: the RoleBinding's roleRef is not kind: Role name: kubexa-support-bundle"
    return 0
  fi
  if ! grep -qE '^[[:space:]]+- kind: ServiceAccount$' <<< "$subj" || ! grep -qF "name: $sa" <<< "$subj"; then
    fail "$profile: the RoleBinding's subject is not the ServiceAccount [$sa]"
    return 0
  fi
  if ! grep -qE '^[[:space:]]+namespace: default$' <<< "$subj"; then
    fail "$profile: the RoleBinding subject carries no namespace: default (the namespace render.sh installs into) -- a ServiceAccount subject without it binds nothing"
    return 0
  fi
  if [ "$sa" != "kubexa-support-bundle" ] || [ "$sa" != "$job_sa" ]; then
    fail "$profile: the Job runs as [$job_sa] and the ServiceAccount is [$sa]; both must be kubexa-support-bundle (the runbook's cleanup command names it)"
    return 0
  fi
  ok "$profile: support-bundle RBAC is a namespaced Role of exactly five list rules plus get pods/log (no secrets, no write, no exec), bound to the Job's ServiceAccount kubexa-support-bundle"
}

# The Job's shape: no retry, no TTL, no hook, no credential env, the namespace
# from the downward API, the command, the flags and the Service URL.
assert_supportbundle_job_shape() {
  local out=$1 profile=$2
  [ "$profile" = "supportbundle" ] || return 0
  local sb api_svc
  sb=$(extract_source "$out" "kubexa/templates/supportbundle.yaml")
  if ! grep -qE '^  backoffLimit: 0$' <<< "$sb"; then
    fail "$profile: support-bundle backoffLimit is not 0 -- a retry writes a second bundle into a second pod's log"
    return 0
  fi
  # secretKeyRef was in this prohibition until chart 0.8.26, when the Job was
  # deliberately given two credentials. What governs them now is
  # assert_supportbundle_credentials, which is stricter than a ban: it pins
  # which two, that both are optional, and that there is no third. The TTL and
  # the Helm hook remain prohibited outright.
  if grep -qE 'ttlSecondsAfterFinished|helm.sh/hook' <<< "$sb"; then
    fail "$profile: the support-bundle Job carries a TTL (it would delete the log) or a Helm hook annotation (a failing hook fails the release, and this Job is run by hand)"
    return 0
  fi
  if ! grep -A3 'name: KUBEXA_NAMESPACE' <<< "$sb" | grep -qF 'fieldPath: metadata.namespace'; then
    fail "$profile: KUBEXA_NAMESPACE is not taken from fieldRef metadata.namespace"
    return 0
  fi
  if ! grep -qF 'command: ["/kubexa-supportbundle"]' <<< "$sb"; then
    fail "$profile: the container does not run /kubexa-supportbundle"
    return 0
  fi
  local env_names
  env_names=$(grep -E '^[[:space:]]+- name: [A-Z_]+$' <<< "$sb" | awk '{print $3}' | tr '\n' ' ' || true)
  # The exact list, in order. A new name here is a new path into a bundle whose
  # configuration masking is default-deny, so it is added deliberately or not
  # at all. assert_supportbundle_credentials pins what the two passwords point
  # at and that both are optional.
  if [ "$env_names" != "KUBEXA_NAMESPACE KUBEXA_APISERVER_POSTGRES_APP_PASSWORD KUBEXA_APISERVER_POSTGRES_USERS_PASSWORD " ]; then
    fail "$profile: the Job's environment is [$env_names], expected exactly KUBEXA_NAMESPACE and the two Postgres passwords"
    return 0
  fi
  local flag
  for flag in --apiserver-config=/etc/kubexa/apiserver/config.yaml --agentserver-config=/etc/kubexa/agentserver/config.yaml \
      --tail-lines=200 --limit-bytes=262144 --max-events=200 --byte-ceiling=4194304 --timeout=240s --log-read-timeout=10s; do
    if ! grep -qE "^[[:space:]]+- ${flag}\$" <<< "$sb"; then
      fail "$profile: the support-bundle Job is missing the argument $flag"
      return 0
    fi
  done
  api_svc=$(extract_source "$out" "kubexa/charts/apiserver/templates/service.yaml")
  local svc_name
  svc_name=$(awk '/^kind: Service$/ {f=1} f && /^  name:/ {print $2; exit}' <<< "$api_svc")
  if [ -z "$svc_name" ] || ! grep -qE "^[[:space:]]+- --apiserver-url=http://${svc_name}\.[^.]+\.svc:8080\$" <<< "$sb"; then
    fail "$profile: --apiserver-url does not name the apiserver Service [$svc_name] on 8080"
    return 0
  fi
  ok "$profile: support-bundle Job: backoffLimit 0, no TTL, no hook, exactly three env names, KUBEXA_NAMESPACE from fieldRef, /kubexa-supportbundle with all eight arguments, --apiserver-url -> $svc_name"
}

# Properties nothing else pins: the key->config.yaml rename in both volumes
# (without it the binary finds no file at its default flag path and both config
# sections come back empty), the deadline arithmetic, restartPolicy, and the
# security context.
assert_supportbundle_pod_invariants() {
  local out=$1 profile=$2
  [ "$profile" = "supportbundle" ] || return 0
  local sb vol items dl to
  sb=$(extract_source "$out" "kubexa/templates/supportbundle.yaml")
  for vol in apiserver-config agentserver-config; do
    items=$(awk -v v="$vol" '$0 ~ "^[[:space:]]+- name: " v "$" {g=1; next} g && /mountPath:/ {g=0} g && /items:/ {i=1; next} g && i && /- key:/ {k=$3} g && i && /path:/ {print k " " $2; exit}' <<< "$sb" || true)
    if [ -z "$items" ]; then
      fail "$profile: volume $vol has no items key->path rename"
      return 0
    fi
    case "$items" in
      "apiserver.yaml config.yaml"|"agentserver.yaml config.yaml") ;;
      *) fail "$profile: volume $vol projects [$items], expected <key> config.yaml with the subchart's default key"
         return 0 ;;
    esac
    if [ "$vol" = "apiserver-config" ] && [ "$items" != "apiserver.yaml config.yaml" ]; then
      fail "$profile: apiserver-config projects [$items]"; return 0
    fi
    if [ "$vol" = "agentserver-config" ] && [ "$items" != "agentserver.yaml config.yaml" ]; then
      fail "$profile: agentserver-config projects [$items]"; return 0
    fi
  done
  dl=$(grep -E '^  activeDeadlineSeconds: ' <<< "$sb" | awk '{print $2}' || true)
  to=$(grep -E '^[[:space:]]+- --timeout=' <<< "$sb" | sed -E 's/.*--timeout=//' || true)
  if ! [[ "$dl" =~ ^[0-9]+$ ]] || ! [[ "$to" =~ ^[0-9]+s$ ]]; then
    fail "$profile: cannot compare the deadlines: activeDeadlineSeconds=[$dl] --timeout=[$to] (expected plain integer seconds and Ns)"
    return 0
  fi
  to=${to%s}
  if [ "$dl" -le "$to" ] || [ $((dl - to)) -lt 90 ]; then
    fail "$profile: activeDeadlineSeconds ($dl) is not at least 90s above --timeout ($to) -- the Job deadline would delete the pod, and the bundle in its log, before the command's own bound fires"
    return 0
  fi
  if ! grep -qE '^      restartPolicy: Never$' <<< "$sb"; then
    fail "$profile: the support-bundle pod's restartPolicy is not Never"
    return 0
  fi
  local needle
  for needle in '        runAsNonRoot: true' '        runAsUser: 65532' '          type: RuntimeDefault' \
      '            allowPrivilegeEscalation: false' '            readOnlyRootFilesystem: true' '              drop: ["ALL"]'; do
    if ! grep -qxF "$needle" <<< "$sb"; then
      fail "$profile: the support-bundle security context lost [${needle#"${needle%%[![:space:]]*}"}]"
      return 0
    fi
  done
  ok "$profile: support-bundle pod: config items rename to config.yaml in both volumes, deadline $dl is $((dl - to))s above --timeout $to, restartPolicy Never, security context pinned"
}

# supportBundle.rbac.create=false: ServiceAccount and Job survive, Role and
# RoleBinding vanish, and the Job still runs as the ServiceAccount that exists.
assert_supportbundle_rbac_create_false_is_coherent() {
  local out=$1 profile=$2
  [ "$profile" = "supportbundle" ] || return 0
  local res sb kinds sa job_sa
  if ! res=$(helm template kubexa "$CHART" -f "$PROFILES_DIR/supportbundle.yaml" --set supportBundle.rbac.create=false 2>&1); then
    fail "$profile: --set supportBundle.rbac.create=false failed to render: ${res:0:300}"
    return 0
  fi
  sb=$(extract_source "$res" "kubexa/templates/supportbundle.yaml")
  kinds=$(grep -E '^kind:' <<< "$sb" | awk '{print $2}' | sort | tr '\n' ' ' || true)
  if [ "$kinds" != "Job ServiceAccount " ]; then
    fail "$profile: with supportBundle.rbac.create=false supportbundle.yaml renders [$kinds], expected exactly Job ServiceAccount"
    return 0
  fi
  sa=$(awk '/^kind: ServiceAccount$/ {f=1} f && /^  name:/ {print $2; exit}' <<< "$sb")
  job_sa=$(grep -E '^[[:space:]]+serviceAccountName:' <<< "$sb" | awk '{print $2}' || true)
  if [ -z "$sa" ] || [ "$sa" != "$job_sa" ]; then
    fail "$profile: with supportBundle.rbac.create=false the Job runs as [$job_sa] but the ServiceAccount is [$sa]"
    return 0
  fi
  ok "$profile: supportBundle.rbac.create=false renders only the Job and its ServiceAccount (no dangling binding)"
}

# The default must render nothing for the support bundle.
assert_no_supportbundle_unless_asked() {
  local out=$1 profile=$2
  [ "$profile" = "supportbundle" ] && return 0
  if grep -qF '# Source: kubexa/templates/supportbundle.yaml' <<< "$out"; then
    fail "$profile: supportbundle.yaml rendered a document with supportBundle.enabled unset"
    return 0
  fi
  if grep -q 'kubexa-support-bundle' <<< "$out"; then
    fail "$profile: supportbundle.yaml rendered nothing, but something else in this render names kubexa-support-bundle"
    return 0
  fi
  ok "$profile: no supportbundle objects"
}

# The schema rejects an unknown key, and types the two duration values as
# strings and the other tuning values as integers: a quote changes the accepted
# type, and a wrong one is a render-time fatal. Renders independently of $out.
assert_supportbundle_schema_types() {
  local out=$1 profile=$2
  [ "$profile" = "default" ] || return 0
  local res
  if res=$(helm template kubexa "$CHART" -f "$PROFILES_DIR/default.yaml" --set supportBundle.enabledd=true 2>&1); then
    fail "$profile: --set supportBundle.enabledd=true rendered successfully -- the schema no longer rejects unknown supportBundle keys"
  elif grep -qF 'enabledd' <<< "$res"; then
    ok "$profile: the schema rejects an unknown supportBundle key"
  else
    fail "$profile: --set supportBundle.enabledd=true failed, but not on the key itself: ${res:0:300}"
  fi
  if res=$(helm template kubexa "$CHART" -f "$PROFILES_DIR/default.yaml" --set supportBundle.timeout=240 2>&1); then
    fail "$profile: supportBundle.timeout=240 (an integer) rendered -- the schema must type timeout as a string"
  elif grep -qF 'timeout' <<< "$res"; then
    ok "$profile: the schema types supportBundle.timeout as a string"
  else
    fail "$profile: supportBundle.timeout=240 failed, but not on the key itself: ${res:0:300}"
  fi
  if res=$(helm template kubexa "$CHART" -f "$PROFILES_DIR/default.yaml" --set-string supportBundle.tailLines=200 2>&1); then
    fail "$profile: supportBundle.tailLines=\"200\" (a string) rendered -- the schema must type tailLines as an integer"
  elif grep -qF 'tailLines' <<< "$res"; then
    ok "$profile: the schema types supportBundle.tailLines as an integer"
  else
    fail "$profile: supportBundle.tailLines=\"200\" failed, but not on the key itself: ${res:0:300}"
  fi
}

# Every OTHER profile must render no preflight at all. This is the assertion
# that would catch a dropped `enabled` gate, which would otherwise ship the
# Job into every install silently.
assert_no_preflight_unless_asked() {
  local out=$1 profile=$2
  [ "$profile" = "preflight" ] && return 0
  # Keyed on the template's own "# Source:" marker, like
  # assert_backup_absent_by_default and for the same reason: a substring match
  # on "kubexa-preflight" is blinded by a rename of the objects, while the
  # marker is the template's path and cannot be renamed out from under the
  # check. The template renders no document at all while enabled=false, so the
  # marker's absence is the whole claim.
  if grep -qF '# Source: kubexa/templates/preflight.yaml' <<< "$out"; then
    fail "$profile: preflight.yaml rendered a document with preflight.enabled=false -- the enabled gate is broken and a normal install would create the Job"
    return 0
  fi
  # A second, separate claim: no OTHER template refers to the preflight
  # objects either. The marker above cannot see that, and a stray reference
  # would mean a normal install expects objects it never creates.
  if grep -q 'kubexa-preflight' <<< "$out"; then
    fail "$profile: preflight.yaml rendered nothing, but something else in this render names kubexa-preflight"
    return 0
  fi
  ok "$profile: no preflight objects"
}

assert_backup_absent_by_default() {
  local out=$1 profile=$2
  case "$profile" in
    backup-s3|backup-filesystem) return 0 ;;
  esac
  # Keyed on the two templates' own "# Source:" markers, not a substring
  # match against object names -- "name: kubexa-backup" as a bare grep also
  # matches secretKeyRef.name values like "kubexa-backup-encryption" that a
  # profile might set even with backup.enabled=false, and a bare
  # "kind: CronJob" check would fail on any unrelated CronJob this chart
  # later grows. The source marker is unambiguous: neither template renders
  # a document at all while backup.enabled=false.
  if grep -qF '# Source: kubexa/templates/backup-cronjob.yaml' <<< "$out" \
      || grep -qF '# Source: kubexa/templates/backup-config-secret.yaml' <<< "$out"; then
    fail "$profile: backup-cronjob.yaml or backup-config-secret.yaml rendered with backup.enabled=false"
  else
    ok "$profile: no backup objects by default"
  fi
}

assert_backup_cronjob() {
  local out=$1 profile=$2
  case "$profile" in
    backup-s3|backup-filesystem) ;;
    *) return 0 ;;
  esac
  # Sliced to the CronJob's OWN document -- see extract_source's comment.
  # Without this, a grep against the whole render passes even with the
  # CronJob's name changed to anything (the config Secret's name,
  # "kubexa-backup-config", still matches "kubexa-backup"), even with
  # fsGroup deleted from this CronJob (the bundled Postgres StatefulSet
  # carries its own "fsGroup: 70"), and even with both password env blocks
  # deleted (the apiserver Deployment carries the same two env var names).
  # Proven by mutation: see task-12-report.md's fix-round-1 section.
  local doc
  doc=$(extract_source "$out" "kubexa/templates/backup-cronjob.yaml")
  if [ -z "$doc" ]; then
    fail "$profile: no backup-cronjob.yaml document found in the render"
    return
  fi
  for needle in "kind: CronJob" "KUBEXA_BACKUP_ENCRYPTION_KEY" "KUBEXA_BACKUP_ENCRYPTION_KEY_ID" "sizeLimit: 10Gi" "KUBEXA_APISERVER_POSTGRES_APP_PASSWORD" "KUBEXA_APISERVER_POSTGRES_USERS_PASSWORD" "KUBEXA_APISERVER_PLATFORM_SETTINGS_KEY" "KUBEXA_BACKUP_ENABLED" "KUBEXA_BACKUP_DATA_SCHEDULE" "KUBEXA_BACKUP_DATA_KEEP" "KUBEXA_BACKUP_DATA_TABLES"; do
    if grep -qF "$needle" <<< "$doc"; then
      ok "$profile: $needle"
    else
      fail "$profile: missing $needle"
    fi
  done
  # KUBEXA_BACKUP_ENABLED must render as the quoted string "true", not the
  # bare YAML boolean true: an unquoted boolean env value is rejected by the
  # API server, and cmd/backup/env.go parses this one back with strconv, not
  # a YAML decoder, so it must arrive as a string either way. Captured into a
  # variable (not piped into a second grep) for the same SIGPIPE-under-
  # pipefail reason documented on assert_bundled_vm above.
  local enabled_line
  enabled_line=$(grep -A1 -F 'name: KUBEXA_BACKUP_ENABLED' <<< "$doc")
  if grep -qF 'value: "true"' <<< "$enabled_line"; then
    ok "$profile: KUBEXA_BACKUP_ENABLED is quoted"
  else
    fail "$profile: KUBEXA_BACKUP_ENABLED did not render as a quoted string -- got: $enabled_line"
  fi
  # Anchored exact match on the object's own metadata.name line, not a bare
  # substring: "name: kubexa-backup" ALSO matches the secretKeyRef.name refs
  # this profile's own fixtures point at ("kubexa-backup-encryption",
  # "kubexa-backup-s3-credentials"), so a substring check here stayed green
  # even with the CronJob's metadata.name renamed to something-else --
  # caught by mutation testing, see task-12-report.md's fix-round-1 section.
  if grep -qE '^  name: kubexa-backup$' <<< "$doc"; then
    ok "$profile: name: kubexa-backup"
  else
    fail "$profile: missing exact metadata.name kubexa-backup"
  fi
  # fsGroup: 70 is a controller ruling, not optional: the image's /work
  # directory is owned by uid 70, but any volume mounted over it (this
  # CronJob's emptyDir) arrives root-owned, and without fsGroup: 70 the uid-70
  # process cannot write its dump staging area.
  grep -qF 'fsGroup: 70' <<< "$doc" \
    && ok "$profile: fsGroup: 70" \
    || fail "$profile: missing fsGroup: 70"
  # No password may ever appear as a plain env value -- only via
  # secretKeyRef. A literal password value inlined in a ConfigMap/env would be
  # readable by anyone who can `kubectl get cronjob -o yaml`.
  if grep -qF 'valueFrom:' <<< "$doc" && grep -qF 'secretKeyRef:' <<< "$doc"; then
    ok "$profile: passwords via secretKeyRef"
  else
    fail "$profile: expected secretKeyRef-backed password env vars"
  fi
  if [ "$profile" = "backup-s3" ]; then
    grep -qF 'KUBEXA_BACKUP_S3_BUCKET' <<< "$doc" \
      && ok "$profile: KUBEXA_BACKUP_S3_BUCKET" \
      || fail "$profile: missing KUBEXA_BACKUP_S3_BUCKET"
    grep -qF 'KUBEXA_BACKUP_FS_PATH' <<< "$doc" \
      && fail "$profile: s3 driver should not carry KUBEXA_BACKUP_FS_PATH" \
      || ok "$profile: no filesystem env var on the s3 driver"
  fi
  if [ "$profile" = "backup-filesystem" ]; then
    grep -qF 'claimName: kubexa-backup-pvc' <<< "$doc" \
      && ok "$profile: claimName: kubexa-backup-pvc" \
      || fail "$profile: missing claimName: kubexa-backup-pvc"
    grep -qF 'KUBEXA_BACKUP_S3_BUCKET' <<< "$doc" \
      && fail "$profile: filesystem driver should not carry S3 env vars" \
      || ok "$profile: no S3 env vars on the filesystem driver"
  fi
}

# The apiserver pod must read the platform settings key from the SAME Secret
# the backup CronJob reads: the process that seals a row and the job that
# must unseal it cannot disagree on the key. Until apiserver chart 0.4.55
# the umbrella's apiserver.secrets.platformKeySecret fed only the CronJob and
# the apiserver pod had no key at all -- every secret field on /platform
# failed on every install, backup or not. Scoped to the apiserver
# Deployment's own document (extract_source), because the CronJob document
# carries the identical env name and would satisfy a whole-render grep.
#
# The block itself is carved with awk, not a fixed `grep -A5` window: the
# rendered secretKeyRef carries comment lines above it, so a fixed window is
# fragile, and a plain window can't tell which container's env list the
# match landed in. Scoped to the "apiserver" container's own env list and
# cut at the next env entry.
assert_platform_key_reaches_apiserver() {
  local out=$1 profile=$2
  [ "$profile" = "backup-s3" ] || return 0
  local doc
  doc=$(extract_source "$out" "kubexa/charts/apiserver/templates/deployment.yaml")
  if [ -z "$doc" ]; then
    fail "$profile: no apiserver deployment.yaml document found in the render"
    return
  fi
  local block
  block=$(awk '
    /^        - name: apiserver$/ { c = 1 }
    c && /name: KUBEXA_APISERVER_PLATFORM_SETTINGS_KEY/ { p = 1; print; next }
    p && /^            - name: / { exit }
    p { print }
  ' <<< "$doc")
  if [ -z "$block" ]; then
    fail "$profile: the apiserver Deployment renders no KUBEXA_APISERVER_PLATFORM_SETTINGS_KEY -- apiserver chart < 0.4.55?"
    return
  fi
  grep -qF 'name: kubexa-platform-settings-key' <<< "$block" \
    || { fail "$profile: apiserver reads the platform key from somewhere other than apiserver.secrets.platformKeySecret.name"; return; }
  grep -qF 'optional: true' <<< "$block" \
    && { fail "$profile: a referenced platform key Secret was rendered optional on the apiserver"; return; }
  ok "$profile: platform key reaches the apiserver Deployment by reference"
}

assert_backup_config_secret() {
  local out=$1 profile=$2
  case "$profile" in
    backup-s3|backup-filesystem) ;;
    *) return 0 ;;
  esac
  # Sliced to the config Secret's OWN document for the same reason as
  # assert_backup_cronjob above -- and specifically proves Critical 1's fix:
  # the apiserver's own rendered config Secret ALSO carries "ssl_mode:" and
  # "username:" for its own Postgres upstreams, so an unscoped grep against
  # the whole render would stay green even if this Secret's template
  # regressed back to `toYaml`'ing the values-shape (camelCase) keys.
  local doc
  doc=$(extract_source "$out" "kubexa/templates/backup-config-secret.yaml")
  if [ -z "$doc" ]; then
    fail "$profile: no backup-config-secret.yaml document found in the render"
    return
  fi
  grep -qF 'name: kubexa-backup-config' <<< "$doc" \
    || { fail "$profile: backup-config-secret.yaml did not render kubexa-backup-config"; return; }
  for needle in "username:" "ssl_mode:" "max_conns:" "min_conns:"; do
    grep -qF "$needle" <<< "$doc" \
      && ok "$profile: config secret carries $needle" \
      || fail "$profile: config secret missing $needle -- config.Load() reads snake_case keys, not the values-shape ones"
  done
  # "user:" (the values-shape key toYaml would have emitted) must NOT appear
  # as its own YAML key -- "username:" contains the substring "user" but
  # never "user:" immediately followed by a colon, so a match here can only
  # be a regression back to the camelCase dump. Comment lines (the template's
  # own explanation of this exact trap, which necessarily quotes "user")
  # are excluded first so the check inspects rendered YAML, not prose.
  local doc_no_comments
  doc_no_comments=$(grep -v '^\s*#' <<< "$doc" || true)
  if grep -qF 'user:' <<< "$doc_no_comments"; then
    fail "$profile: config secret carries a bare \"user:\" key -- config.Load() silently drops it and Username stays empty"
  else
    ok "$profile: no bare \"user:\" key"
  fi
}

assert_bundled_vm() {
  local out=$1 profile=$2
  [ "$profile" = "default" ] || return 0
  # Herestrings, not `echo "$out" | grep -q ...`: with a render this size
  # (~66KB, past a single pipe buffer) a `-q` match early in the stream lets
  # grep close its end of the pipe before echo finishes writing, and under
  # `set -o pipefail` the SIGPIPE echo takes fails the whole pipeline even
  # though grep matched -- reproduced empirically as an intermittent FAIL on
  # this exact assertion (kubexa-victoriametrics renders near the top of the
  # manifest, so this was not theoretical).
  #
  # Anchored on an object NAME ("name: kubexa-victoriametrics" at end of
  # line), not a bare substring, for the same reason assert_bundled_loki is:
  # apiserver.config.upstreams.victoriametrics.url and
  # consumer.config.victoriaMetrics.url both render "kubexa-victoriametrics"
  # too (inside "http://kubexa-victoriametrics:8428"), so a plain
  # `grep -q 'kubexa-victoriametrics'` stays green even with
  # victoriaMetrics.server.fullnameOverride moved back to the top-level
  # victoriaMetrics.fullnameOverride -- which renders every VM object as
  # "kubexa-victoriametrics-server" while the URL literals still say
  # "kubexa-victoriametrics" -- measured against the real render, the exact
  # regression an earlier task already had to fix once. Every object this
  # subchart's server.fullnameOverride produces (ServiceAccount, Service,
  # StatefulSet) is named exactly "kubexa-victoriametrics" with nothing after
  # it on that line; the URL literal is never at end-of-line
  # ("...kubexa-victoriametrics:8428"" always follows), so the anchor
  # excludes it by construction.
  grep -q 'name: kubexa-victoriametrics$' <<< "$out" \
    || { fail "$profile: no VictoriaMetrics objects rendered"; return; }
  grep -q 'url: "http://kubexa-victoriametrics:8428"' <<< "$out" \
    || { fail "$profile: nothing points at the bundled VictoriaMetrics"; return; }
  # Scrape off: the flag creates cluster-scoped RBAC, deliberately not wanted
  # here. If this ever fails, read the reasoning in values.yaml before
  # changing the assertion.
  #
  # A plain grep for 'kind: ClusterRoleBinding' plus a separate 'victoria'
  # match is not a check of this: once ANY VictoriaMetrics object renders,
  # the word "victoria" appears somewhere in the manifest regardless of
  # scrape, so the two greps trip on any other subchart's cluster-scoped RBAC
  # -- present now or added later (e.g. a future Loki bundle). Instead,
  # require a ClusterRole/ClusterRoleBinding whose own metadata.name
  # identifies it as VictoriaMetrics's.
  if grep -E '^(kind: Cluster(Role|RoleBinding))$' -A5 <<< "$out" | grep -qi 'name:.*victoria'; then
    fail "$profile: VictoriaMetrics rendered cluster-scoped RBAC -- scrape should be off"
  fi
  ok "$profile: bundled victoriametrics"
}

assert_bundled_loki() {
  local out=$1 profile=$2
  [ "$profile" = "default" ] || return 0
  # Anchored on an object NAME ("name: kubexa-loki" at end of line), not a
  # bare substring: apiserver.config.upstreams.loki.url and
  # consumer.config.loki.url both render "kubexa-loki" too (inside
  # "http://kubexa-loki:3100"), so a plain `grep -q 'kubexa-loki'` stays
  # green even with loki.enabled=false and zero Loki objects rendered --
  # measured against the real render, the exact condition this check exists
  # to catch. Every object this subchart's fullnameOverride+nameOverride
  # pair produces (ServiceAccount, ConfigMap, Service, StatefulSet) is named
  # exactly "kubexa-loki" with nothing after it on that line; the URL
  # literal is never at end-of-line ("...kubexa-loki:3100"" always follows),
  # so the anchor excludes it by construction.
  grep -q 'name: kubexa-loki$' <<< "$out" \
    || { fail "$profile: no Loki objects rendered"; return; }
  grep -q 'http://kubexa-loki:3100' <<< "$out" \
    || { fail "$profile: nothing points at the bundled Loki"; return; }
  grep -q 'auth_enabled: true' <<< "$out" \
    || { fail "$profile: Loki rendered with auth_enabled off -- every tenant would read every other tenant's logs"; return; }
  grep -q 'retention_enabled: true' <<< "$out" \
    || { fail "$profile: Loki retention is off; nothing would ever be deleted"; return; }
  ok "$profile: bundled loki"
}

assert_consumer_users_db_present_with_loki() {
  local out=$1 profile=$2
  # Cross-store invariant, checked on every profile: the consumer refuses to
  # start with a loki url and no usersDb, and the failure is a Validate()
  # error in a log nobody reads until logs stop arriving.
  #
  # The consumer renders its config through a Go struct with yaml tags, same
  # as the postgres wiring check above: go-yaml quotes every plain string
  # scalar, so the rendered manifest carries
  #   url: "http://kubexa-loki:3100"
  #   database: "kubexa_users"
  # not the unquoted spelling values.yaml itself uses. A pattern without the
  # quotes never matches and this assertion would pass for the wrong reason
  # -- silently, forever, on every profile.
  if grep -q 'url: "http://kubexa-loki:3100"' <<< "$out"; then
    grep -q 'database: "kubexa_users"' <<< "$out" \
      || fail "$profile: consumer has a Loki url but no usersDb -- Validate() refuses that combination"
  fi
  ok "$profile: loki/usersDb pairing"
}

assert_notes_report_the_stores() {
  local out=$1 profile=$2
  [ "$profile" = "default" ] || return 0
  # NOTES.txt is not part of `helm template` output; render it separately.
  # `--show-only templates/NOTES.txt` does not work on every Helm version --
  # NOTES is rendered into the install output, not the manifest, and on the
  # pinned Helm (v4.2.2) it errors: "could not find template
  # templates/NOTES.txt in chart". `helm install --dry-run` renders client-
  # side (no cluster write, confirmed against an unreachable KUBECONFIG) and
  # prints a trailing "NOTES:" section identical to what `helm install` for
  # real would show; pull that section out instead.
  local install_out notes components
  install_out=$(helm install kubexa "$CHART" -f "$PROFILES_DIR/$profile.yaml" --dry-run 2>&1) || true
  notes=$(awk '/^NOTES:$/{flag=1; next} flag' <<< "$install_out")
  # Anchored to the Components: block itself, not the whole NOTES body: the
  # unconditional "Next steps" paragraph further down hardcodes the literal
  # prose "...landing in Postgres/Loki/VictoriaMetrics for the cluster you
  # connected", so a bare `grep -qi "$store"` against the full NOTES text
  # stays green even with the three Components lines below deleted outright
  # -- proven empirically (see task-8-report.md's fix section) and NOT a
  # hypothetical: that was this assertion's original, broken form. Extract
  # just the block between "Components:" and the first line that is not a
  # component entry, and match the literal rendered line prefix there
  # instead, so the check can only pass because the Components list itself
  # names the store.
  #
  # Stop on the first non-component CONTENT line, not the first blank line:
  # the WARNING paragraphs below the block are separated from it by a blank
  # line today, but a blank line landing INSIDE the block for any reason
  # (a future component added above the last one, a template edit) would
  # truncate extraction right there under the old "reset on blank" rule and
  # fail every prefix below it that still rendered fine -- a false failure,
  # not a real one. So blank lines are skipped, not treated as the
  # terminator; only a non-blank line that isn't shaped like "  <word>:" (a
  # WARNING: paragraph, "Next steps", ...) ends the block.
  components=$(awk '
    /^Components:$/ { flag=1; next }
    flag {
      if ($0 == "") next
      if ($0 !~ /^  [a-zA-Z]+:/) exit
      print
    }
  ' <<< "$notes")
  # Requires a POPULATED value, not just a non-empty one: "disabled" is
  # itself valid content, but VM's own line has rendered
  # "enabled (:8428, retention 30d)" for real -- an empty host substituted
  # ahead of the port -- with something present right after the prefix
  # ("enabled") the whole time, so a bare "non-empty after the prefix" check
  # stays green on exactly the bug this exists to catch. Require either the
  # literal "disabled", or "enabled (<non-empty-token>:" -- the hostname
  # field before the first ":" inside the parens must itself be non-empty.
  for prefix in "postgres:" "victoria:" "loki:"; do
    grep -Eq "^  ${prefix}[[:space:]]+(disabled|enabled \([^:()]+:)" <<< "$components" \
      || fail "$profile: NOTES.txt Components: block does not report a populated value for \"$prefix\""
  done
  ok "$profile: NOTES report the stores"
}

# half-thrown* profiles are each ONE store disabled with every pointer left
# behind, so they must FAIL to render -- the failure and its message are the
# assertion, not a successful render. Helm stops at the first `fail`, so each
# profile is built to trip exactly one guard. half_thrown_needle maps the
# profile name to the needle its guard message must contain.
#
# A `case`, not an associative array: `declare -A` requires bash 4, and
# /bin/bash on macOS -- what `#!/usr/bin/env bash` resolves to on any machine
# where Homebrew's bash is not first on PATH -- is 3.2. There `declare -A`
# is not recognised, `[half-thrown]=...` is then parsed as an indexed-array
# arithmetic subscript ("half - thrown"), and under `set -u` the script
# aborts immediately with "half: unbound variable" before a single profile
# runs. This harness exists to run locally without a CI runner, so it must
# work on the platform's own shell.
half_thrown_needle() {
  case "$1" in
    half-thrown)      echo "apiserver.config.upstreams.postgres.{app,users}.host is still" ;;
    half-thrown-vm)   echo "consumer.config.victoriaMetrics.url is still" ;;
    half-thrown-loki) echo "consumer.config.loki.url is still" ;;

    # Every remaining profile is built to trip ONE specific arm inside a
    # guard family that has more than one -- earlier arms in the same family
    # are deliberately defused by the profile's own overrides (see each
    # profile's comment), so the needle below is the exact fragment that
    # arm's own message carries, not just the family's shared prefix, so a
    # DIFFERENT arm in the same family firing instead is caught as a
    # mismatch rather than read as a pass.
    half-thrown-valkey)                    echo "apiserver.secrets.redisPasswordSecret.name is still" ;;
    half-thrown-valkey-addrs)              echo "apiserver.config.upstreams.redis.addrs still contains" ;;
    half-thrown-nats)                      echo "agentserver.config.nats.url is still" ;;
    half-thrown-nats-consumer)             echo "consumer.config.nats.url is still" ;;
    half-thrown-nats-agentserver-secret)   echo "agentserver.secrets.natsPasswordSecret.name is still" ;;
    half-thrown-nats-consumer-secret)      echo "consumer.secrets.natsPasswordSecret.name is still" ;;
    half-thrown-postgres-secret)           echo "apiserver.secrets.postgres{App,Users}PasswordSecret.name is still" ;;
    half-thrown-postgres-consumer-host)    echo "consumer.config.{postgres,usersDb}.host is still" ;;
    half-thrown-postgres-consumer-secret)  echo "consumer.secrets.{postgresPasswordSecret,usersDbPasswordSecret}.name is still" ;;
    half-thrown-postgres-sslmode-apiserver) echo "apiserver.config.upstreams.postgres.{app,users}.sslMode is still" ;;
    half-thrown-postgres-sslmode-consumer)  echo "consumer.config.{postgres,usersDb}.sslMode is still" ;;
    half-thrown-vm-apiserver)              echo "apiserver.config.upstreams.victoriametrics.url is still" ;;
    half-thrown-loki-apiserver)            echo "apiserver.config.upstreams.loki.url is still" ;;
    half-thrown-postgres-split-app)        echo "differs from consumer.config.postgres.host" ;;
    half-thrown-postgres-split-users)      echo "differs from consumer.config.usersDb.host" ;;
    half-thrown-backup-encryption)         echo "backup.enabled=true requires backup.encryption.existingSecret.name" ;;
    half-thrown-backup-vm-url)             echo "backup.enabled=true requires backup.victoriaMetrics.url" ;;
    half-thrown-backup-platform-key)       echo "backup.enabled=true requires apiserver.secrets.platformKeySecret.name" ;;
    half-thrown-backup-key-id)             echo "backup.enabled=true does not allow apiserver.config.platform.settingsKeyId" ;;
    half-thrown-vm-backup)                 echo "backup.victoriaMetrics.url is still" ;;
    half-thrown-backup-s3-bucket)          echo "backup.destination.driver=s3 requires backup.destination.s3.bucket" ;;
    half-thrown-backup-filesystem-claim)   echo "backup.destination.driver=filesystem requires backup.destination.filesystem.existingClaim" ;;
    half-thrown-backup-driver)             echo "is not supported; use s3 or filesystem" ;;
    *)                echo "" ;;
  esac
}

# ── driver ──────────────────────────────────────────────────────────────────
profiles=("$@")
if [ ${#profiles[@]} -eq 0 ]; then
  for f in "$PROFILES_DIR"/*.yaml; do profiles+=("$(basename "$f" .yaml)"); done
fi

for profile in "${profiles[@]}"; do
  echo "profile: $profile"
  needle="$(half_thrown_needle "$profile")"
  if ! out=$(render_profile "$profile"); then
    if [ -n "$needle" ]; then
      # This profile is SUPPOSED to fail. Assert the guard that fired.
      grep -q "$needle" <<<"$out" || fail "$profile: no guard mentioned $needle"
      ok "$profile: guard fired"
      continue
    fi
    fail "$profile: helm template failed"
    echo "$out" >&2
    continue
  fi
  if [ -n "$needle" ]; then
    fail "$profile: rendered successfully -- a guard is missing"
    continue
  fi
  for assertion in $(declare -F | awk '{print $3}' | grep '^assert_'); do
    "$assertion" "$out" "$profile"
  done
done

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)" >&2
  exit 1
fi
echo "all profiles clean"
