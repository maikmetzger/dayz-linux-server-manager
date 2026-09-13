#!/usr/bin/env python3
"""Regression tests for lib/xml_parser.py (Central Economy editor)."""
import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib'))
import xml_parser  # noqa: E402

FRAGMENT = '''<type name="Apple">
    <nominal>10</nominal>
    <lifetime>3600</lifetime>
</type>
<type name="Pear">
    <nominal>3</nominal>
</type>
'''

FULL = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<types>
    <type name="Apple">
        <nominal>10</nominal>
    </type>
</types>
'''


class FragmentUpdateTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def _write(self, name, content):
        path = os.path.join(self.dir, name)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return path

    def test_fragment_keeps_fragment_format(self):
        path = self._write('frag.xml', FRAGMENT)
        xml_parser.update(path, 'Apple', 'nominal', '5')
        with open(path, encoding='utf-8') as f:
            out = f.read()
        self.assertNotIn('<types>', out)
        self.assertNotIn('<?xml', out)
        self.assertIn('<nominal>5</nominal>', out)
        # still two top-level <type> elements, still parseable when wrapped
        root = ET.fromstring('<types>' + out + '</types>')
        self.assertEqual([t.get('name') for t in root.findall('type')], ['Apple', 'Pear'])
        self.assertEqual(root.find("type[@name='Pear']/nominal").text, '3')

    def test_fragment_keeps_its_declaration(self):
        path = self._write('frag_decl.xml', '<?xml version="1.0" encoding="UTF-8"?>\n' + FRAGMENT)
        xml_parser.update(path, 'Apple', 'nominal', '7')
        with open(path, encoding='utf-8') as f:
            out = f.read()
        self.assertTrue(out.startswith('<?xml'))
        self.assertNotIn('<types>', out)

    def test_full_file_keeps_wrapper(self):
        path = self._write('types.xml', FULL)
        xml_parser.update(path, 'Apple', 'nominal', '5')
        root = ET.parse(path).getroot()
        self.assertEqual(root.tag, 'types')
        self.assertEqual(root.find("type[@name='Apple']/nominal").text, '5')


if __name__ == '__main__':
    unittest.main()
