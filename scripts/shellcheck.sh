#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Run shellcheck on project shell scripts (if available).
# Usage: scripts/shellcheck.sh [--fix]
# Requires: shellcheck in PATH. Safe to run locally; CI optional.

set -eu

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

# Collect scripts (exclude binary dir contents except scripts)
SCRIPTS="service/nrsyncd.init bin/nrsyncd lib/nrsyncd_common.sh tests/mocks/ubus tests/mocks/uci tests/scripts/scenario_basic.sh tests/scripts/scenario_skip.sh tests/scripts/scenario_reload.sh tests/run-tests.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found in PATH; skipping lint." >&2
  exit 0
fi

FAIL=0
for f in $SCRIPTS; do
  [ -f "$f" ] || continue
  # SC1090 dynamic sourced files are intentional in tests; disable.
  # Suppress non-actionable infos and a couple of benign warnings in tests/binaries:
  #  - SC1091: "Not following" includes OpenWrt rc.common and test env files
  #  - SC2034: some test vars are intentionally exported/unused
  #  - SC2329: prebuilt daemon stubs show as unused in static analysis
  # Also raise minimum severity to 'warning' to ignore style-only infos.
  if [ $FIX -eq 1 ]; then
    shellcheck -S warning -x -e SC1090 -e SC1091 -e SC2034 -e SC2329 "$f" || FAIL=1
  else
    shellcheck -S warning -x -e SC1090 -e SC1091 -e SC2034 -e SC2329 "$f" || FAIL=1
  fi
done

if [ $FAIL -ne 0 ]; then
  echo "Shellcheck reported issues." >&2
  exit 1
fi

echo "Shellcheck: PASS"
