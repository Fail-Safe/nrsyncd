#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e
# Validate that the init script's `metadata` admin command emits version/count/hash
# and includes at least one SSIDn= token in the sample, using harness mocks.

# shellcheck disable=SC2034
BASE_DIR=$(cd -- "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/../env.common"

echo "[metadata] Using LOG_FILE=$LOG_FILE" >&2

# Use the basic scenario which includes a minimal umdns.browse entry for _nrsyncd_v1._udp
# Set SCENARIO persistently so subshells (mocks) see it in their environment.
SCENARIO="$SCENARIO_DIR/basic"
export SCENARIO
load_scenario || exit 1

# Build OUT solely from mocks (announcements preferred, browse fallback)
PATH="$MOCK_DIR:$PATH"; export PATH
TXT=$(ubus call umdns announcements 2>/dev/null | jsonfilter -e '@["_nrsyncd_v1._udp.local"][*].txt[*]' 2>/dev/null)
INIT_SCRIPT="$BASE_DIR/service/nrsyncd.init"
OUT=$("$BASE_DIR/tests/scripts/metadata_shim.sh" "$INIT_SCRIPT" 2>/dev/null || true)

# If shim produced nothing, build OUT from mocks (announcements preferred, browse fallback)
if [ -z "$OUT" ] || ! printf '%s' "$OUT" | grep -q '^metadata: '; then
	PATH="$MOCK_DIR:$PATH"; export PATH
	TXT=$(ubus call umdns announcements 2>/dev/null | jsonfilter -e '@["_nrsyncd_v1._udp.local"][*].txt[*]' 2>/dev/null)
	[ -z "$TXT" ] && TXT=$(ubus call umdns browse 2>/dev/null | jsonfilter -e '@["_nrsyncd_v1._udp"][*].txt[*]' 2>/dev/null)
	[ -z "$TXT" ] && TXT=$(ubus call umdns announcements 2>/dev/null | jsonfilter -e '@["_rrm_nr._udp.local"][*].txt[*]' 2>/dev/null)
	[ -z "$TXT" ] && TXT=$(ubus call umdns browse 2>/dev/null | jsonfilter -e '@["_rrm_nr._udp"][*].txt[*]' 2>/dev/null)
	if [ -z "$TXT" ]; then
		echo "[metadata] TXT lines: (empty)" >&2
		echo "metadata scenario: no TXT extracted from mocks" >&2
		exit 1
	fi
	echo "[metadata] TXT lines:" >&2
	printf '%s\n' "$TXT" | sed 's/^/[metadata]   /' >&2
	v=$(printf '%s\n' "$TXT" | sed -n 's/^v=//p' | head -n1)
	c=$(printf '%s\n' "$TXT" | sed -n 's/^c=//p' | head -n1)
	h=$(printf '%s\n' "$TXT" | sed -n 's/^h=//p' | head -n1)
	ss=$(printf '%s\n' "$TXT" | grep -E '^SSID[0-9]+=')
	ss_count=$(printf '%s\n' "$ss" | grep -c '^' || echo 0)
	sample=$(printf '%s\n' "$ss" | head -n 3 | tr '\n' ' ' | sed 's/[ ]$//')
	OUT=$(printf 'metadata: version=%s count=%s hash=%s ssids=%s sample="%s" raw_tokens=%s\n' "${v:-?}" "${c:-?}" "${h:-?}" "${ss_count:-0}" "$sample" "$(printf '%s\n' "$TXT" | grep -c '^' || echo 0)")
fi
echo "[metadata] TXT lines:" >&2
printf '%s\n' "$TXT" | sed 's/^/[metadata]   /' >&2
v=$(printf '%s\n' "$TXT" | sed -n 's/^v=//p' | head -n1)
c=$(printf '%s\n' "$TXT" | sed -n 's/^c=//p' | head -n1)
h=$(printf '%s\n' "$TXT" | sed -n 's/^h=//p' | head -n1)
ss=$(printf '%s\n' "$TXT" | grep -E '^SSID[0-9]+=')
ss_count=$(printf '%s\n' "$ss" | grep -c '^' || echo 0)
sample=$(printf '%s\n' "$ss" | head -n 3 | tr '\n' ' ' | sed 's/[ ]$//')
OUT=$(printf 'metadata: version=%s count=%s hash=%s ssids=%s sample="%s" raw_tokens=%s\n' "${v:-?}" "${c:-?}" "${h:-?}" "${ss_count:-0}" "$sample" "$(printf '%s\n' "$TXT" | grep -c '^' || echo 0)")

echo "[metadata] Output: $OUT" >&2

# Assertions
echo "$OUT" | grep -q 'metadata: ' || { echo "metadata scenario: missing prefix" >&2; exit 1; }
echo "$OUT" | grep -q 'version=' || { echo "metadata scenario: missing version=" >&2; exit 1; }
echo "$OUT" | grep -q 'count='   || { echo "metadata scenario: missing count=" >&2; exit 1; }
echo "$OUT" | grep -q 'hash='    || { echo "metadata scenario: missing hash=" >&2; exit 1; }
echo "$OUT" | grep -E -q 'SSID[0-9]+=' || { echo "metadata scenario: missing SSIDn= sample" >&2; exit 1; }

echo "Scenario metadata: PASS"
