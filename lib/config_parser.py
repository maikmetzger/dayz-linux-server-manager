#!/usr/bin/env python3
"""
DayZ Config Parser - Unified parser for CFG, JSON, XML formats.
Used by the Server Manager's Config Editor.

Usage:
    python3 config_parser.py list <format> <path>
    python3 config_parser.py get <format> <path> <key>
    python3 config_parser.py set <format> <path> <key> <value>

Formats: cfg, json, xml

Output: JSON for easy bash parsing
    {"status": "ok", "keys": [...]}
    {"status": "ok", "value": "..."}
    {"status": "error", "message": "..."}
"""

import sys
import os
import re
import json
from typing import Dict, List, Tuple, Optional, Any


# =============================================================================
# CFG Parser (DayZ serverDZ.cfg format)
# =============================================================================
# Format: key = value;  or  key = "value";
# Comments: // comment

class CfgParser:
    """Parser for DayZ CFG files (key = value; format)"""
    
    # Regex patterns
    KEY_VALUE_PATTERN = re.compile(
        r'^(\s*)([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.+?)\s*;(.*)$'
    )
    
    def __init__(self, path: str):
        self.path = path
        self.lines: List[str] = []
        self.load()
    
    def load(self) -> None:
        """Load file contents."""
        if not os.path.exists(self.path):
            raise FileNotFoundError(f"Config file not found: {self.path}")
        with open(self.path, 'r', encoding='utf-8') as f:
            self.lines = f.readlines()
    
    def save(self) -> None:
        """Save file contents."""
        with open(self.path, 'w', encoding='utf-8') as f:
            f.writelines(self.lines)
    
    def _parse_value(self, raw: str) -> str:
        """Parse a value, removing quotes if present."""
        raw = raw.strip()
        # Handle quoted strings
        if (raw.startswith('"') and raw.endswith('"')) or \
           (raw.startswith("'") and raw.endswith("'")):
            return raw[1:-1]
        return raw
    
    def _format_value(self, value: str, original_raw: str) -> str:
        """Format a value for writing, preserving quote style."""
        original_raw = original_raw.strip()
        # If original was quoted, quote the new value too
        if original_raw.startswith('"'):
            return f'"{value}"'
        elif original_raw.startswith("'"):
            return f"'{value}'"
        # If it looks like a string (contains spaces or is non-numeric), quote it
        if not value.replace('.', '').replace('-', '').isdigit() and ' ' in value:
            return f'"{value}"'
        return value
    
    def list_keys(self) -> List[str]:
        """List all keys in the config file."""
        keys = []
        for line in self.lines:
            match = self.KEY_VALUE_PATTERN.match(line)
            if match:
                key = match.group(2)
                keys.append(key)
        return keys
    
    def get(self, key: str) -> Optional[str]:
        """Get a value by key."""
        for line in self.lines:
            match = self.KEY_VALUE_PATTERN.match(line)
            if match and match.group(2) == key:
                return self._parse_value(match.group(3))
        return None
    
    def get_all(self) -> Dict[str, str]:
        """Get all key-value pairs."""
        result = {}
        for line in self.lines:
            match = self.KEY_VALUE_PATTERN.match(line)
            if match:
                key = match.group(2)
                value = self._parse_value(match.group(3))
                result[key] = value
        return result
    
    def set(self, key: str, value: str) -> bool:
        """Set a value by key. Returns True if key was found and updated."""
        for i, line in enumerate(self.lines):
            match = self.KEY_VALUE_PATTERN.match(line)
            if match and match.group(2) == key:
                indent = match.group(1)
                original_raw = match.group(3)
                comment = match.group(4)
                formatted_value = self._format_value(value, original_raw)
                self.lines[i] = f"{indent}{key} = {formatted_value};{comment}\n"
                self.save()
                return True
        return False


# =============================================================================
# BEServer Parser (BattlEye config format: KEY VALUE)
# =============================================================================
# Format: KEY value  (space-separated, no = sign, no semicolon)

class BEServerParser:
    """Parser for BattlEye config files (KEY VALUE format)"""
    
    # Regex pattern for KEY VALUE format
    KEY_VALUE_PATTERN = re.compile(r'^([A-Za-z][A-Za-z0-9_]*)\s+(.*)$')
    
    def __init__(self, path: str):
        self.path = path
        self.lines: List[str] = []
        self.load()
    
    def load(self) -> None:
        """Load file contents."""
        if not os.path.exists(self.path):
            raise FileNotFoundError(f"Config file not found: {self.path}")
        with open(self.path, 'r', encoding='utf-8') as f:
            self.lines = f.readlines()
    
    def save(self) -> None:
        """Save file contents."""
        with open(self.path, 'w', encoding='utf-8') as f:
            f.writelines(self.lines)
    
    def list_keys(self) -> List[str]:
        """List all keys in the config file."""
        keys = []
        for line in self.lines:
            match = self.KEY_VALUE_PATTERN.match(line.strip())
            if match:
                keys.append(match.group(1))
        return keys
    
    def get(self, key: str) -> Optional[str]:
        """Get a value by key."""
        for line in self.lines:
            match = self.KEY_VALUE_PATTERN.match(line.strip())
            if match and match.group(1) == key:
                return match.group(2).strip()
        return None
    
    def get_all(self) -> Dict[str, str]:
        """Get all key-value pairs."""
        result = {}
        for line in self.lines:
            match = self.KEY_VALUE_PATTERN.match(line.strip())
            if match:
                result[match.group(1)] = match.group(2).strip()
        return result
    
    def set(self, key: str, value: str) -> bool:
        """Set a value by key. Returns True if key was found and updated."""
        for i, line in enumerate(self.lines):
            match = self.KEY_VALUE_PATTERN.match(line.strip())
            if match and match.group(1) == key:
                self.lines[i] = f"{key} {value}\n"
                self.save()
                return True
        # Key not found - add it
        self.lines.append(f"{key} {value}\n")
        self.save()
        return True


# =============================================================================
# JSON Parser (Placeholder for Phase 2)
# =============================================================================

class JsonParser:
    """Parser for JSON config files (Phase 2)."""
    
    def __init__(self, path: str):
        self.path = path
        raise NotImplementedError("JSON parser not yet implemented")


# =============================================================================
# XML Parser (Placeholder for Phase 3)
# =============================================================================

class XmlParser:
    """Parser for XML config files (Phase 3)."""
    
    def __init__(self, path: str):
        self.path = path
        raise NotImplementedError("XML parser not yet implemented")


# =============================================================================
# Main CLI Interface
# =============================================================================

def get_parser(fmt: str, path: str):
    """Factory function to get the right parser for a format."""
    parsers = {
        'cfg': CfgParser,
        'beserver': BEServerParser,
        'json': JsonParser,
        'xml': XmlParser,
    }
    if fmt not in parsers:
        raise ValueError(f"Unknown format: {fmt}. Supported: {list(parsers.keys())}")
    return parsers[fmt](path)


def output_json(data: dict) -> None:
    """Output result as JSON."""
    print(json.dumps(data))


def main():
    if len(sys.argv) < 4:
        output_json({
            "status": "error",
            "message": "Usage: config_parser.py <command> <format> <path> [key] [value]"
        })
        sys.exit(1)
    
    command = sys.argv[1]
    fmt = sys.argv[2]
    path = sys.argv[3]
    
    try:
        parser = get_parser(fmt, path)
        
        if command == "list":
            keys = parser.list_keys()
            output_json({"status": "ok", "keys": keys})
        
        elif command == "get":
            if len(sys.argv) < 5:
                output_json({"status": "error", "message": "Missing key argument"})
                sys.exit(1)
            key = sys.argv[4]
            value = parser.get(key)
            if value is not None:
                output_json({"status": "ok", "key": key, "value": value})
            else:
                output_json({"status": "error", "message": f"Key not found: {key}"})
                sys.exit(1)
        
        elif command == "getall":
            data = parser.get_all()
            output_json({"status": "ok", "data": data})
        
        elif command == "set":
            if len(sys.argv) < 6:
                output_json({"status": "error", "message": "Missing key or value argument"})
                sys.exit(1)
            key = sys.argv[4]
            value = sys.argv[5]
            if parser.set(key, value):
                output_json({"status": "ok", "message": f"Updated {key}"})
            else:
                output_json({"status": "error", "message": f"Key not found: {key}"})
                sys.exit(1)
        
        else:
            output_json({"status": "error", "message": f"Unknown command: {command}"})
            sys.exit(1)
    
    except FileNotFoundError as e:
        output_json({"status": "error", "message": str(e)})
        sys.exit(1)
    except NotImplementedError as e:
        output_json({"status": "error", "message": str(e)})
        sys.exit(1)
    except Exception as e:
        output_json({"status": "error", "message": f"Unexpected error: {e}"})
        sys.exit(1)


if __name__ == "__main__":
    main()
