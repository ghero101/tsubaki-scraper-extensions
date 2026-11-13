// Drake Scans Scraper Add-on (Rhai)
// Scanlation group site: https://drakecomic.net
//
// Built from templates/scraper-nextcms: the Next.js scanlation platform that
// Drake Scans, Elf Toon and Valir Scans run (same markup, same /api routes).
// Only the constants at the top differ between sites.
//
//   Browse:   /series?page=N (default order = latest update; &sort=popular)
//             -> cards: [data-card-set-item] a[href^="/series/comic/"] > img[alt]
//   Search:   GET /api/search?q=QUERY&contentMode=all -> {series:[{slug, title,
//             coverImage, status, type, chapterCount}]}
//   Series:   /series/comic/{slug}. The page's React payload carries the series
//             record ("series":{"id",...,"aliases","description","status",
//             "genres"}) and the first 100 chapters; the ld+json Book block has
//             the author.
//   Chapters: those 100 from the page, then GET /api/chapters/next?seriesId=
//             &afterNumber=N&limit=10 (the reader's own "next chapter" call,
//             10 per call, hasMore) for the rest.
//             Coin-locked early-access chapters are skipped.
//   Pages:    /series/comic/{slug}/chapter/{number}: "pages":[{pageNumber,
//             kind, isRedacted, imageUrl, isEncrypted, hasFragments, ...}].
//             Plain image URLs on these sites; if a chapter ever comes back
//             encrypted or fragmented (the platform supports both) we refuse
//             rather than save scrambled files.
//
// Novels share the catalogue (/series/novel/...) and are left out.
// IDs: series id = slug; chapter id = "{slug}|{number}".

const SITE_ID = "drakescans";
const SITE_NAME = "Drake Scans";
const BASE_URL = "https://drakecomic.net";

fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Referer": BASE_URL + "/"
    }
}

fn fetch(url) {
    let body = "";
    try { body = http_get_with_headers(url, get_headers()); } catch { body = ""; }
    if body == () { body = ""; }
    if body == "" || (body.contains("Just a moment...") && body.contains("challenge")) {
        try { body = http_get_plain(url, get_headers()); } catch { body = ""; }
        if body == () { body = ""; }
    }
    body
}

fn fetch_json(url) {
    // The /api routes answer the TLS-impersonating client with the homepage
    // HTML instead of JSON, so ask with the plain client first.
    let h = get_headers();
    h.Accept = "application/json";
    let body = "";
    try { body = http_get_plain(url, h); } catch { body = ""; }
    if body == () || !body.trim().starts_with("{") {
        try { body = http_get_with_headers(url, h); } catch { body = ""; }
    }
    if body == () { body = ""; }
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

fn absolutise(u) {
    if u == () { return (); }
    let s = `${u}`.trim();
    if s == "" { return (); }
    if s.starts_with("http") { return s; }
    if s.starts_with("//") { return "https:" + s; }
    if !s.starts_with("/") { s = "/" + s; }
    BASE_URL + s
}

fn map_status(raw) {
    let s = `${raw}`.to_lower();
    if s.contains("ongoing") { return "ongoing"; }
    if s.contains("complete") { return "completed"; }
    if s.contains("hiatus") { return "hiatus"; }
    if s.contains("drop") || s.contains("cancel") { return "cancelled"; }
    ()
}

fn slug_of(id_or_url) {
    let s = `${id_or_url}`.trim();
    let i = s.index_of("/series/comic/");
    if i >= 0 { s = s.sub_string(i + 14); }
    s = s.split("|")[0];
    s = s.split("?")[0];
    s.split("/")[0]
}

/// Undo the escaping of a value cut out of the React flight payload (a JSON
/// string inside a JS string, so quotes arrive as \" and unicode as \\u....).
fn unescape(s) {
    s.replace("\\\\\"", "\"").replace("\\\"", "\"").replace("\\\\n", "\n").replace("\\n", "\n").trim()
}

/// Text between `start` and the next `end` at or after `from`, or "".
fn cut(text, start, end, from) {
    let i = text.index_of(start, from);
    if i < 0 { return ""; }
    let a = i + start.len();
    let j = text.index_of(end, a);
    if j < 0 { return ""; }
    text.sub_string(a, j - a)
}

// ---------------------------------------------------------------- listing

fn cover_from_img(img) {
    let src = element_attr(img, "src");
    if src == () { return (); }
    let m = regex_find("url=[^&]+", src);
    if m != "" { return absolutise(url_decode(m.sub_string(4))); }   // next/image wraps a site-relative /uploads path
    absolutise(src)
}

fn parse_cards(html) {
    let out = [];
    let seen = #{};
    for a in html_select(html, "[data-card-set-item] a[href^='/series/comic/'], a[href^='/series/comic/']") {
        let href = element_attr(a, "href");
        if href == () || href.contains("/chapter/") { continue; }
        let slug = slug_of(href);
        if slug == "" || seen.contains(slug) { continue; }
        let imgs = html_select(a, "img");
        if imgs.len() == 0 { continue; }
        let title = element_attr(imgs[0], "alt");
        if title == () || title.trim() == "" { continue; }
        seen[slug] = true;
        out.push(#{
            id: slug,
            title: title.trim(),
            url: `${BASE_URL}/series/comic/${slug}`,
            cover_url: cover_from_img(imgs[0]),
            alternate_titles: [], authors: [], artists: [], genres: [], tags: [],
            content_rating: "suggestive",
            extra: #{ source_name: SITE_NAME }
        });
    }
    out
}

fn listing(page, sort) {
    let p = if page < 1 { 1 } else { page };
    let url = `${BASE_URL}/series?page=${p}`;
    if sort != "" { url += `&sort=${sort}`; }
    let html = fetch(url);
    if html == "" { return #{ series: [], has_more: false }; }
    let series = parse_cards(html);
    // The pager is client-side; a full page of cards means there is more.
    #{ series: series, has_more: series.len() >= 20 }
}

fn get_latest_updates(page, auth) {
    listing(page, "")
}

fn get_popular(page, auth) {
    listing(page, "popular").series
}

fn search_series(query, page, auth) {
    // The search API returns one page of best matches; there is no page 2.
    if page > 1 { return #{ series: [], has_more: false, total: 0 }; }
    let q = query.trim();
    if q.len() < 2 { return listing(page, ""); }
    let data = fetch_json(`${BASE_URL}/api/search?q=${url_encode(q)}&contentMode=all`);
    if type_of(data) != "map" || data.series == () { return #{ series: [], has_more: false, total: 0 }; }
    let out = [];
    for s in data.series {
        let t = `${s.type}`.to_upper();
        if t.contains("NOVEL") || t.contains("FICTION") { continue; }
        let slug = if s.urlSlug != () { s.urlSlug } else { s.slug };
        if slug == () || s.title == () { continue; }
        out.push(#{
            id: slug,
            title: s.title,
            url: `${BASE_URL}/series/comic/${slug}`,
            cover_url: absolutise(s.coverImage),
            status: map_status(s.status),
            alternate_titles: [], authors: [], artists: [], genres: [], tags: [],
            content_rating: if s.isMature == true { "nsfw" } else { "suggestive" },
            extra: #{ source_name: SITE_NAME, type: s.type }
        });
    }
    #{ series: out, has_more: false, total: out.len() }
}

// ---------------------------------------------------------------- series

fn ld_book(html) {
    for el in html_select(html, "script[type='application/ld+json']") {
        let d = ();
        try { d = json_parse(element_text(el)); } catch { d = (); }
        if type_of(d) == "map" && d["@type"] == "Book" { return d; }
    }
    #{}
}

fn get_series(id_or_url, auth) {
    let slug = slug_of(id_or_url);
    let url = `${BASE_URL}/series/comic/${slug}`;
    let html = fetch(url);
    if html == "" { throw `${SITE_NAME}: could not load ${url}`; }

    let book = ld_book(html);
    let at = html.index_of("\\\"series\\\":{\\\"id\\\":\\\"");
    if at < 0 { at = 0; }

    let title = if book.name != () { book.name } else { "" };
    if title == "" {
        let h1 = html_select(html, "h1");
        if h1.len() > 0 { title = element_text(h1[0]).trim(); }
    }

    let description = unescape(cut(html, "\\\"description\\\":\\\"", "\\\",\\\"coverImage\\\"", at));
    if description == "" && book.description != () { description = book.description; }

    let cover = absolutise(unescape(cut(html, "\\\"coverImage\\\":\\\"", "\\\"", at)));
    if cover == () && book.image != () { cover = absolutise(book.image); }

    let alt = [];
    let aliases = cut(html, "\\\"aliases\\\":[", "]", at);
    for m in regex_find_all("\\\\\"[^\\\\]+\\\\\"", aliases) {
        let t = unescape(m.sub_string(2, m.len() - 4));
        if t != "" && t != title && !alt.contains(t) { alt.push(t); }
    }

    let status = map_status(cut(html, "\\\"status\\\":\\\"", "\\\"", at));

    let genres = [];
    let gseg = cut(html, "\\\"genres\\\":[", "]", at);
    for m in regex_find_all("\\\\\"name\\\\\":\\\\\"[^\\\\]+", gseg) {
        let g = m.sub_string(11).trim();
        if g != "" && !genres.contains(g) { genres.push(g); }
    }

    let authors = [];
    if type_of(book.author) == "map" && book.author.name != () {
        for a in `${book.author.name}`.split("/") { let t = a.trim(); if t != "" { authors.push(t); } }
    }

    let kind = cut(html, "\\\"type\\\":\\\"", "\\\"", at);
    let mature = cut(html, "\\\"isMature\\\":", ",", at) == "true";

    #{
        id: slug,
        title: title,
        url: url,
        cover_url: cover,
        description: if description == "" { () } else { description },
        alternate_titles: alt,
        authors: authors,
        artists: [],
        status: status,
        genres: genres,
        tags: [],
        content_rating: if mature { "nsfw" } else { "suggestive" },
        extra: #{ source_name: SITE_NAME, type: kind }
    }
}

// ---------------------------------------------------------------- chapters

fn fmt_number(n) {
    let s = `${n}`;
    if s.ends_with(".0") { s = s.sub_string(0, s.len() - 2); }
    s
}

fn make_chapter(slug, number, title, published) {
    let num = fmt_number(number);
    let t = if title == () { "" } else { `${title}`.trim() };
    if t == "" || t == num { t = `Chapter ${num}`; }
    let c = #{
        id: `${slug}|${num}`,
        series_id: slug,
        number: num,
        title: t,
        language: "en",
        scanlator: SITE_NAME,
        url: `${BASE_URL}/series/comic/${slug}/chapter/${num}`
    };
    if published != () && published != "" { c.published_at = published; }
    c
}

fn get_chapters(series_id, auth) {
    let slug = slug_of(series_id);
    let url = `${BASE_URL}/series/comic/${slug}`;
    let html = fetch(url);
    if html == "" { throw `${SITE_NAME}: could not load ${url}`; }

    let at = html.index_of("\\\"series\\\":{\\\"id\\\":\\\"");
    let series_key = if at >= 0 { cut(html, "\\\"series\\\":{\\\"id\\\":\\\"", "\\\"", at) } else { "" };
    let total = 0;
    let tc = cut(html, "\\\"chapterCount\\\":", ",", if at >= 0 { at } else { 0 });
    if tc != "" { total = parse_int(tc); }

    let chapters = [];
    let seen = #{};
    let max_num = -1.0;
    // One flight-payload chapter record per match. Recommendation cards on
    // the page carry chapter stubs too, but without coinPrice/likeCount, so
    // this shape only matches the series' own list.
    let rows = regex_find_all("\\{\\\\\"id\\\\\":\\\\\"[^\\\\]+\\\\\",\\\\\"number\\\\\":[0-9.]+,\\\\\"title\\\\\":(?:null|\\\\\"(?:[^\\\\]|\\\\\\\\[^\"])*\\\\\"),\\\\\"coverImage\\\\\":[^,]*,\\\\\"isLocked\\\\\":(?:true|false),\\\\\"coinPrice\\\\\":(?:null|[0-9]+),\\\\\"viewCount\\\\\":(?:null|[0-9]+),\\\\\"likeCount\\\\\":(?:null|[0-9]+),\\\\\"publishedAt\\\\\":(?:null|\\\\\"[^\\\\]+\\\\\")", html);
    for r in rows {
        let num_s = regex_find("[0-9.]+", cut(r, "\\\"number\\\":", ",", 0));
        if num_s == "" { continue; }
        let n = parse_float(num_s);
        if n > max_num { max_num = n; }
        if r.contains("\\\"isLocked\\\":true") { continue; }
        let key = fmt_number(num_s);
        if seen.contains(key) { continue; }
        seen[key] = true;
        let title = unescape(cut(r, "\\\"title\\\":\\\"", "\\\",\\\"coverImage", 0));
        let published = cut(r, "\\\"publishedAt\\\":\\\"", "\\\"", 0);
        chapters.push(make_chapter(slug, num_s, title, published));
    }

    // The page embeds the first 100; page through the rest 10 at a time.
    let guard = 0;
    if series_key != "" && total > seen.len() && max_num >= 0.0 {
        let after = max_num;
        while guard < 200 {
            guard += 1;
            let data = fetch_json(`${BASE_URL}/api/chapters/next?seriesId=${url_encode(series_key)}&afterNumber=${fmt_number(after)}&limit=10`);
            if type_of(data) != "map" || data.chapters == () || data.chapters.len() == 0 { break; }
            let advanced = false;
            for c in data.chapters {
                let n = parse_float(`${c.number}`);
                if n > after { after = n; advanced = true; }
                if c.isLocked == true || c.hasAccess == false || c.earlyAccessLocked == true { continue; }
                let key = fmt_number(c.number);
                if seen.contains(key) { continue; }
                seen[key] = true;
                chapters.push(make_chapter(slug, c.number, c.title, c.publishedAt));
            }
            if data.hasMore != true || !advanced { break; }
        }
    }
    chapters
}

// ---------------------------------------------------------------- pages

fn get_chapter_pages(chapter_id, auth) {
    let id = `${chapter_id}`;
    let slug = "";
    let num = "";
    if id.contains("|") {
        let parts = id.split("|");
        slug = parts[0];
        num = parts[1];
    } else {
        slug = slug_of(id);
        num = regex_find("[0-9.]+$", id.split("?")[0].replace("/chapter/", "/").trim());
    }
    let url = `${BASE_URL}/series/comic/${slug}/chapter/${num}`;
    let html = fetch(url);
    if html == "" { throw `${SITE_NAME}: could not load ${url}`; }

    let at = html.index_of("\\\"pages\\\":[{");
    if at < 0 { throw `${SITE_NAME}: no pages in ${url} (locked or not released yet)`; }
    let seg = html.sub_string(at);
    if seg.contains("\\\"isEncrypted\\\":true") || seg.contains("\\\"hasFragments\\\":true") || seg.contains("\\\"hasStrips\\\":true") {
        throw `${SITE_NAME}: this chapter's pages are encrypted or split by the site; it can't be downloaded`;
    }

    let pages = [];
    let seen = #{};
    let rows = regex_find_all("\\\\\"pageNumber\\\\\":[0-9]+,\\\\\"kind\\\\\":\\\\\"[A-Z_]+\\\\\",\\\\\"isRedacted\\\\\":(?:true|false),\\\\\"imageUrl\\\\\":\\\\\"[^\\\\]+", seg);
    for r in rows {
        let n = regex_find("[0-9]+", r);
        if seen.contains(n) { continue; }
        seen[n] = true;
        if r.contains("\\\"isRedacted\\\":true") { continue; }
        let i = r.index_of("\\\"imageUrl\\\":\\\"");
        let img = absolutise(r.sub_string(i + 15));
        pages.push(#{ index: pages.len(), url: img, headers: #{ "Referer": BASE_URL + "/" }, referer: BASE_URL + "/" });
    }
    pages
}
