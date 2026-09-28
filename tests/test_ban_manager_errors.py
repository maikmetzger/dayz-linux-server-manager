#!/usr/bin/env python3
"""Regression tests: ban_manager must not report success when it did not write."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib')
sys.path.insert(0, LIB)
import ban_manager  # noqa: E402

CLI = os.path.join(LIB, 'ban_manager.py')


def run_cli(*args):
    p = subprocess.run([sys.executable, CLI, *args], capture_output=True, text=True)
    return p.returncode, (json.loads(p.stdout) if p.stdout.strip() else None), p.stderr


class DurationTest(unittest.TestCase):
    def test_garbage_is_rejected(self):
        for bad in ('garbage', '30', '1w', '1.5h', '0m', '-5m', '2xh'):
            with self.assertRaises(ValueError, msg=bad):
                ban_manager.parse_duration(bad)

    def test_valid_forms(self):
        self.assertEqual(ban_manager.parse_duration('30M')['minutes'], 30)
        self.assertEqual(ban_manager.parse_duration('2h')['minutes'], 120)
        self.assertEqual(ban_manager.parse_duration('7d')['minutes'], 10080)
        self.assertEqual(ban_manager.parse_duration('perm')['minutes'], -1)

    def test_cli_reports_invalid_duration(self):
        d = tempfile.mkdtemp()
        rc, out, _ = run_cli('--file', os.path.join(d, 'bans.json'), 'add', '--guid', 'g', '--name', 'n', '--duration', 'garbage')
        self.assertEqual(rc, 1)
        self.assertFalse(out['success'])
        self.assertFalse(os.path.exists(os.path.join(d, 'bans.json')))


class SaveFailureTest(unittest.TestCase):
    def test_unwritable_target_is_reported(self):
        d = tempfile.mkdtemp()
        target = os.path.join(d, 'bans.json')
        os.mkdir(target)  # a directory where the file should be: open() fails
        rc, out, _ = run_cli('--file', target, 'add', '--guid', 'g', '--name', 'n', '--duration', '30m')
        self.assertEqual(rc, 1)
        self.assertFalse(out['success'])
        self.assertIn('error', out)

    def test_corrupt_file_is_not_overwritten(self):
        d = tempfile.mkdtemp()
        target = os.path.join(d, 'bans.json')
        with open(target, 'w') as f:
            f.write('{"bans": [{"guid": "keepme"}], oops')
        rc, out, _ = run_cli('--file', target, 'add', '--guid', 'g', '--name', 'n', '--duration', '30m')
        self.assertEqual(rc, 1)
        self.assertFalse(out['success'])
        with open(target) as f:
            self.assertIn('keepme', f.read())

    def test_wrong_shape_is_not_overwritten(self):
        d = tempfile.mkdtemp()
        target = os.path.join(d, 'bans.json')
        with open(target, 'w') as f:
            f.write('[]')
        rc, out, _ = run_cli('--file', target, 'add', '--guid', 'g', '--name', 'n', '--duration', '30m')
        self.assertEqual(rc, 1)
        with open(target) as f:
            self.assertEqual(f.read(), '[]')

    def test_success_path_still_works(self):
        d = tempfile.mkdtemp()
        target = os.path.join(d, 'sub', 'bans.json')
        rc, out, _ = run_cli('--file', target, 'add', '--guid', 'abc', '--name', 'Al "Quote"', '--duration', '2h')
        self.assertEqual(rc, 0)
        self.assertTrue(out['success'])
        with open(target) as f:
            self.assertEqual(json.load(f)['bans'][0]['name'], 'Al "Quote"')


if __name__ == '__main__':
    unittest.main()
