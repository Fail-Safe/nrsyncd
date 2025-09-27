#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Four SSIDs + overlay + sidechannel => 4 SSIDn + v c h a i sc = 10 tokens.
# Policy: prune i=<none> then a=<none> (retain sc=) => final 8 tokens.

DIR=$(cd -- "$(dirname "$0")" && pwd)
. "$DIR/overlay_test_lib.sh"
. "$DIR/../env.common"

fail() {
	echo "[prune-four][FAIL] $*" >&2
	exit 1
}

SCEN=prune_four
prepare_scenario "$SCEN" || fail "prepare_scenario failed"

export CFG_DEBUG=1
export CFG_ACTIVITY_OVERLAY=1
export CFG_SIDECHANNEL_ENABLE=1
export CFG_SIDECHANNEL_PROTO=udp
export CFG_SIDECHANNEL_PORT=32026

echo "[prune-four] Using LOG_FILE=$LOG_FILE" >&2
PATH="$MOCK_DIR:$PATH"
export PATH

BASE_ROOT=$(cd -- "$DIR/../.." && pwd)
BIN="$BASE_ROOT/bin/nrsyncd"
LOG_FILE="$LOG_FILE" NRSYNCD_UPDATE_INTERVAL=1 NRSYNCD_JITTER_MAX=0 NRSYNCD_DEBUG=1 NRSYNCD_TEST_FORCE_UPDATE=1 NRSYNCD_MAX_CYCLES=1 \
	/bin/sh "$BIN" >/dev/null 2>&1 || true

# Compute and patch hash: md5(first 8) over concatenated SSIDn tokens with '|'
hash_input='SSID1=NRVAL0|SSID2=NRVAL1|SSID3=NRVAL2|SSID4=NRVAL3|'
if command -v md5sum >/dev/null 2>&1; then
	h=$(printf '%s' "$hash_input" | md5sum | awk '{print $1}' | cut -c1-8)
else
	h=na
fi
sed -i '' "s/h=placeholder/h=$h/" "$SCENARIO/umdns.browse" 2>/dev/null ||
	sed "s/h=placeholder/h=$h/" "$SCENARIO/umdns.browse" >"$SCENARIO/umdns.browse.tmp" 2>/dev/null && mv "$SCENARIO/umdns.browse.tmp" "$SCENARIO/umdns.browse" 2>/dev/null || true

META=$("$DIR/metadata_shim.sh" 2>/dev/null || true)
if [ -z "$META" ] || ! printf '%s' "$META" | grep -q '^metadata: '; then
	TXT=$(sed -n 's/.*"txt"[ ]*:[ ]*\[\(.*\)\].*/\1/p' "$SCENARIO/umdns.browse" | sed 's/","/\n/g; s/^[[:space:]]*"//; s/"[[:space:]]*$//')
	[ -z "$TXT" ] && fail "fallback parse produced no TXT"
	v=$(printf '%s\n' "$TXT" | sed -n 's/^v=//p' | head -n1)
	c=$(printf '%s\n' "$TXT" | sed -n 's/^c=//p' | head -n1)
	hval=$(printf '%s\n' "$TXT" | sed -n 's/^h=//p' | head -n1)
	ss=$(printf '%s\n' "$TXT" | grep -E '^SSID[0-9]+=' || true)
	ss_count=$(printf '%s\n' "$ss" | grep -c '^' 2>/dev/null || echo 0)
	sample=$(printf '%s\n' "$ss" | head -n 4 | tr '\n' ' ' | sed 's/[ ]$//')
	total=$(printf '%s\n' "$TXT" | grep -c '^' 2>/dev/null || echo 0)
	META="metadata: version=${v:-?} count=${c:-?} hash=${hval:-?} ssids=${ss_count:-0} sample=\"$sample\" raw_tokens=$total"
fi

TOKENS=$(sed -n 's/.*"txt"[ ]*:[ ]*\[\([^]]*\)\].*/\1/p' "$SCENARIO/umdns.browse" | sed 's/","/\n/g; s/^[[:space:]]*"//; s/"[[:space:]]*$//')
[ -n "$TOKENS" ] || fail "could not extract tokens"

# Post-prune expectations: raw_tokens=8; i=<none> and a=<none> both pruned; sc= present
printf '%s\n' "$META" | grep -q 'version=2' || fail "missing version=2"
printf '%s\n' "$META" | grep -q 'raw_tokens=8' || fail "expected raw_tokens=8"
printf '%s\n' "$TOKENS" | grep -q '^sc=udp:32026$' || fail "missing sc token"
if printf '%s\n' "$TOKENS" | grep -q '^i=<none>$'; then fail "i placeholder not pruned"; fi
if printf '%s\n' "$TOKENS" | grep -q '^a=<none>$'; then fail "a placeholder not pruned"; fi

echo "Scenario prune_four: PASS"
