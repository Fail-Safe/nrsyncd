# Copilot Instructions (nrsyncd)

Purpose: Guide AI changes to the nrsyncd OpenWrt 802.11k Neighbor Report synchronization daemon.

## Components

- `service/nrsyncd.init`: procd init; gathers per‑iface NR JSON, builds `SSIDn=` TXT args + metadata (`v=1 c=<count> h=<hash>`), exports env, registers mDNS service, admin subcommands.
- `bin/nrsyncd`: Prebuilt daemon (opaque) consuming ordered `SSIDn=` args; periodic neighbor aggregation, mDNS refresh, metrics/state updates; signals HUP/USR1/USR2.
- `lib/nrsyncd_common.sh`: POSIX helpers (adaptive retry, iface mapping, ms sleep abstraction, readiness probes, normalization).
- `scripts/install.sh`: Idempotent installer (deps, sysupgrade persistence, wireless validation / optional auto‑fix, prefix staging, opkg/apk detection, migration helpers).
- `package/nrsyncd/`: OpenWrt package skeleton (Makefile + default `/etc/config/nrsyncd`).
- `tests/` harness (mocks + scenarios: basic, skip, reload; installer test).
- `examples/wireless.config`: Example dual‑band wireless config with required 802.11k / BSS transition options.

## Runtime Flow

1. Count enabled `wifi-iface` stanzas.
2. Wait for matching `hostapd.*` ubus objects (3s cadence, 5m timeout).
3. Quick per‑iface retrieval via `rrm_nr_get_own` (upstream hostapd ubus method) with adaptive retry.
4. Build `SSIDn=` tokens (ordering invariant) then append metadata tokens.
5. Launch daemon with args; export `NRSYNCD_*` env (legacy `RRM_NR_*` exported during deprecation window if still needed).
6. Advertise `_nrsyncd_v1._udp` (browse may still observe `_rrm_nr._udp` for interoperability).
7. Daemon cycles: compute neighbor reports, refresh mDNS (rate‑limited), update metrics/state; honor signals.

## Conventions

- Delimiter `+` reserved; never alter SSID content.
- Never renumber existing `SSIDn=` positions; only append new higher `n` or metadata tokens at end.
- Metadata keys present: `v` (schema version), `c` (SSID entry count), `h` (first 8 hex of md5 over concatenated SSID tokens). Future keys must append only.
- Error hard‑fail for structural config issues; bounded adaptive retry for readiness (no hostapd restarts).
- Shell: strict POSIX (BusyBox ash); avoid arrays, bashisms.
- Skip list via `list skip_iface <iface>`; normalization strips optional `hostapd.` prefix.
- Metrics/state files: `/tmp/nrsyncd_runtime`, `/tmp/nrsyncd_metrics`; ephemeral.
- Version constant: `NRSYNCD_INIT_VERSION` in init script (bump each tagged release).

## Safe Extension Guidelines

- Add new TXT metadata only after all `SSIDn=` tokens; ensure daemon ignores unknown tokens.
- New UCI options: document (README + this file) & ensure reload semantics (SIGHUP path) handle them.
- Keep init fast; heavy logic belongs in daemon or future sidecar.
- Limit retries for non‑transient failures (≤3) with single concise log line per iface.
- If adding per‑iface disable: `option nrsyncd_disable '1'` and mirror skip logic in counting/enumeration.

## Developer Workflow

- Install: `sh scripts/install.sh` (flags: `--fix-wireless`, `--add-sysupgrade`, `--deps-auto-yes`, `--prefix <dir>` etc.).
- Manual deploy: copy binary/init/lib; enable & start service.
- Package build: place `package/nrsyncd` into OpenWrt buildroot `package/`; select in `menuconfig`.
- Debug startup: `sh -x /etc/init.d/nrsyncd start`.
- Reload after UCI edits: `/etc/init.d/nrsyncd reload`.
- mDNS TXT check (local advertisement): `ubus call umdns announcements | jsonfilter -e '@["_nrsyncd_v1._udp.local"][*].txt[*]'`.
- mDNS TXT check (network discovery): `ubus call umdns browse | jsonfilter -e '@["_nrsyncd_v1._udp"][*].txt[*]'` (fallback `_rrm_nr._udp` if still present).
- Tests: `tests/run-tests.sh`; installer: `tests/scripts/test_install.sh`.
- Shell lint: `scripts/shellcheck.sh`.

## Observability & Admin Subcommands

- Logging tag: `nrsyncd` (info/error, debug when enabled).
- Runtime: `/tmp/nrsyncd_runtime` (effective params, skip list, counts, initial_positional_ssids).
- Metrics: `/tmp/nrsyncd_metrics` (cycles, pushes, suppressed, cache hits/misses, uniqueness, failures, per‑iface neighbor*count*\*). Derived ratios via `summary`.
- Subcommands: `mapping`, `mapping_json` (alias `mapping-json`), `neighbors`, `cache`, `refresh`, `diag`, `metrics`, `summary`, `timing_check|timing-check`, `status`, `skiplist`, `reset_metrics`, `version`, `metadata`.
- Readiness probes: `diag` / `timing_check` use `rrm_nr_probe_iface` helper (name reflects upstream ubus method family).
- Metadata inspection: `/etc/init.d/nrsyncd metadata` prints parsed live advertisement.

## Edge Cases / Pitfalls

- Hostapd object mismatch: wait loop until count matches or timeout (exit with error).
- Fractional sleep unavailable: fallback to whole‑second; adaptive retry still capped.
- Missing 802.11k/BSS Transition: installer warns; `--fix-wireless` inserts options with backup `.nrsyncd.bak`.
- Large AP sets (>20): measure before decreasing 3s poll cadence.
- Legacy browse only: init warns if `_rrm_nr._udp` seen without `_nrsyncd_v1._udp`.

## UCI Options (global)

| Option                 | Purpose                                 | Notes                                |
| ---------------------- | --------------------------------------- | ------------------------------------ |
| enabled                | Master enable (0 = skip start)          | Checked only at start                |
| update_interval        | Base seconds between cycles             | Daemon enforces min 5                |
| jitter_max             | Random 0..jitter added to each cycle    | Capped ≤ half interval               |
| debug                  | Verbose logging                         | Adds debug lines                     |
| umdns_refresh_interval | Min seconds between mDNS refresh pushes | Rate limit                           |
| umdns_settle_delay     | Sleep seconds after a refresh           | Default 0                            |
| skip_iface             | Interfaces to exclude (repeatable)      | Normalized; hostapd. prefix stripped |
| quick_max_ms           | Upper bound for quick readiness pass    | Sanitized & capped                   |
| second_pass_ms         | Delay before second readiness pass      | Sanitized & capped                   |

## Installer Flags

- `--add-sysupgrade` Persist binary/init/lib across sysupgrade.
- `--deps-auto-yes|--deps-auto-no` Non‑interactive dependency handling.
- `--install-optional` Install micro‑sleep provider (higher resolution sleeps).
- `--fix-wireless` Add missing 802.11k / BSS transition options to active ifaces.
- `--force-config` Overwrite existing `/etc/config/nrsyncd`.
- `--no-start` Stage files only.
- `--prefix <dir>` Alternate root (staging/tests).
- `--auto-migrate-legacy` (if still present) migrate prior naming.

## Licensing

GPLv2 (see `LICENSE`). New source files must include a GPLv2/SPDX header.

## Change Guidelines

- Update `NRSYNCD_INIT_VERSION` with each tagged release.
- Maintain ordering invariants (all `SSIDn=` first, metadata after).
- Document any new UCI keys / metadata tokens here + README.
- Keep log lines concise and singular per condition.
- Run test harness after any logic change to init/lib scripts.

End of file.
