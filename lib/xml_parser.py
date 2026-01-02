#!/usr/bin/env python3
"""
DayZ Central Economy XML Parser

Provides detection, querying, and modification of DayZ CE XML files.
Supports: types, spawnabletypes, events, eventspawns

Extensibility: Add new file types to CE_TYPE_REGISTRY without modifying logic.
"""
import sys
import os
import xml.etree.ElementTree as ET
import json
import argparse
from typing import Optional, Dict, Any

# =============================================================================
# CE Type Registry (Open/Closed Principle - extend here, not in logic)
# =============================================================================
# Maps XML root tags to CE configuration.
# To add a new type: add an entry here, no other code changes needed.
#
# merge_only: True means file cannot be linked via cfgeconomycore.xml
#             and must be merged into a single target file
CE_TYPE_REGISTRY: Dict[str, Dict[str, Any]] = {
    'types': {
        'ce_type': 'types',
        'folder': 'CustomCE/types',
        'description': 'Item spawn definitions (nominal, min, lifetime, restock)',
        'merge_only': False
    },
    'spawnabletypes': {
        'ce_type': 'spawnabletypes',
        'folder': 'CustomCE/spawnabletypes',
        'description': 'Attachments/cargo spawning on items (vehicles, weapons)',
        'merge_only': False
    },
    'events': {
        'ce_type': 'events',
        'folder': 'CustomCE/events',
        'description': 'Dynamic events (animal herds, vehicle spawns, crashes)',
        'merge_only': False
    },
    'eventposdef': {
        'ce_type': 'eventspawns',
        'folder': 'CustomCE/eventspawns',
        'description': 'Fixed spawn positions for events',
        'merge_only': False
    },
    # Merge-only types: Cannot be included via cfgeconomycore.xml
    'randompresets': {
        'ce_type': 'randompresets',
        'folder': 'db',
        'description': 'Random loot preset groups (themed item bundles)',
        'merge_only': True,
        'target_file': 'cfgrandompresets.xml'
    },
    'eventgroups': {
        'ce_type': 'eventgroups',
        'folder': 'db',
        'description': 'Event object groups (train wrecks, helicopter crashes)',
        'merge_only': True,
        'target_file': 'cfgeventgroups.xml'
    },
}

# =============================================================================
# Fragment Detection Registry (for files without root wrapper tag)
# =============================================================================
# Maps first child element tag to CE type for fragment files.
# Example: A file with just <type name="..."> tags (no <types> wrapper)
CE_FRAGMENT_REGISTRY: Dict[str, str] = {
    'type': 'types',          # <type name="..."> without <types> wrapper
    'cargo': 'randompresets', # <cargo name="..."> without <randompresets>
    'attachments': 'randompresets',  # Alternative child in randompresets
    'event': 'events',        # <event name="..."> without <events>
    'group': 'eventgroups',   # <group name="..."> without <eventgroups>
}

# =============================================================================
# Filename Pattern Fallback (last resort detection)
# =============================================================================
# Regex patterns for filename-based CE type detection.
# Order matters: more specific patterns first.
import re
CE_FILENAME_PATTERNS = [
    (re.compile(r'(?i).*randompresets.*\.xml$'), 'randompresets'),
    (re.compile(r'(?i).*eventgroups.*\.xml$'), 'eventgroups'),
    (re.compile(r'(?i).*spawnabletypes.*\.xml$'), 'spawnabletypes'),
    (re.compile(r'(?i).*eventspawns.*\.xml$'), 'eventspawns'),
    (re.compile(r'(?i).*eventpos.*\.xml$'), 'eventspawns'),
    (re.compile(r'(?i).*events.*\.xml$'), 'events'),
    (re.compile(r'(?i).*types.*\.xml$'), 'types'),
]



def get_types_root(xml_path):
    """
    Parse a types XML file, handling both standard and fragment files.
    
    For fragment files (no root <types> wrapper), automatically wraps
    the content with <types>...</types> before parsing.
    """
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
        
        # If root is not a known container type (types, spawnabletypes, etc.),
        # treat it as a fragment (e.g. single <type> element) and force wrapping
        if root.tag not in CE_TYPE_REGISTRY:
            raise ET.ParseError(f"Root tag '{root.tag}' is not a valid container")
            
        return tree, root
    except ET.ParseError as e:
        # Try wrapping as fragment
        try:
            with open(xml_path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            
            # Check if it contains <type elements (even after comments)
            # Strip XML comments for detection
            import re
            content_no_comments = re.sub(r'<!--.*?-->', '', content, flags=re.DOTALL)
            content_stripped = content_no_comments.strip()
            
            # Check for type fragments anywhere in content
            if '<type ' in content_stripped or '<type>' in content_stripped:
                # Wrap with types root
                wrapped = f'<?xml version="1.0" encoding="UTF-8"?>\n<types>\n{content}\n</types>'
                root = ET.fromstring(wrapped)
                # Create a pseudo-tree
                tree = ET.ElementTree(root)
                return tree, root
        except Exception:
            pass
        
        print(f"Error parsing XML: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error parsing XML: {e}", file=sys.stderr)
        sys.exit(1)

def metadata(xml_path):
    _, root = get_types_root(xml_path)
    categories = set()
    usages = set()
    tiers = set()
    
    for type_node in root.findall('type'):
        # Category
        cat = type_node.find('category')
        if cat is not None:
            categories.add(cat.get('name', ''))
            
        # Usage
        for usage in type_node.findall('usage'):
            usages.add(usage.get('name', ''))
            
        # Tiers (Value)
        for val in type_node.findall('value'):
            name = val.get('name', '')
            if name.startswith('Tier'):
                tiers.add(name)
                
    result = {
        "categories": sorted(list(filter(None, categories))),
        "usages": sorted(list(filter(None, usages))),
        "tiers": sorted(list(filter(None, tiers)))
    }
    print(json.dumps(result))

def detect_ce_type(xml_path: str, use_filename_fallback: bool = True) -> Optional[Dict[str, Any]]:
    """
    Enhanced CE file type detection with 3 fallback layers:
    
    1. Root tag detection - Standard XML files with proper root element
    2. Fragment detection - Files without root wrapper (e.g., <type> without <types>)
    3. Filename pattern - Last resort based on filename patterns
    
    Args:
        xml_path: Path to the XML file to analyze
        use_filename_fallback: If True, use filename patterns as last resort
        
    Returns:
        Dict with 'ce_type', 'folder', 'description', 'merge_only', 'detection_method'
        or None if not recognized
    """
    filename = os.path.basename(xml_path)
    
    # Layer 1: Try parsing and checking root tag
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
        
        registry_entry = CE_TYPE_REGISTRY.get(root.tag)
        if registry_entry:
            # print(f"DEBUG: {filename} -> root_tag '{root.tag}'", file=sys.stderr)
            result = dict(registry_entry)
            result['detection_method'] = 'root_tag'
            return result
        
        # Layer 2a: Check if root tag itself is a fragment element
        fragment_ce_type = CE_FRAGMENT_REGISTRY.get(root.tag)
        if fragment_ce_type:
            # print(f"DEBUG: {filename} -> fragment_root '{root.tag}'", file=sys.stderr)
            for entry in CE_TYPE_REGISTRY.values():
                if entry['ce_type'] == fragment_ce_type:
                    result = dict(entry)
                    result['detection_method'] = 'fragment_root'
                    result['is_fragment'] = True
                    return result
            
        # Layer 2b: Check first child elements
        first_child = next(iter(root), None)
        if first_child is not None:
            child_tag = first_child.tag
            fragment_ce_type = CE_FRAGMENT_REGISTRY.get(child_tag)
            if fragment_ce_type:
                # print(f"DEBUG: {filename} -> fragment_child '{child_tag}'", file=sys.stderr)
                # Look up full info from CE_TYPE_REGISTRY using the type name
                for entry in CE_TYPE_REGISTRY.values():
                    if entry['ce_type'] == fragment_ce_type:
                        result = dict(entry)
                        result['detection_method'] = 'fragment_child'
                        result['is_fragment'] = True
                        return result
                        
    except ET.ParseError:
        # Layer 2.5: Text-based fragment detection
        try:
            with open(xml_path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read(2048)  # Read first 2KB
            
            # Look for first opening tag
            import re
            tag_match = re.search(r'<([a-zA-Z_][a-zA-Z0-9_-]*)\s', content)
            if tag_match:
                first_tag = tag_match.group(1).lower()
                
                # Debug specific file
                if 'trader_config' in filename:
                    print(f"DEBUG: {filename} matched tag '{first_tag}'", file=sys.stderr)
                
                fragment_ce_type = CE_FRAGMENT_REGISTRY.get(first_tag)
                if fragment_ce_type:
                    for entry in CE_TYPE_REGISTRY.values():
                        if entry['ce_type'] == fragment_ce_type:
                            result = dict(entry)
                            result['detection_method'] = 'fragment_text'
                            result['is_fragment'] = True
                            return result
        except Exception:
            pass
    except Exception:
        pass
    
    # Layer 3: Filename pattern fallback
    if use_filename_fallback:
        for pattern, ce_type in CE_FILENAME_PATTERNS:
            if pattern.match(filename):
                # print(f"DEBUG: {filename} -> filename pattern", file=sys.stderr)
                # Look up full info from registry
                for entry in CE_TYPE_REGISTRY.values():
                    if entry['ce_type'] == ce_type:
                        result = dict(entry)
                        result['detection_method'] = 'filename'
                        return result
    
    return None




def is_types_xml(xml_path: str) -> None:
    """
    Legacy function: Checks if the file is a DayZ types/loot XML file.
    Maintained for backward compatibility.
    """
    result = detect_ce_type(xml_path)
    if result and result['ce_type'] == 'types':
        print("true")
    else:
        print("false")

def query(xml_path, name=None, cat=None, usage=None, tier=None, vanilla_path=None):
    _, root = get_types_root(xml_path)
    vanilla_root = None
    if vanilla_path and os.path.exists(vanilla_path):
        try:
            _, vanilla_root = get_types_root(vanilla_path)
        except:
            pass
            
    results = []
    
    # Pre-index vanilla for speed if provided
    vanilla_map = {}
    if vanilla_root is not None:
        for v_node in vanilla_root.findall('type'):
            v_name = v_node.get('name', '')
            if v_name:
                vanilla_map[v_name] = v_node

    for type_node in root.findall('type'):
        item_name = type_node.get('name', '')
        
        # Filter Name
        if name and name.lower() not in item_name.lower():
            continue
            
        # Filter Category
        if cat:
            item_cat = type_node.find('category')
            if item_cat is None or item_cat.get('name', '').lower() != cat.lower():
                continue
                
        # Filter Usage
        if usage:
            found_usage = False
            for u in type_node.findall('usage'):
                if u.get('name', '').lower() == usage.lower():
                    found_usage = True
                    break
            if not found_usage:
                continue
                
        # Filter Tier
        if tier:
            found_tier = False
            for t in type_node.findall('value'):
                if t.get('name', '').lower() == tier.lower():
                    found_tier = True
                    break
            if not found_tier:
                continue
        
        # Extract data for table
        nominal = type_node.find('nominal')
        min_val = type_node.find('min')
        lifetime = type_node.find('lifetime')
        restock = type_node.find('restock')
        
        # Vanilla comparison
        v_item = vanilla_map.get(item_name)
        v_nominal = v_item.find('nominal').text if v_item is not None and v_item.find('nominal') is not None else "0"
        v_min = v_item.find('min').text if v_item is not None and v_item.find('min') is not None else "0"
        v_life = v_item.find('lifetime').text if v_item is not None and v_item.find('lifetime') is not None else "0"
        v_rs = v_item.find('restock').text if v_item is not None and v_item.find('restock') is not None else "0"

        # Details for footer
        # Get all usages
        all_usages = [u.get('name', '') for u in type_node.findall('usage')]
        all_tiers = [v.get('name', '') for v in type_node.findall('value') if v.get('name', '').startswith('Tier')]
        flags = {
            "count_in_map": type_node.find('flags').get('count_in_map', '0') if type_node.find('flags') is not None else '0',
            "count_in_hoarder": type_node.find('flags').get('count_in_hoarder', '0') if type_node.find('flags') is not None else '0',
            "count_in_cargo": type_node.find('flags').get('count_in_cargo', '0') if type_node.find('flags') is not None else '0',
            "count_in_player": type_node.find('flags').get('count_in_player', '0') if type_node.find('flags') is not None else '0',
            "crafted": type_node.find('flags').get('crafted', '0') if type_node.find('flags') is not None else '0',
            "deloot": type_node.find('flags').get('deloot', '0') if type_node.find('flags') is not None else '0',
        }
        
        results.append({
            "name": item_name,
            "nominal": nominal.text if nominal is not None else "0",
            "nominal_v": v_nominal,
            "min": min_val.text if min_val is not None else "0",
            "min_v": v_min,
            "lifetime": lifetime.text if lifetime is not None else "0",
            "lifetime_v": v_life,
            "restock": restock.text if restock is not None else "0",
            "restock_v": v_rs,
            "category": type_node.find('category').get('name', '') if type_node.find('category') is not None else "",
            "usages": ",".join(all_usages),
            "tiers": ",".join(all_tiers),
            "flags": flags
        })
        
    print(json.dumps(results))

def update(xml_path, item_name, key, value):
    tree, root = get_types_root(xml_path)
    target = None
    for type_node in root.findall('type'):
        if type_node.get('name') == item_name:
            target = type_node
            break
            
    if target is None:
        print(f"Item {item_name} not found", file=sys.stderr)
        sys.exit(1)
        
    node = target.find(key)
    if node is None:
        # Create node if it doesn't exist? (e.g. restock)
        node = ET.SubElement(target, key)
        
    node.text = str(value)
    
    # Save back
    try:
        # Note: ET.write doesn't preserve custom formatting/comments perfectly
        # but for DayZ it's usually acceptable if we use indent.
        if sys.version_info >= (3, 9):
            ET.indent(tree, space="    ", level=0)
        tree.write(xml_path, encoding='utf-8', xml_declaration=True)
        print("Success")
    except Exception as e:
        print(f"Error writing XML: {e}", file=sys.stderr)
        sys.exit(1)


# =============================================================================
# CE File Diff and Merge Functions (Phase 3)
# =============================================================================

def _get_items_from_ce_file(xml_path: str) -> Dict[str, ET.Element]:
    """
    Extract all items from a CE XML file into a dict keyed by name.
    
    Works for types, spawnabletypes, events (uses 'name' attribute).
    Returns empty dict if file doesn't exist or is invalid.
    """
    items = {}
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
        
        # Most CE files use children with 'name' attribute
        for child in root:
            name = child.get('name')
            if name:
                items[name] = child
    except Exception:
        pass
    return items


def _element_to_string(elem: ET.Element) -> str:
    """Convert element to canonical string for comparison."""
    return ET.tostring(elem, encoding='unicode', method='xml')


def diff_ce_files(source_path: str, local_path: str) -> Dict[str, Any]:
    """
    Compare two CE XML files at the item level.
    
    Args:
        source_path: Path to workshop/upstream version
        local_path: Path to user's CustomCE version
        
    Returns:
        Dict with keys:
            - added: list of item names in source but not local
            - removed: list of item names in local but not source
            - modified: list of item names with different content
            - unchanged: count of identical items
            - source_count: total items in source
            - local_count: total items in local
    """
    source_items = _get_items_from_ce_file(source_path)
    local_items = _get_items_from_ce_file(local_path)
    
    added = []
    removed = []
    modified = []
    unchanged = 0
    
    # Items in source
    for name, source_elem in source_items.items():
        if name not in local_items:
            added.append(name)
        else:
            # Compare content
            source_str = _element_to_string(source_elem)
            local_str = _element_to_string(local_items[name])
            if source_str != local_str:
                modified.append(name)
            else:
                unchanged += 1
    
    # Items in local but not source
    for name in local_items:
        if name not in source_items:
            removed.append(name)
    
    return {
        "added": sorted(added),
        "removed": sorted(removed),
        "modified": sorted(modified),
        "unchanged": unchanged,
        "source_count": len(source_items),
        "local_count": len(local_items)
    }


def count_ce_items(xml_path: str) -> Dict[str, Any]:
    """
    Count items in a CE XML file.
    
    Returns:
        Dict with 'count', 'ce_type', 'valid' keys
    """
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
        
        ce_info = CE_TYPE_REGISTRY.get(root.tag, {})
        count = sum(1 for child in root if child.get('name'))
        
        return {
            "count": count,
            "ce_type": ce_info.get('ce_type', 'unknown'),
            "valid": True
        }
    except Exception as e:
        return {
            "count": 0,
            "ce_type": "unknown",
            "valid": False,
            "error": str(e)
        }


def merge_ce_files(source_path: str, local_path: str, original_path: str = None) -> Dict[str, Any]:
    """
    Merge CE file updates while preserving user edits.
    
    Strategy:
    - Add items from source that don't exist in local (new from mod update)
    - Keep modified items as-is in local (user's edits preserved)
    - Flag items in local but not in source for review:
      - If original_path provided and item was in original: mod author removed it
      - If item wasn't in original: user added it manually, keep it
    
    Args:
        source_path: Path to new workshop version
        local_path: Path to user's working copy
        original_path: Optional path to snapshot from original link time
        
    Returns:
        Dict with merge result:
            - added: items added from source
            - flagged_for_removal: items possibly removed by mod author
            - user_custom: items user added (kept)
            - preserved: items with user modifications (kept)
            - success: bool
    """
    try:
        source_items = _get_items_from_ce_file(source_path)
        local_items = _get_items_from_ce_file(local_path)
        original_items = _get_items_from_ce_file(original_path) if original_path else {}
        
        # Parse local file for modification
        local_tree = ET.parse(local_path)
        local_root = local_tree.getroot()
        
        result = {
            "added": [],
            "flagged_for_removal": [],
            "user_custom": [],
            "preserved": [],
            "success": True
        }
        
        # Add new items from source
        for name, source_elem in source_items.items():
            if name not in local_items:
                # Deep copy the element
                new_elem = ET.fromstring(ET.tostring(source_elem))
                local_root.append(new_elem)
                result["added"].append(name)
        
        # Check for removed items
        for name in local_items:
            if name not in source_items:
                if name in original_items:
                    # Was in original, now gone from source = mod author removed it
                    result["flagged_for_removal"].append(name)
                else:
                    # Not in original = user added it
                    result["user_custom"].append(name)
        
        # Track preserved modifications
        for name in local_items:
            if name in source_items:
                source_str = _element_to_string(source_items[name])
                local_str = _element_to_string(local_items[name])
                if source_str != local_str:
                    result["preserved"].append(name)
        
        # Write merged file
        if sys.version_info >= (3, 9):
            ET.indent(local_tree, space="    ", level=0)
        local_tree.write(local_path, encoding='utf-8', xml_declaration=True)
        
        return result
        
    except Exception as e:
        return {
            "success": False,
            "error": str(e)
        }

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='DayZ types.xml Parser Backend')
    subparsers = parser.add_subparsers(dest='command')
    
    # Metadata
    p_meta = subparsers.add_parser('metadata')
    p_meta.add_argument('file', help='Path to types.xml')
    
    # Is-Types detection (legacy, use detect-ce-type for new code)
    p_ist = subparsers.add_parser('is-types')
    p_ist.add_argument('file', help='Path to XML file')
    
    # CE Type Detection (new unified detection)
    p_detect = subparsers.add_parser('detect-ce-type', 
        help='Detect CE file type (types, spawnabletypes, events, eventspawns)')
    p_detect.add_argument('file', help='Path to XML file')
    p_detect.add_argument('--json', action='store_true', help='Output full JSON info')
    
    # List all supported CE types (for debugging/discovery)
    p_list = subparsers.add_parser('list-ce-types',
        help='List all supported CE file types')

    # Query
    p_query = subparsers.add_parser('query')
    p_query.add_argument('file', help='Path to types.xml')
    p_query.add_argument('--name', help='Filter by name')
    p_query.add_argument('--cat', help='Filter by category')
    p_query.add_argument('--usage', help='Filter by usage')
    p_query.add_argument('--tier', help='Filter by tier')
    p_query.add_argument('--vanilla', help='Path to vanilla types.xml for comparison')
    
    # Update
    p_upd = subparsers.add_parser('update')
    p_upd.add_argument('file', help='Path to types.xml')
    p_upd.add_argument('--item', required=True, help='Item classname')
    p_upd.add_argument('--key', required=True, help='Element tag to update')
    p_upd.add_argument('--val', required=True, help='New value')
    
    # Diff CE Files (Phase 3)
    p_diff = subparsers.add_parser('diff-ce',
        help='Compare two CE XML files at item level')
    p_diff.add_argument('source', help='Path to source/upstream file')
    p_diff.add_argument('local', help='Path to local/user file')
    
    # Count Items (Phase 3)
    p_count = subparsers.add_parser('count-items',
        help='Count items in a CE XML file')
    p_count.add_argument('file', help='Path to CE XML file')
    
    # Merge CE Files (Phase 4)
    p_merge = subparsers.add_parser('merge-ce',
        help='Merge CE file updates while preserving user edits')
    p_merge.add_argument('source', help='Path to new workshop version')
    p_merge.add_argument('local', help='Path to user working copy')
    p_merge.add_argument('--original', help='Path to original snapshot from link time')
    
    args = parser.parse_args()
    
    if args.command == 'metadata':
        metadata(args.file)
    elif args.command == 'is-types':
        is_types_xml(args.file)
    elif args.command == 'detect-ce-type':
        result = detect_ce_type(args.file)
        if result:
            if args.json:
                print(json.dumps(result))
            else:
                print(result['ce_type'])
        else:
            if args.json:
                print(json.dumps(None))
            else:
                print('')
    elif args.command == 'list-ce-types':
        # Output all supported CE types for discovery
        for root_tag, config in CE_TYPE_REGISTRY.items():
            print(f"{root_tag}: {config['ce_type']} -> {config['folder']}")
    elif args.command == 'query':
        query(args.file, args.name, args.cat, args.usage, args.tier, args.vanilla)
    elif args.command == 'update':
        update(args.file, args.item, args.key, args.val)
    elif args.command == 'diff-ce':
        result = diff_ce_files(args.source, args.local)
        print(json.dumps(result))
    elif args.command == 'count-items':
        result = count_ce_items(args.file)
        print(json.dumps(result))
    elif args.command == 'merge-ce':
        result = merge_ce_files(args.source, args.local, args.original)
        print(json.dumps(result))
    else:
        parser.print_help()

