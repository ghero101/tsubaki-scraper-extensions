// Comix Scraper Add-on (Rhai)
// Source: comix.to
//
// 2026-06 rewrite #2. comix.to locked its ENTIRE JSON API behind a per-request
// anti-bot token (every /api/v1/* call now returns 403 {"message":"Missing
// token."}). The token is minted by obfuscated client JS and can't be
// reproduced here. So we drop the API entirely and scrape the SERVER-RENDERED
// DOM via FlareSolverr (which executes the SPA's JS, token and all):
//   Browse:   /browse?page={p}              -> .lrow cards
//   Search:   /browse?keyword={query}       -> .lrow cards  (the /search route
//                                              loads async and renders empty)
//   Detail:   /title/{hid}-{slug}           -> h1.mpage__title, og:image, .mpage__*
//   Chapters: detail DOM  /title/{slug}/{chapterId}-chapter-{num}
//   Pages:    reader is token-gated + lazy — best-effort scrape of static.comix.to
//
// Card (.lrow) shape:
//   a.lrow__poster[href=/title/{hid}-{slug}] > img(@280 thumb)
//   a.lrow__title-link > h3.lrow__title
//   .lrow__meta > .lrow__type .lrow__year .lrow__status .lrow__ch
//   p.lrow__desc
//
// Series id = the path after /title/  (e.g. "0mmlv-katlaya-rising").

const BASE_URL = "https://comix.to";

fn req_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml",
        "Referer": BASE_URL + "/"
    }
}

/// FlareSolverr-render a URL (executes the SPA's JS so cards/chapters appear).
/// Falls back to a plain fetch (SSR shell only) if FlareSolverr is unavailable.
fn render_html(url) {
    let html = "";
    if flaresolverr_is_available() {
        try { html = flaresolverr_get(url, 60000); } catch { html = ""; }
        if html != "" { return html; }
    }
    try { html = http_get_with_headers(url, req_headers()); } catch { html = ""; }
    html
}

fn get_source_info() {
    #{
        id: "comix",
        name: "Comix",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "browser_automation"
    }
}

/// Map comix status text to the standard vocabulary.
fn map_status(raw) {
    if raw == () { return (); }
    let s = `${raw}`.to_lower().trim();
    if s == "" { return (); }
    if s.contains("releasing") || s.contains("ongoing") { return "Ongoing"; }
    if s.contains("complete") || s.contains("finished") { return "Completed"; }
    if s.contains("hiatus") { return "Hiatus"; }
    if s.contains("cancel") || s.contains("discontin") || s.contains("dropped") { return "Cancelled"; }
    raw
}

/// Series id = the path segment after /title/ (drops a leading host/path).
fn href_to_id(href) {
    if href == () || href == "" { return ""; }
    let m = regex_find("/title/[^/\"?]+", href);
    if m != "" { return m.replace("/title/", ""); }
    href
}

fn text_of(scope, selector) {
    let els = html_select(scope, selector);
    if els.len() == 0 { return ""; }
    element_text(els[0]).trim()
}

/// Parse one .lrow card into a series map, or () to skip.
fn parse_card(card) {
    let posters = html_select(card, "a.lrow__poster");
    let href = ();
    if posters.len() > 0 { href = element_attr(posters[0], "href"); }
    if href == () {
        let tl = html_select(card, "a.lrow__title-link");
        if tl.len() > 0 { href = element_attr(tl[0], "href"); }
    }
    if href == () || !href.contains("/title/") { return (); }

    let id = href_to_id(href);
    if id == "" { return (); }

    let title = text_of(card, "h3.lrow__title, .lrow__title");
    if title == "" { return (); }

    let cover = ();
    let imgs = html_select(card, "img");
    if imgs.len() > 0 {
        let c = element_attr(imgs[0], "src");
        if c == () || c == "" { c = element_attr(imgs[0], "data-src"); }
        if c != () && c != "" { cover = c.trim(); }
    }

    let status = map_status(text_of(card, ".lrow__status"));

    let year = ();
    let ytext = text_of(card, ".lrow__year");
    if ytext != "" { let y = regex_find("\\d{4}", ytext); if y != "" { year = parse_int(y); } }

    let description = ();
    let d = text_of(card, "p.lrow__desc, .lrow__desc");
    if d != "" { description = d; }

    let url = if href.starts_with("http") { href } else { `${BASE_URL}${href}` };

    #{
        id: id,
        title: title,
        url: url,
        cover_url: cover,
        alternate_titles: [],
        authors: [],
        artists: [],
        status: status,
        genres: [],
        tags: [],
        year: year,
        description: description
    }
}

fn parse_card_list(html) {
    let series = [];
    let cards = html_select(html, ".lrow");
    for card in cards {
        let s = parse_card(card);
        if s != () { series.push(s); }
    }
    series
}

fn get_latest_updates(page, auth) {
    let p = if page < 1 { 1 } else { page };
    let html = render_html(`${BASE_URL}/browse?page=${p}`);
    let series = parse_card_list(html);
    #{ series: series, has_more: series.len() >= 12 }
}

fn get_popular(page, auth) {
    let p = if page < 1 { 1 } else { page };
    // ?sort=follows surfaces popular titles; falls back to default order.
    let html = render_html(`${BASE_URL}/browse?page=${p}&sort=follows`);
    parse_card_list(html)
}

fn search_series(query, page, auth) {
    let p = if page < 1 { 1 } else { page };
    let q = url_encode(query);
    let html = render_html(`${BASE_URL}/browse?keyword=${q}&page=${p}`);
    let series = parse_card_list(html);
    #{ series: series, has_more: series.len() >= 12, total: series.len() }
}

fn id_to_url(id_or_url) {
    let s = `${id_or_url}`;
    if s.starts_with("http") { return s; }
    let id = href_to_id(s);
    if id == "" { id = s; }
    `${BASE_URL}/title/${id}`
}

fn get_series(id_or_url, auth) {
    let url = id_to_url(id_or_url);
    let html = render_html(url);

    let title = text_of(html, "h1.mpage__title");
    if title == "" {
        let og = html_select(html, "meta[property=\"og:title\"]");
        if og.len() > 0 { let c = element_attr(og[0], "content"); if c != () { title = c.trim(); } }
    }

    let cover = ();
    let ogimg = html_select(html, "meta[property=\"og:image\"]");
    if ogimg.len() > 0 { let c = element_attr(ogimg[0], "content"); if c != () && c != "" { cover = c.trim(); } }
    if cover == () {
        let posters = html_select(html, ".mpage__poster img, .poster img");
        if posters.len() > 0 { let c = element_attr(posters[0], "src"); if c != () { cover = c.trim(); } }
    }

    let description = ();
    let d = text_of(html, ".mpage__desc, .mpage__synopsis, [class*=synopsis]");
    if d != "" { description = d; }
    if description == () {
        let ogd = html_select(html, "meta[property=\"og:description\"]");
        if ogd.len() > 0 { let c = element_attr(ogd[0], "content"); if c != () && c != "" { description = c.trim(); } }
    }

    // Genres + authors live in .mpage__detail chips keyed by /browse?genres_in / authors.
    let genres = [];
    for g in html_select(html, "a[href*=\"genres_in\"]") {
        let t = element_text(g).trim(); if t != "" { genres.push(t); }
    }
    let authors = [];
    for a in html_select(html, "a[href*=\"authors=\"]") {
        let t = element_text(a).trim(); if t != "" { authors.push(t); }
    }

    let status = map_status(text_of(html, ".mpage__badge--status, .mpage__status"));

    let year = ();
    let ytext = text_of(html, ".mpage__badge--year, .mpage__year");
    if ytext != "" { let y = regex_find("\\d{4}", ytext); if y != "" { year = parse_int(y); } }

    let id = href_to_id(url);
    if id == "" { id = `${id_or_url}`; }

    #{
        id: id,
        title: title,
        alternate_titles: [],
        description: description,
        cover_url: cover,
        authors: authors,
        artists: [],
        status: status,
        genres: genres,
        tags: [],
        year: year,
        content_rating: "suggestive",
        url: url
    }
}

fn get_chapters(series_id, auth) {
    let url = id_to_url(series_id);
    let html = render_html(url);
    if html == "" { return []; }

    let chapters = [];
    let seen = #{};
    let hrefs = regex_find_all("/title/[a-z0-9-]+/[0-9]+-chapter-[0-9.]+", html.to_lower());

    for href in hrefs {
        let id_part = regex_find("/[0-9]+-chapter-", href);
        let chapter_id = "";
        if id_part != "" { chapter_id = regex_find("[0-9]+", id_part); }
        if chapter_id == "" { continue; }
        if seen[chapter_id] != () { continue; }
        seen[chapter_id] = true;

        let num = "0";
        let num_part = regex_find("chapter-[0-9.]+", href);
        if num_part != "" { num = num_part.replace("chapter-", ""); }

        let full_path = href;
        if !full_path.starts_with("/") { full_path = `/${full_path}`; }

        chapters.push(#{
            id: full_path,
            series_id: href_to_id(url),
            number: num,
            title: `Chapter ${num}`,
            language: "en",
            url: `${BASE_URL}${full_path}`,
            extra: #{ chapter_id: chapter_id }
        });
    }
    chapters
}

fn get_chapter_pages(chapter_id, auth) {
    let url = `${chapter_id}`;
    if !url.starts_with("http") {
        if !url.starts_with("/") { url = `/${url}`; }
        url = `${BASE_URL}${url}`;
    }

    let html = render_html(url);
    if html == "" { return []; }

    let pages = [];
    let idx = 0;
    let seen = #{};
    // Full-size reader images live on static.comix.to without an @size suffix.
    let matches = regex_find_all("static\\.comix\\.to/[A-Za-z0-9/]+/[A-Za-z0-9]+\\.(jpg|png|webp)", html);
    for m in matches {
        if m.contains("@") { continue; }
        let full = `https://${m}`;
        if seen[full] != () { continue; }
        seen[full] = true;
        pages.push(#{
            index: idx,
            url: full,
            headers: #{ "Referer": url },
            referer: url
        });
        idx += 1;
    }
    pages
}
