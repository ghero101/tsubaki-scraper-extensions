# Extension API Reference

This document describes all available APIs for Tsubaki extensions.

## Table of Contents

- [Required Functions](#required-functions)
- [HTTP API](#http-api)
- [HTML Parsing API](#html-parsing-api)
- [JSON API](#json-api)
- [Browser Automation API](#browser-automation-api)
- [Regex Utilities](#regex-utilities)
- [Data Types](#data-types)
- [Utility Functions](#utility-functions)

---

## Required Functions

### All Extensions

```rhai
/// Returns metadata about the extension
fn get_source_info() -> SourceInfo
```

### Scraper Extensions

```rhai
/// Search for series matching the query
fn search_series(query: String, page: Int, auth: AuthContext) -> SearchResult

/// Get detailed information about a series
fn get_series(id_or_url: String, auth: AuthContext) -> SeriesInfo

/// Get list of chapters for a series
fn get_chapters(series_id: String, auth: AuthContext) -> Vec<ChapterInfo>

/// Get page URLs/images for a chapter
fn get_chapter_pages(chapter_id: String, auth: AuthContext) -> Vec<PageInfo>
```

### Optional Functions

```rhai
/// Browse latest/popular without search query
fn get_latest_updates(page: Int, auth: AuthContext) -> SearchResult

/// Download a page (if default handler doesn't work)
fn download_page(page: PageInfo, auth: AuthContext) -> Bytes
```

---

## HTTP API

### http_get

Performs a GET request and returns the response body.

```rhai
let html = http_get("https://example.com/page");
```

### http_get_with_headers

Performs a GET request with custom headers using a **TLS-impersonating client**
(rquest with Chrome 131 fingerprint). This is the right choice for most
Cloudflare-protected sites — the TLS fingerprint matches a real browser, so
CF often lets the request through.

```rhai
let headers = #{
    "User-Agent": "Mozilla/5.0",
    "Referer": "https://example.com/",
    "Accept": "application/json"
};
let response = http_get_with_headers("https://api.example.com/data", headers);
```

**Gotcha**: this client returns an empty string when CF serves a 403. Always
check `response.len() > 500` before parsing.

### http_get_plain

Performs a GET request with custom headers using a **standard reqwest client**
— no TLS impersonation. Use this when impersonation backfires, which happens
on some Next.js sites that fingerprint the TLS handshake and refuse responses
that look "too perfect".

```rhai
let response = http_get_plain(url, get_headers());
```

Recommended pattern: try `http_get_with_headers` first, fall back to
`http_get_plain` if the response looks like a Next.js error page or a CF
challenge. See the scraper template for the full three-tier `fetch_html`.

### http_post / http_post_form

Performs a POST request. `http_post` sends a raw body; `http_post_form` sends
`application/x-www-form-urlencoded`.

```rhai
let body = `{"query": "search term"}`;
let response = http_post("https://api.example.com/search", body);

// WordPress Madara theme AJAX:
let ajax_body = `action=manga_get_chapters&manga=${post_id}`;
let html = http_post_form(`${BASE_URL}/wp-admin/admin-ajax.php`, ajax_body);
```

### flaresolverr_get / flaresolverr_is_available

Renders the page through FlareSolverr (a Chromium-based CF bypass service) and
returns the resulting HTML. Heavier than HTTP but resolves JS challenges that
neither impersonation nor browser_launch can.

```rhai
if flaresolverr_is_available() {
    try {
        let html = flaresolverr_get(url, 30000);  // 30 second timeout
        if html.len() > 500 { return html; }
    } catch {}
}
```

Use as the last tier in a fallback chain, not the first — it's the slowest
path and uses a shared resource.

### Residential proxy (`requires_proxy`)

Some sources **IP-ban datacenter / CGNAT / VPN egress** at the Cloudflare/edge
layer — the symptom is empty results or CF blocks *from the server*, even though
the site works fine from a home connection (e.g. **nhentai**, **kagane**). To
get past this, the server can route Cloudflare-bypass traffic through an
operator-configured upstream proxy (usually a **residential** one).

This is **opt-in per extension**. Set `requires_proxy: true` in your manifest's
`capabilities` (see [MANIFEST_SCHEMA.md](MANIFEST_SCHEMA.md)):

```json
"capabilities": {
  "level": "http_only",
  "cloudflare_protected": true,
  "requires_proxy": true
}
```

When set, the host injects the configured proxy into this extension's
`flaresolverr_get` / `flaresolverr_get_cookies` calls. **You don't write any
proxy code** — it's transparent. Just keep using `flaresolverr_get`. The
operator configures the actual proxy under **Server Settings → "FlareSolverr
Proxy"**; it may be an authenticated rotating residential proxy (the server
strips the credentials and passes them to FlareSolverr), an IP-authenticated
proxy (no creds), or an internal forwarder/VPN.

Notes for authors:
- **Only set it if you need it.** Routing through a proxy can *break* CF
  challenges for sources that work fine from the datacenter IP, and it uses the
  shared proxy's bandwidth.
- `http_get_with_headers` / `http_get_plain` (plain HTTP, no FlareSolverr) do
  **not** use the proxy — only the `flaresolverr_*` host functions do. If your
  source needs a clean IP, it must fetch via FlareSolverr.
- **Rotating vs sticky:** the FlareSolverr proxy may rotate IP per request,
  which is fine for single-request fetches (search/series/chapters). A
  **multi-step flow that depends on a consistent IP** (e.g. acquiring CF
  clearance cookies and then reusing them — cookies are IP-bound) needs a
  *sticky* IP; that's handled separately by the browser-extraction service
  below, not by `requires_proxy`.

### Browser-based DRM extraction (advanced)

A few sources (currently **kagane**) deliver pages only through a browser-side
DRM/EME challenge. Those extensions POST to the in-container extraction service
(`http://tsubaki-browser:3001/extract-pages`) which runs the whole flow in
headless Chrome. That service routes its FlareSolverr call **and** Chrome itself
through the `BROWSER_PROXY` env var set on the browser container (a **sticky**
residential proxy — the multi-step CF→integrity→license→pages flow needs one
consistent IP). Extension authors don't configure this; it's operator infra.
The downloaded image URLs are token-authed, so the actual page bytes download
fine over the server's normal connection — **only the extraction needs the
proxy.**

---

## HTML Parsing API

### html_parse

Parses an HTML string into a document object.

```rhai
let html = http_get("https://example.com");
let doc = html_parse(html);
```

### html_select

Selects elements matching a CSS selector.

```rhai
let doc = html_parse(html);

// Select all elements with class "manga-item"
let items = html_select(doc, ".manga-item");

// Select within an element
let title_el = html_select(items[0], ".title");

// Complex selectors
let links = html_select(doc, "div.content > a[href*='/manga/']");
```

### element_text

Gets the text content of an element.

```rhai
let title_el = html_select(doc, ".title")[0];
let title = element_text(title_el);  // "My Manga Title"
```

### element_attr

Gets an attribute value from an element.

```rhai
let link_el = html_select(doc, "a.manga-link")[0];
let href = element_attr(link_el, "href");      // "/manga/123"
let class = element_attr(link_el, "class");    // "manga-link"
let data = element_attr(link_el, "data-id");   // "123"
```

### element_html

Gets the inner HTML of an element.

```rhai
let container = html_select(doc, ".description")[0];
let inner_html = element_html(container);  // "<p>Description...</p>"
```

---

## JSON API

### json_parse

Parses a JSON string into a dynamic object.

```rhai
let response = http_get("https://api.example.com/manga/123");
let data = json_parse(response);

// Access object properties
let title = data["title"];
let chapters = data["chapters"];

// Access nested properties
let author_name = data["author"]["name"];

// Access array elements
let first_chapter = data["chapters"][0];

// Iterate arrays
for chapter in data["chapters"] {
    let num = chapter["number"];
}
```

### Handling null/undefined

```rhai
let value = data["optional_field"];

// Check if null/undefined
if value == () {
    value = "default";
}

// Or use conditional
let cover = if data["cover"] != () { data["cover"] } else { "" };
```

---

## Browser Automation API

These functions require `capability_level: "browser_automation"` in the manifest.

### browser_is_available

Checks if browser automation is available.

```rhai
if browser_is_available() {
    // Use browser
} else {
    // Fallback to HTTP
}
```

### browser_launch

Launches a new browser instance.

```rhai
let browser_id = browser_launch();
```

### browser_goto

Navigates to a URL.

```rhai
browser_goto(browser_id, "https://example.com");
```

### browser_wait_for_cloudflare

Waits for Cloudflare challenge to complete.

```rhai
// Wait up to 15 seconds for Cloudflare
browser_wait_for_cloudflare(browser_id, 15000);
```

### browser_wait_for_selector

Waits for an element to appear.

```rhai
// Wait up to 10 seconds for content to load
browser_wait_for_selector(browser_id, "#main-content", 10000);
```

### browser_get_html

Gets the current page HTML.

```rhai
let html = browser_get_html(browser_id);
```

### browser_close

Closes the browser instance.

```rhai
browser_close(browser_id);
```

### Complete Browser Example

Wrap every `browser_launch` in try/catch and clean up on failure. Without
this, a single browser bring-up failure (chromium OOM, container restart)
aborts the function before any fallback path can run.

```rhai
fn fetch_protected_page(url) {
    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 15000);
            browser_wait_for_selector(browser_id, ".manga-content", 10000);
            let html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            if html != () && html != "" && html.len() > 500 {
                return html;
            }
        } catch {
            // Make sure we close the browser even if it half-launched.
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    // Fall through to lighter tiers — see fetch_html in scraper-rhai template.
    http_get(url)
}
```

---

## Data Types

### SourceInfo

```rhai
#{
    id: "mysource",
    name: "My Source",
    base_url: "https://example.com",
    language: "en",
    supported_languages: ["en", "es"],
    requires_authentication: false,
    capability_level: "http_only"  // or "browser_automation"
}
```

### SearchResult

```rhai
#{
    series: [SeriesInfo, ...],
    has_more: true,  // Are there more pages?
    total: 100       // Optional: total result count
}
```

### SeriesInfo

```rhai
#{
    id: "manga-123",
    title: "My Manga",
    alternate_titles: ["Alt Title 1", "Alt Title 2"],
    description: "A description of the manga...",
    cover_url: "https://cdn.example.com/covers/123.jpg",
    url: "https://example.com/manga/123",
    authors: ["Author Name"],
    artists: ["Artist Name"],
    status: "ongoing",  // ongoing, completed, hiatus, cancelled
    genres: ["Action", "Adventure"],
    tags: ["Fantasy", "Magic"],
    year: 2020,
    content_rating: "safe",  // safe, suggestive, nsfw
    extra: #{}  // Additional metadata
}
```

### ChapterInfo

```rhai
#{
    id: "chapter-456",
    series_id: "manga-123",
    number: 1.0,  // Chapter number (supports decimals like 1.5)
    title: "Chapter Title",
    volume: 1,    // Optional
    language: "en",
    scanlator: "Scan Group",
    url: "https://example.com/manga/123/chapter/456",
    published_at: "2024-01-15T12:00:00Z",
    page_count: 20,
    extra: #{
        // Store source-specific data here
        token: "abc123"
    }
}
```

### PageInfo

```rhai
#{
    index: 0,  // Page number (0-indexed)
    url: "https://cdn.example.com/pages/123/1.jpg",
    headers: #{
        "Referer": "https://example.com/"
    },
    referer: "https://example.com/"  // Shorthand for Referer header
}
```

### AuthContext

Passed to functions when user has authentication configured.

```rhai
// auth may be () if not authenticated
fn search_series(query, page, auth) {
    let headers = #{};

    if auth != () {
        headers["Authorization"] = `Bearer ${auth.token}`;
        headers["Cookie"] = auth.cookies;
    }

    // ... use headers
}
```

---

## Regex Utilities

### regex_find

Returns the **full match** as a string, or `""` if there's no match.

```rhai
let m = regex_find("chapter-(\\d+)", url);
// url = "/series/foo/chapter-5/" → m = "chapter-5"  (NOT "5")
```

**Important footgun**: `regex_find` does **not** return the capture group.
It returns the entire match including the literal `chapter-` prefix. To pull
out just the digits, do a second `regex_find` pass on the first result:

```rhai
let full = regex_find("chapter-\\d+(\\.\\d+)?", url);
if full != "" {
    let digits = regex_find("\\d+(\\.\\d+)?", full);
    // digits = "5" ✓
}
```

Two real bugs in this codebase were caused by missing this distinction — see
the demonicscans and mangaowl `extract_chapter_number` fixes.

### regex_find_all

Returns an array of all matches (full match strings, same rule as above).

```rhai
let img_urls = regex_find_all("\"(https?://[^\"]+\\.(?:jpg|png|webp))\"", html);
for url_match in img_urls {
    // url_match is the full match including the quotes — strip them
    let clean = url_match.replace("\"", "");
    pages.push(clean);
}
```

### url_encode

Percent-encodes a string for use in a URL query parameter.

```rhai
let url = `${BASE_URL}/search?q=${url_encode(query)}&page=${page}`;
```

Always wrap user-supplied query strings — otherwise spaces, `&`, `#`, etc.
break the URL.

---

## Utility Functions

### String Operations

```rhai
// String interpolation
let url = `${BASE_URL}/manga/${id}`;

// Split string
let parts = url.split("/");

// Check contains
if url.contains("/manga/") {
    // ...
}

// Replace
let clean = text.replace("<br>", "\n");

// Trim whitespace
let trimmed = text.trim();

// Substring
let sub = text.sub_string(0, 100);

// Index of
let pos = text.index_of("chapter");
if pos != () {
    // Found at position `pos`
}

// To lowercase/uppercase
let lower = text.to_lower();
let upper = text.to_upper();
```

### Array Operations

```rhai
let arr = [];

// Push
arr.push(item);

// Length
let count = arr.len();

// Iterate
for item in arr {
    // ...
}

// Sort
arr.sort(|a, b| {
    if a.number > b.number { -1 }
    else if a.number < b.number { 1 }
    else { 0 }
});

// Filter (manual)
let filtered = [];
for item in arr {
    if item.status == "active" {
        filtered.push(item);
    }
}
```

### Type Conversion

```rhai
// Parse integer
let num = parse_int("123");  // 123

// Parse float
let dec = parse_float("1.5");  // 1.5

// To string
let str = `${number}`;
```
