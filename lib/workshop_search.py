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
CACHE_FILE = os.path.join(os.path.dirname(os.path.dirname(__file__)), "data", "workshop_cache_v3.json")
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

def search_workshop(text, sort="trend", num=25, page=1, mode="title"):
    cache = load_cache()
    # Cache key reflects query args, but we might fetch different steam pages internally
    # We'll rely on url-based caching inside the loop if possible, or just cache per user-query
    # Actually, simpler to just fetch needed pages and let user-query cache handle the result
    cache_key = f"search_{text}_{sort}_{num}_{page}_{mode}"
    if cache_key in cache:
        entry = cache[cache_key]
        if time.time() - entry['timestamp'] < CACHE_EXPIRY_SEARCH:
            return entry['data']

    encoded_text = urllib.parse.quote(text)
    api_sort = SORT_MAP.get(sort, "trend")
    
    # Simple approach: just use browsesort for all modes
    sort_param = f"&browsesort={api_sort}" if api_sort != "relevance" else ""
    
    # Steam Logic: Page size is fixed at 30 for Browse
    STEAM_PAGE_SIZE = 30
    
    # Calculate Global Item Range
    global_start = (page - 1) * num
    global_end = global_start + num
    
    # Calculate Required Steam Pages
    steam_start_p = (global_start // STEAM_PAGE_SIZE) + 1
    steam_end_p = ((global_end - 1) // STEAM_PAGE_SIZE) + 1
    
    all_found_ids = []
    
    # Fetch Loop
    for p in range(steam_start_p, steam_end_p + 1):
        if text.lower() == "dayz" or not text.strip():
            url = f"https://steamcommunity.com/workshop/browse/?appid=221100{sort_param}&section=readytouseitems&p={p}"
        else:
            url = f"https://steamcommunity.com/workshop/browse/?appid=221100&searchtext={encoded_text}{sort_param}&section=readytouseitems&p={p}"
            
        # print(f"DEBUG_URL: {url}", file=sys.stderr)
        
        try:
            headers = {'User-Agent': 'Mozilla/5.0'}
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req) as response:
                html = response.read().decode('utf-8')
            
            page_ids = []
            
            if mode == "author" and text.strip() and text.lower() != "dayz":
                # Strict Author Filter
                items = html.split('class="workshopItem"')
                for item in items[1:]:
                    try:
                        fid_m = re.search(r'data-publishedfileid="([0-9]+)"', item)
                        if not fid_m: continue
                        fid = fid_m.group(1)
                        if fid in page_ids: continue 
                        
                        author_m = re.search(r'class="workshopItemAuthorName"[^>]*>[\s\S]*?<a[^>]*>([^<]+)</a>', item)
                        if author_m:
                            author_name = author_m.group(1).strip()
                            if text.lower() in author_name.lower():
                                page_ids.append(fid)
                    except: pass
            else:
                # Standard Search
                # We need to split by item to associate rating with ID
                items = html.split('class="workshopItem"')
                for item in items[1:]:
                    fid_m = re.search(r'data-publishedfileid="([0-9]+)"', item)
                    if not fid_m: continue
                    fid = fid_m.group(1)
                    if fid not in page_ids: page_ids.append(fid)
                    
                    # Extract Rating (0-5 stars)
                    # src=".../5-star.png"
                    rating = 0
                    star_m = re.search(r'src=".*?([0-9])-star\.png', item)
                    if star_m:
                        rating = int(star_m.group(1))
                    
                    # Update Cache with Rating immediately
                    d_key = f"details_{fid}"
                    if d_key not in cache:
                        cache[d_key] = {'timestamp': 0, 'data': {'id': fid}} # Timestamp 0 forces refresh but keeps data
                    
                    cache[d_key]['data']['rating_stars'] = rating
            
            all_found_ids.extend(page_ids)
            
        except Exception as e:
            print(f"Fetch Error Page {p}: {e}", file=sys.stderr)
            break
            
    # Slice the result to match user request
    # Indices relative to the first fetched page's start
    # We fetched starting at steam_start_p.
    # The first item in all_found_ids corresponds to global index: (steam_start_p - 1) * 30
    
    base_index = (steam_start_p - 1) * STEAM_PAGE_SIZE
    local_start = global_start - base_index
    local_end = local_start + num
    
    # Safety slice
    final_ids = all_found_ids[local_start:local_end]
    
    cache[cache_key] = {'timestamp': time.time(), 'data': final_ids}
    save_cache(cache)
    return final_ids

def scrape_dependencies(mod_id):
    url = f"https://steamcommunity.com/sharedfiles/filedetails/?id={mod_id}"
    try:
        headers = {'User-Agent': 'Mozilla/5.0'}
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as response:
            html = response.read().decode('utf-8', errors='ignore')
        
        reqs = []
        sidebar_id = 'id="RequiredItems_container"'
        if sidebar_id in html:
            container = html.split(sidebar_id)[1].split('</div>')[0]
            reqs = re.findall(r'id=([0-9]+)', container)
        elif "Required items" in html:
            section = html.split("Required items")[1].split("</div>")[0]
            reqs = re.findall(r'id=([0-9]+)', section)
        
        author = "Unknown"
        # Robust Author Regex
        try:
            # Find all authors (Creators)
            found_authors = re.findall(r'class="friendBlockContent"[^>]*>[\s\r\n]*?(?:<a[^>]*>)?([^<]+)(?:</a>)?', html)
            if found_authors:
                # Clean up whitespace and join
                clean_authors = [a.strip() for a in found_authors if a.strip()]
                if clean_authors:
                    author = ", ".join(clean_authors)
        except: pass

        # Scrape Rating Count
        ratings_count = 0
        try:
            rc_m = re.search(r'(\d{1,3}(?:,\d{3})*) ratings', html)
            if rc_m:
                ratings_count = int(rc_m.group(1).replace(',', ''))
        except: pass
        
        return reqs, author, ratings_count
    except Exception: return [], "Unknown", 0


def check_mod_updates(mod_ids: list, local_versions: dict) -> dict:
    """
    Check for updates by comparing local versions to Steam API time_updated.
    
    Args:
        mod_ids: List of mod IDs to check
        local_versions: Dict mapping mod_id -> installed timestamp
        
    Returns:
        Dict with structure:
        {
            "mods": {
                "1234567": {
                    "installed": 1735603200,
                    "latest": 1735689600,
                    "has_update": true,
                    "name": "Mod Name"
                }
            },
            "update_count": 3,
            "checked_at": 1735761600
        }
    """
    if not mod_ids:
        return {"mods": {}, "update_count": 0, "checked_at": int(time.time())}
    
    # Fetch details from Steam API (uses existing function which caches)
    details = get_mod_details(mod_ids)
    
    result = {
        "mods": {},
        "update_count": 0,
        "checked_at": int(time.time())
    }
    
    for mod in details:
        mod_id = mod.get('id')
        if not mod_id:
            continue
            
        remote_updated = mod.get('updated', 0)
        local_updated = int(local_versions.get(mod_id, 0))
        has_update = remote_updated > local_updated and local_updated > 0
        
        result["mods"][mod_id] = {
            "installed": local_updated,
            "latest": remote_updated,
            "has_update": has_update,
            "name": mod.get('name', f"Mod {mod_id}")
        }
        
        if has_update:
            result["update_count"] += 1
    
    return result

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
            # If we need author/images/rating_count and it's missing (legacy cache) or Unknown, re-fetch
            # Also re-fetch if rating_count is missing or 0 (likely legacy cache), unless it's genuinely 0 (rare for top mods)
            # We can use a heuristic: if we have rating_stars > 0 but rating_count is 0, RE-FETCH.
            data = entry['data']
            needs_refetch = False
            
            if 'author' not in data or 'images' not in data or data['author'] == "Unknown": needs_refetch = True
            elif 'rating_count' not in data: needs_refetch = True
            elif data.get('rating_stars', 0) in [3, 4, 5] and data.get('rating_count', 0) == 0: needs_refetch = True
            
            if not needs_refetch and time.time() - entry['timestamp'] < CACHE_EXPIRY_DETAILS:
                results.append(data)
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
                    scraped_reqs, author, rating_count = scrape_dependencies(mid)
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
                        "author": author,
                        "rating_count": rating_count
                    }
                    
                    # Preserve scraped rating if exists in cache
                    d_key = f"details_{mid}"
                    if d_key in cache and 'rating_stars' in cache[d_key]['data']:
                        details_obj['rating_stars'] = cache[d_key]['data']['rating_stars']
                    
                    fetched_details[mid] = details_obj
                    cache[d_key] = {'timestamp': time.time(), 'data': details_obj}
                    
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
    parser = argparse.ArgumentParser(description='DayZ Workshop Search Backend V3')
    parser.add_argument('--search', help='Search text')
    parser.add_argument('--sort', default='trend', help='Sort order')
    parser.add_argument('--num', type=int, default=25, help='Max results per page')
    parser.add_argument('--page', type=int, default=1, help='Page number')
    parser.add_argument('--mode', default='title', help='Search mode: title or author')
    parser.add_argument('--details', help='Comma-separated Mod IDs for direct details')
    parser.add_argument('--recursive', action='store_true', help='Resolve dependencies recursively')
    parser.add_argument('--update-rules', help='Path to workshop_rules.json to update')
    parser.add_argument('--clear', '--clear-cache', action='store_true', help='Clear cache before searching')
    parser.add_argument('--check-updates', help='JSON string of {mod_id: local_timestamp} to check for updates')
    args = parser.parse_args()

    if args.clear and os.path.exists(CACHE_FILE):
        try: os.remove(CACHE_FILE)
        except: pass
    
    if args.check_updates:
        # Parse input: expects JSON like {"1234567": 1735603200, "9876543": 1735500000}
        try:
            local_versions = json.loads(args.check_updates)
            mod_ids = list(local_versions.keys())
            result = check_mod_updates(mod_ids, local_versions)
            print(json.dumps(result))
        except json.JSONDecodeError as e:
            print(json.dumps({"error": f"Invalid JSON: {e}"}), file=sys.stderr)
            sys.exit(1)
    elif args.details:
        ids = args.details.split(',')
        print(json.dumps(get_mod_details(ids, args.recursive, args.update_rules)))
    elif args.search:
        ids = search_workshop(args.search, args.sort, args.num, args.page, args.mode)
        print(json.dumps(get_mod_details(ids, args.recursive, args.update_rules)))
    else:
        parser.print_help()

