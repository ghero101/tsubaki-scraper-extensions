// FanFox (MangaFox) Scraper Add-on (Rhai)
// HTTP-only scraper for fanfox.net
// Uses the mobile site (m.fanfox.net) for simpler HTML where needed
//
// URL Patterns:
//   Search:  https://fanfox.net/search?title={query}&page={page}
//   Manga:   https://fanfox.net/manga/{slug}/
//   Chapter: https://fanfox.net/manga/{slug}/c{number}/1.html
//   Mobile chapter: https://m.fanfox.net/roll_manga/{slug}/c{number}/1.html
//   Cover:   https://fmcdn.mfcdn.net/store/manga/{id}/cover.jpg
//   Browse:  https://fanfox.net/directory/{page}.htm
//
// Available APIs:
//   HTTP: http_get(url), http_get_with_headers(url, headers)
//   HTML: html_parse(html), html_select(html, selector), html_select_first(html, selector)
//         element_text(el), element_attr(el, attr), element_select(el, selector)
//         element_select_first(el, selector)
//   JSON: json_parse(text)
//   Regex: regex_find(pattern, text), regex_find_all(pattern, text)
//   String: url_encode(text)

const BASE_URL = "https://fanfox.net";
const MOBILE_URL = "https://m.fanfox.net";
const CDN_URL = "https://fmcdn.mfcdn.net";

// ============================================================================
// Helper Functions
// ============================================================================

/// Get headers for desktop requests
fn get_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": BASE_URL
    }
}

/// Get headers for mobile requests
fn get_mobile_headers() {
    #{
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": MOBILE_URL
    }
}

/// Detect a Cloudflare error/challenge interstitial rather than real content.
/// fanfox.net itself is up, but its Cloudflare returns a 520 "origin web server
/// returned an invalid or incomplete response" (and sometimes a JS challenge /
/// 1020 block) to datacenter/CGNAT egress IPs. Treating that HTML as a valid
/// page is why search/series silently broke — we must fall through to a tier
/// that can clear it (FlareSolverr).
fn is_cf_block(html) {
    if html == () || html == "" { return true; }
    if html.contains("origin web server returned an invalid") { return true; } // 520
    if html.contains("Web server is returning an unknown error") { return true; } // 520/521
    if html.contains("Checking your browser") || html.contains("Just a moment") { return true; } // JS challenge
    if html.contains("Attention Required") && html.contains("Cloudflare") { return true; } // 1020 block
    if html.contains("cf-error-details") || html.contains("error-1016") || html.contains("error-1020") { return true; }
    false
}

/// Fetch HTML with desktop headers. Tiers: TLS-impersonated HTTP → plain reqwest
/// (fanfox's CDN rejects requests without a Referer) → FlareSolverr. The
/// FlareSolverr tier renders via headless Chrome (and the configured
/// residential proxy/VPN) and is the documented remedy when fanfox's Cloudflare
/// serves a 520 / challenge to the server's datacenter egress IP.
fn fetch_html(url) {
    try {
        let html = http_get_with_headers(url, get_headers());
        if !is_cf_block(html) { return html; }
    } catch {}
    try {
        let html = http_get_plain(url, get_headers());
        if !is_cf_block(html) { return html; }
    } catch {}
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 40000);
            if !is_cf_block(html) { return html; }
        } catch {}
    }
    ""
}

/// Fetch HTML with mobile headers. Same tiered fallback shape as fetch_html.
fn fetch_mobile_html(url) {
    try {
        let html = http_get_with_headers(url, get_mobile_headers());
        if !is_cf_block(html) { return html; }
    } catch {}
    try {
        let html = http_get_plain(url, get_mobile_headers());
        if !is_cf_block(html) { return html; }
    } catch {}
    if flaresolverr_is_available() {
        try {
            let html = flaresolverr_get(url, 40000);
            if !is_cf_block(html) { return html; }
        } catch {}
    }
    ""
}

/// Extract manga slug from URL
/// URL format: /manga/{slug}/ or https://fanfox.net/manga/{slug}/
fn extract_slug(url) {
    let parts = url.split("/manga/");
    if parts.len() > 1 {
        let after = parts[1];
        let slug_parts = after.split("/");
        if slug_parts.len() > 0 && slug_parts[0] != "" {
            return slug_parts[0];
        }
    }
    ""
}

/// Extract chapter number from URL
/// URL format: /manga/{slug}/c{number}/1.html or /manga/{slug}/v{vol}/c{number}/
fn extract_chapter_number(url) {
    // Try /c{number}/ pattern
    let ch_match = regex_find("/c([0-9]+\\.?[0-9]*)/", url);
    if ch_match != () && ch_match != "" {
        let num = ch_match.replace("/c", "").replace("/", "");
        if num != "" {
            return num;
        }
    }
    // Try /c{number}.html pattern
    let ch_match2 = regex_find("/c([0-9]+\\.?[0-9]*)\\.html", url);
    if ch_match2 != () && ch_match2 != "" {
        let num = regex_find("[0-9]+\\.?[0-9]*", ch_match2);
        if num != () && num != "" {
            return num;
        }
    }
    "0"
}

/// Extract volume number from URL
fn extract_volume_number(url) {
    let vol_match = regex_find("/v([0-9]+)/", url);
    if vol_match != () && vol_match != "" {
        let num = vol_match.replace("/v", "").replace("/", "");
        return num;
    }
    ()
}

/// Map status text to standard format
fn map_status(status_text) {
    if status_text == () || status_text == "" {
        return ();
    }
    let lower = status_text.to_lower();
    if lower.contains("completed") || lower.contains("complete") {
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

/// Clean text by removing extra whitespace
fn clean_text(text) {
    let cleaned = text.trim();
    while cleaned.contains("  ") {
        cleaned = cleaned.replace("  ", " ");
    }
    while cleaned.contains("\n\n") {
        cleaned = cleaned.replace("\n\n", "\n");
    }
    cleaned.trim()
}

/// Build a compound chapter ID from slug and chapter number
/// Format: {slug}|c{number}
fn build_chapter_id(slug, chapter_num) {
    `${slug}|c${chapter_num}`
}

/// Parse a compound chapter ID back into slug and chapter number
/// Format: {slug}|c{number}
fn parse_chapter_id(chapter_id) {
    let parts = chapter_id.split("|c");
    if parts.len() >= 2 {
        return #{
            slug: parts[0],
            number: parts[1]
        };
    }
    // Try alternate split on |
    let parts2 = chapter_id.split("|");
    if parts2.len() >= 2 {
        let num = parts2[1].replace("c", "");
        return #{
            slug: parts2[0],
            number: num
        };
    }
    // Fallback: treat entire ID as a URL path
    let slug = extract_slug(chapter_id);
    let num = extract_chapter_number(chapter_id);
    #{
        slug: slug,
        number: num
    }
}

/// Make a URL absolute if it is relative
fn make_absolute(url) {
    if url.starts_with("http") {
        return url;
    }
    if url.starts_with("//") {
        return `https:${url}`;
    }
    `${BASE_URL}${url}`
}

// ============================================================================
// Required Interface Functions
// ============================================================================

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "fanfox",
        name: "FanFox",
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
fn search_series(query, page, auth) {
    let encoded_query = url_encode(query);
    let url = `${BASE_URL}/search?title=${encoded_query}&page=${page}`;

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false, total: 0 };
    }

    let series = [];
    let seen = #{};

    // FanFox search results are in list items with manga links
    // Try CSS selectors first for structured extraction
    let items = html_select(html, "ul.manga-list-4-list li");

    // Fallback to broader selector
    if items.len() == 0 {
        items = html_select(html, "li");
    }

    for item in items {
        // Find main manga link
        let links = html_select(item, "a[href*='/manga/']");
        if links.len() == 0 {
            continue;
        }

        let main_link = ();
        let title = "";
        let href = "";

        for link in links {
            let link_href = element_attr(link, "href");
            if link_href == () || link_href == "" {
                continue;
            }

            // Skip chapter links (contain /c followed by digits)
            // regex_find returns "" (not ()) on no match, so we must exclude
            // both — otherwise every non-chapter link is wrongly skipped.
            let _cm = regex_find("/c[0-9]", link_href);
            if _cm != () && _cm != "" {
                continue;
            }

            if link_href.contains("/manga/") {
                main_link = link;
                href = link_href;

                // Try title attribute first
                title = element_attr(link, "title");
                if title == () || title == "" {
                    title = element_text(link).trim();
                }
                break;
            }
        }

        if main_link == () || href == "" {
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

        // Clean title
        title = clean_text(title);
        if title == "" {
            continue;
        }

        // Get cover image
        let cover_url = ();
        let imgs = html_select(item, "img");
        for img in imgs {
            let src = element_attr(img, "src");
            if src == () || src == "" {
                src = element_attr(img, "data-src");
            }
            if src != () && src != "" {
                cover_url = make_absolute(src);
                break;
            }
        }

        // Get status if visible in listing
        let status = ();
        let item_text = element_text(item);
        if item_text.to_lower().contains("completed") {
            status = "Completed";
        } else if item_text.to_lower().contains("ongoing") {
            status = "Ongoing";
        }

        let manga_url = make_absolute(href);

        series.push(#{
            id: slug,
            title: title,
            url: manga_url,
            cover_url: cover_url,
            alternate_titles: [],
            authors: [],
            artists: [],
            status: status,
            genres: [],
            tags: [],
            description: (),
            extra: #{
                source_site: "fanfox"
            }
        });
    }

    // If CSS selectors yielded nothing, try regex fallback on raw HTML
    if series.len() == 0 {
        // Pattern: href="/manga/{slug}/" ... title or text
        let manga_links = regex_find_all("href=\"(/manga/[^\"]+)\"[^>]*(?:title=\"([^\"]+)\"|>([^<]+)<)", html);

        for m in manga_links {
            let link_href = regex_find("/manga/[^\"]+", m);
            if link_href == () || link_href == "" {
                continue;
            }

            // Skip chapter links
            // regex_find returns "" (not ()) on no match, so we must exclude
            // both — otherwise every non-chapter link is wrongly skipped.
            let _cm = regex_find("/c[0-9]", link_href);
            if _cm != () && _cm != "" {
                continue;
            }

            let slug = extract_slug(link_href);
            if slug == "" || seen.contains(slug) {
                continue;
            }
            seen[slug] = true;

            // Extract title from title attr or inner text
            let title = regex_find("title=\"([^\"]+)\"", m);
            if title != () && title != "" {
                title = title.replace("title=\"", "").replace("\"", "").trim();
            } else {
                title = regex_find(">([^<]+)<", m);
                if title != () && title != "" {
                    title = title.replace(">", "").replace("<", "").trim();
                }
            }

            if title == () || title == "" || title.len() < 2 {
                continue;
            }

            series.push(#{
                id: slug,
                title: title,
                url: make_absolute(link_href),
                cover_url: (),
                alternate_titles: [],
                authors: [],
                artists: [],
                status: (),
                genres: [],
                tags: [],
                description: (),
                extra: #{
                    source_site: "fanfox"
                }
            });
        }
    }

    // Check for next page
    let has_more = false;
    let next_page = page + 1;
    if html.contains(`page=${next_page}`) || html.contains(`/${next_page}.htm`) {
        has_more = true;
    }
    // Also check for "Next" or ">" pagination link
    let pager_links = html_select(html, "a.pager-next");
    if pager_links.len() > 0 {
        has_more = true;
    }
    if !has_more {
        let next_links = html_select(html, "a.next");
        if next_links.len() > 0 {
            has_more = true;
        }
    }

    #{ series: series, has_more: has_more, total: series.len() }
}

/// Get detailed series information
fn get_series(id_or_url, auth) {
    let slug = id_or_url;
    let url = "";

    if id_or_url.starts_with("http") {
        slug = extract_slug(id_or_url);
        url = id_or_url;
    } else if id_or_url.contains("/manga/") {
        slug = extract_slug(id_or_url);
        url = make_absolute(id_or_url);
    } else {
        // Bare slug
        url = `${BASE_URL}/manga/${slug}/`;
    }

    if slug == "" {
        throw `Invalid series ID or URL: ${id_or_url}`;
    }

    let html = fetch_html(url);

    if html == "" {
        throw `Failed to fetch series page: ${url}`;
    }

    // --- Title ---
    let title = "";
    // Try <h1> or <h2> with class
    let h1_els = html_select(html, "h1");
    if h1_els.len() > 0 {
        title = element_text(h1_els[0]).trim();
    }
    if title == "" {
        let h2_els = html_select(html, "h2");
        if h2_els.len() > 0 {
            title = element_text(h2_els[0]).trim();
        }
    }
    // Fallback to og:title meta
    if title == "" {
        let og_match = regex_find("og:title[\"']\\s*content=[\"']([^\"']+)", html);
        if og_match != () && og_match != "" {
            title = regex_find("content=[\"']([^\"']+)", og_match);
            title = title.replace("content=\"", "").replace("content='", "").replace("\"", "").replace("'", "").trim();
            // Remove site suffix
            if title.contains(" - MangaFox") {
                let idx = title.index_of(" - MangaFox");
                if idx > 0 { title = title.sub_string(0, idx); }
            }
            if title.contains(" Manga - ") {
                let idx = title.index_of(" Manga - ");
                if idx > 0 { title = title.sub_string(0, idx); }
            }
        }
    }
    // Last resort: capitalize slug
    if title == "" {
        title = slug.replace("_", " ").replace("-", " ");
    }

    // --- Cover Image ---
    let cover_url = ();
    // Look for cover image in detail section
    let cover_imgs = html_select(html, "img.detail-info-cover-img");
    if cover_imgs.len() > 0 {
        cover_url = element_attr(cover_imgs[0], "src");
    }
    if cover_url == () || cover_url == "" {
        cover_imgs = html_select(html, "div.detail-info img");
        if cover_imgs.len() > 0 {
            cover_url = element_attr(cover_imgs[0], "src");
        }
    }
    if cover_url == () || cover_url == "" {
        // Try og:image meta
        let og_img = regex_find("og:image[\"']\\s*content=[\"']([^\"']+)", html);
        if og_img != () && og_img != "" {
            cover_url = regex_find("content=[\"']([^\"']+)", og_img);
            cover_url = cover_url.replace("content=\"", "").replace("content='", "").replace("\"", "").replace("'", "").trim();
        }
    }
    if cover_url == () || cover_url == "" {
        // Try any img with fmcdn in src
        let cdn_imgs = html_select(html, "img[src*='fmcdn']");
        if cdn_imgs.len() > 0 {
            cover_url = element_attr(cdn_imgs[0], "src");
        }
    }
    if cover_url != () && cover_url != "" {
        cover_url = make_absolute(cover_url);
    }

    // --- Description ---
    let description = ();
    // Try detail-info-right-content class
    let desc_els = html_select(html, "p.fullcontent");
    if desc_els.len() > 0 {
        description = clean_text(element_text(desc_els[0]));
    }
    if description == () || description == "" {
        desc_els = html_select(html, "div.detail-info-right-content");
        if desc_els.len() > 0 {
            description = clean_text(element_text(desc_els[0]));
        }
    }
    if description == () || description == "" {
        // Try meta description
        let meta_desc = regex_find("name=[\"']description[\"'][^>]*content=[\"']([^\"']+)", html);
        if meta_desc != () && meta_desc != "" {
            description = regex_find("content=[\"']([^\"']+)", meta_desc);
            description = description.replace("content=\"", "").replace("content='", "").replace("\"", "").replace("'", "").trim();
        }
    }

    // --- Authors / Artists ---
    let authors = [];
    let artists = [];

    // Each p.detail-info-right-say has a label span followed by name links
    let info_paras = html_select(html, "p.detail-info-right-say");
    for para in info_paras {
        let para_text = element_text(para).to_lower();
        let links = html_select(para, "a");
        if links.len() == 0 { continue; }
        if para_text.contains("author") {
            for link in links {
                let name = element_text(link).trim();
                if name != "" && !authors.contains(name) { authors.push(name); }
            }
        } else if para_text.contains("artist") {
            for link in links {
                let name = element_text(link).trim();
                if name != "" && !artists.contains(name) { artists.push(name); }
            }
        }
    }

    // Regex fallback for author (when CSS selector finds nothing)
    if authors.len() == 0 {
        let author_matches = regex_find_all("Author[^:]*:[^<]*<a[^>]*>([^<]+)</a>", html);
        for am in author_matches {
            let author = regex_find(">([^<]+)<", am);
            if author != () && author != "" {
                author = author.replace(">", "").replace("<", "").trim();
                if author != "" && !authors.contains(author) {
                    authors.push(author);
                }
            }
        }
    }

    // Regex fallback for artist (when CSS selector finds nothing)
    if artists.len() == 0 {
        let artist_matches = regex_find_all("Artist[^:]*:[^<]*<a[^>]*>([^<]+)</a>", html);
        for am in artist_matches {
            let artist = regex_find(">([^<]+)<", am);
            if artist != () && artist != "" {
                artist = artist.replace(">", "").replace("<", "").trim();
                if artist != "" && !artists.contains(artist) {
                    artists.push(artist);
                }
            }
        }
    }

    // --- Status ---
    let status = ();
    // Look for status span
    let status_spans = html_select(html, "span.detail-info-right-title-tip");
    for span in status_spans {
        let text = element_text(span).trim();
        let mapped = map_status(text);
        if mapped != () {
            status = mapped;
            break;
        }
    }
    if status == () {
        // Regex fallback
        let status_match = regex_find("Status[^:]*:\\s*([A-Za-z]+)", html);
        if status_match != () && status_match != "" {
            status = map_status(status_match);
        }
    }

    // --- Genres ---
    let genres = [];
    // Genre links in detail section
    let genre_links = html_select(html, "a.detail-info-right-tag-list");
    if genre_links.len() == 0 {
        genre_links = html_select(html, "a[href*='/directory/']");
    }
    if genre_links.len() == 0 {
        genre_links = html_select(html, "span.detail-info-right-tag-list a");
    }
    for g_link in genre_links {
        let genre = element_text(g_link).trim();
        if genre != "" && genre.len() < 30 && !genres.contains(genre) {
            genres.push(genre);
        }
    }

    // Regex fallback for genres
    if genres.len() == 0 {
        let genre_matches = regex_find_all("href=\"/directory/[^\"]*\"[^>]*>([^<]+)<", html);
        for gm in genre_matches {
            let genre = regex_find(">([^<]+)<", gm);
            if genre != () && genre != "" {
                genre = genre.replace(">", "").replace("<", "").trim();
                if genre != "" && genre.len() < 30 && !genres.contains(genre) {
                    genres.push(genre);
                }
            }
        }
    }

    // --- Alternate Titles ---
    let alt_titles = [];
    // FanFox sometimes shows alternate titles under the main title
    let alt_match = regex_find("Alternative[^:]*:\\s*([^<]+)", html);
    if alt_match != () && alt_match != "" {
        let alt_text = alt_match.replace("Alternative:", "").replace("Alternative", "").trim();
        let alts = alt_text.split(";");
        for alt in alts {
            let cleaned = alt.trim();
            if cleaned != "" && cleaned != title && cleaned.len() > 1 {
                alt_titles.push(cleaned);
            }
        }
    }

    // --- Year ---
    let year = ();
    let year_match = regex_find("Released[^:]*:[^0-9]*((?:19|20)\\d{2})", html);
    if year_match != () && year_match != "" {
        let yr = regex_find("(19|20)\\d{2}", year_match);
        if yr != () && yr != "" {
            year = yr;
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
            source_name: "FanFox"
        }
    }
}

/// Get all chapters for a series
fn get_chapters(series_id, auth) {
    let slug = series_id;
    let url = "";

    if series_id.starts_with("http") {
        slug = extract_slug(series_id);
        url = series_id;
    } else if series_id.contains("/manga/") {
        slug = extract_slug(series_id);
        url = make_absolute(series_id);
    } else {
        url = `${BASE_URL}/manga/${slug}/`;
    }

    if slug == "" {
        return [];
    }

    let html = fetch_html(url);

    if html == "" {
        return [];
    }

    let chapters = [];
    let seen = #{};

    // FanFox chapter list: links matching /manga/{slug}/c{number}/
    // Try structured selector first
    let chapter_links = html_select(html, "a[href*='/c']");

    // Also try the chapter list container
    if chapter_links.len() == 0 {
        chapter_links = html_select(html, "ul.detail-main-list a");
    }
    if chapter_links.len() == 0 {
        chapter_links = html_select(html, "div#chapterlist a");
    }

    for link in chapter_links {
        let href = element_attr(link, "href");
        if href == () || href == "" {
            continue;
        }

        // Must be a chapter link for this manga
        if !href.contains(`/manga/${slug}/`) {
            continue;
        }

        // Must contain chapter pattern /c{number}. regex_find returns "" on
        // no match (not unit) — the previous `== ()` never fired, so this
        // gate was dead code. The chapter_num == "0" check below was the
        // only thing actually filtering out non-chapter links.
        if regex_find("/c[0-9]", href) == "" {
            continue;
        }

        // Extract chapter number
        let chapter_num = extract_chapter_number(href);
        if chapter_num == "0" {
            continue;
        }

        // Build compound ID
        let ch_id = build_chapter_id(slug, chapter_num);

        // Skip duplicates
        if seen.contains(ch_id) {
            continue;
        }
        seen[ch_id] = true;

        // Get volume if present
        let volume = extract_volume_number(href);

        // Get chapter title from link text
        let chapter_title = element_text(link).trim();
        if chapter_title == "" {
            chapter_title = `Chapter ${chapter_num}`;
        }
        // Clean up title (remove "New" badges etc.)
        chapter_title = chapter_title.replace("new", "").replace("New", "").replace("NEW", "").trim();

        // Try to find date from parent or sibling
        let published_at = ();

        let chapter_url = make_absolute(href);

        chapters.push(#{
            id: ch_id,
            series_id: slug,
            number: chapter_num,
            title: chapter_title,
            volume: volume,
            language: "en",
            scanlator: (),
            url: chapter_url,
            published_at: published_at,
            page_count: (),
            extra: #{}
        });
    }

    // If CSS approach found nothing, use regex fallback
    if chapters.len() == 0 {
        let ch_matches = regex_find_all(`href="(/manga/${slug}/[^"]*c[0-9][^"]*)"`, html);

        for ch_href in ch_matches {
            // Clean up the match
            let href = ch_href.replace("href=\"", "").replace("\"", "").trim();

            let chapter_num = extract_chapter_number(href);
            if chapter_num == "0" {
                continue;
            }

            let ch_id = build_chapter_id(slug, chapter_num);
            if seen.contains(ch_id) {
                continue;
            }
            seen[ch_id] = true;

            let volume = extract_volume_number(href);

            chapters.push(#{
                id: ch_id,
                series_id: slug,
                number: chapter_num,
                title: `Chapter ${chapter_num}`,
                volume: volume,
                language: "en",
                scanlator: (),
                url: make_absolute(href),
                published_at: (),
                page_count: (),
                extra: #{}
            });
        }
    }

    chapters
}

/// Get page URLs for a chapter
/// FanFox images may be loaded via JavaScript on the desktop site.
/// Strategy:
///   1. Try the mobile roll view (m.fanfox.net/roll_manga/) which shows all pages as img tags
///   2. Fall back to desktop page and extract from JavaScript variables
///   3. Fall back to iterating individual pages on the desktop site
fn get_chapter_pages(chapter_id, auth) {
    let info = parse_chapter_id(chapter_id);
    let slug = info.slug;
    let chapter_num = info.number;

    if slug == "" {
        return [];
    }

    // --- Strategy 1: Mobile roll view ---
    // m.fanfox.net/roll_manga/{slug}/c{num}/1.html loads all page images at once
    let mobile_url = `${MOBILE_URL}/roll_manga/${slug}/c${chapter_num}/1.html`;
    let mobile_html = fetch_mobile_html(mobile_url);

    let pages = [];
    let idx = 0;

    if mobile_html != "" && !mobile_html.contains("404") && !mobile_html.contains("Page not found") {
        // Mobile roll view has all images as <img> tags with data-original or src
        let img_els = html_select(mobile_html, "img");

        for img in img_els {
            // Try data-original first (lazy loaded), then src
            let img_url = element_attr(img, "data-original");
            if img_url == () || img_url == "" {
                img_url = element_attr(img, "src");
            }
            if img_url == () || img_url == "" {
                continue;
            }

            // Must be a manga page image (from CDN or containing manga path)
            if !img_url.contains("fmcdn") && !img_url.contains("mfcdn") && !img_url.contains("/manga/") && !img_url.contains("/store/") {
                continue;
            }

            // Skip tiny images (icons, ads) by checking URL patterns
            if img_url.contains("/icon") || img_url.contains("/logo") || img_url.contains("/ads/") {
                continue;
            }

            img_url = make_absolute(img_url);

            pages.push(#{
                index: idx,
                url: img_url,
                headers: #{
                    "Referer": MOBILE_URL
                },
                referer: MOBILE_URL
            });
            idx += 1;
        }
    }

    // Return if mobile roll view worked
    if pages.len() > 0 {
        return pages;
    }

    // --- Strategy 2: Desktop page - extract from JavaScript ---
    let desktop_url = `${BASE_URL}/manga/${slug}/c${chapter_num}/1.html`;
    let desktop_html = fetch_html(desktop_url);

    if desktop_html == "" || desktop_html.contains("404") || desktop_html.contains("Page not found") {
        // Try with volume TBD path
        desktop_url = `${BASE_URL}/manga/${slug}/vTBD/c${chapter_num}/1.html`;
        desktop_html = fetch_html(desktop_url);
    }

    if desktop_html == "" {
        return [];
    }

    // Look for chapterimages or similar JS variable containing image list
    // FanFox often has: var chapterimages = "url1,url2,..."
    let img_var = regex_find("chapterimages\\s*=\\s*\"([^\"]+)\"", desktop_html);
    if img_var != () && img_var != "" {
        // Remove variable name prefix
        img_var = img_var.replace("chapterimages", "").replace("=", "").replace("\"", "").trim();
        let img_urls = img_var.split(",");
        for img_url in img_urls {
            let clean_url = img_url.trim();
            if clean_url == "" {
                continue;
            }
            clean_url = make_absolute(clean_url);

            pages.push(#{
                index: idx,
                url: clean_url,
                headers: #{
                    "Referer": desktop_url
                },
                referer: desktop_url
            });
            idx += 1;
        }
    }

    if pages.len() > 0 {
        return pages;
    }

    // Try to find image URLs in newImgs or similar arrays
    let img_array = regex_find("(?:newImgs|imagearray|pix)\\s*=\\s*\\[([^\\]]+)\\]", desktop_html);
    if img_array != () && img_array != "" {
        let urls = regex_find_all("\"([^\"]+)\"", img_array);
        for url_match in urls {
            let clean_url = url_match.replace("\"", "").trim();
            if clean_url != "" && (clean_url.contains("http") || clean_url.starts_with("/")) {
                clean_url = make_absolute(clean_url);
                pages.push(#{
                    index: idx,
                    url: clean_url,
                    headers: #{
                        "Referer": desktop_url
                    },
                    referer: desktop_url
                });
                idx += 1;
            }
        }
    }

    if pages.len() > 0 {
        return pages;
    }

    // --- Strategy 3: Iterate through page selector ---
    // Find total pages from page selector dropdown
    let page_options = html_select(desktop_html, "select.pager-list-left option");
    if page_options.len() == 0 {
        page_options = html_select(desktop_html, "div.pager-list-left option");
    }
    if page_options.len() == 0 {
        page_options = html_select(desktop_html, "select option");
    }

    let page_urls = [];
    for option in page_options {
        let val = element_attr(option, "value");
        if val == () || val == "" {
            continue;
        }
        // Skip non-page options (comments, etc.)
        let text = element_text(option).trim();
        if text.contains("comment") || text.contains("Comment") {
            continue;
        }
        // Only include numeric pages. regex_find returns "" on no match
        // (not unit), so the previous `== ()` check never fired and let
        // non-numeric options through.
        let num_check = regex_find("^[0-9]+$", text);
        if num_check == "" {
            continue;
        }

        let page_url = make_absolute(val);

        // Avoid duplicates
        let is_dup = false;
        for existing in page_urls {
            if existing == page_url {
                is_dup = true;
                break;
            }
        }
        if !is_dup {
            page_urls.push(page_url);
        }
    }

    // If we have page URLs, try to get the reader image from each
    // First, extract from the current page
    let reader_imgs = html_select(desktop_html, "#image");
    if reader_imgs.len() == 0 {
        reader_imgs = html_select(desktop_html, "img.reader-main-img");
    }
    if reader_imgs.len() == 0 {
        reader_imgs = html_select(desktop_html, "div#viewer img");
    }

    for img in reader_imgs {
        let img_url = element_attr(img, "src");
        if img_url == () || img_url == "" {
            continue;
        }
        img_url = make_absolute(img_url);

        // Skip placeholder/loading images
        if img_url.contains("loading") || img_url.contains("placeholder") || img_url.contains("logo") {
            continue;
        }

        pages.push(#{
            index: idx,
            url: img_url,
            headers: #{
                "Referer": desktop_url
            },
            referer: desktop_url
        });
        idx += 1;
        break;  // Only first valid image from current page
    }

    // Fetch remaining pages
    let start = 1;
    if pages.len() > 0 {
        start = 1;  // Skip first page since we already have it
    } else {
        start = 0;
    }

    for i in start..page_urls.len() {
        let pg_html = fetch_html(page_urls[i]);
        if pg_html == "" {
            continue;
        }

        let imgs = html_select(pg_html, "#image");
        if imgs.len() == 0 {
            imgs = html_select(pg_html, "img.reader-main-img");
        }
        if imgs.len() == 0 {
            imgs = html_select(pg_html, "div#viewer img");
        }

        for img in imgs {
            let img_url = element_attr(img, "src");
            if img_url == () || img_url == "" {
                continue;
            }
            img_url = make_absolute(img_url);

            if img_url.contains("loading") || img_url.contains("placeholder") || img_url.contains("logo") {
                continue;
            }

            pages.push(#{
                index: idx,
                url: img_url,
                headers: #{
                    "Referer": page_urls[i]
                },
                referer: page_urls[i]
            });
            idx += 1;
            break;
        }
    }

    pages
}

/// Get latest updates
fn get_latest_updates(page, auth) {
    // FanFox releases page shows latest chapter updates
    let url = `${BASE_URL}/releases/`;
    if page > 1 {
        url = `${BASE_URL}/releases/${page}.htm`;
    }

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let seen = #{};

    // Try structured extraction from release items
    let items = html_select(html, "li");

    for item in items {
        let links = html_select(item, "a[href*='/manga/']");
        let main_link = ();
        let title = "";

        for link in links {
            let href = element_attr(link, "href");
            if href == () || href == "" {
                continue;
            }
            // Skip chapter links
            // regex_find returns "" (not ()) on no match, so we must exclude
            // both — otherwise every non-chapter link is wrongly skipped.
            let _cm = regex_find("/c[0-9]", href);
            if _cm != () && _cm != "" {
                continue;
            }
            if href.contains("/manga/") {
                main_link = link;
                title = element_attr(link, "title");
                if title == () || title == "" {
                    title = element_text(link).trim();
                }
                break;
            }
        }

        if main_link == () {
            continue;
        }

        let href = element_attr(main_link, "href");
        let slug = extract_slug(href);
        if slug == "" || seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        title = clean_text(title);
        if title == "" {
            continue;
        }

        // Get cover
        let cover_url = ();
        let imgs = html_select(item, "img");
        for img in imgs {
            let src = element_attr(img, "src");
            if src == () || src == "" {
                src = element_attr(img, "data-src");
            }
            if src != () && src != "" {
                cover_url = make_absolute(src);
                break;
            }
        }

        series.push(#{
            id: slug,
            title: title,
            url: make_absolute(href),
            cover_url: cover_url,
            updated_at: ()
        });
    }

    // Check for more pages
    let has_more = false;
    let next_links = html_select(html, "a.pager-next");
    if next_links.len() > 0 {
        has_more = true;
    }
    if !has_more {
        let next_page = page + 1;
        if html.contains(`/${next_page}.htm`) || html.contains(`page=${next_page}`) {
            has_more = true;
        }
    }

    #{ series: series, has_more: has_more }
}

/// Browse manga directory
fn browse(page, filters, auth) {
    // FanFox directory with pagination
    let url = `${BASE_URL}/directory/`;
    if page > 1 {
        url = `${BASE_URL}/directory/${page}.htm`;
    }

    let html = fetch_html(url);

    if html == "" {
        return #{ series: [], has_more: false };
    }

    let series = [];
    let seen = #{};

    // Directory items
    let items = html_select(html, "ul.manga-list-4-list li");
    if items.len() == 0 {
        items = html_select(html, "li");
    }

    for item in items {
        let links = html_select(item, "a[href*='/manga/']");
        let main_link = ();
        let title = "";

        for link in links {
            let href = element_attr(link, "href");
            if href == () || href == "" {
                continue;
            }
            // regex_find returns "" (not ()) on no match, so we must exclude
            // both — otherwise every non-chapter link is wrongly skipped.
            let _cm = regex_find("/c[0-9]", href);
            if _cm != () && _cm != "" {
                continue;
            }
            if href.contains("/manga/") {
                main_link = link;
                title = element_attr(link, "title");
                if title == () || title == "" {
                    title = element_text(link).trim();
                }
                break;
            }
        }

        if main_link == () {
            continue;
        }

        let href = element_attr(main_link, "href");
        let slug = extract_slug(href);
        if slug == "" || seen.contains(slug) {
            continue;
        }
        seen[slug] = true;

        title = clean_text(title);
        if title == "" {
            continue;
        }

        // Get cover
        let cover_url = ();
        let imgs = html_select(item, "img");
        for img in imgs {
            let src = element_attr(img, "src");
            if src == () || src == "" {
                src = element_attr(img, "data-src");
            }
            if src != () && src != "" {
                cover_url = make_absolute(src);
                break;
            }
        }

        // Get status if visible
        let status = ();
        let item_text = element_text(item);
        if item_text.to_lower().contains("completed") {
            status = "Completed";
        } else if item_text.to_lower().contains("ongoing") {
            status = "Ongoing";
        }

        series.push(#{
            id: slug,
            title: title,
            url: make_absolute(href),
            cover_url: cover_url,
            alternate_titles: [],
            authors: [],
            artists: [],
            status: status,
            genres: [],
            tags: [],
            description: ()
        });
    }

    // If structured parsing found nothing, try regex fallback
    if series.len() == 0 {
        let manga_matches = regex_find_all("href=\"(/manga/[^\"]+)\"[^>]*(?:title=\"([^\"]+)\"|>)", html);
        for m in manga_matches {
            let href = regex_find("/manga/[^\"]+", m);
            if href == () || href == "" {
                continue;
            }
            // regex_find returns "" (not ()) on no match, so we must exclude
            // both — otherwise every non-chapter link is wrongly skipped.
            let _cm = regex_find("/c[0-9]", href);
            if _cm != () && _cm != "" {
                continue;
            }
            let slug = extract_slug(href);
            if slug == "" || seen.contains(slug) {
                continue;
            }
            seen[slug] = true;

            let title = regex_find("title=\"([^\"]+)\"", m);
            if title != () && title != "" {
                title = title.replace("title=\"", "").replace("\"", "").trim();
            } else {
                title = slug.replace("_", " ").replace("-", " ");
            }

            if title.len() < 2 {
                continue;
            }

            series.push(#{
                id: slug,
                title: title,
                url: make_absolute(href),
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

    // Check for more pages
    let has_more = false;
    let next_page = page + 1;
    if html.contains(`/${next_page}.htm`) || html.contains(`page=${next_page}`) {
        has_more = true;
    }
    let pager_links = html_select(html, "a.pager-next");
    if pager_links.len() > 0 {
        has_more = true;
    }

    // FanFox has a very large directory, assume more if we got results
    if !has_more && series.len() >= 20 {
        has_more = true;
    }

    #{ series: series, has_more: has_more }
}
