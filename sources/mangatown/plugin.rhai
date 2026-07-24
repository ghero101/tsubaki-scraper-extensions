// MangaTown Scraper Add-on (Rhai)
// HTTP-only scraper for www.mangatown.com
//
// URL Patterns:
//   Directory/browse: /directory/  and /directory/{page}.htm
//   Latest:  /latest/  and /latest/{page}.htm
//   Search:  /search?name={query}&page={page}
//   Manga:   /manga/{slug}/
//   Chapter: /manga/{slug}/c{chapter}/   (optional /v{vol}/c{chapter}/)
//   Pages:   /manga/{slug}/c{chapter}/{N}.html  (one <img id="image"> per page)
//
// Markup notes (verified live 2026-06):
//   Listing cards:  <a class="manga_cover" href="/manga/{slug}/" title="...">
//                     <img src="https://fmcdn.mangahere.com/.../ocover.jpg">
//   Detail title:   <h1 class="title-top">Title</h1>
//   Detail cover:   first <img> inside <div class="detail_info">
//   Detail info:    <div class="detail_info"> <ul> <li><b>Author(s):</b> <a>...</a></li> ...
//   Description:    <span id="show"> ... </span>
//   Genres:         <a href="/directory/...-genre-...">Genre</a>
//   Chapter list:   <ul class="chapter_list"> <li> <a href="/manga/{slug}/c{n}/"> ... </a>
//                     <span class="time">date</span> </li>
//   Page image:     <img id="image" src="//zjcdn.mangahere.org/.../gp_001.jpg">
//   Page selector:  <select onchange="javascript:location.href=this.value;">
//                     <option value="/manga/{slug}/c{n}/{N}.html">NN</option>
//
// IMPORTANT (Rhai): the host `regex_find` returns "" on no-match (NOT ()).
// Always test with `!= ""`, never `!= ()`.
//
// Host APIs:
//   HTTP: http_get(url), http_get_with_headers(url, headers)
//   HTML: html_parse(html), html_select(html_or_el, css), element_text(el), element_attr(el, attr)
//   JSON: json_parse(text)
//   Regex: regex_find(pattern, text), regex_find_all(pattern, text)
//   String: url_encode(text)

const BASE_URL = "https://www.mangatown.com";

// ============================================================================
// Helper Functions
// ============================================================================

/// Get headers for requests
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Fetch HTML with headers. Falls back to plain http_get and finally "".
fn fetch_html(url) {
    try {
        let html = http_get_with_headers(url, get_headers());
        if html != () && html != "" {
            return html;
        }
    } catch {
    }
    try {
        return http_get(url);
    } catch {
        return "";
    }
}

/// Make a protocol-relative or root-relative URL absolute.
fn absolutize(u) {
    if u == () || u == "" {
        return u;
    }
    if u.starts_with("//") {
        return `https:${u}`;
    }
    if u.starts_with("/") {
        return `${BASE_URL}${u}`;
    }
    u
}

/// Extract manga slug from a /manga/{slug}/ URL.
fn extract_manga_slug(url) {
    let parts = url.split("/manga/");
    if parts.len() > 1 {
        let after_manga = parts[1];
        let slug_parts = after_manga.split("/");
        if slug_parts.len() > 0 && slug_parts[0] != "" {
            return slug_parts[0];
        }
    }
    ""
}

/// Map status text to standard format.
fn map_status(status_text) {
    let lower = status_text.to_lower();
    if lower.contains("completed") {
        return "Completed";
    }
    if lower.contains("ongoing") {
        return "Ongoing";
    }
    if lower.contains("hiatus") {
        return "Hiatus";
    }
    ()
}

/// Extract chapter number from chapter URL or title.
/// URL: /manga/{slug}/c{chapter}/ or /manga/{slug}/v{vol}/c{chapter}/
fn extract_chapter_number(url, title) {
    // Prefer URL: /c{number}/ or /c{number}.{decimal}/
    let chapter_match = regex_find("/c([0-9]+\\.?[0-9]*)", url);
    if chapter_match != "" {
        let num = regex_find("[0-9]+\\.?[0-9]*", chapter_match.replace("/c", ""));
        if num != "" {
            return num;
        }
    }

    // Title like "Series Name 519" or "Ch.519"
    let title_match = regex_find("[Cc]h\\.?\\s*([0-9]+\\.?[0-9]*)", title);
    if title_match != "" {
        let num = regex_find("[0-9]+\\.?[0-9]*", title_match);
        if num != "" {
            return num;
        }
    }

    // Fallback: last/any number in title (trailing number preferred).
    let trailing = regex_find("([0-9]+\\.?[0-9]*)\\s*$", title.trim());
    if trailing != "" {
        return trailing.trim();
    }
    let num_match = regex_find("[0-9]+\\.?[0-9]*", title);
    if num_match != "" {
        return num_match;
    }

    "0"
}

/// Extract volume number from URL.
fn extract_volume_number(url) {
    let vol_match = regex_find("/v([0-9]+)/", url);
    if vol_match != "" {
        let num = regex_find("[0-9]+", vol_match);
        if num != "" {
            return num;
        }
    }
    ()
}

/// Collapse whitespace.
fn clean_text(text) {
    let cleaned = text.trim();
    while cleaned.contains("  ") {
        cleaned = cleaned.replace("  ", " ");
    }
    while cleaned.contains("\n") {
        cleaned = cleaned.replace("\n", " ");
    }
    while cleaned.contains("  ") {
        cleaned = cleaned.replace("  ", " ");
    }
    cleaned.trim()
}

/// Parse a listing page (directory / latest / search) into a series array.
/// Cards are <a class="manga_cover" href="/manga/{slug}/" title="...">.
fn parse_listing(html) {
    let series = [];
    let seen = #{};

    let cards = html_select(html, "a.manga_cover");
    for link in cards {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }
        if !href.contains("/manga/") {
            continue;
        }

        let slug = extract_manga_slug(href);
        if slug == "" || seen.contains(slug) {
            continue;
        }

        let title = element_attr(link, "title");
        if title == () || title == "" {
            title = element_text(link).trim();
        }
        title = clean_text(title);
        if title == "" || title.len() < 2 {
            continue;
        }

        seen[slug] = true;

        let cover_url = ();
        let imgs = html_select(link, "img");
        if imgs.len() > 0 {
            cover_url = absolutize(element_attr(imgs[0], "src"));
        }

        series.push(#{
            id: slug,
            title: title,
            url: absolutize(href),
            cover_url: cover_url,
            alternate_titles: [],
            authors: [],
            artists: [],
            status: (),
            genres: [],
            tags: [],
            description: ()
        });
    }

    series
}

// ============================================================================
// Required Interface Functions
// ============================================================================

/// Returns metadata about this source.
fn get_source_info() {
    #{
        id: "mangatown-rhai",
        name: "MangaTown",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

/// Search for series matching query.
fn search_series(query, page, auth) {
    let encoded_query = url_encode(query);
    let url = `${BASE_URL}/search?name=${encoded_query}&page=${page}`;

    let html = fetch_html(url);
    let series = parse_listing(html);

    // Pagination: a link to ?page={next} indicates more results.
    let has_more = false;
    let page_links = html_select(html, "a");
    let next_token = `page=${page + 1}`;
    for p_link in page_links {
        let p_href = element_attr(p_link, "href");
        if p_href != () && p_href.contains(next_token) {
            has_more = true;
            break;
        }
    }
    if !has_more && series.len() >= 20 {
        has_more = true;
    }

    #{ series: series, has_more: has_more, total: () }
}

/// Get detailed series information.
fn get_series(id_or_url, auth) {
    let url = id_or_url;
    let slug = id_or_url;

    if !id_or_url.starts_with("http") {
        url = `${BASE_URL}/manga/${id_or_url}/`;
    } else {
        slug = extract_manga_slug(id_or_url);
    }

    let html = fetch_html(url);

    // Title
    let title = "";
    let title_els = html_select(html, "h1.title-top");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }
    if title == "" {
        let h1_els = html_select(html, "h1");
        if h1_els.len() > 0 {
            title = element_text(h1_els[0]).trim();
        }
    }

    // Cover: first <img> inside div.detail_info
    let cover_url = ();
    let cover_imgs = html_select(html, "div.detail_info img");
    if cover_imgs.len() > 0 {
        cover_url = absolutize(element_attr(cover_imgs[0], "src"));
    }
    if cover_url == () {
        let ocover_imgs = html_select(html, "img[src*='ocover']");
        if ocover_imgs.len() > 0 {
            cover_url = absolutize(element_attr(ocover_imgs[0], "src"));
        }
    }

    // Description: <span id="show">
    let description = ();
    let desc_els = html_select(html, "span#show");
    if desc_els.len() > 0 {
        let d = clean_text(element_text(desc_els[0]));
        if d != "" {
            description = d;
        }
    }

    // Info list: div.detail_info > ul > li, labelled with <b>...</b>
    let authors = [];
    let artists = [];
    let status = ();
    let alt_titles = [];
    let year = ();

    let info_els = html_select(html, "div.detail_info ul li");
    for info in info_els {
        let text = element_text(info);
        let lower = text.to_lower();

        if lower.contains("author") {
            let links = html_select(info, "a");
            for a_link in links {
                let v = clean_text(element_text(a_link));
                if v != "" && !authors.contains(v) {
                    authors.push(v);
                }
            }
        } else if lower.contains("artist") {
            let links = html_select(info, "a");
            for a_link in links {
                let v = clean_text(element_text(a_link));
                if v != "" && !artists.contains(v) {
                    artists.push(v);
                }
            }
        } else if lower.contains("status") {
            let s = map_status(text);
            if s != () {
                status = s;
            }
        } else if lower.contains("alternative") {
            let alt_text = text.replace("Alternative Name:", "")
                               .replace("Alternative:", "")
                               .replace("Alternative", "").trim();
            let alts = alt_text.split(";");
            for alt in alts {
                let cleaned = clean_text(alt);
                if cleaned != "" && cleaned != title && !alt_titles.contains(cleaned) {
                    alt_titles.push(cleaned);
                }
            }
        } else if lower.contains("year") || lower.contains("released") {
            let year_match = regex_find("(19|20)[0-9]{2}", text);
            if year_match != "" {
                year = year_match;
            }
        }
    }

    // Genres: links into /directory/ that carry a genre slot.
    let genres = [];
    let genre_links = html_select(html, "div.detail_info a[href*='/directory/']");
    for g_link in genre_links {
        let genre = clean_text(element_text(g_link));
        if genre != "" && !genres.contains(genre) && genre.len() < 30 {
            genres.push(genre);
        }
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
        year: year,
        content_rating: "suggestive",
        url: url,
        extra: #{
            auto_match_metadata: true,
            source_name: "MangaTown"
        }
    }
}

/// Get all chapters for a series.
fn get_chapters(series_id, auth) {
    let url = series_id;
    if !series_id.starts_with("http") {
        url = `${BASE_URL}/manga/${series_id}/`;
    }

    let html = fetch_html(url);

    let chapters = [];
    let seen = #{};

    let chapter_links = html_select(html, "ul.chapter_list li a");
    if chapter_links.len() == 0 {
        chapter_links = html_select(html, "a[href*='/manga/'][href*='/c']");
    }

    for link in chapter_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Must look like a chapter URL: /c{number}
        if regex_find("/c[0-9]", href) == "" {
            continue;
        }
        if seen.contains(href) {
            continue;
        }
        seen[href] = true;

        let chapter_title = clean_text(element_text(link));
        let chapter_num = extract_chapter_number(href, chapter_title);
        let volume = extract_volume_number(href);
        let chapter_url = absolutize(href);

        chapters.push(#{
            id: chapter_url,
            series_id: series_id,
            number: chapter_num,
            title: chapter_title,
            volume: volume,
            language: "en",
            scanlator: (),
            url: chapter_url,
            published_at: (),
            page_count: (),
            extra: #{}
        });
    }

    chapters
}

/// Pull the single <img id="image"> (or fallbacks) from a page's HTML.
fn extract_page_image(html) {
    let imgs = html_select(html, "img#image");
    if imgs.len() == 0 {
        imgs = html_select(html, "#image");
    }
    if imgs.len() == 0 {
        imgs = html_select(html, "div.read_img img");
    }
    for img in imgs {
        let img_url = element_attr(img, "src");
        if img_url == () || img_url == "" {
            continue;
        }
        if img_url.contains("loading") || img_url.contains("manga_cover.jpg") {
            continue;
        }
        return absolutize(img_url);
    }
    ()
}

/// Get page URLs for a chapter.
/// MangaTown serves one image per page; we enumerate page URLs from the
/// page-selector dropdown and fetch each to read its <img id="image">.
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;
    if !chapter_id.starts_with("http") {
        url = `${BASE_URL}${chapter_id}`;
    }
    // Normalize trailing slash for first page.
    if !url.ends_with("/") && !url.ends_with(".html") {
        url = `${url}/`;
    }

    let html = fetch_html(url);

    let pages = [];
    let idx = 0;

    // Build ordered list of page URLs from any <option value=".../N.html">.
    let page_urls = [];
    let seen_urls = #{};
    let options = html_select(html, "option");
    for option in options {
        let pv = element_attr(option, "value");
        if pv == () || pv == "" {
            continue;
        }
        // Only real page entries: must be under /manga/ and not the featured page.
        if !pv.contains("/manga/") {
            continue;
        }
        if pv.contains("featured") {
            continue;
        }
        // Page entries are either the chapter root (page 1) or "{N}.html".
        let is_page1 = regex_find("/c[0-9.]+/?$", pv) != "";
        let is_page_n = regex_find("/[0-9]+\\.html$", pv) != "";
        if !is_page1 && !is_page_n {
            continue;
        }

        let abs = absolutize(pv);
        if seen_urls.contains(abs) {
            continue;
        }
        seen_urls[abs] = true;
        page_urls.push(abs);
    }

    if page_urls.len() == 0 {
        // No selector found — fall back to just the current page's image.
        let only = extract_page_image(html);
        if only != () {
            pages.push(#{
                index: 0,
                url: only,
                headers: #{ "Referer": url },
                referer: url
            });
        }
        return pages;
    }

    for i in 0..page_urls.len() {
        let page_url = page_urls[i];
        let page_html = html;
        // We already have HTML for the first page if it matches.
        if i > 0 || page_url != url {
            page_html = fetch_html(page_url);
        }

        let img_url = extract_page_image(page_html);
        if img_url == () {
            continue;
        }

        pages.push(#{
            index: idx,
            url: img_url,
            headers: #{ "Referer": page_url },
            referer: page_url
        });
        idx += 1;
    }

    pages
}

/// Get latest updates.
fn get_latest_updates(page, auth) {
    let url = `${BASE_URL}/latest/`;
    if page > 1 {
        url = `${BASE_URL}/latest/${page}.htm`;
    }

    let html = fetch_html(url);
    let series = parse_listing(html);

    let has_more = series.len() > 0 && page < 50;
    #{ series: series, has_more: has_more }
}

/// Browse manga (main browse endpoint) -> popular/directory listing.
fn browse(page, filters, auth) {
    get_popular(page, auth)
}

/// Get popular/hot manga from the directory.
fn get_popular(page, auth) {
    let url = `${BASE_URL}/directory/`;
    if page > 1 {
        url = `${BASE_URL}/directory/${page}.htm`;
    }

    let html = fetch_html(url);
    let series = parse_listing(html);

    let has_more = series.len() > 0 && page < 300;
    #{ series: series, has_more: has_more }
}
