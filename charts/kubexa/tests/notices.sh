#!/usr/bin/env bash
# Asserts that THIRD-PARTY-CHARTS.md still describes the chart archives this
# package actually redistributes. Run from anywhere:
#
#   charts/kubexa/tests/notices.sh
#
# Requires the chart's dependencies to be resolved -- run
# `helm dependency update charts/kubexa` first. An unresolved charts/ is a
# FAILURE here, never a pass: the whole point is that this check cannot be
# satisfied by having nothing to check.
#
# Why this exists. `helm package` puts every resolved dependency INSIDE the
# published kubexa-<ver>.tgz, so installing from oci://ghcr.io/kubexa/charts
# hands the operator the loki, nats and VictoriaMetrics charts as well as
# ours. That is redistribution, and none of those archives carries a licence
# file of its own (measured 2026-11-21: zero licence/notice files in all four
# third-party tarballs), so the copy the licences require has to come from
# this package. Apache-2.0 section 4(a) and AGPL-3.0 section 4 both say a
# copy of the licence travels with the thing.
#
# The failure this guards against is not a wrong sentence, it is a silent
# one: `helm dependency update` after a Chart.yaml edit changes what ships
# without touching a single line of prose.
#
# bash 3.2 compatible (no associative arrays): same reason tests/render.sh
# gives -- this harness has to run on macOS's own /bin/bash.
set -euo pipefail
cd "$(dirname "$0")/../../.."
CHART=charts/kubexa
DOC=$CHART/THIRD-PARTY-CHARTS.md
CHARTS_DIR=$CHART/charts
FAILURES=0

fail() { echo "  FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "  ok: $*"; }

[ -f "$DOC" ] || { echo "$DOC does not exist" >&2; exit 1; }

# Every chart unit that travels in the package, one "name<TAB>version" per
# line: the dependency archives themselves plus every subchart vendored
# inside them (loki carries minio, grafana-agent-operator and
# rollout-operator; each VictoriaMetrics chart carries
# victoria-metrics-common; rollout-operator carries a crds chart). A
# condition that leaves a subchart's objects out of the render does not keep
# its FILES out of the tarball, so "disabled by default" is not a reason to
# leave one out of the notices.
bundled() {
  local tgz name version
  shopt -s nullglob
  for tgz in "$CHARTS_DIR"/*.tgz; do
    # Every Chart.yaml in the archive, at any depth. `tar -O` concatenates
    # them, so read each one separately by path.
    for path in $(tar tzf "$tgz" | grep -E '(^|/)Chart\.yaml$' | sort); do
      # Column 0 only, and the FIRST such line. A `name:`/`version:` scan
      # that ignores indentation reads the wrong fields and did, on the
      # first run of this script: `    name: MinIO, Inc.` under
      # maintainers made the minio chart "MinIO, 5.4.0", nats became "The"
      # (The NATS Authors), and each VictoriaMetrics chart took the
      # version "0.3.*" off its own dependency on victoria-metrics-common.
      # Those are the archive's top-level keys or nothing.
      meta=$(tar xzOf "$tgz" "$path")
      name=$(grep -m1 '^name:' <<< "$meta" | awk '{print $2}')
      version=$(grep -m1 '^version:' <<< "$meta" | awk '{gsub(/"/,"",$2); print $2}')
      [ -n "$name" ] && [ -n "$version" ] && printf '%s\t%s\n' "$name" "$version"
    done
  done
  shopt -u nullglob
}

units=$(bundled | sort -u)
if [ -z "$units" ]; then
  echo "$CHARTS_DIR holds no chart archives -- run: helm dependency update $CHART" >&2
  exit 1
fi

# Our own charts are covered by this repository's LICENSE and EULA.md, not by
# a third-party notice. Anything else has to be named in the document.
third_party=$(awk -F'\t' '$1 !~ /^kubexa-/' <<< "$units")
if [ -z "$third_party" ]; then
  echo "no third-party charts found among: $(tr '\t' ' ' <<< "$units" | tr '\n' ' ')" >&2
  exit 1
fi

needle_for() {
  case "$1" in
    Apache-2.0)    echo "Apache License" ;;
    AGPL-3.0-only) echo "GNU AFFERO GENERAL PUBLIC LICENSE" ;;
    *)             echo "" ;;
  esac
}

# The full text of one licence, as the document reproduces it: everything
# between "## Full text: <id>" and the next "## " heading.
full_text() {
  awk -v want="## Full text: $1" '
    $0 == want { grab=1; next }
    grab && /^## / { exit }
    grab { print }
  ' "$DOC"
}

declared_ids=""

while IFS=$'\t' read -r name version; do
  [ -n "$name" ] || continue
  heading="### $name $version"
  if ! grep -qxF "$heading" "$DOC"; then
    fail "$name $version ships in the package but $DOC has no \"$heading\" section"
    continue
  fi
  # The licence id this section declares, read from that section alone.
  id=$(awk -v want="$heading" '
    $0 == want { grab=1; next }
    grab && /^### / { exit }
    grab && $1 == "*" && $2 == "SPDX-License-Identifier:" { print $3; exit }
  ' "$DOC")
  if [ -z "$id" ]; then
    fail "$name $version: its section declares no SPDX-License-Identifier"
    continue
  fi
  declared_ids="$declared_ids $id"
  needle=$(needle_for "$id")
  if [ -z "$needle" ]; then
    fail "$name $version declares $id, which this check has no needle for -- add one"
    continue
  fi
  text=$(full_text "$id")
  lines=$(wc -l <<< "$text" | tr -d ' ')
  if ! grep -qF "$needle" <<< "$text"; then
    fail "$name $version declares $id, but no \"## Full text: $id\" section reproduces it"
  elif [ "$lines" -lt 150 ]; then
    fail "$id full text is only $lines lines -- a summary is not a copy of the licence"
  else
    ok "$name $version -> $id ($lines lines reproduced)"
  fi
done <<< "$third_party"

# The other direction: a section for a chart that is no longer bundled. A
# stale notice is read and believed, so it fails here too.
while read -r heading; do
  name=$(awk '{print $2}' <<< "$heading")
  version=$(awk '{print $3}' <<< "$heading")
  grep -qxF "$(printf '%s\t%s' "$name" "$version")" <<< "$units" \
    || fail "$DOC describes $name $version, which this package no longer ships"
done < <(grep -E '^### [^ ]+ [^ ]+$' "$DOC")

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)" >&2
  exit 1
fi
echo "third-party chart notices complete"
