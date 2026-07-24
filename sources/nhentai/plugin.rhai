// nhentai Scraper Add-on (Rhai) — HTML-scraping via FlareSolverr
// =============================================================================
// WARNING: This addon provides access to EXPLICIT adult content.
// Users MUST be 18+ years old to use this addon.
//
// Why HTML, not the JSON API:
//   nhentai's JSON API (nhentai.net/api/*) is Cloudflare/IP-blocked for
//   datacenter and CGNAT egress IPs — it returns a CF challenge even through
//   FlareSolverr (verified 2026-06: "Cloudflare has blocked this request").
//   The rendered web pages, however, load cleanly through FlareSolverr (which
//   egresses through the VPN), and the image CDNs (i./t.nhentai.net) serve
//   directly. So this connector scrapes the rendered HTML.
//
// Page structure (Svelte SSR, as of 2026-06):
//   Listing (/, /search/?q=): <div class="gallery lang-*"><a href="/g/{id}/"
//       class="cover"><img class="lazyload"
//       src="https://t{n}.nhentai.net/galleries/{media_id}/thumb.webp">
//       <div class="caption">{title}</div></a></div>
//   Gallery  (/g/{id}/): <h1 class="title">…</h1>, #cover img, tag chips
//       <a class="tagchip"><span class="name">…</span></a>, and one
//       <a class="gallerythumb"><img src=".../{media_id}/{page}t.{ext}"></a>
//       per page.
//   Full page image: https://i.nhentai.net/galleries/{media_id}/{page}.{ext}
//       (extension derived per-page from each thumbnail's src).
//
// Available Rhai APIs:
//   flaresolverr_get(url, timeout_ms) -> string   (VPN egress; USE THIS)
//   http_get_with_headers(url, headers) -> string (optional fast path)
//   html_parse / html_select / html_select_first / element_attr / element_text
//   regex_find / json_parse / url_encode / parse_int
// =============================================================================

const BASE_URL = "https://nhentai.net";
const IMAGE_HOST = "https://i.nhentai.net";
const THUMB_HOST = "https://t.nhentai.net";

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Fetch a page's rendered HTML through FlareSolverr (VPN egress). Returns ""
/// on failure. nhentai is a normal HTML site, so the gallery cards are present
/// in the rendered response.
fn fetch_html(url) {
    let html = "";
    try {
        // 60s literal (Rhai won't inline a bare numeric const into a call arg).
        html = flaresolverr_get(url, 60000);
    } catch {
        return "";
    }
    if html == () { return ""; }
    return html;
}

/// Pull the numeric gallery id out of an id, a "/g/{id}/" path, or a full URL.
fn extract_id(x) {
    let s = `${x}`;
    if s.contains("/g/") {
        let m = regex_find("/g/[0-9]+", s);
        return m.replace("/g/", "");
    }
    return regex_find("[0-9]+", s);
}

/// Best-effort image-source read (lazyload pages put the real URL in `src`,
/// but fall back to data-src just in case).
fn img_src(img_html) {
    let s = element_attr(img_html, "data-src");
    if s == "" { s = element_attr(img_html, "src"); }
    return s;
}

/// Map a single-letter image type to a file extension.
fn ext_from_type(c) {
    if c == "j" { return "jpg"; }
    if c == "p" { return "png"; }
    if c == "g" { return "gif"; }
    if c == "w" { return "webp"; }
    return "jpg";
}

/// Parse gallery cards from any listing page (home / search / tag).
fn parse_cards(html) {
    let series = [];
    let cards = html_select(html, "div.gallery");
    for card in cards {
        let a = html_select_first(card, "a.cover");
        let href = if a != "" { element_attr(a, "href") } else { "" };
        if href == "" { href = regex_find("/g/[0-9]+/", card); }
        let id = href.replace("/g/", "").replace("/", "");
        if id == "" { continue; }

        let cover = "";
        let img = html_select_first(card, "img");
        if img != "" { cover = img_src(img); }

        let title = "";
        let cap = html_select_first(card, "div.caption");
        if cap != "" { title = element_text(cap).trim(); }
        if title == "" && img != "" { title = element_attr(img, "alt"); }

        series.push(#{
            id: id,
            title: title,
            cover_url: cover,
            url: `${BASE_URL}/g/${id}/`,
            content_rating: "nsfw"
        });
    }
    return series;
}

/// Parse per-page { media_id, page, ext } from the gallery thumbnails. The full
/// image keeps each page's own extension (galleries mix jpg/png/webp).
fn parse_pages(html) {
    let result = [];
    let thumbs = html_select(html, "a.gallerythumb img");
    for img in thumbs {
        let src = img_src(img);
        if src == "" { continue; }
        let mid_part = regex_find("galleries/[0-9]+/", src);   // "galleries/3975966/"
        if mid_part == "" { continue; }
        let media_id = mid_part.replace("galleries/", "").replace("/", "");
        let file_part = regex_find("[0-9]+t\\.[a-z0-9]+", src); // "1t.webp"
        if file_part == "" { continue; }
        let page = regex_find("[0-9]+", file_part);             // "1"
        let ext = regex_find("\\.[a-z0-9]+", file_part).replace(".", ""); // "webp"
        if page == "" || ext == "" { continue; }
        result.push(#{ media_id: media_id, page: page, ext: ext });
    }
    return result;
}

/// Collect tag names from the gallery's tag chips.
fn parse_tags(html) {
    let tags = [];
    // Tag chips are <a class="tagchip ..."><span class="name">…</span>…</a>
    let names = html_select(html, ".tagchip .name");
    for n in names {
        let t = element_text(n).trim();
        if t != "" { tags.push(t); }
    }
    return tags;
}

/// Collect tag names whose chip links match a /{kind}/ href (e.g. "artist").
fn parse_tags_of_kind(html, kind) {
    let result = [];
    let chips = html_select(html, "a.tagchip");
    let needle = `/${kind}/`;
    for chip in chips {
        let href = element_attr(chip, "href");
        if href.contains(needle) {
            let name_el = html_select_first(chip, ".name");
            let t = if name_el != "" { element_text(name_el).trim() } else { "" };
            if t != "" { result.push(t); }
        }
    }
    return result;
}

fn join_array(arr, sep) {
    if arr.len() == 0 { return ""; }
    let result = "";
    let first = true;
    for item in arr {
        if first { result = `${item}`; first = false; }
        else { result = result + sep + `${item}`; }
    }
    result
}

// ── Plugin interface ────────────────────────────────────────────────────────

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "nhentai-rhai",
        name: "nhentai",
        base_url: BASE_URL,
        version: "2.0.0",
        language: "en",
        supported_languages: ["en", "ja", "zh"],
        requires_authentication: false,
        capability_level: "browser_automation",
        nsfw: true,
        content_rating: "nsfw",
        content_types: ["doujinshi", "manga", "hentai"]
    }
}

/// Search for galleries matching a query (HTML search page).
fn search_series(query, page, auth) {
    let p = if page < 1 { 1 } else { page };
    let url = `${BASE_URL}/search/?q=${url_encode(query)}&page=${p}`;
    let html = fetch_html(url);
    if html == "" { return #{ series: [], has_more: false, total: 0 }; }
    let series = parse_cards(html);
    let has_more = html.contains("class=\"next\"") || series.len() >= 25;
    #{ series: series, has_more: has_more, total: series.len() }
}

/// Get latest galleries (home page).
fn get_latest_updates(page, auth) {
    let p = if page < 1 { 1 } else { page };
    let url = `${BASE_URL}/?page=${p}`;
    let html = fetch_html(url);
    if html == "" { return #{ series: [], has_more: false }; }
    let series = parse_cards(html);
    let has_more = html.contains("class=\"next\"") || series.len() >= 25;
    #{ series: series, has_more: has_more }
}

fn browse(page, filters, auth) {
    get_latest_updates(page, auth)
}

/// Get detailed gallery information by ID or URL.
fn get_series(id_or_url, auth) {
    let id = extract_id(id_or_url);
    if id == "" { throw `Invalid gallery id: ${id_or_url}`; }
    let url = `${BASE_URL}/g/${id}/`;
    let html = fetch_html(url);
    if html == "" { throw `Failed to fetch gallery ${id}`; }

    let title = element_text(html_select_first(html, "h1.title")).trim();
    if title == "" { title = element_text(html_select_first(html, "h1")).trim(); }

    let pages = parse_pages(html);
    let num_pages = pages.len();
    let media_id = if num_pages > 0 { pages[0].media_id } else { "" };

    let cover = "";
    let cimg = html_select_first(html, "#cover img");
    if cimg != "" { cover = img_src(cimg); }
    if cover == "" && media_id != "" { cover = `${THUMB_HOST}/galleries/${media_id}/cover.webp`; }

    let artists = parse_tags_of_kind(html, "artist");
    let groups = parse_tags_of_kind(html, "group");
    let parodies = parse_tags_of_kind(html, "parody");
    let characters = parse_tags_of_kind(html, "character");
    let languages = parse_tags_of_kind(html, "language");
    let categories = parse_tags_of_kind(html, "category");

    let desc_parts = [];
    if parodies.len() > 0 { desc_parts.push("Parody: " + join_array(parodies, ", ")); }
    if characters.len() > 0 { desc_parts.push("Characters: " + join_array(characters, ", ")); }
    if groups.len() > 0 { desc_parts.push("Group: " + join_array(groups, ", ")); }
    if languages.len() > 0 { desc_parts.push("Language: " + join_array(languages, ", ")); }
    let description = join_array(desc_parts, "\n");

    #{
        id: id,
        title: title,
        alternate_titles: [],
        description: description,
        cover_url: cover,
        authors: artists,
        artists: artists,
        status: "Completed",
        genres: categories,
        tags: parse_tags(html),
        year: (),
        content_rating: "nsfw",
        url: url,
        extra: #{
            media_id: media_id,
            num_pages: num_pages,
            parodies: parodies,
            characters: characters,
            groups: groups,
            languages: languages,
            source_site: "nhentai",
            source_name: "nhentai",
            auto_match_metadata: true
        }
    }
}

/// Get chapters for a gallery. nhentai galleries are single-chapter works.
fn get_chapters(series_id, auth) {
    let id = extract_id(series_id);
    let url = `${BASE_URL}/g/${id}/`;
    let html = fetch_html(url);
    let title = if html != "" { element_text(html_select_first(html, "h1.title")).trim() } else { "" };
    let num_pages = if html != "" { parse_pages(html).len() } else { 0 };

    [
        #{
            id: id,
            series_id: id,
            number: "1",
            title: title,
            volume: (),
            language: "en",
            scanlator: "",
            url: url,
            published_at: (),
            page_count: num_pages,
            extra: #{ is_oneshot: true }
        }
    ]
}

/// Get page image URLs for a chapter (gallery).
fn get_chapter_pages(chapter_id, auth) {
    let id = extract_id(chapter_id);
    let url = `${BASE_URL}/g/${id}/`;
    let html = fetch_html(url);
    if html == "" { return []; }

    let referer = `${BASE_URL}/g/${id}/`;
    let pages = [];
    let i = 0;
    for pi in parse_pages(html) {
        pages.push(#{
            index: i,
            url: `${IMAGE_HOST}/galleries/${pi.media_id}/${pi.page}.${pi.ext}`,
            headers: #{ "Referer": referer },
            referer: referer
        });
        i += 1;
    }
    return pages;
}

/// Get popular tags for browsing.
fn get_popular_tags() {
    [
        "english", "japanese", "chinese", "translated",
        "full color", "sole female", "sole male", "manga", "doujinshi"
    ]
}
