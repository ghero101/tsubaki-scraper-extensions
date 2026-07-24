// MangaPill Scraper Add-on (Rhai)
// Provides access to MangaPill manga library
//
// Website: https://mangapill.com
// Features: Search, Browse, Chapters, Pages
//
// URL Patterns:
//   Search: /search?q={query}&type=&status=&page={page}
//   Browse: /mangas/new
//   Manga: /manga/{id}/{slug}
//   Chapter: /chapters/{manga_id}-{chapter_id}/{slug}
//   Cover: https://cdn.readdetectiveconan.com/file/mangapill/i/{manga_id}.jpeg
//   Pages: https://cdn.readdetectiveconan.com/file/mangap/{manga_id}/{chapter_id}/{uuid}/{page}.jpeg
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

const BASE_URL = "https://mangapill.com";
const CDN_URL = "https://cdn.readdetectiveconan.com/file";

// --- Helper Functions ---

/// Build headers for requests
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Extract manga ID from URL like /manga/123/slug
fn extract_manga_id(url) {
    let result = regex_find("/manga/(\\d+)", url);
    if result != "" {
        // Extract just the number
        let id = regex_find("\\d+", result);
        return id;
    }
    return "";
}

/// Extract chapter info from URL like /chapters/723-10225000/chainsaw-man-chapter-225
fn extract_chapter_info(url) {
    // Pattern: /chapters/{manga_id}-{chapter_id}/{slug}
    let result = regex_find("/chapters/(\\d+)-(\\d+)", url);
    if result != "" {
        let parts = regex_find_all("\\d+", result);
        if parts.len() >= 2 {
            return #{
                manga_id: parts[0],
                chapter_id: parts[1]
            };
        }
    }
    return #{
        manga_id: "",
        chapter_id: ""
    };
}

/// Extract chapter number from slug like "chainsaw-man-chapter-225"
fn extract_chapter_number(slug) {
    // Try to find chapter number in the slug
    let result = regex_find("chapter-([\\d.]+)", slug);
    if result != "" {
        let num = regex_find("[\\d.]+", result);
        if num != "" {
            return num;
        }
    }
    return "1";
}

/// Build cover URL from manga ID
fn build_cover_url(manga_id) {
    `${CDN_URL}/mangapill/i/${manga_id}.jpeg`
}

/// Parse manga card from search/browse results
fn parse_manga_card(card_html) {
    // Find the link to manga page
    let link = element_select_first(card_html, "a");
    if link == "" {
        return ();
    }

    let href = element_attr(link, "href");
    if href == "" || !href.contains("/manga/") {
        return ();
    }

    let manga_id = extract_manga_id(href);
    if manga_id == "" {
        return ();
    }

    // Get title from link text or alt attribute
    let title = element_text(link);
    if title == "" {
        // Try to get from img alt
        let img = element_select_first(card_html, "img");
        if img != "" {
            title = element_attr(img, "alt");
        }
    }

    // Clean up title
    title = title.trim();
    if title == "" {
        title = "Unknown";
    }

    // Get cover from img data-src or src
    let cover_url = "";
    let img = element_select_first(card_html, "img");
    if img != "" {
        cover_url = element_attr(img, "data-src");
        if cover_url == "" {
            cover_url = element_attr(img, "src");
        }
    }
    if cover_url == "" {
        cover_url = build_cover_url(manga_id);
    }

    // Extract type, status, year if available
    let type_text = "";
    let status = ();
    let year = ();

    // Look for metadata divs. Previous code stored the full div text
    // ("status: publishing") as the status value — UI status filters never
    // matched. Map the substring marker to the canonical Ongoing/Completed/
    // Hiatus / Cancelled set instead.
    let divs = element_select(card_html, "div");
    for div in divs {
        let text = element_text(div).to_lower();
        if text.contains("manga") || text.contains("manhwa") || text.contains("manhua") {
            type_text = text;
        }
        if status == () {
            if text.contains("publishing") || text.contains("ongoing") {
                status = "Ongoing";
            } else if text.contains("finished") || text.contains("completed") {
                status = "Completed";
            } else if text.contains("hiatus") {
                status = "Hiatus";
            } else if text.contains("cancelled") || text.contains("canceled") || text.contains("discontinued") {
                status = "Cancelled";
            }
        }
        // Year is usually 4 digits
        if year == () {
            let year_match = regex_find("(19|20)\\d{2}", text);
            if year_match != "" {
                year = year_match;
            }
        }
    }

    #{
        id: href,
        title: title,
        alternate_titles: [],
        description: "",
        cover_url: cover_url,
        authors: [],
        artists: [],
        status: status,
        genres: [],
        tags: [],
        year: year,
        content_rating: "safe",
        url: `${BASE_URL}${href}`,
        extra: #{
            type: type_text,
            source_site: "mangapill",
            manga_id: manga_id
        }
    }
}

/// Parse full manga details from manga page
fn parse_manga_page(html, manga_id, page_url) {
    // Get title from h1 using regex (more reliable)
    let title = "";
    let title_result = regex_find("<h1[^>]*>([^<]+)</h1>", html);
    if title_result != "" {
        title = regex_find(">([^<]+)<", title_result);
        title = title.replace(">", "").replace("<", "").trim();
    }
    // Fallback to meta og:title
    if title == "" || title == "Unknown" {
        let og_title = regex_find("og:title[\"']\\s*content=[\"']([^\"']+)", html);
        if og_title != "" {
            title = regex_find("content=[\"']([^\"']+)", og_title);
            title = title.replace("content=\"", "").replace("content='", "").replace("\"", "").replace("'", "").trim();
            // Remove " Manga - Mangapill" suffix
            if title.contains(" Manga - ") {
                let idx = title.index_of(" Manga - ");
                if idx > 0 {
                    title = title.sub_string(0, idx);
                }
            }
        }
    }
    if title == "" {
        title = "Unknown";
    }

    // Get description from meta description tag using regex
    let description = "";
    let desc_result = regex_find("name=[\"']description[\"'][^>]*content=[\"']([^\"']+)", html);
    if desc_result != "" {
        description = regex_find("content=[\"']([^\"']+)", desc_result);
        description = description.replace("content=\"", "").replace("content='", "").replace("\"", "").replace("'", "").trim();
    }

    // Get cover image
    let cover_url = build_cover_url(manga_id);
    let cover_result = regex_find("og:image[\"']\\s*content=[\"']([^\"']+)", html);
    if cover_result != "" {
        let img_url = regex_find("content=[\"']([^\"']+)", cover_result);
        img_url = img_url.replace("content=\"", "").replace("content='", "").replace("\"", "").replace("'", "").trim();
        if img_url != "" {
            cover_url = img_url;
        }
    }

    // Extract metadata using regex (Type, Status, Year)
    let type_text = "";
    let status = ();
    let year = ();

    // Type: <label class="text-secondary">Type</label> followed by <div>manga</div>
    let type_result = regex_find(">Type</label>\\s*<div>([^<]+)</div>", html);
    if type_result != "" {
        type_text = regex_find("<div>([^<]+)</div>", type_result);
        type_text = type_text.replace("<div>", "").replace("</div>", "").trim();
    }

    // Status — map MangaPill's "Publishing" / "Finished" / "Hiatus" /
    // "Discontinued" labels to the canonical Ongoing / Completed / Hiatus /
    // Cancelled set the rest of the catalog uses. Previous code passed
    // through the raw label so UI status filters never matched.
    let status_result = regex_find(">Status</label>\\s*<div>([^<]+)</div>", html);
    if status_result != "" {
        let raw_status = regex_find("<div>([^<]+)</div>", status_result);
        raw_status = raw_status.replace("<div>", "").replace("</div>", "").trim();
        let lower = raw_status.to_lower();
        if lower == "publishing" || lower == "ongoing" {
            status = "Ongoing";
        } else if lower == "finished" || lower == "completed" {
            status = "Completed";
        } else if lower == "hiatus" || lower == "on hiatus" {
            status = "Hiatus";
        } else if lower == "discontinued" || lower == "cancelled" || lower == "canceled" {
            status = "Cancelled";
        } else if raw_status != "" {
            status = raw_status;
        }
    }

    // Year
    let year_result = regex_find(">Year</label>\\s*<div>([^<]+)</div>", html);
    if year_result != "" {
        let year_str = regex_find("<div>([^<]+)</div>", year_result);
        year_str = year_str.replace("<div>", "").replace("</div>", "").trim();
        let year_num = regex_find("\\d+", year_str);
        if year_num != "" {
            year = year_num;
        }
    }

    // Extract authors
    let authors = [];
    let author_result = regex_find(">Author</label>\\s*<div>([^<]+)</div>", html);
    if author_result != "" {
        let author_str = regex_find("<div>([^<]+)</div>", author_result);
        author_str = author_str.replace("<div>", "").replace("</div>", "").trim();
        if author_str != "" {
            for a in author_str.split(",") {
                let cleaned = a.trim();
                if cleaned != "" && cleaned != "N/A" && !authors.contains(cleaned) {
                    authors.push(cleaned);
                }
            }
        }
    }

    // Extract artists
    let artists = [];
    let artist_result = regex_find(">Artist</label>\\s*<div>([^<]+)</div>", html);
    if artist_result != "" {
        let artist_str = regex_find("<div>([^<]+)</div>", artist_result);
        artist_str = artist_str.replace("<div>", "").replace("</div>", "").trim();
        if artist_str != "" {
            for a in artist_str.split(",") {
                let cleaned = a.trim();
                if cleaned != "" && cleaned != "N/A" && !artists.contains(cleaned) {
                    artists.push(cleaned);
                }
            }
        }
    }

    // Get genres from links using regex
    let genres = [];
    let genre_results = regex_find_all("href=[\"']/search\\?genre=([^\"']+)[\"'][^>]*>([^<]+)<", html);
    for genre_result in genre_results {
        let genre = regex_find(">([^<]+)<", genre_result);
        genre = genre.replace(">", "").replace("<", "").trim();
        if genre != "" && !genres.contains(genre) {
            genres.push(genre);
        }
    }

    // Extract URL path for use as ID (e.g., /manga/33/slug-name)
    let url_path = regex_find("/manga/\\d+/[^\"?#]+", page_url);
    if url_path == "" {
        url_path = `/manga/${manga_id}`;
    }

    #{
        id: url_path,
        title: title,
        alternate_titles: [],
        description: description,
        cover_url: cover_url,
        authors: authors,
        artists: artists,
        status: status,
        genres: genres,
        tags: [],
        year: year,
        content_rating: "safe",
        url: page_url,
        extra: #{
            type: type_text,
            source_site: "mangapill",
            manga_id: manga_id,
            auto_match_metadata: true,
            source_name: "MangaPill"
        }
    }
}

// --- Addon Interface Functions ---

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "mangapill-rhai",
        name: "MangaPill",
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
    let search_query = url_encode(query);
    let url = `${BASE_URL}/search?q=${search_query}&type=&status=&page=${page}`;

    let headers = get_headers();

    let response_text = "";
    try {
        response_text = http_get_with_headers(url, headers);
    } catch {
        response_text = http_get(url);
    }

    if response_text == "" {
        return #{ series: [], has_more: false, total: 0 };
    }

    // Parse manga cards from results using regex for better extraction
    let series = [];
    let seen_ids = #{};

    // Find all manga entries with their cover URLs (including hash)
    // Pattern: href="/manga/{id}/{slug}" ... data-src="{cover_url_with_hash}"
    let manga_patterns = regex_find_all("href=\"(/manga/(\\d+)/[^\"]+)\"[^>]*>[\\s\\S]*?data-src=\"([^\"]+)\"[\\s\\S]*?font-black[^>]*>([^<]+)<", response_text);

    for pattern in manga_patterns {
        // Extract components using regex
        let href = regex_find("/manga/\\d+/[^\"]+", pattern);
        let manga_id = extract_manga_id(href);

        if manga_id == "" {
            continue;
        }

        // Skip duplicates
        if seen_ids[manga_id] != () {
            continue;
        }
        seen_ids[manga_id] = true;

        // Extract cover URL with hash
        let cover_url = regex_find("https://cdn[^\"]+", pattern);
        if cover_url == "" {
            cover_url = build_cover_url(manga_id);
        }

        // Extract title from font-black div
        let title = regex_find("font-black[^>]*>([^<]+)<", pattern);
        title = regex_find(">([^<]+)<", title);
        title = title.replace(">", "").replace("<", "").trim();

        if title == "" || title.len() < 2 {
            continue;
        }

        series.push(#{
            id: href,
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
            content_rating: "safe",
            url: `${BASE_URL}${href}`,
            extra: #{
                source_site: "mangapill",
                manga_id: manga_id
            }
        });
    }

    // Check for next page link
    let has_more = response_text.contains(`page=${page + 1}`);

    #{ series: series, has_more: has_more, total: 0 }
}

/// Get detailed manga information by ID or URL
fn get_series(id_or_url, auth) {
    let manga_id = id_or_url;
    let url = "";

    // Check if full URL was provided
    if id_or_url.contains("mangapill.com") {
        // Full URL - extract ID and use URL as-is
        manga_id = extract_manga_id(id_or_url);
        if id_or_url.starts_with("http") {
            url = id_or_url;
        } else {
            url = `${BASE_URL}${id_or_url}`;
        }
    } else if id_or_url.contains("/manga/") {
        // Relative URL path
        manga_id = extract_manga_id(id_or_url);
        url = `${BASE_URL}${id_or_url}`;
    } else {
        // Just ID - need to find the slug from various sources
        let headers = get_headers();

        // Method 1: Check recent chapters page for manga URL
        for page in 1..10 {
            let chapters_html = "";
            try {
                chapters_html = http_get_with_headers(`${BASE_URL}/chapters?page=${page}`, headers);
            } catch {
                chapters_html = http_get(`${BASE_URL}/chapters?page=${page}`);
            }

            if chapters_html != "" {
                // Look for manga link with this ID
                let manga_pattern = "href=\"(/manga/" + manga_id + "/[^\"]+)\"";
                let manga_result = regex_find(manga_pattern, chapters_html);
                if manga_result != "" {
                    let href = regex_find("/manga/[^\"]+", manga_result);
                    url = `${BASE_URL}${href}`;
                    break;
                }
            }

            // Stop if no more pages
            if !chapters_html.contains(`page=${page + 1}`) {
                break;
            }
        }

        // Method 2: Check latest manga pages
        if url == "" {
            for page in 1..5 {
                let latest_html = "";
                try {
                    latest_html = http_get_with_headers(`${BASE_URL}/mangas/new?page=${page}`, headers);
                } catch {
                    latest_html = http_get(`${BASE_URL}/mangas/new?page=${page}`);
                }

                if latest_html != "" {
                    let manga_pattern = "href=\"(/manga/" + manga_id + "/[^\"]+)\"";
                    let manga_result = regex_find(manga_pattern, latest_html);
                    if manga_result != "" {
                        let href = regex_find("/manga/[^\"]+", manga_result);
                        url = `${BASE_URL}${href}`;
                        break;
                    }
                }

                if !latest_html.contains(`page=${page + 1}`) {
                    break;
                }
            }
        }
    }

    if manga_id == "" {
        throw `Invalid manga ID or URL: ${id_or_url}`;
    }

    if url == "" {
        throw `Could not find manga URL for ID: ${manga_id}. The manga may not be in recent updates. Please provide full URL.`;
    }

    let headers = get_headers();

    let response_text = "";
    try {
        response_text = http_get_with_headers(url, headers);
    } catch {
        response_text = http_get(url);
    }

    if response_text == "" {
        throw `Failed to fetch manga from: ${url}`;
    }

    // Check for error page
    if response_text.contains("Page not found") || response_text.contains("405 Not Allowed") {
        throw `Manga not found at: ${url}`;
    }

    parse_manga_page(response_text, manga_id, url)
}

/// Get chapters for a manga
fn get_chapters(series_id, auth) {
    let url = "";
    let headers = get_headers();

    // Check if full URL was provided
    if series_id.contains("mangapill.com") {
        if series_id.starts_with("http") {
            url = series_id;
        } else {
            url = `${BASE_URL}${series_id}`;
        }
    } else if series_id.contains("/manga/") {
        url = `${BASE_URL}${series_id}`;
    } else {
        // Just ID - find the slug from chapters/latest pages
        for page in 1..10 {
            let chapters_html = "";
            try {
                chapters_html = http_get_with_headers(`${BASE_URL}/chapters?page=${page}`, headers);
            } catch {
                chapters_html = http_get(`${BASE_URL}/chapters?page=${page}`);
            }

            if chapters_html != "" {
                let manga_pattern = "href=\"(/manga/" + series_id + "/[^\"]+)\"";
                let manga_result = regex_find(manga_pattern, chapters_html);
                if manga_result != "" {
                    let href = regex_find("/manga/[^\"]+", manga_result);
                    url = `${BASE_URL}${href}`;
                    break;
                }
            }

            if !chapters_html.contains(`page=${page + 1}`) {
                break;
            }
        }

        // Try latest manga pages
        if url == "" {
            for page in 1..5 {
                let latest_html = "";
                try {
                    latest_html = http_get_with_headers(`${BASE_URL}/mangas/new?page=${page}`, headers);
                } catch {
                    latest_html = http_get(`${BASE_URL}/mangas/new?page=${page}`);
                }

                if latest_html != "" {
                    let manga_pattern = "href=\"(/manga/" + series_id + "/[^\"]+)\"";
                    let manga_result = regex_find(manga_pattern, latest_html);
                    if manga_result != "" {
                        let href = regex_find("/manga/[^\"]+", manga_result);
                        url = `${BASE_URL}${href}`;
                        break;
                    }
                }

                if !latest_html.contains(`page=${page + 1}`) {
                    break;
                }
            }
        }
    }

    if url == "" {
        return [];
    }

    let response_text = "";
    try {
        response_text = http_get_with_headers(url, headers);
    } catch {
        response_text = http_get(url);
    }

    if response_text == "" {
        return [];
    }

    // Find all chapter links
    let chapter_links = html_select(response_text, "a[href*=\"/chapters/\"]");

    let chapters = [];
    let seen_chapters = #{};

    for link in chapter_links {
        let href = element_attr(link, "href");
        if href == "" {
            continue;
        }

        let info = extract_chapter_info(href);
        if info.chapter_id == "" {
            continue;
        }

        // Skip duplicates
        if seen_chapters[info.chapter_id] != () {
            continue;
        }
        seen_chapters[info.chapter_id] = true;

        // Get chapter number from URL slug
        let chapter_num = extract_chapter_number(href);

        // Get title from link text
        let title = element_text(link).trim();
        if title == "" {
            title = `Chapter ${chapter_num}`;
        }

        chapters.push(#{
            id: `${info.manga_id}-${info.chapter_id}`,
            series_id: series_id,
            number: chapter_num,
            title: title,
            volume: (),
            language: "en",
            scanlator: "",
            url: `${BASE_URL}${href}`,
            published_at: (),
            page_count: 0,
            extra: #{
                manga_id: info.manga_id,
                chapter_id: info.chapter_id
            }
        });
    }

    // Sort by chapter number (descending - newest first)
    // Note: Rhai doesn't have built-in sort, so chapters come in page order

    chapters
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    // chapter_id format: {manga_id}-{chapter_id}
    let parts = chapter_id.split("-");
    if parts.len() < 2 {
        return [];
    }

    let manga_id = parts[0];
    let ch_id = parts[1];
    let full_ch_id = `${manga_id}-${ch_id}`;

    let headers = get_headers();
    let chapter_url = "";
    let manga_url = "";

    // Method 0 (primary, reliable): resolve the manga page directly by id.
    // `/manga/{manga_id}` 301-redirects to the slug URL and lists EVERY chapter
    // with its full /chapters/{id}/{slug} href — so this works for old chapters
    // too. The recent-/chapters and /mangas/new crawls below only surface
    // recently-updated series, which is why old/popular chapters (e.g. One Piece
    // ch.1) used to return 0 pages. NOTE: http_get_with_headers does NOT follow
    // redirects — the id-only URL returns a tiny "Moved Permanently" stub
    // (`<a href="/manga/2/one-piece">…</a>`), so we extract the canonical href
    // and refetch it.
    {
        let direct_html = "";
        try {
            direct_html = http_get_with_headers(`${BASE_URL}/manga/${manga_id}`, headers);
        } catch {
            direct_html = http_get(`${BASE_URL}/manga/${manga_id}`);
        }
        // Follow the 301 to the slug URL manually if we got the redirect stub.
        if direct_html.contains("Moved Permanently") || direct_html.len() < 256 {
            let loc = regex_find("/manga/" + manga_id + "/[^\"]+", direct_html);
            if loc != "" {
                manga_url = `${BASE_URL}${loc}`;
                try {
                    direct_html = http_get_with_headers(manga_url, headers);
                } catch {
                    direct_html = http_get(manga_url);
                }
            }
        }
        if direct_html != "" {
            let chapter_pattern = "href=\"(/chapters/" + full_ch_id + "/[^\"]+)\"";
            let chapter_result = regex_find(chapter_pattern, direct_html);
            if chapter_result != "" {
                let href = regex_find("/chapters/[^\"]+", chapter_result);
                chapter_url = `${BASE_URL}${href}`;
            }
        }
    }

    // Primary Method: Get the manga page and find the chapter URL from there
    // This is the most reliable method since all chapters are listed on the manga page

    // First, find the manga page URL (need slug)
    // Method A: Check recent chapters for manga URL
    let chapters_html = "";
    try {
        chapters_html = http_get_with_headers(`${BASE_URL}/chapters`, headers);
    } catch {
        chapters_html = http_get(`${BASE_URL}/chapters`);
    }

    if chapters_html != "" {
        // Look for the chapter URL directly
        let chapter_pattern = "href=\"(/chapters/" + full_ch_id + "/[^\"]+)\"";
        let chapter_result = regex_find(chapter_pattern, chapters_html);
        if chapter_result != "" {
            let href = regex_find("/chapters/[^\"]+", chapter_result);
            chapter_url = `${BASE_URL}${href}`;
        }

        // Also look for manga URL
        if chapter_url == "" {
            let manga_pattern = "href=\"(/manga/" + manga_id + "/[^\"]+)\"";
            let manga_result = regex_find(manga_pattern, chapters_html);
            if manga_result != "" {
                let href = regex_find("/manga/[^\"]+", manga_result);
                manga_url = `${BASE_URL}${href}`;
            }
        }
    }

    // Method B: Check more pages of recent chapters
    if chapter_url == "" {
        for page in 2..8 {
            let page_html = "";
            try {
                page_html = http_get_with_headers(`${BASE_URL}/chapters?page=${page}`, headers);
            } catch {
                page_html = http_get(`${BASE_URL}/chapters?page=${page}`);
            }
            if page_html != "" {
                // Look for chapter URL
                let chapter_pattern = "href=\"(/chapters/" + full_ch_id + "/[^\"]+)\"";
                let chapter_result = regex_find(chapter_pattern, page_html);
                if chapter_result != "" {
                    let href = regex_find("/chapters/[^\"]+", chapter_result);
                    chapter_url = `${BASE_URL}${href}`;
                    break;
                }

                // Also look for manga URL if not found yet
                if manga_url == "" {
                    let manga_pattern = "href=\"(/manga/" + manga_id + "/[^\"]+)\"";
                    let manga_result = regex_find(manga_pattern, page_html);
                    if manga_result != "" {
                        let href = regex_find("/manga/[^\"]+", manga_result);
                        manga_url = `${BASE_URL}${href}`;
                    }
                }
            }

            // Stop if no more pages
            if !page_html.contains(`page=${page + 1}`) {
                break;
            }
        }
    }

    // Method C: Check latest manga pages for the manga URL
    if chapter_url == "" && manga_url == "" {
        for page in 1..5 {
            let latest_html = "";
            try {
                latest_html = http_get_with_headers(`${BASE_URL}/mangas/new?page=${page}`, headers);
            } catch {
                latest_html = http_get(`${BASE_URL}/mangas/new?page=${page}`);
            }
            if latest_html != "" {
                let manga_pattern = "href=\"(/manga/" + manga_id + "/[^\"]+)\"";
                let manga_result = regex_find(manga_pattern, latest_html);
                if manga_result != "" {
                    let href = regex_find("/manga/[^\"]+", manga_result);
                    manga_url = `${BASE_URL}${href}`;
                    break;
                }
            }
            if !latest_html.contains(`page=${page + 1}`) {
                break;
            }
        }
    }

    // Method D: If we found manga URL but not chapter URL, fetch manga page to get chapter list
    if chapter_url == "" && manga_url != "" {
        let manga_html = "";
        try {
            manga_html = http_get_with_headers(manga_url, headers);
        } catch {
            manga_html = http_get(manga_url);
        }

        if manga_html != "" {
            // Find the chapter URL in the manga page
            let chapter_pattern = "href=\"(/chapters/" + full_ch_id + "/[^\"]+)\"";
            let chapter_result = regex_find(chapter_pattern, manga_html);
            if chapter_result != "" {
                let href = regex_find("/chapters/[^\"]+", chapter_result);
                chapter_url = `${BASE_URL}${href}`;
            }
        }
    }

    // Method E: Try to construct URL from manga slug if we have manga_url
    if chapter_url == "" && manga_url != "" {
        // Extract slug from manga URL like /manga/9415/maryoku-kare-no-dark-elf
        let slug = regex_find("/manga/\\d+/([^\"?]+)", manga_url);
        if slug != "" {
            slug = regex_find("[^/]+$", slug);
            // Get chapter number from chapter_id
            let ch_num = regex_find("\\d+$", ch_id);
            if ch_num.len() > 3 {
                ch_num = ch_num.sub_string(ch_num.len() - 3, 3);
                while ch_num.starts_with("0") && ch_num.len() > 1 {
                    ch_num = ch_num.sub_string(1);
                }
            }
            chapter_url = `${BASE_URL}/chapters/${full_ch_id}/${slug}-chapter-${ch_num}`;
        }
    }

    // Fallback: Try search for the manga
    if chapter_url == "" {
        // Search for manga by ID in the /search endpoint
        // Note: This is a last resort since we don't know the manga name
        // Just return empty - user needs to use proper chapter URL
        return [];
    }

    // Fetch the chapter page
    let response_text = "";
    try {
        response_text = http_get_with_headers(chapter_url, headers);
    } catch {
        response_text = http_get(chapter_url);
    }

    if response_text == "" {
        return [];
    }

    // Check for error page
    if response_text.contains("Page not found") || response_text.contains("405 Not Allowed") {
        return [];
    }

    // Find all page images using regex (more reliable)
    let pages = [];
    let image_matches = regex_find_all("img[^>]*class=\"js-page\"[^>]*data-src=\"([^\"]+)\"", response_text);

    let i = 0;
    for img_result in image_matches {
        let src = regex_find("data-src=\"([^\"]+)\"", img_result);
        src = src.replace("data-src=\"", "").replace("\"", "").trim();

        if src != "" && (src.contains("cdn.") || src.contains("mangap")) {
            // Extract width and height if available
            let width = "";
            let height = "";
            let width_result = regex_find("width=\"([^\"]+)\"", img_result);
            if width_result != "" {
                width = width_result.replace("width=\"", "").replace("\"", "").trim();
            }
            let height_result = regex_find("height=\"([^\"]+)\"", img_result);
            if height_result != "" {
                height = height_result.replace("height=\"", "").replace("\"", "").trim();
            }

            pages.push(#{
                index: i,
                url: src,
                headers: #{
                    "Referer": chapter_url
                },
                referer: chapter_url,
                width: width,
                height: height
            });

            i += 1;
        }
    }

    pages
}

/// Get latest/new manga updates
/// Uses search endpoint with type filter for proper pagination
/// Note: /mangas/new ignores page parameter (broken pagination)
fn get_latest_updates(page, auth) {
    // Use search with type=manga filter - this has working pagination
    // The /mangas/new endpoint ignores page parameter and always returns same results
    let url = `${BASE_URL}/search?type=manga&page=${page}`;

    let headers = get_headers();

    let response_text = "";
    try {
        response_text = http_get_with_headers(url, headers);
    } catch {
        response_text = http_get(url);
    }

    if response_text == "" {
        return #{ series: [], has_more: false };
    }

    // Parse manga cards using regex for better extraction (same as search)
    let series = [];
    let seen_ids = #{};

    // Find all manga entries with their cover URLs (including hash)
    let manga_patterns = regex_find_all("href=\"(/manga/(\\d+)/[^\"]+)\"[^>]*>[\\s\\S]*?data-src=\"([^\"]+)\"[\\s\\S]*?font-black[^>]*>([^<]+)<", response_text);

    for pattern in manga_patterns {
        // Extract components using regex
        let href = regex_find("/manga/\\d+/[^\"]+", pattern);
        let manga_id = extract_manga_id(href);

        if manga_id == "" {
            continue;
        }

        // Skip duplicates
        if seen_ids[manga_id] != () {
            continue;
        }
        seen_ids[manga_id] = true;

        // Extract cover URL with hash
        let cover_url = regex_find("https://cdn[^\"]+", pattern);
        if cover_url == "" {
            cover_url = build_cover_url(manga_id);
        }

        // Extract title from font-black div
        let title = regex_find("font-black[^>]*>([^<]+)<", pattern);
        title = regex_find(">([^<]+)<", title);
        title = title.replace(">", "").replace("<", "").trim();

        if title == "" || title.len() < 2 {
            continue;
        }

        series.push(#{
            id: href,
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
            content_rating: "safe",
            url: `${BASE_URL}${href}`,
            extra: #{
                source_site: "mangapill",
                manga_id: manga_id
            }
        });
    }

    // Check for next page - MangaPill uses pagination links with page parameter
    // Look for multiple patterns to ensure we catch the pagination
    let next_page = page + 1;
    let next_page_str = `${next_page}`;
    let has_more = response_text.contains(`page=${next_page_str}`) ||
                   response_text.contains(`page=${next_page}`) ||
                   response_text.contains(`?page=${next_page_str}`) ||
                   response_text.contains(`&page=${next_page_str}`);

    // Also check if we got a reasonable number of results (MangaPill typically shows 30-50 per page)
    // If we got results, assume there might be more
    if !has_more && series.len() >= 20 {
        has_more = true;
    }

    #{ series: series, has_more: has_more }
}

/// Browse popular/trending (same as latest for MangaPill)
fn browse(page, category, auth) {
    if category == "latest" || category == "new" {
        return get_latest_updates(page, auth);
    }

    // Default to recent chapters
    let url = `${BASE_URL}/chapters?page=${page}`;

    let headers = get_headers();

    let response_text = "";
    try {
        response_text = http_get_with_headers(url, headers);
    } catch {
        response_text = http_get(url);
    }

    if response_text == "" {
        return #{ series: [], has_more: false };
    }

    // Parse recent chapters - extract manga info with covers
    let series = [];
    let seen_ids = #{};

    // Pattern to extract chapter info with cover and manga details
    // Chapters page has: /chapters/{id}-{ch_id}/{slug} ... data-src="{cover}" ... /manga/{id}/{slug} ... font-bold>{title}
    let chapter_patterns = regex_find_all("href=\"/chapters/(\\d+)-\\d+/[^\"]+\"[\\s\\S]*?data-src=\"([^\"]+)\"[\\s\\S]*?href=\"(/manga/\\d+/[^\"]+)\"[\\s\\S]*?font-bold[^>]*>([^<]+)<", response_text);

    for pattern in chapter_patterns {
        // Extract manga ID
        let manga_id = regex_find("/chapters/(\\d+)-", pattern);
        manga_id = regex_find("\\d+", manga_id);

        if manga_id == "" {
            continue;
        }

        // Skip duplicates
        if seen_ids[manga_id] != () {
            continue;
        }
        seen_ids[manga_id] = true;

        // Extract manga URL with slug
        let manga_url = regex_find("/manga/\\d+/[^\"]+", pattern);

        // Extract cover URL
        let cover_url = regex_find("https://cdn[^\"]+", pattern);
        if cover_url == "" {
            cover_url = build_cover_url(manga_id);
        }

        // Extract title
        let title = regex_find("font-bold[^>]*>([^<]+)<", pattern);
        title = regex_find(">([^<]+)<", title);
        title = title.replace(">", "").replace("<", "").trim();

        if title == "" || title.len() < 2 {
            continue;
        }

        series.push(#{
            id: manga_url,
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
            content_rating: "safe",
            url: `${BASE_URL}${manga_url}`,
            extra: #{
                source_site: "mangapill",
                manga_id: manga_id
            }
        });
    }

    // Check for next page - MangaPill uses pagination links with page parameter
    // Look for multiple patterns to ensure we catch the pagination
    let next_page = page + 1;
    let next_page_str = `${next_page}`;
    let has_more = response_text.contains(`page=${next_page_str}`) ||
                   response_text.contains(`page=${next_page}`) ||
                   response_text.contains(`?page=${next_page_str}`) ||
                   response_text.contains(`&page=${next_page_str}`);

    // Also check if we got a reasonable number of results
    // If we got results, assume there might be more
    if !has_more && series.len() >= 20 {
        has_more = true;
    }

    #{ series: series, has_more: has_more }
}
