#!/usr/bin/env python3
import socket
import struct
import sys
import argparse
import time
import select
import hashlib
import os
import re

# BattlEye RCON Protocol Constants
BE_LOGIN = 0x00
BE_COMMAND = 0x01
BE_MESSAGE = 0x02

# One row of the BE 'players' reply, e.g.
#   0   1.2.3.4:2304   45   0123...cdef(OK) Name
#   1   1.2.3.4:2304   -1   -(?) Name (Lobby)
# Lobby/unverified players have no GUID yet ('-'), a '?' status and may
# report a negative ping, so all three are optional here.
PLAYER_LINE_RE = re.compile(
    r'^\s*(?P<id>\d+)\s+(?P<ip>\S+)\s+(?P<ping>-?\d+)\s+'
    r'(?P<guid>[a-f0-9]+|-)(?:\((?P<status>[^)]*)\))?\s+(?P<name>.+?)\s*$',
    re.IGNORECASE)
LOBBY_SUFFIX = '(Lobby)'


def player_from_match(match):
    """Turn a PLAYER_LINE_RE match into the player dict used by the TUI."""
    name = match.group('name')
    status = match.group('status') or ''
    if name.endswith(LOBBY_SUFFIX):
        name = name[:-len(LOBBY_SUFFIX)].rstrip()
        status = 'Lobby'
    guid = match.group('guid')
    ip_port = match.group('ip')
    return {
        "id": int(match.group('id')),
        "name": name,
        "ping": int(match.group('ping')),
        "guid": '' if guid == '-' else guid,
        "ip": ip_port.split(':')[0] if ':' in ip_port else ip_port,
        "status": status,
    }


class ResponseAssembler:
    """Collects the command-response packets for one command.

    BE packet layout: 'BE' + CRC32 (4) + 0xFF + type + sequence + payload.
    A multipart reply marks the payload with 0x00 followed by the total
    number of parts and the index of this part; the text follows after.
    Parts are kept as bytes and decoded once at the end, so a UTF-8
    character split across two packets survives. Packets whose sequence
    byte does not match the command are late replies and are ignored.
    """
    MULTIPART_MARKER = 0x00
    HEADER_LEN = 9  # 'BE' + CRC32 + 0xFF + type + sequence
    SEQ_OFFSET = 8

    def __init__(self, expected_seq=None):
        self.expected_seq = expected_seq
        self.single = None
        self.parts = {}
        self.total = None

    @property
    def started(self):
        return self.single is not None or bool(self.parts)

    @property
    def complete(self):
        if self.single is not None:
            return True
        return self.total is not None and len(self.parts) >= self.total

    def feed(self, data):
        """Feed one raw packet. Returns True once the reply is complete."""
        if len(data) < self.HEADER_LEN or data[7] != BE_COMMAND:
            return False  # too short, or a server message (chat)
        if self.expected_seq is not None and data[self.SEQ_OFFSET] != self.expected_seq:
            return False  # late reply to an earlier command
        payload = data[self.HEADER_LEN:]
        if len(payload) >= 3 and payload[0] == self.MULTIPART_MARKER:
            self.total = payload[1]
            self.parts[payload[2]] = payload[3:]
            return self.complete
        self.single = payload
        return True

    def text(self):
        """The decoded reply, or None while parts are still missing."""
        if not self.complete:
            return None
        if self.single is not None:
            return self.single.decode('utf-8', errors='ignore')
        return b"".join(self.parts[i] for i in sorted(self.parts)).decode('utf-8', errors='ignore')


class BattlEyeRcon:
    def __init__(self, host, port, password, debug=False):
        self.host = host
        self.port = int(port)
        self.password = password
        self.sock = None
        self.connected = False
        self.sequence = 0  # BattlEye command sequence number
        self.debug = debug

    def crc32(self, data):
        # CRC32 of data (as bytes)
        # 0xffffffff is the initial value, specific to BE logic requires masking
        import zlib
        return zlib.crc32(data) & 0xFFFFFFFF

    def create_packet(self, command_type, payload=b''):
        # Packet Header: "BE" (2 bytes)
        # CRC32 (4 bytes) - of the rest of the packet
        # 0xFF (1 byte)
        # Command Type (1 byte)
        # Payload (variable)
        
        body = b'\xff' + struct.pack('B', command_type) + payload
        
        # Calculate CRC32 of the body
        checksum = self.crc32(body)
        
        # Full packet: 'BE' + CRC32 + body
        header = b'BE' + struct.pack('<I', checksum)
        return header + body

    def connect(self):
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            # Allow rapid reconnection by reusing address
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.sock.settimeout(3.0)
            self.sock.connect((self.host, self.port))
            
            # Send Login Packet
            packet = self.create_packet(BE_LOGIN, self.password.encode('utf-8'))
            self.sock.send(packet)
            
            # Wait for response
            resp = self.sock.recv(1024)
            if len(resp) < 9:
                return False
                
            # Verify response header 'BE' and CRC... strictly we should, but let's check payload
            # Resp: 'BE' + CRC + 0xFF + 0x00 + Result(1 byte)
            # Result: 0x01 = Success, 0x00 = Fail
            
            result = resp[8]
            if result == 0x01:
                self.connected = True
                if self.debug:
                    print(f"[DEBUG] BE protocol login successful", file=sys.stderr)
                return True
            else:
                print("Login Failed: Incorrect password or banned IP.", file=sys.stderr)
                return False
        except Exception as e:
            print(f"Connection Error: {e}", file=sys.stderr)
            return False

    def send_command(self, cmd):
        if not self.connected:
            return None
            
        # Command packet: sequence number is strictly needed for reliability in full implementation,
        # but for simple command-response, BE often accepts commands directly if traffic is low.
        # Actually, BE RCON over UDP requires Sequence Numbers for commands (Type 0x01).
        # However, for a simple "fire and forget" or single command, specific sequence logic 
        # is complex (need to track server sequence).
        #
        # Simplified approach: Sending command.
        
        # NOTE: BattlEye UDP protocol is complex with sequence numbers.
        # However, many simple clients just send the command. Let's try standard packet.
        # Format: 0xFF 0x01 [Sequence 1 byte] [Command String]
        
        #Wait, standard BE RCON documentation says:
        # 0xFF 0x01 [Sequence Number 1 byte] [Command]
        # BUT, the login packet doesn't use sequence numbers.
        
        # Let's try sending with sequence 0 or standard implementation.
        # Actually, handling semi-reliable UDP here is tricky in a small script.
        # Let's assume we can just send.
        
        # Sequence number is required and must increment for each command
        seq_byte = bytes([self.sequence & 0xFF])
        if self.debug:
            shown = '#login ******' if cmd.startswith('#login') else cmd
            print(f"[DEBUG] Sending command (seq={self.sequence}): {shown}", file=sys.stderr)
        self.sequence = (self.sequence + 1) % 256  # Wrap at 256
        packet = self.create_packet(BE_COMMAND, seq_byte + cmd.encode('utf-8'))
        self.sock.send(packet)
        
        # Wait for the reply. It is one packet, or a multipart set that we
        # reassemble. Returns None when no reply arrived at all.
        try:
            reply = ResponseAssembler(expected_seq=seq_byte[0])
            start_time = time.time()
            while time.time() - start_time < 2.0:
                ready = select.select([self.sock], [], [], 0.5)
                if not ready[0]:
                    # Silence after a partial reply: stop waiting for the rest
                    if reply.started:
                        break
                    continue
                if reply.feed(self.sock.recv(4096)):
                    break

            if not reply.complete:
                if self.debug and reply.started:
                    print("[DEBUG] Incomplete multipart reply discarded", file=sys.stderr)
                return None
            return reply.text()

        except socket.timeout:
            if self.debug:
                print(f"[DEBUG] Socket timeout waiting for response", file=sys.stderr)
            return None
    
    def close(self):
        """Close the RCON connection."""
        if self.sock:
            try:
                self.sock.close()
            except:
                pass
            self.sock = None
            self.connected = False

    def parse_players_response(self, response):
        """
        Parse the 'players' command response into structured data.
        Format: Players on server:
        [#] [IP:Port] [Ping] [GUID] [Name]
        0   IP:Port   45    abc123... PlayerName
        """
        import re
        import json
        
        players = []
        if response is None:
            # No reply at all is a failure, not an empty server
            return json.dumps({"count": 0, "players": [], "error": "No reply from server (connection lost or timeout)"})
        if not response:
            return json.dumps({"count": 0, "players": [], "error": None})
        
        lines = response.strip().split('\n')
        # Skip header line if present
        for line in lines:
            # Match pattern: ID  IP:Port  Ping  GUID  Name
            # Example: 0   127.0.0.1:2304  45    abc123def456789abc123def45(OK) PlayerName
            match = PLAYER_LINE_RE.match(line)
            if match:
                players.append(player_from_match(match))
        
        return json.dumps({"count": len(players), "players": players, "error": None})

    @staticmethod
    def _action_result(replies, response=None):
        """Build the JSON result of an action.

        replies are the raw send_command() results. None means the server
        never answered (not connected, or timeout), so the action failed.
        """
        import json
        ok = all(r is not None for r in replies)
        if response is None:
            response = replies[0] if len(replies) == 1 else ", ".join(str(r) for r in replies)
        return json.dumps({
            "success": ok,
            "response": response,
            "error": None if ok else "No reply from server (connection lost or timeout)"
        })

    def action_players(self):
        """Get list of online players as JSON."""
        resp = self.send_command("players")
        return self.parse_players_response(resp)
    
    def action_kick(self, player_name, reason=""):
        """Kick a player by NAME."""
        import json
        # BattlEye #kick uses player name (reason not supported)
        cmd = f"#kick {player_name}"
        resp = self.send_command(cmd)
        return self._action_result([resp])
    
    def action_ban(self, player_name, player_guid):
        """Ban an ONLINE player: kick them, then add GUID to ban list.
        
        Args:
            player_name: Player name for kick
            player_guid: BattlEye GUID for ban list
        
        Strategy: Kick first (reliable), then addBan GUID, then persist.
        """
        import json
        # Step 1: Kick the player (this works!)
        kick_cmd = f"#kick {player_name}"
        kick_resp = self.send_command(kick_cmd)
        
        # Step 2: Add GUID to ban list (for when they try to rejoin)
        ban_cmd = f"addBan {player_guid} 0"
        ban_resp = self.send_command(ban_cmd)
        
        # Step 3: Persist bans to bans.txt
        write_resp = self.send_command("writeBans")

        # Every step must have been answered by the server, otherwise the
        # ban did not happen and must not be reported as success.
        return self._action_result([kick_resp, ban_resp, write_resp],
                                   f"Kicked: {kick_resp}, Banned: {ban_resp}")
    
    def action_ban_by_guid(self, player_guid):
        """Ban a player by GUID (for bans.txt management)."""
        import json
        cmd = f"addBan {player_guid} -1"
        resp = self.send_command(cmd)
        return self._action_result([resp])
    
    def action_unban(self, player_guid):
        """Unban a player by GUID/Steam64ID."""
        import json
        cmd = f"#exec unban {player_guid}"
        resp = self.send_command(cmd)
        return self._action_result([resp])
    
    def action_say(self, message, player_id=-1):
        """Send a message to all players (-1) or specific player."""
        import json
        cmd = f"say {player_id} {message}"
        resp = self.send_command(cmd)
        return self._action_result([resp])
    
    def action_loadbans(self):
        """Reload bans.txt file."""
        import json
        # BattlEye command to reload bans from bans.txt
        resp = self.send_command("loadBans")
        return self._action_result([resp])
    
    # ==========================================================================
    # Server Control Actions
    # ==========================================================================
    
    def action_shutdown(self):
        """Graceful server shutdown via #shutdown."""
        import json
        resp = self.send_command("#shutdown")
        return self._action_result([resp])
    
    def action_lock(self):
        """Lock server - prevent new connections."""
        import json
        resp = self.send_command("#lock")
        return self._action_result([resp])
    
    def action_unlock(self):
        """Unlock server - allow new connections."""
        import json
        resp = self.send_command("#unlock")
        return self._action_result([resp])
    
    def action_monitor(self, seconds=5):
        """Get performance monitoring data."""
        import json
        resp = self.send_command(f"#monitor {seconds}")
        return self._action_result([resp])
    
    def action_login(self, admin_password=None):
        """Explicit RCON admin login using DayZ passwordAdmin (not RCON password)."""
        import json
        # Use admin_password if provided, otherwise fall back to RCON password
        # NOTE: These are different! passwordAdmin (serverDZ.cfg) is for #login,
        #       RConPassword (BEServer_x64.cfg) is for protocol auth.
        password = admin_password if admin_password else self.password
        resp = self.send_command(f"#login {password}")
        if self.debug:
            print(f"[DEBUG] #login response: {resp}", file=sys.stderr)
        return self._action_result([resp])

    def interactive(self):
        """Interactive RCON console mode."""
        print(f"Connected to {self.host}:{self.port} (Type 'exit' to quit)")
        while True:
            try:
                cmd = input("RCON> ")
                if cmd.strip().lower() in ['exit', 'quit']:
                    break
                if not cmd.strip():
                    continue
                    
                resp = self.send_command(cmd)
                if resp:
                    print(resp.strip())
            except KeyboardInterrupt:
                break
            except Exception as e:
                print(f"Error: {e}")
                break

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='BattlEye RCON Client for DayZ')
    parser.add_argument('--host', required=True, help='Server IP')
    parser.add_argument('--port', required=True, type=int, help='RCON Port')
    parser.add_argument('--password', help='RCON password (prefer the RCON_PASSWORD env var: argv is readable by other processes)')
    parser.add_argument('--password-env', help='Name of the environment variable holding the RCON password (default: RCON_PASSWORD)')
    parser.add_argument('--command', help='Single raw command to execute')
    
    # Action-based interface for TUI integration
    parser.add_argument('--action', 
                        choices=['players', 'kick', 'ban', 'ban_by_guid', 'unban', 
                                 'say', 'loadbans', 'shutdown', 'lock', 'unlock', 'monitor'],
                        help='Predefined action with JSON output')
    parser.add_argument('--player-id', type=str, help='Player ID (deprecated)')
    parser.add_argument('--player-name', type=str, help='Player name for kick/ban_by_name')
    parser.add_argument('--player-guid', type=str, help='Player GUID/Steam64ID for ban/unban')
    parser.add_argument('--message', type=str, help='Message for say action')
    parser.add_argument('--reason', type=str, default='', help='Reason for kick/ban (not used)')
    parser.add_argument('--duration-minutes', type=int, default=0, help='Ban duration in minutes (0 = permanent)')
    parser.add_argument('--seconds', type=int, default=5, help='Seconds for monitor action')
    parser.add_argument('--admin-password', type=str, help='DayZ admin password (passwordAdmin from serverDZ.cfg) for #login command')
    parser.add_argument('--admin-password-env', type=str, help='Name of the environment variable holding the DayZ admin password (preferred: argv is visible to other processes)')
    parser.add_argument('--debug', action='store_true', help='Enable debug output to stderr')
    
    args = parser.parse_args()

    # Password sources, in order: named env var (--password-env), --password, RCON_PASSWORD
    env_name = args.password_env or 'RCON_PASSWORD'
    if args.password_env:
        password = os.environ.get(args.password_env, '')
    else:
        password = args.password or os.environ.get('RCON_PASSWORD', '')
    if not password:
        print(f'{{"success": false, "error": "Missing RCON password (env var {env_name} or --password)"}}')
        sys.exit(1)
    
    client = BattlEyeRcon(args.host, args.port, password, debug=args.debug)
    if client.connect():
        if args.action:
            # Auto-login before action commands using DayZ admin password
            # This is passwordAdmin from serverDZ.cfg, NOT the RCON password
            admin_password = os.environ.get(args.admin_password_env, '') if args.admin_password_env else args.admin_password
            if admin_password:
                client.action_login(admin_password)
            
            # Action-based mode with JSON output
            if args.action == 'players':
                print(client.action_players())
            elif args.action == 'kick':
                name = args.player_name or args.player_id
                if not name:
                    print('{"success": false, "error": "Missing --player-name"}')
                    sys.exit(1)
                print(client.action_kick(name))
            elif args.action == 'ban':
                name = args.player_name
                guid = args.player_guid
                if not name or not guid:
                    print('{"success": false, "error": "Missing --player-name and --player-guid"}')
                    sys.exit(1)
                print(client.action_ban(name, guid))
            elif args.action == 'ban_by_guid':
                guid = args.player_guid
                if not guid:
                    print('{"success": false, "error": "Missing --player-guid"}')
                    sys.exit(1)
                print(client.action_ban_by_guid(guid))
            elif args.action == 'unban':
                guid = args.player_guid or args.player_id
                if not guid:
                    print('{"success": false, "error": "Missing --player-guid"}')
                    sys.exit(1)
                print(client.action_unban(guid))
            elif args.action == 'say':
                if not args.message:
                    print('{"success": false, "error": "Missing --message"}')
                    sys.exit(1)
                print(client.action_say(args.message))
            elif args.action == 'loadbans':
                print(client.action_loadbans())
            elif args.action == 'shutdown':
                print(client.action_shutdown())
            elif args.action == 'lock':
                print(client.action_lock())
            elif args.action == 'unlock':
                print(client.action_unlock())
            elif args.action == 'monitor':
                print(client.action_monitor(args.seconds))
        elif args.command:
            # Raw command mode
            resp = client.send_command(args.command)
            if resp:
                print(resp.strip())
        else:
            # Interactive mode
            client.interactive()
    else:
        import json
        print(json.dumps({"success": False, "error": "Connection failed"}))
        sys.exit(1)
