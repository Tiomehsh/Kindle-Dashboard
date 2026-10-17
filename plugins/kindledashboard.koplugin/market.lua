local Market = {}

local SOURCE = "新浪财经"
local MAX_POINTS = 96
local TREND_SECONDS = 8 * 60 * 60
local OFFSET = 8 * 3600

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end
local function number(value)
    if type(value) ~= "number" and type(value) ~= "string" then return end
    value = tonumber(value)
    if finite(value) then return value end
end
local function positive(value) return finite(value) and value > 0 end
local function record(value) return type(value) == "table" and value or {} end
local function text(value) return type(value) == "string" and value ~= "" and value or nil end
local function shortError(message)
    return (text(message) or "Market data unavailable"):gsub("[%c]", " "):sub(1, 160)
end

-- Gregorian civil date to Unix day; independent of the Kindle's local timezone.
local function civilDay(year, month, day)
    local a = math.floor((14 - month) / 12)
    local y, m = year + 4800 - a, month + 12 * a - 3
    return day + math.floor((153 * m + 2) / 5) + 365 * y + math.floor(y / 4)
        - math.floor(y / 100) + math.floor(y / 400) - 32045 - 2440588
end
local function timestamp(value, new_york)
    if type(value) ~= "string" then return end
    local y, m, d, h, minute, second = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)$")
    y, m, d, h, minute, second = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(minute), tonumber(second)
    if not y or m < 1 or m > 12 or d < 1 or d > 31 or h > 23 or minute > 59 or second > 59 then return end
    local offset = OFFSET
    if new_york then
        -- US daylight saving: second Sunday in March through first Sunday in November.
        local march = 8 + (7 - (civilDay(y, 3, 1) + 4) % 7) % 7
        local november = 1 + (7 - (civilDay(y, 11, 1) + 4) % 7) % 7
        local dst = (m > 3 or (m == 3 and (d > march or (d == march and h >= 2))))
            and (m < 11 or (m == 11 and (d < november or (d == november and h < 2))))
        offset = (dst and -4 or -5) * 3600
    end
    return civilDay(y, m, d) * 86400 + h * 3600 + minute * 60 + second - offset
end
local function fields(value)
    local result = {}
    for field in ((text(value) or "") .. ","):gmatch("(.-),") do result[#result + 1] = field end
    return result
end
local function emptyEntry(spec)
    return { id = spec.id, name = spec.name, symbol = spec.symbol, unit = spec.unit,
        points = {}, source_name = SOURCE, stale = false }
end

function Market.defaultConfig()
    return {
        refresh_seconds = 300,
        markets = {
            { id = "nasdaq", name = "纳斯达克综合指数", symbol = ".IXIC", quote_key = "gb_ixic", kind = "us", unit = "点" },
            { id = "gold", name = "纽约黄金 CFD", symbol = "GC", quote_key = "hf_GC", kind = "gold", unit = "USD/金衡盎司" },
            { id = "sp500", name = "标普 500 指数", symbol = ".INX", quote_key = "gb_inx", kind = "us", unit = "点" },
        },
    }
end

-- Normalize verified Sina quotes and chart JSON; never execute its quote script.
function Market.parseChart(payload, spec)
    payload = record(payload)
    if payload.symbol ~= spec.symbol then return nil, "Response symbol does not match request" end
    local quote = fields(payload.quote)
    local price, previous_close, quote_time
    if spec.kind == "gold" then
        price, previous_close = number(quote[1]), number(quote[8])
        quote_time = timestamp((quote[13] or "") .. " " .. (quote[7] or ""))
    else
        price, previous_close = number(quote[2]), number(quote[27])
        quote_time = timestamp(quote[4])
    end
    if not positive(price) or not positive(quote_time) then return nil, "Quote or quote timestamp unavailable" end
    local entry = emptyEntry(spec)
    entry.price, entry.quote_time, entry.currency = price, quote_time, "USD"
    if positive(previous_close) then
        entry.previous_close = previous_close
        local change = price - previous_close
        local percent = change / previous_close * 100
        if finite(change) and finite(percent) then
            entry.change, entry.change_percent = change, percent
        else
            entry.error = "Day change unavailable"
        end
    else
        entry.error = "Previous close unavailable"
    end
    local samples = {}
    local chart = spec.kind == "gold" and record(record(payload.chart).minLine_1d) or record(payload.chart)
    for _, item in pairs(chart) do
        if type(item) == "table" then
            local time, value
            if spec.kind == "gold" then
                time = timestamp(item[10] or item[6])
                value = number(item[10] and item[6] or item[2])
            else
                time, value = timestamp(item.d, true), number(item.c)
            end
            if positive(time) and positive(value) and time >= quote_time - TREND_SECONDS
                and time <= quote_time and time % 300 == 0 then
                samples[#samples + 1] = { t = time, value = value }
            end
        end
    end
    table.sort(samples, function(a, b) return a.t < b.t end)
    if #samples == 0 then entry.error = entry.error or shortError(payload.chart_error or "Intraday trend unavailable") end
    local recent = {}
    for _, point in ipairs(samples) do
        if recent[#recent] and recent[#recent].t == point.t then
            recent[#recent] = point
        else
            recent[#recent + 1] = point
        end
    end
    -- The last marker is a real, timestamped quote, independent of the last bar.
    if recent[#recent] and recent[#recent].t == quote_time then
        recent[#recent].value = price
    else
        recent[#recent + 1] = { t = quote_time, value = price }
    end
    for index = math.max(1, #recent - MAX_POINTS + 1), #recent do
        entry.points[#entry.points + 1] = recent[index]
    end
    return entry
end

local function productionRequest(config)
    local HTTP = require("dashboardhttp")
    local options = { block_timeout = 8, total_timeout = 20, max_bytes = 512 * 1024,
        referer = "https://finance.sina.com.cn/", protocol = "tlsv1_2" }
    local keys = {}
    for _, spec in ipairs(config.markets) do keys[#keys + 1] = spec.quote_key end
    local quotes, quote_error = HTTP.requestText("https://hq.sinajs.cn/list=" .. table.concat(keys, ","), options)
    return function(spec)
        if not quotes then return nil, quote_error end
        local quote = quotes:match('var hq_str_' .. spec.quote_key .. '="([^"]*)";')
        if not text(quote) then return nil, "Quote unavailable" end
        local url
        if spec.kind == "gold" then
            url = "https://stock2.finance.sina.com.cn/futures/api/json_v2.php/GlobalFuturesService.getGlobalFuturesMinLine?symbol=" .. HTTP.encode(spec.symbol)
        else
            url = "https://stock.finance.sina.com.cn/usstock/api/json_v2.php/US_MinKService.getMinK?symbol=" .. HTTP.encode(spec.symbol) .. "&type=5"
        end
        local chart, err = HTTP.requestJSON(url, options)
        return { symbol = spec.symbol, quote = quote, chart = chart, chart_error = err }
    end
end

local function preservedEntry(spec, previous, err)
    local entry = emptyEntry(spec)
    entry.error, entry.stale = shortError(err), true
    if previous and previous.symbol == spec.symbol and positive(previous.price) and positive(previous.quote_time) then
        entry.price, entry.quote_time = previous.price, previous.quote_time
        entry.currency = text(previous.currency)
        entry.previous_close = positive(previous.previous_close) and previous.previous_close or nil
        if entry.previous_close then
            local change = entry.price - entry.previous_close
            local percent = change / entry.previous_close * 100
            if finite(change) and finite(percent) then entry.change, entry.change_percent = change, percent end
        end
        entry.source_name = text(previous.source_name) or SOURCE
        local points = record(previous.points)
        for index = math.max(1, #points - MAX_POINTS + 1), #points do
            local point = record(points[index])
            if positive(point.t) and positive(point.value) then
                entry.points[#entry.points + 1] = { t = point.t, value = point.value }
            end
        end
    end
    return entry
end

-- Blocking transport belongs in Trapper's dismissable subprocess.
function Market.fetch(config, previous_snapshot, request_chart)
    config = config or Market.defaultConfig()
    request_chart = request_chart or productionRequest(config)
    local previous_by_id = {}
    for _, entry in ipairs(record(record(previous_snapshot).entries)) do
        if type(entry) == "table" and entry.id then previous_by_id[entry.id] = entry end
    end
    local snapshot = { entries = {} }
    for _, spec in ipairs(config.markets) do
        local ok, payload, err = pcall(request_chart, spec)
        local entry
        if ok and payload then entry, err = Market.parseChart(payload, spec)
        elseif not ok then err = payload end
        snapshot.entries[#snapshot.entries + 1] = entry or preservedEntry(spec, previous_by_id[spec.id], err)
    end
    snapshot.fetched_at = os.time()
    return snapshot
end

return Market
