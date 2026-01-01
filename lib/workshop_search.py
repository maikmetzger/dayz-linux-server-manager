#!/usr/bin/env python3
import sys
import json
import urllib.request
import urllib.parse
import re
import argparse
import os

DAYZ_APPID = "221100"

def search_workshop(text, sort="trend", num=25, page=1):
    """
    Scrapes Mod IDs from Steam Workshop browse page.
    """
    encoded_text = urllib.parse.quote(text)
    url = f"https://steamcommunity.com/workshop/browse/?appid=221100&searchtext={encoded_text}&browsesort={sort}&section=readytouseitems&actualsort={sort}&p={page}"
    
    try:
        headers = {'User-Agent': 'Mozilla/5.0'}
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as response:
            html = response.read().decode('utf-8')
        
        ids = []
        found = re.findall(r'id="sharedfile_([0-9]+)"', html)
        for fid in found:
            if fid not in ids:
                ids.append(fid)
                if len(ids) >= num: break
        return ids
    except Exception as e:
        print(f"Search Error: {e}", file=sys.stderr)
        return []

def scrape_dependencies(mod_id):
    """
    Fallback: Scrape 'Required items' from the Workshop HTML.
    Steam API often omits these for standard WebAPI queries.
    """
    url = f"https://steamcommunity.com/sharedfiles/filedetails/?id={mod_id}"
    try:
        headers = {'User-Agent': 'Mozilla/5.0'}
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as response:
            html = response.read().decode('utf-8', errors='ignore')
        
        # Look for the RequiredItems_container
        sidebar_id = 'id="RequiredItems_container"'
        if sidebar_id in html:
            container = html.split(sidebar_id)[1].split('</div>')[0]
            return re.findall(r'id=([0-9]+)', container)
        
        # Broad fallback
        if "Required items" in html:
            section = html.split("Required items")[1].split("</div>")[0]
            return re.findall(r'id=([0-9]+)', section)
            
        return []
    except Exception: return []

def get_mod_details(mod_ids, recursive=False, update_rules=None):
    """
    Fetches rich metadata for a list of Mod IDs using official public WebAPI.
    """
    if not mod_ids: return []
        
    api_url = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
    all_details = {}
    to_fetch = set(mod_ids)
    fetched = set()
    
    while to_fetch:
        batch = list(to_fetch)[:100]
        for mid in batch:
            to_fetch.remove(mid)
            fetched.add(mid)
            
        data_dict = {"itemcount": len(batch)}
        for i, mid in enumerate(batch):
            data_dict[f"publishedfileids[{i}]"] = mid
            
        encoded_data = urllib.parse.urlencode(data_dict).encode('utf-8')
        
        try:
            req = urllib.request.Request(api_url, data=encoded_data)
            with urllib.request.urlopen(req) as response:
                res_data = json.loads(response.read().decode('utf-8'))
                
            details = res_data.get('response', {}).get('publishedfiledetails', [])
            for d in details:
                mid = d.get('publishedfileid')
                if not mid: continue
                
                subs = d.get('subscriptions', 0)
                formatted_subs = "{:,}".format(subs).replace(",", ".")
                
                size_bytes = int(d.get('file_size', 0))
                if size_bytes > 1024**3:
                    size_str = f"{size_bytes / (1024**3):.1f} GB"
                else:
                    size_str = f"{size_bytes / (1024**2):.1f} MB"
                
                req_items = [r.get('publishedfileid') for r in d.get('required_items', [])]
                if not req_items:
                    req_items = scrape_dependencies(mid)
                
                all_details[mid] = {
                    "id": mid,
                    "name": d.get('title', f"Mod {mid}"),
                    "subscribers": subs,
                    "subscribers_f": formatted_subs,
                    "size": size_str,
                    "size_bytes": size_bytes,
                    "updated": d.get('time_updated', 0),
                    "description": d.get('description', ""),
                    "dependencies": req_items
                }
                
                if recursive:
                    for r_id in req_items:
                        if r_id not in fetched: to_fetch.add(r_id)
                            
        except Exception as e:
            print(f"Detail Error: {e}", file=sys.stderr)
            break
            
    results = []
    seen_in_results = set()
    
    def add_to_results(mid):
        if mid not in all_details or mid in seen_in_results: return
        for dep_id in all_details[mid].get('dependencies', []):
            add_to_results(dep_id)
        if mid not in seen_in_results:
            results.append(all_details[mid])
            seen_in_results.add(mid)

    for mid in mod_ids: add_to_results(mid)
        
    if update_rules and os.path.exists(update_rules):
        try:
            with open(update_rules, 'r') as f: rules = json.load(f)
            rules_changed = False
            if 'dependencies' not in rules: rules['dependencies'] = {}
            for mid, info in all_details.items():
                if mid not in rules['dependencies'] or rules['dependencies'][mid] != info['dependencies']:
                    rules['dependencies'][mid] = info['dependencies']
                    rules_changed = True
            if rules_changed:
                with open(update_rules, 'w') as f: json.dump(rules, f, indent=4)
        except Exception as e: print(f"Rules Update Error: {e}", file=sys.stderr)
        
    return results

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='DayZ Workshop Search Backend')
    parser.add_argument('--search', help='Search text')
    parser.add_argument('--sort', default='trend', help='Sort order')
    parser.add_argument('--num', type=int, default=25, help='Max results per page')
    parser.add_argument('--page', type=int, default=1, help='Page number')
    parser.add_argument('--details', help='Comma-separated Mod IDs for direct details')
    parser.add_argument('--recursive', action='store_true', help='Resolve dependencies recursively')
    parser.add_argument('--update-rules', help='Path to workshop_rules.json to update')
    
    args = parser.parse_args()
    
    if args.details:
        mod_ids = args.details.split(',')
        print(json.dumps(get_mod_details(mod_ids, args.recursive, args.update_rules)))
    elif args.search:
        ids = search_workshop(args.search, args.sort, args.num, args.page)
        print(json.dumps(get_mod_details(ids, args.recursive, args.update_rules)))
    else:
        parser.print_help()
