#!/usr/bin/env python3
"""Staged Corosync LAN migration; no live writes before validation and consent."""
import argparse
import copy
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile
import time


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=45, **kwargs).stdout


def parse(text):
    root, stack = [], []
    current = root
    for raw in text.splitlines():
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        if re.fullmatch(r'\w+\s*\{', line):
            child = []
            current.append((line[:-1].strip(), child))
            stack.append(current)
            current = child
        elif line == '}' and stack:
            current = stack.pop()
        elif re.fullmatch(r'\w+\s*:\s*[^{}]+', line):
            key, value = line.split(':', 1)
            current.append((key.strip(), value.strip()))
        else:
            raise ValueError('Unsupported Corosync configuration syntax')
    if stack:
        raise ValueError('Unclosed Corosync section')
    return root


def get(items, name, default=None):
    values = [v for k, v in items if k == name]
    if len(values) > 1:
        raise ValueError('Duplicate setting: ' + name)
    return values[0] if values else default


def put(items, name, value):
    items[:] = [(k, v) for k, v in items if k != name]
    items.append((name, value))


def render(items, indent=''):
    return ''.join(indent + k + (' {\n' + render(v, indent + '  ') + indent + '}\n'
                                if isinstance(v, list) else ': ' + str(v) + '\n')
                   for k, v in items)


def nodes(tree):
    return [v for k, v in get(tree, 'nodelist', []) if k == 'node']


def plan(original, addresses, keep):
    tree = parse(original)
    totem = get(tree, 'totem')
    if not totem or get(totem, 'transport', 'knet') != 'knet':
        raise ValueError('Migration requires KNET transport')
    if get(totem, 'link_mode', 'passive') != 'passive':
        raise ValueError('Migration requires passive link mode')
    interfaces = [v for k, v in totem if k == 'interface']
    if any(get(v, 'linknumber') != '0' for v in interfaces) or len(interfaces) > 1:
        raise ValueError('Existing multiple links require manual review; no changes made')
    if any(any(re.fullmatch(r'ring[1-7]_addr', k) for k, _ in n) for n in nodes(tree)):
        raise ValueError('Existing additional links require manual review')
    version = int(get(totem, 'config_version'))
    base = copy.deepcopy(interfaces[0]) if interfaces else [('linknumber', '0')]
    # Preserve link 0 transport settings and use explicit priorities at every stage.
    def interfaces_for(p0, p1):
        first = copy.deepcopy(base)
        put(first, 'knet_link_priority', str(p0))
        totem[:] = [(k, v) for k, v in totem if k != 'interface']
        totem.append(('interface', first))
        if p1 is not None:
            totem.append(('interface', [('linknumber', '1'), ('knet_link_priority', str(p1))]))

    result = []
    def snapshot(label, links):
        put(totem, 'config_version', str(version + len(result) + 1))
        result.append((label, render(tree), links))

    for node in nodes(tree):
        put(node, 'ring1_addr', addresses[get(node, 'name')])
    interfaces_for(20, 10)
    snapshot('Add LAN link; retain Tailscale preference', [0, 1])
    interfaces_for(10, 20)
    snapshot('Prefer LAN; retain Tailscale fallback', [0, 1])
    if not keep:
        for node in nodes(tree):
            put(node, 'ring0_addr', addresses[get(node, 'name')])
        snapshot('Move link 0 to LAN while LAN link 1 remains active', [0, 1])
        for node in nodes(tree):
            node[:] = [(k, v) for k, v in node if k != 'ring1_addr']
        interfaces_for(20, None)
        snapshot('Remove temporary LAN link 1', [0])
    return result


# Executed on each node over its existing management address. Paths and payloads
# are JSON, never interpolated into remote shell commands.
AGENT = r'''
import json, subprocess, sys, tempfile, os
p = json.load(sys.stdin)
def run(args):
    return subprocess.check_output(args, text=True, timeout=20)
if p['action'] == 'inspect':
    result = {'config': open(p['config']).read(),
              'localConfig': open(p['localConfig']).read(),
              'status': run(['pvecm', 'status']),
              'links': run(['corosync-cfgtool', '-s']),
              'addresses': json.loads(run(['ip', '-j', '-4', 'addr', 'show', 'scope', 'global']))}
    print(json.dumps(result))
elif p['action'] == 'validate':
    with tempfile.NamedTemporaryFile(mode='w', suffix='.conf') as f:
        f.write(p['candidate']); f.flush()
        run(['corosync', '-t', '-c', f.name])
elif p['action'] == 'ping':
    for address in p['peers']:
        run(['ping', '-n', '-I', p['source'], '-c', '2', '-W', '2', address])
'''


class Migration:
    def __init__(self, config):
        self.config = config
        self.local_config = os.environ.get('TAILMOX_LOCAL_COROSYNC_CONFIG', '/etc/corosync/corosync.conf')
        self.hosts = {}

    def agent(self, host, action, **payload):
        payload.update(action=action, config=str(self.config), localConfig=self.local_config)
        args = ['python3', '-c', AGENT]
        if host not in (socket.gethostname(), socket.gethostname().split('.')[0]):
            args = ['ssh', '-oBatchMode=yes', '-oConnectTimeout=10', self.hosts[host], shlex.join(args)]
        return run(args, input=json.dumps(payload))

    def inspect(self, host):
        state = json.loads(self.agent(host, 'inspect'))
        state['host'] = host
        return state

    def healthy(self, state, expected, links):
        tree = parse(expected)
        ids = {int(get(n, 'nodeid')) for n in nodes(tree)}
        if parse(state['config']) != tree or parse(state['localConfig']) != tree:
            return False
        if not re.search(r'^Quorate:\s+Yes\s*$', state['status'], re.M):
            return False
        version = get(get(tree, 'totem'), 'config_version')
        if not re.search(r'^Config Version:\s+' + re.escape(version) + r'\s*$', state['status'], re.M):
            return False
        sections = re.split(r'LINK ID\s+(\d+)', state['links'])
        observed = dict(zip(sections[1::2], sections[2::2]))
        local_nodes = [n for n in nodes(tree) if get(n, 'name') == state.get('host')]
        if len(local_nodes) != 1:
            return False
        for link in links:
            section = observed.get(str(link), '')
            address = re.search(r'addr\s*=\s*(\S+)', section)
            if not address or address[1] != get(local_nodes[0], f'ring{link}_addr'):
                return False
            peers = dict(re.findall(r'nodeid\s+(\d+):\s+(\w+)', section))
            if {int(i) for i in peers} != ids or any(v not in ('localhost', 'connected') for v in peers.values()):
                return False
        return True

    def wait(self, expected, links):
        deadline = time.monotonic() + 90
        consecutive = 0
        while True:
            try:
                if all(self.healthy(self.inspect(h), expected, links) for h in self.hosts):
                    consecutive += 1
                    if consecutive >= 3:
                        return
                else:
                    consecutive = 0
            except (ValueError, subprocess.SubprocessError):
                consecutive = 0
            if time.monotonic() >= deadline:
                raise RuntimeError('Not all nodes verified the stage. Stopped; preserve current links and inspect every node before recovery.')
            time.sleep(2)

    def execute(self, cidr, keep=False, dry_only=False):
        network = ipaddress.IPv4Network(cidr, strict=True)
        original = self.config.read_text()
        tree = parse(original)
        members = nodes(tree)
        if len(members) < 2:
            raise ValueError('Migration requires at least two online cluster members')
        ids = [int(get(node, 'nodeid')) for node in members]
        if len(set(ids)) != len(ids) or any(i <= 0 for i in ids):
            raise ValueError('Invalid or duplicate node IDs')
        for node in members:
            name, address = get(node, 'name'), get(node, 'ring0_addr')
            if not name or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name) or name in self.hosts:
                raise ValueError('Invalid or duplicate node name')
            self.hosts[name] = str(ipaddress.IPv4Address(address))
        addresses = {}
        for host in self.hosts:
            state = self.inspect(host)
            if not self.healthy(state, original, [0]):
                raise ValueError('Cluster configuration, membership or link health differs on ' + host)
            matches = {a['local'] for interface in state['addresses']
                       if interface.get('ifname') != 'tailscale0'
                       for a in interface.get('addr_info', [])
                       if a.get('family') == 'inet' and ipaddress.IPv4Address(a['local']) in network}
            if len(matches) != 1:
                raise ValueError('Expected exactly one LAN address on ' + host)
            addresses[host] = matches.pop()
        if len(set(addresses.values())) != len(addresses):
            raise ValueError('Duplicate LAN addresses')
        if any(addresses[h] == self.hosts[h] for h in self.hosts):
            raise ValueError('LAN and existing link addresses must differ on every node')
        stages = plan(original, addresses, keep)
        for host in self.hosts:
            self.agent(host, 'ping', source=addresses[host], peers=list(addresses.values()))
            for _, candidate, _ in stages:
                self.agent(host, 'validate', candidate=candidate)
        print('Dry run passed. Planned LAN addresses:', flush=True)
        for host, address in addresses.items():
            print(f'  {host}: {self.hosts[host]} -> {address}', flush=True)
        for label, _, _ in stages:
            print('  ' + label, flush=True)
        if dry_only:
            return
        print('WARNING: this changes cluster networking. A failure can lose quorum and trigger HA recovery. '
              'Keep console access available. Validation cannot prove live LAN links until they are added.', flush=True)
        if input('Type DISABLE to apply this dry-run plan: ') != 'DISABLE':
            raise ValueError('Aborted. No changes made.')
        # Consent never bypasses a changed baseline or a newly unhealthy member.
        for host in self.hosts:
            if not self.healthy(self.inspect(host), original, [0]):
                raise ValueError('Cluster changed after dry run; run again')
        backup_dir = Path(os.environ.get('TAILMOX_MIGRATION_BACKUP_DIR', '/var/lib/tailmox/migrations'))
        backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        backup = Path(tempfile.mkdtemp(prefix='lan-', dir=backup_dir))
        (backup / 'original.conf').write_text(original)
        print('Recovery configurations: ' + str(backup), flush=True)
        previous = original
        for index, (label, candidate, links) in enumerate(stages):
            if self.config.read_text() != previous:
                raise ValueError('Concurrent configuration change; stopped')
            (backup / f'stage-{index + 1}.conf').write_text(candidate)
            # pmxcfs supports rename of a regular file within its filesystem.
            pending = Path(str(self.config) + '.tailmox-new')
            try:
                with pending.open('x') as output:
                    output.write(candidate)
            except FileExistsError:
                raise ValueError('Pending migration file exists; inspect it first')
            try:
                if self.config.read_text() != previous:
                    raise ValueError('Concurrent configuration change; stopped')
                os.replace(pending, self.config)
            finally:
                pending.unlink(missing_ok=True)
            print(label, flush=True)
            self.wait(candidate, links)
            previous = candidate
        print('Verified on every node: ' + ('LAN preferred, Tailscale fallback retained.' if keep else 'LAN-only Corosync.'), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('cidr', nargs='?')
    parser.add_argument('--keep-tailscale', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    config = Path(os.environ.get('TAILMOX_COROSYNC_CONFIG', os.environ.get('TAILMOX_PVE_CONFIG_DIR', '/etc/pve') + '/corosync.conf'))
    try:
        cidr = args.cidr or input('LAN CIDR: ').strip()
        keep = args.keep_tailscale
        if not args.cidr:
            choice = input('Retain Tailscale as fallback? [y/N]: ').strip().lower()
            if choice not in ('', 'n', 'no', 'y', 'yes'):
                raise ValueError('Expected yes or no')
            keep = choice in ('y', 'yes')
        lock_path = os.environ.get('TAILMOX_MIGRATION_LOCK', '/run/lock/tailmox-migration.lock')
        with open(lock_path, 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            Migration(config).execute(cidr, keep, args.dry_run)
    except subprocess.SubprocessError:
        # Command arguments may contain the candidate's authentication material.
        print('Migration stopped: a node command failed or timed out. Check node connectivity and Corosync logs.', flush=True)
        return 1
    except (OSError, ValueError, RuntimeError, EOFError) as exc:
        print('Migration stopped: ' + str(exc), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
