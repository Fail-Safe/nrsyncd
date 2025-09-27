#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e
# Scenario: inactivity classification + counts
. "$(dirname "$0")/overlay_test_lib.sh"
rm -f "$STATE_DIR/nrsyncd_set.log" "$STATE_DIR"/*.current 2>/dev/null || true
overlay_run_daemon "$SCENARIO_DIR/activity_inactive" "NRSYNCD_ACTIVITY_OVERLAY=1 NRSYNCD_TEST_INACTIVITY_IFACE=wlan1 NRSYNCD_TEST_INACTIVITY_AFTER_CYCLE=1 NRSYNCD_INACTIVE_THRESHOLD=2 NRSYNCD_OVERLAY_PUBLISH_MIN_INTERVAL=1 NRSYNCD_MAX_CYCLES=7"
assert_log_contains 'overlay_state:' 'missing overlay_state log'
assert_log_contains 'overlay_state:.*inactive=2' 'expected inactive=2 state'
assert_runtime_key overlay_active_count 'missing overlay_active_count runtime'
assert_runtime_key overlay_inactive_count 'missing overlay_inactive_count runtime'
ac=$(grep '^overlay_active_count=' /tmp/nrsyncd_runtime | cut -d= -f2)
ic=$(grep '^overlay_inactive_count=' /tmp/nrsyncd_runtime | cut -d= -f2)
[ $((ac+ic)) -eq 2 ] || { echo "activity_inactive: expected 2 total got $((ac+ic))" >&2; exit 1; }
assert_metrics_key overlay_inactive_count 'missing overlay_inactive_count metrics'
assert_metrics_key overlay_active_count 'missing overlay_active_count metrics'
grep -q '^overlay_inactive_ordinals=' /tmp/nrsyncd_metrics || { echo "missing overlay_inactive_ordinals metrics" >&2; exit 1; }
echo "Scenario activity_inactive: PASS"
