<#
.SYNOPSIS
    DinoDDayPatcher -- applies community fixes to a Dino D-Day install.

.DESCRIPTION
    Run with no arguments for an interactive menu.

    Patches:
      1. Config tweaks   -- managed block in cfg\autoexec.cfg
      2. Spray fix       -- junction so server-delivered sprays render
      3. Thread-count fix -- patches bin\tier0.dll for CPUs with >28 threads

.PARAMETER Path
    Install root (the folder containing 'dinodday'). Auto-detected if omitted.

.PARAMETER Status
    Print the status of every patch and exit.

.PARAMETER Revert
    Non-interactive: remove the spray junction.

.PARAMETER ClearCache
    Non-interactive: wipe the spray caches.

.NOTES
    Close the game before running. Junctions and config edits need no
    elevation; the DLL patch needs write access to the install folder.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)][Alias('p')][string]$Path,
    [Alias('s')][switch]$Status,
    [Alias('r')][switch]$Revert,
    [Alias('c', 'Clear')][switch]$ClearCache,
    [Alias('h', '?')][switch]$Help
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ constants

$APPID = 70000

$CFG_BEGIN = '// >>> DinoDDayPatcher >>>'
$CFG_END   = '// <<< DinoDDayPatcher <<<'

# bin\tier0.dll thread-count patch.
# Rewrites the tail of GetCPUInformation to clamp the reported logical and
# physical processor counts to 0x18 (24), working around a crash on CPUs
# with more than 28 threads.
$T0_REL      = 'bin\tier0.dll'
$T0_BACKUP   = 'bin\tier0.dll.dinopatcher.bak'
$T0_SHA256   = '4FF85A018222C46A3E6B3EDA81EF37E345F67CEAC544551161AAE5AA32F3AE8A'
$T0_OFFSET   = 0x2193
$T0_PATCHED  = [byte[]](0x36,0xC6,0x40,0x05,0x18,0x36,0xC6,0x40,0x06,0x18,0xC3,0x90,0x90)
$T0_ORIGINAL = [byte[]](0xC3,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC)
$T0_MIN_THREADS = 28

# Ambient light presets. The index is also the F-key number used by the binds,
# so this table is the single source of truth for both the picker and the keys
# it hands out.
$AMBIENT_PRESETS = @(
    @{ Value = '0';    Label = 'off (game default)' },
    @{ Value = '0.01'; Label = 'light' },
    @{ Value = '0.03'; Label = 'medium' },
    @{ Value = '0.1';  Label = 'bright' },
    @{ Value = '0.2';  Label = 'really bright' }
)
# One key past the presets, for a custom level. Function keys are unbound in
# Dino D-Day by default, so F1-F6 are safe to take.
$AMBIENT_CUSTOM_KEY = 'F' + ($AMBIENT_PRESETS.Count + 1)

# All three channels have to be set together and to the same number. Setting
# them independently tints the scene instead of brightening it.
function New-AmbientCommand($value) {
    return ('mat_ambient_light_r {0};mat_ambient_light_g {0};mat_ambient_light_b {0}' -f $value)
}

# A legend line followed by one bind per preset. Passing '{0}' through
# New-AmbientCommand yields a line Write-ConfigBlock can fill in later.
function New-AmbientBindLines {
    $legend = @()
    $binds  = @()
    for ($i = 0; $i -lt $AMBIENT_PRESETS.Count; $i++) {
        $p = $AMBIENT_PRESETS[$i]
        $legend += ('F{0}={1}' -f ($i + 1), $p.Label)
        $binds  += ('bind F{0} "{1}"' -f ($i + 1), (New-AmbientCommand $p.Value))
    }
    return @('// ' + ($legend -join '  ')) + $binds
}

# Config tweaks. Built fresh by New-TweakList so each call gets its own
# hashtables -- no cloning, no shared state between menu visits.
# ArgType: 'none', 'key' (a bind key), 'logofile' (a path under dinodday\),
# 'fps', 'ambient' (a light level), or 'ambientbinds' (level mirrored from the
# ambient option rather than prompted for).
# {0} in a line is replaced with Arg. OptionalLines are emitted only when Arg
# holds something.
function New-TweakList {
    $list = @()
    $list += @{ Enabled = $true;  ArgType = 'none'; Arg = '';
                Desc = 'Skip warmup rounds on private maps';
                Lines = @('ddd_player_waittime "0"') }
    $list += @{ Enabled = $true;  ArgType = 'none'; Arg = '';
                Desc = 'Allow downloading maps and sprays';
                Lines = @('cl_downloadfilter "all"', 'cl_allowdownload "1"') }
    $list += @{ Enabled = $true;  ArgType = 'none'; Arg = '';
                Desc = "Show other players' sprays";
                Lines = @('cl_playerspraydisable "0"') }
    $list += @{ Enabled = $true;  ArgType = 'key';  Arg = 'g';
                Desc = 'Bind a key to spray';
                Lines = @('bind {0} "impulse 201"') }
    $list += @{ Enabled = $false; ArgType = 'logofile'; Arg = '';
                Desc = 'Use a custom spray file';
                Lines = @('cl_logofile "{0}"') }
    $list += @{ Enabled = $true;  ArgType = 'fps'; Arg = '120';
                Desc = 'Frame rate cap';
                Lines = @('fps_max "{0}"') }
    $list += @{ Enabled = $false; ArgType = 'ambient'; Arg = '0.01';
                Desc = 'Ambient light level (brightens dark areas)';
                Lines = @('mat_ambient_light_r "{0}"',
                          'mat_ambient_light_g "{0}"',
                          'mat_ambient_light_b "{0}"') }
    $list += @{ Enabled = $false; ArgType = 'ambientbinds'; Arg = '';
                Desc = "Bind F1-F$($AMBIENT_PRESETS.Count) to ambient light levels";
                Lines = (New-AmbientBindLines);
                OptionalLines = @("// $AMBIENT_CUSTOM_KEY = your custom level",
                                  "bind $AMBIENT_CUSTOM_KEY `"$(New-AmbientCommand '{0}')`"") }
    $list += @{ Enabled = $false; ArgType = 'none'; Arg = '';
                Desc = 'Brightness fix (for Intel HD Graphics, mainly 500/600 series)';
                Lines = @('mat_tonemapping_occlusion_use_stencil "1"') }
    return $list
}

# Prompts for a spray file and returns it as a forward-slash path relative to
# the dinodday folder, which is what cl_logofile expects.
function Read-LogoFile($root) {
    $modRoot = (Resolve-Path (Join-Path $root 'dinodday')).Path
    $prefix  = $modRoot.TrimEnd('\') + '\'

    Write-Step "Spray file -- absolute path, or relative to the dinodday folder."
    Write-Step "e.g. materials\vgui\logos\mine.vtf"

    while ($true) {
        $in = (Read-Host "  spray file (blank to cancel)").Trim('"', ' ')
        if ($in -eq '') { return $null }

        if ([System.IO.Path]::IsPathRooted($in)) { $full = $in }
        else { $full = Join-Path $modRoot $in }

        if (-not (Test-Path $full -PathType Leaf)) {
            Write-Bad "no file at $full"
            continue
        }
        $full = (Resolve-Path $full).Path

        if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Bad "that file is outside $modRoot"
            Write-Step "cl_logofile paths are read relative to the dinodday folder,"
            Write-Step "so copy the file in there first, then pick it again."
            continue
        }

        $rel = $full.Substring($prefix.Length) -replace '\\', '/'

        if ($rel -notmatch '\.vtf$') {
            Write-Warn2 "that is not a .vtf file -- the game will not load it as a spray"
            if (-not (Read-YesNo "Use it anyway?" $false)) { continue }
        }

        Write-Good "using $rel"
        return $rel
    }
}

# fps_max. 0 means uncapped; the engine ignores anything under 30.
function Read-FpsMax($current) {
    Write-Step "Frame rate cap. 0 is uncapped; the engine ignores values under 30."
    while ($true) {
        $in = (Read-Host "  fps (blank keeps $current)").Trim()
        if ($in -eq '') { return $current }
        if ($in -notmatch '^\d+$') { Write-Bad "whole numbers only"; continue }
        $n = [int]$in
        if ($n -ne 0 -and ($n -lt 30 -or $n -gt 1000)) {
            Write-Bad "use 0 for uncapped, or a number between 30 and 1000"
            continue
        }
        return "$n"
    }
}

# The regex forbids a comma, so a non-English locale cannot get '0,05' this
# far, and parsing is pinned to the invariant culture for the same reason.
# Normalising means '0.010' collapses to '0.01' and is recognised as a preset
# instead of pointlessly occupying the custom key.
function Read-AmbientCustom {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    while ($true) {
        $in = (Read-Host "  custom level, 0 to 1 (blank to go back)").Trim()
        if ($in -eq '') { return $null }
        if ($in -notmatch '^\d+(\.\d+)?$') {
            Write-Bad "a number like 0.05 -- use a dot, not a comma"
            continue
        }
        $v = [double]::Parse($in, $inv)
        if ($v -lt 0 -or $v -gt 1) { Write-Bad "0 to 1 only"; continue }
        if ($v -gt 0.2) { Write-Warn2 "above 0.2 the picture washes out badly" }
        return $v.ToString('0.####', $inv)
    }
}

function Read-AmbientLevel($current) {
    $customChoice = $AMBIENT_PRESETS.Count + 1
    Write-Host ''
    Write-Step "Ambient light level -- lifts the darkest parts of a map."
    for ($i = 0; $i -lt $AMBIENT_PRESETS.Count; $i++) {
        $p = $AMBIENT_PRESETS[$i]
        Write-Host ("    " + ($i + 1) + ". " + $p.Value.PadRight(6) + $p.Label)
    }
    Write-Host ("    $customChoice. custom value")

    while ($true) {
        $in = (Read-Host "  level (blank keeps $current)").Trim()
        if ($in -eq '') { return $current }
        if ($in -notmatch '^\d+$') { Write-Bad "pick a number from the list"; continue }
        $n = [int]$in
        if ($n -ge 1 -and $n -le $AMBIENT_PRESETS.Count) { return $AMBIENT_PRESETS[$n - 1].Value }
        if ($n -ne $customChoice) { Write-Warn2 "no such option"; continue }
        $v = Read-AmbientCustom
        if ($v) { return $v }
    }
}

# The custom key mirrors a custom level picked in the ambient light option.
# Preset levels already have keys of their own, so it is only added for a value
# that is not one of them. Runs after every change and before writing.
function Sync-AmbientBinds($tweaks) {
    $binds = @($tweaks | Where-Object { $_.ArgType -eq 'ambientbinds' })
    if ($binds.Count -eq 0) { return }
    $amb = @($tweaks | Where-Object { $_.ArgType -eq 'ambient' })
    $level = ''
    if ($amb.Count -gt 0) { $level = $amb[0].Arg }
    if ($level -and ($AMBIENT_PRESETS.Value -notcontains $level)) { $binds[0].Arg = $level }
    else { $binds[0].Arg = '' }
}

# ------------------------------------------------------------------ utilities

function Write-Good($m) { Write-Host "  $m" -ForegroundColor Green }
function Write-Bad($m)  { Write-Host "  $m" -ForegroundColor Red }
function Write-Warn2($m){ Write-Host "  $m" -ForegroundColor Yellow }
function Write-Step($m) { Write-Host "  $m" }
function Write-Header($m) { Write-Host "  $m" -ForegroundColor Cyan }
function Write-Alert($m)  { Write-Host "  WARNING: $m" -ForegroundColor Red }
# Continuation lines for a multi-line alert, indented to line up under the text.
function Write-AlertLine($m) { Write-Host "           $m" -ForegroundColor Red }

# Reads $count bytes at $offset without pulling the whole file into memory.
# Opens with FileShare::ReadWrite so status checks still work while something
# else has the file open. Returns $null if the read cannot be satisfied.
function Read-FileBytes($path, $offset, $count) {
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read,
                                     [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -lt ($offset + $count)) { return $null }
        $fs.Position = $offset
        $buf = New-Object byte[] $count
        if ($fs.Read($buf, 0, $count) -ne $count) { return $null }
        return $buf
    } catch {
        return $null
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

# True only if the file can be opened for writing with no other handles on it.
# FileShare::None makes this fail while a hex editor, Explorer preview pane or
# an antivirus scan is holding the file.
function Test-FileWritable($path) {
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::ReadWrite,
                                     [System.IO.FileShare]::None)
        $fs.Close()
        $fs.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Read-YesNo($prompt, $default = $false) {
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = (Read-Host "  $prompt $hint").Trim().ToLower()
        if ($a -eq '')                 { return $default }
        if ($a -in @('y','yes'))       { return $true }
        if ($a -in @('n','no'))        { return $false }
    }
}

# The CPU does not change while the script runs, and the WMI query is slow
# enough to be noticeable on every menu redraw.
$script:CachedThreads = 0

function Get-LogicalProcessorCount {
    if ($script:CachedThreads -gt 0) { return $script:CachedThreads }
    $n = 0
    try {
        $n = (Get-CimInstance Win32_Processor |
              Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    } catch { }
    if (-not $n -or $n -le 0) { $n = [int][Environment]::ProcessorCount }
    $script:CachedThreads = [int]$n
    return $script:CachedThreads
}

function Test-GameRunning {
    $p = Get-Process -Name 'dinodday','hl2','srcds' -ErrorAction SilentlyContinue
    if ($p) {
        Write-Bad "close the game first ($($p.Name -join ', ') running)"
        return $true
    }
    return $false
}

# ------------------------------------------------------------------ detection

function Get-SteamRoot {
    foreach ($k in @('HKCU:\Software\Valve\Steam',
                     'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
                     'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            foreach ($prop in @('SteamPath','InstallPath')) {
                if ($p.$prop -and (Test-Path $p.$prop)) { return (Resolve-Path $p.$prop).Path }
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
        foreach ($line in Get-Content $vdf) {
            if ($line -match '"(?:path|\d+)"\s+"(.+?)"') {
                $sa = Join-Path ($matches[1] -replace '\\\\','\') 'steamapps'
                if (Test-Path $sa) { $libs += $sa }
            }
        }
    }
    return $libs | Select-Object -Unique
}

function Find-GameRoot {
    foreach ($base in @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        try {
            $p = Get-ItemProperty -Path (Join-Path $base "Steam App $APPID") -ErrorAction Stop
            if ($p.InstallLocation -and (Test-Path $p.InstallLocation)) {
                return (Resolve-Path $p.InstallLocation).Path
            }
        } catch { }
    }
    $sr = Get-SteamRoot
    if (-not $sr) { return $null }
    foreach ($lib in (Get-SteamLibraries $sr)) {
        $acf = Join-Path $lib "appmanifest_$APPID.acf"
        if (-not (Test-Path $acf)) { continue }
        foreach ($line in Get-Content $acf) {
            if ($line -match '"installdir"\s+"(.+?)"') {
                $full = Join-Path $lib "common\$($matches[1])"
                if (Test-Path $full) { return (Resolve-Path $full).Path }
            }
        }
    }
    return $null
}

function Test-GameRoot($p) {
    return ($p -and (Test-Path (Join-Path $p 'dinodday\gameinfo.txt')))
}

function Read-GameRootPrompt($current) {
    if ($current) { Write-Step "current: $current" }
    while ($true) {
        $in = (Read-Host "  Install root (blank to cancel)").Trim('"', ' ')
        if ($in -eq '') { return $null }
        if (Test-GameRoot $in) { return (Resolve-Path $in).Path }
        Write-Bad "no dinodday\gameinfo.txt there -- try again"
    }
}

function Resolve-GameRoot($explicit) {
    if ($explicit) {
        if (-not (Test-GameRoot $explicit)) {
            throw "no dinodday\gameinfo.txt under '$explicit'"
        }
        return (Resolve-Path $explicit).Path
    }
    $r = Find-GameRoot
    if (Test-GameRoot $r) { return $r }

    Write-Warn2 "could not auto-detect the install."
    return Read-GameRootPrompt $null
}

# ------------------------------------------------------------------ spray fix

function Get-SprayPaths($root) {
    return @{
        Target = Join-Path $root 'dinodday\downloads'
        Link   = Join-Path $root 'update\downloads'
        Temps  = @((Join-Path $root 'update\materials\temp'),
                   (Join-Path $root 'dinodday\materials\temp'))
    }
}

function Get-SprayStatus($root) {
    $p = Get-SprayPaths $root
    $i = Get-Item $p.Link -Force -ErrorAction SilentlyContinue
    if (-not $i) { return 'not installed' }
    if ($i.LinkType -ne 'Junction') { return 'not installed' }
    if ($i.Target -contains $p.Target) { return 'installed' }
    return 'wrong target'
}

function Show-SprayInfo {
    Write-Host ''
    Write-Header "Getting your own spray on DinoTown"
    Write-Host ''
    Write-Step "Sprays have to be added to the server before anyone can see them."
    Write-Step "If you want yours added, contact one of the server admins on Steam"
    Write-Step "or on Discord -- invite at http://dinotown.net/discord"
    Write-Host ''
    Write-Warn2 "NSFW, gore or otherwise illegal content is not allowed in sprays."
    Write-Host ''
}

function Install-SprayFix($root) {
    if (Test-GameRunning) { return }
    $p = Get-SprayPaths $root

    if (-not (Test-Path $p.Target)) {
        New-Item -ItemType Directory -Path $p.Target -Force | Out-Null
        Write-Good "created $($p.Target)"
    }

    $existing = Get-Item $p.Link -Force -ErrorAction SilentlyContinue
    if ($existing -and $existing.LinkType -eq 'Junction') {
        if ($existing.Target -contains $p.Target) {
            Write-Good "already installed"
            Show-SprayInfo
            return
        }
        Write-Warn2 "replacing junction pointing at $($existing.Target)"
        [System.IO.Directory]::Delete($p.Link, $false)
    } elseif ($existing) {
        $files = Get-ChildItem $p.Link -File -ErrorAction SilentlyContinue
        if ($files) {
            Write-Warn2 "migrating $($files.Count) file(s) to the target folder"
            foreach ($f in $files) {
                $d = Join-Path $p.Target $f.Name
                if (-not (Test-Path $d)) { Move-Item $f.FullName $d }
            }
        }
        if (Get-ChildItem $p.Link -Force -ErrorAction SilentlyContinue) {
            Write-Bad "$($p.Link) still has contents -- clear it by hand"; return
        }
        Remove-Item $p.Link -Force
    }

    $parent = Split-Path $p.Link -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    New-Item -ItemType Junction -Path $p.Link -Target $p.Target | Out-Null
    Write-Good "junction created: $($p.Link) -> $($p.Target)"
    Show-SprayInfo
}

function Uninstall-SprayFix($root) {
    if (Test-GameRunning) { return }
    $p = Get-SprayPaths $root
    $i = Get-Item $p.Link -Force -ErrorAction SilentlyContinue
    if ($i -and $i.LinkType -eq 'Junction') {
        # Delete($path, $false) removes the link only. Remove-Item -Recurse
        # would follow it and take the target's contents.
        [System.IO.Directory]::Delete($p.Link, $false)
        New-Item -ItemType Directory -Path $p.Link -Force | Out-Null
        Write-Good "junction removed"
    } else {
        Write-Warn2 "no junction to remove"
    }
}

function Clear-SprayCache($root) {
    if (Test-GameRunning) { return }
    $p = Get-SprayPaths $root
    foreach ($t in $p.Temps) {
        if (Test-Path $t) {
            Get-ChildItem $t -File | Remove-Item -Force
            Write-Good "cleared $t"
        }
    }
    if (Test-Path $p.Target) {
        Get-ChildItem $p.Target -File -Filter *.dat | Remove-Item -Force
        Write-Good "cleared downloaded .dat files"
    }
}

# --------------------------------------------------------------- config tweaks

function Get-ConfigPath($root) { Join-Path $root 'dinodday\cfg\autoexec.cfg' }

function Get-ConfigStatus($root) {
    $f = Get-ConfigPath $root
    if (-not (Test-Path $f)) { return 'not installed' }
    if ((Get-Content $f -Raw) -match [regex]::Escape($CFG_BEGIN)) { return 'installed' }
    return 'not installed'
}

# Matches an option's first real (non-comment) line, with {0} turned into a
# capture group so the value comes back with the on/off state. Splitting on the
# placeholder and escaping the pieces avoids depending on how Regex.Escape
# happens to treat braces.
function Get-TweakPattern($t) {
    $sig = @($t.Lines | Where-Object { $_ -notmatch '^\s*//' })[0]
    if (-not $sig) { return $null }
    $parts = @($sig -split '\{0\}' | ForEach-Object { [regex]::Escape($_) })
    return '^\s*' + ($parts -join '(.+?)') + '\s*$'
}

# A block that has been edited by hand can hold anything. Values that do not fit
# the option are dropped so nonsense cannot travel back into the file or into a
# bind; the option still comes back on, at its default value.
function Test-TweakArg($t, $v) {
    if ($v -eq '') { return $false }
    switch ($t.ArgType) {
        'key'      { return ($v -notmatch '[\s"]') }
        'logofile' { return $true }
        'fps'      { return ($v -match '^\d+$') }
        'ambient'  { return ($v -match '^\d+(\.\d+)?$') }
    }
    return $false
}

# Reads an existing managed block back into the toggle list, so the menu opens
# on what is actually in the file instead of the defaults. The block is the
# record of what was applied, so an option the block does not mention is one
# that was switched off.
#
# Only the first line of a multi-line option is inspected. The three ambient
# channels are always written together, so reading the red one back is enough --
# hand-edited channels that disagree get unified on the next apply.
function Read-ConfigBlock($root, $tweaks) {
    $f = Get-ConfigPath $root
    if (-not (Test-Path $f)) { return }

    $body = @(); $inBlock = $false; $seen = $false
    foreach ($line in Get-Content $f) {
        if ($line.Trim() -eq $CFG_BEGIN) { $inBlock = $true; $seen = $true; continue }
        if ($line.Trim() -eq $CFG_END)   { $inBlock = $false; continue }
        if ($inBlock) { $body += $line }
    }
    if (-not $seen) { return }

    foreach ($t in $tweaks) { $t.Enabled = $false }

    $rejected = @()
    foreach ($t in $tweaks) {
        $rx = Get-TweakPattern $t
        if (-not $rx) { continue }
        foreach ($line in $body) {
            $m = [regex]::Match($line, $rx)
            if (-not $m.Success) { continue }
            $t.Enabled = $true
            if ($m.Groups.Count -gt 1) {
                $v = $m.Groups[1].Value.Trim()
                if (Test-TweakArg $t $v) { $t.Arg = $v }
                else { $rejected += "$($t.Desc) -- '$v'" }
            }
            break
        }
    }

    Write-Good "loaded your current settings from autoexec.cfg"
    foreach ($r in $rejected) { Write-Warn2 "unusable value ignored: $r" }
}

function Write-ConfigBlock($root, $tweaks) {
    $f = Get-ConfigPath $root
    $dir = Split-Path $f -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Preserve anything the user put outside our markers.
    $kept = @()
    if (Test-Path $f) {
        $inBlock = $false
        foreach ($line in Get-Content $f) {
            if ($line.Trim() -eq $CFG_BEGIN) { $inBlock = $true; continue }
            if ($line.Trim() -eq $CFG_END)   { $inBlock = $false; continue }
            if (-not $inBlock) { $kept += $line }
        }
        Copy-Item $f "$f.bak" -Force
    }

    $block = @($CFG_BEGIN, "// generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    foreach ($t in $tweaks) {
        if (-not $t.Enabled) { continue }
        $block += "// $($t.Desc)"
        $lines = @($t.Lines)
        # Optional lines only make sense once Arg holds something -- see the
        # ambient binds, where they are the custom-level key.
        if ($t.OptionalLines -and $t.Arg) { $lines += $t.OptionalLines }
        foreach ($l in $lines) {
            if ($l -like '*{0}*') { $block += ($l -f $t.Arg) }
            else { $block += $l }
        }
    }
    $block += $CFG_END

    # Trim trailing blanks from kept content so the file stays tidy.
    while ($kept.Count -gt 0 -and $kept[-1].Trim() -eq '') {
        $kept = $kept[0..($kept.Count - 2)]
    }

    Set-Content -Path $f -Value (@($kept) + @('') + $block) -Encoding ASCII
    Write-Good "wrote $f"
    if (Test-Path "$f.bak") { Write-Step "previous version saved as autoexec.cfg.bak" }
}

function Remove-ConfigBlock($root) {
    $f = Get-ConfigPath $root
    if (-not (Test-Path $f)) { Write-Warn2 "no autoexec.cfg"; return }
    Copy-Item $f "$f.bak" -Force
    $kept = @(); $inBlock = $false
    foreach ($line in Get-Content $f) {
        if ($line.Trim() -eq $CFG_BEGIN) { $inBlock = $true; continue }
        if ($line.Trim() -eq $CFG_END)   { $inBlock = $false; continue }
        if (-not $inBlock) { $kept += $line }
    }
    Set-Content -Path $f -Value $kept -Encoding ASCII
    Write-Good "removed managed block (other lines kept)"
    Write-Step "previous version saved as autoexec.cfg.bak"
}

# The parenthesised part after an option in the menu.
function Get-TweakArgLabel($t) {
    switch ($t.ArgType) {
        'key'      { return "key: $($t.Arg)" }
        'logofile' {
            if ($t.Arg) { return $t.Arg }
            return 'none picked'
        }
        'fps' {
            if ($t.Arg -eq '0') { return 'uncapped' }
            return $t.Arg
        }
        'ambient' {
            $p = @($AMBIENT_PRESETS | Where-Object { $_.Value -eq $t.Arg })
            if ($p.Count -gt 0) { return "$($t.Arg) - $($p[0].Label)" }
            return "$($t.Arg) - custom"
        }
        'ambientbinds' {
            if ($t.Arg) { return "+$($AMBIENT_CUSTOM_KEY): $($t.Arg)" }
            return ''
        }
    }
    return ''
}

# Prompts for an option's value. Returns $null only when the user cancelled,
# in which case the caller leaves the option as it found it.
function Read-TweakArg($root, $t) {
    switch ($t.ArgType) {
        'key' {
            $k = (Read-Host "  key to bind (blank keeps '$($t.Arg)')").Trim()
            if ($k -eq '') { return $t.Arg }
            return $k.ToLower()
        }
        'logofile' { return (Read-LogoFile $root) }
        'fps'      { return (Read-FpsMax $t.Arg) }
        'ambient'  { return (Read-AmbientLevel $t.Arg) }
    }
    return $null
}

# An option that carries a value needs a way to change it without toggling it
# off and on again, which would throw the current value away.
function Read-TweakAction($t) {
    Write-Host ''
    Write-Step "$($t.Desc) is on ($(Get-TweakArgLabel $t))."
    Write-Host "    1. change value"
    Write-Host "    2. turn it off"
    Write-Host "    3. cancel"
    while ($true) {
        $a = (Read-Host "  choice").Trim()
        if ($a -eq '1') { return 'edit' }
        if ($a -eq '2') { return 'off' }
        if ($a -eq '3' -or $a -eq '') { return 'cancel' }
    }
}

function Invoke-ConfigMenu($root) {
    $tweaks = @(New-TweakList)
    Read-ConfigBlock $root $tweaks
    Sync-AmbientBinds $tweaks

    if ($tweaks.Count -eq 0) {
        Write-Bad "tweak list came back empty -- New-TweakList is not returning anything"
        return
    }

    while ($true) {
        $installed = (Get-ConfigStatus $root) -eq 'installed'

        Write-Host ''
        Write-Header "Config tweaks for autoexec.cfg"
        if ($installed) {
            Write-Header "toggle by number, 'a' to apply, 'u' to uninstall, 'q' to go back"
        } else {
            Write-Header "toggle by number, 'a' to apply, 'q' to go back"
        }
        Write-Host ''

        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            $mark = ' '
            if ($tweaks[$i].Enabled) { $mark = 'x' }
            $label = $tweaks[$i].Desc
            $arg = Get-TweakArgLabel $tweaks[$i]
            if ($arg) { $label = "$label ($arg)" }
            Write-Host ("    [$mark] " + ($i + 1) + ". " + $label)
        }

        Write-Host ''
        $a = (Read-Host "  choice").Trim().ToLower()

        if ($a -eq 'q') { return }

        if ($a -eq 'u') {
            if (-not $installed) { Write-Warn2 "no managed block to remove"; continue }
            if (Read-YesNo "Remove the managed block from autoexec.cfg?" $false) {
                Remove-ConfigBlock $root
                return
            }
            continue
        }

        if ($a -eq 'a') {
            $missing = @($tweaks | Where-Object {
                $_.Enabled -and ($_.ArgType -notin @('none', 'ambientbinds')) -and -not $_.Arg
            })
            if ($missing.Count -gt 0) {
                Write-Bad "no value set for: $(($missing | ForEach-Object { $_.Desc }) -join ', ')"
                Write-Step "set one, or turn that option off"
                continue
            }
            Sync-AmbientBinds $tweaks
            Write-ConfigBlock $root $tweaks
            return
        }

        if ($a -match '^\d+$') {
            $idx = [int]$a - 1
            if ($idx -ge 0 -and $idx -lt $tweaks.Count) {
                $t = $tweaks[$idx]
                if ($t.ArgType -in @('none', 'ambientbinds')) {
                    $t.Enabled = -not $t.Enabled
                } elseif ($t.Enabled) {
                    switch (Read-TweakAction $t) {
                        'edit' {
                            $v = Read-TweakArg $root $t
                            if ($null -ne $v) { $t.Arg = $v }
                        }
                        'off' { $t.Enabled = $false }
                    }
                } else {
                    # A cancelled prompt leaves the option off, which is how
                    # picking no spray file has always behaved.
                    $v = Read-TweakArg $root $t
                    if ($null -ne $v) { $t.Arg = $v; $t.Enabled = $true }
                }
                Sync-AmbientBinds $tweaks
            } else {
                Write-Warn2 "no such option"
            }
        }
    }
}

# ------------------------------------------------------------- tier0 dll patch

function Get-Tier0Status($root) {
    $f = Join-Path $root $T0_REL
    if (-not (Test-Path $f)) { return 'missing' }
    $cur = Read-FileBytes $f $T0_OFFSET $T0_PATCHED.Length
    if ($null -eq $cur) { return 'unreadable' }
    if (-not (Compare-Object $cur $T0_PATCHED))  { return 'applied' }
    if (-not (Compare-Object $cur $T0_ORIGINAL)) { return 'not applied' }
    return 'unrecognised'
}

function Install-Tier0Patch($root) {
    if (Test-GameRunning) { return }
    $f = Join-Path $root $T0_REL
    if (-not (Test-Path $f)) { Write-Bad "$T0_REL not found"; return }

    $threads = Get-LogicalProcessorCount
    Write-Step "this CPU reports $threads logical processors"
    if ($threads -le $T0_MIN_THREADS) {
        Write-Warn2 "the bug only affects CPUs with more than $T0_MIN_THREADS threads."
        Write-Warn2 "this patch will not help you and is not worth the risk."
        if (-not (Read-YesNo "Apply anyway?" $false)) { return }
    }

    if (-not (Test-FileWritable $f)) {
        Write-Bad "cannot get write access to $T0_REL"
        Write-Step "it is open in another program -- close any hex editor, Explorer"
        Write-Step "preview pane, or antivirus scan holding it, then try again."
        return
    }

    Write-Host ''
    Write-Alert     "This modifies a game DLL. Dino D-Day has VAC enabled, so"
    Write-AlertLine "modifying game files carries a risk of a VAC ban. The community"
    Write-AlertLine "runs this patch widely without reported problems, but the risk"
    Write-AlertLine "is yours to take."
    Write-Host ''
    if (-not (Read-YesNo "Understood -- proceed?" $false)) { return }

    $status = Get-Tier0Status $root
    if ($status -eq 'applied') { Write-Good "already patched"; return }

    $hash = (Get-FileHash $f -Algorithm SHA256).Hash
    if ($hash -ne $T0_SHA256) {
        Write-Warn2 "tier0.dll does not match the known original:"
        Write-Warn2 "  expected $T0_SHA256"
        Write-Warn2 "  found    $hash"
        Write-Warn2 "The game may have been updated. Patching at a fixed offset"
        Write-Warn2 "in a file you cannot verify can corrupt it."
        if (-not (Read-YesNo "Proceed regardless?" $false)) { return }
    }

    if ($status -ne 'not applied') {
        Write-Bad "bytes at 0x$('{0:X}' -f $T0_OFFSET) are not the expected original ($status) -- refusing"
        return
    }

    $backup = Join-Path $root $T0_BACKUP
    try {
        if (-not (Test-Path $backup)) {
            Copy-Item $f $backup -Force
            Write-Good "backed up to $T0_BACKUP"
        }

        $b = [System.IO.File]::ReadAllBytes($f)
        for ($i = 0; $i -lt $T0_PATCHED.Length; $i++) { $b[$T0_OFFSET + $i] = $T0_PATCHED[$i] }
        [System.IO.File]::WriteAllBytes($f, $b)
    } catch {
        Write-Bad "patch failed: $($_.Exception.Message)"
        Write-Step "nothing was changed, or the backup at $T0_BACKUP has the original."
        return
    }

    if ((Get-Tier0Status $root) -eq 'applied') {
        Write-Good "patch applied and verified"
    } else {
        Write-Bad "verification failed -- restore from $T0_BACKUP"
    }
}

function Uninstall-Tier0Patch($root) {
    if (Test-GameRunning) { return }
    $f = Join-Path $root $T0_REL
    $backup = Join-Path $root $T0_BACKUP

    if (-not (Test-Path $f)) { Write-Bad "$T0_REL not found"; return }

    if (-not (Test-FileWritable $f)) {
        Write-Bad "cannot get write access to $T0_REL"
        Write-Step "it is open in another program -- close any hex editor, Explorer"
        Write-Step "preview pane, or antivirus scan holding it, then try again."
        return
    }

    try {
        if (Test-Path $backup) {
            if ((Get-FileHash $backup -Algorithm SHA256).Hash -eq $T0_SHA256) {
                Copy-Item $backup $f -Force
                Write-Good "restored original from backup"
                return
            }
            Write-Warn2 "backup does not match the known original hash; not using it"
        }

        if ((Get-Tier0Status $root) -ne 'applied') { Write-Warn2 "not patched"; return }
        $b = [System.IO.File]::ReadAllBytes($f)
        for ($i = 0; $i -lt $T0_ORIGINAL.Length; $i++) { $b[$T0_OFFSET + $i] = $T0_ORIGINAL[$i] }
        [System.IO.File]::WriteAllBytes($f, $b)
        Write-Good "bytes restored in place"
        Write-Step "run Steam's 'Verify integrity of game files' to be certain"
    } catch {
        Write-Bad "revert failed: $($_.Exception.Message)"
        Write-Step "the original is still at $T0_BACKUP if you need it."
    }
}

# ------------------------------------------------------------------- main menu

function Show-Status($root) {
    $threads = Get-LogicalProcessorCount
    Write-Host ''
    Write-Header "Install : $root"
    Write-Header "CPU     : $threads logical processors"
    Write-Host ''
    Write-Host "    1. Config tweaks ........ [$(Get-ConfigStatus $root)]"
    Write-Host "       [Optional fixes and binds written to cfg\autoexec.cfg]" -ForegroundColor DarkGray
    Write-Host "    2. Spray fix ............ [$(Get-SprayStatus $root)]"
    Write-Host "       [Lets server-delivered custom sprays download and render]" -ForegroundColor DarkGray
    $t0 = Get-Tier0Status $root
    $note = if ($threads -gt $T0_MIN_THREADS) { '  <- recommended for this CPU' } else { '  (not needed)' }
    Write-Host "    3. Thread-count fix ..... [$t0]$note"
    Write-Host "       [Fixes crash on map load on high end CPUs]" -ForegroundColor DarkGray
}

function Invoke-Menu($root) {
    while ($true) {
        Show-Status $root
        Write-Host "`n    4. Clear spray caches"
        Write-Host "    5. Change install path"
        Write-Host "    0. Exit`n"
        $a = (Read-Host "  choice").Trim()

        try {
            switch ($a) {
                '1' { Invoke-ConfigMenu $root }
                '2' {
                    if ((Get-SprayStatus $root) -eq 'installed') {
                        if (Read-YesNo "Spray fix is installed. Remove it?" $false) {
                            Uninstall-SprayFix $root
                        }
                    } else { Install-SprayFix $root }
                }
                '3' {
                    if ((Get-Tier0Status $root) -eq 'applied') {
                        if (Read-YesNo "Thread-count fix is applied. Revert it?" $false) {
                            Uninstall-Tier0Patch $root
                        }
                    } else { Install-Tier0Patch $root }
                }
                '4' { Clear-SprayCache $root }
                '5' {
                    $n = Read-GameRootPrompt $root
                    if ($n) {
                        $root = $n
                        Write-Good "install path changed"
                    } else {
                        Write-Step "path unchanged"
                    }
                }
                '0' { return }
            }
        } catch {
            Write-Host ''
            Write-Bad "that action failed: $($_.Exception.Message)"
            Write-Step "nothing further was changed. Returning to the menu."
        }
    }
}

# ------------------------------------------------------------------------ run

if ($Help) { Get-Help $PSCommandPath -Detailed; return }

Write-Host "`n  DinoDDayPatcher`n"

$root = Resolve-GameRoot $Path
if (-not $root) { Write-Bad "no install selected"; return }

if ($Status)     { Show-Status $root; Write-Host ''; return }
if ($Revert)     { Uninstall-SprayFix $root; return }
if ($ClearCache) { Clear-SprayCache $root; return }

Invoke-Menu $root
Write-Host ''
