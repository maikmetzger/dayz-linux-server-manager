#!/usr/bin/env python3
"""
DayZ Server Scripts - Ban Manager
==================================
Handles ban domain logic:
- Ban record management (create, list, remove)
- Expiry tracking and checking
- Integration with bans.json tracking file

This module is called from bash scripts to handle complex data operations
that are better suited to Python than bash.
"""

import json
import os
import re
import sys
from datetime import datetime, timezone
from typing import Optional, Dict, List, Any


# =============================================================================
# Ban Record Model
# =============================================================================

class BanRecord:
    """Represents a ban record."""

    def __init__(
        self,
        guid: str,
        name: str,
        reason: str = "Banned by admin",
        duration_minutes: int = -1,
        banned_at: Optional[str] = None,
        expires: Optional[str] = None
    ):
        self.guid = guid
        self.name = name
        self.reason = reason
        self.duration_minutes = duration_minutes
        self.banned_at = banned_at or self._now_iso()
        self.expires = expires or self._calculate_expiry(duration_minutes)

    @staticmethod
    def _now_iso() -> str:
        """Get current time in ISO 8601 format."""
        return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

    @staticmethod
    def _calculate_expiry(duration_minutes: int) -> str:
        """Calculate expiry timestamp from duration."""
        if duration_minutes <= 0:
            return 'never'
        now = datetime.now(timezone.utc)
        expiry_ts = now.timestamp() + (duration_minutes * 60)
        return datetime.fromtimestamp(expiry_ts, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            'guid': self.guid,
            'name': self.name,
            'reason': self.reason,
            'duration_minutes': self.duration_minutes,
            'banned_at': self.banned_at,
            'expires': self.expires
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'BanRecord':
        """Create BanRecord from dictionary."""
        return cls(
            guid=data.get('guid', ''),
            name=data.get('name', 'Unknown'),
            reason=data.get('reason', 'Banned by admin'),
            duration_minutes=data.get('duration_minutes', -1),
            banned_at=data.get('banned_at'),
            expires=data.get('expires')
        )

    def is_expired(self) -> bool:
        """Check if this ban has expired."""
        if self.expires in ('never', 'unknown', '', None):
            return False

        try:
            expiry_dt = datetime.strptime(self.expires, '%Y-%m-%dT%H:%M:%SZ')
            expiry_dt = expiry_dt.replace(tzinfo=timezone.utc)
            return datetime.now(timezone.utc) >= expiry_dt
        except ValueError:
            return False


# =============================================================================
# Ban Manager
# =============================================================================

class BanManager:
    """Manages ban records stored in bans.json."""

    def __init__(self, bans_file: str):
        """Initialize with path to bans.json file."""
        self.bans_file = bans_file
        self.bans: List[BanRecord] = []
        self._load()

    def _load(self) -> None:
        """Load bans from JSON file.

        A file that cannot be read or has the wrong shape is remembered in
        self.load_error; _save then refuses to overwrite it, so a corrupt
        file is never silently replaced by a single new record.
        """
        self.load_error = None
        if not os.path.exists(self.bans_file):
            return
        try:
            with open(self.bans_file, 'r', encoding='utf-8') as f:
                data = json.load(f)
            bans = data.get('bans') if isinstance(data, dict) else None
            if not isinstance(bans, list) or not all(isinstance(b, dict) for b in bans):
                raise ValueError('expected an object with a "bans" list of objects')
            self.bans = [BanRecord.from_dict(b) for b in bans]
        except (json.JSONDecodeError, OSError, ValueError, KeyError, TypeError) as e:
            self.load_error = f"{self.bans_file}: {e}"
            print(f"WARN: cannot read {self.load_error}", file=sys.stderr)
            self.bans = []

    def _save(self) -> None:
        """Save bans to JSON file. Raises OSError when the write is not possible."""
        if self.load_error:
            raise OSError(f"refusing to overwrite unreadable ban file ({self.load_error})")
        os.makedirs(os.path.dirname(os.path.abspath(self.bans_file)), exist_ok=True)
        data = {'bans': [b.to_dict() for b in self.bans]}
        with open(self.bans_file, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)

    def add_ban(
        self,
        guid: str,
        name: str,
        reason: str = "Banned by admin",
        duration_minutes: int = -1
    ) -> BanRecord:
        """Add a new ban record.

        Args:
            guid: Player's BattlEye GUID
            name: Player's name
            reason: Ban reason
            duration_minutes: Ban duration (-1 for permanent)

        Returns:
            The created BanRecord
        """
        # Remove any existing ban for this GUID first
        self.bans = [b for b in self.bans if b.guid != guid]

        ban = BanRecord(
            guid=guid,
            name=name,
            reason=reason,
            duration_minutes=duration_minutes
        )
        self.bans.append(ban)
        self._save()
        return ban

    def remove_ban(self, guid: str) -> bool:
        """Remove a ban by GUID.

        Args:
            guid: Player's BattlEye GUID

        Returns:
            True if ban was found and removed
        """
        original_count = len(self.bans)
        self.bans = [b for b in self.bans if b.guid != guid]
        if len(self.bans) < original_count:
            self._save()
            return True
        return False

    def get_ban(self, guid: str) -> Optional[BanRecord]:
        """Get ban record by GUID.

        Args:
            guid: Player's BattlEye GUID

        Returns:
            BanRecord if found, None otherwise
        """
        for ban in self.bans:
            if ban.guid == guid:
                return ban
        return None

    def list_bans(self) -> List[BanRecord]:
        """Get all ban records."""
        return self.bans.copy()

    def get_expired_bans(self) -> List[BanRecord]:
        """Get list of expired bans.

        Returns:
            List of expired BanRecord objects
        """
        return [b for b in self.bans if b.is_expired()]

    def remove_expired_bans(self) -> List[str]:
        """Remove all expired bans.

        Returns:
            List of removed GUIDs
        """
        expired = self.get_expired_bans()
        expired_guids = [b.guid for b in expired]

        if expired_guids:
            self.bans = [b for b in self.bans if not b.is_expired()]
            self._save()

        return expired_guids

    def count(self) -> int:
        """Get total number of bans."""
        return len(self.bans)


# =============================================================================
# Duration Parsing (shared with player_manager)
# =============================================================================

def parse_duration(duration_str: str) -> Dict[str, Any]:
    """Parse a duration string into minutes and human-readable format.

    Supports formats:
    - "30m" -> 30 minutes
    - "2h" -> 120 minutes (2 hours)
    - "7d" -> 10080 minutes (7 days)
    - "perm" or "permanent" -> -1 (permanent)

    Args:
        duration_str: Duration string to parse

    Returns:
        Dict with 'minutes' (int) and 'human' (str) keys
    """
    duration_str = duration_str.strip().lower()

    if duration_str in ('perm', 'permanent', '-1', ''):
        return {'minutes': -1, 'human': 'permanent'}

    # Anything else must be a positive number with a unit; unknown input
    # raises instead of silently turning into a permanent ban.
    match = re.fullmatch(r'(\d+)([mhd])', duration_str)
    if not match or int(match.group(1)) == 0:
        raise ValueError(f"invalid duration '{duration_str}': use 30m, 2h, 7d or perm")
    num, unit = int(match.group(1)), match.group(2)

    if unit == 'm':
        return {'minutes': num, 'human': f'{num} minutes'}
    if unit == 'h':
        return {'minutes': num * 60, 'human': f'{num} hours'}
    return {'minutes': num * 60 * 24, 'human': f'{num} days'}


# =============================================================================
# CLI Interface
# =============================================================================

def main():
    """CLI interface for ban manager operations."""
    import argparse

    parser = argparse.ArgumentParser(description='DayZ Ban Manager')
    parser.add_argument('--file', required=True, help='Path to bans.json')

    subparsers = parser.add_subparsers(dest='command', help='Command to run')

    # Add ban
    add_parser = subparsers.add_parser('add', help='Add a ban')
    add_parser.add_argument('--guid', required=True, help='Player GUID')
    add_parser.add_argument('--name', required=True, help='Player name')
    add_parser.add_argument('--reason', default='Banned by admin', help='Ban reason')
    add_parser.add_argument('--duration', default='perm', help='Duration (30m, 2h, 7d, perm)')

    # Remove ban
    remove_parser = subparsers.add_parser('remove', help='Remove a ban')
    remove_parser.add_argument('--guid', required=True, help='Player GUID')

    # Get ban
    get_parser = subparsers.add_parser('get', help='Get ban by GUID')
    get_parser.add_argument('--guid', required=True, help='Player GUID')

    # List bans
    list_parser = subparsers.add_parser('list', help='List all bans')
    list_parser.add_argument('--tsv', action='store_true', help='One row per ban: guid, name, reason, minutes, banned_at, expires')

    # Get expired bans
    subparsers.add_parser('expired', help='List expired bans')

    # Remove expired bans
    subparsers.add_parser('cleanup', help='Remove all expired bans')

    # Parse duration
    duration_parser = subparsers.add_parser('parse-duration', help='Parse duration string')
    duration_parser.add_argument('--input', required=True, help='Duration string')

    args = parser.parse_args()

    manager = BanManager(args.file)

    if args.command == 'add':
        duration = parse_duration(args.duration)
        ban = manager.add_ban(
            guid=args.guid,
            name=args.name,
            reason=args.reason,
            duration_minutes=duration['minutes']
        )
        print(json.dumps({
            'success': True,
            'ban': ban.to_dict()
        }))

    elif args.command == 'remove':
        removed = manager.remove_ban(args.guid)
        print(json.dumps({
            'success': removed,
            'guid': args.guid
        }))

    elif args.command == 'get':
        ban = manager.get_ban(args.guid)
        if ban:
            print(json.dumps({
                'found': True,
                'ban': ban.to_dict()
            }))
        else:
            print(json.dumps({
                'found': False,
                'guid': args.guid
            }))

    elif args.command == 'list':
        bans = manager.list_bans()
        if args.tsv:
            for b in bans:
                fields = (b.guid, b.name, b.reason, b.duration_minutes, b.banned_at, b.expires)
                print('\t'.join(str(f).replace('\t', ' ').replace('\n', ' ') for f in fields))
        else:
            print(json.dumps({
                'count': len(bans),
                'bans': [b.to_dict() for b in bans]
            }))

    elif args.command == 'expired':
        expired = manager.get_expired_bans()
        print(json.dumps({
            'count': len(expired),
            'bans': [b.to_dict() for b in expired]
        }))

    elif args.command == 'cleanup':
        removed = manager.remove_expired_bans()
        print(json.dumps({
            'success': True,
            'removed_count': len(removed),
            'removed_guids': removed
        }))

    elif args.command == 'parse-duration':
        result = parse_duration(args.input)
        print(json.dumps(result))

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as e:
        print(json.dumps({'success': False, 'error': str(e)}))
        sys.exit(1)
