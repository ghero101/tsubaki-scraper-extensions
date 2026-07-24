// Arena Scans Scraper Add-on (Rhai)
// Flavor/MangaStream WordPress theme scraper for arenascan.com (Cloudflare protected)
//
// Arena Scans uses the Flavor/Flavor-Starter WordPress theme (MangaStream clone),
// which has different CSS classes from the Madara theme.
//
// URL Patterns:
//   Search: /?s={query} (WordPress default search)
//   Browse: /manga/ with pagination via /manga/page/{page}/
//   Series: /manga/{slug}/
//   Chapter: /manga/{slug}/{chapter-slug}/ (e.g. /manga/some-title/chapter-10/)
//   Reader: chapter page with #readerarea img or ts_reader.run() JSON
//
// Flavor/MangaStream CSS patterns:
//   Series listing: .bsx containers with a[href] links
//   Cover images: .limit img (src attribute)
//   Title: .bigor .tt or .tt h1
//   Series detail: .infox container
//   Description: .desc or .entry-content
//   Genres: .seriestugenre a or .mgen a
//   Status/Author: .imptdt items
//   Chapter list: #chapterlist li or .eplister li
//   Chapter text: .chapternum inside a
//   Chapter date: .chapterdate
//   Reader images: #readerarea img (check data-src for lazy loading)
//
// Available Rhai APIs:
//   HTTP: http_get_with_headers(url, headers), http_get_plain(url, headers),
//         http_post_form(url, body)
//   HTML: html_parse(html), html_select(html, selector), element_text(el),
//         element_attr(el, attr)
//   Regex: regex_match(pattern, text), regex_find(pattern, text),
//          regex_find_all(pattern, text)
//   url_encode(text) -> string

const BASE_URL = "https://arenascan.com";

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
/// 3. Fall back to FlareSolverr if available
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
        id: "arenascans",
        name: "Arena Scans",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only",
        nsfw: false,
        content_types: ["manhwa", "manga"]
    }
}

/// Extract manga slug from a URL
/// URL patterns: /manga/{slug}/, or full URL
fn extract_slug(url) {
    if url.contains("/manga/") {
        let parts = url.split("/manga/");
        if parts.len() > 1 {
            let after = parts[1];
            // Split by / and get the first non-empty segment (the slug)
            let segments = after.split("/");
            for seg in segments {
                let s = seg.split("?")[0];
                if s != "" {
                    return s;
                }
            }
        }
    }

    // Last resort: get the last meaningful path segment
    let parts = url.split("/");
    let last_non_empty = "";
    for part in parts {
        if part != "" && !part.contains("?") && !part.contains(".") && part != "http:" && part != "https:" && part != "arenascan.com" && part != "manga" {
            last_non_empty = part;
        }
    }
    last_non_empty
}

/// Extract chapter number from URL or text
fn extract_chapter_number(text) {
    let text_lower = text.to_lower();

    // Try "chapter-{number}" pattern in URL
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
    // Flavor theme uses lazy loading with data-src, data-lazy-src, etc.
    // Priority: data-src > data-lazy-src > src
    let url = element_attr(img, "data-src");

    if url == () || url == "" || url.contains("blank.gif") || url.starts_with("data:") {
        url = element_attr(img, "data-lazy-src");
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
    let cleaned = text;
    cleaned = cleaned.replace("<br>", "\n");
    cleaned = cleaned.replace("<br/>", "\n");
    cleaned = cleaned.replace("<br />", "\n");
    let result = regex_find_all("<[^>]+>", cleaned);
    for tag in result {
        cleaned = cleaned.replace(tag, "");
    }
    cleaned = cleaned.trim();
    cleaned
}

// ============================================================================
// Required Interface Functions
// ============================================================================

/// Search for series matching a query
/// Flavor theme uses WordPress default search: /?s=QUERY
fn search_series(query, page, auth) {
    let encoded_query = url_encode(query);
    let url = `${BASE_URL}/?s=${encoded_query}`;
    if page > 1 {
        url = `${BASE_URL}/page/${page}/?s=${encoded_query}`;
    }

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false, total: () };
    }

    let series = [];
    let seen = #{};

    // Flavor/MangaStream search results: .bsx containers with manga links
    let items = html_select(html, ".bsx");

    // Fallback: try article containers or generic list items
    if items.len() == 0 {
        items = html_select(html, "article");
    }
    if items.len() == 0 {
        items = html_select(html, ".bs");
    }
    if items.len() == 0 {
        items = html_select(html, ".listupd .bs");
    }

    for item in items {
        // Get the main link
        let links = html_select(item, "a");
        if links.len() == 0 {
            continue;
        }

        let link = links[0];
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Only process manga links
        if !href.contains("/manga/") {
            continue;
        }
        // Skip chapter links
        if href.contains("chapter") {
            continue;
        }

        let slug = extract_slug(href);
        if slug == "" {
            continue;
        }

        // Skip duplicates
        if seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        // Get title from .tt (Flavor theme title class)
        let title = "";
        let tt_els = html_select(item, ".tt");
        if tt_els.len() > 0 {
            title = element_text(tt_els[0]).trim();
        }
        // Fallback: try h2, h3, h4
        if title == "" {
            let h_els = html_select(item, "h2");
            if h_els.len() > 0 {
                title = element_text(h_els[0]).trim();
            }
        }
        if title == "" {
            let h_els = html_select(item, "h3");
            if h_els.len() > 0 {
                title = element_text(h_els[0]).trim();
            }
        }
        if title == "" {
            let h_els = html_select(item, "h4");
            if h_els.len() > 0 {
                title = element_text(h_els[0]).trim();
            }
        }
        // Fallback: link title attribute
        if title == "" {
            let title_attr = element_attr(link, "title");
            if title_attr != () {
                title = title_attr.trim();
            }
        }
        if title == "" {
            continue;
        }

        // Get cover image from .limit img (Flavor pattern)
        let cover_url = ();
        let imgs = html_select(item, ".limit img");
        if imgs.len() == 0 {
            imgs = html_select(item, "img.ts-post-image");
        }
        if imgs.len() == 0 {
            imgs = html_select(item, "img");
        }
        if imgs.len() > 0 {
            cover_url = get_image_url(imgs[0]);
        }
        cover_url = make_absolute_url(cover_url);

        // Get genres if visible in search results
        let genres = [];
        let genre_els = html_select(item, ".mgen a, .seriestugenre a, .genre a");
        for el in genre_els {
            let genre = element_text(el).trim();
            if genre != "" && !genres.contains(genre) {
                genres.push(genre);
            }
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
            genres: genres,
            tags: [],
            description: (),
            extra: #{}
        });
    }

    // Check for next page - try multiple pagination selectors
    let has_more = false;
    let next_links = html_select(html, "a.next, a.nextpostslink, .nav-next a, .hpage a.r, .nextprev a, .pagination a.next");
    if next_links.len() > 0 {
        has_more = true;
    }
    // Also check page number links
    if !has_more {
        let next_page = page + 1;
        let page_links = html_select(html, ".pagination a, .hpage a, nav.navigation a, .nextprev a");
        for pl in page_links {
            let pl_href = element_attr(pl, "href");
            if pl_href != () && (pl_href.contains(`/page/${next_page}/`) || pl_href.contains(`paged=${next_page}`) || pl_href.contains(`?page=${next_page}`)) {
                has_more = true;
                break;
            }
        }
    }
    // Fallback: if we got a full page of results, assume there's more
    if !has_more && series.len() >= 18 {
        has_more = true;
    }

    #{ series: series, has_more: has_more, total: () }
}

/// Browse manga by category/order
fn browse(page, category, auth) {
    if category == "latest" || category == "new" || category == () || category == "" {
        return get_latest_updates(page, auth);
    }

    // Flavor theme browse: /manga/ with optional ordering
    let url = `${BASE_URL}/manga/`;
    if page > 1 {
        url = `${BASE_URL}/manga/page/${page}/`;
    }

    // Flavor theme may support ?order=popular, ?order=update, etc.
    if category == "popular" || category == "views" {
        url += "?order=popular";
    } else if category == "az" || category == "alphabetical" {
        url += "?order=title";
    } else if category == "rating" {
        url += "?order=rating";
    }

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let result = parse_series_listing(html);
    let series = result.series;

    // Check for more pages
    let has_more = false;
    let next_links = html_select(html, "a.next, a.nextpostslink, .hpage a.r, .nextprev a, .pagination a.next, .wp-pagenavi a.nextpostslink");
    if next_links.len() > 0 {
        has_more = true;
    }
    if !has_more && series.len() >= 15 {
        has_more = true;
    }
    if page >= 100 {
        has_more = false;
    }

    #{ series: series, has_more: has_more }
}

/// Parse a series listing page (used by both browse and latest updates)
/// Flavor theme uses .bsx containers in .listupd
fn parse_series_listing(html) {
    let series = [];
    let seen = #{};

    // Flavor/MangaStream: .bsx containers (each is a manga card)
    let items = html_select(html, ".bsx");
    if items.len() == 0 {
        items = html_select(html, ".bs");
    }
    if items.len() == 0 {
        items = html_select(html, ".listupd .bs");
    }

    for item in items {
        let links = html_select(item, "a");
        if links.len() == 0 {
            continue;
        }

        let link = links[0];
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        if !href.contains("/manga/") {
            continue;
        }
        if href.contains("chapter") {
            continue;
        }

        let slug = extract_slug(href);
        if slug == "" {
            continue;
        }

        if seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        // Title from .tt (Flavor) or heading tags
        let title = "";
        let tt_els = html_select(item, ".tt");
        if tt_els.len() > 0 {
            title = element_text(tt_els[0]).trim();
        }
        if title == "" {
            let h_els = html_select(item, "h2, h3, h4");
            if h_els.len() > 0 {
                title = element_text(h_els[0]).trim();
            }
        }
        if title == "" {
            let title_attr = element_attr(link, "title");
            if title_attr != () { title = title_attr.trim(); }
        }
        if title == "" {
            continue;
        }

        // Cover from .limit img (Flavor pattern)
        let cover_url = ();
        let imgs = html_select(item, ".limit img");
        if imgs.len() == 0 {
            imgs = html_select(item, "img.ts-post-image");
        }
        if imgs.len() == 0 {
            imgs = html_select(item, "img");
        }
        if imgs.len() > 0 {
            cover_url = get_image_url(imgs[0]);
        }
        cover_url = make_absolute_url(cover_url);

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

    #{ series: series }
}

/// Get detailed series information
/// Flavor theme uses .infox for info container, .seriestugenre for genres,
/// .imptdt for status/author/artist metadata items
fn get_series(id_or_url, auth) {
    let url = id_or_url;
    let slug = id_or_url;

    if !id_or_url.starts_with("http") {
        url = `${BASE_URL}/manga/${id_or_url}/`;
    } else {
        slug = extract_slug(id_or_url);
    }

    let html = fetch_html(url);

    if html == "" {
        throw `Failed to fetch series: ${id_or_url}`;
    }

    // Extract title - Flavor uses .tt h1 or h1.entry-title
    let title = "";
    let title_els = html_select(html, ".tt h1");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }
    if title == "" {
        let title_els2 = html_select(html, "h1.entry-title");
        if title_els2.len() > 0 {
            title = element_text(title_els2[0]).trim();
        }
    }
    if title == "" {
        let title_els3 = html_select(html, ".infox h1");
        if title_els3.len() > 0 {
            title = element_text(title_els3[0]).trim();
        }
    }
    if title == "" {
        let title_els4 = html_select(html, "h1");
        if title_els4.len() > 0 {
            title = element_text(title_els4[0]).trim();
        }
    }
    // Regex fallback from <title> tag
    if title == "" {
        let title_match = regex_find("<title>([^<]+)</title>", html);
        if title_match != "" {
            title = title_match.replace("<title>", "").replace("</title>", "").trim();
            if title.contains(" - Arena Scans") {
                title = title.split(" - Arena Scans")[0].trim();
            }
            if title.contains(" | Arena Scans") {
                title = title.split(" | Arena Scans")[0].trim();
            }
        }
    }

    // Extract cover image - Flavor uses .thumb img or .seriestucontent img
    let cover_url = ();
    let cover_els = html_select(html, ".thumb img");
    if cover_els.len() == 0 {
        cover_els = html_select(html, ".seriestucontent img");
    }
    if cover_els.len() == 0 {
        cover_els = html_select(html, ".limit img");
    }
    if cover_els.len() == 0 {
        cover_els = html_select(html, ".infoanime img");
    }
    if cover_els.len() > 0 {
        cover_url = get_image_url(cover_els[0]);
    }
    cover_url = make_absolute_url(cover_url);

    // Extract description - Flavor uses .desc or .entry-content in series detail
    let description = ();
    let desc_els = html_select(html, ".desc p, .entry-content-single p");
    if desc_els.len() > 0 {
        let desc_parts = [];
        for p in desc_els {
            let text = element_text(p).trim();
            if text != "" && text.len() > 5 {
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
    // Fallback: try .desc container directly
    if description == () || description == "" {
        let desc_container = html_select(html, ".desc, .entry-content");
        if desc_container.len() > 0 {
            let raw = element_text(desc_container[0]).trim();
            if raw != "" && raw.len() > 10 {
                description = raw;
            }
        }
    }
    // Fallback: .synp or .summary container
    if description == () || description == "" {
        let synp_els = html_select(html, ".synp .entry-content p, .summary p");
        if synp_els.len() > 0 {
            let desc_parts = [];
            for p in synp_els {
                let text = element_text(p).trim();
                if text != "" && text.len() > 5 {
                    desc_parts.push(text);
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
    }

    // Extract genres - Flavor uses .seriestugenre a or .mgen a
    let genres = [];
    let genre_els = html_select(html, ".seriestugenre a");
    if genre_els.len() == 0 {
        genre_els = html_select(html, ".mgen a");
    }
    if genre_els.len() == 0 {
        genre_els = html_select(html, ".genre-info a");
    }
    for el in genre_els {
        let genre = element_text(el).trim().replace(",", "");
        if genre != "" && genre.len() < 50 && !genres.contains(genre) {
            genres.push(genre);
        }
    }

    // Extract status, author, artist from .imptdt items
    // Flavor theme: .imptdt contains label + value pairs
    let status = ();
    let authors = [];
    let artists = [];
    let alternate_titles = [];
    let year = ();

    let imptdt_els = html_select(html, ".imptdt");
    for item in imptdt_els {
        let text = element_text(item).to_lower().trim();

        // Status
        if text.contains("status") {
            // Get the value (usually in an <i> tag or after the label)
            let value_els = html_select(item, "i");
            let value = "";
            if value_els.len() > 0 {
                value = element_text(value_els[0]).to_lower().trim();
            } else {
                // Try to extract value after "Status" text
                value = text;
            }
            if value.contains("ongoing") || value.contains("publishing") {
                status = "Ongoing";
            } else if value.contains("completed") || value.contains("finished") {
                status = "Completed";
            } else if value.contains("hiatus") {
                status = "Hiatus";
            } else if value.contains("cancelled") || value.contains("canceled") || value.contains("dropped") {
                status = "Cancelled";
            }
        }

        // Author
        if text.contains("author") {
            let author_links = html_select(item, "a");
            if author_links.len() > 0 {
                for al in author_links {
                    let author = element_text(al).trim();
                    if author != "" && author != "Updating" && author != "-" && !authors.contains(author) {
                        authors.push(author);
                    }
                }
            } else {
                // Author text directly in the element (after "Author" label)
                let value_els = html_select(item, "i");
                if value_els.len() > 0 {
                    let author = element_text(value_els[0]).trim();
                    if author != "" && author != "Updating" && author != "-" && !authors.contains(author) {
                        authors.push(author);
                    }
                }
            }
        }

        // Artist
        if text.contains("artist") {
            let artist_links = html_select(item, "a");
            if artist_links.len() > 0 {
                for al in artist_links {
                    let artist = element_text(al).trim();
                    if artist != "" && artist != "Updating" && artist != "-" && !artists.contains(artist) {
                        artists.push(artist);
                    }
                }
            } else {
                let value_els = html_select(item, "i");
                if value_els.len() > 0 {
                    let artist = element_text(value_els[0]).trim();
                    if artist != "" && artist != "Updating" && artist != "-" && !artists.contains(artist) {
                        artists.push(artist);
                    }
                }
            }
        }

        // Released year (MangaThemesia "Released <i>2023</i>")
        if year == () && (text.contains("released") || text.contains("year")) {
            let y = regex_find("(19|20)\\d{2}", text);
            if y != "" { year = parse_int(y); }
        }
    }

    // Also check .fmed containers (another Flavor pattern for author/artist)
    if authors.len() == 0 {
        let fmed_els = html_select(html, ".fmed");
        for item in fmed_els {
            let label_text = "";
            let label_els = html_select(item, "b, span");
            if label_els.len() > 0 {
                label_text = element_text(label_els[0]).to_lower().trim();
            }
            if label_text.contains("author") {
                let val_els = html_select(item, "span a, span");
                for vel in val_els {
                    let val = element_text(vel).trim();
                    if val != "" && val != "-" && !val.to_lower().contains("author") && !authors.contains(val) {
                        authors.push(val);
                    }
                }
            }
            if label_text.contains("artist") && artists.len() == 0 {
                let val_els = html_select(item, "span a, span");
                for vel in val_els {
                    let val = element_text(vel).trim();
                    if val != "" && val != "-" && !val.to_lower().contains("artist") && !artists.contains(val) {
                        artists.push(val);
                    }
                }
            }
        }
    }

    // Extract alternative titles - Flavor uses .wd-full or .seriestualt
    let alt_els = html_select(html, ".seriestualt");
    if alt_els.len() > 0 {
        let alt_text = element_text(alt_els[0]).trim();
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
    // Fallback: try .wd-full with "Alternative" heading
    if alternate_titles.len() == 0 {
        let wd_els = html_select(html, ".wd-full");
        for item in wd_els {
            let item_text = element_text(item).to_lower();
            if item_text.contains("alternative") || item_text.contains("alt name") || item_text.contains("other name") {
                let span_els = html_select(item, "span");
                if span_els.len() > 0 {
                    let alt_text = element_text(span_els[span_els.len() - 1]).trim();
                    if alt_text != "" && alt_text != "-" {
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
            source_name: "Arena Scans"
        }
    }
}

/// Get all chapters for a series
/// Flavor theme lists chapters on the series page in #chapterlist or .eplister
fn get_chapters(series_id, auth) {
    let url = series_id;
    let slug = series_id;

    if !series_id.starts_with("http") {
        url = `${BASE_URL}/manga/${series_id}/`;
    } else {
        slug = extract_slug(series_id);
    }

    let html = fetch_html(url);

    if html == "" {
        return [];
    }

    let chapters = [];
    let seen = #{};

    // Flavor/MangaStream: chapters in #chapterlist li or .eplister li
    let chapter_items = html_select(html, "#chapterlist li");
    if chapter_items.len() == 0 {
        chapter_items = html_select(html, ".eplister li");
    }
    if chapter_items.len() == 0 {
        chapter_items = html_select(html, "ul.clstyle li");
    }
    // Fallback: try .bxcl li or generic chapter containers
    if chapter_items.len() == 0 {
        chapter_items = html_select(html, ".bxcl li");
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

        // Build full URL
        let chapter_url = href;
        if !href.starts_with("http") {
            chapter_url = make_absolute_url(href);
        }

        // Extract chapter number from URL or text
        // Flavor theme: .chapternum contains chapter name/number
        let chapter_text = "";
        let chnum_els = html_select(item, ".chapternum");
        if chnum_els.len() > 0 {
            chapter_text = element_text(chnum_els[0]).trim();
        }
        if chapter_text == "" {
            chapter_text = element_text(link).trim();
        }

        let chapter_num = extract_chapter_number(href);

        // If we couldn't get number from URL, try the text
        if chapter_num == "0" || chapter_num == "" {
            chapter_num = extract_chapter_number(chapter_text);
        }

        // Use data-num attribute if available (some Flavor themes provide this)
        let data_num = element_attr(item, "data-num");
        if data_num != () && data_num != "" {
            let parsed = extract_number(data_num);
            if parsed != "" {
                chapter_num = parsed;
            }
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

        // Get release date - Flavor uses .chapterdate
        let published_at = ();
        let date_els = html_select(item, ".chapterdate");
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
            scanlator: "Arena Scans",
            url: chapter_url,
            published_at: published_at,
            page_count: (),
            extra: #{}
        });
    }

    // Flavor/MangaStream lists chapters newest-first, so reverse for ascending order
    chapters.reverse();

    chapters
}

/// Get page image URLs for a chapter
/// Flavor/MangaStream themes use #readerarea img or ts_reader.run() JSON
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

    // Method 1: Try ts_reader.run() JSON extraction (common in MangaStream/Flavor themes)
    // This is a JavaScript object containing the image URLs as an array
    // Pattern: ts_reader.run({"sources":[{"source":"...","images":["url1","url2",...]}]})
    let images_match = regex_find("\"images\":\\[([^\\]]+)\\]", html);
    if images_match != () && images_match != "" {
        // Extract all image URLs from the match
        let url_pattern = "https?:\\\\/\\\\/[^\"]+|https?://[^\"]+";
        let all_urls = regex_find_all(url_pattern, images_match);
        if all_urls != () && all_urls.len() > 0 {
            for img_url in all_urls {
                // Clean up escaped URLs
                let clean_url = img_url.replace("\\/", "/");
                clean_url = clean_url.trim();

                if is_valid_page_image(clean_url) && !seen_urls.contains(clean_url) {
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
    }

    // Method 2: HTML parsing of #readerarea img (standard Flavor/MangaStream reader)
    if pages.len() == 0 {
        let selectors = [
            "#readerarea img",
            ".rdminimal img",
            ".reading-content img",
            ".page-break img",
            ".entry-content img"
        ];

        for selector in selectors {
            let page_imgs = html_select(html, selector);

            for img in page_imgs {
                let img_url = get_image_url(img);

                if img_url != () && img_url != "" && is_valid_page_image(img_url) {
                    let full_url = make_absolute_url(img_url);
                    full_url = full_url.trim();

                    if !seen_urls.contains(full_url) {
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

            // If we found pages with this selector, stop trying others
            if pages.len() > 0 {
                break;
            }
        }
    }

    // Method 3: Regex fallback for image URLs in the page source
    if pages.len() == 0 {
        let img_matches = regex_find_all("\"(https?://[^\"]+(?:\\.jpg|\\.jpeg|\\.png|\\.webp)[^\"]*)\"", html);
        for img_url in img_matches {
            let clean_url = img_url.replace("\"", "").trim();

            if is_valid_page_image(clean_url) {
                if !seen_urls.contains(clean_url) {
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
    }

    pages
}

/// Get latest manga updates
fn get_latest_updates(page, auth) {
    let url = `${BASE_URL}/manga/`;
    if page > 1 {
        url = `${BASE_URL}/manga/page/${page}/`;
    }
    // Flavor theme: ?order=update for latest
    url += "?order=update";

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let result = parse_series_listing(html);
    let series = result.series;

    // Check for next page
    let has_more = false;
    let next_links = html_select(html, "a.next, a.nextpostslink, .hpage a.r, .nextprev a, .pagination a.next, .wp-pagenavi a.nextpostslink");
    if next_links.len() > 0 {
        has_more = true;
    }
    if !has_more && series.len() >= 15 {
        has_more = true;
    }
    if page >= 100 {
        has_more = false;
    }

    #{ series: series, has_more: has_more }
}
