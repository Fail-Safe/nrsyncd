#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Scenario: SSID with embedded quotes should be handled safely end-to-end.

set -e

# shellcheck disable=SC2034
BASE_DIR=$(cd -- "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/../env.common"

echo "[quotes] Using LOG_FILE=$LOG_FILE" >&2
echo "[quotes] SCENARIO will be set to $SCENARIO_DIR/quotes" >&2
SCENARIO="$SCENARIO_DIR/quotes"
export SCENARIO
load_scenario || exit 1

# Clean prior state
rm -f "$STATE_DIR/nrsyncd_set.log" "$STATE_DIR"/*.current 2>/dev/null || true

BIN="$BASE_DIR/bin/nrsyncd"

# Run with bounded cycles for determinism
LOG_FILE="$LOG_FILE" NRSYNCD_UPDATE_INTERVAL=1 NRSYNCD_JITTER_MAX=0 NRSYNCD_DEBUG=1 NRSYNCD_MAX_CYCLES=3 \
	/bin/sh "$BIN" &
PID=$!
wait $PID 2>/dev/null || true

# Validate that the SSID containing quotes made it through as a JSON string with escaped quotes
LOG="$STATE_DIR/nrsyncd_set.log"
if [ ! -s "$LOG" ]; then
	echo "[quotes] DEBUG log tail:" >&2
	tail -n 100 "$LOG_FILE" >&2 || true
	echo "Expected nrsyncd_set.log not written" >&2
	exit 1
fi

# Expect to see the SSID value with escaped quotes in JSON context.
# Depending on shell quoting layer, the payload may contain either \" (single escaped) or \\\" (double escaped) in the log.
expect='"SSID \\"Quote\\" Test"'
if ! grep -Fq -- "$expect" "$LOG" 2>/dev/null; then
	echo "Quotes scenario failure: expected escaped quoted SSID not found in set payload" >&2
	echo "Log tail:" >&2
	tail -n 50 "$LOG_FILE" >&2 || true
	echo "Set log:" >&2
	cat "$STATE_DIR/nrsyncd_set.log" >&2 || true
	exit 1
fi

echo "Scenario quotes: PASS"
