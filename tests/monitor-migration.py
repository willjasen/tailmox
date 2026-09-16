import io
import json
import pathlib
import runpy
import sys
import time
import unittest
from unittest.mock import patch

from tailmox_migration_control import MigrationControl, PROMPT

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
            self.assertEqual(request('GET', '/disable')[0], 403)
            status, html = request('GET', '/disable', headers={'Test-User': 'alice'})
            self.assertEqual(status, 200)
            self.assertIn('Run dry run', html)
            self.assertIn('value="disable" selected', html)
            self.assertNotIn('__CSRF_TOKEN__', html)
            self.assertIn('value="disable"', module['INDEX_HTML'])
            self.assertIn('value="disable"', module['SETTINGS_HTML'])
            self.assertEqual(request('POST', '/api/migration/start', {'cidr': '10.0.0.0/24'}, {'Test-User': 'alice'})[0], 403)
            self.assertEqual(request('POST', '/api/migration/decide', {'decision': 'DISABLE'}, {'Test-User': 'alice', 'X-CSRF-Token': module['CSRF_TOKEN']})[0], 409)


unittest.main()
