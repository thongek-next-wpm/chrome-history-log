# Chrome Browsing History Logger (`.bat`)

A self-contained batch script ([collect_chrome_history.bat](./collect_chrome_history.bat)) that exports Google Chrome browsing history for the **current local machine only** to CSV files (UTF-8 with BOM), categorizes visits by activity type, and extracts search engine queries.

## Features
- **Local machine only**:
  - Saves logs under `logs\<COMPUTERNAME>\` by default.
  - Excludes synced visits from other devices (`originator_cache_guid` in Chrome's `visits` table) when `LOCAL_MACHINE_ONLY=1` (default).
- **Search Engine tracking & query extraction**:
  - Dedicated `Search Engine` category covering Google (`google.*`), Bing, DuckDuckGo, Yahoo, Brave Search, Ecosia, Startpage, Qwant, Kagi, Yandex, Baidu, Ask, Naver, and AOL.
  - Extracts search queries (`SearchQuery`) from Chrome's `keyword_search_terms` table as well as URL query parameters (`?q=`, `?p=`, `?wd=`, `?text=`, `?query=`, YouTube `?search_query=`, Perplexity `?q=`).
- **Activity categorization**:
  - `Search Engine`
  - `Video / Streaming` (YouTube, TikTok, Netflix, Twitch, Viu, Bilibili, etc.)
  - `Music / Audio` (YouTube Music, Spotify, SoundCloud, Joox, etc.)
  - `Gaming` (Steam, Epic Games, Roblox, Riot Games, Garena, Battle.net, gaming domains)
  - `Social / Online Community` (Facebook, Instagram, X/Twitter, Discord, LINE, Reddit, Pantip, etc.)
  - `AI / Productivity / Work` (ChatGPT, Claude, Gemini, GitHub, Google Docs/Drive/Mail, Microsoft 365/Teams, local/intranet IPs)
  - `Shopping / E-Commerce` (Shopee, Lazada, Amazon, Advice, JIB, etc.)
  - `News / Media` (BBC, CNN, Thairath, Bangkok Post, Sanook, Google News, MSN, etc.)
  - `Education / Reference` (Wikipedia, Coursera, Udemy, MDN, Google Scholar, Google Translate, etc.)
  - `Download / File Sharing` (MediaFire, Mega, Dropbox, WeTransfer, etc.)
  - `Browser / Internal` (`chrome://`, `file://`, `about:`, etc.)
  - `Other` (uncategorized domains)
- **Three CSV reports per run**:
  - `ChromeHistory_<COMPUTERNAME>_<USERNAME>_<YYYYMMDD_HHmmss>.csv`: Full chronological visit log (`VisitTime,Computer,WindowsUser,Profile,Category,Domain,SearchQuery,Title,URL,VisitCount`).
  - `ChromeSummary_<COMPUTERNAME>_<USERNAME>_<YYYYMMDD_HHmmss>.csv`: Aggregated summary grouped by `Category` and `Domain` (`Computer,WindowsUser,Category,Domain,Visits,LastVisitTime`).
  - `ChromeSearches_<COMPUTERNAME>_<USERNAME>_<YYYYMMDD_HHmmss>.csv`: Dedicated log of extracted search queries (`VisitTime,Computer,WindowsUser,Profile,Category,Domain,SearchQuery,URL`).
- **Zero external dependencies**: Uses PowerShell and Windows built-in `winsqlite3.dll` (works even while Chrome is open).

## Usage

### 1. Interactive Run
Double-click `collect_chrome_history.bat` to export logs to `logs\<COMPUTERNAME>\`.

### 2. In-Script Configuration
Edit variables at the top of `collect_chrome_history.bat`:
- `CHROME_USER_DATA`: Path to Chrome User Data (default `%LOCALAPPDATA%\Google\Chrome\User Data`)
- `LOG_DIR`: Output folder (default `%BAT_DIR%logs\%COMPUTERNAME%`)
- `DAYS_BACK`: Past days to export (`0` = all available history)
- `LOCAL_MACHINE_ONLY`: Exclude Chrome Sync remote-device visits (`1` = local machine only, `0` = all devices)
- `SEARCH_FILTER`: Optional keyword filter across URL, Title, SearchQuery, Domain, or Category (empty = all)
- `BACKUP_RAW_DB`: Copy raw SQLite `History` files (`1` = yes, `0` = no)
- `PAUSE_ON_EXIT`: Wait for a keypress on exit (`1` = pause, `0` = exit immediately)

### 3. Command-Line Flags
- `--nopause`: Exit immediately without pausing (recommended for Task Scheduler)
- `--days <N>`: Export only the last `N` days (e.g., `--days 7`)
- `--out "<PATH>"`: Custom output folder
- `--source "<PATH>"`: Custom Chrome User Data or profile folder
- `--search "<KEYWORD>"`: Export only rows matching a keyword in URL, Title, SearchQuery, Domain, or Category
- `--all-devices`: Include Chrome Sync visits from other devices
- `--backup`: Also copy raw SQLite `History` files

Example:
```bat
collect_chrome_history.bat --nopause --days 7 --out "D:\ChromeLogs\PC01"
```

## Windows Task Scheduler Example (Daily Run)
- **Program/script**: `C:\path\to\collect_chrome_history.bat`
- **Add arguments**: `--nopause --days 1`
