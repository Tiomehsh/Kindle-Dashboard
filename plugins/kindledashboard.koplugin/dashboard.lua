local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function timestamp(value, short)
    if not finite(value) or value <= 0 then return "--" end
    -- Source timestamps are explicitly UTC+8, independently of the device TZ.
    return os.date(short and "!%H:%M" or "!%m/%d %H:%M", value + 28800)
end

local function number(value, suffix, decimals)
    if not finite(value) then return "--" end
    return string.format("%." .. (decimals or 0) .. "f", value) .. (suffix or "")
end

local function amount(value)
    if not finite(value) then return "--" end
    local text = string.format("%.2f", math.abs(value))
    local integer, fraction = text:match("^(%d+)(%.%d+)$")
    if integer then
        integer = integer:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
        text = integer .. fraction
    end
    return (value < 0 and "-" or "") .. text
end

local function clean(value)
    return value == nil and "" or tostring(value):gsub("[%c]", " ")
end

-- Fixed native child positions keep all four panels visible in both rotations.
-- Numeric children retain KOReader's event propagation and recursive free().
local Layout = WidgetContainer:extend{}

function Layout:init()
    self.positions = {}
end

function Layout:add(widget, x, y)
    self[#self + 1] = widget
    self.positions[#self] = { x = x, y = y }
    return widget
end

function Layout:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    for index, child in ipairs(self) do
        local position = self.positions[index]
        child:paintTo(bb, x + position.x, y + position.y)
    end
end

local Bar = Widget:extend{}

function Bar:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, self.color or Blitbuffer.COLOR_BLACK)
    if self.fill then
        local stroke = self.stroke or 1
        bb:paintRect(x + stroke, y + stroke, self.dimen.w - stroke * 2,
            self.dimen.h - stroke * 2, Blitbuffer.COLOR_WHITE)
        local filled = math.floor((self.dimen.w - stroke * 2) * self.fill)
        if filled > 0 then
            bb:paintRect(x + stroke, y + stroke, filled, self.dimen.h - stroke * 2,
                Blitbuffer.COLOR_BLACK)
        end
    end
end

-- WMO weather marks are local monochrome geometry; no icon downloads or font glyph assumptions.
local WeatherMark = Widget:extend{}

function WeatherMark:init()
    self.rects = {}
    if not finite(self.code) then return end
    local function rect(x, y, w, h)
        local scale = self.dimen.w / 48
        self.rects[#self.rects + 1] = {
            math.floor(x * scale), math.floor(y * scale),
            math.max(1, math.floor(w * scale)), math.max(1, math.floor(h * scale)),
        }
    end
    local code = self.code
    if code <= 2 then
        rect(16, 11, 16, 16)
        rect(22, 2, 4, 6); rect(22, 30, 4, 6)
        rect(7, 17, 6, 4); rect(35, 17, 6, 4)
        rect(10, 5, 4, 4); rect(34, 5, 4, 4)
        rect(10, 29, 4, 4); rect(34, 29, 4, 4)
        if code == 0 then return end
    end
    rect(7, 21, 35, 12); rect(13, 15, 12, 9); rect(23, 18, 13, 7)
    if code == 45 or code == 48 then
        rect(8, 37, 32, 2); rect(13, 43, 23, 2)
    elseif code >= 95 then
        rect(25, 34, 6, 5); rect(21, 38, 6, 5); rect(18, 42, 6, 5)
    elseif (code >= 71 and code <= 77) or code == 85 or code == 86 then
        for x = 12, 36, 12 do
            rect(x, 36, 2, 10); rect(x - 3, 40, 8, 2)
        end
    elseif code >= 51 then
        for x = 12, 36, 12 do rect(x, 36, 3, 9) end
    end
end

function WeatherMark:paintTo(bb, x, y)
    for _, rect in ipairs(self.rects) do
        bb:paintRect(x + rect[1], y + rect[2], rect[3], rect[4], Blitbuffer.COLOR_BLACK)
    end
end

-- Preserve gaps in the actual five-minute series instead of inventing points.
local Trend = Widget:extend{}

function Trend:init()
    local points = {}
    for _, point in ipairs(self.points or {}) do
        if finite(point.t) and finite(point.value) then
            points[#points + 1] = { t = point.t, value = point.value }
        end
    end
    table.sort(points, function(a, b) return a.t < b.t end)
    self.samples, self.rects = points, {}
    if #points == 0 then return end
    local low, high = points[1].value, points[1].value
    for _, point in ipairs(points) do
        low, high = math.min(low, point.value), math.max(high, point.value)
    end
    local inset = self.stroke + 1
    local width = math.max(1, self.dimen.w - inset * 2)
    local height = math.max(1, self.dimen.h - inset * 2)
    local start_time, end_time = points[1].t, points[#points].t
    local previous, px, py
    for _, point in ipairs(points) do
        local ratio_x = end_time > start_time and (point.t - start_time) / (end_time - start_time) or 0.5
        local ratio_y = high > low and (high - point.value) / (high - low) or 0.5
        local x, y = inset + math.floor(ratio_x * width), inset + math.floor(ratio_y * height)
        if previous and point.t > previous.t and point.t - previous.t <= 900 then
            local dx = x - px
            if dx > 0 then
                local last_y = py
                for column = px, x do
                    local next_y = math.floor(py + (y - py) * (column - px) / dx + 0.5)
                    self.rects[#self.rects + 1] = {
                        x = column, y = math.min(last_y, next_y),
                        w = self.stroke, h = math.abs(next_y - last_y) + self.stroke,
                    }
                    last_y = next_y
                end
            else
                self.rects[#self.rects + 1] = {
                    x = x, y = math.min(py, y), w = self.stroke, h = math.abs(y - py) + self.stroke,
                }
            end
        else
            self.rects[#self.rects + 1] = { x = x, y = y, w = self.stroke, h = self.stroke }
        end
        previous, px, py = point, x, y
    end
end

function Trend:paintTo(bb, x, y)
    if #self.samples == 0 then return end
    for grid = 0, 2 do
        local gy = y + self.stroke + 1 + math.floor((self.dimen.h - 2 * (self.stroke + 1)) * grid / 2)
        for gx = 0, self.dimen.w - 1, 14 * self.stroke do
            bb:paintRect(x + gx, gy, math.min(7 * self.stroke, self.dimen.w - gx), 1,
                Blitbuffer.COLOR_LIGHT_GRAY)
        end
    end
    for _, rect in ipairs(self.rects) do
        bb:paintRect(x + rect.x, y + rect.y, rect.w, rect.h, Blitbuffer.COLOR_BLACK)
    end
end

local Dashboard = InputContainer:extend{
    name = "kindle_market_dashboard",
    covers_fullscreen = true,
    stop_events_propagation = true,
    refresh_seconds = 300,
    refreshing = false,
}

function Dashboard:init()
    self.snapshot = self.snapshot or { entries = {} }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = function() return self.dimen end },
        }
    end
    self:_rebuild()
end

-- Physical pixels at PW3's 1072px short edge; Font already scales for DPI.
function Dashboard:_px(value)
    return math.max(1, math.floor(value * self._scale + 0.5))
end

function Dashboard:_face(pixel_size)
    return Font:getFace("cfont", pixel_size / self._font_scale)
end

function Dashboard:_text(text, width, height, size, bold, centered)
    local container = centered and CenterContainer or LeftContainer
    return container:new{
        dimen = Geom:new{ w = width, h = height }, allow_mirroring = false,
        TextWidget:new{
            text = clean(text), face = self:_face(size), bold = bold or false,
            padding = 0, max_width = width, lang = "zh-CN",
        },
    }
end

function Dashboard:_paragraph(text, width, height, size, bold)
    return TextBoxWidget:new{
        text = clean(text), width = width, height = height, face = self:_face(size),
        bold = bold or false, lang = "zh-CN", line_height = 0,
        height_overflow_show_ellipsis = true,
    }
end

function Dashboard:_line(width, height)
    return Bar:new{ dimen = Geom:new{ w = width, h = height or self:_px(2) } }
end

function Dashboard:_panel(width, height)
    local padding, border = self:_px(16), self:_px(2)
    local content = Layout:new{
        dimen = Geom:new{ w = width - 2 * (padding + border), h = height - 2 * (padding + border) },
    }
    local frame = FrameContainer:new{
        padding = padding, margin = 0, bordersize = border,
        background = Blitbuffer.COLOR_WHITE, allow_mirroring = false, content,
    }
    return frame, content, content.dimen.w, content.dimen.h
end

function Dashboard:_calendar(width, height)
    local panel, content, w, h = self:_panel(width, height)
    local calendar = self.snapshot.calendar or {}
    local next_day = calendar.next_day or {}
    local left_w = math.floor(w * 0.64)
    local right_x = left_w + self:_px(8)
    local right_w = w - right_x
    content:add(self:_text(calendar.date_str or "日期 --", left_w, self:_px(44), self:_px(36), true), 0, 0)
    content:add(self:_text(calendar.weekday or "星期 --", left_w, self:_px(96),
        math.min(self:_px(80), math.floor(left_w / 3.2)), true), 0, self:_px(44))
    content:add(self:_text(calendar.is_rest_today and "下个工作日" or "下个休息日",
        right_w, self:_px(30), self:_px(22), true), right_x, 0)
    content:add(self:_text(number(next_day.days_away, "天后"), right_w, self:_px(48), self:_px(34), true),
        right_x, self:_px(30))
    content:add(self:_text(next_day.date or "--", right_w, self:_px(36), self:_px(29), true), right_x, self:_px(78))
    content:add(self:_text(next_day.name or "--", right_w, self:_px(30), self:_px(21)), right_x, self:_px(114))
    content:add(self:_text(calendar.lunar or "农历 --", w, self:_px(36), self:_px(27), true), 0, self:_px(144))
    content:add(self:_line(w), 0, self:_px(188))
    local footer_y = h - self:_px(74)
    local clock_y = self:_px(197)
    local clock_h = math.max(self:_px(88), footer_y - clock_y - self:_px(26))
    local clock_size = math.min(self:_px(152), math.floor(w / 3.1), math.floor(clock_h * 0.86))
    content:add(self:_text(calendar.time or "--:--", w, clock_h, clock_size, true, true), 0, clock_y)
    content:add(self:_text("本地时间 UTC+8", w, self:_px(24), self:_px(19), false, true),
        0, footer_y - self:_px(24))
    local day_text = (calendar.day_name or "日历 --") .. " · " .. (calendar.holiday_region or "中国")
    if calendar.holiday_estimated then day_text = day_text .. " · 节假日估算" end
    content:add(self:_text(day_text, w, self:_px(28), self:_px(21)), 0, footer_y)
    content:add(self:_text("今年已过 " .. number(calendar.year_progress, "%", 1),
        w, self:_px(28), self:_px(21)), 0, footer_y + self:_px(28))
    local progress = finite(calendar.year_progress) and math.max(0, math.min(1, calendar.year_progress / 100)) or 0
    content:add(Bar:new{
        dimen = Geom:new{ w = w, h = self:_px(12) }, fill = progress, stroke = self:_px(2),
    }, 0, h - self:_px(12))
    return panel
end

function Dashboard:_weather(width, height)
    local panel, content, w, h = self:_panel(width, height)
    local weather = self.snapshot.weather or {}
    local current, location = weather.current or {}, weather.location or {}
    content:add(self:_text(location.name or "天气 · 城市未设置", w, self:_px(38), self:_px(30), true), 0, 0)
    local metrics = {
        { "湿度", number(current.humidity, "%") },
        { "UV", number(current.uv, "", 1) },
        { "US AQI" .. (weather.aqi_stale and " 旧" or weather.aqi_error and " !" or ""), number(current.aqi) },
        { "降水概率", number(current.rain_chance, "%") },
    }
    local metric_w = math.floor(w / 4)
    for index, metric in ipairs(metrics) do
        local x = (index - 1) * metric_w
        content:add(self:_text(metric[1], metric_w, self:_px(24), self:_px(19), false, true), x, self:_px(42))
        content:add(self:_text(metric[2], metric_w, self:_px(34), self:_px(27), true, true), x, self:_px(66))
    end
    local main_y = self:_px(106)
    local mark_size = self:_px(56)
    content:add(WeatherMark:new{ dimen = Geom:new{ w = mark_size, h = mark_size }, code = current.weather_code }, 0, main_y)
    local temp_w = math.floor(w * 0.35)
    content:add(self:_text(current.desc or "天气 --", w - temp_w - mark_size - self:_px(8), self:_px(72),
        self:_px(32), true), mark_size + self:_px(8), main_y)
    content:add(self:_text(number(current.temp, "°"), temp_w, self:_px(72), self:_px(61), true, true), w - temp_w, main_y)
    content:add(self:_text("最高 " .. number(current.high, "°") .. " / 最低 " .. number(current.low, "°")
        .. (current.aqi_level and (" · " .. current.aqi_level) or ""), w, self:_px(28), self:_px(22)), 0, self:_px(180))
    content:add(self:_text(current.alert or "雨雪时段 --", w, self:_px(30), self:_px(23), true), 0, self:_px(208))
    local forecast_y = math.max(self:_px(246), h - self:_px(166))
    content:add(self:_line(w), 0, forecast_y - self:_px(8))
    for index = 1, 4 do
        local item = index == 4 and (weather.tomorrow or {}) or ((weather.forecast or {})[index] or {})
        local x = (index - 1) * metric_w
        content:add(self:_text(item.label or (index == 4 and "明天" or "时段 --"), metric_w,
            self:_px(26), self:_px(20), true, true), x, forecast_y)
        local icon_size = self:_px(30)
        content:add(WeatherMark:new{ dimen = Geom:new{ w = icon_size, h = icon_size }, code = item.weather_code },
            x + math.floor((metric_w - icon_size) / 2), forecast_y + self:_px(27))
        local temp = index == 4 and (number(item.high, "°") .. "/" .. number(item.low, "°")) or number(item.temp, "°")
        content:add(self:_text(temp, metric_w, self:_px(34), self:_px(index == 4 and 23 or 28), true, true),
            x, forecast_y + self:_px(58))
        content:add(self:_text(item.desc or "--", metric_w - self:_px(4), self:_px(26), self:_px(19), false, true),
            x, forecast_y + self:_px(92))
    end
    local state = weather.stale and "旧天气" or weather.error and "天气失败" or "天气"
    local observed = weather.observed_at or weather.fetched_at
    content:add(self:_text(state .. " " .. timestamp(observed) .. (weather.error and (" · " .. clean(weather.error)) or ""),
        w, self:_px(23), self:_px(18), weather.error ~= nil), 0, h - self:_px(46))
    local air_state = weather.aqi_stale and "空气旧数据" or weather.aqi_error and "空气失败" or "空气"
    content:add(self:_text(air_state .. " " .. timestamp(weather.aqi_observed_at or weather.aqi_fetched_at)
        .. (weather.aqi_error and (" · " .. clean(weather.aqi_error)) or " · Open-Meteo / CAMS"),
        w, self:_px(23), self:_px(18), weather.aqi_error ~= nil), 0, h - self:_px(23))
    return panel
end

function Dashboard:_news(width, height)
    local panel, content, w, h = self:_panel(width, height)
    local news = self.snapshot.news or {}
    local items = news.items or {}
    local external = items[1] and items[1].is_external
    content:add(self:_text(external and "新闻" or "HACKER NEWS", w, self:_px(34), self:_px(27), true), 0, 0)
    local rows_y, footer_h = self:_px(38), self:_px(46)
    local row_h = math.floor((h - rows_y - footer_h) / 5)
    local title_size = math.min(self:_px(25), math.floor((row_h - self:_px(22)) / 2))
    for index = 1, math.min(5, #items) do
        local item, y = items[index], rows_y + (index - 1) * row_h
        local meta = item.is_external and clean(item.meta)
            or ((item.is_breaking and "突发 · " or "") .. number(item.score, " 分") .. " · HN")
        content:add(self:_text(tostring(index) .. ".  " .. meta, w, self:_px(20), self:_px(18), item.is_breaking), 0, y)
        content:add(self:_paragraph(item.title or "标题缺失", w, row_h - self:_px(22), title_size, item.is_breaking),
            0, y + self:_px(20))
        if index < math.min(5, #items) then content:add(self:_line(w, self:_px(1)), 0, y + row_h - self:_px(1)) end
    end
    if #items == 0 then
        content:add(self:_text(news.error and "新闻获取失败" or "等待新闻数据", w, self:_px(60), self:_px(27)), 0, rows_y)
    end
    local state = news.stale and "旧数据" or news.error and "获取失败" or "更新"
    content:add(self:_text(state .. " " .. timestamp(news.fetched_at) .. " UTC+8", w,
        self:_px(23), self:_px(18), news.stale), 0, h - footer_h)
    content:add(self:_text(news.error and clean(news.error) or (external and "自定义新闻源 · 原始标题"
        or ((news.source_name or "Hacker News / Firebase") .. " · 原始标题")),
        w, self:_px(23), self:_px(18), news.error ~= nil), 0, h - self:_px(23))
    return panel
end

function Dashboard:_markets(width, height)
    local panel, content, w, h = self:_panel(width, height)
    content:add(self:_text("市场行情", w, self:_px(34), self:_px(27), true), 0, 0)
    local defaults = {
        { name = "纳斯达克综合指数", symbol = ".IXIC", unit = "点" },
        { name = "纽约黄金 CFD", symbol = "GC", unit = "USD/金衡盎司" },
        { name = "标普 500 指数", symbol = ".INX", unit = "点" },
    }
    local entries = self.snapshot.entries or {}
    local start_y = self:_px(38)
    local row_h = math.floor((h - start_y) / 3)
    for index = 1, 3 do
        local entry, fallback = entries[index] or defaults[index], defaults[index]
        local y = start_y + (index - 1) * row_h
        local name = entry.name or fallback.name
        content:add(self:_text(name, w, self:_px(24), self:_px(22), true), 0, y)
        local price_w = math.floor(w * 0.64)
        content:add(self:_text(amount(entry.price), price_w, self:_px(34), self:_px(31), true), 0, y + self:_px(24))
        local percent = finite(entry.change_percent) and string.format("%+.2f%%", entry.change_percent) or "--%"
        content:add(self:_text(percent, w - price_w, self:_px(34), self:_px(25), true, true), price_w, y + self:_px(24))
        local chart_y = y + self:_px(60)
        local chart_h = math.max(self:_px(18), row_h - self:_px(106))
        local trend = Trend:new{
            dimen = Geom:new{ w = w, h = chart_h }, stroke = self:_px(2), points = entry.points,
        }
        if #trend.samples > 0 then
            content:add(trend, 0, chart_y)
        else
            content:add(self:_text("暂无日内走势", w, chart_h, self:_px(18), false, true), 0, chart_y)
        end
        local status = entry.stale and " · 旧数据" or entry.error and " · 错误" or ""
        content:add(self:_text((entry.source_name or "新浪财经") .. " " .. timestamp(entry.quote_time) .. status,
            w, self:_px(22), self:_px(17), entry.stale or entry.error ~= nil), 0, y + row_h - self:_px(46))
        content:add(self:_text(entry.error and clean(entry.error)
            or ((entry.symbol or fallback.symbol) .. " · " .. (entry.unit or fallback.unit) .. " · 日变动/前收盘"),
            w, self:_px(22), self:_px(17), entry.error ~= nil), 0, y + row_h - self:_px(24))
        if index < 3 then content:add(self:_line(w), 0, y + row_h - self:_px(2)) end
    end
    return panel
end

function Dashboard:_rebuild()
    if self._closed then return end
    local old = self[1]
    local width, height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = width, h = height }
    self._scale = math.min(width, height) / 1072
    self._font_scale = Screen:scaleBySize(100) / 100
    local margin, gap = self:_px(12), self:_px(4)
    local w = width - margin * 2
    local button_h, note_h = self:_px(66), self:_px(28)
    local grid_h = height - margin * 2 - button_h - note_h - self:_px(12)
    local top_h = math.floor((grid_h - gap) / 2)
    local bottom_h = grid_h - gap - top_h
    local top_w = math.floor((w - gap) / 2)
    local news_w = math.floor((w - gap) * (height > width and 0.55 or 0.60))
    local root = Layout:new{ dimen = Geom:new{ w = w, h = height - margin * 2 } }
    self._calendar_width, self._calendar_height = top_w, top_h
    root:add(self:_calendar(top_w, top_h), 0, 0)
    root:add(self:_weather(w - gap - top_w, top_h), top_w + gap, 0)
    root:add(self:_news(news_w, bottom_h), 0, top_h + gap)
    root:add(self:_markets(w - gap - news_w, bottom_h), news_w + gap, top_h + gap)
    local note = self.snapshot.error and (clean(self.snapshot.error) .. " · 保留旧数据及来源时间 · UTC+8")
        or self.refreshing and "正在刷新各数据源… 保留原始来源时间"
        or ("自动刷新 " .. tostring(self.refresh_seconds) .. "秒 · 报价可能延迟 · 来源时间 UTC+8")
    root:add(self:_text(note, w, note_h, self:_px(20), self.snapshot.error ~= nil), 0, grid_h + self:_px(4))
    local button_gap = self:_px(10)
    local button_w = math.floor((w - button_gap * 3) / 4)
    local function button(text, callback, enabled)
        return Button:new{
            text = text, callback = callback, enabled = enabled ~= false,
            width = button_w, height = button_h - self:_px(12),
            padding = self:_px(5), bordersize = self:_px(2), margin = 0,
            text_font_size = self:_px(25) / self._font_scale, lang = "zh-CN", show_parent = self,
        }
    end
    local button_y = grid_h + note_h + self:_px(12)
    root:add(button(self.refreshing and "刷新中…" or "刷新数据", function() self:onRefresh() end,
        not self.refreshing), 0, button_y)
    root:add(button("设置城市", function() self:onSettings() end), button_w + button_gap, button_y)
    root:add(button("旋转屏幕", function() self:onRotate() end), (button_w + button_gap) * 2, button_y)
    root:add(button("返回阅读", function() self:onClose() end), (button_w + button_gap) * 3, button_y)
    self._root = root
    self[1] = FrameContainer:new{
        padding = margin, margin = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE,
        width = width, height = height, allow_mirroring = false, root,
    }
    if old then old:free() end
end

function Dashboard:_repaint()
    if not self._closed then UIManager:setDirty(self, "ui", self.dimen) end
end

function Dashboard:setSnapshot(snapshot, refreshing)
    if self._closed then return end
    self.snapshot = snapshot or { entries = {} }
    self.refreshing = refreshing == true
    self:_rebuild()
    self:_repaint()
end

function Dashboard:setClock(calendar)
    if self._closed then return end
    self.snapshot.calendar = calendar
    -- A minute tick replaces only the calendar subtree, preserving source timestamps and charts.
    local old = self._root[1]
    self._root[1] = self:_calendar(self._calendar_width, self._calendar_height)
    if old then old:free() end
    self:_repaint()
end

function Dashboard:setRefreshing(refreshing)
    if self._closed or self.refreshing == (refreshing == true) then return end
    self.refreshing = refreshing == true
    self:_rebuild()
    self:_repaint()
end

function Dashboard:onRefresh()
    if not self._closed and not self.refreshing and self.on_refresh then self.on_refresh() end
    return true
end

function Dashboard:onSettings()
    if not self._closed and self.on_settings then self.on_settings() end
    return true
end

function Dashboard:onRotate()
    if not self._closed and self.on_rotate then self.on_rotate() end
    return true
end

function Dashboard:onSwipe(_, gesture)
    if gesture.direction == "south" then return self:onRefresh() end
    if gesture.direction == "east" then return self:onClose() end
    return true
end

function Dashboard:onClose()
    if not self._close_requested and not self._closed then
        self._close_requested = true
        if self.on_close then self.on_close() end
    end
    return true
end

Dashboard.onBack = Dashboard.onClose

function Dashboard:onScreenResize()
    self:_rebuild()
    self:_repaint()
    return false
end

Dashboard.onSetDimensions = Dashboard.onScreenResize

function Dashboard:onShow()
    self:_repaint()
    return true
end

function Dashboard:onCloseWidget()
    self._closed = true
    self:free()
    self[1], self._root = nil, nil
end

return Dashboard
