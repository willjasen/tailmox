"""Keep the validated migration process alive while its owner reviews the plan."""
import ipaddress
import json
import pathlib
import secrets
import subprocess
import sys
import threading


PROMPT = 'Type DISABLE to apply this dry-run plan: '
BUSY = ('running', 'awaiting_confirmation', 'applying')


def discover_subnets():
    """Read locally assigned LAN networks without probing or changing interfaces."""
    try:
        result = subprocess.run(['ip', '-j', '-4', 'addr', 'show', 'scope', 'global'],
                                check=True, capture_output=True, text=True, timeout=10)
        interfaces = json.loads(result.stdout)
        if not isinstance(interfaces, list):
            raise ValueError('Expected interface list')
        networks = {}
        for interface in interfaces:
            name = interface['ifname']
            if name == 'lo' or name.startswith('tailscale'):
                continue
            for address in interface.get('addr_info', []):
                if address.get('family') != 'inet':
                    continue
                assigned = ipaddress.IPv4Interface(f"{address['local']}/{address['prefixlen']}")
                if assigned.ip.is_loopback or assigned.ip.is_link_local or assigned.ip.is_unspecified:
                    continue
                cidr = str(assigned.network)
                entry = networks.setdefault(cidr, {'cidr': cidr, 'interfaces': []})
                attachment = {'name': name, 'address': str(assigned.ip)}
                if attachment not in entry['interfaces']:
                    entry['interfaces'].append(attachment)
        return sorted(networks.values(), key=lambda item: (int(ipaddress.IPv4Network(item['cidr']).network_address), ipaddress.IPv4Network(item['cidr']).prefixlen))
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise RuntimeError('Unable to read host IPv4 subnets. You can enter a subnet manually.') from error


class MigrationControl:
    def __init__(self, command=None):
        self.command = command or [sys.executable, str(pathlib.Path(__file__).with_name('tailmox-migrate.py'))]
        self.lock = threading.Lock()
        self.process = None
        self.owner = None
        self.state = {'status': 'idle', 'output': '', 'token': None}

    def busy(self):
        with self.lock:
            return self.state['status'] in BUSY or self.process is not None

    def snapshot(self, owner):
        with self.lock:
            if self.owner and self.owner != owner:
                raise RuntimeError('Another user owns this migration.')
            return dict(self.state)

    def start(self, owner, payload):
        cidr = str(ipaddress.IPv4Network(payload.get('cidr', ''), strict=True))
        keep = payload.get('keepTailscale', False)
        if not isinstance(keep, bool):
            raise ValueError('The fallback choice must be true or false.')
        with self.lock:
            if self.state['status'] in BUSY or self.process is not None:
                raise RuntimeError('A migration is already running.')
            self.owner = owner
            self.state = {'status': 'running', 'output': '', 'token': None,
                          'cidr': cidr, 'keepTailscale': keep}
            args = [*self.command, cidr]
            if keep:
                args.append('--keep-tailscale')
            try:
                self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                                stderr=subprocess.STDOUT, text=True, bufsize=1)
            except OSError:
                self.process = None
                self.state.update(status='failed', output='Unable to start migration.')
                raise RuntimeError('Unable to start migration.')
            process = self.process
        threading.Thread(target=self._read, args=(process,), daemon=True).start()
        return self.snapshot(owner)

    def _expire(self, process):
        with self.lock:
            if self.process is process and self.state['status'] == 'awaiting_confirmation':
                self.state.update(status='expired', token=None)
                process.terminate()

    def _read(self, process):
        timer = None
        try:
            while True:
                char = process.stdout.read(1)
                if not char:
                    break
                with self.lock:
                    self.state['output'] = (self.state['output'] + char)[-100000:]
                    if self.state['status'] == 'running' and self.state['output'].endswith(PROMPT):
                        self.state.update(status='awaiting_confirmation', token=secrets.token_urlsafe(32))
                        timer = threading.Timer(600, self._expire, args=(process,))
                        timer.daemon = True
                        timer.start()
            code = process.wait()
            with self.lock:
                if self.state['status'] not in ('expired', 'cancelled'):
                    self.state['status'] = 'succeeded' if code == 0 else 'failed'
                self.state.update(exitCode=code, token=None)
                self.process = None
        finally:
            if timer:
                timer.cancel()
            process.stdout.close()
            process.stdin.close()

    def decide(self, owner, payload):
        with self.lock:
            if self.owner != owner or self.state['status'] != 'awaiting_confirmation':
                raise RuntimeError('No validated migration is waiting for your confirmation.')
            token = payload.get('token')
            if not isinstance(token, str) or not secrets.compare_digest(token, self.state['token']):
                raise ValueError('This dry-run plan is no longer valid.')
            decision = payload.get('decision')
            if decision not in ('DISABLE', 'cancel'):
                raise ValueError('Type DISABLE to confirm.')
            try:
                self.process.stdin.write('DISABLE\n' if decision == 'DISABLE' else 'cancel\n')
                self.process.stdin.flush()
            except (OSError, ValueError):
                self.state.update(status='failed', token=None)
                raise RuntimeError('Migration process exited; run the dry run again.')
            self.state.update(status='applying' if decision == 'DISABLE' else 'cancelled', token=None)
        return self.snapshot(owner)
