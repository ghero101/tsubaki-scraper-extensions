// Asura Scans Scraper Add-on (Rhai) — JSON API client.
//
// Asura migrated to an Astro SPA backed by a public JSON API at
// api.asurascans.com. The old HTML scraper broke (client-rendered grid). The
// API needs no auth/cookies/impersonation — plain GET returns JSON.
//
// API map (base https://api.asurascans.com):
//   Browse/latest: GET /api/series?page=N&sort=update&order=desc -> {data:[item]}
//   Search:        GET /api/series?search=Q&page=N               -> {data:[item]}
//   Detail:        GET /api/series/{slug}                        -> {series:{...}}
//   Chapters:      GET /api/series/{slug}/chapters               -> {data:[chap]}
//   Pages:         GET /api/series/{slug}/chapters/{chapSlug}     -> {data:{chapter:{pages:[{url}]}}}
//
// IDs: series_id = slug. chapter_id = "{seriesSlug}|{chapterSlug}" ('|' avoids
// the Actix routing issues a '/' would cause).

const BASE_URL = "https://asurascans.com";
const API_URL = "https://api.asurascans.com";

fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "application/json",
        "Referer": "https://asurascans.com/",
        "Origin": "https://asurascans.com"
    }
}

fn get_source_info() {
    #{
        id: "asurascans",
        name: "Asura Scans",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

/// GET an API path and json_parse the body. Returns () on any failure.
fn api_get(path) {
    let body = "";
    try {
        body = http_get_with_headers(`${API_URL}${path}`, get_headers());
    } catch {
        body = "";
    }
    if body == "" {
        // Fallback to the plain client (the API is open; no impersonation needed)
        try { body = http_get_plain(`${API_URL}${path}`, get_headers()); } catch { body = ""; }
    }
    if body == "" { return (); }
    let parsed = ();
    try { parsed = json_parse(body); } catch { parsed = (); }
    parsed
}

/// Safely pull the array under a top-level "data" key.
fn data_array(parsed) {
    if parsed == () { return []; }
    let arr = parsed.data;
    if type_of(arr) == "array" { return arr; }
    []
}

/// Map an API series object (list item or detail.series) to a SeriesInfo map.
fn map_series_item(item) {
    if item == () { return (); }

    let genres = [];
    let gs = item.genres;
    if type_of(gs) == "array" {
        for g in gs {
            let n = g.name;
            if n != () && n != "" { genres.push(n); }
        }
    }

    let authors = [];
    if item.author != () && item.author != "" { authors.push(item.author); }
    let artists = [];
    if item.artist != () && item.artist != "" { artists.push(item.artist); }

    let alts = [];
    if type_of(item.alt_titles) == "array" { alts = item.alt_titles; }

    let cover = item.cover;
    if cover == () || cover == "" { cover = item.cover_url; }

    #{
        id: item.slug,
        title: item.title,
        url: `${BASE_URL}/comics/${item.slug}`,
        cover_url: cover,
        alternate_titles: alts,
        authors: authors,
        artists: artists,
        status: item.status,
        genres: genres,
        tags: [],
        description: item.description
    }
}

/// Extract the bare series slug from an id or full URL.
fn to_slug(id_or_url) {
    let s = id_or_url;
    if s.contains("/comics/") {
        let parts = s.split("/comics/");
        if parts.len() > 1 { s = parts[1]; }
    } else if s.contains("/series/") {
        let parts = s.split("/series/");
        if parts.len() > 1 { s = parts[1]; }
    }
    s = s.split("/")[0].split("?")[0];
    s
}

fn search_series(query, page, auth) {
    let p = if page < 1 { 1 } else { page };
    let path = if query != "" {
        `/api/series?search=${url_encode(query)}&page=${p}`
    } else {
        `/api/series?page=${p}&sort=update&order=desc`
    };

    let parsed = api_get(path);
    let arr = data_array(parsed);

    let series = [];
    for it in arr {
        let m = map_series_item(it);
        if m != () && m.id != () && m.id != "" { series.push(m); }
    }
    #{ series: series, has_more: series.len() >= 18, total: () }
}

fn get_latest_updates(page, auth) {
    let p = if page < 1 { 1 } else { page };
    let parsed = api_get(`/api/series?page=${p}&sort=update&order=desc`);
    let arr = data_array(parsed);
    let series = [];
    for it in arr {
        let m = map_series_item(it);
        if m != () && m.id != () && m.id != "" { series.push(m); }
    }
    #{ series: series, has_more: series.len() >= 18 }
}

fn get_popular(page, auth) {
    let p = if page < 1 { 1 } else { page };
    let parsed = api_get(`/api/series?page=${p}&sort=popularity&order=desc`);
    let arr = data_array(parsed);
    let series = [];
    for it in arr {
        let m = map_series_item(it);
        if m != () && m.id != () && m.id != "" { series.push(m); }
    }
    series
}

fn get_series(id_or_url, auth) {
    let slug = to_slug(id_or_url);
    let parsed = api_get(`/api/series/${slug}`);
    if parsed == () { return (); }
    let s = parsed.series;
    if s == () { return (); }
    map_series_item(s)
}

fn get_chapters(series_id, auth) {
    let slug = to_slug(series_id);
    let parsed = api_get(`/api/series/${slug}/chapters`);
    let arr = data_array(parsed);

    let chapters = [];
    for ch in arr {
        let cslug = ch.slug;
        if cslug == () || cslug == "" { continue; }
        let num = `${ch.number}`;
        chapters.push(#{
            id: `${slug}|${cslug}`,
            series_id: series_id,
            number: num,
            title: (),
            volume: (),
            language: "en",
            scanlator: "Asura Scans",
            url: `${BASE_URL}/comics/${slug}/chapter/${num}`,
            published_at: ch.published_at,
            page_count: ch.page_count,
            extra: #{}
        });
    }

    // Ascending by chapter number (API returns newest-first).
    chapters.sort(|a, b| {
        let na = parse_float(a.number);
        let nb = parse_float(b.number);
        if na < nb { -1 } else if na > nb { 1 } else { 0 }
    });
    chapters
}

fn get_chapter_pages(chapter_id, auth) {
    // chapter_id = "{seriesSlug}|{chapterSlug}"
    let slug = chapter_id;
    let cslug = chapter_id;
    if chapter_id.contains("|") {
        let parts = chapter_id.split("|");
        slug = parts[0];
        if parts.len() > 1 { cslug = parts[1]; }
    }

    let parsed = api_get(`/api/series/${slug}/chapters/${cslug}`);
    let pages = [];
    if parsed == () { return pages; }

    // {data:{chapter:{pages:[{url}]}}}
    let d = parsed.data;
    if d == () { return pages; }
    let chap = d.chapter;
    if chap == () { return pages; }
    let plist = chap.pages;
    if type_of(plist) != "array" { return pages; }

    let idx = 0;
    for pg in plist {
        let u = pg.url;
        if u == () || u == "" { continue; }
        pages.push(#{
            index: idx,
            url: u,
            headers: #{ "Referer": "https://asurascans.com/" },
            referer: "https://asurascans.com/"
        });
        idx += 1;
    }
    pages
}
