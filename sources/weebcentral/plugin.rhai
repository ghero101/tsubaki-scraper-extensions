// WeebCentral Scraper Add-on (Rhai)
// Scraper for weebcentral.com (successor to MangaSee/MangaLife)
// Uses browser automation for Cloudflare bypass
//
// Available APIs:
//   HTTP: http_get(url), http_get_with_headers(url, headers)
//   Browser: browser_launch(), browser_goto(id, url), browser_wait_for_cloudflare(id, timeout)
//            browser_get_html(id), browser_close(id), browser_is_available()
//   HTML: html_parse(html), html_select(html, selector), html_select_first(html, selector)
//         element_text(el), element_attr(el, attr)
//   JSON: json_parse(text), json_stringify(obj)
//   String: url_encode(text), regex_find(pattern, text), regex_find_all(pattern, text)

const BASE_URL = "https://weebcentral.com";

/// Fetch HTML using HTTP (WeebCentral content is server-side rendered).
/// Wrapped in try/catch so a transient network exception returns "" instead
/// of crashing every search/browse/series fetch.
fn fetch_html(url) {
    try {
        return http_get_with_headers(url, get_headers());
    } catch {
        return "";
    }
}

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "weebcentral-rhai",
        name: "WeebCentral",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

/// Get headers for HTTP requests (fallback)
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Clean search query (remove special characters)
fn clean_query(query) {
    let result = "";
    for c in query.chars() {
        // Remove characters that cause issues: !#:()
        if c != '!' && c != '#' && c != ':' && c != '(' && c != ')' {
            result += c;
        }
    }
    result.trim()
}

/// Map status string to standard format
fn map_status(status_text) {
    if status_text == () || status_text == "" {
        return ();
    }
    let lower = status_text.to_lower();
    if lower.contains("ongoing") {
        return "Ongoing";
    } else if lower.contains("complete") {
        return "Completed";
    } else if lower.contains("hiatus") {
        return "Hiatus";
    } else if lower.contains("cancel") {
        return "Cancelled";
    }
    ()
}

/// Extract series ID from URL
/// URL format: https://weebcentral.com/series/01J76XYFP55025PVETS8GD9B6B/Series-Title
fn extract_series_id(url) {
    let parts = url.split("/series/");
    if parts.len() > 1 {
        let id_part = parts[1].split("/")[0];
        return id_part;
    }
    ""
}

/// Extract chapter ID from URL
/// URL format: https://weebcentral.com/chapters/01J76XZ812WKWQH58G74HPTWXX
fn extract_chapter_id(url) {
    let parts = url.split("/chapters/");
    if parts.len() > 1 {
        let id_part = parts[1].split("/")[0].split("?")[0];
        return id_part;
    }
    ""
}

/// Clean title text — strip "Official" badge text and excessive whitespace
fn clean_title(title) {
    if title == () || title == "" {
        return "";
    }
    // Remove "Official" prefix that comes from badge elements
    let cleaned = title;
    if cleaned.starts_with("Official") {
        cleaned = cleaned.sub_string(8, cleaned.len());
    }
    // Collapse multiple whitespace/newlines into single space
    let result = "";
    let last_was_space = true;  // Trim leading whitespace
    for c in cleaned.chars() {
        if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
            if !last_was_space {
                result += " ";
                last_was_space = true;
            }
        } else {
            result += c;
            last_was_space = false;
        }
    }
    result.trim()
}

/// Search for series matching query
fn search_series(query, page, auth) {
    let cleaned_query = clean_query(query);
    let encoded_query = url_encode(cleaned_query);
    let limit = 32;
    let offset = (page - 1) * limit;

    // WeebCentral uses /search/data endpoint for search API
    let url = `${BASE_URL}/search/data?text=${encoded_query}&limit=${limit}&offset=${offset}&display_mode=Full+Display`;

    let html = fetch_html(url);

    // The response is HTML with article/section structure
    let series = [];
    let seen = #{};

    // Select search result items: article > section > a
    let items = html_select(html, "article section a");

    for item in items {
        let href = element_attr(item, "href");
        if href == () || href == "" || !href.contains("/series/") {
            continue;
        }

        // Extract series ID
        let id = extract_series_id(href);
        if id == "" || seen.contains(id) {
            continue;
        }
        seen[id] = true;

        // Get title from the link or nested div
        let title = "";
        let title_divs = html_select(item, "div:last-child");
        if title_divs.len() > 0 {
            title = clean_title(element_text(title_divs[title_divs.len() - 1]));
        }
        if title == "" {
            title = clean_title(element_text(item));
        }

        // Get cover image
        let cover_url = ();
        let imgs = html_select(item, "img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
            if cover_url == () || cover_url == "" {
                cover_url = element_attr(imgs[0], "data-src");
            }
        }

        if title != "" {
            series.push(#{
                id: id,
                title: title,
                url: href,
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
    }

    // Check if there are more results
    let has_more = series.len() >= limit;

    #{ series: series, has_more: has_more, total: () }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let url = id_or_url;
    let id = id_or_url;

    if !id_or_url.starts_with("http") {
        // Build URL from ID
        url = `${BASE_URL}/series/${id_or_url}`;
    } else {
        id = extract_series_id(id_or_url);
    }

    let html = fetch_html(url);

    // Extract title from h1 in section[x-data] > section
    let title = "";
    let title_els = html_select(html, "section h1");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }

    // Extract cover image
    let cover_url = ();
    let cover_imgs = html_select(html, "img[alt$='cover']");
    if cover_imgs.len() > 0 {
        cover_url = element_attr(cover_imgs[0], "src");
    }
    // Fallback to any image in the main section
    if cover_url == () {
        let section_imgs = html_select(html, "section img");
        if section_imgs.len() > 0 {
            cover_url = element_attr(section_imgs[0], "src");
        }
    }

    // Extract description
    let description = ();
    let desc_els = html_select(html, "section p");
    for el in desc_els {
        let text = element_text(el).trim();
        if text.len() > 50 {
            description = text;
            break;
        }
    }

    // Extract authors and artists from ul > li entries with Author/Artist labels
    let authors = [];
    let artists = [];
    let info_lis = html_select(html, "ul li");
    for li in info_lis {
        let li_text = element_text(li).to_lower();
        let links = html_select(li, "a.link-info");
        if links.len() == 0 { continue; }
        if li_text.starts_with("author") {
            for link in links {
                let name = element_text(link).trim();
                if name != "" && !authors.contains(name) { authors.push(name); }
            }
        } else if li_text.starts_with("artist") {
            for link in links {
                let name = element_text(link).trim();
                if name != "" && !artists.contains(name) { artists.push(name); }
            }
        }
    }
    // Fallback: if no structured match, collect all link-info as authors
    if authors.len() == 0 && artists.len() == 0 {
        let author_links = html_select(html, "a.link-info");
        for link in author_links {
            let name = element_text(link).trim();
            if name != "" && !authors.contains(name) { authors.push(name); }
        }
    }

    // Extract genres/tags
    let genres = [];
    let genre_links = html_select(html, "ul li a");
    for link in genre_links {
        let href = element_attr(link, "href");
        // Filter for genre/tag links
        if href != () && (href.contains("genre") || href.contains("tag")) {
            let genre = element_text(link).trim();
            if genre != "" && !genres.contains(genre) {
                genres.push(genre);
            }
        }
    }

    // Extract status
    let status = ();
    let status_links = html_select(html, "ul li a");
    for link in status_links {
        let text = element_text(link).to_lower();
        if text.contains("ongoing") || text.contains("complete") || text.contains("hiatus") || text.contains("cancel") {
            status = map_status(text);
            break;
        }
    }

    // Extract alternate titles (Associated Names)
    let alt_titles = [];
    let li_els = html_select(html, "ul li");
    for li in li_els {
        let li_text = element_text(li);
        if li_text.to_lower().contains("alternative") || li_text.to_lower().contains("associated") {
            // Parse the alternate names
            let spans = html_select(li, "span");
            for span in spans {
                let alt = element_text(span).trim();
                if alt != "" && alt != title && !alt_titles.contains(alt) {
                    alt_titles.push(alt);
                }
            }
        }
    }

    #{
        id: id,
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
            source_name: "WeebCentral"
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let url = series_id;

    if !series_id.starts_with("http") {
        url = `${BASE_URL}/series/${series_id}`;
    }

    // Fetch full chapter list
    let chapter_list_url = `${url}/full-chapter-list`;
    let html = fetch_html(chapter_list_url);

    let chapters = [];
    let seen = #{};

    // Select chapter links: div[x-data] > a
    let chapter_links = html_select(html, "div a");

    for link in chapter_links {
        let href = element_attr(link, "href");
        if href == () || href == "" || !href.contains("/chapters/") {
            continue;
        }

        // Skip duplicates
        if seen.contains(href) {
            continue;
        }
        seen[href] = true;

        let ch_id = extract_chapter_id(href);
        if ch_id == "" {
            continue;
        }

        // Get chapter name from span.flex > span
        let ch_title = "";
        let spans = html_select(link, "span span");
        if spans.len() > 0 {
            ch_title = element_text(spans[0]).trim();
        }
        if ch_title == "" {
            ch_title = element_text(link).trim();
        }

        // Extract chapter number from title
        let ch_num = extract_chapter_number(ch_title);

        // Get upload date from time element
        let published_at = ();
        let time_els = html_select(link, "time");
        if time_els.len() > 0 {
            published_at = element_attr(time_els[0], "datetime");
        }

        // Detect scanlator type (official vs unofficial)
        // Official chapters have purple stroke color (#d8b4fe)
        let scanlator = ();
        let svg_els = html_select(link, "svg");
        for svg in svg_els {
            let svg_html = svg;
            if svg_html.contains("#d8b4fe") || svg_html.contains("d8b4fe") {
                scanlator = "Official";
                break;
            }
        }

        chapters.push(#{
            id: ch_id,
            series_id: series_id,
            number: ch_num,
            title: ch_title,
            volume: (),
            language: "en",
            scanlator: scanlator,
            url: href,
            published_at: published_at,
            page_count: (),
            extra: #{}
        });
    }

    chapters
}

/// Extract chapter number from title
fn extract_chapter_number(title) {
    if title == () || title == "" {
        return "0";
    }

    let lower = title.to_lower();

    // Try to find "chapter X" or "ch X" or "ch. X"
    let patterns = ["chapter ", "ch. ", "ch "];
    for pattern in patterns {
        if lower.contains(pattern) {
            let parts = lower.split(pattern);
            if parts.len() > 1 {
                let after = parts[1].trim();
                // Extract number (including decimals)
                let num_str = "";
                for c in after.chars() {
                    if c >= '0' && c <= '9' || c == '.' {
                        num_str += c;
                    } else if num_str.len() > 0 {
                        break;
                    }
                }
                if num_str != "" {
                    return num_str;
                }
            }
        }
    }

    // Fallback: find any number at the start or after common patterns
    let num_str = "";
    let found_num = false;
    for c in title.chars() {
        if c >= '0' && c <= '9' || c == '.' {
            num_str += c;
            found_num = true;
        } else if found_num && num_str.len() > 0 {
            break;
        }
    }

    if num_str != "" {
        return num_str;
    }

    "0"
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;

    if !chapter_id.starts_with("http") {
        url = `${BASE_URL}/chapters/${chapter_id}`;
    }

    // Get reading style from settings (default: long_strip)
    let reading_style = "long_strip";
    let s = if settings != () { settings } else { #{} };
    if s.contains("reading_style") {
        reading_style = s["reading_style"];
    }

    // Fetch pages using the /images endpoint
    let images_url = `${url}/images?is_prev=False&reading_style=${reading_style}`;
    let html = fetch_html(images_url);

    let pages = [];
    let idx = 0;

    // Select page images: section[x-data~=scroll] > img or img[src*='/manga/']
    let page_imgs = html_select(html, "section img");

    for img in page_imgs {
        let img_url = element_attr(img, "src");
        if img_url == () || img_url == "" {
            img_url = element_attr(img, "data-src");
        }

        // Filter for actual manga page images
        if img_url != () && img_url != "" && img_url.contains("http") {
            // Skip thumbnails and icons
            if img_url.contains("/manga/") || img_url.contains("cdn") || img_url.contains("thumbnail") {
                pages.push(#{
                    index: idx,
                    url: img_url,
                    headers: #{
                        "Referer": BASE_URL,
                        "Accept": "image/avif,image/webp,*/*"
                    },
                    referer: BASE_URL
                });
                idx += 1;
            }
        }
    }

    // If no images found in section, try broader selector
    if pages.len() == 0 {
        let all_imgs = html_select(html, "img");
        for img in all_imgs {
            let img_url = element_attr(img, "src");
            if img_url == () || img_url == "" {
                img_url = element_attr(img, "data-src");
            }

            if img_url != () && img_url != "" && img_url.contains("/manga/") {
                pages.push(#{
                    index: idx,
                    url: img_url,
                    headers: #{
                        "Referer": BASE_URL,
                        "Accept": "image/avif,image/webp,*/*"
                    },
                    referer: BASE_URL
                });
                idx += 1;
            }
        }
    }

    pages
}

/// Get latest updates
/// Uses path-based pagination /latest-updates/{page}
/// Note: /hot-updates?page=X ignores page param (broken pagination)
fn get_latest_updates(page, auth) {
    // Use path-based pagination - this endpoint properly paginates
    // The /hot-updates?page=X endpoint ignores page parameter
    let url = `${BASE_URL}/latest-updates/${page}`;

    let html = fetch_html(url);
    let doc = html_parse(html);

    let series = [];
    let seen = #{};

    // Select article elements with data-tip (contains title)
    // The mobile view articles contain series links
    let articles = html_select(doc, "article[data-tip]");

    for article in articles {
        // Get title from data-tip attribute
        let title = element_attr(article, "data-tip");
        if title == () || title == "" {
            continue;
        }

        // Find series link inside the article
        let links = html_select(article, "a[href*='/series/']");
        if links.len() == 0 {
            continue;
        }

        let href = element_attr(links[0], "href");
        if href == () || href == "" {
            continue;
        }

        let id = extract_series_id(href);
        if id == "" || seen.contains(id) {
            continue;
        }
        seen[id] = true;

        // Get cover from img or source
        let cover_url = ();
        let imgs = html_select(article, "img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
        }
        // Try source tag for webp
        if cover_url == () || cover_url == "" {
            let sources = html_select(article, "source");
            if sources.len() > 0 {
                cover_url = element_attr(sources[0], "srcset");
            }
        }

        series.push(#{
            id: id,
            title: title,
            url: href,
            cover_url: cover_url,
            updated_at: ()
        });
    }

    let has_more = series.len() >= 10;

    #{ series: series, has_more: has_more }
}

/// Get popular series
fn get_popular(page, auth) {
    // WeebCentral doesn't have a dedicated popular page
    // Use search sorted by popularity or the main page
    let limit = 32;
    let offset = (page - 1) * limit;
    let url = `${BASE_URL}/search/data?text=&limit=${limit}&offset=${offset}&sort=Most+Popular&display_mode=Full+Display`;

    let html = fetch_html(url);

    let series = [];

    let seen = #{};
    let items = html_select(html, "article section a");

    for item in items {
        let href = element_attr(item, "href");
        if href == () || href == "" || !href.contains("/series/") {
            continue;
        }

        let id = extract_series_id(href);
        if id == "" || seen.contains(id) {
            continue;
        }
        seen[id] = true;

        // Get title
        let title = "";
        let title_divs = html_select(item, "div:last-child");
        if title_divs.len() > 0 {
            title = clean_title(element_text(title_divs[title_divs.len() - 1]));
        }
        if title == "" {
            title = clean_title(element_text(item));
        }

        // Get cover
        let cover_url = ();
        let imgs = html_select(item, "img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
        }

        if title != "" {
            series.push(#{
                id: id,
                title: title,
                url: href,
                cover_url: cover_url
            });
        }
    }

    let has_more = series.len() >= limit;

    #{ series: series, has_more: has_more }
}

/// Browse manga (main browse endpoint)
fn browse(page, filters, auth) {
    // Default to latest updates for browse
    get_latest_updates(page, auth)
}
