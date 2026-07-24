// MangaOwl Scraper Add-on (Rhai)
// Browser-based scraper for mangaowl.io (Cloudflare protected)
// Uses WordPress Madara theme structure
//
// Available APIs:
//   HTTP (fallback): http_get(url), http_get_with_headers(url, headers)
//   Browser: browser_launch(), browser_goto(id, url), browser_wait_for_cloudflare(id, timeout)
//            browser_get_html(id), browser_close(id), browser_is_available()
//   HTML: html_parse(html), html_select(html, selector), element_text(el), element_attr(el, attr)
//   Regex: regex_match(pattern, text), regex_find(pattern, text)
//   url_encode(text) -> string

const BASE_URL = "https://mangaowl.io";

/// Three-tier fetch: browser → FlareSolverr → plain HTTP. mangaowl.io sits
/// behind Cloudflare, so plain HTTP is almost always blocked — but it's the
/// cheapest probe to keep around as a last resort.
///
/// Each tier is individually wrapped so an exception falls through to the
/// next. The browser-tier `return html` skipped the FlareSolverr fallback
/// even when the browser returned an empty or CF-challenge page; now we
/// short-circuit only on a clearly non-empty body.
fn fetch_html(url) {
    if browser_is_available() {
        let browser_id = ();
        try {
            browser_id = browser_launch();
            browser_goto(browser_id, url);
            browser_wait_for_cloudflare(browser_id, 15000);
            let html = browser_get_html(browser_id);
            try { browser_close(browser_id); } catch {}
            if html != () && html != "" && html.len() > 500 {
                return html;
            }
        } catch {
            if browser_id != () { try { browser_close(browser_id); } catch {} }
        }
    }

    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 30000);
            if html != () && html != "" && html.len() > 500 {
                return html;
            }
        } catch {}
    }

    // Last-resort plain HTTP. Usually CF-blocked on mangaowl.io but cheap.
    try {
        return http_get_with_headers(url, get_headers());
    } catch {
        return "";
    }
}

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "mangaowl-rhai",
        name: "MangaOwl",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "browser_automation"
    }
}

/// Get headers for HTTP fallback requests
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Referer": BASE_URL,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"
    }
}

/// Search for series matching query
fn search_series(query, page, auth) {
    let encoded_query = url_encode(query);
    let url = `${BASE_URL}/?s=${encoded_query}&post_type=wp-manga&paged=${page}`;

    let html = fetch_html(url);
    let doc = html_parse(html);

    let series = [];

    // Select search result items (Madara theme structure)
    let items = html_select(html, "div.page-item-detail");
    if items.len() == 0 {
        items = html_select(html, ".page-listing-item");
    }
    if items.len() == 0 {
        items = html_select(html, "div.c-tabs-item__content");
    }

    for item in items {
        // Get the title link - MangaOwl uses h1 not h3
        let title_links = html_select(item, ".post-title a");
        if title_links.len() == 0 {
            title_links = html_select(item, ".post-title h1 a");
        }
        if title_links.len() == 0 {
            title_links = html_select(item, "h1 a");
        }
        if title_links.len() == 0 {
            title_links = html_select(item, "h3 a");
        }
        if title_links.len() == 0 {
            continue;
        }
        let link = title_links[0];

        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Extract slug from URL
        let slug = extract_slug(href);
        if slug == "" {
            continue;
        }

        // Get title
        let title = element_text(link).trim();
        if title == "" {
            title = element_attr(link, "title");
            if title != () {
                title = title.trim();
            }
        }

        // Get cover image
        let cover_url = ();
        let imgs = html_select(item, ".item-thumb img");
        if imgs.len() == 0 {
            imgs = html_select(item, "img");
        }
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
            if cover_url == () || cover_url == "" {
                cover_url = element_attr(imgs[0], "data-src");
            }
        }

        // Get genres if available
        let genres = [];
        let genre_links = html_select(item, ".mg_genres a, .manga-genre-1 a");
        for g in genre_links {
            let genre = element_text(g).trim();
            if genre != "" && !genres.contains(genre) {
                genres.push(genre);
            }
        }

        // Get status if available
        let status = ();
        let status_els = html_select(item, ".post-on, .mg_status");
        for el in status_els {
            let text = element_text(el).to_lower();
            if text.contains("ongoing") {
                status = "Ongoing";
            } else if text.contains("completed") {
                status = "Completed";
            }
        }

        series.push(#{
            id: slug,
            title: title,
            url: href,
            cover_url: cover_url,
            alternate_titles: [],
            authors: [],
            artists: [],
            status: status,
            genres: genres,
            tags: [],
            description: ()
        });
    }

    // Check for next page
    let has_more = false;
    let next_pages = html_select(html, "a.next, a.nextpostslink, .nav-next a");
    if next_pages.len() > 0 {
        has_more = true;
    }

    #{ series: series, has_more: has_more, total: () }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let url = id_or_url;
    let slug = id_or_url;

    if !id_or_url.starts_with("http") {
        url = `${BASE_URL}/read-1/${id_or_url}/`;
    } else {
        slug = extract_slug(id_or_url);
    }

    let html = fetch_html(url);
    let doc = html_parse(html);

    // Extract title
    let title = "";
    let title_els = html_select(html, ".post-title h1");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }
    if title == "" {
        title_els = html_select(html, "h1");
        if title_els.len() > 0 {
            title = element_text(title_els[0]).trim();
        }
    }

    // Extract cover
    let cover_url = ();
    let cover_imgs = html_select(html, ".summary_image img");
    if cover_imgs.len() == 0 {
        cover_imgs = html_select(html, ".tab-summary img");
    }
    if cover_imgs.len() > 0 {
        cover_url = element_attr(cover_imgs[0], "src");
        if cover_url == () || cover_url == "" {
            cover_url = element_attr(cover_imgs[0], "data-src");
        }
    }

    // Extract description
    let description = ();
    let desc_els = html_select(html, ".manga-excerpt p, .summary_content .post-content_item p, .description-summary p");
    if desc_els.len() > 0 {
        description = element_text(desc_els[0]).trim();
        // Clean up "Description:" prefix if present
        if description.to_lower().starts_with("description") {
            let parts = description.split(":");
            if parts.len() > 1 {
                description = parts[1].trim();
            }
        }
    }

    // Extract authors
    let authors = [];
    let author_els = html_select(html, ".author-content a, .manga-authors a");
    for el in author_els {
        let author = element_text(el).trim();
        if author != "" && !authors.contains(author) {
            authors.push(author);
        }
    }

    // Extract artists
    let artists = [];
    let artist_els = html_select(html, ".artist-content a, .manga-artists a");
    for el in artist_els {
        let artist = element_text(el).trim();
        if artist != "" && !artists.contains(artist) {
            artists.push(artist);
        }
    }

    // Extract status
    let status = ();
    let status_els = html_select(html, ".post-status .post-content_item, .summary-content");
    for el in status_els {
        let text = element_text(el).to_lower();
        if text.contains("status") {
            if text.contains("ongoing") || text.contains("publishing") {
                status = "Ongoing";
            } else if text.contains("completed") || text.contains("finished") {
                status = "Completed";
            } else if text.contains("hiatus") {
                status = "Hiatus";
            } else if text.contains("cancelled") || text.contains("canceled") {
                status = "Cancelled";
            }
        }
    }

    // Extract genres
    let genres = [];
    let genre_els = html_select(html, ".genres-content a, .manga-genre-1 a");
    for el in genre_els {
        let genre = element_text(el).trim();
        if genre != "" && !genres.contains(genre) {
            genres.push(genre);
        }
    }

    // Extract alternative titles
    let alt_titles = [];
    let alt_els = html_select(html, ".post-content_item .alternative, .manga-alt");
    for el in alt_els {
        let text = element_text(el).trim();
        let alts = text.split(",");
        for alt in alts {
            let cleaned = alt.trim();
            if cleaned != "" && cleaned != title && !alt_titles.contains(cleaned) {
                alt_titles.push(cleaned);
            }
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
        year: (),
        content_rating: "suggestive",
        url: url,
        extra: #{
            auto_match_metadata: true,
            source_name: "MangaOwl"
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let url = series_id;

    if !series_id.starts_with("http") {
        url = `${BASE_URL}/read-1/${series_id}/`;
    }

    let html = fetch_html(url);
    let doc = html_parse(html);

    let chapters = [];
    let seen = #{};

    // Find chapter links (Madara theme uses .wp-manga-chapter class)
    let chapter_links = html_select(html, ".wp-manga-chapter a, .listing-chapters_wrap li a, ul.main li a");

    for link in chapter_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Skip non-chapter links
        if !href.contains("chapter") {
            continue;
        }

        // Extract chapter number from URL or text
        let chapter_num = extract_chapter_number(href);

        // Skip duplicates
        if seen.contains(chapter_num) {
            continue;
        }
        seen[chapter_num] = true;

        // Get chapter title
        let chapter_title = element_text(link).trim();

        // Build full URL if needed
        let chapter_url = href;
        if !href.starts_with("http") {
            if href.starts_with("/") {
                chapter_url = `${BASE_URL}${href}`;
            } else {
                chapter_url = `${BASE_URL}/${href}`;
            }
        }

        chapters.push(#{
            id: chapter_url,
            series_id: series_id,
            number: chapter_num,
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

    // Sort chapters by number (descending order from site, reverse to ascending)
    chapters.reverse();

    chapters
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;

    if !chapter_id.starts_with("http") {
        url = `${BASE_URL}${chapter_id}`;
    }

    let html = fetch_html(url);
    let doc = html_parse(html);

    let pages = [];
    let idx = 0;

    // Find page images in the reader container
    // Madara theme typically uses .reading-content img
    let page_imgs = html_select(html, ".reading-content img, .read-container img, #readerarea img");

    for img in page_imgs {
        let img_url = element_attr(img, "src");
        if img_url == () || img_url == "" {
            img_url = element_attr(img, "data-src");
        }
        if img_url == () || img_url == "" {
            img_url = element_attr(img, "data-lazy-src");
        }

        if img_url != () && img_url != "" {
            // Skip non-page images (logos, ads, etc.)
            if img_url.contains("logo") || img_url.contains("banner") || img_url.contains("advertisement") {
                continue;
            }

            // Ensure we have a valid image URL
            if img_url.contains(".jpg") || img_url.contains(".png") || img_url.contains(".webp") || img_url.contains(".gif") || img_url.contains("wp-content/uploads") {
                pages.push(#{
                    index: idx,
                    url: img_url,
                    headers: #{
                        "Referer": url
                    },
                    referer: url
                });
                idx += 1;
            }
        }
    }

    pages
}

/// Get latest updates
fn get_latest_updates(page, auth) {
    // MangaOwl uses /read-1/ with Madara's m_orderby and page/ pagination
    let url = `${BASE_URL}/read-1/?m_orderby=latest`;
    if page > 1 {
        url = `${BASE_URL}/read-1/page/${page}/?m_orderby=latest`;
    }

    let html = fetch_html(url);
    let doc = html_parse(html);

    let series = [];

    // Parse latest updates - Madara theme uses .page-item-detail for each card
    let items = html_select(html, ".page-item-detail");
    if items.len() == 0 {
        items = html_select(html, ".page-listing-item");
    }

    for item in items {
        // MangaOwl uses .post-title with h1 (not h3)
        let title_links = html_select(item, ".post-title a");
        if title_links.len() == 0 {
            title_links = html_select(item, ".post-title h1 a");
        }
        if title_links.len() == 0 {
            title_links = html_select(item, "h1 a");
        }
        if title_links.len() == 0 {
            title_links = html_select(item, "h3 a");
        }
        if title_links.len() == 0 {
            // Fallback: find any link to /read-1/ within item
            title_links = html_select(item, "a[href*='/read-1/']");
        }
        if title_links.len() == 0 {
            continue;
        }
        let link = title_links[0];

        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        let slug = extract_slug(href);
        let title = element_text(link).trim();
        if title == "" {
            let title_attr = element_attr(link, "title");
            if title_attr != () {
                title = title_attr.trim();
            }
        }

        let cover_url = ();
        let imgs = html_select(item, ".item-thumb img, img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
            if cover_url == () || cover_url == "" {
                cover_url = element_attr(imgs[0], "data-src");
            }
        }

        if slug != "" && title != "" {
            series.push(#{
                id: slug,
                title: title,
                url: href,
                cover_url: cover_url,
                updated_at: ()
            });
        }
    }

    // Check for next page
    let has_more = false;
    let next_links = html_select(html, "a.next, a.nextpostslink, .nav-next a, .wp-pagenavi a.nextpostslink");
    if next_links.len() > 0 {
        has_more = true;
    }
    // Fallback: check page link numbers
    if !has_more {
        let next_page = page + 1;
        let page_links = html_select(html, ".wp-pagenavi a, .page-numbers a");
        for pl in page_links {
            let pl_href = element_attr(pl, "href");
            if pl_href != () && pl_href.contains(`/page/${next_page}`) {
                has_more = true;
                break;
            }
        }
    }
    // If we got a full page, likely more exist
    if !has_more && series.len() >= 10 {
        has_more = true;
    }

    // Limit pages to prevent infinite loops
    if page >= 50 {
        has_more = false;
    }

    #{ series: series, has_more: has_more }
}

/// Get popular series
fn get_popular(page, auth) {
    // MangaOwl uses read-1 path with m_orderby parameter and page/ pagination
    let url = `${BASE_URL}/read-1/?m_orderby=views`;
    if page > 1 {
        url = `${BASE_URL}/read-1/page/${page}/?m_orderby=views`;
    }

    let html = fetch_html(url);
    let doc = html_parse(html);

    let series = [];

    let items = html_select(html, ".page-item-detail");
    if items.len() == 0 {
        items = html_select(html, ".page-listing-item");
    }

    for item in items {
        // MangaOwl uses .post-title with h1, not h3
        let title_links = html_select(item, ".post-title a");
        if title_links.len() == 0 {
            title_links = html_select(item, ".post-title h1 a");
        }
        if title_links.len() == 0 {
            title_links = html_select(item, "h1 a");
        }
        if title_links.len() == 0 {
            title_links = html_select(item, "h3 a");
        }
        if title_links.len() == 0 {
            title_links = html_select(item, "a[href*='/read-1/']");
        }
        if title_links.len() == 0 {
            continue;
        }
        let link = title_links[0];

        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        let slug = extract_slug(href);
        let title = element_text(link).trim();
        if title == "" {
            let title_attr = element_attr(link, "title");
            if title_attr != () {
                title = title_attr.trim();
            }
        }

        let cover_url = ();
        let imgs = html_select(item, ".item-thumb img, img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
            if cover_url == () || cover_url == "" {
                cover_url = element_attr(imgs[0], "data-src");
            }
        }

        if slug != "" && title != "" {
            series.push(#{
                id: slug,
                title: title,
                url: href,
                cover_url: cover_url
            });
        }
    }

    // Check for more pages
    let has_more = false;
    let next_links = html_select(html, "a.next, a.nextpostslink, .nav-next a, .wp-pagenavi a.nextpostslink");
    if next_links.len() > 0 {
        has_more = true;
    }
    if !has_more {
        let next_page = page + 1;
        let page_links = html_select(html, ".wp-pagenavi a, .page-numbers a");
        for pl in page_links {
            let pl_href = element_attr(pl, "href");
            if pl_href != () && pl_href.contains(`/page/${next_page}`) {
                has_more = true;
                break;
            }
        }
    }
    if !has_more && series.len() >= 10 {
        has_more = true;
    }

    if page >= 100 {
        has_more = false;
    }

    #{ series: series, has_more: has_more }
}

// === Helper Functions ===

/// Extract manga slug from URL
/// URL format: https://mangaowl.io/read-1/{slug}/ or similar
fn extract_slug(url) {
    // Handle various URL patterns
    let parts = url.split("/");

    // Find the slug after read-1 or manga
    let found_marker = false;
    for i in 0..parts.len() {
        let part = parts[i];
        if part == "read-1" || part == "manga" {
            found_marker = true;
            continue;
        }
        if found_marker && part != "" && !part.starts_with("chapter") {
            // Remove trailing query params
            let clean = part.split("?")[0];
            if clean != "" {
                return clean;
            }
        }
    }

    // Fallback: get the last non-empty part
    let last_non_empty = "";
    for part in parts {
        if part != "" && !part.contains("?") && !part.starts_with("chapter") {
            last_non_empty = part;
        }
    }

    last_non_empty
}

/// Extract chapter number from URL or text
fn extract_chapter_number(url) {
    // URL format: .../chapter-{number}/ or chapter{number}
    let parts = url.split("/");

    for part in parts {
        if part.starts_with("chapter-") {
            let num = part.replace("chapter-", "");
            let clean = num.split("?")[0];
            return clean;
        }
        if part.starts_with("chapter") && part.len() > 7 {
            let num = part.sub_string(7);
            let clean = num.split("?")[0];
            if clean != "" {
                return clean;
            }
        }
    }

    // Try to find any number pattern in the URL. regex_find returns the full
    // match (e.g. "chapter-5"), not the capture group, so we do a second pass
    // to pull out just the digits. Previous version returned "chapter-5" as
    // the number, breaking numeric chapter ordering for any URL that hit this
    // fallback path.
    let full_match = regex_find("chapter[-_]?\\d+(\\.\\d+)?", url);
    if full_match != "" {
        let digits = regex_find("\\d+(\\.\\d+)?", full_match);
        if digits != "" {
            return digits;
        }
    }

    // Last resort
    "0"
}
