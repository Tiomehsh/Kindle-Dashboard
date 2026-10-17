-- Run from the repository root: lua tests/sources_spec.lua (or luajit).
-- Deterministic, offline; no KOReader, network or JSON dependency required.
local directory = (arg[0] or "tests/sources_spec.lua"):match("^(.*[/\\])") or ""
local Sources = dofile(directory .. "../plugins/kindledashboard.koplugin/sources.lua")
local passed = 0
local HOUR, DAY, OFFSET = 3600, 86400, 8 * 3600
local MIDNIGHT = 1735603200 - OFFSET -- 2024-12-31, location-local midnight.
local function equal(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    io.write("ok - " .. name .. "\n")
end
local function plain(value)
    local kind = type(value)
    assert(kind == "table" or kind == "string" or kind == "number" or kind == "boolean", kind)
    if kind == "table" then for key, item in pairs(value) do plain(key); plain(item) end end
end
local function weather(hour)
    local payload = {
        timezone = "Asia/Singapore", utc_offset_seconds = OFFSET,
        current = { time = MIDNIGHT + hour * HOUR + 900, temperature_2m = 28,
            relative_humidity_2m = 78, weather_code = 2 },
        hourly = { time = {}, temperature_2m = {}, weather_code = {},
            precipitation_probability = {}, uv_index = {} },
        daily = { time = { MIDNIGHT, MIDNIGHT + DAY, MIDNIGHT + DAY * 2, MIDNIGHT + DAY * 3 },
            temperature_2m_max = { 32, 33, 34, 35 }, temperature_2m_min = { 24, 25, 26, 27 },
            weather_code = { 2, 61, 3, 0 } },
    }
    for index = 1, 96 do
        payload.hourly.time[index] = MIDNIGHT + (index - 1) * HOUR
        payload.hourly.temperature_2m[index] = 20 + index / 10
        payload.hourly.weather_code[index] = 2
        payload.hourly.precipitation_probability[index] = index - 1
        payload.hourly.uv_index[index] = 1.5
    end
    return payload
end
local function air(time, aqi)
    return { current = { time = time, us_aqi = aqi or 42, pm2_5 = 8.5, pm10 = 12 } }
end
local function fetchWeather(payload, previous, air_payload, settings)
    return Sources.fetch({ weather = settings or Sources.defaultWeather() }, previous,
        function(url)
            if url:find("/v1/forecast?", 1, true) then
                assert(url:find("timeformat=unixtime", 1, true))
                assert(url:find("forecast_days=4", 1, true))
                return payload, "Weather offline"
            elseif url:find("/v1/air-quality?", 1, true) then return air_payload, "Air offline"
            end
            return {}, nil -- empty HN lists
        end, MIDNIGHT + 23 * HOUR)
end
local function story(id, score, age, title)
    return { id = id, type = "story", score = score or 20, descendants = 10,
        time = MIDNIGHT + DAY - (age or 24) * HOUR, title = title or ("Story " .. id) }
end
local function newsFixture(top, best, items, previous, failure)
    local requests = {}
    local result = Sources.fetch({}, previous, function(url)
        if url:find("topstories.json", 1, true) then return top, "Top unavailable" end
        if url:find("beststories.json", 1, true) then return best, "Best unavailable" end
        local id = tonumber(url:match("/item/(%d+)%.json"))
        if id then
            requests[#requests + 1] = id
            if failure == id then return nil, "Item offline" end
            return items[id], "Item unavailable"
        end
        return nil, "Weather offline"
    end, MIDNIGHT + DAY)
    return result.news, requests
end

test("city configuration instances do not share mutations", function()
    local one, two = Sources.defaultWeather(), Sources.defaultWeather()
    one.city_name, one.work_start_hour = "Changed", 6
    assert(two.city_name ~= "Changed")
    assert(two.work_start_hour ~= 6)
end)

test("current-hour rain and hourly UV use source time rather than midnight or host clock", function()
    local payload = weather(15)
    payload.hourly.precipitation_probability[1] = 99
    payload.hourly.precipitation_probability[16] = 17
    payload.hourly.uv_index[16] = 0
    local result = fetchWeather(payload, nil, air(payload.current.time, 0)).weather
    equal(result.current.rain_chance, 17)
    equal(result.current.uv, 0)
    equal(result.current.aqi, 0)
    equal(result.current.aqi_level, "优")
    equal(result.current.high, 32)
    equal(result.current.low, 24)
    equal(result.observed_at, payload.current.time)
    equal(result.stale, false)
    equal(result.aqi_stale, false)
    plain(result)
end)

test("smart third slot selects commute start then end then ordinary hour", function()
    local cases = { { 5, "06:00", "07:00", "10:00" },
        { 8, "09:00", "10:00", "18:00" }, { 15, "16:00", "17:00", "18:00" },
        { 18, "19:00", "20:00", "21:00" } }
    for _, case in ipairs(cases) do
        local result = fetchWeather(weather(case[1])).weather
        equal(#result.forecast, 3)
        for index = 1, 3 do equal(result.forecast[index].label, case[index + 1]) end
    end
end)

test("midnight and year rollover select the next day's commute and tomorrow's daily entry", function()
    local payload = weather(23)
    local result = fetchWeather(payload).weather
    equal(result.forecast[1].label, "00:00")
    equal(result.forecast[1].time, MIDNIGHT + DAY)
    equal(result.forecast[1].temp, payload.hourly.temperature_2m[25])
    equal(result.forecast[2].label, "01:00")
    equal(result.forecast[3].label, "10:00")
    equal(result.forecast[3].time, MIDNIGHT + DAY + 10 * HOUR)
    equal(result.tomorrow.high, 33)
    equal(result.tomorrow.low, 25)
    equal(result.tomorrow.desc, "小雨")
    payload = weather(24)
    result = fetchWeather(payload).weather
    equal(result.current.high, 33)
    equal(result.tomorrow.high, 34)
end)

test("forecast and daily null gaps keep later readings aligned without fabricated zeroes", function()
    for _, null in ipairs({ {}, function() end, false }) do
        local payload = weather(23)
        payload.current.relative_humidity_2m = null
        payload.hourly.temperature_2m[25] = null
        payload.hourly.weather_code[25] = null
        payload.hourly.precipitation_probability[24] = null
        payload.hourly.uv_index[24] = null
        payload.daily.temperature_2m_min[2] = null
        local result = fetchWeather(payload).weather
        equal(result.current.humidity, nil)
        equal(result.current.rain_chance, nil)
        equal(result.current.uv, nil)
        equal(result.forecast[1].temp, nil)
        equal(result.forecast[1].desc, nil)
        equal(result.forecast[2].temp, payload.hourly.temperature_2m[26])
        equal(result.tomorrow.low, nil)
        equal(result.tomorrow.high, 33)
        plain(result)
    end
    local payload = weather(23)
    payload.hourly.time[25], payload.hourly.temperature_2m[25] = nil, nil
    payload.daily.time[1] = nil
    local result = fetchWeather(payload).weather
    equal(result.forecast[1].temp, nil)
    equal(result.forecast[2].temp, payload.hourly.temperature_2m[26])
    equal(result.current.high, nil)
    equal(result.tomorrow.high, 33)
end)

test("rain start and stop timing crosses midnight and uses the full 48-hour window", function()
    local payload = weather(23)
    payload.hourly.weather_code[26] = 71
    equal(fetchWeather(payload).weather.current.alert, "2H后有雪")
    payload.hourly.weather_code[26] = 2
    payload.hourly.weather_code[30] = 61
    equal(fetchWeather(payload).weather.current.alert, "明天5点有雨")
    payload.hourly.weather_code[30] = 2
    payload.hourly.weather_code[72] = 95
    equal(fetchWeather(payload).weather.current.alert, "48H后有雷雨")
    payload.hourly.weather_code[72], payload.hourly.weather_code[73] = 2, 61
    equal(fetchWeather(payload).weather.current.alert, nil)
    for index = 24, 27 do payload.hourly.weather_code[index] = 61 end
    equal(fetchWeather(payload).weather.current.alert, "4H后雨停")
    for index = 24, 72 do payload.hourly.weather_code[index] = 61 end
    equal(fetchWeather(payload).weather.current.alert, "雨将持续至少48H")
end)

test("unknown precipitation gaps never claim rain stops or starts beyond missing coverage", function()
    local payload = weather(10)
    payload.hourly.weather_code[11], payload.hourly.weather_code[12] = 61, nil
    equal(fetchWeather(payload).weather.current.alert, nil)
    payload.hourly.weather_code[11], payload.hourly.weather_code[13] = 2, 61
    equal(fetchWeather(payload).weather.current.alert, nil)
end)

test("failed air retains original air time while weather advances independently", function()
    local initial_payload = weather(10)
    local initial = fetchWeather(initial_payload, nil, air(initial_payload.current.time))
    local next_payload = weather(11)
    next_payload.current.temperature_2m = 30
    local result = fetchWeather(next_payload, initial).weather
    equal(result.current.temp, 30)
    equal(result.observed_at, next_payload.current.time)
    equal(result.stale, false)
    equal(result.current.aqi, 42)
    equal(result.aqi_stale, true)
    equal(result.aqi_observed_at, initial.weather.aqi_observed_at)
    assert(result.aqi_error)
    equal(initial.weather.aqi_stale, false)
    result = fetchWeather(nil, initial, air(next_payload.current.time, 71)).weather
    equal(result.current.temp, initial.weather.current.temp)
    equal(result.observed_at, initial.weather.observed_at)
    equal(result.fetched_at, initial.weather.fetched_at)
    equal(result.stale, true)
    equal(result.current.aqi, 71)
    equal(result.aqi_stale, false)
    equal(result.aqi_observed_at, next_payload.current.time)
end)

test("first failure and all-null air have no invented observations", function()
    local result = fetchWeather(nil, nil, { current = { time = MIDNIGHT, us_aqi = {}, pm10 = false } }).weather
    equal(result.current.temp, nil)
    equal(result.current.aqi, nil)
    equal(result.observed_at, nil)
    equal(result.aqi_observed_at, nil)
    equal(result.stale, true)
    equal(result.aqi_stale, true)
    plain(result)
end)

test("changing city cannot inherit stale readings from the old location", function()
    local initial = fetchWeather(weather(10), nil, air(MIDNIGHT))
    local settings = Sources.defaultWeather()
    settings.latitude, settings.longitude, settings.city_name = 51.5, -0.1, "伦敦"
    local result = fetchWeather(nil, initial, nil, settings).weather
    equal(result.current.temp, nil)
    equal(result.current.aqi, nil)
    equal(result.location.name, "伦敦")
end)

test("HN inserts one qualified breaker then best order with deduplication", function()
    local items = {}
    for id = 1, 8 do items[id] = story(id, 20, 24) end
    items[1] = story(1, 300, 1, "New release available")
    local news, requests = newsFixture({ 1, 2, 3, 4 }, { 2, 1, 5, 6, 7, 8 }, items)
    equal(#news.items, 5)
    equal(news.items[1].id, 1)
    equal(news.items[1].is_breaking, true)
    equal(news.items[2].id, 2)
    equal(news.items[3].id, 5)
    equal(news.items[4].id, 6)
    equal(news.items[5].id, 7)
    equal(news.items[2].is_breaking, false)
    equal(news.items[1].title, "New release available")
    equal(news.items[1].time, items[1].time)
    local seen = {}
    for _, item in ipairs(news.items) do assert(not seen[item.id]); seen[item.id] = true end
    equal(news.stale, false)
    plain(news)
end)

test("HN semantic penalty and event boost determine breaker ahead of best", function()
    local items = {
        [1] = story(1, 200, 1, "What my laptop forced me to do"),
        [2] = story(2, 150, 1, "Project release available"),
        [3] = story(3, 500, 24, "Yesterday's popular story"),
        [4] = story(4), [5] = story(5), [6] = story(6),
    }
    local news = newsFixture({ 1, 2, 3 }, { 3, 4, 5, 6 }, items)
    equal(news.items[1].id, 2)
    equal(news.items[1].is_breaking, true)
    equal(news.items[2].id, 3)
    -- A score below 50 cannot displace best even when very new.
    items[2].score, items[1].score = 49, 49
    news = newsFixture({ 1, 2, 3 }, { 3, 4, 5, 6 }, items)
    equal(news.items[1].id, 3)
    equal(news.items[1].is_breaking, false)
end)

test("HN filters deleted stories and fills short best lists from breakers then top score", function()
    local items = { [1] = story(1, 100, 8), [2] = story(2, 40, 24),
        [3] = story(3, 20, 24), [4] = story(4, 30, 24), [5] = story(5),
        [6] = story(6), [7] = story(7) }
    items[6].dead, items[7].deleted = true, true
    local news = newsFixture({ 1, 2, 3, 4, 6, 7 }, { 5 }, items)
    equal(#news.items, 5)
    for index, id in ipairs({ 5, 1, 2, 4, 3 }) do equal(news.items[index].id, id) end
    for _, item in ipairs(news.items) do equal(item.is_breaking, false) end
end)


test("failed feeds or incomplete item responses retain prior headlines and fetch time", function()
    local items = {}
    for id = 1, 5 do items[id] = story(id) end
    local initial = newsFixture({ 1, 2, 3, 4, 5 }, { 1, 2, 3, 4, 5 }, items)
    local previous = { news = initial }
    local result = newsFixture(nil, { 1 }, items, previous)
    equal(#result.items, 5)
    equal(result.stale, true)
    equal(result.fetched_at, initial.fetched_at)
    equal(result.items[1].title, initial.items[1].title)
    result = newsFixture({ 1, 2, 3, 4, 5 }, { 1, 2, 3, 4, 5 }, items, previous, 3)
    equal(#result.items, 5)
    equal(result.stale, true)
    equal(result.fetched_at, initial.fetched_at)
    result.items[1].title = "changed"
    assert(initial.items[1].title ~= "changed")
    equal(initial.stale, false)
end)

test("unreachable Firebase switches to mirror stories with original metadata and deduplication", function()
    local function hit(id, score, title)
        return { objectID = tostring(id), title = title or ("Mirror story " .. id), points = score or 20,
            num_comments = 10, created_at_i = MIDNIGHT, url = "https://example.org/" .. id }
    end
    local result = Sources.fetch({}, nil, function(url)
        if url:find("hn.algolia.com", 1, true) then
            if url:find("tags=front_page", 1, true) then
                return { hits = { hit(1), hit(2) } }
            end
            return { hits = { hit(2, 100, "Original title"), hit(3), hit(4), hit(5), hit(6) } }
        end
        return nil, "Blocked"
    end, MIDNIGHT + DAY).news
    equal(#result.items, 5)
    equal(result.items[1].id, 2)
    equal(result.items[1].title, "Original title")
    equal(result.items[1].score, 100)
    equal(result.items[1].time, MIDNIGHT)
    equal(result.items[1].url, "https://example.org/2")
    equal(result.source_name, "Hacker News / Algolia 镜像")
    equal(result.stale, false)
    local seen = {}
    for _, item in ipairs(result.items) do assert(not seen[item.id]); seen[item.id] = true end
    plain(result)
end)

test("invalid or unreachable mirrors preserve headlines and their original fetch time", function()
    local items = {}
    for id = 1, 5 do items[id] = story(id) end
    local initial = newsFixture({ 1, 2, 3, 4, 5 }, { 1, 2, 3, 4, 5 }, items)
    local result = Sources.fetch({}, { news = initial }, function(url)
        if url:find("hn.algolia.com", 1, true) then
            return { hits = { { objectID = {}, title = "Malformed", created_at_i = MIDNIGHT } } }
        end
        return nil, "Blocked"
    end, MIDNIGHT + DAY + HOUR).news
    equal(result.items[1].title, initial.items[1].title)
    equal(result.fetched_at, initial.fetched_at)
    equal(result.stale, true)
    assert(result.error:find("镜像", 1, true))
    result.items[1].title = "Changed"
    assert(initial.items[1].title ~= "Changed")
end)

test("external JSON news preserves meta and stale retention", function()
    local config = { news_external_url = "https://example.org/news.json" }
    local result = Sources.fetch(config, nil, function(url)
        if url == config.news_external_url then return { { title = "Original title", meta = "Source · 10:30" } } end
        return nil, "Offline"
    end, MIDNIGHT)
    equal(result.news.items[1].title, "Original title")
    equal(result.news.items[1].meta, "Source · 10:30")
    equal(result.news.items[1].is_external, true)
    equal(result.news.stale, false)
    local updated = Sources.fetch(config, result, function() return nil, "Offline" end, MIDNIGHT + HOUR)
    equal(updated.news.items[1].meta, "Source · 10:30")
    equal(updated.news.fetched_at, MIDNIGHT)
    equal(updated.news.stale, true)
end)

test("native city search escapes queries and ignores unusable locations", function()
    local results = Sources.searchCities("New York & 北京", function(url, options)
        assert(url:find("name=New%20York%20%26%20", 1, true))
        return { results = { { name = "纽约", admin1 = "纽约州", country = "美国", country_code = "US",
            latitude = 40.7, longitude = -74, timezone = "America/New_York" },
            { name = "Broken", latitude = {}, longitude = 0 } } }
    end)
    equal(#results, 1)
    equal(results[1].display_name, "纽约 · 纽约州 · 美国")
    equal(results[1].timezone, "America/New_York")
    equal(results[1].longitude, -74)
    local failed, err = Sources.searchCities("Paris", function() return nil, "Search offline" end)
    equal(failed, nil)
    equal(err, "Search offline")
    equal(#Sources.searchCities(" "), 0)
end)

test("annual holidays validate source year and individual day records", function()
    local payload = { year = 2027, papers = { "https://www.gov.cn/notice" },
        days = { { name = "元旦", date = "2027-01-01", isOffDay = true },
            { name = "元旦", date = "2027-01-02", isOffDay = false } } }
    local result = Sources.fetchHolidays(2027, function(url, options)
        equal(url, "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/2027.json")
        equal(options.total_timeout, 6)
        return payload
    end)
    equal(result, payload)
    equal(result.days[2].isOffDay, false)
    payload.year = 2026
    equal(Sources.fetchHolidays(2027, function() return payload end), nil)
    payload.year, payload.days[1].isOffDay = 2027, "true"
    equal(Sources.fetchHolidays(2027, function() return payload end), nil)
    equal(Sources.fetchHolidays(2027, function() return nil, "HTTP 404" end), nil)
    equal(Sources.fetchHolidays("2027", function() error("must not request") end), nil)
end)

test("HTTPS checks each URL hostname, limits wildcards and restores native timeouts", function()
    local HTTP = dofile(directory .. "../plugins/kindledashboard.koplugin/dashboardhttp.lua")
    local modules = { "socket.http", "ssl.https", "socketutil", "json" }
    local saved = {}
    for _, name in ipairs(modules) do saved[name] = package.loaded[name] end
    local socketutil = { block_timeout = 60, total_timeout = -1 }
    function socketutil:set_timeout(block, total) self.block_timeout, self.total_timeout = block, total end
    function socketutil.table_sink(chunks)
        return function(chunk) if chunk then chunks[#chunks + 1] = chunk end; return 1 end
    end
    local certificate_names, did_send, closed, raise_request
    local http = {}
    function http.request(request)
        if raise_request then error("network exception") end
        equal(request.cafile, "data/ca-bundle.crt")
        equal(request.verify, "peer")
        equal(request.redirect, false)
        local connection = request.create()
        local connected, err = connection:connect(request.url:match("^https://([^/]+)"), 443)
        if not connected then return nil, err end
        did_send = true
        request.sink("{}")
        return 1, 200
    end
    local https = {}
    function https.tcp()
        return function()
            return { connect = function() return 1 end,
                getpeercertificate = function()
                    return { extensions = function() return { ["2.5.29.17"] = { dNSName = certificate_names } } end }
                end,
                close = function() closed = true end }
        end
    end
    package.loaded["socket.http"], package.loaded["ssl.https"] = http, https
    package.loaded.socketutil, package.loaded.json = socketutil, { decode = function() return {} end }
    local ok, err = pcall(function()
        for _, host in ipairs({ "api.open-meteo.com", "air-quality-api.open-meteo.com",
            "hacker-news.firebaseio.com", "query2.finance.yahoo.com", "raw.githubusercontent.com" }) do
            certificate_names, did_send = { host }, false
            assert(HTTP.requestJSON("https://" .. host .. "/data"))
            equal(did_send, true)
            equal(socketutil.block_timeout, 60)
            equal(socketutil.total_timeout, -1)
        end
        certificate_names = { "*.open-meteo.com" }
        assert(HTTP.requestJSON("https://api.open-meteo.com/data"))
        did_send, closed = false, false
        equal(HTTP.requestJSON("https://nested.api.open-meteo.com/data"), nil)
        equal(did_send, false)
        equal(closed, true)
        certificate_names, did_send = { "query2.finance.yahoo.com" }, false
        equal(HTTP.requestJSON("https://api.open-meteo.com/data"), nil)
        equal(did_send, false)
        equal(HTTP.requestJSON("http://example.org/news"), nil)
        equal(HTTP.requestJSON("https://user:password@example.org/news"), nil)
        raise_request = true
        equal(HTTP.requestJSON("https://api.open-meteo.com/data"), nil)
        equal(socketutil.block_timeout, 60)
        equal(socketutil.total_timeout, -1)
    end)
    for _, name in ipairs(modules) do package.loaded[name] = saved[name] end
    assert(ok, err)
end)

io.write(tostring(passed) .. " source tests passed\n")
