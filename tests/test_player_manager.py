#!/usr/bin/env python3
"""
Unit tests for player_manager.py
"""

import unittest
import os
import json
import shutil
import tempfile
import sys
from datetime import datetime, timezone

# Add lib to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../lib'))
import player_manager


class TestSessionManager(unittest.TestCase):
    """Tests for SessionManager class."""

    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.sessions_file = os.path.join(self.test_dir, 'sessions.json')

    def tearDown(self):
        shutil.rmtree(self.test_dir)

    def test_get_or_create_session_new_player(self):
        """Test creating a new session for a new player."""
        manager = player_manager.SessionManager(self.sessions_file)
        now = 1700000000

        join_ts = manager.get_or_create_session('abc123', now)

        self.assertEqual(join_ts, now)
        self.assertIn('abc123', manager.sessions)

    def test_get_or_create_session_existing_player(self):
        """Test getting an existing session."""
        # Pre-create session file
        with open(self.sessions_file, 'w') as f:
            json.dump({'abc123': 1699999000}, f)

        manager = player_manager.SessionManager(self.sessions_file)
        now = 1700000000

        join_ts = manager.get_or_create_session('abc123', now)

        self.assertEqual(join_ts, 1699999000)  # Should return original time

    def test_cleanup_departed(self):
        """Test cleaning up departed players."""
        # Pre-create session file with multiple players
        with open(self.sessions_file, 'w') as f:
            json.dump({
                'player1': 1699999000,
                'player2': 1699999100,
                'player3': 1699999200
            }, f)

        manager = player_manager.SessionManager(self.sessions_file)

        # Only player1 and player3 are still online
        manager.cleanup_departed(['player1', 'player3'])

        self.assertIn('player1', manager.sessions)
        self.assertNotIn('player2', manager.sessions)
        self.assertIn('player3', manager.sessions)

    def test_calculate_time_on_server(self):
        """Test calculating time on server."""
        manager = player_manager.SessionManager(self.sessions_file)

        # 120 seconds = 2 minutes
        time_mins = manager.calculate_time_on_server(1699999880, 1700000000)
        self.assertEqual(time_mins, 2)

        # Negative time should return 0
        time_mins = manager.calculate_time_on_server(1700000100, 1700000000)
        self.assertEqual(time_mins, 0)

    def test_format_time(self):
        """Test time formatting."""
        manager = player_manager.SessionManager(self.sessions_file)

        self.assertEqual(manager.format_time(30), '30m')
        self.assertEqual(manager.format_time(60), '1h00m')
        self.assertEqual(manager.format_time(75), '1h15m')
        self.assertEqual(manager.format_time(125), '2h05m')

    def test_persistence(self):
        """Test that sessions are persisted to file."""
        manager = player_manager.SessionManager(self.sessions_file)
        manager.get_or_create_session('persistent_player', 1700000000)

        # Create a new manager and verify data is loaded
        manager2 = player_manager.SessionManager(self.sessions_file)
        self.assertIn('persistent_player', manager2.sessions)
        self.assertEqual(manager2.sessions['persistent_player'], 1700000000)


class TestDurationParsing(unittest.TestCase):
    """Tests for duration parsing functions."""

    def test_parse_duration_minutes(self):
        """Test parsing minute durations."""
        result = player_manager.parse_duration('30m')
        self.assertEqual(result['minutes'], 30)
        self.assertEqual(result['human'], '30 minutes')

    def test_parse_duration_hours(self):
        """Test parsing hour durations."""
        result = player_manager.parse_duration('2h')
        self.assertEqual(result['minutes'], 120)
        self.assertEqual(result['human'], '2 hours')

    def test_parse_duration_days(self):
        """Test parsing day durations."""
        result = player_manager.parse_duration('7d')
        self.assertEqual(result['minutes'], 7 * 24 * 60)
        self.assertEqual(result['human'], '7 days')

    def test_parse_duration_permanent(self):
        """Test parsing permanent duration."""
        for perm in ['perm', 'permanent', '-1', '']:
            result = player_manager.parse_duration(perm)
            self.assertEqual(result['minutes'], -1)
            self.assertEqual(result['human'], 'permanent')

    def test_parse_duration_uppercase(self):
        """Test that parsing is case-insensitive."""
        result = player_manager.parse_duration('2H')
        self.assertEqual(result['minutes'], 120)

    def test_parse_duration_whitespace(self):
        """Test that whitespace is handled."""
        result = player_manager.parse_duration('  30m  ')
        self.assertEqual(result['minutes'], 30)

    def test_parse_duration_invalid(self):
        """Test parsing invalid duration."""
        result = player_manager.parse_duration('invalid')
        self.assertEqual(result['minutes'], -1)


class TestExpiryCalculation(unittest.TestCase):
    """Tests for expiry calculation."""

    def test_calculate_expiry_permanent(self):
        """Test that permanent bans return 'never'."""
        self.assertEqual(player_manager.calculate_expiry(-1), 'never')
        self.assertEqual(player_manager.calculate_expiry(0), 'never')

    def test_calculate_expiry_timed(self):
        """Test that timed bans return ISO timestamp."""
        result = player_manager.calculate_expiry(60)  # 1 hour

        # Should be a valid ISO timestamp
        self.assertRegex(result, r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z')

        # Should be in the future
        expiry_dt = datetime.strptime(result, '%Y-%m-%dT%H:%M:%SZ')
        expiry_dt = expiry_dt.replace(tzinfo=timezone.utc)
        self.assertGreater(expiry_dt, datetime.now(timezone.utc))


class TestTimestampFormatting(unittest.TestCase):
    """Tests for timestamp formatting."""

    def test_format_timestamp(self):
        """Test formatting a valid timestamp."""
        # 2023-11-14 12:00:00 UTC = 1699963200
        result = player_manager.format_timestamp(1699963200)
        self.assertRegex(result, r'\d{2}/\d{2}/\d{4} \d{2}:\d{2}')

    def test_format_timestamp_invalid(self):
        """Test formatting an invalid timestamp."""
        result = player_manager.format_timestamp(-999999999999999)
        self.assertEqual(result, '?')


class BashRowReadTest(unittest.TestCase):
    """Regression: the players TUI reads the sync rows with bash `read`. With
    tab separated rows an empty GUID (lobby player) shifted minutes and join
    time into the GUID and minutes columns."""

    def test_lobby_player_fields_stay_in_place(self):
        import subprocess
        tmp = tempfile.mkdtemp()
        try:
            sessions = os.path.join(tmp, 'sessions.json')
            players = json.dumps({'players': [
                {'id': 0, 'name': 'Survivor', 'ping': 40, 'guid': 'a' * 32},
                {'id': 1, 'name': 'Lobby Guy', 'ping': -1, 'guid': ''},
            ]})
            script = ("python3 \"$1\" session --file \"$2\" --action sync --now 1700000000 | "
                      "while IFS=$'\\x1f' read -r pid pname pping pguid ptime pjoined; do "
                      "printf '%s|%s|%s|%s|%s|%s\\n' \"$pid\" \"$pname\" \"$pping\" \"$pguid\" \"$ptime\" \"$pjoined\"; done")
            manager = os.path.join(os.path.dirname(__file__), '../lib/player_manager.py')
            proc = subprocess.run(['bash', '-c', script, '_', manager, sessions],
                                  input=players, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            lines = proc.stdout.strip().split('\n')
            self.assertEqual(len(lines), 2)
            self.assertTrue(lines[0].startswith('0|Survivor|40|' + 'a' * 32 + '|0|'), lines[0])
            self.assertEqual(lines[1], '1|Lobby Guy|-1||0|?')
        finally:
            shutil.rmtree(tmp)


if __name__ == '__main__':
    unittest.main()
