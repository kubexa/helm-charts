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
  grep -q 'kubexa-victoriametrics' <<< "$out" \
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

# half-thrown* profiles are each ONE store disabled with every pointer left
# behind, so they must FAIL to render -- the failure and its message are the
# assertion, not a successful render. Helm stops at the first `fail`, so each
# profile is built to trip exactly one guard; map the profile name to the
# needle its guard message must contain.
declare -A HALF_THROWN_NEEDLE=(
  [half-thrown]="postgres.enabled=false"
  [half-thrown-vm]="victoriaMetrics.enabled=false"
  [half-thrown-loki]="loki.enabled=false"
)

# ── driver ──────────────────────────────────────────────────────────────────
profiles=("$@")
if [ ${#profiles[@]} -eq 0 ]; then
  for f in "$PROFILES_DIR"/*.yaml; do profiles+=("$(basename "$f" .yaml)"); done
fi

for profile in "${profiles[@]}"; do
  echo "profile: $profile"
  needle="${HALF_THROWN_NEEDLE[$profile]:-}"
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
