local Sources = {}

local HOUR, DAY = 3600, 86400
local HN = "https://hacker-news.firebaseio.com/v0/"
local function record(value) return type(value) == "table" and value or {} end
local function number(value)
    if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
        return value
    end
end
local function text(value) return type(value) == "string" and value ~= "" and value or nil end
local function shortError(value)
    return (text(value) or "Source unavailable"):gsub("[%c]", " "):sub(1, 160)
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function encode(value)
    return (tostring(value):gsub("([^%w%-._~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end
local function requestJSON(url, options)
    return require("dashboardhttp").requestJSON(url, options)
end
local function get(request, url, options)
    local ok, payload, err = pcall(request, url, options)
    if not ok then return nil, shortError(payload) end
    if type(payload) ~= "table" then return nil, shortError(err) end
    if payload.error == true then return nil, shortError(payload.reason) end
    return payload
end

function Sources.defaultWeather()
    return {
        city_name = "新加坡", latitude = 1.27710, longitude = 103.84610,
        timezone = "Asia/Singapore", work_start_hour = 10, work_end_hour = 18,
    }
end

local descriptions = {
    [0] = "晴朗", [1] = "多云", [2] = "多云", [3] = "阴天", [45] = "有雾", [48] = "有雾",
    [51] = "毛毛雨", [53] = "毛毛雨", [55] = "毛毛雨", [56] = "冻雨", [57] = "冻雨",
    [61] = "小雨", [63] = "中雨", [65] = "大雨", [66] = "冻雨", [67] = "冻雨",
    [71] = "小雪", [73] = "中雪", [75] = "大雪", [77] = "雪粒", [80] = "阵雨",
    [81] = "阵雨", [82] = "暴雨", [85] = "阵雪", [86] = "阵雪",
    [95] = "雷雨", [96] = "雷雨", [99] = "雷雨",
}
local precip_types = {
    [51] = "小雨", [53] = "小雨", [55] = "小雨", [56] = "冻雨", [57] = "冻雨",
    [61] = "雨", [63] = "雨", [65] = "雨", [66] = "冻雨", [67] = "冻雨",
    [71] = "雪", [73] = "雪", [75] = "雪", [77] = "雪", [80] = "雨", [81] = "雨",
    [82] = "雨", [85] = "雪", [86] = "雪", [95] = "雷雨", [96] = "雷雨", [99] = "雷雨",
}
local function dayOf(time, offset) return math.floor((time + offset) / DAY) end
local function hourOf(time, offset) return math.floor((time + offset) / HOUR) % 24 end
local function indexTimes(times)
    local result = {}
    -- A nil JSON null must not hide valid later array entries.
    for index, time in pairs(record(times)) do
        if type(index) == "number" and number(time) then result[time] = index end
    end
    return result
end
local function precipAlert(hourly, by_time, current_hour, offset)
    local codes = record(hourly.weather_code)
    local current_code = number(codes[by_time[current_hour]])
    if not descriptions[current_code] then return nil end
    local kind = precip_types[current_code]
    local covered = 0
    for hours = 1, 48 do
        local time = current_hour + hours * HOUR
        local code = number(codes[by_time[time]])
        -- A missing hour cannot establish either dry weather or continued rain.
        if not descriptions[code] then break end
        covered = hours
        if kind and not precip_types[code] then
            return string.format("%dH后%s停", hours, kind)
        elseif not kind and precip_types[code] then
            local next_kind = precip_types[code]
            if hours <= 3 then return string.format("%dH后有%s", hours, next_kind) end
            local days = dayOf(time, offset) - dayOf(current_hour, offset)
            if days == 0 then return string.format("今天%d点有%s", hourOf(time, offset), next_kind) end
            if days == 1 then return string.format("明天%d点有%s", hourOf(time, offset), next_kind) end
            return string.format("%dH后有%s", hours, next_kind)
        end
    end
    if kind and covered > 0 then return string.format("%s将持续至少%dH", kind, covered) end
end

local function parseWeather(payload, settings, now)
    local current, hourly, daily = record(payload.current), record(payload.hourly), record(payload.daily)
    local observed, offset = number(current.time), number(payload.utc_offset_seconds)
    if not observed or not offset or not (number(current.temperature_2m)
        or number(current.weather_code) or number(current.relative_humidity_2m)) then
        return nil, "Weather readings or source timestamp unavailable"
    end
    local current_hour = math.floor((observed + offset) / HOUR) * HOUR - offset
    local by_time, by_day = indexTimes(hourly.time), {}
    for index, time in pairs(record(daily.time)) do
        if type(index) == "number" and number(time) then by_day[dayOf(time, offset)] = index end
    end
    local today = dayOf(observed, offset)
    local today_index, tomorrow_index = by_day[today], by_day[today + 1]
    local hour_index = by_time[current_hour]
    local code = number(current.weather_code)
    local result = {
        location = { name = settings.city_name, timezone = text(payload.timezone) or settings.timezone,
            latitude = settings.latitude, longitude = settings.longitude },
        current = {
            temp = number(current.temperature_2m), humidity = number(current.relative_humidity_2m),
            weather_code = code, desc = descriptions[code],
            rain_chance = number(record(hourly.precipitation_probability)[hour_index]),
            uv = number(record(hourly.uv_index)[hour_index]) or number(current.uv_index),
            high = number(record(daily.temperature_2m_max)[today_index]),
            low = number(record(daily.temperature_2m_min)[today_index]),
            alert = precipAlert(hourly, by_time, current_hour, offset),
        },
        forecast = {}, tomorrow = { label = "明天" },
        fetched_at = now, observed_at = observed, utc_offset_seconds = offset, stale = false,
    }
    local third = current_hour + 3 * HOUR
    local third_day_start = dayOf(third, offset) * DAY - offset
    local work_start = third_day_start + settings.work_start_hour * HOUR
    local work_end = third_day_start + settings.work_end_hour * HOUR
    if third < work_start then third = work_start
    elseif third < work_end then third = work_end end
    for _, time in ipairs({ current_hour + HOUR, current_hour + 2 * HOUR, third }) do
        local index = by_time[time]
        local forecast_code = number(record(hourly.weather_code)[index])
        result.forecast[#result.forecast + 1] = {
            label = string.format("%02d:00", hourOf(time, offset)), time = time,
            temp = number(record(hourly.temperature_2m)[index]),
            weather_code = forecast_code, desc = descriptions[forecast_code],
        }
    end
    if tomorrow_index then
        local tomorrow_code = number(record(daily.weather_code)[tomorrow_index])
        result.tomorrow.high = number(record(daily.temperature_2m_max)[tomorrow_index])
        result.tomorrow.low = number(record(daily.temperature_2m_min)[tomorrow_index])
        result.tomorrow.weather_code = tomorrow_code
        result.tomorrow.desc = descriptions[tomorrow_code]
    end
    return result
end

local function aqiLevel(aqi)
    if not aqi then return nil end
    if aqi <= 50 then return "优"
    elseif aqi <= 100 then return "良"
    elseif aqi <= 150 then return "轻度"
    elseif aqi <= 200 then return "中度"
    elseif aqi <= 300 then return "重度"
    else return "严重" end
end
local function weatherSettings(config)
    local result = Sources.defaultWeather()
    for key, value in pairs(record(config.weather)) do result[key] = value end
    -- Persisted work-hour settings are integers; reject corrupt values locally.
    for _, key in ipairs({ "work_start_hour", "work_end_hour" }) do
        local hour = number(result[key])
        if not hour or hour < 0 or hour > 23 or hour % 1 ~= 0 then
            result[key] = Sources.defaultWeather()[key]
        end
    end
    return result
end
local function fetchWeather(config, previous, request, now)
    local settings = weatherSettings(config)
    local location = { name = settings.city_name, timezone = settings.timezone,
        latitude = settings.latitude, longitude = settings.longitude }
    previous = record(previous)
    local old_location = record(previous.location)
    if old_location.latitude ~= settings.latitude or old_location.longitude ~= settings.longitude
        or old_location.timezone ~= settings.timezone then previous = {} end
    local coords = "latitude=" .. encode(settings.latitude) .. "&longitude=" .. encode(settings.longitude)
        .. "&timezone=" .. encode(settings.timezone) .. "&timeformat=unixtime"
    local payload, err = get(request, "https://api.open-meteo.com/v1/forecast?" .. coords
        .. "&current=temperature_2m,relative_humidity_2m,weather_code"
        .. "&hourly=temperature_2m,weather_code,precipitation_probability,uv_index"
        .. "&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=4",
        { block_timeout = 4, total_timeout = 8 })
    local weather
    if payload then weather, err = parseWeather(payload, settings, now) end
    if not weather then
        weather = copy(previous)
        weather.location, weather.current = location, record(weather.current)
        weather.forecast, weather.tomorrow = record(weather.forecast), record(weather.tomorrow)
        weather.stale, weather.error = true, shortError(err)
    end
    local air, air_err = get(request, "https://air-quality-api.open-meteo.com/v1/air-quality?"
        .. coords .. "&current=us_aqi,pm2_5,pm10", { block_timeout = 3, total_timeout = 6 })
    local readings = record(record(air).current)
    local aqi, pm2_5, pm10 = number(readings.us_aqi), number(readings.pm2_5), number(readings.pm10)
    if air and number(readings.time) and (aqi or pm2_5 or pm10) then
        weather.current.aqi, weather.current.aqi_level = aqi, aqiLevel(aqi)
        weather.current.pm2_5, weather.current.pm10 = pm2_5, pm10
        weather.aqi_observed_at, weather.aqi_fetched_at = readings.time, now
        weather.aqi_stale, weather.aqi_error = false, nil
    else
        local old = record(previous.current)
        for _, key in ipairs({ "aqi", "aqi_level", "pm2_5", "pm10" }) do weather.current[key] = old[key] end
        weather.aqi_observed_at, weather.aqi_fetched_at = previous.aqi_observed_at, previous.aqi_fetched_at
        weather.aqi_stale, weather.aqi_error = true, shortError(air_err or "Air quality readings unavailable")
    end
    return weather
end

local subjective_words = { " i ", " me ", " my ", " how i ", " why i ", "forced me" }
local event_words = { "release", "launch", "announce", "available", "open source", "v1.", "v2.",
    "v3.", "v4.", "gpt", "claude", "llama", "deepseek", "cve-", "zero-day", "hack", "outage" }
local function containsAny(title, words)
    for _, word in ipairs(words) do if title:find(word, 1, true) then return true end end
    return false
end
local function rankNews(top, best, items, now)
    local breaking, sorted_top, seen_top = {}, {}, {}
    for _, id in ipairs(top) do
        local item = items[id]
        if item and not seen_top[id] then
            seen_top[id] = true
            sorted_top[#sorted_top + 1] = item
            local age = item.time and (now - item.time) / HOUR
            if age and age >= 0 and age <= 12 and item.score >= 50 then
                local modifier, lower = 1, item.title:lower()
                if containsAny(lower, subjective_words) then modifier = modifier * 0.4 end
                if containsAny(lower, event_words) then modifier = modifier * 1.5 end
                item.velocity = (item.score + item.comments * 0.2) * modifier / (age + 1.5)^1.8
                breaking[#breaking + 1] = item
            end
        end
    end
    table.sort(breaking, function(a, b)
        if a.velocity == b.velocity then return a.id < b.id end
        return a.velocity > b.velocity
    end)
    table.sort(sorted_top, function(a, b)
        if a.score == b.score then return a.id < b.id end
        return a.score > b.score
    end)
    local result, seen = {}, {}
    local function add(item, is_breaking)
        if not item or seen[item.id] or #result >= 5 then return end
        seen[item.id] = true
        result[#result + 1] = { id = item.id, title = item.title, score = item.score,
            url = item.url, time = item.time, velocity = item.velocity,
            is_breaking = is_breaking or false, is_external = false }
    end
    if breaking[1] and breaking[1].velocity > 30 then add(breaking[1], true) end
    for _, id in ipairs(best) do add(items[id]) end
    for _, item in ipairs(breaking) do add(item) end
    for _, item in ipairs(sorted_top) do add(item) end
    return result
end
local function retainedNews(previous, err)
    local result = copy(record(previous))
    result.items, result.stale, result.error = record(result.items), true, shortError(err)
    return result
end

local function mirroredNews(request, now)
    local base = "https://hn.algolia.com/api/v1/search?hitsPerPage=10"
        .. "&attributesToRetrieve=objectID,title,points,num_comments,created_at_i,url&attributesToHighlight="
    local options = { block_timeout = 4, total_timeout = 8, max_bytes = 256 * 1024 }
    local front, front_err = get(request, base .. "&tags=front_page", options)
    local best, best_err = get(request, base .. "&tags=story&numericFilters=created_at_i%3E"
        .. tostring(now - 7 * DAY), options)
    if not front or not best then return nil, front_err or best_err end
    if type(front.hits) ~= "table" or type(best.hits) ~= "table" then return nil, "Invalid HN mirror response" end
    local top_ids, best_ids, items = {}, {}, {}
    for _, pair in ipairs({ { front.hits, top_ids }, { best.hits, best_ids } }) do
        for index = 1, 10 do
            local hit = record(pair[1][index])
            local id = type(hit.objectID) == "string" and tonumber(hit.objectID) or number(hit.objectID)
            if id and id > 0 and id % 1 == 0 and text(hit.title) and number(hit.created_at_i) then
                pair[2][#pair[2] + 1] = id
                items[id] = { id = id, title = hit.title, score = number(hit.points) or 0,
                    comments = number(hit.num_comments) or 0, time = hit.created_at_i,
                    url = text(hit.url) or ("https://news.ycombinator.com/item?id=" .. string.format("%.0f", id)) }
            end
        end
    end
    local ranked = rankNews(top_ids, best_ids, items, now)
    if #ranked == 0 then return nil, "HN mirror stories unavailable" end
    return { items = ranked, source = "Hacker News", source_name = "Hacker News / Algolia 镜像",
        fetched_at = now, stale = false }
end

local function fetchNews(config, previous, request, now)
    local external = text(config.news_external_url)
    local source = external or "Hacker News"
    previous = record(previous)
    if previous.source ~= source then previous = {} end
    local function mirrorOrRetain(err)
        local mirrored, mirror_err = mirroredNews(request, now)
        return mirrored or retainedNews(previous, (err or "HN unavailable") .. "; 镜像: " .. (mirror_err or "unavailable"))
    end
    if external then
        local payload, err = get(request, external, { block_timeout = 4, total_timeout = 8 })
        if not payload then return retainedNews(previous, err) end
        local items = {}
        for index = 1, 5 do
            local item = record(payload[index])
            if text(item.title) then items[#items + 1] = { title = item.title,
                meta = text(item.meta), is_external = true, is_breaking = false,
                url = text(item.url), time = number(item.time) } end
        end
        if #items == 0 and next(payload) ~= nil then return retainedNews(previous, "Invalid external news list") end
        return { items = items, source = source, fetched_at = now, stale = false }
    end
    -- At most 20 unique item requests, with an overall news deadline. Trapper
    -- supplies cancellation even during DNS resolution in the native resolver.
    local started = os.time()
    local options = { block_timeout = 4, total_timeout = 8, max_bytes = 256 * 1024 }
    local top_payload, top_err = get(request, HN .. "topstories.json", options)
    local best_payload, best_err = get(request, HN .. "beststories.json", options)
    if not top_payload or not best_payload then return mirrorOrRetain(top_err or best_err) end
    local top, best, ids, seen = {}, {}, {}, {}
    for _, pair in ipairs({ { top_payload, top }, { best_payload, best } }) do
        for index = 1, 10 do
            local id = number(pair[1][index])
            if id and id > 0 and id % 1 == 0 then
                pair[2][#pair[2] + 1] = id
                if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
            end
        end
        if #pair[2] == 0 and next(pair[1]) ~= nil then return mirrorOrRetain("Invalid HN story list") end
    end
    local items, failed = {}, false
    for _, id in ipairs(ids) do
        if os.time() - started >= 35 then failed = true; break end
        local payload = get(request, HN .. "item/" .. string.format("%.0f", id) .. ".json", options)
        if not payload then
            failed = true
        elseif not payload.dead and not payload.deleted then
            if payload.id == id and text(payload.title) and (payload.type == nil or payload.type == "story") then
                items[id] = { id = id, title = payload.title, score = number(payload.score) or 0,
                    comments = number(payload.descendants) or 0, time = number(payload.time),
                    url = text(payload.url) or ("https://news.ycombinator.com/item?id=" .. string.format("%.0f", id)) }
            elseif next(payload) ~= nil then failed = true end
        end
    end
    local ranked = rankNews(top, best, items, now)
    if failed then
        local mirrored = mirroredNews(request, now)
        if mirrored then return mirrored end
    end
    if failed and #ranked < 5 and #record(previous.items) > #ranked then
        return retainedNews(previous, "HN stories partially unavailable")
    end
    if failed and #ranked == 0 then return retainedNews(previous, "HN stories unavailable") end
    return { items = ranked, source = source, source_name = "Hacker News / Firebase", fetched_at = now, stale = failed,
        error = failed and "Some HN stories unavailable" or nil }
end

-- Optional transport/clock arguments support deterministic offline source tests.
-- This synchronous work belongs in the main plugin's Trapper subprocess.
function Sources.fetch(config, previous_snapshot, request_json, now)
    config, previous_snapshot = record(config), record(previous_snapshot)
    request_json, now = request_json or requestJSON, now or os.time()
    return {
        weather = fetchWeather(config, previous_snapshot.weather, request_json, now),
        news = fetchNews(config, previous_snapshot.news, request_json, now),
    }
end

function Sources.searchCities(query, request_json)
    query = text(query)
    if not query or not query:find("%S") then return {} end
    local payload, err = get(request_json or requestJSON,
        "https://geocoding-api.open-meteo.com/v1/search?name=" .. encode(query)
        .. "&count=10&language=zh&format=json", { block_timeout = 3, total_timeout = 6 })
    if not payload then return nil, err end
    local cities = {}
    for _, item in ipairs(record(payload.results)) do
        if type(item) == "table" and text(item.name) and number(item.latitude)
            and number(item.longitude) and text(item.timezone) then
            local parts = { item.name }
            if text(item.admin1) and item.admin1 ~= item.name then parts[#parts + 1] = item.admin1 end
            if text(item.country) then parts[#parts + 1] = item.country end
            cities[#cities + 1] = { name = item.name, display_name = table.concat(parts, " · "),
                latitude = item.latitude, longitude = item.longitude, timezone = item.timezone,
                country_code = text(item.country_code) }
        end
    end
    return cities
end

-- Annual official arrangements are data, never inferred from weekend rules.
function Sources.fetchHolidays(year, request_json)
    if not number(year) or year % 1 ~= 0 or year < 1900 or year > 9999 then
        return nil, "Invalid holiday year"
    end
    local payload, err = get(request_json or requestJSON,
        "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/"
            .. string.format("%04d", year) .. ".json",
        { block_timeout = 3, total_timeout = 6, max_bytes = 256 * 1024 })
    if not payload then return nil, err end
    if payload.year ~= year or type(payload.days) ~= "table" or #payload.days == 0
        or type(payload.papers) ~= "table" then
        return nil, "Invalid official holiday data"
    end
    for index, day in pairs(payload.days) do
        if type(index) ~= "number" or index % 1 ~= 0 or index < 1
            or type(day) ~= "table" or not text(day.name)
            or type(day.date) ~= "string"
            or not day.date:match("^" .. string.format("%04d", year) .. "%-%d%d%-%d%d$")
            or type(day.isOffDay) ~= "boolean" then
            return nil, "Invalid official holiday day"
        end
    end
    return payload
end

return Sources
