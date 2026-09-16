import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('migration', Path(__file__).resolve().parents[1] / 'tailmox-migrate.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

CONFIG = '''nodelist {
 node {
  name: pve1
  nodeid: 1
  ring0_addr: 100.64.0.1
 }
 node {
  name: pve2
  nodeid: 2
  ring0_addr: 100.64.0.2
 }
}
totem {
 config_version: 7
 transport: knet
 interface {
  linknumber: 0
 }
}
'''


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / 'corosync.conf'
        self.config.write_text(CONFIG)
        self.migration = m.Migration(self.config)
        self.calls = []
        self.stages = []
        self.bad = None
        self.env = patch.dict(os.environ, {'TAILMOX_MIGRATION_BACKUP_DIR': self.temp.name + '/backups', 'TAILMOX_ASSUME_YES': 'true'})
        self.env.start()
        self.addCleanup(self.env.stop)

    def state(self, text=CONFIG, host='pve1'):
        tree = m.parse(text)
        links = [m.get(i, 'linknumber') for k, i in m.get(tree, 'totem') if k == 'interface']
        version = m.get(m.get(tree, 'totem'), 'config_version')
        local = next(n for n in m.nodes(tree) if m.get(n, 'name') == host)
        return {'config': text, 'localConfig': text, 'host': host,
                'status': f'Quorate: Yes\nConfig Version: {version}\n',
                'links': ''.join(f'LINK ID {i}\n addr = {m.get(local, "ring" + i + "_addr")}\n nodeid 1: localhost\n nodeid 2: connected\n' for i in links),
                'addresses': [{'ifname': 'vmbr0', 'addr_info': [{'family': 'inet', 'local': '10.0.0.1'}]}]}

    def agent(self, host, action, **payload):
        self.calls.append((host, action))
        if self.bad == action:
            raise RuntimeError('mock remote failure')
        if action == 'inspect':
            state = self.state(self.config.read_text(), host)
            state['addresses'][0]['addr_info'][0]['local'] = '10.0.0.' + host[-1]
            return json.dumps(state)
        return ''

    def wait(self, text, links):
        self.assertEqual(self.config.read_text(), text)
        self.stages.append((text, links))
        for host in self.migration.hosts:
            self.assertTrue(self.migration.healthy(self.migration.inspect(host), text, links))

    def execute(self, answer='DISABLE', keep=False, dry=False):
        def confirm(prompt):
            self.assertEqual(self.config.read_text(), CONFIG)
            self.assertEqual(sum(action == 'validate' for _, action in self.calls), 4 if keep else 8)
            return answer
        with patch.object(self.migration, 'agent', side_effect=self.agent), patch.object(self.migration, 'wait', side_effect=self.wait), patch('builtins.input', side_effect=confirm) as consent:
            self.migration.execute('10.0.0.0/24', keep, dry)
            if dry:
                consent.assert_not_called()

    def test_lan_only_stages_and_backups(self):
        self.execute()
        self.assertEqual(len(self.stages), 4)
        self.assertIn('ring0_addr: 100.64.0.1', self.stages[0][0])
        self.assertIn('ring1_addr: 10.0.0.1', self.stages[0][0])
        self.assertNotIn('100.64.', self.config.read_text())
        self.assertNotIn('ring1_addr', self.config.read_text())
        self.assertIn('config_version: 11', self.config.read_text())
        self.assertEqual(len(list(Path(self.temp.name).glob('backups/*/original.conf'))), 1)

    def test_keep_fallback(self):
        self.execute(keep=True)
        self.assertEqual(len(self.stages), 2)
        self.assertIn('ring0_addr: 100.64.0.1', self.config.read_text())

    def test_dry_run_never_writes_or_prompts(self):
        self.execute(dry=True)
        self.assertEqual(self.config.read_text(), CONFIG)
        self.assertFalse(self.stages)
        self.assertFalse((Path(self.temp.name) / 'backups').exists())

    def test_reject_confirmation_even_with_assume_yes(self):
        with self.assertRaises(ValueError):
            self.execute(answer='yes')
        self.assertEqual(self.config.read_text(), CONFIG)

    def test_preflight_failures_never_write(self):
        for action in ('inspect', 'validate', 'ping'):
            self.migration = m.Migration(self.config)
            self.bad = action
            with self.assertRaises(RuntimeError):
                self.execute()
            self.assertEqual(self.config.read_text(), CONFIG)

    def test_failed_live_stage_stops_before_removing_tailscale(self):
        def stop(text, links):
            raise RuntimeError('LAN not connected')
        with patch.object(self, 'wait', side_effect=stop), self.assertRaises(RuntimeError):
            self.execute()
        self.assertIn('ring0_addr: 100.64.0.1', self.config.read_text())
        self.assertIn('config_version: 8', self.config.read_text())

    def test_bad_health_rejected(self):
        for key, value in [('config', ''), ('localConfig', ''), ('status', 'Quorate: No'), ('links', 'LINK ID 0\n nodeid 1: localhost\n')]:
            state = self.state()
            state[key] = value
            self.assertFalse(self.migration.healthy(state, CONFIG, [0]))

    def test_wait_requires_repeated_all_node_health(self):
        self.migration.hosts = {'pve1': '100.64.0.1', 'pve2': '100.64.0.2'}
        with patch.object(self.migration, 'inspect', return_value=self.state()) as inspect, patch.object(m.time, 'sleep'):
            self.migration.wait(CONFIG, [0])
        self.assertEqual(inspect.call_count, 6)

    def test_wait_times_out_on_missing_peer(self):
        self.migration.hosts = {'pve1': '100.64.0.1'}
        state = self.state()
        state['links'] = ''
        with patch.object(self.migration, 'inspect', return_value=state), patch.object(m.time, 'monotonic', side_effect=[0, 91]), self.assertRaises(RuntimeError):
            self.migration.wait(CONFIG, [0])

    def test_missing_or_duplicate_lan_addresses_rejected(self):
        for addresses in ([], [{'ifname': 'vmbr0', 'addr_info': [{'family': 'inet', 'local': '10.0.0.1'}]}]):
            self.migration = m.Migration(self.config)
            state = self.state()
            state['addresses'] = addresses
            with patch.object(self.migration, 'inspect', return_value=state), patch('builtins.input') as consent, self.assertRaises(ValueError):
                self.migration.execute('10.0.0.0/24')
            consent.assert_not_called()
            self.assertEqual(self.config.read_text(), CONFIG)

    def test_agent_uses_stdin_for_configuration(self):
        self.migration.hosts = {'remote-node': '100.64.0.2'}
        with patch.object(m, 'run', return_value='') as run:
            self.migration.agent('remote-node', 'validate', candidate='sensitive-material')
        args, kwargs = run.call_args
        self.assertNotIn('sensitive-material', str(args))
        self.assertIn('sensitive-material', kwargs['input'])

    def test_malformed_and_existing_multilink_rejected(self):
        for original in (CONFIG.replace('config_version: 7', 'config_version: bad'), CONFIG.replace('linknumber: 0', 'linknumber: 1'), CONFIG.replace('transport: knet', 'transport: udp')):
            with self.assertRaises(ValueError):
                m.plan(original, {'pve1': '10.0.0.1', 'pve2': '10.0.0.2'}, False)

    def test_stale_plan_rejected(self):
        def change(prompt):
            self.config.write_text(CONFIG.replace('config_version: 7', 'config_version: 9'))
            return 'DISABLE'
        with patch.object(self.migration, 'agent', side_effect=self.agent), patch('builtins.input', side_effect=change), self.assertRaises(ValueError):
            self.migration.execute('10.0.0.0/24')
        self.assertNotIn('ring1_addr', self.config.read_text())


unittest.main()
