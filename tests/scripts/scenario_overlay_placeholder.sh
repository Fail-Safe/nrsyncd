#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -e
BASE_DIR=$(cd -- "$(dirname "$0")/../.." && pwd)
. "$BASE_DIR/tests/scripts/overlay_test_lib.sh"
echo "[overlay-placeholder] Using LOG_FILE=$LOG_FILE" >&2
run_daemon_basic
overlay_placeholder_assert
echo "Scenario overlay-placeholder: PASS"
