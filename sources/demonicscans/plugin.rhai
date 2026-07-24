// DemonicScans Scraper Add-on (Rhai)
// demonicscans.org is a CUSTOM site (NOT Madara/WordPress). Endpoints:
//   browse:   /advanced.php?list={page}      -> .advanced-element > a[href^="/manga/"][title]
//   search:   /search.php?manga={query}      -> a[href^="/manga/"] (li.search row + title div)
//   detail:   /manga/{Title-With-Dashes}     -> h1.big-fat-titles, .genres-list li, .white-font, og:image
//   chapters: a.chplinks  href=/chaptered.php?manga={id}&chapter={n}  title="Title N"
//   pages:    img.imgholder  src=https://mangareadon.org/{Title}/{ch}/{n}.jpg

const BASE_URL = "https://demonicscans.org";

fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml",
        "Referer": BASE_URL + "/"
    }
}

/// Recognise the CF-challenge HTML shapes demonicscans serves.
fn is_cloudflare_page(html) {
    if html == () || html == "" { return true; }
    if html.contains("Just a moment") && html.contains("_cf_chl_opt") { return true; }
    if html.contains("challenge-platform") && html.contains("Enable JavaScript") { return true; }
    if html.contains("Attention Required") && html.contains("Cloudflare") { return true; }
    false
}

/// Three-tier fetch: plain HTTP -> FlareSolverr -> browser. Each tier is wrapped
/// so a CF challenge or exception falls through instead of aborting the call.
fn fetch_html(url) {
    let http_html = "";
    try {
        http_html = http_get_with_headers(url, get_headers());
        if http_html != "" && !is_cloudflare_page(http_html) { return http_html; }
    } catch {}

    if flaresolverr_is_available() {
        try {
            let fs_html = flaresolverr_get(url, 45000);
            if fs_html != "" && !is_cloudflare_page(fs_html) { return fs_html; }
        } catch {}
    }

    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_selector(browser_id, ".advanced-element, .updates-element, .big-fat-titles, .chplinks, .imgholder", 15000);
            let result = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            if result != "" && !is_cloudflare_page(result) { return result; }
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    http_html
}

fn get_source_info() {
    #{
        id: "demonicscans",
        name: "DemonicScans",
        base_url: BASE_URL,
        language: "en",
        requires_authentication: false,
        capability_level: "browser_automation"
    }
}

/// Absolutise a site-relative href to a full URL.
fn absolutise(href) {
    if href == () || href == "" { return ""; }
    if href.starts_with("http") { return href; }
    if href.starts_with("/") { return BASE_URL + href; }
    return BASE_URL + "/" + href;
}

/// Pull a cover URL off an element's <img> (data-src first, then src).
fn img_cover(scope) {
    let imgs = html_select(scope, "img");
    if imgs.len() == 0 { return (); }
    let c = element_attr(imgs[0], "data-src");
    if c == () || c == "" { c = element_attr(imgs[0], "src"); }
    if c == () || c == "" { return (); }
    c.trim()
}

/// Parse one listing anchor (advanced/updates) into a series map, or () to skip.
fn parse_listing_anchor(a) {
    let href = element_attr(a, "href");
    if href == () || !href.contains("/manga/") { return (); }
    let title = element_attr(a, "title");
    if title == () || title == "" { title = element_text(a).trim(); }
    if title == () || title == "" { return (); }
    let url = absolutise(href);
    #{
        id: url,
        title: title,
        url: url,
        cover_url: img_cover(a),
        alternate_titles: [],
        authors: [],
        status: (),
        genres: []
    }
}

/// Shared browse list (advanced.php is paginated + carries clean title attrs).
fn browse_list(page) {
    let url = `${BASE_URL}/advanced.php`;
    if page > 1 { url = `${BASE_URL}/advanced.php?list=${page}`; }
    let html = fetch_html(url);

    let series = [];
    let items = html_select(html, ".advanced-element");
    for item in items {
        let links = html_select(item, "a");
        if links.len() == 0 { continue; }
        let s = parse_listing_anchor(links[0]);
        if s != () { series.push(s); }
    }
    series
}

fn get_latest_updates(page, auth) {
    let series = browse_list(page);
    #{ series: series, has_more: series.len() >= 20 }
}

fn get_popular(page, auth) {
    browse_list(page)
}

fn search_series(query, page, auth) {
    let encoded = url_encode(query);
    let url = `${BASE_URL}/search.php?manga=${encoded}`;
    let html = fetch_html(url);

    let series = [];
    let anchors = html_select(html, "a");
    for a in anchors {
        let href = element_attr(a, "href");
        if href == () || !href.contains("/manga/") { continue; }

        // Title: prefer the visible row label, then img alt, then anchor text.
        let title = "";
        let label = html_select(a, ".seach-right div, .search-right div");
        if label.len() > 0 { title = element_text(label[0]).trim(); }
        if title == "" {
            let imgs = html_select(a, "img");
            if imgs.len() > 0 {
                let alt = element_attr(imgs[0], "alt");
                if alt != () { title = alt.trim(); }
            }
        }
        if title == "" { title = element_text(a).trim(); }
        if title == "" { continue; }

        let url2 = absolutise(href);
        series.push(#{
            id: url2,
            title: title,
            url: url2,
            cover_url: img_cover(a),
            alternate_titles: [],
            authors: [],
            status: (),
            genres: []
        });
    }
    #{ series: series, has_more: false, total: series.len() }
}

fn get_series(id_or_url, auth) {
    let url = id_or_url;
    if !id_or_url.starts_with("http") {
        if id_or_url.starts_with("/") { url = BASE_URL + id_or_url; }
        else { url = `${BASE_URL}/manga/${id_or_url}`; }
    }
    let html = fetch_html(url);

    // Title
    let title = "";
    let h1s = html_select(html, "h1.big-fat-titles");
    if h1s.len() == 0 { h1s = html_select(html, ".big-fat-titles"); }
    if h1s.len() > 0 { title = element_text(h1s[0]).trim(); }
    if title == "" {
        let og = html_select(html, "meta[property=\"og:title\"]");
        if og.len() > 0 { let c = element_attr(og[0], "content"); if c != () { title = c.trim(); } }
    }

    // Cover (og:image -> readermc thumbnail)
    let cover = ();
    let ogimg = html_select(html, "meta[property=\"og:image\"]");
    if ogimg.len() > 0 { let c = element_attr(ogimg[0], "content"); if c != () && c != "" { cover = c.trim(); } }

    // Description: .white-font is the real synopsis (og:description is generic).
    let description = ();
    let desc_els = html_select(html, ".white-font");
    if desc_els.len() > 0 {
        let d = element_text(desc_els[0]).trim();
        if d != "" { description = d; }
    }

    // Genres
    let genres = [];
    let genre_els = html_select(html, ".genres-list li, .genres-list a");
    for g in genre_els {
        let t = element_text(g).trim();
        if t != "" { genres.push(t); }
    }

    // Status / Author / Artist / Released sit in `div.flex-row` rows, each with
    // two <li>: a styled label and the value. ("Updating"/"N/A" = unset.)
    let status = ();
    let authors = [];
    let artists = [];
    let year = ();
    let info_rows = html_select(html, "div.flex-row");
    for row in info_rows {
        let lis = html_select(row, "li");
        if lis.len() < 2 { continue; }
        let label = element_text(lis[0]).trim().to_lower();
        let value = element_text(lis[1]).trim();
        let lv = value.to_lower();
        if value == "" || lv == "updating" || lv == "n/a" { continue; }

        if label.contains("status") {
            if lv.contains("ongoing") { status = "Ongoing"; }
            else if lv.contains("completed") { status = "Completed"; }
            else if lv.contains("hiatus") { status = "Hiatus"; }
            else if lv.contains("dropped") || lv.contains("cancelled") { status = "Cancelled"; }
            else { status = value; }
        } else if label.contains("author") {
            authors.push(value);
        } else if label.contains("artist") {
            artists.push(value);
        } else if label.contains("released") || label.contains("year") {
            let y = regex_find("\\d{4}", value);
            if y != "" { year = parse_int(y); }
        }
    }

    #{
        id: url,
        title: title,
        alternate_titles: [],
        description: description,
        cover_url: cover,
        authors: authors,
        artists: artists,
        status: status,
        genres: genres,
        year: year,
        url: url
    }
}

fn get_chapters(series_id, auth) {
    let url = series_id;
    if !series_id.starts_with("http") {
        if series_id.starts_with("/") { url = BASE_URL + series_id; }
        else { url = `${BASE_URL}/manga/${series_id}`; }
    }
    let html = fetch_html(url);

    let chapters = [];
    let ch_links = html_select(html, "a.chplinks");
    let idx = 0;
    for link in ch_links {
        let href = element_attr(link, "href");
        if href == () || href == "" { continue; }

        // Chapter number from the title attr ("Dandadan 237") or link text.
        let label = element_attr(link, "title");
        if label == () || label == "" { label = element_text(link).trim(); }
        let ch_num = regex_find("\\d+(\\.\\d+)?", label);
        if ch_num == "" {
            // Fall back to the &chapter=N query param.
            ch_num = regex_find("chapter=\\d+(\\.\\d+)?", href);
            if ch_num != "" { ch_num = regex_find("\\d+(\\.\\d+)?", ch_num); }
        }
        if ch_num == "" { ch_num = `${idx + 1}`; }

        let ch_url = absolutise(href);
        chapters.push(#{
            id: ch_url,
            series_id: series_id,
            number: ch_num,
            title: label,
            url: ch_url
        });
        idx += 1;
    }
    chapters
}

fn get_chapter_pages(chapter_id, auth) {
    let url = absolutise(chapter_id);
    let html = fetch_html(url);

    let pages = [];
    let idx = 0;
    let imgs = html_select(html, "img.imgholder");
    for img in imgs {
        let src = element_attr(img, "src");
        if src == () || src == "" { src = element_attr(img, "data-src"); }
        if src == () || src == "" { continue; }
        let clean = src.trim();
        // Skip site chrome / ad placeholders; real pages are on the CDN host.
        if clean.contains("/img/") || clean.contains("free_ads") || clean.contains("logo") { continue; }
        if !clean.starts_with("http") { continue; }

        pages.push(#{
            index: idx,
            url: clean,
            headers: #{ "Referer": BASE_URL + "/" }
        });
        idx += 1;
    }
    pages
}
