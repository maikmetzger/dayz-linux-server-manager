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


class RealMissionLayoutTest(unittest.TestCase):
    """Root tags as found in BohemiaInteractive/DayZ-Central-Economy."""

    def test_eventgroupdef_root_is_eventgroups(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, 'something.xml')
        with open(path, 'w', encoding='utf-8') as f:
            f.write('<eventgroupdef><group name="Train"><child type="X"/></group></eventgroupdef>')
        info = xml_parser.detect_ce_type(path, use_filename_fallback=False)
        self.assertIsNotNone(info)
        self.assertEqual(info['ce_type'], 'eventgroups')
        self.assertTrue(info['merge_only'])

    def test_merge_only_targets_live_in_mission_root(self):
        for key in ('randompresets', 'eventgroups', 'eventgroupdef'):
            self.assertEqual(xml_parser.CE_TYPE_REGISTRY[key]['folder'], '')



CORE = '''<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<economycore>
    <classes><rootclass name="DefaultWeapon" /></classes>
    <defaults><default name="log_ce_loop" value="false"/></defaults>
    <ce folder="db">
        <file name="types.xml" type="types" />
    </ce>
    <ce folder="CustomCE/types">
    </ce>
</economycore>
'''


class CoreRegistrationTest(unittest.TestCase):
    """add-ce-file / remove-ce-file: the cfgeconomycore.xml side of linking."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.core = os.path.join(self.tmp.name, 'cfgeconomycore.xml')
        with open(self.core, 'w') as fp:
            fp.write(CORE)

    def tearDown(self):
        self.tmp.cleanup()

    def entries(self, folder):
        root = ET.parse(self.core).getroot()
        for ce in root.findall('ce'):
            if ce.get('folder') == folder:
                return [(f.get('name'), f.get('type')) for f in ce.findall('file')]
        return None

    def test_add_into_existing_block_once(self):
        self.assertEqual(xml_parser.add_ce_file(self.core, '111_mod_types.xml', 'types', 'CustomCE/types'), 'Success')
        self.assertEqual(xml_parser.add_ce_file(self.core, '111_mod_types.xml', 'types', 'CustomCE/types'), 'Already linked')
        self.assertEqual(self.entries('CustomCE/types'), [('111_mod_types.xml', 'types')])

    def test_same_name_in_another_block_is_not_a_duplicate(self):
        # a db block listing the vanilla types.xml must not block a local types.xml
        self.assertEqual(xml_parser.add_ce_file(self.core, 'types.xml', 'types', 'CustomCE/types'), 'Success')
        self.assertEqual(self.entries('db'), [('types.xml', 'types')])
        self.assertEqual(self.entries('CustomCE/types'), [('types.xml', 'types')])

    def test_missing_block_is_created(self):
        self.assertEqual(xml_parser.add_ce_file(self.core, '111_events.xml', 'events', 'CustomCE/events'), 'Success')
        self.assertEqual(self.entries('CustomCE/events'), [('111_events.xml', 'events')])
        self.assertEqual(self.entries('db'), [('types.xml', 'types')])   # untouched
        ET.parse(self.core)                                              # still well-formed

    def test_remove_case_insensitive_across_blocks(self):
        xml_parser.add_ce_file(self.core, 'Mod_Types.xml', 'types', 'CustomCE/types')
        xml_parser.add_ce_file(self.core, 'mod_types.xml', 'types', 'CustomCE/events')
        self.assertEqual(xml_parser.remove_ce_file(self.core, 'MOD_TYPES.XML'), 2)
        self.assertEqual(self.entries('CustomCE/types'), [])
        self.assertEqual(self.entries('CustomCE/events'), [])
        self.assertEqual(xml_parser.remove_ce_file(self.core, 'nothing.xml'), 0)
        self.assertEqual(self.entries('db'), [('types.xml', 'types')])

    def test_errors_propagate(self):
        with self.assertRaises(OSError):
            xml_parser.add_ce_file(os.path.join(self.tmp.name, 'missing.xml'), 'a.xml', 'types', 'CustomCE/types')
        with open(self.core, 'w') as fp:
            fp.write('')
        with self.assertRaises(ET.ParseError):
            xml_parser.remove_ce_file(self.core, 'a.xml')

    def test_validate(self):
        good = os.path.join(self.tmp.name, 'good.xml')
        frag = os.path.join(self.tmp.name, 'frag.xml')
        bad = os.path.join(self.tmp.name, 'bad.xml')
        with open(good, 'w') as fp:
            fp.write(FULL)
        with open(frag, 'w') as fp:
            fp.write('<?xml version="1.0"?>\n' + FRAGMENT)
        with open(bad, 'w') as fp:
            fp.write('<types><type name="x">')
        self.assertTrue(xml_parser.validate_ce_xml(good))
        self.assertTrue(xml_parser.validate_ce_xml(frag))
        self.assertFalse(xml_parser.validate_ce_xml(bad))

    def test_cli(self):
        import subprocess
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib', 'xml_parser.py')
        def run(*args):
            return subprocess.run([sys.executable, script, *args], capture_output=True, text=True)
        proc = run('add-ce-file', self.core, '111_x.xml', 'types', 'CustomCE/types')
        self.assertEqual((proc.returncode, proc.stdout.strip()), (0, 'Success'))
        proc = run('add-ce-file', self.core, '111_x.xml', 'types', 'CustomCE/types')
        self.assertEqual((proc.returncode, proc.stdout.strip()), (0, 'Already linked'))
        proc = run('remove-ce-file', self.core, '111_X.XML')
        self.assertEqual((proc.returncode, proc.stdout.strip()), (0, 'Success'))
        proc = run('remove-ce-file', self.core, '111_x.xml')
        self.assertEqual((proc.returncode, proc.stdout.strip()), (0, 'NotFound'))
        proc = run('add-ce-file', os.path.join(self.tmp.name, 'missing.xml'), 'a.xml', 'types', 'CustomCE/types')
        self.assertEqual(proc.returncode, 1)
        self.assertIn('Error', proc.stderr)
        bad = os.path.join(self.tmp.name, 'bad.xml')
        with open(bad, 'w') as fp:
            fp.write('<types><type name="x">')
        self.assertEqual(run('validate-ce', bad).returncode, 1)
        good = os.path.join(self.tmp.name, 'good.xml')
        with open(good, 'w') as fp:
            fp.write(FULL)
        self.assertEqual(run('validate-ce', good).returncode, 0)

if __name__ == '__main__':
    unittest.main()
