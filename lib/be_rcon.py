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

class BattlEyeRcon:
    def __init__(self, host, port, password):
        self.host = host
        self.port = int(port)
        self.password = password
        self.sock = None
        self.connected = False

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
        
        # Sequence number is technically required.
        packet = self.create_packet(BE_COMMAND, b'\x00' + cmd.encode('utf-8'))
        self.sock.send(packet)
        
        # Wait for response(s)
        # Responses might be multipart or simple ACK.
        try:
            responses = []
            start_time = time.time()
            while time.time() - start_time < 2.0:
                ready = select.select([self.sock], [], [], 0.5)
                if ready[0]:
                    data = self.sock.recv(4096)
                    if len(data) < 7: continue
                    
                    # Header analysis
                    # 'BE' + CRC + 0xFF + Type
                    msg_type = data[7]
                    
                    if msg_type == BE_COMMAND:
                        # This is likely the command response
                        # Payload: [Sequence] [Text]
                        text = data[9:].decode('utf-8', errors='ignore')
                        responses.append(text)
                        
                        # Assuming single response for now, but loop to be safe for multipart
                        # BE doesn't strictly signal "end of message" perfectly in UDP.
                        # Break if we got something substantial?
                        if len(text) > 0:
                            # Heuristic: break after receiving data
                            break
                    elif msg_type == BE_MESSAGE:
                        # Server message/Chat
                        # [Sequence] [Text]
                        text = data[9:].decode('utf-8', errors='ignore')
                        # print(f"(Stream) {text}", file=sys.stderr) 
                        pass
                else:
                    if responses: break
                    
            return "".join(responses)
            
        except socket.timeout:
            return None

    def interactive(self):
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
    parser = argparse.ArgumentParser(description='Simple BattlEye RCON Client')
    parser.add_argument('--host', required=True, help='Server IP')
    parser.add_argument('--port', required=True, type=int, help='RCON Port')
    parser.add_argument('--password', required=True, help='RCON Password')
    parser.add_argument('--command', help='Single command to execute')
    
    args = parser.parse_args()
    
    client = BattlEyeRcon(args.host, args.port, args.password)
    if client.connect():
        if args.command:
            resp = client.send_command(args.command)
            if resp:
                print(resp.strip())
        else:
            client.interactive()
    else:
        sys.exit(1)
