#!/usr/bin/env python3
"""Create (or refresh) a scanlator source from one of the site templates.

Usage:
  tools/new-source.py mangathemesia ID "Name" https://base.url SERIES_DIR VERSION [rating] [extra,domains]
  tools/new-source.py iken          ID "Name" https://base.url API_URL    VERSION [rating] [extra,domains]

templates/scraper-mangathemesia: the Themesia "MangaReader" WordPress theme.
  SERIES_DIR is the series folder in its URLs ("manga", "comics", "series").
  tools/new-source.py nextcms       ID "Name" https://base.url -          VERSION [rating] [extra,domains]

templates/scraper-nextcms: the Next.js platform of Drake Scans / Elf Toon /
  Valir Scans (/series/comic/{slug}, /api/search, /api/chapters/next).
templates/scraper-iken: the Next.js scanlation CMS with a JSON API on
  api.<domain>/api (HiveToons, Vortex Scans, ...). Pass that API base.

Writes sources/ID/plugin.rhai and manifest.json. Keeps an existing icon.png.
"""
import json, os, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
kind, sid, name, base, param, version = sys.argv[1:7]
rating = sys.argv[7] if len(sys.argv) > 7 else "suggestive"
extra = [d for d in (sys.argv[8].split(",") if len(sys.argv) > 8 else []) if d]
base = base.rstrip("/")
host = base.split("://", 1)[1]
tpl = os.path.join(root, "templates", "scraper-" + kind, "plugin.rhai")
src = open(tpl, encoding="utf-8").read()
for k, v in {"{{ID}}": sid, "{{NAME}}": name, "{{BASE_URL}}": base,
             "{{SERIES_DIR}}": param, "{{API_URL}}": param.rstrip("/"), "{{CONTENT_RATING}}": rating}.items():
    src = src.replace(k, v)
out = os.path.join(root, "sources", sid)
os.makedirs(out, exist_ok=True)
open(os.path.join(out, "plugin.rhai"), "w", encoding="utf-8").write(src)
bare = host[4:] if host.startswith("www.") else host
domains = [bare, "www." + bare] + ([ "i0.wp.com", "i1.wp.com", "i2.wp.com", "i3.wp.com"] if kind == "mangathemesia" else ["api." + bare, "storage." + bare, "media." + bare] if kind == "iken" else ["media." + bare]) + extra
manifest = {
    "manifest_version": 1,
    "id": sid,
    "name": name,
    "version": version,
    "description": f"{name} — read chapters straight from the scanlation group's own site ({bare}).",
    "author": {"name": "Tsubaki Community", "url": "https://github.com/ghero101"},
    "license": "MIT",
    "repository": "https://github.com/ghero101/tsubaki-scraper-extensions",
    "addon_type": "scraper",
    "icon_path": "icon.png",
    "nsfw": rating == "nsfw",
    "technology": "rhai",
    "entry_point": {"file": "plugin.rhai"},
    "capabilities": {
        "level": "http_only",
        "allowed_domains": domains,
        "requires_cookies": False,
        "requires_javascript": False,
        "cloudflare_protected": False,
    },
    "features": {"search": True, "browse": True, "get_series": True, "get_chapters": True,
                 "get_pages": True, "download": True, "get_covers": True},
    "authentication": {"type": "none"},
    "source_info": {"base_url": base, "language": "en", "content_rating": rating,
                    "tags": ["scanlation", "scanlator", "manhwa", kind]},
    "rate_limiting": {"requests_per_minute": 30, "burst_limit": 5},
}
json.dump(manifest, open(os.path.join(out, "manifest.json"), "w", encoding="utf-8"), indent=2, ensure_ascii=False)
open(os.path.join(out, "manifest.json"), "a").write("\n")
print("wrote", out)
