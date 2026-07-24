-- Tsubaki Scraper Add-on Template (Lua)
--
-- This template provides the required functions for a scraper add-on.
-- Implement each function to scrape your target source.
--
-- Available APIs:
--   tsubaki.http.get(url) -> string
--   tsubaki.http.get_with_headers(url, headers) -> string
--   tsubaki.http.post(url, body) -> string
--   tsubaki.html.parse(html) -> document
--   tsubaki.json.parse(text) -> table
--   tsubaki.json.stringify(value) -> string
--
-- Document methods:
--   doc:select(selector) -> {element, ...}
--   doc:select_one(selector) -> element | nil
--
-- Element methods:
--   el:text() -> string
--   el:html() -> string
--   el:attr(name) -> string | nil
--   el:select(selector) -> {element, ...}
--   el:select_one(selector) -> element | nil

local BASE_URL = "https://yoursource.com"

--- Returns metadata about this source
function get_source_info()
    return {
        id = "your-source-id",
        name = "Your Source Name",
        base_url = BASE_URL,
        language = "en",
        supported_languages = {"en"},
        requires_authentication = false,
        capability_level = "http_only"
    }
end

--- Search for series matching query
--- @param query string Search query
--- @param page number Page number (1-indexed)
--- @param auth table Authentication context
--- @return table {series: [...], has_more: bool}
function search_series(query, page, auth)
    -- Build search URL
    local url = BASE_URL .. "/search?q=" .. query .. "&page=" .. tostring(page)

    -- Fetch and parse
    local html = tsubaki.http.get(url)
    local doc = tsubaki.html.parse(html)

    -- Extract series
    local series = {}
    for _, item in ipairs(doc:select("div.series-item")) do
        local link = item:select_one("a.title")
        local img = item:select_one("img")

        if link then
            table.insert(series, {
                id = link:attr("href"),
                title = link:text(),
                url = link:attr("href"),
                cover_url = img and img:attr("src") or nil,
                alternate_titles = {},
                authors = {},
                artists = {},
                status = nil,
                genres = {},
                tags = {},
                description = nil
            })
        end
    end

    -- Check for next page
    local has_more = doc:select_one("a.next-page") ~= nil

    return { series = series, has_more = has_more, total = nil }
end

--- Get detailed series information
--- @param id_or_url string Series ID or URL
--- @param auth table Authentication context
--- @return table SeriesInfo
function get_series(id_or_url, auth)
    local url = id_or_url
    if not id_or_url:match("^http") then
        url = BASE_URL .. id_or_url
    end

    local html = tsubaki.http.get(url)
    local doc = tsubaki.html.parse(html)

    -- Extract series details
    local title_el = doc:select_one("h1.title")
    local desc_el = doc:select_one("div.description")
    local cover_el = doc:select_one("img.cover")
    local status_el = doc:select_one("span.status")

    -- Extract authors
    local authors = {}
    for _, author in ipairs(doc:select("a.author")) do
        table.insert(authors, author:text())
    end

    -- Extract genres
    local genres = {}
    for _, genre in ipairs(doc:select("a.genre")) do
        table.insert(genres, genre:text())
    end

    return {
        id = url,
        title = title_el and title_el:text() or "",
        alternate_titles = {},
        description = desc_el and desc_el:text() or nil,
        cover_url = cover_el and cover_el:attr("src") or nil,
        authors = authors,
        artists = {},
        status = status_el and status_el:text() or nil,
        genres = genres,
        tags = {},
        year = nil,
        content_rating = nil,
        url = url,
        extra = {}
    }
end

--- Get all chapters for a series
--- @param series_id string Series ID or URL
--- @param auth table Authentication context
--- @return table [ChapterInfo]
function get_chapters(series_id, auth)
    local url = series_id
    if not series_id:match("^http") then
        url = BASE_URL .. series_id
    end

    local html = tsubaki.http.get(url)
    local doc = tsubaki.html.parse(html)

    local chapters = {}
    for _, item in ipairs(doc:select("li.chapter-item a")) do
        local chapter_url = item:attr("href")
        local chapter_text = item:text()

        -- Extract chapter number from text
        local number = chapter_text:gsub("Chapter%s*", ""):match("^%s*(.-)%s*$")

        table.insert(chapters, {
            id = chapter_url,
            series_id = series_id,
            number = number,
            title = nil,
            volume = nil,
            language = "en",
            scanlator = nil,
            url = chapter_url,
            published_at = nil,
            page_count = nil,
            extra = {}
        })
    end

    return chapters
end

--- Get page URLs for a chapter
--- @param chapter_id string Chapter ID or URL
--- @param auth table Authentication context
--- @return table [PageInfo]
function get_chapter_pages(chapter_id, auth)
    local url = chapter_id
    if not chapter_id:match("^http") then
        url = BASE_URL .. chapter_id
    end

    local html = tsubaki.http.get(url)
    local doc = tsubaki.html.parse(html)

    local pages = {}
    local idx = 0

    for _, img in ipairs(doc:select("div.reader-content img")) do
        local img_url = img:attr("src") or img:attr("data-src")

        if img_url then
            table.insert(pages, {
                index = idx,
                url = img_url,
                headers = {},
                referer = url
            })
            idx = idx + 1
        end
    end

    return pages
end

-- Optional: Custom login handler
-- function login(credentials)
--     local username = credentials["username"]
--     local password = credentials["password"]
--
--     local response = tsubaki.http.post(BASE_URL .. "/login", {
--         username = username,
--         password = password
--     })
--
--     return {
--         credentials = credentials,
--         cookies = {},
--         session_token = nil
--     }
-- end

-- Optional: Get latest updates
-- function get_latest_updates(page, auth)
--     local url = BASE_URL .. "/latest?page=" .. tostring(page)
--     local html = tsubaki.http.get(url)
--     -- ... parse and return series list
--     return {}
-- end
