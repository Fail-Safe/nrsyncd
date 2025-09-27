#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e

# Exercise PSK enforcement logic in bin/nrsyncd_sidechannel validate_and_store

BASE_DIR=$(cd -- "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/../env.common"

echo "[psk] Using LOG_FILE=$LOG_FILE" >&2

SCENARIO="$SCENARIO_DIR/basic"
export SCENARIO
load_scenario || exit 1

# Ensure mocks precede system tools
PATH="$MOCK_DIR:$PATH"
export PATH

STATE_ROOT="$STATE_DIR/psk_test"
export NRSYNCD_SC_STATE_DIR="$STATE_ROOT"
export NRSYNCD_SC_DEBUG=0

rm -rf "$STATE_ROOT" && mkdir -p "$STATE_ROOT/sidechannel_peers"

SC_BIN="$BASE_DIR/bin/nrsyncd_sidechannel"
[ -x "$SC_BIN" ] || {
	echo "psk scenario: sidechannel binary missing" >&2
	exit 1
}

# 1) With PSK set: accept matching, reject mismatching
export NRSYNCD_SC_PSK="s3cret"
printf '%s' '{"id":"peer1","ok":1,"psk":"s3cret"}' | "$SC_BIN" --ingest
test -f "$STATE_ROOT/sidechannel_peers/peer1.json" || {
	echo "psk scenario: expected peer1.json" >&2
	exit 1
}

# Mismatch should not overwrite
get_mtime() {
	f="$1"
	if stat -f %m "$f" >/dev/null 2>&1; then
		stat -f %m "$f"
	elif stat -c %Y "$f" >/dev/null 2>&1; then
		stat -c %Y "$f"
	else
		echo 0
	fi
}
before=$(get_mtime "$STATE_ROOT/sidechannel_peers/peer1.json")
sleep 1
printf '%s' '{"id":"peer1","ok":2,"psk":"wrong"}' | "$SC_BIN" --ingest || true
after=$(get_mtime "$STATE_ROOT/sidechannel_peers/peer1.json")
[ "$after" = "$before" ] || {
	echo "psk scenario: mismatch should not update" >&2
	exit 1
}

# 2) Without PSK set: accept frames lacking psk
unset NRSYNCD_SC_PSK
printf '%s' '{"id":"peer2","ok":3}' | "$SC_BIN" --ingest
test -f "$STATE_ROOT/sidechannel_peers/peer2.json" || {
	echo "psk scenario: expected peer2.json" >&2
	exit 1
}

echo "Scenario psk: PASS"
