// MangaNato Unified Scraper (Rhai)
// Distributes requests across all MangaNato mirror sites for reliability:
//   - manganato.gg (primary)
//   - mangakakalot.gg
//   - nelomanga.net
//   - natomanga.com
//   - manganato.com (original, fallback)
//
// All .gg mirrors share the same content and URL structure.
// Original manganato.com uses manga-XXXXX ID format.
// Image CDN: img-r1.2xstorage.com / imgs-2.2xstorage.com
//
// URL Patterns (.gg sites):
//   Search:   /search/story/{query}
//   Series:   /manga/{slug}
//   Chapter:  /manga/{slug}/chapter-{number}
//   Cover:    https://img-r1.2xstorage.com/thumb/{slug}.webp
//   Pages:    https://img-r1.2xstorage.com/{slug}/{chapter}/{page}.webp
//
// URL Patterns (manganato.com):
//   Search:   /search/story/{query}
//   Series:   /{manga-XXXXX}
//   Chapter:  https://chapmanganato.to/{manga-XXXXX}/chapter-{number}

// Mirror sites in priority order (inlined in functions due to Rhai scoping)
// Primary: manganato.gg, Fallbacks: mangakakalot.gg, nelomanga.net, natomanga.com, manganato.com

/// Get the primary mirror URL
fn get_mirror() {
    "https://www.manganato.gg"
}

/// Get all mirrors for fallback (try each one)
fn get_mirror_list() {
    [
        "https://www.manganato.gg",
        "https://www.mangakakalot.gg",
        "https://www.nelomanga.net",
        "https://www.natomanga.com",
        "https://manganato.com"
    ]
}

/// Get original manganato.com mirrors
fn get_original_mirrors() {
    [
        "https://manganato.com",
        "https://chapmanganato.to"
    ]
}

/// Get image CDN URL
fn get_img_cdn() {
    "https://img-r1.2xstorage.com"
}

/// Get backup image CDN URL
fn get_img_cdn_backup() {
    "https://imgs-2.2xstorage.com"
}

/// Build request headers
fn get_headers(referer) {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": referer
    }
}

/// True if the HTML is a Cloudflare/interstitial challenge rather than real
/// content. Some mirrors (natomanga.com, nelomanga.net) serve a "Just a
/// moment..." challenge for detail pages while manganato.gg serves them plainly,
/// so callers must skip blocked pages and fall through to the next mirror.
fn looks_blocked(html) {
    html.contains("Just a moment")
        || html.contains("cf-browser-verification")
        || html.contains("cf-challenge")
        || html.contains("Checking if the site connection is secure")
        || html.contains("Enable JavaScript and cookies to continue")
}

/// Fetch a JSON API endpoint across mirrors (sets the XHR header the site's
/// own JS uses). Skips CF-challenge/empty responses. Returns the raw JSON body.
fn fetch_api(path) {
    let mirrors = get_mirror_list();
    for mirror in mirrors {
        let url = `${mirror}${path}`;
        let headers = get_headers(mirror);
        headers["X-Requested-With"] = "XMLHttpRequest";
        headers["Accept"] = "application/json, text/plain, */*";
        let body = "";
        try { body = http_get_with_headers(url, headers); } catch {}
        if body == "" { try { body = http_get(url); } catch {} }
        if body != "" && !looks_blocked(body) && body.contains("\"success\"") {
            return body;
        }
    }
    ""
}

/// Fetch HTML with mirror fallback - tries each mirror until one works
/// Uses browser automation if available, falls back to HTTP
fn fetch_with_fallback(path) {
    let mirrors = get_mirror_list();

    for mirror in mirrors {
        let url = `${mirror}${path}`;
        let html = "";

        // Try browser first (handles JS-rendered content like chapter lists)
        if browser_is_available() {
            try {
                let browser_id = browser_launch();
                browser_goto(browser_id, url);
                browser_wait_for_selector(browser_id, "body", 10000);
                html = browser_get_html(browser_id);
                browser_close(browser_id);
            } catch {
                html = "";
            }
        }

        // Fallback to HTTP
        if html == "" || html.len() < 500 {
            try {
                html = http_get_with_headers(url, get_headers(mirror));
            } catch {
                try {
                    html = http_get(url);
                } catch {
                    html = "";
                }
            }
        }

        if html != "" && html.len() > 500 && !looks_blocked(html) && !html.contains("Page not found") {
            return html;
        }
    }

    ""
}

/// Fetch a full URL directly (for chapter pages that already have full URLs)
fn fetch_url(url) {
    let html = "";

    if browser_is_available() {
        try {
            let browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_selector(browser_id, "body", 10000);
            html = browser_get_html(browser_id);
            browser_close(browser_id);
        } catch {
            html = "";
        }
    }

    if html == "" || html.len() < 500 {
        let referer = regex_find("https?://[^/]+", url);
        if referer == "" {
            referer = get_mirror();
        }
        try {
            html = http_get_with_headers(url, get_headers(referer));
        } catch {
            try {
                html = http_get(url);
            } catch {
                html = "";
            }
        }
    }

    html
}

/// Fetch a series detail page. The working mirror (manganato.gg) serves the
/// full chapter list in static HTML, so we try plain HTTP first (fast, no CF
/// headless fingerprinting) and only fall back to the browser if no mirror
/// yields chapter links over HTTP. CF-challenge pages are skipped so we fall
/// through to a clean mirror.
fn fetch_series_page(path) {
    let mirrors = get_mirror_list();

    // Pass 1: HTTP across mirrors, require chapter markers + not CF-blocked.
    for mirror in mirrors {
        let url = `${mirror}${path}`;
        let html = "";
        try {
            html = http_get_with_headers(url, get_headers(mirror));
        } catch {
            try { html = http_get(url); } catch { html = ""; }
        }
        if html != "" && html.len() > 500 && !looks_blocked(html)
            && !html.contains("Page not found") && html.contains("/chapter-") {
            return html;
        }
    }

    // Pass 2: browser fallback for mirrors whose chapter list is JS-rendered.
    if browser_is_available() {
        for mirror in mirrors {
            let url = `${mirror}${path}`;
            let html = "";
            try {
                let browser_id = browser_launch();
                browser_goto(browser_id, url);
                browser_wait_for_selector(browser_id, "ul.row-content-chapter, div.chapter-list, a[href*='/chapter-']", 15000);
                html = browser_get_html(browser_id);
                browser_close(browser_id);
            } catch {
                html = "";
            }
            if html != "" && html.len() > 500 && !looks_blocked(html) && !html.contains("Page not found") {
                return html;
            }
        }
    }

    ""
}

/// Extract manga slug from URL path
/// Handles both formats:
///   - /manga/one-piece -> one-piece (manganato.gg style)
///   - /manga-xy123456 or /{manga-xy123456} -> manga-xy123456 (manganato.com style)
fn extract_slug(url) {
    let parts = url.split("/");

    // Check for manga-XXXXX format (manganato.com style)
    for part in parts {
        if part.starts_with("manga-") && part.len() > 8 {
            return part;
        }
    }

    // Check for /manga/{slug} format (.gg style)
    for i in 0..parts.len() {
        if parts[i] == "manga" && i + 1 < parts.len() {
            // Return the slug, stripping any chapter part
            let slug = parts[i + 1];
            if slug != "" && !slug.starts_with("chapter") {
                return slug;
            }
        }
    }

    // Fallback: last non-empty path segment
    let last = "";
    for part in parts {
        if part != "" {
            last = part;
        }
    }
    last
}

/// Check if a slug is in manga-XXXXX format (original manganato.com)
fn is_original_format(slug) {
    slug.starts_with("manga-") && slug.len() > 8
}

/// Extract chapter number from URL or title text
fn extract_chapter_number(url, title) {
    // From URL: /manga/slug/chapter-123 or chapter-123.5
    let result = regex_find("chapter-(\\d+\\.?\\d*)", url);
    if result != "" {
        let num = regex_find("\\d+\\.?\\d*", result);
        if num != "" {
            return num;
        }
    }

    // From title text: "Chapter 123" or "Ch.123"
    let title_lower = title.to_lower();
    if title_lower.contains("chapter") {
        let after = title_lower.split("chapter")[1];
        let cleaned = after.trim();
        let num_str = "";
        for c in cleaned.chars() {
            if (c >= '0' && c <= '9') || c == '.' {
                num_str += c;
            } else if num_str.len() > 0 {
                break;
            }
        }
        if num_str != "" {
            return num_str;
        }
    }

    "0"
}

/// Build cover URL from slug
fn build_cover_url(slug) {
    let cdn = get_img_cdn();
    `${cdn}/thumb/${slug}.webp`
}

// === Addon Interface Functions ===

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "manganato-gg-rhai",
        name: "MangaNato (Unified)",
        base_url: get_mirror(),
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "browser_automation"
    }
}

/// Search for manga matching a query
fn search_series(query, page, auth) {
    // These sites use the path-based search with spaces as underscores
    let encoded_query = query.replace(" ", "_");
    let path = `/search/story/${encoded_query}`;
    if page > 1 {
        path = `${path}?page=${page}`;
    }

    // The /search/ path is Cloudflare-gated on every mirror: the browser/HTTP
    // tiers in fetch_with_fallback get the challenge page (looks_blocked) and
    // cycle all 5 mirrors (~30s) before giving up empty. FlareSolverr solves CF
    // and returns the real results (div.story_item), so try it FIRST and only
    // fall back to mirror-cycling if FlareSolverr is unavailable.
    let html = "";
    if flaresolverr_is_available() {
        try {
            let rendered = flaresolverr_get(`${get_mirror()}${path}`, 40000);
            if rendered != "" && rendered.len() > 500 && !looks_blocked(rendered) {
                html = rendered;
            }
        } catch {
            // fall through to mirror-cycling
        }
    }
    if html == "" {
        html = fetch_with_fallback(path);
    }

    if html == "" {
        return #{ series: [], has_more: false, total: 0 };
    }

    let series = [];
    let seen = #{};

    // Parse search results - try the .gg site structure
    // Search results use div.search-story-item or similar containers
    let items = html_select(html, "div.search-story-item");

    // Fallback selector if the first one doesn't match
    if items.len() == 0 {
        items = html_select(html, "div.story_item");
    }
    if items.len() == 0 {
        items = html_select(html, "div.content-genres-item");
    }

    for item in items {
        // Find the primary link
        let link = element_select_first(item, "a.item-img");
        if link == "" {
            link = element_select_first(item, "a");
        }
        if link == "" {
            continue;
        }

        let href = element_attr(link, "href");
        if href == "" || href == () {
            continue;
        }

        let slug = extract_slug(href);
        if slug == "" || seen[slug] != () {
            continue;
        }
        seen[slug] = true;

        // Get title
        let title = "";
        let title_el = element_select_first(item, "h3 a");
        if title_el != "" {
            title = element_text(title_el).trim();
        }
        if title == "" {
            title = element_attr(link, "title");
            if title == () {
                title = "";
            }
            title = title.trim();
        }
        if title == "" {
            continue;
        }

        // Get cover image
        let cover_url = "";
        let img = element_select_first(item, "img");
        if img != "" {
            cover_url = element_attr(img, "src");
            if cover_url == () {
                cover_url = "";
            }
        }
        if cover_url == "" {
            cover_url = build_cover_url(slug);
        }

        // Get authors
        let authors = [];
        let author_el = element_select_first(item, "span.item-author");
        if author_el != "" {
            let author = element_text(author_el).trim();
            if author != "" && author != "Updating" {
                authors.push(author);
            }
        }

        series.push(#{
            id: slug,
            title: title,
            url: `/manga/${slug}`,
            cover_url: cover_url,
            alternate_titles: [],
            authors: authors,
            artists: [],
            status: (),
            genres: [],
            tags: [],
            description: ()
        });
    }

    // Check for next page
    let has_more = false;
    let next_btn = html_select(html, "a.page-blue.page-last");
    if next_btn.len() > 0 {
        has_more = true;
    }
    // Also check by page number in links
    let next_page = page + 1;
    if html.contains(`page=${next_page}`) {
        has_more = true;
    }

    #{ series: series, has_more: has_more, total: () }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let slug = id_or_url;
    let path = "";

    if id_or_url.starts_with("http") {
        slug = extract_slug(id_or_url);
    }

    if id_or_url.contains("/manga/") {
        path = regex_find("/manga/[^?#]+", id_or_url);
        if path == "" {
            path = `/manga/${slug}`;
        }
    } else {
        path = `/manga/${slug}`;
    }

    let html = fetch_series_page(path);

    if html == "" {
        throw `Failed to fetch series: ${slug}`;
    }

    // Extract title
    let title = "";
    let title_els = html_select(html, "h1");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }

    // Extract cover
    let cover_url = build_cover_url(slug);
    let cover_imgs = html_select(html, "span.info-image img, div.manga-info-pic img");
    if cover_imgs.len() > 0 {
        let src = element_attr(cover_imgs[0], "src");
        if src != () && src != "" {
            cover_url = src;
        }
    }

    // Extract description (current site uses .description; legacy fallbacks kept)
    let description = ();
    let desc_els = html_select(html, "div.description, .description, div.panel-story-info-description, div#noidungm");
    if desc_els.len() > 0 {
        description = element_text(desc_els[0]).trim();
        if description.starts_with("Description :") {
            description = description.sub_string(13).trim();
        }
        if description.starts_with("Description:") {
            description = description.sub_string(12).trim();
        }
    }

    // Extract info from table rows
    let authors = [];
    let artists = [];
    let genres = [];
    let status = ();
    let alt_titles = [];

    // Try table-based info layout
    let table_rows = html_select(html, "table.variations-tableInfo tr");
    for row in table_rows {
        let label_els = html_select(row, "td.table-label");
        let value_els = html_select(row, "td.table-value");

        if label_els.len() > 0 && value_els.len() > 0 {
            let label = element_text(label_els[0]).to_lower();
            let value_html = value_els[0];

            if label.contains("author") {
                let links = html_select(value_html, "a");
                for link in links {
                    let author = element_text(link).trim();
                    if author != "" && author != "Updating" && !authors.contains(author) {
                        authors.push(author);
                    }
                }
            } else if label.contains("artist") {
                let links = html_select(value_html, "a");
                for link in links {
                    let artist = element_text(link).trim();
                    if artist != "" && artist != "Updating" && !artists.contains(artist) {
                        artists.push(artist);
                    }
                }
            } else if label.contains("genre") {
                let links = html_select(value_html, "a");
                for link in links {
                    let genre = element_text(link).trim();
                    if genre != "" && !genres.contains(genre) {
                        genres.push(genre);
                    }
                }
            } else if label.contains("status") {
                let s = element_text(value_html).to_lower().trim();
                if s.contains("ongoing") {
                    status = "Ongoing";
                } else if s.contains("completed") {
                    status = "Completed";
                }
            } else if label.contains("alternative") {
                let alt_text = element_text(value_html);
                let alts = alt_text.split(";");
                for alt in alts {
                    let cleaned = alt.trim();
                    if cleaned != "" && cleaned != title {
                        alt_titles.push(cleaned);
                    }
                }
            }
        }
    }

    // Fallback: list-based info layout (current site). Run whenever authors are
    // still missing — genres/status often come from here too, so don't gate on
    // genres being empty.
    if authors.len() == 0 {
        let info_items = html_select(html, "ul.manga-info-text li");
        for item in info_items {
            let text = element_text(item).to_lower();
            if text.contains("author") {
                let links = html_select(item, "a");
                for link in links {
                    let author = element_text(link).trim();
                    if author != "" && author != "Updating" && !authors.contains(author) {
                        authors.push(author);
                    }
                }
                // Author may be plain text ("Author(s) : Name"), not a link.
                if authors.len() == 0 {
                    let raw = element_text(item).trim();
                    let cpos = raw.index_of(":");
                    if cpos >= 0 {
                        let name = raw.sub_string(cpos + 1).trim();
                        if name != "" && name != "Updating" && name.to_lower() != "updating" { authors.push(name); }
                    }
                }
            } else if text.contains("artist") {
                let links = html_select(item, "a");
                for link in links {
                    let artist = element_text(link).trim();
                    if artist != "" && artist != "Updating" && !artists.contains(artist) {
                        artists.push(artist);
                    }
                }
            } else if text.contains("genre") {
                let links = html_select(item, "a");
                for link in links {
                    let genre = element_text(link).trim();
                    if genre != "" && !genres.contains(genre) {
                        genres.push(genre);
                    }
                }
            } else if text.contains("status") {
                if text.contains("ongoing") {
                    status = "Ongoing";
                } else if text.contains("completed") {
                    status = "Completed";
                }
            } else if text.contains("alternative") {
                let alt_text = text.replace("alternative :", "").trim();
                let alts = alt_text.split(";");
                for alt in alts {
                    let cleaned = alt.trim();
                    if cleaned != "" && cleaned != title.to_lower() {
                        alt_titles.push(cleaned);
                    }
                }
            }
        }
    }

    #{
        id: slug,
        title: title,
        alternate_titles: alt_titles,
        description: description,
        cover_url: cover_url,
        authors: authors,
        artists: artists,
        status: status,
        genres: genres,
        tags: [],
        year: (),
        content_rating: "suggestive",
        url: `${get_mirror()}/manga/${slug}`,
        extra: #{}
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let slug = series_id;

    if series_id.starts_with("http") {
        slug = extract_slug(series_id);
    } else if series_id.contains("/manga/") {
        slug = extract_slug(series_id);
    }

    let chapters = [];
    let seen = #{};

    // Primary: the chapter list loads via a JSON API (the series page ships only
    // a "chapter-list-loading" stub plus sidebar links to OTHER series — the old
    // a[href*='/chapter-'] selector wrongly scraped those, producing chapters
    // that don't belong to this series). Returns the most recent ~50 chapters.
    let json_str = fetch_api(`/api/manga/${slug}/chapters`);
    if json_str != "" {
        let parsed = ();
        try { parsed = json_parse(json_str); } catch {}
        if parsed != () && parsed["success"] == true && parsed["data"] != () {
            let list = parsed["data"]["chapters"];
            if list != () {
                for ch in list {
                    let num = `${ch["chapter_num"]}`;
                    if num == "" || seen[num] != () { continue; }
                    seen[num] = true;
                    // Skip the site's spam/placeholder chapters (absurd numbers
                    // like 67676767 that only resolve to a 2-image "not found"
                    // page). No real manga exceeds a few thousand chapters.
                    if parse_float(num) > 100000.0 { continue; }
                    let cslug = ch["chapter_slug"];
                    if cslug == () || cslug == "" { cslug = `chapter-${num}`; }
                    let cname = ch["chapter_name"];
                    if cname == () || cname == "" { cname = `Chapter ${num}`; }
                    let chapter_path = `/manga/${slug}/${cslug}`;
                    chapters.push(#{
                        id: chapter_path,
                        series_id: slug,
                        number: num,
                        title: cname,
                        volume: (),
                        language: "en",
                        scanlator: (),
                        url: chapter_path,
                        published_at: ch["updated_at"],
                        page_count: (),
                        extra: #{}
                    });
                }
            }
        }
    }
    if chapters.len() > 0 {
        return chapters;
    }

    // Fallback: scrape the static page, but ONLY links under this series' slug
    // (so we never pick up sidebar links to other series).
    let html = fetch_series_page(`/manga/${slug}`);
    if html == "" {
        return [];
    }
    let chapter_links = html_select(html, `a[href*='/manga/${slug}/chapter-']`);
    if chapter_links.len() == 0 {
        chapter_links = html_select(html, "ul.row-content-chapter li a.chapter-name");
    }
    for link in chapter_links {
        let href = element_attr(link, "href");
        if href == () || href == "" { continue; }
        // Guard: the link must belong to THIS series.
        if !href.contains(`/manga/${slug}/chapter-`) { continue; }

        let chapter_title = element_text(link).trim();
        let chapter_num = extract_chapter_number(href, chapter_title);
        if seen[chapter_num] != () { continue; }
        seen[chapter_num] = true;
        // Skip spam/placeholder chapters (absurd numbers like 67676767).
        if parse_float(chapter_num) > 100000.0 { continue; }

        let chapter_path = `/manga/${slug}/chapter-${chapter_num}`;
        if chapter_title == "" { chapter_title = `Chapter ${chapter_num}`; }

        chapters.push(#{
            id: chapter_path,
            series_id: slug,
            number: chapter_num,
            title: chapter_title,
            volume: (),
            language: "en",
            scanlator: (),
            url: chapter_path,
            published_at: (),
            page_count: (),
            extra: #{}
        });
    }

    chapters
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    let path = chapter_id;

    // Normalize to a path
    if chapter_id.starts_with("http") {
        path = regex_find("/manga/[^?#]+", chapter_id);
        if path == "" {
            path = chapter_id;
        }
    }

    // Fetch the chapter reader page
    let html = "";
    let used_mirror = get_mirror();
    let mirrors = get_mirror_list();

    for mirror in mirrors {
        let url = `${mirror}${path}`;
        try {
            html = http_get_with_headers(url, get_headers(mirror));
        } catch {
            try {
                html = http_get(url);
            } catch {
                html = "";
            }
        }

        if html != "" && html.len() > 1000 && (html.contains("chapterImages") || html.contains("container-chapter-reader")) {
            used_mirror = mirror;
            break;
        }

        // Try browser if HTTP didn't get the images
        if browser_is_available() {
            try {
                let browser_id = browser_launch();
                browser_goto(browser_id, url);
                browser_wait_for_selector(browser_id, ".container-chapter-reader img, img[loading='lazy']", 10000);
                html = browser_get_html(browser_id);
                browser_close(browser_id);
                if html != "" && html.len() > 1000 {
                    used_mirror = mirror;
                    break;
                }
            } catch {
                html = "";
            }
        }
    }

    if html == "" {
        return [];
    }

    let pages = [];
    let idx = 0;

    // Method 1: Extract from chapterImages JavaScript array
    // var chapterImages = ["one-piece/1/0.webp","one-piece/1/1.webp",...];
    let images_match = regex_find("chapterImages\\s*=\\s*\\[([^\\]]+)\\]", html);
    if images_match != "" {
        // Extract the array contents
        let array_content = regex_find("\\[([^\\]]+)\\]", images_match);
        array_content = array_content.replace("[", "").replace("]", "");

        // Extract individual image paths
        let image_paths = regex_find_all("\"([^\"]+)\"", array_content);

        // Find CDN URLs from the page
        let cdn_url = get_img_cdn();
        let cdn_match = regex_find("(https://[^\"']+2xstorage\\.com[^\"']*)", html);
        if cdn_match != "" {
            // Extract just the base CDN URL
            let cdn_base = regex_find("https://[^/]+\\.2xstorage\\.com", cdn_match);
            if cdn_base != "" {
                cdn_url = cdn_base;
            }
        }

        for img_path in image_paths {
            // Clean the path - remove quotes
            let clean_path = img_path.replace("\"", "").trim();
            if clean_path == "" {
                continue;
            }

            let full_url = `${cdn_url}/${clean_path}`;

            pages.push(#{
                index: idx,
                url: full_url,
                headers: #{
                    "Referer": `${used_mirror}${path}`
                },
                referer: `${used_mirror}${path}`
            });
            idx += 1;
        }
    }

    // Method 2: Fallback to parsing img tags in the reader container
    if pages.len() == 0 {
        let page_imgs = html_select(html, "div.container-chapter-reader img");

        for img in page_imgs {
            let img_url = element_attr(img, "src");
            if img_url == () || img_url == "" {
                img_url = element_attr(img, "data-src");
            }

            if img_url != () && img_url != "" && img_url.contains("http") {
                // Skip non-manga images
                if img_url.contains("logo") || img_url.contains("icon") || img_url.contains("banner") || img_url.contains("default_nato") {
                    continue;
                }

                pages.push(#{
                    index: idx,
                    url: img_url,
                    headers: #{
                        "Referer": `${used_mirror}${path}`
                    },
                    referer: `${used_mirror}${path}`
                });
                idx += 1;
            }
        }
    }

    pages
}

/// Get latest updates
fn get_latest_updates(page, auth) {
    let path = `/?page=${page}`;
    let html = fetch_with_fallback(path);

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let seen = #{};

    // Parse latest updates items. Current MangaNato/Nato template wraps each
    // item in div.itemupdate (older themes used content-genres-item /
    // list-truyen-item-wrap — kept as fallbacks).
    let items = html_select(html, "div.itemupdate");
    if items.len() == 0 {
        items = html_select(html, "div.content-genres-item");
    }
    if items.len() == 0 {
        items = html_select(html, "div.list-truyen-item-wrap");
    }

    for item in items {
        // Cover anchor (a.cover) carries the /manga/{slug} href; fall back to
        // the older a.genres-item-img then any anchor.
        let link = element_select_first(item, "a.cover");
        if link == "" {
            link = element_select_first(item, "a.genres-item-img");
        }
        if link == "" {
            link = element_select_first(item, "a");
        }
        if link == "" {
            continue;
        }

        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        let slug = extract_slug(href);
        if slug == "" || seen[slug] != () {
            continue;
        }
        seen[slug] = true;

        // Title: prefer the cover img alt, then the h3 anchor text, then the
        // anchor's own title attr.
        let title = ();
        let img_el = element_select_first(item, "img");
        if img_el != "" {
            title = element_attr(img_el, "alt");
        }
        if title == () || title == "" {
            let title_el = element_select_first(item, "h3 a");
            if title_el != "" {
                title = element_text(title_el);
            }
        }
        if title == () || title == "" {
            title = element_attr(link, "title");
        }
        if title == () {
            title = "";
        }
        title = title.trim();
        if title == "" {
            continue;
        }

        let cover_url = "";
        let img = element_select_first(item, "img");
        if img != "" {
            cover_url = element_attr(img, "src");
            if cover_url == () {
                cover_url = "";
            }
        }
        if cover_url == "" {
            cover_url = build_cover_url(slug);
        }

        series.push(#{
            id: slug,
            title: title,
            url: `/manga/${slug}`,
            cover_url: cover_url,
            updated_at: ()
        });
    }

    let has_more = page < 50 && series.len() > 0;

    #{ series: series, has_more: has_more }
}

/// Browse manga (main browse endpoint)
fn browse(page, filters, auth) {
    // Default to latest updates for browse
    get_latest_updates(page, auth)
}
