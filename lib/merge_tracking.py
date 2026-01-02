#!/usr/bin/env python3
"""
DayZ CE Merge Tracking System

Tracks which mod contributed which entries to shared CE files
(cfgrandompresets.xml, cfgeventgroups.xml) that cannot be linked
via cfgeconomycore.xml.

Features:
- Track mod contributions with JSON + XML comment fallback
- Detect name collisions and offer prefixing
- Clean uninstall with cross-file reference checking
- Rebuild tracking from XML comments if JSON lost
"""
import os
import sys
import json
import re
import xml.etree.ElementTree as ET
from datetime import datetime
from typing import Dict, List, Any, Optional, Tuple
import hashlib


# =============================================================================
# Constants
# =============================================================================
TRACKING_SUBDIR = "data/state/ce_merge_tracking"
MERGE_COMMENT_BEGIN = "===== BEGIN MOD:"
MERGE_COMMENT_END = "===== END MOD:"


# =============================================================================
# Tracking File I/O
# =============================================================================

def get_tracking_dir(instance_dir: str) -> str:
    """Get the tracking directory for an instance."""
    return os.path.join(instance_dir, TRACKING_SUBDIR)


def get_tracking_path(instance_dir: str, target_file: str) -> str:
    """
    Get path to tracking JSON for a target file.
    
    Args:
        instance_dir: Path to server instance (e.g., ~/servers/dayz-server1)
        target_file: Target file basename (e.g., cfgrandompresets.xml)
    
    Returns:
        Path like: instance_dir/data/state/ce_merge_tracking/cfgrandompresets.xml.json
    """
    return os.path.join(get_tracking_dir(instance_dir), f"{target_file}.json")


def load_tracking(instance_dir: str, target_file: str) -> Dict[str, Any]:
    """
    Load tracking data for a target file.
    
    Returns empty structure if file doesn't exist.
    """
    tracking_path = get_tracking_path(instance_dir, target_file)
    
    if os.path.exists(tracking_path):
        try:
            with open(tracking_path, 'r', encoding='utf-8') as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    
    # Return empty tracking structure
    return {
        "target_file": target_file,
        "last_updated": None,
        "mods": {}
    }


def save_tracking(instance_dir: str, target_file: str, data: Dict[str, Any]) -> bool:
    """
    Save tracking data for a target file.
    
    Creates directory if needed. Returns True on success.
    """
    tracking_dir = get_tracking_dir(instance_dir)
    tracking_path = get_tracking_path(instance_dir, target_file)
    
    try:
        os.makedirs(tracking_dir, exist_ok=True)
        data["last_updated"] = datetime.now().isoformat()
        
        with open(tracking_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        return True
    except IOError as e:
        print(f"Error saving tracking: {e}", file=sys.stderr)
        return False


# =============================================================================
# Source Entry Parsing
# =============================================================================

def parse_source_entries(xml_path: str) -> List[Dict[str, Any]]:
    """
    Parse entries from a source CE file (mod's randompresets/eventgroups).
    
    Returns list of entry dicts with: name, type (cargo/attachments/group), content_hash
    """
    entries = []
    
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
        
        # Handle both wrapped and fragment files
        # Wrapped: <randompresets><cargo>...</cargo></randompresets>
        # Fragment: <cargo>...</cargo> (root IS the entry)
        
        if root.tag in ('randompresets', 'eventgroups'):
            # Wrapped file - iterate children
            elements = list(root)
        elif root.tag in ('cargo', 'attachments', 'group', 'event', 'type'):
            # Fragment file - root is the first entry, might have siblings
            # Actually for fragments we treat the whole file as content
            elements = [root]
            # Check for siblings not possible in single-root XML
        else:
            # Unknown structure - try children
            elements = list(root)
        
        for elem in elements:
            entry_name = elem.get('name', '')
            if not entry_name:
                continue
                
            # Calculate content hash for change detection
            content = ET.tostring(elem, encoding='unicode', method='xml')
            content_hash = hashlib.md5(content.encode()).hexdigest()[:12]
            
            entries.append({
                "name": entry_name,
                "type": elem.tag,
                "content_hash": content_hash,
                "element": elem  # Keep for later merging
            })
            
    except Exception as e:
        print(f"Error parsing {xml_path}: {e}", file=sys.stderr)
    
    return entries


# =============================================================================
# Collision Detection
# =============================================================================

def get_existing_entry_names(target_path: str) -> set:
    """Get all entry names currently in the target file."""
    names = set()
    
    if not os.path.exists(target_path):
        return names
        
    try:
        tree = ET.parse(target_path)
        root = tree.getroot()
        
        for elem in root:
            name = elem.get('name', '')
            if name:
                names.add(name)
    except Exception:
        pass
        
    return names


def check_collisions(
    source_entries: List[Dict[str, Any]], 
    target_path: str,
    mod_id: str
) -> List[Dict[str, Any]]:
    """
    Check for name collisions between source entries and target file.
    
    Returns list of collision dicts with: name, suggested_name (with prefix)
    """
    existing_names = get_existing_entry_names(target_path)
    collisions = []
    
    for entry in source_entries:
        name = entry['name']
        if name in existing_names:
            # Suggest prefixed name
            suggested = f"{mod_id}_{name}"
            collisions.append({
                "original_name": name,
                "suggested_name": suggested,
                "type": entry['type']
            })
    
    return collisions


# =============================================================================
# Merge Operations
# =============================================================================

def merge_entries(
    target_path: str,
    entries: List[Dict[str, Any]],
    mod_id: str,
    mod_name: str,
    rename_map: Optional[Dict[str, str]] = None
) -> Dict[str, Any]:
    """
    Merge entries into target file with XML comment markers.
    
    Args:
        target_path: Path to target file (e.g., db/cfgrandompresets.xml)
        entries: List of entry dicts from parse_source_entries()
        mod_id: Steam Workshop mod ID
        mod_name: Human-readable mod name
        rename_map: Optional dict mapping original names to new names (for collision fixes)
    
    Returns:
        Dict with 'success', 'added_count', 'entries_added'
    """
    rename_map = rename_map or {}
    added_entries = []
    
    try:
        # Load or create target file
        if os.path.exists(target_path):
            tree = ET.parse(target_path)
            root = tree.getroot()
        else:
            # Determine root tag based on file type
            if 'randompresets' in target_path.lower():
                root = ET.Element('randompresets')
            elif 'eventgroups' in target_path.lower():
                root = ET.Element('eventgroups')
            else:
                root = ET.Element('root')
            tree = ET.ElementTree(root)
        
        # Add comment marker before new entries
        # Note: ElementTree doesn't support comments well, we'll add them via string manipulation
        
        for entry in entries:
            elem = entry.get('element')
            if elem is None:
                continue
                
            original_name = entry['name']
            final_name = rename_map.get(original_name, original_name)
            
            # Create a copy of the element with potentially new name
            new_elem = ET.fromstring(ET.tostring(elem))
            if final_name != original_name:
                new_elem.set('name', final_name)
            
            root.append(new_elem)
            added_entries.append({
                "name": final_name,
                "original_name": original_name if final_name != original_name else None,
                "type": entry['type'],
                "content_hash": entry['content_hash']
            })
        
        # Write file
        if sys.version_info >= (3, 9):
            ET.indent(tree, space="    ", level=0)
        tree.write(target_path, encoding='utf-8', xml_declaration=True)
        
        # Now add XML comments via string manipulation
        _add_mod_comments(target_path, mod_id, mod_name, [e['name'] for e in added_entries])
        
        return {
            "success": True,
            "added_count": len(added_entries),
            "entries_added": added_entries
        }
        
    except Exception as e:
        return {
            "success": False,
            "error": str(e),
            "added_count": 0,
            "entries_added": []
        }


def _add_mod_comments(target_path: str, mod_id: str, mod_name: str, entry_names: List[str]) -> None:
    """
    Add XML comments around mod entries for visual tracking.
    
    This is done via string manipulation since ElementTree doesn't handle comments well.
    """
    try:
        with open(target_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Find and wrap each entry with comments
        begin_comment = f"<!-- {MERGE_COMMENT_BEGIN} {mod_id} ({mod_name}) -->\n"
        end_comment = f"\n<!-- {MERGE_COMMENT_END} {mod_id} -->"
        
        for name in entry_names:
            # Find the entry by name attribute
            # Match pattern like: <cargo name="EntryName"
            pattern = rf'(<(?:cargo|attachments|group|event|type)[^>]*name\s*=\s*["\']' + re.escape(name) + rf'["\'][^>]*>)'
            
            # Find the full element including closing tag
            match = re.search(pattern, content, re.IGNORECASE)
            if match:
                start_pos = match.start()
                # Find the closing tag
                tag_match = re.match(r'<(\w+)', match.group(1))
                if tag_match:
                    tag_name = tag_match.group(1)
                    # Find closing tag or self-closing
                    if '/>' in match.group(1):
                        # Self-closing
                        end_pos = match.end()
                    else:
                        close_pattern = rf'</{tag_name}>'
                        close_match = re.search(close_pattern, content[match.end():], re.IGNORECASE)
                        if close_match:
                            end_pos = match.end() + close_match.end()
                        else:
                            end_pos = match.end()
                    
                    # Check if already wrapped
                    if MERGE_COMMENT_BEGIN not in content[max(0, start_pos-100):start_pos]:
                        # Insert comments
                        content = (
                            content[:start_pos] + 
                            begin_comment + 
                            content[start_pos:end_pos] + 
                            end_comment + 
                            content[end_pos:]
                        )
        
        with open(target_path, 'w', encoding='utf-8') as f:
            f.write(content)
            
    except Exception as e:
        print(f"Warning: Could not add mod comments: {e}", file=sys.stderr)


# =============================================================================
# Unmerge Operations  
# =============================================================================

def unmerge_entries(
    target_path: str,
    mod_id: str,
    entry_names: List[str],
    comment_out: bool = True
) -> Dict[str, Any]:
    """
    Remove or comment-out entries belonging to a mod.
    
    Args:
        target_path: Path to target file
        mod_id: Mod ID to remove entries for
        entry_names: List of entry names to remove
        comment_out: If True, comment out instead of delete (safer)
    
    Returns:
        Dict with 'success', 'removed_count', 'not_found'
    """
    removed = []
    not_found = []
    
    try:
        with open(target_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        for name in entry_names:
            # Find the entry block including comments
            # Look for BEGIN comment...entry...END comment
            begin_pattern = rf'<!--\s*{re.escape(MERGE_COMMENT_BEGIN)}\s*{mod_id}[^>]*-->\s*'
            entry_pattern = rf'<(?:cargo|attachments|group|event|type)[^>]*name\s*=\s*["\']' + re.escape(name) + rf'["\'][^>]*>.*?</\w+>'
            end_pattern = rf'\s*<!--\s*{re.escape(MERGE_COMMENT_END)}\s*{mod_id}\s*-->'
            
            full_pattern = begin_pattern + rf'(' + entry_pattern + rf')' + end_pattern
            
            match = re.search(full_pattern, content, re.IGNORECASE | re.DOTALL)
            
            if not match:
                # Try finding just the entry without comments
                simple_pattern = rf'<(?:cargo|attachments|group|event|type)[^>]*name\s*=\s*["\']' + re.escape(name) + rf'["\'][^>]*>.*?</\w+>'
                match = re.search(simple_pattern, content, re.IGNORECASE | re.DOTALL)
            
            if match:
                if comment_out:
                    # Comment out the entry
                    commented = f"<!-- REMOVED (uninstall {mod_id}):\n{match.group(0)}\n-->"
                    content = content[:match.start()] + commented + content[match.end():]
                else:
                    # Delete the entry
                    content = content[:match.start()] + content[match.end():]
                removed.append(name)
            else:
                not_found.append(name)
        
        with open(target_path, 'w', encoding='utf-8') as f:
            f.write(content)
        
        return {
            "success": True,
            "removed_count": len(removed),
            "removed": removed,
            "not_found": not_found
        }
        
    except Exception as e:
        return {
            "success": False,
            "error": str(e),
            "removed_count": 0,
            "removed": [],
            "not_found": entry_names
        }


# =============================================================================
# Cross-File Reference Detection
# =============================================================================

def find_references(entry_name: str, search_dirs: List[str], exclude_files: Optional[List[str]] = None) -> List[Dict[str, str]]:
    """
    Search for references to an entry name in other CE files.
    
    Args:
        entry_name: Name of entry to search for
        search_dirs: List of directories to search
        exclude_files: Optional list of filenames to exclude
    
    Returns:
        List of dicts with 'file', 'line', 'context'
    """
    exclude_files = exclude_files or []
    references = []
    
    # Pattern to find references (in attributes like preset="name" or preset='name')
    pattern = re.compile(
        rf'(preset|group|cargo|type)\s*=\s*["\']' + re.escape(entry_name) + rf'["\']',
        re.IGNORECASE
    )
    
    for search_dir in search_dirs:
        if not os.path.isdir(search_dir):
            continue
            
        for root, dirs, files in os.walk(search_dir):
            # Skip backup/original folders
            dirs[:] = [d for d in dirs if d not in ('.backups', '.originals')]
            
            for filename in files:
                if not filename.endswith('.xml'):
                    continue
                if filename in exclude_files:
                    continue
                    
                filepath = os.path.join(root, filename)
                try:
                    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
                        for line_num, line in enumerate(f, 1):
                            if pattern.search(line):
                                references.append({
                                    "file": filepath,
                                    "filename": filename,
                                    "line": line_num,
                                    "context": line.strip()[:100]
                                })
                except IOError:
                    pass
    
    return references


# =============================================================================
# Tracking Rebuild from XML Comments
# =============================================================================

def rebuild_tracking_from_comments(target_path: str) -> Dict[str, Any]:
    """
    Rebuild tracking data by parsing XML comments in target file.
    
    Returns tracking structure for all mods found in comments.
    """
    tracking = {
        "target_file": os.path.basename(target_path),
        "last_updated": datetime.now().isoformat(),
        "mods": {},
        "rebuilt_from_comments": True
    }
    
    try:
        with open(target_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Find all BEGIN...END blocks
        pattern = rf'<!--\s*{re.escape(MERGE_COMMENT_BEGIN)}\s*(\d+)\s*\(([^)]+)\)\s*-->(.*?)<!--\s*{re.escape(MERGE_COMMENT_END)}\s*\1\s*-->'
        
        for match in re.finditer(pattern, content, re.DOTALL):
            mod_id = match.group(1)
            mod_name = match.group(2)
            block_content = match.group(3)
            
            if mod_id not in tracking["mods"]:
                tracking["mods"][mod_id] = {
                    "mod_name": mod_name,
                    "entries": [],
                    "rebuilt": True
                }
            
            # Extract entry names from the block
            entry_pattern = rf'<(?:cargo|attachments|group|event|type)[^>]*name\s*=\s*["\']([^"\']+)["\']'
            for entry_match in re.finditer(entry_pattern, block_content, re.IGNORECASE):
                entry_name = entry_match.group(1)
                tracking["mods"][mod_id]["entries"].append({
                    "name": entry_name,
                    "type": "unknown"
                })
        
    except Exception as e:
        tracking["error"] = str(e)
    
    return tracking


# =============================================================================
# CLI Interface
# =============================================================================

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description='DayZ CE Merge Tracking System')
    subparsers = parser.add_subparsers(dest='command')
    
    # Parse source entries
    p_parse = subparsers.add_parser('parse-entries', help='Parse entries from a CE source file')
    p_parse.add_argument('file', help='Path to source XML file')
    
    # Check collisions
    p_coll = subparsers.add_parser('check-collisions', help='Check for name collisions')
    p_coll.add_argument('source', help='Path to source file')
    p_coll.add_argument('target', help='Path to target file')
    p_coll.add_argument('--mod-id', required=True, help='Mod ID for prefix suggestion')
    
    # Find references
    p_refs = subparsers.add_parser('find-references', help='Find references to an entry')
    p_refs.add_argument('name', help='Entry name to search for')
    p_refs.add_argument('--dirs', nargs='+', required=True, help='Directories to search')
    
    # Load tracking
    p_load = subparsers.add_parser('load-tracking', help='Load tracking for a target file')
    p_load.add_argument('--instance', required=True, help='Instance directory')
    p_load.add_argument('--target', required=True, help='Target file name')
    
    # Rebuild from comments
    p_rebuild = subparsers.add_parser('rebuild-tracking', help='Rebuild tracking from XML comments')
    p_rebuild.add_argument('file', help='Path to target file')
    
    args = parser.parse_args()
    
    if args.command == 'parse-entries':
        entries = parse_source_entries(args.file)
        # Remove non-serializable element
        for e in entries:
            if 'element' in e:
                del e['element']
        print(json.dumps(entries, indent=2))
        
    elif args.command == 'check-collisions':
        entries = parse_source_entries(args.source)
        collisions = check_collisions(entries, args.target, args.mod_id)
        print(json.dumps(collisions, indent=2))
        
    elif args.command == 'find-references':
        refs = find_references(args.name, args.dirs)
        print(json.dumps(refs, indent=2))
        
    elif args.command == 'load-tracking':
        data = load_tracking(args.instance, args.target)
        print(json.dumps(data, indent=2))
        
    elif args.command == 'rebuild-tracking':
        data = rebuild_tracking_from_comments(args.file)
        print(json.dumps(data, indent=2))
        
    else:
        parser.print_help()
