// MangaKatana Scraper Add-on (Rhai)
// HTTP-only scraper for mangakatana.com
//
// Website: https://mangakatana.com
// Features: Search, Browse, Series Details, Chapters, Page Images
//
// URL Patterns:
//   Search:   /?search={query}&search_by=book_name
//   Browse:   /manga?page={n}
//   Latest:   /latest/page/{n}
//   Series:   /manga/{slug}.{id}
//   Chapter:  /manga/{slug}.{id}/c{number}
//   Cover:    https://mangakatana.com/imgs/cover/...
//   Pages:    https://i1.mangakatana.com/token/{encoded}/{page}.jpg
//
// Series IDs use slug.numeric_id format (e.g., solo-leveling.21708)
// Chapter compound IDs use pipe separator: {slug_id}|c{number}
//
// Available Rhai APIs:
//   http_get(url) -> string
//   http_get_with_headers(url, headers) -> string
//   html_select(html, selector) -> array
//   html_select_first(html, selector) -> string
//   element_text(html) -> string
//   element_attr(html, attr) -> string
//   element_select(html, selector) -> array
//   element_select_first(html, selector) -> string
//   regex_find(pattern, text) -> string
//   regex_find_all(pattern, text) -> array
//   url_encode(text) -> string
//   parse_float(text) -> float

const BASE_URL = "https://mangakatana.com";

// ============================================================================
// Helper Functions
// ============================================================================

/// Build request headers
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Fetch HTML from a URL with error handling
fn fetch_html(url) {
    let html = "";
    try {
        html = http_get_with_headers(url, get_headers());
    } catch {
        try {
            html = http_get(url);
        } catch {
            html = "";
        }
    }
    html
}

/// Strip HTML tags from text (simple approach)
fn strip_html(text) {
    if text == () {
        return "";
    }
    let result = text + "";
    // Remove common HTML tags
    let tag_patterns = regex_find_all("<[^>]+>", result);
    for tag in tag_patterns {
        result = result.replace(tag, "");
    }
    // Decode common HTML entities
    result = result.replace("&amp;", "&");
    result = result.replace("&lt;", "<");
    result = result.replace("&gt;", ">");
    result = result.replace("&quot;", "\"");
    result = result.replace("&#39;", "'");
    result = result.replace("&nbsp;", " ");
    result.trim()
}

/// Extract the slug.id from a MangaKatana manga URL
/// e.g., /manga/solo-leveling.21708 -> solo-leveling.21708
fn extract_slug_id(url) {
    let result = regex_find("/manga/([^/]+)", url);
    if result != "" {
        // Remove the /manga/ prefix
        result = result.replace("/manga/", "");
        // Strip any trailing slash or query
        let qpos = result.index_of("?");
        if qpos >= 0 {
            result = result.sub_string(0, qpos);
        }
        let hpos = result.index_of("#");
        if hpos >= 0 {
            result = result.sub_string(0, hpos);
        }
        return result.trim();
    }
    ""
}

/// Normalize status text
fn normalize_status(text) {
    let lower = text.to_lower().trim();
    if lower.contains("ongoing") {
        return "Ongoing";
    }
    if lower.contains("completed") || lower.contains("finished") {
        return "Completed";
    }
    if lower.contains("hiatus") {
        return "Hiatus";
    }
    if lower.contains("cancelled") || lower.contains("canceled") {
        return "Cancelled";
    }
    ""
}

// ============================================================================
// Addon Interface Functions
// ============================================================================

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "mangakatana",
        name: "MangaKatana",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only",
        nsfw: false,
        content_types: ["manga", "manhwa", "manhua"]
    }
}

/// Search for manga matching a query
fn search_series(query, page, auth) {
    let encoded = url_encode(query);
    let url = `${BASE_URL}/?search=${encoded}&search_by=book_name`;
    if page > 1 {
        url = `${url}&page=${page}`;
    }

    let html = fetch_html(url);
    if html == "" {
        return #{ series: [], has_more: false, total: 0 };
    }

    let series = [];
    let seen = #{};

    // Parse #book_list .item entries
    let items = html_select(html, "#book_list .item");

    for item in items {
        // Title and URL from the heading link
        let title_link = element_select_first(item, "h3 a");
        if title_link == "" {
            // Fallback: try .title a
            title_link = element_select_first(item, ".title a");
        }
        if title_link == "" {
            continue;
        }

        let href = element_attr(title_link, "href");
        if href == "" || href == () {
            continue;
        }

        let title = element_text(title_link).trim();
        if title == "" {
            continue;
        }

        let slug_id = extract_slug_id(href);
        if slug_id == "" {
            continue;
        }

        // Skip duplicates
        if seen[slug_id] != () {
            continue;
        }
        seen[slug_id] = true;

        // Cover image
        let cover_url = "";
        let img = element_select_first(item, "img");
        if img != "" {
            cover_url = element_attr(img, "src");
            if cover_url == () {
                cover_url = "";
            }
        }

        // Status from item text
        let status = "";
        let item_text = element_text(item);
        if item_text != () {
            status = normalize_status(item_text);
        }

        // Genres from genre links
        let genres = [];
        let genre_links = element_select(item, "a[href*=\"/genre/\"]");
        for gl in genre_links {
            let genre = element_text(gl).trim();
            if genre != "" && !genres.contains(genre) {
                genres.push(genre);
            }
        }

        // Build full URL
        let full_url = href;
        if !href.starts_with("http") {
            full_url = `${BASE_URL}${href}`;
        }

        series.push(#{
            id: slug_id,
            title: title,
            alternate_titles: [],
            description: "",
            cover_url: cover_url,
            authors: [],
            artists: [],
            status: status,
            genres: genres,
            tags: [],
            year: (),
            content_rating: "suggestive",
            url: full_url,
            extra: #{
                source_site: "mangakatana",
                auto_match_metadata: true,
                source_name: "MangaKatana"
            }
        });
    }

    // Check for next page
    let has_more = false;
    let next_page = page + 1;
    if html.contains(`page=${next_page}`) {
        has_more = true;
    }

    #{ series: series, has_more: has_more, total: 0 }
}

/// Get detailed series information by slug_id or URL
fn get_series(id_or_url, auth) {
    let slug_id = id_or_url;
    let url = "";

    if id_or_url.starts_with("http") {
        slug_id = extract_slug_id(id_or_url);
        url = id_or_url;
    } else if id_or_url.contains("/manga/") {
        slug_id = extract_slug_id(id_or_url);
        url = `${BASE_URL}${id_or_url}`;
    } else {
        url = `${BASE_URL}/manga/${slug_id}`;
    }

    if slug_id == "" {
        throw `Invalid series ID or URL: ${id_or_url}`;
    }

    let html = fetch_html(url);
    if html == "" {
        throw `Failed to fetch series page: ${url}`;
    }

    // Title from h1
    let title = "";
    let h1_els = html_select(html, "h1");
    if h1_els.len() > 0 {
        title = element_text(h1_els[0]).trim();
    }
    if title == "" {
        title = "Unknown";
    }

    // Cover image from #single_book .cover img
    let cover_url = "";
    let cover_img = html_select_first(html, "#single_book .cover img");
    if cover_img == "" {
        // Broader fallback
        cover_img = html_select_first(html, ".cover img");
    }
    if cover_img != "" {
        cover_url = element_attr(cover_img, "src");
        if cover_url == () {
            cover_url = "";
        }
    }

    // Parse metadata from dl/dt/dd structure
    let alt_titles = [];
    let authors = [];
    let artists = [];
    let genres = [];
    let status = "";
    let description = "";

    // Try to extract dt/dd pairs
    let dt_els = html_select(html, "dt");
    let dd_els = html_select(html, "dd");

    let min_len = dt_els.len();
    if dd_els.len() < min_len {
        min_len = dd_els.len();
    }

    for i in 0..min_len {
        let label = element_text(dt_els[i]).to_lower().trim();
        let value_el = dd_els[i];
        let value_text = element_text(value_el).trim();

        if label.contains("alt name") || label.contains("alternative") {
            // Alt names may be semicolon or comma separated
            let alts = value_text.split(";");
            if alts.len() <= 1 {
                alts = value_text.split(",");
            }
            for alt in alts {
                let cleaned = alt.trim();
                if cleaned != "" && cleaned != title {
                    alt_titles.push(cleaned);
                }
            }
        } else if label.contains("author") && !label.contains("artist") {
            let author_links = element_select(value_el, "a");
            if author_links.len() > 0 {
                for al in author_links {
                    let author = element_text(al).trim();
                    if author != "" && !authors.contains(author) {
                        authors.push(author);
                    }
                }
            } else if value_text != "" {
                authors.push(value_text);
            }
        } else if label.contains("artist") {
            let artist_links = element_select(value_el, "a");
            if artist_links.len() > 0 {
                for al in artist_links {
                    let artist = element_text(al).trim();
                    if artist != "" && !artists.contains(artist) {
                        artists.push(artist);
                    }
                }
            } else if value_text != "" {
                artists.push(value_text);
            }
        } else if label.contains("genre") {
            let genre_links = element_select(value_el, "a");
            for gl in genre_links {
                let genre = element_text(gl).trim();
                if genre != "" && !genres.contains(genre) {
                    genres.push(genre);
                }
            }
        } else if label.contains("status") {
            status = normalize_status(value_text);
        }
    }

    // The live site dropped dt/dd for a div-table: .d-cell-small.value.authors,
    // .value.status, and a .genres list inside #single_book. Fill anything the
    // dt/dd pass missed.
    if authors.len() == 0 {
        let acell = html_select(html, ".value.authors a, .author a");
        for al in acell {
            let a = element_text(al).trim();
            if a != "" && !authors.contains(a) { authors.push(a); }
        }
        if authors.len() == 0 {
            let at = html_select_first(html, ".value.authors");
            if at != "" {
                let a = element_text(at).trim();
                if a != "" && a.to_lower() != "updating" { authors.push(a); }
            }
        }
    }
    if status == "" {
        let scell = html_select_first(html, ".value.status");
        if scell != "" { status = normalize_status(element_text(scell).trim()); }
    }
    if genres.len() == 0 {
        let gels = html_select(html, "#single_book .genres a, .meta .genres a");
        for gl in gels {
            let g = element_text(gl).trim();
            if g != "" && !genres.contains(g) { genres.push(g); }
        }
    }

    // Description from .summary or paragraph tags after metadata
    let summary_el = html_select_first(html, ".summary");
    if summary_el != "" {
        description = element_text(summary_el).trim();
    }
    if description == "" {
        // Try meta description
        let meta_desc = regex_find("name=[\"']description[\"'][^>]*content=[\"']([^\"']+)", html);
        if meta_desc != "" {
            description = regex_find("content=[\"']([^\"']+)", meta_desc);
            description = description.replace("content=\"", "").replace("content='", "").replace("\"", "").replace("'", "").trim();
        }
    }
    description = strip_html(description);

    #{
        id: slug_id,
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
        url: url,
        extra: #{
            source_site: "mangakatana",
            auto_match_metadata: true,
            source_name: "MangaKatana"
        }
    }
}

/// Get chapters for a series
fn get_chapters(series_id, auth) {
    let slug_id = series_id;
    let url = "";

    if series_id.starts_with("http") {
        slug_id = extract_slug_id(series_id);
        url = series_id;
    } else if series_id.contains("/manga/") {
        slug_id = extract_slug_id(series_id);
        url = `${BASE_URL}${series_id}`;
    } else {
        url = `${BASE_URL}/manga/${slug_id}`;
    }

    if slug_id == "" {
        return [];
    }

    let html = fetch_html(url);
    if html == "" {
        return [];
    }

    let chapters = [];
    let seen = #{};

    // Parse chapter rows from .chapters table tbody tr
    let rows = html_select(html, ".chapters table tbody tr");

    // Fallback: try just table rows if the specific selector didn't match
    if rows.len() == 0 {
        rows = html_select(html, ".chapters tr");
    }

    for row in rows {
        // Get the chapter link
        let link = element_select_first(row, "a");
        if link == "" {
            continue;
        }

        let href = element_attr(link, "href");
        if href == "" || href == () {
            continue;
        }

        // Extract chapter number from URL: /manga/{slug}.{id}/c{number}
        let ch_num_match = regex_find("/c([\\d.]+)$", href);
        if ch_num_match == "" {
            ch_num_match = regex_find("/c([\\d.]+)(?:\\?|#|$)", href);
        }
        if ch_num_match == "" {
            continue;
        }

        let ch_num = ch_num_match.replace("/c", "");
        // Strip trailing query/hash fragments
        let qpos = ch_num.index_of("?");
        if qpos >= 0 {
            ch_num = ch_num.sub_string(0, qpos);
        }
        let hpos = ch_num.index_of("#");
        if hpos >= 0 {
            ch_num = ch_num.sub_string(0, hpos);
        }
        ch_num = ch_num.trim();

        if ch_num == "" {
            continue;
        }

        // Skip duplicates
        if seen[ch_num] != () {
            continue;
        }
        seen[ch_num] = true;

        // Chapter title from link text
        let ch_title = element_text(link).trim();
        if ch_title == "" {
            ch_title = `Chapter ${ch_num}`;
        }

        // Date from second td
        let date = "";
        let tds = element_select(row, "td");
        if tds.len() >= 2 {
            date = element_text(tds[1]).trim();
        }

        // Compound chapter ID: slug_id|c{number}
        let chapter_id = `${slug_id}|c${ch_num}`;

        // Build full chapter URL
        let full_url = href;
        if !href.starts_with("http") {
            full_url = `${BASE_URL}${href}`;
        }

        chapters.push(#{
            id: chapter_id,
            series_id: slug_id,
            number: ch_num,
            title: ch_title,
            volume: (),
            language: "en",
            scanlator: "",
            url: full_url,
            published_at: date,
            page_count: 0,
            extra: #{
                slug_id: slug_id,
                chapter_number: ch_num
            }
        });
    }

    // Chapters are listed newest-first on the page; reverse to ascending order
    let reversed = [];
    let idx = chapters.len();
    while idx > 0 {
        idx -= 1;
        reversed.push(chapters[idx]);
    }

    reversed
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    // chapter_id format: {slug_id}|c{number}
    let parts = chapter_id.split("|");
    if parts.len() < 2 {
        return [];
    }

    let slug_id = parts[0];
    let ch_part = parts[1]; // e.g., "c1" or "c10.5"

    // Build chapter URL
    let chapter_url = `${BASE_URL}/manga/${slug_id}/${ch_part}`;

    let html = fetch_html(chapter_url);
    if html == "" {
        return [];
    }

    // Images are in a JavaScript array: var thzq = ["url1", "url2", ...]
    let pages = [];

    // Extract the thzq array from JavaScript
    let array_match = regex_find("var\\s+thzq\\s*=\\s*\\[([^\\]]+)\\]", html);

    if array_match != "" {
        // Get just the array contents (between the brackets)
        let array_content = regex_find("\\[([^\\]]+)\\]", array_match);
        array_content = array_content.replace("[", "").replace("]", "");

        // Extract all quoted URLs from the array
        let url_matches = regex_find_all("'([^']+)'", array_content);
        if url_matches.len() == 0 {
            // Try double quotes
            url_matches = regex_find_all("\"([^\"]+)\"", array_content);
        }

        let idx = 0;
        for url_match in url_matches {
            // Clean the URL - remove surrounding quotes
            let img_url = url_match;
            img_url = img_url.replace("'", "").replace("\"", "").trim();

            if img_url == "" {
                continue;
            }

            // Ensure it's a full URL
            if !img_url.starts_with("http") {
                if img_url.starts_with("//") {
                    img_url = `https:${img_url}`;
                } else {
                    img_url = `https://i1.mangakatana.com/${img_url}`;
                }
            }

            pages.push(#{
                index: idx,
                url: img_url,
                headers: #{
                    "Referer": chapter_url
                },
                referer: chapter_url
            });
            idx += 1;
        }
    }

    // Fallback: try to find img tags in the reader
    if pages.len() == 0 {
        let imgs = html_select(html, "#imgs img");
        if imgs.len() == 0 {
            imgs = html_select(html, ".page img");
        }

        let idx = 0;
        for img in imgs {
            let src = element_attr(img, "data-src");
            if src == "" || src == () {
                src = element_attr(img, "src");
            }
            if src == () {
                src = "";
            }

            if src != "" && (src.contains("mangakatana") || src.contains("i1.")) {
                if !src.starts_with("http") {
                    if src.starts_with("//") {
                        src = `https:${src}`;
                    } else {
                        src = `https://i1.mangakatana.com/${src}`;
                    }
                }

                pages.push(#{
                    index: idx,
                    url: src,
                    headers: #{
                        "Referer": chapter_url
                    },
                    referer: chapter_url
                });
                idx += 1;
            }
        }
    }

    pages
}

/// Get latest updates
fn get_latest_updates(page, auth) {
    let url = `${BASE_URL}/latest/page/${page}`;

    let html = fetch_html(url);
    if html == "" {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let seen = #{};

    // Parse items from the listing
    let items = html_select(html, "#book_list .item");

    for item in items {
        let title_link = element_select_first(item, "h3 a");
        if title_link == "" {
            title_link = element_select_first(item, ".title a");
        }
        if title_link == "" {
            continue;
        }

        let href = element_attr(title_link, "href");
        if href == "" || href == () {
            continue;
        }

        let title = element_text(title_link).trim();
        if title == "" {
            continue;
        }

        let slug_id = extract_slug_id(href);
        if slug_id == "" {
            continue;
        }

        if seen[slug_id] != () {
            continue;
        }
        seen[slug_id] = true;

        let cover_url = "";
        let img = element_select_first(item, "img");
        if img != "" {
            cover_url = element_attr(img, "src");
            if cover_url == () {
                cover_url = "";
            }
        }

        let full_url = href;
        if !href.starts_with("http") {
            full_url = `${BASE_URL}${href}`;
        }

        series.push(#{
            id: slug_id,
            title: title,
            alternate_titles: [],
            description: "",
            cover_url: cover_url,
            authors: [],
            artists: [],
            status: "",
            genres: [],
            tags: [],
            year: (),
            content_rating: "suggestive",
            url: full_url,
            extra: #{
                source_site: "mangakatana",
                auto_match_metadata: true,
                source_name: "MangaKatana"
            }
        });
    }

    // Check for next page
    let has_more = false;
    let next_page = page + 1;
    if html.contains(`/latest/page/${next_page}`) || html.contains(`page=${next_page}`) {
        has_more = true;
    }
    // If we got a reasonable number of results, assume more pages exist
    if !has_more && series.len() >= 15 {
        has_more = true;
    }

    #{ series: series, has_more: has_more }
}

/// Browse manga directory or latest
fn browse(page, category, auth) {
    if category == "latest" || category == "new" || category == "updates" {
        return get_latest_updates(page, auth);
    }

    // Default: browse the manga directory
    let url = `${BASE_URL}/manga/page/${page}`;

    let html = fetch_html(url);
    if html == "" {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let seen = #{};

    let items = html_select(html, "#book_list .item");

    for item in items {
        let title_link = element_select_first(item, "h3 a");
        if title_link == "" {
            title_link = element_select_first(item, ".title a");
        }
        if title_link == "" {
            continue;
        }

        let href = element_attr(title_link, "href");
        if href == "" || href == () {
            continue;
        }

        let title = element_text(title_link).trim();
        if title == "" {
            continue;
        }

        let slug_id = extract_slug_id(href);
        if slug_id == "" {
            continue;
        }

        if seen[slug_id] != () {
            continue;
        }
        seen[slug_id] = true;

        let cover_url = "";
        let img = element_select_first(item, "img");
        if img != "" {
            cover_url = element_attr(img, "src");
            if cover_url == () {
                cover_url = "";
            }
        }

        // Status
        let status = "";
        let item_text = element_text(item);
        if item_text != () {
            status = normalize_status(item_text);
        }

        // Genres
        let genres = [];
        let genre_links = element_select(item, "a[href*=\"/genre/\"]");
        for gl in genre_links {
            let genre = element_text(gl).trim();
            if genre != "" && !genres.contains(genre) {
                genres.push(genre);
            }
        }

        let full_url = href;
        if !href.starts_with("http") {
            full_url = `${BASE_URL}${href}`;
        }

        series.push(#{
            id: slug_id,
            title: title,
            alternate_titles: [],
            description: "",
            cover_url: cover_url,
            authors: [],
            artists: [],
            status: status,
            genres: genres,
            tags: [],
            year: (),
            content_rating: "suggestive",
            url: full_url,
            extra: #{
                source_site: "mangakatana",
                auto_match_metadata: true,
                source_name: "MangaKatana"
            }
        });
    }

    // Check for next page
    let has_more = false;
    let next_page = page + 1;
    if html.contains(`/manga/page/${next_page}`) || html.contains(`page=${next_page}`) {
        has_more = true;
    }
    if !has_more && series.len() >= 15 {
        has_more = true;
    }

    #{ series: series, has_more: has_more }
}
