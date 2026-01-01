#!/usr/bin/env bash
# Debug script for CE detection
# Usage: ./debug_ce_scan.sh /path/to/server_instance

INSTANCE_DIR="$1"

if [[ -z "$INSTANCE_DIR" ]]; then
    echo "Usage: $0 <instance_dir>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# Source libraries
source "${SCRIPT_DIR}/lib/colors.sh"
source "${SCRIPT_DIR}/lib/tui.sh"
source "${SCRIPT_DIR}/lib/dialogs.sh"
source "${SCRIPT_DIR}/lib/mod_config.sh"
source "${SCRIPT_DIR}/lib/workshop.sh" 

echo "=== Debug CE Detection ==="
echo "Instance Dir: $INSTANCE_DIR"
echo "Script Dir: $SCRIPT_DIR"

WORKSHOP_DIR="${INSTANCE_DIR}/serverfiles/steamapps/workshop/content/221100"
echo "Workshop Dir: $WORKSHOP_DIR"

if [[ ! -d "$WORKSHOP_DIR" ]]; then
    echo "ERROR: Workshop dir does not exist!"
    exit 1
fi

MODS_FILE="${INSTANCE_DIR}/data/config/mods.txt"
SERVERMODS_FILE="${INSTANCE_DIR}/data/config/servermods.txt"

echo "Mods File: $MODS_FILE"
[[ -f "$MODS_FILE" ]] && echo "  (Exists)" || echo "  (Missing)"

echo "--- Linked CE Files ---"
get_linked_ce_files "$INSTANCE_DIR"
echo ""

echo "--- Scanning Mods for CE Files ---"
# Run with python directly to see stderr
cat <<EOF | python3
import os
import json
import subprocess
import sys

workshop_dir = "$WORKSHOP_DIR"
instance_dir = "$INSTANCE_DIR"
mods_file = "$MODS_FILE"
servermods_file = "$SERVERMODS_FILE"
script_dir = "$SCRIPT_DIR"

print(f"DEBUG: Checking mods in {workshop_dir}")

mod_ids = set()
for f in [mods_file, servermods_file]:
    if os.path.exists(f):
        print(f"DEBUG: Reading {f}")
        with open(f) as fp:
            for line in fp:
                parts = line.strip().split('|')
                if parts and parts[0].strip().isdigit():
                    mod_ids.add(parts[0].strip())

print(f"DEBUG: Found {len(mod_ids)} mod IDs: {mod_ids}")

results = []
for mod_id in sorted(mod_ids):
    mod_folder = os.path.join(workshop_dir, mod_id)
    if not os.path.isdir(mod_folder):
        print(f"DEBUG: Mod folder not found: {mod_folder}")
        continue
    
    print(f"DEBUG: Scanning mod {mod_id}...")
    for root, dirs, files in os.walk(mod_folder):
        for fname in files:
            if not fname.lower().endswith('.xml'):
                continue
            
            fpath = os.path.join(root, fname)
            parser_script = os.path.join(script_dir, 'lib', 'xml_parser.py')
            
            try:
                cmd = ['python3', parser_script, 'detect-ce-type', fpath]
                print(f"DEBUG: Running {cmd}")
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
                ce_type = result.stdout.strip()
                if ce_type:
                    print(f"DEBUG: Found CE file: {fname} ({ce_type})")
                    results.append({"file": fname, "type": ce_type})
                else:
                    if result.stderr:
                         print(f"DEBUG: Parser stderr: {result.stderr}")
            except Exception as e:
                print(f"DEBUG: Error: {e}")

print(f"DEBUG: Total CE files found: {len(results)}")
print(json.dumps(results, indent=2))
EOF
