#!/bin/sh
#
# dump_advert.sh - Extract and order nrsyncd `_nrsyncd_v1._udp` TXT tokens
# from the (often non-strict) umdns JSON snapshot `/tmp/umdns.json` on an
# OpenWrt host. Produces a per-host ordered dump matching contract:
#   SSIDn= (ascending, contiguous) then v= c= h= then optional a= i=
# Includes a simple count consistency check.
#
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2025 nrsyncd contributors
#
# Intended for diagnostics only (not used by daemon logic). Safe to copy

set -eu

SRC=${1:-/tmp/umdns.json}
OUT=${2:-/tmp/nrsyncd_tokens_dump.txt}
TMP_BLOCK=/tmp/_nrsyncd_block.$$.
TMP_LIST=/tmp/_nrsyncd_host_tokens.$$.
TMP_SSID=/tmp/_nrsyncd_host_ssid_tokens.$$.
TMP_SSID2=/tmp/_nrsyncd_host_ssid_tokens2.$$.
TMP_CLEAN=/tmp/_nrsyncd_host_tokens_clean.$$.

if [ ! -f "$SRC" ]; then
	echo "[dump_advert] Source file not found: $SRC" >&2
	exit 1
fi

echo "[dump_advert] Parsing: $SRC" >&2

# 1. Extract just the service object for `_nrsyncd_v1._udp`
awk '
  BEGIN{ host="" }
  /"_nrsyncd_v1._udp"[ \t]*:/ {
     capture=1; depth=0
  }
  capture {
     for(i=1;i<=length($0);i++) {
       c=substr($0,i,1)
       if(c=="{") depth++
       else if(c=="}") depth--
     }
     print
     if(capture && depth==0) exit
  }
' "$SRC" >"$TMP_BLOCK" || true

if ! grep -q '_nrsyncd_v1._udp' "$TMP_BLOCK" 2>/dev/null; then
	echo "[dump_advert] Service key not found in source (maybe not yet advertised)" >&2
	rm -f "$TMP_BLOCK" "$TMP_LIST" 2>/dev/null || true
	exit 2
fi

# 2. Derive host label + each TXT token entry (with backtracking fallback).
awk '
  BEGIN{ debug=ENVIRON["DUMP_ADVERT_DEBUG"] }
  function extract_txt(line,   i,start,c,out,phase,esc) {
    start = index(line, "\"txt\""); if(!start) return "";
    for(i=start;i<=length(line);i++){ c=substr(line,i,1); if(c==":"){ phase=1; continue } if(phase && c=="\""){ start=i+1; break } }
    out=""; esc=0;
    for(i=start;i<=length(line);i++){ c=substr(line,i,1); if(esc){ out=out c; esc=0; continue } if(c=="\\"){ esc=1; continue } if(c=="\"") break; out=out c }
    gsub(/\\"/,"\"",out); return out
  }
  /"_nrsyncd_v1._udp"[[:space:]]*:/ { next }
  { lines[++ln]=$0 }
  /"host"[[:space:]]*:/ {
    if(index($0, "\"host\"")>0) {
      line=$0
      gsub(/^[ \t]+/, "", line)
      # strip up to first "host":
      sub(/.*"host"[ \t]*:[ \t]*"/, "", line)
      # now line starts with FQDN + rest
      fqdn=line; sub(/".*/, "", fqdn)
      base=fqdn; sub(/\..*/, "", base)
      host_line[ln]=base
      if(debug) print "@@host " base > "/dev/stderr"
    }
  }
  /"txt"[[:space:]]*:/ {
    val=extract_txt($0); if(val=="") next
    # Backtrack for nearest prior host line
    h=""; for(b=ln; b>=1; b--) if(host_line[b]!=""){ h=host_line[b]; break }
    if(h=="") h="(unknown)"
    print h "\t" val
  }
' "$TMP_BLOCK" >"$TMP_LIST"

if [ ! -s "$TMP_LIST" ]; then
	echo "[dump_advert] No TXT tokens extracted (service present but empty?)" >&2
	rm -f "$TMP_BLOCK" "$TMP_LIST"
	exit 3
fi

# Fallback / supplemental extraction for SSIDn= lines in case initial pass missed them
awk '
  BEGIN{ debug=ENVIRON["DUMP_ADVERT_DEBUG"] }
  /"_nrsyncd_v1._udp"[[:space:]]*:/ { next }
  { lines[++ln]=$0 }
  /"host"[[:space:]]*:/ {
    if(index($0, "\"host\"")>0) {
      line=$0; gsub(/^[ \t]+/, "", line); sub(/.*"host"[ \t]*:[ \t]*"/, "", line); fqdn=line; sub(/".*/, "", fqdn); base=fqdn; sub(/\..*/, "", base); current=base
    }
  }
  /"txt"[[:space:]]*:/ {
    if(match($0,/"txt"[[:space:]]*:[[:space:]]*"(SSID[0-9]+=[^"]*)"/,m)) {
      if(current=="") current="(unknown)"; print current "\t" m[1]
    }
  }
' "$TMP_BLOCK" >"$TMP_SSID" || true

# Merge (avoid duplicates)
if [ -s "$TMP_SSID" ]; then
	cat "$TMP_SSID" >>"$TMP_LIST"
fi

# Second robust fallback: linear scan and immediate emission of SSID tokens
awk '
  BEGIN{ host=""; debug=ENVIRON["DUMP_ADVERT_DEBUG"] }
  /"_nrsyncd_v1._udp"[[:space:]]*:/ { next }
  /"host"[[:space:]]*:/ {
    line=$0; sub(/.*"host"[ \t]*:[ \t]*"/,"",line); sub(/".*/,"",line); sub(/\..*/,"",line); host=line;
  }
  /"txt"[[:space:]]*:/ {
    if(match($0, /"txt"[[:space:]]*:[[:space:]]*"(SSID[0-9]+=[^"]*)"/, m)) {
      if(host=="") host="(unknown)"; print host"\t"m[1]
    }
  }
' "$TMP_BLOCK" >"$TMP_SSID2" || true

if [ -s "$TMP_SSID2" ]; then
	cat "$TMP_SSID2" >>"$TMP_LIST"
fi

# 3. Optional debug preview
if [ -n "${DUMP_ADVERT_DEBUG:-}" ]; then
	echo "[dump_advert][debug] Service block (first 30 lines):" >&2
	sed -n '1,30p' "$TMP_BLOCK" >&2
	echo "[dump_advert][debug] Raw extracted tokens:" >&2
	sed -n '1,30p' "$TMP_LIST" >&2
fi

# 4. Clean list (retain only expected token patterns) before ordering
# Allow user to bypass cleaning (for troubleshooting) by setting DUMP_ADVERT_NO_CLEAN=1
if [ "${DUMP_ADVERT_NO_CLEAN:-0}" = 1 ]; then
	cp "$TMP_LIST" "$TMP_CLEAN"
else
	# Permit optional spaces after the host<tab> before token; be liberal so we do not drop SSID lines.
	grep -E '^[^\t]+\t[[:space:]]*(SSID[0-9]+=|v=|c=|h=|a=|i=)' "$TMP_LIST" >"$TMP_CLEAN" || true
	# If SSID tokens appear in raw but none survived cleaning, fall back (avoid false negatives due to grep quirks)
	if [ ! -s "$TMP_CLEAN" ] || ! grep -q '^.*\tSSID[0-9]\+=' "$TMP_CLEAN" 2>/dev/null; then
		if grep -q '\tSSID[0-9]\+=' "$TMP_LIST" 2>/dev/null; then
			cp "$TMP_LIST" "$TMP_CLEAN"
		fi
	fi
	[ ! -s "$TMP_CLEAN" ] && cp "$TMP_LIST" "$TMP_CLEAN"
fi

if [ -n "${DUMP_ADVERT_DEBUG:-}" ]; then
	echo "[dump_advert][debug] Cleaned token list:" >&2
	sed -n '1,120p' "$TMP_CLEAN" >&2
fi

# 4b. Strip any accidental host-only lines (can appear from malformed input)
# Keep a debug trace if we drop anything so users can inspect anomalies.
awk -F"\t" -v dbg="${DUMP_ADVERT_DEBUG:-}" '
  NF==1 { lone[$0]++; next }
  { print }
  END {
    if(dbg && length(lone)) {
      for(h in lone) {
        print "[dump_advert][debug] Dropped orphan host-only line: " h " (count=" lone[h] ")" > "/dev/stderr"
      }
    }
  }
' "$TMP_CLEAN" >"${TMP_CLEAN}.filtered" 2>/dev/null || true
mv "${TMP_CLEAN}.filtered" "$TMP_CLEAN"

# 5. Order and emit
awk '
  function push(h, ord, tok){
    key=h SUBSEP tok
    if(!(key in dedup)) { dedup[key]=1; bucket[h,ord]=(bucket[h,ord]?bucket[h,ord]"\n":"") tok }
  }
  {
    line=$0
    tab=index(line, "\t"); if(!tab) next
    h=substr(line,1,tab-1); tok=substr(line,tab+1)
    gsub(/^[ \t]+/,"",tok)
    # classify
    ord=9999
    if(match(tok,/^SSID([0-9]+)=/,m)) { ord=m[1]; ssid_seen[h]++ }
    else if(tok ~ /^v=/) ord=10001
    else if(tok ~ /^c=/) ord=10002
    else if(tok ~ /^h=/) ord=10003
    else if(tok ~ /^a=/) ord=10004
    else if(tok ~ /^i=/) ord=10005
    push(h, ord, tok)
    seen[h]=1
    if(match(tok,/^c=([0-9]+)/,cm)) declared[h]=cm[1]
  }
  END {
    # Build sorted host list for deterministic output
    for(h in seen){ hostlist[++hc]=h }
    if(hc>0){
      # simple bubble sort (hc is tiny; clarity > perf)
      for(i=1;i<=hc;i++) for(j=i+1;j<=hc;j++) if(hostlist[i]>hostlist[j]) { tmp=hostlist[i]; hostlist[i]=hostlist[j]; hostlist[j]=tmp }
    }
    for(x=1;x<=hc;x++) {
      h=hostlist[x]
      print "===== " h " ====="
      ssidmax=0
      for(i=1;i<10000;i++) { k=h SUBSEP i; if(k in bucket){ n=split(bucket[k],arr,/\n/); for(j=1;j<=n;j++){ print arr[j]; if(i>ssidmax) ssidmax=i } } }
      for(i=10001;i<=10005;i++){ k=h SUBSEP i; if(k in bucket){ n=split(bucket[k],arr,/\n/); for(j=1;j<=n;j++) print arr[j] } }
      if(declared[h] != "") {
        status=(ssidmax==declared[h]?"OK":"WARN(count="declared[h]" max_seen="ssidmax")")
        print "#count_check " status
      } else if(ssid_seen[h]>0) {
        print "#count_check inferred(max_seen=" ssidmax ")"
      } else {
        print "#count_check MISSING(all_ssid_tokens_dropped?)"
      }
      if(!(h SUBSEP 1 in bucket) && ssid_seen[h]>0) {
        print "#anomaly missing_contiguous_start (saw SSID tokens but no SSID1 bucket)"
      }
      if(ssid_seen[h]==0 && declared[h] > 0) {
        print "#anomaly declared_nonzero_but_no_ssid_tokens"
      }
      print ""
    }
  }
' "$TMP_CLEAN" >"$OUT"

echo "[dump_advert] Wrote ordered tokens -> $OUT" >&2
sed -n '1,200p' "$OUT"

rm -f "$TMP_BLOCK" "$TMP_LIST" "$TMP_SSID" "$TMP_SSID2" "$TMP_CLEAN" 2>/dev/null || true
exit 0
