#!/usr/bin/env python3
"""Regression tests for lib/be_rcon.py (BattlEye RCON client)."""
import os
import sys
import json
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib'))
import be_rcon  # noqa: E402


def cmd_packet(payload):
    """Build a BE command-response packet with sequence byte 0x01."""
    return be_rcon.BattlEyeRcon('127.0.0.1', 1, 'x').create_packet(be_rcon.BE_COMMAND, b'\x01' + payload)


class ResponseAssemblerTest(unittest.TestCase):
    def test_single_packet_reply(self):
        r = be_rcon.ResponseAssembler()
        self.assertTrue(r.feed(cmd_packet(b'hello')))
        self.assertEqual(r.text(), 'hello')

    def test_empty_ack_counts_as_reply(self):
        r = be_rcon.ResponseAssembler()
        self.assertTrue(r.feed(cmd_packet(b'')))
        self.assertTrue(r.started)
        self.assertEqual(r.text(), '')

    def test_multipart_is_joined_in_order_without_header_bytes(self):
        r = be_rcon.ResponseAssembler()
        # total=3, parts arrive out of order
        self.assertFalse(r.feed(cmd_packet(b'\x00\x03\x01' + b'BBB')))
        self.assertFalse(r.feed(cmd_packet(b'\x00\x03\x00' + b'AAA')))
        self.assertTrue(r.feed(cmd_packet(b'\x00\x03\x02' + b'CCC')))
        self.assertEqual(r.text(), 'AAABBBCCC')

    def test_server_messages_are_ignored(self):
        r = be_rcon.ResponseAssembler()
        chat = be_rcon.BattlEyeRcon('127.0.0.1', 1, 'x').create_packet(be_rcon.BE_MESSAGE, b'\x05(Global) hi')
        self.assertFalse(r.feed(chat))
        self.assertFalse(r.started)

    def test_short_garbage_is_ignored(self):
        r = be_rcon.ResponseAssembler()
        self.assertFalse(r.feed(b'BE'))
        self.assertFalse(r.started)


class ActionResultTest(unittest.TestCase):
    """Actions must not claim success when the server never answered."""

    def _client(self, reply):
        c = be_rcon.BattlEyeRcon('127.0.0.1', 1, 'x')
        c.send_command = lambda cmd: reply
        return c

    def test_ban_fails_when_server_never_answers(self):
        r = json.loads(self._client(None).action_ban('Bob', 'abc'))
        self.assertFalse(r['success'])
        self.assertIsNotNone(r['error'])

    def test_ban_succeeds_on_empty_ack(self):
        r = json.loads(self._client('').action_ban('Bob', 'abc'))
        self.assertTrue(r['success'])
        self.assertIsNone(r['error'])

    def test_kick_reports_failure_without_reply(self):
        self.assertFalse(json.loads(self._client(None).action_kick('Bob'))['success'])

    def test_monitor_passes_reply_through(self):
        r = json.loads(self._client('FPS 42').action_monitor(1))
        self.assertTrue(r['success'])
        self.assertEqual(r['response'], 'FPS 42')


if __name__ == '__main__':
    unittest.main()
