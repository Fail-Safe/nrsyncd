#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Exercise the production publication helper against stateful procd/umdns mocks."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

MOCK_UBUS = r'''
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["DISCOVERY_STATE"])
_, obj, method, *args = sys.argv[1:]
if obj == "service" and method == "set_data":
    with (root / "calls.jsonl").open("a") as out:
        out.write(json.dumps([obj, method]) + "\n")
    if os.environ.get("FAIL_SET_DATA") == "1":
        sys.exit(1)
    request = json.loads(args[0])
    service = json.loads((root / "service.json").read_text())
    assert request["name"] == "nrsyncd"
    instance = service["nrsyncd"]["instances"][request["instance"]]
    instance["data"] = request["data"]
    (root / "service.json").write_text(json.dumps(service))
    print("{}")
elif obj == "umdns" and method == "reload":
    with (root / "calls.jsonl").open("a") as out:
        out.write(json.dumps([obj, method]) + "\n")
    if os.environ.get("FAIL_RELOAD") == "1":
        sys.exit(1)
    service = json.loads((root / "service.json").read_text())
    records = service["nrsyncd"]["instances"]["instance1"]["data"]["mdns"]
    previous_path = root / "published.json"
    previous = json.loads(previous_path.read_text())
    cache_path = root / "peer_cache.json"
    cache = json.loads(cache_path.read_text())
    # Model umdns's immutable cached TXT contents for an existing DNS name.
    # Removed service IDs send goodbyes; new IDs announce their DNS instance.
    for key, record in previous.items():
        if key not in records:
            cache.pop(record.get("instance", "example-ap"), None)
    for record in records.values():
        cache.setdefault(record.get("instance", "example-ap"), record)
    cache_path.write_text(json.dumps(cache))
    previous_path.write_text(json.dumps(records))
    announcements = {}
    for record in records.values():
        announcements.setdefault(record["service"], []).append(record)
    (root / "announcements.json").write_text(json.dumps(announcements))
    print("{}")
elif obj == "umdns" and method == "announcements":
    print((root / "announcements.json").read_text())
else:
    raise AssertionError((obj, method))
'''


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nrsyncd-discovery-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, source in {
            "ubus": MOCK_UBUS,
            "md5sum": 'import hashlib,sys; print(hashlib.md5(sys.stdin.buffer.read()).hexdigest()+"  -")',
            "uname": 'print("example-ap")',
        }.items():
            program = self.bin / name
            program.write_text(f"#!{sys.executable}\n" + source)
            program.chmod(0o755)
        self.old_record = {
            "service": "_nrsyncd_v1._udp.local", "port": 32025,
            "txt": ['SSID1=["02:00:00:00:ff:ff","OldSSID","startup-channel"]',
                    "v=1", "c=1", "h=oldhash"],
        }
        self.instance = {
            "running": True, "pid": 1234,
            "command": ["/usr/bin/nrsyncd", *self.old_record["txt"]],
            "data": {"mdns": {"nrsyncd_v1_32025": self.old_record}},
        }
        (self.root / "service.json").write_text(json.dumps({
            "nrsyncd": {"instances": {"instance1": self.instance}}
        }))
        (self.root / "announcements.json").write_text(json.dumps({
            self.old_record["service"]: [self.old_record]
        }))
        (self.root / "published.json").write_text(json.dumps({
            "nrsyncd_v1_32025": self.old_record
        }))
        (self.root / "peer_cache.json").write_text(json.dumps({"example-ap": self.old_record}))
        source = (ROOT / "bin/nrsyncd").read_text()
        # Source actual helper code only, excluding startup and daemon execution.
        self.helper = source.split("publish_own_mdns() {", 1)[1].split("\ndo_updates() {", 1)[0]
        self.helper = "publish_own_mdns() {" + self.helper
        self.commands = []
        self.expected = []

    def cycle(self, label, own, members=None, skipped=(), fail=None, expected=None):
        directory = self.root / label
        directory.mkdir()
        for iface, value in own.items():
            (directory / iface).write_text(json.dumps(value, separators=(",", ":")))
        members = list(own) if members is None else members
        self.commands.extend([
            "hostapd_members=" + shlex.quote(" ".join(members)),
            "skip_ifaces=" + shlex.quote(" ".join(skipped)),
            "export FAIL_SET_DATA=" + ("1" if fail == "set_data" else "0"),
            "export FAIL_RELOAD=" + ("1" if fail == "reload" else "0"),
            "publish_own_mdns " + shlex.quote(str(directory)),
            "ubus call umdns announcements > " + shlex.quote(str(self.root / (label + ".json"))),
            "cp " + shlex.quote(str(self.root / "peer_cache.json")) + " " +
            shlex.quote(str(self.root / (label + ".peer.json"))),
        ])
        if expected is None:
            expected = [own[iface] for iface in sorted(members) if iface in own and iface not in skipped]
        self.expected.append((label, [list(value) for value in expected]))

    def run_cycles(self):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   DISCOVERY_STATE=str(self.root))
        subprocess.run(["/bin/sh"], input=self.helper + "\n" + "\n".join(self.commands),
                       text=True, env=env, check=True, capture_output=True)
        for label, expected in self.expected:
            with self.subTest(cycle=label):
                advertisements = json.loads((self.root / (label + ".json")).read_text())
                self.assertEqual(set(advertisements), {"_nrsyncd_v1._udp.local"})
                records = advertisements["_nrsyncd_v1._udp.local"]
                self.assertEqual(len(records), 1)
                record = records[0]
                self.assertEqual(record["port"], 32025)
                tokens = record["txt"][:-3]
                self.assertEqual([json.loads(token.split("=", 1)[1]) for token in tokens], expected)
                self.assertEqual([token.split("=", 1)[0] for token in tokens],
                                 [f"SSID{i}" for i in range(1, len(expected) + 1)])
                digest = hashlib.md5("".join(token + "|" for token in tokens).encode()).hexdigest()[:8]
                self.assertEqual(record["txt"][-3:], ["v=1", f"c={len(expected)}", f"h={digest}"])
                peer_records = json.loads((self.root / (label + ".peer.json")).read_text())
                self.assertEqual(len(peer_records), 1)
                peer_record = next(iter(peer_records.values()))
                self.assertEqual([json.loads(token.split("=", 1)[1])
                                  for token in peer_record["txt"][:-3]], expected)
        current = json.loads((self.root / "service.json").read_text())["nrsyncd"]["instances"]
        self.assertEqual(set(current), {"instance1"})
        self.assertEqual(len(current["instance1"]["data"]["mdns"]), 1)
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def test_live_changes_replace_startup_and_suppress_unchanged(self):
        own = {
            "wlan0": ["02:00:00:00:00:01", 'Guest "east" \\ room', "020000000001ef48000051010e"],
            "wlan1": ["02:00:00:00:00:02", 'Guest "east" \\ room', "020000000002ef58000080990e"],
            "wlan2": ["02:00:00:00:00:03", "SkippedSSID", "020000000003ef48000051010e"],
        }
        self.cycle("initial", own, skipped=("wlan2",))
        self.cycle("unchanged_reordered", own, members=list(reversed(own)), skipped=("wlan2",))
        own["wlan1"][2] = "020000000002ef58000080950e"
        self.cycle("channel", own, skipped=("wlan2",))
        own["wlan0"][1] = "New SSID"
        self.cycle("ssid", own, skipped=("wlan2",))
        own["wlan0"][0] = "02:00:00:00:00:11"
        own["wlan0"][2] = "020000000011ef48000051010e"
        self.cycle("bssid", own, skipped=("wlan2",))
        own["wlan3"] = ["02:00:00:00:00:04", "New SSID", "020000000004ef58000080950e"]
        self.cycle("new_interface", own, skipped=("wlan2",))
        self.cycle("skip_changed", own, skipped=("wlan0", "wlan2"))
        self.cycle("missing_report", {"wlan1": own["wlan1"]}, members=list(own), skipped=("wlan0", "wlan2"))
        self.cycle("empty", {}, members=list(own))
        calls = self.run_cycles()
        self.assertEqual(calls, [["service", "set_data"], ["umdns", "reload"]] * 8)

    def test_failed_publication_does_not_suppress_next_collection(self):
        before = ["02:00:00:00:00:01", "ExampleSSID", "020000000001ef58000080990e"]
        after = ["02:00:00:00:00:01", "ExampleSSID", "020000000001ef58000080950e"]
        self.cycle("initial", {"wlan0": before})
        self.cycle("set_failed", {"wlan0": after}, fail="set_data", expected=[before])
        self.cycle("reload_failed", {"wlan0": after}, fail="reload", expected=[before])
        self.cycle("recovered", {"wlan0": after})
        self.cycle("unchanged", {"wlan0": after})
        calls = self.run_cycles()
        self.assertEqual(calls, [["service", "set_data"], ["umdns", "reload"],
                                 ["service", "set_data"],
                                 ["service", "set_data"], ["umdns", "reload"],
                                 ["service", "set_data"], ["umdns", "reload"]])


if __name__ == "__main__":
    unittest.main()
