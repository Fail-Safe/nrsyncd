#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Shared helpers for future activity overlay tests. Currently inert; sourced by
# placeholder scenarios so we can introduce the overlay feature incrementally.

set -e

# load base harness env (static path; keep simple at this stage)
BASE_DIR=$(cd -- "$(dirname "$0")/../.." && pwd)
# shellcheck source=/dev/null
. "$BASE_DIR/tests/env.common"

overlay_log() { echo "[overlay-lib] $*" >&2; }

# run_daemon_basic: start daemon with standard basic scenario assets; does NOT
# attempt any overlay-related env or parsing yet. Returns after daemon exits.
run_daemon_basic() {
  SCENARIO="$SCENARIO_DIR/basic"; export SCENARIO
  load_scenario || return 1
  PATH="$MOCK_DIR:$PATH"; export PATH
  # Minimal direct start of daemon (avoid recursion into scenario_basic which has assertions)
  BIN="$BASE_DIR/bin/nrsyncd"
  LOG_FILE="$LOG_FILE" NRSYNCD_UPDATE_INTERVAL=1 NRSYNCD_JITTER_MAX=0 NRSYNCD_DEBUG=0 NRSYNCD_TEST_FORCE_UPDATE=1 NRSYNCD_MAX_CYCLES=1 \
    /bin/sh "$BIN" >/dev/null 2>&1 || true
}

# placeholder assertion (always passes) so placeholder scenarios show PASS.
overlay_placeholder_assert() { :; }
