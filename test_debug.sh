#!/usr/bin/env bash
# test_debug.sh

# 1. Setup Env
export SCRIPT_DIR="$(pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/mod_config.sh"

echo "SCRIPT_DIR: $SCRIPT_DIR"
echo "PYTHONPATH check:"
python3 -c "import sys; print(sys.path)"

# 2. Identify Instance
INSTANCE_DIR="$1"
if [[ -z "$INSTANCE_DIR" ]]; then
    # Try current dir
    if [[ -d "${SCRIPT_DIR}/serverfiles" ]]; then
       INSTANCE_DIR="${SCRIPT_DIR}"
       echo "Auto-detected instance at current dir."
    else
       echo "Usage: ./test_debug.sh <path_to_instance>"
       exit 1
    fi
fi

# 3. Setup Paths
WORKSHOP_DIR="${INSTANCE_DIR}/serverfiles/steamapps/workshop/content/221100"
echo "Instance: $INSTANCE_DIR"
echo "Workshop: $WORKSHOP_DIR"

if [[ ! -d "$WORKSHOP_DIR" ]]; then
    echo "ERROR: Workshop dir not found."
    # List what IS there
    ls -l "${INSTANCE_DIR}/serverfiles/steamapps/workshop/content" 2>/dev/null
    exit 1
fi

# 4. Run Scan (Verbose)
echo "--- Running Scan ---"
# Capture output
OUTPUT=$(scan_mods_for_ce_files "$INSTANCE_DIR" "$WORKSHOP_DIR" 2> scan_error.log)
RET=$?

echo "Exit Code: $RET"
echo "--- STDERR Content (scan_error.log) ---"
cat scan_error.log
echo "--- STDOUT Content ---"
echo "$OUTPUT"

echo "--- JSON Validation ---"
echo "$OUTPUT" | python3 -c "import sys, json; print(f'Valid JSON items: {len(json.load(sys.stdin))}')" 2>/dev/null || echo "Invalid JSON"
