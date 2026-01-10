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
        """Load bans from JSON file."""
        if os.path.exists(self.bans_file):
            try:
                with open(self.bans_file, 'r') as f:
                    data = json.load(f)
                    self.bans = [BanRecord.from_dict(b) for b in data.get('bans', [])]
            except (json.JSONDecodeError, IOError):
                self.bans = []

    def _save(self) -> None:
        """Save bans to JSON file."""
        try:
            os.makedirs(os.path.dirname(self.bans_file), exist_ok=True)
            data = {'bans': [b.to_dict() for b in self.bans]}
            with open(self.bans_file, 'w') as f:
                json.dump(data, f, indent=2)
        except IOError:
            pass

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

    if len(duration_str) < 2:
        return {'minutes': -1, 'human': 'permanent'}

    try:
        num = int(duration_str[:-1])
        unit = duration_str[-1]
    except ValueError:
        return {'minutes': -1, 'human': duration_str}

    if unit == 'm':
        return {'minutes': num, 'human': f'{num} minutes'}
    elif unit == 'h':
        return {'minutes': num * 60, 'human': f'{num} hours'}
    elif unit == 'd':
        return {'minutes': num * 60 * 24, 'human': f'{num} days'}
    else:
        return {'minutes': -1, 'human': duration_str}


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
    subparsers.add_parser('list', help='List all bans')

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
    main()
