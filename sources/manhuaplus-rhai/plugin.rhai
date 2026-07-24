// ManhuaPlus Scraper Add-on (Rhai)
// WordPress Madara theme scraper for manhuaplus.com (Cloudflare protected)
//
// ManhuaPlus is a Chinese manhua reader site built on the WordPress Madara theme.
// The site is behind Cloudflare, so we use http_get_with_headers() with Chrome TLS
// impersonation and fall back to http_get_plain() if that fails.
//
// URL Patterns:
//   Search: /?s={query}&post_type=wp-manga
//   Browse: /manga/?m_orderby=latest&page={page}
//   Series: /manga/{slug}/
//   Chapter: /manga/{slug}/{chapter-slug}/
//   Chapter list AJAX: POST /wp-admin/admin-ajax.php (action=manga_get_chapters&manga={post_id})
//
// Available Rhai APIs:
//   HTTP: http_get_with_headers(url, headers), http_get_plain(url, headers),
//         http_post_form(url, body)
//   HTML: html_parse(html), html_select(html, selector), element_text(el),
//         element_attr(el, attr)
//   Regex: regex_match(pattern, text), regex_find(pattern, text),
//          regex_find_all(pattern, text)
//   url_encode(text) -> string

const BASE_URL = "https://manhuaplus.com";

// ============================================================================
// Helper Functions
// ============================================================================

/// Get standard browser headers for requests
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Check if HTML looks like a Cloudflare challenge page
fn is_cloudflare_page(html) {
    if html.len() < 500 {
        return true;
    }
    if html.contains("Just a moment") && html.contains("_cf_chl_opt") {
        return true;
    }
    if html.contains("challenge-platform") && html.contains("Enable JavaScript") {
        return true;
    }
    if html.contains("Attention Required") && html.contains("Cloudflare") {
        return true;
    }
    false
}

/// Fetch HTML with Cloudflare bypass:
/// 1. Try http_get_with_headers (rquest with Chrome131 TLS impersonation)
/// 2. Fall back to http_get_plain (standard reqwest, no impersonation)
fn fetch_html(url) {
    // Tier 1: rquest with Chrome TLS impersonation (best for Cloudflare)
    try {
        let html = http_get_with_headers(url, get_headers());
        if html.len() > 500 && !is_cloudflare_page(html) {
            return html;
        }
    } catch {
        // Fall through to next tier
    }

    // Tier 2: plain reqwest (no TLS impersonation)
    try {
        let html = http_get_plain(url, get_headers());
        if html.len() > 500 && !is_cloudflare_page(html) {
            return html;
        }
    } catch {
        // Fall through
    }

    // Tier 3: FlareSolverr if available
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 30000);
            if html.len() > 500 && !is_cloudflare_page(html) {
                return html;
            }
        } catch {
            // Fall through
        }
    }

    ""
}

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "manhuaplus",
        name: "ManhuaPlus",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only",
        nsfw: false,
        content_types: ["manhua", "manga"]
    }
}

/// Extract manga slug from a URL
/// URL patterns: /manga/{slug}/, or full URL
fn extract_slug(url) {
    // Primary: /manga/{slug}/
    if url.contains("/manga/") {
        let parts = url.split("/manga/");
        if parts.len() > 1 {
            let slug = parts[1].split("/")[0].split("?")[0];
            if slug != "" && slug != "?m_orderby" {
                return slug;
            }
        }
    }

    // Last resort: get the meaningful path segment
    let parts = url.split("/");
    let last_non_empty = "";
    for part in parts {
        if part != "" && !part.contains("?") && !part.contains(".") && part != "http:" && part != "https:" && part != "manhuaplus.com" {
            last_non_empty = part;
        }
    }
    last_non_empty
}

/// Extract chapter number from URL or text
fn extract_chapter_number(text) {
    // Try "chapter-{number}" pattern in URL
    let text_lower = text.to_lower();

    if text_lower.contains("chapter-") {
        let parts = text_lower.split("chapter-");
        if parts.len() > 1 {
            let num_part = parts[parts.len() - 1];
            num_part = num_part.split("/")[0].split("?")[0].split("-")[0];
            let num = extract_number(num_part);
            if num != "" {
                return num;
            }
        }
    }

    // Try "Chapter {number}" pattern in text
    if text_lower.contains("chapter ") {
        let parts = text_lower.split("chapter ");
        if parts.len() > 1 {
            let after = parts[parts.len() - 1].trim();
            let num = extract_number(after);
            if num != "" {
                return num;
            }
        }
    }

    // Try "ch-{number}" pattern
    if text_lower.contains("ch-") {
        let parts = text_lower.split("ch-");
        if parts.len() > 1 {
            let num_part = parts[parts.len() - 1].split("/")[0].split("?")[0];
            let num = extract_number(num_part);
            if num != "" {
                return num;
            }
        }
    }

    // Fallback: find any number
    let num = extract_number(text);
    if num != "" {
        return num;
    }

    "0"
}

/// Extract a numeric value (including decimals) from the beginning of a string
fn extract_number(s) {
    let num = "";
    let found_digit = false;

    for c in s.chars() {
        if c >= '0' && c <= '9' {
            num += c;
            found_digit = true;
        } else if c == '.' && found_digit {
            num += c;
        } else if found_digit {
            break;
        }
    }

    num
}

/// Make a URL absolute if it is relative
fn make_absolute_url(url) {
    if url == () || url == "" {
        return ();
    }
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

/// Get the best image URL from an img element, handling lazy loading
fn get_image_url(img) {
    // Madara theme uses multiple lazy-loading patterns
    // Priority: data-src > data-lazy-src > data-lazy > src
    let url = element_attr(img, "data-src");

    if url == () || url == "" || url.contains("blank.gif") || url.contains("dflazy") || url.starts_with("data:") {
        url = element_attr(img, "data-lazy-src");
    }
    if url == () || url == "" || url.contains("blank.gif") || url.contains("dflazy") || url.starts_with("data:") {
        url = element_attr(img, "data-lazy");
    }
    if url == () || url == "" || url.contains("blank.gif") || url.contains("dflazy") || url.starts_with("data:") {
        url = element_attr(img, "src");
    }

    // Skip placeholder/invalid images
    if url != () && url != "" {
        if url.contains("blank.gif") || url.contains("dflazy") || url.starts_with("data:") || url.contains("loading") {
            return ();
        }
    }

    url
}

/// Check if a URL looks like a valid page image (not a logo, icon, etc.)
fn is_valid_page_image(url) {
    if url == () || url == "" {
        return false;
    }

    let url_lower = url.to_lower();

    // Skip non-page images
    if url_lower.contains("logo") { return false; }
    if url_lower.contains("icon") { return false; }
    if url_lower.contains("avatar") { return false; }
    if url_lower.contains("banner") { return false; }
    if url_lower.contains("advertisement") { return false; }
    if url_lower.contains("ads/") { return false; }
    if url_lower.contains("blank.gif") { return false; }
    if url_lower.contains("placeholder") { return false; }
    if url_lower.contains("loading") { return false; }
    if url_lower.contains("spinner") { return false; }
    if url_lower.contains("gravatar") { return false; }
    if url_lower.contains("emoji") { return false; }
    if url_lower.starts_with("data:") { return false; }

    // Must look like an image or be from content path
    if url_lower.contains(".jpg") || url_lower.contains(".jpeg") ||
       url_lower.contains(".png") || url_lower.contains(".webp") ||
       url_lower.contains(".gif") || url_lower.contains("wp-content/uploads") {
        return true;
    }

    // CDN or image hosting patterns
    if url_lower.contains("cdn") || url_lower.contains("img") ||
       url_lower.contains("image") || url_lower.contains("chapter") {
        return true;
    }

    false
}

/// Strip HTML tags from text
fn strip_html(text) {
    if text == () || text == "" {
        return "";
    }
    // Remove HTML tags using simple regex
    let cleaned = text;
    // Remove <br> tags and replace with newlines
    cleaned = cleaned.replace("<br>", "\n");
    cleaned = cleaned.replace("<br/>", "\n");
    cleaned = cleaned.replace("<br />", "\n");
    // Remove all other HTML tags via regex
    let result = regex_find_all("<[^>]+>", cleaned);
    for tag in result {
        cleaned = cleaned.replace(tag, "");
    }
    // Clean up whitespace
    cleaned = cleaned.trim();
    cleaned
}

// ============================================================================
// Required Interface Functions
// ============================================================================

/// Search for series matching a query
fn search_series(query, page, auth) {
    let encoded_query = url_encode(query);
    // Madara theme search: /?s=QUERY&post_type=wp-manga&paged=PAGE
    let url = `${BASE_URL}/?s=${encoded_query}&post_type=wp-manga&paged=${page}`;

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false, total: () };
    }

    let series = [];
    let seen = #{};

    // ManhuaPlus search results use .page-listing-item containers
    // Each contains .page-item-detail (metadata) and .item-summary
    // Fallback to standard Madara selectors for compatibility
    let items = html_select(html, "div.page-listing-item .page-item-detail");

    if items.len() == 0 {
        items = html_select(html, "div.c-tabs-item__content");
    }
    if items.len() == 0 {
        items = html_select(html, "div.page-item-detail");
    }
    if items.len() == 0 {
        items = html_select(html, "div.row.c-tabs-item");
    }

    for item in items {
        // Get title and URL from the title link
        let title_links = html_select(item, ".post-title a");
        if title_links.len() == 0 {
            title_links = html_select(item, "h3 a");
        }
        if title_links.len() == 0 {
            title_links = html_select(item, "h4 a");
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
        if slug == "" {
            continue;
        }

        // Skip duplicates
        if seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        // Get title
        let title = element_text(link).trim();
        if title == "" {
            let title_attr = element_attr(link, "title");
            if title_attr != () {
                title = title_attr.trim();
            }
        }
        if title == "" {
            continue;
        }

        // Get cover image
        let cover_url = ();
        let imgs = html_select(item, ".tab-thumb img, .item-thumb img, img.img-responsive");
        if imgs.len() == 0 {
            imgs = html_select(item, "img");
        }
        if imgs.len() > 0 {
            cover_url = get_image_url(imgs[0]);
        }
        cover_url = make_absolute_url(cover_url);

        // Get genres if visible in search results
        let genres = [];
        let genre_els = html_select(item, ".mg_genres .summary-content a, .genres-content a");
        for el in genre_els {
            let genre = element_text(el).trim();
            if genre != "" && !genres.contains(genre) {
                genres.push(genre);
            }
        }

        // Get latest chapter info if available
        let latest_chapter = ();
        let ch_els = html_select(item, ".chapter a, .latest-chap .chapter a");
        if ch_els.len() > 0 {
            latest_chapter = element_text(ch_els[0]).trim();
        }

        series.push(#{
            id: slug,
            title: title,
            url: make_absolute_url(href),
            cover_url: cover_url,
            alternate_titles: [],
            authors: [],
            artists: [],
            status: (),
            genres: genres,
            tags: [],
            description: (),
            extra: #{
                latest_chapter: latest_chapter
            }
        });
    }

    // Check for next page using Madara pagination
    let has_more = false;
    let next_links = html_select(html, "a.next, a.nextpostslink, .nav-next a, .wp-pagenavi a.next, .nextprev a, .pagination a.next");
    if next_links.len() > 0 {
        has_more = true;
    }
    // Also check for page number links
    if !has_more {
        let next_page = page + 1;
        let page_links = html_select(html, ".wp-pagenavi a, .pagination a, nav.navigation a");
        for pl in page_links {
            let pl_href = element_attr(pl, "href");
            if pl_href != () && (pl_href.contains(`paged=${next_page}`) || pl_href.contains(`/page/${next_page}`)) {
                has_more = true;
                break;
            }
        }
    }

    #{ series: series, has_more: has_more, total: () }
}

/// Browse manga by category/order
fn browse(page, category, auth) {
    if category == "latest" || category == "new" || category == () || category == "" {
        return get_latest_updates(page, auth);
    }

    // Madara theme browse with ordering
    let order = "latest";
    if category == "popular" || category == "views" {
        order = "views";
    } else if category == "trending" {
        order = "trending";
    } else if category == "rating" {
        order = "rating";
    } else if category == "new-manga" {
        order = "new-manga";
    } else if category == "az" || category == "alphabetical" {
        order = "alphabet";
    }

    let url = `${BASE_URL}/manga/?m_orderby=${order}&page=${page}`;

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let seen = #{};

    // Madara browse page uses .page-item-detail for each manga card
    let items = html_select(html, ".page-item-detail");
    if items.len() == 0 {
        items = html_select(html, "div.manga");
    }

    for item in items {
        let title_links = html_select(item, ".post-title a");
        if title_links.len() == 0 {
            title_links = html_select(item, "h3 a");
        }
        if title_links.len() == 0 {
            title_links = html_select(item, "h5 a");
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
        if slug == "" {
            continue;
        }

        if seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        let title = element_text(link).trim();
        if title == "" {
            let title_attr = element_attr(link, "title");
            if title_attr != () { title = title_attr.trim(); }
        }
        if title == "" {
            continue;
        }

        let cover_url = ();
        let imgs = html_select(item, ".item-thumb img, img");
        if imgs.len() > 0 {
            cover_url = get_image_url(imgs[0]);
        }
        cover_url = make_absolute_url(cover_url);

        series.push(#{
            id: slug,
            title: title,
            url: make_absolute_url(href),
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

    // Check for more pages
    let has_more = false;
    let next_links = html_select(html, "a.next, a.nextpostslink, .nav-next a, .nextprev a, .pagination a.next, .wp-pagenavi a.nextpostslink");
    if next_links.len() > 0 {
        has_more = true;
    }
    if !has_more && series.len() >= 15 {
        // Madara typically shows 12-20 items per page; assume more if we got a full page
        has_more = true;
    }
    if page >= 100 {
        has_more = false;
    }

    #{ series: series, has_more: has_more }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let url = id_or_url;
    let slug = id_or_url;

    if !id_or_url.starts_with("http") {
        url = `${BASE_URL}/manga/${id_or_url}/`;
    } else {
        slug = extract_slug(id_or_url);
    }

    let html = fetch_html(url);

    if html == "" {
        throw `Failed to fetch series: ${id_or_url}`;
    }

    // Extract title - Madara theme uses .post-title h1
    let title = "";
    let title_els = html_select(html, ".post-title h1");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }
    if title == "" {
        let title_els2 = html_select(html, "h1");
        if title_els2.len() > 0 {
            title = element_text(title_els2[0]).trim();
        }
    }
    // Regex fallback from <title> tag
    if title == "" {
        let title_match = regex_find("<title>([^<]+)</title>", html);
        if title_match != "" {
            title = title_match.replace("<title>", "").replace("</title>", "").trim();
            // Remove site name suffix
            if title.contains(" - ManhuaPlus") {
                title = title.split(" - ManhuaPlus")[0].trim();
            }
            if title.contains(" | ManhuaPlus") {
                title = title.split(" | ManhuaPlus")[0].trim();
            }
        }
    }

    // Extract cover image - Madara uses .summary_image img
    let cover_url = ();
    let cover_els = html_select(html, ".summary_image img");
    if cover_els.len() == 0 {
        cover_els = html_select(html, ".tab-summary img");
    }
    if cover_els.len() == 0 {
        cover_els = html_select(html, ".manga-page img");
    }
    if cover_els.len() > 0 {
        cover_url = get_image_url(cover_els[0]);
    }
    cover_url = make_absolute_url(cover_url);

    // Extract description - Madara uses .summary__content or .description-summary
    let description = ();
    let desc_els = html_select(html, ".summary__content p, .description-summary p, .manga-excerpt p");
    if desc_els.len() > 0 {
        let desc_parts = [];
        for p in desc_els {
            let text = element_text(p).trim();
            if text != "" && text.len() > 5 {
                // Skip "Show more" or navigation text
                if !text.to_lower().starts_with("show more") && !text.to_lower().starts_with("show less") {
                    desc_parts.push(text);
                }
            }
        }
        if desc_parts.len() > 0 {
            description = "";
            let first = true;
            for part in desc_parts {
                if !first {
                    description += "\n\n";
                }
                description += part;
                first = false;
            }
        }
    }
    // Fallback: try the container directly
    if description == () || description == "" {
        let desc_container = html_select(html, ".summary__content, .description-summary");
        if desc_container.len() > 0 {
            let raw = element_text(desc_container[0]).trim();
            if raw != "" && raw.len() > 10 {
                description = raw;
            }
        }
    }

    // Extract authors - Madara uses .author-content a
    let authors = [];
    let author_els = html_select(html, ".author-content a");
    for el in author_els {
        let author = element_text(el).trim();
        if author != "" && author != "Updating" && author != "-" && !authors.contains(author) {
            authors.push(author);
        }
    }

    // Extract artists - Madara uses .artist-content a
    let artists = [];
    let artist_els = html_select(html, ".artist-content a");
    for el in artist_els {
        let artist = element_text(el).trim();
        if artist != "" && artist != "Updating" && artist != "-" && !artists.contains(artist) {
            artists.push(artist);
        }
    }

    // Extract genres - Madara uses .genres-content a
    let genres = [];
    let genre_els = html_select(html, ".genres-content a");
    for el in genre_els {
        let genre = element_text(el).trim().replace(",", "");
        if genre != "" && genre.len() < 50 && !genres.contains(genre) {
            genres.push(genre);
        }
    }

    // Extract status - Madara uses .post-status with .summary-content
    let status = ();
    let status_els = html_select(html, ".post-status .post-content_item");
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
    // Fallback: check .summary-content divs
    if status == () {
        let summary_els = html_select(html, ".summary-content");
        for el in summary_els {
            let text = element_text(el).to_lower().trim();
            if text == "ongoing" || text == "publishing" {
                status = "Ongoing";
                break;
            } else if text == "completed" || text == "finished" {
                status = "Completed";
                break;
            } else if text == "hiatus" {
                status = "Hiatus";
                break;
            } else if text == "cancelled" || text == "canceled" {
                status = "Cancelled";
                break;
            }
        }
    }

    // Extract alternative titles
    let alternate_titles = [];
    // Madara theme: .post-content_item with "Alternative" heading
    let content_items = html_select(html, ".post-content_item");
    for item in content_items {
        let heading_els = html_select(item, ".summary-heading h5, .summary-heading h7, h5");
        let content_els = html_select(item, ".summary-content");
        if heading_els.len() > 0 && content_els.len() > 0 {
            let heading = element_text(heading_els[0]).to_lower().trim();
            if heading.contains("alternative") || heading.contains("alt name") || heading.contains("other name") {
                let alt_text = element_text(content_els[0]).trim();
                if alt_text != "" && alt_text != "-" && alt_text != "N/A" {
                    let parts = alt_text.split(",");
                    if parts.len() == 1 {
                        parts = alt_text.split(";");
                    }
                    for p in parts {
                        let cleaned = p.trim();
                        if cleaned != "" && cleaned != title && !alternate_titles.contains(cleaned) {
                            alternate_titles.push(cleaned);
                        }
                    }
                }
            }
        }
    }

    // Extract year/release date
    let year = ();
    for item in content_items {
        let heading_els2 = html_select(item, ".summary-heading h5, h5");
        let content_els2 = html_select(item, ".summary-content");
        if heading_els2.len() > 0 && content_els2.len() > 0 {
            let heading = element_text(heading_els2[0]).to_lower().trim();
            if heading.contains("release") || heading.contains("year") {
                let year_text = element_text(content_els2[0]).trim();
                let year_match = regex_find("(19|20)\\d{2}", year_text);
                if year_match != "" {
                    year = year_match;
                }
            }
        }
    }

    #{
        id: slug,
        title: title,
        alternate_titles: alternate_titles,
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
            source_name: "ManhuaPlus"
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let url = series_id;
    let slug = series_id;

    if !series_id.starts_with("http") {
        url = `${BASE_URL}/manga/${series_id}/`;
    } else {
        slug = extract_slug(series_id);
    }

    let html = fetch_html(url);

    if html == "" {
        return [];
    }

    let chapters = [];
    let seen = #{};

    // Method 1: Try to get chapters via AJAX (Madara's manga_get_chapters action)
    // First, extract the post ID from the page for the AJAX call
    let post_id = "";
    // Madara embeds the manga ID in data-id attribute or in a hidden input
    let id_match = regex_find("data-id=\"(\\d+)\"", html);
    if id_match != "" {
        post_id = regex_find("\\d+", id_match);
    }
    if post_id == "" {
        // Try wp_manga_chapter_preload or similar
        let id_match2 = regex_find("manga_id\\s*[:=]\\s*[\"']?(\\d+)", html);
        if id_match2 != "" {
            post_id = regex_find("\\d+", id_match2);
        }
    }
    if post_id == "" {
        // Try class="wp-manga-action-button" data-post="12345"
        let id_match3 = regex_find("data-post=\"(\\d+)\"", html);
        if id_match3 != "" {
            post_id = regex_find("\\d+", id_match3);
        }
    }

    // If we have a post ID, try AJAX endpoint for full chapter list
    if post_id != "" {
        try {
            let ajax_url = `${BASE_URL}/wp-admin/admin-ajax.php`;
            let ajax_body = `action=manga_get_chapters&manga=${post_id}`;
            let ajax_html = http_post_form(ajax_url, ajax_body);

            if ajax_html != () && ajax_html != "" && ajax_html.len() > 50 {
                // Parse AJAX response which returns chapter list HTML
                let ajax_chapters = parse_chapter_list(ajax_html, series_id, seen);
                if ajax_chapters.len() > 0 {
                    return ajax_chapters;
                }
            }
        } catch {
            // AJAX failed, fall through to HTML parsing
        }
    }

    // Method 2: Parse chapters directly from the series page HTML
    chapters = parse_chapter_list(html, series_id, seen);

    chapters
}

/// Parse chapter list from HTML (used for both AJAX response and direct page parsing)
fn parse_chapter_list(html, series_id, seen) {
    let chapters = [];

    // Madara theme chapter list: li.wp-manga-chapter
    let chapter_items = html_select(html, "li.wp-manga-chapter");

    // Fallback selectors
    if chapter_items.len() == 0 {
        chapter_items = html_select(html, ".listing-chapters_wrap li");
    }
    if chapter_items.len() == 0 {
        chapter_items = html_select(html, "ul.main li");
    }
    if chapter_items.len() == 0 {
        chapter_items = html_select(html, ".version-chap li");
    }

    for item in chapter_items {
        // Find the chapter link
        let links = html_select(item, "a");
        if links.len() == 0 {
            continue;
        }

        let link = links[0];
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Extract chapter number from URL or text
        let chapter_text = element_text(link).trim();
        let chapter_num = extract_chapter_number(href);

        // If we couldn't get number from URL, try the text
        if chapter_num == "0" || chapter_num == "" {
            chapter_num = extract_chapter_number(chapter_text);
        }

        // Skip duplicates
        if seen.contains(chapter_num) {
            continue;
        }
        seen[chapter_num] = true;

        // Extract chapter title (text after the number, if any)
        let chapter_title = ();
        if chapter_text.contains("-") {
            let parts = chapter_text.split("-");
            if parts.len() > 1 {
                let title_part = "";
                for i in 1..parts.len() {
                    if title_part != "" { title_part += "-"; }
                    title_part += parts[i];
                }
                title_part = title_part.trim();
                if title_part != "" && title_part.len() > 1 {
                    chapter_title = title_part;
                }
            }
        }
        if chapter_title == () && chapter_text.contains(":") {
            let parts = chapter_text.split(":");
            if parts.len() > 1 {
                let title_part = "";
                for i in 1..parts.len() {
                    if title_part != "" { title_part += ":"; }
                    title_part += parts[i];
                }
                title_part = title_part.trim();
                if title_part != "" && title_part.len() > 1 {
                    chapter_title = title_part;
                }
            }
        }

        // Build full URL
        let chapter_url = href;
        if !href.starts_with("http") {
            chapter_url = make_absolute_url(href);
        }

        // Get release date if available
        let published_at = ();
        let date_els = html_select(item, ".chapter-release-date, .chapter-release-date i, span.chapter-time");
        if date_els.len() > 0 {
            let date_text = element_text(date_els[0]).trim();
            if date_text != "" {
                published_at = date_text;
            }
        }

        chapters.push(#{
            id: chapter_url,
            series_id: series_id,
            number: chapter_num,
            title: chapter_title,
            volume: (),
            language: "en",
            scanlator: "ManhuaPlus",
            url: chapter_url,
            published_at: published_at,
            page_count: (),
            extra: #{}
        });
    }

    // Madara lists chapters newest-first, so reverse to get ascending order
    chapters.reverse();

    chapters
}

/// Get page image URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;

    if !chapter_id.starts_with("http") {
        url = make_absolute_url(chapter_id);
    }

    let html = fetch_html(url);

    if html == "" {
        return [];
    }

    let pages = [];
    let idx = 0;
    let seen_urls = #{};

    // Madara theme reader: div.page-break img or div.reading-content img
    // These are the standard selectors in order of specificity
    let selectors = [
        "div.page-break img",
        ".reading-content .page-break img",
        ".reading-content img",
        ".read-container img",
        "#image-list img",
        "#readerarea img",
        ".entry-content img",
        ".text-left img"
    ];

    for selector in selectors {
        let page_imgs = html_select(html, selector);

        for img in page_imgs {
            let img_url = get_image_url(img);

            if img_url != () && img_url != "" && is_valid_page_image(img_url) {
                let full_url = make_absolute_url(img_url);

                // Trim whitespace from URLs (Madara sometimes has leading/trailing spaces)
                full_url = full_url.trim();

                // Skip duplicates
                if seen_urls.contains(full_url) {
                    continue;
                }
                seen_urls[full_url] = true;

                pages.push(#{
                    index: idx,
                    url: full_url,
                    headers: #{
                        "Referer": url
                    },
                    referer: url
                });
                idx += 1;
            }
        }

        // If we found pages with this selector, stop trying others
        if pages.len() > 0 {
            break;
        }
    }

    // Fallback: regex extraction for image URLs in case HTML parsing missed them
    if pages.len() == 0 {
        // Look for image URLs in the page source (common in Madara themes)
        let img_matches = regex_find_all("\"(https?://[^\"]+(?:\\.jpg|\\.jpeg|\\.png|\\.webp)[^\"]*)\"", html);
        for img_url in img_matches {
            // Clean up the match - remove surrounding quotes
            let clean_url = img_url.replace("\"", "").trim();

            if is_valid_page_image(clean_url) {
                if seen_urls.contains(clean_url) {
                    continue;
                }
                seen_urls[clean_url] = true;

                pages.push(#{
                    index: idx,
                    url: clean_url,
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

/// Get latest manga updates
fn get_latest_updates(page, auth) {
    // Madara latest: /manga/?m_orderby=latest&page={page}
    let url = `${BASE_URL}/manga/?m_orderby=latest&page=${page}`;

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let seen = #{};

    // Madara browse uses .page-item-detail for each card
    let items = html_select(html, ".page-item-detail");
    if items.len() == 0 {
        items = html_select(html, "div.manga");
    }

    for item in items {
        let title_links = html_select(item, ".post-title a");
        if title_links.len() == 0 {
            title_links = html_select(item, "h3 a");
        }
        if title_links.len() == 0 {
            title_links = html_select(item, "h5 a");
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
        if slug == "" {
            continue;
        }

        if seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        let title = element_text(link).trim();
        if title == "" {
            let title_attr = element_attr(link, "title");
            if title_attr != () { title = title_attr.trim(); }
        }
        if title == "" {
            continue;
        }

        let cover_url = ();
        let imgs = html_select(item, ".item-thumb img, img");
        if imgs.len() > 0 {
            cover_url = get_image_url(imgs[0]);
        }
        cover_url = make_absolute_url(cover_url);

        // Get latest chapter link text for updated_at
        let updated_at = ();
        let ch_els = html_select(item, ".chapter a, .list-chapter a");
        if ch_els.len() > 0 {
            // Get the date next to the chapter
            let date_els = html_select(item, ".post-on, .chapter-time");
            if date_els.len() > 0 {
                updated_at = element_text(date_els[0]).trim();
            }
        }

        series.push(#{
            id: slug,
            title: title,
            url: make_absolute_url(href),
            cover_url: cover_url,
            updated_at: updated_at
        });
    }

    // Check for next page
    let has_more = false;
    let next_links = html_select(html, "a.next, a.nextpostslink, .nav-next a, .nextprev a, .pagination a.next, .wp-pagenavi a.nextpostslink");
    if next_links.len() > 0 {
        has_more = true;
    }
    // If we got a full page of results, assume there are more
    if !has_more && series.len() >= 15 {
        has_more = true;
    }
    if page >= 100 {
        has_more = false;
    }

    #{ series: series, has_more: has_more }
}
