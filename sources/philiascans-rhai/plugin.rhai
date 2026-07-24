// Philia Scans Scraper Add-on (Rhai)
// Custom Next.js / HeanCMS-style scraper for philiascans.org (Cloudflare protected)
//
// Philia Scans is a manga/manhua scanlation site built on a custom Next.js
// frontend (NOT WordPress Madara). The site is behind Cloudflare, so we use
// http_get_with_headers() with Chrome TLS impersonation and fall back to
// http_get_plain() / FlareSolverr if that fails.
//
// URL Patterns:
//   Browse:  /all-mangas (paginated: /all-mangas?page={n})
//   Series:  /series/{slug}
//   Chapter: /series/{slug}/chapter-{num}   <- canonical reader URL (serves page images)
//
// Chapter list (the part that broke): server-rendered as `div.chapter-row`
// containers with the number in `div.chapter-num` ("Ch.11"). The visible anchor
// points at an obfuscated `/read/{token}` URL that returns a JS shell with no
// images, so we ignore it and rebuild `/series/{slug}/chapter-{num}` instead.
// Page images are hosted on media.philiascans.org and embedded in the Next.js
// payload (no <img> tags), extracted by get_chapter_pages' regex fallback.
//
// Legacy Madara selectors (li.wp-manga-chapter, admin-ajax) are retained only as
// fallbacks in case the site ever migrates themes.
//
// Available Rhai APIs:
//   HTTP: http_get_with_headers(url, headers), http_get_plain(url, headers),
//         http_post_form(url, body)
//   HTML: html_parse(html), html_select(html, selector), element_text(el),
//         element_attr(el, attr)
//   Regex: regex_match(pattern, text), regex_find(pattern, text),
//          regex_find_all(pattern, text)
//   url_encode(text) -> string

const BASE_URL = "https://philiascans.org";

// ============================================================================
// Helper Functions
// ============================================================================

/// Get standard browser headers for requests
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Check if HTML looks like a Cloudflare challenge page
fn is_cloudflare_page(html) {
    if html.len() < 500 {
        return true;
    }
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

/// Fetch HTML with Cloudflare bypass:
/// 1. Try http_get_with_headers (rquest with Chrome131 TLS impersonation)
/// 2. Fall back to http_get_plain (standard reqwest, no impersonation)
fn fetch_html(url) {
    // Tier 1: rquest with Chrome TLS impersonation (best for Cloudflare)
    try {
        let html = http_get_with_headers(url, get_headers());
        if html.len() > 500 && !is_cloudflare_page(html) {
            return html;
        }
    } catch {
        // Fall through to next tier
    }

    // Tier 2: plain reqwest (no TLS impersonation)
    try {
        let html = http_get_plain(url, get_headers());
        if html.len() > 500 && !is_cloudflare_page(html) {
            return html;
        }
    } catch {
        // Fall through
    }

    // Tier 3: FlareSolverr if available
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 30000);
            if html.len() > 500 && !is_cloudflare_page(html) {
                return html;
            }
        } catch {
            // Fall through
        }
    }

    ""
}

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "philiascans",
        name: "Philia Scans",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only",
        nsfw: false,
        content_types: ["manga", "manhua"]
    }
}

/// Extract manga slug from a URL
/// URL patterns: /series/{slug}/, or full URL
fn extract_slug(url) {
    // Primary: /series/{slug}/
    if url.contains("/series/") {
        let parts = url.split("/series/");
        if parts.len() > 1 {
            let slug = parts[1].split("/")[0].split("?")[0];
            if slug != "" && slug != "?m_orderby" {
                return slug;
            }
        }
    }

    // Fallback: /manga/{slug}/ (in case any old URLs use this pattern)
    if url.contains("/manga/") {
        let parts = url.split("/manga/");
        if parts.len() > 1 {
            let slug = parts[1].split("/")[0].split("?")[0];
            if slug != "" && slug != "?m_orderby" {
                return slug;
            }
        }
    }

    // Last resort: get the meaningful path segment
    let parts = url.split("/");
    let last_non_empty = "";
    for part in parts {
        if part != "" && !part.contains("?") && !part.contains(".") && part != "http:" && part != "https:" && part != "philiascans.org" {
            last_non_empty = part;
        }
    }
    last_non_empty
}

/// Extract chapter number from URL or text
fn extract_chapter_number(text) {
    // Try "chapter-{number}" pattern in URL
    let text_lower = text.to_lower();

    if text_lower.contains("chapter-") {
        let parts = text_lower.split("chapter-");
        if parts.len() > 1 {
            let num_part = parts[parts.len() - 1];
            num_part = num_part.split("/")[0].split("?")[0].split("-")[0];
            let num = extract_number(num_part);
            if num != "" {
                return num;
            }
        }
    }

    // Try "Chapter {number}" pattern in text
    if text_lower.contains("chapter ") {
        let parts = text_lower.split("chapter ");
        if parts.len() > 1 {
            let after = parts[parts.len() - 1].trim();
            let num = extract_number(after);
            if num != "" {
                return num;
            }
        }
    }

    // Try "ch-{number}" pattern
    if text_lower.contains("ch-") {
        let parts = text_lower.split("ch-");
        if parts.len() > 1 {
            let num_part = parts[parts.len() - 1].split("/")[0].split("?")[0];
            let num = extract_number(num_part);
            if num != "" {
                return num;
            }
        }
    }

    // Fallback: find any number
    let num = extract_number(text);
    if num != "" {
        return num;
    }

    "0"
}

/// Extract a numeric value (including decimals) from the beginning of a string
fn extract_number(s) {
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

/// Make a URL absolute if it is relative
fn make_absolute_url(url) {
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

/// Get the best image URL from an img element, handling lazy loading
fn get_image_url(img) {
    // Madara theme uses multiple lazy-loading patterns
    // Priority: data-src > data-lazy-src > data-lazy > src
    let url = element_attr(img, "data-src");

    if url == () || url == "" || url.contains("blank.gif") || url.starts_with("data:") {
        url = element_attr(img, "data-lazy-src");
    }
    if url == () || url == "" || url.contains("blank.gif") || url.starts_with("data:") {
        url = element_attr(img, "data-lazy");
    }
    if url == () || url == "" || url.contains("blank.gif") || url.starts_with("data:") {
        url = element_attr(img, "src");
    }

    // Skip placeholder/invalid images
    if url != () && url != "" {
        if url.contains("blank.gif") || url.starts_with("data:") || url.contains("loading") {
            return ();
        }
    }

    url
}

/// Build an `alt`-text → cover-URL map from every <img> on the page.
///
/// Philia's cards nest the cover <img> behind an inline <svg> skeleton inside
/// the <a class="manga-card">. The HTML5 parser hoists that <img> out of the
/// anchor subtree, so a nested `html_select(link, "img")` finds nothing and the
/// cover comes back empty. Each cover img carries `alt="<series title>"`, so a
/// page-level lookup keyed by the resolved title recovers the cover regardless
/// of how the parser nested things.
fn build_cover_map(html) {
    let map = #{};
    let imgs = html_select(html, "img");
    for img in imgs {
        let alt = element_attr(img, "alt");
        if alt == () { continue; }
        let a = alt.trim();
        if a == "" || looks_like_rating(a) { continue; }
        let src = get_image_url(img);
        if src == () || src == "" {
            src = element_attr(img, "src");
        }
        if src != () && src != "" {
            map[a] = make_absolute_url(src);
        }
    }
    map
}

/// Check if a URL looks like a valid page image (not a logo, icon, etc.)
fn is_valid_page_image(url) {
    if url == () || url == "" {
        return false;
    }

    let url_lower = url.to_lower();

    // Skip non-page images
    if url_lower.contains("logo") { return false; }
    if url_lower.contains("icon") { return false; }
    if url_lower.contains("avatar") { return false; }
    if url_lower.contains("banner") { return false; }
    if url_lower.contains("advertisement") { return false; }
    if url_lower.contains("ads/") { return false; }
    if url_lower.contains("blank.gif") { return false; }
    if url_lower.contains("placeholder") { return false; }
    if url_lower.contains("loading") { return false; }
    if url_lower.contains("spinner") { return false; }
    if url_lower.contains("gravatar") { return false; }
    if url_lower.contains("emoji") { return false; }
    if url_lower.starts_with("data:") { return false; }

    // Must look like an image or be from content path
    if url_lower.contains(".jpg") || url_lower.contains(".jpeg") ||
       url_lower.contains(".png") || url_lower.contains(".webp") ||
       url_lower.contains(".gif") || url_lower.contains("wp-content/uploads") {
        return true;
    }

    // CDN or image hosting patterns
    if url_lower.contains("cdn") || url_lower.contains("img") ||
       url_lower.contains("image") || url_lower.contains("chapter") {
        return true;
    }

    false
}

/// Strip HTML tags from text
fn strip_html(text) {
    if text == () || text == "" {
        return "";
    }
    // Remove HTML tags using simple regex
    let cleaned = text;
    // Remove <br> tags and replace with newlines
    cleaned = cleaned.replace("<br>", "\n");
    cleaned = cleaned.replace("<br/>", "\n");
    cleaned = cleaned.replace("<br />", "\n");
    // Remove all other HTML tags via regex
    let result = regex_find_all("<[^>]+>", cleaned);
    for tag in result {
        cleaned = cleaned.replace(tag, "");
    }
    // Clean up whitespace
    cleaned = cleaned.trim();
    cleaned
}

/// Guard against accepting a rating ("9.7", "10", "4.5") as a title.
fn looks_like_rating(s) {
    if s == () || s == "" {
        return false;
    }
    let t = s.trim();
    if t == "" {
        return false;
    }
    if regex_match("^[0-9]+(\\.[0-9]+)?$", t) {
        return true;
    }
    false
}

/// Clean a title that was scraped from raw concatenated link text.
///
/// On the Philia card the <a> wraps a status badge + rating + the real title,
/// so element_text(link) returns e.g. "Ongoing 9.7 The Great Hero". This strips
/// leading numeric/rating tokens and known status words until the real title is
/// reached. Returns "" if nothing usable remains.
fn clean_card_title(raw) {
    if raw == () || raw == "" {
        return "";
    }
    let words = raw.trim().split(" ");
    let kept = [];
    let started = false;
    for w in words {
        let tok = w.trim();
        if tok == "" {
            continue;
        }
        if !started {
            // Drop leading metadata noise: pure numbers/ratings and status words.
            if looks_like_rating(tok) {
                continue;
            }
            let lower = tok.to_lower();
            if lower == "ongoing" || lower == "completed" || lower == "hiatus"
                || lower == "cancelled" || lower == "canceled" || lower == "dropped" {
                continue;
            }
            started = true;
        }
        kept.push(tok);
    }
    if kept.len() == 0 {
        return "";
    }
    kept.reduce(|a, b| a + " " + b)
}

/// Resolve a series title from a card: prefer the cover img `alt`, then the
/// link `title` attribute, then a heading element, then cleaned raw link text.
/// Numeric/rating-only candidates are always rejected.
fn resolve_card_title(item, link) {
    // 1. Cover img alt text.
    let imgs = html_select(item, "img");
    if imgs.len() > 0 {
        let alt = element_attr(imgs[0], "alt");
        if alt != () {
            let a = alt.trim();
            if a != "" && !looks_like_rating(a) {
                return a;
            }
        }
    }

    // 2. Link `title` attribute.
    let link_title = element_attr(link, "title");
    if link_title != () {
        let lt = link_title.trim();
        if lt != "" && !looks_like_rating(lt) {
            return lt;
        }
    }

    // 3. A specific heading element inside the card.
    let heading_els = html_select(item, "h3, h4, .post-title, .tt, .series-title");
    if heading_els.len() > 0 {
        let h = element_text(heading_els[0]).trim();
        if h != "" && !looks_like_rating(h) {
            return h;
        }
    }

    // 4. Cleaned raw link text (strips leading status/rating tokens).
    let cleaned = clean_card_title(element_text(link).trim());
    if cleaned != "" && !looks_like_rating(cleaned) {
        return cleaned;
    }

    ""
}

// ============================================================================
// Required Interface Functions
// ============================================================================

/// Search for series matching a query
fn search_series(query, page, auth) {
    let encoded_query = url_encode(query);
    // Philia Scans is Next.js, NOT WordPress: the old /?s=QUERY&post_type=wp-manga
    // URL doesn't exist and always returned empty. Search is server-rendered on
    // the /all-mangas route via the ?s= param (confirmed: ?s=solo returns only the
    // matching series), so we fetch that and reuse the same anchor-based parsing as
    // browse() — the .search-result-card / Madara card selectors never matched here.
    let url = `${BASE_URL}/all-mangas?s=${encoded_query}`;
    if page > 1 {
        url = `${BASE_URL}/all-mangas?s=${encoded_query}&paged=${page}`;
    }

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false, total: () };
    }

    let series = [];
    let seen = #{};

    // The all-mangas listing renders each result as an <a href="/series/{slug}">
    // wrapping a status badge, rating, cover <img> and the title (no card divs).
    let cover_map = build_cover_map(html);
    let all_links = html_select(html, "a[href*='/series/']");

    for link in all_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }
        if !href.contains("/series/") {
            continue;
        }

        let slug = extract_slug(href);
        if slug == "" || slug == "?m_orderby" {
            continue;
        }

        // Skip duplicates
        if seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        // Title — the <a> wraps a status badge + rating + the real title, so prefer
        // img alt / link title / heading; the card container here IS the link.
        let title = resolve_card_title(link, link);
        if title == "" || title.len() < 3 {
            continue;
        }
        let title_lower = title.to_lower();
        if title_lower.starts_with("ch.") || title_lower.starts_with("chapter") {
            continue;
        }

        // Cover: prefer the page-level alt→src map (robust to the parser hoisting
        // the <img> out of the anchor). Fall back to the nested selector cascade.
        let cover_url = ();
        if cover_map.contains(title) {
            cover_url = cover_map[title];
        }
        if cover_url == () || cover_url == "" {
            let imgs = html_select(link, "img[data-src]");
            if imgs.len() == 0 {
                imgs = html_select(link, ".tab-thumb img, .item-thumb img, img.img-responsive");
            }
            if imgs.len() == 0 {
                imgs = html_select(link, "img");
            }
            if imgs.len() > 0 {
                cover_url = get_image_url(imgs[0]);
                if cover_url == () || cover_url == "" {
                    cover_url = element_attr(imgs[0], "src");
                }
            }
            cover_url = make_absolute_url(cover_url);
        }

        series.push(#{
            id: slug,
            title: title,
            url: make_absolute_url(href),
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

    // The search view is a single server-rendered page; no reliable "next" marker.
    #{ series: series, has_more: false, total: () }
}

/// Browse manga by category/order
fn browse(page, category, auth) {
    if category == "latest" || category == "new" || category == () || category == "" {
        return get_latest_updates(page, auth);
    }

    // Philia Scans uses /all-mangas/ with ?paged= pagination (WordPress block template)
    let url = `${BASE_URL}/all-mangas/`;
    if page > 1 {
        url = `${BASE_URL}/all-mangas/?paged=${page}`;
    }

    let html = fetch_html(url);

    // Fallback: try /series/ listing
    if html == "" {
        url = `${BASE_URL}/series/`;
        if page > 1 {
            url = `${BASE_URL}/series/?paged=${page}`;
        }
        html = fetch_html(url);
    }

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let seen = #{};

    // PhiliaScans uses WordPress block template - manga entries are simple <a> tags
    // linking to /series/{slug}/ with images and text inside. No .page-item-detail divs.
    // Strategy: find all anchor tags with /series/ in href
    let cover_map = build_cover_map(html);
    let all_links = html_select(html, "a[href*='/series/']");

    for link in all_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Only process links to series pages (not chapter links)
        if !href.contains("/series/") {
            continue;
        }

        let slug = extract_slug(href);
        if slug == "" || slug == "?m_orderby" {
            continue;
        }

        // Skip duplicates
        if seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        // Get title — the <a> wraps a status badge + rating + the real title,
        // so raw element_text(link) yields "Ongoing 9.7 Title". Prefer img alt /
        // link title / heading, then cleaned raw text (drops leading metadata).
        // The card container here IS the link, so pass it as both args.
        let title = resolve_card_title(link, link);
        if title == "" {
            continue;
        }

        // Skip very short titles that are likely chapter numbers
        if title.len() < 3 {
            continue;
        }
        // Skip "Chapter" or "Ch." links (these are chapter links, not series)
        let title_lower = title.to_lower();
        if title_lower.starts_with("ch.") || title_lower.starts_with("chapter") {
            continue;
        }

        // Cover: prefer the page-level alt→src map (robust to the parser hoisting
        // the <img> out of the anchor). Fall back to the nested selector cascade.
        let cover_url = ();
        if cover_map.contains(title) {
            cover_url = cover_map[title];
        }
        if cover_url == () || cover_url == "" {
            let imgs = html_select(link, "img[data-src]");
            if imgs.len() == 0 {
                imgs = html_select(link, ".tab-thumb img, .item-thumb img, img.img-responsive");
            }
            if imgs.len() == 0 {
                imgs = html_select(link, "img");
            }
            if imgs.len() > 0 {
                cover_url = get_image_url(imgs[0]);
                if cover_url == () || cover_url == "" {
                    cover_url = element_attr(imgs[0], "src");
                }
            }
            cover_url = make_absolute_url(cover_url);
        }

        series.push(#{
            id: slug,
            title: title,
            url: make_absolute_url(href),
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

    // Check for more pages using ?paged= pagination links
    let has_more = false;
    let next_page = page + 1;
    let page_links = html_select(html, "a[href*='paged=']");
    for pl in page_links {
        let pl_href = element_attr(pl, "href");
        if pl_href != () && pl_href.contains(`paged=${next_page}`) {
            has_more = true;
            break;
        }
    }
    // Also check for standard next link selectors
    if !has_more {
        let next_links = html_select(html, "a.next, a.nextpostslink, .nav-next a");
        if next_links.len() > 0 {
            has_more = true;
        }
    }
    // Fallback: if we got a full page of results, assume more
    if !has_more && series.len() >= 12 {
        has_more = true;
    }
    if page >= 50 {
        has_more = false;
    }

    #{ series: series, has_more: has_more }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let url = id_or_url;
    let slug = id_or_url;

    if !id_or_url.starts_with("http") {
        url = `${BASE_URL}/series/${id_or_url}/`;
    } else {
        slug = extract_slug(id_or_url);
    }

    let html = fetch_html(url);

    if html == "" {
        throw `Failed to fetch series: ${id_or_url}`;
    }

    // Extract title - try h1 directly first, then Madara's .post-title h1
    let title = "";
    let title_els = html_select(html, "h1");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }
    if title == "" {
        let title_els2 = html_select(html, ".post-title h1");
        if title_els2.len() > 0 {
            title = element_text(title_els2[0]).trim();
        }
    }
    // Regex fallback from <title> tag
    if title == "" {
        let title_match = regex_find("<title>([^<]+)</title>", html);
        if title_match != "" {
            title = title_match.replace("<title>", "").replace("</title>", "").trim();
            // Remove site name suffix
            if title.contains(" - Philia Scans") {
                title = title.split(" - Philia Scans")[0].trim();
            }
            if title.contains(" | Philia Scans") {
                title = title.split(" | Philia Scans")[0].trim();
            }
        }
    }

    // Cover: the current Next.js site exposes it via og:image
    // (/api/media/covers/...); fall back to legacy Madara selectors.
    let cover_url = ();
    let ogimg = html_select(html, "meta[property=\"og:image\"]");
    if ogimg.len() > 0 {
        let c = element_attr(ogimg[0], "content");
        if c != () && c != "" { cover_url = c.trim(); }
    }
    if cover_url == () {
        let cover_els = html_select(html, ".detail-cover img, .series-cover img, .summary_image img, .tab-summary img, .manga-page img");
        if cover_els.len() > 0 {
            cover_url = get_image_url(cover_els[0]);
        }
    }
    cover_url = make_absolute_url(cover_url);

    // Description - current site uses .synopsis-text; legacy Madara fallbacks.
    let description = ();
    let synth = html_select(html, ".synopsis-text");
    if synth.len() > 0 {
        let raw = element_text(synth[0]).trim();
        if raw != "" && raw.len() > 10 { description = raw; }
    }
    let desc_els = [];
    if description == () {
        desc_els = html_select(html, "#synopsis ~ p, #synopsis ~ div p");
        if desc_els.len() == 0 {
            desc_els = html_select(html, ".summary__content p, .description-summary p, .manga-excerpt p");
        }
    }
    if desc_els.len() > 0 {
        let desc_parts = [];
        for p in desc_els {
            let text = element_text(p).trim();
            if text != "" && text.len() > 5 {
                // Skip "Show more" or navigation text
                if !text.to_lower().starts_with("show more") && !text.to_lower().starts_with("show less") {
                    desc_parts.push(text);
                }
            }
        }
        if desc_parts.len() > 0 {
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
    // Fallback: try the container directly
    if description == () || description == "" {
        let desc_container = html_select(html, ".summary__content, .description-summary");
        if desc_container.len() > 0 {
            let raw = element_text(desc_container[0]).trim();
            if raw != "" && raw.len() > 10 {
                description = raw;
            }
        }
    }

    // Extract authors - Madara uses .author-content a
    let authors = [];
    let author_els = html_select(html, ".author-content a");
    for el in author_els {
        let author = element_text(el).trim();
        if author != "" && author != "Updating" && author != "-" && !authors.contains(author) {
            authors.push(author);
        }
    }

    // Extract artists - Madara uses .artist-content a
    let artists = [];
    let artist_els = html_select(html, ".artist-content a");
    for el in artist_els {
        let artist = element_text(el).trim();
        if artist != "" && artist != "Updating" && artist != "-" && !artists.contains(artist) {
            artists.push(artist);
        }
    }

    // Genres - current site uses .detail-genre-tag; legacy .genres-content a.
    let genres = [];
    let genre_els = html_select(html, ".detail-genre-tag, .detail-genres a, .genres-content a");
    for el in genre_els {
        let genre = element_text(el).trim().replace(",", "");
        if genre != "" && genre.len() < 50 && !genres.contains(genre) {
            genres.push(genre);
        }
    }

    // Status - current site: .stat-box-value--status / .detail-badge[badge-status-*]
    // ("On Going"); legacy Madara fallback below.
    let status = ();
    let new_status = html_select(html, ".stat-box-value--status, .detail-badge[class*=\"badge-status\"]");
    for el in new_status {
        let t = element_text(el).to_lower();
        if t.contains("ongoing") || t.contains("on going") || t.contains("releasing") || t.contains("publishing") { status = "Ongoing"; }
        else if t.contains("completed") || t.contains("finished") { status = "Completed"; }
        else if t.contains("hiatus") { status = "Hiatus"; }
        else if t.contains("cancelled") || t.contains("canceled") || t.contains("dropped") { status = "Cancelled"; }
        if status != () { break; }
    }
    let status_els = if status == () { html_select(html, ".post-status .post-content_item") } else { [] };
    for el in status_els {
        let text = element_text(el).to_lower();
        if text.contains("status") {
            if text.contains("ongoing") || text.contains("publishing") || text.contains("releasing") {
                status = "Ongoing";
            } else if text.contains("completed") || text.contains("finished") {
                status = "Completed";
            } else if text.contains("hiatus") {
                status = "Hiatus";
            } else if text.contains("cancelled") || text.contains("canceled") || text.contains("dropped") {
                status = "Cancelled";
            }
        }
    }
    // Fallback: check .summary-content divs
    if status == () {
        let summary_els = html_select(html, ".summary-content");
        for el in summary_els {
            let text = element_text(el).to_lower().trim();
            if text == "ongoing" || text == "publishing" || text == "releasing" {
                status = "Ongoing";
                break;
            } else if text == "completed" || text == "finished" {
                status = "Completed";
                break;
            } else if text == "hiatus" {
                status = "Hiatus";
                break;
            } else if text == "cancelled" || text == "canceled" || text == "dropped" {
                status = "Cancelled";
                break;
            }
        }
    }

    // Extract alternative titles
    let alternate_titles = [];
    // Madara theme: .post-content_item with "Alternative" heading
    let content_items = html_select(html, ".post-content_item");
    for item in content_items {
        let heading_els = html_select(item, ".summary-heading h5, .summary-heading h7, h5");
        let content_els = html_select(item, ".summary-content");
        if heading_els.len() > 0 && content_els.len() > 0 {
            let heading = element_text(heading_els[0]).to_lower().trim();
            if heading.contains("alternative") || heading.contains("alt name") || heading.contains("other name") {
                let alt_text = element_text(content_els[0]).trim();
                if alt_text != "" && alt_text != "-" && alt_text != "N/A" {
                    let parts = alt_text.split(",");
                    if parts.len() == 1 {
                        parts = alt_text.split(";");
                    }
                    for p in parts {
                        let cleaned = p.trim();
                        if cleaned != "" && cleaned != title && !alternate_titles.contains(cleaned) {
                            alternate_titles.push(cleaned);
                        }
                    }
                }
            }
        }
    }

    // Extract year/release date
    let year = ();
    for item in content_items {
        let heading_els2 = html_select(item, ".summary-heading h5, h5");
        let content_els2 = html_select(item, ".summary-content");
        if heading_els2.len() > 0 && content_els2.len() > 0 {
            let heading = element_text(heading_els2[0]).to_lower().trim();
            if heading.contains("release") || heading.contains("year") {
                let year_text = element_text(content_els2[0]).trim();
                let year_match = regex_find("(19|20)\\d{2}", year_text);
                if year_match != "" {
                    year = year_match;
                }
            }
        }
    }

    #{
        id: slug,
        title: title,
        alternate_titles: alternate_titles,
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
        extra: #{
            auto_match_metadata: true,
            source_name: "Philia Scans"
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let url = series_id;
    let slug = series_id;

    if !series_id.starts_with("http") {
        url = `${BASE_URL}/series/${series_id}/`;
    } else {
        slug = extract_slug(series_id);
    }

    let html = fetch_html(url);

    if html == "" {
        return [];
    }

    let chapters = [];
    let seen = #{};

    // Method 1: Try to get chapters via AJAX (Madara's manga_get_chapters action)
    // First, extract the post ID from the page for the AJAX call
    let post_id = "";
    // Madara embeds the manga ID in data-id attribute or in a hidden input
    let id_match = regex_find("data-id=\"(\\d+)\"", html);
    if id_match != "" {
        post_id = regex_find("\\d+", id_match);
    }
    if post_id == "" {
        // Try wp_manga_chapter_preload or similar
        let id_match2 = regex_find("manga_id\\s*[:=]\\s*[\"']?(\\d+)", html);
        if id_match2 != "" {
            post_id = regex_find("\\d+", id_match2);
        }
    }
    if post_id == "" {
        // Try class="wp-manga-action-button" data-post="12345"
        let id_match3 = regex_find("data-post=\"(\\d+)\"", html);
        if id_match3 != "" {
            post_id = regex_find("\\d+", id_match3);
        }
    }
    if post_id == "" {
        // Try input hidden with manga id
        let id_match4 = regex_find("id=\"manga-chapters-holder\"[^>]*data-id=\"(\\d+)\"", html);
        if id_match4 != "" {
            post_id = regex_find("\\d+", id_match4);
        }
    }

    // If we have a post ID, try AJAX endpoint for full chapter list
    if post_id != "" {
        try {
            let ajax_url = `${BASE_URL}/wp-admin/admin-ajax.php`;
            let ajax_body = `action=manga_get_chapters&manga=${post_id}`;
            let ajax_html = http_post_form(ajax_url, ajax_body);

            if ajax_html != () && ajax_html != "" && ajax_html.len() > 50 {
                // Parse AJAX response which returns chapter list HTML
                let ajax_chapters = parse_chapter_list(ajax_html, series_id, seen);
                if ajax_chapters.len() > 0 {
                    return ajax_chapters;
                }
            }
        } catch {
            // AJAX failed, fall through to HTML parsing
        }
    }

    // Method 2: Parse chapters directly from the series page HTML
    chapters = parse_chapter_list(html, series_id, seen);

    chapters
}

/// Parse chapter list from HTML (used for both AJAX response and direct page parsing)
///
/// Philia Scans is a custom Next.js/HeanCMS-style site (NOT Madara). The chapter
/// list is server-rendered as `div.chapter-row` containers, each holding an
/// `a.chapter-row-link` whose visible label lives in `div.chapter-num` (e.g.
/// "Ch.11"). The anchor href points at an obfuscated `/read/{token}` reader URL
/// that returns a JS shell with no images, so we do NOT use it. Instead we build
/// the canonical `/series/{slug}/chapter-{num}` URL, which serves the full reader
/// page (with media.philiascans.org page images) that get_chapter_pages consumes.
///
/// Madara selectors are kept as a fallback in case the site ever changes themes.
fn parse_chapter_list(html, series_id, seen) {
    let chapters = [];

    // Resolve the series slug so we can build canonical chapter URLs.
    let slug = series_id;
    if series_id.starts_with("http") {
        slug = extract_slug(series_id);
    }

    // ---- Primary: custom Philia Scans theme (div.chapter-row) ----
    let rows = html_select(html, "div.chapter-row");
    for row in rows {
        // Chapter number lives in div.chapter-num ("Ch.11", "Ch.10.5")
        let num_els = html_select(row, ".chapter-num");
        let chapter_num = "";
        if num_els.len() > 0 {
            let num_text = element_text(num_els[0]).trim();
            chapter_num = extract_number(num_text);
        }
        // Fallback: derive from the visible row text
        if chapter_num == "" {
            chapter_num = extract_chapter_number(element_text(row).trim());
        }
        if chapter_num == "" || chapter_num == "0" {
            continue;
        }

        // Dedup (rows are rendered twice for responsive layouts)
        if seen.contains(chapter_num) {
            continue;
        }
        seen[chapter_num] = true;

        // Canonical reader URL that serves real page images.
        let chapter_url = `${BASE_URL}/series/${slug}/chapter-${chapter_num}`;

        // Premium / paywalled?
        let row_class = element_attr(row, "class");
        let is_premium = false;
        if row_class != () && row_class.contains("premium") {
            is_premium = true;
        }

        // Release date from <time class="chapter-meta">
        let published_at = ();
        let date_els = html_select(row, "time.chapter-meta, time");
        if date_els.len() > 0 {
            let dt = element_attr(date_els[0], "datetime");
            if dt != () && dt != "" {
                published_at = dt;
            } else {
                let date_text = element_text(date_els[0]).trim();
                if date_text != "" {
                    published_at = date_text;
                }
            }
        }

        chapters.push(#{
            id: chapter_url,
            series_id: series_id,
            number: chapter_num,
            title: (),
            volume: (),
            language: "en",
            scanlator: "Philia Scans",
            url: chapter_url,
            published_at: published_at,
            page_count: (),
            extra: #{
                premium: is_premium
            }
        });
    }

    if chapters.len() > 0 {
        // Listed newest-first, so reverse to ascending order.
        chapters.reverse();
        return chapters;
    }

    // ---- Fallback: legacy Madara theme chapter list ----
    let chapter_items = html_select(html, "li.wp-manga-chapter");
    if chapter_items.len() == 0 {
        chapter_items = html_select(html, ".listing-chapters_wrap li");
    }
    if chapter_items.len() == 0 {
        chapter_items = html_select(html, "ul.main li");
    }
    if chapter_items.len() == 0 {
        chapter_items = html_select(html, ".version-chap li");
    }

    for item in chapter_items {
        // Find the chapter link
        let links = html_select(item, "a");
        if links.len() == 0 {
            continue;
        }

        let link = links[0];
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Extract chapter number from URL or text
        let chapter_text = element_text(link).trim();
        let chapter_num = extract_chapter_number(href);

        // If we couldn't get number from URL, try the text
        if chapter_num == "0" || chapter_num == "" {
            chapter_num = extract_chapter_number(chapter_text);
        }

        // Skip duplicates
        if seen.contains(chapter_num) {
            continue;
        }
        seen[chapter_num] = true;

        // Extract chapter title (text after the number, if any)
        let chapter_title = ();
        if chapter_text.contains("-") {
            let parts = chapter_text.split("-");
            if parts.len() > 1 {
                let title_part = "";
                for i in 1..parts.len() {
                    if title_part != "" { title_part += "-"; }
                    title_part += parts[i];
                }
                title_part = title_part.trim();
                if title_part != "" && title_part.len() > 1 {
                    chapter_title = title_part;
                }
            }
        }
        if chapter_title == () && chapter_text.contains(":") {
            let parts = chapter_text.split(":");
            if parts.len() > 1 {
                let title_part = "";
                for i in 1..parts.len() {
                    if title_part != "" { title_part += ":"; }
                    title_part += parts[i];
                }
                title_part = title_part.trim();
                if title_part != "" && title_part.len() > 1 {
                    chapter_title = title_part;
                }
            }
        }

        // Build full URL
        let chapter_url = href;
        if !href.starts_with("http") {
            chapter_url = make_absolute_url(href);
        }

        // Get release date if available
        let published_at = ();
        let date_els = html_select(item, ".chapter-release-date, .chapter-release-date i, span.chapter-time");
        if date_els.len() > 0 {
            let date_text = element_text(date_els[0]).trim();
            if date_text != "" {
                published_at = date_text;
            }
        }

        chapters.push(#{
            id: chapter_url,
            series_id: series_id,
            number: chapter_num,
            title: chapter_title,
            volume: (),
            language: "en",
            scanlator: "Philia Scans",
            url: chapter_url,
            published_at: published_at,
            page_count: (),
            extra: #{}
        });
    }

    // Madara lists chapters newest-first, so reverse to get ascending order
    chapters.reverse();

    chapters
}

/// Get page image URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;

    if !chapter_id.starts_with("http") {
        url = make_absolute_url(chapter_id);
    }

    let html = fetch_html(url);

    if html == "" {
        return [];
    }

    let pages = [];
    let idx = 0;
    let seen_urls = #{};

    // Madara theme reader: div.page-break img or div.reading-content img
    // These are the standard selectors in order of specificity
    let selectors = [
        "div.page-break img",
        ".reading-content .page-break img",
        ".reading-content img",
        ".read-container img",
        "#image-list img",
        "#readerarea img",
        ".entry-content img",
        ".text-left img"
    ];

    for selector in selectors {
        let page_imgs = html_select(html, selector);

        for img in page_imgs {
            let img_url = get_image_url(img);

            if img_url != () && img_url != "" && is_valid_page_image(img_url) {
                let full_url = make_absolute_url(img_url);

                // Trim whitespace from URLs (Madara sometimes has leading/trailing spaces)
                full_url = full_url.trim();

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

        // If we found pages with this selector, stop trying others
        if pages.len() > 0 {
            break;
        }
    }

    // Fallback: regex extraction for image URLs in case HTML parsing missed them
    if pages.len() == 0 {
        // Look for image URLs in the page source (common in Madara themes)
        let img_matches = regex_find_all("\"(https?://[^\"]+(?:\\.jpg|\\.jpeg|\\.png|\\.webp)[^\"]*)\"", html);
        for img_url in img_matches {
            // Clean up the match - remove surrounding quotes
            let clean_url = img_url.replace("\"", "").trim();

            if is_valid_page_image(clean_url) {
                if seen_urls.contains(clean_url) {
                    continue;
                }
                seen_urls[clean_url] = true;

                pages.push(#{
                    index: idx,
                    url: clean_url,
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

/// Get latest manga updates
fn get_latest_updates(page, auth) {
    // Philia Scans uses /all-mangas/ with ?paged= pagination (WordPress block template)
    let url = `${BASE_URL}/all-mangas/`;
    if page > 1 {
        url = `${BASE_URL}/all-mangas/?paged=${page}`;
    }

    let html = fetch_html(url);

    // Fallback: try /series/ listing
    if html == "" {
        url = `${BASE_URL}/series/`;
        if page > 1 {
            url = `${BASE_URL}/series/?paged=${page}`;
        }
        html = fetch_html(url);
    }

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let seen = #{};

    // PhiliaScans uses WordPress block template - manga entries are <a> tags
    // linking to /series/{slug}/ with images and text inside
    let cover_map = build_cover_map(html);
    let all_links = html_select(html, "a[href*='/series/']");

    for link in all_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        if !href.contains("/series/") {
            continue;
        }

        let slug = extract_slug(href);
        if slug == "" || slug == "?m_orderby" {
            continue;
        }

        if seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        // Prefer img alt / link title / heading over raw link text (which
        // concatenates status badge + rating before the real title).
        let title = resolve_card_title(link, link);
        if title == "" {
            continue;
        }

        // Skip chapter-like text
        let title_lower = title.to_lower();
        if title.len() < 3 || title_lower.starts_with("ch.") || title_lower.starts_with("chapter") {
            continue;
        }

        // Cover: prefer the page-level alt→src map (robust to the parser hoisting
        // the <img> out of the anchor). Fall back to the nested selector cascade.
        let cover_url = ();
        if cover_map.contains(title) {
            cover_url = cover_map[title];
        }
        if cover_url == () || cover_url == "" {
            let imgs = html_select(link, "img[data-src]");
            if imgs.len() == 0 {
                imgs = html_select(link, ".tab-thumb img, .item-thumb img, img.img-responsive");
            }
            if imgs.len() == 0 {
                imgs = html_select(link, "img");
            }
            if imgs.len() > 0 {
                cover_url = get_image_url(imgs[0]);
                if cover_url == () || cover_url == "" {
                    cover_url = element_attr(imgs[0], "src");
                }
            }
            cover_url = make_absolute_url(cover_url);
        }

        series.push(#{
            id: slug,
            title: title,
            url: make_absolute_url(href),
            cover_url: cover_url,
            updated_at: ()
        });
    }

    // Check for next page using ?paged= pagination
    let has_more = false;
    let next_page = page + 1;
    let page_links = html_select(html, "a[href*='paged=']");
    for pl in page_links {
        let pl_href = element_attr(pl, "href");
        if pl_href != () && pl_href.contains(`paged=${next_page}`) {
            has_more = true;
            break;
        }
    }
    if !has_more {
        let next_links = html_select(html, "a.next, a.nextpostslink, .nav-next a");
        if next_links.len() > 0 {
            has_more = true;
        }
    }
    if !has_more && series.len() >= 12 {
        has_more = true;
    }
    if page >= 50 {
        has_more = false;
    }

    #{ series: series, has_more: has_more }
}
