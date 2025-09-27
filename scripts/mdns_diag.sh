#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# mdns_diag.sh - Gather mDNS/umdns/nrsyncd diagnostics on an OpenWrt WAP
# Safe to run repeatedly; read-only except for optional HUP to sidecar and umdns browse/update calls.

set -eu

echo "==[ basic ]=="
date || true
hostname || true
uname -a || true
[ -f /etc/openwrt_release ] && cat /etc/openwrt_release || true
echo

echo "==[ network quick view ]=="
if command -v ip >/dev/null 2>&1; then
	ip -o -4 addr show || true
else
	ifconfig 2>/dev/null || true
fi
echo

echo "==[ config flags ]=="
command -v uci >/dev/null 2>&1 && {
	uci -q show nrsyncd.global.activity_overlay || true
}
echo

echo "==[ processes ]=="
ps w | grep -E "(umdns|nrsyncd)" | grep -v grep || true
echo

echo "==[ init: metadata / overlay files ]=="
if [ -x /etc/init.d/nrsyncd ]; then
	/etc/init.d/nrsyncd metadata 2>/dev/null || true
	echo
	/etc/init.d/nrsyncd overlay 2>/dev/null || true
fi
echo

echo "==[ files ]=="
ls -l /tmp/nrsyncd_state 2>/dev/null || true
echo "--- /tmp/nrsyncd_state/base_txt ---" && cat /tmp/nrsyncd_state/base_txt 2>/dev/null || true
echo "--- /tmp/nrsyncd_overlay_tokens ---" && cat /tmp/nrsyncd_overlay_tokens 2>/dev/null || true
echo

echo "==[ umdns browse (raw) ]=="
if command -v ubus >/dev/null 2>&1; then
	ubus call umdns browse 2>/dev/null | sed -n '1,200p' || true
	echo
	echo "==[ umdns browse (_nrsyncd_v1._udp slice) ]=="
	# BusyBox sed lacks GNU ",+Np" address; use awk to print a generous slice after the match
	ubus call umdns browse 2>/dev/null | awk '
			BEGIN{printing=0; n=0; max=180}
			/"_nrsyncd_v1._udp"[[:space:]]*:/ {printing=1; n=0}
			{ if(printing){ print; n++; if(n>=max) exit 0 } }
		' 2>/dev/null || true
	echo
	echo "==[ merged TXT quick check ]=="
	# Scan browse slice for a=/i= separate tokens; flag placeholders
	if ubus call umdns browse 2>/dev/null | grep -q '"_nrsyncd_v1._udp"'; then
		b=$(ubus call umdns browse 2>/dev/null)
		printf '%s' "$b" | grep -E '"txt":\s*"a=<none>"' >/dev/null 2>&1 && echo "note: base TXT shows placeholders (a=<none>, i=<none>)"
		if printf '%s' "$b" | grep -E '"txt":\s*"a=' >/dev/null 2>&1 && printf '%s' "$b" | grep -E '"txt":\s*"i=' >/dev/null 2>&1; then
			echo "found: separate a= and i= tokens present in browse output"
		else
			echo "warn: a=/i= not visible as separate tokens in browse (could be cache or base only)"
		fi
	fi
	echo
	echo "==[ umdns browse (jsonfilter attempts) ]=="
	if command -v jsonfilter >/dev/null 2>&1; then
		echo "-- extract TXT arrays (pattern 1) --" && ubus call umdns browse 2>/dev/null | jsonfilter -l1 -e '@["_nrsyncd_v1._udp"][*].txt[*]' 2>/dev/null || true
		echo "-- extract TXT arrays (pattern 2) --" && ubus call umdns browse 2>/dev/null | jsonfilter -l1 -e '@["_nrsyncd_v1._udp"]..txt[*]' 2>/dev/null || true
	fi
	echo
	echo "==[ umdns update -> browse (raw) ]=="
	ubus call umdns update 2>/dev/null || true
	sleep 1
	ubus call umdns browse 2>/dev/null | sed -n '1,200p' || true
fi
echo

echo "==[ sidecar announce: HUP and re-browse ]=="
echo "publisher removed; skip"
echo

echo "==[ packet capture (optional) ]=="
if command -v tcpdump >/dev/null 2>&1; then
	# Pick a likely interface (prefer br-lan)
	IFACE="${NRSYNCD_PUBLISH_IFACE:-br-lan}"
	[ -z "$IFACE" ] && IFACE="br-lan"
	echo "Capturing 10 mDNS packets on $IFACE (ASCII payload) ..."
	tcpdump -n -A -i "$IFACE" -s 0 -c 10 udp port 5353 2>/dev/null | sed -n '1,240p' || true
else
	echo "tcpdump not installed; skipping"
fi
echo

echo "==[ done ]=="
