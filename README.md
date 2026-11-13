# tsubaki-scraper-extensions

Scraper (source) extensions for [Tsubaki](https://github.com/ghero101/Tsubaki) — the
scanlation/manga source connectors (MangaDex, Asura Scans, Webtoon, Comick, …).

This is one of three type-split extension repositories:

- [tsubaki-metadata-extensions](https://github.com/ghero101/tsubaki-metadata-extensions) — metadata providers
- **tsubaki-scraper-extensions** — source/scanlation scrapers (this repo)
- [tsubaki-art-extensions](https://github.com/ghero101/tsubaki-art-extensions) — artwork / image-board sources

## Layout

```
sources/<addon>/     # addon source (manifest.json, plugin.rhai/.lua, icon.png)
dist/<addon>/        # built .zip packages consumed by the marketplace
templates/           # scaffolding for new addons of this type
docs/                # EXTENSION_API.md, MANIFEST_SCHEMA.md
index.json           # marketplace index for this repo
```

## Marketplace index

The app consumes `index.json` at the repo root (raw GitHub URL). Each entry's
`icon_url` / `manifest_url` / `download_url` point back into this repo.

## Adding / updating an addon

1. Edit files under `sources/<addon>/` and bump the `version` in `manifest.json`.
2. Build the zip into `dist/<addon>/` (see `build.ps1` / `build.sh`).
3. Update `index.json`.
4. Commit and push; update via the app UI to test.

## Scanlator site templates

Many scanlation groups run one of a few site platforms. `templates/` holds one
Rhai scraper per platform, and `tools/new-source.py` stamps out a source from
one (plugin, manifest; add an `icon.png`, then run `build.sh`):

| Template | Platform | Sources built from it |
|---|---|---|
| `scraper-mangathemesia` | Themesia "MangaReader" WordPress theme | Thunder Scans, Kingofshojo, Lagoon Scans, Madara Scans |
| `scraper-iken` | Next.js CMS with a JSON API on `api.<domain>/api` | Vortex Scans, Ken Scans, Magus Manga, Nyx Scans (HiveToons runs it too) |
| `scraper-nextcms` | Next.js platform with `/series/comic/{slug}` and `/api/search` | Drake Scans, Elf Toon, Valir Scans |

```bash
tools/new-source.py mangathemesia lagoonscans "Lagoon Scans" https://lagoonscans.com manga 1.0.0
tools/new-source.py iken vortexscans "Vortex Scans" https://vortexscans.org https://api.vortexscans.org/api 1.0.0
tools/new-source.py nextcms drakescans "Drake Scans" https://drakecomic.net - 1.0.0
```

Coin-locked early-access chapters are skipped by all three: they can't be
read for free, and they appear once the group unlocks them.
