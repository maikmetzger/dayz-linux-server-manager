#!/usr/bin/env python3
"""Regression tests for lib/config_parser.py (serverDZ.cfg / BEServer parsers)."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib'))
import config_parser  # noqa: E402


class CfgFormatValueTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, 'serverDZ.cfg')
        with open(self.path, 'w', encoding='utf-8') as f:
            f.write('hostname = "Old Name";\nmaxPlayers = 60;\nenableDebug = 0;\n')
        self.cfg = config_parser.CfgParser(self.path)

    def _line(self, key):
        with open(self.path, encoding='utf-8') as f:
            return next(l.strip() for l in f if l.startswith(key))

    def test_dashed_text_is_quoted(self):
        self.cfg.set('maxPlayers', '1-2-3')
        self.assertEqual(self._line('maxPlayers'), 'maxPlayers = "1-2-3";')

    def test_word_without_spaces_is_quoted(self):
        self.cfg.set('maxPlayers', 'MyServer')
        self.assertEqual(self._line('maxPlayers'), 'maxPlayers = "MyServer";')

    def test_numbers_stay_bare(self):
        self.cfg.set('maxPlayers', '42')
        self.assertEqual(self._line('maxPlayers'), 'maxPlayers = 42;')
        self.cfg.set('maxPlayers', '-1.5')
        self.assertEqual(self._line('maxPlayers'), 'maxPlayers = -1.5;')

    def test_booleans_stay_bare(self):
        self.cfg.set('enableDebug', 'true')
        self.assertEqual(self._line('enableDebug'), 'enableDebug = true;')

    def test_quoted_original_stays_quoted(self):
        self.cfg.set('hostname', '12')
        self.assertEqual(self._line('hostname'), 'hostname = "12";')


class BEServerSetTest(unittest.TestCase):
    def test_set_replaces_or_appends_verbatim(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, 'BEServer_x64.cfg')
        with open(path, 'w', encoding='utf-8') as f:
            f.write('RConPassword old\n')
        be = config_parser.BEServerParser(path)
        be.set('RConPassword', 'a/b&c\\d')
        be.set('RConPort', '2305')
        with open(path, encoding='utf-8') as f:
            self.assertEqual(f.read(), 'RConPassword a/b&c\\d\nRConPort 2305\n')


if __name__ == '__main__':
    unittest.main()
