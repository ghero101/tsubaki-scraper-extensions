// ReadM Scraper Add-on (Rhai)
// Scraper for readm.org - large manga library with daily updates
//
// Website: https://readm.org
// Features: Search (POST), Browse (popular/latest), Series, Chapters, Pages
// Cloudflare protected - uses rquest TLS impersonation with FlareSolverr fallback
//
// URL Patterns:
//   Search: POST /service/search (body: dataType=json&phrase={query})
//   Browse Popular: /popular-manga/{page}
//   Browse Latest: /latest-releases/{page}
//   Series: /manga/{slug}
//   Chapter: /manga/{slug}/{chapter_number}/all-pages
//
// Available Rhai APIs:
//   HTTP: http_get_with_headers(url, headers), http_get_plain(url, headers),
//         http_post_form(url, body), flaresolverr_get(url, timeout)
//   HTML: html_parse(html), html_select(html, selector), element_text(el),
//         element_attr(el, attr), element_select(el, selector)
//   JSON: json_parse(json)
//   Regex: regex_match(pattern, text), regex_find(pattern, text),
//          regex_find_all(pattern, text)
//   Utility: url_encode(text), parse_int(str), parse_float(str)

// readm.org returns 522 (origin unreachable). readm.today is a redirect/tracking
// wrapper that requires JS execution. We try readm.org first (in case it comes back),
// then fall back to readm.today via FlareSolverr which can execute the JS redirect.
const BASE_URL = "https://readm.org";
const ALT_URL = "https://readm.today";

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

/// Check if HTML is a redirect/tracking page (readm.today wraps content in JS redirects)
fn is_redirect_page(html) {
    if html.contains("FingerprintJS") && html.contains("redirect_link") {
        return true;
    }
    if html.contains("Click here to enter") && html.contains("redirect") {
        return true;
    }
    false
}

/// Fetch HTML with multi-tier approach:
/// 1. Try readm.org with rquest (Chrome TLS impersonation)
/// 2. Try readm.org with plain reqwest
/// 3. Try readm.today via FlareSolverr (handles JS redirect)
/// 4. Try readm.org via FlareSolverr
fn fetch_html(url) {
    // Tier 1: rquest with Chrome TLS impersonation on primary domain
    try {
        let html = http_get_with_headers(url, get_headers());
        if html.len() > 500 && !is_cloudflare_page(html) && !is_redirect_page(html) {
            return html;
        }
    } catch {
        // Fall through - readm.org may return 522
    }

    // Tier 2: plain reqwest on primary domain
    try {
        let html = http_get_plain(url, get_headers());
        if html.len() > 500 && !is_cloudflare_page(html) && !is_redirect_page(html) {
            return html;
        }
    } catch {
        // Fall through
    }

    // Tier 3: Try alternate domain (readm.today) via FlareSolverr
    // FlareSolverr can execute JS redirects that readm.today uses
    if flaresolverr_is_available() {
        // Try alt URL first (readm.today) - FlareSolverr handles the JS redirect
        let alt_url = url.replace(BASE_URL, ALT_URL);
        try {
            let html = flaresolverr_get(alt_url, 45000);
            if html.len() > 500 && !is_cloudflare_page(html) && !is_redirect_page(html) {
                return html;
            }
        } catch {
            // Fall through
        }

        // Try original URL via FlareSolverr
        try {
            let html = flaresolverr_get(url, 30000);
            if html.len() > 500 && !is_cloudflare_page(html) && !is_redirect_page(html) {
                return html;
            }
        } catch {
            // Fall through
        }
    }

    // Tier 4: Try alt domain with HTTP directly (may work if redirect is simple)
    let alt_url = url.replace(BASE_URL, ALT_URL);
    try {
        let html = http_get_with_headers(alt_url, get_headers());
        if html.len() > 500 && !is_cloudflare_page(html) && !is_redirect_page(html) {
            return html;
        }
    } catch {
        // Fall through
    }

    ""
}

/// Make a URL absolute if it's relative
fn make_absolute(url) {
    if url == () || url == "" {
        return "";
    }
    if url.starts_with("http") {
        return url;
    }
    if url.starts_with("//") {
        return "https:" + url;
    }
    if url.starts_with("/") {
        return BASE_URL + url;
    }
    BASE_URL + "/" + url
}

/// Extract the slug from a ReadM manga URL
/// e.g. /manga/one-piece -> one-piece
///      https://readm.org/manga/one-piece -> one-piece
fn extract_slug(id_or_url) {
    let slug = id_or_url;

    if slug.contains("/manga/") {
        let parts = slug.split("/manga/");
        if parts.len() > 1 {
            slug = parts[1];
        }
    }

    // Remove trailing slashes and query strings
    if slug.contains("?") {
        slug = slug.split("?")[0];
    }
    if slug.contains("#") {
        slug = slug.split("#")[0];
    }
    while slug.ends_with("/") {
        slug = slug.sub_string(0, slug.len() - 1);
    }

    // If slug contains further path segments (e.g. chapter number), take only the first
    if slug.contains("/") {
        slug = slug.split("/")[0];
    }

    slug
}

/// Get the cover image URL from an img element, trying data-src first then src
fn get_image_url(img_el) {
    let url = element_attr(img_el, "data-src");
    if url == () || url == "" {
        url = element_attr(img_el, "src");
    }
    if url != () && url != "" {
        url = make_absolute(url);
    }
    url
}

// ============================================================================
// Addon Interface Functions
// ============================================================================

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "readm",
        name: "ReadM",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only",
        nsfw: false,
        content_types: ["manga"]
    }
}

/// Search for series matching a query
/// ReadM uses POST /service/search with form-encoded body
fn search_series(query, page, auth) {
    // ReadM search has no pagination — all results returned at once
    // Return empty on page > 1
    if page > 1 {
        return #{ series: [], has_more: false, total: () };
    }

    let search_url = `${BASE_URL}/service/search`;
    let body = `dataType=json&phrase=${url_encode(query)}`;

    let response_text = "";

    // http_post_form uses rquest with Chrome TLS impersonation — good for CF
    try {
        response_text = http_post_form(search_url, body);
    } catch {
        // POST failed — no good fallback for POST search
    }

    if response_text == "" || response_text.len() < 10 {
        return #{ series: [], has_more: false, total: () };
    }

    // Parse JSON response — expected format: { "manga": [{title, url, image}, ...] }
    let data = ();
    try {
        data = json_parse(response_text);
    } catch {
        return #{ series: [], has_more: false, total: () };
    }

    let series = [];

    if data.manga == () {
        return #{ series: [], has_more: false, total: () };
    }

    for item in data.manga {
        let title = "";
        if item.title != () {
            title = item.title;
        }
        if title == "" {
            continue;
        }

        // URL is relative like /manga/one-piece
        let item_url = "";
        if item.url != () {
            item_url = item.url;
        }
        let slug = extract_slug(item_url);
        if slug == "" {
            continue;
        }

        let cover_url = "";
        if item.image != () {
            cover_url = make_absolute(item.image);
        }

        series.push(#{
            id: slug,
            title: title,
            alternate_titles: [],
            description: (),
            cover_url: cover_url,
            authors: [],
            artists: [],
            status: (),
            genres: [],
            tags: [],
            year: (),
            content_rating: "suggestive",
            url: make_absolute(item_url),
            extra: #{
                source_name: "ReadM",
                auto_match_metadata: true
            }
        });
    }

    #{ series: series, has_more: false, total: () }
}

/// Browse popular or latest series
fn browse(page, category, auth) {
    if category == "latest" || category == "new" || category == "updates" {
        return get_latest_updates(page, auth);
    }

    // Default: popular manga
    let url = `${BASE_URL}/popular-manga/${page}`;
    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let doc = html_parse(html);
    let series = [];
    let seen = #{};

    // Popular page: div#discover-response contains li elements
    let items = html_select(doc, "div#discover-response li");

    // Fallback: try broader selector
    if items.len() == 0 {
        items = html_select(doc, "ul.filter-results li");
    }

    for item in items {
        // Get title and link from div.subject-title a
        let title_links = element_select(item, "div.subject-title a");
        if title_links.len() == 0 {
            // Fallback: any link with /manga/ in href
            title_links = element_select(item, "a[href*='/manga/']");
        }
        if title_links.len() == 0 {
            continue;
        }

        let link = title_links[0];
        let href = element_attr(link, "href");
        let title = element_text(link).trim();

        if href == () || href == "" || title == "" {
            continue;
        }

        let slug = extract_slug(href);
        if slug == "" || seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        // Get cover image
        let cover_url = "";
        let imgs = element_select(item, "img");
        if imgs.len() > 0 {
            cover_url = get_image_url(imgs[0]);
        }

        series.push(#{
            id: slug,
            title: title,
            alternate_titles: [],
            description: (),
            cover_url: cover_url,
            authors: [],
            artists: [],
            status: (),
            genres: [],
            tags: [],
            year: (),
            content_rating: "suggestive",
            url: make_absolute(href),
            extra: #{
                source_name: "ReadM",
                auto_match_metadata: true
            }
        });
    }

    // Check for next page: look for pagination link containing ">>"
    let has_more = false;
    let pagination_links = html_select(doc, "div.pagination a");
    for plink in pagination_links {
        let ptext = element_text(plink).trim();
        if ptext.contains(">>") || ptext.contains("Next") {
            has_more = true;
            break;
        }
    }

    #{ series: series, has_more: has_more }
}

/// Get latest updates
fn get_latest_updates(page, auth) {
    let url = `${BASE_URL}/latest-releases/${page}`;
    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let doc = html_parse(html);
    let series = [];
    let seen = #{};

    // Latest updates: ul.latest-updates > li
    let items = html_select(doc, "ul.latest-updates li");

    // Fallback: broader selector
    if items.len() == 0 {
        items = html_select(doc, "div.latest-updates li");
    }

    for item in items {
        // Title and link from h2 a
        let title_links = element_select(item, "h2 a");
        if title_links.len() == 0 {
            title_links = element_select(item, "a[href*='/manga/']");
        }
        if title_links.len() == 0 {
            continue;
        }

        let link = title_links[0];
        let href = element_attr(link, "href");
        let title = element_text(link).trim();

        if href == () || href == "" || title == "" {
            continue;
        }

        let slug = extract_slug(href);
        if slug == "" || seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        // Get cover image
        let cover_url = "";
        let imgs = element_select(item, "img");
        if imgs.len() > 0 {
            cover_url = get_image_url(imgs[0]);
        }

        series.push(#{
            id: slug,
            title: title,
            alternate_titles: [],
            description: (),
            cover_url: cover_url,
            authors: [],
            artists: [],
            status: (),
            genres: [],
            tags: [],
            year: (),
            content_rating: "suggestive",
            url: make_absolute(href),
            extra: #{
                source_name: "ReadM",
                auto_match_metadata: true
            }
        });
    }

    // Check for next page
    let has_more = false;
    let pagination_links = html_select(doc, "div.pagination a");
    for plink in pagination_links {
        let ptext = element_text(plink).trim();
        if ptext.contains(">>") || ptext.contains("Next") {
            has_more = true;
            break;
        }
    }

    // Fallback: if we got a good number of results, assume more exist
    if !has_more && series.len() >= 20 {
        has_more = true;
    }

    #{ series: series, has_more: has_more }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let slug = extract_slug(id_or_url);
    let url = `${BASE_URL}/manga/${slug}`;

    if id_or_url.starts_with("http") {
        url = id_or_url;
        // Re-extract slug from the full URL
        slug = extract_slug(url);
    }

    let html = fetch_html(url);

    if html == "" {
        throw `Failed to fetch series page: ${url}`;
    }

    let doc = html_parse(html);

    // --- Title ---
    let title = "";
    let title_els = html_select(doc, "h1.page-title");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }
    // Fallback: regex
    if title == "" {
        let title_match = regex_find("<h1[^>]*class=\"[^\"]*page-title[^\"]*\"[^>]*>([^<]+)</h1>", html);
        if title_match != "" {
            title = regex_find(">([^<]+)<", title_match);
            title = title.replace(">", "").replace("<", "").trim();
        }
    }
    // Fallback: <title> tag
    if title == "" {
        let title_match = regex_find("<title>([^<]+)</title>", html);
        if title_match != "" {
            title = title_match.replace("<title>", "").replace("</title>", "").trim();
            // Remove site suffix
            if title.contains(" - ReadM") {
                title = title.split(" - ReadM")[0].trim();
            }
            if title.contains(" | ReadM") {
                title = title.split(" | ReadM")[0].trim();
            }
        }
    }
    if title == "" {
        title = slug.replace("-", " ");
    }

    // --- Cover ---
    let cover_url = "";
    let cover_els = html_select(doc, "img.series-profile-thumb");
    if cover_els.len() > 0 {
        cover_url = get_image_url(cover_els[0]);
    }
    // Fallback: any large image in the profile section
    if cover_url == "" {
        let profile_imgs = html_select(doc, "div.series-profile img");
        if profile_imgs.len() > 0 {
            cover_url = get_image_url(profile_imgs[0]);
        }
    }
    // Fallback: og:image meta
    if cover_url == "" {
        let og_match = regex_find("og:image[\"']\\s*content=[\"']([^\"']+)", html);
        if og_match != "" {
            cover_url = regex_find("content=[\"']([^\"']+)", og_match);
            cover_url = cover_url.replace("content=\"", "").replace("content='", "").replace("\"", "").replace("'", "").trim();
            cover_url = make_absolute(cover_url);
        }
    }

    // --- Author (span#first_episode a) ---
    let authors = [];
    let author_els = html_select(doc, "span#first_episode a");
    if author_els.len() > 0 {
        let author = element_text(author_els[0]).trim();
        if author != "" && author != "-" && author.to_lower() != "updating" {
            authors.push(author);
        }
    }
    // Fallback: regex
    if authors.len() == 0 {
        let author_match = regex_find("id=\"first_episode\"[^>]*>\\s*<a[^>]*>([^<]+)</a>", html);
        if author_match != "" {
            let a = regex_find(">([^<]+)</a>", author_match);
            a = a.replace(">", "").replace("</a>", "").trim();
            if a != "" && a != "-" {
                authors.push(a);
            }
        }
    }

    // --- Artist (span#last_episode a) ---
    let artists = [];
    let artist_els = html_select(doc, "span#last_episode a");
    if artist_els.len() > 0 {
        let artist = element_text(artist_els[0]).trim();
        if artist != "" && artist != "-" && artist.to_lower() != "updating" {
            artists.push(artist);
        }
    }
    // Fallback: regex
    if artists.len() == 0 {
        let artist_match = regex_find("id=\"last_episode\"[^>]*>\\s*<a[^>]*>([^<]+)</a>", html);
        if artist_match != "" {
            let a = regex_find(">([^<]+)</a>", artist_match);
            a = a.replace(">", "").replace("</a>", "").trim();
            if a != "" && a != "-" {
                artists.push(a);
            }
        }
    }

    // --- Description ---
    let description = ();
    let desc_els = html_select(doc, "div.series-summary-wrapper p");
    if desc_els.len() > 0 {
        let desc_parts = [];
        for d in desc_els {
            let text = element_text(d).trim();
            if text != "" {
                desc_parts.push(text);
            }
        }
        if desc_parts.len() > 0 {
            description = desc_parts.reduce(|a, b| a + "\n" + b);
        }
    }
    // Fallback: regex
    if description == () || description == "" {
        let desc_match = regex_find("series-summary-wrapper[^>]*>[\\s\\S]*?<p>([^<]+)</p>", html);
        if desc_match != "" {
            description = regex_find("<p>([^<]+)</p>", desc_match);
            description = description.replace("<p>", "").replace("</p>", "").trim();
        }
    }

    // --- Genres ---
    let genres = [];
    let genre_els = html_select(doc, "div.series-summary-wrapper div.item a");
    for g in genre_els {
        let genre = element_text(g).trim();
        if genre != "" && genre.len() < 40 && !genres.contains(genre) {
            genres.push(genre);
        }
    }
    // Fallback: regex for genre links
    if genres.len() == 0 {
        let genre_matches = regex_find_all("category/[^\"]+\"[^>]*>([^<]+)<", html);
        for gm in genre_matches {
            let genre = regex_find(">([^<]+)<", gm);
            genre = genre.replace(">", "").replace("<", "").trim();
            if genre != "" && genre.len() < 40 && !genres.contains(genre) {
                genres.push(genre);
            }
        }
    }

    // --- Status ---
    let status = ();
    let status_els = html_select(doc, "div.series-genres .series-status");
    if status_els.len() > 0 {
        let status_text = element_text(status_els[0]).trim().to_lower();
        if status_text.contains("ongoing") { status = "Ongoing"; }
        else if status_text.contains("completed") || status_text.contains("complete") { status = "Completed"; }
        else if status_text.contains("hiatus") { status = "Hiatus"; }
    }
    // Fallback: regex
    if status == () {
        let status_match = regex_find("series-status[^>]*>([^<]+)<", html);
        if status_match != "" {
            let s = regex_find(">([^<]+)<", status_match);
            s = s.replace(">", "").replace("<", "").trim().to_lower();
            if s.contains("ongoing") { status = "Ongoing"; }
            else if s.contains("completed") || s.contains("complete") { status = "Completed"; }
            else if s.contains("hiatus") { status = "Hiatus"; }
        }
    }

    #{
        id: slug,
        title: title,
        alternate_titles: [],
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
            source_name: "ReadM",
            auto_match_metadata: true
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let slug = extract_slug(series_id);
    let url = `${BASE_URL}/manga/${slug}`;

    if series_id.starts_with("http") {
        url = series_id;
        slug = extract_slug(url);
    }

    let html = fetch_html(url);

    if html == "" {
        return [];
    }

    let doc = html_parse(html);
    let chapters = [];
    let seen = #{};

    // Chapter rows: div.season_start elements
    let rows = html_select(doc, "div.season_start");

    // Fallback: try table rows in episode list
    if rows.len() == 0 {
        rows = html_select(doc, "div.episodes-list a");
    }

    // If we got div.season_start rows, extract links from within each
    for row in rows {
        let links = element_select(row, "a");

        // If the row itself is an <a> element (from fallback), treat it as the link
        if links.len() == 0 {
            let href = element_attr(row, "href");
            if href != () && href != "" && href.contains("/manga/") {
                links = [row];
            }
        }

        for link in links {
            let href = element_attr(link, "href");
            if href == () || href == "" {
                continue;
            }

            // Only process links that look like chapter URLs
            // Format: /manga/{slug}/{chapter_number} or /manga/{slug}/{chapter_number}/all-pages
            if !href.contains("/manga/") {
                continue;
            }

            // Extract chapter number from URL
            // URL pattern: /manga/slug/number or /manga/slug/number/all-pages
            let chapter_num = "";
            let path = href;
            if path.starts_with("http") {
                let parts = path.split("readm.org");
                if parts.len() > 1 {
                    path = parts[1];
                }
            }

            // Remove trailing /all-pages
            path = path.replace("/all-pages", "");
            // Remove trailing slash
            while path.ends_with("/") {
                path = path.sub_string(0, path.len() - 1);
            }

            // Split path: /manga/{slug}/{number}
            let path_parts = path.split("/");
            // path_parts: ["", "manga", slug, number]
            if path_parts.len() >= 4 {
                chapter_num = path_parts[path_parts.len() - 1];
            }

            if chapter_num == "" || chapter_num == slug {
                continue;
            }

            // Build compound ID: slug|chapter_number
            let compound_id = `${slug}|${chapter_num}`;

            if seen.contains(compound_id) {
                continue;
            }
            seen[compound_id] = true;

            // Get chapter name from link text
            let chapter_title = element_text(link).trim();

            // Get publish date from the row if available
            let published_at = ();
            let date_els = element_select(row, "td.episode-date");
            if date_els.len() > 0 {
                let date_text = element_text(date_els[0]).trim();
                if date_text != "" {
                    published_at = date_text;
                }
            }

            let chapter_url = make_absolute(`/manga/${slug}/${chapter_num}/all-pages`);

            chapters.push(#{
                id: compound_id,
                series_id: slug,
                number: chapter_num,
                title: chapter_title,
                volume: (),
                language: "en",
                scanlator: "ReadM",
                url: chapter_url,
                published_at: published_at,
                page_count: (),
                extra: #{}
            });
        }
    }

    // Fallback: regex extraction if CSS selectors returned nothing
    if chapters.len() == 0 {
        let href_matches = regex_find_all("href=\"(/manga/" + slug + "/[\\d.]+)\"", html);
        for href in href_matches {
            let clean_href = href.replace("href=\"", "").replace("\"", "");
            // Extract chapter number
            let parts = clean_href.split("/");
            let chapter_num = parts[parts.len() - 1];

            if chapter_num == "" || chapter_num == slug {
                continue;
            }

            let compound_id = `${slug}|${chapter_num}`;
            if seen.contains(compound_id) {
                continue;
            }
            seen[compound_id] = true;

            let chapter_url = make_absolute(`/manga/${slug}/${chapter_num}/all-pages`);

            chapters.push(#{
                id: compound_id,
                series_id: slug,
                number: chapter_num,
                title: `Chapter ${chapter_num}`,
                volume: (),
                language: "en",
                scanlator: "ReadM",
                url: chapter_url,
                published_at: (),
                page_count: (),
                extra: #{}
            });
        }
    }

    // Sort ascending by chapter number
    chapters.sort(|a, b| {
        let num_a = parse_float(a.number);
        let num_b = parse_float(b.number);
        if num_a < num_b { -1 } else if num_a > num_b { 1 } else { 0 }
    });

    chapters
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    // chapter_id format: slug|chapter_number
    let parts = chapter_id.split("|");
    if parts.len() < 2 {
        // Maybe it's a full URL
        if chapter_id.starts_with("http") {
            let slug = extract_slug(chapter_id);
            // Try to extract chapter number from URL
            let path = chapter_id;
            if path.contains("readm.org") {
                path = path.split("readm.org")[1];
            }
            path = path.replace("/all-pages", "");
            while path.ends_with("/") {
                path = path.sub_string(0, path.len() - 1);
            }
            let segs = path.split("/");
            if segs.len() >= 4 {
                let ch_num = segs[segs.len() - 1];
                parts = [slug, ch_num];
            }
        }
        if parts.len() < 2 {
            return [];
        }
    }

    let slug = parts[0];
    let chapter_num = parts[1];

    // Fetch the all-pages URL
    let url = `${BASE_URL}/manga/${slug}/${chapter_num}/all-pages`;
    let html = fetch_html(url);

    if html == "" {
        return [];
    }

    let doc = html_parse(html);
    let pages = [];
    let seen = #{};
    let idx = 0;

    // Primary selector: div.ch-images img
    let imgs = html_select(doc, "div.ch-images img");

    // Fallback: img.img-responsive.scroll-down
    if imgs.len() == 0 {
        imgs = html_select(doc, "img.img-responsive.scroll-down");
    }

    // Fallback: any img inside the chapter content area
    if imgs.len() == 0 {
        imgs = html_select(doc, "div.chapter-content img");
    }

    for img in imgs {
        let img_url = get_image_url(img);

        if img_url == () || img_url == "" {
            continue;
        }

        // Skip tiny images (icons, ads, etc.)
        if img_url.contains("logo") || img_url.contains("icon") || img_url.contains("avatar") {
            continue;
        }

        // Skip duplicates
        if seen.contains(img_url) {
            continue;
        }
        seen[img_url] = true;

        pages.push(#{
            index: idx,
            url: img_url,
            headers: #{
                "Referer": `${BASE_URL}/manga/${slug}/${chapter_num}/all-pages`
            },
            referer: `${BASE_URL}/manga/${slug}/${chapter_num}/all-pages`
        });
        idx += 1;
    }

    // Fallback: regex extraction for image URLs
    if pages.len() == 0 {
        let img_matches = regex_find_all("data-src=\"([^\"]+)\"", html);
        if img_matches.len() == 0 {
            // Try src attributes inside ch-images
            img_matches = regex_find_all("ch-images[\\s\\S]*?src=\"([^\"]+)\"", html);
        }

        for img_match in img_matches {
            let img_url = img_match.replace("data-src=\"", "").replace("src=\"", "").replace("\"", "").trim();
            img_url = make_absolute(img_url);

            if img_url.contains("logo") || img_url.contains("icon") || img_url.contains("avatar") {
                continue;
            }

            if seen.contains(img_url) {
                continue;
            }
            seen[img_url] = true;

            pages.push(#{
                index: idx,
                url: img_url,
                headers: #{
                    "Referer": `${BASE_URL}/manga/${slug}/${chapter_num}/all-pages`
                },
                referer: `${BASE_URL}/manga/${slug}/${chapter_num}/all-pages`
            });
            idx += 1;
        }
    }

    pages
}
