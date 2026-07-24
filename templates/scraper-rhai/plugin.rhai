// Tsubaki Scraper Add-on Template (Rhai)
//
// Implement each of the five required functions to scrape your target source.
// Most working plugins in this repo are good reference points — pick one with
// a similar CMS / theme to your site and copy its parsing strategy.
//
// AVAILABLE HOST FUNCTIONS
//
// HTTP (cheapest → heaviest):
//   http_get(url) -> string
//   http_get_with_headers(url, headers) -> string    (rquest Chrome131 TLS impersonation)
//   http_get_plain(url, headers) -> string           (standard reqwest, no impersonation)
//   http_post(url, body) -> string
//   http_post_form(url, body) -> string              (application/x-www-form-urlencoded)
//   flaresolverr_get(url, timeout_ms) -> string      (rendered HTML; only if FS available)
//   flaresolverr_is_available() -> bool
//
// Browser (only if manifest.capabilities.level = "browser_automation"):
//   browser_is_available() -> bool
//   browser_launch() / browser_launch_stealth() -> session_id
//   browser_goto(session_id, url)
//   browser_wait_for_cloudflare(session_id, timeout_ms)
//   browser_wait_for_selector(session_id, selector, timeout_ms)
//   browser_get_html(session_id) -> string
//   browser_close(session_id)
//
// HTML parsing (prefer html_select; doc.select is the older API):
//   html_select(html, selector) -> [Element]
//   html_select_first(html, selector) -> Element | ()
//   element_text(el) -> string
//   element_attr(el, attr_name) -> string | ()
//
// JSON / regex / utility:
//   json_parse(text) -> Dynamic
//   json_stringify(value) -> string
//   regex_find(pattern, text) -> string              (full match, NOT capture group!)
//   regex_find_all(pattern, text) -> [string]
//   url_encode(text) -> string
//   parse_int(str) -> int
//   parse_float(str) -> float
//
// IMPORTANT: regex_find returns the *full match*. To pull out a capture group,
// do a second regex_find pass on the first result. See `extract_chapter_number`
// below for the pattern.

// ============================================================================
// Configuration
// ============================================================================

const BASE_URL = "https://yoursource.com";
const SITE_NAME = "Your Source Name";

// ============================================================================
// Helpers
// ============================================================================

fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Recognise Cloudflare challenge HTML. Keep this even if your site isn't
/// CF-protected today — sites flip onto CF periodically and silent CF
/// challenge bodies parse as "no results" without it.
fn is_cloudflare_page(html) {
    if html == () || html == "" { return true; }
    if html.contains("Just a moment") && html.contains("_cf_chl_opt") { return true; }
    if html.contains("challenge-platform") && html.contains("Enable JavaScript") { return true; }
    if html.contains("Attention Required") && html.contains("Cloudflare") { return true; }
    false
}

/// Three-tier fetch: rquest impersonation → plain reqwest → FlareSolverr.
///
/// Every tier is wrapped so a network exception in one falls through to the
/// next. The FlareSolverr tier is the only "heavy" path and only fires if
/// the earlier tiers returned CF challenge HTML or threw.
///
/// If your site needs browser_automation (e.g. JS-rendered Next.js / Vue),
/// prepend a `browser_launch_stealth + browser_goto + browser_get_html`
/// tier wrapped in its own try/catch (see batcave-rhai or flamecomics-rhai).
fn fetch_html(url) {
    try {
        let html = http_get_with_headers(url, get_headers());
        if html.len() > 500 && !is_cloudflare_page(html) {
            return html;
        }
    } catch {}

    try {
        let html = http_get_plain(url, get_headers());
        if html.len() > 500 && !is_cloudflare_page(html) {
            return html;
        }
    } catch {}

    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 30000);
            if html.len() > 500 && !is_cloudflare_page(html) {
                return html;
            }
        } catch {}
    }

    ""
}

/// Make a relative URL absolute against BASE_URL.
fn make_absolute(url) {
    if url == () || url == "" { return (); }
    if url.starts_with("http") { return url; }
    if url.starts_with("//") { return `https:${url}`; }
    if url.starts_with("/") { return `${BASE_URL}${url}`; }
    `${BASE_URL}/${url}`
}

/// Pull the chapter number out of a URL or text. regex_find returns the full
/// match (e.g. "chapter-5"), not the capture group, so this does a second
/// regex_find pass for just the digits. Returning the unprocessed full match
/// would break numeric chapter ordering downstream.
fn extract_chapter_number(text) {
    if text == () || text == "" { return "0"; }
    let lower = text.to_lower();

    // Try "chapter-N" or "chapter N" with optional decimal
    let full = regex_find("chapter[\\s_-]*\\d+(\\.\\d+)?", lower);
    if full != "" {
        let digits = regex_find("\\d+(\\.\\d+)?", full);
        if digits != "" { return digits; }
    }

    // Try plain "ch-N" or "ch.N"
    let ch_full = regex_find("ch[\\s._-]*\\d+(\\.\\d+)?", lower);
    if ch_full != "" {
        let digits = regex_find("\\d+(\\.\\d+)?", ch_full);
        if digits != "" { return digits; }
    }

    // Last resort: any number in the text
    let any_digits = regex_find("\\d+(\\.\\d+)?", text);
    if any_digits != "" { return any_digits; }

    "0"
}

// ============================================================================
// Required interface
// ============================================================================

/// Returns metadata about this source. id MUST match manifest.id.
fn get_source_info() {
    #{
        id: "your-source-id",
        name: SITE_NAME,
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

/// Search for series matching query.
/// Returns: #{ series: [...], has_more: bool, total: int | () }
fn search_series(query, page, auth) {
    let url = `${BASE_URL}/search?q=${url_encode(query)}&page=${page}`;
    let html = fetch_html(url);
    if html == "" {
        return #{ series: [], has_more: false, total: () };
    }

    let series = [];
    let seen = #{};  // dedup by slug — most sites repeat featured entries
    for item in html_select(html, "div.series-item") {
        let links = html_select(item, "a.title");
        if links.len() == 0 { continue; }

        let link = links[0];
        let href = element_attr(link, "href");
        if href == () || href == "" { continue; }

        let slug = href;  // adjust if your URLs need slug extraction
        if seen.contains(slug) { continue; }
        seen[slug] = true;

        let title = element_text(link).trim();
        if title == "" { continue; }

        let cover_url = ();
        let imgs = html_select(item, "img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "data-src");
            if cover_url == () { cover_url = element_attr(imgs[0], "src"); }
        }
        cover_url = make_absolute(cover_url);

        series.push(#{
            id: slug,
            title: title,
            url: make_absolute(href),
            cover_url: cover_url,
            alternate_titles: [],
            authors: [],
            artists: [],
            status: (),
            genres: [],
            tags: [],
            description: ()
        });
    }

    let has_more = html_select(html, "a.next-page").len() > 0;
    #{ series: series, has_more: has_more, total: () }
}

/// Get detailed series information for one series.
/// Returns: SeriesInfo
fn get_series(id_or_url, auth) {
    let url = if id_or_url.starts_with("http") { id_or_url } else { `${BASE_URL}${id_or_url}` };
    let html = fetch_html(url);
    if html == "" {
        throw `Failed to fetch series: ${id_or_url}`;
    }

    let title = "";
    let title_els = html_select(html, "h1.title");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }

    let description = ();
    let desc_els = html_select(html, "div.description");
    if desc_els.len() > 0 {
        let raw = element_text(desc_els[0]).trim();
        if raw != "" { description = raw; }
    }

    let cover_url = ();
    let cover_els = html_select(html, "img.cover");
    if cover_els.len() > 0 {
        cover_url = element_attr(cover_els[0], "data-src");
        if cover_url == () { cover_url = element_attr(cover_els[0], "src"); }
    }
    cover_url = make_absolute(cover_url);

    let status = ();
    let status_els = html_select(html, "span.status");
    if status_els.len() > 0 {
        let s = element_text(status_els[0]).to_lower().trim();
        if s.contains("ongoing") { status = "Ongoing"; }
        else if s.contains("completed") { status = "Completed"; }
        else if s.contains("hiatus") { status = "Hiatus"; }
        else if s.contains("cancelled") || s.contains("canceled") { status = "Cancelled"; }
    }

    let authors = [];
    for el in html_select(html, "a.author") {
        let name = element_text(el).trim();
        if name != "" && name != "Updating" && !authors.contains(name) {
            authors.push(name);
        }
    }

    let genres = [];
    for el in html_select(html, "a.genre") {
        let name = element_text(el).trim();
        if name != "" && !genres.contains(name) { genres.push(name); }
    }

    #{
        id: url,
        title: title,
        alternate_titles: [],
        description: description,
        cover_url: cover_url,
        authors: authors,
        artists: [],
        status: status,
        genres: genres,
        tags: [],
        year: (),
        content_rating: (),
        url: url,
        extra: #{}
    }
}

/// Get all chapters for a series. Return them in *ascending* order
/// (oldest → newest). Most sites list newest-first, so call `.reverse()`
/// on your result before returning.
fn get_chapters(series_id, auth) {
    let url = if series_id.starts_with("http") { series_id } else { `${BASE_URL}${series_id}` };
    let html = fetch_html(url);
    if html == "" { return []; }

    let chapters = [];
    let seen = #{};
    for item in html_select(html, "li.chapter-item a") {
        let href = element_attr(item, "href");
        if href == () || href == "" { continue; }

        let chapter_text = element_text(item).trim();
        let number = extract_chapter_number(href);
        if number == "0" { number = extract_chapter_number(chapter_text); }

        if seen.contains(number) { continue; }
        seen[number] = true;

        chapters.push(#{
            id: make_absolute(href),
            series_id: series_id,
            number: number,
            title: (),
            volume: (),
            language: "en",
            scanlator: SITE_NAME,
            url: make_absolute(href),
            published_at: (),
            page_count: (),
            extra: #{}
        });
    }

    chapters.reverse();
    chapters
}

/// Get page URLs for a chapter. Set `referer` on each page — most CDNs
/// (Cloudflare, image hosts) reject hot-linked image requests without it.
fn get_chapter_pages(chapter_id, auth) {
    let url = if chapter_id.starts_with("http") { chapter_id } else { `${BASE_URL}${chapter_id}` };
    let html = fetch_html(url);
    if html == "" { return []; }

    let pages = [];
    let idx = 0;
    let seen_urls = #{};

    for img in html_select(html, "div.reader-content img") {
        let img_url = element_attr(img, "data-src");
        if img_url == () || img_url == "" { img_url = element_attr(img, "src"); }
        if img_url == () || img_url == "" { continue; }
        if img_url.starts_with("data:") { continue; }
        if img_url.contains("blank.gif") || img_url.contains("loading") { continue; }

        let full_url = make_absolute(img_url);
        if seen_urls.contains(full_url) { continue; }
        seen_urls[full_url] = true;

        pages.push(#{
            index: idx,
            url: full_url,
            headers: #{ "Referer": url },
            referer: url
        });
        idx += 1;
    }

    pages
}

// ============================================================================
// Optional interface (delete if unused)
// ============================================================================

// fn get_latest_updates(page, auth) {
//     let url = `${BASE_URL}/latest?page=${page}`;
//     let html = fetch_html(url);
//     // ... same parsing pattern as search_series
//     #{ series: [], has_more: false }
// }

// fn login(credentials) {
//     let username = credentials["username"];
//     let password = credentials["password"];
//     let response = http_post(`${BASE_URL}/login`, json_stringify(#{
//         username: username,
//         password: password
//     }));
//     #{
//         credentials: credentials,
//         cookies: [],
//         session_token: ()
//     }
// }
