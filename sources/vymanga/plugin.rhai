// VyManga Scraper Add-on (Rhai)
// Browser-based scraper for vymanga.net (Cloudflare protected)
//
// VyManga is a manga aggregator site with extensive library of manga, manhwa, and manhua.
// It uses Cloudflare protection and requires browser automation for reliable access.
//
// URL Patterns:
//   Search: /search?q={query}&page={page}
//   Series: /manga/{slug}
//   Chapter: /manga/{series-slug}/{chapter-slug}
//   Genres: /genre/{genre-name}
//
// Available APIs:
//   HTTP (fallback): http_get(url), http_get_with_headers(url, headers)
//   Browser: browser_launch(), browser_goto(id, url), browser_wait_for_cloudflare(id, timeout)
//            browser_get_html(id), browser_close(id), browser_is_available()
//   HTML: html_parse(html), html_select(html, selector), element_text(el), element_attr(el, attr)
//   Regex: regex_match(pattern, text), regex_find(pattern, text), regex_find_all(pattern, text)
//   url_encode(text) -> string

const BASE_URL = "https://vymanga.net";

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if HTML is a CloudFlare challenge page (not real content).
/// Three challenge variants — earlier versions missed the third ("Attention
/// Required") one, so CF challenge bodies that used that template slipped
/// through as if they were real content and produced zero parsed results.
fn is_cloudflare_challenge(html) {
    if html.contains("Just a moment") && html.contains("_cf_chl_opt") {
        return true;
    }
    if html.contains("challenge-platform") && html.contains("Enable JavaScript") {
        return true;
    }
    if html.contains("Attention Required") && html.contains("Cloudflare") {
        return true;
    }
    false
}

/// Fetch HTML with multi-tier fallback:
/// 1. HTTP (fastest, works for non-CF pages like search)
/// 2. FlareSolverr (bypasses CloudFlare challenges)
/// 3. Browser automation (last resort)
fn fetch_html(url) {
    // Tier 1: Try HTTP first - fastest for non-CF pages
    try {
        let html = http_get_with_headers(url, get_headers());
        if html.len() > 1000 && !is_cloudflare_challenge(html) {
            return html;
        }
    } catch {
        // Fall through
    }

    // Tier 2: FlareSolverr - reliable CloudFlare bypass
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 30000);
            if html.len() > 1000 && !is_cloudflare_challenge(html) {
                return html;
            }
        } catch {
            // Fall through
        }
    }

    // Tier 3: Browser automation - last resort
    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 15000);
            browser_wait_for_selector(browser_id, "a[href*='/manga/'], .book-list, .comic-thumb, h1", 10000);
            let html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            return html;
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    ""
}

/// Fetch HTML for Cloudflare-protected detail pages (series + chapter list).
///
/// The series page at /manga/{slug} is behind a Cloudflare interstitial
/// ("Just a moment...") even though the /search listing is NOT. Plain HTTP
/// therefore always returns the challenge body for these pages, so we must go
/// straight to FlareSolverr. The CF JS challenge on vymanga.net regularly takes
/// 80-100s to solve, so the previous 30000ms budget timed out and the chapter
/// list came back empty (get_chapters -> 0). We give FlareSolverr a 110s budget
/// (the host's IMPERSONATE_CLIENT caps the call at 120s) and only fall back to
/// HTTP/browser if FlareSolverr is unavailable.
fn fetch_html_cf(url) {
    // Tier 1: try plain HTTP — cheap, and covers the case where CF is briefly
    // disengaged or clearance is cached. Reject challenge bodies.
    try {
        let html = http_get_with_headers(url, get_headers());
        if html.len() > 1000 && !is_cloudflare_challenge(html) {
            return html;
        }
    } catch {
        // Fall through
    }

    // Tier 2: FlareSolverr with a generous budget for the slow CF solve.
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 110000);
            if html.len() > 1000 && !is_cloudflare_challenge(html) {
                return html;
            }
        } catch {
            // Fall through
        }
    }

    // Tier 3: browser automation - last resort.
    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 30000);
            browser_wait_for_selector(browser_id, "a.list-chapter, a[id^='chapter-'], h1", 15000);
            let html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            return html;
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    ""
}

/// Fetch HTML for reader pages (need images to be loaded).
/// Uses FlareSolverr for CF bypass, browser for JS-rendered content.
fn fetch_html_browser(url) {
    // Tier 1: FlareSolverr - gets past CF, but images may be lazy-loaded
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 30000);
            if html.len() > 1000 && !is_cloudflare_challenge(html) {
                // Check if the page has actual image content
                if html.contains("cdnxyz") || html.contains("vycdn") || html.contains("data-src") || html.contains("blogspot.com/drive-storage") {
                    return html;
                }
            }
        } catch {
            // Fall through
        }
    }

    // Tier 2: Browser automation - can render JS and load lazy images
    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 15000);
            browser_wait_for_selector(browser_id, "img[src*='cdn'], img[data-src], .reading-content img", 10000);
            let html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            return html;
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    // Tier 3: HTTP fallback
    try {
        return http_get_with_headers(url, get_headers());
    } catch {
        return "";
    }
}

/// Get headers for requests (used for HTTP fallback)
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Extract manga slug from URL
fn extract_manga_slug(url) {
    // URL patterns:
    // /manga/solo-leveling-78ay
    // https://vymanga.net/manga/solo-leveling-78ay

    if url.contains("/manga/") {
        let parts = url.split("/manga/");
        if parts.len() > 1 {
            let slug = parts[1];
            // Remove trailing path segments and query params
            slug = slug.split("/")[0];
            slug = slug.split("?")[0];
            return slug;
        }
    }

    ""
}

/// Extract the numeric VyManga manga id from a string (cover URL, html, or a
/// composite series id of the form "slug|46730").
///
/// VyManga's chapter list is rendered server-side on the Cloudflare-protected
/// /manga/{slug} page (an ~70-90s FlareSolverr solve — far longer than the
/// 30s harness/Django step budget). The SAME chapter list is also available
/// from the lightweight, UN-protected endpoint /api/manga-detail/{numericId}
/// over plain HTTP (HTTP 200, no CF challenge, instant). That endpoint keys on
/// the NUMERIC manga id (not the slug), so we thread the numeric id through the
/// series id and recover it here.
///
/// The numeric id appears in several plain-HTTP-reachable places:
///   - cover URL:        https://cdnxyz.xyz/web/cover/46730/thumbnail.png
///   - composite id:     solo-leveling-78ay|46730
///   - search markup:    manga_id="46730", btn-bookmark-46730, previewManga(...,'46730')
fn extract_numeric_id(s) {
    if s == () || s == "" {
        return "";
    }

    // Composite id form: "slug|numericId"
    if s.contains("|") {
        let parts = s.split("|");
        let tail = parts[parts.len() - 1];
        if is_all_digits(tail) {
            return tail;
        }
    }

    // Whole string is already numeric.
    if is_all_digits(s) {
        return s;
    }

    // Cover URL form: /web/cover/{id}/
    if s.contains("/web/cover/") {
        let after = s.split("/web/cover/")[1];
        let num = after.split("/")[0];
        if is_all_digits(num) {
            return num;
        }
    }

    // manga_id="{id}" form (search markup).
    if s.contains("manga_id=\"") {
        let after = s.split("manga_id=\"")[1];
        let num = after.split("\"")[0];
        if is_all_digits(num) {
            return num;
        }
    }

    ""
}

/// True if `s` is non-empty and every character is a digit.
fn is_all_digits(s) {
    if s == () || s == "" {
        return false;
    }
    for c in s.chars() {
        if c < '0' || c > '9' {
            return false;
        }
    }
    true
}

/// Extract chapter slug from URL
fn extract_chapter_slug(url) {
    // URL pattern: /manga/series-slug/chapter-slug
    let parts = url.split("/manga/");
    if parts.len() > 1 {
        let path_parts = parts[1].split("/");
        if path_parts.len() > 1 {
            return path_parts[1].split("?")[0];
        }
    }
    url
}

/// Extract chapter number from text or URL
fn extract_chapter_number(url, text) {
    // Try URL patterns first
    // Pattern: chapter-123, ch-123, -chapter-123-
    let url_lower = url.to_lower();

    // Try chapter- pattern
    if url_lower.contains("chapter-") {
        let parts = url_lower.split("chapter-");
        if parts.len() > 1 {
            let num_part = parts[parts.len() - 1];
            num_part = num_part.split("-")[0];
            num_part = num_part.split("/")[0];
            num_part = num_part.split("?")[0];
            // Extract just numbers and dots
            let num = extract_number_from_string(num_part);
            if num != "" {
                return num;
            }
        }
    }

    // Try ch- pattern
    if url_lower.contains("-ch-") || url_lower.contains("/ch-") {
        let parts = url_lower.split("ch-");
        if parts.len() > 1 {
            let num_part = parts[parts.len() - 1];
            num_part = num_part.split("-")[0];
            num_part = num_part.split("/")[0];
            let num = extract_number_from_string(num_part);
            if num != "" {
                return num;
            }
        }
    }

    // Try text patterns
    let text_lower = text.to_lower();

    // Look for "chapter X" or "ch. X" or "ch X"
    for prefix in ["chapter ", "ch. ", "ch ", "chap "] {
        if text_lower.contains(prefix) {
            let parts = text_lower.split(prefix);
            if parts.len() > 1 {
                let after = parts[1].trim();
                let num = extract_number_from_string(after);
                if num != "" {
                    return num;
                }
            }
        }
    }

    // Fallback: find any number in the text
    let num = extract_number_from_string(text);
    if num != "" {
        return num;
    }

    "0"
}

/// Extract numeric value (including decimals) from start of string
fn extract_number_from_string(s) {
    let num = "";
    let found_digit = false;

    for c in s.chars() {
        if c >= '0' && c <= '9' {
            num += c;
            found_digit = true;
        } else if c == '.' && found_digit {
            num += c;
        } else if found_digit {
            break;
        }
    }

    num
}

/// Make URL absolute
fn make_full_url(url) {
    if url == () || url == "" {
        return ();
    }
    if url.starts_with("http") {
        return url;
    }
    if url.starts_with("//") {
        return `https:${url}`;
    }
    if url.starts_with("/") {
        return `${BASE_URL}${url}`;
    }
    `${BASE_URL}/${url}`
}

/// Check if URL is a valid page image (not icon, logo, etc.)
fn is_valid_page_url(url) {
    if url == () || url == "" {
        return false;
    }

    let url_lower = url.to_lower();

    // Skip non-page images
    if url_lower.contains("logo") { return false; }
    if url_lower.contains("icon") { return false; }
    if url_lower.contains("avatar") { return false; }
    if url_lower.contains("banner") { return false; }
    if url_lower.contains("blank.gif") { return false; }
    if url_lower.contains("placeholder") { return false; }
    if url_lower.contains("loading") { return false; }
    if url_lower.contains(".gif") && !url_lower.contains("page") { return false; }

    // Must look like an image or be from CDN
    if url_lower.contains(".jpg") || url_lower.contains(".jpeg") ||
       url_lower.contains(".png") || url_lower.contains(".webp") {
        return true;
    }

    // CDN URLs
    if url_lower.contains("cdnxyz") || url_lower.contains("vycdn") ||
       url_lower.contains("blogspot.com/drive-storage") || url_lower.contains("bp.blogspot.com") {
        return true;
    }

    // Dynamic image URLs
    if url_lower.contains("/chapter/") || url_lower.contains("/page/") ||
       url_lower.contains("/img/") || url_lower.contains("/image/") {
        return true;
    }

    false
}

// ============================================================================
// Required Interface Functions
// ============================================================================

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "vymanga-rhai",
        name: "VyManga",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "browser_automation"
    }
}

/// Search for series matching query
fn search_series(query, page, auth) {
    let encoded_query = url_encode(query);
    let url = `${BASE_URL}/search?q=${encoded_query}&page=${page}`;

    let html = fetch_html(url);

    let series = [];
    let seen = #{};

    // Select all manga links - VyManga uses links to /manga/ paths
    let manga_links = html_select(html, "a[href*='/manga/']");

    for link in manga_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Extract slug
        let slug = extract_manga_slug(href);
        if slug == "" {
            continue;
        }

        // Skip chapter links (they have additional path segments)
        let path_after_manga = "";
        if href.contains("/manga/") {
            let parts = href.split("/manga/");
            if parts.len() > 1 {
                path_after_manga = parts[1];
            }
        }
        if path_after_manga.contains("/") {
            // This is a chapter link, skip
            continue;
        }

        // Skip duplicates
        if seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        // Get title from link text or alt attribute
        let title = element_text(link).trim();

        // Try to get title from parent or sibling elements if empty
        if title == "" || title.len() < 2 {
            let title_attr = element_attr(link, "title");
            if title_attr != () && title_attr != "" {
                title = title_attr;
            }
        }

        // Skip if we still don't have a valid title
        if title == "" || title.len() < 2 {
            continue;
        }

        // Clean up title - remove chapter info
        if title.to_lower().contains("chapter") {
            let parts = title.split("Chapter");
            if parts.len() > 0 {
                title = parts[0].trim();
            }
        }

        // If title is empty after cleanup, derive from slug
        if title == "" || title.len() < 2 {
            title = slug.split("-");
            // Join by spaces and capitalize
            let rebuilt = "";
            for word in title {
                if rebuilt != "" { rebuilt += " "; }
                if word.len() > 0 {
                    // Remove trailing hash codes (4-char alphanumeric at end of slug)
                    rebuilt += word;
                }
            }
            title = rebuilt.trim();
            // Remove trailing short hash (e.g. "solo leveling 78ay" -> "solo leveling")
            if title.len() > 5 {
                let last_space = 0;
                for i in 0..title.len() {
                    if title[i] == ' ' { last_space = i; }
                }
                let last_word = title.sub_string(last_space + 1);
                // If last word is short and looks like a hash (alphanumeric mix), remove it
                if last_word.len() <= 4 && last_word.len() >= 2 {
                    let has_digit = false;
                    let has_alpha = false;
                    for c in last_word.chars() {
                        if c >= '0' && c <= '9' { has_digit = true; }
                        if c >= 'a' && c <= 'z' { has_alpha = true; }
                    }
                    if has_digit && has_alpha {
                        title = title.sub_string(0, last_space).trim();
                    }
                }
            }
        }

        // Final check
        if title == "" || title.len() < 2 {
            continue;
        }

        // Get cover image
        let cover_url = ();
        let imgs = html_select(link, "img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
            if cover_url == () || cover_url == "" || cover_url.contains("blank.gif") {
                cover_url = element_attr(imgs[0], "data-src");
            }
            if cover_url == () || cover_url == "" || cover_url.contains("blank.gif") {
                // Try data-lazy attribute
                cover_url = element_attr(imgs[0], "data-lazy");
            }
        }

        // Make cover URL absolute
        cover_url = make_full_url(cover_url);

        // Recover the numeric manga id (needed by get_chapters' fast path) from
        // the cover URL (/web/cover/{id}/...). Encode it into the series id as
        // "slug|numericId" so get_chapters can hit /api/manga-detail/{id}
        // directly over plain HTTP instead of doing a ~70s Cloudflare solve.
        let numeric_id = extract_numeric_id(cover_url);
        let series_id_out = slug;
        if numeric_id != "" {
            series_id_out = `${slug}|${numeric_id}`;
        }

        series.push(#{
            id: series_id_out,
            title: title,
            url: make_full_url(href),
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

    // Check for next page - VyManga uses standard pagination
    let has_more = false;
    let pagers = html_select(html, "nav a, .pagination a, a[href*='page=']");
    for pager in pagers {
        let pager_href = element_attr(pager, "href");
        if pager_href != () && pager_href.contains(`page=${page + 1}`) {
            has_more = true;
            break;
        }
        let text = element_text(pager).to_lower();
        if text.contains("next") || text == ">" || text == ">>" {
            has_more = true;
            break;
        }
    }

    #{ series: series, has_more: has_more, total: () }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    // The id may arrive as a bare slug, a composite "slug|numericId", or a full
    // URL. Recover the numeric id (if present) so we can re-emit it on the way
    // out, and strip the "|numericId" suffix before building the /manga/{slug}
    // URL (the site doesn't understand the suffix).
    let numeric_id = extract_numeric_id(id_or_url);

    let url = id_or_url;
    let slug = id_or_url;

    if !id_or_url.starts_with("http") {
        // Drop any "|numericId" suffix for the slug + URL.
        if slug.contains("|") {
            slug = slug.split("|")[0];
        }
        url = `${BASE_URL}/manga/${slug}`;
    } else {
        slug = extract_manga_slug(id_or_url);
    }

    // Prefer the lightweight, Cloudflare-FREE detail fragment at
    // /api/manga-detail/{numericId}. The /manga/{slug} page is CF-protected and
    // returns a 403 interstitial (empty content) — which is why every metadata
    // field came back blank. Fall back to the page only if we lack a numeric id.
    let html = "";
    if numeric_id != "" {
        try { html = http_get_with_headers(`${BASE_URL}/api/manga-detail/${numeric_id}`, get_headers()); } catch { html = ""; }
    }
    if html == "" {
        html = fetch_html(url);
        if numeric_id == "" { numeric_id = extract_numeric_id(html); }
    }

    // Extract title - the detail fragment uses .title.mr-auto; pages use h1.
    let title = "";
    let title_els = html_select(html, ".title.mr-auto, h1");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }

    // Extract alternate titles
    let alt_titles = [];
    let alt_els = html_select(html, ".alt-name, .alias, .other-names, .alternative");
    for el in alt_els {
        let alt_text = element_text(el).trim();
        if alt_text != "" && alt_text != title {
            // Split by comma or semicolon
            let parts = alt_text.split(",");
            for p in parts {
                let cleaned = p.trim();
                if cleaned != "" && cleaned != title && !alt_titles.contains(cleaned) {
                    alt_titles.push(cleaned);
                }
            }
        }
    }

    // Extract cover - look for main image
    let cover_url = ();
    let cover_els = html_select(html, "img.img-manga, .img-manga, .cover img, .thumb img, .manga-cover img, img.cover, img[alt*='cover'], .info img");
    if cover_els.len() > 0 {
        cover_url = element_attr(cover_els[0], "src");
        if cover_url == () || cover_url.contains("blank.gif") {
            cover_url = element_attr(cover_els[0], "data-src");
        }
    }
    // Try any img in main content area
    if cover_url == () || cover_url.contains("blank.gif") {
        let all_imgs = html_select(html, ".info img, .detail img, article img");
        for img in all_imgs {
            let src = element_attr(img, "src");
            if src != () && !src.contains("blank.gif") && !src.contains("avatar") {
                cover_url = src;
                break;
            }
        }
    }
    cover_url = make_full_url(cover_url);

    // Extract description
    let description = ();
    let desc_els = html_select(html, ".summary p, .description p, .synopsis, .manga-summary, .content p, .info p");
    if desc_els.len() > 0 {
        let desc_parts = [];
        for p in desc_els {
            let text = element_text(p).trim();
            if text != "" && text.len() > 20 {
                desc_parts.push(text);
            }
        }
        if desc_parts.len() > 0 {
            // Manual join since Rhai doesn't have built-in join
            description = "";
            let first = true;
            for part in desc_parts {
                if !first {
                    description += "\n\n";
                }
                description += part;
                first = false;
            }
        }
    }

    // Extract authors
    let authors = [];
    let author_els = html_select(html, "a[href*='/author/'], a[href*='/creator/'], .author a");
    for el in author_els {
        let author = element_text(el).trim();
        if author != "" && !authors.contains(author) {
            authors.push(author);
        }
    }

    // Extract artists
    let artists = [];
    let artist_els = html_select(html, "a[href*='/artist/'], .artist a");
    for el in artist_els {
        let artist = element_text(el).trim();
        if artist != "" && !artists.contains(artist) {
            artists.push(artist);
        }
    }

    // Extract genres
    let genres = [];
    let genre_els = html_select(html, "a[href*='/genre/'], a[href*='/tag/'], .genre a, .genres a");
    for el in genre_els {
        let genre = element_text(el).trim();
        if genre != "" && !genres.contains(genre) && genre.len() < 50 {
            genres.push(genre);
        }
    }

    // Extract status
    let status = ();
    let info_els = html_select(html, "span[class*='text-'], .info span, .info div, .status, .detail span");
    for el in info_els {
        let text = element_text(el).to_lower();
        if text.contains("ongoing") || text.contains("releasing") {
            status = "Ongoing";
            break;
        } else if text.contains("completed") || text.contains("complete") || text.contains("finished") {
            status = "Completed";
            break;
        } else if text.contains("hiatus") {
            status = "Hiatus";
            break;
        } else if text.contains("cancelled") || text.contains("canceled") {
            status = "Cancelled";
            break;
        }
    }

    // Extract year
    let year = ();
    let year_match = regex_find(`(19|20)\d{2}`, html);
    if year_match != () && year_match != "" {
        year = year_match;
    }

    // If the page didn't yield a numeric id but the cover URL did, use that.
    if numeric_id == "" {
        numeric_id = extract_numeric_id(cover_url);
    }

    // Emit "slug|numericId" when known so get_chapters can use the fast,
    // Cloudflare-free /api/manga-detail/{id} endpoint.
    let series_id_out = slug;
    if numeric_id != "" {
        series_id_out = `${slug}|${numeric_id}`;
    }

    #{
        id: series_id_out,
        title: title,
        alternate_titles: alt_titles,
        description: description,
        cover_url: cover_url,
        authors: authors,
        artists: artists,
        status: status,
        genres: genres,
        tags: [],
        year: year,
        content_rating: "suggestive",
        url: url,
        extra: #{ auto_match_metadata: true, source_name: "VyManga" }
    }
}

/// Get all chapters for a series.
///
/// Fast path (preferred): if we know the numeric manga id, fetch
/// /api/manga-detail/{numericId} over plain HTTP. That endpoint is NOT behind
/// Cloudflare and returns the full chapter list instantly — avoiding the
/// ~70-90s FlareSolverr solve of the protected /manga/{slug} page, which blows
/// past the 30s harness/Django step timeout (the real cause of the prior
/// "get_chapters -> 0" failures).
///
/// Slow path (fallback): if no numeric id is available, fetch the protected
/// series page via FlareSolverr (long budget) and parse the same list.
fn get_chapters(series_id, auth) {
    let numeric_id = extract_numeric_id(series_id);

    let html = "";

    // Fast path: lightweight, Cloudflare-free chapter-list fragment.
    if numeric_id != "" {
        let api_url = `${BASE_URL}/api/manga-detail/${numeric_id}?userid=`;
        try {
            let h = http_get_with_headers(api_url, get_headers());
            // The fragment carries dt-chapter-* anchors; reject CF challenge bodies.
            if h.len() > 500 && !is_cloudflare_challenge(h) && h.contains("dt-chapter-") {
                html = h;
            }
        } catch {
            // Fall through to slow path.
        }
    }

    // Slow path: Cloudflare-protected series page via FlareSolverr.
    if html == "" {
        let url = series_id;
        if series_id.starts_with("http") {
            url = series_id;
        } else {
            // Strip any "|numericId" suffix before building the /manga/{slug} URL.
            let slug = series_id;
            if slug.contains("|") {
                slug = slug.split("|")[0];
            }
            url = `${BASE_URL}/manga/${slug}`;
        }
        html = fetch_html_cf(url);
    }

    let chapters = [];
    let seen = #{};

    // Two markup variants share the same external aovheroes redirect href:
    //   /api/manga-detail/{id}  -> <a class="list-group-item list-group-item-action" id="dt-chapter-200" ...>
    //   /manga/{slug} (CF page) -> <a class="list-chapter ..." id="chapter-200" ...>
    // Prefer dt-chapter (fast path), then fall back to the series-page selectors.
    let chapter_links = html_select(html, "a[id^='dt-chapter-']");
    if chapter_links.len() == 0 {
        chapter_links = html_select(html, "a.list-chapter");
    }
    if chapter_links.len() == 0 {
        chapter_links = html_select(html, "a[id^='chapter-']");
    }

    for link in chapter_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Get chapter ID from the id attribute (e.g. "dt-chapter-200" / "chapter-200")
        let ch_id = element_attr(link, "id");
        if ch_id == () || ch_id == "" {
            continue;
        }

        // Skip duplicates (some chapters appear twice - in first/last buttons and in list)
        if seen.contains(ch_id) {
            continue;
        }
        seen[ch_id] = true;

        // Extract chapter number from id attribute. Handle both the "dt-chapter-"
        // (api-detail) and "chapter-" (series page) prefixes; "dt-chapter-"
        // contains "chapter-" so split on "chapter-" works for both.
        let ch_num = "0";
        if ch_id.contains("chapter-") {
            let parts = ch_id.split("chapter-");
            if parts.len() > 1 {
                ch_num = parts[parts.len() - 1];
            }
        }

        // Get chapter text. The series page wraps it in <span>; the api-detail
        // fragment puts it as direct anchor text (followed by a <p> date), so
        // element_text(link) includes the date — strip the date paragraph.
        let chapter_text = "";
        let spans = html_select(link, "span");
        if spans.len() > 0 {
            chapter_text = element_text(spans[0]).trim();
        }
        if chapter_text == "" {
            chapter_text = element_text(link).trim();
            // Drop a trailing date paragraph if present (api-detail markup).
            let p_for_date = html_select(link, "p");
            if p_for_date.len() > 0 {
                let dtxt = element_text(p_for_date[0]).trim();
                if dtxt != "" && chapter_text.contains(dtxt) {
                    chapter_text = chapter_text.replace(dtxt, "").trim();
                }
            }
        }

        // Extract title from chapter text (e.g., "Chapter 200 : Side Story 21 - The End")
        let title = ();
        if chapter_text.contains(":") {
            let colon_parts = chapter_text.split(":");
            if colon_parts.len() > 1 {
                // Join everything after the first colon
                let title_text = "";
                for i in 1..colon_parts.len() {
                    if title_text != "" { title_text += ":"; }
                    title_text += colon_parts[i];
                }
                title_text = title_text.trim();
                if title_text != "" && title_text.len() > 1 {
                    title = title_text;
                }
            }
        }

        // Extract published date from <p> element
        let published_at = ();
        let date_els = html_select(link, "p");
        if date_els.len() > 0 {
            let date_text = element_text(date_els[0]).trim();
            if date_text != "" {
                published_at = date_text;
            }
        }

        chapters.push(#{
            id: href,
            series_id: series_id,
            number: ch_num,
            title: title,
            volume: (),
            language: "en",
            scanlator: (),
            url: href,
            published_at: published_at,
            page_count: (),
            extra: #{}
        });
    }

    chapters
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;

    if !chapter_id.starts_with("http") {
        url = `${BASE_URL}${chapter_id}`;
    }

    // Reader pages need browser for lazy-loaded images
    let html = fetch_html_browser(url);

    let pages = [];
    let idx = 0;
    let seen_urls = #{};

    // Try multiple selectors for page images
    // VyManga serves reading pages via redirect (aov-news.com) with entry-content container
    // and blogspot.com/drive-storage image URLs
    let selectors = [
        ".entry-content img",
        ".reading-content img",
        ".chapter-content img",
        ".reader-content img",
        ".chapter-images img",
        "#chapter-content img",
        ".container-chapter-reader img",
        "img.chapter-img",
        ".page-img img"
    ];

    for selector in selectors {
        let page_imgs = html_select(html, selector);

        for img in page_imgs {
            let img_url = element_attr(img, "src");

            // Try various data attributes for lazy loading
            // Also skip data: URIs (base64 placeholder images)
            // Skip placeholder images: blank.gif, data URIs, loading spinners
            if img_url == () || img_url == "" || img_url.contains("blank.gif") || img_url.starts_with("data:") || img_url.contains("loading") {
                img_url = element_attr(img, "data-src");
            }
            if img_url == () || img_url == "" || img_url.contains("blank.gif") || img_url.starts_with("data:") || img_url.contains("loading") {
                img_url = element_attr(img, "data-lazy");
            }
            if img_url == () || img_url == "" || img_url.contains("blank.gif") || img_url.starts_with("data:") || img_url.contains("loading") {
                img_url = element_attr(img, "data-original");
            }
            if img_url == () || img_url == "" || img_url.contains("blank.gif") || img_url.starts_with("data:") || img_url.contains("loading") {
                img_url = element_attr(img, "data-lazy-src");
            }

            // Validate and add
            if img_url != () && img_url != "" && is_valid_page_url(img_url) {
                let full_url = make_full_url(img_url);

                // Skip duplicates
                if seen_urls.contains(full_url) {
                    continue;
                }
                seen_urls[full_url] = true;

                pages.push(#{
                    index: idx,
                    url: full_url,
                    headers: #{
                        "Referer": url
                    },
                    referer: url
                });
                idx += 1;
            }
        }

        // If we found pages, stop looking
        if pages.len() > 0 {
            break;
        }
    }

    // Fallback: try to find any images in the main content area
    if pages.len() == 0 {
        let all_imgs = html_select(html, "article img, main img, .content img, #content img");

        for img in all_imgs {
            let img_url = element_attr(img, "src");
            if img_url == () || img_url == "" || img_url.contains("blank.gif") || img_url.starts_with("data:") || img_url.contains("loading") {
                img_url = element_attr(img, "data-src");
            }

            if img_url != () && img_url != "" && is_valid_page_url(img_url) {
                let full_url = make_full_url(img_url);

                if seen_urls.contains(full_url) {
                    continue;
                }
                seen_urls[full_url] = true;

                pages.push(#{
                    index: idx,
                    url: full_url,
                    headers: #{
                        "Referer": url
                    },
                    referer: url
                });
                idx += 1;
            }
        }
    }

    pages
}

// ============================================================================
// Optional Functions
// ============================================================================

/// Get latest updates
/// Uses search endpoint with empty query - this has proper pagination
/// Note: The homepage /?page=X doesn't respect pagination (returns same results)
fn get_latest_updates(page, auth) {
    // Use search endpoint with empty query - this has proper pagination
    let url = `${BASE_URL}/search?page=${page}`;

    let html = fetch_html(url);

    let series = [];
    let seen = #{};

    // Find update items - similar to search
    let manga_links = html_select(html, "a[href*='/manga/']");

    for link in manga_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        let slug = extract_manga_slug(href);
        if slug == "" {
            continue;
        }

        // Skip chapter links
        if href.contains("/manga/") {
            let parts = href.split("/manga/");
            if parts.len() > 1 && parts[1].contains("/") {
                continue;
            }
        }

        // Skip duplicates
        if seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        let title = element_text(link).trim();

        // Try title attribute or img alt
        if title == "" || title.len() < 2 {
            let title_attr = element_attr(link, "title");
            if title_attr != () && title_attr != "" {
                title = title_attr.trim();
            }
        }
        if title == "" || title.len() < 2 {
            let imgs_inner = html_select(link, "img");
            if imgs_inner.len() > 0 {
                let alt = element_attr(imgs_inner[0], "alt");
                if alt != () && alt != "" {
                    title = alt.trim();
                }
            }
        }

        // Clean title
        if title.to_lower().contains("chapter") {
            let parts = title.split("Chapter");
            if parts.len() > 0 {
                title = parts[0].trim();
            }
        }

        // Slug-based fallback
        if title == "" || title.len() < 2 {
            title = slug.replace("-", " ").trim();
        }

        if title == "" || title.len() < 2 {
            continue;
        }

        let cover_url = ();
        let imgs = html_select(link, "img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
            if cover_url == () || cover_url.contains("blank.gif") {
                cover_url = element_attr(imgs[0], "data-src");
            }
        }
        cover_url = make_full_url(cover_url);

        // Thread the numeric manga id through the series id (see search_series)
        // so get_chapters can use the fast /api/manga-detail/{id} path.
        let numeric_id = extract_numeric_id(cover_url);
        let series_id_out = slug;
        if numeric_id != "" {
            series_id_out = `${slug}|${numeric_id}`;
        }

        series.push(#{
            id: series_id_out,
            title: title,
            url: make_full_url(href),
            cover_url: cover_url,
            updated_at: ()
        });
    }

    // Check for next page
    let has_more = false;
    let pagers = html_select(html, "nav a, .pagination a, a[href*='page=']");
    for pager in pagers {
        let pager_href = element_attr(pager, "href");
        if pager_href != () && pager_href.contains(`page=${page + 1}`) {
            has_more = true;
            break;
        }
    }

    // Assume there's more if we got results
    if !has_more && series.len() > 0 {
        has_more = page < 100;
    }

    #{ series: series, has_more: has_more }
}

/// Get popular series
fn get_popular(page, auth) {
    // VyManga may have a popular/top page
    let url = `${BASE_URL}/search?sort=views&page=${page}`;

    let html = fetch_html(url);

    let series = [];
    let seen = #{};

    let manga_links = html_select(html, "a[href*='/manga/']");

    for link in manga_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        let slug = extract_manga_slug(href);
        if slug == "" {
            continue;
        }

        // Skip chapter links
        if href.contains("/manga/") {
            let parts = href.split("/manga/");
            if parts.len() > 1 && parts[1].contains("/") {
                continue;
            }
        }

        if seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        let title = element_text(link).trim();

        // Try title attribute or img alt
        if title == "" || title.len() < 2 {
            let title_attr = element_attr(link, "title");
            if title_attr != () && title_attr != "" {
                title = title_attr.trim();
            }
        }
        if title == "" || title.len() < 2 {
            let imgs_inner = html_select(link, "img");
            if imgs_inner.len() > 0 {
                let alt = element_attr(imgs_inner[0], "alt");
                if alt != () && alt != "" {
                    title = alt.trim();
                }
            }
        }

        // Clean title
        if title.to_lower().contains("chapter") {
            let parts = title.split("Chapter");
            if parts.len() > 0 {
                title = parts[0].trim();
            }
        }

        // Slug-based fallback
        if title == "" || title.len() < 2 {
            title = slug.replace("-", " ").trim();
        }

        if title == "" || title.len() < 2 {
            continue;
        }

        let cover_url = ();
        let imgs = html_select(link, "img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
            if cover_url == () || cover_url.contains("blank.gif") {
                cover_url = element_attr(imgs[0], "data-src");
            }
        }
        cover_url = make_full_url(cover_url);

        // Thread the numeric manga id through the series id (see search_series)
        // so get_chapters can use the fast /api/manga-detail/{id} path.
        let numeric_id = extract_numeric_id(cover_url);
        let series_id_out = slug;
        if numeric_id != "" {
            series_id_out = `${slug}|${numeric_id}`;
        }

        series.push(#{
            id: series_id_out,
            title: title,
            url: make_full_url(href),
            cover_url: cover_url
        });
    }

    // Check for next page
    let has_more = false;
    let pagers = html_select(html, "nav a, .pagination a, a[href*='page=']");
    for pager in pagers {
        let pager_href = element_attr(pager, "href");
        if pager_href != () && pager_href.contains(`page=${page + 1}`) {
            has_more = true;
            break;
        }
    }

    if !has_more && series.len() > 0 {
        has_more = page < 50;
    }

    #{ series: series, has_more: has_more }
}
