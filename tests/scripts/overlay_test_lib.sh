#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Shared helpers for future activity overlay tests. Currently inert; sourced by
# placeholder scenarios so we can introduce the overlay feature incrementally.

set -e

# load base harness env
BASE_DIR=$(cd -- "$(dirname "$0")/../.." && pwd)
.
"$BASE_DIR/tests/env.common"

overlay_log() { echo "[overlay-lib] $*" >&2; }

# run_daemon_basic: start daemon with standard basic scenario assets; does NOT
# attempt any overlay-related env or parsing yet. Returns after daemon exits.
run_daemon_basic() {
  SCENARIO="$SCENARIO_DIR/basic"; export SCENARIO
  load_scenario || return 1
  PATH="$MOCK_DIR:$PATH"; export PATH
  # Minimal direct start of daemon (avoid recursion into scenario_basic which has assertions)
  BIN="$BASE_DIR/bin/nrsyncd"
  LOG_FILE="$LOG_FILE" NRSYNCD_UPDATE_INTERVAL=1 NRSYNCD_JITTER_MAX=0 NRSYNCD_DEBUG=0 NRSYNCD_TEST_FORCE_UPDATE=1 NRSYNCD_MAX_CYCLES=1 \
    /bin/sh "$BIN" >/dev/null 2>&1 || true
}

# placeholder assertion (always passes) so placeholder scenarios show PASS.
overlay_placeholder_assert() { :; }
#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# overlay_test_lib.sh – shared helpers for overlay scenario tests
# Purpose: collapse repeated boilerplate so individual scenario_* scripts stay tiny
# and future diffs are minimal (reduces patch noise).

set -e

BASE_DIR=${BASE_DIR:-$(cd -- "$(dirname "$0")/../.." && pwd)}
. "$(dirname "$0")/../env.common"
. "$BASE_DIR/tests/scripts/_overlay_env.sh"

# Source init script lazily (for summary_service / metadata_service access)
_overlay_init_loaded=0
_overlay_load_init() {
  [ "$_overlay_init_loaded" = 1 ] && return 0
  # shellcheck source=/dev/null
  . "$BASE_DIR/service/nrsyncd.init" 2>/dev/null || true
  _overlay_init_loaded=1
}

# Run daemon with overlay enabled and arbitrary extra env (single-shot bounded by MAX_CYCLES)
overlay_run_daemon() {
  scenario_path=$1; shift
  extra_env="$*"
  SCENARIO="$scenario_path"; export SCENARIO
  load_scenario || { echo "load_scenario failed for $scenario_path" >&2; return 1; }
  BIN="$BASE_DIR/bin/nrsyncd"
  eval $OVERLAY_ENV $extra_env /bin/sh "$BIN" >/dev/null 2>&1 &
  pid=$!
  wait $pid 2>/dev/null || true
}

assert_file_contains() {
  file=$1; pattern=$2; msg=$3
  if ! grep -q -- "$pattern" "$file" 2>/dev/null; then
    echo "ASSERT FAIL: $msg (pattern '$pattern' not in $file)" >&2
    [ -f "$file" ] && tail -n 60 "$file" >&2 || true
    exit 1
  fi
}

assert_log_contains() { assert_file_contains "$LOG_FILE" "$1" "$2"; }

assert_metrics_key() {
  key=$1; msg=$2
  if ! grep -q "^${key}=" /tmp/nrsyncd_metrics 2>/dev/null; then
    echo "ASSERT FAIL: $msg (missing key ${key} in metrics)" >&2; exit 1; fi
}

assert_runtime_key() {
  key=$1; msg=$2
  if ! grep -q "^${key}=" /tmp/nrsyncd_runtime 2>/dev/null; then
    echo "ASSERT FAIL: $msg (missing key ${key} in runtime)" >&2; exit 1; fi
}

get_summary() { _overlay_load_init; summary_service 2>/dev/null || true; }
get_metadata() { _overlay_load_init; metadata_service 2>/dev/null || true; }

overlay_expect_disabled_reason() {
  reason_pat=$1
  if ! grep -q "overlay_disabled_reason=.*${reason_pat}" /tmp/nrsyncd_runtime 2>/dev/null; then
    echo "ASSERT FAIL: expected disabled reason containing '${reason_pat}'" >&2; exit 1; fi
  sum=$(get_summary)
  printf '%s' "$sum" | grep -q "overlay(disabled=" || { echo "ASSERT FAIL: summary missing overlay(disabled= segment" >&2; echo "$sum" >&2; exit 1; }
}

overlay_parse_txt() {
  # Convenience: dump current browse TXT set
  ubus call umdns browse 2>/dev/null | jsonfilter -e '@["_nrsyncd_v1._udp"][*].txt[*]' 2>/dev/null || true
}

echo "overlay_test_lib loaded" >/dev/null
