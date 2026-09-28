#!/usr/bin/env python3
"""Central Economy scanner for the Modular Loot Manager.

Finds the CE XML files the enabled mods ship (types, spawnabletypes, events,
eventspawns, randompresets, eventgroups) and reports for each one whether it
is already linked in cfgeconomycore.xml (or merged, for the merge-only types)
and whether the linked copy was edited after linking. Local files in
CustomCE/ that belong to no enabled mod are reported as orphans.

Usage:
  ce_scanner.py scan --workshop-dir DIR --mission-path DIR --instance-dir DIR
                     [--mods-file FILE ...] [--format json|rows]
  ce_scanner.py linked --mission-path DIR      files registered in cfgeconomycore.xml
  ce_scanner.py detect FILE                    CE type of one XML file (self test)

Row format (--format rows, fields separated by 0x1F, see rowfmt.py):
file_path, mod_id, mod_name, filename, ce_type, linked(0/1), linked_filename,
modified(0/1).
"""
import argparse
import hashlib
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xml_parser  # noqa: E402
from rowfmt import join_row  # noqa: E402

# Files a mod ships that are never loot definitions
NON_CE_FILES = {'cfgeconomycore.xml', 'mod.xml', 'meta.cpp', 'meta.bin', 'meta.cpp.xml'}
# Types that are merged into one mission file instead of being linked
MERGE_ONLY_TYPES = {'randompresets': 'cfgrandompresets', 'eventgroups': 'cfgeventgroups'}
# CustomCE sub folders that may hold local (orphan) files
CUSTOM_CE_FOLDERS = ('types', 'spawnabletypes', 'events', 'eventspawns', 'randompresets', 'eventgroups')
# Last resort when the XML content does not reveal the type. Order matters:
# 'eventspawns' must win over 'events', 'spawnable' over 'types'.
FILENAME_HINTS = (
    ('randompresets', 'randompresets'),
    ('eventgroups', 'eventgroups'),
    ('spawnable', 'spawnabletypes'),
    ('eventspawns', 'eventspawns'),
    ('eventpos', 'eventspawns'),
    ('events', 'events'),
    ('types', 'types'),
)
LOCAL_MOD_ID = 'LOCAL'
LOCAL_MOD_NAME = '[ Manual / Local ]'
HASH_CHUNK = 64 * 1024


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

def read_mod_ids(mod_files):
    """Workshop IDs listed in mods.txt/servermods.txt (first '|' field per line)."""
    ids = set()
    for path in mod_files:
        if not path or not os.path.isfile(path):
            continue
        with open(path, errors='ignore') as fp:
            for line in fp:
                mod_id = line.strip().split('|')[0].strip()
                if mod_id.isdigit():
                    ids.add(mod_id)
    return ids


def get_mod_name(workshop_dir, mod_id):
    """Display name from the mod's meta.cpp, the ID when unavailable."""
    meta = os.path.join(workshop_dir, mod_id, 'meta.cpp')
    try:
        with open(meta, errors='ignore') as fp:
            match = re.search(r'name\s*=\s*"([^"]+)"', fp.read())
    except OSError:
        return mod_id
    return match.group(1) if match else mod_id


def linked_files(mission_path):
    """Files registered in cfgeconomycore.xml with their on-disk state."""
    core = os.path.join(mission_path, 'cfgeconomycore.xml')
    if not os.path.isfile(core):
        return []
    try:
        root = ET.parse(core).getroot()
    except (ET.ParseError, OSError) as exc:
        sys.stderr.write(f"ce_scanner: cannot read {core}: {exc}\n")
        return []
    files = []
    for ce in root.findall('ce'):
        folder = ce.get('folder', '')
        for entry in ce.findall('file'):
            name = entry.get('name', '')
            path = os.path.join(mission_path, folder, name)
            original = os.path.join(mission_path, folder, '.originals', name)
            files.append({
                'name': name,
                'folder': folder,
                'ce_type': entry.get('type', 'types'),
                'path': path,
                'original_path': original,
                'exists': os.path.exists(path),
                'has_original': os.path.exists(original),
            })
    return files


# ---------------------------------------------------------------------------
# Classification of one file
# ---------------------------------------------------------------------------

def detect_ce_type(xml_path):
    """CE type of a file, '' when it is not a loot definition."""
    try:
        result = xml_parser.detect_ce_type(xml_path)
        if result and result.get('ce_type'):
            return result['ce_type']
    except Exception as exc:  # detection must never abort the whole scan
        sys.stderr.write(f"ce_scanner: detect failed for {xml_path}: {exc}\n")
    lower_name = os.path.basename(xml_path).lower()
    for hint, ce_type in FILENAME_HINTS:
        if hint in lower_name:
            return ce_type
    return ''


def is_merged(instance_dir, mod_id, ce_type):
    """True when merge tracking records an entry of this mod for the type."""
    target = MERGE_ONLY_TYPES[ce_type]
    tracking = os.path.join(instance_dir, 'data', 'state', 'ce_merge_tracking', f'{target}.json')
    try:
        with open(tracking) as fp:
            data = json.load(fp)
    except (OSError, ValueError):
        return False
    return mod_id in data.get('entries', {})


def find_linked_name(linked, mod_id, filename):
    """Name under which this mod file is registered, '' when it is not.

    Linked names look like <mod_id>_<filename>; a name whose prefix is a
    different mod ID belongs to that other mod and is not a match.
    """
    search = filename.lower().strip()
    cleaned = ''.join(c for c in search if c.isalnum() or c in '._-')
    for name in linked:
        lowered = name.lower().strip()
        if '_' not in lowered:
            continue
        prefix, suffix = lowered.split('_', 1)
        if suffix not in (search, cleaned):
            continue
        if prefix.isdigit() and prefix != mod_id:
            continue
        return name
    return ''


def _digest(path):
    md5 = hashlib.md5()
    with open(path, 'rb') as fp:
        for chunk in iter(lambda: fp.read(HASH_CHUNK), b''):
            md5.update(chunk)
    return md5.hexdigest()


def is_modified(entry):
    """True when the linked copy differs from its .originals snapshot."""
    path = entry.get('path', '')
    original = entry.get('original_path', '')
    if not (path and original and os.path.isfile(path) and os.path.isfile(original)):
        return False
    try:
        if os.path.getsize(path) != os.path.getsize(original):
            return True
        return _digest(path) != _digest(original)
    except OSError:
        return False


class ScanContext:
    """Everything a scan needs to know about the instance."""

    def __init__(self, workshop_dir, mission_path, instance_dir, mod_files=()):
        self.workshop_dir = workshop_dir
        self.mission_path = mission_path
        self.instance_dir = instance_dir
        self.mod_ids = read_mod_ids(mod_files)
        self.linked = {entry['name']: entry for entry in linked_files(mission_path)}


def classify(ctx, mod_id, filename, ce_type):
    """(status, linked_filename, modified) for one mod file."""
    if ce_type in MERGE_ONLY_TYPES:
        if is_merged(ctx.instance_dir, mod_id, ce_type):
            # the TUI shows merged files as linked; the name is synthetic
            return 'linked', f'{mod_id}_{ce_type}', False
        return 'new', '', False
    linked_name = find_linked_name(ctx.linked, mod_id, filename)
    if not linked_name:
        return 'new', '', False
    return 'linked', linked_name, is_modified(ctx.linked.get(linked_name, {}))


# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

def iter_mod_xml(mod_folder):
    """(directory, filename) of every candidate XML below a mod folder."""
    for root, _dirs, files in os.walk(mod_folder):
        for filename in files:
            lower = filename.lower()
            if lower in NON_CE_FILES or not lower.endswith('.xml'):
                continue
            yield root, filename


def scan_mods(ctx):
    """Results for the enabled mods plus the set of file names seen."""
    results = []
    seen = set()
    for mod_id in sorted(ctx.mod_ids):
        folder = os.path.join(ctx.workshop_dir, mod_id)
        if not os.path.isdir(folder):
            continue
        mod_name = get_mod_name(ctx.workshop_dir, mod_id)
        for root, filename in iter_mod_xml(folder):
            path = os.path.join(root, filename)
            ce_type = detect_ce_type(path)
            if not ce_type:
                continue
            status, linked_name, modified = classify(ctx, mod_id, filename, ce_type)
            results.append({
                'mod_id': mod_id,
                'mod_name': mod_name,
                'file_path': path,
                'filename': filename,
                'ce_type': ce_type,
                'status': status,
                'linked_filename': linked_name,
                'modified': modified,
            })
            seen.add(filename)
            if linked_name:
                seen.add(linked_name)
    return results, seen


def scan_orphans(ctx, seen):
    """Local CustomCE files that belong to no enabled mod and are not linked."""
    results = []
    for folder in CUSTOM_CE_FOLDERS:
        base = os.path.join(ctx.mission_path, 'CustomCE', folder)
        if not os.path.isdir(base):
            continue
        for root, _dirs, files in os.walk(base):
            if '.originals' in root or '.backups' in root:
                continue
            for filename in files:
                lower = filename.lower()
                if not lower.endswith('.xml') or lower in NON_CE_FILES:
                    continue
                if filename in seen or filename in ctx.linked:
                    continue
                if any(filename.startswith(f'{mod_id}_') for mod_id in ctx.mod_ids):
                    continue
                results.append({
                    'mod_id': LOCAL_MOD_ID,
                    'mod_name': LOCAL_MOD_NAME,
                    'file_path': os.path.join(root, filename),
                    'filename': filename,
                    'ce_type': folder,
                    'status': 'unlinked',
                    'linked_filename': '',
                    'modified': False,
                })
    return results


def scan(ctx):
    results, seen = scan_mods(ctx)
    return results + scan_orphans(ctx, seen)


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def to_rows(results):
    """One line per result for bash (parse_scan_result in lib/mod_config.sh)."""
    rows = []
    for item in results:
        rows.append(join_row((
            item['file_path'], item['mod_id'], item['mod_name'], item['filename'],
            item['ce_type'], 1 if item['status'] == 'linked' else 0,
            item['linked_filename'], 1 if item['modified'] else 0,
        )))
    return '\n'.join(rows)


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = parser.add_subparsers(dest='command', required=True)

    p_scan = sub.add_parser('scan', help='scan enabled mods and CustomCE')
    p_scan.add_argument('--workshop-dir', required=True)
    p_scan.add_argument('--mission-path', required=True)
    p_scan.add_argument('--instance-dir', required=True)
    p_scan.add_argument('--mods-file', action='append', default=[],
                        help='mods.txt or servermods.txt (repeatable)')
    p_scan.add_argument('--format', choices=('json', 'rows'), default='json',
                        help='rows: one line per file for bash (0x1F separated)')

    p_linked = sub.add_parser('linked', help='files registered in cfgeconomycore.xml')
    p_linked.add_argument('--mission-path', required=True)

    p_detect = sub.add_parser('detect', help='print the CE type of one XML file')
    p_detect.add_argument('file')
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == 'scan':
        ctx = ScanContext(args.workshop_dir, args.mission_path, args.instance_dir, args.mods_file)
        results = scan(ctx)
        print(to_rows(results) if args.format == 'rows' else json.dumps(results))
    elif args.command == 'linked':
        print(json.dumps(linked_files(args.mission_path)))
    elif args.command == 'detect':
        print(detect_ce_type(args.file) or 'unknown')
    return 0


if __name__ == '__main__':
    sys.exit(main())
