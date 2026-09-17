import io
import json
import pathlib
import runpy
import sys
import time
import unittest
from unittest.mock import patch

from tailmox_migration_control import MigrationControl, PROMPT, discover_subnets
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
MOCK = "import sys; print('Dry run passed.', flush=True); answer=input(" + repr(PROMPT) + "); print('APPLIED' if answer == 'DISABLE' else 'CANCELLED', flush=True)"


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.control = MigrationControl([sys.executable, '-c', MOCK])
        self.addCleanup(self.cleanup)

    def cleanup(self):
        process = self.control.process
        if process:
            process.terminate()
            process.wait(timeout=5)

    def wait(self, status):
        for _ in range(200):
            state = self.control.snapshot('alice')
            if state['status'] == status and (status == 'awaiting_confirmation' or not self.control.busy()):
                return state
            time.sleep(.01)
        self.fail(str(state))

    def start(self):
        self.control.start('alice', {'cidr': '192.168.1.0/24', 'keepTailscale': True})
        return self.wait('awaiting_confirmation')

    def test_dry_run_then_exact_owner_confirmation(self):
        with self.assertRaises(RuntimeError):
            self.control.decide('alice', {'decision': 'DISABLE'})
        state = self.start()
        self.assertNotIn('APPLIED', state['output'])
        for owner, payload, error in (
            ('bob', {'token': state['token'], 'decision': 'DISABLE'}, RuntimeError),
            ('alice', {'token': 'stale', 'decision': 'DISABLE'}, ValueError),
            ('alice', {'token': state['token'], 'decision': 'yes'}, ValueError),
        ):
            with self.assertRaises(error):
                self.control.decide(owner, payload)
        self.control.decide('alice', {'token': state['token'], 'decision': 'DISABLE'})
        self.assertIn('APPLIED', self.wait('succeeded')['output'])
        with self.assertRaises(RuntimeError):
            self.control.decide('alice', {'token': state['token'], 'decision': 'DISABLE'})

    def test_cancel_and_expire_never_apply(self):
        state = self.start()
        self.control.decide('alice', {'token': state['token'], 'decision': 'cancel'})
        self.assertNotIn('APPLIED', self.wait('cancelled')['output'])
        self.start()
        self.control._expire(self.control.process)
        self.assertNotIn('APPLIED', self.wait('expired')['output'])

    def test_failed_dry_run_never_offers_confirmation(self):
        self.control = MigrationControl([sys.executable, '-c', "print('Validation failed'); raise SystemExit(1)"])
        self.control.start('alice', {'cidr': '192.168.1.0/24'})
        self.assertIsNone(self.wait('failed')['token'])

    def test_bad_input_and_concurrent_start_rejected(self):
        for payload in ({'cidr': 'bad'}, {'cidr': '192.168.1.0/24', 'keepTailscale': 'yes'}):
            with self.assertRaises(ValueError):
                self.control.start('alice', payload)
        self.start()
        with self.assertRaises(RuntimeError):
            self.control.start('alice', {'cidr': '10.0.0.0/24'})


class SubnetTests(unittest.TestCase):
    def test_discovery_normalizes_and_groups_lan_networks(self):
        interfaces = [{'ifname': name, 'addr_info': [{'family': 'inet', 'local': address, 'prefixlen': prefix}]} for name, address, prefix in (
            ('vmbr0', '192.168.1.11', 24), ('eno1', '192.168.1.12', 24),
            ('vmbr1', '10.0.0.2', 16), ('tailscale0', '100.64.0.1', 32),
            ('lo', '127.0.0.1', 8), ('eno2', '169.254.1.1', 16))]
        with patch('tailmox_migration_control.subprocess.run', return_value=subprocess.CompletedProcess([], 0, json.dumps(interfaces))) as run:
            result = discover_subnets()
        self.assertEqual([item['cidr'] for item in result], ['10.0.0.0/16', '192.168.1.0/24'])
        self.assertEqual(len(result[1]['interfaces']), 2)
        self.assertEqual(run.call_args.args[0][:4], ['ip', '-j', '-4', 'addr'])

    def test_failed_and_malformed_scans_allow_manual_fallback(self):
        for value in ('bad json', '{}', '[null]'):
            with patch('tailmox_migration_control.subprocess.run', return_value=subprocess.CompletedProcess([], 0, value)), self.assertRaisesRegex(RuntimeError, 'manually'):
                discover_subnets()
        with patch('tailmox_migration_control.subprocess.run', side_effect=subprocess.TimeoutExpired(['ip'], 10)), self.assertRaises(RuntimeError):
            discover_subnets()
        with patch('tailmox_migration_control.subprocess.run', return_value=subprocess.CompletedProcess([], 0, '[]')):
            self.assertEqual(discover_subnets(), [])


class HttpTests(unittest.TestCase):
    def test_page_navigation_authentication_and_csrf(self):
        module = runpy.run_path(str(ROOT / 'tailmox-monitor.py'))
        handler = module['Handler']
        globals_ = handler.do_POST.__globals__
        with patch.dict(globals_, {'request_identity': lambda headers: headers.get('Test-User')}):
            def request(method, path, payload=None, headers=None):
                instance = handler.__new__(handler)
                instance.path = path
                instance.headers = dict(headers or {})
                body = json.dumps(payload).encode() if payload is not None else b''
                instance.headers['Content-Length'] = str(len(body))
                instance.rfile = io.BytesIO(body)
                responses = []
                instance.send_body = lambda status, kind, body, *args: responses.append((status, body))
                getattr(instance, 'do_' + method)()
                return responses[0]
            self.assertEqual(request('GET', '/')[0], 403)
            self.assertEqual(request('GET', '/', headers={
                'Test-User': 'alice', 'CF-Connecting-IP': '203.0.113.9'
            })[0], 403)
            self.assertEqual(request('GET', '/settings', headers={
                'Test-User': 'alice', 'CF-Ray': 'test'
            })[0], 403)
            self.assertEqual(request('GET', '/disable')[0], 403)
            self.assertEqual(request('GET', '/api/migration/subnets')[0], 403)
            with patch.dict(globals_, {'discover_subnets': lambda: [{'cidr': '10.0.0.0/24', 'interfaces': []}]}):
                code, body = request('GET', '/api/migration/subnets', headers={'Test-User': 'alice'})
                self.assertEqual(code, 200)
                self.assertEqual(json.loads(body)['subnets'][0]['cidr'], '10.0.0.0/24')
            status, html = request('GET', '/disable', headers={'Test-User': 'alice'})
            self.assertEqual(status, 200)
            self.assertIn('Run dry run', html)
            self.assertIn('value="disable" selected', html)
            self.assertNotIn('__CSRF_TOKEN__', html)
            self.assertNotIn('__MONITOR_FORM_STYLE__', html)
            self.assertIn(module['MONITOR_FORM_STYLE'], html)
            self.assertIn(module['MONITOR_FORM_STYLE'], module['SETTINGS_HTML'])
            self.assertIn('class="page-picker"', html)
            self.assertIn('.page-picker select option { color: #f8fafc; background: #0f172a;', html)
            self.assertIn('value="health"', html)
            for element in ('<a ', '<button', '<select', '<input', '<form'):
                self.assertNotIn(element, module['INDEX_HTML'])
            self.assertIn('select option{color:#f8fafc;background:#0f172a;', module['HEALTH_HTML'])
            self.assertIn('value="disable"', module['SETTINGS_HTML'])
            self.assertEqual(request('POST', '/api/migration/start', {'cidr': '10.0.0.0/24'}, {'Test-User': 'alice'})[0], 403)
            self.assertEqual(request('POST', '/api/migration/decide', {'decision': 'DISABLE'}, {'Test-User': 'alice', 'X-CSRF-Token': module['CSRF_TOKEN']})[0], 409)


unittest.main()
