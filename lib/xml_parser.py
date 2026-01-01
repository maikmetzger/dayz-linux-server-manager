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
CE_TYPE_REGISTRY: Dict[str, Dict[str, str]] = {
    'types': {
        'ce_type': 'types',
        'folder': 'CustomCE/types',
        'description': 'Item spawn definitions (nominal, min, lifetime, restock)'
    },
    'spawnabletypes': {
        'ce_type': 'spawnabletypes',
        'folder': 'CustomCE/spawnabletypes',
        'description': 'Attachments/cargo spawning on items (vehicles, weapons)'
    },
    'events': {
        'ce_type': 'events',
        'folder': 'CustomCE/events',
        'description': 'Dynamic events (animal herds, vehicle spawns, crashes)'
    },
    'eventposdef': {
        'ce_type': 'eventspawns',
        'folder': 'CustomCE/eventspawns',
        'description': 'Fixed spawn positions for events'
    }
}

def get_types_root(xml_path):
    try:
        tree = ET.parse(xml_path)
        return tree, tree.getroot()
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

def detect_ce_type(xml_path: str) -> Optional[Dict[str, str]]:
    """
    Detects the Central Economy file type based on root XML element.
    
    Args:
        xml_path: Path to the XML file to analyze
        
    Returns:
        Dict with 'ce_type', 'folder', 'description' if recognized, else None
    """
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
        return CE_TYPE_REGISTRY.get(root.tag)
    except Exception:
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

