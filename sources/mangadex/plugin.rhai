// MangaDex Scraper Add-on (Rhai)
// Uses the official MangaDex API v5

const BASE_URL = "https://api.mangadex.org";
const COVERS_URL = "https://uploads.mangadex.org/covers";

// --- Authentication Functions ---

/// Get session token from auth context.
/// Checks for session_token or access_token (OAuth compatibility).
fn get_token_from_auth(auth) {
    // Check for session_token first (from OAuth login)
    if auth != () {
        if auth.session_token != () && auth.session_token != "" {
            return auth.session_token;
        }
        // Also check access_token for OAuth compatibility
        if auth.access_token != () && auth.access_token != "" {
            return auth.access_token;
        }
    }
    return "";
}

/// Get auth headers for a request.
fn get_auth_headers(auth) {
    let token = get_token_from_auth(auth);
    if token != "" {
        return #{
            "Authorization": `Bearer ${token}`
        };
    }
    return #{};
}

/// Make an authenticated GET request.
fn auth_http_get(url, auth) {
    let headers = get_auth_headers(auth);
    if headers.len() > 0 {
        return http_get_with_headers(url, headers);
    }
    return http_get(url);
}

/// Perform OAuth 2.0 login to MangaDex.
/// MangaDex uses Keycloak with password grant type.
/// Required credentials: username, password, client_id, client_secret
fn login(credentials) {
    let auth_url = "https://auth.mangadex.org/realms/mangadex/protocol/openid-connect/token";

    // Extract credentials
    let username = if credentials.username != () { credentials.username } else { "" };
    let password = if credentials.password != () { credentials.password } else { "" };
    let client_id = if credentials.client_id != () { credentials.client_id } else { "" };
    let client_secret = if credentials.client_secret != () { credentials.client_secret } else { "" };

    // Validate required credentials
    if username == "" || password == "" {
        return #{
            success: false,
            error: "Username and password are required"
        };
    }

    if client_id == "" || client_secret == "" {
        return #{
            success: false,
            error: "Client ID and Client Secret are required. Create a Personal API Client at https://mangadex.org/settings"
        };
    }

    // Build OAuth request body (URL-encoded form)
    let body = `grant_type=password&username=${url_encode(username)}&password=${url_encode(password)}&client_id=${url_encode(client_id)}&client_secret=${url_encode(client_secret)}`;

    // Make OAuth token request (http_post_form sets Content-Type automatically)
    let response_text = http_post_form(auth_url, body);
    let response = json_parse(response_text);

    // Check for error response
    if response.error != () {
        let error_desc = if response.error_description != () { response.error_description } else { response.error };
        return #{
            success: false,
            error: `Authentication failed: ${error_desc}`
        };
    }

    // Check for access token
    if response.access_token == () {
        return #{
            success: false,
            error: "No access token in response"
        };
    }

    // Return successful auth context
    return #{
        success: true,
        session_token: response.access_token,
        refresh_token: response.refresh_token,
        expires_in: response.expires_in
    };
}

// --- Helper Functions ---

/// Checks if an array contains a given value.
fn array_contains(array, value) {
    for item in array {
        if item == value {
            return true;
        }
    }
    return false;
}

/// Extract title from MangaDex title object, preferring specified language.
fn extract_title(title_obj, preferred_lang) {
    if title_obj == () { return ""; }
    // Try preferred language first
    if title_obj.contains(preferred_lang) { return title_obj[preferred_lang]; }
    // Fall back to English
    if title_obj.contains("en") { return title_obj["en"]; }
    // Fall back to Japanese
    if title_obj.contains("ja") { return title_obj["ja"]; }
    // Return first available by iterating over keys
    let keys = title_obj.keys();
    if keys.len() > 0 { return title_obj[keys[0]]; }
    return "";
}

/// Extract cover URL from relationships.
fn extract_cover_url(manga_id, relationships) {
    if relationships == () { return ""; }
    for rel in relationships {
        if rel.type == "cover_art" {
            let attrs = rel.attributes;
            if attrs != () && attrs.fileName != () {
                return `${COVERS_URL}/${manga_id}/${attrs.fileName}`;
            }
        }
    }
    return "";
}

/// Extract authors from relationships.
fn extract_authors(relationships) {
    let people = [];
    let seen = [];
    if relationships == () { return people; }
    for rel in relationships {
        if rel.type == "author" {
            let attrs = rel.attributes;
            if attrs != () && attrs.name != () {
                if !array_contains(seen, attrs.name) {
                    people.push(attrs.name);
                    seen.push(attrs.name);
                }
            }
        }
    }
    return people;
}

/// Extract artists from relationships.
fn extract_artists(relationships) {
    let people = [];
    let seen = [];
    if relationships == () { return people; }
    for rel in relationships {
        if rel.type == "artist" {
            let attrs = rel.attributes;
            if attrs != () && attrs.name != () {
                if !array_contains(seen, attrs.name) {
                    people.push(attrs.name);
                    seen.push(attrs.name);
                }
            }
        }
    }
    return people;
}

/// Extract tags from manga data.
fn extract_tags(tags, lang) {
    let result = [];
    if tags == () { return result; }
    for tag in tags {
        let attrs = tag.attributes;
        if attrs != () && attrs.name != () {
            let tag_name = extract_title(attrs.name, lang);
            if tag_name != "" {
                result.push(tag_name);
            }
        }
    }
    return result;
}

/// Map status string to standard format.
fn map_status(status) {
    let status_map = #{
        "ongoing": "Ongoing",
        "completed": "Completed",
        "hiatus": "Hiatus",
        "cancelled": "Cancelled"
    };
    if status_map.contains(status) {
        return status_map[status];
    }
    return status;
}

/// Map MangaDex's contentRating ("safe" / "suggestive" / "erotica" /
/// "pornographic") to the canonical safe/suggestive/nsfw set the UI
/// filters on. Pre-1.8.5 the plugin passed "erotica" and "pornographic"
/// through raw — adult content slipped past the NSFW filter entirely.
fn map_content_rating(rating) {
    if rating == () || rating == "" { return "safe"; }
    let s = `${rating}`.to_lower().trim();
    if s == "safe" { return "safe"; }
    if s == "suggestive" { return "suggestive"; }
    if s == "erotica" || s == "pornographic" || s == "nsfw" { return "nsfw"; }
    rating
}

/// Build content rating query parameters based on settings.
/// Returns the query string portion for content ratings.
fn build_content_rating_params() {
    let include_adult = false;
    try {
        if settings.include_adult_content != () {
            include_adult = settings.include_adult_content;
        }
    } catch {
        // Settings not available or field missing - default to safe only
    }

    // Always include safe and suggestive
    let params = "contentRating[]=safe&contentRating[]=suggestive";

    // Add adult content ratings if enabled
    if include_adult {
        params = params + "&contentRating[]=erotica&contentRating[]=pornographic";
    }

    return params;
}

/// Builds a series object from MangaDex manga data.
fn build_series_result(manga, preferred_lang) {
    let id = manga.id;
    let attrs = manga.attributes;
    let rels = manga.relationships;
    let title = extract_title(attrs.title, preferred_lang);

    // Extract alternate titles
    let alt_titles = [];
    if attrs.altTitles != () {
        for alt in attrs.altTitles {
            for key in alt.keys() {
                let alt_title = alt[key];
                if alt_title != title && !array_contains(alt_titles, alt_title) {
                    alt_titles.push(alt_title);
                }
            }
        }
    }

    // Extract description
    let description = "";
    if attrs.description != () {
        description = extract_title(attrs.description, preferred_lang);
    }
    
    // Separate genre-type tags from format/theme tags
    let all_tags = [];
    let genres = [];
    if attrs.tags != () {
        for tag in attrs.tags {
            let tag_attrs = tag.attributes;
            if tag_attrs != () && tag_attrs.name != () {
                let tag_name = extract_title(tag_attrs.name, preferred_lang);
                if tag_name != "" {
                    let group = if tag_attrs.group != () { tag_attrs.group } else { "" };
                    if group == "genre" {
                        genres.push(tag_name);
                    } else {
                        all_tags.push(tag_name);
                    }
                }
            }
        }
    }

    return #{
        id: id,
        title: title,
        alternate_titles: alt_titles,
        description: description,
        cover_url: extract_cover_url(id, rels),
        authors: extract_authors(rels),
        artists: extract_artists(rels),
        status: map_status(attrs.status),
        genres: genres,
        tags: all_tags,
        year: attrs.year,
        content_rating: map_content_rating(attrs.contentRating),
        url: `https://mangadex.org/title/${id}`,
        extra: #{
            original_language: attrs.originalLanguage,
            last_chapter: attrs.lastChapter,
            last_volume: attrs.lastVolume,
            demographic: attrs.publicationDemographic,
            auto_match_metadata: true
        }
    };
}


// --- Addon Interface Functions ---

/// Returns metadata about this source.
fn get_source_info() {
    #{
        id: "mangadex-rhai",
        name: "MangaDex",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en", "ja", "ko", "zh", "es", "fr", "de", "it", "pt-br", "ru"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

/// Helper: safely get preferred language from settings
fn get_preferred_language() {
    try {
        if settings.preferred_language != () {
            return settings.preferred_language;
        }
    } catch {}
    return "en";
}

/// Search for series matching a query.
/// Note: 'settings' is injected as a scope variable by the host
fn search_series(query, page, auth) {
    let offset = (page - 1) * 25;
    let preferred_lang = get_preferred_language();
    let content_rating_params = build_content_rating_params();

    let url = `${BASE_URL}/manga?title=${url_encode(query)}&limit=25&offset=${offset}&includes[]=cover_art&includes[]=author&includes[]=artist&${content_rating_params}`;

    let response_text = auth_http_get(url, auth);
    let response = json_parse(response_text);

    if response.result != "ok" {
        return #{ series: [], has_more: false, total: 0 };
    }

    let series = [];
    for manga in response.data {
        series.push(build_series_result(manga, preferred_lang));
    }

    let total = response.total;
    let has_more = offset + 25 < total;

    return #{ series: series, has_more: has_more, total: total };
}

/// Get detailed series information.
/// This is the main entry point expected by the scraper host.
fn get_series(id_or_url, auth) {
    return get_series_details(id_or_url, auth);
}

/// Get detailed series information (internal implementation).
fn get_series_details(id_or_url, auth) {
    let id = id_or_url;
    // Basic URL extraction
    if id_or_url.contains("mangadex.org/title/") {
        id = id_or_url.split("/")[4];
    }

    let preferred_lang = get_preferred_language();
    let url = `${BASE_URL}/manga/${id}?includes[]=cover_art&includes[]=author&includes[]=artist`;

    let response_text = auth_http_get(url, auth);
    let response = json_parse(response_text);

    if response.result != "ok" {
        throw `Failed to fetch manga with ID: ${id}`;
    }

    return build_series_result(response.data, preferred_lang);
}

/// Get all chapters for a series.
fn get_chapters(series_id, auth) {
    let id = series_id;
    // Extract UUID from full URL if needed
    if id.contains("mangadex.org/title/") {
        id = id.split("/title/")[1].split("/")[0];
    }

    let chapters = [];
    let offset = 0;
    let limit = 500; // Max limit for this endpoint
    let lang = get_preferred_language();
    let content_rating_params = build_content_rating_params();

    while true {
        let url = `${BASE_URL}/manga/${id}/feed?limit=${limit}&offset=${offset}&translatedLanguage[]=${lang}&order[chapter]=desc&includes[]=scanlation_group&${content_rating_params}`;

        let response_text = auth_http_get(url, auth);
        let response = json_parse(response_text);

        // Surface the silent-failure reason. Before: when MangaDex returned a
        // CF challenge, rate-limit response, or error JSON we silently broke
        // out of the loop and the host saw "0 chapters" with no clue why.
        // Now the host log shows exactly which response shape we bailed on,
        // so the FindNewChapters WARN ("scraper returned 0 chapters …") has
        // a paired plugin-side reason in the same docker log stream.
        if response == () {
            let snippet = if response_text.len() > 0 { response_text.sub_string(0, 200) } else { "(empty body)" };
            print(`[mangadex-rhai] get_chapters: JSON parse failed at offset=${offset} (CF block or HTTP error?) body_snippet=${snippet}`);
            break;
        }
        if response.result != "ok" {
            let err_kind = if response.errors != () && response.errors.len() > 0 && response.errors[0].detail != () { response.errors[0].detail } else { "(no detail)" };
            print(`[mangadex-rhai] get_chapters: API result=${response.result} at offset=${offset} error=${err_kind}`);
            break;
        }
        if response.data == () || response.data.len() == 0 {
            // No chapters at this offset — for offset==0 this just means the
            // series has no published chapters in the requested language. That's
            // an expected, non-error condition, so stay silent (it was spamming
            // the logs with one INFO line per such series on every monitored scan).
            break;
        }

        for chapter_data in response.data {
            let attrs = chapter_data.attributes;
            let rels = chapter_data.relationships;

            // Skip external-only chapters (licensed content hosted elsewhere, no MangaDex pages)
            if attrs.externalUrl != () && attrs.externalUrl != "" {
                continue;
            }

            let scanlator = "";
            if rels != () {
                for rel in rels {
                    if rel.type == "scanlation_group" {
                        if rel.attributes != () && rel.attributes.name != () {
                            scanlator = rel.attributes.name;
                            break;
                        }
                    }
                }
            }

            chapters.push(#{
                id: chapter_data.id,
                series_id: series_id,
                number: attrs.chapter,
                title: attrs.title,
                volume: attrs.volume,
                language: attrs.translatedLanguage,
                scanlator: scanlator,
                url: `https://mangadex.org/chapter/${chapter_data.id}`,
                published_at: attrs.publishAt,
                page_count: attrs.pages
            });
        }

        offset += limit;
        if offset >= response.total {
            break;
        }
        // Safety break for unexpected API behavior
        if offset >= 10000 { 
            break; 
        }
    }
    return chapters;
}

/// Get page URLs for a chapter.
fn get_chapter_pages(chapter_id, auth) {
    // Force port 443 to avoid unreliable volunteer CDN nodes
    let url = `${BASE_URL}/at-home/server/${chapter_id}?forcePort443=true`;

    let response_text = auth_http_get(url, auth);
    let response = json_parse(response_text);

    if response == () || response.result != "ok" {
        return [];
    }

    let chapter_data = response.chapter;
    if chapter_data == () {
        return [];
    }
    let hash = chapter_data.hash;
    if hash == () || hash == "" {
        return [];
    }

    // Build headers that look like a real browser
    let image_headers = #{
        "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Accept-Encoding": "gzip, deflate, br",
        "Sec-Fetch-Dest": "image",
        "Sec-Fetch-Mode": "no-cors",
        "Sec-Fetch-Site": "cross-site",
        "Pragma": "no-cache",
        "Cache-Control": "no-cache"
    };

    // Use the at-home server's baseUrl as per MangaDex API guidelines.
    // Falls back to uploads.mangadex.org if baseUrl is missing.
    let base_url = response.baseUrl;
    if base_url == () || base_url == "" {
        base_url = "https://uploads.mangadex.org";
    }
    // Strip trailing slash
    if base_url.ends_with("/") {
        base_url = base_url.sub_string(0, base_url.len() - 1);
    }

    let pages = [];
    let i = 0;
    for filename in chapter_data.data {
        let page_url = `${base_url}/data/${hash}/${filename}`;

        pages.push(#{
            index: i,
            url: page_url,
            headers: image_headers,
            referer: `https://mangadex.org/chapter/${chapter_id}`
        });
        i += 1;
    }
    return pages;
}

/// Get latest updates (for browse).
fn get_latest_updates(page, auth) {
    let offset = (page - 1) * 25;
    let preferred_lang = get_preferred_language();
    let content_rating_params = build_content_rating_params();

    let url = `${BASE_URL}/manga?limit=25&offset=${offset}&includes[]=cover_art&includes[]=author&includes[]=artist&order[updatedAt]=desc&${content_rating_params}`;

    let response_text = auth_http_get(url, auth);
    let response = json_parse(response_text);

    if response.result != "ok" {
        return #{ series: [], has_more: false };
    }

    let series = [];
    for manga in response.data {
        series.push(build_series_result(manga, preferred_lang));
    }

    let has_more = offset + 25 < response.total;
    return #{ series: series, has_more: has_more, total: response.total };
}

/// Get popular manga (alternative browse).
fn get_popular(page, auth) {
    let offset = (page - 1) * 25;
    let preferred_lang = get_preferred_language();
    let content_rating_params = build_content_rating_params();

    let url = `${BASE_URL}/manga?limit=25&offset=${offset}&includes[]=cover_art&includes[]=author&includes[]=artist&order[followedCount]=desc&${content_rating_params}`;

    let response_text = auth_http_get(url, auth);
    let response = json_parse(response_text);

    if response.result != "ok" {
        return [];
    }

    let series = [];
    for manga in response.data {
        series.push(build_series_result(manga, preferred_lang));
    }

    return series;
}