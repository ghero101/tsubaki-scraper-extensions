// MangaGeko Scraper Add-on (Rhai)
// HTTP-only scraper for mgeko.cc (formerly mangageko.com)
//
// URL Patterns:
//   Browse:  /browse-comics/?q={query}&page={page}
//   Manga:   /manga/{slug}/
//   Chapters: /manga/{slug}/all-chapters/
//   Reader:  /reader/en/{slug}-chapter-{number}-eng-li/
//
// Available APIs:
//   HTTP: http_get(url), http_get_with_headers(url, headers)
//   HTML: html_parse(html), html_select(html, selector), element_text(el), element_attr(el, attr)
//   JSON: json_parse(text)
//   Regex: regex_find(pattern, text), regex_find_all(pattern, text)
//   String: url_encode(text)

const BASE_URL = "https://www.mgeko.cc";
const IMG_CDN = "https://imgsrv4.com";

// ============================================================================
// Helper Functions
// ============================================================================

/// Get headers for requests
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Fetch HTML with headers
fn fetch_html(url) {
    http_get_with_headers(url, get_headers())
}

/// Extract manga slug from URL
/// URL format: /manga/{slug}/ or https://www.mgeko.cc/manga/{slug}/
fn extract_slug(url) {
    let parts = url.split("/manga/");
    if parts.len() > 1 {
        let after_manga = parts[1];
        // Remove trailing slashes and any query params
        let slug = after_manga.split("/")[0].split("?")[0];
        return slug;
    }
    ""
}

/// Map status text to standard format
fn map_status(status_text) {
    let lower = status_text.to_lower();
    if lower.contains("completed") || lower.contains("finished") {
        return "Completed";
    }
    if lower.contains("ongoing") || lower.contains("publishing") {
        return "Ongoing";
    }
    if lower.contains("hiatus") {
        return "Hiatus";
    }
    if lower.contains("cancelled") || lower.contains("discontinued") {
        return "Cancelled";
    }
    ()
}

/// Extract chapter number from URL or title
/// URL format: /reader/en/{slug}-chapter-{number}-eng-li/
fn extract_chapter_number(url, title) {
    // Try to extract from URL first
    // Pattern: -chapter-{number}-
    let chapter_match = regex_find("chapter-(\\d+\\.?\\d*)", url);
    if chapter_match != () && chapter_match != "" {
        // The regex returns the full match, extract just the number
        let num = chapter_match.replace("chapter-", "");
        return num;
    }

    // Try to extract from title
    let title_match = regex_find("(?:chapter|ch\\.?)\\s*(\\d+\\.?\\d*)", title.to_lower());
    if title_match != () && title_match != "" {
        return title_match;
    }

    // Fallback: try to find any number in the chapter title
    let num_match = regex_find("\\d+\\.?\\d*", title);
    if num_match != () && num_match != "" {
        return num_match;
    }

    "0"
}

/// Clean up description text
fn clean_description(text) {
    let cleaned = text.trim();
    // Remove common prefixes
    if cleaned.starts_with("Description:") {
        cleaned = cleaned.sub_string(12).trim();
    }
    if cleaned.starts_with("Summary:") {
        cleaned = cleaned.sub_string(8).trim();
    }
    cleaned
}

// ============================================================================
// Required Interface Functions
// ============================================================================

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "mangageko-rhai",
        name: "MangaGeko",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

/// Parse series from API HTML response (used by search, browse, latest)
fn parse_series_from_api_html(html_content) {
    let series = [];
    let seen = #{};
    let doc = html_parse(html_content);

    // The API returns HTML with comic-card or novel-item elements
    // Try comic-card first (browse/search API), then novel-item (homepage)
    let items = html_select(doc, ".comic-card");
    if items.len() == 0 {
        items = html_select(doc, "li.novel-item");
    }

    for item in items {
        // Get the manga link
        let links = html_select(item, "a[href*='/manga/']");
        if links.len() == 0 {
            links = html_select(item, "a");
        }
        if links.len() == 0 {
            continue;
        }

        let href = ();
        for link in links {
            let h = element_attr(link, "href");
            if h != () && h.contains("/manga/") {
                href = h;
                break;
            }
        }

        if href == () || href == "" {
            continue;
        }

        // Make URL absolute
        let manga_url = href;
        if !href.starts_with("http") {
            manga_url = `${BASE_URL}${href}`;
        }

        let slug = extract_slug(manga_url);
        if slug == "" || seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        // Get title - try various selectors
        let title = "";
        let title_els = html_select(item, ".comic-card__title a");
        if title_els.len() > 0 {
            title = element_text(title_els[0]).trim();
        }
        if title == "" {
            let title_els2 = html_select(item, ".comic-card__title");
            if title_els2.len() > 0 {
                title = element_text(title_els2[0]).trim();
            }
        }
        if title == "" {
            let title_els3 = html_select(item, "h4.novel-title");
            if title_els3.len() > 0 {
                title = element_text(title_els3[0]).trim();
            }
        }
        if title == "" {
            let title_els4 = html_select(item, ".novel-title");
            if title_els4.len() > 0 {
                title = element_text(title_els4[0]).trim();
            }
        }
        if title == "" {
            // Fallback: link text or title attribute
            title = element_text(links[0]).trim();
            if title == "" {
                title = element_attr(links[0], "title");
                if title == () { title = ""; }
            }
        }

        if title == "" {
            continue;
        }

        // Get cover image
        let cover_url = ();
        let imgs = html_select(item, "img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "data-src");
            if cover_url == () || cover_url == "" {
                cover_url = element_attr(imgs[0], "src");
            }
            // Skip placeholder images
            if cover_url != () && cover_url.contains("placeholder.gif") {
                let alt_src = element_attr(imgs[0], "data-src");
                if alt_src != () && alt_src != "" {
                    cover_url = alt_src;
                }
            }
        }

        series.push(#{
            id: slug,
            title: title,
            url: manga_url,
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

/// Search for series matching query
fn search_series(query, page, auth) {
    // MangaGeko browse page loads results via AJAX from /browse-comics/data/
    let encoded_query = url_encode(query);
    let api_url = `${BASE_URL}/browse-comics/data/?q=${encoded_query}&page=${page}`;

    let json_text = fetch_html(api_url);

    let series = [];
    let has_more = false;

    // The API returns JSON with results_html containing the comic cards
    if json_text != "" && json_text.len() > 10 {
        // Try to parse as JSON to get the results_html field
        try {
            let data = json_parse(json_text);
            if data.results_html != () && data.results_html != "" {
                series = parse_series_from_api_html(data.results_html);
            }
            // Check pagination from API response
            if data.num_pages != () && data.page != () {
                has_more = data.page < data.num_pages;
            }
        } catch {
            // If JSON parse fails, try parsing the raw text as HTML
            series = parse_series_from_api_html(json_text);
        }
    }

    // Fallback: try loading the browse page directly and parsing links
    if series.len() == 0 {
        let browse_url = `${BASE_URL}/browse-comics/?q=${encoded_query}&page=${page}`;
        let html = fetch_html(browse_url);

        // Try parsing any manga links from the page
        let links = html_select(html, "a[href*='/manga/']");
        let seen = #{};
        for link in links {
            let href = element_attr(link, "href");
            if href == () || href == "" { continue; }

            let manga_url = href;
            if !href.starts_with("http") {
                manga_url = `${BASE_URL}${href}`;
            }

            let slug = extract_slug(manga_url);
            if slug == "" || seen.contains(slug) { continue; }
            seen[slug] = true;

            let title = element_text(link).trim();
            if title == "" {
                title = element_attr(link, "title");
                if title == () { title = ""; }
            }
            title = title.trim();

            if title == "" || title.to_lower().contains("browse") || title.to_lower().contains("home") {
                continue;
            }

            series.push(#{
                id: slug,
                title: title,
                url: manga_url,
                cover_url: (),
                alternate_titles: [],
                authors: [],
                artists: [],
                status: (),
                genres: [],
                tags: [],
                description: ()
            });
        }
    }

    if !has_more && series.len() >= 20 {
        has_more = true;
    }

    #{ series: series, has_more: has_more, total: () }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let url = id_or_url;
    let slug = id_or_url;

    if id_or_url.starts_with("http") {
        slug = extract_slug(id_or_url);
    } else {
        url = `${BASE_URL}/manga/${id_or_url}/`;
    }

    let html = fetch_html(url);

    // Extract title from page
    let title = "";
    let title_els = html_select(html, "h1");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }

    // Try alternative selector
    if title == "" {
        let title_els2 = html_select(html, ".novel-title");
        if title_els2.len() > 0 {
            title = element_text(title_els2[0]).trim();
        }
    }

    // Extract cover image - og:image is the reliable source
    // (https://www.mgeko.cc/media/manga_covers/{slug}.jpg).
    let cover_url = ();
    let ogimg = html_select(html, "meta[property=\"og:image\"]");
    if ogimg.len() > 0 {
        let c = element_attr(ogimg[0], "content");
        if c != () && c != "" { cover_url = c.trim(); }
    }
    // Look for cover image (usually in novel-cover or similar container)
    let cover_imgs = if cover_url == () { html_select(html, ".novel-cover img") } else { [] };
    if cover_imgs.len() > 0 {
        cover_url = element_attr(cover_imgs[0], "data-src");
        if cover_url == () || cover_url == "" {
            cover_url = element_attr(cover_imgs[0], "src");
        }
    }

    // Try finding any image that looks like a cover
    if cover_url == () {
        let all_imgs = html_select(html, "img");
        for img in all_imgs {
            let src = element_attr(img, "src");
            if src == () || src == "" {
                src = element_attr(img, "data-src");
            }
            if src != () && src != "" {
                if src.contains("avatar") || src.contains("cover") || src.contains("manga_covers") {
                    cover_url = src;
                    break;
                }
            }
        }
    }

    // Extract description
    let description = ();
    let desc_els = html_select(html, ".description");
    if desc_els.len() > 0 {
        description = clean_description(element_text(desc_els[0]));
    }

    // Try alternative selector for description
    if description == () || description == "" {
        let p_els = html_select(html, "p");
        for p in p_els {
            let text = element_text(p).trim();
            // Look for a substantial paragraph that might be the description
            if text.len() > 100 && !text.contains("Copyright") && !text.contains("DMCA") {
                description = clean_description(text);
                break;
            }
        }
    }

    // Extract genres/categories
    let genres = [];
    let genre_els = html_select(html, ".categories li");
    for el in genre_els {
        let genre = element_text(el).trim();
        if genre != "" && !genres.contains(genre) {
            genres.push(genre);
        }
    }

    // Try alternative genre selectors
    if genres.len() == 0 {
        let genre_links = html_select(html, "a[href*='genre']");
        for link in genre_links {
            let genre = element_text(link).trim();
            if genre != "" && !genres.contains(genre) {
                genres.push(genre);
            }
        }
    }

    // Extract status
    let status = ();
    let status_els = html_select(html, ".novel-stats");
    for el in status_els {
        let text = element_text(el).to_lower();
        if text.contains("ongoing") || text.contains("completed") || text.contains("hiatus") {
            status = map_status(text);
            break;
        }
    }

    // Try to find status in page text
    if status == () {
        if html.to_lower().contains("status: ongoing") || html.to_lower().contains("ongoing") {
            status = "Ongoing";
        } else if html.to_lower().contains("status: completed") || html.to_lower().contains("completed") {
            status = "Completed";
        }
    }

    // Extract authors/artists from info table or link-based structure
    let authors = [];
    let artists = [];

    // Try structured info rows (dt/dd or table)
    let info_rows = html_select(html, ".novel-info .item, .manga-info .item, .info-meta li");
    for row in info_rows {
        let label_els = html_select(row, "h3, label, .label, span.label");
        let label = if label_els.len() > 0 { element_text(label_els[0]).to_lower() } else { "" };
        if label.contains("author") {
            let links = html_select(row, "a");
            for link in links {
                let name = element_text(link).trim();
                if name != "" && name != "N/A" && !authors.contains(name) { authors.push(name); }
            }
        } else if label.contains("artist") {
            let links = html_select(row, "a");
            for link in links {
                let name = element_text(link).trim();
                if name != "" && name != "N/A" && !artists.contains(name) { artists.push(name); }
            }
        }
    }

    // Fallback: author links in href
    if authors.len() == 0 {
        let author_links = html_select(html, "a[href*='/author/'], a[href*='author=']");
        for link in author_links {
            let name = element_text(link).trim();
            if name != "" && name != "N/A" && !authors.contains(name) { authors.push(name); }
        }
    }
    // Current layout: <div class="author"><span>Author:</span><a ...>Name</a></div>
    if authors.len() == 0 {
        for link in html_select(html, ".author a") {
            let name = element_text(link).trim();
            if name != "" && name != "N/A" && name.to_lower() != "updating" && !authors.contains(name) { authors.push(name); }
        }
    }

    // Extract rating
    let rating = ();
    let rating_els = html_select(html, ".rating");
    if rating_els.len() > 0 {
        rating = element_text(rating_els[0]).trim();
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
            rating: rating,
            auto_match_metadata: true,
            source_name: "MangaGeko"
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let url = series_id;
    let slug = series_id;

    if series_id.starts_with("http") {
        slug = extract_slug(series_id);
        // Try to get the all-chapters page for complete list
        url = `${BASE_URL}/manga/${slug}/all-chapters/`;
    } else {
        url = `${BASE_URL}/manga/${series_id}/all-chapters/`;
    }

    let html = fetch_html(url);

    let chapters = [];
    let seen = #{};

    // Select chapter links - they're in <li> elements within the chapter list
    // Pattern: /reader/en/{slug}-chapter-{number}-eng-li/
    let chapter_links = html_select(html, "a[href*='/reader/']");

    // If no links found on all-chapters page, try the main manga page
    if chapter_links.len() == 0 {
        let main_url = `${BASE_URL}/manga/${slug}/`;
        html = fetch_html(main_url);
        chapter_links = html_select(html, "a[href*='/reader/']");
    }

    for link in chapter_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Skip duplicate links
        if seen.contains(href) {
            continue;
        }
        seen[href] = true;

        // Make URL absolute
        let chapter_url = href;
        if !href.starts_with("http") {
            chapter_url = `${BASE_URL}${href}`;
        }

        // Get chapter text/title
        let chapter_text = element_text(link).trim();

        // Extract chapter number from URL
        let chapter_num = extract_chapter_number(href, chapter_text);

        // Build chapter title
        let chapter_title = ();
        if chapter_text != "" && !chapter_text.starts_with(chapter_num) {
            chapter_title = chapter_text;
        }

        chapters.push(#{
            id: chapter_url,
            series_id: slug,
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

    // Chapters are listed newest first, we may want to keep that order
    // or reverse for oldest-first depending on preference

    chapters
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;
    if !chapter_id.starts_with("http") {
        url = `${BASE_URL}${chapter_id}`;
    }

    let html = fetch_html(url);

    let pages = [];
    let idx = 0;

    // MangaGeko displays images directly with src attributes
    // Pattern: https://imgsrv4.com/mg1/fastcdn/cdn_mangaraw/{manga}/{chapter}/{page}.jpg
    let page_imgs = html_select(html, "img");

    for img in page_imgs {
        let img_url = element_attr(img, "src");
        if img_url == () || img_url == "" {
            img_url = element_attr(img, "data-src");
        }

        // Skip non-page images
        if img_url == () || img_url == "" {
            continue;
        }

        // Filter for actual manga page images
        // They typically come from imgsrv4.com or similar CDN and are in a manga reader context
        if !img_url.contains("cdn_mangaraw") && !img_url.contains("fastcdn") {
            // Check if it looks like a page image (numbered jpg/png)
            if !regex_match("\\d+\\.(jpg|png|webp)", img_url.to_lower()) {
                continue;
            }
        }

        // Skip common non-manga images
        if img_url.contains("logo") || img_url.contains("icon") || img_url.contains("avatar") {
            continue;
        }
        if img_url.contains("ad") || img_url.contains("banner") || img_url.contains("sponsor") {
            continue;
        }
        if img_url.contains("loading") || img_url.contains("placeholder") {
            continue;
        }

        // Make URL absolute if needed
        if !img_url.starts_with("http") {
            if img_url.starts_with("//") {
                img_url = `https:${img_url}`;
            } else {
                img_url = `${BASE_URL}${img_url}`;
            }
        }

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

    pages
}

/// Get latest updates
fn get_latest_updates(page, auth) {
    // Try the API endpoint first for latest updates
    let api_url = `${BASE_URL}/browse-comics/data/?sort=latest&page=${page}`;

    let json_text = fetch_html(api_url);

    let series = [];
    let has_more = false;

    if json_text != "" && json_text.len() > 10 {
        try {
            let data = json_parse(json_text);
            if data.results_html != () && data.results_html != "" {
                let parsed = parse_series_from_api_html(data.results_html);
                for s in parsed {
                    series.push(#{
                        id: s.id,
                        title: s.title,
                        url: s.url,
                        cover_url: s.cover_url,
                        updated_at: ()
                    });
                }
            }
            if data.num_pages != () && data.page != () {
                has_more = data.page < data.num_pages;
            }
        } catch {}
    }

    // Fallback: try the jumbo/manga page which uses novel-item elements
    if series.len() == 0 {
        let url = `${BASE_URL}/jumbo/manga/?page=${page}`;
        let html = fetch_html(url);
        let doc = html_parse(html);

        let items = html_select(doc, "li.novel-item");
        if items.len() == 0 {
            items = html_select(doc, ".novel-item");
        }
        let seen = #{};

        for item in items {
            let links = html_select(item, "a");
            if links.len() == 0 { continue; }

            let href = ();
            for link in links {
                let h = element_attr(link, "href");
                if h != () && h.contains("/manga/") {
                    href = h;
                    break;
                }
            }

            if href == () || href == "" { continue; }

            let slug = extract_slug(href);
            if slug == "" || seen.contains(slug) { continue; }
            seen[slug] = true;

            let manga_url = href;
            if !href.starts_with("http") {
                manga_url = `${BASE_URL}${href}`;
            }

            let title = "";
            let title_els = html_select(item, "h4.novel-title");
            if title_els.len() > 0 {
                title = element_text(title_els[0]).trim();
            }
            if title == "" {
                let title_els2 = html_select(item, ".novel-title");
                if title_els2.len() > 0 {
                    title = element_text(title_els2[0]).trim();
                }
            }
            if title == "" {
                for link in links {
                    let t = element_attr(link, "title");
                    if t != () && t != "" {
                        title = t.trim();
                        break;
                    }
                }
            }

            let cover_url = ();
            let imgs = html_select(item, "img");
            if imgs.len() > 0 {
                cover_url = element_attr(imgs[0], "src");
                if cover_url == () || cover_url == "" || cover_url.contains("placeholder") {
                    cover_url = element_attr(imgs[0], "data-src");
                }
            }

            if title != "" {
                series.push(#{
                    id: slug,
                    title: title,
                    url: manga_url,
                    cover_url: cover_url,
                    updated_at: ()
                });
            }
        }
    }

    if !has_more && series.len() >= 20 {
        has_more = true;
    }

    #{ series: series, has_more: has_more }
}

/// Browse manga (main browse endpoint)
fn browse(page, filters, auth) {
    // Default to popular manga for browse
    get_popular(page, auth)
}

/// Get popular manga
fn get_popular(page, auth) {
    // Use the API endpoint which returns JSON with rendered HTML
    let api_url = `${BASE_URL}/browse-comics/data/?sort=views&page=${page}`;

    let json_text = fetch_html(api_url);

    let series = [];
    let has_more = false;

    if json_text != "" && json_text.len() > 10 {
        try {
            let data = json_parse(json_text);
            if data.results_html != () && data.results_html != "" {
                let parsed = parse_series_from_api_html(data.results_html);
                for s in parsed {
                    series.push(#{
                        id: s.id,
                        title: s.title,
                        url: s.url,
                        cover_url: s.cover_url
                    });
                }
            }
            if data.num_pages != () && data.page != () {
                has_more = data.page < data.num_pages;
            }
        } catch {
            // Fallback: parse raw text
            let parsed = parse_series_from_api_html(json_text);
            for s in parsed {
                series.push(#{
                    id: s.id,
                    title: s.title,
                    url: s.url,
                    cover_url: s.cover_url
                });
            }
        }
    }

    // Fallback: try the jumbo/manga page which uses novel-item elements
    if series.len() == 0 {
        let url = `${BASE_URL}/jumbo/manga/?page=${page}`;
        let html = fetch_html(url);
        let doc = html_parse(html);

        let items = html_select(doc, "li.novel-item");
        if items.len() == 0 {
            items = html_select(doc, ".novel-item");
        }
        let seen = #{};

        for item in items {
            let links = html_select(item, "a");
            if links.len() == 0 { continue; }

            let href = ();
            for link in links {
                let h = element_attr(link, "href");
                if h != () && h.contains("/manga/") {
                    href = h;
                    break;
                }
            }

            if href == () || href == "" { continue; }

            let slug = extract_slug(href);
            if slug == "" || seen.contains(slug) { continue; }
            seen[slug] = true;

            let manga_url = href;
            if !href.starts_with("http") {
                manga_url = `${BASE_URL}${href}`;
            }

            let title = "";
            let title_els = html_select(item, "h4.novel-title");
            if title_els.len() > 0 {
                title = element_text(title_els[0]).trim();
            }
            if title == "" {
                let title_els2 = html_select(item, ".novel-title");
                if title_els2.len() > 0 {
                    title = element_text(title_els2[0]).trim();
                }
            }
            if title == "" {
                for link in links {
                    let t = element_attr(link, "title");
                    if t != () && t != "" {
                        title = t.trim();
                        break;
                    }
                }
            }

            let cover_url = ();
            let imgs = html_select(item, "img");
            if imgs.len() > 0 {
                cover_url = element_attr(imgs[0], "src");
                if cover_url == () || cover_url == "" || cover_url.contains("placeholder") {
                    cover_url = element_attr(imgs[0], "data-src");
                }
            }

            if title != "" {
                series.push(#{
                    id: slug,
                    title: title,
                    url: manga_url,
                    cover_url: cover_url
                });
            }
        }
    }

    if !has_more && series.len() >= 20 {
        has_more = true;
    }

    #{ series: series, has_more: has_more }
}
