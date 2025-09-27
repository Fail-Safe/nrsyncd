#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e
# Scenario: overlay counters presence
. "$(dirname "$0")/overlay_test_lib.sh"
rm -f /tmp/nrsyncd_metrics /tmp/nrsyncd_runtime 2>/dev/null || true
overlay_run_daemon "$SCENARIO_DIR/activity_inactive" "NRSYNCD_ACTIVITY_OVERLAY=1 NRSYNCD_TEST_INACTIVITY_IFACE=wlan1 NRSYNCD_TEST_INACTIVITY_AFTER_CYCLE=1 NRSYNCD_INACTIVE_THRESHOLD=2 NRSYNCD_OVERLAY_PUBLISH_MIN_INTERVAL=1 NRSYNCD_MAX_CYCLES=10"
for k in overlay_publishes overlay_skips_rate overlay_skips_nochange overlay_publish_failures; do
  grep -q "^$k=" /tmp/nrsyncd_metrics || { echo "overlay_counters: missing $k metrics" >&2; exit 1; }
  grep -q "^$k=" /tmp/nrsyncd_runtime || { echo "overlay_counters: missing $k runtime" >&2; exit 1; }
done
summary=$(get_summary)
printf '%s' "$summary" | grep -q 'overlay(pub=' || { echo "overlay_counters: summary missing overlay(pub segment" >&2; echo "$summary" >&2; exit 1; }
echo "Scenario overlay_counters: PASS"
