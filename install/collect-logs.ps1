# Author: Tim Harrison
# Created: 2026-11-01
# Updated: 2026-11-09

# Collect the client's support files into one archive for a bug report.
# Read-only against the bridge, game and save folders: the only writes are a
# temp dir and the archive. Save files are never included.
# Path discovery follows docs/client_paths.md.

param(
    [string]$Out = "",
    [string]$BridgeDir = "",
    [Alias("?")][switch]$Help
)

$ErrorActionPreference = "Stop"
$Last = 4000

function Show-Usage {
    Write-Host "Usage: collect-logs.ps1 [-Out PATH] [-BridgeDir DIR]"
    Write-Host ""
    Write-Host "  -Out PATH        archive path (default srtap-logs-<timestamp>.zip here)"
    Write-Host "  -BridgeDir DIR   use this srtap_bridge folder instead of discovery"
}

function Add-SteamRoot([string]$Path) {
    if (-not $Path) { return }
    if (-not [IO.Path]::IsPathRooted($Path)) { return }
    try { $Full = [IO.Path]::GetFullPath($Path) } catch { return }
    if ($Full.Length -gt 3) { $Full = $Full.TrimEnd('\') }
    if (-not (Test-Path -LiteralPath $Full -PathType Container)) { return }
    foreach ($Known in $script:SteamRoots) {
        if ([string]::Equals($Known, $Full, [StringComparison]::OrdinalIgnoreCase)) { return }
    }
    [void]$script:SteamRoots.Add($Full)
}

function Add-RegistryRoot([string]$Key, [string]$Name) {
    try {
        $Item = Get-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop
        Add-SteamRoot ([string]$Item.$Name)
    } catch { }
}

function Test-BridgeMarker([string]$Path) {
    if (-not $Path) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Path "config.txt") -PathType Leaf) { return $true }
    if (Test-Path -LiteralPath (Join-Path $Path "srtap_checkd.exe") -PathType Leaf) { return $true }
    return $false
}

function Read-ConfigValue([string]$Path, [string]$Key) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    $Match = [regex]::Match([IO.File]::ReadAllText($Path), "(?m)^[ \t]*$Key[ \t]*=[ \t]*([^\r\n]*)")
    if (-not $Match.Success) { return "" }
    return $Match.Groups[1].Value.Trim()
}

function Redact([string]$Text, [string[]]$Values) {
    foreach ($Value in $Values) {
        if (-not $Value -or $Value.Length -lt 3) { continue }
        $Text = [regex]::Replace($Text, [regex]::Escape($Value), '<redacted>')
    }
    $Text = [regex]::Replace($Text, '(wss?://)[^ \t]+', '$1<redacted>')
    $Text = [regex]::Replace($Text, 'To [^:]*:', 'To <redacted>:')
    return $Text
}

function Read-LogTail([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $Lines = [IO.File]::ReadAllLines($Path)
    $Total = $Lines.Count
    if ($Total -gt $Last) {
        $Lines = $Lines[($Total - $Last)..($Total - 1)]
    }
    return @{ Total = $Total; Text = ($Lines -join "`r`n") }
}

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text)
}

if ($Help) { Show-Usage; exit 0 }

$Ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
$Created = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$OutGiven = [bool]$Out
if (-not $Out) { $Out = Join-Path $PSScriptRoot ("srtap-logs-$Ts.zip") }
# Compress-Archive on PowerShell 5.1 requires the .zip extension.
if ($Out -notlike "*.zip") { $Out = "$Out.zip" }

$script:SteamRoots = New-Object System.Collections.ArrayList
Add-SteamRoot $env:STEAM_ROOT
Add-RegistryRoot "HKCU:\Software\Valve\Steam" "SteamPath"
Add-RegistryRoot "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" "InstallPath"
Add-RegistryRoot "HKLM:\SOFTWARE\Valve\Steam" "InstallPath"
$Pf86 = ${env:ProgramFiles(x86)}
if ($Pf86) { Add-SteamRoot (Join-Path $Pf86 "Steam") }
if ($env:ProgramFiles) { Add-SteamRoot (Join-Path $env:ProgramFiles "Steam") }

# Every root's libraryfolders.vdf adds libraries, which may carry their own vdf.
# Keys are "path" (modern) or "<n>" (legacy); vdf escapes a backslash as two.
$Seen = 0
while ($Seen -lt $script:SteamRoots.Count) {
    $Root = $script:SteamRoots[$Seen]
    $Seen++
    $Vdf = Join-Path $Root "steamapps\libraryfolders.vdf"
    if (-not (Test-Path -LiteralPath $Vdf -PathType Leaf)) { continue }
    $VdfText = [IO.File]::ReadAllText($Vdf)
    foreach ($M in [regex]::Matches($VdfText, '"(?:path|\d+)"\s+"([^"]+)"')) {
        Add-SteamRoot ($M.Groups[1].Value -replace '\\\\', '\')
    }
}

$NewBridge = ""
if ($env:LOCALAPPDATA) { $NewBridge = Join-Path $env:LOCALAPPDATA "srtap_bridge" }
$LegacyBridge = "C:\srtap_bridge"

$Bridges = New-Object System.Collections.ArrayList
if ($BridgeDir) {
    if (-not (Test-Path -LiteralPath $BridgeDir -PathType Container)) {
        [Console]::Error.WriteLine("bridge folder not found: $BridgeDir")
        exit 1
    }
    [void]$Bridges.Add((Resolve-Path -LiteralPath $BridgeDir).Path)
} else {
    $Candidates = New-Object System.Collections.ArrayList
    if ($NewBridge -and (Test-Path -LiteralPath $NewBridge -PathType Container)) { [void]$Candidates.Add($NewBridge) }
    if (Test-Path -LiteralPath $LegacyBridge -PathType Container) { [void]$Candidates.Add($LegacyBridge) }
    $Selected = ""
    foreach ($Candidate in $Candidates) {
        if (Test-BridgeMarker $Candidate) { $Selected = $Candidate; break }
    }
    if (-not $Selected -and $Candidates.Count -gt 0) { $Selected = $Candidates[0] }
    if ($Selected) { [void]$Bridges.Add($Selected) }
    foreach ($Candidate in $Candidates) {
        if ($Candidate -ne $Selected) { [void]$Bridges.Add($Candidate) }
    }
}
if ($Bridges.Count -eq 0) {
    [Console]::Error.WriteLine("Nothing found " + [char]0x2014 + " run with -BridgeDir <path to srtap_bridge>")
    exit 1
}

$Bridge = $Bridges[0]
$Other = ""
if ($Bridges.Count -gt 1) {
    $Other = ($Bridges[1..($Bridges.Count - 1)] -join "; ")
}

# A library holding appmanifest_996580.acf is the copy Steam considers
# installed; fall back to the first folder that merely exists.
$Game = ""
$GameAny = ""
foreach ($Root in $script:SteamRoots) {
    $Candidate = Join-Path $Root "steamapps\common\Spyro Reignited Trilogy\Falcon\Binaries\Win64"
    if (-not (Test-Path -LiteralPath $Candidate -PathType Container)) { continue }
    if (-not $GameAny) { $GameAny = $Candidate }
    if (Test-Path -LiteralPath (Join-Path $Root "steamapps\appmanifest_996580.acf") -PathType Leaf) {
        $Game = $Candidate
        break
    }
}
if (-not $Game) { $Game = $GameAny }
if (-not $Game) { $Game = "not found" }

$SaveDir = "not found"
if ($env:LOCALAPPDATA) {
    $Candidate = Join-Path $env:LOCALAPPDATA "Falcon\Saved\SaveGames"
    if (Test-Path -LiteralPath $Candidate -PathType Container) { $SaveDir = $Candidate }
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("srtap-logs-" + [Guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $Tmp)
try {
    $Stage = Join-Path $Tmp "srtap-logs-$Ts"
    [void](New-Item -ItemType Directory -Path $Stage)

    # The three connection values, read once and replaced verbatim wherever they
    # appear in a copied text file.
    $Config = Join-Path $Bridge "config.txt"
    $CfgPassword = Read-ConfigValue $Config "password"
    $CfgHost = Read-ConfigValue $Config "host"
    $CfgSlot = Read-ConfigValue $Config "slot"
    $CfgValues = @($CfgPassword, $CfgHost, $CfgSlot)

    $Version = "not found"
    $Lua = Join-Path $Game "Mods\srt_bridge\Scripts\ap_client.lua"
    if ((Test-Path -LiteralPath $Lua -PathType Leaf)) {
        $Match = [regex]::Match([IO.File]::ReadAllText($Lua), '(client_version\s*=\s*\{[^}]*\})')
        if ($Match.Success) { $Version = $Match.Groups[1].Value }
    }

    $BridgeLine = "not found"
    $Log = Read-LogTail (Join-Path $Bridge "bridge.log")
    if ($Log -ne $null) {
        Write-Text (Join-Path $Stage "bridge.log") (Redact $Log.Text $CfgValues)
        $BridgeLine = "$($Log.Total) lines"
    }
    $CheckdLine = "not found"
    $Log = Read-LogTail (Join-Path $Bridge "checkd.log")
    if ($Log -ne $null) {
        Write-Text (Join-Path $Stage "checkd.log") (Redact $Log.Text $CfgValues)
        $CheckdLine = "$($Log.Total) lines"
    }
    $Log = Read-LogTail (Join-Path $Game "UE4SS.log")
    if ($Log -ne $null) { Write-Text (Join-Path $Stage "UE4SS.log") (Redact $Log.Text $CfgValues) }

    if (Test-Path -LiteralPath $Config -PathType Leaf) {
        Write-Text (Join-Path $Stage "config.txt") (Redact ([IO.File]::ReadAllText($Config)) $CfgValues)
    }
    foreach ($Name in @("checkd.status.json", "checks.json", "checkd.hb")) {
        $Src = Join-Path $Bridge $Name
        if (Test-Path -LiteralPath $Src -PathType Leaf) { Copy-Item -LiteralPath $Src -Destination (Join-Path $Stage $Name) -Force }
    }
    $Session = Join-Path $Bridge "session.txt"
    if (Test-Path -LiteralPath $Session -PathType Leaf) {
        Write-Text (Join-Path $Stage "session.txt") (Redact ([IO.File]::ReadAllText($Session)) $CfgValues)
    }

    $Mods = Join-Path $Game "Mods\srt_bridge"
    if (Test-Path -LiteralPath $Mods -PathType Container) {
        $Listing = New-Object System.Collections.ArrayList
        foreach ($File in (Get-ChildItem -LiteralPath $Mods -Recurse -File | Sort-Object FullName)) {
            $Rel = $File.FullName.Substring($Mods.Length + 1).Replace("\", "/")
            [void]$Listing.Add("$($File.Length)`t$Rel")
        }
        Write-Text (Join-Path $Stage "srt_bridge-files.txt") (($Listing -join "`r`n") + "`r`n")
    }

    $RootsLine = if ($script:SteamRoots.Count -gt 0) { $script:SteamRoots -join "; " } else { "not found" }

    $Meta = New-Object System.Collections.ArrayList
    [void]$Meta.Add("Reignited AP support bundle")
    [void]$Meta.Add("created: $Created")
    [void]$Meta.Add("os: $([Environment]::OSVersion.VersionString)")
    [void]$Meta.Add("mod client_version: $Version")
    [void]$Meta.Add("steam roots: $RootsLine")
    [void]$Meta.Add("libraries: $RootsLine")
    [void]$Meta.Add("bridge dir: $Bridge")
    [void]$Meta.Add("game dir: $Game")
    [void]$Meta.Add("save dir: $SaveDir")
    if ($Other) { [void]$Meta.Add("other bridge folders: $Other") }
    [void]$Meta.Add("bridge.log: $BridgeLine")
    [void]$Meta.Add("checkd.log: $CheckdLine")
    [void]$Meta.Add('redacted: password, host, slot, ws:// and wss:// addresses, "Connected to ... as ...", "To <player>:"')
    [void]$Meta.Add("save files: not included")

    Write-Text (Join-Path $Stage "meta.txt") (($Meta -join "`r`n") + "`r`n")

    try {
        Compress-Archive -Path (Join-Path $Tmp "*") -DestinationPath $Out -Force
    } catch {
        if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
        [Console]::Error.WriteLine("archive write failed: $($_.Exception.Message)")
        exit 1
    }
} finally {
    Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$Final = (Resolve-Path -LiteralPath $Out).Path

Write-Output $Final
Write-Output "Attach this file to your report. Connection details were redacted; save files are not included."
try { if (-not $OutGiven) { Start-Process explorer.exe -ArgumentList "/select,`"$Final`"" } } catch { }
