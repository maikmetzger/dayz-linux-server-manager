#!/usr/bin/env python3
import json
import os
import sys
import xml.etree.ElementTree as ET
import re
from datetime import datetime
from fileutil import atomic_write_text, atomic_write_tree
from typing import Dict, List, Optional, Any

# =============================================================================
# CE Merge Tracking Module
# =============================================================================
# Manages the state of merged CE entries to allow clean uninstalls and 
# collision detection.
#
# Tracking File Schema:
# {
#   "target_file": "db/cfgrandompresets.xml",
#   "last_updated": "ISO8601",
#   "entries": {
#     "ModID_123": [
#       {
#         "xpath": "cargo[@name='MedicalPreset']",
#         "original_name": "MedicalPreset",
#         "current_name": "TF_MedicalPreset",
#         "was_renamed": true
#       }
#     ]
#   }
# }
# =============================================================================

def get_tracking_path(instance_dir: str, target_file: str) -> str:
    """
    Returns the absolute path to the tracking JSON for a given target file.
    Example: target_file='db/cfgrandompresets.xml' -> '.../state/ce_merge_tracking/cfgrandompresets.json'
    """
    state_dir = os.path.join(instance_dir, 'data', 'state', 'ce_merge_tracking')
    if not os.path.exists(state_dir):
        os.makedirs(state_dir, exist_ok=True)
    
    # Flatten filename for storage (db/cfgrandompresets.xml -> cfgrandompresets.json)
    basename = os.path.basename(target_file)
    name_only = os.path.splitext(basename)[0]
    return os.path.join(state_dir, f"{name_only}.json")

def indent(elem, level=0):
    """
    Format XML with indentation in-place.
    """
    i = "\n" + level * "    "
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = i + "    "
        if not elem.tail or not elem.tail.strip():
            elem.tail = i
        for child in elem:
            indent(child, level + 1)
        if not child.tail or not child.tail.strip():
            child.tail = i
            child.tail = i
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = i

def parse_xml_robust(path: str) -> tuple[Optional[ET.Element], bool]:
    """
    Parses XML file, handling fragments (missing root) by wrapping them.
    Returns (root_element, was_wrapped_boolean).
    """
    if not os.path.exists(path):
        return None, False
        
    try:
        tree = ET.parse(path)
        return tree.getroot(), False
    except ET.ParseError:
        # Try wrapping in fake root AND sanitizing
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read()
            
            # Sanitize: Escape unescaped &
            # Matches & that is NOT followed by (entity;)
            content = re.sub(r'&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)', '&amp;', content)
            
            # wrapped_content = f"<root>{content}</root>" # f-string might be unsafe if content has weird bytes?
            # Use format or concatenation
            root = ET.fromstring(f"<root>{content}</root>")
            return root, True
        except Exception as e:
            # print(f"DEBUG: Failed to parse fragment {path}: {e}", file=sys.stderr)
            return None, False

def inject_entries(target_file: str, source_file: str, mod_id: str, mod_name: str) -> List[Dict[str, Any]]:
    """
    Merges entries from source_file into target_file.
    Returns list of added entries for tracking.
    """
    added_entries = []
    
    # Load or create target
    target_root = None
    target_tree = None
    
    if os.path.exists(target_file):
        try:
            target_tree = ET.parse(target_file)
            target_root = target_tree.getroot()
        except ET.ParseError:
            pass # Handle corrupt later
            
    # Parse Source Robustly
    src_root, is_wrapped = parse_xml_robust(source_file)
    if src_root is None:
        return []

    # Initialize target if needed
    if target_root is None:
        # Infer tag
        tag_name = "types" # Default
        base = os.path.basename(target_file).lower()
        if 'randompresets' in base: tag_name = 'randompresets'
        elif 'eventgroups' in base: tag_name = 'eventgroups'
        elif not is_wrapped: tag_name = src_root.tag
            
        target_root = ET.Element(tag_name)
        target_tree = ET.ElementTree(target_root)
    
    # Identify items to merge
    items_to_merge = []
    
    # 1. If wrapped, all children are items
    if is_wrapped:
        for child in src_root:
            items_to_merge.append(child)
    else:
        # 2. If not wrapped, check if root itself is an item
        if src_root.get('name'): 
            items_to_merge.append(src_root)
        # 3. And check children (standard Types.xml structure)
        for child in src_root:
             if child.get('name'):
                 items_to_merge.append(child)

    if not items_to_merge:
        return []

    # Adding items
    for item in items_to_merge:
        # Deep copy item to avoid weirdness
        import copy
        new_item = copy.deepcopy(item)
        
        target_root.append(new_item)
        
        added_entries.append({
            "name": item.get('name'),
            "type": item.tag,
            "original_name": item.get('name')
        })

    # Format
    indent(target_root)
    
    # Write
    atomic_write_tree(target_tree, target_file, encoding='utf-8', xml_declaration=True)
    
    return added_entries

def remove_entries(target_file: str, entries_to_remove: List[Dict[str, Any]]) -> bool:
    """
    Removes specific entries from target file.
    """
    if not os.path.exists(target_file):
        return False
        
    try:
        tree = ET.parse(target_file)
        root = tree.getroot()
    except:
        return False
        
    removed_count = 0
    
    # Build lookup for removal
    # (tag, name) tuple
    targets = set()
    for e in entries_to_remove:
        targets.add((e['type'], e['name']))
        
    # Iterate copy of children to modify list safely
    for child in list(root):
        name = child.get('name')
        tag = child.tag
        if name and (tag, name) in targets:
            root.remove(child)
            removed_count += 1
            
    if removed_count > 0:
        indent(root)
        atomic_write_tree(tree, target_file, encoding='utf-8', xml_declaration=True)
        return True
        
    return False


def load_tracking(instance_dir: str, target_file: str) -> Dict[str, Any]:
    """Loads tracking data or returns empty structure if new."""
    path = get_tracking_path(instance_dir, target_file)
    if not os.path.exists(path):
        return {
            "target_file": target_file,
            "last_updated": None,
            "entries": {}
        }
    
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        print(f"WARN: Corrupt tracking file {path}, resetting.", file=sys.stderr)
        return {
            "target_file": target_file,
            "last_updated": None,
            "entries": {}
        }

def save_tracking(instance_dir: str, target_file: str, data: Dict[str, Any]):
    """Saves tracking data to disk."""
    path = get_tracking_path(instance_dir, target_file)
    data["last_updated"] = datetime.now().isoformat()
    
    atomic_write_text(path, json.dumps(data, indent=2))

def check_collisions(source_xml_path: str, target_xml_path: str) -> List[Dict[str, str]]:
    """
    Checks if entries in source XML already exist in target XML.
    Returns list of collisions: [{'name': 'Preset1', 'type': 'cargo'}]
    """
    collisions = []
    
    # 1. Parse Target (if exists)
    existing_names = set()
    if os.path.exists(target_xml_path):
        try:
            tree = ET.parse(target_xml_path)
            root = tree.getroot()
            # Capture names of all children (cargo, attachments, etc.)
            for child in root:
                name = child.get('name')
                if name:
                    existing_names.add(name)
        except ET.ParseError:
            pass # Target might be empty or valid fragment, proceed
            
    # 2. Parse Source
    # 2. Parse Source Robustly
    src_root, is_wrapped = parse_xml_robust(source_xml_path)
    if src_root is None:
        return []

    items_to_check = []
    
    if is_wrapped:
        for child in src_root:
            items_to_check.append(child)
    else:
        if src_root.get('name'):
            items_to_check.append(src_root)
        for child in src_root:
            if child.get('name'):
                items_to_check.append(child)
                
    for item in items_to_check:
        name = item.get('name')
        tag = item.tag
        if name and name in existing_names:
            collisions.append({
                'name': name,
                'type': tag
            })
            
    return collisions
        
    return collisions

if __name__ == "__main__":
    # CLI interface for shell script integration
    if len(sys.argv) < 2:
        print("Usage: merge_tracking.py <command> [args...]")
        sys.exit(1)
        
    cmd = sys.argv[1]
    
    if cmd == "check_collisions":
        # check_collisions <source> <target>
        if len(sys.argv) != 4:
            sys.exit(1)
        cols = check_collisions(sys.argv[2], sys.argv[3])
        if cols:
            print(json.dumps(cols))
            sys.exit(2) # Exit 2 = Collisions found
        else:
            sys.exit(0) # Exit 0 = Clean merge
            
    elif cmd == "inject":
        # inject <target> <source> <mod_id> <mod_name> <instance_dir>
        if len(sys.argv) != 7:
            print(f"Usage: {sys.argv[0]} inject <target> <source> <mod_id> <mod_name> <instance_dir>", file=sys.stderr)
            sys.exit(1)
            
        target = sys.argv[2]
        source = sys.argv[3]
        mod_id = sys.argv[4]
        mod_name = sys.argv[5]
        inst_dir = sys.argv[6]
        
        added = inject_entries(target, source, mod_id, mod_name)
        if added:
            # Update tracking
            data = load_tracking(inst_dir, target)
            if mod_id not in data.get('entries', {}):
                if 'entries' not in data: data['entries'] = {}
                data['entries'][mod_id] = []
            
            data['entries'][mod_id].extend(added)
            save_tracking(inst_dir, target, data)
            
            print(f"Merged {len(added)} entries.")
            sys.exit(0)
        else:
            print("No entries found to merge.", file=sys.stderr)
            sys.exit(1)
            
    elif cmd == "remove":
        # remove <target> <mod_id> <instance_dir>
        if len(sys.argv) != 5:
             print(f"Usage: {sys.argv[0]} remove <target> <mod_id> <instance_dir>", file=sys.stderr)
             sys.exit(1)
             
        target = sys.argv[2]
        mod_id = sys.argv[3]
        inst_dir = sys.argv[4]
        
        data = load_tracking(inst_dir, target)
        entries = data.get('entries', {}).get(mod_id, [])
        
        if not entries:
            print(f"No tracked entries found for mod {mod_id}", file=sys.stderr)
            sys.exit(0)
            
        if remove_entries(target, entries):
            # Clean tracking
            del data['entries'][mod_id]
            save_tracking(inst_dir, target, data)
            print(f"Unmerged module {mod_id}.")
            sys.exit(0)
        else:
            print("Failed to remove entries from XML.", file=sys.stderr)
            sys.exit(1)
            
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
