local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local JSON = require("json")
local NetworkMgr = require("ui/network/manager")
local PluginShare = require("pluginshare")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen
local logger = require("logger")

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
-- PluginLoader's local search path is active now; lazy worker requests reuse it.
require("dashboardhttp")
local Market = dofile(plugin_dir .. "/market.lua")
local Dashboard = dofile(plugin_dir .. "/dashboard.lua")
local Calendar = dofile(plugin_dir .. "/calendar.lua")
local Sources = dofile(plugin_dir .. "/sources.lua")
local REQUEST_PATH = "/tmp/kindle-dashboard-open"

local KindleDashboard = WidgetContainer:extend{
    name = "kindledashboard",
    is_doc_only = false,
}

local moon_extensions = package.loaded["utils.extension"]
if moon_extensions and moon_extensions.POINTS and moon_extensions.POINTS["desktop.tabs"] then
    moon_extensions.add("desktop.tabs", {
        id = "kindledashboard", text = "仪表盘", icon = "dashboard", after = "insight",
        tap = function()
            UIManager:broadcastEvent(Event:new("KindleDashboard"))
        end,
    })
end

local function readCache(path, config)
    local file = io.open(path, "r")
    if not file then return end
    local content = file:read("*a")
    file:close()
    local ok, snapshot = pcall(JSON.decode, content)
    if ok and type(snapshot) == "table" and type(snapshot.entries) == "table" then
        for _, entry in ipairs(snapshot.entries) do
            entry.stale = true
        end
        if snapshot.weather then
            local location = snapshot.weather.location or {}
            if location.latitude ~= config.weather.latitude or location.longitude ~= config.weather.longitude
                or location.timezone ~= config.weather.timezone then
                snapshot.weather = nil
            else
                snapshot.weather.stale, snapshot.weather.aqi_stale = true, true
            end
        end
        if snapshot.news then
            if snapshot.news.source ~= (config.news_external_url ~= "" and config.news_external_url or "Hacker News") then
                snapshot.news = nil
            else
                snapshot.news.stale = true
            end
        end
        return snapshot
    end
end

function KindleDashboard:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kindledashboard.lua")
    self.config = Market.defaultConfig()
    self.config.weather = self.settings:readSetting("weather", Sources.defaultWeather())
    self.config.news_external_url = self.settings:readSetting("news_external_url", "")
    self.keep_display_on = self.settings:readSetting("keep_display_on", true)
    self.cache_path = DataStorage:getSettingsDir() .. "/kindledashboard-cache.json"
    self.bundled_holidays = Calendar.loadBundled()
    self.snapshot = readCache(self.cache_path, self.config) or {entries={}}
    self.refresh_task = function() self:refresh(false) end
    self.keep_awake_task = function() self:refreshKeepAwake() end
    self.clock_task = function()
        self:updateClock()
        self:scheduleClock()
    end
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    local request = io.open(REQUEST_PATH, "r")
    if request then
        request:close()
        os.remove(REQUEST_PATH)
        UIManager:scheduleIn(1, function() self:onKindleDashboard() end)
    end
end

function KindleDashboard:onDispatcherRegisterActions()
    Dispatcher:registerAction("kindle_dashboard", {
        category = "none", event = "KindleDashboard",
        title = "阅读仪表盘", general = true,
    })
end

function KindleDashboard:addToMainMenu(menu_items)
    menu_items.kindle_dashboard = {
        text = "阅读仪表盘",
        sorting_hint = "more_tools",
        callback = function() self:onKindleDashboard() end,
    }
end

function KindleDashboard:onKindleDashboard()
    if self.dashboard then return true end
    self.suspended = false
    self:updateClock()
    self.original_rotation = Device.screen:getRotationMode()
    self.dashboard = Dashboard:new{
        snapshot = self.snapshot,
        refresh_seconds = self.config.refresh_seconds,
        refreshing = false,
        on_refresh = function() self:refresh(true) end,
        on_close = function() self:closeDashboard() end,
        on_rotate = function() self:rotateDashboard() end,
        on_settings = function() self:showSettings() end,
    }
    UIManager:show(self.dashboard)
    self:setKeepAwake(self.keep_display_on)
    self:scheduleClock()
    UIManager:nextTick(function() self:refresh(true) end)
    return true
end

function KindleDashboard:setKeepAwake(enabled)
    if enabled == (self.keep_awake_state ~= nil) then return true end
    local state = self.keep_awake_state or {
        pause_auto_suspend = PluginShare.pause_auto_suspend,
        keepalive = PluginShare.keepalive,
    }
    if Device:isKindle() then
        -- Own the T1 reset schedule while AutoSuspend's automatic sleep is paused.
        PluginShare.keepalive = enabled and true or state.keepalive
    end
    PluginShare.pause_auto_suspend = enabled and true or state.pause_auto_suspend
    if enabled then
        self.keep_awake_state = state
        UIManager:preventStandby()
        return self:refreshKeepAwake()
    else
        UIManager:unschedule(self.keep_awake_task)
        self.keep_awake_state = nil
        UIManager:allowStandby()
        -- AutoSuspend stops its T1 task while keepalive is true.
        local autosuspend = self.ui.autosuspend
        if Device:isKindle() and state.prevent_screen_saver == 0 and autosuspend
                and not self.suspended and not PluginShare.keepalive then
            UIManager:unschedule(autosuspend.kindle_task)
            local ok, err = pcall(autosuspend._start_kindle, autosuspend)
            if not ok then logger.warn("KindleDashboard: sleep timer restoration failed", err) end
        end
    end
    return true
end

function KindleDashboard:refreshKeepAwake()
    UIManager:unschedule(self.keep_awake_task)
    local state = self.keep_awake_state
    if not state or self.suspended or not Device:isKindle() then return true end
    local ok, native = pcall(function()
        local powerd = Device:getPowerDevice()
        local handle = assert(powerd.lipc_handle, "Kindle power control unavailable")
        local prevented = handle:get_int_property("com.lab126.powerd", "preventScreenSaver")
        assert(type(prevented) == "number", "Cannot read screen saver state")
        -- Never reset T1 when another owner inhibits screen saver: powerd can crash.
        if prevented == 0 then powerd:resetT1Timeout() end
        return prevented
    end)
    if not ok then
        self:setKeepAwake(false)
        logger.warn("KindleDashboard: keep-awake timer failed", native)
        UIManager:show(InfoMessage:new{text = "无法启用保持显示，请查看 KOReader 日志。"})
        return false
    end
    if state.prevent_screen_saver == nil then state.prevent_screen_saver = native end
    -- Same four-minute interval as AutoSuspend, below Kindle's minimum T1 timeout.
    UIManager:scheduleIn(240, self.keep_awake_task)
    return true
end

function KindleDashboard:scheduleRefresh(delay)
    UIManager:unschedule(self.refresh_task)
    if self.dashboard and not self.suspended then
        UIManager:scheduleIn(delay or self.config.refresh_seconds, self.refresh_task)
    end
end

function KindleDashboard:updateClock()
    self.snapshot.calendar = Calendar.at(os.time(), self.snapshot.holidays or self.bundled_holidays)
    if self.dashboard and not self.suspended then
        self.dashboard:setClock(self.snapshot.calendar)
    end
end

function KindleDashboard:scheduleClock()
    UIManager:unschedule(self.clock_task)
    if self.dashboard and not self.suspended then
        UIManager:scheduleIn(60 - os.time() % 60, self.clock_task)
    end
end

function KindleDashboard:saveCache()
    local ok, content = pcall(JSON.encode, self.snapshot)
    if not ok then
        logger.warn("KindleDashboard: cache encoding failed", content)
        return
    end
    local temp_path = self.cache_path .. ".new"
    local file = io.open(temp_path, "w")
    if not file then return end
    local wrote = file:write(content)
    local closed = file:close()
    if wrote and closed then
        if not os.rename(temp_path, self.cache_path) then os.remove(temp_path) end
    else
        os.remove(temp_path)
    end
end

function KindleDashboard:showSettings()
    local dialog
    dialog = ButtonDialog:new{
        title = "仪表盘设置",
        width_factor = 0.85,
        use_info_style = false,
        title_face = Font:getFace("x_smalltfont",
            44 * math.min(Screen:getWidth(), Screen:getHeight()) / 1072 / (Screen:scaleBySize(100) / 100)),
        buttons = {
            {{text = "保持显示：" .. (self.keep_awake_state and "开启" or "关闭"), callback = function()
                local enabled = self.keep_awake_state == nil
                UIManager:close(dialog)
                if self:setKeepAwake(enabled) then
                    self.keep_display_on = enabled
                    self.settings:saveSetting("keep_display_on", enabled)
                    self.settings:flush()
                    self:showSettings()
                end
            end},
            {text = "前光亮度", enabled = Device:hasFrontlight(), callback = function()
                UIManager:close(dialog)
                UIManager:show(dofile(plugin_dir .. "/frontlight.lua"):new{})
            end}},
            {{text = "天气城市：" .. self.config.weather.city_name, callback = function()
                UIManager:close(dialog)
                self:searchCity()
            end}},
            {{text = self.config.news_external_url == "" and "新闻源：Hacker News" or "新闻源：自定义", callback = function()
                UIManager:close(dialog)
                self:editNewsSource()
            end}},
            {{text = "关闭", callback = function() UIManager:close(dialog) end}},
        },
    }
    UIManager:show(dialog)
end

function KindleDashboard:searchCity()
    local input
    input = InputDialog:new{
        title = "天气城市（可输入中文或英文）",
        input = self.config.weather.city_name,
        buttons = {{
            {text = "取消", callback = function() UIManager:close(input) end},
            {text = "查找", is_enter_default = true, callback = function()
                local query = input:getInputText()
                UIManager:close(input)
                NetworkMgr:runWhenConnected(function()
                    Trapper:wrap(function()
                        local completed, cities, err = Trapper:dismissableRunInSubprocess(function()
                            return Sources.searchCities(query)
                        end, "正在查找城市，轻触取消…")
                        if not completed then return end
                        if not cities or #cities == 0 then
                            UIManager:show(InfoMessage:new{text = err or "未找到城市，请尝试英文名称。"})
                            return
                        end
                        local choices
                        local buttons = {}
                        for _, city in ipairs(cities) do
                            local chosen = city
                            buttons[#buttons + 1] = {{text = city.display_name or city.name, callback = function()
                                UIManager:close(choices)
                                self.config.weather.city_name = chosen.name
                                self.config.weather.latitude = chosen.latitude
                                self.config.weather.longitude = chosen.longitude
                                self.config.weather.timezone = chosen.timezone
                                self.settings:saveSetting("weather", self.config.weather)
                                self.settings:flush()
                                self.snapshot.weather = nil
                                if self.dashboard then self.dashboard:setSnapshot(self.snapshot, false) end
                                self:refresh(true)
                            end}}
                        end
                        buttons[#buttons + 1] = {{text = "取消", callback = function() UIManager:close(choices) end}}
                        choices = ButtonDialog:new{title = "选择天气城市", buttons = buttons}
                        UIManager:show(choices)
                    end)
                end)
            end},
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function KindleDashboard:editNewsSource()
    local input
    input = InputDialog:new{
        title = "自定义新闻 JSON 地址（留空使用 Hacker News）",
        input = self.config.news_external_url,
        input_type = "text",
        buttons = {{
            {text = "取消", callback = function() UIManager:close(input) end},
            {text = "保存", is_enter_default = true, callback = function()
                local url = input:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                if url ~= "" and not url:match("^https://") then
                    UIManager:show(InfoMessage:new{text = "请输入 HTTPS 地址，或留空使用 Hacker News。"})
                    return
                end
                UIManager:close(input)
                self.config.news_external_url = url
                self.settings:saveSetting("news_external_url", url)
                self.settings:flush()
                self.snapshot.news = nil
                self:refresh(true)
            end},
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function KindleDashboard:collectSnapshot()
    local snapshot = Market.fetch(self.config, self.snapshot)
    local sections = Sources.fetch(self.config, self.snapshot)
    snapshot.weather, snapshot.news = sections.weather, sections.news
    local annual = self.snapshot.holidays or self.bundled_holidays
    local year = tonumber(os.date("!%Y", os.time() + 8 * 3600))
    local checked_at = self.snapshot.holidays_checked_at or 0
    if (not annual or annual.year ~= year) and os.time() - checked_at >= 86400 then
        local downloaded = Sources.fetchHolidays(year)
        if downloaded then annual = downloaded end
        checked_at = os.time()
    end
    snapshot.holidays = annual
    snapshot.holidays_checked_at = checked_at
    return snapshot
end

function KindleDashboard:refresh(interactive)
    if not self.dashboard or self.suspended or self.refreshing then return end
    UIManager:unschedule(self.refresh_task)
    if not NetworkMgr:isConnected() then
        self.snapshot.error = "Wi-Fi 未连接"
        for _, entry in ipairs(self.snapshot.entries) do entry.stale = true end
        if self.snapshot.weather then
            self.snapshot.weather.stale, self.snapshot.weather.aqi_stale = true, true
        end
        if self.snapshot.news then self.snapshot.news.stale = true end
        self.dashboard:setSnapshot(self.snapshot, false)
        self:scheduleRefresh()
        if interactive then
            NetworkMgr:runWhenConnected(function() self:refresh(false) end)
        end
        return
    end
    local dashboard = self.dashboard
    self.refreshing = true
    dashboard:setRefreshing(true)
    -- Trapper forks the blocking HTTPS calls. A tap cancels the child and is
    -- resent to the dashboard, so Return remains usable during a slow request.
    Trapper:wrap(function()
        local completed, snapshot = Trapper:dismissableRunInSubprocess(function()
            return self:collectSnapshot()
        end)
        self.refreshing = false
        if completed and type(snapshot) == "table" and type(snapshot.entries) == "table" then
            snapshot.calendar = Calendar.at(os.time(), snapshot.holidays or self.bundled_holidays)
            self.snapshot = snapshot
            self:saveCache()
        end
        if self.dashboard == dashboard and not self.suspended then
            dashboard:setSnapshot(self.snapshot, false)
            -- Trapper replays the cancellation tap before the next scheduled paint.
            if not completed then UIManager:forceRePaint() end
        end
        self:scheduleRefresh()
    end)
end

function KindleDashboard:rotateDashboard()
    if not self.dashboard then return end
    local screen = Device.screen
    local rotation = screen:getRotationMode()
    local new_rotation = rotation % 2 == 0 and (rotation + 1) % 4 or (rotation + 3) % 4
    self:setRotation(new_rotation)
    self.dashboard:onScreenResize(screen:getSize())
    UIManager:setDirty(nil, "full")
end

function KindleDashboard:setRotation(mode)
    if Device.screen:getRotationMode() == mode then return end
    -- Let the underlying reader/file manager reflow too; it will be exposed
    -- when the dashboard closes, with its original orientation restored.
    self.ui:handleEvent(Event:new("SetRotationMode", mode))
end

function KindleDashboard:closeDashboard()
    self:setKeepAwake(false)
    local dashboard = self.dashboard
    if not dashboard then return end
    self.dashboard = nil
    UIManager:unschedule(self.refresh_task)
    UIManager:unschedule(self.clock_task)
    UIManager:close(dashboard)
    self:setRotation(self.original_rotation)
    -- Moon's desktop is a separate window outside FileManager's resize tree.
    local moon_desktop = self.ui.book and self.ui.book.desktop
    if moon_desktop and moon_desktop.updateView then moon_desktop:updateView() end
    self.original_rotation = nil
    UIManager:setDirty(nil, "full")
end

function KindleDashboard:onSuspend()
    self.suspended = true
    self:setKeepAwake(false)
    UIManager:unschedule(self.refresh_task)
    UIManager:unschedule(self.clock_task)
end

function KindleDashboard:onResume()
    self.suspended = false
    if self.dashboard then
        self:setKeepAwake(self.keep_display_on)
        self:updateClock()
        self:scheduleClock()
        UIManager:nextTick(function() self:refresh(false) end)
    end
end

function KindleDashboard:onCloseDocument()
    self:closeDashboard()
end

function KindleDashboard:onCloseWidget()
    self:closeDashboard()
end

function KindleDashboard:onExit()
    self:closeDashboard()
end

return KindleDashboard
