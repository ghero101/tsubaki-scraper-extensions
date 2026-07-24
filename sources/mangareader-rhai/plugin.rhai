// MangaReader Scraper Add-on (Rhai)
// Scraper for mangareader.to — Cloudflare-protected manga aggregator with scrambled images
//
// Architecture:
//   - All HTML pages are behind Cloudflare — FlareSolverr is the primary fetcher
//   - Chapter list is loaded via AJAX: /ajax/manga/reading-list/{mangaID}?readingBy=chap
//   - Chapter images via AJAX: /ajax/image/list/chap/{readingId}?quality=high
//   - Images may be SCRAMBLED (tiles shuffled) — browser automation extracts descrambled canvases
//
// URL Patterns:
//   Search:     /search?keyword={query}&page={page}
//   Browse:     /filter?sort=latest-updated&page={page}
//   Series:     /{slug}-{id} (e.g., /one-piece-3)
//   Reader:     /read/{slug}-{id}/en/chapter-{num}
//   Chapters:   /ajax/manga/reading-list/{mangaID}?readingBy=chap (AJAX, returns HTML fragment)
//   Pages:      /ajax/image/list/chap/{readingId}?quality=high (AJAX, returns HTML with image URLs)
//
// IDs:
//   Series: the full URL slug including numeric suffix (e.g., "one-piece-3")
//   Chapter: compound "{slug}|{readingId}|{chapterNum}" (pipe-separated)
//   Manga numeric ID: extracted from slug suffix for AJAX endpoints

const BASE_URL = "https://mangareader.to";

// ============================================================================
// Request Helpers
// ============================================================================

fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Check if HTML is a Cloudflare challenge page.
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

/// Primary fetch function — FlareSolverr first (CF blocks HTTP), browser fallback
fn fetch_html(url) {
    // Tier 1: FlareSolverr — primary method for CF-protected pages
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 30000);
            if html.len() > 500 && !is_cloudflare_challenge(html) {
                return html;
            }
        } catch {}
    }

    // Tier 2: Browser automation
    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch_stealth();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 20000);
            browser_wait_for_selector(browser_id, "body", 8000);
            let html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            if html.len() > 500 && !is_cloudflare_challenge(html) {
                return html;
            }
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    // Tier 3: HTTP fallback (unlikely to work with CF, but try)
    try {
        let html = http_get_with_headers(url, get_headers());
        if html.len() > 500 && !is_cloudflare_challenge(html) {
            return html;
        }
    } catch {}

    ""
}

/// Fetch AJAX endpoint — needs Referer header. FlareSolverr handles CF cookies.
fn fetch_ajax(url) {
    // Tier 1: FlareSolverr
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 30000);
            if html.len() > 100 && !is_cloudflare_challenge(html) {
                return html;
            }
        } catch {}
    }

    // Tier 2: Browser
    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch_stealth();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 15000);
            browser_sleep(2000);
            let html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            if html.len() > 100 {
                return html;
            }
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    // Tier 3: HTTP with headers
    try {
        let headers = get_headers();
        headers["X-Requested-With"] = "XMLHttpRequest";
        let html = http_get_with_headers(url, headers);
        if html.len() > 100 {
            return html;
        }
    } catch {}

    ""
}

// ============================================================================
// ID/URL Helpers
// ============================================================================

/// Extract the manga slug from a URL path.
/// /one-piece-3 -> one-piece-3
/// https://mangareader.to/one-piece-3 -> one-piece-3
fn extract_slug(url) {
    // Remove base URL if present
    let path = url;
    if path.starts_with("http") {
        let idx = path.index_of("mangareader.to/");
        if idx >= 0 {
            path = path.sub_string(idx + 15);
        }
    }
    // Remove leading slash
    if path.starts_with("/") {
        path = path.sub_string(1);
    }
    // Remove trailing slashes and query params
    let q_idx = path.index_of("?");
    if q_idx >= 0 {
        path = path.sub_string(0, q_idx);
    }
    let h_idx = path.index_of("#");
    if h_idx >= 0 {
        path = path.sub_string(0, h_idx);
    }
    // Remove trailing slash
    if path.ends_with("/") {
        path = path.sub_string(0, path.len() - 1);
    }
    path
}

/// Extract the numeric manga ID from a slug (last number after last dash).
/// "one-piece-3" -> "3"
/// "solo-leveling-7584" -> "7584"
fn extract_manga_id(slug) {
    let result = regex_find("-(\\d+)$", slug);
    if result != "" {
        return result.replace("-", "");
    }
    // Fallback: try just digits at end
    let num = regex_find("\\d+$", slug);
    if num != "" {
        return num;
    }
    ""
}

/// Map status text to standard format
fn map_status(status) {
    let s = status.to_lower().trim();
    if s.contains("ongoing") || s.contains("publishing") {
        return "Ongoing";
    } else if s.contains("completed") || s.contains("finished") {
        return "Completed";
    } else if s.contains("hiatus") || s.contains("on hold") {
        return "Hiatus";
    } else if s.contains("discontinued") || s.contains("cancelled") || s.contains("canceled") {
        return "Cancelled";
    }
    status
}

// ============================================================================
// Required Interface Functions
// ============================================================================

fn get_source_info() {
    #{
        id: "mangareader",
        name: "MangaReader",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en", "ja", "ko", "zh", "fr"],
        requires_authentication: false,
        capability_level: "browser_automation"
    }
}

/// Search for manga by keyword
fn search_series(query, page, auth) {
    let encoded = url_encode(query);
    let url = `${BASE_URL}/search?keyword=${encoded}&page=${page}`;

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false, total: 0 };
    }

    let series = parse_series_list(html);

    // Check for next page
    let has_more = html.contains(`page=${page + 1}`) || html.contains("page-next");
    if has_more == false && series.len() >= 24 {
        has_more = true;
    }

    #{ series: series, has_more: has_more, total: () }
}

/// Browse latest updates
fn get_latest_updates(page, auth) {
    let url = `${BASE_URL}/filter?sort=latest-updated&page=${page}`;

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let series = parse_series_list(html);

    let has_more = html.contains(`page=${page + 1}`) || html.contains("page-next");
    if has_more == false && series.len() >= 24 {
        has_more = true;
    }

    #{ series: series, has_more: has_more }
}

/// Browse (alias for get_latest_updates)
fn browse(page, filters, auth) {
    get_latest_updates(page, auth)
}

/// Parse series cards from a search/browse results page
fn parse_series_list(html) {
    let series = [];
    let seen = #{};

    // Method 1: DOM-based parsing — .manga_list-sbs .mls-wrap .item
    let items = html_select(html, ".mls-wrap .item");
    if items.len() == 0 {
        items = html_select(html, ".manga_list-sbs .item");
    }
    if items.len() == 0 {
        items = html_select(html, "div.item");
    }

    for item in items {
        // Find the manga link
        let link = element_select_first(item, "h3.manga-name a");
        if link == "" {
            link = element_select_first(item, "a.manga-name");
        }
        if link == "" {
            link = element_select_first(item, "a[href]");
        }
        if link == "" {
            continue;
        }

        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Skip non-manga links
        if href.contains("/filter") || href.contains("/search") || href.contains("/genre") {
            continue;
        }

        let slug = extract_slug(href);
        if slug == "" || slug.contains("/") || seen[slug] != () {
            continue;
        }
        seen[slug] = true;

        // Title
        let title = element_text(link).trim();
        if title == "" {
            title = element_attr(link, "title");
            if title == () { title = ""; }
            title = title.trim();
        }
        if title == "" || title.len() < 2 {
            continue;
        }

        // Cover image
        let cover_url = "";
        let img = element_select_first(item, "img.manga-poster-img");
        if img == "" {
            img = element_select_first(item, "a.manga-poster img");
        }
        if img == "" {
            img = element_select_first(item, "img");
        }
        if img != "" {
            cover_url = element_attr(img, "src");
            if cover_url == () || cover_url == "" {
                cover_url = element_attr(img, "data-src");
            }
            if cover_url == () { cover_url = ""; }
        }

        // Genres
        let genres = [];
        let genre_links = element_select(item, ".fdi-cate a");
        for gl in genre_links {
            let g = element_text(gl).trim();
            if g != "" && !genres.contains(g) {
                genres.push(g);
            }
        }

        series.push(#{
            id: slug,
            title: title,
            url: `${BASE_URL}/${slug}`,
            cover_url: cover_url,
            alternate_titles: [],
            authors: [],
            artists: [],
            status: (),
            genres: genres,
            tags: [],
            description: ()
        });
    }

    // Method 2: Regex fallback if DOM parsing failed
    if series.len() == 0 {
        // Extract manga links and titles from href patterns
        let link_matches = regex_find_all("href=\"(/[a-z0-9][a-z0-9-]+-\\d+)\"", html);
        for link_match in link_matches {
            let href = regex_find("/[a-z0-9][a-z0-9-]+-\\d+", link_match);
            if href == "" {
                continue;
            }

            let slug = extract_slug(href);
            if slug == "" || seen[slug] != () {
                continue;
            }

            // Skip known non-manga paths
            if slug.starts_with("filter") || slug.starts_with("search") || slug.starts_with("genre") || slug.starts_with("type") {
                continue;
            }

            seen[slug] = true;

            // Try to find associated title near this link
            let title = slug;
            // Remove numeric ID suffix and convert dashes to spaces
            let parts = slug.split("-");
            if parts.len() > 1 {
                // Remove the last part (numeric ID)
                let title_parts = [];
                let i = 0;
                while i < parts.len() - 1 {
                    title_parts.push(parts[i]);
                    i += 1;
                }
                title = "";
                for tp in title_parts {
                    if title != "" { title += " "; }
                    if tp.len() > 0 {
                        let first = tp.sub_string(0, 1).to_upper();
                        let rest = if tp.len() > 1 { tp.sub_string(1) } else { "" };
                        title += first + rest;
                    }
                }
            }

            if title == "" || title.len() < 2 {
                continue;
            }

            series.push(#{
                id: slug,
                title: title,
                url: `${BASE_URL}/${slug}`,
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

    series
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let slug = id_or_url;

    if id_or_url.starts_with("http") {
        slug = extract_slug(id_or_url);
    } else if slug.starts_with("/") {
        slug = slug.sub_string(1);
    }

    if slug == "" {
        throw `Invalid series ID: ${id_or_url}`;
    }

    let url = `${BASE_URL}/${slug}`;
    let html = fetch_html(url);

    if html == "" {
        throw `Failed to fetch series page: ${slug}`;
    }

    // Title — h2.manga-name or h1
    let title = "";
    let title_els = html_select(html, "h2.manga-name");
    if title_els.len() == 0 {
        title_els = html_select(html, "h1.manga-name");
    }
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }
    if title == "" {
        // Fallback: og:title
        let og_match = regex_find("og:title[\"']\\s*content=[\"']([^\"']+)", html);
        if og_match != "" {
            title = regex_find("content=[\"']([^\"']+)", og_match);
            title = title.replace("content=\"", "").replace("content='", "").replace("\"", "").replace("'", "").trim();
            // Remove site suffix
            if title.contains(" - MangaReader") {
                let idx = title.index_of(" - MangaReader");
                if idx > 0 {
                    title = title.sub_string(0, idx).trim();
                }
            }
        }
    }
    if title == "" {
        title = slug;
    }

    // Alternate title
    let alt_titles = [];
    let alt_els = html_select(html, "div.manga-name-or");
    if alt_els.len() > 0 {
        let alt = element_text(alt_els[0]).trim();
        if alt != "" && alt != title {
            alt_titles.push(alt);
        }
    }

    // Cover image
    let cover_url = "";
    let cover_els = html_select(html, "img.manga-poster-img");
    if cover_els.len() == 0 {
        cover_els = html_select(html, ".manga-poster img");
    }
    if cover_els.len() > 0 {
        cover_url = element_attr(cover_els[0], "src");
        if cover_url == () || cover_url == "" {
            cover_url = element_attr(cover_els[0], "data-src");
        }
        if cover_url == () { cover_url = ""; }
    }

    // Description
    let description = ();
    let desc_els = html_select(html, ".description");
    if desc_els.len() > 0 {
        description = element_text(desc_els[0]).trim();
    }
    if description == () || description == "" {
        // Fallback: og:description
        let desc_match = regex_find("og:description[\"']\\s*content=[\"']([^\"']+)", html);
        if desc_match != "" {
            description = regex_find("content=[\"']([^\"']+)", desc_match);
            description = description.replace("content=\"", "").replace("content='", "").replace("\"", "").replace("'", "").trim();
        }
    }

    // Status, type, authors — from .anisc-info items
    let status = ();
    let authors = [];
    let artists = [];
    let manga_type = "";

    let info_items = html_select(html, ".anisc-info .item");
    for info_item in info_items {
        let item_text = element_text(info_item);

        // Status
        if item_text.contains("Status") {
            let status_name = element_select_first(info_item, ".name");
            if status_name != "" {
                status = map_status(element_text(status_name).trim());
            }
        }

        // Authors (but not artist label)
        if (item_text.contains("Authors") || item_text.contains("Author")) && !item_text.contains("Artist") {
            let author_links = element_select(info_item, "a");
            for al in author_links {
                let name = element_text(al).trim();
                if name != "" && name != "N/A" && !authors.contains(name) {
                    authors.push(name);
                }
            }
        }

        // Artists
        if item_text.contains("Artists") || item_text.contains("Artist") {
            let artist_links = element_select(info_item, "a");
            for al in artist_links {
                let name = element_text(al).trim();
                if name != "" && name != "N/A" && !artists.contains(name) {
                    artists.push(name);
                }
            }
        }

        // Type
        if item_text.contains("Type") {
            let type_el = element_select_first(info_item, "a");
            if type_el == "" {
                type_el = element_select_first(info_item, ".name");
            }
            if type_el != "" {
                manga_type = element_text(type_el).trim();
            }
        }
    }

    // Genres
    let genres = [];
    let genre_els = html_select(html, ".genres a");
    for ge in genre_els {
        let genre = element_text(ge).trim();
        if genre != "" && !genres.contains(genre) {
            genres.push(genre);
        }
    }

    // Year — try to find in page text
    let year = ();
    let year_match = regex_find("(?i)Published:\\s*(\\d{4})", html);
    if year_match != "" {
        year = regex_find("\\d{4}", year_match);
    }
    if year == () {
        // Try from meta info
        for info_item in info_items {
            let item_text = element_text(info_item);
            if item_text.contains("Published") {
                let y = regex_find("(19|20)\\d{2}", item_text);
                if y != "" {
                    year = y;
                    break;
                }
            }
        }
    }

    // Tags
    let tags = [];
    if manga_type != "" {
        tags.push(manga_type);
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
        tags: tags,
        year: year,
        content_rating: "suggestive",
        url: url,
        extra: #{
            source_name: "MangaReader",
            auto_match_metadata: true,
            manga_id: extract_manga_id(slug)
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let slug = series_id;
    if series_id.starts_with("http") {
        slug = extract_slug(series_id);
    } else if slug.starts_with("/") {
        slug = slug.sub_string(1);
    }

    // Extract numeric manga ID from slug for the AJAX endpoint
    let manga_id = extract_manga_id(slug);

    // If we can't extract the ID from the slug, fetch the series page to find it
    if manga_id == "" {
        let series_html = fetch_html(`${BASE_URL}/${slug}`);
        if series_html != "" {
            // Try to find the manga ID from data attributes or AJAX URLs in the page
            let id_match = regex_find("manga/reading-list/(\\d+)", series_html);
            if id_match != "" {
                manga_id = regex_find("\\d+", id_match);
            }
            if manga_id == "" {
                // Try data-id attribute
                id_match = regex_find("data-id=\"(\\d+)\"", series_html);
                if id_match != "" {
                    manga_id = regex_find("\\d+", id_match);
                }
            }
        }
    }

    if manga_id == "" {
        throw `Could not extract manga ID from: ${slug}`;
    }

    // Fetch chapter list via AJAX endpoint
    let ajax_url = `${BASE_URL}/ajax/manga/reading-list/${manga_id}?readingBy=chap`;
    let ajax_html = fetch_ajax(ajax_url);

    if ajax_html == "" {
        // Fallback: try to get chapters from the series page directly
        return get_chapters_from_page(slug);
    }

    // The AJAX response may be wrapped in JSON with an "html" field
    // or it may be raw HTML. Handle both cases.
    let chapter_html = ajax_html;

    // Check if it's JSON wrapped: {"html":"...","result":true}
    if ajax_html.contains("\"html\"") && ajax_html.contains("\"result\"") {
        // FlareSolverr might wrap JSON in HTML — try to extract
        let pre_start = ajax_html.index_of("<pre");
        if pre_start >= 0 {
            let after_pre = ajax_html.sub_string(pre_start);
            let gt_pos = after_pre.index_of(">");
            if gt_pos >= 0 {
                let content = after_pre.sub_string(gt_pos + 1);
                let end_pos = content.index_of("</pre>");
                if end_pos >= 0 {
                    content = content.sub_string(0, end_pos);
                }
                content = content.trim();
                if content.starts_with("{") {
                    try {
                        let json_data = json_parse(content);
                        if json_data != () {
                            let html_field = json_data["html"];
                            if html_field != () && html_field != "" {
                                chapter_html = html_field;
                            }
                        }
                    } catch {}
                }
            }
        }
        // Also try parsing directly if it looks like JSON
        if chapter_html == ajax_html && ajax_html.trim().starts_with("{") {
            try {
                let json_data = json_parse(ajax_html);
                if json_data != () {
                    let html_field = json_data["html"];
                    if html_field != () && html_field != "" {
                        chapter_html = html_field;
                    }
                }
            } catch {}
        }
    }

    let chapters = [];
    let seen = #{};

    // Parse chapter list items from the HTML fragment
    // Structure: <li data-number="1" data-id="123456"> ... </li>
    let items = html_select(chapter_html, "li[data-number]");
    if items.len() == 0 {
        items = html_select(chapter_html, "li");
    }
    if items.len() == 0 {
        items = html_select(chapter_html, "a[href*='/read/']");
    }

    for item in items {
        let chapter_num = element_attr(item, "data-number");
        if chapter_num == () || chapter_num == "" {
            // Try to extract from link text
            let link = element_select_first(item, "a");
            if link != "" {
                let text = element_text(link).trim();
                chapter_num = regex_find("\\d+\\.?\\d*", text);
            }
            if chapter_num == () || chapter_num == "" {
                continue;
            }
        }

        // Reading ID — used for the image AJAX endpoint
        let reading_id = element_attr(item, "data-id");
        if reading_id == () { reading_id = ""; }

        // If no data-id on the li, look for it in a nested link
        if reading_id == "" {
            let link = element_select_first(item, "a[data-id]");
            if link != "" {
                reading_id = element_attr(link, "data-id");
                if reading_id == () { reading_id = ""; }
            }
        }

        // Chapter title
        let chapter_title = "";
        let title_el = element_select_first(item, "a");
        if title_el != "" {
            chapter_title = element_text(title_el).trim();
        }
        if chapter_title == "" {
            chapter_title = `Chapter ${chapter_num}`;
        }

        // Deduplicate by chapter number
        let dedup_key = `${chapter_num}`;
        if seen[dedup_key] != () {
            continue;
        }
        seen[dedup_key] = true;

        // Build compound chapter ID: slug|readingId|chapterNum
        let chapter_id = `${slug}|${reading_id}|${chapter_num}`;

        // Build reader URL
        let chapter_url = `${BASE_URL}/read/${slug}/en/chapter-${chapter_num}`;

        // Volume
        let volume = ();
        let vol_match = element_attr(item, "data-volume");
        if vol_match != () && vol_match != "" && vol_match != "0" {
            volume = vol_match;
        }

        chapters.push(#{
            id: chapter_id,
            series_id: slug,
            number: chapter_num,
            title: chapter_title,
            volume: volume,
            language: "en",
            scanlator: (),
            url: chapter_url,
            published_at: (),
            page_count: (),
            extra: #{
                reading_id: reading_id,
                manga_id: manga_id
            }
        });
    }

    // Fallback: regex parsing of chapter data
    if chapters.len() == 0 {
        let data_matches = regex_find_all("data-number=\"([^\"]+)\"[^>]*data-id=\"([^\"]+)\"", chapter_html);
        for dm in data_matches {
            let ch_num = regex_find("data-number=\"([^\"]+)\"", dm);
            ch_num = ch_num.replace("data-number=\"", "").replace("\"", "");
            let rd_id = regex_find("data-id=\"([^\"]+)\"", dm);
            rd_id = rd_id.replace("data-id=\"", "").replace("\"", "");

            if ch_num == "" {
                continue;
            }

            let dedup_key = `${ch_num}`;
            if seen[dedup_key] != () {
                continue;
            }
            seen[dedup_key] = true;

            let chapter_id = `${slug}|${rd_id}|${ch_num}`;

            chapters.push(#{
                id: chapter_id,
                series_id: slug,
                number: ch_num,
                title: `Chapter ${ch_num}`,
                volume: (),
                language: "en",
                scanlator: (),
                url: `${BASE_URL}/read/${slug}/en/chapter-${ch_num}`,
                published_at: (),
                page_count: (),
                extra: #{
                    reading_id: rd_id,
                    manga_id: manga_id
                }
            });
        }
    }

    // Sort chapters by number ascending
    chapters.sort(|a, b| {
        let num_a = parse_float(a.number);
        let num_b = parse_float(b.number);
        if num_a < num_b { -1 } else if num_a > num_b { 1 } else { 0 }
    });

    chapters
}

/// Fallback: get chapters from the series page HTML directly
fn get_chapters_from_page(slug) {
    let html = fetch_html(`${BASE_URL}/${slug}`);
    if html == "" {
        return [];
    }

    let chapters = [];
    let seen = #{};
    let manga_id = extract_manga_id(slug);

    // Find chapter links in the page
    let chapter_links = html_select(html, "a[href*='/read/']");

    for link in chapter_links {
        let href = element_attr(link, "href");
        if href == () || href == "" || !href.contains("/read/") {
            continue;
        }

        // Extract chapter number from URL: /read/{slug}/en/chapter-{num}
        let chapter_num = "";
        let num_match = regex_find("chapter-(\\d+\\.?\\d*)", href);
        if num_match != "" {
            chapter_num = regex_find("\\d+\\.?\\d*", num_match);
        }
        if chapter_num == "" {
            continue;
        }

        let dedup_key = `${chapter_num}`;
        if seen[dedup_key] != () {
            continue;
        }
        seen[dedup_key] = true;

        let chapter_title = element_text(link).trim();
        if chapter_title == "" {
            chapter_title = `Chapter ${chapter_num}`;
        }

        let chapter_url = href;
        if !chapter_url.starts_with("http") {
            chapter_url = `${BASE_URL}${href}`;
        }

        // We don't have reading_id from the page, leave it empty
        chapters.push(#{
            id: `${slug}||${chapter_num}`,
            series_id: slug,
            number: chapter_num,
            title: chapter_title,
            volume: (),
            language: "en",
            scanlator: (),
            url: chapter_url,
            published_at: (),
            page_count: (),
            extra: #{
                reading_id: "",
                manga_id: manga_id
            }
        });
    }

    // Sort ascending
    chapters.sort(|a, b| {
        let num_a = parse_float(a.number);
        let num_b = parse_float(b.number);
        if num_a < num_b { -1 } else if num_a > num_b { 1 } else { 0 }
    });

    chapters
}

/// Get page URLs for a chapter.
///
/// Strategy:
///   1. Try AJAX image list endpoint (returns .iv-card data-url attributes)
///   2. If browser available AND images are scrambled, use browser to load reader
///      page, wait for descrambling JS, then extract canvas data URLs
///   3. Fallback: return scrambled image URLs directly (downloadable but shuffled)
fn get_chapter_pages(chapter_id, auth) {
    // Parse compound ID: slug|readingId|chapterNum
    let parts = chapter_id.split("|");
    let slug = "";
    let reading_id = "";
    let chapter_num = "";

    if parts.len() >= 3 {
        slug = parts[0];
        reading_id = parts[1];
        chapter_num = parts[2];
    } else if parts.len() == 2 {
        slug = parts[0];
        reading_id = parts[1];
    } else {
        // Single value — assume it's a URL or slug
        slug = chapter_id;
    }

    // If we have a reading ID, try the AJAX image endpoint first
    let pages = [];

    if reading_id != "" {
        pages = get_pages_from_ajax(reading_id, slug, chapter_num);
    }

    // If AJAX failed or returned no pages, try browser-based extraction
    if pages.len() == 0 && browser_is_available() {
        pages = get_pages_from_browser(slug, chapter_num);
    }

    // If browser extraction also failed, try fetching the reader page via FlareSolverr
    if pages.len() == 0 {
        pages = get_pages_from_reader(slug, chapter_num);
    }

    pages
}

/// Extract image URLs from the AJAX image list endpoint
fn get_pages_from_ajax(reading_id, slug, chapter_num) {
    let ajax_url = `${BASE_URL}/ajax/image/list/chap/${reading_id}?quality=high`;
    let ajax_html = fetch_ajax(ajax_url);

    if ajax_html == "" {
        return [];
    }

    // The response may be JSON wrapped or raw HTML
    let image_html = ajax_html;

    // Check for JSON wrapper
    if ajax_html.contains("\"html\"") {
        // Extract from <pre> wrapper (FlareSolverr)
        let pre_start = ajax_html.index_of("<pre");
        if pre_start >= 0 {
            let after_pre = ajax_html.sub_string(pre_start);
            let gt_pos = after_pre.index_of(">");
            if gt_pos >= 0 {
                let content = after_pre.sub_string(gt_pos + 1);
                let end_pos = content.index_of("</pre>");
                if end_pos >= 0 {
                    content = content.sub_string(0, end_pos);
                }
                content = content.trim();
                if content.starts_with("{") {
                    try {
                        let json_data = json_parse(content);
                        if json_data != () {
                            let html_field = json_data["html"];
                            if html_field != () && html_field != "" {
                                image_html = html_field;
                            }
                        }
                    } catch {}
                }
            }
        }
        // Try direct JSON parse
        if image_html == ajax_html && ajax_html.trim().starts_with("{") {
            try {
                let json_data = json_parse(ajax_html);
                if json_data != () {
                    let html_field = json_data["html"];
                    if html_field != () && html_field != "" {
                        image_html = html_field;
                    }
                }
            } catch {}
        }
    }

    let pages = [];
    let idx = 0;
    let seen = #{};
    let reader_url = `${BASE_URL}/read/${slug}/en/chapter-${chapter_num}`;

    // Parse .iv-card elements with data-url attribute
    let cards = html_select(image_html, ".iv-card");
    if cards.len() == 0 {
        cards = html_select(image_html, "div[data-url]");
    }
    if cards.len() == 0 {
        cards = html_select(image_html, "[data-url]");
    }

    for card in cards {
        let img_url = element_attr(card, "data-url");
        if img_url == () || img_url == "" {
            continue;
        }

        // Clean up URL
        img_url = img_url.trim();
        if !img_url.starts_with("http") {
            if img_url.starts_with("//") {
                img_url = `https:${img_url}`;
            } else if img_url.starts_with("/") {
                img_url = `${BASE_URL}${img_url}`;
            }
        }

        if seen[img_url] != () {
            continue;
        }
        seen[img_url] = true;

        // Check if image is marked as scrambled
        let is_scrambled = false;
        let class_attr = element_attr(card, "class");
        if class_attr != () && class_attr.contains("shuffled") {
            is_scrambled = true;
        }

        pages.push(#{
            index: idx,
            url: img_url,
            headers: #{
                "Referer": reader_url
            },
            referer: reader_url,
            extra: #{
                scrambled: is_scrambled
            }
        });
        idx += 1;
    }

    // Fallback: Extract image URLs via regex
    if pages.len() == 0 {
        let url_matches = regex_find_all("data-url=\"([^\"]+)\"", image_html);
        for url_match in url_matches {
            let img_url = url_match.replace("data-url=\"", "").replace("\"", "").trim();
            if img_url == "" {
                continue;
            }
            if !img_url.starts_with("http") {
                if img_url.starts_with("//") {
                    img_url = `https:${img_url}`;
                } else if img_url.starts_with("/") {
                    img_url = `${BASE_URL}${img_url}`;
                }
            }

            if seen[img_url] != () {
                continue;
            }
            seen[img_url] = true;

            pages.push(#{
                index: idx,
                url: img_url,
                headers: #{
                    "Referer": reader_url
                },
                referer: reader_url
            });
            idx += 1;
        }
    }

    // Second fallback: extract any CDN image URLs
    if pages.len() == 0 {
        let cdn_urls = regex_find_all("(https?://[a-z0-9-]+\\.mreadercdn\\.com/[^\"'\\s]+\\.(jpg|png|webp))", image_html);
        for cdn_url in cdn_urls {
            if cdn_url.contains("logo") || cdn_url.contains("icon") {
                continue;
            }
            if seen[cdn_url] != () {
                continue;
            }
            seen[cdn_url] = true;

            pages.push(#{
                index: idx,
                url: cdn_url,
                headers: #{
                    "Referer": reader_url
                },
                referer: reader_url
            });
            idx += 1;
        }
    }

    pages
}

/// Use browser automation to load the reader page, wait for JS descrambling,
/// and extract the canvas data URLs or rendered image sources.
fn get_pages_from_browser(slug, chapter_num) {
    let reader_url = `${BASE_URL}/read/${slug}/en/chapter-${chapter_num}`;

    let browser_id = ();
    try {
        browser_id = browser_launch_stealth();
        browser_goto(browser_id, reader_url);
        browser_wait_for_cloudflare(browser_id, 20000);

        // Wait for the reader container to load
        try {
            browser_wait_for_selector(browser_id, ".ds-image, .iv-card, canvas, img[src*='mreadercdn']", 15000);
        } catch {
            // If specific selectors fail, give the page more time
            browser_sleep(5000);
        }

        // Give descrambling JS time to process all images
        browser_sleep(5000);

        // Try to extract descrambled images from canvases
        let result = browser_execute_script(browser_id, "
            (function() {
                var urls = [];
                // Method 1: Extract canvas data URLs (descrambled images)
                var canvases = document.querySelectorAll('canvas');
                for (var i = 0; i < canvases.length; i++) {
                    try {
                        var dataUrl = canvases[i].toDataURL('image/png');
                        if (dataUrl && dataUrl.length > 100 && dataUrl !== 'data:,') {
                            urls.push(dataUrl);
                        }
                    } catch(e) {}
                }
                // Method 2: If no canvases, get img sources
                if (urls.length === 0) {
                    var imgs = document.querySelectorAll('.ds-image img, .iv-card img, .reading-content img');
                    for (var i = 0; i < imgs.length; i++) {
                        var src = imgs[i].currentSrc || imgs[i].src;
                        if (src && src.length > 10 && !src.includes('logo') && !src.includes('icon')) {
                            urls.push(src);
                        }
                    }
                }
                // Method 3: Get data-url attributes from .iv-card elements
                if (urls.length === 0) {
                    var cards = document.querySelectorAll('[data-url]');
                    for (var i = 0; i < cards.length; i++) {
                        var url = cards[i].getAttribute('data-url');
                        if (url) urls.push(url);
                    }
                }
                return JSON.stringify(urls);
            })()
        ");

        try { browser_close(browser_id); } catch {}

        if result == "" || result == "[]" {
            return [];
        }

        // Parse the JSON array of URLs
        // Remove surrounding quotes if present (browser_execute_script may return quoted string)
        result = result.trim();
        if result.starts_with("\"") && result.ends_with("\"") {
            result = result.sub_string(1, result.len() - 2);
            // Unescape
            result = result.replace("\\\"", "\"");
        }

        let url_list = [];
        try {
            url_list = json_parse(result);
        } catch {
            return [];
        }

        if url_list == () || type_of(url_list) != "array" || url_list.len() == 0 {
            return [];
        }

        let pages = [];
        let idx = 0;
        for img_url in url_list {
            if img_url == () || img_url == "" {
                continue;
            }
            pages.push(#{
                index: idx,
                url: img_url,
                headers: #{
                    "Referer": reader_url
                },
                referer: reader_url
            });
            idx += 1;
        }

        return pages;
    } catch {
        if browser_id != () { try { browser_close(browser_id); } catch {} }
    }

    []
}

/// Fallback: fetch the reader page via FlareSolverr and extract image URLs
fn get_pages_from_reader(slug, chapter_num) {
    let reader_url = `${BASE_URL}/read/${slug}/en/chapter-${chapter_num}`;
    let html = fetch_html(reader_url);

    if html == "" {
        return [];
    }

    let pages = [];
    let idx = 0;
    let seen = #{};

    // Extract image sources from img tags
    let imgs = html_select(html, ".ds-image img, .reading-content img, .container-reader-chapter img");
    for img in imgs {
        let src = element_attr(img, "src");
        if src == () || src == "" {
            src = element_attr(img, "data-src");
        }
        if src == () || src == "" {
            continue;
        }
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
                "Referer": reader_url
            },
            referer: reader_url
        });
        idx += 1;
    }

    // Regex fallback for CDN images
    if pages.len() == 0 {
        let cdn_urls = regex_find_all("(https?://[a-z0-9-]+\\.mreadercdn\\.com/[^\"'\\s>]+)", html);
        for cdn_url in cdn_urls {
            if cdn_url.contains("logo") || cdn_url.contains("icon") || cdn_url.contains("thumb") {
                continue;
            }
            if seen[cdn_url] != () {
                continue;
            }
            seen[cdn_url] = true;

            pages.push(#{
                index: idx,
                url: cdn_url,
                headers: #{
                    "Referer": reader_url
                },
                referer: reader_url
            });
            idx += 1;
        }
    }

    pages
}
