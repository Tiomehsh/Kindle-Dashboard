# Kindle Dashboard

[中文](README.md)

A native Kindle dashboard inside KOReader. KOReader Lua widgets render the interface, and the Kindle fetches public data directly over HTTPS. No self-hosted server or API key is required. The interface is currently primarily Chinese.

![Paperwhite 3 device screenshot](screenshot.png)

## Panels and sources

- **Calendar and clock**: Gregorian date, weekday, Chinese lunar date (data covers 1900–2100), sexagenary year and zodiac, year progress, Chinese working/rest days, and a countdown to the next change. The clock and calendar use fixed UTC+8 and update locally every minute without network access.
- **Weather and air quality**: Singapore by default, with Chinese or English city search. Displays temperature, conditions, humidity, UV, precipitation probability, daily high/low, rain/snow timing hints, three upcoming forecast slots, and tomorrow’s forecast. Weather icons use bundled black-and-white SVGs. Weather comes from [Open-Meteo](https://open-meteo.com/); air quality uses its CAMS data and **US AQI**, rather than China’s AQI scale. Forecast slots and “today/tomorrow” follow the selected city’s timezone. The third forecast slot takes the default 10:00/18:00 work hours into account.
- **Markets**: Sina Finance supplies the NASDAQ Composite `gb_ixic`, New York gold CFD `hf_GC`, and S&P 500 `gb_inx`. Gold is quoted in USD per troy ounce; **this source identifies the instrument as a CFD, rather than COMEX front-month futures or spot gold**. Each row shows the quote, daily change against the source’s previous close, and an intraday trend. US index history uses five-minute data; gold history uses minute data. Missing values are not interpolated, and longer gaps remain disconnected.
- **Hacker News**: Tries the [official Firebase API](https://github.com/HackerNews/API) top/best lists first. Unavailable or invalid lists, or incomplete story retrieval, trigger the [Algolia mirror](https://hn.algolia.com/api). The mirror takes ten candidates each from front_page and high-scoring stories from the last seven days, applying the same popularity, age, comment, title-keyword sorting and deduplication rules to select up to five stories. Its high-score list is not guaranteed to match Firebase best ordering. The panel displays numbered original headlines; sources, scores, timestamps, and URLs remain in the cache. No translation or AI summaries are provided. If both sources fail, previous headlines and their original fetch time are retained. An optional custom HTTPS JSON news feed is supported.

[Sina Finance](https://finance.sina.com.cn/) quotes and history are fetched directly by the Kindle, without a proxy. Quotes may be delayed and may remain at the previous trading session during market closures. US index history timestamps are interpreted in New York time, and gold history timestamps in UTC+8. The interface retains quote timestamps in UTC+8 and stale/error indicators; weather observation times and news fetch times remain in the cache. A successful request does not mean the underlying observation is new. Missing values or timestamps remain empty/`--`, rather than being replaced with sample data.

Chinese holiday arrangements for 2026 are bundled from [NateScarlet/holiday-cn](https://github.com/NateScarlet/holiday-cn). When the current year is not cached, the plugin attempts to download that year’s arrangements, retrying at most daily after failure. Without matching annual data, it uses weekend rules and marks the result “估算” (estimated). Statutory holidays and compensatory working days are unavailable in that case; countdowns crossing into another year may also involve estimates.

## Installation

Requires a jailbroken Kindle with KOReader installed. KUAL is needed for the KUAL entry; Moon is optional. Device validation on a Paperwhite 3 with KOReader 2026.07.2 and Moon 0.2.10 covers all four panels, real quotes and trends, city search and selection, opening settings during refresh, and restoring the previous orientation on return.

Copy these directories over USB, merging destination directories without replacing the entire KOReader installation:

```text
plugins/kindledashboard.koplugin → Kindle root/koreader/plugins/kindledashboard.koplugin
extensions/Kindle-Dashboard    → Kindle root/extensions/Kindle-Dashboard
```

Safely eject the device and restart KOReader once. The KUAL launcher `extensions/Kindle-Dashboard/bin/boot.sh` must be executable.

Alternatively, from a computer with SSH key login configured, run from the repository:

```sh
sh scripts/deploy.sh KINDLE_IP
# Optional SSH port (default 2222) and private key
sh scripts/deploy.sh KINDLE_IP 2222 ~/.ssh/id_ed25519
```

The script connects as `root`, checks `/mnt/us/koreader`, copies the plugin and KUAL entry, and sets launcher permissions. It does not install KOReader. Set `DASHBOARD_SSH_KNOWN_HOSTS` to use a specific known_hosts file. Restart KOReader after deployment.

## Usage and settings

In KOReader, open **More tools > 阅读仪表盘**. When Moon is installed and its public `desktop.tabs` extension point is available, its desktop also offers an **仪表盘** tab. From KUAL, **Kindle-Dashboard > Open Dashboard** launches KOReader and opens the dashboard automatically. If KOReader is already running, use its internal menu.

The four panels meet without gaps, separated by thin lines, with larger, bold text for the main content. Portrait and landscape layouts adapt to the screen, as do the settings and frontlight dialogs. KOReader renders the weather icons natively without relying on system fonts.

The bottom buttons are **刷新数据** (refresh), **仪表盘设置** (dashboard settings), **旋转屏幕** (rotate), and **返回阅读** (return to reading). Settings include display retention, frontlight brightness, weather city, and news feed. Try an English city name if Chinese search returns no results. Custom news URLs must use HTTPS; leave the field empty to restore Hacker News. The response is a JSON array, for example:

```json
[{"title":"Story title","meta":"Source description","url":"https://example.com/story","time":1792195200}]
```

Only the first five entries are read. `title` is required; other fields are optional, and `time` is Unix seconds.

**保持显示** (keep display on) is enabled by default and prevents automatic screen saver and automatic suspend while the dashboard is open. Turning it off or returning to reading restores the previous keep-awake state. The power button still allows manual sleep, which pauses refreshes; waking restores the saved preference. On Kindle, this uses the native screen saver timer to preserve manual sleep.

**前光亮度** opens KOReader's native frontlight panel, with a slider, plus/minus buttons, minimum, maximum, and an on/off switch. Changes take effect immediately and remain in effect when returning to reading. Display retention does not turn on the frontlight; keeping the device running and increasing brightness both use more battery.

![Dashboard settings on the device](dashboard-settings.png)

![Frontlight brightness controls on the device](dashboard-frontlight.png)

The dashboard attempts a refresh when opened, then waits 300 seconds after each refresh completes before the next one. Automatic refresh does not turn on disconnected Wi-Fi; manual refresh can invoke KOReader's network connection flow. Requests run in a cancellable subprocess, and a tap can cancel the wait. Failed sources retain their available cached data, original timestamps, and stale indicators. A first launch without cached data shows empty fields. The clock and calendar continue locally while offline.

Rotation uses KOReader’s native screen orientation interface, with no device-specific rotation number to configure. “返回阅读” closes the dashboard, restores the previous orientation, and returns to the reader or file manager. Moon’s desktop reflows for the restored orientation without a device reboot.

Settings and cache live in KOReader’s settings directory, usually `/mnt/us/koreader/settings/`:

- `kindledashboard.lua`: display retention, weather city, coordinates, timezone, and custom news URL. KOReader manages frontlight settings.
- `kindledashboard-cache.json`: the latest data snapshot, initially marked stale when reloaded after restart.

The refresh interval and three market symbols are currently defined in the plugin’s `market.lua` defaults; the settings dialog does not expose them.

## Validation and troubleshooting

After installation, confirm the menu entry appears, then check all four panels, city changes, manual and automatic refresh, cached data after disconnecting Wi-Fi, portrait/landscape rotation, and orientation restoration when returning to reading. With Moon, also check the desktop tab. Read source timestamps and stale indicators to distinguish cached observations from current data.

Device checks include searching for “杭州”, selecting Hangzhou in Zhejiang, and tapping settings and return while a refresh is active. Settings dialogs appear above the dashboard. Cancelled refreshes repaint widgets before replaying button taps, preventing lost taps and touch-feedback errors. Display retention checks cover preference persistence, repeated open/close, restoration of previous keep-awake states, and manual sleep and resume. Frontlight checks cover the slider, plus/minus buttons, and switch, with actual hardware brightness readings. Portrait and landscape checks cover panel alignment without gaps, larger text, and settings/frontlight dialogs staying within the screen. All seven weather icons were checked through native SVG rendering on the Kindle.

KUAL launch output is written to `/tmp/kindle-dashboard-launch.log`. For plugin loading or runtime errors, inspect KOReader’s `crash.log`. Public API availability, rate limits, and regional connectivity can affect refreshes.

This project is licensed under the MIT License.
