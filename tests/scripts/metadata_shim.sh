#!/bin/sh
# Tiny shim to invoke metadata_service from service/nrsyncd.init under the test harness.
# Stubs rc.common/procd helpers so sourcing the init works outside OpenWrt.
set -e

# Resolve init script path
INIT="$1"
if [ -z "$INIT" ]; then
  # Default to repo root service path relative to this script
  INIT=$(cd -- "$(dirname "$0")/../.." && pwd)/service/nrsyncd.init
fi

# Ensure mocks are first on PATH
HARNESS_DIR=$(cd -- "$(dirname "$0")/.." && pwd)
MOCK_DIR="$HARNESS_DIR/mocks"
PATH="$MOCK_DIR:$PATH"; export PATH

# Minimal stubs used by init script (no-ops for tests)
procd_add_reload_trigger() { :; }
procd_open_instance() { :; }
procd_close_instance() { :; }
procd_set_param() { :; }
procd_add_mdns() { :; }
procd_send_signal() { return 1; }
logger() { :; }

# Source the init; tolerate missing optional libraries
. "$INIT" 2>/dev/null || true

# Prefer calling the service function directly
if command -v metadata_service >/dev/null 2>&1; then
  metadata_service
  exit 0
fi

# Fallback: nothing to do
exit 2
