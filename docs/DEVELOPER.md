# Developer Guide

This document captures developer-focused details removed from the README for end-user clarity.

## Repository Layout

| Path                    | Purpose                                                                         |
| ----------------------- | ------------------------------------------------------------------------------- |
| `service/nrsyncd.init`  | Init script (procd) orchestrating readiness, argument assembly, admin commands. |
| `bin/nrsyncd`           | Prebuilt daemon (opaque); consumes `SSIDn=` args and performs periodic updates. |
| `lib/nrsyncd_common.sh` | Shared helpers (normalization, retries, probes). Optional but preferred.        |
| `config/nrsyncd.config` | Example UCI configuration template (formerly `rrm_nr.config`).                  |
| `examples/`             | Example wireless config enabling required 802.11k features.                     |
| `tests/`                | (If present) harness for basic functional validation.                           |
| `docs/`                 | Documentation (CHANGELOG, developer notes).                                     |

## Coding Guidelines

- Target shell: BusyBox ash (strict POSIX subset). Avoid arrays, `[[` tests, process substitution.
- Keep init script fast and deterministic; heavy logic belongs in daemon.
- Prefer single concise log lines. Use `logger -t nrsyncd -p daemon.info|error` and guarded debug lines when `debug=1`.
- Avoid unbounded loops; timeouts must be explicit.
- Favor idempotent operations (cache directory creation, baseline push tracking).

## Versioning

- Bump `NRSYNCD_INIT_VERSION` in `service/nrsyncd.init` for each tagged release (legacy `RRM_NR_INIT_VERSION` kept temporarily for backward compatibility export block).
- Maintain `docs/CHANGELOG.md` with Added/Changed/Fixed/Removed sections.

## Release Checklist

1. Ensure working branch merged (fast-forward) into main.
2. Update CHANGELOG with final date & content.
3. Bump `NRSYNCD_INIT_VERSION`.
4. Run lint/tests (if available).
5. Tag: `git tag -a vX.Y.Z -m "vX.Y.Z" && git push --tags`.
6. Build package (optional) and publish ipk.
7. Announce / update external documentation.

## Metrics Overview

| Metric                      | Notes                                                  |
| --------------------------- | ------------------------------------------------------ |
| `cache_hits/misses`         | Per-SSID diff detection effectiveness.                 |
| `nr_sets_sent/suppressed`   | Interface-level push behavior (suppression health).    |
| `baseline_ssids`            | Distinct SSIDs receiving baseline push this process.   |
| `remote_entries_merged`     | Aggregate remote TXT line ingestion (raw).             |
| `remote_unique_cycle/total` | Per-cycle and cumulative uniqueness of remote entries. |
| `nr_set_failures`           | Hostapd update failures; investigate if non-zero.      |
| `neighbor_count_<iface>`    | Post self-filter neighbor set sizes.                   |

## Admin Commands Implementation Notes

| Command         | Internals                                                                                                             |
| --------------- | --------------------------------------------------------------------------------------------------------------------- |
| `summary`       | Parses metrics file; computes neighbor count min/max/avg.                                                             |
| `reset_metrics` | Sends SIGUSR2 -> daemon resets counters & uniqueness.                                                                 |
| `refresh`       | SIGUSR1 -> immediate update cycle outside normal cadence.                                                             |
| `diag`          | Quick probe for each hostapd object using legacy‑prefixed function `rrm_nr_probe_iface` (ubus method names retained). |

## Neighbor Assembly & Adaptive Retry

The init script performs a bounded two‑phase readiness & fetch process to assemble ordered `SSIDn=` TXT arguments before launching the daemon.

Key points:

- Ordering invariant: Arguments are strictly `SSID1=… SSID2=… ...` followed only by metadata tokens (`v= c= h=` today). Never renumber existing positional SSID tokens; only append new highest `n` in future.
- Delimiter `+` is reserved (invalid in SSIDs) to safely join SSID components when needed; do not alter.
- Hostapd dependency: Relies on ubus method `rrm_nr_get_own`. If upstream changes this name, add a fallback probe sequence (e.g. discover supported methods via `ubus -v list hostapd.<iface>` and select the first matching replacement) rather than failing open‑ended.
- Quick readiness pass: Repeated short sleeps (200ms cadence) when sub‑second micro‑sleep available (`usleep` / high‑res `sleep`); otherwise it degrades to a single 1s retry (keeps total bounded on systems without micro‑sleep support).
- Bounds: Total quick pass time capped by sanitized `quick_max_ms` (default 2000, hard cap 5000). A second targeted pass may wait `second_pass_ms` (default 800, cap 1500) before a final fetch for any interfaces that initially returned empty.
- Log lines use concise, single‑line summaries to avoid log spam.

Sample startup log (no skips, one interface briefly not ready):

```
Assembled 2 SSID entries (config-skipped 0, not-ready 1)
```

Sample reload (one configured skip + one still not providing data):

```
Reload assembled 3 SSID entries (config-skipped 1, not-ready 1)
```

Interpretation:

- `config-skipped` counts interfaces explicitly excluded via `list skip_iface`.
- `not-ready` counts enabled hostapd objects that returned no neighbor report value during the fetch window (often transient during immediate post‑radio bring‑up).

Implementation Notes:

- Detection of micro‑sleep capability is lazy (`command -v usleep >/dev/null`).
- When high‑resolution sleep unavailable, fall back to one bounded whole‑second wait rather than multiple 1s sleeps to keep startup fast.
- No unbounded loops: both quick and second pass are strictly capped by sanitized configuration.
- Future interface additions must append new `SSIDn=` tokens without shifting earlier positions to preserve hash stability (`h=` md5 over concatenated SSID tokens).

Developer Considerations for Changes:

- If adding a third pass or alternative probe, keep total wall clock <5s in worst case for typical (<8 iface) deployments.
- Any change impacting ordering must also update hash computation logic (currently first 8 hex of md5) in the init script.
- Keep log wording stable; external parsers may rely on the structured fragments `(config-skipped X, not-ready Y)`.

## Skip List Normalization

- Accept lines with or without `hostapd.` prefix; stored internally stripped.
- Normalization collapses duplicates and extraneous whitespace.
- Reload (SIGHUP) or startup reconstructs skip list each time.

## Remote Uniqueness Tracking

- Cycle uniqueness from `sort -u` of raw remote TXT lines.
- Cumulative uniqueness stored as normalized lines in `/tmp/nrsyncd_state/remote_seen`.
- Reset via SIGUSR2.

## Baseline Push Logic

- Each SSID hash tracked in `baseline_sent_hashes` in daemon memory.
- If no diff but baseline not yet done, force a push (ensures hostapd populated).

## Future Work Ideas

- Configurable interface-level disable (planned `option rrm_nr_disable '1'`).
- Neighbor list length cap + truncation metric.
- Optional remote ingestion toggle for isolated test nodes.
- JSON export endpoint (lightweight HTTP or ubus method) for metrics.

## Testing Tips

- Use `NRSYNCD_MAX_CYCLES=3` (legacy `RRM_NR_MAX_CYCLES` still honored) env var for bounded test runs.
- Add `debug=1` temporarily; remember to turn it off for performance.
- Validate local advertisement via: `ubus call umdns announcements | jsonfilter -e '@["_nrsyncd_v1._udp.local"][*].txt[*]'`.
- Validate network discovery via: `ubus call umdns browse | jsonfilter -e '@["_nrsyncd_v1._udp"][*].txt[*]'`.

## Troubleshooting Flow

1. No TXT records: confirm `umdns` running; run `ubus call umdns update`.
2. Empty neighbor lists: check logs for `filter self (orig= after=...)` diagnostics.
3. `remote_unique_total` stuck: ensure remote TXT diversity; verify seen file writes.
4. High `nr_set_failures`: inspect hostapd logs (`logread -e hostapd`).

## License

GPLv2 – contributions must include compatible license headers where appropriate.
