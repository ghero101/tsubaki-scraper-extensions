// RoliaScan Scraper Add-on (Rhai)
// Manga scanlation site scraper (HTTP-only, no browser automation required)
//
// Available APIs:
//   HTTP: http_get(url), http_get_with_headers(url, headers)
//   HTML: html_parse(html), html_select(html, selector), element_text(el), element_attr(el, attr)
//   JSON: json_parse(text)
//   Utility: url_encode(text), regex_match(pattern, text), regex_find(pattern, text)

const BASE_URL = "https://roliascann.com";

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

// Render JS before returning HTML. RoliaScan's /search results are injected
// client-side by Ajax Search Pro, so the static page has no real matches —
// FlareSolverr executes the JS so the result anchors exist in the DOM.
fn fetch_rendered(url) {
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 45000);
            if html != "" && html.len() > 500 {
                return html;
            }
        } catch {
            // fall through to static fetch
        }
    }
    return fetch_html(url);
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

fn search_series(query, page, auth) {
    let encoded = url_encode(query);
    // Search is the WordPress searchForm's GET target /search?keyword=. The
    // results are rendered client-side by Ajax Search Pro (the old /filter?keyword=
    // endpoint never filtered — it returned the default grid), so fetch with JS
    // rendering. It's a single result page; ignore `page`.
    let url = `${BASE_URL}/search?keyword=${encoded}`;

    let html = fetch_rendered(url);
    let doc = html_parse(html);
    let series = [];

    // Search for manga links
    let items = html_select(doc, "a[href*='/manga/']");
    let seen = #{};

    for item in items {
        let href = element_attr(item, "href");
        if href == () || href == "" { continue; }
        if seen.contains(href) { continue; }
        if href.contains("/chapter") { continue; }

        seen[href] = true;

        // Get cover image first (we need it to extract alt text for title)
        let cover = ();
        let img_alt = "";
        let imgs = html_select(item, "img");
        if imgs.len() > 0 {
            cover = element_attr(imgs[0], "src");
            if cover == () || cover == "" {
                cover = element_attr(imgs[0], "data-src");
            }
            // Get alt text as fallback for title
            img_alt = element_attr(imgs[0], "alt");
            if img_alt == () { img_alt = ""; }
        }

        let title = "";
        let title_els = html_select(item, "h3, h4, .title, .tt");
        if title_els.len() > 0 {
            title = element_text(title_els[0]).trim();
        }
        if title == "" {
            title = element_text(item).trim();
            if title.len() > 100 { title = ""; }
        }
        if title == "" && img_alt != "" {
            // Extract title from img alt attribute (format: "Title manga cover")
            title = img_alt;
            if title.ends_with(" manga cover") {
                title = title.sub_string(0, title.len() - 12);
            }
            title = title.trim();
        }

        if title != "" {
            series.push(#{
                id: href,
                title: title,
                url: href,
                cover_url: cover,
                alternate_titles: [],
                authors: [],
                status: (),
                genres: []
            });
        }
    }

    // Ajax Search Pro returns a single result set (no pagination), so don't
    // signal more pages — `page` is ignored above and page 2 would just repeat.
    #{ series: series, has_more: false, total: series.len() }
}

fn get_series(id_or_url, auth) {
    let url = id_or_url;
    if !id_or_url.starts_with("http") {
        url = `${BASE_URL}/manga/${id_or_url}`;
    }

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
            if src != () && src.contains("cdn2.fandommanga.xyz") {
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
        url: url
    }
}

fn get_chapters(series_id, auth) {
    let url = series_id;
    if !series_id.starts_with("http") {
        url = `${BASE_URL}/manga/${series_id}`;
    }

    let html = fetch_html(url);
    let doc = html_parse(html);
    let chapters = [];

    // RoliaScan uses /read/ URLs for chapters (e.g., /read/kinato-s-magic/chapter-9)
    let ch_links = html_select(doc, "a[href*='/read/']");

    // Fallback: also try /chapter links
    if ch_links.len() == 0 {
        ch_links = html_select(doc, "a[href*='/chapter']");
    }

    let seen = #{};
    let idx = 0;

    for link in ch_links {
        let href = element_attr(link, "href");
        if href == () || href == "" { continue; }
        if seen.contains(href) { continue; }

        // Skip non-chapter links (navigation, etc.)
        if !href.contains("chapter") { continue; }

        seen[href] = true;

        let ch_title = element_text(link).trim();
        if ch_title == "" { continue; }

        // Extract chapter number from URL or title
        let ch_num = `${idx + 1}`;

        // Try URL pattern first: chapter-{number}
        let url_match = regex_find("chapter-(\\d+\\.?\\d*)", href);
        if url_match != () && url_match != "" {
            // url_match is like "chapter-9", extract the number
            let parts = url_match.split("-");
            if parts.len() >= 2 {
                ch_num = parts[1];
            }
        }

        // Fallback: try title text
        if ch_num == `${idx + 1}` {
            let title_match = regex_find("(?i)chapter[\\s.-]*(\\d+\\.?\\d*)", ch_title);
            if title_match != () && title_match != "" {
                // Extract just the number
                let num = regex_find("\\d+\\.?\\d*", title_match);
                if num != () && num != "" {
                    ch_num = num;
                }
            } else {
                let num_match2 = regex_find("(\\d+\\.?\\d*)", ch_title);
                if num_match2 != () && num_match2 != "" {
                    ch_num = num_match2;
                }
            }
        }

        chapters.push(#{
            id: href,
            series_id: series_id,
            number: ch_num,
            title: ch_title,
            url: href
        });
        idx += 1;
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

// True if a URL looks like a real manga page image hosted on the
// (rotating) RoliaScan page CDN, not a site asset/logo/ad/cover.
fn is_page_image(src) {
    if src == () || src == "" { return false; }
    let s = src.to_lower();
    // Site assets / chrome — never pages.
    if s.contains("/assets/") || s.contains("roliascann.com") { return false; }
    if s.contains("logo") || s.contains("icon") || s.contains("avatar") { return false; }
    if s.contains("banner") || s.contains("loading") || s.contains("favicon") { return false; }
    // Must be an image extension.
    if !(s.contains(".webp") || s.contains(".jpg") || s.contains(".jpeg") || s.contains(".png")) {
        return false;
    }
    // Known/likely page CDNs. love4awalk is the current host (2026);
    // fandommanga is the legacy host. Also accept any CDN-style host that
    // carries a manga page path so future CDN renames keep working.
    if s.contains("love4awalk.xyz") || s.contains("fandommanga.xyz") { return true; }
    if s.contains("//cdn") && (s.contains("/chapters/") || s.contains("/manga/")) { return true; }
    return false;
}

fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;
    if !chapter_id.starts_with("http") {
        url = `${BASE_URL}${chapter_id}`;
    }

    let html = fetch_html(url);
    let doc = html_parse(html);
    let pages = [];
    let seen = #{};
    let idx = 0;

    // Page images live as <img src='https://cdn2.love4awalk.xyz/.../N.webp'
    // class='... img-fluid'> inside the reading-content container. Prefer
    // those, but fall back to scanning every <img> on the page.
    let imgs = html_select(doc, ".reading-content img, .read-content img, img.img-fluid");
    if imgs.len() == 0 {
        imgs = html_select(doc, "img");
    }

    for img in imgs {
        let src = element_attr(img, "src");
        if src == () || src == "" {
            src = element_attr(img, "data-src");
        }
        if src == () || src == "" { continue; }
        src = src.trim();

        if !is_page_image(src) { continue; }
        if seen.contains(src) { continue; }
        seen[src] = true;

        pages.push(#{
            index: idx,
            url: src,
            referer: url,
            headers: page_headers(url)
        });
        idx += 1;
    }

    // Fallback: some layouts embed the URLs in JS/JSON rather than <img>.
    // Match any love4awalk/fandommanga page image URL in the raw HTML.
    if pages.len() == 0 {
        let cdn_urls = regex_find_all("https?://[a-z0-9.-]*(?:love4awalk|fandommanga)\\.xyz/[^\"'\\s)]+\\.(?:webp|jpg|jpeg|png)", html);
        for img_url in cdn_urls {
            let clean = img_url.trim();
            if seen.contains(clean) { continue; }
            seen[clean] = true;
            pages.push(#{
                index: idx,
                url: clean,
                referer: url,
                headers: page_headers(url)
            });
            idx += 1;
        }
    }

    pages
}

/// Get latest updates for browsing
fn get_latest_updates(page, auth) {
    // RoliaScan uses /manga?page=X for pagination (up to 30 pages)
    let url = `${BASE_URL}/manga`;
    if page > 1 {
        url = `${BASE_URL}/manga?page=${page}`;
    }

    let html = fetch_html(url);
    let doc = html_parse(html);
    let series = [];

    // RoliaScan uses simple a > img + h3/h4 structure
    let items = html_select(doc, "a[href*='/manga/']");
    let seen = #{};

    for item in items {
        let href = element_attr(item, "href");
        if href == () || href == "" { continue; }

        // Skip duplicates and non-series links
        if seen.contains(href) { continue; }
        if !href.contains("/manga/") { continue; }
        // Skip chapter links
        if href.contains("/chapter") { continue; }
        if href.contains("/read/") { continue; }

        seen[href] = true;

        // Get cover image first (we need it to extract alt text for title)
        let cover = ();
        let img_alt = "";
        let imgs = html_select(item, "img");
        if imgs.len() > 0 {
            cover = element_attr(imgs[0], "src");
            if cover == () || cover == "" {
                cover = element_attr(imgs[0], "data-src");
            }
            // Get alt text as fallback for title
            img_alt = element_attr(imgs[0], "alt");
            if img_alt == () { img_alt = ""; }
        }

        // Get title from h3, h4, .title, or text content
        let title = "";
        let title_els = html_select(item, "h3, h4, .title");
        if title_els.len() > 0 {
            title = element_text(title_els[0]).trim();
        }
        if title == "" {
            // Try getting text after the image
            title = element_text(item).trim();
            // Clean up - remove extra whitespace
            if title.len() > 100 {
                title = "";
            }
        }
        if title == "" && img_alt != "" {
            // Extract title from img alt attribute (format: "Title manga cover")
            title = img_alt;
            if title.ends_with(" manga cover") {
                title = title.sub_string(0, title.len() - 12);
            }
            title = title.trim();
        }

        if title != "" && cover != () {
            series.push(#{
                id: href,
                title: title,
                url: href,
                cover_url: cover,
                alternate_titles: [],
                authors: [],
                status: (),
                genres: []
            });
        }
    }

    // RoliaScan has up to 30 pages of manga
    let has_more = page < 30 && series.len() > 0;
    #{ series: series, has_more: has_more }
}

/// Get popular manga (uses manga listing with pagination)
fn get_popular(page, auth) {
    // RoliaScan uses /manga?page=X for pagination
    let url = `${BASE_URL}/manga`;
    if page > 1 {
        url = `${BASE_URL}/manga?page=${page}`;
    }

    let html = fetch_html(url);
    let doc = html_parse(html);
    let series = [];

    let items = html_select(doc, "a[href*='/manga/']");
    let seen = #{};

    for item in items {
        let href = element_attr(item, "href");
        if href == () || href == "" { continue; }
        if seen.contains(href) { continue; }
        if href.contains("/chapter") { continue; }
        if href.contains("/read/") { continue; }

        seen[href] = true;

        // Get cover image first (we need it to extract alt text for title)
        let cover = ();
        let img_alt = "";
        let imgs = html_select(item, "img");
        if imgs.len() > 0 {
            cover = element_attr(imgs[0], "src");
            if cover == () || cover == "" {
                cover = element_attr(imgs[0], "data-src");
            }
            // Get alt text as fallback for title
            img_alt = element_attr(imgs[0], "alt");
            if img_alt == () { img_alt = ""; }
        }

        let title = "";
        let title_els = html_select(item, "h3, h4, .title");
        if title_els.len() > 0 {
            title = element_text(title_els[0]).trim();
        }
        if title == "" {
            title = element_text(item).trim();
            if title.len() > 100 { title = ""; }
        }
        if title == "" && img_alt != "" {
            // Extract title from img alt attribute (format: "Title manga cover")
            title = img_alt;
            if title.ends_with(" manga cover") {
                title = title.sub_string(0, title.len() - 12);
            }
            title = title.trim();
        }

        if title != "" && cover != () {
            series.push(#{
                id: href,
                title: title,
                url: href,
                cover_url: cover,
                alternate_titles: [],
                authors: [],
                status: (),
                genres: []
            });
        }
    }

    series
}
