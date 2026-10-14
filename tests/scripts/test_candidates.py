#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Exercise real do_updates across discovery/radio transitions, without daemon sleeps."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['CANDIDATE_STATE'])
name = pathlib.Path(sys.argv[0]).name
if name == 'jsonfilter':
    try:
        value = json.load(sys.stdin)
        expr = sys.argv[sys.argv.index('-e') + 1]
        if expr.startswith('$.value['):
            print(value['value'][int(expr[8:-1])])
        elif '.txt[*]' in expr:
            service = expr.split('"')[1]
            for peer in value.get(service, []):
                for txt in peer.get('txt', []):
                    print(txt)
    except (ValueError, KeyError, TypeError):
        sys.exit(1)
    sys.exit(0)
state = json.loads((root / 'input.json').read_text())
if sys.argv[1] == 'list':
    print('\n'.join('hostapd.' + iface for iface in state['own']))
    sys.exit(0)
obj, method = sys.argv[2:4]
if method == 'rrm_nr_get_own':
    print(json.dumps({'value': state['own'][obj.removeprefix('hostapd.')]}))
elif method == 'browse':
    print(json.dumps({'_nrsyncd_v1._udp': [{'txt': ['SSID%d=%s' % (i, json.dumps(t)) for i, t in enumerate(state['remote'])]}]}))
elif method == 'rrm_nr_set':
    iface = obj.removeprefix('hostapd.')
    payload = json.loads(sys.argv[4])['list']
    with (root / 'sets.jsonl').open('a') as stream:
        stream.write(json.dumps([iface, payload]) + '\n')
    if iface in state.get('fail', []):
        sys.exit(1)
    tables_path = root / 'tables.json'
    tables = json.loads(tables_path.read_text()) if tables_path.exists() else {}
    tables[iface] = payload
    tables_path.write_text(json.dumps(tables))
    print('{}')
else:
    print('{}')
'''


class CandidateHarness:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nrsyncd-candidates-')
        self.path = Path(self.temp.name)
        for name in ('ubus', 'jsonfilter'):
            executable = self.path / name
            executable.write_text(MOCK)
            executable.chmod(0o755)
        # Source only actual function definitions, avoiding daemon startup/traps
        # and global /tmp files. The test controls cycles, not candidate behavior.
        source = (ROOT / 'bin/nrsyncd').read_text()
        functions = source[source.index('do_updates() {'):source.index('\nwrite_state\ndo_updates')]
        bootstrap = r'''
state_dir=$CANDIDATE_STATE
hashmap=$state_dir/map
mkdir -p "$hashmap"
remote_seen_file=$state_dir/remote_seen
: >"$remote_seen_file"
last_umdns_update=0
UMDNS_REFRESH_INTERVAL=0
UMDNS_SETTLE_DELAY=0
cache_hits=0
cache_misses=0
nr_sets_sent=0
nr_sets_suppressed=0
nr_set_failures=0
remote_entries_merged=0
remote_unique_cycle=0
remote_unique_total=0
baseline_ssids=0
baseline_sent_hashes=""
neighbor_counts=""
skip_ifaces=""
force_update_test=0
POST_RELOAD_FORCE=0
hm_put() { printf '%s\n' "$3" >"$1/$2"; }
hm_get() { cat "$1/$2" 2>/dev/null; }
rrm_get_own_quick() { ubus call "hostapd.$1" rrm_nr_get_own; }
debug() { :; }
publish_own_mdns() { :; }
'''
        script = self.path / 'cycle.sh'
        script.write_text(bootstrap + functions + '\nwhile IFS= read -r command; do\n'
                          '  do_updates\n  printf "CYCLE_DONE\\n"\ndone\n')
        environment = dict(os.environ, CANDIDATE_STATE=str(self.path),
                           PATH=str(self.path) + os.pathsep + os.environ['PATH'])
        self.process = subprocess.Popen(['/bin/sh', str(script)], env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)

    def cycle(self, own, remote=(), fail=()):
        (self.path / 'input.json').write_text(json.dumps({'own': own, 'remote': remote, 'fail': fail}))
        self.process.stdin.write('cycle\n')
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            if line == 'CYCLE_DONE\n':
                break
            if not line:
                raise AssertionError('cycle exited: ' + self.process.stderr.read())
        tables = self.path / 'tables.json'
        return json.loads(tables.read_text()) if tables.exists() else {}

    def sets(self):
        path = self.path / 'sets.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        stderr = self.process.stderr.read()
        self.process.stdout.close()
        self.process.stderr.close()
        self.temp.cleanup()
        if self.process.returncode:
            raise AssertionError(stderr)


def tuple_for(mac, ssid='Guest [1].* |, network', channel='010203'):
    return [mac, ssid, channel]


class CandidateTransitions(unittest.TestCase):
    def setUp(self):
        self.harness = CandidateHarness()
        self.addCleanup(self.harness.close)

    def test_late_peer_channel_change_removal_and_stable_suppression(self):
        own = {'wlan0': tuple_for('02:00:00:00:00:01')}
        peer = tuple_for('02:00:00:00:00:02')
        self.assertEqual(self.harness.cycle(own)['wlan0'], [])
        count = len(self.harness.sets())
        self.harness.cycle(own)
        self.assertEqual(len(self.harness.sets()), count)
        self.assertEqual(self.harness.cycle(own, [peer])['wlan0'], [peer])
        changed = peer[:2] + ['010224']
        self.assertEqual(self.harness.cycle(own, [changed])['wlan0'], [changed])
        count = len(self.harness.sets())
        self.harness.cycle(own, [changed, changed])
        self.assertEqual(len(self.harness.sets()), count)
        self.assertEqual(self.harness.cycle(own)['wlan0'], [])

    def test_literal_ssids_local_authority_self_exclusion_and_ordering(self):
        first = tuple_for('02:00:00:00:00:01')
        second = tuple_for('02:00:00:00:00:02')
        other = tuple_for('02:00:00:00:00:03', 'Guest 1xxx |, network')
        quoted = tuple_for('02:00:00:00:00:04', 'Guest "quoted" \\ network')
        remote = tuple_for('02:00:00:00:00:09')
        own = {'wlan0': first, 'wlan1': second, 'wlan2': other, 'wlan3': quoted}
        stale_self = first[:2] + ['000000']
        stale_local = second[:2] + ['000000']
        remote_other = tuple_for('02:00:00:00:00:08', other[1])
        remote_quoted = tuple_for('02:00:00:00:00:07', quoted[1])
        tables = self.harness.cycle(own, [remote, stale_local, stale_self, remote_other, remote_quoted])
        self.assertEqual(tables['wlan0'], [second, remote])
        self.assertEqual(tables['wlan1'], [first, remote])
        self.assertEqual(tables['wlan2'], [remote_other])
        self.assertEqual(tables['wlan3'], [remote_quoted])
        count = len(self.harness.sets())
        self.harness.cycle(own, [remote_quoted, remote_other, stale_self, stale_local, remote])
        self.assertEqual(len(self.harness.sets()), count)

    def test_live_interface_membership_ssid_and_own_channel_changes(self):
        first = tuple_for('02:00:00:00:00:01')
        second = tuple_for('02:00:00:00:00:02')
        own = {'wlan0': first}
        self.harness.cycle(own)
        own['wlan1'] = second
        tables = self.harness.cycle(own)
        self.assertEqual(tables['wlan0'], [second])
        self.assertEqual(tables['wlan1'], [first])
        own['wlan1'] = second[:2] + ['010224']
        self.assertEqual(self.harness.cycle(own)['wlan0'], [own['wlan1']])
        own['wlan1'] = tuple_for(second[0], 'New SSID')
        tables = self.harness.cycle(own)
        self.assertEqual(tables['wlan0'], [])
        self.assertEqual(tables['wlan1'], [])
        own['wlan1'] = second
        self.assertEqual(self.harness.cycle(own)['wlan0'], [second])
        del own['wlan1']
        self.assertEqual(self.harness.cycle(own)['wlan0'], [])

    def test_failed_write_does_not_commit_suppression_cache(self):
        own = {'wlan0': tuple_for('02:00:00:00:00:01')}
        self.harness.cycle(own)
        peer = tuple_for('02:00:00:00:00:02')
        self.assertEqual(self.harness.cycle(own, [peer], fail=['wlan0'])['wlan0'], [])
        self.assertEqual(self.harness.cycle(own, [peer])['wlan0'], [peer])
        count = len(self.harness.sets())
        self.harness.cycle(own, [peer])
        self.assertEqual(len(self.harness.sets()), count)


if __name__ == '__main__':
    unittest.main()
