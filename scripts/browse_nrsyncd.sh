#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# browse_nrsyncd.sh — BusyBox-safe mDNS/DNS-SD browser for _nrsyncd_v1._udp
# Prints TXT tokens (per line) with host and iface columns. Useful on OpenWrt
# where jsonfilter shapes differ across builds and arrays may be emitted as
# repeated string values. This script avoids brittle selectors.
#
# Usage:
#   sh scripts/browse_nrsyncd.sh            # all TXT tokens (SSIDn=, v/c/h, a/i, sc)
#   sh scripts/browse_nrsyncd.sh --sc-only  # only lines with sc= (sidechannel)
#   sh scripts/browse_nrsyncd.sh --help
#
# Requirements: ubus, umdns running. sed/awk from BusyBox.

set -eu

SC_ONLY=0
case "${1:-}" in
--sc-only) SC_ONLY=1 ;;
--help | -h)
	cat <<'EOF'
browse_nrsyncd.sh — print TXT tokens for _nrsyncd_v1._udp from umdns browse

Options:
  --sc-only   Show only sc= tokens (sidechannel advert)
  --help      This help

Examples:
  sh scripts/browse_nrsyncd.sh
  sh scripts/browse_nrsyncd.sh --sc-only
EOF
	exit 0
	;;
"") : ;;
*)
	echo "Unknown option: $1" >&2
	exit 2
	;;
esac

if ! command -v ubus >/dev/null 2>&1; then
	echo "ubus not found" >&2
	exit 1
fi

# Nudge umdns to refresh (best-effort)
ubus call umdns update >/dev/null 2>&1 || true

# Slice the _nrsyncd_v1._udp section, mask escaped quotes, then extract each TXT
# occurrence as a single line. This handles both single-string and array forms
# because the BusyBox umdns JSON often repeats '"txt": "..."' for each item.
OUT=$(ubus call umdns browse 2>/dev/null |
	sed -n '/"_nrsyncd_v1._udp"[ \t]*:/,/^[ \t]*}/p' |
	sed 's/\\"/@Q@/g' |
	awk -v sc_only="$SC_ONLY" '
  /"host":/  {host=$2;  gsub(/[",]/,"",host)}
  /"iface":/ {iface=$2; gsub(/[",]/,"",iface)}
  /"txt":/   {
    line=$0
    sub(/^.*"txt":[ \t]*"/,"",line)
    sub(/".*$/,"",line)
    gsub(/@Q@/,"\"",line)
    if (line != "") {
      if (sc_only=="1") {
        if (line ~ /^sc=/) printf "%-22s %-10s %s\n", host, iface, line
      } else {
        printf "%-22s %-10s %s\n", host, iface, line
      }
    }
  }
')

printf '%s\n' "$OUT"

# Fallback: if requesting only sc= and browse returned nothing, show local
# announcement sc= so operators can confirm enablement, even if inter-AP browse
# hasn’t converged or is filtered by multicast policy.
if [ "$SC_ONLY" = "1" ] && [ -z "$OUT" ]; then
	if command -v jsonfilter >/dev/null 2>&1; then
		ubus call umdns announcements 2>/dev/null |
			jsonfilter -e '@["_nrsyncd_v1._udp.local"][*].txt[*]' 2>/dev/null |
			sed -n 's/^sc=/local  -     &/p'
	fi
fi

exit 0
