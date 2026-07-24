// nhentai Scraper Add-on (Rhai) — HTML-scraping variant
// =============================================================================
// Why this exists:
//   nhentai's JSON API (nhentai.net/api/*) Cloudflare/IP-blocks datacenter and
//   CGNAT-shared IPs, which silently empties the API-based `nhentai-rhai`. The
//   rendered web pages, however, load fine through FlareSolverr, and the image
//   CDNs (i./t.nhentai.net) serve directly. So this connector scrapes the HTML
//   instead of calling the API.
//
// Page structure (Svelte SSR, as of 2026-06):
//   Listing (/, /search/?q=): <div class="gallery"><a href="/g/{id}/" class="cover">
//       <img src="https://t.nhentai.net/galleries/{media_id}/thumb.webp">
//       <div class="caption">{title}</div></a></div>
//   Gallery  (/g/{id}/): <h1 class="title">…</h1>, #cover img, and one
//       <a class="gallerythumb"><img src=".../{media_id}/{page}t.{ext}"></a> per page.
//   Full page image: https://i.nhentai.net/galleries/{media_id}/{page}.{ext}
//       (extension derived per-page from each thumbnail's src).
// =============================================================================

const BASE_URL = "https://nhentai.net";
const IMAGE_HOST = "https://i.nhentai.net";

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Fetch a page's rendered HTML through FlareSolverr. Returns "" on failure.
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
        let mid_part = regex_find("galleries/[0-9]+/", src);   // "galleries/3870098/"
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

/// Collect tag names from the gallery's tag containers.
fn parse_tags(html) {
    let tags = [];
    // Tag chips are <a class="tagchip"><span class="name">…</span><span class="count">…</span></a>
    // across the parody/character/tag/artist/group/language/category containers.
    let names = html_select(html, ".tagchip .name");
    for n in names {
        let t = element_text(n).trim();
        if t != "" { tags.push(t); }
    }
    return tags;
}

// ── Plugin interface ────────────────────────────────────────────────────────

fn get_source_info() {
    #{
        id: "nhentai-scraper",
        name: "nhentai (Scraper)",
        base_url: BASE_URL,
        version: "1.0.0",
        content_rating: "nsfw"
    }
}

fn search_series(query, page, auth) {
    let p = if page < 1 { 1 } else { page };
    let url = `${BASE_URL}/search/?q=${url_encode(query)}&page=${p}`;
    let html = fetch_html(url);
    if html == "" { return #{ series: [], has_more: false, total: 0 }; }
    let series = parse_cards(html);
    let has_more = html.contains("class=\"next\"") || series.len() >= 25;
    #{ series: series, has_more: has_more, total: series.len() }
}

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
    if cover == "" && media_id != "" { cover = `https://t.nhentai.net/galleries/${media_id}/cover.webp`; }

    #{
        id: id,
        title: title,
        alternate_titles: [],
        description: "",
        cover_url: cover,
        authors: [],
        artists: [],
        status: "Completed",
        genres: [],
        tags: parse_tags(html),
        year: (),
        content_rating: "nsfw",
        url: url,
        extra: #{
            media_id: media_id,
            num_pages: num_pages,
            source_site: "nhentai",
            source_name: "nhentai",
            auto_match_metadata: true
        }
    }
}

fn get_chapters(series_id, auth) {
    let id = extract_id(series_id);
    let url = `${BASE_URL}/g/${id}/`;
    let html = fetch_html(url);
    let title = if html != "" { element_text(html_select_first(html, "h1.title")).trim() } else { "" };
    let num_pages = if html != "" { parse_pages(html).len() } else { 0 };

    // nhentai galleries are single-chapter works.
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

fn get_popular_tags() {
    []
}
