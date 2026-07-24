// ComicK Scraper Add-on (Rhai)
// Scraper for comick.art — large aggregator with JSON API + HTML page parsing
//
// Architecture:
//   - Search: GET /api/search?q={query}&type=comic
//   - Browse: GET /api/chapters/latest?order=new&page={page} (page-based pagination)
//   - Series details: GET /api/search?q={slug}&type=comic (match by slug)
//   - Chapter list: GET /api/comics/{slug}/chapter-list?lang=en&page={page}
//   - Chapter pages: HTML parse /comic/{slug}/{hid}-chapter-{chap}-en (extract images JSON from inline script)
//
// URL Patterns:
//   Series:  /comic/{slug}
//   Chapter: /comic/{slug}/{hid}-chapter-{chap}-en
//
// IDs:
//   Series: slug (e.g., "solo-leveling-ragnarok")
//   Chapter compound: {slug}|{hid}|{chap} (e.g., "solo-leveling-ragnarok|abc123|42")
//
// CDN: https://cdn1.comicknew.pictures

const BASE_URL = "https://comick.art";
const CDN_URL = "https://cdn1.comicknew.pictures";

// ============================================================================
// HTTP Helpers
// ============================================================================

/// Build standard headers for ComicK requests.
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "application/json, text/html, */*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Referer": `${BASE_URL}/`
    }
}

/// GET request with standard headers.
fn api_get(url) {
    let body = http_get_with_headers(url, get_headers());
    if body == "" {
        throw `Empty response from: ${url}`;
    }
    body
}

/// GET and parse JSON response.
fn api_get_json(url) {
    let body = api_get(url);
    let data = json_parse(body);
    if data == () {
        throw `Failed to parse JSON from: ${url}`;
    }
    data
}

// ============================================================================
// Helpers
// ============================================================================

/// Strip basic HTML tags from a description string.
fn strip_html(text) {
    if text == () || text == "" {
        return "";
    }
    // Remove HTML tags
    let result = text;
    let tag_start = result.index_of("<");
    while tag_start >= 0 {
        let tag_end = result.index_of(">");
        if tag_end > tag_start {
            result = result.sub_string(0, tag_start) + result.sub_string(tag_end + 1);
        } else {
            break;
        }
        tag_start = result.index_of("<");
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

/// Map ComicK numeric status to standard string.
/// 1=Ongoing, 2=Completed, 3=Cancelled, 4=Hiatus
fn map_status(status) {
    if status == () {
        return ();
    }
    if status == 1 { return "Ongoing"; }
    if status == 2 { return "Completed"; }
    if status == 3 { return "Cancelled"; }
    if status == 4 { return "Hiatus"; }
    // Handle string statuses as fallback
    let s = `${status}`.to_lower();
    if s == "1" || s.contains("ongoing") { return "Ongoing"; }
    if s == "2" || s.contains("complet") { return "Completed"; }
    if s == "3" || s.contains("cancel") { return "Cancelled"; }
    if s == "4" || s.contains("hiatus") { return "Hiatus"; }
    ()
}

/// Build a cover URL from the default_thumbnail field.
/// ComicK thumbnails are either full URLs or relative paths on CDN.
fn build_cover_url(thumbnail) {
    if thumbnail == () || thumbnail == "" {
        return "";
    }
    if thumbnail.starts_with("http") {
        return thumbnail;
    }
    if thumbnail.starts_with("/") {
        return `${CDN_URL}${thumbnail}`;
    }
    `${CDN_URL}/${thumbnail}`
}

/// Extract slug from a ComicK URL or return as-is if already a slug.
fn extract_slug(id_or_url) {
    if id_or_url == () || id_or_url == "" {
        return "";
    }
    // Handle full URL: https://comick.art/comic/solo-leveling-ragnarok
    if id_or_url.contains("/comic/") {
        let parts = id_or_url.split("/comic/");
        if parts.len() > 1 {
            // Take the slug part, remove any trailing path segments
            let slug = parts[1].split("/")[0].split("?")[0].split("#")[0];
            return slug;
        }
    }
    // Handle comick.art URL without /comic/ (unlikely but safe)
    if id_or_url.contains("comick.art/") || id_or_url.contains("comick.live/") {
        let parts = id_or_url.split("/");
        let last = parts[parts.len() - 1];
        if last != "" {
            return last;
        }
    }
    // Assume it's already a slug
    id_or_url
}

/// Build a series result map from a ComicK search API item.
fn build_series_from_search(item) {
    let slug = item["slug"];
    if slug == () || slug == "" {
        slug = item["hid"];
    }
    if slug == () || slug == "" {
        return ();
    }

    let title = item["title"];
    if title == () || title == "" {
        title = slug;
    }

    let description = "";
    let raw_desc = item["description"];
    if raw_desc != () && raw_desc != "" {
        description = strip_html(raw_desc);
    }

    let cover_url = build_cover_url(item["default_thumbnail"]);

    let status = map_status(item["status"]);

    let year = ();
    let raw_year = item["year"];
    if raw_year != () {
        year = raw_year;
    }

    // Alternate titles from titles array (simple string array in search)
    let alt_titles = [];
    let titles_arr = item["titles"];
    if titles_arr != () && type_of(titles_arr) == "array" {
        for t in titles_arr {
            if t != () && t != "" && t != title {
                alt_titles.push(t);
            }
        }
    }

    // Also check limited_titles (array of {title, lang} objects)
    let limited = item["limited_titles"];
    if limited != () && type_of(limited) == "array" {
        for lt in limited {
            let lt_title = lt["title"];
            if lt_title != () && lt_title != "" && lt_title != title && !alt_titles.contains(lt_title) {
                alt_titles.push(lt_title);
            }
        }
    }

    // Content rating
    let content_rating = "safe";
    let cr = item["content_rating"];
    if cr != () && cr != "" {
        let cr_lower = `${cr}`.to_lower();
        if cr_lower == "erotica" || cr_lower == "pornographic" || cr_lower == "adult" {
            content_rating = "nsfw";
        } else if cr_lower == "suggestive" {
            content_rating = "suggestive";
        }
    }

    // Country -> tags
    let tags = [];
    let country = item["country"];
    if country != () && country != "" {
        let cl = country.to_lower();
        if cl == "jp" || cl == "ja" { tags.push("manga"); }
        else if cl == "kr" || cl == "ko" { tags.push("manhwa"); }
        else if cl == "cn" || cl == "zh" { tags.push("manhua"); }
    }

    #{
        id: slug,
        title: title,
        alternate_titles: alt_titles,
        description: description,
        cover_url: cover_url,
        authors: [],
        artists: [],
        status: status,
        genres: [],
        tags: tags,
        year: year,
        content_rating: content_rating,
        url: `${BASE_URL}/comic/${slug}`,
        extra: #{
            source_name: "ComicK",
            auto_match_metadata: true,
            hid: if item["hid"] != () { item["hid"] } else { "" },
            bayesian_rating: if item["bayesian_rating"] != () { item["bayesian_rating"] } else { () },
            chapter_count: if item["chapter_count"] != () { item["chapter_count"] } else { () },
            last_chapter: if item["last_chapter"] != () { item["last_chapter"] } else { () }
        }
    }
}

// ============================================================================
// Required Interface Functions
// ============================================================================

/// Returns metadata about this source.
fn get_source_info() {
    #{
        id: "comick",
        name: "ComicK",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en", "ja", "ko", "zh", "es", "fr", "pt", "de", "it", "ru"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

/// Search for series matching a query.
/// ComicK search API returns all results at once (no pagination for text search).
fn search_series(query, page, auth) {
    if query == () || query.trim() == "" {
        return #{ series: [], has_more: false, total: 0 };
    }

    let encoded_query = url_encode(query.trim());
    let url = `${BASE_URL}/api/search?q=${encoded_query}&type=comic&showAll=false&exclude_mylist=false&order_by=user_follow_count&order_direction=desc`;

    let data = ();
    try {
        data = api_get_json(url);
    } catch(err) {
        return #{ series: [], has_more: false, total: 0 };
    }

    // Response can be either {data:[...]} or just an array
    let items = [];
    if type_of(data) == "array" {
        items = data;
    } else if data["data"] != () && type_of(data["data"]) == "array" {
        items = data["data"];
    }

    let series = [];
    for item in items {
        let s = build_series_from_search(item);
        if s != () {
            series.push(s);
        }
    }

    // Text search returns all results at once, no pagination
    #{ series: series, has_more: false, total: series.len() }
}

/// Browse latest updates with page-based pagination.
fn browse(page, category, auth) {
    get_latest_updates(page, auth)
}

/// Get latest chapter updates (page-based pagination).
fn get_latest_updates(page, auth) {
    let url = `${BASE_URL}/api/chapters/latest?order=new&page=${page}`;

    let data = ();
    try {
        data = api_get_json(url);
    } catch(err) {
        return #{ series: [], has_more: false };
    }

    // Response: {data: [{id, slug, title, default_thumbnail, ...}]}
    let items = [];
    if type_of(data) == "array" {
        items = data;
    } else if data["data"] != () && type_of(data["data"]) == "array" {
        items = data["data"];
    }

    let series = [];
    let seen = #{};

    for item in items {
        let slug = item["slug"];
        if slug == () || slug == "" {
            continue;
        }
        // Deduplicate (latest endpoint may list same series multiple times)
        if seen[slug] != () {
            continue;
        }
        seen[slug] = true;

        let title = item["title"];
        if title == () || title == "" {
            title = slug;
        }

        let cover_url = build_cover_url(item["default_thumbnail"]);

        let content_rating = "safe";
        let cr = item["content_rating"];
        if cr != () && cr != "" {
            let cr_lower = `${cr}`.to_lower();
            if cr_lower == "erotica" || cr_lower == "adult" || cr_lower == "pornographic" {
                content_rating = "nsfw";
            } else if cr_lower == "suggestive" {
                content_rating = "suggestive";
            }
        }

        // Extract genres if available
        let genres = [];
        let genre_list = item["genres"];
        if genre_list != () && type_of(genre_list) == "array" {
            for g in genre_list {
                let gname = g["slug"];
                if gname == () { gname = g["name"]; }
                if gname != () && gname != "" {
                    genres.push(gname);
                }
            }
        }

        series.push(#{
            id: slug,
            title: title,
            alternate_titles: [],
            description: "",
            cover_url: cover_url,
            authors: [],
            artists: [],
            status: (),
            genres: genres,
            tags: [],
            year: (),
            content_rating: content_rating,
            url: `${BASE_URL}/comic/${slug}`,
            extra: #{
                source_name: "ComicK",
                auto_match_metadata: true
            }
        });
    }

    // Latest endpoint has page-based pagination; assume more if we got a decent number of results
    let has_more = series.len() >= 10;

    #{ series: series, has_more: has_more }
}

/// Fetch full series details from /api/comics/{hid} and merge into base result.
/// Returns merged result with authors, artists, and complete genres.
fn enrich_from_detail(base_result, hid) {
    if hid == () || hid == "" {
        return base_result;
    }

    let detail = ();
    try {
        detail = api_get_json(`${BASE_URL}/api/comics/${hid}`);
    } catch {
        return base_result;
    }

    if detail == () {
        return base_result;
    }

    // The detail endpoint wraps the comic under "comic" key
    let comic = detail["comic"];
    if comic == () {
        comic = detail;
    }

    // Extract authors and artists from detail response
    let authors = [];
    let authors_list = detail["authors"];
    if authors_list == () { authors_list = comic["authors"]; }
    if authors_list != () && type_of(authors_list) == "array" {
        for a in authors_list {
            let name = a["name"];
            if name != () && name != "" { authors.push(name); }
        }
    }

    let artists = [];
    let artists_list = detail["artists"];
    if artists_list == () { artists_list = comic["artists"]; }
    if artists_list != () && type_of(artists_list) == "array" {
        for a in artists_list {
            let name = a["name"];
            if name != () && name != "" { artists.push(name); }
        }
    }

    // Extract full genres from detail (more complete than search result)
    let genres = base_result["genres"];
    let detail_genres = detail["genres"];
    if detail_genres == () { detail_genres = comic["genres"]; }
    if detail_genres != () && type_of(detail_genres) == "array" {
        genres = [];
        for g in detail_genres {
            let gname = g["name"];
            if gname == () { gname = g["slug"]; }
            if gname != () && gname != "" { genres.push(gname); }
        }
    }

    // Extract description if missing from search result
    let description = base_result["description"];
    if description == () || description == "" {
        let raw_desc = comic["description"];
        if raw_desc != () && raw_desc != "" {
            description = strip_html(raw_desc);
        }
    }

    #{
        id: base_result["id"],
        title: base_result["title"],
        alternate_titles: base_result["alternate_titles"],
        description: description,
        cover_url: base_result["cover_url"],
        authors: authors,
        artists: artists,
        status: base_result["status"],
        genres: genres,
        tags: base_result["tags"],
        year: base_result["year"],
        content_rating: base_result["content_rating"],
        url: base_result["url"],
        extra: base_result["extra"]
    }
}

/// Get detailed series information by slug or URL.
///
/// comick.art removed the JSON detail endpoint (/api/comics/{slug|hid} now 404)
/// AND the search API no longer matches a full hyphenated slug query, so the old
/// search-by-slug + enrich path returned nothing. Instead we parse the comic-data
/// JSON the series HTML page embeds:
///   <script type="application/json" id="comic-data">{ ...full comic... }</script>
/// which carries title, md_titles, desc, status, year, content_rating, genres
/// (md_comic_md_genres[].md_genres.name), authors[], artists[], default_thumbnail.
fn get_series(id_or_url, auth) {
    let slug = extract_slug(id_or_url);
    if slug == "" {
        throw `Invalid series ID or URL: ${id_or_url}`;
    }

    let html = "";
    try {
        html = http_get_with_headers(`${BASE_URL}/comic/${slug}`, get_headers());
    } catch(err) {
        throw `Failed to fetch series page: ${slug} - ${err}`;
    }
    if html == "" { throw `Empty series page: ${slug}`; }

    let marker = `<script type="application/json" id="comic-data">`;
    let start = html.index_of(marker);
    let comic = ();
    if start >= 0 {
        let rest = html.sub_string(start + marker.len());
        let end = rest.index_of("</script>");
        if end > 0 {
            let json_str = rest.sub_string(0, end);
            try { comic = json_parse(json_str); } catch { comic = (); }
        }
    }
    if comic == () || type_of(comic) != "map" {
        throw `Could not parse comic data for: ${slug}`;
    }

    let title = if comic["title"] != () && comic["title"] != "" { comic["title"] } else { slug };

    let alt = [];
    let mdt = comic["md_titles"];
    if mdt != () && type_of(mdt) == "array" {
        for t in mdt {
            if type_of(t) == "map" {
                let tt = t["title"];
                if tt != () && tt != "" { alt.push(tt); }
            }
        }
    }

    let genres = [];
    let mg = comic["md_comic_md_genres"];
    if mg != () && type_of(mg) == "array" {
        for g in mg {
            if type_of(g) == "map" {
                let inner = g["md_genres"];
                if inner != () && type_of(inner) == "map" {
                    let n = inner["name"];
                    if n != () && n != "" { genres.push(n); }
                }
            }
        }
    }

    let authors = [];
    let al = comic["authors"];
    if al != () && type_of(al) == "array" {
        for a in al { if type_of(a) == "map" { let n = a["name"]; if n != () && n != "" { authors.push(n); } } }
    }
    let artists = [];
    let arl = comic["artists"];
    if arl != () && type_of(arl) == "array" {
        for a in arl { if type_of(a) == "map" { let n = a["name"]; if n != () && n != "" { artists.push(n); } } }
    }

    let description = ();
    let raw_desc = comic["desc"];
    if raw_desc != () && raw_desc != "" { description = strip_html(raw_desc); }

    let cover = build_cover_url(comic["default_thumbnail"]);
    let status = map_status(comic["status"]);
    let year = comic["year"];

    let content_rating = ();
    let cr = comic["content_rating"];
    if cr != () && `${cr}` != "" { content_rating = `${cr}`; }

    let hid = if comic["hid"] != () { comic["hid"] } else { "" };

    return #{
        id: slug,
        title: title,
        alternate_titles: alt,
        description: description,
        cover_url: cover,
        authors: authors,
        artists: artists,
        status: status,
        genres: genres,
        tags: [],
        year: year,
        content_rating: content_rating,
        url: `${BASE_URL}/comic/${slug}`,
        extra: #{ hid: hid }
    };
}

/// Get all chapters for a series.
/// Paginates through the chapter-list API endpoint.
fn get_chapters(series_id, auth) {
    let slug = extract_slug(series_id);
    if slug == "" {
        return [];
    }

    let chapters = [];
    let current_page = 1;
    let max_pages = 200; // Safety limit

    while current_page <= max_pages {
        let url = `${BASE_URL}/api/comics/${slug}/chapter-list?lang=en&page=${current_page}`;

        let data = ();
        try {
            data = api_get_json(url);
        } catch {
            break;
        }

        // Response: {data: [...], pagination: {current_page, per_page, last_page, total}}
        let items = [];
        if type_of(data) == "array" {
            items = data;
        } else if data["data"] != () && type_of(data["data"]) == "array" {
            items = data["data"];
        }

        if items.len() == 0 {
            break;
        }

        for ch in items {
            let hid = ch["hid"];
            if hid == () || hid == "" {
                continue;
            }

            let chap = "";
            let raw_chap = ch["chap"];
            if raw_chap != () && raw_chap != "" {
                chap = `${raw_chap}`;
            } else {
                chap = "0";
            }

            let title = ();
            let raw_title = ch["title"];
            if raw_title != () && raw_title != "" {
                title = raw_title;
            }

            let volume = ();
            let raw_vol = ch["vol"];
            if raw_vol != () && raw_vol != "" {
                volume = `${raw_vol}`;
            }

            let language = "en";
            let raw_lang = ch["lang"];
            if raw_lang != () && raw_lang != "" {
                language = raw_lang;
            }

            let scanlator = ();
            let groups = ch["group_name"];
            if groups != () && type_of(groups) == "array" && groups.len() > 0 {
                scanlator = groups[0];
            }

            let published_at = ();
            let raw_pub = ch["publish_at"];
            if raw_pub != () && raw_pub != "" {
                published_at = raw_pub;
            } else {
                let raw_created = ch["created_at"];
                if raw_created != () && raw_created != "" {
                    published_at = raw_created;
                }
            }

            // Compound ID: slug|hid|chap (need chap for page URL construction)
            let compound_id = `${slug}|${hid}|${chap}`;

            // Build reader URL
            let reader_url = `${BASE_URL}/comic/${slug}/${hid}-chapter-${chap}-en`;

            chapters.push(#{
                id: compound_id,
                series_id: slug,
                number: chap,
                title: title,
                volume: volume,
                language: language,
                scanlator: scanlator,
                url: reader_url,
                published_at: published_at,
                page_count: (),
                extra: #{
                    hid: hid
                }
            });
        }

        // Check pagination
        let pagination = data["pagination"];
        if pagination != () {
            let last_page = pagination["last_page"];
            if last_page != () {
                // Ensure numeric comparison (API may return int or string)
                let last_num = parse_int(`${last_page}`);
                if current_page >= last_num {
                    break;
                }
            }
            // If no last_page but we got items, continue
        } else {
            // No pagination info — check if items suggest more pages
            if items.len() < 10 {
                break;
            }
        }

        current_page += 1;
    }

    // Sort chapters ascending by chapter number
    chapters.sort(|a, b| {
        let num_a = parse_float(a["number"]);
        let num_b = parse_float(b["number"]);
        if num_a < num_b { -1 } else if num_a > num_b { 1 } else { 0 }
    });

    chapters
}

/// Get page image URLs for a chapter.
/// Fetches the HTML reader page and extracts the images JSON from an inline <script> tag.
/// Chapter ID format: {slug}|{hid}|{chap}
fn get_chapter_pages(chapter_id, auth) {
    // Parse compound ID
    let parts = chapter_id.split("|");
    if parts.len() < 3 {
        // Try with just slug|hid (chap defaults to "0")
        if parts.len() == 2 {
            let slug = parts[0];
            let hid = parts[1];
            return fetch_pages_from_html(slug, hid, "0");
        }
        throw `Invalid chapter_id format: "${chapter_id}" (expected "slug|hid|chap")`;
    }

    let slug = parts[0];
    let hid = parts[1];
    let chap = parts[2];

    fetch_pages_from_html(slug, hid, chap)
}

/// Fetch and extract page images from the ComicK reader HTML page.
/// The page contains an inline <script> tag with a JSON object that includes an "images" array.
fn fetch_pages_from_html(slug, hid, chap) {
    // Build the reader URL
    let url = `${BASE_URL}/comic/${slug}/${hid}-chapter-${chap}-en`;

    let html = "";
    try {
        html = api_get(url);
    } catch(err) {
        throw `Failed to fetch chapter page: ${err}`;
    }

    if html == "" || html.len() < 500 {
        throw `Empty or too short response from chapter page: ${url}`;
    }

    // Strategy 1: Extract from inline JSON containing "images" array.
    // The HTML contains a <script> tag with JSON data including: "images":[{...},{...}]
    // Each image object has fields like: h, w, name, url
    // We use regex to find the images array and parse each image URL.
    let pages = extract_images_from_json(html);

    // Strategy 2: If Strategy 1 fails, look for CDN image URLs directly in the HTML
    if pages.len() == 0 {
        pages = extract_images_from_cdn_urls(html);
    }

    // Strategy 3: Look for img tags with CDN sources
    if pages.len() == 0 {
        pages = extract_images_from_img_tags(html);
    }

    if pages.len() == 0 {
        throw `No page images found for chapter: ${slug} ch.${chap} (${hid})`;
    }

    pages
}

/// Extract images from the inline JSON "images" array in the HTML.
/// Looks for the pattern "images":[...] and parses individual image objects.
fn extract_images_from_json(html) {
    let pages = [];

    // Find the "images":[ pattern in the HTML
    let marker = "\"images\":[";
    let marker_pos = html.index_of(marker);

    if marker_pos < 0 {
        // Try alternate patterns
        marker = "\"images\": [";
        marker_pos = html.index_of(marker);
    }

    if marker_pos < 0 {
        return pages;
    }

    // Extract the array content starting from the marker
    let start = marker_pos + marker.len();
    let remaining = html.sub_string(start);

    // Find the matching closing bracket by tracking nesting depth
    let depth = 1;
    let end_pos = 0;
    let i = 0;
    while i < remaining.len() && depth > 0 {
        let ch = remaining.sub_string(i, 1);
        if ch == "[" {
            depth += 1;
        } else if ch == "]" {
            depth -= 1;
            if depth == 0 {
                end_pos = i;
            }
        }
        i += 1;
        // Safety limit
        if i > 500000 {
            break;
        }
    }

    if end_pos == 0 {
        return pages;
    }

    let array_content = remaining.sub_string(0, end_pos);

    // Parse individual image objects from the array
    // Each object looks like: {"h":1350,"w":950,"name":"filename.jpg","url":"https://cdn1.comicknew.pictures/..."}
    // Extract all "url":"..." values
    let url_matches = regex_find_all("\"url\"\\s*:\\s*\"([^\"]+)\"", array_content);

    let idx = 0;
    for url_match in url_matches {
        // Extract the URL value from the match
        let img_url = url_match.replace("\"url\":", "").replace("\"", "").replace(" ", "").trim();

        // Clean up: handle escaped slashes
        img_url = img_url.replace("\\/", "/");

        if img_url != "" && (img_url.contains("comicknew") || img_url.contains("cdn") || img_url.starts_with("http")) {
            pages.push(#{
                index: idx,
                url: img_url,
                headers: #{
                    "Referer": `${BASE_URL}/`
                },
                referer: `${BASE_URL}/`
            });
            idx += 1;
        }
    }

    pages
}

/// Fallback: Extract CDN image URLs directly from the HTML using regex.
fn extract_images_from_cdn_urls(html) {
    let pages = [];

    // Find all CDN URLs that look like page images
    let cdn_matches = regex_find_all("https?://cdn1\\.comicknew\\.pictures/[^\"'\\s<>]+\\.(jpg|jpeg|png|webp|avif)", html);

    let seen = #{};
    let idx = 0;

    for url_match in cdn_matches {
        // Clean up the URL
        let img_url = url_match.trim();

        // Remove any trailing characters that aren't part of the URL
        let q_pos = img_url.index_of("?");
        // Keep query params if present (might be needed for auth)

        // Deduplicate
        if seen[img_url] != () {
            continue;
        }
        seen[img_url] = true;

        pages.push(#{
            index: idx,
            url: img_url,
            headers: #{
                "Referer": `${BASE_URL}/`
            },
            referer: `${BASE_URL}/`
        });
        idx += 1;
    }

    pages
}

/// Fallback: Extract images from <img> tags with CDN sources.
fn extract_images_from_img_tags(html) {
    let pages = [];

    let imgs = html_select(html, "img[src*=\"comicknew\"]");

    let idx = 0;
    for img in imgs {
        let src = element_attr(img, "src");
        if src == () || src == "" {
            src = element_attr(img, "data-src");
        }
        if src != () && src != "" && src.contains("comicknew") {
            pages.push(#{
                index: idx,
                url: src,
                headers: #{
                    "Referer": `${BASE_URL}/`
                },
                referer: `${BASE_URL}/`
            });
            idx += 1;
        }
    }

    pages
}
