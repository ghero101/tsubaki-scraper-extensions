// Omega Scans Scraper Add-on (Rhai)
// Pure API-based scraper for omegascans.org
//
// API Endpoints (api.omegascans.org):
//   GET /query         - Search/browse series
//   GET /series/{slug} - Series details
//   GET /chapter/query - List chapters for a series
//   GET /chapter/{series_slug}/{chapter_slug} - Chapter page images

const BASE_URL = "https://omegascans.org";
const API_URL = "https://api.omegascans.org";

fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "application/json",
        "Referer": BASE_URL
    }
}

fn get_source_info() {
    #{
        id: "omegascans",
        name: "Omega Scans",
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
        params = `page=${page}&perPage=20&series_type=Comic&adult=true&order=desc&orderBy=created_at&status=All&tags_ids=[]&query_string=${url_encode(query)}`;
    }

    let url = `${API_URL}/query?${params}`;
    let response = http_get_with_headers(url, get_headers());

    if response == "" || response == () {
        return #{ series: [], has_more: false, total: 0 };
    }

    let data = json_parse(response);
    if data == () {
        return #{ series: [], has_more: false, total: 0 };
    }

    let items = data["data"];
    if items == () || items.len() == 0 {
        return #{ series: [], has_more: false, total: 0 };
    }

    let meta = data["meta"];
    let has_more = false;
    let total = 0;
    if meta != () {
        let current = meta["current_page"];
        let last = meta["last_page"];
        if current != () && last != () {
            has_more = current < last;
        }
        if meta["total"] != () {
            total = meta["total"];
        }
    }

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
        order_by = "total_views";
    } else if category == "new" {
        order_by = "created_at";
    }

    let params = `page=${page}&perPage=20&series_type=Comic&adult=true&order=desc&orderBy=${order_by}&status=All&tags_ids=[]`;
    let url = `${API_URL}/query?${params}`;
    let response = http_get_with_headers(url, get_headers());

    if response == "" || response == () {
        return #{ series: [], has_more: false };
    }

    let data = json_parse(response);
    if data == () {
        return #{ series: [], has_more: false };
    }

    let items = data["data"];
    if items == () || items.len() == 0 {
        return #{ series: [], has_more: false };
    }

    let meta = data["meta"];
    let has_more = false;
    if meta != () {
        let current = meta["current_page"];
        let last = meta["last_page"];
        if current != () && last != () {
            has_more = current < last;
        }
    }

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

    let url = `${API_URL}/series/${slug}`;
    let response = http_get_with_headers(url, get_headers());

    if response == "" || response == () {
        return #{ id: slug, title: "", error: "Failed to fetch series" };
    }

    let s = json_parse(response);
    if s == () {
        return #{ id: slug, title: "", error: "Failed to parse response" };
    }

    let title = if s["title"] != () { s["title"] } else { "" };
    let description = if s["description"] != () { strip_html(s["description"]) } else { "" };
    let status = if s["status"] != () { s["status"] } else { () };
    let author = if s["author"] != () { s["author"] } else { "" };
    let studio = if s["studio"] != () { s["studio"] } else { "" };
    let slug_val = if s["series_slug"] != () { s["series_slug"] } else { slug };
    let thumbnail = if s["thumbnail"] != () { s["thumbnail"] } else { () };
    let alt_names = if s["alternative_names"] != () { s["alternative_names"] } else { "" };
    let release_year = if s["release_year"] != () { s["release_year"] } else { () };

    // Build cover URL
    let cover_url = thumbnail;
    if cover_url != () && cover_url != "" && !cover_url.starts_with("http") {
        cover_url = `${API_URL}/${cover_url}`;
    }

    // Parse authors
    let authors = [];
    if author != "" {
        authors.push(author);
    }

    // Parse artists (studio)
    let artists = [];
    if studio != "" {
        artists.push(studio);
    }

    // Parse alternative titles
    let alternate_titles = [];
    if alt_names != "" {
        let parts = alt_names.split(",");
        for p in parts {
            let t = p.trim();
            if t != "" && t != title {
                alternate_titles.push(t);
            }
        }
    }

    // Parse genres/tags
    let genres = [];
    let tags_data = s["tags"];
    if tags_data != () {
        for tag in tags_data {
            if type_of(tag) == "map" {
                let name = tag["name"];
                if name != () && name != "" {
                    genres.push(name);
                }
            } else if type_of(tag) == "string" {
                genres.push(tag);
            }
        }
    }

    // Parse year
    let year = ();
    if release_year != () && release_year != "" {
        try {
            year = parse_int(release_year);
        } catch {}
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
        year: year,
        content_rating: "nsfw",
        url: `${BASE_URL}/series/${slug_val}`,
        extra: #{
            source_name: "Omega Scans",
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

    // First get the series numeric ID from the series detail endpoint
    let series_url = `${API_URL}/series/${slug}`;
    let series_response = http_get_with_headers(series_url, get_headers());

    if series_response == "" || series_response == () {
        return [];
    }

    let series_data = json_parse(series_response);
    if series_data == () {
        return [];
    }

    let numeric_id = series_data["id"];
    if numeric_id == () {
        return [];
    }

    // Fetch chapters using the numeric series ID
    let chapters = [];
    let page = 1;
    let has_more = true;

    while has_more {
        let url = `${API_URL}/chapter/query?page=${page}&perPage=30&series_id=${numeric_id}`;
        let response = http_get_with_headers(url, get_headers());

        if response == "" || response == () {
            break;
        }

        let data = json_parse(response);
        if data == () {
            break;
        }

        let items = data["data"];
        if items == () || items.len() == 0 {
            break;
        }

        for ch in items {
            let ch_id = ch["id"];
            let ch_name = if ch["chapter_name"] != () { ch["chapter_name"] } else { "" };
            let ch_slug = if ch["chapter_slug"] != () { ch["chapter_slug"] } else { "" };
            let ch_index = if ch["index"] != () { ch["index"] } else { "" };
            let ch_created = if ch["created_at"] != () { ch["created_at"] } else { () };
            let ch_price = if ch["price"] != () { ch["price"] } else { 0 };

            // Extract chapter number from index (e.g., 7.0 -> "7")
            // The API returns index as a number, so convert to string first
            let number = `${ch_index}`;
            if number.ends_with(".0") {
                number = number.sub_string(0, number.len() - 2);
            }

            // Build chapter URL using series slug and chapter slug
            let chapter_url = `${BASE_URL}/series/${slug}/${ch_slug}`;

            // Use series_slug|chapter_slug as compound ID for get_chapter_pages
            let compound_id = `${slug}|${ch_slug}`;

            chapters.push(#{
                id: compound_id,
                series_id: series_id,
                number: number,
                title: ch_name,
                volume: (),
                language: "en",
                scanlator: "Omega Scans",
                url: chapter_url,
                published_at: ch_created,
                page_count: (),
                extra: #{
                    price: ch_price
                }
            });
        }

        // Check pagination
        let meta = data["meta"];
        if meta != () {
            let current = meta["current_page"];
            let last = meta["last_page"];
            if current != () && last != () {
                has_more = current < last;
            } else {
                has_more = false;
            }
        } else {
            has_more = false;
        }

        page += 1;
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
        // Assume it's just a chapter slug with no series context
        return [];
    }

    let url = `${API_URL}/chapter/${series_slug}/${chapter_slug}`;
    let response = http_get_with_headers(url, get_headers());

    if response == "" || response == () {
        return [];
    }

    let data = json_parse(response);
    if data == () {
        return [];
    }

    let chapter = data["chapter"];
    if chapter == () {
        return [];
    }

    let chapter_data = chapter["chapter_data"];
    if chapter_data == () {
        return [];
    }

    let images = chapter_data["images"];
    if images == () || images.len() == 0 {
        return [];
    }

    let pages = [];
    let idx = 0;

    for img_url in images {
        if img_url == () || img_url == "" {
            continue;
        }

        // Ensure absolute URL
        let full_url = img_url;
        if !img_url.starts_with("http") {
            full_url = `${API_URL}/${img_url}`;
        }

        pages.push(#{
            index: idx,
            url: full_url,
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
    let title = item["title"];
    let slug = item["series_slug"];

    if title == () || slug == () {
        return ();
    }

    let description = if item["description"] != () { strip_html(item["description"]) } else { "" };
    let status = if item["status"] != () { item["status"] } else { () };
    let thumbnail = if item["thumbnail"] != () { item["thumbnail"] } else { () };
    let alt_names = if item["alternative_names"] != () { item["alternative_names"] } else { "" };
    let rating = if item["rating"] != () { item["rating"] } else { () };

    // Cover URL
    let cover_url = thumbnail;
    if cover_url != () && cover_url != "" && !cover_url.starts_with("http") {
        cover_url = `${API_URL}/${cover_url}`;
    }

    // Alternative titles
    let alternate_titles = [];
    if alt_names != "" {
        let parts = alt_names.split(",");
        for p in parts {
            let t = p.trim();
            if t != "" && t != title {
                alternate_titles.push(t);
            }
        }
    }

    #{
        id: slug,
        title: title,
        url: `${BASE_URL}/series/${slug}`,
        cover_url: cover_url,
        alternate_titles: alternate_titles,
        authors: [],
        artists: [],
        status: status,
        genres: [],
        tags: [],
        description: description
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
