#!/usr/bin/env python3
"""Tests for lib/ce_scanner.py (Modular Loot Manager scan)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib')
sys.path.insert(0, LIB)
import ce_scanner  # noqa: E402

TYPES_XML = '<types><type name="Apple"><nominal>5</nominal></type></types>\n'
PRESETS_XML = '<randompresets><cargo chance="0.5" name="foodMod"><item name="Apple" /></cargo></randompresets>\n'
GROUPS_XML = '<eventgroupdef><group name="Camp"><child type="Barrel" x="1" z="2" a="0" /></group></eventgroupdef>\n'
CORE_XML = '''<economycore>
    <ce folder="CustomCE/types">
        <file name="111_mod_types.xml" type="types" />
        <file name="other_types.xml" type="types" />
        <file name="222_mod_types.xml" type="types" />
    </ce>
</economycore>
'''


def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as fp:
        fp.write(content)


class ScannerFixture(unittest.TestCase):
    """A workshop with one enabled mod and a mission with linked and local files."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = self.tmp.name
        self.workshop = os.path.join(base, 'workshop')
        self.instance = os.path.join(base, 'instance')
        self.mission = os.path.join(base, 'mission')
        self.mods_file = os.path.join(self.instance, 'data', 'config', 'mods.txt')

        # enabled mod 111, listed mod 222 is not installed, mod 333 is installed but not listed
        write(self.mods_file, '111\n222|Disabled Mod\n')
        write(os.path.join(self.workshop, '111', 'meta.cpp'), 'protocol = 1;\nname = "Mod One";\n')
        write(os.path.join(self.workshop, '111', 'ce', 'mod_types.xml'), TYPES_XML)
        write(os.path.join(self.workshop, '111', 'ce', 'mod_randompresets.xml'), PRESETS_XML)
        write(os.path.join(self.workshop, '111', 'ce', 'mod_eventgroups.xml'), GROUPS_XML)
        write(os.path.join(self.workshop, '111', 'info', 'readme.xml'), '<notes>hi</notes>\n')
        write(os.path.join(self.workshop, '111', 'mod.xml'), TYPES_XML)
        write(os.path.join(self.workshop, '333', 'ce', 'types.xml'), TYPES_XML)

        # mission: linked copy of the mod file, edited after linking
        write(os.path.join(self.mission, 'cfgeconomycore.xml'), CORE_XML)
        types_dir = os.path.join(self.mission, 'CustomCE', 'types')
        write(os.path.join(types_dir, '111_mod_types.xml'), TYPES_XML.replace('5', '50'))
        write(os.path.join(types_dir, '.originals', '111_mod_types.xml'), TYPES_XML)
        write(os.path.join(types_dir, 'other_types.xml'), TYPES_XML)      # linked, not an orphan
        write(os.path.join(types_dir, '111_extra_types.xml'), TYPES_XML)  # registered pattern
        write(os.path.join(types_dir, 'local_types.xml'), TYPES_XML)      # orphan
        write(os.path.join(types_dir, '.backups', 'old_types.xml'), TYPES_XML)

        # randompresets of mod 111 were merged, eventgroups were not
        write(os.path.join(self.instance, 'data', 'state', 'ce_merge_tracking', 'cfgrandompresets.json'),
              json.dumps({'entries': {'111': {'names': ['foodMod']}}}))

        # mod 111's eventgroups file is on the ignore list
        self.ignore_file = os.path.join(self.mission, 'CustomCE', '.ce_ignored.json')
        write(self.ignore_file, json.dumps({'ignored': ['111|MOD_EVENTGROUPS.XML']}))

        self.ctx = ce_scanner.ScanContext(self.workshop, self.mission, self.instance,
                                          [self.mods_file], self.ignore_file)

    def tearDown(self):
        self.tmp.cleanup()

    def by_name(self, results, filename):
        matches = [r for r in results if r['filename'] == filename]
        self.assertEqual(len(matches), 1, f'{filename} reported {len(matches)} times')
        return matches[0]


class ScanTest(ScannerFixture):
    def test_mod_ids_and_names(self):
        self.assertEqual(self.ctx.mod_ids, {'111', '222'})
        self.assertEqual(ce_scanner.get_mod_name(self.workshop, '111'), 'Mod One')
        self.assertEqual(ce_scanner.get_mod_name(self.workshop, '999'), '999')

    def test_linked_file_is_reported_as_linked_and_modified(self):
        item = self.by_name(ce_scanner.scan(self.ctx), 'mod_types.xml')
        self.assertEqual(item['mod_id'], '111')
        self.assertEqual(item['mod_name'], 'Mod One')
        self.assertEqual(item['ce_type'], 'types')
        self.assertEqual(item['status'], 'linked')
        self.assertEqual(item['linked_filename'], '111_mod_types.xml')
        self.assertTrue(item['modified'])

    def test_unmodified_linked_copy(self):
        write(os.path.join(self.mission, 'CustomCE', 'types', '111_mod_types.xml'), TYPES_XML)
        item = self.by_name(ce_scanner.scan(self.ctx), 'mod_types.xml')
        self.assertFalse(item['modified'])

    def test_merge_only_types_use_tracking(self):
        results = ce_scanner.scan(self.ctx)
        presets = self.by_name(results, 'mod_randompresets.xml')
        self.assertEqual((presets['ce_type'], presets['status']), ('randompresets', 'linked'))
        self.assertEqual(presets['linked_filename'], '111_randompresets')
        groups = self.by_name(results, 'mod_eventgroups.xml')
        self.assertEqual((groups['ce_type'], groups['status']), ('eventgroups', 'new'))

    def test_non_ce_and_unlisted_mods_are_skipped(self):
        names = {(r['mod_id'], r['filename']) for r in ce_scanner.scan(self.ctx)}
        self.assertNotIn(('111', 'readme.xml'), names)
        self.assertNotIn(('111', 'mod.xml'), names)
        self.assertNotIn(('333', 'types.xml'), names)

    def test_orphans(self):
        results = ce_scanner.scan(self.ctx)
        local = self.by_name(results, 'local_types.xml')
        self.assertEqual((local['mod_id'], local['status'], local['ce_type']), ('LOCAL', 'unlinked', 'types'))
        names = {r['filename'] for r in results}
        self.assertNotIn('other_types.xml', names)      # linked in cfgeconomycore.xml
        self.assertNotIn('111_extra_types.xml', names)  # registered by an enabled mod
        self.assertNotIn('old_types.xml', names)        # lives in .backups

    def test_linked_name_belongs_to_the_right_mod(self):
        linked = {'222_mod_types.xml': {}, '111_mod_types.xml': {}}
        self.assertEqual(ce_scanner.find_linked_name(linked, '111', 'mod_types.xml'), '111_mod_types.xml')
        self.assertEqual(ce_scanner.find_linked_name({'222_mod_types.xml': {}}, '111', 'mod_types.xml'), '')
        self.assertEqual(ce_scanner.find_linked_name({'custom_mod_types.xml': {}}, '111', 'mod_types.xml'),
                         'custom_mod_types.xml')

    def test_linked_files_report_disk_state(self):
        entries = {e['name']: e for e in ce_scanner.linked_files(self.mission)}
        self.assertEqual(set(entries), {'111_mod_types.xml', 'other_types.xml', '222_mod_types.xml'})
        self.assertTrue(entries['111_mod_types.xml']['has_original'])
        self.assertFalse(entries['222_mod_types.xml']['exists'])
        self.assertEqual(ce_scanner.linked_files(os.path.join(self.mission, 'nope')), [])

    def test_missing_mods_files_and_missing_workshop(self):
        ctx = ce_scanner.ScanContext(os.path.join(self.workshop, 'nope'), self.mission, self.instance,
                                     ['/does/not/exist'])
        results = ce_scanner.scan(ctx)
        self.assertEqual({r['mod_id'] for r in results}, {'LOCAL'})

    def test_rows_have_eight_fields_and_flags(self):
        sep = ce_scanner.join_row.__globals__['FIELD_SEP']
        rows = ce_scanner.to_rows(ce_scanner.scan(self.ctx)).split('\n')
        self.assertTrue(rows)
        for row in rows:
            self.assertEqual(len(row.split(sep)), 9, row)
        linked = [r for r in rows if r.split(sep)[3] == 'mod_types.xml'][0].split(sep)
        self.assertEqual(linked[5:], ['1', '111_mod_types.xml', '1', '0'])
        local = [r for r in rows if r.split(sep)[3] == 'local_types.xml'][0].split(sep)
        self.assertEqual(local[5:], ['0', '', '0', '0'])
        groups = [r for r in rows if r.split(sep)[3] == 'mod_eventgroups.xml'][0].split(sep)
        self.assertEqual(groups[5:], ['0', '', '0', '1'])

    def test_ignore_list_and_only_new(self):
        results = ce_scanner.scan(self.ctx)
        self.assertTrue(self.by_name(results, 'mod_eventgroups.xml')['ignored'])
        self.assertFalse(self.by_name(results, 'mod_types.xml')['ignored'])
        new = {r['filename'] for r in ce_scanner.only_new(results)}
        self.assertEqual(new, {'local_types.xml'})  # types linked, presets merged, groups ignored
        self.assertEqual(ce_scanner.read_ignore_list(''), set())
        self.assertEqual(ce_scanner.read_ignore_list(os.path.join(self.tmp.name, 'missing.json')), set())

    def test_detect_by_content_then_filename(self):
        self.assertEqual(ce_scanner.detect_ce_type(os.path.join(self.workshop, '111', 'ce', 'mod_types.xml')), 'types')
        self.assertEqual(ce_scanner.detect_ce_type(os.path.join(self.workshop, '111', 'info', 'readme.xml')), '')
        # content does not reveal the type: the filename decides
        by_name = os.path.join(self.tmp.name, 'custom_eventspawns.xml')
        write(by_name, '<unknown />')
        self.assertEqual(ce_scanner.detect_ce_type(by_name), 'eventspawns')


class CliTest(ScannerFixture):
    def run_cli(self, *args):
        proc = subprocess.run([sys.executable, os.path.join(LIB, 'ce_scanner.py'), *args],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout

    def test_scan_json_and_tsv(self):
        common = ['--workshop-dir', self.workshop, '--mission-path', self.mission,
                  '--instance-dir', self.instance, '--mods-file', self.mods_file,
                  '--mods-file', '/missing/servermods.txt', '--ignore-file', self.ignore_file]
        data = json.loads(self.run_cli('scan', *common))
        self.assertEqual({r['filename'] for r in data},
                         {'mod_types.xml', 'mod_randompresets.xml', 'mod_eventgroups.xml', 'local_types.xml'})
        rows = self.run_cli('scan', '--format', 'rows', *common)
        self.assertEqual(len(rows.strip().split('\n')), 4)
        new = json.loads(self.run_cli('scan', '--only-new', *common))
        self.assertEqual([r['filename'] for r in new], ['local_types.xml'])

    def test_bash_read_keeps_empty_fields_in_place(self):
        """Regression: with tab separated rows bash's read collapsed the empty
        linked_filename and the modified flag landed in the wrong variable."""
        rows = self.run_cli('scan', '--format', 'rows', '--workshop-dir', self.workshop,
                            '--mission-path', self.mission, '--instance-dir', self.instance,
                            '--mods-file', self.mods_file, '--ignore-file', self.ignore_file)
        script = ("while IFS=$'\\x1f' read -r sp mid mn fn ct st ln md ig; do "
                  "printf '%s|%s|%s|%s|%s\\n' \"$fn\" \"$st\" \"$ln\" \"$md\" \"$ig\"; done")
        out = subprocess.run(['bash', '-c', script], input=rows, capture_output=True, text=True).stdout
        self.assertIn('mod_types.xml|1|111_mod_types.xml|1|0', out)
        self.assertIn('local_types.xml|0||0|0', out)
        self.assertIn('mod_eventgroups.xml|0||0|1', out)

    def test_linked_and_detect(self):
        data = json.loads(self.run_cli('linked', '--mission-path', self.mission))
        self.assertEqual(len(data), 3)
        out = self.run_cli('detect', os.path.join(self.workshop, '111', 'ce', 'mod_randompresets.xml'))
        self.assertEqual(out.strip(), 'randompresets')


if __name__ == '__main__':
    unittest.main()
