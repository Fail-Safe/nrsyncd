#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e
DIR=$(cd -- "$(dirname "$0")" && pwd)
chmod +x "$DIR"/mocks/* 2>/dev/null || true
chmod +x "$DIR"/scripts/*.sh 2>/dev/null || true
chmod +x "$DIR"/../bin/* 2>/dev/null || true
export LOG_FILE="$DIR/test.log"
: >"$LOG_FILE"
STATE_DIR="$DIR/state"
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
export STATE_DIR

# Execute scenarios
"$DIR/scripts/scenario_basic.sh"
"$DIR/scripts/scenario_skip.sh"
"$DIR/scripts/scenario_reload.sh"
"$DIR/scripts/scenario_metadata.sh"

# Overlay contract: v2 only (ordering + version bump)
"$DIR/scripts/scenario_overlay_v2_contract.sh"

# SSID edge cases
"$DIR/scripts/scenario_space_ssid.sh"
"$DIR/scripts/scenario_quotes.sh"

# PSK enforcement scenario
"$DIR/scripts/scenario_psk.sh"

# Broadcast helper scenario (loopback one-shot)
"$DIR/scripts/scenario_broadcast_helper.sh"

# Broadcast helper self-filter scenario
"$DIR/scripts/scenario_broadcast_self_filter.sh"

echo "All scenarios (with placeholder): PASS"
