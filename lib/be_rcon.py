#!/usr/bin/env python3
import socket
import struct
import sys
import argparse
import time
import select
import hashlib

# BattlEye RCON Protocol Constants
BE_LOGIN = 0x00
BE_COMMAND = 0x01
BE_MESSAGE = 0x02

class ResponseAssembler:
    """Collects the command-response packets for one command.

    BE packet layout: 'BE' + CRC32 (4) + 0xFF + type + sequence + payload.
    A multipart reply marks the payload with 0x00 followed by the total
    number of parts and the index of this part; the text follows after.
    """
    MULTIPART_MARKER = 0x00
    HEADER_LEN = 9  # 'BE' + CRC32 + 0xFF + type + sequence

    def __init__(self):
        self.single = None
        self.parts = {}
        self.total = None

    @property
    def started(self):
        return self.single is not None or bool(self.parts)

    def feed(self, data):
        """Feed one raw packet. Returns True once the reply is complete."""
        if len(data) < self.HEADER_LEN or data[7] != BE_COMMAND:
            # Too short, or a server message (chat) that is not our reply
            return False
        payload = data[self.HEADER_LEN:]
        if len(payload) >= 3 and payload[0] == self.MULTIPART_MARKER:
            self.total = payload[1]
            self.parts[payload[2]] = payload[3:].decode('utf-8', errors='ignore')
            return len(self.parts) >= self.total
        self.single = payload.decode('utf-8', errors='ignore')
        return True

    def text(self):
        if self.parts:
            return "".join(self.parts[i] for i in sorted(self.parts))
        return self.single or ""


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
            print(f"[DEBUG] Sending command (seq={self.sequence}): {cmd}", file=sys.stderr)
        self.sequence = (self.sequence + 1) % 256  # Wrap at 256
        packet = self.create_packet(BE_COMMAND, seq_byte + cmd.encode('utf-8'))
        self.sock.send(packet)
        
        # Wait for the reply. It is one packet, or a multipart set that we
        # reassemble. Returns None when no reply arrived at all.
        try:
            reply = ResponseAssembler()
            start_time = time.time()
            while time.time() - start_time < 2.0:
                ready = select.select([self.sock], [], [], 0.5)
                if not ready[0]:
                    # Silence after a partial reply: return what we have
                    if reply.started:
                        break
                    continue
                if reply.feed(self.sock.recv(4096)):
                    break

            return reply.text() if reply.started else None

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
        if not response:
            return json.dumps({"count": 0, "players": [], "error": None})
        
        lines = response.strip().split('\n')
        # Skip header line if present
        for line in lines:
            # Match pattern: ID  IP:Port  Ping  GUID  Name
            # Example: 0   127.0.0.1:2304  45    abc123def456789abc123def45(OK) PlayerName
            match = re.match(r'^\s*(\d+)\s+(\S+)\s+(\d+)\s+([a-f0-9]+)\((\w+)\)\s+(.+)$', line, re.IGNORECASE)
            if match:
                player_id = match.group(1)
                ip_port = match.group(2)
                ping = match.group(3)
                guid = match.group(4)
                status = match.group(5)
                name = match.group(6).strip()
                
                players.append({
                    "id": int(player_id),
                    "name": name,
                    "ping": int(ping),
                    "guid": guid,
                    "ip": ip_port.split(':')[0] if ':' in ip_port else ip_port,
                    "status": status
                })
        
        return json.dumps({"count": len(players), "players": players, "error": None})

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
        return json.dumps({"success": True, "response": resp, "error": None})
    
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
        self.send_command("writeBans")
        
        return json.dumps({
            "success": True, 
            "response": f"Kicked: {kick_resp}, Banned: {ban_resp}", 
            "error": None
        })
    
    def action_ban_by_guid(self, player_guid):
        """Ban a player by GUID (for bans.txt management)."""
        import json
        cmd = f"addBan {player_guid} -1"
        resp = self.send_command(cmd)
        return json.dumps({"success": True, "response": resp, "error": None})
    
    def action_unban(self, player_guid):
        """Unban a player by GUID/Steam64ID."""
        import json
        cmd = f"#exec unban {player_guid}"
        resp = self.send_command(cmd)
        return json.dumps({"success": True, "response": resp, "error": None})
    
    def action_say(self, message, player_id=-1):
        """Send a message to all players (-1) or specific player."""
        import json
        cmd = f"say {player_id} {message}"
        resp = self.send_command(cmd)
        return json.dumps({"success": True, "response": resp, "error": None})
    
    def action_loadbans(self):
        """Reload bans.txt file."""
        import json
        # BattlEye command to reload bans from bans.txt
        resp = self.send_command("loadBans")
        return json.dumps({"success": True, "response": resp, "error": None})
    
    # ==========================================================================
    # Server Control Actions
    # ==========================================================================
    
    def action_shutdown(self):
        """Graceful server shutdown via #shutdown."""
        import json
        resp = self.send_command("#shutdown")
        return json.dumps({"success": True, "response": resp, "error": None})
    
    def action_lock(self):
        """Lock server - prevent new connections."""
        import json
        resp = self.send_command("#lock")
        return json.dumps({"success": True, "response": resp, "error": None})
    
    def action_unlock(self):
        """Unlock server - allow new connections."""
        import json
        resp = self.send_command("#unlock")
        return json.dumps({"success": True, "response": resp, "error": None})
    
    def action_monitor(self, seconds=5):
        """Get performance monitoring data."""
        import json
        resp = self.send_command(f"#monitor {seconds}")
        return json.dumps({"success": True, "response": resp, "error": None})
    
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
        return json.dumps({"success": True, "response": resp, "error": None})

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
    parser.add_argument('--password', required=True, help='RCON Password')
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
    parser.add_argument('--debug', action='store_true', help='Enable debug output to stderr')
    
    args = parser.parse_args()
    
    client = BattlEyeRcon(args.host, args.port, args.password, debug=args.debug)
    if client.connect():
        if args.action:
            # Auto-login before action commands using DayZ admin password
            # This is passwordAdmin from serverDZ.cfg, NOT the RCON password
            if args.admin_password:
                client.action_login(args.admin_password)
            
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
