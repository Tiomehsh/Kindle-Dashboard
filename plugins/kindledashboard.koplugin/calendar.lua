local Calendar = {}
local directory = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
local years = dofile(directory .. "/lunar-years.lua")
local OFFSET = 8 * 3600
local WEEKDAYS = {"星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"}
local MONTHS = {"正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"}
local DIGITS = {"一", "二", "三", "四", "五", "六", "七", "八", "九"}
local STEMS = {"甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"}
local BRANCHES = {"子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"}
local ANIMALS = {"鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪"}

local function dayName(day)
    if day == 10 then return "初十" end
    if day == 20 then return "二十" end
    if day == 30 then return "三十" end
    local digit = DIGITS[day % 10]
    if day < 10 then return "初" .. digit end
    if day < 20 then return "十" .. digit end
    return "廿" .. digit
end

function Calendar.lunar(timestamp)
    local shifted = timestamp + OFFSET
    local unix_day = math.floor(shifted / 86400)
    local year = tonumber(os.date("!%Y", shifted))
    if years[year] and unix_day < years[year][1] then year = year - 1 end
    local record = years[year]
    if not record then return nil, "农历数据范围为 1900—2100 年" end
    local remaining = unix_day - record[1]
    if remaining < 0 then return nil, "农历数据范围为 1900—2100 年" end
    local leap_month, bits = record[2], record[3]
    for index = 1, leap_month == 0 and 12 or 13 do
        local days = 29 + math.floor(bits / 2 ^ (index - 1)) % 2
        if remaining < days then
            local leap = leap_month > 0 and index == leap_month + 1
            local month = index
            if leap_month > 0 and index > leap_month then month = month - 1 end
            local branch = (year - 4) % 12 + 1
            local text = STEMS[(year - 4) % 10 + 1] .. BRANCHES[branch] .. ANIMALS[branch]
                .. "年 " .. (leap and "闰" or "") .. MONTHS[month] .. "月" .. dayName(remaining + 1)
            return {year=year, month=month, day=remaining + 1, leap=leap, text=text}
        end
        remaining = remaining - days
    end
    return nil, "农历数据范围为 1900—2100 年"
end

function Calendar.loadBundled()
    local file = io.open(directory .. "/holidays-2026.json", "r")
    if not file then return end
    local content = file:read("*a")
    file:close()
    local ok, data = pcall(require("json").decode, content)
    if ok and type(data) == "table" then return data end
end

local function workState(timestamp, annual)
    local shifted = timestamp + OFFSET
    local date = os.date("!%Y-%m-%d", shifted)
    local weekday = tonumber(os.date("!%w", shifted))
    local year = tonumber(os.date("!%Y", shifted))
    local known = annual and annual.year == year and type(annual.days) == "table"
    if known then
        for _, day in ipairs(annual.days) do
            if day.date == date then
                return day.isOffDay, day.isOffDay and day.name .. "假期" or "调休上班", false
            end
        end
    end
    local resting = weekday == 0 or weekday == 6
    return resting, resting and "周末" or "工作日", not known
end

function Calendar.at(timestamp, annual)
    timestamp = timestamp or os.time()
    local shifted = timestamp + OFFSET
    local date = os.date("!*t", shifted)
    local lunar, lunar_error = Calendar.lunar(timestamp)
    local is_rest, name, estimated = workState(timestamp, annual)
    local next_day
    for days_away = 1, 370 do
        local next_timestamp = timestamp + days_away * 86400
        local next_rest, next_name, next_estimated = workState(next_timestamp, annual)
        if next_rest ~= is_rest then
            next_day = {
                date = os.date("!%m/%d", next_timestamp + OFFSET),
                days_away = days_away,
                name = next_name,
                estimated = next_estimated,
            }
            break
        end
    end
    local leap_year = date.year % 4 == 0 and (date.year % 100 ~= 0 or date.year % 400 == 0)
    local fraction_day = (date.hour * 3600 + date.min * 60 + date.sec) / 86400
    return {
        date_str = os.date("!%Y/%m/%d", shifted),
        weekday = WEEKDAYS[date.wday],
        time = os.date("!%H:%M", shifted),
        lunar = lunar and lunar.text or lunar_error,
        is_rest_today = is_rest,
        day_name = name,
        next_day = next_day,
        year_progress = (date.yday - 1 + fraction_day) / (leap_year and 366 or 365) * 100,
        holiday_region = "中国",
        holiday_estimated = estimated,
    }
end

return Calendar
