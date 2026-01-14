# Changelog

All notable changes will be documented here. Dates use UTC.

## [1.0.4] - 2026-01-13

### Fixed

- Daemon: always finalize runtime state file (`/tmp/nrsyncd_runtime`) even when no `SSIDn=` positional args are present (prevents missing runtime state in test harness / edge cases).
- Daemon: suppress noisy stderr from optional `ubus call hostapd.<iface> bss` fallback when the method is unavailable.

### Changed

- Init script: clarify AP/hostapd-only behavior and log how many `wifi-iface` stanzas are ignored (non-`ap` or disabled).
- Admin UX: `status` notes when metrics may be stale immediately after a restart.
- Docs: prefer `ubus call umdns announcements` (`_nrsyncd_v1._udp.local`) for validating local TXT advertisement; keep `umdns browse` for network discovery.
- Repo hygiene: ignore local scratch scripts (`temp_*.sh`).

## [1.0.3] - 2025-11-18

### Fixed

- `rand_jitter()` portability: added fallback from `od` → `hexdump` → time-based seed for systems without GNU `od` support.
- Init script: ensure `/tmp/nrsyncd_state` directory exists early before startup operations to prevent marker file write failures.

---

## [1.0.2] - 2025-09-01

### Added

- Installer: `--cleanup-legacy` and `--cleanup-legacy-force` flags to remove legacy `rrm_nr` artifacts after install (`--cleanup-legacy-force` also removes legacy config, gated by `--force`).

### Changed

- Installer (remote): forward `--auto-migrate-legacy` to the remote side and de‑duplicate repeated hosts (order preserved).

---

## [1.0.1] - 2025-09-01

### Fixed

- Admin `metadata` subcommand: prefer authoritative umdns announcements; robust TXT parsing; correct SSID token regex; outputs version/count/hash and sample SSID entries.
- Installer: `--add-sysupgrade` now de-duplicates `/etc/sysupgrade.conf` and prunes legacy `rrm_nr` entries. Note: `/etc/config` is persisted by OpenWrt by default, so `/etc/config/nrsyncd` is not added explicitly.
- Migration: `--remove-old` also removes leftover legacy binary (`/usr/bin/rrm_nr`) and library (`/lib/rrm_nr_common.sh`), even if config/init were already removed; config removal remains gated by `--force`.

### Changed

- Tests: Added metadata scenario exercising real `metadata_service` via a shim; mocks updated for TXT arrays with `v/c/h` tokens.
- Developer UX: Improved `jsonfilter` selector guidance (`[*]` for arrays) and refined logs/warnings during startup and discovery.

## [1.0.0] - 2025-09-01

Initial public release (versioned service adoption from day one).

### Added

- Runtime state file now includes `primary_service=nrsyncd_v1` for observability / monitoring correlation.
- Informational mDNS TXT metadata appended after SSID entries: `v=1`, `c=<count>`, `h=<8hex>` (currently advisory only; safe to ignore). Added `metadata` admin subcommand to inspect live advertisement.

### Diagnostics / Warnings

- Init script now emits a warning if only the legacy browse record (`_rrm_nr._udp`) is discoverable but the primary versioned service is absent (post‑migration aid).

### Changed

- Service port changed from UDP/5247 (CAPWAP Data channel) to UDP/32025 (unassigned mnemonic) to avoid protocol collision.
- mDNS discovery order: primary `_nrsyncd_v1._udp` (versioned) with legacy fallback `_rrm_nr._udp` only. Unversioned `_nrsyncd._udp` name intentionally never deployed.
- Installer: on live systems, aborts when legacy rrm_nr is detected and no nrsyncd config exists (use `--auto-migrate-legacy` or run migration script first) to prevent mixed states.

### Compatibility / Deprecations

- Legacy environment variable prefix `RRM_NR_*` and legacy mDNS browse fallback `_rrm_nr._udp` are supported this release but **deprecated effective 2025-10-01**. They will be removed in a subsequent minor release after that date (exact version TBD). Update any automation to prefer `NRSYNCD_*` and `_nrsyncd_v1._udp` now.

### Features

- 802.11k neighbor report synchronization daemon (nrsyncd) with hostapd integration via `rrm_nr_*` ubus method names.
- Deterministic neighbor list ordering (SSID, then BSSID) and duplicate suppression across local + remote sources.
- Baseline per‑SSID push to ensure hostapd list population on first cycle.
- mDNS advertisement (`_nrsyncd_v1._udp`) with legacy fallback discovery of `_rrm_nr._udp`.
- Skip list support for interfaces (`skip_iface` / `skip_ifaces`).
- Metrics: per‑cycle + cumulative (`remote_unique_cycle`, `remote_unique_total`, per‑interface `neighbor_count_<iface>`, cache hits/misses, suppression ratio, failures).
- Signals / admin actions: SIGHUP (reload), SIGUSR1 (manual refresh), SIGUSR2 (metrics reset).
- Config options: `update_interval`, `jitter_max`, `umdns_refresh_interval`, `umdns_settle_delay`, `debug`.

### Migration Note

Renamed from legacy project `rrm_nr`; legacy environment variables (`RRM_NR_*`) retained for compatibility. Environment prefix and legacy mDNS service fallback are deprecated 2025-10-01. See README Migration section for precedence rules and timeline.
