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
