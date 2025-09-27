# Developer Guide

This document captures developer-focused details removed from the README for end-user clarity.

## Repository Layout

Path | Purpose
-----|--------
`service/nrsyncd.init` | Init script (procd) orchestrating readiness, argument assembly, admin commands.
`bin/nrsyncd` | Daemon script (POSIX shell); consumes `SSIDn=` args and performs periodic updates.
`lib/nrsyncd_common.sh` | Shared helpers (normalization, retries, probes). Optional but preferred.
`bin/nrsyncd_sidechannel` | Prototype sidechannel listener (extended mode) storing last JSON frame per peer id.
`bin/nrsyncd_broadcast_helper` | Prototype broadcaster sending periodic heartbeats to discovered sidechannel peers.
`config/nrsyncd.config` | Example UCI configuration template (formerly `rrm_nr.config`).
`examples/` | Example wireless config enabling required 802.11k features.
`tests/` | (If present) harness for basic functional validation.
`docs/` | Documentation (CHANGELOG, developer notes).
`src/` | (reserved)

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

Metric | Notes
-------|------
`cache_hits/misses` | Per-SSID diff detection effectiveness.
`nr_sets_sent/suppressed` | Interface-level push behavior (suppression health).
`baseline_ssids` | Distinct SSIDs receiving baseline push this process.
`remote_entries_merged` | Aggregate remote TXT line ingestion (raw).
`remote_unique_cycle/total` | Per-cycle and cumulative uniqueness of remote entries.
`nr_set_failures` | Hostapd update failures; investigate if non-zero.
`neighbor_count_<iface>` | Post self-filter neighbor set sizes.

## Admin Commands Implementation Notes

Command | Internals
--------|----------
`summary` | Parses metrics file; computes neighbor count min/max/avg.
`reset_metrics` | Sends SIGUSR2 -> daemon resets counters & uniqueness.
`refresh` | SIGUSR1 -> immediate update cycle outside normal cadence.
`diag` | Quick probe for each hostapd object using legacy‑prefixed function `rrm_nr_probe_iface` (ubus method names retained).

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
- Validate mDNS via: `ubus call umdns browse | jsonfilter -e '@["_nrsyncd_v1._udp"][*].txt[*]'`.

## Extended mode (opt-in) and sidechannel v1 schema

Extended features are disabled by default to keep the core simple. To opt in:

```
uci set nrsyncd.global.extended=1
uci commit nrsyncd
/etc/init.d/nrsyncd reload
```

Then selectively enable the sidechannel if you want dynamic peer exchanges:

```
uci set nrsyncd.global.sidechannel_enable=1
# optional:
# uci set nrsyncd.global.sidechannel_proto='udp'   # or 'tcp'
# uci set nrsyncd.global.sidechannel_port='32026'
# uci set nrsyncd.global.sidechannel_psk='secret'
uci commit nrsyncd; /etc/init.d/nrsyncd reload
```

Sidechannel listener (prototype): `/usr/bin/nrsyncd_sidechannel`
 - Backend preference (listen): `socat` (per datagram/connection SYSTEM ingest) → `ncat` → BusyBox `nc` (must support `-l/-p` and `-u` for UDP).
- Stores the last JSON frame per peer under `/tmp/nrsyncd_state/sidechannel_peers/<id>.json`.
- Drops frames if PSK is set and missing/mismatch.
- Size cap: 8KB per frame (recommend <= 1KB for interoperability and future constraints).

Notes on dependencies on OpenWrt:
- Many BusyBox `nc` builds are client-only (no `-l`). If unsupported, install one of:
	- `opkg install socat` (preferred)
	- or `opkg install nmap-ncat` (provides `ncat`)
- After installing, reload the service to have procd restart the sidechannel.

Recommended v1 message schema (JSON, single line):

```
{
	"v": 1,                 // schema version
	"id": "ap-5g-01",      // sender identity (hostname or stable ID)
	"ts": 1732499200,       // unix seconds
	"essid_h": "deadbeef", // short hash of advertised ESSIDs (grouping / quick guard)
	"act": "1,3",          // optional: active ordinals hint (collapsed form of a=/i=)
	"load": {               // optional: coarse load hints
		"sta": 17,
		"ch": 36
	}
}
```

Guidelines:
- Ignore unknown fields; only require v/id/ts. Treat newer ts as fresher.
- Only accept frames with matching `essid_h` if you want to fence per-ESS.
- Rate-limit your sender (e.g., >= 5s); send on change + periodic heartbeat.
- Bind to LAN; PSK is a filter, not encryption. Prefer firewalling the port.
- Do not rely on ordering or delivery guarantees (especially with UDP).

Quick test (listener):

```
echo '{"v":1,"id":"lab","ts":'"$(date +%s)"',"essid_h":"deadbeef","act":"1"}' | nc -u <ap-ip> 32026
ls -1 /tmp/nrsyncd_state/sidechannel_peers
cat /tmp/nrsyncd_state/sidechannel_peers/lab.json
```

Keep the schema small and conservative. If you need to add fields, bump `v` only if semantics change in incompatible ways; consumers should still ignore unknown keys.

### Broadcast helper (prototype)

Script: `bin/nrsyncd_broadcast_helper` (spawned by init when `sidechannel_broadcast_enable=1` and extended mode enabled).

Purpose:
- Discover peers advertising `sc=proto:port` via mDNS (announcements preferred, browse fallback) and proactively send a small heartbeat JSON frame.
- Accelerate initial peer awareness without waiting for them to initiate sidechannel frames.

Key behaviors:
- Structured discovery using `jsonfilter` when available; resilient AWK fallback parser handles minimal umdns JSON.
- Self-filtering: skips localhost, its own instance name (case-insensitive), and any of its local IPv4 addresses.
- Rate control: base interval (`sidechannel_broadcast_interval`) plus random jitter 0..`sidechannel_broadcast_jitter` seconds.
- Backend preference (send): `socat` → `ncat` → `nc`; UDP or TCP selected by sidechannel proto.
- Loopback test mode (env `NRSYNCD_SC_BCAST_LOOPBACK=1`) delivers directly to local `nrsyncd_sidechannel --ingest` without network.
- Safety cap: sends to at most 50 peers per cycle.

Payload format (current): `{ "id":"<self>", "ts":<epoch>, "kind":"hb", "psk":"..."? }`.

Future considerations: optional embedding of overlay ordinals or summarized load metrics (keep under 1KB total per frame).

### When your SDK doesn't have an `env` helper

Some recent SDK tarballs do not include the convenience `/path/to/sdk/env` script. You can still use the toolchain by exporting `PATH` and discovering the `CROSS_COMPILE` prefix from the toolchain bin directory.

Inside your container (or shell where the SDK is mounted at `/sdk`):

```
# Point to the SDK root
SDK=/sdk

# Locate the toolchain bin directory (there is usually only one)
TOOLBIN=$(printf '%s\n' "$SDK"/staging_dir/toolchain-*/bin | head -n1)

# Put the cross tools on PATH
export PATH="$TOOLBIN:$PATH"

# Derive the CROSS_COMPILE triplet from the gcc name (e.g. aarch64-openwrt-linux-musl-)
export CROSS_COMPILE=$(basename "$(ls "$TOOLBIN"/*-gcc | head -n1)" | sed 's/-gcc$/-/')

# Build the sidecar
make -C /work/src CROSS_COMPILE="$CROSS_COMPILE"

# Optional: verify the artifact target

```

Notes:
- On Filogic (MT798x, aarch64), the detected prefix will typically be `aarch64-openwrt-linux-musl-`.
- If the glob `toolchain-*/bin` does not exist or no `*-gcc` is found, the SDK might be incomplete; ensure you extracted the full SDK tarball (not just ImageBuilder) and that `staging_dir/toolchain-*` is present.

Runtime example on target:

```

```

Notes:
- This helper is not a full RFC 6762/6763 responder. Use for experimentation while proper dynamic TXT support in `umdns` is evaluated.


## Troubleshooting Flow

1. No TXT records: confirm `umdns` running; run `ubus call umdns update`.
2. Empty neighbor lists: check logs for `filter self (orig= after=...)` diagnostics.
3. `remote_unique_total` stuck: ensure remote TXT diversity; verify seen file writes.
4. High `nr_set_failures`: inspect hostapd logs (`logread -e hostapd`).

### SDK gcc segfaults when invoked in a container

Symptoms: `aarch64-openwrt-linux-gcc --version` or the build command segfaults.

Likely cause: Missing host library paths for the SDK’s toolchain (mpfr/gmp/mpc) when not using the SDK’s `env` script. Fix by exporting the SDK host paths explicitly:

```
SDK=/sdk
export STAGING_DIR="$SDK/staging_dir"
TOOLCHAIN_DIR=$(ls -d "$STAGING_DIR"/toolchain-* | head -n1)
export PATH="$STAGING_DIR/host/bin:$TOOLCHAIN_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$STAGING_DIR/host/lib:$TOOLCHAIN_DIR/lib:${LD_LIBRARY_PATH:-}"

# Re-run the compiler check
"$TOOLCHAIN_DIR"/bin/aarch64-openwrt-linux-musl-gcc --version
```

If it still segfaults (some emulated environments do), use the Zig fallback below.

### Zig cross-compile fallback (no SDK needed)

You can build a static or mostly-static aarch64-musl binary directly with Zig’s C compiler shim:

```
# Install Zig (host)
# macOS (brew): brew install zig
# Linux: download from https://ziglang.org/download/

# Build using the Makefile target
make -C src zig-aarch64

# Result

```

This produces an `aarch64-linux-musl` ELF binary suitable for OpenWrt on Filogic without relying on the SDK gcc. If you need strip:

```

```

## License

GPLv2 – contributions must include compatible license headers where appropriate.
