#!/usr/bin/env python3
"""Regression tests for lib/fileutil.py (atomic writes)."""
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib'))
import fileutil  # noqa: E402


class AtomicWriteTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, 'serverDZ.cfg')
        with open(self.path, 'w', encoding='utf-8') as f:
            f.write('hostname = "old";\n')
        os.chmod(self.path, 0o640)

    def test_replaces_content_and_keeps_mode(self):
        fileutil.atomic_write_text(self.path, 'hostname = "new";\n')
        with open(self.path, encoding='utf-8') as f:
            self.assertEqual(f.read(), 'hostname = "new";\n')
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o640)
        self.assertEqual(os.listdir(self.dir), ['serverDZ.cfg'])  # no temp file left

    def test_failed_write_leaves_original_untouched(self):
        def boom(f):
            f.write(b'half')
            raise OSError('disk full')
        with self.assertRaises(OSError):
            fileutil.atomic_write(self.path, boom)
        with open(self.path, encoding='utf-8') as f:
            self.assertEqual(f.read(), 'hostname = "old";\n')
        self.assertEqual(os.listdir(self.dir), ['serverDZ.cfg'])

    def test_creates_new_file(self):
        new = os.path.join(self.dir, 'fresh.json')
        fileutil.atomic_write_text(new, '{}')
        with open(new, encoding='utf-8') as f:
            self.assertEqual(f.read(), '{}')


if __name__ == '__main__':
    unittest.main()
