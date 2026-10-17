-- Run from the repository root: lua tests/market_spec.lua (or luajit).
local directory = (arg[0] or "tests/market_spec.lua"):match("^(.*[/\\])") or ""
local Market = dofile(directory .. "../plugins/kindledashboard.koplugin/market.lua")
local config = Market.defaultConfig()
local spec = config.markets[1]
local passed = 0
local function equal(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function near(actual, expected)
    assert(type(actual) == "number" and math.abs(actual - expected) < 0.000001,
        "expected approximately " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    io.write("ok - " .. name .. "\n")
end
local function chart(market, price, previous_close, date)
    local quote = {}
    for index = 1, 27 do quote[index] = "" end
    local payload = { symbol = market.symbol }
    if market.kind == "gold" then
        quote[1], quote[7], quote[8], quote[13] = tostring(price), "05:30:00", tostring(previous_close), "2026-10-17"
        payload.chart = { minLine_1d = {
            { "2026-10-16", "100", "cme", "", "22:00", "108", "0", "0", "108", "2026-10-16 22:00:00" },
            { "22:05", "109", "0", "0", "109", "2026-10-16 22:05:00" },
        } }
    else
        quote[2], quote[4], quote[27] = tostring(price), date or "2026-10-17 05:30:00", tostring(previous_close)
        payload.chart = {
            { d = "2026-10-16 09:30:00", c = "108" },
            { d = "2026-10-16 09:35:00", c = "109" },
            { d = "2026-10-16 16:00:00", c = "109.5" },
        }
    end
    payload.quote = table.concat(quote, ",")
    return payload
end
local function plain(value)
    local kind = type(value)
    assert(kind == "table" or kind == "string" or kind == "number" or kind == "boolean", kind)
    if kind == "table" then for key, item in pairs(value) do plain(key); plain(item) end end
end

test("day change uses the quoted prior close independently of chart prices", function()
    local entry = assert(Market.parseChart(chart(spec, 110, 100), spec))
    equal(entry.price, 110)
    equal(entry.previous_close, 100)
    equal(entry.change, 10)
    near(entry.change_percent, 10)
    equal(entry.quote_time, 1792186200)
    equal(entry.points[1].t, 1792157400)
    equal(entry.points[3].t, 1792180800)
    equal(entry.points[3].value, 109.5)
    equal(entry.points[4].t, entry.quote_time)
    equal(entry.points[4].value, 110)
    equal(entry.error, nil)
    equal(entry.stale, false)
    plain(entry)
end)

test("New York bars cross daylight saving boundaries independently of local TZ", function()
    local cases = {
        { "2026-03-06 23:00:00", "2026-03-06 09:35:00", 1772807700 },
        { "2026-03-09 22:00:00", "2026-03-09 09:35:00", 1773063300 },
        { "2026-11-02 23:00:00", "2026-11-02 09:35:00", 1793630100 },
    }
    for _, case in ipairs(cases) do
        local payload = chart(spec, 110, 100, case[1])
        payload.chart = { { d = case[2], c = "109" } }
        local entry = assert(Market.parseChart(payload, spec))
        equal(entry.points[1].t, case[3])
        equal(entry.points[1].value, 109)
    end
end)

test("gold metadata rows and minute rows share UTC+8 source time", function()
    local gold = config.markets[2]
    local payload = chart(gold, 110, 100)
    local entry = assert(Market.parseChart(payload, gold))
    equal(entry.price, 110)
    equal(entry.previous_close, 100)
    equal(entry.quote_time, 1792186200)
    equal(entry.points[1].t, 1792159200)
    equal(entry.points[1].value, 108)
    equal(entry.points[2].t, 1792159500)
    equal(entry.points[2].value, 109)
    near(entry.change_percent, 10)
end)

test("invalid and sparse bars leave real gaps without manufacturing zero samples", function()
    local payload = chart(spec, 110, 100)
    payload.chart = {
        [1] = { d = "2026-10-16 09:30:00", c = "108" },
        [3] = { d = "2026-10-16 09:35:00", c = {} },
        [4] = { d = "invalid", c = "999" },
        [5] = { d = "2026-10-16 09:40:00", c = "109" },
        [6] = { d = "2026-10-16 09:45:00", c = "0" },
    }
    local entry = assert(Market.parseChart(payload, spec))
    equal(#entry.points, 3)
    equal(entry.points[1].value, 108)
    equal(entry.points[2].t - entry.points[1].t, 600)
    equal(entry.points[2].value, 109)
    equal(entry.points[3].value, 110)
end)

test("old sessions and future bars cannot enter the current eight-hour window", function()
    local payload = chart(spec, 110, 100)
    payload.chart = {
        { d = "2026-10-15 16:00:00", c = "500" },
        { d = "2026-10-16 09:25:00", c = "600" },
        { d = "2026-10-16 09:30:00", c = "108" },
        { d = "2026-10-16 17:35:00", c = "700" },
        { d = "2026-10-16 09:30:00", c = "108" },
    }
    local entry = assert(Market.parseChart(payload, spec))
    equal(#entry.points, 2)
    equal(entry.points[1].value, 108)
    equal(entry.points[2].value, 110)
end)

test("gold minute history is sampled at five minutes and bounded to 96 points", function()
    local gold = config.markets[2]
    local payload = chart(gold, 110, 100)
    payload.chart.minLine_1d = {}
    for hour = 21, 23 do
        for minute = 0, 59 do
            payload.chart.minLine_1d[#payload.chart.minLine_1d + 1] = {
                string.format("%02d:%02d", hour, minute), tostring(100 + minute / 100), "0", "0", "100",
                string.format("2026-10-16 %02d:%02d:00", hour, minute),
            }
        end
    end
    for hour = 0, 5 do
        for minute = 0, 59 do
            payload.chart.minLine_1d[#payload.chart.minLine_1d + 1] = {
                string.format("%02d:%02d", hour, minute), "105", "0", "0", "105",
                string.format("2026-10-17 %02d:%02d:00", hour, minute),
            }
        end
    end
    local entry = assert(Market.parseChart(payload, gold))
    equal(#entry.points, 96)
    equal(entry.points[#entry.points].t, entry.quote_time)
    equal(entry.points[#entry.points].value, 110)
    equal(entry.points[2].t - entry.points[1].t, 300)
    assert(entry.points[1].t >= entry.quote_time - 8 * 3600)
end)

test("chart failure preserves a current quote and flags unavailable history", function()
    local payload = chart(spec, 110, 100)
    payload.chart, payload.chart_error = nil, "HTTP 503"
    local entry = assert(Market.parseChart(payload, spec))
    equal(entry.price, 110)
    equal(entry.quote_time, 1792186200)
    equal(entry.error, "HTTP 503")
    equal(entry.stale, false)
    equal(#entry.points, 1)
    equal(entry.points[1].value, 110)
end)

test("invalid prices, missing timestamps and mismatched symbols stay unavailable", function()
    for _, price in ipairs({ 0, -1, math.huge, -math.huge, 0 / 0, false, {} }) do
        equal(Market.parseChart(chart(spec, price, 100), spec), nil)
    end
    equal(Market.parseChart(chart(spec, 110, 100, ""), spec), nil)
    local payload = chart(spec, 110, 100)
    payload.symbol = ".OTHER"
    equal(Market.parseChart(payload, spec), nil)
    equal(Market.parseChart({}, spec), nil)
end)

test("missing previous close never turns the first chart point into day change", function()
    local entry = assert(Market.parseChart(chart(spec, 110, 0), spec))
    equal(entry.price, 110)
    equal(entry.previous_close, nil)
    equal(entry.change, nil)
    equal(entry.change_percent, nil)
    equal(entry.error, "Previous close unavailable")
end)

test("partial source failures retain only the failed symbol while other quotes advance", function()
    local initial = Market.fetch(config, nil, function(market) return chart(market, 110, 100) end)
    local updated = Market.fetch(config, initial, function(market)
        if market.id == "gold" then return nil, "HTTP 503" end
        return chart(market, 125, 100)
    end)
    equal(updated.entries[1].price, 125)
    equal(updated.entries[1].stale, false)
    equal(updated.entries[2].price, 110)
    equal(updated.entries[2].quote_time, initial.entries[2].quote_time)
    equal(updated.entries[2].error, "HTTP 503")
    equal(updated.entries[2].stale, true)
    equal(updated.entries[3].price, 125)
    updated.entries[2].points[1].value = 999
    equal(initial.entries[2].points[1].value, 108)
    plain(updated)
end)

test("retention follows symbol identity and first failures invent no quote", function()
    local initial = Market.fetch(config, nil, function(market) return chart(market, market.id == "gold" and 2000 or 110, 100) end)
    initial.entries = { initial.entries[3], initial.entries[1], initial.entries[2] }
    local failed = Market.fetch(config, initial, function() return nil, "Offline" end)
    equal(failed.entries[1].price, 110)
    equal(failed.entries[2].price, 2000)
    equal(failed.entries[3].price, 110)
    local changed = Market.defaultConfig()
    changed.markets[1].symbol = "OTHER"
    failed = Market.fetch(changed, initial, function() return nil, "Offline" end)
    equal(failed.entries[1].price, nil)
    equal(failed.entries[1].quote_time, nil)
    equal(#failed.entries[1].points, 0)
    local fresh = Market.fetch(config, nil, function() error("TLS failure") end)
    for _, entry in ipairs(fresh.entries) do
        equal(entry.price, nil)
        equal(entry.quote_time, nil)
        equal(entry.change_percent, nil)
        assert(entry.error:find("TLS failure", 1, true))
    end
end)

io.write(tostring(passed) .. " market tests passed\n")
