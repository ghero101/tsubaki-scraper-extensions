// HeanCMS Framework Parser Add-on (Rhai)
// Generic parser for HeanCMS-based manga/manhwa sites
// Supports sites like OmegaScans, ReaperScans, QuantumScans, etc.
//
// Available APIs:
//   HTTP: http_get(url), http_get_with_headers(url, headers), http_post_json(url, body, headers)
//   JSON: json_parse(text), json_stringify(obj)
//   Settings: get_setting(key), set_setting(key, value)
//   Storage: get_storage(key), set_storage(key, value)

// Default configuration (inlined in functions due to Rhai scoping)
// Default site: OmegaScans (omegascans.org / api.omegascans.org)

/// Get default base URL
fn get_default_base_url() {
    "https://omegascans.org"
}

/// Get default API URL
fn get_default_api_url() {
    "https://api.omegascans.org"
}

/// Get results per page
fn get_per_page() {
    20
}

/// Get chapters per page
fn get_chapters_per_page() {
    1000
}

/// Safely get a setting with fallback (get_setting may not be available)
fn safe_get_setting(key) {
    // get_setting is not available in current scraper runtime
    // Return empty to use defaults
    ()
}

/// Remove trailing slashes from a string
fn strip_trailing_slash(s) {
    while s.ends_with("/") {
        s = s.sub_string(0, s.len() - 1);
    }
    s
}

/// Get the configured base URL
fn get_base_url() {
    let url = safe_get_setting("base_url");
    if url == () || url == "" {
        return get_default_base_url();
    }
    // Remove trailing slash
    strip_trailing_slash(url)
}

/// Get the API URL (auto-detect or from settings)
fn get_api_url() {
    let custom_api = safe_get_setting("api_url");
    if custom_api != () && custom_api != "" {
        return strip_trailing_slash(custom_api);
    }

    // Use default API URL for the default base
    let base = get_base_url();
    let default_base = get_default_base_url();
    if base == default_base {
        return get_default_api_url();
    }

    // Auto-detect API URL by replacing :// with ://api.
    if base.contains("://") {
        let parts = base.split("://");
        if parts.len() >= 2 {
            return `${parts[0]}://api.${parts[1]}`;
        }
    }

    `https://api.${base.replace("https://", "").replace("http://", "")}`
}

/// Get request headers
fn get_headers(auth) {
    let base = get_base_url();
    let headers = #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "en-US,en;q=0.9",
        "Referer": base,
        "Origin": base
    };

    // Auth token support removed - get_storage not available in scraper runtime
    // To add auth support, pass token via auth parameter from caller

    headers
}

/// Returns metadata about this source
fn get_source_info() {
    let base_url = get_base_url();
    #{
        id: "heancms-rhai",
        name: "HeanCMS",
        base_url: base_url,
        language: "en",
        supported_languages: ["en", "es", "pt-br"],
        requires_authentication: false,
        capability_level: "http_only",
        is_framework: true,
        framework_name: "HeanCMS"
    }
}

/// Login and get auth token
fn login(email, password) {
    if email == () || email == "" || password == () || password == "" {
        return #{ success: false, error: "Email and password required" };
    }

    let api_url = get_api_url();
    let url = `${api_url}/login`;

    let body = #{
        email: email,
        password: password
    };

    let headers = get_headers(());
    headers["Content-Type"] = "application/json";

    let response = http_post_json(url, body, headers);
    if response == () {
        return #{ success: false, error: "Login request failed" };
    }

    let data = json_parse(response);
    if data == () {
        return #{ success: false, error: "Invalid response" };
    }

    let token = data["token"];
    if token != () && token != "" {
        // Note: set_storage not available, return token for caller to handle
        return #{ success: true, token: token };
    }

    let errors = data["errors"];
    if errors != () && errors.len() > 0 {
        return #{ success: false, error: errors[0]["message"] };
    }

    #{ success: false, error: "Login failed" }
}

/// Search for series matching query
fn search_series(query, page, auth) {
    let api_url = get_api_url();
    let encoded_query = url_encode(query);

    // Build query URL
    let url = `${api_url}/query?query_string=${encoded_query}&page=${page}&perPage=${get_per_page()}&series_type=Comic`;

    let response = "";
    try {
        response = http_get_with_headers(url, get_headers(auth));
    } catch(err) {
        return #{ series: [], has_more: false, total: 0 };
    }
    if response == () || response == "" {
        return #{ series: [], has_more: false, total: 0 };
    }

    let data = json_parse(response);
    if data == () {
        return #{ series: [], has_more: false, total: 0 };
    }

    let series = [];
    let items = data["data"];

    if items != () {
        for item in items {
            let s = parse_series_dto(item);
            if s != () {
                series.push(s);
            }
        }
    }

    // Check for more pages
    let meta = data["meta"];
    let has_more = false;
    if meta != () {
        let current_page = meta["current_page"];
        let last_page = meta["last_page"];
        if current_page != () && last_page != () {
            has_more = current_page < last_page;
        }
    }

    #{ series: series, has_more: has_more, total: () }
}

/// Parse a series DTO from JSON
fn parse_series_dto(item) {
    if item == () {
        return ();
    }

    let id = item["id"];
    let slug = item["slug"];
    if slug == () || slug == "" {
        slug = item["series_slug"];
    }

    if slug == () || slug == "" {
        return ();
    }

    let title = item["title"];
    if title == () {
        title = item["name"];
    }

    let thumbnail = item["thumbnail"];
    if thumbnail == () {
        thumbnail = item["cover"];
    }

    // Build cover URL if needed
    let cover_url = thumbnail;
    if cover_url != () && !cover_url.starts_with("http") {
        let base = get_base_url();
        if cover_url.starts_with("/") {
            cover_url = `${base}${cover_url}`;
        } else {
            cover_url = `${base}/${cover_url}`;
        }
    }

    // Parse tags/genres
    let genres = [];
    let tags_data = item["tags"];
    if tags_data != () {
        for tag in tags_data {
            let tag_name = tag["name"];
            if tag_name == () {
                tag_name = tag;
            }
            if tag_name != () && tag_name != "" {
                genres.push(tag_name);
            }
        }
    }

    // Parse status
    let status = parse_status(item["status"]);

    // Parse author
    let authors = [];
    let author = item["author"];
    if author != () && author != "" {
        authors.push(author);
    }

    // Parse artist/studio
    let artists = [];
    let studio = item["studio"];
    if studio != () && studio != "" {
        artists.push(studio);
    }

    // Extract chapter count (HeanCMS API may return as chapters_count, chapter_count, or meta.total)
    let chapter_count = item["chapters_count"];
    if chapter_count == () {
        chapter_count = item["chapter_count"];
    }
    if chapter_count == () {
        chapter_count = item["total_chapters"];
    }

    let base_url = get_base_url();

    #{
        id: slug,
        title: if title != () { title } else { slug },
        url: `${base_url}/series/${slug}`,
        cover_url: cover_url,
        alternate_titles: [],
        authors: authors,
        artists: artists,
        status: status,
        genres: genres,
        tags: [],
        description: item["description"],
        chapter_count: chapter_count
    }
}

/// Parse status string to normalized status
fn parse_status(status_str) {
    if status_str == () {
        return ();
    }

    let status_lower = status_str.to_lower();

    if status_lower == "ongoing" {
        return "Ongoing";
    } else if status_lower == "completed" || status_lower == "finished" {
        return "Completed";
    } else if status_lower == "hiatus" {
        return "Hiatus";
    } else if status_lower == "dropped" || status_lower == "cancelled" {
        return "Cancelled";
    }

    ()
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let slug = id_or_url;

    // Extract slug from URL if needed
    if id_or_url.starts_with("http") {
        slug = extract_slug_from_url(id_or_url);
    }

    let api_url = get_api_url();
    let url = `${api_url}/series/${slug}`;

    let response = "";
    try {
        response = http_get_with_headers(url, get_headers(auth));
    } catch(err) {
        return #{
            id: slug,
            title: "",
            error: `Network error: ${err}`
        };
    }
    if response == () || response == "" {
        return #{
            id: slug,
            title: "",
            error: "Failed to fetch series"
        };
    }

    let data = json_parse(response);
    if data == () {
        return #{
            id: slug,
            title: "",
            error: "Invalid JSON response"
        };
    }

    // Parse the series data
    let series = parse_series_dto(data);
    if series == () {
        return #{
            id: slug,
            title: "",
            error: "Failed to parse series data"
        };
    }

    // Add extra fields from full response
    let description = data["description"];
    if description != () {
        series["description"] = description;
    }

    let base_url = get_base_url();
    series["url"] = `${base_url}/series/${slug}`;
    series["content_rating"] = "suggestive";
    series["extra"] = #{
        auto_match_metadata: true,
        source_name: "HeanCMS"
    };

    series
}

/// Extract slug from URL
fn extract_slug_from_url(url) {
    // Pattern: .../series/{slug} or .../series/{slug}/
    if url.contains("/series/") {
        let parts = url.split("/series/");
        if parts.len() > 1 {
            let slug = parts[1];
            slug = strip_trailing_slash(slug);
            // Remove any query params
            let slug_parts = slug.split("?");
            return slug_parts[0];
        }
    }

    // Fallback: get last non-empty path segment
    let parts = url.split("/");
    for i in (0..parts.len()).rev() {
        let part = parts[i].trim();
        if part != "" && !part.contains("?") {
            return part;
        }
    }

    url
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let slug = series_id;

    if series_id.starts_with("http") {
        slug = extract_slug_from_url(series_id);
    }

    // Try the new /chapter/query endpoint first (works on current HeanCMS sites)
    let chapters = get_chapters_new_endpoint(slug, auth);
    if chapters.len() > 0 {
        return chapters;
    }

    // Fallback: get chapters from series response (seasons)
    get_chapters_from_series(slug, auth)
}

/// Get chapters using the new /chapter/query endpoint
fn get_chapters_new_endpoint(slug, auth) {
    // First, get series ID from slug
    let api_url = get_api_url();
    let series_url = `${api_url}/series/${slug}`;

    let response = "";
    try {
        response = http_get_with_headers(series_url, get_headers(auth));
    } catch(err) {
        return [];
    }
    if response == () || response == "" {
        return [];
    }

    let series_data = json_parse(response);
    if series_data == () {
        return [];
    }

    let series_id = series_data["id"];
    if series_id == () {
        // Fallback to seasons if available
        return parse_seasons_chapters(series_data, slug);
    }

    // Query chapters endpoint
    let chapters_url = `${api_url}/chapter/query?series_id=${series_id}&perPage=${get_chapters_per_page()}`;

    let chapters_response = "";
    try {
        chapters_response = http_get_with_headers(chapters_url, get_headers(auth));
    } catch(err) {
        return parse_seasons_chapters(series_data, slug);
    }
    if chapters_response == () || chapters_response == "" {
        // Fallback to seasons
        return parse_seasons_chapters(series_data, slug);
    }

    let chapters_data = json_parse(chapters_response);
    if chapters_data == () {
        return parse_seasons_chapters(series_data, slug);
    }

    let chapters = [];
    let items = chapters_data["data"];

    if items == () {
        // Check if response is the array directly
        if type_of(chapters_data) == "array" && chapters_data.len() > 0 {
            items = chapters_data;
        }
    }

    if items != () {
        for ch in items {
            let chapter = parse_chapter_dto(ch, slug);
            if chapter != () {
                chapters.push(chapter);
            }
        }
    }

    // Sort by chapter number descending
    chapters.sort(|a, b| {
        let num_a = parse_float(a.number);
        let num_b = parse_float(b.number);
        if num_a > num_b { -1 } else if num_a < num_b { 1 } else { 0 }
    });

    chapters
}

/// Get chapters from series response (seasons array)
fn get_chapters_from_series(slug, auth) {
    let api_url = get_api_url();
    let url = `${api_url}/series/${slug}`;

    let response = "";
    try {
        response = http_get_with_headers(url, get_headers(auth));
    } catch(err) {
        return [];
    }
    if response == () || response == "" {
        return [];
    }

    let data = json_parse(response);
    if data == () {
        return [];
    }

    parse_seasons_chapters(data, slug)
}

/// Parse chapters from seasons array in series response
fn parse_seasons_chapters(series_data, slug) {
    let chapters = [];
    let seasons = series_data["seasons"];

    if seasons == () {
        return [];
    }

    for season in seasons {
        let season_chapters = season["chapters"];
        if season_chapters == () {
            continue;
        }

        for ch in season_chapters {
            let chapter = parse_chapter_dto(ch, slug);
            if chapter != () {
                chapters.push(chapter);
            }
        }
    }

    // Sort by chapter number descending
    chapters.sort(|a, b| {
        let num_a = parse_float(a.number);
        let num_b = parse_float(b.number);
        if num_a > num_b { -1 } else if num_a < num_b { 1 } else { 0 }
    });

    chapters
}

/// Parse a chapter DTO
fn parse_chapter_dto(ch, series_slug) {
    if ch == () {
        return ();
    }

    let chapter_id = ch["id"];
    let chapter_slug = ch["slug"];
    if chapter_slug == () {
        chapter_slug = ch["chapter_slug"];
    }

    // Get chapter number from name field
    let chapter_name = ch["name"];
    if chapter_name == () {
        chapter_name = ch["chapter_name"];
    }

    let chapter_num = extract_chapter_number(chapter_name);

    // Get chapter title
    let chapter_title = ch["title"];
    if chapter_title == () {
        chapter_title = ch["chapter_title"];
    }

    // Parse date
    let created_at = ch["created_at"];
    if created_at == () {
        created_at = ch["createdAt"];
    }

    // Check if paywalled
    let price = ch["price"];
    let is_free = price == () || price == 0;

    let base_url = get_base_url();
    let chapter_url = `${base_url}/series/${series_slug}/${chapter_slug}`;

    #{
        id: `${series_slug}/${chapter_slug}`,
        series_id: series_slug,
        number: chapter_num,
        title: chapter_title,
        volume: (),
        language: "en",
        scanlator: (),
        url: chapter_url,
        published_at: created_at,
        page_count: (),
        extra: #{
            is_free: is_free,
            is_premium: !is_free,
            internal_id: chapter_id
        }
    }
}

/// Extract chapter number from chapter name
fn extract_chapter_number(name) {
    if name == () {
        return "0";
    }

    let name_str = `${name}`;

    // Try to parse as number directly
    let num = "";
    let found_digit = false;

    for c in name_str.chars() {
        if c >= '0' && c <= '9' {
            num += c;
            found_digit = true;
        } else if c == '.' && found_digit {
            num += c;
        } else if found_digit && num != "" {
            // Stop at first non-digit after finding digits
            break;
        }
    }

    if num != "" {
        return num;
    }

    name_str
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    // chapter_id can be a URL or chapter slug
    let chapter_path = chapter_id;
    let referer_url = chapter_id;

    if chapter_id.starts_with("http") {
        // Extract path from URL
        // Format: /series/{series_slug}/{chapter_slug}
        if chapter_id.contains("/series/") {
            let parts = chapter_id.split("/series/");
            if parts.len() > 1 {
                chapter_path = parts[1];
                // Remove trailing slash
                chapter_path = strip_trailing_slash(chapter_path);
            }
        }
        referer_url = chapter_id;
    } else {
        let base = get_base_url();
        referer_url = `${base}/series/${chapter_id}`;
    }

    let api_url = get_api_url();
    let url = `${api_url}/chapter/${chapter_path}`;

    let headers = get_headers(auth);
    let response = "";
    try {
        response = http_get_with_headers(url, headers);
    } catch(err) {
        return [];
    }

    if response == () || response == "" {
        return [];
    }

    let data = json_parse(response);
    if data == () {
        return [];
    }

    // Paywalled chapters return {"paywall": true, "chapter": {...no chapter_data...}}
    // with HTTP 200. There are no images to fetch without a purchased account, so
    // return [] explicitly (the caller treats 0 pages as "needs auth / locked").
    if data["paywall"] == true {
        return [];
    }

    // Try new format: chapter.chapterData.images / chapter.chapter_data.images.
    // Modern HeanCMS returns chapter_data as a nested object, but some forks
    // serialize it as a JSON *string* — handle both.
    let chapter = data["chapter"];
    if chapter != () {
        let chapter_data = chapter["chapterData"];
        if chapter_data == () {
            chapter_data = chapter["chapter_data"];
        }

        // chapter_data may be a JSON string that itself contains {"images":[...]}
        if type_of(chapter_data) == "string" && chapter_data != "" {
            let parsed = json_parse(chapter_data);
            if parsed != () {
                chapter_data = parsed;
            }
        }

        if chapter_data != () && type_of(chapter_data) == "map" {
            let pages = build_pages(chapter_data["images"], referer_url);
            if pages.len() > 0 {
                return pages;
            }
        }

        // Some payloads put images straight on the chapter object
        let pages = build_pages(chapter["images"], referer_url);
        if pages.len() > 0 {
            return pages;
        }
    }

    // Try: data array directly in response
    let pages = build_pages(data["data"], referer_url);
    if pages.len() > 0 {
        return pages;
    }

    // Try: images array at root level
    pages = build_pages(data["images"], referer_url);
    if pages.len() > 0 {
        return pages;
    }

    // Try: content.images
    let content = data["content"];
    if content != () && type_of(content) == "map" {
        pages = build_pages(content["images"], referer_url);
    }

    pages
}

/// Build page objects from a HeanCMS images array and RETURN them.
/// (Rhai passes args by value, so we return a new array rather than mutate one.)
/// Each element may be a plain URL string or an object like {url}/{src}/{image}.
fn build_pages(images, referer_url) {
    let pages = [];
    if images == () || type_of(images) != "array" {
        return pages;
    }

    for img in images {
        let img_url = ();
        if type_of(img) == "string" {
            img_url = img;
        } else if type_of(img) == "map" {
            img_url = img["url"];
            if img_url == () { img_url = img["src"]; }
            if img_url == () { img_url = img["image"]; }
            if img_url == () { img_url = img["path"]; }
        }

        if img_url != () && img_url != "" {
            pages.push(create_page(pages.len(), img_url, referer_url));
        }
    }

    pages
}

/// Create a page object
fn create_page(index, url, referer) {
    let full_url = url;

    // Make URL absolute if needed
    if !url.starts_with("http") {
        let base = get_base_url();
        if url.starts_with("/") {
            full_url = `${base}${url}`;
        } else {
            full_url = `${base}/${url}`;
        }
    }

    #{
        index: index,
        url: full_url,
        headers: #{
            "Referer": referer
        },
        referer: referer
    }
}

/// Get latest updates
fn get_latest_updates(page, auth) {
    let api_url = get_api_url();
    let url = `${api_url}/query?page=${page}&perPage=${get_per_page()}&orderBy=latest&series_type=Comic`;

    let response = "";
    try {
        response = http_get_with_headers(url, get_headers(auth));
    } catch(err) {
        return #{ series: [], has_more: false };
    }
    if response == () || response == "" {
        return #{ series: [], has_more: false };
    }

    let data = json_parse(response);
    if data == () {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let items = data["data"];

    if items != () {
        for item in items {
            let s = parse_series_dto(item);
            if s != () {
                series.push(s);
            }
        }
    }

    // Check for more pages
    let meta = data["meta"];
    let has_more = false;
    if meta != () {
        let current_page = meta["current_page"];
        let last_page = meta["last_page"];
        if current_page != () && last_page != () {
            has_more = current_page < last_page;
        }
    }

    #{ series: series, has_more: has_more }
}

/// Browse manga (main browse endpoint)
fn browse(page, filters, auth) {
    // Default to popular manga for browse
    get_popular(page, auth)
}

/// Get popular series
fn get_popular(page, auth) {
    let api_url = get_api_url();
    let url = `${api_url}/query?page=${page}&perPage=${get_per_page()}&orderBy=total_views&order=desc&series_type=Comic`;

    let response = "";
    try {
        response = http_get_with_headers(url, get_headers(auth));
    } catch(err) {
        return #{ series: [], has_more: false };
    }
    if response == () || response == "" {
        return #{ series: [], has_more: false };
    }

    let data = json_parse(response);
    if data == () {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let items = data["data"];

    if items != () {
        for item in items {
            let s = parse_series_dto(item);
            if s != () {
                series.push(s);
            }
        }
    }

    let meta = data["meta"];
    let has_more = false;
    if meta != () {
        let current_page = meta["current_page"];
        let last_page = meta["last_page"];
        if current_page != () && last_page != () {
            has_more = current_page < last_page;
        }
    }

    #{ series: series, has_more: has_more }
}

/// Get available genres/tags
fn get_genres(auth) {
    let api_url = get_api_url();
    let url = `${api_url}/tags`;

    let response = "";
    try {
        response = http_get_with_headers(url, get_headers(auth));
    } catch(err) {
        return [];
    }
    if response == () || response == "" {
        return [];
    }

    let data = json_parse(response);
    if data == () {
        return [];
    }

    let genres = [];

    // Tags might be in data array or at root level
    let tags = data["data"];
    if tags == () {
        tags = data;
    }

    if tags != () {
        for tag in tags {
            let name = tag["name"];
            let id = tag["id"];
            if name != () {
                genres.push(#{
                    id: id,
                    name: name
                });
            }
        }
    }

    genres
}

/// Helper: Parse float from string
fn parse_float(s) {
    if s == () { return 0.0; }

    let s_str = `${s}`;
    let result = 0.0;
    let parts = s_str.split(".");

    if parts.len() > 0 {
        let int_part = 0;
        for c in parts[0].chars() {
            if c >= '0' && c <= '9' {
                int_part = int_part * 10 + (c.to_int() - '0'.to_int());
            }
        }
        result = int_part;
    }

    if parts.len() > 1 {
        let decimal = 0.0;
        let divisor = 1.0;
        for c in parts[1].chars() {
            if c >= '0' && c <= '9' {
                divisor *= 10.0;
                decimal = decimal * 10.0 + (c.to_int() - '0'.to_int());
            }
        }
        if divisor > 1.0 {
            result += decimal / divisor;
        }
    }

    result
}
