#!/usr/bin/env python3
"""Per-mod status lines for the Mod Manager table.

Reads the update cache JSON (get_cached_update_info in lib/workshop.sh) from
stdin and prints one line per requested mod ID, in the given order:

    WS_DATE|SYNC_DATE|INSTALL_DATE|HAS_UPDATE|REASON

REASON letters: U = the workshop copy is newer than the synced folder,
M = mod folder missing, D = the @<id> link is not deployed. Dates are '-'
when unknown. A mod that raises an error still yields exactly one line.

Usage: get_cached_update_info DIR | mod_status.py --workshop-dir DIR [--workshop-dir DIR] ID...
"""
import argparse
import datetime
import json
import os
import sys

DATE_FORMAT = '%d.%m.%y %H:%M'   # compact, fits the 14 character table column
ERROR_LINE = '-|-|-|1|Err'


def fmt_ts(ts):
    if not ts:
        return '-'
    return datetime.datetime.fromtimestamp(ts).strftime(DATE_FORMAT)


def read_ts(path, fallback):
    """Unix timestamp stored in a marker file, fallback when unreadable."""
    try:
        with open(path) as fp:
            return int(fp.read().strip())
    except (OSError, ValueError):
        return int(fallback)


def is_deployed_anywhere(mod_path, mod_id):
    """True when an @<id> link exists next to steamapps or next to serverfiles."""
    roots = [os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(mod_path))))]
    parts = mod_path.split(os.sep)
    if 'serverfiles' in parts:
        roots.append(os.sep.join(parts[:parts.index('serverfiles') + 1]))
    # lexists: the link target lives inside the container and may be dangling here
    return any(os.path.lexists(os.path.join(root, f'@{mod_id}')) for root in roots)


def newest_mod_path(workshop_dirs, mod_id):
    """The mod folder among the candidate workshop dirs, newest first; None when absent."""
    choices = [os.path.join(d, mod_id) for d in workshop_dirs if os.path.exists(os.path.join(d, mod_id))]
    return max(choices, key=os.path.getmtime) if choices else None


def install_timestamp(mod_path):
    """Original install date: .first_installed, else .installed_version, else ctime."""
    ctime = os.path.getctime(mod_path)
    for marker in ('.first_installed', '.installed_version'):
        path = os.path.join(mod_path, marker)
        if os.path.exists(path):
            return read_ts(path, ctime)
    return int(ctime)


def status_line(mods_info, workshop_dirs, mod_id):
    mod_path = newest_mod_path(workshop_dirs, mod_id)
    local_ts = 0
    install_ts = 0
    deployed = False
    if mod_path:
        # the folder mtime is touched on every sync/fix, so it is the sync date
        local_ts = int(os.path.getmtime(mod_path))
        install_ts = install_timestamp(mod_path)
        try:
            deployed = is_deployed_anywhere(mod_path, mod_id)
        except OSError:
            deployed = False

    info = mods_info.get(mod_id, {})
    remote_ts = info.get('updated', 0) or info.get('latest', 0)

    reason = ''
    if remote_ts > local_ts:
        reason += 'U'
    if local_ts == 0:
        reason += 'M'
    if not deployed:
        reason += 'D'
    has_update = 1 if reason else 0
    return f'{fmt_ts(remote_ts)}|{fmt_ts(local_ts)}|{fmt_ts(install_ts)}|{has_update}|{reason}'


def load_mods_info(stream):
    """The 'mods' map of the update cache; empty when the cache is unreadable."""
    try:
        data = json.load(stream)
    except ValueError:
        return {}
    return data.get('mods', {}) if isinstance(data, dict) else {}


def status_lines(mods_info, workshop_dirs, mod_ids):
    lines = []
    for mod_id in mod_ids:
        try:
            lines.append(status_line(mods_info, workshop_dirs, mod_id))
        except Exception as exc:  # one broken mod must not hide the others
            sys.stderr.write(f'mod_status: {mod_id}: {exc}\n')
            lines.append(ERROR_LINE)
    return lines


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--workshop-dir', action='append', default=[], required=True,
                        help='workshop content dir (repeatable, newest folder wins)')
    parser.add_argument('mod_ids', nargs='*')
    args = parser.parse_args(argv)
    mods_info = load_mods_info(sys.stdin)
    for line in status_lines(mods_info, args.workshop_dir, args.mod_ids):
        print(line)
    return 0


if __name__ == '__main__':
    sys.exit(main())
