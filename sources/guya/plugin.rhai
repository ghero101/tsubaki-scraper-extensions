// Guya Scraper Add-on (Rhai)
// Uses the Guya/Cubari API (guya.cubari.moe)
//
// API Endpoints:
//   /api/get_all_series/       - List all series
//   /api/series/{slug}/        - Get series details and chapters
//
// Available APIs:
//   http_get(url) -> string
//   http_get_with_headers(url, headers) -> string
//   json_parse(text) -> Dynamic
//   url_encode(text) -> string

const BASE_URL = "https://guya.cubari.moe";
const API_URL = "https://guya.cubari.moe/api";

// ============================================================================
// Helper Functions
// ============================================================================

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "guya-rhai",
        name: "Guya",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

/// Get headers for API requests
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "application/json",
        "Referer": BASE_URL
    }
}

/// Convert Unix timestamp to ISO date string (approximate)
fn timestamp_to_date(ts) {
    if ts == () || ts == 0 {
        return ();
    }
    // Return as Unix timestamp - the host will handle conversion
    ts
}

/// Extract slug from URL
fn extract_slug(url) {
    // URL format: https://guya.cubari.moe/read/manga/{slug}/...
    // or just the slug itself
    if url.contains("/read/manga/") {
        let parts = url.split("/read/manga/");
        if parts.len() > 1 {
            let after = parts[1];
            let slug_parts = after.split("/");
            if slug_parts.len() > 0 {
                return slug_parts[0];
            }
        }
    }
    // If it's already a slug or series URL
    if url.contains("/api/series/") {
        let parts = url.split("/api/series/");
        if parts.len() > 1 {
            let after = parts[1];
            return after.replace("/", "");
        }
    }
    // Return as-is if it looks like a slug
    url
}

// ============================================================================
// Required Interface Functions
// ============================================================================

/// Search for series matching query
/// Guya doesn't have a search API, so we fetch all series and filter locally
fn search_series(query, page, auth) {
    // Only page 1 since we get all results at once
    if page > 1 {
        return #{ series: [], has_more: false, total: 0 };
    }

    let url = `${API_URL}/get_all_series/`;
    let response_text = "";
    try {
        response_text = http_get_with_headers(url, get_headers());
    } catch(err) {
        return #{ series: [], has_more: false, total: 0 };
    }
    let data = json_parse(response_text);

    if data == () {
        return #{ series: [], has_more: false, total: 0 };
    }

    let series = [];
    let query_lower = query.to_lower();

    // Iterate through all series in the response
    // The API returns an object with series names as keys
    let keys = data.keys();

    for key in keys {
        let manga = data[key];
        let title = key;

        // Check if title matches query (case-insensitive)
        let title_lower = title.to_lower();
        if !title_lower.contains(query_lower) {
            // Also check description and author/artist
            let desc = "";
            if manga.contains("description") && manga["description"] != () {
                desc = manga["description"].to_lower();
            }
            let author = "";
            if manga.contains("author") && manga["author"] != () {
                author = manga["author"].to_lower();
            }
            if !desc.contains(query_lower) && !author.contains(query_lower) {
                continue;
            }
        }

        let slug = "";
        if manga.contains("slug") {
            slug = manga["slug"];
        }

        // Build cover URL
        let cover_url = ();
        if manga.contains("cover") && manga["cover"] != () {
            let cover = manga["cover"];
            if cover.starts_with("/") {
                cover_url = `${BASE_URL}${cover}`;
            } else if cover.starts_with("http") {
                cover_url = cover;
            } else {
                cover_url = `${BASE_URL}/${cover}`;
            }
        }

        // Get author/artist
        let authors = [];
        let artists = [];
        if manga.contains("author") && manga["author"] != () {
            authors.push(manga["author"]);
        }
        if manga.contains("artist") && manga["artist"] != () {
            artists.push(manga["artist"]);
        }

        // Get description
        let description = ();
        if manga.contains("description") {
            description = manga["description"];
        }

        series.push(#{
            id: slug,
            title: title,
            url: `${BASE_URL}/read/manga/${slug}/`,
            cover_url: cover_url,
            alternate_titles: [],
            authors: authors,
            artists: artists,
            status: "Ongoing",
            genres: [],
            tags: [],
            description: description
        });
    }

    #{ series: series, has_more: false, total: series.len() }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let slug = extract_slug(id_or_url);

    let url = `${API_URL}/series/${slug}/`;
    let response_text = "";
    try {
        response_text = http_get_with_headers(url, get_headers());
    } catch(err) {
        return #{
            id: slug,
            title: "",
            error: `Network error: ${err}`
        };
    }
    let data = json_parse(response_text);

    if data == () {
        return #{
            id: slug,
            title: "",
            error: "Failed to fetch series"
        };
    }

    // Get title
    let title = "";
    if data.contains("title") {
        title = data["title"];
    } else if data.contains("slug") {
        // Convert slug to readable title
        title = data["slug"].replace("-", " ");
    } else {
        title = slug.replace("-", " ");
    }

    // Build cover URL
    let cover_url = ();
    if data.contains("cover") && data["cover"] != () {
        let cover = data["cover"];
        if cover.starts_with("/") {
            cover_url = `${BASE_URL}${cover}`;
        } else if cover.starts_with("http") {
            cover_url = cover;
        } else {
            cover_url = `${BASE_URL}/${cover}`;
        }
    }

    // Get author/artist
    let authors = [];
    let artists = [];
    if data.contains("author") && data["author"] != () {
        authors.push(data["author"]);
    }
    if data.contains("artist") && data["artist"] != () {
        artists.push(data["artist"]);
    }

    // Get description
    let description = ();
    if data.contains("description") {
        description = data["description"];
    }

    // Get groups (scanlation teams)
    let groups = #{};
    if data.contains("groups") {
        groups = data["groups"];
    }

    #{
        id: slug,
        title: title,
        alternate_titles: [],
        description: description,
        cover_url: cover_url,
        authors: authors,
        artists: artists,
        status: "Ongoing",
        genres: [],
        tags: [],
        year: (),
        content_rating: "safe",
        url: `${BASE_URL}/read/manga/${slug}/`,
        extra: #{
            slug: slug,
            groups: groups
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let slug = extract_slug(series_id);

    let url = `${API_URL}/series/${slug}/`;
    let response_text = "";
    try {
        response_text = http_get_with_headers(url, get_headers());
    } catch(err) {
        return [];
    }
    let data = json_parse(response_text);

    if data == () || !data.contains("chapters") {
        return [];
    }

    let chapters_data = data["chapters"];
    let groups = #{};
    if data.contains("groups") {
        groups = data["groups"];
    }

    let chapters = [];
    let chapter_keys = chapters_data.keys();

    for ch_num in chapter_keys {
        let chapter = chapters_data[ch_num];

        // Get chapter title
        let title = ();
        if chapter.contains("title") && chapter["title"] != () && chapter["title"] != "" {
            title = chapter["title"];
        }

        // Get volume
        let volume = ();
        if chapter.contains("volume") && chapter["volume"] != () {
            volume = chapter["volume"];
        }

        // Get folder (unique identifier)
        let folder = "";
        if chapter.contains("folder") {
            folder = chapter["folder"];
        }

        // Get release date - check for release_date field in groups
        let published_at = ();
        if chapter.contains("release_date") {
            // release_date is a map of group_id -> timestamp
            let release_dates = chapter["release_date"];
            let date_keys = release_dates.keys();
            if date_keys.len() > 0 {
                // Get the first (or preferred) group's release date
                published_at = timestamp_to_date(release_dates[date_keys[0]]);
            }
        }

        // Get scanlator from groups
        let scanlator = ();
        if chapter.contains("groups") {
            let ch_groups = chapter["groups"];
            let group_keys = ch_groups.keys();
            if group_keys.len() > 0 {
                let first_group_id = group_keys[0];
                if groups.contains(first_group_id) {
                    scanlator = groups[first_group_id];
                }
            }
        }

        // Get page count from first group's pages array
        let page_count = ();
        if chapter.contains("groups") {
            let ch_groups = chapter["groups"];
            let group_keys = ch_groups.keys();
            if group_keys.len() > 0 {
                let pages = ch_groups[group_keys[0]];
                if pages.is_array() {
                    page_count = pages.len();
                }
            }
        }

        chapters.push(#{
            id: `${slug}/${ch_num}/${folder}`,
            series_id: slug,
            number: ch_num,
            title: title,
            volume: volume,
            language: "en",
            scanlator: scanlator,
            url: `${BASE_URL}/read/manga/${slug}/${ch_num}/1/`,
            published_at: published_at,
            page_count: page_count,
            extra: #{
                folder: folder
            }
        });
    }

    // Sort chapters by number (descending - newest first)
    // Rhai doesn't have built-in sort, so we'll return as-is
    // The host system should handle sorting if needed

    chapters
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    // chapter_id format: {slug}/{chapter_num}/{folder}
    let parts = chapter_id.split("/");

    let slug = "";
    let ch_num = "";
    let folder = "";

    if parts.len() >= 3 {
        slug = parts[0];
        ch_num = parts[1];
        folder = parts[2];
    } else if parts.len() >= 2 {
        slug = parts[0];
        ch_num = parts[1];
    } else {
        // Try to extract from URL
        slug = extract_slug(chapter_id);
        return [];
    }

    // Fetch series data to get chapter pages
    let url = `${API_URL}/series/${slug}/`;
    let response_text = "";
    try {
        response_text = http_get_with_headers(url, get_headers());
    } catch(err) {
        return [];
    }
    let data = json_parse(response_text);

    if data == () || !data.contains("chapters") {
        return [];
    }

    let chapters_data = data["chapters"];

    if !chapters_data.contains(ch_num) {
        return [];
    }

    let chapter = chapters_data[ch_num];

    if !chapter.contains("groups") || !chapter.contains("folder") {
        return [];
    }

    let ch_folder = chapter["folder"];
    let ch_groups = chapter["groups"];

    // Get preferred group or first available
    let preferred_sort = [];
    if chapter.contains("preferred_sort") {
        preferred_sort = chapter["preferred_sort"];
    } else if data.contains("preferred_sort") {
        preferred_sort = data["preferred_sort"];
    }

    let group_keys = ch_groups.keys();
    let selected_group = "";

    // Use preferred group if available
    for pref in preferred_sort {
        let pref_str = `${pref}`;
        if ch_groups.contains(pref_str) {
            selected_group = pref_str;
            break;
        }
    }

    // Fallback to first group
    if selected_group == "" && group_keys.len() > 0 {
        selected_group = group_keys[0];
    }

    if selected_group == "" {
        return [];
    }

    let page_list = ch_groups[selected_group];
    let pages = [];
    let idx = 0;

    for page_file in page_list {
        // Build page URL
        // Format: /media/manga/{slug}/chapters/{folder}/{group_id}/{page_file}
        let page_url = `${BASE_URL}/media/manga/${slug}/chapters/${ch_folder}/${selected_group}/${page_file}`;

        pages.push(#{
            index: idx,
            url: page_url,
            headers: #{
                "Referer": BASE_URL
            },
            referer: BASE_URL
        });
        idx += 1;
    }

    pages
}

/// Get latest updates (all series sorted by last update)
fn get_latest_updates(page, auth) {
    if page > 1 {
        return #{ series: [], has_more: false };
    }

    let url = `${API_URL}/get_all_series/`;
    let response_text = "";
    try {
        response_text = http_get_with_headers(url, get_headers());
    } catch(err) {
        return #{ series: [], has_more: false };
    }
    let data = json_parse(response_text);

    if data == () {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let keys = data.keys();

    for key in keys {
        let manga = data[key];
        let title = key;

        let slug = "";
        if manga.contains("slug") {
            slug = manga["slug"];
        }

        // Build cover URL
        let cover_url = ();
        if manga.contains("cover") && manga["cover"] != () {
            let cover = manga["cover"];
            if cover.starts_with("/") {
                cover_url = `${BASE_URL}${cover}`;
            } else if cover.starts_with("http") {
                cover_url = cover;
            } else {
                cover_url = `${BASE_URL}/${cover}`;
            }
        }

        // Get last updated timestamp
        let updated_at = ();
        if manga.contains("last_updated") {
            updated_at = timestamp_to_date(manga["last_updated"]);
        }

        series.push(#{
            id: slug,
            title: title,
            url: `${BASE_URL}/read/manga/${slug}/`,
            cover_url: cover_url,
            updated_at: updated_at
        });
    }

    // Note: Results should be sorted by updated_at by the host
    // Guya API doesn't guarantee order

    #{ series: series, has_more: false }
}

/// Get popular series (same as all series for Guya since it's a small catalog)
fn get_popular(page, auth) {
    // Guya has a small, curated catalog so popular = all series
    get_latest_updates(page, auth)
}
