// HiveToons Scraper Add-on (Rhai)
// API-based scraper for hivetoons.org (formerly Void Scans)
//
// API Endpoints (api.hivetoons.org/api):
//   GET /query - Search/browse series (returns series data)
//   GET /post/chapters?postId={id} - Get all chapters for a series (flat JSON array)
// Chapter pages:
//   Fetched by scraping HTML from hivetoons.org/series/{slug}/{chapter-slug}
//   Images hosted on storage.hivetoon.com

const BASE_URL = "https://hivetoons.org";
const API_URL = "https://api.hivetoons.org/api";

fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "application/json",
        "Referer": BASE_URL
    }
}

/// Safe API GET — wraps http_get_with_headers in try/catch so a network
/// exception falls through to "" instead of propagating up to the caller.
/// Without this, a single transient blip crashed entire search / browse /
/// get_series / get_chapters calls because the call sites had no guard.
fn api_get(url) {
    try {
        return http_get_with_headers(url, get_headers());
    } catch {
        return "";
    }
}

fn get_source_info() {
    #{
        id: "hivetoons",
        name: "HiveToons",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

/// Search for series by query
fn search_series(query, page, auth) {
    let params = `page=${page}&perPage=20&series_type=Comic&adult=true&order=desc&orderBy=created_at&status=All&tags_ids=[]`;
    if query != "" && query != () {
        params = `page=${page}&perPage=20&series_type=Comic&query_string=${url_encode(query)}&adult=true&order=desc&orderBy=updated_at&status=All&tags_ids=[]`;
    }

    let url = `${API_URL}/query?${params}`;
    let response = api_get(url);

    if response == "" || response == () {
        return #{ series: [], has_more: false, total: 0 };
    }

    let data = json_parse(response);
    if data == () {
        return #{ series: [], has_more: false, total: 0 };
    }

    let items = data["posts"];
    if items == () || items.len() == 0 {
        return #{ series: [], has_more: false, total: 0 };
    }

    let total = 0;
    if data["totalCount"] != () {
        total = data["totalCount"];
    }

    let has_more = (page * 20) < total;

    let series = [];
    for item in items {
        let s = parse_series_from_query(item);
        if s != () {
            series.push(s);
        }
    }

    #{ series: series, has_more: has_more, total: total }
}

/// Browse latest series (no search query)
fn browse(page, category, auth) {
    let order_by = "updated_at";
    if category == "popular" {
        order_by = "totalViews";
    } else if category == "new" {
        order_by = "created_at";
    } else if category == "rating" {
        order_by = "averageRating";
    }

    let params = `page=${page}&perPage=20&series_type=Comic&adult=true&order=desc&orderBy=${order_by}&status=All&tags_ids=[]`;
    let url = `${API_URL}/query?${params}`;
    let response = api_get(url);

    if response == "" || response == () {
        return #{ series: [], has_more: false };
    }

    let data = json_parse(response);
    if data == () {
        return #{ series: [], has_more: false };
    }

    let items = data["posts"];
    if items == () || items.len() == 0 {
        return #{ series: [], has_more: false };
    }

    let total = 0;
    if data["totalCount"] != () {
        total = data["totalCount"];
    }

    let has_more = (page * 20) < total;

    let series = [];
    for item in items {
        let s = parse_series_from_query(item);
        if s != () {
            series.push(s);
        }
    }

    #{ series: series, has_more: has_more }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let slug = id_or_url;

    // Extract slug from URL if needed
    if id_or_url.contains("/series/") {
        let parts = id_or_url.split("/series/");
        if parts.len() > 1 {
            slug = parts[1].split("/")[0].split("?")[0];
        }
    }

    // Query API searching by slug to find the series
    let url = `${API_URL}/query?page=1&perPage=20&series_type=Comic&query_string=${url_encode(slug)}&adult=true&order=desc&orderBy=updated_at&status=All&tags_ids=[]`;
    let response = api_get(url);

    if response == "" || response == () {
        return #{ id: slug, title: "", error: "Failed to fetch series" };
    }

    let data = json_parse(response);
    if data == () {
        return #{ id: slug, title: "", error: "Failed to parse response" };
    }

    let items = data["posts"];
    if items == () || items.len() == 0 {
        return #{ id: slug, title: "", error: "Series not found" };
    }

    // Find the exact match by slug
    let s = ();
    for item in items {
        if item["slug"] == slug {
            s = item;
            break;
        }
    }

    // Fallback: use first result if no exact slug match
    if s == () {
        s = items[0];
    }

    let title = if s["postTitle"] != () { s["postTitle"] } else { "" };
    let description = if s["postContent"] != () { strip_html(s["postContent"]) } else { "" };
    let slug_val = if s["slug"] != () { s["slug"] } else { slug };
    let cover_url = if s["featuredImage"] != () { s["featuredImage"] } else { () };
    let author_val = if s["author"] != () { s["author"] } else { "" };
    let artist_val = if s["artist"] != () { s["artist"] } else { "" };
    let alt_titles_raw = if s["alternativeTitles"] != () { s["alternativeTitles"] } else { "" };
    let rating = if s["averageRating"] != () { s["averageRating"] } else { () };

    // Parse status
    let status_raw = if s["seriesStatus"] != () { s["seriesStatus"] } else { () };
    let status = status_raw;
    if status_raw == "ONGOING" {
        status = "Ongoing";
    } else if status_raw == "COMPLETED" {
        status = "Completed";
    }

    // Parse authors
    let authors = [];
    if author_val != "" {
        authors.push(author_val);
    }

    // Parse artists
    let artists = [];
    if artist_val != "" {
        artists.push(artist_val);
    }

    // Parse alternative titles
    let alternate_titles = [];
    if type_of(alt_titles_raw) == "string" && alt_titles_raw != "" {
        let parts = alt_titles_raw.split(",");
        for p in parts {
            let t = p.trim();
            if t != "" && t != title {
                alternate_titles.push(t);
            }
        }
    } else if type_of(alt_titles_raw) == "array" {
        for t in alt_titles_raw {
            if t != () && t != "" && t != title {
                alternate_titles.push(t);
            }
        }
    }

    // Parse genres
    let genres = [];
    let genres_data = s["genres"];
    if genres_data != () {
        for genre in genres_data {
            if type_of(genre) == "map" {
                let name = genre["name"];
                if name != () && name != "" {
                    genres.push(name);
                }
            } else if type_of(genre) == "string" {
                genres.push(genre);
            }
        }
    }

    // The /api/query result omits the synopsis (postContent is only on the
    // detail record, and the /api/series detail endpoint 404s). Backfill from
    // the series page's og:description, which carries the full synopsis.
    if description == "" {
        let page = api_get(`${BASE_URL}/series/${slug_val}`);
        if page != "" {
            let m = regex_find("og:description\" content=\"[^\"]+", page);
            if m != "" {
                let d = m.replace("og:description\" content=\"", "").trim();
                if d != "" { description = d; }
            }
        }
    }

    #{
        id: slug_val,
        title: title,
        alternate_titles: alternate_titles,
        description: description,
        cover_url: cover_url,
        authors: authors,
        artists: artists,
        status: status,
        genres: genres,
        tags: [],
        year: (),
        content_rating: "suggestive",
        url: `${BASE_URL}/series/${slug_val}`,
        extra: #{
            source_name: "HiveToons",
            auto_match_metadata: true
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let slug = series_id;

    // Extract slug from URL if needed
    if series_id.contains("/series/") {
        let parts = series_id.split("/series/");
        if parts.len() > 1 {
            slug = parts[1].split("/")[0].split("?")[0];
        }
    }

    // Step 1: Query API to find the series and get its numeric id
    let query_url = `${API_URL}/query?page=1&perPage=20&series_type=Comic&query_string=${url_encode(slug)}&adult=true&order=desc&orderBy=updated_at&status=All&tags_ids=[]`;
    let response = api_get(query_url);

    if response == "" || response == () {
        return [];
    }

    let data = json_parse(response);
    if data == () {
        return [];
    }

    let items = data["posts"];
    if items == () || items.len() == 0 {
        return [];
    }

    // Find the exact match by slug
    let series_data = ();
    for item in items {
        if item["slug"] == slug {
            series_data = item;
            break;
        }
    }

    // Fallback: use first result
    if series_data == () {
        series_data = items[0];
    }

    let post_id = series_data["id"];
    if post_id == () {
        return [];
    }

    // Step 2: Fetch chapters from the dedicated chapters endpoint
    let chapters_url = `${API_URL}/post/chapters?postId=${post_id}`;
    let ch_response = api_get(chapters_url);

    if ch_response == "" || ch_response == () {
        return [];
    }

    let chapters_data = json_parse(ch_response);
    if chapters_data == () || chapters_data.len() == 0 {
        return [];
    }

    let chapters = [];

    for ch in chapters_data {
        let ch_number = if ch["number"] != () { ch["number"] } else { "" };
        let ch_title = if ch["title"] != () { ch["title"] } else { "" };
        let ch_slug = if ch["slug"] != () { ch["slug"] } else { "" };
        let ch_created = if ch["createdAt"] != () { ch["createdAt"] } else { () };
        let is_locked = if ch["isLocked"] != () { ch["isLocked"] } else { false };

        // Format chapter number - remove trailing .0
        let number = `${ch_number}`;
        if number.ends_with(".0") {
            number = number.sub_string(0, number.len() - 2);
        }

        // Use slug|chapter_slug as compound ID
        let compound_id = `${slug}|${ch_slug}`;
        let chapter_url = `${BASE_URL}/series/${slug}/${ch_slug}`;

        chapters.push(#{
            id: compound_id,
            series_id: series_id,
            number: number,
            title: ch_title,
            volume: (),
            language: "en",
            scanlator: "HiveToons",
            url: chapter_url,
            published_at: ch_created,
            page_count: (),
            extra: #{
                is_locked: is_locked
            }
        });
    }

    // Sort ascending by chapter number
    chapters.sort(|a, b| {
        let num_a = parse_float(a.number);
        let num_b = parse_float(b.number);
        if num_a < num_b { -1 } else if num_a > num_b { 1 } else { 0 }
    });

    chapters
}

/// Get page image URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    let series_slug = "";
    let chapter_slug = "";

    if chapter_id.contains("|") {
        // Compound ID: series_slug|chapter_slug
        let parts = chapter_id.split("|");
        series_slug = parts[0];
        chapter_slug = parts[1];
    } else if chapter_id.starts_with("http") {
        // Full URL: extract slugs
        let parts = chapter_id.split("/series/");
        if parts.len() > 1 {
            let path = parts[1];
            let segments = path.split("/");
            if segments.len() >= 2 {
                series_slug = segments[0];
                chapter_slug = segments[1].split("?")[0];
            }
        }
    } else {
        return [];
    }

    // Fetch the chapter page HTML
    let url = `${BASE_URL}/series/${series_slug}/${chapter_slug}`;
    let html_headers = #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Referer": BASE_URL
    };

    let html = "";
    try {
        html = http_get_with_headers(url, html_headers);
    } catch {}

    if html == "" || html == () {
        // Fallback: try plain HTTP (no TLS impersonation) for Next.js sites
        try {
            html = http_get_plain(url, html_headers);
        } catch {}
    }

    if html == "" || html == () {
        return [];
    }

    // Extract image URLs from storage.hivetoon.com in the RSC payload / HTML
    // Pattern: https://storage.hivetoon.com/public//upload/series/{slug}/{hash}/{number}.webp
    let matches = regex_find_all("https://storage\\.hivetoon\\.com/[^\"\\s\\\\]+\\.(?:webp|jpg|jpeg|png)", html);

    // Fallback: broader pattern
    if matches.len() == 0 {
        matches = regex_find_all("https://storage\\.hivetoon\\.com[^\"\\s\\\\]+", html);
    }

    // Deduplicate while preserving order
    let seen = #{};
    let pages = [];
    let idx = 0;

    for img_url in matches {
        if img_url == () || img_url == "" {
            continue;
        }

        // Clean up any escaped characters from JSON/RSC payload
        let clean_url = img_url;
        clean_url = clean_url.replace("\\u0026", "&");
        clean_url = clean_url.replace("\\u003d", "=");

        // Skip duplicates
        if seen.contains(clean_url) {
            continue;
        }
        seen[clean_url] = true;

        // Skip non-page images (icons, logos, thumbnails, etc.)
        if clean_url.contains("/icon") || clean_url.contains("/logo") || clean_url.contains("/favicon") {
            continue;
        }

        pages.push(#{
            index: idx,
            url: clean_url,
            headers: #{
                "Referer": BASE_URL
            },
            referer: BASE_URL
        });
        idx += 1;
    }

    pages
}

/// Get latest updates
fn get_latest_updates(page, auth) {
    let result = browse(page, "", auth);

    let series = [];
    for s in result.series {
        series.push(#{
            id: s.id,
            title: s.title,
            url: s.url,
            cover_url: s.cover_url,
            updated_at: ()
        });
    }

    #{ series: series, has_more: result.has_more }
}

/// Parse a series object from the /query API response
fn parse_series_from_query(item) {
    let id = item["id"];
    let title = item["postTitle"];
    let slug = item["slug"];

    if title == () || slug == () {
        return ();
    }

    let description = if item["postContent"] != () { strip_html(item["postContent"]) } else { "" };
    let cover_url = if item["featuredImage"] != () { item["featuredImage"] } else { () };
    let alt_titles_raw = if item["alternativeTitles"] != () { item["alternativeTitles"] } else { "" };
    let author_val = if item["author"] != () { item["author"] } else { "" };
    let artist_val = if item["artist"] != () { item["artist"] } else { "" };

    // Parse status
    let status_raw = if item["seriesStatus"] != () { item["seriesStatus"] } else { () };
    let status = status_raw;
    if status_raw == "ONGOING" {
        status = "Ongoing";
    } else if status_raw == "COMPLETED" {
        status = "Completed";
    }

    // Parse authors
    let authors = [];
    if author_val != "" {
        authors.push(author_val);
    }

    // Parse artists
    let artists = [];
    if artist_val != "" {
        artists.push(artist_val);
    }

    // Alternative titles
    let alternate_titles = [];
    if type_of(alt_titles_raw) == "string" && alt_titles_raw != "" {
        let parts = alt_titles_raw.split(",");
        for p in parts {
            let t = p.trim();
            if t != "" && t != title {
                alternate_titles.push(t);
            }
        }
    } else if type_of(alt_titles_raw) == "array" {
        for t in alt_titles_raw {
            if t != () && t != "" && t != title {
                alternate_titles.push(t);
            }
        }
    }

    // Parse genres
    let genres = [];
    let genres_data = item["genres"];
    if genres_data != () {
        for genre in genres_data {
            if type_of(genre) == "map" {
                let name = genre["name"];
                if name != () && name != "" {
                    genres.push(name);
                }
            } else if type_of(genre) == "string" {
                genres.push(genre);
            }
        }
    }

    // Chapter count from _count
    let chapter_count = ();
    let count_data = item["_count"];
    if count_data != () && count_data["chapters"] != () {
        chapter_count = count_data["chapters"];
    }

    #{
        id: slug,
        title: title,
        url: `${BASE_URL}/series/${slug}`,
        cover_url: cover_url,
        alternate_titles: alternate_titles,
        authors: authors,
        artists: artists,
        status: status,
        genres: genres,
        tags: [],
        description: description,
        extra: #{
            chapter_count: chapter_count
        }
    }
}

/// Strip HTML tags from text
fn strip_html(text) {
    if text == () {
        return "";
    }

    let result = text;
    result = result.replace("<p>", "");
    result = result.replace("</p>", "\n");
    result = result.replace("<br>", "\n");
    result = result.replace("<br/>", "\n");
    result = result.replace("<br />", "\n");
    result = result.replace("&nbsp;", " ");
    result = result.replace("&amp;", "&");
    result = result.replace("&lt;", "<");
    result = result.replace("&gt;", ">");
    result = result.replace("&quot;", "\"");

    loop {
        let start = result.index_of("<");
        if start == () { break; }
        let end = result.index_of(">");
        if end == () { break; }
        if end > start {
            result = result.sub_string(0, start) + result.sub_string(end + 1);
        } else {
            break;
        }
    }

    result.trim()
}

/// Parse float from string (for chapter sorting)
fn parse_float(s) {
    if s == () { return 0.0; }
    let str_val = `${s}`;
    let parts = str_val.split(".");
    let result = 0.0;
    if parts.len() > 0 {
        try {
            result = parse_int(parts[0]);
        } catch {
            return 0.0;
        }
    }
    if parts.len() > 1 {
        try {
            let decimal = parse_int(parts[1]);
            let divisor = 1.0;
            for i in 0..parts[1].len() {
                divisor *= 10.0;
            }
            result += decimal / divisor;
        } catch {}
    }
    result
}
