# Changelog

All notable changes will be documented here. Dates use UTC.

## [Unreleased]

_(no changes yet)_

## [1.1.0] - 2025-09-26

### Added

- Optional sidechannel TXT token `sc=<proto>:<port>` exposure documented; listener prefers `socat` backend when available.
- Broadcast helper (`nrsyncd_broadcast_helper`): proactive heartbeat/status frames to discovered peers (structured discovery, self-filtering, jittered cadence, host+endpoint dedup).
- Test env toggles: `NRSYNCD_SC_BCAST_DIRECT_INGEST` (direct ingest without network) and `NRSYNCD_SC_DISABLE_SELF_HEARTBEAT` (suppress sidechannel self file) documented.

### Changed

- README: Expanded architecture table (sidechannel + broadcast helper) and clarified dependency preference order (`socat` → `ncat` → `nc`).
- Developer guide/README: Documented self-filter logic and structured discovery (announcements-first, browse fallback) with AWK fallback parser.
- Removed experimental internal `mdns_publisher` (dynamic TXT mutation path); sidechannel + overlay cover dynamic needs.

## [1.0.3] - 2025-09-25

### Added

- Tests: Added quotes-SSID scenario to validate end-to-end handling of embedded double quotes in SSIDs. Updated mocks (`jsonfilter`, `ubus`, `iwinfo`) and assertions accordingly.

### Changed

- Daemon: Canonicalization uses JSON parsing throughout and normalizes JSON-encoded array lines from mDNS TXT before scanning. Maintains stable ordering (SSID, then BSSID) and reduces fragile text parsing.
- Internal mapping: Switch temporary SSID→iface map to TAB as the field separator to avoid collisions with SSID contents (spaces, plus signs, quotes).
- Debuggability: Added targeted debug lines (`remote_entries`, `group_build`, `canon_line`, `canon_wrapped`, `canon_scan`, `cache_hit`/`cache_write`) gated by `NRSYNCD_DEBUG=1` to speed up diagnostics without noisy logs by default.

### Fixed

- Robust SSID handling end-to-end: SSIDs with spaces (including repeated), plus signs (`+`), and embedded double quotes are preserved and JSON-escaped correctly in all paths.
- Quotes-SSID update path: Properly escape SSID before awk variable binding in group membership lookup, ensuring `rrm_nr_set` updates occur and payloads retain intended escaping.
- TXT parsing: Hardened mock `jsonfilter` and TXT item splitting to avoid breaking on escaped quotes or commas inside items; daemon now unescapes one level when TXT carries JSON-encoded arrays.


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

