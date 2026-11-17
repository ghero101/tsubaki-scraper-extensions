// Lagoon Scans Scraper Add-on (Rhai)
// Scanlation group site: https://lagoonscans.com
//
// Built from templates/scraper-mangathemesia: the "MangaReader" WordPress
// theme by Themesia (also called MangaThemesia / MangaStream), which a lot of
// scanlation groups run. Only the constants at the top differ between sites.
//
//   Browse:   /{SERIES_DIR}/?order=update&page=N        -> .listupd .bsx > a
//   Popular:  /{SERIES_DIR}/?order=popular&page=N
//   Search:   /page/N/?s=QUERY                           -> .listupd .bsx > a
//   Series:   /{SERIES_DIR}/{slug}/                      -> h1.entry-title, .thumb img,
//             [itemprop=description], .tsinfo .imptdt, .mgen a, .alternative
//   Chapters: #chapterlist li[data-num] a[href]          (series page; one request)
//             Coin-locked early-access chapters have no href (they open a
//             purchase modal) and are skipped: they can't be read for free.
//   Pages:    chapter page -> ts_reader.run({... "sources":[{"images":[...]}]})
//             falling back to #readerarea img.
//
// IDs: series id = slug; chapter id = chapter URL path ("/slug-chapter-12/").

const SITE_ID = "lagoonscans";
const SITE_NAME = "Lagoon Scans";
const BASE_URL = "https://lagoonscans.com";
const SERIES_DIR = "manga";
const CONTENT_RATING = "suggestive";

fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Referer": BASE_URL + "/"
    }
}

fn is_challenge(html) {
    if html == () || html == "" { return true; }
    if html.len() < 600 { return true; }
    if html.contains("Just a moment...") && html.contains("challenge") { return true; }
    if html.contains("Attention Required!") && html.contains("Cloudflare") { return true; }
    false
}

/// Impersonating client first, then a plain client, then FlareSolverr.
fn fetch_html(url) {
    let html = "";
    try { html = http_get_with_headers(url, get_headers()); } catch { html = ""; }
    if !is_challenge(html) { return html; }
    try { html = http_get_plain(url, get_headers()); } catch { html = ""; }
    if !is_challenge(html) { return html; }
    if flaresolverr_is_available() {
        try { html = flaresolverr_get(url, 60000); } catch { html = ""; }
        if !is_challenge(html) { return html; }
    }
    ""
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

fn absolutise(href) {
    if href == () { return ""; }
    let h = href.trim();
    if h.starts_with("//") { return "https:" + h; }
    if h.starts_with("http") { return h; }
    if h.starts_with("/") { return BASE_URL + h; }
    BASE_URL + "/" + h
}

/// Slug from a series URL ("https://site/manga/foo-bar/" -> "foo-bar").
fn slug_of(url) {
    let s = `${url}`.trim();
    let marker = "/" + SERIES_DIR + "/";
    let i = s.index_of(marker);
    if i >= 0 { s = s.sub_string(i + marker.len()); }
    let q = s.index_of("?");
    if q >= 0 { s = s.sub_string(0, q); }
    while s.ends_with("/") { s = s.sub_string(0, s.len() - 1); }
    let parts = s.split("/");
    parts[parts.len() - 1]
}

fn series_url(id_or_url) {
    let s = `${id_or_url}`.trim();
    if s.starts_with("http") { return s; }
    `${BASE_URL}/${SERIES_DIR}/${slug_of(s)}/`
}

fn first_text(scope, selector) {
    let els = html_select(scope, selector);
    if els.len() == 0 { return ""; }
    element_text(els[0]).trim()
}

/// Best image URL on an <img>: lazy-load attributes first, then src.
/// Strips Jetpack's ?resize= so covers come back full size.
fn img_url(img) {
    for attr in ["data-src", "data-lazy-src", "data-cfsrc", "src"] {
        let v = element_attr(img, attr);
        if v != () && v != "" && !v.starts_with("data:") {
            let u = absolutise(v);
            let q = u.index_of("?resize=");
            if q > 0 { u = u.sub_string(0, q); }
            return u;
        }
    }
    ()
}

fn map_status(raw) {
    let s = `${raw}`.to_lower().trim();
    if s == "" { return (); }
    if s.contains("ongoing") || s.contains("releasing") { return "ongoing"; }
    if s.contains("complete") || s.contains("finished") || s.contains("end") { return "completed"; }
    if s.contains("hiatus") || s.contains("paused") { return "hiatus"; }
    if s.contains("drop") || s.contains("cancel") { return "cancelled"; }
    ()
}

/// One .bsx card -> SeriesInfo (or () to skip).
fn parse_card(card) {
    let links = html_select(card, "a");
    if links.len() == 0 { return (); }
    let href = element_attr(links[0], "href");
    if href == () || !href.contains("/" + SERIES_DIR + "/") { return (); }
    let title = element_attr(links[0], "title");
    if title == () || title.trim() == "" { title = first_text(card, ".tt"); }
    if title == () || title.trim() == "" { return (); }
    let cover = ();
    let imgs = html_select(card, "img");
    if imgs.len() > 0 { cover = img_url(imgs[0]); }
    let url = absolutise(href);
    #{
        id: slug_of(url),
        title: title.trim(),
        url: url,
        cover_url: cover,
        alternate_titles: [],
        authors: [],
        artists: [],
        genres: [],
        tags: [],
        content_rating: CONTENT_RATING,
        extra: #{ source_name: SITE_NAME }
    }
}

fn parse_listing(html) {
    let out = [];
    let seen = #{};
    let cards = html_select(html, ".listupd .bsx");
    if cards.len() == 0 { cards = html_select(html, ".bsx"); }
    for card in cards {
        let s = parse_card(card);
        if s == () { continue; }
        if seen.contains(s.id) { continue; }
        seen[s.id] = true;
        out.push(s);
    }
    out
}

fn has_next_page(html) {
    html_select(html, ".hpage a.r, a.next.page-numbers, .pagination a.next").len() > 0
}

fn listing(order, page) {
    let p = if page < 1 { 1 } else { page };
    let html = fetch_html(`${BASE_URL}/${SERIES_DIR}/?order=${order}&page=${p}`);
    if html == "" { return #{ series: [], has_more: false }; }
    let series = parse_listing(html);
    #{ series: series, has_more: series.len() > 0 && has_next_page(html) }
}

fn get_latest_updates(page, auth) {
    listing("update", page)
}

fn get_popular(page, auth) {
    listing("popular", page).series
}

// Full catalog sync: the whole series directory, A-Z, paged to the end. A
// title order stays put while the crawl runs; "update" order reshuffles as
// chapters land and can skip series between pages.
fn get_catalog(page, auth) {
    listing("title", page)
}

fn search_series(query, page, auth) {
    let p = if page < 1 { 1 } else { page };
    // WordPress search misses titles typed with curly quotes ("Serim’s"), and
    // catalogue titles often have them, or en/em dashes. Search on straight
    // quotes and plain spaces instead.
    let q = url_encode(query.trim().replace("’", "'").replace("‘", "'").replace("“", "\"").replace("”", "\"").replace(" – ", " ").replace(" — ", " ").replace("–", " ").replace("—", " "));
    let url = if p == 1 { `${BASE_URL}/?s=${q}` } else { `${BASE_URL}/page/${p}/?s=${q}` };
    let html = fetch_html(url);
    if html == "" { return #{ series: [], has_more: false, total: 0 }; }
    let series = parse_listing(html);
    #{ series: series, has_more: series.len() > 0 && has_next_page(html), total: series.len() }
}

/// Value of a ".tsinfo .imptdt" row whose label contains `label`
/// ("Status", "Type", "Released", "Author", "Artist").
fn info_value(html, label) {
    for row in html_select(html, ".tsinfo .imptdt, .infotable tr, .fmed") {
        let t = element_text(row);
        if t.to_lower().contains(label.to_lower()) {
            let vals = html_select(row, "i, a, span, td:last-child");
            if vals.len() > 0 {
                let v = element_text(vals[vals.len() - 1]).trim();
                if v != "" && v != "-" { return v; }
            }
            let v = t.replace(label, "").trim();
            if v != "" && v != "-" { return v; }
        }
    }
    ""
}

fn split_people(s) {
    let out = [];
    if s == () || s == "" { return out; }
    for part in s.split(",") {
        let p = part.trim();
        if p != "" && p != "-" && p.to_lower() != "updating" { out.push(p); }
    }
    out
}

fn get_series(id_or_url, auth) {
    let url = series_url(id_or_url);
    let html = fetch_html(url);
    if html == "" { throw `${SITE_NAME}: could not load ${url}`; }

    let title = first_text(html, "h1.entry-title");
    if title == "" {
        let og = html_select(html, "meta[property='og:title']");
        if og.len() > 0 { title = `${element_attr(og[0], "content")}`.trim(); }
    }

    let cover = ();
    let thumbs = html_select(html, ".thumb img, .thumbook img");
    if thumbs.len() > 0 { cover = img_url(thumbs[0]); }

    let description = ();
    let d = html_select(html, "[itemprop='description']");
    if d.len() > 0 {
        let paras = html_select(d[0], "p");
        let text = "";
        if paras.len() > 0 {
            let parts = [];
            for p in paras { let t = element_text(p).trim(); if t != "" { parts.push(t); } }
            text = parts.join("\n\n");
        } else {
            text = element_text(d[0]).trim();
        }
        if text != "" { description = text; }
    }

    let alt = [];
    let alt_text = first_text(html, ".alternative .desktop-titles, .alternative, .wd-full .alternative");
    if alt_text != "" {
        for a in alt_text.split(",") {
            let t = a.trim();
            if t != "" && t != title && !alt.contains(t) { alt.push(t); }
        }
    }

    let genres = [];
    for g in html_select(html, ".mgen a, .seriestugenre a") {
        let t = element_text(g).trim();
        if t != "" && !genres.contains(t) { genres.push(t); }
    }

    let status = map_status(info_value(html, "Status"));
    if status == () { status = map_status(first_text(html, ".imptdt .status i, .status i")); }

    let year = ();
    let y = regex_find("(19|20)\\d\\d", info_value(html, "Released"));
    if y != "" { year = parse_int(y); }

    let kind = info_value(html, "Type");

    #{
        id: slug_of(url),
        title: title,
        url: url,
        cover_url: cover,
        description: description,
        alternate_titles: alt,
        authors: split_people(info_value(html, "Author")),
        artists: split_people(info_value(html, "Artist")),
        status: status,
        genres: genres,
        tags: [],
        year: year,
        content_rating: CONTENT_RATING,
        extra: #{ source_name: SITE_NAME, type: kind }
    }
}

fn chapter_number(li, title) {
    let n = element_attr(li, "data-num");
    if n != () {
        let m = regex_find("\\d+(\\.\\d+)?", n);
        if m != "" { return parse_float(m); }
    }
    let full = regex_find("(?i)chapter\\s*\\d+(\\.\\d+)?", title);
    if full != "" { return parse_float(regex_find("\\d+(\\.\\d+)?", full)); }
    let any = regex_find("\\d+(\\.\\d+)?", title);
    if any != "" { return parse_float(any); }
    0.0
}

fn get_chapters(series_id, auth) {
    let url = series_url(series_id);
    let html = fetch_html(url);
    if html == "" { throw `${SITE_NAME}: could not load ${url}`; }
    let slug = slug_of(url);

    let chapters = [];
    let seen = #{};
    for li in html_select(html, "#chapterlist li") {
        let links = html_select(li, "a[href]");
        if links.len() == 0 { continue; }          // coin-locked: no free link
        // Some sites keep the link and mark paid early-access chapters with a
        // gold coin price tag instead (Rokari Comics); those pages are empty.
        if `${li}`.contains("text-gold") || `${li}`.contains("premium-chapter") { continue; }
        let href = element_attr(links[0], "href");
        if href == () || href == "" || href.starts_with("#") { continue; }
        let ch_url = absolutise(href);
        let path = ch_url.replace(BASE_URL, "");
        if seen.contains(path) { continue; }
        seen[path] = true;

        let label = first_text(li, ".chapternum");
        if label == "" { label = element_text(links[0]).trim(); }
        let num = chapter_number(li, label);
        let date = first_text(li, ".chapterdate");

        let ch = #{
            id: path,
            series_id: slug,
            number: num,
            title: label,
            language: "en",
            scanlator: SITE_NAME,
            url: ch_url
        };
        if date != "" { ch.published_at = date; }
        chapters.push(ch);
    }
    chapters
}

fn chapter_url(chapter_id) {
    let s = `${chapter_id}`.trim();
    if s.starts_with("http") { return s; }
    if !s.starts_with("/") { s = "/" + s; }
    BASE_URL + s
}

fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_url(chapter_id);
    let html = fetch_html(url);
    if html == "" { throw `${SITE_NAME}: could not load ${url}`; }

    let images = [];

    // The reader is fed by ts_reader.run({...}); its first source's images
    // are the full chapter, in order.
    let start = html.index_of("ts_reader.run(");
    if start >= 0 {
        let rest = html.sub_string(start + 14);
        let end = rest.index_of("});");
        if end > 0 {
            let data = ();
            try { data = json_parse(rest.sub_string(0, end + 1)); } catch {}
            if type_of(data) == "map" && data.sources != () && data.sources.len() > 0 {
                for img in data.sources[0].images {
                    let u = `${img}`.trim();
                    if u != "" { images.push(absolutise(u)); }
                }
            }
        }
    }

    if images.len() == 0 {
        for img in html_select(html, "#readerarea img") {
            let u = img_url(img);
            if u != () && u != "" && !u.contains("readerarea.svg") { images.push(u); }
        }
    }

    if images.len() == 0 && (html.contains("text-gold") || html.to_lower().contains("unlock this chapter") || html.to_lower().contains("purchase this chapter")) {
        throw `${SITE_NAME}: this chapter is coin-locked (paid early access) and has no free pages yet`;
    }

    let pages = [];
    let idx = 0;
    for u in images {
        pages.push(#{ index: idx, url: u, headers: #{ "Referer": url }, referer: url });
        idx += 1;
    }
    pages
}
