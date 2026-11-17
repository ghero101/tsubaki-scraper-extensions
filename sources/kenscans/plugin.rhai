// Ken Scans Scraper Add-on (Rhai)
// Scanlation group site: https://kencomics.com
//
// Built from templates/scraper-iken: the Next.js scanlation CMS that HiveToons,
// Vortex Scans, Ken Scans, Magus Manga, Nyx Scans and others run. Each site
// exposes the same public JSON API on api.<domain>/api; only the constants at
// the top differ between sites.
//
//   Browse/search: GET {API}/query?page&perPage&orderBy&order[&query_string]
//                  -> {posts:[{id, slug, postTitle, featuredImage, seriesType,
//                      seriesStatus, genres, author, artist, ...}], totalCount}
//   Chapters:      GET {API}/post/chapters?postId={id}
//                  -> [{number, slug, title, createdAt, isLocked, price}]
//                  Coin-locked early-access chapters (isLocked) are skipped:
//                  they can't be read for free, and they show up here once
//                  the group unlocks them.
//   Pages:         chapter page HTML {BASE}/series/{slug}/{chapterSlug}; the
//                  page images are the /upload/series/<folder>/... URLs in its
//                  server-rendered payload. Site chrome from the same bucket
//                  (/upload/series/featured/, /upload/settings/) is dropped.
//
// Novels share the catalogue on some sites (seriesType "NOVEL") and are
// filtered out: they have no page images.
//
// IDs: series id = slug; chapter id = "{seriesSlug}|{chapterSlug}" ('|' keeps
// it a single path segment for the server's routes).

const SITE_ID = "kenscans";
const SITE_NAME = "Ken Scans";
const BASE_URL = "https://kencomics.com";
const API_URL = "https://api.kencomics.com/api";
// (Not a const: the host only exposes string constants inside functions.)
fn per_page() { 20 }

fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "application/json, text/html;q=0.9, */*;q=0.8",
        "Origin": BASE_URL,
        "Referer": BASE_URL + "/"
    }
}

fn fetch(url) {
    let body = "";
    try { body = http_get_with_headers(url, get_headers()); } catch { body = ""; }
    if body == () { body = ""; }
    if body == "" {
        try { body = http_get_plain(url, get_headers()); } catch { body = ""; }
        if body == () { body = ""; }
    }
    body
}

fn fetch_json(url) {
    let body = fetch(url);
    if body == "" { return (); }
    let data = ();
    try { data = json_parse(body); } catch { data = (); }
    data
}

fn get_source_info() {
    #{
        id: SITE_ID,
        name: SITE_NAME,
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

fn str_or(v, d) {
    if v == () { return d; }
    let s = `${v}`.trim();
    if s == "" { d } else { s }
}

fn strip_html(s) {
    if s == () { return ""; }
    let t = `${s}`;
    t = t.replace("<br>", "\n").replace("<br/>", "\n").replace("<br />", "\n");
    t = t.replace("</p>", "\n\n");
    let tags = regex_find_all("<[^>]+>", t);
    for tag in tags { t = t.replace(tag, ""); }
    t.replace("&amp;", "&").replace("&quot;", "\"").replace("&#39;", "'").replace("&nbsp;", " ").trim()
}

fn map_status(raw) {
    let s = str_or(raw, "").to_lower();
    if s == "" { return (); }
    if s.contains("ongoing") { return "ongoing"; }
    if s.contains("complete") { return "completed"; }
    if s.contains("hiatus") { return "hiatus"; }
    if s.contains("drop") || s.contains("cancel") { return "cancelled"; }
    ()
}

fn is_novel(item) {
    str_or(item["seriesType"], "").to_upper() == "NOVEL"
}

fn slug_of(id_or_url) {
    let s = `${id_or_url}`.trim();
    let i = s.index_of("/series/");
    if i >= 0 { s = s.sub_string(i + 8); }
    s = s.split("?")[0];
    s = s.split("/")[0];
    s = s.split("|")[0];
    s
}

fn parse_item(item) {
    if type_of(item) != "map" { return (); }
    if is_novel(item) { return (); }
    let slug = str_or(item["slug"], "");
    let title = str_or(item["postTitle"], "");
    if slug == "" || title == "" { return (); }

    let genres = [];
    if item["genres"] != () {
        for g in item["genres"] {
            let name = if type_of(g) == "map" { str_or(g["name"], "") } else { str_or(g, "") };
            if name != "" && !genres.contains(name) { genres.push(name); }
        }
    }

    let alt = [];
    let raw_alt = item["alternativeTitles"];
    if type_of(raw_alt) == "string" {
        for p in raw_alt.split(",") { let t = p.trim(); if t != "" && t != title { alt.push(t); } }
    } else if type_of(raw_alt) == "array" {
        for p in raw_alt { let t = str_or(p, ""); if t != "" && t != title { alt.push(t); } }
    }

    let authors = [];
    let a = str_or(item["author"], "");
    if a != "" { authors.push(a); }
    let artists = [];
    let r = str_or(item["artist"], "");
    if r != "" { artists.push(r); }

    let year = ();
    let ry = str_or(item["releaseYear"], "");
    if ry != "" { let y = regex_find("(19|20)\\d\\d", ry); if y != "" { year = parse_int(y); } }

    let description = strip_html(item["postContent"]);

    #{
        id: slug,
        title: title,
        url: `${BASE_URL}/series/${slug}`,
        cover_url: item["featuredImage"],
        description: if description == "" { () } else { description },
        alternate_titles: alt,
        authors: authors,
        artists: artists,
        status: map_status(item["seriesStatus"]),
        genres: genres,
        tags: [],
        year: year,
        content_rating: "suggestive",
        extra: #{ source_name: SITE_NAME, post_id: item["id"], type: item["seriesType"] }
    }
}

fn query(page, order_by, q) {
    let p = if page < 1 { 1 } else { page };
    let url = `${API_URL}/query?page=${p}&perPage=${per_page()}&series_type=Comic&adult=true&order=desc&orderBy=${order_by}&status=All&tags_ids=[]`;
    if q != "" { url += `&query_string=${url_encode(q)}`; }
    let data = fetch_json(url);
    if type_of(data) != "map" || data["posts"] == () {
        return #{ series: [], has_more: false, total: 0 };
    }
    let series = [];
    for item in data["posts"] {
        let s = parse_item(item);
        if s != () { series.push(s); }
    }
    let total = if data["totalCount"] != () { data["totalCount"] } else { 0 };
    #{ series: series, has_more: p * per_page() < total, total: total }
}

fn get_latest_updates(page, auth) {
    let r = query(page, "updated_at", "");
    #{ series: r.series, has_more: r.has_more }
}

fn get_popular(page, auth) {
    query(page, "totalViews", "").series
}

// Full catalog sync: every comic on the site, by title (orderBy=postTitle is
// the one stable order the API honours), paged until totalCount is reached.
fn get_catalog(page, auth) {
    let r = query(page, "postTitle", "");
    #{ series: r.series, has_more: r.has_more }
}

fn search_series(q, page, auth) {
    query(page, "updated_at", q.trim())
}

/// The API has no by-slug detail route, so find the series through a title
/// search on its slug and pick the exact slug match.
fn find_item(slug) {
    // Direct lookup by slug ({post:{...}}); the title search below misses
    // slugs that don't read like the title ("a-stepmother-s-m-rchen" for
    // "A Stepmother's Märchen").
    let direct = fetch_json(`${API_URL}/post?postSlug=${url_encode(slug)}`);
    if type_of(direct) == "map" && type_of(direct["post"]) == "map" && str_or(direct["post"]["slug"], "") != "" {
        return direct["post"];
    }
    let terms = [slug.replace("-", " "), slug];
    for t in terms {
        let url = `${API_URL}/query?page=1&perPage=${per_page()}&series_type=Comic&adult=true&order=desc&orderBy=updated_at&status=All&tags_ids=[]&query_string=${url_encode(t)}`;
        let data = fetch_json(url);
        if type_of(data) != "map" || data["posts"] == () { continue; }
        for item in data["posts"] {
            if str_or(item["slug"], "") == slug { return item; }
        }
    }
    ()
}

fn get_series(id_or_url, auth) {
    let slug = slug_of(id_or_url);
    let item = find_item(slug);
    if item == () { throw `${SITE_NAME}: series '${slug}' not found`; }
    let s = parse_item(item);
    if s == () { throw `${SITE_NAME}: '${slug}' is not a comic`; }

    // The query result usually omits the synopsis; the series page's
    // og:description carries it.
    if s.description == () {
        let page = fetch(`${BASE_URL}/series/${slug}`);
        let m = regex_find("og:description\" content=\"[^\"]+", page);
        if m != "" {
            let d = strip_html(m.replace("og:description\" content=\"", ""));
            if d != "" { s.description = d; }
        }
    }
    s
}

fn get_chapters(series_id, auth) {
    let slug = slug_of(series_id);
    let item = find_item(slug);
    if item == () { throw `${SITE_NAME}: series '${slug}' not found`; }
    let data = fetch_json(`${API_URL}/post/chapters?postId=${item["id"]}`);
    if type_of(data) == "map" && data["chapters"] != () { data = data["chapters"]; }
    if type_of(data) != "array" { return []; }

    let chapters = [];
    for ch in data {
        if ch["isLocked"] == true { continue; }
        let ch_slug = str_or(ch["slug"], "");
        if ch_slug == "" { continue; }
        let number = str_or(ch["number"], "0");
        if number.ends_with(".0") { number = number.sub_string(0, number.len() - 2); }
        let title = str_or(ch["title"], "");
        let c = #{
            id: `${slug}|${ch_slug}`,
            series_id: slug,
            number: number,
            title: if title == "" { `Chapter ${number}` } else { `Chapter ${number}: ${title}` },
            language: "en",
            scanlator: SITE_NAME,
            url: `${BASE_URL}/series/${slug}/${ch_slug}`
        };
        if ch["createdAt"] != () { c.published_at = ch["createdAt"]; }
        chapters.push(c);
    }
    chapters
}

fn get_chapter_pages(chapter_id, auth) {
    let id = `${chapter_id}`;
    let slug = "";
    let ch_slug = "";
    if id.contains("|") {
        let parts = id.split("|");
        slug = parts[0];
        ch_slug = parts[1];
    } else {
        let i = id.index_of("/series/");
        if i < 0 { throw `${SITE_NAME}: bad chapter id ${id}`; }
        let parts = id.sub_string(i + 8).split("/");
        slug = parts[0];
        if parts.len() > 1 { ch_slug = parts[1]; }
    }
    let url = `${BASE_URL}/series/${slug}/${ch_slug}`;
    let html = fetch(url);
    if html == "" { throw `${SITE_NAME}: could not load ${url}`; }

    let found = regex_find_all("https://[^\"'\\s\\\\]+/upload/series/[^\"'\\s\\\\]+\\.(?:webp|jpe?g|png|gif|avif)", html);
    let pages = [];
    let seen = #{};
    let idx = 0;
    for u in found {
        if u.contains("/upload/series/featured/") || u.contains("/upload/settings/") { continue; }
        if seen.contains(u) { continue; }
        seen[u] = true;
        pages.push(#{ index: idx, url: u, headers: #{ "Referer": BASE_URL + "/" }, referer: BASE_URL + "/" });
        idx += 1;
    }
    pages
}
