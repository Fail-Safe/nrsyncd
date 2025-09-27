#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e

BASE_DIR=$(cd -- "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/../env.common"

echo "[broadcast] Using LOG_FILE=$LOG_FILE" >&2

SCENARIO="$SCENARIO_DIR/basic"
export SCENARIO
load_scenario || exit 1

# Ensure mocks precede system tools
PATH="$MOCK_DIR:$BASE_DIR/bin:$PATH"
export PATH

STATE_ROOT="$STATE_DIR/bcast_test"
rm -rf "$STATE_ROOT" && mkdir -p "$STATE_ROOT/sidechannel_peers"

SC_BIN="$BASE_DIR/bin/nrsyncd_sidechannel"
BH_BIN="$BASE_DIR/bin/nrsyncd_broadcast_helper"
[ -x "$SC_BIN" ] || {
	echo "broadcast scenario: sidechannel binary missing" >&2
	exit 1
}
[ -x "$BH_BIN" ] || {
	echo "broadcast scenario: helper binary missing" >&2
	exit 1
}

# Configure environment to deliver to local ingest without networking
export NRSYNCD_SC_STATE_DIR="$STATE_ROOT"
export NRSYNCD_SC_DEBUG=0
export NRSYNCD_SC_BCAST_LOOPBACK=1
export NRSYNCD_SC_SELF_ID="tester-host"

# With PSK set, payload includes it and will be accepted by ingest
export NRSYNCD_SC_PSK="abc123"

# Run one-shot broadcast; expect a file for self id (normalized by receiver to lowercase filename)
"$BH_BIN" --once

test -f "$STATE_ROOT/sidechannel_peers/tester-host.json" || {
	echo "broadcast scenario: expected tester-host.json from loopback ingest" >&2
	exit 1
}

echo "Scenario broadcast_helper: PASS"
