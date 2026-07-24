// Webtoon Scraper Add-on (Rhai)
// Official Webtoon platform scraper (webtoons.com)
// Uses HTML parsing and API endpoints
//
// Available APIs:
//   http_get(url) -> string
//   http_get_with_headers(url, headers) -> string
//   html_select(html, selector) -> array
//   element_text(element) -> string
//   element_attr(element, name) -> string
//   json_parse(text) -> Dynamic
//   url_encode(text) -> string

const BASE_URL = "https://www.webtoons.com";
const MOBILE_URL = "https://m.webtoons.com";

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "webtoon-rhai",
        name: "Webtoon",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en", "es", "fr", "de", "id", "th", "zh-hant"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

/// Get headers for requests
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Referer": BASE_URL,
        "Accept-Language": "en-US,en;q=0.9"
    }
}

/// Get mobile headers (sometimes returns cleaner data)
fn get_mobile_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Referer": MOBILE_URL
    }
}

/// Wrap http_get_with_headers (desktop headers) so a transient network
/// exception falls through to "" and downstream html_select / regex_find
/// see "no data" rather than crashing the entire fetch. 13 call sites in
/// this plugin previously had no protection.
fn safe_get(url) {
    try {
        return http_get_with_headers(url, get_headers());
    } catch {
        return "";
    }
}

/// Search for series matching query
fn search_series(query, page, auth) {
    let encoded_query = url_encode(query);
    let url = `${BASE_URL}/en/search?keyword=${encoded_query}&page=${page}`;

    let html = safe_get(url);

    // Check if we got blocked/redirected (more specific patterns to avoid false positives)
    if html.contains("Access Denied") || html.contains("challenge-running") || html.contains("cf-chl-widget") {
        return #{
            series: [],
            has_more: false,
            total: (),
            error: "Access blocked or captcha required"
        };
    }

    let series = [];
    let seen_ids = #{};

    // Find all card items with data-title-no attribute
    let cards = html_select(html, "a._card_item[data-title-no]");

    for card in cards {
        let title_no = element_attr(card, "data-title-no");
        if title_no == () || title_no == "" {
            continue;
        }

        // Skip duplicates
        if seen_ids[title_no] != () {
            continue;
        }
        seen_ids[title_no] = true;

        // Get URL - need the full URL with genre/slug for get_series to work
        let href = element_attr(card, "href");
        let series_url = "";
        if href != () && href != "" {
            series_url = make_full_url(href);
        }
        if series_url == "" {
            series_url = `${BASE_URL}/en/originals/series?title_no=${title_no}`;
        }

        // Get title from .title element
        let title = `Webtoon #${title_no}`;
        let title_els = html_select(card, "strong.title, .title");
        if title_els.len() > 0 {
            let t = element_text(title_els[0]);
            if t != () && t != "" {
                title = t.trim();
            }
        }

        // Get author
        let authors = [];
        let author_els = html_select(card, ".author");
        if author_els.len() > 0 {
            let a = element_text(author_els[0]);
            if a != () && a != "" {
                authors.push(a.trim());
            }
        }

        // Get cover image
        let cover_url = ();
        let img_els = html_select(card, "img");
        if img_els.len() > 0 {
            let src = element_attr(img_els[0], "src");
            if src != () && src != "" {
                cover_url = src;
            }
        }

        // Use full URL as ID - this is required for Webtoon since get_series needs the path
        let series_id = if series_url.contains("webtoons.com") { series_url } else { title_no };

        // Bound the result — a very large array overflows the Rhai→Rust
        // conversion (see parse_webtoon_cards). 100 is plenty for a search page.
        if series.len() >= 100 { break; }
        series.push(#{
            id: series_id,
            title: title,
            url: series_url,
            cover_url: cover_url,
            alternate_titles: [],
            authors: authors,
            artists: [],
            status: (),
            genres: [],
            tags: [],
            description: ()
        });
    }

    // Check for next page
    let has_more = html.contains("pg_next") || html.contains("page-next");

    #{ series: series, has_more: has_more, total: () }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let title_no = "";
    let url = "";

    // Check if we received a URL (our new ID format) or just a numeric ID
    if id_or_url.contains("webtoons.com") {
        // We have a full URL - use it directly
        url = id_or_url;
        title_no = extract_title_no(id_or_url);
    } else {
        // Just a numeric ID - need to search for the proper URL
        title_no = id_or_url;

        // Search the originals page to find the series URL
        let originals_url = `${BASE_URL}/en/originals`;
        let search_html = safe_get(originals_url);

        // Find the card with matching data-title-no
        let cards = html_select(search_html, `a[data-title-no="${title_no}"]`);
        if cards.len() > 0 {
            let href = element_attr(cards[0], "href");
            if href != () && href != "" {
                url = make_full_url(href);
            }
        }

        // If not found in originals, try search
        if url == "" {
            let search_page = `${BASE_URL}/en/search?keyword=${title_no}&page=1`;
            let search_html2 = safe_get(search_page);
            let cards2 = html_select(search_html2, `a._card_item[data-title-no="${title_no}"]`);
            if cards2.len() > 0 {
                let href = element_attr(cards2[0], "href");
                if href != () && href != "" {
                    url = make_full_url(href);
                }
            }
        }

        // Last resort fallback
        if url == "" {
            url = `${BASE_URL}/en/originals/series?title_no=${title_no}`;
        }
    }

    let html = safe_get(url);

    // Extract title
    let title = "";
    let title_els = html_select(html, "h1.subj, h3.subj, .detail_header .subj");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }

    // If no title found, try og:title meta
    if title == "" {
        let meta_els = html_select(html, "meta[property='og:title']");
        if meta_els.len() > 0 {
            title = element_attr(meta_els[0], "content");
            if title != () {
                title = title.trim();
            }
        }
    }

    // Extract cover — og:image contains the thumbnail; search fallback for older series
    let cover_url = ();

    // Tier 1: og:image meta (already fetched, no extra request)
    let og_img_els = html_select(html, "meta[property='og:image']");
    if og_img_els.len() > 0 {
        let src = element_attr(og_img_els[0], "content");
        if src != () && src != "" {
            cover_url = src;
        }
    }

    // Tier 2: detail page thumbnail img elements
    if cover_url == () {
        let cover_els = html_select(html, ".detail_body .thmb img, .detail_header img");
        for el in cover_els {
            let src = element_attr(el, "src");
            if src != () && src != "" && src.contains("http") && !src.contains("spacer") {
                cover_url = src;
                break;
            }
        }
    }

    // Tier 3: search page (extra HTTP request, only if needed)
    if cover_url == () && title != "" {
        let encoded_title = url_encode(title);
        let search_url = `${BASE_URL}/en/search?keyword=${encoded_title}&page=1`;
        let search_html = safe_get(search_url);
        let search_cards = html_select(search_html, `a._card_item[data-title-no="${title_no}"]`);
        if search_cards.len() > 0 {
            let imgs = html_select(search_cards[0], "img");
            if imgs.len() > 0 {
                let src = element_attr(imgs[0], "src");
                if src != () && src != "" {
                    cover_url = src;
                }
            }
        }
    }

    // Extract description
    let description = ();
    let desc_els = html_select(html, "p.summary, .detail_body .summary, meta[property='og:description']");
    for el in desc_els {
        let text = element_text(el);
        if text == () || text == "" {
            text = element_attr(el, "content");
        }
        if text != () && text != "" {
            description = text.trim();
            break;
        }
    }

    // Extract author
    let authors = [];
    let author_els = html_select(html, "a.author, .info .author_area a, .detail_header .author");
    for el in author_els {
        let author = element_text(el).trim();
        if author != "" && !authors.contains(author) {
            authors.push(author);
        }
    }

    // Extract genre
    let genres = [];
    let genre_els = html_select(html, "h2.genre, .info .genre, .detail_header .genre");
    for el in genre_els {
        let genre = element_text(el).trim();
        if genre != "" && !genres.contains(genre) {
            genres.push(genre);
        }
    }

    // Determine status
    let status = "Ongoing";
    let html_lower = html.to_lower();
    if html_lower.contains("completed") || html_lower.contains("complete") {
        status = "Completed";
    }

    #{
        id: title_no,
        title: if title != () && title != "" { title } else { `Webtoon #${title_no}` },
        alternate_titles: [],
        description: description,
        cover_url: cover_url,
        authors: authors,
        artists: [],
        status: status,
        genres: genres,
        tags: ["webtoon"],
        year: (),
        content_rating: "safe",
        url: url,
        extra: #{
            title_no: title_no,
            auto_match_metadata: true,
            source_name: "Webtoon"
        }
    }
}

/// Get all chapters (episodes) for a series
fn get_chapters(series_id, auth) {
    let title_no = "";
    let base_list_url = "";

    // Check if we received a URL or just a numeric ID
    if series_id.contains("webtoons.com") {
        title_no = extract_title_no(series_id);
        // Build the list URL from the provided URL
        // URLs look like: https://www.webtoons.com/en/action/teenage-mercenary/list?title_no=2677
        if series_id.contains("/list") {
            // Already a list URL, extract base
            base_list_url = series_id.split("?")[0];
        } else {
            // Not a list URL, but same pattern - just append /list if needed
            // Or use as-is
            let url_base = series_id.split("?")[0];
            if url_base.ends_with("/list") {
                base_list_url = url_base;
            } else {
                // Need to add /list - check if URL has trailing slug
                // e.g., /en/action/teenage-mercenary -> /en/action/teenage-mercenary/list
                base_list_url = url_base + "/list";
            }
        }
    } else {
        // Just a numeric ID - need to find the proper URL first
        title_no = series_id;

        // Try originals page first
        let originals_url = `${BASE_URL}/en/originals`;
        let search_html = safe_get(originals_url);
        let cards = html_select(search_html, `a[data-title-no="${title_no}"]`);
        if cards.len() > 0 {
            let href = element_attr(cards[0], "href");
            if href != () && href != "" {
                let full_url = make_full_url(href);
                let url_base = full_url.split("?")[0];
                if url_base.ends_with("/list") {
                    base_list_url = url_base;
                } else {
                    base_list_url = url_base + "/list";
                }
            }
        }
    }

    let chapters = [];
    let page = 1;

    loop {
        // Build episode list URL
        let url = "";
        if base_list_url != "" {
            url = `${base_list_url}?title_no=${title_no}&page=${page}`;
        } else {
            // Fallback - unlikely to work but try anyway
            url = `${BASE_URL}/en/originals/series/list?title_no=${title_no}&page=${page}`;
        }

        let html = safe_get(url);

        // Find episode items
        let episode_items = html_select(html, "#_listUl li a, ul._episodeList li a, .episode_lst li a");

        if episode_items.len() == 0 {
            break;
        }

        for item in episode_items {
            let href = element_attr(item, "href");
            if href == () || href == "" {
                continue;
            }

            // Extract episode number
            let episode_no = extract_episode_no(href);
            if episode_no == "" {
                continue;
            }

            // Get episode title
            let title = ();
            let title_els = html_select(item, ".subj span, .episode_title, .sub_title");
            if title_els.len() > 0 {
                title = element_text(title_els[0]).trim();
            }

            // Get episode number display
            let ep_num = "";
            let num_els = html_select(item, ".tx, .num, .episode_num");
            if num_els.len() > 0 {
                ep_num = element_text(num_els[0]).trim();
                // Extract just the number
                ep_num = extract_number_from_text(ep_num);
            }

            if ep_num == "" {
                ep_num = episode_no;
            }

            // Get date
            let date = ();
            let date_els = html_select(item, ".date, .update_date");
            if date_els.len() > 0 {
                date = element_text(date_els[0]).trim();
            }

            // Get thumbnail
            let thumb = ();
            let thumb_els = html_select(item, "img");
            if thumb_els.len() > 0 {
                thumb = element_attr(thumb_els[0], "src");
                if thumb == () {
                    thumb = element_attr(thumb_els[0], "data-src");
                }
            }

            // Use full viewer URL as chapter ID - Webtoon requires the path with slug
            let chapter_url = make_full_url(href);

            chapters.push(#{
                id: chapter_url,
                series_id: title_no,
                number: ep_num,
                title: title,
                volume: (),
                language: "en",
                scanlator: "Webtoon",
                url: chapter_url,
                published_at: date,
                page_count: (),
                extra: #{
                    episode_no: episode_no,
                    thumbnail: thumb
                }
            });
        }

        // Check for next page - Webtoon pagination uses numbered links inside .paginate
        // The current page has span.on, we need to check if there are more pages
        let paginate = html_select(html, ".paginate a");
        let has_next = false;
        let current_page_found = false;
        for pg_link in paginate {
            let span_els = html_select(pg_link, "span.on");
            if span_els.len() > 0 {
                current_page_found = true;
            } else if current_page_found {
                // Found a link after the current page
                has_next = true;
                break;
            }
        }
        if !has_next {
            break;
        }

        page += 1;

        // Safety limit - prevent runaway loops
        if page > 20 {
            break;
        }

        // Also limit total chapters to prevent Rhai operation limit
        if chapters.len() > 500 {
            break;
        }
    }

    // Webtoon shows newest first, reverse for chronological order
    chapters.reverse();

    chapters
}

/// Get page URLs for an episode
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;

    // Chapter ID should now be the full viewer URL
    // Handle legacy composite ID format just in case
    if chapter_id.contains("_") && !chapter_id.contains("webtoons.com") && !chapter_id.contains("/") {
        let parts = chapter_id.split("_");
        if parts.len() >= 2 {
            let title_no = parts[0];
            let episode_no = parts[1];
            // This fallback URL likely won't work without the proper path
            url = `${BASE_URL}/en/originals/viewer?title_no=${title_no}&episode_no=${episode_no}`;
        }
    }

    // Make sure URL is absolute
    url = make_full_url(url);

    let html = safe_get(url);

    let pages = [];
    let idx = 0;

    // Try multiple selectors to handle Webtoon's variable HTML structure
    // Priority order: most specific to most general
    let selectors = [
        "#_imageList img",           // Primary viewer image list
        ".viewer_lst img",           // Alternative viewer list
        "#content img._images",      // Content area images
        ".viewer_img img",           // Viewer image container
        ".episode_cont img",         // Episode content images
        "div[class*='viewer'] img",  // Any viewer div
        ".content_area img"          // Generic content area
    ];

    let img_container = [];
    for selector in selectors {
        img_container = html_select(html, selector);
        if img_container.len() > 0 {
            break;
        }
    }

    for img in img_container {
        // Try multiple attributes for the image URL
        let img_url = element_attr(img, "data-url");
        if img_url == () || img_url == "" {
            img_url = element_attr(img, "src");
        }
        if img_url == () || img_url == "" {
            img_url = element_attr(img, "data-src");
        }
        if img_url == () || img_url == "" {
            img_url = element_attr(img, "data-lazy-src");
        }
        if img_url == () || img_url == "" {
            img_url = element_attr(img, "data-original");
        }

        // Validate URL before adding
        if img_url != () && img_url != "" && img_url.contains("http") {
            // Skip thumbnails, icons, banners, and placeholder images
            if img_url.contains("thumb") || img_url.contains("icon") || img_url.contains("banner") {
                continue;
            }
            if img_url.contains("placeholder") || img_url.contains("loading") || img_url.contains("spinner") {
                continue;
            }
            // Must be from Webtoon's image CDN (webtoon-phinf or swebtoon-phinf)
            if !img_url.contains("phinf.pstatic.net") && !img_url.contains("webtoon") {
                continue;
            }

            // Use the actual chapter URL as referer for better CDN acceptance
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

    pages
}

/// Get latest updates - iterates through genre pages for comprehensive coverage
/// Pages: 1=Originals, 2=Completed(A-L), 3=Completed(M-Z), 4+=Genre pages
fn get_latest_updates(page, auth) {
    // Webtoon genre slugs - each genre page contains 100-800 series
    let webtoon_genres = [
        "drama", "fantasy", "comedy", "action", "romance",
        "sf", "thriller", "supernatural", "mystery", "sports",
        "slice_of_life", "super_hero", "historical", "heart_warming",
        "horror", "informative"
    ];

    if page == 1 {
        // First page: Get series from main originals page (ongoing)
        let url = `${BASE_URL}/en/originals`;
        let html = safe_get(url);
        let result = parse_webtoon_cards(html);
        return #{ series: result.series, has_more: true };
    }

    if page == 2 {
        // Second page: Completed originals sorted by MANA (first 100). Capped at
        // 100 — large result arrays overflow the Rhai→Rust conversion.
        let url = `${BASE_URL}/en/originals/complete?sortOrder=MANA`;
        let html = safe_get(url);
        let result = parse_webtoon_genre_cards_limited(html, 0, 100);
        return #{ series: result.series, has_more: true };
    }

    if page == 3 {
        // Third page: Completed originals (next 100, offset).
        let url = `${BASE_URL}/en/originals/complete?sortOrder=MANA`;
        let html = safe_get(url);
        let result = parse_webtoon_genre_cards_limited(html, 100, 100);
        return #{ series: result.series, has_more: true };
    }

    // Pages 4+ iterate through genre pages
    let genre_index = page - 4;  // page 4 = genre 0, page 5 = genre 1, etc.

    if genre_index >= webtoon_genres.len() {
        return #{ series: [], has_more: false };
    }

    let genre = webtoon_genres[genre_index];
    let url = `${BASE_URL}/en/genres/${genre}?sortOrder=MANA`;

    let html = safe_get(url);

    // Parse genre page cards (capped at 100 — see page-2 note)
    let result = parse_webtoon_genre_cards_limited(html, 0, 100);

    // Has more if there are more genres to iterate
    let has_more = genre_index + 1 < webtoon_genres.len();

    #{ series: result.series, has_more: has_more }
}

/// Parse cards from genre/completed pages with offset and limit
/// Used to split large pages into multiple requests
fn parse_webtoon_genre_cards_limited(html, offset, limit) {
    let series = [];
    let seen_ids = #{};

    // Use the broad selector for all Webtoon link types
    let cards = html_select(html, "a[data-title-no]");

    let count = 0;
    let skipped = 0;

    for card in cards {
        // Skip items until we reach offset
        if skipped < offset {
            skipped += 1;
            continue;
        }

        // Stop when we've collected enough
        if count >= limit {
            break;
        }

        let title_no = element_attr(card, "data-title-no");
        if title_no == () || title_no == "" {
            continue;
        }

        // Skip duplicates
        if seen_ids[title_no] != () {
            continue;
        }
        seen_ids[title_no] = true;

        let href = element_attr(card, "href");
        let full_url = "";
        if href != () && href != "" {
            full_url = make_full_url(href);
        }

        // Get title - simplified extraction
        let title = "";
        let title_els = html_select(card, "strong.title, p.subj");
        if title_els.len() > 0 {
            title = element_text(title_els[0]).trim();
        }
        if title == "" {
            title = `Webtoon #${title_no}`;
        }

        // Get cover from first img
        let cover_url = ();
        let imgs = html_select(card, "img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
        }

        let series_id = if full_url != "" { full_url } else { title_no };

        series.push(#{
            id: series_id,
            title: title,
            url: if full_url != "" { full_url } else { `${BASE_URL}/en/originals/series?title_no=${title_no}` },
            cover_url: cover_url,
            authors: [],
            artists: [],
            genres: [],
            tags: ["webtoon"],
            status: (),
            content_rating: "safe",
            updated_at: ()
        });

        count += 1;
    }

    #{ series: series, seen_ids: seen_ids }
}

/// Helper function to parse Webtoon cards from HTML - returns result map
fn parse_webtoon_cards(html) {
    let series = [];
    let seen_ids = #{};

    // Get originals title cards - use multiple selector patterns
    let cards = html_select(html, "a._originals_title_a[data-title-no], a._card_item[data-title-no], a[data-title-no]");

    for card in cards {
        let title_no = element_attr(card, "data-title-no");
        if title_no == () || title_no == "" {
            continue;
        }

        // Skip duplicates
        if seen_ids[title_no] != () {
            continue;
        }
        seen_ids[title_no] = true;

        let href = element_attr(card, "href");

        // Make full URL - this is critical for get_series/get_chapters to work
        let full_url = "";
        if href != () && href != "" {
            full_url = make_full_url(href);
        }

        // Get title
        let title = "";
        let title_els = html_select(card, "strong.title, p.subj, .info .subj");
        if title_els.len() > 0 {
            title = element_text(title_els[0]).trim();
        }

        if title == "" {
            title = `Webtoon #${title_no}`;
        }

        // Get cover
        let cover_url = ();
        let imgs = html_select(card, "img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
            if cover_url == () {
                cover_url = element_attr(imgs[0], "data-src");
            }
        }

        // Get genre
        let genres = [];
        let genre_els = html_select(card, "div.genre, .genre");
        if genre_els.len() > 0 {
            let genre = element_text(genre_els[0]).trim();
            if genre != "" {
                genres.push(genre);
            }
        }

        // Extract genre from URL path (e.g., /en/action/teenage-mercenary/)
        if genres.len() == 0 && href != () {
            let url_parts = href.split("/");
            for i in 0..url_parts.len() {
                if url_parts[i] == "en" && i + 1 < url_parts.len() {
                    let genre_slug = url_parts[i + 1];
                    // Capitalize first letter
                    if genre_slug != "" && genre_slug != "originals" && genre_slug != "genre" {
                        let first_char = genre_slug.sub_string(0, 1).to_upper();
                        let rest = genre_slug.sub_string(1);
                        genres.push(first_char + rest);
                    }
                    break;
                }
            }
        }

        // Check content rating from data attribute
        let content_rating = "safe";
        let image_wrap = html_select(card, ".image_wrap");
        if image_wrap.len() > 0 {
            let unsuitable = element_attr(image_wrap[0], "data-title-unsuitable-for-children");
            if unsuitable == "true" {
                content_rating = "suggestive";
            }
        }

        // Use full URL as the ID so get_series/get_chapters can work properly
        // Webtoon requires the full path with genre/slug to fetch series data
        let series_id = if full_url != "" { full_url } else { title_no };

        // Bound the result. Webtoon's broad title-anchor selector can match
        // hundreds of unique series on a single page, and a very large result
        // array overflows the Rhai→Rust conversion (the connector was hard-down
        // with "Stack overflow" whenever the page was large). Browse paginates,
        // so a per-page cap costs no coverage.
        if series.len() >= 100 { break; }
        series.push(#{
            id: series_id,
            title: title,
            url: if full_url != "" { full_url } else { `${BASE_URL}/en/originals/series?title_no=${title_no}` },
            cover_url: cover_url,
            authors: [],
            artists: [],
            genres: genres,
            tags: ["webtoon", "originals"],
            status: "Ongoing",
            content_rating: content_rating,
            updated_at: ()
        });
    }

    #{ series: series, seen_ids: seen_ids }
}

/// Get popular series
fn get_popular(page, auth) {
    // Popular/top page only has one page of content
    if page > 1 {
        return #{ series: [], has_more: false };
    }

    let url = `${BASE_URL}/en/top`;

    let html = safe_get(url);

    let series = [];
    let seen_ids = #{};

    // Get top ranking cards
    let cards = html_select(html, ".lst_area li a, .top_lst li a, .ranking_lst li a, a[data-title-no]");

    for card in cards {
        let href = element_attr(card, "href");
        if href == () || href == "" {
            continue;
        }

        let title_no = extract_title_no(href);
        if title_no == "" {
            title_no = element_attr(card, "data-title-no");
        }
        if title_no == "" || title_no == () {
            continue;
        }

        // Skip duplicates
        if seen_ids[title_no] != () {
            continue;
        }
        seen_ids[title_no] = true;

        // Get title
        let title = "";
        let title_els = html_select(card, "p.subj, .info .subj, strong.title");
        if title_els.len() > 0 {
            title = element_text(title_els[0]).trim();
        }

        if title == "" {
            continue;
        }

        // Get cover
        let cover_url = ();
        let imgs = html_select(card, "img");
        if imgs.len() > 0 {
            cover_url = element_attr(imgs[0], "src");
            if cover_url == () {
                cover_url = element_attr(imgs[0], "data-src");
            }
        }

        let full_url = make_full_url(href);

        series.push(#{
            id: full_url,
            title: title,
            url: full_url,
            cover_url: cover_url,
            authors: [],
            artists: [],
            genres: [],
            tags: ["webtoon", "popular"],
            status: "Ongoing"
        });
    }

    // Popular page doesn't have multiple pages
    let has_more = false;

    #{ series: series, has_more: has_more }
}

// === Helper Functions ===

/// Extract title_no from Webtoon URL
fn extract_title_no(url) {
    // Pattern: title_no=12345
    if url.contains("title_no=") {
        let parts = url.split("title_no=");
        if parts.len() > 1 {
            let num = parts[1].split("&")[0];
            return num;
        }
    }

    // Pattern: /title/12345/
    if url.contains("/title/") {
        let parts = url.split("/title/");
        if parts.len() > 1 {
            let segment = parts[1].split("/")[0];
            return segment;
        }
    }

    ""
}

/// Extract episode_no from Webtoon URL
fn extract_episode_no(url) {
    // Pattern: episode_no=12345
    if url.contains("episode_no=") {
        let parts = url.split("episode_no=");
        if parts.len() > 1 {
            let num = parts[1].split("&")[0];
            return num;
        }
    }

    // Pattern: /episode/12345/
    if url.contains("/episode/") {
        let parts = url.split("/episode/");
        if parts.len() > 1 {
            let segment = parts[1].split("/")[0];
            return segment;
        }
    }

    ""
}

/// Extract just numbers from text like "Ep. 123" -> "123"
fn extract_number_from_text(text) {
    let num = "";
    let found_num = false;

    for c in text.chars() {
        if c >= '0' && c <= '9' {
            num += c;
            found_num = true;
        } else if found_num && c != '.' {
            // Stop at first non-digit after finding numbers (except decimal)
            break;
        } else if c == '.' && found_num {
            num += c;
        }
    }

    num
}

/// Make URL absolute if relative
fn make_full_url(url) {
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
