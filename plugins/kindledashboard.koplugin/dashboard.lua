local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
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

local function timestamp(value)
    if not finite(value) or value <= 0 then return "--" end
    -- Source timestamps are explicitly UTC+8, independently of the device TZ.
    return os.date("!%m/%d %H:%M", value + 28800)
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

local weather_icon_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") .. "/icons/weather/"
local weather_icons = {
    [0] = "sun", [1] = "partly-cloudy", [2] = "partly-cloudy", [3] = "cloud",
    [45] = "fog", [48] = "fog",
    [51] = "rain", [53] = "rain", [55] = "rain", [56] = "rain", [57] = "rain",
    [61] = "rain", [63] = "rain", [65] = "rain", [66] = "rain", [67] = "rain",
    [71] = "snow", [73] = "snow", [75] = "snow", [77] = "snow",
    [80] = "rain", [81] = "rain", [82] = "rain", [85] = "snow", [86] = "snow",
    [95] = "storm", [96] = "storm", [99] = "storm",
}

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
    local reference_y = y + math.floor(self.dimen.h / 2)
    bb:paintRect(x, reference_y, self.dimen.w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
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
    local padding, border = self:_px(10), self:_px(1)
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
    local left_w = math.floor(w * 0.58)
    local right_x = left_w + self:_px(8)
    local right_w = w - right_x
    content:add(self:_text(calendar.date_str or "日期 --", left_w, self:_px(40), self:_px(32), true), 0, 0)
    content:add(self:_text(calendar.weekday or "星期 --", left_w, self:_px(40), self:_px(32), true), 0, self:_px(40))
    content:add(self:_text(calendar.is_rest_today and "下个工作日" or "下个休息日",
        right_w, self:_px(30), self:_px(24), true), right_x, 0)
    content:add(self:_text(number(next_day.days_away, "天后"), right_w, self:_px(42), self:_px(34), true),
        right_x, self:_px(30))
    content:add(self:_text(next_day.date or "--", right_w, self:_px(30), self:_px(24), true), right_x, self:_px(72))
    content:add(self:_text(next_day.name or "--", right_w, self:_px(30), self:_px(24), true), right_x, self:_px(102))
    local clock_y = self:_px(136)
    local clock_h = h - clock_y - self:_px(106)
    -- Measure the actual bold clock face; nominal point sizes do not describe glyph bounds.
    local clock = TextWidget:new{ text = calendar.time or "--:--", face = self:_face(self:_px(160)),
        bold = true, padding = 0, lang = "zh-CN" }
    local clock_size = self:_px(160)
    while clock_size > self:_px(30) do
        local size = clock:getSize()
        if size.w <= w and size.h <= clock_h then break end
        clock:free()
        clock_size = clock_size - 1
        clock = TextWidget:new{ text = calendar.time or "--:--", face = self:_face(clock_size),
            bold = true, padding = 0, lang = "zh-CN" }
    end
    content:add(CenterContainer:new{ dimen = Geom:new{ w = w, h = clock_h },
        allow_mirroring = false, clock }, 0, clock_y)
    content:add(self:_text(calendar.lunar or "农历 --", w, self:_px(36), self:_px(28), true), 0, h - self:_px(104))
    local day_text = calendar.day_name or "日历 --"
    if calendar.holiday_estimated then day_text = day_text .. " · 估算" end
    content:add(self:_text(day_text, math.floor(w * 0.7), self:_px(36), self:_px(26), true), 0, h - self:_px(68))
    local percent_w = w - math.floor(w * 0.7)
    content:add(self:_text(number(calendar.year_progress, "%", 1), percent_w,
        self:_px(36), self:_px(26), true, true), w - percent_w, h - self:_px(68))
    local progress = finite(calendar.year_progress) and math.max(0, math.min(1, calendar.year_progress / 100)) or 0
    content:add(Bar:new{
        dimen = Geom:new{ w = w, h = self:_px(16) }, fill = progress, stroke = self:_px(1),
    }, 0, h - self:_px(20))
    return panel
end

function Dashboard:_weather(width, height)
    local panel, content, w, h = self:_panel(width, height)
    local weather = self.snapshot.weather or {}
    local current, location = weather.current or {}, weather.location or {}
    local state = weather.stale and " · 旧数据" or weather.error and " · 获取失败" or ""
    content:add(self:_text((location.name or "城市未设置") .. state, w, self:_px(40), self:_px(32), true), 0, 0)
    local mark_size, temp_w = self:_px(80), math.floor(w * 0.34)
    local icon = weather_icons[current.weather_code]
    if icon then
        content:add(IconWidget:new{
            file = weather_icon_dir .. icon .. ".svg", width = mark_size, height = mark_size,
        }, 0, self:_px(40))
    end
    local desc_x = mark_size + self:_px(10)
    content:add(self:_paragraph(current.desc or "天气 --", w - temp_w - desc_x,
        self:_px(76), self:_px(32), true), desc_x, self:_px(42))
    content:add(self:_text(number(current.temp, "°"), temp_w, self:_px(80), self:_px(60), true, true),
        w - temp_w, self:_px(40))
    content:add(self:_text("最高 " .. number(current.high, "°") .. " / 最低 " .. number(current.low, "°"),
        w, self:_px(32), self:_px(26), true), 0, self:_px(120))
    content:add(self:_text(current.alert or "雨雪时段 --", w, self:_px(32), self:_px(24), true), 0, self:_px(152))
    local metrics = {
        { "湿度", number(current.humidity, "%") },
        { "UV", number(current.uv, "", 1) },
        { "US AQI" .. (weather.aqi_stale and " 旧" or weather.aqi_error and " !" or ""), number(current.aqi) },
        { "降水概率", number(current.rain_chance, "%") },
    }
    local metric_w = math.floor(w / 4)
    for index, metric in ipairs(metrics) do
        local x = (index - 1) * metric_w
        content:add(self:_text(metric[1], metric_w, self:_px(30), self:_px(23), true, true), x, self:_px(184))
        content:add(self:_text(metric[2], metric_w, self:_px(40), self:_px(33), true, true), x, self:_px(214))
    end
    local air_state = weather.aqi_stale and " · 旧数据" or weather.aqi_error and " · 获取失败" or ""
    content:add(self:_text("US AQI · " .. (current.aqi_level or "--") .. air_state,
        w, self:_px(30), self:_px(24), true), 0, self:_px(254))
    local forecast_y = math.max(self:_px(290), h - self:_px(120))
    content:add(self:_line(w, self:_px(1)), 0, forecast_y - self:_px(4))
    for index = 1, 4 do
        local item = index == 4 and (weather.tomorrow or {}) or ((weather.forecast or {})[index] or {})
        local x = (index - 1) * metric_w
        content:add(self:_text(item.label or (index == 4 and "明天" or "时段 --"), metric_w,
            self:_px(30), self:_px(24), true, true), x, forecast_y)
        local temp = index == 4 and (number(item.high, "°") .. "/" .. number(item.low, "°")) or number(item.temp, "°")
        content:add(self:_text(temp, metric_w, self:_px(36), self:_px(28), true, true), x, forecast_y + self:_px(30))
        content:add(self:_paragraph(item.desc or "--", metric_w - self:_px(6), self:_px(54), self:_px(24), true),
            x + self:_px(3), forecast_y + self:_px(66))
    end
    return panel
end

function Dashboard:_news(width, height)
    local panel, content, w, h = self:_panel(width, height)
    local news = self.snapshot.news or {}
    local items = news.items or {}
    local external = items[1] and items[1].is_external
    local state = news.stale and " · 旧数据" or news.error and " · 获取失败" or ""
    content:add(self:_text((external and "新闻" or "HACKER NEWS") .. state,
        w, self:_px(40), self:_px(32), true), 0, 0)
    local rows_y = self:_px(44)
    local row_h = math.floor((h - rows_y) / 5)
    local rank_w = self:_px(40)
    for index = 1, math.min(5, #items) do
        local item, y = items[index], rows_y + (index - 1) * row_h
        content:add(self:_text(tostring(index), rank_w, self:_px(40), self:_px(32), true), 0, y)
        content:add(self:_paragraph(item.title or "标题缺失", w - rank_w,
            row_h - self:_px(8), self:_px(32), true), rank_w, y + self:_px(3))
        if index < math.min(5, #items) then content:add(self:_line(w, self:_px(1)), 0, y + row_h - self:_px(1)) end
    end
    if #items == 0 then
        content:add(self:_text(news.error and "新闻获取失败" or "等待新闻数据", w,
            self:_px(60), self:_px(32), true), 0, rows_y)
    end
    return panel
end

function Dashboard:_markets(width, height)
    local panel, content, w, h = self:_panel(width, height)
    content:add(self:_text("市场行情", w, self:_px(40), self:_px(32), true), 0, 0)
    local defaults = {
        { name = "纳斯达克综合指数", unit = "点" },
        { name = "纽约黄金 CFD", unit = "USD/金衡盎司" },
        { name = "标普 500 指数", unit = "点" },
    }
    local entries = self.snapshot.entries or {}
    local start_y = self:_px(44)
    local row_h = math.floor((h - start_y) / 3)
    for index = 1, 3 do
        local entry, fallback = entries[index] or defaults[index], defaults[index]
        local y = start_y + (index - 1) * row_h
        local name = entry.name or fallback.name
        local text_w = math.floor(w * 0.58)
        content:add(self:_text(name, text_w, self:_px(32), self:_px(28), true), 0, y)
        content:add(self:_text(amount(entry.price), text_w, self:_px(54), self:_px(42), true), 0, y + self:_px(32))
        local percent = finite(entry.change_percent) and string.format("%+.2f%%", entry.change_percent) or "--%"
        content:add(self:_text(percent, text_w, self:_px(36), self:_px(30), true), 0, y + self:_px(88))
        local chart_x = text_w + self:_px(14)
        local chart_y, chart_h = y + self:_px(8), row_h - self:_px(44)
        local chart_w = w - chart_x
        local trend = Trend:new{
            dimen = Geom:new{ w = chart_w, h = chart_h }, stroke = self:_px(2), points = entry.points,
        }
        if #trend.samples > 0 then
            content:add(trend, chart_x, chart_y)
        else
            content:add(self:_text("暂无走势", chart_w, chart_h, self:_px(24), true, true), chart_x, chart_y)
        end
        local status = entry.stale and " · 旧数据" or entry.error and " · 获取失败" or ""
        local unit = entry.unit or fallback.unit
        local quote = timestamp(entry.quote_time) .. status
        if unit ~= "点" then quote = quote .. " · " .. unit end
        content:add(self:_text(quote, w, self:_px(30), self:_px(24), true), 0, y + row_h - self:_px(32))
        if index < 3 then content:add(self:_line(w, self:_px(1)), 0, y + row_h - self:_px(1)) end
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
    local button_h = self:_px(72)
    local grid_h = height - button_h
    local top_h = math.floor(grid_h * (height > width and 0.35 or 0.44))
    local bottom_h = grid_h - top_h
    local column_w = math.floor(width / 2)
    local root = Layout:new{ dimen = Geom:new{ w = width, h = height } }
    self._calendar_width, self._calendar_height = column_w, top_h
    root:add(self:_calendar(column_w, top_h), 0, 0)
    root:add(self:_weather(width - column_w, top_h), column_w, 0)
    root:add(self:_news(column_w, bottom_h), 0, top_h)
    root:add(self:_markets(width - column_w, bottom_h), column_w, top_h)
    local function button(text, callback, enabled, button_width)
        return Button:new{
            text = text, callback = callback, enabled = enabled ~= false,
            width = button_width, height = button_h - self:_px(2),
            padding = 0, bordersize = self:_px(1), margin = 0,
            text_font_size = self:_px(30) / self._font_scale, text_font_bold = true,
            lang = "zh-CN", show_parent = self,
        }
    end
    local labels = { self.refreshing and "刷新中…" or "刷新数据", "仪表盘设置", "旋转屏幕", "返回阅读" }
    local callbacks = {
        function() self:onRefresh() end, function() self:onSettings() end,
        function() self:onRotate() end, function() self:onClose() end,
    }
    for index = 1, 4 do
        local x = math.floor((index - 1) * width / 4)
        local next_x = math.floor(index * width / 4)
        root:add(button(labels[index], callbacks[index], index ~= 1 or not self.refreshing, next_x - x), x, grid_h)
    end
    self._root = root
    self[1] = FrameContainer:new{
        padding = 0, margin = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE,
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
