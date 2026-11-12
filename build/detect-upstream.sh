#!/usr/bin/env bash
# Prints the newest maintained OpenStack series that has a Trove stable
# branch (e.g. 2026.2), from `git ls-remote` on opendev.org/openstack/trove.
# VERSION follows the OpenStack series: a new stable/YYYY.N branch on Trove
# means a new release to publish. Building it first needs pinned trove and
# requirements commits for that series in build/dib-build.sh.
# Runs in the upstream-watch reusable workflow: keep it to bash + git + sort.

set -euo pipefail

REPO='https://opendev.org/openstack/trove.git'

refs=$(git ls-remote --heads "$REPO" 'stable/*') || {
  echo "::error::could not list branches of $REPO" >&2
  exit 1
}

latest=$(printf '%s\n' "$refs" \
  | sed -nE 's#^[0-9a-f]+\s+refs/heads/stable/([0-9]{4}\.[0-9]+)$#\1#p' \
  | sort -V \
  | tail -n1)

if [[ -z "$latest" ]]; then
  echo "::error::no stable/YYYY.N branch found on $REPO" >&2
  exit 1
fi

printf '%s\n' "$latest"
