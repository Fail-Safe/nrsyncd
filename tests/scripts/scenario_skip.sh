#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e
BASE_DIR=$(cd -- "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/../env.common"
echo "[skip] Using LOG_FILE=$LOG_FILE" >&2
SCENARIO="$SCENARIO_DIR/skip" load_scenario || exit 1
export SCENARIO
BIN="$BASE_DIR/bin/nrsyncd"
STATE_FILE="/tmp/nrsyncd_runtime"
# Clean prior state so assertions only look at this run
rm -f "$STATE_DIR/nrsyncd_set.log" "$STATE_DIR"/*.current 2>/dev/null || true
LOG_FILE="$LOG_FILE" NRSYNCD_UPDATE_INTERVAL=1 NRSYNCD_JITTER_MAX=0 NRSYNCD_DEBUG=1 NRSYNCD_SKIP_IFACES="wlan1" NRSYNCD_MAX_CYCLES=3 \
  /bin/sh "$BIN" > /dev/null 2>&1 &
PID=$!
wait $PID 2>/dev/null || true
# nrsyncd_set log should only contain wlan0 entries
if grep -q '^wlan1 ' "$STATE_DIR/nrsyncd_set.log" 2>/dev/null; then
  echo "Skip scenario failure: wlan1 should have been skipped" >&2
  exit 1
fi
if ! grep -q '^wlan0 ' "$STATE_DIR/nrsyncd_set.log" 2>/dev/null; then
  echo "Skip scenario failure: wlan0 update missing" >&2
  exit 1
fi
echo "Scenario skip: PASS"
