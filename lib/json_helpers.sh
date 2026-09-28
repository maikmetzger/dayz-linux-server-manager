#!/usr/bin/env bash
# =============================================================================
# DayZ Server Scripts - JSON Helpers
# =============================================================================
# Secure JSON parsing using Python (no jq dependency)
# SECURITY: All functions pass data via stdin/files to avoid shell injection
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_JSON_HELPERS_LOADED:-}" ]] && return 0
_DAYZ_JSON_HELPERS_LOADED=1

# =============================================================================
# Core JSON Functions
# =============================================================================

# Parse JSON field using Python (SECURE - uses stdin)
# Usage: value=$(echo "$json" | json_get ".field" "default")
# Or:    value=$(json_get_str "$json" ".field" "default")
json_get_str() {
    local json="$1"
    local path="$2"
    local default="${3:-}"

    echo "$json" | python3 -c "
import json
import sys

try:
    data = json.load(sys.stdin)
    keys = sys.argv[1].lstrip('.').split('.')
    result = data
    for key in keys:
        if key:
            result = result.get(key, None) if isinstance(result, dict) else None
            if result is None:
                break
    if result is None:
        print(sys.argv[2] if len(sys.argv) > 2 else '')
    elif isinstance(result, bool):
        print('true' if result else 'false')
    elif isinstance(result, (dict, list)):
        print(json.dumps(result))
    else:
        print(result)
except Exception:
    print(sys.argv[2] if len(sys.argv) > 2 else '')
" "$path" "$default" 2>/dev/null
}

# Parse JSON field (legacy wrapper for compatibility)
# Usage: value=$(json_get "$json" ".field" "default")
json_get() {
    json_get_str "$1" "$2" "${3:-}"
}

# Parse JSON array to lines using Python (SECURE - uses stdin)
# Usage: while IFS= read -r item; do ... done < <(echo "$json" | json_array_stdin ".players")
# Or:    while IFS= read -r item; do ... done < <(json_array "$json" ".players")
json_array() {
    local json="$1"
    local path="$2"

    echo "$json" | python3 -c "
import json
import sys

try:
    data = json.load(sys.stdin)
    keys = sys.argv[1].lstrip('.').split('.')
    result = data
    for key in keys:
        if key:
            result = result.get(key, []) if isinstance(result, dict) else []
    if isinstance(result, list):
        for item in result:
            print(json.dumps(item))
except Exception:
    pass
" "$path" 2>/dev/null
}

# Count JSON array length (SECURE - uses stdin)
# Usage: count=$(json_count "$json" ".players")
json_count() {
    local json="$1"
    local path="$2"

    echo "$json" | python3 -c "
import json
import sys

try:
    data = json.load(sys.stdin)
    keys = sys.argv[1].lstrip('.').split('.')
    result = data
    for key in keys:
        if key:
            result = result.get(key, []) if isinstance(result, dict) else []
    print(len(result) if isinstance(result, list) else 0)
except Exception:
    print(0)
" "$path" 2>/dev/null
}

# =============================================================================
# JSON File Operations (SECURE)
# =============================================================================

# Read JSON value from file
# Usage: value=$(json_file_get "$file" ".field" "default")
json_file_get() {
    local file="$1"
    local path="$2"
    local default="${3:-}"

    if [[ ! -f "$file" ]]; then
        echo "$default"
        return
    fi

    python3 -c "
import json
import sys

try:
    with open(sys.argv[1], 'r') as f:
        data = json.load(f)
    keys = sys.argv[2].lstrip('.').split('.')
    result = data
    for key in keys:
        if key:
            result = result.get(key, None) if isinstance(result, dict) else None
            if result is None:
                break
    if result is None:
        print(sys.argv[3] if len(sys.argv) > 3 else '')
    elif isinstance(result, bool):
        print('true' if result else 'false')
    elif isinstance(result, (dict, list)):
        print(json.dumps(result))
    else:
        print(result)
except Exception:
    print(sys.argv[3] if len(sys.argv) > 3 else '')
" "$file" "$path" "$default" 2>/dev/null
}

# Update JSON file with a new value (SECURE)
# Usage: json_file_set "$file" ".field" "value"
json_file_set() {
    local file="$1"
    local path="$2"
    local value="$3"

    python3 -c "
import json
import sys
import os

file_path = sys.argv[1]
path = sys.argv[2].lstrip('.').split('.')
value = sys.argv[3]

# Try to parse value as JSON, fallback to string
try:
    parsed_value = json.loads(value)
except:
    parsed_value = value

# Load existing or create new
data = {}
if os.path.exists(file_path):
    try:
        with open(file_path, 'r') as f:
            data = json.load(f)
    except:
        pass

# Navigate and set
current = data
for i, key in enumerate(path[:-1]):
    if key not in current or not isinstance(current[key], dict):
        current[key] = {}
    current = current[key]

if path:
    current[path[-1]] = parsed_value

# Write back
with open(file_path, 'w') as f:
    json.dump(data, f, indent=2)
" "$file" "$path" "$value" 2>/dev/null
}

# Append to JSON array in file (SECURE)
# Usage: json_file_array_append "$file" ".bans" '{"guid": "xxx", "name": "yyy"}'
json_file_array_append() {
    local file="$1"
    local path="$2"
    local item="$3"

    python3 -c "
import json
import sys
import os

file_path = sys.argv[1]
path = sys.argv[2].lstrip('.').split('.')
item_json = sys.argv[3]

# Parse item
try:
    item = json.loads(item_json)
except:
    item = item_json

# Load existing or create new
data = {}
if os.path.exists(file_path):
    try:
        with open(file_path, 'r') as f:
            data = json.load(f)
    except:
        pass

# Navigate to array location
current = data
for i, key in enumerate(path[:-1]):
    if key not in current or not isinstance(current[key], dict):
        current[key] = {}
    current = current[key]

# Ensure array exists and append
if path:
    last_key = path[-1]
    if last_key not in current or not isinstance(current[last_key], list):
        current[last_key] = []
    current[last_key].append(item)

# Write back
with open(file_path, 'w') as f:
    json.dump(data, f, indent=2)
" "$file" "$path" "$item" 2>/dev/null
}

# Remove item from JSON array by field match (SECURE)
# Usage: json_file_array_remove "$file" ".bans" "guid" "abc123"
json_file_array_remove() {
    local file="$1"
    local path="$2"
    local field="$3"
    local value="$4"

    [[ ! -f "$file" ]] && return 0

    python3 -c "
import json
import sys

file_path = sys.argv[1]
path = sys.argv[2].lstrip('.').split('.')
field = sys.argv[3]
value = sys.argv[4]

try:
    with open(file_path, 'r') as f:
        data = json.load(f)

    # Navigate to array
    current = data
    for key in path[:-1]:
        current = current.get(key, {})

    if path:
        last_key = path[-1]
        if last_key in current and isinstance(current[last_key], list):
            current[last_key] = [
                item for item in current[last_key]
                if not (isinstance(item, dict) and item.get(field) == value)
            ]

    with open(file_path, 'w') as f:
        json.dump(data, f, indent=2)
except Exception:
    pass
" "$file" "$path" "$field" "$value" 2>/dev/null
}

# =============================================================================
# JSON Creation Helpers (SECURE)
# =============================================================================

# Create JSON object from key-value pairs (SECURE - properly escapes values)
# Usage: json=$(json_create "key1" "value1" "key2" "value2")
json_create() {
    python3 -c "
import json
import sys

result = {}
args = sys.argv[1:]
for i in range(0, len(args), 2):
    if i + 1 < len(args):
        key = args[i]
        val = args[i + 1]
        # Try to parse as JSON (for numbers, bools, nested objects)
        try:
            result[key] = json.loads(val)
        except:
            result[key] = val
print(json.dumps(result))
" "$@" 2>/dev/null
}

# Create JSON object from associative array (for more complex structures)
# Usage: json=$(json_create_object '{"guid": "abc", "name": "test"}')
# This is a passthrough that validates JSON
json_validate() {
    local json="$1"
    echo "$json" | python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    print(json.dumps(data))
except:
    print('{}')
" 2>/dev/null
}
