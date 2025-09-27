#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e
# Validate handling of SSIDs containing spaces (including repeated spaces)

# shellcheck disable=SC2034
BASE_DIR=$(cd -- "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/../env.common"

echo "[space-ssid] Using LOG_FILE=$LOG_FILE" >&2
SCENARIO="$SCENARIO_DIR/space"
load_scenario || exit 1
export SCENARIO

BIN="$BASE_DIR/bin/nrsyncd"
# Clean prior state
rm -f "$STATE_DIR/nrsyncd_set.log" "$STATE_DIR"/*.current 2>/dev/null || true

# Run with small cycle count
LOG_FILE="$LOG_FILE" NRSYNCD_UPDATE_INTERVAL=1 NRSYNCD_JITTER_MAX=0 NRSYNCD_DEBUG=1 NRSYNCD_MAX_CYCLES=3 \
	/bin/sh "$BIN" >/dev/null 2>&1 &
PID=$!
wait $PID 2>/dev/null || true

# Assertions: ensure the SSID with repeated spaces is preserved in payloads
expect_ssid='"My  SSID With  Spaces"'
if ! grep -Fq -- "$expect_ssid" "$STATE_DIR/nrsyncd_set.log" 2>/dev/null; then
	echo "Space-SSID scenario failure: expected SSID with repeated spaces not found in set payload" >&2
	echo "Log tail:" >&2
	tail -n 50 "$LOG_FILE" >&2 || true
	echo "Set log:" >&2
	cat "$STATE_DIR/nrsyncd_set.log" >&2 || true
	exit 1
fi

echo "Scenario space-ssid: PASS"
