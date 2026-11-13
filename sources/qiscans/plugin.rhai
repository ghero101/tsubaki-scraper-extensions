// Quantum Scans Scraper Add-on (Rhai)
// Scanlation group site: https://qimanga.com (formerly qiscans.org)
//
// The site is a Next.js front end over a public JSON API at
// api.qimanga.com/api/v1:
//
//   Browse:   GET /series?page&perPage[&sort=popular]   -> {data:[...], totalPages}
//   Latest:   GET /home/latest?page&perPage              -> {data:[...], next}
//   Search:   GET /series/search?q&page                  -> {data:[...], totalPages}
//   Series:   GET /series/{slug}                         -> full series record
//   Chapters: GET /series/{slug}/chapters?page&perPage   -> {data:[{slug, number,
//             title, isFree, requiresPurchase, createdAt}], next}
//   Pages:    GET /series/{slug}/chapters/{chapterSlug}  -> {images:[{url, order}]}
//
// Paid early-access chapters (requiresPurchase) are skipped: they have no
// free images, and they appear here once the group makes them free.
// Novels share the catalogue (type NOVEL) and are filtered out.
//
// IDs: series id = slug; chapter id = "{seriesSlug}|{chapterSlug}".

const SITE_ID = "qiscans";
const SITE_NAME = "Quantum Scans";
const BASE_URL = "https://qimanga.com";
const API_URL = "https://api.qimanga.com/api/v1";

fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "application/json, */*;q=0.8",
        "Origin": BASE_URL,
        "Referer": BASE_URL + "/"
    }
}

fn fetch_json(url) {
    let body = "";
    try { body = http_get_plain(url, get_headers()); } catch { body = ""; }
    if body == () || body == "" {
        try { body = http_get_with_headers(url, get_headers()); } catch { body = ""; }
    }
    if body == () || body == "" { return (); }
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
    if str_or(item["type"], "").to_upper() == "NOVEL" { return (); }
    let slug = str_or(item["slug"], "");
    let title = str_or(item["title"], "");
    if slug == "" || title == "" { return (); }

    let genres = [];
    if type_of(item["genres"]) == "array" {
        for g in item["genres"] {
            let name = if type_of(g) == "map" { str_or(g["name"], "") } else { str_or(g, "") };
            if name != "" {
                // The site lower-cases some tags ("tower"); title-case them.
                let n = name.sub_string(0, 1).to_upper() + name.sub_string(1);
                if !genres.contains(n) { genres.push(n); }
            }
        }
    }

    let alt = [];
    let raw_alt = item["alternativeTitles"];
    if type_of(raw_alt) == "string" {
        for p in raw_alt.split("•") { let t = p.trim(); if t != "" && t != title && !alt.contains(t) { alt.push(t); } }
    }

    let authors = [];
    let a = str_or(item["author"], "");
    if a != "" { authors.push(a); }
    let artists = [];
    let r = str_or(item["artist"], "");
    if r != "" { artists.push(r); }

    let description = strip_html(item["description"]);

    #{
        id: slug,
        title: title,
        url: `${BASE_URL}/series/${slug}`,
        cover_url: item["cover"],
        description: if description == "" { () } else { description },
        alternate_titles: alt,
        authors: authors,
        artists: artists,
        status: map_status(item["status"]),
        genres: genres,
        tags: [],
        content_rating: "suggestive",
        extra: #{ source_name: SITE_NAME, post_id: item["id"], type: item["type"] }
    }
}

fn list_of(data) {
    let series = [];
    if type_of(data) != "map" || type_of(data["data"]) != "array" { return series; }
    for item in data["data"] {
        let s = parse_item(item);
        if s != () { series.push(s); }
    }
    series
}

fn more_of(data, p) {
    if type_of(data) != "map" { return false; }
    if data["next"] != () { return true; }
    let tp = data["totalPages"];
    tp != () && p < tp
}

fn page_or_one(page) { if page == () || page < 1 { 1 } else { page } }

fn get_latest_updates(page, auth) {
    let p = page_or_one(page);
    let data = fetch_json(`${API_URL}/home/latest?page=${p}&perPage=24`);
    #{ series: list_of(data), has_more: more_of(data, p) }
}

fn get_popular(page, auth) {
    let p = page_or_one(page);
    list_of(fetch_json(`${API_URL}/series?page=${p}&perPage=24&sort=popular`))
}

fn search_series(q, page, auth) {
    let p = page_or_one(page);
    let data = fetch_json(`${API_URL}/series/search?q=${url_encode(q.trim())}&page=${p}`);
    #{ series: list_of(data), has_more: more_of(data, p) }
}

fn get_series(id_or_url, auth) {
    let slug = slug_of(id_or_url);
    let data = fetch_json(`${API_URL}/series/${slug}`);
    if type_of(data) != "map" || data["slug"] == () { throw `${SITE_NAME}: series '${slug}' not found`; }
    let s = parse_item(data);
    if s == () { throw `${SITE_NAME}: '${slug}' is a novel, not a comic`; }
    s
}

fn get_chapters(series_id, auth) {
    let slug = slug_of(series_id);
    let chapters = [];
    let p = 1;
    while p <= 50 {
        let data = fetch_json(`${API_URL}/series/${slug}/chapters?page=${p}&perPage=100`);
        if type_of(data) != "map" || type_of(data["data"]) != "array" {
            if p == 1 { throw `${SITE_NAME}: could not load chapters for '${slug}'`; }
            break;
        }
        for ch in data["data"] {
            if ch["requiresPurchase"] == true { continue; }
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
        if data["next"] == () { break; }
        p += 1;
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
    let data = fetch_json(`${API_URL}/series/${slug}/chapters/${ch_slug}`);
    if type_of(data) != "map" { throw `${SITE_NAME}: could not load chapter ${ch_slug}`; }
    if data["requiresPurchase"] == true {
        throw `${SITE_NAME}: this chapter is paid early access and has no free pages yet`;
    }
    let pages = [];
    if type_of(data["images"]) != "array" { return pages; }
    let imgs = data["images"];
    imgs.sort(|a, b| {
        let x = if a["order"] == () { 0 } else { a["order"] };
        let y = if b["order"] == () { 0 } else { b["order"] };
        x - y
    });
    let idx = 0;
    for img in imgs {
        let u = str_or(img["url"], "");
        if u == "" { continue; }
        pages.push(#{ index: idx, url: u, headers: #{ "Referer": BASE_URL + "/" }, referer: BASE_URL + "/" });
        idx += 1;
    }
    pages
}
