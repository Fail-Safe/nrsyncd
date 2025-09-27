#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# overlay_set.sh — Normalize and set overlay TXT tokens for nrsyncd sidecar
#
# Usage:
#   sh /usr/bin/overlay_set.sh [i_list]
#
# Behavior:
#   - Writes two lines to /tmp/nrsyncd_overlay_tokens atomically:
#       a=
#       i=<i_list>
#   - If i_list is omitted, it attempts to derive ordinals in this order:
#       1) /tmp/nrsyncd_metrics overlay_inactive_ordinals
#       2) /tmp/nrsyncd_runtime initial_positional_ssids (1..N)
#       3) Count SSID lines in /tmp/nrsyncd_state/base_txt (1..N)
#   - Previously signaled an mDNS publisher; that publisher has been removed.
#   - Prints resulting file contents.

set -eu

derive_ordinals() {
	ord=""
	# 1) metrics
	if [ -z "$ord" ] && [ -f /tmp/nrsyncd_metrics ]; then
		ord=$(sed -n 's/^overlay_inactive_ordinals=//p' /tmp/nrsyncd_metrics 2>/dev/null | head -n1 || true)
	fi
	# 2) runtime -> expand 1..N
	if [ -z "$ord" ] && [ -f /tmp/nrsyncd_runtime ]; then
		n=$(sed -n 's/^initial_positional_ssids=//p' /tmp/nrsyncd_runtime 2>/dev/null | head -n1 || true)
		case "$n" in '' | *[!0-9]*) n=0 ;; esac
		if [ "$n" -gt 0 ]; then
			i=1
			o=""
			while [ "$i" -le "$n" ]; do
				if [ -z "$o" ]; then o="$i"; else o="$o,$i"; fi
				i=$((i + 1))
			done
			ord="$o"
		fi
	fi
	# 3) base_txt count -> expand 1..N
	if [ -z "$ord" ] && [ -f /tmp/nrsyncd_state/base_txt ]; then
		n=$(grep -c '^SSID[0-9]\+=' /tmp/nrsyncd_state/base_txt 2>/dev/null || true)
		case "$n" in '' | *[!0-9]*) n=0 ;; esac
		if [ "$n" -gt 0 ]; then
			i=1
			o=""
			while [ "$i" -le "$n" ]; do
				if [ -z "$o" ]; then o="$i"; else o="$o,$i"; fi
				i=$((i + 1))
			done
			ord="$o"
		fi
	fi
	printf '%s' "$ord"
}

I_LIST="${1:-}"
if [ -z "$I_LIST" ]; then
	I_LIST=$(derive_ordinals)
fi

umask 077
tmp="/tmp/nrsyncd_overlay_tokens.tmp"
{
	printf '%s\n' 'a='
	printf '%s\n' "i=$I_LIST"
} >"$tmp"
mv -f "$tmp" /tmp/nrsyncd_overlay_tokens

# Nudge sidecar if present
# publisher removed; no-op

echo "overlay: tokens (/tmp/nrsyncd_overlay_tokens)"
sed -n '1,20p' /tmp/nrsyncd_overlay_tokens 2>/dev/null || true

exit 0
