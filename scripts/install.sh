#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# install.sh - helper to deploy the nrsyncd distributor onto a running OpenWrt system
#
# Usage (on your workstation):
#   scp -r nrsyncd root@ap:/tmp/nrsyncd_src
#   ssh root@ap 'sh /tmp/nrsyncd_src/scripts/install.sh'
#
# Or copy just this script & required files, then run it on the target device.
#
# Idempotent: safe to re-run; will not overwrite existing /etc/config/nrsyncd unless --force-config given.
#
# License: GPL-2.0 (see top-level LICENSE)
#
# Environment variables (advanced / test):
#   NRSYNCD_TEST_MODE=1  - enable wireless config validation inside --prefix root (not just live /etc)

set -eu

PREFIX=""
FORCE_CONFIG=0
START_SERVICE=1
ADD_SYSUPGRADE=0
DEPS_MODE="prompt"       # prompt | yes | no
INSTALL_OPTIONAL=0       # install optional deps automatically
FIX_WIRELESS=0           # auto-add missing ieee80211k/bss_transition
AUTO_MIGRATE_LEGACY=0    # auto-run migration script if legacy rrm_nr config present (live system only, no --prefix)

# Remote install orchestrator (executes this script over SSH on target)
REMOTE_HOSTS=""          # space separated list (user@host or host) may be built from comma list(s)
REMOTE_PREFIX="/tmp/nrsyncd_remote"
REMOTE_KEEP=0
REMOTE_SSH_OPTS=""
REMOTE_DRY_RUN=0
REMOTE_RETRIES=1          # number of attempts per host (>=1)
REMOTE_BACKOFF_BASE=2     # base seconds for exponential backoff between retries
PASS_ARGS=""              # non-remote flags preserved for remote invocation
STATUS_WAIT=0             # seconds to wait/poll for runtime status after start

while [ $# -gt 0 ]; do
  case "$1" in
    --remote)
      # Accept comma-separated host list, may be passed multiple times
      list=$2; shift 2
      list=$(echo "$list" | tr ',' ' ')
      REMOTE_HOSTS="$REMOTE_HOSTS $list" ;;
    --remote-prefix)
      REMOTE_PREFIX=$2; shift 2 ;;
    --remote-keep)
      REMOTE_KEEP=1; shift ;;
    --ssh-opts)
      REMOTE_SSH_OPTS=$2; shift 2 ;;
    --remote-dry-run)
      REMOTE_DRY_RUN=1; shift ;;
    --remote-retries)
      REMOTE_RETRIES=$2; shift 2 ;;
    --remote-backoff)
      REMOTE_BACKOFF_BASE=$2; shift 2 ;;
    --prefix)
      PREFIX=$2; PASS_ARGS="$PASS_ARGS --prefix $2"; shift 2 ;;
    --force-config)
      FORCE_CONFIG=1; PASS_ARGS="$PASS_ARGS --force-config"; shift ;;
    --no-start)
      START_SERVICE=0; PASS_ARGS="$PASS_ARGS --no-start"; shift ;;
    --add-sysupgrade)
      ADD_SYSUPGRADE=1; PASS_ARGS="$PASS_ARGS --add-sysupgrade"; shift ;;
    --deps-auto-yes)
      DEPS_MODE="yes"; PASS_ARGS="$PASS_ARGS --deps-auto-yes"; shift ;;
    --deps-auto-no)
      DEPS_MODE="no"; PASS_ARGS="$PASS_ARGS --deps-auto-no"; shift ;;
    --install-optional)
      INSTALL_OPTIONAL=1; PASS_ARGS="$PASS_ARGS --install-optional"; shift ;;
    --fix-wireless)
      FIX_WIRELESS=1; PASS_ARGS="$PASS_ARGS --fix-wireless"; shift ;;
    --status-wait)
      STATUS_WAIT=$2; shift 2 ;;
    --auto-migrate-legacy)
      AUTO_MIGRATE_LEGACY=1; shift ;;
    -h|--help)
      cat <<EOF
Install nrsyncd distributor files.
Options:
  --remote <user@host[,host2,...]>  Remote install (comma or space separated list). Repeatable.
  --remote-prefix <dir> Remote staging directory (default /tmp/nrsyncd_remote).
  --remote-keep         Keep remote staging directory (default removed after success).
  --ssh-opts "<opts>"    Extra SSH options (e.g. '-p 2222 -i key').
  --remote-dry-run      Show what would be transferred / commands for remote install then exit.
  --remote-retries <n>  Retry count per host on failure (default 1).
  --remote-backoff <s>  Base seconds for exponential backoff (2,4,8..) (default 2).
  --prefix <dir>       Install root (default "", i.e. /). Useful for staging (e.g. image build rootfs overlay).
  --force-config       Overwrite existing /etc/config/nrsyncd with bundled default.
  --no-start           Do not enable/start the init service after install.
  --add-sysupgrade     Append file paths to /etc/sysupgrade.conf (persist across firmware upgrades).
  --deps-auto-yes      Install missing required dependencies without prompting.
  --deps-auto-no       Skip installing dependencies (just warn if missing).
  --install-optional   Also install optional enhancements (high-res sleep: coreutils-sleep/coreutils).
  --fix-wireless       Auto-add missing ieee80211k '1' / bss_transition '1' to active wifi-iface stanzas.
  --status-wait <sec>  After starting service, poll up to <sec> seconds for runtime status file.
  --auto-migrate-legacy  If legacy rrm_nr config/service present and no nrsyncd config yet (live system), run migration script automatically.
  -h, --help           Show this help.
Examples:
  sh scripts/install.sh
  sh scripts/install.sh --no-start --prefix /builder/root
 Remote examples:
   sh scripts/install.sh --remote root@ap1
   sh scripts/install.sh --remote ap1,ap2,ap3 --deps-auto-yes --install-optional
   sh scripts/install.sh --remote ap1 --remote ap2 --ssh-opts '-p 2222' --force-config
   sh scripts/install.sh --remote ap1 --remote-dry-run
   sh scripts/install.sh --remote root@ap1 --remote-prefix /tmp/customdir --force-config
EOF
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Resolve repo root (directory containing this script) early for remote mode too
CDPATH="" SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(dirname "$SCRIPT_DIR")

if [ -n "$REMOTE_HOSTS" ]; then
  # Normalize whitespace
  set -- "$REMOTE_HOSTS"
  REMOTE_HOSTS="$*"
  FILE_LIST="service/nrsyncd.init bin/nrsyncd lib/nrsyncd_common.sh scripts/install.sh scripts/migrate_from_rrm_nr.sh config/nrsyncd.config"
  MANIFEST_NAME="nrsyncd_manifest.sha256"
  MANIFEST_PATH="$REPO_ROOT/$MANIFEST_NAME"
  # Sanitize retry/backoff numeric inputs
  case "$REMOTE_RETRIES" in ''|*[!0-9]* ) REMOTE_RETRIES=1 ;; esac
  [ "$REMOTE_RETRIES" -lt 1 ] && REMOTE_RETRIES=1
  case "$REMOTE_BACKOFF_BASE" in ''|*[!0-9]* ) REMOTE_BACKOFF_BASE=2 ;; esac
  [ "$REMOTE_BACKOFF_BASE" -lt 1 ] && REMOTE_BACKOFF_BASE=1
  # Build manifest (only include existing files)
  : >"$MANIFEST_PATH" || { echo "[nrsyncd] ERROR: cannot create manifest at $MANIFEST_PATH" >&2; exit 1; }
  for f in $FILE_LIST; do
    if [ -f "$REPO_ROOT/$f" ]; then
      if command -v sha256sum >/dev/null 2>&1; then
        (cd "$REPO_ROOT" && sha256sum "$f" >>"$MANIFEST_PATH")
      else
        # Fallback to md5 if sha256 unavailable locally (rare on dev systems)
        if command -v md5sum >/dev/null 2>&1; then
          (cd "$REPO_ROOT" && md5sum "$f" | sed 's/^/md5:/') >>"$MANIFEST_PATH"
        else
          echo "[nrsyncd] WARNING: No sha256sum or md5sum locally; manifest will be empty" >&2
        fi
      fi
    else
  echo "[nrsyncd] NOTE: missing local file $f (may be optional)" >&2
    fi
  done
  FILE_LIST="$FILE_LIST $MANIFEST_NAME"

  if [ $REMOTE_DRY_RUN -eq 1 ]; then
  echo "[nrsyncd] Remote dry-run mode. No changes will be made."
  echo "[nrsyncd] Targets: $REMOTE_HOSTS"
  echo "[nrsyncd] Staging directory: $REMOTE_PREFIX"
  echo "[nrsyncd] Retries per host: $REMOTE_RETRIES (backoff base: ${REMOTE_BACKOFF_BASE}s)"
  echo "[nrsyncd] Files to transfer with hashes (sha256 where available):"
    if [ -s "$MANIFEST_PATH" ]; then
      sed 's/^/  /' "$MANIFEST_PATH"
    else
      echo "  (manifest empty)"
    fi
  echo "[nrsyncd] Equivalent per-host command pipeline:"
    echo "  tar -C '$REPO_ROOT' -czf - $FILE_LIST | ssh <host> 'mkdir -p $REMOTE_PREFIX && tar -xzf - -C $REMOTE_PREFIX && (cd $REMOTE_PREFIX && sha256sum -c $MANIFEST_NAME && sh scripts/install.sh $PASS_ARGS)'"
    rm -f "$MANIFEST_PATH" 2>/dev/null || true
    exit 0
  fi

  overall_status=0
  for H in $REMOTE_HOSTS; do
    host_disp=$H
    case "$H" in *@*) ;; *) H="root@$H" ;; esac
    attempt=1
    delay=$REMOTE_BACKOFF_BASE
    success=0
    while [ $attempt -le $REMOTE_RETRIES ]; do
  echo "[nrsyncd] [$host_disp] Attempt $attempt/$REMOTE_RETRIES (staging: $REMOTE_PREFIX)"
      # Prepare positional args array for tar to avoid SC2086 (word splitting) while still expanding list
      set -- $FILE_LIST
      # shellcheck disable=SC2086  # intentional splitting of SSH options and PASS_ARGS
      if tar -C "$REPO_ROOT" -czf - "$@" 2>/dev/null | ssh $REMOTE_SSH_OPTS "$H" "mkdir -p '$REMOTE_PREFIX' && tar -xzf - -C '$REMOTE_PREFIX' && if command -v sha256sum >/dev/null 2>&1; then (cd '$REMOTE_PREFIX' && sha256sum -c '$MANIFEST_NAME'); else echo '[nrsyncd] WARNING: sha256sum not present remotely; skipping integrity verification'; fi && (cd '$REMOTE_PREFIX' && sh scripts/install.sh $PASS_ARGS)"; then
        echo "[nrsyncd] [$host_disp] Remote install succeeded"
        success=1
        if [ "$REMOTE_KEEP" -ne 1 ]; then
          # shellcheck disable=SC2086
          ssh $REMOTE_SSH_OPTS "$H" "rm -rf '$REMOTE_PREFIX'" 2>/dev/null || true
          echo "[nrsyncd] [$host_disp] Remote staging directory removed"
        else
          echo "[nrsyncd] [$host_disp] Remote staging directory retained (--remote-keep)"
        fi
        break
      else
  echo "[nrsyncd] [$host_disp] WARNING: Attempt $attempt failed" >&2
        if [ $attempt -lt $REMOTE_RETRIES ]; then
          echo "[nrsyncd] [$host_disp] Backing off ${delay}s before retry" >&2
          sleep "$delay" || true
          delay=$((delay * 2))
        fi
      fi
      attempt=$((attempt + 1))
    done
    if [ $success -ne 1 ]; then
  echo "[nrsyncd] [$host_disp] ERROR: Remote install failed after $REMOTE_RETRIES attempts" >&2
      overall_status=1
    fi
  done
  rm -f "$MANIFEST_PATH" 2>/dev/null || true
  exit $overall_status
fi

# (Local install path below)

# ---------------- Legacy rrm_nr Detection / Migration ----------------
if [ -z "$REMOTE_HOSTS" ] && [ -z "$PREFIX" ]; then
  legacy_cfg=/etc/config/rrm_nr
  legacy_init=/etc/init.d/rrm_nr
  new_cfg=/etc/config/nrsyncd
  if [ -f "$legacy_cfg" ] || [ -f "$legacy_init" ]; then
    if [ -f "$new_cfg" ]; then
      echo "[nrsyncd] NOTICE: legacy rrm_nr artifacts present alongside existing nrsyncd config. Consider running scripts/migrate_from_rrm_nr.sh --remove-old after validation." >&2
    else
      if [ $AUTO_MIGRATE_LEGACY -eq 1 ]; then
        if [ -f "$REPO_ROOT/scripts/migrate_from_rrm_nr.sh" ]; then
          echo "[nrsyncd] Detected legacy rrm_nr; auto-migrating (config + service disable)" >&2
          sh "$REPO_ROOT/scripts/migrate_from_rrm_nr.sh" --no-service || echo "[nrsyncd] WARNING: migration script encountered an issue" >&2
        else
          echo "[nrsyncd] WARNING: migration script not found; cannot auto-migrate" >&2
        fi
      else
        echo "[nrsyncd] LEGACY DETECTED: rrm_nr config/service present. Run: sh scripts/migrate_from_rrm_nr.sh (or re-run install with --auto-migrate-legacy) before proceeding for a clean transition." >&2
      fi
    fi
  fi
fi
# -------------- End Legacy Detection --------------

dest() { printf '%s%s' "$PREFIX" "$1"; }

# copy_file <src-relative> <dest-path> <mode>
# Idempotent + atomic:
#  1. Copy to temp file inside target dir
#  2. If existing file is byte-identical (cmp/md5sum), discard temp (preserves mtime / flash wear)
#  3. Else atomic rename (mv) to final path
copy_file() {
  src=$1; dst=$2; mode=$3
  target="$(dest "$dst")"
  dir=$(dirname "$target")
  mkdir -p "$dir"
  # Create temp in same directory for atomic rename semantics
  if command -v mktemp >/dev/null 2>&1; then
    tmp=$(mktemp "$dir/.nrsyncd.XXXXXX" 2>/dev/null || mktemp 2>/dev/null) || tmp="$dir/.nrsyncd.$$.$(date +%s 2>/dev/null).tmp"
  else
    ts=$(date +%s 2>/dev/null || echo $$)
    tmp="$dir/.nrsyncd.$$.$ts.tmp"
  fi
  # Copy content
  cp "$REPO_ROOT/$src" "$tmp" 2>/dev/null || { echo "[nrsyncd] ERROR: copy failed for $src" >&2; rm -f "$tmp"; return 1; }
  chmod "$mode" "$tmp" 2>/dev/null || true
  if [ -f "$target" ]; then
    identical=0
    if command -v cmp >/dev/null 2>&1; then
      cmp -s "$target" "$tmp" && identical=1 || true
    elif command -v md5sum >/dev/null 2>&1; then
      old_md5=$(md5sum "$target" | awk '{print $1}')
      new_md5=$(md5sum "$tmp" | awk '{print $1}')
      [ "$old_md5" = "$new_md5" ] && identical=1 || true
    fi
    if [ "$identical" -eq 1 ]; then
      rm -f "$tmp"
      return 0
    fi
  fi
  mv -f "$tmp" "$target" 2>/dev/null || { cp "$tmp" "$target" 2>/dev/null; rm -f "$tmp"; }
  chmod "$mode" "$target" 2>/dev/null || true
}

echo "[nrsyncd] Installing files (prefix='${PREFIX:-/}')"

# ---------------- Dependency Handling ----------------

detect_pkg_mgr() {
  if command -v opkg >/dev/null 2>&1; then echo opkg; return 0; fi
  if command -v apk  >/dev/null 2>&1; then echo apk;  return 0; fi
  echo none; return 0
}

pkg_mgr=$(detect_pkg_mgr)
REQ_PKGS="umdns jsonfilter iwinfo"
# ubus typically built-in (base-files / busybox), so we don't test it here.
OPT_PKG_OPKG="coreutils-sleep"   # provides higher-resolution sleep (usleep or fractional)
OPT_PKG_APK="coreutils"

have_pkg_opkg() { opkg list-installed 2>/dev/null | grep -q "^$1 -"; }
have_pkg_apk()  { apk info -e "$1" >/dev/null 2>&1; }

missing_required=""
if [ "$pkg_mgr" = opkg ]; then
  for p in $REQ_PKGS; do have_pkg_opkg "$p" || missing_required="$missing_required $p"; done
elif [ "$pkg_mgr" = apk ]; then
  for p in $REQ_PKGS; do have_pkg_apk "$p" || missing_required="$missing_required $p"; done
fi

install_required() {
  [ -z "$missing_required" ] && return 0
  echo "[nrsyncd] Installing required packages: $missing_required"
  if [ "$pkg_mgr" = opkg ]; then
    opkg update || true
    # shellcheck disable=SC2086
    opkg install $missing_required || true
  elif [ "$pkg_mgr" = apk ]; then
    apk update || true
    # shellcheck disable=SC2086
    apk add $missing_required || true
  fi
}

maybe_install_required() {
  [ -z "$missing_required" ] && return 0
  case "$DEPS_MODE" in
    yes) install_required ;;
  no)  echo "[nrsyncd] WARNING: Missing required packages (not installing due to --deps-auto-no):$missing_required" ;;
    *)
      if [ -t 0 ]; then
  printf '[nrsyncd] Missing required packages:%s\nInstall now? [Y/n] ' "$missing_required"
        read -r ans || ans=""
  case "$ans" in n|N) echo "[nrsyncd] Skipping required package install (may fail at runtime)." ;; *) install_required ;; esac
      else
  echo "[nrsyncd] Non-interactive: required packages missing:$missing_required (use --deps-auto-yes to auto-install)."
      fi
    ;;
  esac
}

maybe_install_optional() {
  [ "$INSTALL_OPTIONAL" -eq 0 ] && return 0
  opt_pkg=""
  [ "$pkg_mgr" = opkg ] && opt_pkg="$OPT_PKG_OPKG"
  [ "$pkg_mgr" = apk ] && opt_pkg="$OPT_PKG_APK"
  [ -z "$opt_pkg" ] && return 0
  have=0
  if [ "$pkg_mgr" = opkg ]; then have_pkg_opkg "$opt_pkg" && have=1; fi
  if [ "$pkg_mgr" = apk ]; then have_pkg_apk "$opt_pkg" && have=1; fi
  [ $have -eq 1 ] && return 0
  echo "[nrsyncd] Installing optional package: $opt_pkg (for high-resolution sleep)"
  if [ "$pkg_mgr" = opkg ]; then
    opkg update || true
    opkg install "$opt_pkg" || true
  elif [ "$pkg_mgr" = apk ]; then
    apk update || true
    apk add "$opt_pkg" || true
  fi
}

if [ "$pkg_mgr" = none ]; then
  echo "[nrsyncd] NOTE: No supported package manager (opkg/apk) detected; ensure dependencies exist: $REQ_PKGS" >&2
else
  [ -n "$missing_required" ] && echo "[nrsyncd] Detected package manager: $pkg_mgr" || true
  maybe_install_required
  maybe_install_optional
fi

# -------------- End Dependency Handling -------------

# ---------------- Wireless 802.11k/v Sanity Check ----------------

check_wireless_rrm() {
  # If prefix set we normally skip, unless in explicit test mode
  if [ -n "$PREFIX" ] && [ "${NRSYNCD_TEST_MODE:-0}" != 1 ]; then
    return 0
  fi
  if [ "${NRSYNCD_TEST_MODE:-0}" = 1 ]; then
    wcfg="${PREFIX}/etc/config/wireless"
  else
    wcfg=/etc/config/wireless
  fi
  [ ! -f "$wcfg" ] && { echo "[nrsyncd] WARNING: $wcfg not found; cannot verify 802.11k/v options" >&2; return 0; }
  awk '
      function flush(){
        if(sec != "" && disabled == 0){
          iface=sec; gsub("'\''","",iface);
          if(ieee==0 || bss==0){ printf("MISSING_IFACE %s %d %d\n", iface, ieee, bss); }
        }
      }
      /^config[[:space:]]+wifi-iface/ { flush(); sec=$3; ieee=0; bss=0; disabled=0; next }
      /option[[:space:]]+ieee80211k/ { v=$3; gsub("'\''","",v); if(v==1) ieee=1 }
      /option[[:space:]]+bss_transition/ { v=$3; gsub("'\''","",v); if(v==1) bss=1 }
      /option[[:space:]]+disabled/ { v=$3; gsub("'\''","",v); if(v==1) disabled=1 }
      END{ flush() }
    ' "$wcfg" 2>/dev/null | while read -r tag iface has_ieee has_bss; do
      [ "$tag" = MISSING_IFACE ] || continue
  msg="[nrsyncd] WARNING: wifi-iface $iface missing required 802.11 options:";
      [ "$has_ieee" -eq 0 ] && msg="$msg ieee80211k=1";
      [ "$has_bss" -eq 0 ] && msg="$msg bss_transition=1";
      echo "$msg" >&2
    done
}

check_wireless_rrm

auto_fix_wireless() {
  [ "$FIX_WIRELESS" -eq 1 ] || return 0
  if [ -n "$PREFIX" ] && [ "${NRSYNCD_TEST_MODE:-0}" = 1 ]; then
    wcfg="${PREFIX}/etc/config/wireless"
  elif [ -n "$PREFIX" ]; then
    # Do not modify non-live prefix roots silently
    return 0
  else
    wcfg=/etc/config/wireless
  fi
  [ ! -f "$wcfg" ] && return 0
  tmp=$(mktemp 2>/dev/null || mktemp -t nrsyncdfix)
  awk '
    function flush(){
      if(inf && disabled==0){
  if(has_k==0){ print "  option ieee80211k '\''1'\''  # added by nrsyncd"; changed=1 }
  if(has_v==0){ print "  option bss_transition '\''1'\''  # added by nrsyncd"; changed=1 }
      }
    }
    BEGIN{inf=0;changed=0}
    /^config[[:space:]]+wifi-iface/ { flush(); inf=1; has_k=0; has_v=0; disabled=0; print; next }
    inf && /option[[:space:]]+ieee80211k/ { if($3 ~ /(^'?1'?$)/) has_k=1 }
    inf && /option[[:space:]]+bss_transition/ { if($3 ~ /(^'?1'?$)/) has_v=1 }
    inf && /option[[:space:]]+disabled/ { if($3 ~ /(^'?1'?$)/) disabled=1 }
    { print }
  END{ flush(); if(changed){ print "# nrsyncd wireless auto-fix applied" } }
  ' "$wcfg" >"$tmp" || { rm -f "$tmp"; return 1; }
  if grep -q "nrsyncd wireless auto-fix applied" "$tmp"; then
    cp "$wcfg" "$wcfg.nrsyncd.bak" 2>/dev/null || true
    mv "$tmp" "$wcfg"
  echo "[nrsyncd] Applied wireless auto-fix (backup at ${wcfg}.nrsyncd.bak)"
  else
    rm -f "$tmp"
  echo "[nrsyncd] Wireless auto-fix: no changes needed"
  fi
}

auto_fix_wireless

# -------------- End Wireless Sanity Check -------------

copy_file service/nrsyncd.init /etc/init.d/nrsyncd 0755
copy_file bin/nrsyncd /usr/bin/nrsyncd 0755
if [ -f "$REPO_ROOT/lib/nrsyncd_common.sh" ]; then
  copy_file lib/nrsyncd_common.sh /lib/nrsyncd_common.sh 0644
fi

# Provide default UCI config if absent or forced.
if [ ! -f "$(dest /etc/config/nrsyncd)" ] || [ "$FORCE_CONFIG" -eq 1 ]; then
  mkdir -p "$(dest /etc/config)"
  cat >"$(dest /etc/config/nrsyncd)" <<'EOC'
config nrsyncd 'global'
	option enabled '1'
	option update_interval '60'
	option jitter_max '10'
	option debug '0'
	option umdns_refresh_interval '30'
	option umdns_settle_delay '0'
	# list skip_iface 'wlan0'
	# list skip_iface 'wlan1-1'
EOC
  echo "[nrsyncd] Installed default /etc/config/nrsyncd"
else
  echo "[nrsyncd] Keeping existing /etc/config/nrsyncd (use --force-config to overwrite)"
fi

if [ "$START_SERVICE" -eq 1 ]; then
  if command -v /etc/init.d/nrsyncd >/dev/null 2>&1; then
    /etc/init.d/nrsyncd enable || true
    # Decide whether to restart (if already registered) or start fresh to avoid benign ubus 'service delete' warning.
    if ubus call service list 2>/dev/null | grep -q '"nrsyncd"'; then
      /etc/init.d/nrsyncd restart || /etc/init.d/nrsyncd start || true
    else
  /etc/init.d/nrsyncd start || true
    fi
  /etc/init.d/nrsyncd status || true
    if [ "$STATUS_WAIT" -gt 0 ]; then
      waited=0
      while [ $waited -lt "$STATUS_WAIT" ]; do
  if /etc/init.d/nrsyncd status 2>/dev/null | grep -q 'cycle='; then
          break
        fi
        sleep 1 || true
        waited=$((waited + 1))
      done
      if [ $waited -ge "$STATUS_WAIT" ]; then
  echo "[nrsyncd] WARNING: runtime status not ready after ${STATUS_WAIT}s" >&2
      else
  echo "[nrsyncd] Status ready after ${waited}s"
      fi
    fi
  else
  echo "[nrsyncd] WARNING: init script not found at /etc/init.d/nrsyncd after install" >&2
  fi
else
  echo "[nrsyncd] Skipped service enable/start (--no-start given)"
fi

if [ "$ADD_SYSUPGRADE" -eq 1 ]; then
  PERSIST_FILE="$(dest /etc/sysupgrade.conf)"
  # Ensure file exists
  touch "$PERSIST_FILE" 2>/dev/null || true
  add_entry() {
    path=$1
    grep -q "^$path$" "$PERSIST_FILE" 2>/dev/null || echo "$path" >>"$PERSIST_FILE"
  }
  add_entry /etc/init.d/nrsyncd
  add_entry /usr/bin/nrsyncd
  add_entry /lib/nrsyncd_common.sh
  echo "[nrsyncd] Added persistence entries to /etc/sysupgrade.conf"
fi

echo "[nrsyncd] Done. Check: logread | grep nrsyncd"
