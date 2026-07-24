// Dynasty Scans Scraper Add-on (Rhai)
// HTTP-based scraper for dynasty-scans.com
// Features yuri/shoujo-ai manga, doujins, anthologies, and original series
//
// Available APIs:
//   HTTP: http_get(url), http_get_with_headers(url, headers)
//   HTML: html_parse(html), html_select(html, selector), element_text(el), element_attr(el, attr)
//   JSON: json_parse(text)
//   Regex: regex_find(pattern, text), regex_find_all(pattern, text)
//   url_encode(text) -> string

const BASE_URL = "https://dynasty-scans.com";

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "dynastyscans-rhai",
        name: "Dynasty Scans",
        base_url: BASE_URL,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only"
    }
}

/// Get headers for requests
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Wrap http_get_with_headers so a transient network exception falls through
/// to "" and downstream html_select / json_parse see "no data" rather than
/// crashing the entire search/browse/series fetch.
fn safe_get(url) {
    try {
        return http_get_with_headers(url, get_headers());
    } catch {
        return "";
    }
}

/// Search for series matching query
/// Dynasty Scans search - searches for Series, Doujins, and Anthologies only
/// Note: Search results on Dynasty Scans do not include cover images
fn search_series(query, page, auth) {
    let encoded_query = url_encode(query);
    // Search for Series, Doujins, and Anthologies only (not chapters)
    let url = `${BASE_URL}/search?q=${encoded_query}&page=${page}&classes[]=Series&classes[]=Doujin&classes[]=Anthology`;

    let html = safe_get(url);

    let series = [];
    let seen = #{};

    // Search results are in <dl class="chapter-list"> with <dd> items
    let items = html_select(html, "dl.chapter-list dd");

    for item in items {
        // Get the main link
        let links = html_select(item, "a.name");
        if links.len() == 0 {
            continue;
        }

        let link = links[0];
        let href = element_attr(link, "href");
        let title = element_text(link).trim();

        if href == () || href == "" || title == "" {
            continue;
        }

        // Extract series ID based on URL type
        let series_id = "";
        let series_url = "";

        if href.contains("/series/") || href.contains("/doujins/") || href.contains("/anthologies/") {
            series_id = extract_series_id(href);
            series_url = make_full_url(href);
        }

        if series_id == "" {
            continue;
        }

        // Skip duplicates
        if seen[series_id] != () {
            continue;
        }
        seen[series_id] = true;

        // Get tags
        let tags = [];
        let tag_links = html_select(item, "span.tags a");
        for tag_el in tag_links {
            let tag = element_text(tag_el).trim();
            if tag != "" && !tags.contains(tag) {
                tags.push(tag);
            }
        }

        // Get author if available
        let authors = [];
        let author_links = html_select(item, "a[href*='/authors/']");
        for author_el in author_links {
            let author = element_text(author_el).trim();
            if author != "" && !authors.contains(author) {
                authors.push(author);
            }
        }

        // Note: Dynasty Scans search results don't include cover images
        // Covers are fetched when viewing series details
        series.push(#{
            id: series_id,
            title: title,
            url: series_url,
            cover_url: (),
            alternate_titles: [],
            authors: authors,
            artists: [],
            status: (),
            genres: [],
            tags: tags,
            description: ()
        });
    }

    // Check for next page
    let has_more = false;
    let pagers = html_select(html, "div.pagination a, ul.pagination li a");
    for pager in pagers {
        let rel = element_attr(pager, "rel");
        if rel == "next" {
            has_more = true;
            break;
        }
        let text = element_text(pager).trim();
        if text == ">" || text == "Next" || text.contains("Next") {
            has_more = true;
            break;
        }
    }

    #{ series: series, has_more: has_more, total: () }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let url = id_or_url;
    let series_id = id_or_url;
    let is_chapter_page = false;

    if !id_or_url.starts_with("http") {
        // Determine type from ID prefix
        if id_or_url.starts_with("doujin:") {
            let slug = id_or_url.replace("doujin:", "");
            url = `${BASE_URL}/doujins/${slug}`;
        } else if id_or_url.starts_with("anthology:") {
            let slug = id_or_url.replace("anthology:", "");
            url = `${BASE_URL}/anthologies/${slug}`;
        } else if id_or_url.starts_with("chapter:") {
            // One-shot chapter
            let slug = id_or_url.replace("chapter:", "");
            url = `${BASE_URL}/chapters/${slug}`;
            is_chapter_page = true;
        } else {
            url = `${BASE_URL}/series/${id_or_url}`;
        }
    } else {
        series_id = extract_series_id(id_or_url);
        if id_or_url.contains("/chapters/") {
            is_chapter_page = true;
        }
    }

    let html = safe_get(url);

    // For chapter pages, try to find parent series and redirect
    if is_chapter_page {
        let parent_links = html_select(html, "h3#chapter-title a[href*='/series/'], h3#chapter-title a[href*='/doujins/'], h3#chapter-title a[href*='/anthologies/']");
        if parent_links.len() > 0 {
            let parent_href = element_attr(parent_links[0], "href");
            if parent_href != () && parent_href != "" {
                // Recursively get the parent series
                let parent_url = make_full_url(parent_href);
                return get_series(parent_url, auth);
            }
        }
    }

    // Extract title - different selectors for different page types
    let title = "";

    // Try series/doujin/anthology page selectors - get just the <b> tag text
    let title_els = html_select(html, "h2.tag-title b");
    if title_els.len() > 0 {
        title = element_text(title_els[0]).trim();
    }

    // Fallback: try h1 for other page types
    if title == "" {
        let h1_els = html_select(html, "h1");
        if h1_els.len() > 0 {
            title = element_text(h1_els[0]).trim();
        }
    }

    // Fallback for chapter pages (one-shots without parent series)
    if title == "" {
        let chapter_title_els = html_select(html, "h3#chapter-title b");
        if chapter_title_els.len() > 0 {
            title = element_text(chapter_title_els[0]).trim();
            // Remove author portion if present (after " by ")
            if title.contains(" by ") {
                let parts = title.split(" by ");
                title = parts[0].trim();
            }
        }
    }

    // Last resort: use page title
    if title == "" {
        let page_title_els = html_select(html, "title");
        if page_title_els.len() > 0 {
            title = element_text(page_title_els[0]).trim();
            // Remove "Dynasty Reader » " prefix
            if title.starts_with("Dynasty Reader") {
                title = title.replace("Dynasty Reader »", "").replace("Dynasty Reader", "").trim();
            }
        }
    }

    // Extract alternate titles (shown in parentheses or as aliases)
    let alt_titles = [];
    let alias_els = html_select(html, "span.aliases");
    for el in alias_els {
        let alias_text = element_text(el).trim();
        // Clean up aliases - may be comma-separated or in parentheses
        alias_text = alias_text.replace("(", "").replace(")", "");
        let parts = alias_text.split(",");
        for part in parts {
            let cleaned = part.trim();
            // Skip empty, same as title, or status-like text
            if cleaned != "" && cleaned != title && !alt_titles.contains(cleaned) {
                let lower = cleaned.to_lower();
                if !lower.contains("ongoing") && !lower.contains("completed") &&
                   !lower.contains("licensed") && !lower.contains("hiatus") && cleaned != "—" {
                    alt_titles.push(cleaned);
                }
            }
        }
    }

    // Extract cover image
    let cover_url = ();
    let cover_els = html_select(html, "img.cover, .tag-cover img, div.cover img");
    if cover_els.len() > 0 {
        cover_url = element_attr(cover_els[0], "src");
        if cover_url != () && cover_url != "" {
            cover_url = make_full_url(cover_url);
        }
    }

    // Extract description
    let description = ();
    let desc_els = html_select(html, "div.description, p.description, .tag-description");
    if desc_els.len() > 0 {
        description = element_text(desc_els[0]).trim();
        if description == "" {
            description = ();
        }
    }

    // Extract authors
    let authors = [];
    let author_els = html_select(html, "a[href*='/authors/']");
    for el in author_els {
        let author = element_text(el).trim();
        if author != "" && !authors.contains(author) {
            authors.push(author);
        }
    }

    // Extract artists
    let artists = [];
    let artist_els = html_select(html, "a[href*='/artists/']");
    for el in artist_els {
        let artist = element_text(el).trim();
        if artist != "" && !artists.contains(artist) {
            artists.push(artist);
        }
    }

    // Extract tags/genres
    let tags = [];
    let genres = [];
    let tag_els = html_select(html, "a[href*='/tags/'], span.tags a");
    for el in tag_els {
        let tag = element_text(el).trim();
        if tag != "" && !tags.contains(tag) {
            // Common genre tags
            if tag == "Yuri" || tag == "Romance" || tag == "Comedy" || tag == "Drama" ||
               tag == "Action" || tag == "Fantasy" || tag == "Slice of Life" || tag == "Horror" ||
               tag == "Sci-Fi" || tag == "School Life" || tag == "Supernatural" {
                if !genres.contains(tag) {
                    genres.push(tag);
                }
            } else {
                tags.push(tag);
            }
        }
    }

    // Extract status (completed/ongoing)
    let status = ();
    let status_els = html_select(html, "span.status, .tag-status");
    if status_els.len() > 0 {
        let status_text = element_text(status_els[0]).to_lower();
        if status_text.contains("completed") || status_text.contains("complete") {
            status = "Completed";
        } else if status_text.contains("ongoing") {
            status = "Ongoing";
        } else if status_text.contains("licensed") {
            status = "Licensed";
        }
    }

    // Check for "Completed" in tags as well
    for tag in tags {
        if tag.to_lower() == "completed" {
            status = "Completed";
            break;
        }
    }

    // Extract pairing tags
    let pairings = [];
    let pairing_els = html_select(html, "a[href*='/pairings/']");
    for el in pairing_els {
        let pairing = element_text(el).trim();
        if pairing != "" && !pairings.contains(pairing) {
            pairings.push(pairing);
        }
    }

    #{
        id: series_id,
        title: title,
        alternate_titles: alt_titles,
        description: description,
        cover_url: cover_url,
        authors: authors,
        artists: artists,
        status: status,
        genres: genres,
        tags: tags,
        year: (),
        content_rating: "suggestive",
        url: url,
        extra: #{
            pairings: pairings,
            auto_match_metadata: true,
            source_name: "Dynasty Scans"
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let url = series_id;

    if !series_id.starts_with("http") {
        if series_id.starts_with("doujin:") {
            let slug = series_id.replace("doujin:", "");
            url = `${BASE_URL}/doujins/${slug}`;
        } else if series_id.starts_with("anthology:") {
            let slug = series_id.replace("anthology:", "");
            url = `${BASE_URL}/anthologies/${slug}`;
        } else if series_id.starts_with("chapter:") {
            // One-shot - the chapter IS the series
            let slug = series_id.replace("chapter:", "");
            return [#{
                id: `${BASE_URL}/chapters/${slug}`,
                series_id: series_id,
                number: "1",
                title: (),
                volume: (),
                language: "en",
                scanlator: (),
                url: `${BASE_URL}/chapters/${slug}`,
                published_at: (),
                page_count: (),
                extra: #{}
            }];
        } else {
            url = `${BASE_URL}/series/${series_id}`;
        }
    }

    let html = safe_get(url);

    let chapters = [];
    let seen = #{};

    // Chapters are listed in dl.chapter-list with dd items
    let chapter_items = html_select(html, "dl.chapter-list dd");

    for item in chapter_items {
        let links = html_select(item, "a.name");
        if links.len() == 0 {
            continue;
        }

        let link = links[0];
        let href = element_attr(link, "href");
        let chapter_title = element_text(link).trim();

        if href == () || href == "" || !href.contains("/chapters/") {
            continue;
        }

        // Skip duplicates
        if seen[href] != () {
            continue;
        }
        seen[href] = true;

        let chapter_id = extract_chapter_id(href);
        let chapter_url = make_full_url(href);

        // Extract chapter number from title
        // Format: "Series Name chXX: Title" or just "Chapter XX" or "XX. Title"
        let number = extract_chapter_number(chapter_title);

        // Get title after the chapter number
        let title = extract_chapter_title(chapter_title);

        // Get release date
        let published_at = ();
        let date_els = html_select(item, "small, time, span.released, .date");
        if date_els.len() > 0 {
            published_at = element_text(date_els[date_els.len() - 1]).trim();
        }

        // Get scanlator
        let scanlator = ();
        let scanlator_els = html_select(item, "a[href*='/scanlators/']");
        if scanlator_els.len() > 0 {
            scanlator = element_text(scanlator_els[0]).trim();
        }

        // Get tags for this chapter
        let chapter_tags = [];
        let tag_els = html_select(item, "span.tags a");
        for tag_el in tag_els {
            let tag = element_text(tag_el).trim();
            if tag != "" && !chapter_tags.contains(tag) {
                chapter_tags.push(tag);
            }
        }

        chapters.push(#{
            id: chapter_url,
            series_id: series_id,
            number: number,
            title: title,
            volume: (),
            language: "en",
            scanlator: scanlator,
            url: chapter_url,
            published_at: published_at,
            page_count: (),
            extra: #{
                tags: chapter_tags
            }
        });
    }

    // Sort chapters by number (newest first is typical)
    // Note: Rhai doesn't have built-in sort, so we return in page order

    chapters
}

/// Get page URLs for a chapter
fn get_chapter_pages(chapter_id, auth) {
    let url = chapter_id;

    if !chapter_id.starts_with("http") {
        url = `${BASE_URL}/chapters/${chapter_id}`;
    }

    let html = safe_get(url);

    let pages = [];

    // Dynasty Scans stores page data in a JavaScript array
    // Look for: var pages = [{...}, {...}];
    // or: pages = [{image: "/system/releases/...", name: "01.webp"}, ...]

    // Find the pages array in script
    let pages_match = regex_find(`pages\s*=\s*\[([^\]]+)\]`, html);

    if pages_match != () && pages_match != "" {
        // Parse the JavaScript array manually
        // Format: {image: "/path", name: "01.webp"}, {...}

        // Find all image paths
        let image_matches = regex_find_all(`"image"\s*:\s*"([^"]+)"`, html);

        if image_matches.len() == 0 {
            // Try alternate format with single quotes
            image_matches = regex_find_all(`'image'\s*:\s*'([^']+)'`, html);
        }

        if image_matches.len() == 0 {
            // Try format without quotes on key
            image_matches = regex_find_all(`image:\s*["']([^"']+)["']`, html);
        }

        let idx = 0;
        for img_match in image_matches {
            // Clean up the match - remove all quote characters and key prefix
            let img_url = img_match;
            // Remove various "image": prefixes
            img_url = img_url.replace(`"image": `, "").replace(`"image":`, "");
            img_url = img_url.replace(`'image': `, "").replace(`'image':`, "");
            img_url = img_url.replace(`image: `, "").replace(`image:`, "");
            // Remove all quote characters
            img_url = img_url.replace(`"`, "").replace(`'`, "").trim();

            if img_url != () && img_url != "" && img_url.starts_with("/") {
                let full_url = make_full_url(img_url);
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
    }

    // Fallback: Try to find images directly in reader container
    if pages.len() == 0 {
        let img_els = html_select(html, "div#image img, img.page-image, div.reader img, #reader img");
        let idx = 0;

        for img in img_els {
            let img_url = element_attr(img, "src");
            if img_url == () || img_url == "" {
                img_url = element_attr(img, "data-src");
            }

            if img_url != () && img_url != "" && is_valid_page_url(img_url) {
                pages.push(#{
                    index: idx,
                    url: make_full_url(img_url),
                    headers: #{
                        "Referer": url
                    },
                    referer: url
                });
                idx += 1;
            }
        }
    }

    // Another fallback: Parse JSON from script tag
    if pages.len() == 0 {
        // Look for system/releases paths
        let release_matches = regex_find_all(`/system/releases/[^"'\s]+\.(webp|jpg|jpeg|png)`, html);

        let idx = 0;
        let seen_urls = #{};

        for img_path in release_matches {
            if seen_urls.contains(img_path) {
                continue;
            }
            seen_urls[img_path] = true;

            pages.push(#{
                index: idx,
                url: make_full_url(img_path),
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

/// Browse the catalog - uses latest updates which has cover images
/// Dynasty Scans series directory doesn't show cover thumbnails,
/// so we use the homepage/latest updates which has proper thumbnails
fn browse(page, filters, auth) {
    // Extract category from filters if provided
    let category = "latest";
    if filters != () {
        if filters.contains("category") {
            category = filters["category"];
        }
    }

    // Use latest updates as the default browse view since it has cover images
    // The series directory (get_popular) doesn't have cover thumbnails
    if category == "popular" {
        return get_popular(page, auth);
    }

    // Default to latest updates which has cover images
    return get_latest_updates(page, auth);
}

/// Get latest updates
fn get_latest_updates(page, auth) {
    let url = `${BASE_URL}/?page=${page}`;

    let html = safe_get(url);

    let series = [];
    let seen = #{};

    // Latest chapters are in a.chapter.media.thumbnail links
    let items = html_select(html, "a.chapter.media.thumbnail");

    for item in items {
        // The item itself is the link (a.chapter.media.thumbnail)
        let href = element_attr(item, "href");

        if href == () || href == "" {
            continue;
        }

        // Get title from div.title (e.g., "Your Scent is a Little Sweet ch62")
        let full_title = "";
        let title_els = html_select(item, "div.title");
        if title_els.len() > 0 {
            full_title = element_text(title_els[0]).trim();
        }

        if full_title == "" {
            continue;
        }

        // Extract series title by removing chapter number suffix
        // Patterns: "Series Name ch62", "Series Name ch7.2", "Series Name"
        let series_title = extract_series_title_from_chapter(full_title);

        // Skip duplicates by series title (not chapter)
        if seen[series_title] != () {
            continue;
        }
        seen[series_title] = true;

        // Use chapter ID - get_series will redirect to parent series
        let series_id = "chapter:" + extract_chapter_id(href);
        let series_url = make_full_url(href);

        // Get cover - check both src and data-src for lazy loading
        let cover_url = ();
        let imgs = html_select(item, "img");
        if imgs.len() > 0 {
            // Try src first
            cover_url = element_attr(imgs[0], "src");

            // Fallback to data-src for lazy loaded images
            if cover_url == () || cover_url == "" || cover_url.contains("blank.gif") || cover_url.contains("placeholder") {
                cover_url = element_attr(imgs[0], "data-src");
            }

            // Also try data-original
            if cover_url == () || cover_url == "" {
                cover_url = element_attr(imgs[0], "data-original");
            }

            if cover_url != () && cover_url != "" {
                cover_url = make_full_url(cover_url);
            }
        }

        series.push(#{
            id: series_id,
            title: series_title,
            url: series_url,
            cover_url: cover_url
        });
    }

    // Check for next page
    let has_more = false;
    let pagers = html_select(html, "div.pagination a, ul.pagination li a");
    for pager in pagers {
        let rel = element_attr(pager, "rel");
        if rel == "next" {
            has_more = true;
            break;
        }
    }

    #{ series: series, has_more: has_more }
}

/// Get popular series (browse series directory)
fn get_popular(page, auth) {
    let url = `${BASE_URL}/series?page=${page}`;

    let html = safe_get(url);

    let series = [];

    // Series directory lists series as links
    let series_links = html_select(html, "ul.tag-list li a, dd a[href*='/series/']");

    for link in series_links {
        let href = element_attr(link, "href");
        let title = element_text(link).trim();

        if href == () || href == "" || title == "" {
            continue;
        }

        if !href.contains("/series/") {
            continue;
        }

        let series_id = extract_series_id(href);
        if series_id == "" {
            continue;
        }

        series.push(#{
            id: series_id,
            title: title,
            url: make_full_url(href),
            cover_url: ()
        });
    }

    // Check for next page
    let has_more = false;
    let pagers = html_select(html, "div.pagination a, ul.pagination li a");
    for pager in pagers {
        let rel = element_attr(pager, "rel");
        if rel == "next" {
            has_more = true;
            break;
        }
    }

    #{ series: series, has_more: has_more }
}

// === Helper Functions ===

/// Extract series ID from URL
fn extract_series_id(url) {
    // URL patterns:
    // /series/slug
    // /doujins/slug
    // /anthologies/slug

    if url.contains("/series/") {
        let parts = url.split("/series/");
        if parts.len() > 1 {
            let id_part = parts[1].split("/")[0].split("?")[0];
            return id_part;
        }
    }

    if url.contains("/doujins/") {
        let parts = url.split("/doujins/");
        if parts.len() > 1 {
            let id_part = parts[1].split("/")[0].split("?")[0];
            return "doujin:" + id_part;
        }
    }

    if url.contains("/anthologies/") {
        let parts = url.split("/anthologies/");
        if parts.len() > 1 {
            let id_part = parts[1].split("/")[0].split("?")[0];
            return "anthology:" + id_part;
        }
    }

    ""
}

/// Extract chapter ID from URL
fn extract_chapter_id(url) {
    // URL pattern: /chapters/slug

    if url.contains("/chapters/") {
        let parts = url.split("/chapters/");
        if parts.len() > 1 {
            let id_part = parts[1].split("/")[0].split("?")[0];
            return id_part;
        }
    }

    url
}

/// Extract chapter number from title
fn extract_chapter_number(title) {
    // Patterns:
    // "Series Name ch01: Title"
    // "Series Name ch01"
    // "Chapter 1: Title"
    // "Chapter 1"
    // "01. Title"

    let title_lower = title.to_lower();

    // Try "chXX" pattern
    let ch_match = regex_find(`ch(\d+(?:\.\d+)?)`, title_lower);
    if ch_match != () && ch_match != "" {
        let num = ch_match.replace("ch", "");
        if num != "" {
            return num;
        }
    }

    // Try "chapter XX" pattern
    if title_lower.contains("chapter") {
        let parts = title_lower.split("chapter");
        if parts.len() > 1 {
            let after = parts[1].trim();
            let num = "";
            for c in after.chars() {
                if c >= '0' && c <= '9' || c == '.' {
                    num += c;
                } else if num.len() > 0 {
                    break;
                }
            }
            if num != "" {
                return num;
            }
        }
    }

    // Try leading number pattern "01. Title"
    let leading_match = regex_find(`^(\d+(?:\.\d+)?)\s*[.:\-]`, title);
    if leading_match != () && leading_match != "" {
        let num = "";
        for c in leading_match.chars() {
            if c >= '0' && c <= '9' || c == '.' {
                num += c;
            } else {
                break;
            }
        }
        if num != "" {
            return num;
        }
    }

    // Default to "1" for chapters without numbers
    "1"
}

/// Extract chapter title (part after chapter number)
fn extract_chapter_title(full_title) {
    // Try to extract title after ": " or " - "
    if full_title.contains(": ") {
        let parts = full_title.split(": ");
        if parts.len() > 1 {
            // Return everything after the first colon
            let title = "";
            for i in 1..parts.len() {
                if title != "" {
                    title += ": ";
                }
                title += parts[i];
            }
            return title.trim();
        }
    }

    if full_title.contains(" - ") {
        let parts = full_title.split(" - ");
        if parts.len() > 1 {
            return parts[parts.len() - 1].trim();
        }
    }

    ()
}

/// Extract series title from a chapter title
/// "Your Scent is a Little Sweet ch62" -> "Your Scent is a Little Sweet"
/// "Bloom Into You ch01" -> "Bloom Into You"
/// "One-shot Title" -> "One-shot Title"
fn extract_series_title_from_chapter(chapter_title) {
    let title = chapter_title;

    // Try to find " chXX" pattern and remove it
    let ch_match = regex_find(` ch\d+(?:\.\d+)?(?:$|:)`, title);
    if ch_match != () && ch_match != "" {
        // Find position and cut
        let parts = title.split(" ch");
        if parts.len() > 1 {
            // Rebuild without the last ch part
            let result = parts[0];
            // If there were multiple " ch" occurrences, rejoin all but last
            for i in 1..(parts.len() - 1) {
                result += " ch" + parts[i];
            }
            return result.trim();
        }
    }

    // Try " Chapter XX" pattern
    if title.to_lower().contains(" chapter ") {
        let lower = title.to_lower();
        let idx = lower.index_of(" chapter ");
        if idx != () && idx > 0 {
            return title.sub_string(0, idx).trim();
        }
    }

    // No chapter number found, return as-is
    title
}

/// Check if URL is a valid page image
fn is_valid_page_url(url) {
    let url_lower = url.to_lower();

    // Skip common non-page images
    if url_lower.contains("logo") { return false; }
    if url_lower.contains("icon") { return false; }
    if url_lower.contains("avatar") { return false; }
    if url_lower.contains("banner") { return false; }
    if url_lower.contains("thumb") { return false; }
    if url_lower.contains("cover") { return false; }

    // Must be an image
    if url_lower.contains(".jpg") || url_lower.contains(".jpeg") ||
       url_lower.contains(".png") || url_lower.contains(".webp") ||
       url_lower.contains(".gif") {
        return true;
    }

    // Dynasty uses /system/releases/ for pages
    if url_lower.contains("/system/releases/") {
        return true;
    }

    false
}

/// Make URL absolute
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
