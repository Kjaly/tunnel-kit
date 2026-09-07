import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load_bot():
    spec = importlib.util.spec_from_file_location('vpnbot', ROOT / 'scripts/vpnbot.py')
    module = importlib.util.module_from_spec(spec)
    with patch('builtins.open', side_effect=FileNotFoundError), contextlib.redirect_stdout(io.StringIO()):
        try:
            spec.loader.exec_module(module)
        except SystemExit:
            raise AssertionError('Import must not require a live bot token')
    return module


class BotTests(unittest.TestCase):
    def test_import_does_not_require_credentials(self):
        self.assertTrue(callable(load_bot().main))

    def test_unauthorized_chat_cannot_restart(self):
        bot = load_bot()
        bot.ALLOWED_CHAT_IDS = {123}
        with patch.object(bot, 'run_vpnctl', side_effect=AssertionError('unauthorized operation')):
            bot.handle_callback({'message': {'chat': {'id': 999}, 'message_id': 1},
                                 'id': 'test', 'data': 'confirm:restart'})

    def test_qr_stays_private_and_is_removed(self):
        bot = load_bot()
        sent_paths = []

        def encode(command, **kwargs):
            path = Path(command[command.index('-o') + 1])
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            path.write_bytes(b'test-qr')
            return subprocess.CompletedProcess(command, 0)

        def receive(chat_id, path, caption):
            sent_paths.append(Path(path))
            self.assertEqual(Path(path).read_bytes(), b'test-qr')

        with patch.object(bot, 'build_vless_link', return_value='test-link'), \
             patch.object(bot, 'chat_action'), patch.object(bot.shutil, 'which', return_value='/bin/qrencode'), \
             patch.object(bot.subprocess, 'run', side_effect=encode), \
             patch.object(bot, 'send_photo_file', side_effect=receive), \
             patch.object(bot, 'send_message', side_effect=AssertionError('QR failed')):
            bot.cmd_qr(123, ['test-user'])
        self.assertEqual(len(sent_paths), 1)
        self.assertFalse(sent_paths[0].exists())
        self.assertFalse(sent_paths[0].parent.exists())

    def test_old_and_new_xray_public_key_labels(self):
        bot = load_bot()
        bot.SERVER_IP = '192.0.2.1'
        cfg = {'inbounds': [{'protocol': 'vless', 'settings': {'clients': [
            {'email': 'test', 'id': 'test-id'}]}, 'streamSettings': {'realitySettings': {
                'serverNames': ['example.com'], 'shortIds': ['test'], 'privateKey': 'test-key'}}}]}
        for label in ('Password (PublicKey)', 'Password', 'Public key'):
            with self.subTest(label=label), tempfile.NamedTemporaryFile(mode='w+') as f:
                import json
                json.dump(cfg, f)
                f.flush()
                bot.CFG = f.name
                with patch.object(bot.subprocess, 'run', return_value=subprocess.CompletedProcess(
                        [], 0, stdout=f'{label}: test-public-key\n')):
                    self.assertIn('pbk=test-public-key', bot.build_vless_link('test') or '')

    def test_key_generation_failure_does_not_log_private_key(self):
        bot = load_bot()
        cfg = {'inbounds': [{'protocol': 'vless', 'settings': {'clients': [
            {'email': 'test', 'id': 'test-id'}]}, 'streamSettings': {'realitySettings': {
                'serverNames': ['example.com'], 'shortIds': ['test'], 'privateKey': 'confidential-test-key'}}}]}
        import json
        with tempfile.NamedTemporaryFile(mode='w+') as f:
            json.dump(cfg, f)
            f.flush()
            bot.CFG = f.name
            output = io.StringIO()
            error = subprocess.TimeoutExpired(['xray', 'x25519', '-i', 'confidential-test-key'], 10)
            with patch.object(bot.subprocess, 'run', side_effect=error), contextlib.redirect_stdout(output):
                self.assertIsNone(bot.build_vless_link('test'))
            self.assertNotIn('confidential-test-key', output.getvalue())
