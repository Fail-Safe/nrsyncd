#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e
# Scenario: broadcast helper should skip self target when discovery includes
# an entry matching its own instance and local addresses.

BASE_DIR=$(cd -- "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/../env.common"

echo "[broadcast-self] Using LOG_FILE=$LOG_FILE" >&2

SCENARIO="$SCENARIO_DIR/broadcast_self"
export SCENARIO
load_scenario || exit 1

PATH="$MOCK_DIR:$BASE_DIR/bin:$PATH"
export PATH

STATE_ROOT="$STATE_DIR/bcast_self"
rm -rf "$STATE_ROOT" && mkdir -p "$STATE_ROOT/sidechannel_peers"

SC_BIN="$BASE_DIR/bin/nrsyncd_sidechannel"
BH_BIN="$BASE_DIR/bin/nrsyncd_broadcast_helper"
[ -x "$SC_BIN" ] || {
	echo "broadcast-self: sidechannel binary missing" >&2
	exit 1
}
[ -x "$BH_BIN" ] || {
	echo "broadcast-self: helper binary missing" >&2
	exit 1
}

# Force deterministic self id that appears in browse (self-ap) and simulate local IP via 127.0.0.1 entry.
export NRSYNCD_SC_STATE_DIR="$STATE_ROOT"
export NRSYNCD_SC_DEBUG=1
export NRSYNCD_SC_SELF_ID="self-ap"
export NRSYNCD_SC_PSK="sfkey"
# Disable self heartbeat so we only observe frames the helper injects
export NRSYNCD_SC_DISABLE_SELF_HEARTBEAT=1

# Start sidechannel listener in background (UDP default) so broadcast helper sends real packet
NRSYNCD_SC_PORT=32026 NRSYNCD_SC_PROTO=udp NRSYNCD_SC_BIND=127.0.0.1 \
	"$SC_BIN" >/dev/null 2>&1 &
SC_PID=$!
sleep 1

# Run one shot broadcast with direct ingest (network backends may be absent).
# Expect one peer file (peer-ap.json) and no self-ap.json
NRSYNCD_SC_BCAST_DIRECT_INGEST=1 NRSYNCD_SC_PORT=32026 "$BH_BIN" --once || true

# Allow a brief settle for ingest (if socat/nc path used)
sleep 1

ls "$STATE_ROOT/sidechannel_peers" >&2 || true

if [ -f "$STATE_ROOT/sidechannel_peers/peer-ap.json" ] && [ ! -f "$STATE_ROOT/sidechannel_peers/self-ap.json" ]; then
	kill "$SC_PID" 2>/dev/null || true
	echo "Scenario broadcast-self-filter: PASS"
	exit 0
fi

kill "$SC_PID" 2>/dev/null || true

echo "broadcast-self-filter: expected peer-ap.json only (self filtered)" >&2
echo "Contents:" >&2
ls -l "$STATE_ROOT/sidechannel_peers" >&2 || true
exit 1
