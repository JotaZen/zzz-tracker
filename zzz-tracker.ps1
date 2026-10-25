# ZZZ Tracker: abre una página local con tu historial de señales de Zenless Zone Zero.
# Uso: iwr -useb https://raw.githubusercontent.com/JotaZen/zzz-tracker/main/zzz-tracker.ps1 | iex

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Web

$Repo = 'https://raw.githubusercontent.com/JotaZen/zzz-tracker/main'
$Home_ = Join-Path $env:LOCALAPPDATA 'zzz-tracker'
$Banners = '1', '2', '3', '5'   # estándar, exclusiva, motor-W, bangboo
$Port = 47811
New-Item -ItemType Directory -Force $Home_ | Out-Null

function Find-GameDir {
    $dir = Join-Path $env:USERPROFILE 'AppData\LocalLow\miHoYo\ZenlessZoneZero'
    foreach ($log in 'Player.log', 'Player-prev.log') {
        $path = Join-Path $dir $log
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $m = [regex]::Match((Read-Shared $path ([Text.Encoding]::UTF8)), 'Discovering subsystems at path (.+?)/UnitySubsystems')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    throw 'nogame'
}

function Read-Shared($path, $encoding = [Text.Encoding]::GetEncoding(28591)) {
    # El juego mantiene sus archivos abiertos; hay que leerlos compartidos.
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        $ms = New-Object IO.MemoryStream
        $fs.CopyTo($ms)
        return $encoding.GetString($ms.ToArray())
    } finally { $fs.Dispose() }
}

function Get-CacheUrls {
    $caches = Join-Path (Find-GameDir) 'webCaches'
    $newest = Get-ChildItem -LiteralPath $caches -Directory |
        Where-Object { $_.Name -match '^[\d.]+$' } |
        Sort-Object { [version]$_.Name } |
        Select-Object -Last 1
    if (-not $newest) { throw 'nogame' }
    $blob = Read-Shared (Join-Path $newest.FullName 'Cache\Cache_Data\data_2')
    [regex]::Matches($blob, 'https://[\x21-\x7e]+?getGachaLog\?[\x21-\x7e]+') |
        ForEach-Object { $_.Value } | Select-Object -Unique |
        Sort-Object { if ($_ -match 'timestamp=(\d+)') { [int64]$Matches[1] } else { 0 } } -Descending
}

function Set-Params($url, $params) {
    $uri = [Uri]$url
    $q = [Web.HttpUtility]::ParseQueryString($uri.Query)
    $q.Remove('page')
    foreach ($k in $params.Keys) { $q[$k] = $params[$k] }
    return $uri.GetLeftPart('Path') + '?' + $q.ToString()
}

function Invoke-Api($url) {
    $res = Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{ 'User-Agent' = 'zzz-tracker' }
    $text = [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray())
    return $text | ConvertFrom-Json
}

function Get-ValidUrl {
    foreach ($url in @(Get-CacheUrls)) {
        if ((Invoke-Api (Set-Params $url @{ size = '1'; end_id = '0' })).retcode -eq 0) { return $url }
    }
    throw 'expired'
}

function Get-Uid($url) {
    foreach ($b in $Banners) {
        $res = Invoke-Api (Set-Params $url @{ real_gacha_type = $b; gacha_type = "${b}001"; init_log_gacha_base_type = $b; size = '1'; end_id = '0' })
        if (@($res.data.list).Count) { return [string]$res.data.list[0].uid }
    }
    throw 'empty'
}

function Get-Accounts {
    @([Sqlite]::Query($Db, 'SELECT uid FROM accounts ORDER BY updated DESC', @()) | ForEach-Object { [string]$_[0] })
}

function ConvertTo-Unix($text) {
    # Hora del servidor del juego, guardada como si fuera UTC.
    $d = [DateTime]::ParseExact($text, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    return [DateTimeOffset]::new($d, [TimeSpan]::Zero).ToUnixTimeSeconds()
}

function Get-HistoryJson($uid) {
    # Cada tirada: [id, item_id, rango (4=S, 3=A, 2=B), unix]. El id va como texto: no cabe en un número de JS.
    $banners = foreach ($b in $Banners) {
        $rows = foreach ($r in [Sqlite]::Query($Db, 'SELECT id, item_id, rank, ts FROM pulls WHERE uid = ? AND banner = ? ORDER BY id', @($uid, $b))) {
            '["{0}",{1},{2},{3}]' -f $r
        }
        '"{0}":[{1}]' -f $b, ($rows -join ',')
    }
    $names = @{}
    foreach ($r in [Sqlite]::Query($Db, 'SELECT item_id, name FROM items WHERE item_id IN (SELECT item_id FROM pulls WHERE uid = ?)', @($uid))) {
        $names["$($r[0])"] = $r[1]
    }
    $names = if ($names.Count) { $names | ConvertTo-Json -Compress } else { '{}' }
    return '{{"v":1,"uid":"{0}","names":{1},"pulls":{{{2}}}}}' -f $uid, $names, ($banners -join ',')
}

function Update-History {
    $url = Get-ValidUrl
    $uid = Get-Uid $url
    $added = 0
    [void][Sqlite]::Query($Db, 'BEGIN', @())
    try {
        foreach ($b in $Banners) {
            $end = '0'
            # Se pide cada banner hasta llegar a una tirada ya guardada.
            while ($true) {
                $res = Invoke-Api (Set-Params $url @{ real_gacha_type = $b; gacha_type = "${b}001"; init_log_gacha_base_type = $b; size = '20'; end_id = $end })
                if ($res.retcode -ne 0) { throw 'api' }
                $page = @($res.data.list)
                $fresh = 0
                foreach ($r in $page) {
                    [void][Sqlite]::Query($Db, 'INSERT INTO items (item_id, name) VALUES (?, ?) ON CONFLICT (item_id) DO UPDATE SET name = excluded.name', @([int64]$r.item_id, $r.name))
                    [void][Sqlite]::Query($Db, 'INSERT OR IGNORE INTO pulls (id, uid, banner, item_id, rank, ts) VALUES (?, ?, ?, ?, ?, ?)',
                        @([int64]$r.id, $uid, $b, [int64]$r.item_id, [int64]$r.rank_type, (ConvertTo-Unix $r.time)))
                    $fresh += [Sqlite]::Changes($Db)
                }
                $added += $fresh
                if ($page.Count -eq 0 -or $fresh -lt $page.Count) { break }
                $end = $page[-1].id
                Start-Sleep -Milliseconds 250
            }
        }
        [void][Sqlite]::Query($Db, 'INSERT INTO accounts (uid, updated) VALUES (?, ?) ON CONFLICT (uid) DO UPDATE SET updated = excluded.updated',
            @($uid, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
        [void][Sqlite]::Query($Db, 'COMMIT', @())
    } catch {
        [void][Sqlite]::Query($Db, 'ROLLBACK', @())
        throw
    }
    return '{"added":' + $added + ',"uid":"' + $uid + '"}'
}

function Get-Template {
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'template.html' }
    if ($local -and (Test-Path -LiteralPath $local)) { return [IO.File]::ReadAllText($local, [Text.Encoding]::UTF8) }
    $cache = Join-Path $Home_ 'template.html'
    try {
        $res = Invoke-WebRequest -UseBasicParsing "$Repo/template.html"
        [IO.File]::WriteAllBytes($cache, $res.RawContentStream.ToArray())
    } catch { if (-not (Test-Path -LiteralPath $cache)) { throw } }
    return [IO.File]::ReadAllText($cache, [Text.Encoding]::UTF8)
}

function Send($ctx, $code, $body, $type) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $type
    $ctx.Response.Headers['Cache-Control'] = 'no-store'
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

# SQLite que trae Windows 10 y 11 (winsqlite3.dll): nada que instalar.
if (-not ('Sqlite' -as [type])) { Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Sqlite {
    const string L = "winsqlite3.dll";
    [DllImport(L, CharSet = CharSet.Unicode)] static extern int sqlite3_open16(string file, out IntPtr db);
    [DllImport(L, CharSet = CharSet.Unicode)] static extern int sqlite3_prepare16_v2(IntPtr db, string sql, int n, out IntPtr st, IntPtr tail);
    [DllImport(L, CharSet = CharSet.Unicode)] static extern int sqlite3_bind_text16(IntPtr st, int i, string v, int n, IntPtr destructor);
    [DllImport(L)] static extern int sqlite3_bind_int64(IntPtr st, int i, long v);
    [DllImport(L)] static extern int sqlite3_step(IntPtr st);
    [DllImport(L)] static extern int sqlite3_finalize(IntPtr st);
    [DllImport(L)] static extern int sqlite3_column_count(IntPtr st);
    [DllImport(L)] static extern int sqlite3_column_type(IntPtr st, int i);
    [DllImport(L)] static extern long sqlite3_column_int64(IntPtr st, int i);
    [DllImport(L)] static extern IntPtr sqlite3_column_text16(IntPtr st, int i);
    [DllImport(L)] static extern IntPtr sqlite3_errmsg16(IntPtr db);
    [DllImport(L)] static extern int sqlite3_changes(IntPtr db);
    public static IntPtr Open(string file) {
        IntPtr db;
        if (sqlite3_open16(file, out db) != 0) throw new Exception("No se pudo abrir " + file);
        return db;
    }
    public static int Changes(IntPtr db) { return sqlite3_changes(db); }
    public static List<object[]> Query(IntPtr db, string sql, object[] args) {
        IntPtr st;
        if (sqlite3_prepare16_v2(db, sql, -1, out st, IntPtr.Zero) != 0) throw new Exception(Marshal.PtrToStringUni(sqlite3_errmsg16(db)));
        try {
            for (int i = 0; i < args.Length; i++) {
                if (!(args[i] is IConvertible) || args[i] is string) sqlite3_bind_text16(st, i + 1, args[i].ToString(), -1, new IntPtr(-1));
                else sqlite3_bind_int64(st, i + 1, Convert.ToInt64(args[i]));
            }
            var rows = new List<object[]>();
            int rc;
            while ((rc = sqlite3_step(st)) == 100) {
                var row = new object[sqlite3_column_count(st)];
                for (int c = 0; c < row.Length; c++) {
                    int t = sqlite3_column_type(st, c);
                    row[c] = t == 1 ? (object)sqlite3_column_int64(st, c) : t == 5 ? null : Marshal.PtrToStringUni(sqlite3_column_text16(st, c));
                }
                rows.Add(row);
            }
            if (rc != 101) throw new Exception(Marshal.PtrToStringUni(sqlite3_errmsg16(db)));
            return rows;
        } finally { sqlite3_finalize(st); }
    }
}
'@ }

$Db = [Sqlite]::Open((Join-Path $Home_ 'zzz.db'))
foreach ($sql in @(
    'CREATE TABLE IF NOT EXISTS accounts (uid TEXT PRIMARY KEY, updated INTEGER NOT NULL)',
    'CREATE TABLE IF NOT EXISTS items (item_id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS pulls (id INTEGER PRIMARY KEY, uid TEXT NOT NULL, banner TEXT NOT NULL, item_id INTEGER NOT NULL, rank INTEGER NOT NULL, ts INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS pulls_uid_banner ON pulls (uid, banner, id)'
)) { [void][Sqlite]::Query($Db, $sql, @()) }

# Versiones anteriores guardaban un JSON por cuenta; se pasan a la base una sola vez.
foreach ($file in @(Get-ChildItem -LiteralPath $Home_ -Filter '*.json')) {
    $data = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ("$($data.uid)" -notmatch '^\d+$') { continue }
    [void][Sqlite]::Query($Db, 'BEGIN', @())
    foreach ($p in $data.names.PSObject.Properties) {
        [void][Sqlite]::Query($Db, 'INSERT OR IGNORE INTO items (item_id, name) VALUES (?, ?)', @([int64]$p.Name, $p.Value))
    }
    foreach ($b in $Banners) {
        foreach ($r in @($data.pulls.$b)) {
            if ($r) { [void][Sqlite]::Query($Db, 'INSERT OR IGNORE INTO pulls (id, uid, banner, item_id, rank, ts) VALUES (?, ?, ?, ?, ?, ?)', @([int64]$r[0], "$($data.uid)", $b, [int64]$r[1], [int64]$r[2], [int64]$r[3])) }
        }
    }
    [void][Sqlite]::Query($Db, 'INSERT OR IGNORE INTO accounts (uid, updated) VALUES (?, ?)', @("$($data.uid)", [DateTimeOffset]::new($file.LastWriteTimeUtc).ToUnixTimeSeconds()))
    [void][Sqlite]::Query($Db, 'COMMIT', @())
    Rename-Item -LiteralPath $file.FullName ($file.Name + '.importado')
}

$template = Get-Template
$bytes = New-Object byte[] 24
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$token = [Convert]::ToBase64String($bytes) -replace '[+/=]', ''
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$address = "http://localhost:$Port/"
try { $listener.Start() } catch {
    # Ya hay otro tracker abierto: basta con mostrarlo.
    Start-Process $address
    return
}
Write-Host "ZZZ Tracker abierto en $address"
Write-Host 'Cierra esta ventana para salir.'
Start-Process $address

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        try {
            if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/') {
                $accounts = Get-Accounts
                $uid = $req.QueryString['uid']
                if ($uid -notin $accounts) { $uid = $accounts | Select-Object -First 1 }
                $data = (Get-HistoryJson $uid).Replace('</', '<\/')
                $list = '[' + (($accounts | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
                $page = $template.Replace('__HISTORY__', $data).Replace('__ACCOUNTS__', $list).Replace('__TOKEN__', $token)
                Send $ctx 200 $page 'text/html; charset=utf-8'
            } elseif ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/update' -and $req.Headers['X-Token'] -ceq $token) {
                # Solo la página servida conoce el token; otra web no puede disparar la descarga.
                $result = try { Update-History } catch {
                    $code = "$($_.Exception.Message)"
                    if ($code -notin 'nogame', 'expired', 'empty') { $code = 'api' }
                    '{"error":"' + $code + '"}'
                }
                Send $ctx 200 $result 'application/json'
            } else {
                Send $ctx 404 '' 'text/plain'
            }
        } catch {
            Write-Warning $_
            try { $ctx.Response.Abort() } catch {}
        }
    }
} finally { $listener.Stop() }
