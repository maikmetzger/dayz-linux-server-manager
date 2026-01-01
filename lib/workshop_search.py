#!/usr/bin/env python3
import sys
import json
import urllib.request
import urllib.parse
import re
import argparse
import os
import time

DAYZ_APPID = "221100"
CACHE_FILE = os.path.join(os.path.dirname(os.path.dirname(__file__)), "data", "workshop_cache_v2.json")
CACHE_EXPIRY_SEARCH = 3600 # 1 hour
CACHE_EXPIRY_DETAILS = 86400 # 24 hours

SORT_MAP = {
    "trend": "trend",
    "mostsubscribed": "totaluniquesubscribers",
    "mostsubscribed_asc": "totaluniquesubscribers", # Steam only has DESC, we reverse locally
    "newestfirst": "mostrecent",
    "lastupdated": "lastupdated",
    "relevance": "relevance"
}

def load_cache():
    if not os.path.exists(CACHE_FILE): return {}
    try:
        with open(CACHE_FILE, 'r') as f: return json.load(f)
    except: return {}

def save_cache(cache):
    try:
        os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
        with open(CACHE_FILE, 'w') as f: json.dump(cache, f, indent=2)
    except: pass

def search_workshop(text, sort="trend", num=25, page=1):
    cache = load_cache()
    cache_key = f"search_{text}_{sort}_{num}_{page}"
    if cache_key in cache:
        entry = cache[cache_key]
        if time.time() - entry['timestamp'] < CACHE_EXPIRY_SEARCH:
            return entry['data']

    encoded_text = urllib.parse.quote(text)
    api_sort = SORT_MAP.get(sort, "trend")
    sort_param = f"&browsesort={api_sort}" if api_sort != "relevance" else ""
    
    # FIX: If searching for "DayZ" (app name), treat as empty search to enable global Browsing Sort
    # Search mode forces 'Relevance', Browsing mode allows 'Most Subscribed' etc.
    if text.lower() == "dayz" or not text.strip():
        url = f"https://steamcommunity.com/workshop/browse/?appid=221100{sort_param}&section=readytouseitems&actualsort={api_sort}&p={page}"
    else:
        url = f"https://steamcommunity.com/workshop/browse/?appid=221100&searchtext={encoded_text}{sort_param}&section=readytouseitems&actualsort={api_sort}&p={page}"
    
    try:
        headers = {'User-Agent': 'Mozilla/5.0'}
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as response:
            html = response.read().decode('utf-8')
        
        ids = []
        found = re.findall(r'data-publishedfileid="([0-9]+)"', html)
        for fid in found:
            if fid not in ids:
                ids.append(fid)
                if len(ids) >= num: break
        
        cache[cache_key] = {'timestamp': time.time(), 'data': ids}
        save_cache(cache)
        return ids
    except Exception as e:
        print(f"Search Error: {e}", file=sys.stderr)
        return []

def scrape_dependencies(mod_id):
    url = f"https://steamcommunity.com/sharedfiles/filedetails/?id={mod_id}"
    try:
        headers = {'User-Agent': 'Mozilla/5.0'}
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as response:
            html = response.read().decode('utf-8', errors='ignore')
        
        sidebar_id = 'id="RequiredItems_container"'
        if sidebar_id in html:
            container = html.split(sidebar_id)[1].split('</div>')[0]
            return re.findall(r'id=([0-9]+)', container)
        
        if "Required items" in html:
            section = html.split("Required items")[1].split("</div>")[0]
            reqs = re.findall(r'id=([0-9]+)', section)
        
        author = "Unknown"
        # Robust Author Regex: Look for friendBlockContent, then capture text inside (or inside anchor)
        # Matches: <div class="friendBlockContent">Username</div> OR <div ...><a ...>Username</a>...
        try:
            m = re.search(r'class="friendBlockContent"[^>]*>[\s\r\n]*?(?:<a[^>]*>)?([^<]+)(?:</a>)?', html)
            if m:
                author = m.group(1).strip()
        except: pass
        
        return reqs, author
    except Exception: return [], "Unknown"

def parse_bbcode(text):
    if not text: return "", []
    images = []
    # Extract images
    img_tags = re.findall(r'\[img\](.*?)\[/img\]', text, re.IGNORECASE)
    images.extend(img_tags)
    
    # Clean text
    clean = text
    clean = re.sub(r'\[img\].*?\[/img\]', '', clean, flags=re.IGNORECASE) # Remove images from text
    clean = re.sub(r'\[url=.*?\](.*?)\[/url\]', r'\1', clean, flags=re.IGNORECASE)
    clean = re.sub(r'\[url\](.*?)\[/url\]', r'\1', clean, flags=re.IGNORECASE)
    
    # Visual markers for Headers
    def header_rep(m): return f"\n\n>> {m.group(1).upper()} <<\n"
    clean = re.sub(r'\[h[123]\](.*?)\[/h[123]\]', header_rep, clean, flags=re.IGNORECASE)
    
    # Other Formatting
    clean = re.sub(r'\[b\](.*?)\[/b\]', r'*\1*', clean, flags=re.IGNORECASE)
    clean = re.sub(r'\[i\](.*?)\[/i\]', r'_\1_', clean, flags=re.IGNORECASE)
    clean = re.sub(r'\[/*(list|olist|\*|hr|code|quote|box)\]', '', clean, flags=re.IGNORECASE)
    
    clean = re.sub(r'\r\n', '\n', clean)
    clean = re.sub(r'\n\n+', '\n\n', clean)  # Keep paragraphs distinct
    
    return clean.strip(), images

def get_mod_details(mod_ids, recursive=False, update_rules=None):
    if not mod_ids: return []
    cache = load_cache()
    
    results = []
    to_fetch = []
    
    for mid in mod_ids:
        cache_key = f"details_{mid}"
        if cache_key in cache:
            entry = cache[cache_key]
            # If we need author/images and it's missing (legacy cache), re-fetch
            if 'author' not in entry['data'] or 'images' not in entry['data']: to_fetch.append(mid)
            elif time.time() - entry['timestamp'] < CACHE_EXPIRY_DETAILS:
                results.append(entry['data'])
                continue
            else: to_fetch.append(mid)
        else: to_fetch.append(mid)

    if to_fetch:
        api_url = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
        fetched_details = {}
        fetch_queue = set(to_fetch)
        processed = set()
        
        while fetch_queue:
            batch = list(fetch_queue)[:100]
            for mid in batch: fetch_queue.remove(mid); processed.add(mid)
            
            data_dict = {"itemcount": len(batch)}
            for i, mid in enumerate(batch): data_dict[f"publishedfileids[{i}]"] = mid
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
                    size_str = f"{size_bytes / (1024**3):.1f} GB" if size_bytes > 1024**3 else f"{size_bytes / (1024**2):.1f} MB"
                    
                    req_items = [r.get('publishedfileid') for r in d.get('required_items', [])]
                    scraped_reqs, author = scrape_dependencies(mid)
                    if not req_items: req_items = scraped_reqs
                    
                    raw_desc = d.get('description', "")
                    clean_desc, imgs = parse_bbcode(raw_desc)
                    
                    details_obj = {
                        "id": mid, "name": d.get('title', f"Mod {mid}"),
                        "subscribers": subs, "subscribers_f": formatted_subs,
                        "size": size_str, "size_bytes": size_bytes,
                        "updated": d.get('time_updated', 0), 
                        "description": raw_desc,
                        "description_clean": clean_desc,
                        "images": imgs,
                        "dependencies": req_items,
                        "author": author
                    }
                    fetched_details[mid] = details_obj
                    cache[f"details_{mid}"] = {'timestamp': time.time(), 'data': details_obj}
                    
                    if recursive:
                        for r_id in req_items:
                            if r_id not in processed: fetch_queue.add(r_id)
            except Exception as e:
                print(f"Detail Error: {e}", file=sys.stderr)
                break
        
        save_cache(cache)
        # Combine and preserve order
        for mid in mod_ids:
            if mid in fetched_details: results.append(fetched_details[mid])
            elif f"details_{mid}" in cache: results.append(cache[f"details_{mid}"]['data'])

    # Recursive resolver for results
    final_results = []
    seen = set()
    def resolve(obj):
        if obj['id'] in seen: return
        if recursive:
            for dep_id in obj.get('dependencies', []):
                # Ensure we have details for dependency (might be in cache)
                d_key = f"details_{dep_id}"
                if d_key in cache: resolve(cache[d_key]['data'])
        if obj['id'] not in seen:
            final_results.append(obj)
            seen.add(obj['id'])

    for res in results: resolve(res)
    
    if update_rules and os.path.exists(update_rules):
        try:
            with open(update_rules, 'r') as f: rules = json.load(f)
            ch = False
            if 'dependencies' not in rules: rules['dependencies'] = {}; ch = True
            for mid, entry in cache.items():
                if not mid.startswith("details_"): continue
                item = entry['data']
                iid = item['id']
                if iid not in rules['dependencies'] or rules['dependencies'][iid] != item['dependencies']:
                    rules['dependencies'][iid] = item['dependencies']; ch = True
            if ch:
                with open(update_rules, 'w') as f: json.dump(rules, f, indent=4)
        except Exception as e: print(f"Rules Update Error: {e}", file=sys.stderr)
        
    return final_results

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
        ids = args.details.split(',')
        print(json.dumps(get_mod_details(ids, args.recursive, args.update_rules)))
    elif args.search:
        ids = search_workshop(args.search, args.sort, args.num, args.page)
        print(json.dumps(get_mod_details(ids, args.recursive, args.update_rules)))
    else: parser.print_help()
