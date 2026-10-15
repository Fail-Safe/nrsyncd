#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e
# shellcheck disable=SC2034
SCENARIO_DIR=$(cd -- "$(dirname "$0")/.." && pwd)/scenarios
SCENARIO="$SCENARIO_DIR/basic"
. "$(dirname "$0")/../env.common"
echo "[basic] Using LOG_FILE=$LOG_FILE" >&2
echo "[basic] HARNESS_DIR=$HARNESS_DIR MOCK_DIR=$MOCK_DIR" >&2
echo "[basic] PATH=$PATH" >&2
export LOG_FILE

# Isolate previous runs
rm -f "$STATE_DIR/nrsyncd_set.log" "$STATE_DIR"/*.current 2>/dev/null || true

SCENARIO="$SCENARIO" load_scenario || exit 1
export SCENARIO

# Run daemon bounded cycles
BASE_ROOT=$(dirname "$0")/../..
BIN="$(cd -- "$BASE_ROOT" && pwd)/bin/nrsyncd"
LOG_FILE="$LOG_FILE" NRSYNCD_UPDATE_INTERVAL=1 NRSYNCD_JITTER_MAX=0 NRSYNCD_DEBUG=1 NRSYNCD_TEST_FORCE_UPDATE=1 NRSYNCD_MAX_CYCLES=3 \
  /bin/sh "$BIN" > /dev/null 2>&1 &
PID=$!
echo "[basic] Started daemon PID=$PID (max cycles)" >&2
wait $PID 2>/dev/null || true
echo "[basic] Daemon exited (max cycles)" >&2

# Each BSS must receive its sibling, never itself or malformed remote TXT.
python3 - <<'PY'
import json
import os
from pathlib import Path
import subprocess

own = {}
for iface in ("wlan0", "wlan1"):
    own[iface] = json.loads(subprocess.check_output(
        ["ubus", "call", "hostapd." + iface, "rrm_nr_get_own"], text=True
    ))["value"]
for iface, sibling in (("wlan0", "wlan1"), ("wlan1", "wlan0")):
    actual = json.loads((Path(os.environ["STATE_DIR"]) / (iface + ".current")).read_text())
    assert actual == [own[sibling]], (iface, actual, own[sibling])
PY

echo "Scenario basic: PASS"
