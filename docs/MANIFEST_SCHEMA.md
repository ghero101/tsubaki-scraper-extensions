# Manifest Schema Reference

Complete documentation for the `manifest.json` file format.

## Full Schema

```json
{
  "manifest_version": 1,
  "id": "string (required)",
  "name": "string (required)",
  "version": "string (required)",
  "description": "string",
  "nsfw": "boolean",
  "author": {
    "name": "string",
    "url": "string"
  },
  "license": "string",
  "repository": "string",
  "addon_type": "scraper | metadata | artwork (required)",
  "icon_path": "string",
  "technology": "rhai | lua | wasm | python (required)",
  "entry_point": {
    "file": "string (required)"
  },
  "settings": [
    {
      "key": "string",
      "type": "text | boolean | number",
      "label": "string",
      "description": "string",
      "default": "any",
      "required": "boolean"
    }
  ],
  "capabilities": {
    "level": "http_only | browser_automation",
    "allowed_domains": ["string"],
    "requires_cookies": "boolean",
    "requires_javascript": "boolean",
    "cloudflare_protected": "boolean",
    "requires_proxy": "boolean"
  },
  "features": {
    "search": "boolean",
    "browse": "boolean",
    "get_series": "boolean",
    "get_chapters": "boolean",
    "get_pages": "boolean",
    "download": "boolean",
    "get_covers": "boolean",
    "tracking": "boolean",
    "sync_progress": "boolean"
  },
  "authentication": {
    "type": "none | oauth2 | basic | api_key | cookies",
    "oauth2": {
      "authorization_url": "string",
      "token_url": "string",
      "client_id": "string",
      "scopes": ["string"]
    },
    "fields": [
      {
        "name": "string",
        "label": "string",
        "type": "text | password | checkbox",
        "required": "boolean"
      }
    ]
  },
  "source_info": {
    "base_url": "string",
    "language": "string",
    "supported_languages": ["string"],
    "content_rating": "safe | suggestive | nsfw",
    "tags": ["string"]
  },
  "tag_search": {
    "autocomplete": "boolean",
    "popular_tags": "boolean",
    "syntax_help": "string"
  },
  "rate_limiting": {
    "requests_per_minute": "number",
    "burst_limit": "number"
  },
  "update": {
    "url": "string",
    "auto_update": "boolean",
    "download_url": "string"
  },
  "dependencies": {
    "addons": ["string"],
    "libraries": {
      "python": ["string"],
      "lua": ["string"]
    }
  }
}
```

---

## Field Reference

### Core Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `manifest_version` | number | Yes | Schema version. `1` is the baseline; `2` is used by a handful of metadata + settings-aware scrapers (AniList, MangaDex, Kitsu, MangaUpdates, BatCave) — no behavioural difference today, treated as a versioning placeholder for future format changes. |
| `id` | string | Yes | Unique identifier (lowercase, no spaces). **Must match the `id` in `index.json`** — otherwise the build script silently no-op's on this entry and updates never reach users. See NOTES.md for past incidents. |
| `name` | string | Yes | Display name |
| `version` | string | Yes | Semantic version (e.g., `1.0.0`) |
| `description` | string | No | Brief description |
| `nsfw` | boolean | No | Whether the source primarily serves adult content. Surfaced in the UI for content filtering. Default `false`. |
| `addon_type` | string | Yes | One of: `scraper`, `metadata`, `artwork` |
| `technology` | string | Yes | One of: `rhai`, `lua`, `wasm`, `python` |

### Author

```json
"author": {
  "name": "Developer Name",
  "url": "https://github.com/username"
}
```

### Entry Point

```json
"entry_point": {
  "file": "plugin.rhai"
}
```

The file extension should match the `technology` field.

### Capabilities

```json
"capabilities": {
  "level": "http_only",
  "allowed_domains": [
    "example.com",
    "cdn.example.com",
    "api.example.com"
  ],
  "requires_cookies": false,
  "requires_javascript": false,
  "cloudflare_protected": false
}
```

| Field | Description |
|-------|-------------|
| `level` | `http_only` for standard requests, `browser_automation` for Cloudflare bypass |
| `allowed_domains` | **Required.** All domains the extension will access (for image proxy whitelist) |
| `requires_cookies` | Extension needs to maintain cookies |
| `requires_javascript` | Site requires JS rendering |
| `cloudflare_protected` | Site uses Cloudflare protection |
| `requires_proxy` | **Opt in to the server's configured upstream proxy.** When `true`, the host routes this extension's `flaresolverr_get` / `flaresolverr_get_cookies` calls through the operator-configured proxy (Server Settings → "FlareSolverr Proxy") — typically a **residential** egress for sources that IP-ban datacenter/VPN addresses (e.g. nhentai, kagane). When `false`/omitted, those calls egress from the server's own IP. See *Residential proxy* in [EXTENSION_API.md](EXTENSION_API.md). |

**Important:** Always include CDN domains in `allowed_domains` or cover images won't load!

**When to set `requires_proxy: true`:** only if your source blocks the server's
datacenter/CGNAT IP at the Cloudflare/edge layer (symptom: empty results or CF
blocks from the server, but the site works from a home connection). It's opt-in
because routing through a proxy can *break* CF challenges for sources that are
fine from the datacenter IP, and it consumes the shared proxy's bandwidth.

### Features

Declare which functions your extension implements:

```json
"features": {
  "search": true,
  "browse": true,
  "get_series": true,
  "get_chapters": true,
  "get_pages": true,
  "download": false,
  "get_covers": true
}
```

For metadata extensions:
```json
"features": {
  "search": true,
  "get_series": true,
  "get_metadata": true,
  "tracking": true,
  "sync_progress": true
}
```

### Settings (user-configurable)

Use a `settings` array when your plugin needs runtime configuration that the
user can edit through the app's addon settings UI — typically the base URL of
a multi-tenant CMS, an opt-in feature flag, or a per-user content filter.

```json
"settings": [
  {
    "key": "base_url",
    "type": "text",
    "label": "Base URL",
    "description": "The base URL of the HeanCMS site (e.g., https://omegascans.org)",
    "default": "https://omegascans.org",
    "required": true
  },
  {
    "key": "use_new_chapter_endpoint",
    "type": "boolean",
    "label": "Use New Chapter Endpoint",
    "description": "Enable if the site uses /chapter/query instead of seasons in series response",
    "default": true
  }
]
```

| Field | Description |
|-------|-------------|
| `key` | Identifier the plugin reads via `safe_get_setting("key")` in Rhai |
| `type` | One of `text`, `boolean`, `number` |
| `label` | Shown above the input in the UI |
| `description` | Helper text shown below the input |
| `default` | Default value when the user hasn't set one |
| `required` | If true, the UI blocks save until the user provides a value |

Read settings inside the plugin with:

```rhai
let url = safe_get_setting("base_url");
let enabled = safe_get_setting("use_new_chapter_endpoint");
```

The `settings` array is the framework-extension pattern. The canonical example
is `heancms-rhai`, which lets users point one addon at any HeanCMS site (Omega
Scans, Reaper Scans, etc.) by editing the `base_url` setting.

---

### Authentication

#### No Authentication

```json
"authentication": {
  "type": "none"
}
```

#### OAuth2 (AniList, MyAnimeList)

```json
"authentication": {
  "type": "oauth2",
  "oauth2": {
    "authorization_url": "https://anilist.co/api/v2/oauth/authorize",
    "token_url": "https://anilist.co/api/v2/oauth/token",
    "client_id": "YOUR_CLIENT_ID",
    "scopes": ["read", "write"]
  }
}
```

#### API Key

```json
"authentication": {
  "type": "api_key",
  "fields": [
    {
      "name": "api_key",
      "label": "API Key",
      "type": "password",
      "required": true
    }
  ]
}
```

#### Username/Password

```json
"authentication": {
  "type": "basic",
  "fields": [
    {
      "name": "username",
      "label": "Username",
      "type": "text",
      "required": true
    },
    {
      "name": "password",
      "label": "Password",
      "type": "password",
      "required": true
    }
  ]
}
```

### Source Info

```json
"source_info": {
  "base_url": "https://example.com",
  "language": "en",
  "supported_languages": ["en", "es", "pt-br"],
  "content_rating": "suggestive",
  "tags": ["manga", "manhwa", "webtoon"]
}
```

| Content Rating | Description |
|----------------|-------------|
| `safe` | All ages content |
| `suggestive` | May contain mild adult themes |
| `nsfw` | Adult content, 18+ |

### Tag Search (Artwork Only)

For artwork/booru extensions with tag-based search:

```json
"tag_search": {
  "autocomplete": true,
  "popular_tags": true,
  "syntax_help": "Use spaces to combine tags. Prefix with - to exclude."
}
```

### Rate Limiting

```json
"rate_limiting": {
  "requests_per_minute": 30,
  "burst_limit": 5
}
```

### Update Configuration

```json
"update": {
  "url": "https://raw.githubusercontent.com/user/repo/master/sources/ext/manifest.json",
  "download_url": "https://raw.githubusercontent.com/user/repo/master/dist/ext/ext_latest.zip",
  "auto_update": true
}
```

---

## Complete Examples

### Scraper Extension

```json
{
  "manifest_version": 1,
  "id": "mangasite",
  "name": "MangaSite",
  "version": "1.0.0",
  "description": "Read manga from MangaSite",
  "author": {
    "name": "Developer",
    "url": "https://github.com/developer"
  },
  "license": "MIT",
  "addon_type": "scraper",
  "icon_path": "icon.png",
  "technology": "rhai",
  "entry_point": {
    "file": "plugin.rhai"
  },
  "capabilities": {
    "level": "http_only",
    "allowed_domains": [
      "mangasite.com",
      "cdn.mangasite.com"
    ]
  },
  "features": {
    "search": true,
    "browse": true,
    "get_series": true,
    "get_chapters": true,
    "get_pages": true
  },
  "authentication": {
    "type": "none"
  },
  "source_info": {
    "base_url": "https://mangasite.com",
    "language": "en",
    "content_rating": "suggestive"
  },
  "rate_limiting": {
    "requests_per_minute": 60,
    "burst_limit": 10
  }
}
```

### Metadata Extension

```json
{
  "manifest_version": 1,
  "id": "mytracker",
  "name": "MyTracker",
  "version": "1.0.0",
  "description": "Track your reading progress",
  "addon_type": "metadata",
  "technology": "rhai",
  "entry_point": {
    "file": "plugin.rhai"
  },
  "capabilities": {
    "level": "http_only",
    "allowed_domains": [
      "api.mytracker.com",
      "mytracker.com"
    ]
  },
  "features": {
    "search": true,
    "get_series": true,
    "get_metadata": true,
    "tracking": true,
    "sync_progress": true
  },
  "authentication": {
    "type": "oauth2",
    "oauth2": {
      "authorization_url": "https://mytracker.com/oauth/authorize",
      "token_url": "https://mytracker.com/oauth/token",
      "scopes": ["read", "write"]
    }
  },
  "source_info": {
    "base_url": "https://mytracker.com",
    "language": "en"
  }
}
```

### Browser Automation Extension

```json
{
  "manifest_version": 1,
  "id": "protectedsite",
  "name": "Protected Site",
  "version": "1.0.0",
  "description": "Site with Cloudflare protection",
  "addon_type": "scraper",
  "technology": "rhai",
  "entry_point": {
    "file": "plugin.rhai"
  },
  "capabilities": {
    "level": "browser_automation",
    "allowed_domains": [
      "protectedsite.com",
      "cdn.protectedsite.com"
    ],
    "requires_javascript": true,
    "cloudflare_protected": true
  },
  "features": {
    "search": true,
    "browse": true,
    "get_series": true,
    "get_chapters": true,
    "get_pages": true
  },
  "source_info": {
    "base_url": "https://protectedsite.com",
    "language": "en"
  }
}
```
