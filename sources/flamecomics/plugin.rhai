// Flame Comics Scraper Add-on (Rhai)
// Browser-based scraper for Next.js site with __NEXT_DATA__ JSON
//
// Available APIs:
//   HTTP (fallback): http_get(url), http_get_with_headers(url, headers)
//   Browser: browser_launch(), browser_goto(id, url), browser_wait_for_cloudflare(id, timeout)
//            browser_get_html(id), browser_close(id), browser_is_available()
//   HTML: html_parse(html), html_select(html, selector), element_text(el), element_attr(el, attr)
//   JSON: json_parse(text)

const BASE_URL = "https://flamecomics.xyz";
const CDN_URL = "https://cdn.flamecomics.xyz";

/// Fetch HTML using browser automation (bypasses Cloudflare)
/// Falls back to HTTP if browser not available
fn fetch_html(url) {
    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 15000);

            // Wait for Next.js content to render
            browser_wait_for_selector(browser_id, "#__NEXT_DATA__", 10000);

            let html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            return html;
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    // Fallback to HTTP
    http_get(url)
}

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "flamecomics-rhai",
        name: "Flame Comics",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "browser_automation"
    }
}

/// Extract __NEXT_DATA__ JSON from Next.js HTML
fn extract_next_data(html) {
    let start_marker = `<script id="__NEXT_DATA__" type="application/json">`;
    let end_marker = `</script>`;

    let start = html.index_of(start_marker);
    if start == () {
        return ();
    }

    let json_start = start + start_marker.len();
    let rest = html.sub_string(json_start);
    let end = rest.index_of(end_marker);

    if end == () {
        return ();
    }

    let json_str = rest.sub_string(0, end);
    json_parse(json_str)
}

/// Search for series matching query.
///
/// Uses /api/series — the same endpoint browse() uses — instead of scraping the
/// homepage's __NEXT_DATA__. The homepage only ships ~20-30 series in
/// `latestEntries`, so the old implementation silently returned zero results for
/// any catalog series outside that window. /api/series returns the full ~145
/// series and does not require CF bypass.
///
/// Trade-off: we lose authors/artists/description/tags in search results, but
/// callers fill these in via get_series anyway and the matrix of "find any
/// series by name" now actually works.
fn search_series(query, page, auth) {
    let url = `${BASE_URL}/api/series`;
    let response = http_get(url);

    if response == "" || response == () {
        return #{ series: [], has_more: false, total: 0 };
    }

    let data = json_parse(response);
    if data == () || data.len() == 0 {
        return #{ series: [], has_more: false, total: 0 };
    }

    let query_lower = query.to_lower();
    let series = [];

    for item in data {
        let id = item["id"];
        let title = item["label"];
        let image = item["image"];
        let status = item["status"];

        if id == () || title == () {
            continue;
        }

        // Empty query returns everything (browse-all behavior).
        if query != "" && !title.to_lower().contains(query_lower) {
            continue;
        }

        series.push(#{
            id: `${id}`,
            title: title,
            url: `${BASE_URL}/series/${id}`,
            cover_url: build_cover_url(id, image),
            alternate_titles: [],
            authors: [],
            artists: [],
            status: status,
            genres: [],
            tags: [],
            description: ()
        });
    }

    #{ series: series, has_more: false, total: series.len() }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let series_id = id_or_url;

    if id_or_url.contains("/series/") {
        let parts = id_or_url.split("/series/");
        if parts.len() > 1 {
            series_id = parts[1].split("/")[0];
        }
    }

    let url = `${BASE_URL}/series/${series_id}`;
    let html = fetch_html(url);
    let next_data = extract_next_data(html);

    if next_data == () {
        return #{
            id: series_id,
            title: "",
            error: "Failed to extract data"
        };
    }

    let props = next_data["props"];
    let page_props = props["pageProps"];
    let series_data = page_props["series"];

    if series_data == () {
        return #{
            id: series_id,
            title: "",
            error: "Series not found"
        };
    }

    let title = series_data["title"];
    let cover = series_data["cover"];
    let description = series_data["description"];
    let alt_titles = series_data["altTitles"];
    let authors = series_data["author"];
    let artists = series_data["artist"];
    let tags = series_data["tags"];

    // status + year are present in the __NEXT_DATA__ series object.
    let status = ();
    let status_raw = series_data["status"];
    if status_raw != () && `${status_raw}` != "" {
        let s = `${status_raw}`.to_lower();
        if s.contains("ongoing") || s.contains("releasing") { status = "Ongoing"; }
        else if s.contains("completed") || s.contains("finished") { status = "Completed"; }
        else if s.contains("hiatus") { status = "Hiatus"; }
        else if s.contains("cancel") || s.contains("dropped") { status = "Cancelled"; }
        else { status = status_raw; }
    }
    let year = ();
    let year_raw = series_data["year"];
    if year_raw != () && `${year_raw}` != "" && `${year_raw}` != "0" { year = year_raw; }

    #{
        id: series_id,
        title: if title != () { title } else { "" },
        alternate_titles: if alt_titles != () { alt_titles } else { [] },
        description: strip_html(description),
        cover_url: build_cover_url(series_id, cover),
        authors: if authors != () { authors } else { [] },
        artists: if artists != () { artists } else { [] },
        status: status,
        genres: if tags != () { tags } else { [] },
        tags: [],
        year: year,
        content_rating: "suggestive",
        url: url,
        extra: #{ auto_match_metadata: true, source_name: "Flame Comics" }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let url = series_id;
    let original_series_id = series_id;

    if !series_id.starts_with("http") {
        url = `${BASE_URL}/series/${series_id}`;
    } else {
        let parts = series_id.split("/series/");
        if parts.len() > 1 {
            original_series_id = parts[1].split("/")[0];
        }
    }

    let html = fetch_html(url);
    let next_data = extract_next_data(html);

    if next_data == () {
        return [];
    }

    let props = next_data["props"];
    let page_props = props["pageProps"];
    let chapters_data = page_props["chapters"];

    if chapters_data == () {
        return [];
    }

    let chapters = [];

    for ch in chapters_data {
        let chapter_id = ch["chapter_id"];
        let token = ch["token"];  // Token is required for reader URL
        let chapter_num = ch["chapter"];
        let title = ch["title"];
        let ch_series_id = ch["series_id"];

        // Use compound ID (series_id:token) so get_chapter_pages can build correct URL
        chapters.push(#{
            id: `${ch_series_id}:${token}`,  // Compound ID: series_id:token
            series_id: `${ch_series_id}`,
            number: chapter_num,
            title: title,
            volume: (),
            language: "en",
            scanlator: "Flame Comics",
            url: `${BASE_URL}/series/${ch_series_id}/${token}`,
            published_at: (),
            page_count: (),
            extra: #{
                chapter_id: `${chapter_id}`,  // Store original chapter_id in extra
                token: token
            }
        });
    }

    chapters.sort(|a, b| {
        let num_a = parse_float(a.number);
        let num_b = parse_float(b.number);
        if num_a > num_b { -1 } else if num_a < num_b { 1 } else { 0 }
    });

    chapters
}

/// Get page URLs for a chapter
/// chapter_id can be:
/// - A token (e.g., "51b1d42b24b70dd6") - needs series_id to build URL
/// - A full URL (e.g., "https://flamecomics.xyz/series/51/51b1d42b24b70dd6")
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;

    if !chapter_id.starts_with("http") {
        // chapter_id is a token, but we don't know the series_id
        // Try to parse it as a compound ID: "series_id:token"
        if chapter_id.contains(":") {
            let parts = chapter_id.split(":");
            let series_id = parts[0];
            let token = parts[1];
            url = `${BASE_URL}/series/${series_id}/${token}`;
        } else {
            // Assume it's just a token - we need to figure out the series ID
            // For backwards compatibility, try the old format first
            url = `${BASE_URL}/series/0/${chapter_id}`;
        }
    }

    let html = fetch_html(url);
    let next_data = extract_next_data(html);

    if next_data == () {
        return [];
    }

    let props = next_data["props"];
    let page_props = props["pageProps"];

    // Check if page is 404
    let page_type = next_data["page"];
    if page_type == "/404" {
        return [];
    }

    // Images are inside the chapter object
    let chapter_data = page_props["chapter"];
    if chapter_data == () {
        return [];
    }

    let images = chapter_data["images"];
    if images == () {
        return [];
    }

    // Get series_id and token from chapter data for building CDN URLs
    let series_id_num = chapter_data["series_id"];
    let chapter_token = chapter_data["token"];
    let edit_time = chapter_data["edit_time"];  // Used as cache-buster

    // CDN URL pattern: https://cdn.flamecomics.xyz/uploads/images/series/{series_id}/{token}/{filename}
    let cdn_base = "https://cdn.flamecomics.xyz";

    let pages = [];

    // Images is an object with numeric string keys ("0", "1", etc.)
    // Each value has: name, size, type, width, height, modified
    let keys = images.keys();
    keys.sort(|a, b| {
        let num_a = parse_int(a);
        let num_b = parse_int(b);
        if num_a < num_b { -1 } else if num_a > num_b { 1 } else { 0 }
    });

    let idx = 0;
    for key in keys {
        let img_data = images[key];
        let filename = img_data["name"];

        // Build CDN URL
        let img_url = `${cdn_base}/uploads/images/series/${series_id_num}/${chapter_token}/${filename}`;
        if edit_time != () {
            img_url = `${img_url}?${edit_time}`;
        }

        pages.push(#{
            index: idx,
            url: img_url,
            headers: #{
                "Referer": BASE_URL
            },
            referer: BASE_URL
        });
        idx += 1;
    }

    pages
}

/// Get latest updates - uses the /api/series endpoint which returns all series
/// FlameComics is a small site with ~145 series total, no real pagination
fn get_latest_updates(page, auth) {
    // Only fetch on page 1 - the API returns all series at once
    if page > 1 {
        return #{ series: [], has_more: false };
    }

    let url = `${BASE_URL}/api/series`;
    let response = http_get(url);

    if response == "" || response == () {
        return #{ series: [], has_more: false };
    }

    let data = json_parse(response);
    if data == () || data.len() == 0 {
        return #{ series: [], has_more: false };
    }

    let series = [];
    for item in data {
        let id = item["id"];
        let title = item["label"];
        let image = item["image"];
        let status = item["status"];

        if id == () || title == () {
            continue;
        }

        series.push(#{
            id: `${id}`,
            title: title,
            url: `${BASE_URL}/series/${id}`,
            cover_url: build_cover_url(id, image),
            status: status,
            genres: [],
            tags: []
        });
    }

    #{ series: series, has_more: false }
}

/// Helper: Build cover URL from series_id and cover filename
fn build_cover_url(series_id, cover) {
    if cover == () || cover == "" {
        return ();
    }
    `${CDN_URL}/uploads/images/series/${series_id}/${cover}`
}

/// Helper: Strip HTML tags from text
fn strip_html(text) {
    if text == () {
        return "";
    }

    let result = text;

    // Remove common HTML tags
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

    // Remove remaining tags using a simple approach
    // Find < and remove everything until >
    loop {
        let start = result.index_of("<");
        if start == () {
            break;
        }
        let end = result.index_of(">");
        if end == () {
            break;
        }
        if end > start {
            result = result.sub_string(0, start) + result.sub_string(end + 1);
        } else {
            break;
        }
    }

    // Trim whitespace
    result.trim()
}

/// Helper: Parse float from string
fn parse_float(s) {
    if s == () { return 0.0; }
    let result = 0.0;
    let parts = s.split(".");
    if parts.len() > 0 {
        result = parse_int(parts[0]);
    }
    if parts.len() > 1 {
        let decimal = parse_int(parts[1]);
        let divisor = 1.0;
        for i in 0..parts[1].len() {
            divisor *= 10.0;
        }
        result += decimal / divisor;
    }
    result
}
