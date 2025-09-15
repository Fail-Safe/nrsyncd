#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Validate that enabling activity_overlay flag bumps protocol to v=2 and adds
# placeholder a=<none> i=<none> tokens after SSIDn= + v/c/h metadata, preserving ordering invariants.
set -e
BASE_DIR=$(cd -- "$(dirname "$0")/../.." && pwd)
. "$BASE_DIR/tests/env.common"

echo "[overlay-v2] Using LOG_FILE=$LOG_FILE" >&2

SCENARIO="$SCENARIO_DIR/basic"; export SCENARIO
# Enable overlay flag BEFORE loading scenario so init sees it during config load.
grep -v '^nrsyncd.global.activity_overlay=' "$STATE_DIR/uci.conf" 2>/dev/null > "$STATE_DIR/uci.conf.tmp" || true
mv "$STATE_DIR/uci.conf.tmp" "$STATE_DIR/uci.conf"
echo 'nrsyncd.global.activity_overlay=1' >> "$STATE_DIR/uci.conf"
load_scenario || exit 1

PATH="$MOCK_DIR:$PATH"; export PATH

# Helper duplicated (lite) from metadata scenario
get_txt() {
  txt=$(ubus call umdns announcements 2>/dev/null | jsonfilter -e '@["_nrsyncd_v1._udp.local"][*].txt[*]' 2>/dev/null || true)
  [ -z "$txt" ] && txt=$(ubus call umdns browse 2>/dev/null | jsonfilter -e '@["_nrsyncd_v1._udp"][*].txt[*]' 2>/dev/null || true)
  printf '%s' "$txt"
}

# Run daemon single cycle for quick TXT population
BIN="$BASE_DIR/bin/nrsyncd"
LOG_FILE="$LOG_FILE" NRSYNCD_UPDATE_INTERVAL=1 NRSYNCD_JITTER_MAX=0 NRSYNCD_DEBUG=1 NRSYNCD_TEST_FORCE_UPDATE=1 NRSYNCD_MAX_CYCLES=1 \
  /bin/sh "$BIN" >/dev/null 2>&1 || true

# Debug: show effective config line for overlay
grep '^nrsyncd.global.activity_overlay=' "$STATE_DIR/uci.conf" >&2 || true

TXT=$(get_txt)
if [ -z "$TXT" ]; then
  echo "overlay v2 placeholder: no TXT observed" >&2; exit 1; fi

echo "[overlay-v2] TXT lines:" >&2
printf '%s\n' "$TXT" | sed 's/^/[overlay-v2]   /' >&2

# Assertions
printf '%s' "$TXT" | grep -q '^v=2$' || { echo "overlay v2 placeholder: missing v=2" >&2; exit 1; }
printf '%s' "$TXT" | grep -q '^a=<none>' || { echo "overlay v2 placeholder: missing a=<none>" >&2; exit 1; }
printf '%s' "$TXT" | grep -q '^i=<none>' || { echo "overlay v2 placeholder: missing i=<none>" >&2; exit 1; }

# Ordering: all SSIDn= must appear before first v= entry; none after.
after_meta=0
printf '%s' "$TXT" | while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    v=*) after_meta=1 ;;
    SSID[0-9]*=*) [ $after_meta -eq 1 ] && { echo "overlay v2 placeholder: SSID token after metadata (ordering violation)" >&2; exit 1; } ;;
  esac
done || exit 1

echo "Scenario overlay-v2-placeholder: PASS"
