<#
.SYNOPSIS
    DinoDDayPatcher -- applies community fixes to a Dino D-Day install.

.DESCRIPTION
    Run with no arguments for an interactive menu.

    Patches:
      1. Spray fix       -- junction so server-delivered sprays render
      2. Config tweaks   -- managed block in cfg\autoexec.cfg
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

# Config tweaks. Built fresh by New-TweakList so each call gets its own
# hashtables -- no cloning, no shared state between menu visits.
# ArgType: 'none', 'key' (a bind key), or 'logofile' (a path under dinodday\).
# {0} in a line is replaced with Arg.
function New-TweakList {
    $list = @()
    $list += @{ Enabled = $true;  ArgType = 'none'; Arg = '';
                Desc = 'Skip warmup rounds on private maps';
                Lines = @('ddd_player_waittime "0"') }
    $list += @{ Enabled = $false; ArgType = 'none'; Arg = '';
                Desc = 'Brightness fix (some Intel systems render too dark)';
                Lines = @('mat_tonemapping_occlusion_use_stencil "1"') }
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

# ------------------------------------------------------------------ utilities

function Write-Good($m) { Write-Host "  $m" -ForegroundColor Green }
function Write-Bad($m)  { Write-Host "  $m" -ForegroundColor Red }
function Write-Warn2($m){ Write-Host "  $m" -ForegroundColor Yellow }
function Write-Step($m) { Write-Host "  $m" }
function Write-Header($m) { Write-Host "  $m" -ForegroundColor Cyan }
function Write-Alert($m)  { Write-Host "  WARNING: $m" -ForegroundColor Red }

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

function Get-LogicalProcessorCount {
    try {
        $n = (Get-CimInstance Win32_Processor |
              Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        if ($n -gt 0) { return [int]$n }
    } catch { }
    return [int][Environment]::ProcessorCount
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
        foreach ($l in $t.Lines) {
            if ($t.ArgType -ne 'none') { $block += ($l -f $t.Arg) }
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
    $kept = @(); $inBlock = $false
    foreach ($line in Get-Content $f) {
        if ($line.Trim() -eq $CFG_BEGIN) { $inBlock = $true; continue }
        if ($line.Trim() -eq $CFG_END)   { $inBlock = $false; continue }
        if (-not $inBlock) { $kept += $line }
    }
    Set-Content -Path $f -Value $kept -Encoding ASCII
    Write-Good "removed managed block (other lines kept)"
}

function Invoke-ConfigMenu($root) {
    $tweaks = @(New-TweakList)

    if ($tweaks.Count -eq 0) {
        Write-Bad "tweak list came back empty -- New-TweakList is not returning anything"
        return
    }

    while ($true) {
        Write-Host ''
        Write-Header "Config tweaks for autoexec.cfg"
        Write-Header "toggle by number, 'a' to apply, 'q' to go back"
        Write-Host ''

        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            $mark = ' '
            if ($tweaks[$i].Enabled) { $mark = 'x' }
            $label = $tweaks[$i].Desc
            if ($tweaks[$i].ArgType -eq 'key') {
                $label = "$label (key: $($tweaks[$i].Arg))"
            } elseif ($tweaks[$i].ArgType -eq 'logofile') {
                $shown = $tweaks[$i].Arg
                if (-not $shown) { $shown = 'none picked' }
                $label = "$label ($shown)"
            }
            Write-Host ("    [$mark] " + ($i + 1) + ". " + $label)
        }

        Write-Host ''
        $a = (Read-Host "  choice").Trim().ToLower()

        if ($a -eq 'q') { return }

        if ($a -eq 'a') {
            $missing = @($tweaks | Where-Object {
                $_.Enabled -and $_.ArgType -eq 'logofile' -and -not $_.Arg
            })
            if ($missing.Count -gt 0) {
                Write-Bad "no spray file picked -- choose one or turn that option off"
                continue
            }
            Write-ConfigBlock $root $tweaks
            return
        }

        if ($a -match '^\d+$') {
            $idx = [int]$a - 1
            if ($idx -ge 0 -and $idx -lt $tweaks.Count) {
                $tweaks[$idx].Enabled = -not $tweaks[$idx].Enabled

                if ($tweaks[$idx].Enabled -and $tweaks[$idx].ArgType -eq 'key') {
                    $k = (Read-Host "  key to bind (blank keeps '$($tweaks[$idx].Arg)')").Trim()
                    if ($k -ne '') { $tweaks[$idx].Arg = $k.ToLower() }
                }

                if ($tweaks[$idx].Enabled -and $tweaks[$idx].ArgType -eq 'logofile') {
                    $f = Read-LogoFile $root
                    if ($f) { $tweaks[$idx].Arg = $f }
                    else { $tweaks[$idx].Enabled = $false }
                }
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
    $b = [System.IO.File]::ReadAllBytes($f)
    if ($b.Length -lt ($T0_OFFSET + $T0_PATCHED.Length)) { return 'unrecognised' }
    $cur = $b[$T0_OFFSET..($T0_OFFSET + $T0_PATCHED.Length - 1)]
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
    Write-Alert "This modifies a game DLL. Dino D-Day has VAC enabled, so"
    Write-Alert "modifying game files carries a risk of a VAC ban. The community"
    Write-Alert "runs this patch widely without reported problems, but the risk"
    Write-Alert "is yours to take."
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

    if ($status -eq 'unrecognised') {
        Write-Bad "bytes at 0x$('{0:X}' -f $T0_OFFSET) are neither original nor patched -- refusing"
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
    Write-Host "    1. Spray fix ............ [$(Get-SprayStatus $root)]"
    Write-Host "       [Lets server-delivered custom sprays download and render]" -ForegroundColor DarkGray
    Write-Host "    2. Config tweaks ........ [$(Get-ConfigStatus $root)]"
    Write-Host "       [Optional fixes and binds written to cfg\autoexec.cfg]" -ForegroundColor DarkGray
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
                '1' {
                    if ((Get-SprayStatus $root) -eq 'installed') {
                        if (Read-YesNo "Spray fix is installed. Remove it?" $false) {
                            Uninstall-SprayFix $root
                        }
                    } else { Install-SprayFix $root }
                }
                '2' {
                    if ((Get-ConfigStatus $root) -eq 'installed') {
                        if (Read-YesNo "Config block exists. Remove it? (no = edit)" $false) {
                            Remove-ConfigBlock $root
                        } else { Invoke-ConfigMenu $root }
                    } else { Invoke-ConfigMenu $root }
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
