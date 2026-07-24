// MangaFire Scraper Add-on (Rhai)
// Browser-based scraper for mangafire.to
//
// MangaFire uses Cloudflare protection and VRF tokens for AJAX endpoints.
// Browser automation is required for reliable access.
//
// URL Patterns:
//   Search:    /filter?keyword={query}&language[]={lang}&page={page}
//   Series:    /manga/{slug}.{code}
//   Reader:    /read/{slug}/{lang}/chapter-{number}
//   Chapters:  /ajax/manga/{id}/chapter/{langCode} (VRF protected)
//   Pages:     /ajax/read/chapter/{chapterId} (VRF protected)
//   Covers:    https://static.mfcdn.cc/{hash}/i/{path}/{file}.jpg
//
// Since VRF tokens are JS-generated, we use browser automation for all requests.

const BASE_URL = "https://mangafire.to";
const CDN_URL = "https://static.mfcdn.cc";

/// Build request headers (HTTP fallback)
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Check if HTML is a CloudFlare challenge page (not real content).
/// Three challenge variants — the "Attention Required" template was being
/// missed, so those challenge bodies slipped through as "real content".
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

/// Fetch page via HTTP first, FlareSolverr second, browser last.
/// MangaFire filter/browse/series pages serve full HTML without JS.
fn fetch_http_first(url) {
    // Tier 1: HTTP first
    try {
        let html = http_get_with_headers(url, get_headers());
        if html.len() > 1000 && !is_cloudflare_challenge(html) {
            return html;
        }
    } catch {}

    // Tier 2: FlareSolverr - reliable CF bypass
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 30000);
            if html.len() > 1000 && !is_cloudflare_challenge(html) {
                return html;
            }
        } catch {}
    }

    // Tier 3: Browser
    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 15000);
            browser_wait_for_selector(browser_id, "body", 8000);
            let html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            return html;
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    ""
}

/// Fetch page for reader/AJAX (FlareSolverr first, then browser)
fn fetch_page(url) {
    // Tier 1: FlareSolverr
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 30000);
            if html.len() > 1000 && !is_cloudflare_challenge(html) {
                return html;
            }
        } catch {}
    }

    // Tier 2: Browser
    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 15000);
            browser_wait_for_selector(browser_id, "body", 8000);
            let html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            return html;
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    // Tier 3: HTTP
    try {
        return http_get_with_headers(url, get_headers());
    } catch {
        return "";
    }
}

/// Fetch page with specific content wait (FlareSolverr first, then browser)
fn fetch_page_wait(url, selector) {
    // Tier 1: FlareSolverr
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 30000);
            if html.len() > 1000 && !is_cloudflare_challenge(html) {
                return html;
            }
        } catch {}
    }

    // Tier 2: Browser with selector wait
    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 15000);
            browser_wait_for_selector(browser_id, selector, 12000);
            let html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            return html;
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    // Tier 3: HTTP
    try {
        return http_get_with_headers(url, get_headers());
    } catch {
        return "";
    }
}

/// Extract manga slug+code from URL
/// /manga/one-piecee.dkw -> one-piecee.dkw
fn extract_manga_id(url) {
    let result = regex_find("/manga/([^/?#]+)", url);
    if result != "" {
        return result.replace("/manga/", "");
    }
    ""
}

/// Extract the read slug from a reader URL
/// /read/one-piecee.dkw/en/chapter-1 -> one-piecee.dkw
fn extract_read_slug(url) {
    let result = regex_find("/read/([^/]+)", url);
    if result != "" {
        return result.replace("/read/", "");
    }
    ""
}

/// Map MangaFire status to standard format
fn map_status(status) {
    let s = status.to_lower().trim();
    if s == "releasing" || s.contains("ongoing") {
        return "Ongoing";
    } else if s == "completed" || s.contains("finished") {
        return "Completed";
    } else if s.contains("hiatus") {
        return "Hiatus";
    } else if s.contains("discontinued") || s.contains("cancelled") {
        return "Cancelled";
    }
    status
}

// === Addon Interface Functions ===

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "mangafire-rhai",
        name: "MangaFire",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en", "es-la", "fr", "pt-br", "ja"],
        requires_authentication: false,
        capability_level: "browser_automation"
    }
}

/// Search for manga matching a query
fn search_series(query, page, auth) {
    let encoded = url_encode(query);
    let url = `${BASE_URL}/filter?keyword=${encoded}&language[]=en&page=${page}`;

    // Try HTTP first - MangaFire filter pages often serve full HTML
    let html = fetch_http_first(url);

    if html == "" {
        return #{ series: [], has_more: false, total: 0 };
    }

    let series = [];
    let seen = #{};

    // Parse search results - find manga cards
    // MangaFire uses <div class="unit item-{id}"> for each card
    let items = html_select(html, "div.unit");

    if items.len() == 0 {
        items = html_select(html, "div.original");
    }
    if items.len() == 0 {
        items = html_select(html, "div.inner");
    }

    // Process items from DOM
    for item in items {
        let link = element_select_first(item, "a[href*='/manga/']");
        if link == "" {
            continue;
        }

        let href = element_attr(link, "href");
        if href == "" || href == () {
            continue;
        }

        let manga_id = extract_manga_id(href);
        if manga_id == "" || seen[manga_id] != () {
            continue;
        }
        seen[manga_id] = true;

        // Title
        let title = "";
        let title_el = element_select_first(item, "a[href*='/manga/']");
        if title_el != "" {
            title = element_text(title_el).trim();
        }
        if title == "" {
            title = element_attr(link, "title");
            if title == () {
                title = "";
            }
        }
        if title == "" {
            continue;
        }

        // Cover image - inside <a class="poster"><div><img src="..."></div></a>
        let cover_url = "";
        let poster = element_select_first(item, "a.poster img");
        if poster == "" {
            poster = element_select_first(item, "img");
        }
        if poster != "" {
            cover_url = element_attr(poster, "src");
            if cover_url == "" {
                cover_url = element_attr(poster, "data-src");
            }
        }

        // Type badge (manga, manhwa, etc.)
        let manga_type = "";
        let type_el = element_select_first(item, "span.type");
        if type_el != "" {
            manga_type = element_text(type_el).trim();
        }

        series.push(#{
            id: manga_id,
            title: title,
            url: `${BASE_URL}/manga/${manga_id}`,
            cover_url: cover_url,
            alternate_titles: [],
            authors: [],
            artists: [],
            status: (),
            genres: [],
            tags: [],
            description: (),
            extra: #{
                manga_type: manga_type
            }
        });
    }

    // Fallback: parse from href patterns if no items found
    if series.len() == 0 {
        let manga_links = regex_find_all("href=\"(/manga/[^\"]+)\"[^>]*>([^<]*)<", html);
        for link_match in manga_links {
            let href = regex_find("/manga/[^\"]+", link_match);
            if href == "" {
                continue;
            }

            let manga_id = extract_manga_id(href);
            if manga_id == "" || seen[manga_id] != () {
                continue;
            }
            seen[manga_id] = true;

            let title = regex_find(">([^<]+)<", link_match);
            title = title.replace(">", "").replace("<", "").trim();
            if title == "" || title.len() < 2 {
                continue;
            }

            series.push(#{
                id: manga_id,
                title: title,
                url: `${BASE_URL}/manga/${manga_id}`,
                cover_url: "",
                alternate_titles: [],
                authors: [],
                artists: [],
                status: (),
                genres: [],
                tags: [],
                description: ()
            });
        }
    }

    // Check for pagination
    let has_more = html.contains(`page=${page + 1}`) || html.contains("page-next");

    #{ series: series, has_more: has_more, total: () }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let manga_id = id_or_url;

    if id_or_url.starts_with("http") {
        manga_id = extract_manga_id(id_or_url);
    } else if id_or_url.starts_with("/manga/") {
        manga_id = id_or_url.replace("/manga/", "");
    }

    let url = `${BASE_URL}/manga/${manga_id}`;
    let html = fetch_http_first(url);

    if html == "" {
        throw `Failed to fetch series: ${manga_id}`;
    }

    // Title - from the manga-detail section's h1
    let title = "";
    let title_els = html_select(html, "div.manga-detail h1");
    if title_els.len() == 0 {
        title_els = html_select(html, "h1");
    }
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }

    // Cover image - from the manga-detail poster section
    let cover_url = "";
    let poster_imgs = html_select(html, "div.manga-detail div.poster img");
    if poster_imgs.len() == 0 {
        poster_imgs = html_select(html, "aside.content div.poster img");
    }
    if poster_imgs.len() > 0 {
        cover_url = element_attr(poster_imgs[0], "src");
    }

    // Description - from og:description meta tag (most reliable)
    let description = ();
    let desc_match = regex_find("og:description[\"']\\s*content=[\"']([^\"']+)", html);
    if desc_match != "" {
        description = regex_find("content=[\"']([^\"']+)", desc_match);
        description = description.replace("content=\"", "").replace("content='", "").replace("\"", "").replace("'", "").trim();
    }
    // Also try synopsis section
    if description == () || description == "" {
        let desc_els = html_select(html, "#synopsis .modal-content, div.synopsis");
        if desc_els.len() > 0 {
            description = element_text(desc_els[0]).trim();
        }
    }

    // Status - from the info section within manga-detail
    let status = ();
    let info_els = html_select(html, "div.manga-detail div.info p");
    if info_els.len() == 0 {
        info_els = html_select(html, "aside.content div.info p");
    }
    for info_el in info_els {
        let info_text = element_text(info_el).trim();
        if info_text == "Releasing" || info_text == "Completed" || info_text == "On Hiatus" || info_text == "Discontinued" {
            status = map_status(info_text);
            break;
        }
    }

    // Authors/artists - from the meta section only (not nav)
    let authors = [];
    let artists = [];
    let meta_els = html_select(html, "div.meta");
    if meta_els.len() > 0 {
        let author_links = html_select(html, "div.meta a[href*='/author/']");
        for link in author_links {
            let name = element_text(link).trim();
            if name != "" && !authors.contains(name) {
                authors.push(name);
            }
        }
        let artist_links = html_select(html, "div.meta a[href*='/artist/']");
        for link in artist_links {
            let name = element_text(link).trim();
            if name != "" && !artists.contains(name) {
                artists.push(name);
            }
        }
    }

    // Genres - from the meta section only (not nav bar)
    let genres = [];
    if meta_els.len() > 0 {
        let genre_links = html_select(html, "div.meta a[href*='/genre/']");
        for link in genre_links {
            let genre = element_text(link).trim();
            if genre != "" && !genres.contains(genre) {
                genres.push(genre);
            }
        }
    }

    // Alternate titles - from the manga-detail info h6 only
    let alt_titles = [];
    let alt_els = html_select(html, "div.manga-detail div.info h6, aside.content div.info h6");
    for el in alt_els {
        let alt = element_text(el).trim();
        if alt != "" && alt != title && !alt_titles.contains(alt) {
            alt_titles.push(alt);
        }
    }

    // Year/published date - from meta section
    let year = ();
    if meta_els.len() > 0 {
        let meta_text = element_text(meta_els[0]);
        let year_match = regex_find("(19|20)\\d{2}", meta_text);
        if year_match != "" {
            year = year_match;
        }
    }

    #{
        id: manga_id,
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
        extra: #{
            auto_match_metadata: true,
            source_name: "MangaFire"
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let manga_id = series_id;

    if series_id.starts_with("http") {
        manga_id = extract_manga_id(series_id);
    } else if series_id.starts_with("/manga/") {
        manga_id = series_id.replace("/manga/", "");
    }

    let url = `${BASE_URL}/manga/${manga_id}`;

    // Load the series page - HTTP works for chapter listing
    let html = fetch_http_first(url);

    if html == "" {
        return [];
    }

    let chapters = [];
    let seen = #{};

    // Method 1: Parse chapter links from the rendered page
    // MangaFire chapter links: /read/{slug}/{lang}/chapter-{number}
    let chapter_links = html_select(html, "a[href*='/read/']");

    // Also try li elements with data-number attribute
    if chapter_links.len() == 0 {
        let chapter_items = html_select(html, "li[data-number]");
        for item in chapter_items {
            let link = element_select_first(item, "a");
            if link != "" {
                chapter_links.push(link);
            }
        }
    }

    for link in chapter_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Filter to only chapter links for this manga
        if !href.contains("/read/") {
            continue;
        }

        // Extract chapter number from URL
        let chapter_num = "0";
        let num_match = regex_find("chapter-(\\d+\\.?\\d*)", href);
        if num_match != "" {
            chapter_num = regex_find("\\d+\\.?\\d*", num_match);
        }

        // Also try volume pattern
        if chapter_num == "0" {
            num_match = regex_find("volume-(\\d+)", href);
            if num_match != "" {
                chapter_num = regex_find("\\d+", num_match);
            }
        }

        // Skip duplicates
        let dedup_key = `${chapter_num}`;
        if seen[dedup_key] != () {
            continue;
        }
        seen[dedup_key] = true;

        let chapter_title = element_text(link).trim();
        if chapter_title == "" {
            chapter_title = `Chapter ${chapter_num}`;
        }

        // Extract language from URL
        let lang = "en";
        let lang_match = regex_find("/read/[^/]+/([a-z]{2}(?:-[a-z]{2})?)/", href);
        if lang_match != "" {
            lang = regex_find("[a-z]{2}(-[a-z]{2})?", lang_match.replace("/read/", "").split("/")[1]);
            if lang == "" {
                lang = "en";
            }
        }

        // Build full URL if relative
        let chapter_url = href;
        if !chapter_url.starts_with("http") {
            chapter_url = `${BASE_URL}${href}`;
        }

        chapters.push(#{
            id: href,
            series_id: manga_id,
            number: chapter_num,
            title: chapter_title,
            volume: (),
            language: lang,
            scanlator: (),
            url: chapter_url,
            published_at: (),
            page_count: (),
            extra: #{}
        });
    }

    // Method 2: Fallback - extract from regex patterns in the HTML
    if chapters.len() == 0 {
        let read_patterns = regex_find_all("href=\"(/read/[^\"]+/chapter-[^\"]+)\"", html);
        for pattern in read_patterns {
            let href = regex_find("/read/[^\"]+", pattern);
            if href == "" {
                continue;
            }

            let chapter_num = "0";
            let num_match = regex_find("chapter-(\\d+\\.?\\d*)", href);
            if num_match != "" {
                chapter_num = regex_find("\\d+\\.?\\d*", num_match);
            }

            let dedup_key = `${chapter_num}`;
            if seen[dedup_key] != () {
                continue;
            }
            seen[dedup_key] = true;

            chapters.push(#{
                id: href,
                series_id: manga_id,
                number: chapter_num,
                title: `Chapter ${chapter_num}`,
                volume: (),
                language: "en",
                scanlator: (),
                url: `${BASE_URL}${href}`,
                published_at: (),
                page_count: (),
                extra: #{}
            });
        }
    }

    chapters
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;
    if !chapter_id.starts_with("http") {
        url = `${BASE_URL}${chapter_id}`;
    }

    // Reader pages need JS for VRF tokens and image loading
    let html = "";

    // Tier 1: FlareSolverr - bypasses CF and renders JS
    if flaresolverr_is_available() {
        try {
            html = flaresolverr_get(url, 30000);
            if html.len() < 1000 || is_cloudflare_challenge(html) {
                html = "";
            }
        } catch {
            html = "";
        }
    }

    // Tier 2: Browser automation
    if html == "" && browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 15000);
            browser_wait_for_selector(browser_id, "img.page-img, img[src*='mfcdn'], div.reader img, canvas", 15000);
            html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
            html = "";
        }
    }

    // Tier 3: HTTP fallback
    if html == "" {
        try {
            html = http_get_with_headers(url, get_headers());
        } catch {
            return [];
        }
    }

    if html == "" {
        return [];
    }

    let pages = [];
    let idx = 0;
    let seen = #{};

    // Method 1: Extract from rendered img elements
    let page_imgs = html_select(html, "img.page-img, div.reader img, div.read-container img");

    for img in page_imgs {
        let src = element_attr(img, "src");
        if src == () || src == "" {
            src = element_attr(img, "data-src");
        }
        if src == () || src == "" {
            continue;
        }

        // Skip non-page images
        if src.contains("logo") || src.contains("icon") || src.contains("avatar") {
            continue;
        }

        if seen[src] != () {
            continue;
        }
        seen[src] = true;

        pages.push(#{
            index: idx,
            url: src,
            headers: #{
                "Referer": url
            },
            referer: url
        });
        idx += 1;
    }

    // Method 2: Extract from any image URLs matching the CDN pattern
    if pages.len() == 0 {
        let cdn_patterns = regex_find_all("(https?://static\\.mfcdn\\.cc/[^\"'\\s]+\\.(jpg|png|webp))", html);

        for img_url in cdn_patterns {
            // Skip small thumbnails
            if img_url.contains("/thumb/") || img_url.contains("/logo") {
                continue;
            }

            if seen[img_url] != () {
                continue;
            }
            seen[img_url] = true;

            pages.push(#{
                index: idx,
                url: img_url,
                headers: #{
                    "Referer": url
                },
                referer: url
            });
            idx += 1;
        }
    }

    // Method 3: Try extracting from inline JavaScript data
    if pages.len() == 0 {
        // Look for image array in JS
        let img_array = regex_find("images\\s*[=:]\\s*\\[([^\\]]+)\\]", html);
        if img_array != "" {
            let urls = regex_find_all("\"(https?://[^\"]+)\"", img_array);
            for img_url in urls {
                let clean = img_url.replace("\"", "");
                if seen[clean] != () {
                    continue;
                }
                seen[clean] = true;

                pages.push(#{
                    index: idx,
                    url: clean,
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

/// Get latest updates / browse
fn get_latest_updates(page, auth) {
    let url = `${BASE_URL}/filter?language[]=en&sort=recently_updated&page=${page}`;

    // Use HTTP-first since MangaFire filter pages serve full HTML
    let html = fetch_http_first(url);

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let seen = #{};

    // Parse manga cards from the DOM
    // MangaFire uses <div class="unit item-{id}"> for each card
    let items = html_select(html, "div.unit");
    if items.len() == 0 {
        items = html_select(html, "div.original");
    }

    for item in items {
        // Find manga link - in the info section
        let link = element_select_first(item, "div.info a[href*='/manga/']");
        if link == "" {
            link = element_select_first(item, "a[href*='/manga/']");
        }
        if link == "" {
            continue;
        }

        let href = element_attr(link, "href");
        if href == "" {
            continue;
        }

        let manga_id = extract_manga_id(href);
        if manga_id == "" || seen[manga_id] != () {
            continue;
        }
        seen[manga_id] = true;

        // Title - from the info section's direct manga link text
        let title = element_text(link).trim();
        if title == "" {
            // Try the poster's alt text
            let poster_img = element_select_first(item, "a.poster img");
            if poster_img != "" {
                title = element_attr(poster_img, "alt");
                title = title.trim();
            }
        }
        if title == "" {
            // Fallback: derive from slug
            title = manga_id.split(".")[0].replace("-", " ");
        }
        if title == "" {
            continue;
        }

        // Cover image - inside <a class="poster"><div><img src="..."></div></a>
        let cover_url = "";
        let poster_img = element_select_first(item, "a.poster img");
        if poster_img == "" {
            poster_img = element_select_first(item, "img");
        }
        if poster_img != "" {
            cover_url = element_attr(poster_img, "src");
            if cover_url == "" {
                cover_url = element_attr(poster_img, "data-src");
            }
        }

        series.push(#{
            id: manga_id,
            title: title,
            url: `${BASE_URL}/manga/${manga_id}`,
            cover_url: cover_url,
            updated_at: ()
        });
    }

    // Fallback: regex approach if DOM parsing found nothing
    if series.len() == 0 {
        let manga_links = regex_find_all("href=\"(/manga/[^\"]+)\"", html);
        for link_found in manga_links {
            let href = regex_find("/manga/[^\"]+", link_found);
            if href == "" { continue; }

            let manga_id = extract_manga_id(href);
            if manga_id == "" || seen[manga_id] != () { continue; }
            seen[manga_id] = true;

            let title = manga_id.split(".")[0].replace("-", " ");
            if title == "" { continue; }

            series.push(#{
                id: manga_id,
                title: title,
                url: `${BASE_URL}/manga/${manga_id}`,
                cover_url: "",
                updated_at: ()
            });
        }
    }

    let has_more = html.contains(`page=${page + 1}`) && series.len() > 0;

    #{ series: series, has_more: has_more }
}
