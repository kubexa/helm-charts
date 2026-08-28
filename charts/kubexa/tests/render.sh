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
  if echo "$out" | kubeconform -strict -ignore-missing-schemas -summary >/dev/null 2>&1; then
    ok "$profile: kubeconform"
  else
    fail "$profile: kubeconform rejected the render"
    echo "$out" | kubeconform -strict -ignore-missing-schemas -summary || true
  fi
}

assert_no_empty_documents() {
  local out=$1 profile=$2
  # A template whose whole body is inside an {{- if }} that is false renders
  # as a bare "---" with nothing after it. Harmless to kubectl, but it means
  # a guard fired that the profile did not intend.
  if echo "$out" | awk '
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
  '; then
    fail "$profile: an empty document was rendered"
  else
    ok "$profile: no empty documents"
  fi
}

assert_bundled_postgres() {
  local out=$1 profile=$2
  [ "$profile" = "default" ] || return 0
  echo "$out" | grep -q 'name: kubexa-postgres$' \
    || { fail "$profile: no kubexa-postgres Service/StatefulSet rendered"; return; }
  echo "$out" | grep -q 'name: kubexa-postgres-auth' \
    || { fail "$profile: no kubexa-postgres-auth Secret rendered"; return; }
  echo "$out" | grep -q 'CREATE DATABASE kubexa_app' \
    || { fail "$profile: the init script does not create kubexa_app"; return; }
  echo "$out" | grep -q 'CREATE DATABASE kubexa_users' \
    || { fail "$profile: the init script does not create kubexa_users"; return; }
  ok "$profile: bundled postgres"
}

assert_postgres_absent_when_disabled() {
  local out=$1 profile=$2
  [ "$profile" = "external-stores" ] || return 0
  if echo "$out" | grep -q 'kubexa-postgres'; then
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
  [ "$(echo "$out" | grep -c 'host: "kubexa-postgres"')" -ge 4 ] \
    || { fail "$profile: expected >=4 postgres hosts (apiserver app+users, consumer postgres+usersDb), got $(echo "$out" | grep -c 'host: "kubexa-postgres"')"; return; }
  echo "$out" | grep -q 'name: kubexa-postgres-auth' \
    || { fail "$profile: nothing references the kubexa-postgres-auth Secret"; return; }
  echo "$out" | grep -q 'ssl_mode: "disable"' \
    || { fail "$profile: the bundled Postgres carries no TLS; ssl_mode must be disable"; return; }
  ok "$profile: postgres wiring"
}

# ── driver ──────────────────────────────────────────────────────────────────
profiles=("$@")
if [ ${#profiles[@]} -eq 0 ]; then
  for f in "$PROFILES_DIR"/*.yaml; do profiles+=("$(basename "$f" .yaml)"); done
fi

for profile in "${profiles[@]}"; do
  echo "profile: $profile"
  if ! out=$(render_profile "$profile"); then
    fail "$profile: helm template failed"
    echo "$out" >&2
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
