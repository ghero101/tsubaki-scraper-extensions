// RoliaScan Scraper Add-on (Rhai)
// Manga scanlation site scraper (HTTP-only, no browser automation required)
//
// Available APIs:
//   HTTP: http_get(url), http_get_with_headers(url, headers)
//   HTML: html_parse(html), html_select(html, selector), element_text(el), element_attr(el, attr)
//   JSON: json_parse(text)
//   Utility: url_encode(text), regex_match(pattern, text), regex_find(pattern, text)

const BASE_URL = "https://roliascan.com";

fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Accept": "text/html,application/xhtml+xml",
        "Referer": BASE_URL
    }
}

fn fetch_html(url) {
    try {
        return http_get_with_headers(url, get_headers());
    } catch {
        return "";
    }
}

fn get_source_info() {
    #{
        id: "roliascan-rhai",
        name: "RoliaScan",
        base_url: BASE_URL,
        language: "en",
        requires_authentication: false,
        capability_level: "http_only"
    }
}

// The /browse/ grid and its search box both call this JSON endpoint
// (mangalist.js): POST {page, search, sort, ...filters} -> array of
// {id, title, url, cover, status, type, year, description}. 24 per page,
// an empty array past the last page. No JS rendering or auth needed.
fn load_catalog(page, search, sort) {
    let p = if page == () || page < 1 { 1 } else { page };
    let body = json_stringify(#{
        page: p,
        search: search,
        years: "[]",
        genres: "[]",
        types: "[]",
        statuses: "[]",
        sort: sort,
        genreMatchMode: "any"
    });
    let headers = get_headers();
    headers["Accept"] = "application/json";
    headers["Content-Type"] = "application/json";
    let raw = "";
    try {
        raw = http_post_json_with_headers(`${BASE_URL}/wp-json/manga/v1/load`, body, headers);
    } catch {
        return [];
    }
    let data = json_parse(raw);
    if type_of(data) != "array" { return []; }

    let series = [];
    for item in data {
        let url = item["url"];
        let title = item["title"];
        if url == () || url == "" || title == () || title == "" { continue; }
        let status = ();
        let s = item["status"];
        if s != () {
            let sl = s.to_lower();
            if sl.contains("ongoing") { status = "Ongoing"; }
            else if sl.contains("completed") { status = "Completed"; }
            else if sl.contains("hiatus") { status = "Hiatus"; }
            else if sl.contains("cancel") || sl.contains("dropped") { status = "Cancelled"; }
        }
        let year = ();
        if item["year"] != () && item["year"] != "" { year = parse_int(`${item["year"]}`); }
        series.push(#{
            id: url,
            title: html_unescape(title),
            url: url,
            cover_url: item["cover"],
            description: item["description"],
            alternate_titles: [],
            authors: [],
            status: status,
            year: year,
            genres: [],
            extra: #{ roliascan_id: `${item["id"]}`, type: item["type"] }
        });
    }
    series
}

// String replace that works whichever `replace` overload Rhai resolves
// (the built-in mutates in place and returns (), the host's returns a copy).
fn rep(s, from, to) {
    let t = s;
    let r = t.replace(from, to);
    if type_of(r) == "string" { r } else { t }
}

fn html_unescape(s) {
    if s == () { return s; }
    let t = s;
    t = rep(t, "&#8217;", "’");
    t = rep(t, "&#8216;", "‘");
    t = rep(t, "&#8220;", "“");
    t = rep(t, "&#8221;", "”");
    t = rep(t, "&#8211;", "–");
    t = rep(t, "&#038;", "&");
    t = rep(t, "&amp;", "&");
    t = rep(t, "&quot;", "\"");
    t = rep(t, "&#039;", "'");
    t
}

fn search_series(query, page, auth) {
    let series = load_catalog(page, query, "post_desc");
    #{ series: series, has_more: series.len() >= 24, total: series.len() }
}

fn get_series(id_or_url, auth) {
    let url = normalize_url(id_or_url);

    let html = fetch_html(url);
    let doc = html_parse(html);

    // Get title from h1
    let title = "";
    let h1s = html_select(doc, "h1");
    if h1s.len() > 0 {
        title = element_text(h1s[0]).trim();
    }

    // Get cover image
    let cover = ();
    let cover_imgs = html_select(doc, "img.poster, img.coverimage, .thumb img");
    if cover_imgs.len() > 0 {
        cover = element_attr(cover_imgs[0], "src");
    }
    if cover == () {
        // Fallback - find first image in the page that looks like a cover
        let all_imgs = html_select(doc, "img");
        for img in all_imgs {
            let src = element_attr(img, "src");
            if src != () && (src.contains("-cover-") || src.contains("fandommanga.xyz")) {
                cover = src;
                break;
            }
        }
    }

    // Get description
    let description = ();
    let desc_els = html_select(doc, "p");
    for el in desc_els {
        let text = element_text(el).trim();
        if text.len() > 50 && !text.contains("©") && !text.contains("roliascan") {
            description = text;
            break;
        }
    }

    // Get genres from links
    let genres = [];
    let genre_links = html_select(doc, "a[href*='/genre/'], a[href*='/tag/']");
    for link in genre_links {
        let g = element_text(link).trim();
        if g != "" && !genres.contains(g) { genres.push(g); }
    }

    // Get authors
    let authors = [];
    let author_links = html_select(doc, "a[href*='/author/']");
    for link in author_links {
        let a = element_text(link).trim();
        if a != "" && !authors.contains(a) { authors.push(a); }
    }

    // Get artists
    let artists = [];
    let artist_links = html_select(doc, "a[href*='/artist/']");
    for link in artist_links {
        let a = element_text(link).trim();
        if a != "" && !artists.contains(a) { artists.push(a); }
    }

    // Get status
    let status = ();
    let status_links = html_select(doc, "a[href*='/status/']");
    if status_links.len() > 0 {
        let s = element_text(status_links[0]).trim().to_lower();
        if s.contains("ongoing") { status = "Ongoing"; }
        else if s.contains("completed") { status = "Completed"; }
        else if s.contains("hiatus") { status = "Hiatus"; }
    }

    // The detail page lists metadata in a <th>label</th><td>value</td> table
    // (no /author/ or /status/ links). Pair th[i] with td[i] globally — nested
    // per-row selection proved unreliable on this host.
    if status == () || authors.len() == 0 || artists.len() == 0 {
        let th_els = html_select(doc, "th");
        let td_els = html_select(doc, "td");
        let n = if th_els.len() < td_els.len() { th_els.len() } else { td_els.len() };
        for i in 0..n {
            let label = element_text(th_els[i]).trim().to_lower();
            let value = element_text(td_els[i]).trim();
            if value == "" || value == "-" || value.to_lower() == "updating" { continue; }
            if label.contains("status") && status == () {
                let s = value.to_lower();
                if s.contains("ongoing") { status = "Ongoing"; }
                else if s.contains("completed") { status = "Completed"; }
                else if s.contains("hiatus") { status = "Hiatus"; }
                else if s.contains("cancel") || s.contains("dropped") { status = "Cancelled"; }
            } else if label.contains("author") && authors.len() == 0 {
                authors.push(value);
            } else if label.contains("artist") && artists.len() == 0 {
                artists.push(value);
            }
        }
    }

    // The site's own quick-search (POST /auth/search) returns the full
    // synopsis, alt titles, author list and status that the page truncates
    // or renders only via JS. Match our series by slug.
    let alt_titles = [];
    let slug_m = regex_find("/manga/[^/?#]+", url);
    if title != "" && slug_m != "" {
        let slug = slug_m.sub_string(7);
        let headers = get_headers();
        headers["Accept"] = "application/json";
        headers["Content-Type"] = "application/json";
        let raw = "";
        try {
            raw = http_post_json_with_headers(`${BASE_URL}/auth/search`, json_stringify(#{ query: title, limit: 20 }), headers);
        } catch {}
        let data = json_parse(raw);
        if type_of(data) == "map" && type_of(data["results"]) == "array" {
            for r in data["results"] {
                if r["slug"] != slug { continue; }
                if type_of(r["alt_titles"]) == "array" {
                    for t in r["alt_titles"] {
                        if t != () && t != "" && t != title && !alt_titles.contains(t) { alt_titles.push(t); }
                    }
                }
                if type_of(r["authors"]) == "array" && r["authors"].len() > 0 {
                    authors = [];
                    for a in r["authors"] { if a != () && a != "" { authors.push(a); } }
                }
                let d = r["description"];
                if d != () && d != "" && (description == () || d.len() > description.len()) {
                    description = html_unescape(d);
                }
                if cover == () && r["thumbnail"] != () { cover = r["thumbnail"]; }
                let s = r["status"];
                if status == () && s != () {
                    let sl = s.to_lower();
                    if sl.contains("ongoing") { status = "Ongoing"; }
                    else if sl.contains("completed") { status = "Completed"; }
                    else if sl.contains("hiatus") { status = "Hiatus"; }
                    else if sl.contains("cancel") || sl.contains("dropped") { status = "Cancelled"; }
                }
                break;
            }
        }
    }
    // JSON-LD ComicSeries block as a last resort for status/cover.
    if status == () {
        let m = regex_find("\"status\":\"[A-Za-z]+\"", html);
        if m.contains("Ongoing") { status = "Ongoing"; }
        else if m.contains("Completed") { status = "Completed"; }
        else if m.contains("Hiatus") { status = "Hiatus"; }
    }
    // Genre links include the type tag ("Manhwa"), which is fine as a genre.

    #{
        id: url,
        title: title,
        alternate_titles: alt_titles,
        description: description,
        cover_url: cover,
        authors: authors,
        artists: artists,
        status: status,
        genres: genres,
        url: url
    }
}

// The old domain (roliascann.com) is dead (522); stored series/chapter ids
// from it still point there, so rewrite them onto the live site.
fn normalize_url(u) {
    let url = u.trim();
    if !url.starts_with("http") {
        if !url.starts_with("/") { url = `/manga/${url}`; }
        url = `${BASE_URL}${url}`;
    }
    url = rep(url, "://www.roliascann.com", "://roliascan.com");
    url = rep(url, "://roliascann.com", "://roliascan.com");
    url
}

// Digits at the end of a regex_find match ("data-manga-id=\"10864\"" -> "10864").
fn trailing_number(m) {
    if m == () || m == "" { return ""; }
    let n = regex_find("\\d+(\\.\\d+)?", m.sub_string(m.index_of("=") + 1));
    if n == () { "" } else { n }
}

// The series page carries its numeric WordPress post id on the chapter list
// container (data-manga-id), which the chapter API needs.
fn manga_id_for(series_url) {
    let html = fetch_html(series_url);
    let m = regex_find("data-manga-id=\"\\d+\"", html);
    trailing_number(m)
}

// Since the 2026 redesign the series page ships an empty chapter list and
// manga.js fills it from GET /auth/manga-chapters (public, no login):
// {success, chapters:[{id, chapter, title, date, group_id, group_name,
// language, url}], total, has_more}. Paged by offset, up to 500 per call.
fn fetch_all_chapters(manga_id) {
    let all = [];
    let offset = 0;
    let headers = get_headers();
    headers["Accept"] = "application/json";
    for guard in 0..40 {
        let url = `${BASE_URL}/auth/manga-chapters?manga_id=${manga_id}&offset=${offset}&limit=500&order=DESC`;
        let raw = "";
        try {
            raw = http_get_with_headers(url, headers);
        } catch {
            break;
        }
        let data = json_parse(raw);
        if type_of(data) != "map" || data["chapters"] == () { break; }
        let batch = data["chapters"];
        if batch.len() == 0 { break; }
        for c in batch { all.push(c); }
        offset += batch.len();
        if data["has_more"] != true { break; }
    }
    all
}

fn get_chapters(series_id, auth) {
    let url = normalize_url(series_id);
    let manga_id = manga_id_for(url);
    if manga_id == "" { return []; }
    let raw = fetch_all_chapters(manga_id);

    // The same chapter number can be uploaded by several groups. Keep one per
    // number so a download doesn't fetch (and file) the chapter twice: prefer
    // anything not flagged "Low Quality", then the group that uploaded the
    // most chapters of this series (the main release line), then the newest.
    let group_counts = #{};
    for c in raw {
        let g = if c["group_name"] == () { "" } else { c["group_name"] };
        if group_counts.contains(g) { group_counts[g] += 1; } else { group_counts[g] = 1; }
    }
    let best = #{};
    let order = [];
    for c in raw {
        let num = c["chapter"];
        if num == () || num == "" { continue; }
        num = `${num}`;
        let g = if c["group_name"] == () { "" } else { c["group_name"] };
        let score = group_counts[g];
        if g.to_lower().contains("low quality") { score -= 100000; }
        c["_score"] = score;
        if !best.contains(num) {
            best[num] = c;
            order.push(num);
        } else if score > best[num]["_score"] {
            best[num] = c;
        }
    }

    let chapters = [];
    for num in order {
        let c = best[num];
        let title = c["title"];
        if title == () || title == "" || title == "N/A" { title = (); } else { title = html_unescape(title); }
        let group = c["group_name"];
        if group == "" { group = (); }
        chapters.push(#{
            id: c["url"],
            series_id: series_id,
            number: num,
            title: title,
            url: c["url"],
            language: if c["language"] == () { "en" } else { c["language"] },
            scanlator: group,
            published_at: c["date"],
            extra: #{ chapter_id: `${c["id"]}`, group_id: c["group_id"] }
        });
    }
    chapters
}

// Build the standard page-image header map. The page CDN
// (cdn2.love4awalk.xyz, formerly cdn2.fandommanga.xyz) hotlink-protects
// images: the proxy layer supplies Chrome TLS impersonation, but we must
// emit the correct Referer (the chapter page URL on the site origin).
fn page_headers(referer) {
    #{
        "Referer": referer,
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
    }
}

// Resolve a stored chapter id/URL to the site's numeric chapter id.
// Current URLs end in ".../ch{N}-{id}/". Pre-redesign URLs
// (".../read/{slug}/chapter-{N}") now redirect to an unrelated chapter, so
// they are mapped back through the series' chapter list by number.
fn resolve_chapter_id(url) {
    let m = regex_find("/ch[0-9.]+-\\d+/?$", url);
    if m != () && m != "" {
        let parts = m.split("-");
        return rep(parts[parts.len() - 1], "/", "");
    }
    let legacy = regex_find("/read/[^/]+/chapter-[0-9.]+", url);
    if legacy != () && legacy != "" {
        let segs = legacy.split("/");
        let slug = segs[2];
        let num = segs[3].sub_string(8);
        let manga_id = manga_id_for(`${BASE_URL}/manga/${slug}/`);
        if manga_id != "" {
            for c in fetch_all_chapters(manga_id) {
                if `${c["chapter"]}` == num { return `${c["id"]}`; }
            }
        }
        return "";
    }
    // Unknown shape: the reader page has the id on <body data-chapter-id>.
    let html = fetch_html(url);
    trailing_number(regex_find("data-chapter-id=\"\\d+\"", html))
}

fn get_chapter_pages(chapter_id, auth) {
    let url = normalize_url(chapter_id);
    if !chapter_id.starts_with("http") && chapter_id.starts_with("/") {
        url = `${BASE_URL}${chapter_id}`;
    }
    let pages = [];
    let cid = resolve_chapter_id(url);
    if cid == "" { return pages; }

    // chapter.js loads the images from this public endpoint:
    // {success, chapter_type: "media"|"text", images: [url, ...]}.
    let headers = get_headers();
    headers["Accept"] = "application/json";
    headers["Referer"] = url;
    let raw = "";
    try {
        raw = http_get_with_headers(`${BASE_URL}/auth/chapter-content?chapter_id=${cid}`, headers);
    } catch {
        return pages;
    }
    let data = json_parse(raw);
    if type_of(data) != "map" || data["images"] == () { return pages; }

    let idx = 0;
    for img in data["images"] {
        if img == () || img == "" { continue; }
        pages.push(#{
            index: idx,
            url: img,
            referer: `${BASE_URL}/`,
            headers: page_headers(`${BASE_URL}/`)
        });
        idx += 1;
    }
    pages
}

/// Get latest updates for browsing (newest series first; the catalogue
/// endpoint has no "recently updated" sort).
fn get_latest_updates(page, auth) {
    let series = load_catalog(page, "", "post_desc");
    #{ series: series, has_more: series.len() >= 24 }
}

/// Get popular manga
fn get_popular(page, auth) {
    load_catalog(page, "", "popular_desc")
}
