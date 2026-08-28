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
  for needle in "kind: CronJob" "KUBEXA_BACKUP_ENCRYPTION_KEY" "KUBEXA_BACKUP_ENCRYPTION_KEY_ID" "sizeLimit: 10Gi" "KUBEXA_APISERVER_POSTGRES_APP_PASSWORD" "KUBEXA_APISERVER_POSTGRES_USERS_PASSWORD"; do
    if grep -qF "$needle" <<< "$doc"; then
      ok "$profile: $needle"
    else
      fail "$profile: missing $needle"
    fi
  done
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
