<#
.SYNOPSIS
    Sets up the spray download junction for Dino D-Day.

.DESCRIPTION
    The game's custom-file system writes downloaded sprays to
    <root>\dinodday\downloads but only converts them into renderable
    materials from <root>\update\downloads. Junctioning the second path to
    the first makes server-delivered sprays work.

    Locates the install via the Steam registry keys and library manifests,
    creates the target folder, migrates anything already sitting in the old
    update\downloads, and replaces it with a junction.

.PARAMETER GamePath
    Install root, skipping auto-detection. Should be the folder containing
    the 'dinodday' subfolder.

.PARAMETER Revert
    Remove the junction and restore a plain empty directory.

.PARAMETER ClearCache
    Also wipe the spray caches. Useful when testing changes to the pipeline,
    since materials\temp persists forever and will happily serve you results
    from three iterations ago.

.NOTES
    Junctions do not require administrator rights. Close the game first --
    the engine caches its search paths at startup and will not notice a
    junction created while it is running.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('p', 'Path')]
    [string]$GamePath,

    [Alias('a', 'App')]
    [int]$AppId = 70000,

    [Alias('r')]
    [switch]$Revert,

    [Alias('c', 'Clear')]
    [switch]$ClearCache,

    [Alias('h', '?')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Show-Usage {
    $name = Split-Path -Leaf $PSCommandPath
    Write-Host @"

$name -- spray download junction setup for Dino D-Day

USAGE
    .\$name [-p <path>] [-r] [-c] [-a <appid>] [-h]

PARAMETERS
    -p, -Path, -GamePath <path>
        Install root -- the folder containing the 'dinodday' subfolder.
        Omit to auto-detect from the Steam registry keys and library
        manifests. Also accepted positionally: .\$name "D:\Games\Dino D-Day"

    -r, -Revert
        Remove the junction and restore a plain empty directory.

    -c, -Clear, -ClearCache
        Wipe both materials\temp folders and any downloaded .dat files.
        Use before re-testing: those caches persist forever and will
        otherwise serve you stale results.

    -a, -App, -AppId <number>
        Steam app id for detection. Default 70000.

    -h, -Help
        This text.

EXAMPLES
    .\$name
        Auto-detect and set up the junction.

    .\$name -p "D:\Games\Dino D-Day" -c
        Use an explicit path and clear the caches too.

    .\$name -r
        Undo.

NOTES
    Junctions do not need administrator rights.
    Close the game first -- search paths are cached at startup.

"@
}

if ($Help) { Show-Usage; return }

function Write-Step($msg)  { Write-Host "  $msg" }
function Write-Good($msg)  { Write-Host "  $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "  $msg" -ForegroundColor Yellow }


function Get-SteamRoot {
    foreach ($key in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($prop in @('SteamPath', 'InstallPath')) {
                if ($p.$prop -and (Test-Path $p.$prop)) {
                    return (Resolve-Path $p.$prop).Path
                }
            }
        } catch { }
    }
    return $null
}


function Get-SteamLibraries($steamRoot) {
    $libs = @()
    if ($steamRoot) { $libs += (Join-Path $steamRoot 'steamapps') }

    $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        # Both the old flat format and the newer nested one quote the path
        # on a "path" line, so one pattern covers each.
        foreach ($line in Get-Content $vdf) {
            if ($line -match '"(?:path|\d+)"\s+"(.+?)"') {
                $candidate = $matches[1] -replace '\\\\', '\'
                $sa = Join-Path $candidate 'steamapps'
                if (Test-Path $sa) { $libs += $sa }
            }
        }
    }
    return $libs | Select-Object -Unique
}


function Get-GamePathFromSteam($appId) {
    # Fast path: the per-app uninstall entry, when Steam wrote one.
    foreach ($base in @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        $key = Join-Path $base "Steam App $appId"
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($p.InstallLocation -and (Test-Path $p.InstallLocation)) {
                Write-Step "found via uninstall registry key"
                return (Resolve-Path $p.InstallLocation).Path
            }
        } catch { }
    }

    # General path: walk every library and read the app manifest.
    $steamRoot = Get-SteamRoot
    if (-not $steamRoot) { return $null }
    Write-Step "steam root: $steamRoot"

    foreach ($lib in (Get-SteamLibraries $steamRoot)) {
        $acf = Join-Path $lib "appmanifest_$appId.acf"
        if (-not (Test-Path $acf)) { continue }

        $installdir = $null
        foreach ($line in Get-Content $acf) {
            if ($line -match '"installdir"\s+"(.+?)"') { $installdir = $matches[1]; break }
        }
        if (-not $installdir) { continue }

        $full = Join-Path $lib "common\$installdir"
        if (Test-Path $full) {
            Write-Step "found via app manifest in $lib"
            return (Resolve-Path $full).Path
        }
    }
    return $null
}


function Test-GameRoot($path) {
    return (Test-Path (Join-Path $path 'dinodday\gameinfo.txt'))
}


# ---------------------------------------------------------------- main

Write-Host "`nDino D-Day spray junction setup`n"

if ($GamePath) {
    if (-not (Test-GameRoot $GamePath)) {
        throw "no dinodday\gameinfo.txt under '$GamePath' -- is that the install root?"
    }
    $root = (Resolve-Path $GamePath).Path
} else {
    Write-Step "locating install..."
    $root = Get-GamePathFromSteam $AppId
    if (-not $root) {
        throw "could not locate the game. Re-run with -p '<install root>' (see -h)."
    }
    if (-not (Test-GameRoot $root)) {
        throw "found '$root' but it has no dinodday\gameinfo.txt. Re-run with -p (see -h)."
    }
}
Write-Good "install root: $root"

$proc = Get-Process -Name 'dinodday', 'hl2', 'srcds' -ErrorAction SilentlyContinue
if ($proc) {
    throw "close the game first ($($proc.Name -join ', ') running) -- search paths are cached at startup."
}

$target = Join-Path $root 'dinodday\downloads'
$link   = Join-Path $root 'update\downloads'
$temps  = @((Join-Path $root 'update\materials\temp'),
            (Join-Path $root 'dinodday\materials\temp'))

if ($Revert) {
    $item = Get-Item $link -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'Junction') {
        [System.IO.Directory]::Delete($link, $false)
        New-Item -ItemType Directory -Path $link -Force | Out-Null
        Write-Good "junction removed, plain directory restored"
    } else {
        Write-Warn2 "no junction at $link -- nothing to revert"
    }
    return
}

if (-not (Test-Path $target)) {
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Write-Good "created $target"
} else {
    Write-Step "target exists: $target"
}

$existing = Get-Item $link -Force -ErrorAction SilentlyContinue

if ($existing -and $existing.LinkType -eq 'Junction') {
    if ($existing.Target -contains $target) {
        Write-Good "junction already correct -- nothing to do"
    } else {
        Write-Warn2 "junction points elsewhere ($($existing.Target)); replacing"
        [System.IO.Directory]::Delete($link, $false)
        $existing = $null
    }
} elseif ($existing) {
    # A real directory. Move anything in it rather than destroying files.
    $files = Get-ChildItem $link -File -ErrorAction SilentlyContinue
    if ($files) {
        Write-Warn2 "migrating $($files.Count) file(s) into the target folder"
        foreach ($f in $files) {
            $dest = Join-Path $target $f.Name
            if (-not (Test-Path $dest)) { Move-Item $f.FullName $dest }
        }
    }
    $left = Get-ChildItem $link -Force -ErrorAction SilentlyContinue
    if ($left) { throw "$link still has contents after migration; sort it out by hand" }
    Remove-Item $link -Force
    Write-Step "removed old directory"
    $existing = $null
}

if (-not (Get-Item $link -Force -ErrorAction SilentlyContinue)) {
    $parent = Split-Path $link -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Write-Good "junction created: $link -> $target"
}

if ($ClearCache) {
    foreach ($t in $temps) {
        if (Test-Path $t) {
            Get-ChildItem $t -File | Remove-Item -Force
            Write-Good "cleared $t"
        }
    }
    Get-ChildItem $target -File -Filter *.dat -ErrorAction SilentlyContinue | Remove-Item -Force
    Write-Good "cleared downloaded spray files"
}

Write-Host "`nDone. Start the game and connect.`n"
