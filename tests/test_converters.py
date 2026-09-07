import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


sr = load_script('shadowrocket-to-xray')
wg = load_script('wg-conf-to-routes')


class ConverterTests(unittest.TestCase):
    def run_cli(self, script, content, *args):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'input.conf'
            path.write_text(content)
            return subprocess.run([sys.executable, str(ROOT / 'scripts' / script), str(path), *args],
                                  capture_output=True, text=True)

    def test_proxy_and_reject_policies_cannot_become_direct(self):
        result = self.run_cli('shadowrocket-to-xray.py',
                             'DOMAIN,private.example,PROXY\nDOMAIN,ads.example,REJECT\n', '--strict-json')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_full_config_is_rejected_instead_of_losing_rule_order(self):
        result = self.run_cli('shadowrocket-to-xray.py',
                             '[Rule]\nDOMAIN,private.example,PROXY\nDOMAIN-SUFFIX,example,DIRECT\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_direct_list_and_geo_database(self):
        result = self.run_cli('shadowrocket-to-xray.py',
                             'DOMAIN,Example.COM,DIRECT\nDOMAIN,example.com\nGEOIP,RU\n', '--strict-json')
        self.assertEqual(result.returncode, 0, result.stderr)
        rules = json.loads(result.stdout)['routing']['rules']
        self.assertEqual(rules[0]['ip'], ['ext:geoip_v2fly.dat:private'])
        self.assertEqual(rules[1]['domain'], ['full:example.com'])
        self.assertEqual(rules[2]['ip'], ['ext:geoip_v2fly.dat:ru'])
        self.assertEqual(rules[-1]['outboundTag'], 'proxy')

    def test_wireguard_machine_output_does_not_expose_metadata(self):
        result = self.run_cli('wg-conf-to-routes.py',
                             '[Interface]\nDNS = 10.9.0.1\n[Peer]\n'
                             'Endpoint = confidential.example:51820\nAllowedIPs = 10.9.0.0/24\n',
                             '--format', 'bat')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('confidential.example', result.stdout)
        self.assertNotIn('#', result.stdout)
        self.assertIn('route ADD 10.9.0.0 MASK 255.255.255.0 0.0.0.0', result.stdout)

    def test_wireguard_ipv6_does_not_generate_invalid_ipv4_commands(self):
        result = self.run_cli('wg-conf-to-routes.py', '[Peer]\nAllowedIPs = fd00::/64\n', '--format', 'cli')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_wireguard_collision_is_reported(self):
        result = self.run_cli('wg-conf-to-routes.py', '[Peer]\nAllowedIPs = 192.168.1.20/32\n', '--format', 'xkeen')
        self.assertEqual(result.returncode, 2)
        self.assertIn('пересечение', result.stderr)


if __name__ == '__main__':
    unittest.main()
