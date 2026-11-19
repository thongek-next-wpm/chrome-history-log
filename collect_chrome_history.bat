@echo off
setlocal EnableExtensions
chcp 65001 >nul

:: ============================================================================
:: Chrome Browsing History Logger (collect_chrome_history.bat)
:: Exports Google Chrome browsing history for this local machine to CSV,
:: categorized by activity (Search Engine, Video/Streaming, Gaming, Social, etc.)
:: and extracts search engine queries.
:: Tip: Pass --nopause when running from Windows Task Scheduler.
:: ============================================================================

:: --- Save script path before shifting arguments (%0 shifts too) ---
set "BAT_SELF=%~f0"
set "BAT_DIR=%~dp0"

:: --- Configuration (edit as needed) ---
set "CHROME_USER_DATA=%LOCALAPPDATA%\Google\Chrome\User Data"
set "LOG_DIR=%BAT_DIR%logs\%COMPUTERNAME%"

:: Number of past days to export (0 = export all available history)
set "DAYS_BACK=0"

:: Collect visits from this machine only, excluding Chrome Sync remote devices (1 = local only, 0 = all)
set "LOCAL_MACHINE_ONLY=1"

:: Optional keyword filter across URL, Title, SearchQuery, Domain, or Category (empty = export all)
set "SEARCH_FILTER="

:: Also copy raw SQLite History database files (1 = yes, 0 = no)
set "BACKUP_RAW_DB=0"

:: Wait for a keypress on exit (1 = pause on interactive run, 0 = exit immediately)
set "PAUSE_ON_EXIT=1"

:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--nopause" (set "PAUSE_ON_EXIT=0" & shift & goto :parse_args)
if /i "%~1"=="-nopause" (set "PAUSE_ON_EXIT=0" & shift & goto :parse_args)
if /i "%~1"=="--backup" (set "BACKUP_RAW_DB=1" & shift & goto :parse_args)
if /i "%~1"=="--all-devices" (set "LOCAL_MACHINE_ONLY=0" & shift & goto :parse_args)
if /i "%~1"=="--days" (if not "%~2"=="" (set "DAYS_BACK=%~2" & shift & shift & goto :parse_args))
if /i "%~1"=="--out" (if not "%~2"=="" (set "LOG_DIR=%~2" & shift & shift & goto :parse_args))
if /i "%~1"=="--source" (if not "%~2"=="" (set "CHROME_USER_DATA=%~2" & shift & shift & goto :parse_args))
if /i "%~1"=="--search" (if not "%~2"=="" (set "SEARCH_FILTER=%~2" & shift & shift & goto :parse_args))
shift
goto :parse_args
:args_done

echo [INFO] Collecting Chrome history for machine "%COMPUTERNAME%" (User: "%USERNAME%")...
echo [INFO] Chrome User Data : "%CHROME_USER_DATA%"
echo [INFO] Output Folder    : "%LOG_DIR%"
if defined SEARCH_FILTER echo [INFO] Keyword Filter   : "%SEARCH_FILTER%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $c=[System.IO.File]::ReadAllText($env:BAT_SELF,[System.Text.Encoding]::UTF8); $p=([regex]('(?m)^###__PS_'+'START__###\r?$')).Split($c,2); if($p.Count -lt 2){throw 'Embedded PowerShell section not found.'}; &([ScriptBlock]::Create($p[1]))"

set "EXIT_CODE=%ERRORLEVEL%"

if "%PAUSE_ON_EXIT%"=="1" (
    echo.
    pause
)

exit /b %EXIT_CODE%

###__PS_START__###
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Copy-FileAllowLocked {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestPath
    )
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $inStream = [System.IO.File]::Open($SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $outStream = [System.IO.File]::Create($DestPath)
        try {
            $inStream.CopyTo($outStream)
        }
        finally {
            $outStream.Dispose()
        }
    }
    finally {
        $inStream.Dispose()
    }
}

function Get-ProfileDisplayMap {
    param([string]$UserDataPath)
    $map = @{}
    $localStatePath = Join-Path $UserDataPath 'Local State'
    if (-not (Test-Path -LiteralPath $localStatePath -PathType Leaf)) {
        return $map
    }
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        Copy-FileAllowLocked -SourcePath $localStatePath -DestPath $tempFile
        $raw = [System.IO.File]::ReadAllText($tempFile, [System.Text.Encoding]::UTF8)
        $json = $raw | ConvertFrom-Json
        if ($json.profile -and $json.profile.info_cache) {
            foreach ($prop in $json.profile.info_cache.PSObject.Properties) {
                $displayName = $prop.Value.name
                if (-not [string]::IsNullOrWhiteSpace($displayName)) {
                    $map[$prop.Name] = $displayName.Trim()
                }
            }
        }
    }
    catch {
        # Fallback to folder names when Local State cannot be parsed
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
    return $map
}

function Resolve-ChromeProfiles {
    param([string]$UserDataPath)
    $profiles = New-Object System.Collections.Generic.List[object]

    $directHistory = Join-Path $UserDataPath 'History'
    if (Test-Path -LiteralPath $directHistory -PathType Leaf) {
        $item = Get-Item -LiteralPath $directHistory
        if ($item.Length -gt 0) {
            $folderName = Split-Path -Path $UserDataPath -Leaf
            $profiles.Add([PSCustomObject]@{
                FolderName  = $folderName
                DisplayName = $folderName
                Directory   = $UserDataPath
                HistoryPath = $directHistory
            })
        }
        return $profiles
    }

    $nameMap = Get-ProfileDisplayMap -UserDataPath $UserDataPath
    $subDirs = Get-ChildItem -LiteralPath $UserDataPath -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $subDirs) {
        $histPath = Join-Path $dir.FullName 'History'
        if (Test-Path -LiteralPath $histPath -PathType Leaf) {
            $histFile = Get-Item -LiteralPath $histPath -ErrorAction SilentlyContinue
            if ($histFile -and $histFile.Length -gt 0) {
                $display = $dir.Name
                if ($nameMap.ContainsKey($dir.Name) -and $nameMap[$dir.Name] -ne $dir.Name) {
                    $display = "$($dir.Name) ($($nameMap[$dir.Name]))"
                }
                $profiles.Add([PSCustomObject]@{
                    FolderName  = $dir.Name
                    DisplayName = $display
                    Directory   = $dir.FullName
                    HistoryPath = $histPath
                })
            }
        }
    }
    return $profiles
}

$winSqliteCSharp = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

public class ChromeHistoryEntry {
    public long VisitTimeMicros;
    public string VisitTimeLocal;
    public string Profile;
    public string Category;
    public string Domain;
    public string SearchQuery;
    public string Title;
    public string Url;
    public long VisitCount;
}

public class CategoryRuleGroup {
    public string Category;
    public string[] Domains;
    public CategoryRuleGroup(string category, string[] domains) {
        Category = category;
        Domains = domains;
    }
}

public class SummaryRow {
    public string Category;
    public string Domain;
    public long Visits;
    public long LastVisitMicros;
    public string LastVisitLocal;
}

public static class ActivityClassifier {
    private static readonly Regex GoogleDomainRegex = new Regex(
        @"^(?:[a-z0-9-]+\.)*google\.(?:com|co\.[a-z]{2}|com\.[a-z]{2}|[a-z]{2,3})$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled
    );

    private static readonly CategoryRuleGroup[] RuleGroups = new CategoryRuleGroup[] {
        new CategoryRuleGroup("Music / Audio", new string[] {
            "music.youtube.com", "spotify.com", "soundcloud.com", "music.apple.com",
            "joox.com", "tidal.com", "deezer.com", "fungjai.com"
        }),
        new CategoryRuleGroup("Video / Streaming", new string[] {
            "youtube.com", "youtu.be", "tiktok.com", "twitch.tv", "kick.com",
            "netflix.com", "bilibili.tv", "bilibili.com", "vimeo.com", "dailymotion.com",
            "viu.com", "iq.com", "wetv.vip", "disneyplus.com", "hotstar.com",
            "trueid.net", "primevideo.com", "max.com", "crunchyroll.com", "rumble.com",
            "monomax.me", "bugaboo.tv", "aisplay.ais.co.th"
        }),
        new CategoryRuleGroup("Gaming", new string[] {
            "steampowered.com", "steamcommunity.com", "epicgames.com", "roblox.com",
            "riotgames.com", "leagueoflegends.com", "playvalorant.com", "garena.com",
            "garena.co.th", "blizzard.com", "battle.net", "hoyoverse.com", "minecraft.net",
            "poki.com", "crazygames.com", "y8.com", "friv.com", "itch.io", "ea.com",
            "ubisoft.com", "playstation.com", "xbox.com", "nintendo.com", "curseforge.com",
            "nexusmods.com", "op.gg", "tracker.gg", "ign.com", "gamespot.com"
        }),
        new CategoryRuleGroup("Social / Online Community", new string[] {
            "facebook.com", "fb.com", "messenger.com", "instagram.com", "threads.net",
            "twitter.com", "x.com", "reddit.com", "pantip.com", "discord.com",
            "discordapp.com", "line.me", "whatsapp.com", "telegram.org", "t.me",
            "pinterest.com", "snapchat.com", "tumblr.com", "linkedin.com", "weibo.com",
            "quora.com", "vk.com"
        }),
        new CategoryRuleGroup("AI / Productivity / Work", new string[] {
            "chatgpt.com", "openai.com", "claude.ai", "gemini.google.com",
            "copilot.microsoft.com", "perplexity.ai", "github.com", "gitlab.com",
            "stackoverflow.com", "docs.google.com", "drive.google.com", "sheets.google.com",
            "slides.google.com", "mail.google.com", "calendar.google.com", "meet.google.com",
            "chat.google.com", "office.com", "office365.com", "microsoft365.com",
            "sharepoint.com", "teams.microsoft.com", "outlook.live.com", "outlook.office.com",
            "outlook.office365.com", "onedrive.live.com", "zoom.us", "canva.com",
            "figma.com", "notion.so", "trello.com", "slack.com", "atlassian.net",
            "anydesk.com", "teamviewer.com"
        }),
        new CategoryRuleGroup("Shopping / E-Commerce", new string[] {
            "shopee.co.th", "shopee.com", "lazada.co.th", "lazada.com", "amazon.com",
            "aliexpress.com", "alibaba.com", "ebay.com", "temu.com", "shein.com",
            "kaidee.com", "advice.co.th", "jib.co.th", "bnn.in.th", "mercular.com",
            "powerbuy.co.th", "central.co.th", "lotuss.com", "bigc.co.th"
        }),
        new CategoryRuleGroup("News / Media", new string[] {
            "thairath.co.th", "matichon.co.th", "khaosod.co.th", "dailynews.co.th",
            "bangkokpost.com", "nationthailand.com", "thaipbs.or.th", "thestandard.co",
            "sanook.com", "kapook.com", "mthai.com", "prachachat.net", "posttoday.com",
            "pptvhd36.com", "mgronline.com", "komchadluek.net", "tnnthailand.com",
            "workpointtoday.com", "bbc.com", "bbc.co.uk", "cnn.com", "reuters.com",
            "bloomberg.com", "msn.com"
        }),
        new CategoryRuleGroup("Education / Reference", new string[] {
            "wikipedia.org", "w3schools.com", "developer.mozilla.org", "learn.microsoft.com",
            "coursera.org", "udemy.com", "edx.org", "khanacademy.org"
        }),
        new CategoryRuleGroup("Download / File Sharing", new string[] {
            "mediafire.com", "mega.nz", "mega.io", "4shared.com", "dropbox.com",
            "wetransfer.com", "filehippo.com", "sourceforge.net"
        }),
        new CategoryRuleGroup("Search Engine", new string[] {
            "bing.com", "duckduckgo.com", "search.yahoo.com", "yahoo.com",
            "search.brave.com", "ecosia.org", "startpage.com", "qwant.com",
            "kagi.com", "yandex.com", "yandex.ru", "baidu.com", "ask.com",
            "search.naver.com", "naver.com", "aol.com"
        })
    };

    private static bool DomainMatches(string host, string pattern) {
        return host.Equals(pattern, StringComparison.OrdinalIgnoreCase)
            || host.EndsWith("." + pattern, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsPrivateOrInternalHost(string host) {
        if (string.IsNullOrEmpty(host)) return false;
        if (host.Equals("localhost", StringComparison.OrdinalIgnoreCase)
            || host.EndsWith(".local", StringComparison.OrdinalIgnoreCase)
            || host.EndsWith(".internal", StringComparison.OrdinalIgnoreCase)
            || host.EndsWith(".lan", StringComparison.OrdinalIgnoreCase)
            || host.IndexOf('.') < 0) {
            return true;
        }
        IPAddress ip;
        if (IPAddress.TryParse(host, out ip)) {
            if (IPAddress.IsLoopback(ip)) return true;
            if (ip.AddressFamily == AddressFamily.InterNetwork) {
                byte[] b = ip.GetAddressBytes();
                if (b[0] == 10) return true;
                if (b[0] == 127) return true;
                if (b[0] == 192 && b[1] == 168) return true;
                if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
                if (b[0] == 169 && b[1] == 254) return true;
            }
        }
        return false;
    }

    private static bool ContainsAnyToken(string text, string[] tokens) {
        for (int i = 0; i < tokens.Length; i++) {
            if (text.IndexOf(tokens[i], StringComparison.OrdinalIgnoreCase) >= 0) return true;
        }
        return false;
    }

    private static string GetQueryParam(string queryString, string[] paramNames) {
        if (string.IsNullOrEmpty(queryString)) return string.Empty;
        string trimmed = queryString.StartsWith("?") ? queryString.Substring(1) : queryString;
        if (string.IsNullOrEmpty(trimmed)) return string.Empty;

        string[] pairs = trimmed.Split('&');
        for (int p = 0; p < pairs.Length; p++) {
            string pair = pairs[p];
            int eq = pair.IndexOf('=');
            if (eq <= 0) continue;
            string key = pair.Substring(0, eq);
            for (int n = 0; n < paramNames.Length; n++) {
                if (key.Equals(paramNames[n], StringComparison.OrdinalIgnoreCase)) {
                    string rawVal = pair.Substring(eq + 1).Replace("+", " ");
                    try {
                        return Uri.UnescapeDataString(rawVal).Trim();
                    }
                    catch {
                        return rawVal.Trim();
                    }
                }
            }
        }
        return string.Empty;
    }

    public static string ExtractSearchQuery(Uri uri, string host, string category) {
        if (uri == null || string.IsNullOrEmpty(uri.Query)) return string.Empty;

        if (category == "Search Engine") {
            if (DomainMatches(host, "yahoo.com")) {
                return GetQueryParam(uri.Query, new string[] { "p", "q" });
            }
            if (DomainMatches(host, "baidu.com")) {
                return GetQueryParam(uri.Query, new string[] { "wd", "word", "q" });
            }
            if (DomainMatches(host, "yandex.com") || DomainMatches(host, "yandex.ru")) {
                return GetQueryParam(uri.Query, new string[] { "text", "q" });
            }
            if (DomainMatches(host, "naver.com")) {
                return GetQueryParam(uri.Query, new string[] { "query", "q" });
            }
            return GetQueryParam(uri.Query, new string[] { "q", "query" });
        }

        if (DomainMatches(host, "youtube.com") && uri.AbsolutePath.Equals("/results", StringComparison.OrdinalIgnoreCase)) {
            return GetQueryParam(uri.Query, new string[] { "search_query" });
        }
        if (DomainMatches(host, "perplexity.ai")) {
            return GetQueryParam(uri.Query, new string[] { "q" });
        }

        return string.Empty;
    }

    public static void Classify(string url, string dbSearchTerm, out string domain, out string category, out string searchQuery) {
        domain = string.Empty;
        category = "Other";
        searchQuery = dbSearchTerm ?? string.Empty;
        if (string.IsNullOrWhiteSpace(url)) return;

        Uri uri;
        if (!Uri.TryCreate(url, UriKind.Absolute, out uri)) {
            return;
        }

        string scheme = uri.Scheme.ToLowerInvariant();
        if (scheme == "chrome" || scheme == "chrome-extension" || scheme == "edge"
            || scheme == "about" || scheme == "file" || scheme == "data" || scheme == "blob") {
            domain = scheme + "://";
            category = "Browser / Internal";
            return;
        }

        string host = (uri.Host ?? string.Empty).ToLowerInvariant();
        domain = host;
        if (string.IsNullOrEmpty(host)) return;

        if (host.StartsWith("scholar.google.", StringComparison.OrdinalIgnoreCase)
            || host.StartsWith("translate.google.", StringComparison.OrdinalIgnoreCase)) {
            category = "Education / Reference";
        }
        else if (host.StartsWith("news.google.", StringComparison.OrdinalIgnoreCase)) {
            category = "News / Media";
        }
        else {
            bool matched = false;
            for (int g = 0; g < RuleGroups.Length; g++) {
                string[] domains = RuleGroups[g].Domains;
                for (int d = 0; d < domains.Length; d++) {
                    if (DomainMatches(host, domains[d])) {
                        category = RuleGroups[g].Category;
                        matched = true;
                        break;
                    }
                }
                if (matched) break;
            }

            if (!matched) {
                if (GoogleDomainRegex.IsMatch(host)) {
                    category = "Search Engine";
                }
                else if (IsPrivateOrInternalHost(host)) {
                    category = "AI / Productivity / Work";
                }
                else if (ContainsAnyToken(host, new string[] { "game", "gaming", "esport", "casino", "slot" })) {
                    category = "Gaming";
                }
                else if (ContainsAnyToken(host, new string[] { "video", "movie", "cinema", "stream", "anime", "iptv", "tvonline" })) {
                    category = "Video / Streaming";
                }
                else if (ContainsAnyToken(host, new string[] { "music", "radio", "podcast", "mp3" })) {
                    category = "Music / Audio";
                }
                else if (ContainsAnyToken(host, new string[] { "social", "forum", "webboard", "community", "chat" })) {
                    category = "Social / Online Community";
                }
                else if (ContainsAnyToken(host, new string[] { "shop", "store", "mall", "mart", "market" })) {
                    category = "Shopping / E-Commerce";
                }
                else if (ContainsAnyToken(host, new string[] { "news", "press" })) {
                    category = "News / Media";
                }
            }
        }

        if (string.IsNullOrWhiteSpace(searchQuery)) {
            searchQuery = ExtractSearchQuery(uri, host, category);
        }
    }
}

public static class WinSqliteHistory {
    private const int SQLITE_OK = 0;
    private const int SQLITE_ROW = 100;
    private const int SQLITE_NULL = 5;
    private const int SQLITE_OPEN_READONLY = 1;
    private const int SQLITE_OPEN_READWRITE = 2;

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr zVfs);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern int sqlite3_close(IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern int sqlite3_prepare_v2(IntPtr db, byte[] zSql, int nByte, out IntPtr ppStmt, out IntPtr pzTail);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern int sqlite3_step(IntPtr stmt);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern int sqlite3_finalize(IntPtr stmt);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern IntPtr sqlite3_column_text(IntPtr stmt, int iCol);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern int sqlite3_column_bytes(IntPtr stmt, int iCol);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern long sqlite3_column_int64(IntPtr stmt, int iCol);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern int sqlite3_column_type(IntPtr stmt, int iCol);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern IntPtr sqlite3_errmsg(IntPtr db);

    private static string GetUtf8Column(IntPtr stmt, int col) {
        if (sqlite3_column_type(stmt, col) == SQLITE_NULL) return string.Empty;
        IntPtr ptr = sqlite3_column_text(stmt, col);
        if (ptr == IntPtr.Zero) return string.Empty;
        int len = sqlite3_column_bytes(stmt, col);
        if (len <= 0) return string.Empty;
        byte[] buf = new byte[len];
        Marshal.Copy(ptr, buf, 0, len);
        return Encoding.UTF8.GetString(buf);
    }

    private static string GetErrorMessage(IntPtr db) {
        if (db == IntPtr.Zero) return "Unknown SQLite error";
        IntPtr ptr = sqlite3_errmsg(db);
        if (ptr == IntPtr.Zero) return "Unknown SQLite error";
        int len = 0;
        while (Marshal.ReadByte(ptr, len) != 0) len++;
        if (len == 0) return "Unknown SQLite error";
        byte[] buf = new byte[len];
        Marshal.Copy(ptr, buf, 0, len);
        return Encoding.UTF8.GetString(buf);
    }

    private static string FormatChromeTimeLocal(long visitTimeMicros, long maxMicros) {
        if (visitTimeMicros <= 0 || visitTimeMicros > maxMicros) return string.Empty;
        try {
            return DateTime.FromFileTimeUtc(visitTimeMicros * 10L).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss");
        }
        catch {
            return string.Empty;
        }
    }

    private static string CsvEscape(string value) {
        if (string.IsNullOrEmpty(value)) return string.Empty;
        string cleaned = value.Replace("\r\n", " ").Replace("\r", " ").Replace("\n", " ");
        bool mustQuote = cleaned.IndexOfAny(new char[] { ',', '"' }) >= 0
            || cleaned.StartsWith(" ")
            || cleaned.EndsWith(" ");
        if (!mustQuote) return cleaned;
        return "\"" + cleaned.Replace("\"", "\"\"") + "\"";
    }

    private static bool HasTable(IntPtr db, string tableName) {
        IntPtr stmt = IntPtr.Zero;
        try {
            byte[] sqlBytes = Encoding.UTF8.GetBytes("SELECT 1 FROM sqlite_master WHERE type='table' AND name='" + tableName.Replace("'", "''") + "' LIMIT 1;\0");
            IntPtr tail;
            if (sqlite3_prepare_v2(db, sqlBytes, -1, out stmt, out tail) != SQLITE_OK) return false;
            return sqlite3_step(stmt) == SQLITE_ROW;
        }
        finally {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
        }
    }

    private static bool HasColumn(IntPtr db, string tableName, string columnName) {
        IntPtr stmt = IntPtr.Zero;
        try {
            byte[] sqlBytes = Encoding.UTF8.GetBytes("PRAGMA table_info(" + tableName + ");\0");
            IntPtr tail;
            if (sqlite3_prepare_v2(db, sqlBytes, -1, out stmt, out tail) != SQLITE_OK) return false;
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                if (GetUtf8Column(stmt, 1).Equals(columnName, StringComparison.OrdinalIgnoreCase)) {
                    return true;
                }
            }
            return false;
        }
        finally {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
        }
    }

    private static Dictionary<long, string> LoadSearchTerms(IntPtr db) {
        Dictionary<long, string> map = new Dictionary<long, string>();
        if (!HasTable(db, "keyword_search_terms")) return map;

        IntPtr stmt = IntPtr.Zero;
        try {
            byte[] sqlBytes = Encoding.UTF8.GetBytes("SELECT url_id, IFNULL(term, '') FROM keyword_search_terms;\0");
            IntPtr tail;
            if (sqlite3_prepare_v2(db, sqlBytes, -1, out stmt, out tail) != SQLITE_OK) return map;
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                long urlId = sqlite3_column_int64(stmt, 0);
                string term = GetUtf8Column(stmt, 1).Trim();
                if (!string.IsNullOrEmpty(term) && !map.ContainsKey(urlId)) {
                    map[urlId] = term;
                }
            }
        }
        finally {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
        }
        return map;
    }

    private static bool MatchesSearchFilter(ChromeHistoryEntry entry, string filter) {
        if (string.IsNullOrWhiteSpace(filter)) return true;
        return entry.Category.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0
            || entry.Domain.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0
            || entry.SearchQuery.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0
            || entry.Title.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0
            || entry.Url.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    public static int ReadHistory(string dbPath, string profileName, long minVisitTimeMicros, bool localMachineOnly, string searchFilter, List<ChromeHistoryEntry> results) {
        IntPtr db = IntPtr.Zero;
        IntPtr stmt = IntPtr.Zero;
        byte[] pathBytes = Encoding.UTF8.GetBytes(dbPath + "\0");
        long maxMicros = DateTime.MaxValue.ToFileTimeUtc() / 10L;
        int count = 0;

        try {
            int rc = sqlite3_open_v2(pathBytes, out db, SQLITE_OPEN_READWRITE, IntPtr.Zero);
            if (rc != SQLITE_OK) {
                if (db != IntPtr.Zero) { sqlite3_close(db); db = IntPtr.Zero; }
                rc = sqlite3_open_v2(pathBytes, out db, SQLITE_OPEN_READONLY, IntPtr.Zero);
                if (rc != SQLITE_OK) {
                    throw new InvalidOperationException("Cannot open SQLite DB (rc=" + rc + "): " + GetErrorMessage(db));
                }
            }

            Dictionary<long, string> searchTerms = LoadSearchTerms(db);

            List<string> whereParts = new List<string>();
            if (minVisitTimeMicros > 0) {
                whereParts.Add("v.visit_time >= " + minVisitTimeMicros);
            }
            if (localMachineOnly && HasColumn(db, "visits", "originator_cache_guid")) {
                whereParts.Add("(v.originator_cache_guid IS NULL OR v.originator_cache_guid = '')");
            }

            string sql = "SELECT v.visit_time, u.id, IFNULL(u.title, ''), IFNULL(u.url, ''), IFNULL(u.visit_count, 0) " +
                         "FROM visits v INNER JOIN urls u ON v.url = u.id ";
            if (whereParts.Count > 0) {
                sql += "WHERE " + string.Join(" AND ", whereParts.ToArray()) + " ";
            }
            sql += "ORDER BY v.visit_time DESC";

            byte[] sqlBytes = Encoding.UTF8.GetBytes(sql + "\0");
            IntPtr tail;
            rc = sqlite3_prepare_v2(db, sqlBytes, -1, out stmt, out tail);
            if (rc != SQLITE_OK) {
                throw new InvalidOperationException("Cannot prepare SQL query (rc=" + rc + "): " + GetErrorMessage(db));
            }

            while (sqlite3_step(stmt) == SQLITE_ROW) {
                long vt = sqlite3_column_int64(stmt, 0);
                long urlId = sqlite3_column_int64(stmt, 1);
                string title = GetUtf8Column(stmt, 2);
                string url = GetUtf8Column(stmt, 3);
                string dbTerm;
                searchTerms.TryGetValue(urlId, out dbTerm);

                string domain;
                string category;
                string searchQuery;
                ActivityClassifier.Classify(url, dbTerm, out domain, out category, out searchQuery);

                ChromeHistoryEntry entry = new ChromeHistoryEntry();
                entry.VisitTimeMicros = vt;
                entry.VisitTimeLocal = FormatChromeTimeLocal(vt, maxMicros);
                entry.Profile = profileName;
                entry.Category = category;
                entry.Domain = domain;
                entry.SearchQuery = searchQuery;
                entry.Title = title;
                entry.Url = url;
                entry.VisitCount = sqlite3_column_int64(stmt, 4);

                if (MatchesSearchFilter(entry, searchFilter)) {
                    results.Add(entry);
                    count++;
                }
            }
            return count;
        }
        finally {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
            if (db != IntPtr.Zero) sqlite3_close(db);
        }
    }

    public static void WriteDetailCsv(string outputPath, string computerName, string userName, List<ChromeHistoryEntry> entries) {
        entries.Sort(delegate(ChromeHistoryEntry a, ChromeHistoryEntry b) {
            return b.VisitTimeMicros.CompareTo(a.VisitTimeMicros);
        });

        string escComputer = CsvEscape(computerName);
        string escUser = CsvEscape(userName);

        using (StreamWriter writer = new StreamWriter(outputPath, false, new UTF8Encoding(true))) {
            writer.WriteLine("VisitTime,Computer,WindowsUser,Profile,Category,Domain,SearchQuery,Title,URL,VisitCount");
            for (int i = 0; i < entries.Count; i++) {
                ChromeHistoryEntry e = entries[i];
                writer.Write(CsvEscape(e.VisitTimeLocal));
                writer.Write(',');
                writer.Write(escComputer);
                writer.Write(',');
                writer.Write(escUser);
                writer.Write(',');
                writer.Write(CsvEscape(e.Profile));
                writer.Write(',');
                writer.Write(CsvEscape(e.Category));
                writer.Write(',');
                writer.Write(CsvEscape(e.Domain));
                writer.Write(',');
                writer.Write(CsvEscape(e.SearchQuery));
                writer.Write(',');
                writer.Write(CsvEscape(e.Title));
                writer.Write(',');
                writer.Write(CsvEscape(e.Url));
                writer.Write(',');
                writer.WriteLine(e.VisitCount);
            }
        }
    }

    public static int WriteSearchesCsv(string outputPath, string computerName, string userName, List<ChromeHistoryEntry> entries) {
        string escComputer = CsvEscape(computerName);
        string escUser = CsvEscape(userName);
        int searchCount = 0;

        using (StreamWriter writer = new StreamWriter(outputPath, false, new UTF8Encoding(true))) {
            writer.WriteLine("VisitTime,Computer,WindowsUser,Profile,Category,Domain,SearchQuery,URL");
            for (int i = 0; i < entries.Count; i++) {
                ChromeHistoryEntry e = entries[i];
                if (string.IsNullOrWhiteSpace(e.SearchQuery)) continue;
                writer.Write(CsvEscape(e.VisitTimeLocal));
                writer.Write(',');
                writer.Write(escComputer);
                writer.Write(',');
                writer.Write(escUser);
                writer.Write(',');
                writer.Write(CsvEscape(e.Profile));
                writer.Write(',');
                writer.Write(CsvEscape(e.Category));
                writer.Write(',');
                writer.Write(CsvEscape(e.Domain));
                writer.Write(',');
                writer.Write(CsvEscape(e.SearchQuery));
                writer.Write(',');
                writer.WriteLine(CsvEscape(e.Url));
                searchCount++;
            }
        }

        return searchCount;
    }

    public static Dictionary<string, long> WriteSummaryCsv(string outputPath, string computerName, string userName, List<ChromeHistoryEntry> entries) {
        Dictionary<string, SummaryRow> byDomain = new Dictionary<string, SummaryRow>(StringComparer.OrdinalIgnoreCase);
        Dictionary<string, long> byCategory = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);

        for (int i = 0; i < entries.Count; i++) {
            ChromeHistoryEntry e = entries[i];
            long catCount;
            byCategory.TryGetValue(e.Category, out catCount);
            byCategory[e.Category] = catCount + 1;

            string key = e.Category + "\t" + e.Domain;
            SummaryRow row;
            if (!byDomain.TryGetValue(key, out row)) {
                row = new SummaryRow();
                row.Category = e.Category;
                row.Domain = e.Domain;
                row.Visits = 0;
                row.LastVisitMicros = 0;
                row.LastVisitLocal = string.Empty;
                byDomain[key] = row;
            }
            row.Visits++;
            if (e.VisitTimeMicros > row.LastVisitMicros) {
                row.LastVisitMicros = e.VisitTimeMicros;
                row.LastVisitLocal = e.VisitTimeLocal;
            }
        }

        List<SummaryRow> sortedRows = new List<SummaryRow>(byDomain.Values);
        sortedRows.Sort(delegate(SummaryRow a, SummaryRow b) {
            int cmp = b.Visits.CompareTo(a.Visits);
            if (cmp != 0) return cmp;
            return string.Compare(a.Domain, b.Domain, StringComparison.OrdinalIgnoreCase);
        });

        string escComputer = CsvEscape(computerName);
        string escUser = CsvEscape(userName);

        using (StreamWriter writer = new StreamWriter(outputPath, false, new UTF8Encoding(true))) {
            writer.WriteLine("Computer,WindowsUser,Category,Domain,Visits,LastVisitTime");
            for (int i = 0; i < sortedRows.Count; i++) {
                SummaryRow r = sortedRows[i];
                writer.Write(escComputer);
                writer.Write(',');
                writer.Write(escUser);
                writer.Write(',');
                writer.Write(CsvEscape(r.Category));
                writer.Write(',');
                writer.Write(CsvEscape(r.Domain));
                writer.Write(',');
                writer.Write(r.Visits);
                writer.Write(',');
                writer.WriteLine(CsvEscape(r.LastVisitLocal));
            }
        }

        return byCategory;
    }
}
'@

$chromeUserData = ($env:CHROME_USER_DATA).Trim()
$logDir = ($env:LOG_DIR).Trim()
$daysBackRaw = ($env:DAYS_BACK).Trim()
$localOnly = ($env:LOCAL_MACHINE_ONLY).Trim() -ne '0'
$searchFilter = if ($null -ne $env:SEARCH_FILTER) { ($env:SEARCH_FILTER).Trim() } else { '' }
$backupRawDb = ($env:BACKUP_RAW_DB).Trim() -eq '1'

$daysBack = 0
if (-not [int]::TryParse($daysBackRaw, [ref]$daysBack) -or $daysBack -lt 0) {
    Write-Host "[ERROR] Invalid DAYS_BACK value ($daysBackRaw). Must be an integer >= 0." -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($chromeUserData) -or -not (Test-Path -LiteralPath $chromeUserData -PathType Container)) {
    Write-Host "[ERROR] Chrome User Data folder not found: $chromeUserData" -ForegroundColor Red
    exit 1
}

$winSqlitePath = Join-Path $env:SystemRoot 'System32\winsqlite3.dll'
if (-not (Test-Path -LiteralPath $winSqlitePath -PathType Leaf)) {
    Write-Host "[ERROR] System file winsqlite3.dll not found (Windows 10/11 or later required)." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logDir = (Resolve-Path -LiteralPath $logDir).Path

$profiles = Resolve-ChromeProfiles -UserDataPath $chromeUserData
if ($profiles.Count -eq 0) {
    Write-Host "[WARN] No Chrome History file found in: $chromeUserData" -ForegroundColor Yellow
    exit 1
}

Add-Type -TypeDefinition $winSqliteCSharp

$minVisitTimeMicros = 0L
if ($daysBack -gt 0) {
    $cutoffUtc = [DateTime]::UtcNow.AddDays(-$daysBack)
    $minVisitTimeMicros = [long]($cutoffUtc.ToFileTimeUtc() / 10L)
}

$timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$safeComputer = ($env:COMPUTERNAME -replace '[\\/:*?"<>|]', '_')
$safeUser = ($env:USERNAME -replace '[\\/:*?"<>|]', '_')
$detailCsvPath = Join-Path $logDir "ChromeHistory_${safeComputer}_${safeUser}_${timestamp}.csv"
$summaryCsvPath = Join-Path $logDir "ChromeSummary_${safeComputer}_${safeUser}_${timestamp}.csv"
$searchesCsvPath = Join-Path $logDir "ChromeSearches_${safeComputer}_${safeUser}_${timestamp}.csv"

$tempWorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ChromeHist_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempWorkDir -Force | Out-Null

$rawBackupRoot = $null
if ($backupRawDb) {
    $rawBackupRoot = Join-Path $logDir "raw_backup_${safeComputer}_${safeUser}_${timestamp}"
    New-Item -ItemType Directory -Path $rawBackupRoot -Force | Out-Null
}

$allEntries = New-Object 'System.Collections.Generic.List[ChromeHistoryEntry]'
$profileIndex = 0
$processedCount = 0

try {
    foreach ($prof in $profiles) {
        $profileIndex++
        $profTempDir = Join-Path $tempWorkDir ("p_" + $profileIndex)
        New-Item -ItemType Directory -Path $profTempDir -Force | Out-Null

        try {
            foreach ($suffix in @('', '-wal', '-shm', '-journal')) {
                $src = $prof.HistoryPath + $suffix
                if (Test-Path -LiteralPath $src -PathType Leaf) {
                    $dst = Join-Path $profTempDir ("History" + $suffix)
                    Copy-FileAllowLocked -SourcePath $src -DestPath $dst
                }
            }

            if ($backupRawDb -and $rawBackupRoot) {
                $safeProfDirName = ($prof.FolderName -replace '[\\/:*?"<>|]', '_')
                $profBackupDir = Join-Path $rawBackupRoot $safeProfDirName
                New-Item -ItemType Directory -Path $profBackupDir -Force | Out-Null
                foreach ($suffix in @('', '-wal', '-shm', '-journal')) {
                    $copiedFile = Join-Path $profTempDir ("History" + $suffix)
                    if (Test-Path -LiteralPath $copiedFile -PathType Leaf) {
                        Copy-Item -LiteralPath $copiedFile -Destination (Join-Path $profBackupDir ("History" + $suffix)) -Force
                    }
                }
            }

            $tempDbPath = Join-Path $profTempDir 'History'
            $rowCount = [WinSqliteHistory]::ReadHistory($tempDbPath, $prof.DisplayName, $minVisitTimeMicros, $localOnly, $searchFilter, $allEntries)
            $processedCount++
            Write-Host "[OK] Profile '$($prof.DisplayName)': found $rowCount record(s)" -ForegroundColor Green
        }
        catch {
            Write-Host "[WARN] Skipped profile '$($prof.DisplayName)': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($processedCount -eq 0) {
        Write-Host "[ERROR] Failed to read history from any profile." -ForegroundColor Red
        exit 1
    }

    [WinSqliteHistory]::WriteDetailCsv($detailCsvPath, $env:COMPUTERNAME, $env:USERNAME, $allEntries)
    $catCounts = [WinSqliteHistory]::WriteSummaryCsv($summaryCsvPath, $env:COMPUTERNAME, $env:USERNAME, $allEntries)
    $searchCount = [WinSqliteHistory]::WriteSearchesCsv($searchesCsvPath, $env:COMPUTERNAME, $env:USERNAME, $allEntries)

    Write-Host "[DONE] Saved $($allEntries.Count) record(s) and $searchCount search query(s) for machine $($env:COMPUTERNAME)." -ForegroundColor Cyan
    Write-Host "[FILE] Detail   : $detailCsvPath" -ForegroundColor Cyan
    Write-Host "[FILE] Summary  : $summaryCsvPath" -ForegroundColor Cyan
    Write-Host "[FILE] Searches : $searchesCsvPath" -ForegroundColor Cyan
    if ($backupRawDb -and $rawBackupRoot) {
        Write-Host "[RAW]  Backup   : $rawBackupRoot" -ForegroundColor Cyan
    }

    if ($catCounts.Count -gt 0) {
        Write-Host "[SUMMARY] Activity breakdown:" -ForegroundColor White
        $catCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            $label = $_.Key.PadRight(28)
            Write-Host ("  - {0} : {1} visit(s)" -f $label, $_.Value) -ForegroundColor Gray
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempWorkDir) {
        Remove-Item -LiteralPath $tempWorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
