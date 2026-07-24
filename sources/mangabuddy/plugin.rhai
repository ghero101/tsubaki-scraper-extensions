// MangaBuddy Scraper Add-on (Rhai)
// HTTP-only scraper for MangaK (formerly MangaBuddy)
//
// Website: https://mangak.io   (mangabuddy.com 301-redirects here)
// Backend: Next.js SPA. Every listing/detail/reader page is server-rendered
//          with a `<script id="__NEXT_DATA__" type="application/json">` blob
//          that contains the full, structured data. We parse that JSON instead
//          of scraping the (Tailwind, class-hashed) DOM.
//
// URL / data map (confirmed live 2026-06-07):
//   Browse:   /search?sort={popular|latest|views|rating|...}&page={n}
//             -> props.pageProps.ssrItems[]  + props.pageProps.ssrPagination
//   Search:   /search?q={query}&page={n}     (server-side filtered)
//             -> same ssrItems / ssrPagination shape
//   Series:   /{slug}                         e.g. /jinx
//             -> props.pageProps.initialManga  (+ .chapters[] sibling)
//   Reader:   /{slug}/{chapter-slug}          e.g. /jinx/bounus-92-5
//             -> props.pageProps.{...}.images[]  (array of full image URLs)
//
//   ssrItem / initialManga slug: take last path segment of `url` (e.g. "/jinx" -> "jinx")
//   chapter id  : chapter `url` minus leading slash (e.g. "jinx/bounus-92-5")
//   page images : full URLs on rx.*.org CDN; REQUIRE Referer: https://mangak.io/
//
// Available Rhai APIs used:
//   http_get_with_headers(url, headers) -> string
//   http_get(url) -> string
//   json_parse(text) -> dynamic
//   regex_find(pattern, text) -> string
//   url_encode(text) -> string
//   parse_int / parse_float

const BASE_URL = "https://mangak.io";

// ============================================================================
// Helper Functions
// ============================================================================

/// Build request headers
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
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
    if html == () { html = ""; }
    html
}

/// Extract and parse the __NEXT_DATA__ JSON blob from a server-rendered page.
/// Returns the parsed `props.pageProps` map, or () on failure.
fn extract_page_props(html) {
    if html == () || html == "" {
        return ();
    }

    // Locate the opening of the __NEXT_DATA__ script tag.
    let marker = "__NEXT_DATA__\"";
    let m_idx = html.index_of(marker);
    if m_idx == () || m_idx < 0 {
        return ();
    }

    // Find the start of the JSON object: first '{' after the '>' that closes the tag.
    let gt_idx = html.index_of(">", m_idx);
    if gt_idx == () || gt_idx < 0 {
        return ();
    }
    let json_start = html.index_of("{", gt_idx);
    if json_start == () || json_start < 0 {
        return ();
    }

    // The JSON ends at "</script>" following json_start.
    let end_idx = html.index_of("</script>", json_start);
    if end_idx == () || end_idx < 0 {
        return ();
    }

    let json_str = html.sub_string(json_start, end_idx - json_start);

    let parsed = ();
    try {
        parsed = json_parse(json_str);
    } catch {
        return ();
    }

    if type_of(parsed) != "map" {
        return ();
    }
    let props = parsed["props"];
    if type_of(props) != "map" {
        return ();
    }
    let page_props = props["pageProps"];
    if type_of(page_props) != "map" {
        return ();
    }
    page_props
}

/// Make URL absolute
fn make_absolute_url(url) {
    if url == () || url == "" {
        return "";
    }
    if url.starts_with("http") {
        return url;
    }
    if url.starts_with("//") {
        return `https:${url}`;
    }
    if url.starts_with("/") {
        return `${BASE_URL}${url}`;
    }
    `${BASE_URL}/${url}`
}

/// Extract the manga slug (last path segment) from a site URL/path.
/// e.g. "/jinx" -> "jinx", "https://mangak.io/jinx" -> "jinx"
fn slug_from_url(url) {
    if url == () { return ""; }
    let path = url;

    if path.contains("://") {
        let parts = path.split("://");
        if parts.len() > 1 {
            path = parts[1];
            // drop host
            let seg = path.split("/");
            if seg.len() > 1 {
                path = "";
                for i in 1..seg.len() {
                    path += "/" + seg[i];
                }
            } else {
                path = "";
            }
        }
    }

    if path.contains("?") {
        path = path.split("?")[0];
    }
    if path.starts_with("/") {
        path = path.sub_string(1);
    }
    if path.ends_with("/") {
        path = path.sub_string(0, path.len() - 1);
    }
    // Series slug is the single segment (series URLs are /{slug}); if a longer
    // path is given, take the FIRST segment as the series slug.
    let parts = path.split("/");
    if parts.len() > 0 && parts[0] != "" {
        return parts[0];
    }
    path
}

/// Strip the leading slash from a chapter URL to form a stable chapter id.
/// e.g. "/jinx/bounus-92-5" -> "jinx/bounus-92-5"
fn chapter_id_from_url(url) {
    if url == () { return ""; }
    let path = url;
    if path.contains("://") {
        let parts = path.split("://");
        if parts.len() > 1 {
            let seg = parts[1].split("/");
            path = "";
            for i in 1..seg.len() {
                if path != "" { path += "/"; }
                path += seg[i];
            }
            return path;
        }
    }
    if path.starts_with("/") {
        path = path.sub_string(1);
    }
    path
}

/// Map status text to standard format
fn map_status(text) {
    if text == () { return (); }
    let lower = `${text}`.to_lower();
    if lower.contains("ongoing") || lower.contains("releasing") {
        return "Ongoing";
    }
    if lower.contains("completed") || lower.contains("complete") || lower.contains("finished") {
        return "Completed";
    }
    if lower.contains("hiatus") {
        return "Hiatus";
    }
    if lower.contains("cancelled") || lower.contains("canceled") || lower.contains("dropped") {
        return "Cancelled";
    }
    ()
}

/// Pull a string field from a map, returning "" when absent/null
fn get_str(map, key) {
    if type_of(map) != "map" { return ""; }
    let v = map[key];
    if v == () { return ""; }
    `${v}`
}

/// Convert a chapter number (int/float) to a clean STRING.
/// 164 -> "164", 85.5 -> "85.5"
fn num_to_str(n) {
    if n == () { return ""; }
    let t = type_of(n);
    if t == "i64" || t == "int" {
        return `${n}`;
    }
    if t == "f64" || t == "float" {
        // Drop trailing ".0" for whole numbers
        let i = n.to_int();
        let frac = n - i.to_float();
        if frac < 0.0001 && frac > -0.0001 {
            return `${i}`;
        }
        return `${n}`;
    }
    `${n}`
}

/// Build a search/browse series-card map from an ssrItem object
fn item_to_series(item) {
    let url = get_str(item, "url");
    let slug = slug_from_url(url);
    if slug == "" {
        slug = get_str(item, "slug");
    }
    let title = get_str(item, "name");
    let cover = make_absolute_url(get_str(item, "cover"));

    #{
        id: slug,
        title: title,
        url: make_absolute_url(url),
        cover_url: cover,
        status: map_status(get_str(item, "status"))
    }
}

// ============================================================================
// Required Interface Functions
// ============================================================================

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "mangabuddy-rhai",
        name: "MangaBuddy",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only",
        nsfw: false,
        content_types: ["manga", "manhwa", "manhua"]
    }
}

/// Internal: fetch a /search listing page and turn ssrItems into series cards.
/// Returns #{ series, has_more }.
fn fetch_listing(url, page) {
    let html = fetch_html(url);
    let props = extract_page_props(html);

    if props == () {
        return #{ series: [], has_more: false, total: 0 };
    }

    let series = [];
    let seen = #{};

    let items = props["ssrItems"];
    if type_of(items) == "array" {
        for item in items {
            if type_of(item) != "map" { continue; }
            let card = item_to_series(item);
            if card.id == "" || card.title == "" { continue; }
            if seen[card.id] != () { continue; }
            seen[card.id] = true;
            series.push(card);
        }
    }

    // Pagination from ssrPagination.has_next / total_pages
    let has_more = false;
    let pag = props["ssrPagination"];
    if type_of(pag) == "map" {
        let hn = pag["has_next"];
        if hn == true {
            has_more = true;
        } else {
            let tp = pag["total_pages"];
            if type_of(tp) == "i64" || type_of(tp) == "int" {
                if page < tp { has_more = true; }
            }
        }
    }

    #{ series: series, has_more: has_more, total: 0 }
}

/// Search for manga matching a query (server-side filtered via ?q=)
fn search_series(query, page, auth) {
    let encoded = url_encode(query);
    let url = `${BASE_URL}/search?q=${encoded}&page=${page}`;
    let result = fetch_listing(url, page);

    // Enrich cards with the metadata fields the search contract expects.
    let out = [];
    for c in result.series {
        out.push(#{
            id: c.id,
            title: c.title,
            alternate_titles: [],
            description: (),
            cover_url: c.cover_url,
            authors: [],
            artists: [],
            status: c.status,
            genres: [],
            tags: [],
            year: (),
            content_rating: "suggestive",
            url: c.url,
            extra: #{
                source_site: "mangabuddy",
                auto_match_metadata: true,
                source_name: "MangaBuddy"
            }
        });
    }

    #{ series: out, has_more: result.has_more, total: 0 }
}

/// Get detailed series information by slug or URL
fn get_series(id_or_url, auth) {
    let slug = id_or_url;
    let url = "";

    if id_or_url.starts_with("http") {
        slug = slug_from_url(id_or_url);
        url = `${BASE_URL}/${slug}`;
    } else if id_or_url.starts_with("/") {
        slug = slug_from_url(id_or_url);
        url = `${BASE_URL}/${slug}`;
    } else {
        slug = id_or_url;
        url = `${BASE_URL}/${slug}`;
    }

    let html = fetch_html(url);
    let props = extract_page_props(html);

    if props == () {
        throw `Failed to fetch series page: ${url}`;
    }

    let manga = props["initialManga"];
    if type_of(manga) != "map" {
        throw `Series data not found: ${url}`;
    }

    // --- Title ---
    let title = get_str(manga, "name");
    if title == "" {
        title = slug.replace("-", " ");
    }

    // --- Alternate Titles (altNames: [{name, language?}]) ---
    let alt_titles = [];
    let alt_names = manga["altNames"];
    if type_of(alt_names) == "array" {
        for a in alt_names {
            let nm = "";
            if type_of(a) == "map" {
                nm = get_str(a, "name");
            } else {
                nm = `${a}`;
            }
            nm = nm.trim();
            if nm != "" && nm != title && !alt_titles.contains(nm) {
                alt_titles.push(nm);
            }
        }
    }
    if alt_titles.len() == 0 {
        let an = get_str(manga, "altName");
        if an != "" && an != title {
            alt_titles.push(an);
        }
    }

    // --- Cover ---
    let cover_url = make_absolute_url(get_str(manga, "cover"));

    // --- Description (summary) ---
    let description = ();
    let summary = get_str(manga, "summary");
    if summary != "" {
        description = summary;
    }

    // --- Authors ---
    let authors = [];
    let author_arr = manga["authors"];
    if type_of(author_arr) == "array" {
        for a in author_arr {
            let nm = "";
            if type_of(a) == "map" { nm = get_str(a, "name"); } else { nm = `${a}`; }
            nm = nm.trim();
            if nm != "" && nm != "Updating" && !authors.contains(nm) {
                authors.push(nm);
            }
        }
    }

    // --- Artists ---
    let artists = [];
    let artist_arr = manga["artists"];
    if type_of(artist_arr) == "array" {
        for a in artist_arr {
            let nm = "";
            if type_of(a) == "map" { nm = get_str(a, "name"); } else { nm = `${a}`; }
            nm = nm.trim();
            if nm != "" && nm != "Updating" && !artists.contains(nm) {
                artists.push(nm);
            }
        }
    }

    // --- Genres ---
    let genres = [];
    let genre_arr = manga["genres"];
    if type_of(genre_arr) == "array" {
        for g in genre_arr {
            let nm = "";
            if type_of(g) == "map" { nm = get_str(g, "name"); } else { nm = `${g}`; }
            nm = nm.trim();
            if nm != "" && !genres.contains(nm) {
                genres.push(nm);
            }
        }
    }

    // --- Status ---
    let status = map_status(get_str(manga, "status"));

    // --- Content rating (isAdult flag) ---
    let content_rating = "suggestive";
    if manga["isAdult"] == true {
        content_rating = "pornographic";
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
        tags: [],
        year: (),
        content_rating: content_rating,
        url: url,
        extra: #{
            source_site: "mangabuddy",
            auto_match_metadata: true,
            source_name: "MangaBuddy"
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let slug = series_id;
    if series_id.starts_with("http") || series_id.starts_with("/") {
        slug = slug_from_url(series_id);
    }

    let url = `${BASE_URL}/${slug}`;
    let html = fetch_html(url);
    let props = extract_page_props(html);

    if props == () {
        return [];
    }

    // The full chapter list lives in pageProps.chapters[] (sibling of initialManga).
    let chapter_arr = props["chapters"];
    if type_of(chapter_arr) != "array" {
        // Some payloads nest it under initialManga.chapters
        let manga = props["initialManga"];
        if type_of(manga) == "map" {
            chapter_arr = manga["chapters"];
        }
    }
    if type_of(chapter_arr) != "array" {
        return [];
    }

    let chapters = [];
    let seen = #{};

    for item in chapter_arr {
        if type_of(item) != "map" { continue; }

        let ch_url = get_str(item, "url");
        if ch_url == "" {
            // build from slug + chapter slug
            let cslug = get_str(item, "slug");
            if cslug == "" { cslug = get_str(item, "id"); }
            if cslug == "" { continue; }
            ch_url = `/${slug}/${cslug}`;
        }

        let ch_id = chapter_id_from_url(ch_url);
        if ch_id == "" { continue; }
        if seen[ch_id] != () { continue; }
        seen[ch_id] = true;

        let name = get_str(item, "name");

        // Chapter number: prefer the numeric `chapterNumber` field.
        let number = num_to_str(item["chapterNumber"]);
        if number == "" {
            // Fallback: pull a number out of the name.
            let n = regex_find("\\d+\\.?\\d*", name);
            if n != "" { number = n; } else { number = "0"; }
        }

        let display_title = name;
        if display_title == "" {
            display_title = `Chapter ${number}`;
        }

        let published = get_str(item, "updatedAt");
        if published == "" { published = get_str(item, "date"); }
        if published == "" { published = (); }

        chapters.push(#{
            id: ch_id,
            series_id: slug,
            number: number,
            title: display_title,
            volume: (),
            language: "en",
            scanlator: (),
            url: make_absolute_url(ch_url),
            published_at: published,
            page_count: (),
            extra: #{}
        });
    }

    chapters
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;
    if chapter_id.starts_with("http") {
        url = chapter_id;
    } else if chapter_id.starts_with("/") {
        url = `${BASE_URL}${chapter_id}`;
    } else {
        url = `${BASE_URL}/${chapter_id}`;
    }

    let html = fetch_html(url);
    let props = extract_page_props(html);

    let pages = [];
    let idx = 0;

    // Page images: a flat array of full CDN URLs. It may sit directly under
    // pageProps, or under a nested chapter object. Search a few likely spots.
    let images = ();

    if type_of(props) == "map" {
        // Page images live under pageProps.initialChapter.images (flat array of
        // full CDN URLs). Fall back to a top-level `images` array, then to any
        // nested map exposing an `images` array.
        let ic = props["initialChapter"];
        if type_of(ic) == "map" && type_of(ic["images"]) == "array" {
            images = ic["images"];
        }
        if type_of(images) != "array" && type_of(props["images"]) == "array" {
            images = props["images"];
        }
        if type_of(images) != "array" {
            for k in props.keys() {
                let v = props[k];
                if type_of(v) == "map" && type_of(v["images"]) == "array" {
                    images = v["images"];
                    break;
                }
            }
        }
    }

    if type_of(images) == "array" {
        for img in images {
            let img_url = "";
            if type_of(img) == "map" {
                // Object form: {url} or {storage_key}
                img_url = get_str(img, "url");
                if img_url == "" {
                    img_url = get_str(img, "image");
                }
            } else {
                img_url = `${img}`;
            }
            img_url = img_url.trim();
            if img_url == "" { continue; }
            img_url = make_absolute_url(img_url);

            pages.push(#{
                index: idx,
                url: img_url,
                headers: #{
                    "Referer": `${BASE_URL}/`,
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
                },
                referer: `${BASE_URL}/`
            });
            idx += 1;
        }
    }

    // Fallback: regex over the raw HTML for the images array if JSON parse missed it.
    if pages.len() == 0 && html != "" {
        let img_urls = regex_find_all("https?://[a-zA-Z0-9._/-]+\\.(?:webp|jpg|jpeg|png)", html);
        let seen = #{};
        for u in img_urls {
            // Only accept CDN page images (rx.* hosts), skip cover/asset URLs.
            if !u.contains("/r/p/") && !u.contains("/p/") { continue; }
            if seen[u] != () { continue; }
            seen[u] = true;
            pages.push(#{
                index: idx,
                url: u,
                headers: #{
                    "Referer": `${BASE_URL}/`,
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
                },
                referer: `${BASE_URL}/`
            });
            idx += 1;
        }
    }

    pages
}

/// Get latest manga updates
fn get_latest_updates(page, auth) {
    let url = `${BASE_URL}/search?sort=latest&page=${page}`;
    let result = fetch_listing(url, page);

    let series = [];
    for c in result.series {
        series.push(#{
            id: c.id,
            title: c.title,
            url: c.url,
            cover_url: c.cover_url,
            updated_at: ()
        });
    }

    #{ series: series, has_more: result.has_more }
}

/// Browse manga (main browse endpoint)
fn browse(page, category, auth) {
    if category == "latest" || category == "updated" || category == "new" {
        return get_latest_updates(page, auth);
    }

    // Map category to a supported sort; default to popularity.
    let sort = "popular";
    if category == "views" || category == "rating" || category == "newest" ||
       category == "chapters" || category == "alphabetical" || category == "completed" ||
       category == "ongoing" || category == "hiatus" {
        sort = category;
    }

    let url = `${BASE_URL}/search?sort=${sort}&page=${page}`;
    let result = fetch_listing(url, page);

    let series = [];
    for c in result.series {
        series.push(#{
            id: c.id,
            title: c.title,
            url: c.url,
            cover_url: c.cover_url
        });
    }

    #{ series: series, has_more: result.has_more }
}
