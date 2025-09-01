# Changelog

All notable changes will be documented here. Dates use UTC.

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

