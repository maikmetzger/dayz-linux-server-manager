#!/usr/bin/env python3
"""
Unit tests for ban_manager.py
"""

import unittest
import os
import json
import shutil
import tempfile
import sys
from datetime import datetime, timezone, timedelta

# Add lib to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../lib'))
import ban_manager


class TestBanRecord(unittest.TestCase):
    """Tests for BanRecord class."""

    def test_create_ban_record(self):
        """Test creating a ban record."""
        ban = ban_manager.BanRecord(
            guid='abc123def456',
            name='TestPlayer',
            reason='Cheating',
            duration_minutes=60
        )

        self.assertEqual(ban.guid, 'abc123def456')
        self.assertEqual(ban.name, 'TestPlayer')
        self.assertEqual(ban.reason, 'Cheating')
        self.assertEqual(ban.duration_minutes, 60)
        self.assertIsNotNone(ban.banned_at)
        self.assertNotEqual(ban.expires, 'never')

    def test_create_permanent_ban(self):
        """Test creating a permanent ban."""
        ban = ban_manager.BanRecord(
            guid='abc123',
            name='TestPlayer',
            duration_minutes=-1
        )

        self.assertEqual(ban.expires, 'never')

    def test_to_dict(self):
        """Test converting to dictionary."""
        ban = ban_manager.BanRecord(
            guid='abc123',
            name='TestPlayer',
            reason='Testing',
            duration_minutes=-1
        )

        d = ban.to_dict()

        self.assertEqual(d['guid'], 'abc123')
        self.assertEqual(d['name'], 'TestPlayer')
        self.assertEqual(d['reason'], 'Testing')
        self.assertEqual(d['duration_minutes'], -1)
        self.assertIn('banned_at', d)
        self.assertEqual(d['expires'], 'never')

    def test_from_dict(self):
        """Test creating from dictionary."""
        data = {
            'guid': 'xyz789',
            'name': 'LoadedPlayer',
            'reason': 'Loaded reason',
            'duration_minutes': 120,
            'banned_at': '2023-11-14T12:00:00Z',
            'expires': '2023-11-14T14:00:00Z'
        }

        ban = ban_manager.BanRecord.from_dict(data)

        self.assertEqual(ban.guid, 'xyz789')
        self.assertEqual(ban.name, 'LoadedPlayer')
        self.assertEqual(ban.reason, 'Loaded reason')
        self.assertEqual(ban.duration_minutes, 120)

    def test_is_expired_permanent(self):
        """Test that permanent bans never expire."""
        ban = ban_manager.BanRecord(
            guid='abc123',
            name='TestPlayer',
            duration_minutes=-1
        )

        self.assertFalse(ban.is_expired())

    def test_is_expired_active(self):
        """Test that active bans are not expired."""
        # Create a ban that expires in 1 hour
        future_expiry = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')

        ban = ban_manager.BanRecord(
            guid='abc123',
            name='TestPlayer',
            duration_minutes=60,
            expires=future_expiry
        )

        self.assertFalse(ban.is_expired())

    def test_is_expired_past(self):
        """Test that past bans are expired."""
        # Create a ban that expired 1 hour ago
        past_expiry = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')

        ban = ban_manager.BanRecord(
            guid='abc123',
            name='TestPlayer',
            duration_minutes=60,
            expires=past_expiry
        )

        self.assertTrue(ban.is_expired())


class TestBanManager(unittest.TestCase):
    """Tests for BanManager class."""

    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.bans_file = os.path.join(self.test_dir, 'bans.json')

    def tearDown(self):
        shutil.rmtree(self.test_dir)

    def test_add_ban(self):
        """Test adding a ban."""
        manager = ban_manager.BanManager(self.bans_file)

        ban = manager.add_ban(
            guid='abc123',
            name='TestPlayer',
            reason='Testing',
            duration_minutes=-1
        )

        self.assertEqual(ban.guid, 'abc123')
        self.assertEqual(len(manager.bans), 1)

    def test_add_ban_replaces_existing(self):
        """Test that adding a ban for the same GUID replaces the old one."""
        manager = ban_manager.BanManager(self.bans_file)

        manager.add_ban(guid='abc123', name='Player1', reason='First ban')
        manager.add_ban(guid='abc123', name='Player1', reason='Second ban')

        self.assertEqual(len(manager.bans), 1)
        self.assertEqual(manager.bans[0].reason, 'Second ban')

    def test_remove_ban(self):
        """Test removing a ban."""
        manager = ban_manager.BanManager(self.bans_file)
        manager.add_ban(guid='abc123', name='TestPlayer')

        result = manager.remove_ban('abc123')

        self.assertTrue(result)
        self.assertEqual(len(manager.bans), 0)

    def test_remove_ban_not_found(self):
        """Test removing a non-existent ban."""
        manager = ban_manager.BanManager(self.bans_file)

        result = manager.remove_ban('nonexistent')

        self.assertFalse(result)

    def test_get_ban(self):
        """Test getting a ban by GUID."""
        manager = ban_manager.BanManager(self.bans_file)
        manager.add_ban(guid='abc123', name='TestPlayer', reason='Test')

        ban = manager.get_ban('abc123')

        self.assertIsNotNone(ban)
        self.assertEqual(ban.name, 'TestPlayer')

    def test_get_ban_not_found(self):
        """Test getting a non-existent ban."""
        manager = ban_manager.BanManager(self.bans_file)

        ban = manager.get_ban('nonexistent')

        self.assertIsNone(ban)

    def test_list_bans(self):
        """Test listing all bans."""
        manager = ban_manager.BanManager(self.bans_file)
        manager.add_ban(guid='player1', name='Player1')
        manager.add_ban(guid='player2', name='Player2')
        manager.add_ban(guid='player3', name='Player3')

        bans = manager.list_bans()

        self.assertEqual(len(bans), 3)

    def test_get_expired_bans(self):
        """Test getting expired bans."""
        manager = ban_manager.BanManager(self.bans_file)

        # Add permanent ban (never expires)
        manager.add_ban(guid='permanent', name='Permanent', duration_minutes=-1)

        # Add expired ban
        past_expiry = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
        expired_ban = ban_manager.BanRecord(
            guid='expired',
            name='Expired',
            expires=past_expiry
        )
        manager.bans.append(expired_ban)

        expired = manager.get_expired_bans()

        self.assertEqual(len(expired), 1)
        self.assertEqual(expired[0].guid, 'expired')

    def test_remove_expired_bans(self):
        """Test removing all expired bans."""
        manager = ban_manager.BanManager(self.bans_file)

        # Add permanent ban
        manager.add_ban(guid='permanent', name='Permanent', duration_minutes=-1)

        # Add expired ban
        past_expiry = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
        expired_ban = ban_manager.BanRecord(
            guid='expired',
            name='Expired',
            expires=past_expiry
        )
        manager.bans.append(expired_ban)

        removed = manager.remove_expired_bans()

        self.assertEqual(len(removed), 1)
        self.assertEqual(removed[0], 'expired')
        self.assertEqual(len(manager.bans), 1)
        self.assertEqual(manager.bans[0].guid, 'permanent')

    def test_count(self):
        """Test counting bans."""
        manager = ban_manager.BanManager(self.bans_file)
        self.assertEqual(manager.count(), 0)

        manager.add_ban(guid='player1', name='Player1')
        self.assertEqual(manager.count(), 1)

        manager.add_ban(guid='player2', name='Player2')
        self.assertEqual(manager.count(), 2)

    def test_persistence(self):
        """Test that bans are persisted to file."""
        manager = ban_manager.BanManager(self.bans_file)
        manager.add_ban(guid='persistent', name='PersistentPlayer', reason='Will persist')

        # Create a new manager and verify data is loaded
        manager2 = ban_manager.BanManager(self.bans_file)
        self.assertEqual(len(manager2.bans), 1)
        self.assertEqual(manager2.bans[0].guid, 'persistent')
        self.assertEqual(manager2.bans[0].name, 'PersistentPlayer')


class TestDurationParsing(unittest.TestCase):
    """Tests for duration parsing in ban_manager."""

    def test_parse_duration_minutes(self):
        """Test parsing minute durations."""
        result = ban_manager.parse_duration('30m')
        self.assertEqual(result['minutes'], 30)
        self.assertEqual(result['human'], '30 minutes')

    def test_parse_duration_hours(self):
        """Test parsing hour durations."""
        result = ban_manager.parse_duration('2h')
        self.assertEqual(result['minutes'], 120)
        self.assertEqual(result['human'], '2 hours')

    def test_parse_duration_days(self):
        """Test parsing day durations."""
        result = ban_manager.parse_duration('7d')
        self.assertEqual(result['minutes'], 7 * 24 * 60)
        self.assertEqual(result['human'], '7 days')

    def test_parse_duration_permanent(self):
        """Test parsing permanent duration."""
        for perm in ['perm', 'permanent', '-1', '']:
            result = ban_manager.parse_duration(perm)
            self.assertEqual(result['minutes'], -1)
            self.assertEqual(result['human'], 'permanent')


if __name__ == '__main__':
    unittest.main()
