#!/usr/bin/env python3
"""Tests for lib/mod_status.py (Mod Manager date/update columns)."""
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib')
sys.path.insert(0, LIB)
import mod_status  # noqa: E402


class ModStatusTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.serverfiles = os.path.join(self.tmp.name, 'data', 'serverfiles')
        self.workshop = os.path.join(self.serverfiles, 'steamapps', 'workshop', 'content', '221100')
        self.mod = os.path.join(self.workshop, '111')
        os.makedirs(self.mod)
        with open(os.path.join(self.mod, '.first_installed'), 'w') as fp:
            fp.write('1700000000\n')
        self.sync_ts = int(time.time()) - 3600
        os.utime(self.mod, (self.sync_ts, self.sync_ts))

    def tearDown(self):
        self.tmp.cleanup()

    def line(self, mods_info, mod_id='111'):
        return mod_status.status_line(mods_info, [self.workshop], mod_id).split('|')

    def test_up_to_date_but_not_deployed(self):
        ws, sync, inst, has_update, reason = self.line({'111': {'updated': self.sync_ts - 10}})
        self.assertEqual(sync, mod_status.fmt_ts(self.sync_ts))
        self.assertEqual(inst, mod_status.fmt_ts(1700000000))
        self.assertEqual((has_update, reason), ('1', 'D'))

    def test_deployed_link_clears_d(self):
        os.symlink('/dayz/serverfiles/steamapps/workshop/content/221100/111',
                   os.path.join(self.serverfiles, '@111'))   # dangling on the host, like in Docker
        _, _, _, has_update, reason = self.line({'111': {'updated': 0}})
        self.assertEqual((has_update, reason), ('0', ''))

    def test_workshop_newer_marks_update(self):
        os.symlink(self.mod, os.path.join(self.serverfiles, '@111'))
        _, _, _, has_update, reason = self.line({'111': {'updated': self.sync_ts + 500}})
        self.assertEqual((has_update, reason), ('1', 'U'))

    def test_missing_folder(self):
        self.assertEqual(self.line({}, '222'), ['-', '-', '-', '1', 'MD'])

    def test_latest_is_fallback_for_updated(self):
        _, _, _, _, reason = self.line({'111': {'latest': self.sync_ts + 5}})
        self.assertIn('U', reason)

    def test_installed_version_marker_and_ctime_fallback(self):
        os.remove(os.path.join(self.mod, '.first_installed'))
        with open(os.path.join(self.mod, '.installed_version'), 'w') as fp:
            fp.write('1690000000')
        self.assertEqual(self.line({})[2], mod_status.fmt_ts(1690000000))
        with open(os.path.join(self.mod, '.installed_version'), 'w') as fp:
            fp.write('garbage')
        self.assertNotEqual(self.line({})[2], '-')   # ctime fallback

    def test_one_line_per_mod_in_order_even_on_error(self):
        lines = mod_status.status_lines({}, [self.workshop], ['222', '111', '333'])
        self.assertEqual(len(lines), 3)
        self.assertEqual(lines[0], '-|-|-|1|MD')
        self.assertTrue(lines[1].endswith('|1|D'))

    def test_cache_json_errors_are_empty(self):
        self.assertEqual(mod_status.load_mods_info(io.StringIO('not json')), {})
        self.assertEqual(mod_status.load_mods_info(io.StringIO('[1,2]')), {})
        self.assertEqual(mod_status.load_mods_info(io.StringIO('{"mods": {"1": {}}}')), {'1': {}})

    def test_dates(self):
        installed, synced = mod_status.mod_dates(self.mod).split('|')
        self.assertEqual(installed, time.strftime('%d. %b %Y %H:%M', time.localtime(1700000000)))
        self.assertEqual(synced, time.strftime('%d. %b %Y %H:%M', time.localtime(self.sync_ts)))
        self.assertEqual(mod_status.mod_dates(os.path.join(self.workshop, 'nope')), '-|-')
        proc = subprocess.run([sys.executable, os.path.join(LIB, 'mod_status.py'), '--dates', self.mod],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), mod_status.mod_dates(self.mod))

    def test_cli(self):
        cache = json.dumps({'mods': {'111': {'updated': self.sync_ts + 500}}})
        proc = subprocess.run([sys.executable, os.path.join(LIB, 'mod_status.py'),
                               '--workshop-dir', os.path.join(self.tmp.name, 'nope'),
                               '--workshop-dir', self.workshop, '111', '222'],
                              input=cache, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.strip().split('\n')
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].endswith('|1|UD'), lines[0])
        self.assertEqual(lines[1], '-|-|-|1|MD')


if __name__ == '__main__':
    unittest.main()
