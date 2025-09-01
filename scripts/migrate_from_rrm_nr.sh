#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# migrate_from_rrm_nr.sh
#
# Purpose:
#   Assist an operator in migrating an existing rrm_nr deployment to the new
#   nrsyncd naming without providing full backward-compatibility shims.
#   Safe, idempotent, BusyBox / POSIX compatible.
#
# Actions (when applicable):
#   * Copy /etc/config/rrm_nr -> /etc/config/nrsyncd (if target missing)
#     and rewrite section headers from 'config rrm_nr' to 'config nrsyncd'.
#   * (Optional) Disable old service and enable new service (if init scripts present).
#   * (Optional) Remove old files if --remove-old specified (after successful copy).
#   * Provide a concise summary of any manual follow-up needed.
#
# Features:
#   --dry-run      : Show what would change, perform no modifications
#   --remove-old   : After successful migration, delete legacy service/config
#   --verbose      : Extra logging
#   --no-service   : Skip service enable/disable actions (config only)
#   --force        : Overwrite existing /etc/config/nrsyncd (default: skip if exists)
#
# Exit codes:
#   0 success (or nothing to do)
#   1 generic failure
#   2 precondition problem (e.g., both configs present without --force)
#
# NOTE: This script does NOT alter runtime /tmp files nor attempt to translate
#       environment variable prefixes inside the opaque daemon. Ensure you have
#       installed the nrsyncd init script & binary beforehand (e.g., via installer).

set -eu

DRY_RUN=0
REMOVE_OLD=0
VERBOSE=0
NO_SERVICE=0
FORCE=0

log() { printf '%s\n' "$*"; }
vlog() { [ "$VERBOSE" -eq 1 ] && log "$@" || true; }
warn() { log "WARN: $*"; }
err() { log "ERROR: $*" 1>&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sh migrate_from_rrm_nr.sh [options]

Options:
  --dry-run       Show planned actions only
  --remove-old    Delete legacy rrm_nr service/config after migration
  --verbose       Verbose logging
  --no-service    Do not enable/disable any services (config only)
  --force         Overwrite existing /etc/config/nrsyncd with migrated copy
  -h|--help       Show this help

Typical flow:
  1. Install nrsyncd files (binary, init, library) separately.
  2. Run this script to copy & rename config if old exists.
  3. Start new service: /etc/init.d/nrsyncd start
  4. Validate; optionally remove old service/config.

Installer interplay:
- The nrsyncd installer aborts on live systems if legacy rrm_nr is detected and no /etc/config/nrsyncd exists yet. Run this script first or pass --auto-migrate-legacy to the installer to proceed automatically.

Idempotency: Re-running will skip steps already applied unless --force or --remove-old specified.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --remove-old) REMOVE_OLD=1 ;;
    --verbose) VERBOSE=1 ;;
    --no-service) NO_SERVICE=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
  shift
done

OLD_CFG=/etc/config/rrm_nr
NEW_CFG=/etc/config/nrsyncd
OLD_INIT=/etc/init.d/rrm_nr
NEW_INIT=/etc/init.d/nrsyncd

SUMMARY=""
append_summary() { SUMMARY="$SUMMARY\n$*"; }

exists() { [ -e "$1" ]; }

# 1. Pre-flight checks
if ! exists "$OLD_CFG" && ! exists "$OLD_INIT"; then
  log "Nothing to migrate: neither $OLD_CFG nor $OLD_INIT present.";
  exit 0
fi

# 2. Config migration
if exists "$OLD_CFG"; then
  if exists "$NEW_CFG" && [ "$FORCE" -eq 0 ]; then
    vlog "Target config already exists ($NEW_CFG); skipping copy (use --force to overwrite)."
  else
    if [ "$DRY_RUN" -eq 1 ]; then
      log "(dry-run) Would copy $OLD_CFG -> $NEW_CFG and rewrite section header(s)."
    else
      vlog "Copying config $OLD_CFG -> $NEW_CFG"
      cp "$OLD_CFG" "$NEW_CFG.tmp" || err "Copy failed"
      # Rewrite section headers: lines starting with 'config rrm_nr'
      # Keep user custom section names if they changed them (only transform standard form)
      sed 's/^config[[:space:]]\+rrm_nr\([[:space:]]\)/config nrsyncd\1/' "$OLD_CFG" > "$NEW_CFG.tmp" || err "Sed transform failed"
      mv "$NEW_CFG.tmp" "$NEW_CFG" || err "Atomic rename failed"
      append_summary "Config migrated: $OLD_CFG -> $NEW_CFG"
    fi
  fi
else
  vlog "Old config not present ($OLD_CFG); skipping config migration."
fi

# 3. Service actions
if [ "$NO_SERVICE" -eq 1 ]; then
  vlog "Service modifications suppressed (--no-service)."
else
  if exists "$OLD_INIT" && exists "$NEW_INIT"; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "(dry-run) Would disable old service rrm_nr and enable new service nrsyncd."
    else
      if command -v /etc/init.d/rrm_nr >/dev/null 2>&1; then
        /etc/init.d/rrm_nr stop 2>/dev/null || true
        /etc/init.d/rrm_nr disable 2>/dev/null || true
        append_summary "Old service rrm_nr stopped & disabled"
      fi
      if command -v /etc/init.d/nrsyncd >/dev/null 2>&1; then
        /etc/init.d/nrsyncd enable 2>/dev/null || true
        append_summary "New service nrsyncd enabled"
      else
        warn "New init script not found or not executable ($NEW_INIT). Install nrsyncd first."
      fi
    fi
  else
    vlog "Skipping service enable/disable (one or both init scripts missing)."
  fi
fi

# 4. Optional removal of legacy artifacts
if [ "$REMOVE_OLD" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) Would remove old artifacts: $OLD_INIT $OLD_CFG (if present)."
  else
    if exists "$OLD_INIT"; then
      if rm -f "$OLD_INIT"; then
        append_summary "Removed old init script $OLD_INIT"
      else
        warn "Failed to remove $OLD_INIT"
      fi
    fi
    if exists "$OLD_CFG" && [ "$FORCE" -eq 1 ]; then
      if rm -f "$OLD_CFG"; then
        append_summary "Removed old config $OLD_CFG"
      else
        warn "Failed to remove $OLD_CFG"
      fi
    elif exists "$OLD_CFG"; then
      warn "Not removing $OLD_CFG (use --force with --remove-old to delete after migration)."
    fi
  fi
fi

# 5. Advisory notes
ADVISORY='Environment variable prefix changed (RRM_NR_ -> NRSYNCD_), runtime /tmp file names updated (/tmp/nrsyncd_*). mDNS service type now versioned `_nrsyncd_v1._udp` (primary) with legacy fallback `_rrm_nr._udp` (deprecated 2025-10-01 along with RRM_NR_* envs). Unversioned `_nrsyncd._udp` was never deployed; update discovery tooling accordingly before deprecation date.'

if [ "$DRY_RUN" -eq 1 ]; then
  log "--- DRY RUN COMPLETE ---"
else
  log "--- MIGRATION SUMMARY ---"
  if [ -n "$SUMMARY" ]; then
    printf '%s\n' "$SUMMARY"
  else
    log "No changes performed."
  fi
fi
log "Advisory: $ADVISORY"
log "Next: start new service (/etc/init.d/nrsyncd start) and validate logs + metrics."

exit 0
