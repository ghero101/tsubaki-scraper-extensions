// BatCave Scraper Add-on (Rhai)
// Browser-based scraper for batcave.biz (formerly batcave.cc)
// Western comics source featuring Marvel, DC, Image, Dark Horse, and more
//
// URL Patterns:
//   Home: https://batcave.biz/
//   Comics List: /comix/ or /comix/?page={page}
//   Search: /index.php?do=search (POST) or /search/{query}/
//   Comic Page: /{id}-{slug}.html (e.g., /33758-batman-2025.html)
//   Reader: /reader/{comic-id}/{chapter-id} (e.g., /reader/11265/74861)
//
// Available APIs:
//   HTTP (fallback): http_get(url), http_get_with_headers(url, headers), http_post(url, body)
//   Browser: browser_launch(), browser_launch_stealth(), browser_goto(id, url),
//            browser_wait_for_cloudflare(id, timeout), browser_wait_for_selector(id, sel, timeout),
//            browser_get_html(id), browser_close(id), browser_is_available()
//   HTML: html_parse(html), html_select(html, selector), html_select_first(html, selector),
//         element_text(el), element_attr(el, attr)
//   JSON: json_parse(text), json_stringify(obj)
//   Regex: regex_match(pattern, text), regex_find(pattern, text), regex_find_all(pattern, text)
//   Utility: url_encode(text), url_decode(text)

const BASE_URL = "https://batcave.biz";

// ============================================================================
// Helper Functions
// ============================================================================

/// Get headers for HTTP requests (with optional mobile user-agent)
fn get_headers() {
    let s = if settings != () { settings } else { #{} };
    let use_mobile = if s.contains("use_mobile_ua") { s["use_mobile_ua"] } else { true };

    if use_mobile {
        #{
            "User-Agent": "Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.5",
            "Referer": BASE_URL
        }
    } else {
        #{
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.5",
            "Referer": BASE_URL
        }
    }
}

/// batcave.biz sits behind TWO gates that defeat plain HTTP and FlareSolverr:
///
///   1. A Cloudflare *managed* challenge ("Just a moment..." / Turnstile) —
///      the outer gate. Only a real JS-running browser clears it; plain HTTP
///      gets 403 and FlareSolverr's body comes back empty-titled.
///   2. A custom proof-of-work guard (the INNER gate). After CF clears, the
///      site serves a tiny spinner page that, in JS, computes a SHA-256 PoW
///      (hash of `token:nonce` starting with "00"), POSTs the result + browser
///      fingerprint to `/_v`, receives an upgraded `__guard_token` cookie, then
///      `location.replace()`s to the real URL. FlareSolverr returns BEFORE this
///      JS runs (it only waits out the CF Turnstile), so its body is always the
///      spinner page — which is why discover returned 0.
///
/// The headless stealth browser is the ONLY tier that solves both: it runs the
/// guard's PoW JS and follows the redirect. The catch is timing — the spinner
/// page has a `<body>` instantly, so we must NOT grab HTML the moment `body`
/// appears; we have to poll until the guard has redirected to real content.
///
/// Tier order: browser (solves both gates) -> FlareSolverr (CF only, usually
/// stuck on the guard) -> plain HTTP (cheap probe, almost always 403).

/// True when `html` is the CF "Just a moment" / managed-challenge page.
fn is_cf_challenge(html) {
    if html == () || html == "" { return true; }
    if html.contains("Just a moment") { return true; }
    if html.contains("cf_chl_opt") || html.contains("__cf_chl") { return true; }
    if html.contains("challenge-platform") { return true; }
    false
}

/// True when `html` is the custom PoW guard spinner page (inner gate).
/// Signatures: the `/_v` PoW POST, the obfuscated spinner class names, the
/// `__guard_token` script, or a guard `/_c?t=...&u=...` redirect URL — all with
/// no real listing content.
fn is_guard_page(html) {
    if html == () || html == "" { return true; }
    // Real content always carries comic cards; if we see those, it's NOT a gate.
    if html.contains("readed") || html.contains("grid-item") || html.contains("poster__") {
        return false;
    }
    if html.contains("/_v") && html.contains("pow_nonce") { return true; }
    if html.contains("powHash") || html.contains("runModern") || html.contains("runLegacy") { return true; }
    if html.contains("x46429") || html.contains("x78247") { return true; } // spinner divs
    if html.contains("__guard_token") || html.contains("/_c?t=") { return true; }
    false
}

/// True when `html` looks like a fully-rendered batcave content page.
fn is_real_content(html) {
    if html == () || html == "" { return false; }
    if is_cf_challenge(html) || is_guard_page(html) { return false; }
    true
}

/// Drive the stealth browser through CF + the PoW guard, polling until the
/// guard's JS has finished its PoW/redirect cycle and real content is in the DOM.
fn fetch_via_browser(url) {
    let browser_id = ();
    try {
        browser_id = browser_launch_stealth();
        browser_goto(browser_id, url);
        // Clear the Cloudflare managed challenge first.
        try { browser_wait_for_cloudflare(browser_id, 20000); } catch {}
        try { browser_wait_for_selector(browser_id, "body", 10000); } catch {}

        // Now poll: the guard spinner shows instantly, runs a ~1s SHA-256 PoW,
        // POSTs /_v, then location.replace()s to the target. Re-read the DOM on a
        // short cadence until we either see real content or run out of patience.
        // Budget ~24s (12 * 2s) — the modern PoW caps itself at 900ms but the
        // /_v round-trip + redirect + content render needs headroom.
        let html = browser_get_html(browser_id);
        let tries = 0;
        while tries < 12 {
            if is_real_content(html) {
                try { browser_close(browser_id); } catch {}
                return html;
            }
            // If we're still on the CF challenge, give it extra room to clear.
            if is_cf_challenge(html) {
                try { browser_wait_for_cloudflare(browser_id, 8000); } catch {}
            }
            browser_sleep(2000);
            html = browser_get_html(browser_id);
            tries += 1;
        }
        // Final attempt: a directly-named content selector may have appeared even
        // if our heuristic was conservative.
        try { browser_wait_for_selector(browser_id, "a[href$='.html']", 6000); } catch {}
        html = browser_get_html(browser_id);
        try { browser_close(browser_id); } catch {}
        return html;
    } catch {
        if browser_id != () { try { browser_close(browser_id); } catch {} }
    }
    ()
}

fn fetch_html(url) {
    if browser_is_available() {
        let html = fetch_via_browser(url);
        if html != () && html != "" {
            return html;
        }
    }

    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 40000);
            // FlareSolverr clears CF but typically stalls on the PoW guard; only
            // accept its body if it actually carries content.
            if is_real_content(html) {
                return html;
            }
        } catch {}
    }

    // Last-resort plain HTTP — usually CF-blocked but cheap to attempt.
    http_get_with_headers(url, get_headers())
}

/// Extract comic ID from URL
/// URL format: /{id}-{slug}.html or https://batcave.biz/{id}-{slug}.html
fn extract_comic_id(url) {
    // Pattern: /33758-batman-2025.html -> 33758
    let found = regex_find("/(\\d+)-[^/]+\\.html", url);
    if found != "" {
        let num = regex_find("\\d+", found);
        if num != "" {
            return num;
        }
    }

    // Try alternative: just find leading number
    let parts = url.split("/");
    for part in parts {
        if part.ends_with(".html") {
            let clean = part.replace(".html", "");
            let id_part = clean.split("-")[0];
            let num = regex_find("^\\d+$", id_part);
            if num != "" {
                return num;
            }
        }
    }

    url
}

/// Extract slug from comic URL
/// URL format: /{id}-{slug}.html -> {slug}
fn extract_slug(url) {
    let found = regex_find("/\\d+-([^/]+)\\.html", url);
    if found != "" {
        // Remove the leading /ID- and trailing .html
        let clean = found.split("-");
        if clean.len() > 1 {
            // Join everything after the ID
            let slug_parts = [];
            for i in 1..clean.len() {
                slug_parts.push(clean[i]);
            }
            let slug = "";
            for i in 0..slug_parts.len() {
                if i > 0 { slug += "-"; }
                slug += slug_parts[i];
            }
            return slug.replace(".html", "");
        }
    }
    ""
}

/// Build full URL from comic ID and slug
fn build_comic_url(id, slug) {
    if slug != "" {
        `${BASE_URL}/${id}-${slug}.html`
    } else {
        `${BASE_URL}/${id}.html`
    }
}

/// Extract chapter ID from reader URL
/// URL format: /reader/{comic-id}/{chapter-id}
/// Returns the combined "{comic-id}/{chapter-id}" so get_chapter_pages can
/// rebuild the full /reader/ URL. (Returning only the chapter-id loses the
/// comic-id and makes the page fetch impossible.)
fn extract_chapter_id(url) {
    if url.contains("/reader/") {
        let parts = url.split("/reader/");
        if parts.len() > 1 {
            let tail = parts[1].split("?")[0].split("#")[0];
            // Strip any trailing slash
            while tail.ends_with("/") { tail = tail.sub_string(0, tail.len() - 1); }
            let path_parts = tail.split("/");
            if path_parts.len() >= 2 {
                return `${path_parts[0]}/${path_parts[1]}`;
            }
            return tail;
        }
    }
    url
}

/// Map status text to standard format
fn map_status(status_text) {
    if status_text == () || status_text == "" { return (); }
    let lower = status_text.to_lower();
    if lower.contains("ongoing") || lower.contains("active") {
        return "Ongoing";
    } else if lower.contains("completed") || lower.contains("complete") || lower.contains("finished") {
        return "Completed";
    } else if lower.contains("hiatus") {
        return "Hiatus";
    } else if lower.contains("cancelled") || lower.contains("canceled") {
        return "Cancelled";
    }
    ()
}

/// Parse issue/chapter number from text
fn parse_chapter_number(text) {
    if text == () || text == "" { return "0"; }

    let lower = text.to_lower();

    // Try "Issue #X" or "#X" pattern
    let issue_match = regex_find("(?:issue|#)\\s*#?(\\d+(?:\\.\\d+)?)", lower);
    if issue_match != "" {
        let num = regex_find("\\d+(?:\\.\\d+)?", issue_match);
        if num != "" {
            return num;
        }
    }

    // Try "Chapter X" pattern
    let ch_match = regex_find("(?:chapter|ch\\.?)\\s*#?(\\d+(?:\\.\\d+)?)", lower);
    if ch_match != "" {
        let num = regex_find("\\d+(?:\\.\\d+)?", ch_match);
        if num != "" {
            return num;
        }
    }

    // Try to find any number
    let any_num = regex_find("\\d+(?:\\.\\d+)?", text);
    if any_num != "" {
        return any_num;
    }

    "0"
}

/// Make URL absolute if relative
fn make_absolute_url(url) {
    if url.starts_with("http") {
        return url;
    }
    if url.starts_with("//") {
        return `https:${url}`;
    }
    if url.starts_with("/") {
        return `${BASE_URL}${url}`;
    }
    `${BASE_URL}/${url}`
}

/// Check if image URL is valid (not placeholder/icon/ad)
fn is_valid_image(url) {
    if url == () || url == "" { return false; }
    let lower = url.to_lower();
    if lower.contains("placeholder") { return false; }
    if lower.contains("loading") { return false; }
    if lower.contains("spinner") { return false; }
    if lower.contains("logo") { return false; }
    if lower.contains("icon") { return false; }
    if lower.contains("avatar") { return false; }
    if lower.contains("banner") { return false; }
    if lower.contains("advertisement") { return false; }
    if lower.contains("/ads/") { return false; }
    if lower.starts_with("data:") { return false; } // base64 lazyload placeholder
    true
}

/// Pull the real cover URL from a card's <img>, preferring lazy-load attrs.
/// batcave lazy-loads listing thumbnails: `src` is a base64/blank placeholder
/// and the real path lives in `data-src`.
fn extract_card_cover(item) {
    let imgs = html_select(item, "img");
    if imgs.len() == 0 { return (); }
    extract_card_cover_el(imgs[0])
}

/// Same as extract_card_cover but for an already-selected <img> element.
fn extract_card_cover_el(img) {
    let candidates = [
        element_attr(img, "data-src"),
        element_attr(img, "data-original"),
        element_attr(img, "data-lazy-src"),
        element_attr(img, "src")
    ];
    for c in candidates {
        if c != () && c != "" && is_valid_image(c) {
            return make_absolute_url(c);
        }
    }
    ()
}

/// Parse a comic listing/grid from a rendered page into the series[] shape.
/// Handles both card layouts batcave uses:
///   - `.readed` cards (search results, /comix/ list): link = a.readed__img
///   - `.poster.grid-item` cards (home page): the <a> itself is the card
fn parse_comic_cards(doc) {
    let series = [];
    let seen = #{};

    // Collect candidate card elements from both known layouts.
    let cards = html_select(doc, "div.readed, a.poster.grid-item, .poster.grid-item");

    for card in cards {
        // Resolve the comic link + title.
        let href = ();
        let title = "";

        // Card is itself an <a> (poster grid-item)?
        let self_href = element_attr(card, "href");
        if self_href != () && self_href.ends_with(".html") {
            href = self_href;
        } else {
            // Look for the primary link inside the card.
            let links = html_select(card, "a.readed__img, h2.readed__title a, .poster__title, a[href$='.html']");
            for l in links {
                let h = element_attr(l, "href");
                if h != () && h.ends_with(".html") {
                    href = h;
                    break;
                }
            }
        }

        if href == () || href == "" { continue; }
        if href.contains("index.php") || href.contains("/page/") { continue; }

        let comic_url = make_absolute_url(href);
        let id = extract_comic_id(comic_url);
        if id == () || id == "" { continue; }
        if seen.contains(id) { continue; }
        seen[id] = true;

        // Title: prefer dedicated title elements, then img alt, then link text.
        let title_els = html_select(card, "h2.readed__title, .poster__title, h2, h3, .title");
        if title_els.len() > 0 {
            title = element_text(title_els[0]).trim();
        }
        if title == "" {
            let imgs = html_select(card, "img");
            if imgs.len() > 0 {
                let alt = element_attr(imgs[0], "alt");
                if alt != () { title = alt.trim(); }
            }
        }
        if title == "" {
            title = element_text(card).trim();
        }
        if title == "" || title.len() < 2 { continue; }

        let cover_url = extract_card_cover(card);

        series.push(#{
            id: id,
            title: title,
            url: comic_url,
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

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "batcave-rhai",
        name: "BatCave",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "browser_automation"
    }
}

/// Search for series matching query
fn search_series(query, page, auth) {
    // BatCave uses a search URL pattern: /search/{query}/page/{page}/
    // or query parameter based search
    let encoded_query = url_encode(query);
    let url = `${BASE_URL}/?do=search&subaction=search&story=${encoded_query}`;

    if page > 1 {
        url = `${BASE_URL}/?do=search&subaction=search&story=${encoded_query}&search_start=${page}`;
    }

    let html = fetch_html(url);
    let doc = html_parse(html);

    let series = parse_comic_cards(doc);

    // Search returns one DLE result page; "more" is true only if we filled a
    // full page of cards (batcave shows 10 per page).
    let has_more = series.len() >= 10;

    #{ series: series, has_more: has_more, total: () }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let url = id_or_url;
    let id = id_or_url;

    if !id_or_url.starts_with("http") {
        // ID format might be "12345" or "12345-slug"
        if id_or_url.contains("-") {
            url = `${BASE_URL}/${id_or_url}.html`;
            id = id_or_url.split("-")[0];
        } else {
            // Need to find the full URL - this is a limitation
            url = `${BASE_URL}/${id_or_url}.html`;
        }
    } else {
        id = extract_comic_id(id_or_url);
    }

    let html = fetch_html(url);
    let doc = html_parse(html);

    // Extract title (page__head h1)
    let title = "";
    let title_els = html_select(doc, "h1, .page__title, h2.title");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }

    // Extract cover image (.page__poster img — real poster, not lazy thumb)
    let cover_url = ();
    let cover_els = html_select(doc, ".page__poster img, .poster__img img");
    if cover_els.len() > 0 {
        cover_url = extract_card_cover_el(cover_els[0]);
    }

    // Extract description (.page__text / .full-text)
    let description = ();
    let desc_els = html_select(doc, ".page__text, .full-text, .full-story");
    if desc_els.len() > 0 {
        let desc_text = element_text(desc_els[0]).trim();
        if desc_text.len() > 20 {
            description = desc_text;
        }
    }

    // Extract genres/categories (.page__tags a)
    let genres = [];
    let genre_els = html_select(doc, ".page__tags a, a[href*='/genres/']");
    for el in genre_els {
        let genre = element_text(el).trim();
        if genre != "" && !genres.contains(genre) && genre.len() > 1 {
            genres.push(genre);
        }
    }

    // Metadata rows: ul.page__list > li, each "<div>Label:</div> value(s)"
    let info_els = html_select(doc, "ul.page__list li, .page__list li");

    // Extract status (label "Release type" or "Status")
    let status = ();
    for el in info_els {
        let text = element_text(el);
        let lower = text.to_lower();
        if lower.contains("status") || lower.contains("release type") {
            status = map_status(text);
            if status != () { break; }
        }
    }

    // Extract year
    let year = ();
    // Try from title first (e.g., "Batman (2025-)")
    let year_match = regex_find("\\((19|20)\\d{2}", title);
    if year_match != "" {
        year = regex_find("(19|20)\\d{2}", year_match);
    }
    // Fallback: search in info
    if year == () || year == "" {
        for el in info_els {
            let text = element_text(el);
            if text.to_lower().contains("year") || text.to_lower().contains("released") {
                let y = regex_find("(19|20)\\d{2}", text);
                if y != "" {
                    year = y;
                    break;
                }
            }
        }
    }

    // Extract authors/writers
    let authors = [];
    for el in info_els {
        let text = element_text(el).to_lower();
        if text.contains("writer") || text.contains("author") {
            let links = html_select(el, "a");
            for link in links {
                let author = element_text(link).trim();
                if author != "" && !authors.contains(author) {
                    authors.push(author);
                }
            }
            // If no links, try plain text
            if authors.len() == 0 {
                let full_text = element_text(el);
                // Remove label
                let clean = full_text.replace("Writer:", "").replace("Author:", "").replace("writer:", "").replace("author:", "").trim();
                let parts = clean.split(",");
                for part in parts {
                    let author = part.trim();
                    if author != "" && !authors.contains(author) {
                        authors.push(author);
                    }
                }
            }
        }
    }

    // Extract artists
    let artists = [];
    for el in info_els {
        let text = element_text(el).to_lower();
        if text.contains("artist") || text.contains("illustrator") {
            let links = html_select(el, "a");
            for link in links {
                let artist = element_text(link).trim();
                if artist != "" && !artists.contains(artist) {
                    artists.push(artist);
                }
            }
        }
    }

    // Extract publisher as tag
    let tags = [];
    for el in info_els {
        let text = element_text(el).to_lower();
        if text.contains("publisher") {
            let links = html_select(el, "a");
            for link in links {
                let publisher = element_text(link).trim();
                if publisher != "" && !tags.contains(publisher) {
                    tags.push(publisher);
                }
            }
        }
    }

    #{
        id: id,
        title: title,
        alternate_titles: [],
        description: description,
        cover_url: cover_url,
        authors: authors,
        artists: artists,
        status: status,
        genres: genres,
        tags: tags,
        year: year,
        content_rating: (),
        url: url,
        extra: #{}
    }
}

/// Get all chapters/issues for a series
fn get_chapters(series_id, auth) {
    let url = series_id;

    if !series_id.starts_with("http") {
        if series_id.contains("-") {
            url = `${BASE_URL}/${series_id}.html`;
        } else {
            url = `${BASE_URL}/${series_id}.html`;
        }
    }

    let html = fetch_html(url);
    let doc = html_parse(html);

    let chapters = [];
    let seen = #{};

    let comic_id = extract_comic_id(url);

    // Preferred: structured chapter rows. Each `.cl__item` carries
    //   .cl__item-num    -> "#4"
    //   .cl__item-title a -> /reader/{comic}/{chapter}, title text
    //   .cl__item-pages  -> "94 pages"
    let rows = html_select(doc, ".cl__item, li.cl__item, .page__chapters-list .cl__item");

    for row in rows {
        let links = html_select(row, ".cl__item-title a, a[href*='/reader/']");
        if links.len() == 0 { continue; }
        let link = links[0];
        let href = element_attr(link, "href");
        if href == () || href == "" || !href.contains("/reader/") { continue; }

        let chapter_url = make_absolute_url(href);
        let ch_id = extract_chapter_id(chapter_url);
        if seen.contains(ch_id) { continue; }
        seen[ch_id] = true;

        let chapter_title = element_text(link).trim();

        // Chapter number: prefer .cl__item-num ("#4"), else parse title/url.
        let number = "0";
        let num_els = html_select(row, ".cl__item-num");
        if num_els.len() > 0 {
            let n = regex_find("\\d+(?:\\.\\d+)?", element_text(num_els[0]));
            if n != "" { number = n; }
        }
        if number == "0" { number = parse_chapter_number(chapter_title); }
        if number == "0" { number = parse_chapter_number(href); }

        // Page count from .cl__item-pages
        let page_count = ();
        let pg_els = html_select(row, ".cl__item-pages");
        if pg_els.len() > 0 {
            let pc = regex_find("\\d+", element_text(pg_els[0]));
            if pc != "" { page_count = parse_int(pc); }
        }

        chapters.push(#{
            id: ch_id,
            series_id: comic_id,
            number: number,
            title: chapter_title,
            volume: (),
            language: "en",
            scanlator: (),
            url: chapter_url,
            published_at: (),
            page_count: page_count,
            extra: #{}
        });
    }

    // Fallback: bare reader links if structured rows weren't found.
    if chapters.len() == 0 {
        let chapter_links = html_select(doc, "a[href*='/reader/']");
        for link in chapter_links {
            let href = element_attr(link, "href");
            if href == () || href == "" || !href.contains("/reader/") { continue; }

            let chapter_url = make_absolute_url(href);
            let ch_id = extract_chapter_id(chapter_url);
            if seen.contains(ch_id) { continue; }
            seen[ch_id] = true;

            let chapter_title = element_text(link).trim();
            let number = parse_chapter_number(chapter_title);
            if number == "0" { number = parse_chapter_number(href); }

            chapters.push(#{
                id: ch_id,
                series_id: comic_id,
                number: number,
                title: chapter_title,
                volume: (),
                language: "en",
                scanlator: (),
                url: chapter_url,
                published_at: (),
                page_count: (),
                extra: #{}
            });
        }
    }

    // If no chapters found via links, the comic might be a single volume
    // Check for direct reader link or page images
    if chapters.len() == 0 {
        // Try to find a "Read" or "View" button
        let read_links = html_select(doc, "a.read-btn, a.read-now, a[href*='/reader/'], .read a");
        for link in read_links {
            let href = element_attr(link, "href");
            if href != () && href != "" {
                let chapter_url = make_absolute_url(href);
                chapters.push(#{
                    id: extract_chapter_id(chapter_url),
                    series_id: comic_id,
                    number: "1",
                    title: "Full Issue",
                    volume: (),
                    language: "en",
                    scanlator: (),
                    url: chapter_url,
                    published_at: (),
                    page_count: (),
                    extra: #{}
                });
                break;
            }
        }
    }

    chapters
}

/// Get page URLs for a chapter/issue
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;

    if !chapter_id.starts_with("http") {
        // Assume format: comic_id/chapter_id
        if chapter_id.contains("/") {
            url = `${BASE_URL}/reader/${chapter_id}`;
        } else {
            // Can't construct URL without more info
            throw `Invalid chapter ID format: ${chapter_id}`;
        }
    }

    let html = fetch_html(url);

    let pages = [];
    let idx = 0;
    let seen_urls = #{};

    // Primary path: the reader ships its page list inside
    //   window.__DATA__ = { ... "images":["https:\/\/img.batcave.biz\/..."] ... }
    // Grab the "images" array specifically (NOT the earlier "chapters"/"fav_folders"
    // arrays). The URL strings contain no ']', so the array ends at the first ']'.
    let images_match = regex_find("\"images\"\\s*:\\s*\\[[^\\]]*\\]", html);
    if images_match != "" {
        let array_match = regex_find("\\[[^\\]]*\\]", images_match);
        if array_match != "" {
            let page_data = json_parse(array_match);
            if page_data != () && type_of(page_data) == "array" {
                for item in page_data {
                    let img_url = ();
                    if type_of(item) == "string" {
                        img_url = item;
                    } else if type_of(item) == "map" {
                        if item.contains("url") { img_url = item["url"]; }
                        else if item.contains("src") { img_url = item["src"]; }
                        else if item.contains("image") { img_url = item["image"]; }
                    }
                    if img_url == () || img_url == "" { continue; }
                    if !is_valid_image(img_url) { continue; }
                    img_url = make_absolute_url(img_url);
                    if seen_urls.contains(img_url) { continue; }
                    seen_urls[img_url] = true;
                    pages.push(#{
                        index: idx,
                        url: img_url,
                        headers: #{ "Referer": url },
                        referer: url
                    });
                    idx += 1;
                }
            }
        }
    }

    // Fallback: scrape <img> tags from the rendered reader DOM.
    if pages.len() == 0 {
        let doc = html_parse(html);
        let page_imgs = html_select(doc, ".reader__item img, .reader img, #reader img, .reading-content img, main img, article img");
        for img in page_imgs {
            let img_url = element_attr(img, "data-src");
            if img_url == () || img_url == "" { img_url = element_attr(img, "src"); }
            if img_url == () || img_url == "" { img_url = element_attr(img, "data-original"); }
            if img_url == () || img_url == "" { continue; }
            if !is_valid_image(img_url) { continue; }
            img_url = make_absolute_url(img_url);
            if seen_urls.contains(img_url) { continue; }
            seen_urls[img_url] = true;
            pages.push(#{
                index: idx,
                url: img_url,
                headers: #{ "Referer": url },
                referer: url
            });
            idx += 1;
        }
    }

    pages
}

/// Get latest updates (newest comics). Uses the /comix/ list which is sorted
/// newest-first and paginates via /comix/page/{n}.
fn get_latest_updates(page, auth) {
    let url = `${BASE_URL}/comix/`;
    if page > 1 {
        url = `${BASE_URL}/comix/page/${page}/`;
    }

    let html = fetch_html(url);
    let doc = html_parse(html);

    let series = parse_comic_cards(doc);
    let has_more = series.len() >= 10;

    #{ series: series, has_more: has_more }
}

/// Get popular comics. batcave's home page shows the curated/hot grid
/// (`.poster.grid-item` cards); fall back to the /comix/ list for deeper pages.
fn get_popular(page, auth) {
    let url = BASE_URL;
    if page > 1 {
        url = `${BASE_URL}/comix/page/${page}/`;
    }

    let html = fetch_html(url);
    let doc = html_parse(html);

    let series = parse_comic_cards(doc);
    let has_more = series.len() >= 10;

    #{ series: series, has_more: has_more }
}
