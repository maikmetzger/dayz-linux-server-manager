#!/usr/bin/env python3
"""
DayZ Server Scripts - Player Manager
=====================================
Handles player domain logic:
- Session tracking (join times, time on server)
- Player data parsing and management
- Duration parsing for ban durations

This module is called from bash scripts to handle complex data operations
that are better suited to Python than bash.
"""

import json
import os
import sys
from datetime import datetime, timezone
from typing import Optional, Dict, List, Any


# =============================================================================
# Session Management
# =============================================================================

class SessionManager:
    """Manages player session tracking (join times, time on server)."""

    def __init__(self, sessions_file: str):
        """Initialize with path to sessions.json file."""
        self.sessions_file = sessions_file
        self.sessions: Dict[str, int] = {}
        self._load()

    def _load(self) -> None:
        """Load sessions from JSON file."""
        if os.path.exists(self.sessions_file):
            try:
                with open(self.sessions_file, 'r') as f:
                    self.sessions = json.load(f)
            except (json.JSONDecodeError, IOError):
                self.sessions = {}

    def _save(self) -> None:
        """Save sessions to JSON file."""
        try:
            os.makedirs(os.path.dirname(self.sessions_file), exist_ok=True)
            with open(self.sessions_file, 'w') as f:
                json.dump(self.sessions, f, indent=2)
        except IOError:
            pass

    def get_or_create_session(self, guid: str, now_ts: Optional[int] = None) -> int:
        """Get existing session join time or create new one.

        Args:
            guid: Player's BattlEye GUID
            now_ts: Current Unix timestamp (defaults to now)

        Returns:
            Unix timestamp when player joined
        """
        if now_ts is None:
            now_ts = int(datetime.now(timezone.utc).timestamp())

        if guid in self.sessions:
            return self.sessions[guid]

        # New player - record join time
        self.sessions[guid] = now_ts
        self._save()
        return now_ts

    def cleanup_departed(self, current_guids: List[str]) -> None:
        """Remove sessions for players who have left.

        Args:
            current_guids: List of GUIDs currently online
        """
        current_set = set(current_guids)
        self.sessions = {k: v for k, v in self.sessions.items() if k in current_set}
        self._save()

    def calculate_time_on_server(self, join_ts: int, now_ts: Optional[int] = None) -> int:
        """Calculate time on server in minutes.

        Args:
            join_ts: Unix timestamp when player joined
            now_ts: Current Unix timestamp (defaults to now)

        Returns:
            Minutes on server (minimum 0)
        """
        if now_ts is None:
            now_ts = int(datetime.now(timezone.utc).timestamp())

        minutes = (now_ts - join_ts) // 60
        return max(0, minutes)

    def format_time(self, minutes: int) -> str:
        """Format time in minutes as human-readable string.

        Args:
            minutes: Time in minutes

        Returns:
            Formatted string like "2h15m" or "45m"
        """
        if minutes >= 60:
            hours = minutes // 60
            mins = minutes % 60
            return f"{hours}h{mins:02d}m"
        return f"{minutes}m"


# =============================================================================
# Duration Parsing
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

    # Try to parse number + unit
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


def calculate_expiry(duration_minutes: int) -> str:
    """Calculate expiry timestamp from duration.

    Args:
        duration_minutes: Duration in minutes (-1 for permanent)

    Returns:
        ISO 8601 timestamp string or 'never'
    """
    if duration_minutes <= 0:
        return 'never'

    now = datetime.now(timezone.utc)
    expiry = now.timestamp() + (duration_minutes * 60)
    return datetime.fromtimestamp(expiry, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def format_timestamp(ts: int) -> str:
    """Format Unix timestamp as DD/MM/YYYY HH:MM.

    Args:
        ts: Unix timestamp

    Returns:
        Formatted date string
    """
    try:
        dt = datetime.fromtimestamp(ts, timezone.utc)
        return dt.strftime('%d/%m/%Y %H:%M')
    except (ValueError, OSError):
        return '?'


# =============================================================================
# CLI Interface
# =============================================================================

def main():
    """CLI interface for player manager operations."""
    import argparse

    parser = argparse.ArgumentParser(description='DayZ Player Manager')
    subparsers = parser.add_subparsers(dest='command', help='Command to run')

    # Session commands
    session_parser = subparsers.add_parser('session', help='Session management')
    session_parser.add_argument('--file', required=True, help='Path to sessions.json')
    session_parser.add_argument('--action', required=True,
                               choices=['get', 'cleanup'],
                               help='Action to perform')
    session_parser.add_argument('--guid', help='Player GUID')
    session_parser.add_argument('--now', type=int, help='Current Unix timestamp')
    session_parser.add_argument('--guids', help='Comma-separated list of current GUIDs (for cleanup)')

    # Duration parsing
    duration_parser = subparsers.add_parser('duration', help='Parse duration string')
    duration_parser.add_argument('--input', required=True, help='Duration string to parse')

    # Expiry calculation
    expiry_parser = subparsers.add_parser('expiry', help='Calculate expiry timestamp')
    expiry_parser.add_argument('--minutes', type=int, required=True, help='Duration in minutes')

    # Timestamp formatting
    format_parser = subparsers.add_parser('format-time', help='Format Unix timestamp')
    format_parser.add_argument('--timestamp', type=int, required=True, help='Unix timestamp')

    args = parser.parse_args()

    if args.command == 'session':
        manager = SessionManager(args.file)
        now = args.now if args.now else int(datetime.now(timezone.utc).timestamp())

        if args.action == 'get':
            if not args.guid:
                print(json.dumps({'error': 'Missing --guid'}))
                sys.exit(1)
            join_ts = manager.get_or_create_session(args.guid, now)
            time_on_server = manager.calculate_time_on_server(join_ts, now)
            print(json.dumps({
                'join_ts': join_ts,
                'time_minutes': time_on_server,
                'time_formatted': manager.format_time(time_on_server),
                'joined_at': format_timestamp(join_ts)
            }))

        elif args.action == 'cleanup':
            if args.guids:
                current = [g.strip() for g in args.guids.split(',') if g.strip()]
            else:
                current = []
            manager.cleanup_departed(current)
            print(json.dumps({'success': True, 'remaining': len(manager.sessions)}))

    elif args.command == 'duration':
        result = parse_duration(args.input)
        print(json.dumps(result))

    elif args.command == 'expiry':
        expiry = calculate_expiry(args.minutes)
        print(json.dumps({'expires': expiry}))

    elif args.command == 'format-time':
        formatted = format_timestamp(args.timestamp)
        print(json.dumps({'formatted': formatted}))

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == '__main__':
    main()
