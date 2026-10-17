local Calendar = dofile("plugins/kindledashboard.koplugin/calendar.lua")
local function check(value, message) assert(value, message) end
local function lunar(timestamp, year, month, day, leap)
    local value = assert(Calendar.lunar(timestamp))
    check(value.year == year and value.month == month and value.day == day and value.leap == leap,
        "unexpected lunar date: " .. value.text)
end
lunar(1771286400, 2026, 1, 1, false) -- 2026-02-17 00:00 UTC
lunar(1771344000, 2026, 1, 2, false) -- UTC+8 has crossed to the next day
lunar(1771200000, 2025, 12, 29, false) -- New Year's Eve
lunar(1753401600, 2025, 6, 1, true) -- Leap sixth month begins
lunar(1792195200, 2026, 9, 8, false) -- 2026-10-17 00:00 UTC
local annual = {year=2026, days={
    {date="2026-10-09",name="国庆节",isOffDay=true},
    {date="2026-10-10",name="国庆节",isOffDay=false},
}}
local makeup = Calendar.at(1791590400, annual) -- Saturday 2026-10-10
check(not makeup.is_rest_today and makeup.day_name == "调休上班", "make-up Saturday must be a workday")
check(makeup.next_day.days_away == 1, "next rest day after make-up Saturday must be Sunday")
local weekend = Calendar.at(1792195200, annual)
check(weekend.is_rest_today and weekend.next_day.days_away == 2, "Saturday must point to Monday")
local unknown = Calendar.at(1792195200, {year=2025,days={}})
check(unknown.holiday_estimated, "unavailable holiday year must be explicitly estimated")
local before_midnight = Calendar.at(1792166399, annual)
local after_midnight = Calendar.at(1792166400, annual)
check(before_midnight.date_str == "2026/10/16" and after_midnight.date_str == "2026/10/17", "clock must change date at UTC+8 midnight")
check(after_midnight.time == "00:00", "clock timezone must be UTC+8")
check(after_midnight.year_progress > 79 and after_midnight.year_progress < 80, "year progress must use calendar day")
print("calendar_spec: lunar dates, timezone, makeup workday, next day and unavailable-year checks passed")
