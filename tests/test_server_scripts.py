"""Run real scripts with temporary filesystem paths and fake service commands.

Linux only: GNU utilities, root ownership and /proc match the target VPS.
Never execute against host /etc or /root; every writable absolute path is remapped.
"""
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'linux' and os.geteuid() == 0,
                     'run inside the documented disposable Linux container')
class ServerScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f'{self.bin}:' + os.environ['PATH'])
        for name, body in {'xray': 'exit 0', 'sleep': 'exit 0',
                           'ss': "echo 'LISTEN 0 128 127.0.0.1:443 0.0.0.0:*'; echo 'LISTEN 0 128 127.0.0.1:10085 0.0.0.0:*'"}.items():
            self.fake(name, body)
        self.cfg = self.root / 'usr/local/etc/xray/config.json'
        self.cfg.parent.mkdir(parents=True)
        self.original = {'inbounds': [{'protocol': 'vless', 'settings': {'clients': [
            {'id': 'test-only-id', 'email': 'original', 'flow': 'xtls-rprx-vision'}]}}],
            'routing': {'rules': []}}
        self.cfg.write_text(json.dumps(self.original))
        (self.root / 'var/lib/vpn-usage').mkdir(parents=True)
        (self.root / 'run/lock').mkdir(parents=True)

    def fake(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_script(self, name, *args):
        content = (ROOT / 'scripts' / name).read_text()
        content = re.sub(r'(?<![\w/])/(?:usr/local|var/lib|var/www|root|etc|run|tmp)/',
                         lambda m: str(self.root) + m.group(), content)
        (self.root / 'tmp').mkdir(exist_ok=True)
        script = self.root / name
        script.write_text(content)
        return subprocess.run(['bash', str(script), *args], env=self.env,
                              capture_output=True, text=True, timeout=15)

    def fail_first_restart(self):
        marker = self.root / 'restart-failed'
        self.fake('systemctl', f'''if [ "$1" = restart ] && [ ! -e '{marker}' ]; then
  touch '{marker}'
  exit 1
fi
exit 0''')

    def test_vpnctl_restores_config_when_restart_command_fails(self):
        self.fail_first_restart()
        result = self.run_script('vpnctl.sh', 'adduser', 'new-user')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.cfg.read_text()), self.original)
        self.assertIn('откат', result.stderr.lower())

    def test_stats_restores_config_when_restart_command_fails(self):
        self.fail_first_restart()
        result = self.run_script('enable-xray-stats.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.cfg.read_text()), self.original)

    def test_stats_accepts_config_without_routing(self):
        del self.original['routing']
        self.cfg.write_text(json.dumps(self.original))
        self.fake('systemctl', 'exit 0')
        result = self.run_script('enable-xray-stats.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.cfg.read_text())['routing']['rules'][0]['inboundTag'], ['api'])

    def test_failed_archive_is_not_reported_or_retained(self):
        self.fake('tar', 'touch "$2"; exit 2')
        result = self.run_script('backup-config.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('✅', result.stdout)
        self.assertEqual(list((self.root / 'root/backups').glob('*.tar.gz')), [])

    def test_archive_is_private_and_contains_config(self):
        result = self.run_script('backup-config.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        archives = list((self.root / 'root/backups').glob('*.tar.gz'))
        self.assertEqual(len(archives), 1)
        self.assertEqual(archives[0].stat().st_mode & 0o777, 0o600)
        listing = subprocess.check_output(['tar', 'tzf', str(archives[0])], text=True)
        self.assertIn('config.json', listing)

    def test_traffic_report_honors_bot_configuration(self):
        import datetime
        now = datetime.datetime.now(datetime.timezone.utc)
        payload = {'interfaces': [{'name': 'ens3', 'traffic': {'month': [
            {'date': {'year': now.year, 'month': now.month}, 'tx': 107374182400}]}}]}
        self.fake('vnstat', "cat <<'EOF'\n" + json.dumps(payload) + "\nEOF")
        self.env.update(IFACE='ens3', QUOTA_GIB='200', SERVER_LABEL='Test Server')
        result = self.run_script('vpn-traffic-alert.sh', '--dry')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('100.0 / 200 ГиБ (50.0%)', result.stdout)
        self.assertIn('Test Server', result.stdout)
