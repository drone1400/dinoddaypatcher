# Dino D-Day tools

> ⚠️ **Work in progress — not yet fully tested.**
>
> These scripts are still undergoing testing and should be treated as
> pre-release. Back up anything you care about before running them, and don't
> rely on them working correctly yet. In particular, `DinoDDayPatcher.ps1`
> modifies files in your game install, including an optional patch to a game
> DLL. This notice will be removed once everything has been properly
> re-tested.

Tooling for custom player sprays on [DinoTown](http://dinotown.net), a patcher
that applies community fixes to a Dino D-Day install, and a map asset auditor
for server operators.

Dino D-Day supports Team Fortress–style sprays via `impulse 201`, but they
appear broken out of the box: the default `cl_logofile` points at a texture
that isn't in the shipped game files, and two bugs in the engine's
custom-file handling stop server-delivered sprays from ever rendering. These
scripts work around both.

## Scripts

Everything lives under `scripts/`:

```
ddd-patcher/    the patcher — spray junction, config tweaks, tier0 fix
spray-tools/    the spray pipeline — image in, server-ready files out
other-tools/    nothing to do with sprays; see the end of this file
```

### `ddd-patcher/DinoDDayPatcher.ps1`

Interactive Windows patcher. Run it with no arguments for a menu; it finds
your install through Steam automatically.

```powershell
.\DinoDDayPatcher.ps1          # menu
.\DinoDDayPatcher.ps1 -s       # status only
.\DinoDDayPatcher.ps1 -h       # help
```

If you'd rather not use a terminal, double-click **`DinoDDayPatcher.bat`**
instead. It launches the script with the execution policy bypassed for that
one process — nothing on your machine is changed. You do **not** need to run
`Set-ExecutionPolicy`.

Three patches:

- **Config tweaks** — writes a managed block to `dinodday\cfg\autoexec.cfg`:
  skip warmup rounds, download settings, show other players' sprays, a spray
  keybind, picking your own `cl_logofile`, a frame rate cap, an ambient light
  level that lifts the darkest parts of a map — optionally with the five
  preset levels bound to `F1`–`F5` so you can change it mid-match — and a
  brightness fix for Intel HD Graphics (mainly the 500 and 600 series), which
  render the game too dark. Each is individually toggleable, re-opening the
  menu loads your current settings back out of the block rather than starting
  from the defaults, and anything already in your `autoexec.cfg` outside the
  managed block is preserved.
- **Spray fix** — creates the directory junction that lets server-delivered
  sprays download and render.
- **Thread-count fix** — patches `bin\tier0.dll` to fix a crash on map load
  for CPUs with more than 28 threads.

> **The thread-count fix modifies a game DLL, and Dino D-Day has VAC
> enabled.** The community runs this patch widely without reported problems,
> but modifying game files carries a risk of a VAC ban. The script backs up
> the original and asks for explicit confirmation. Use at your own risk.

Close the game before running — the engine caches its file search paths at
startup.

### `spray-tools/spray_encode.py`

Turns an image into a ready-to-ship spray VTF.

```bash
python spray_encode.py mine.png mine.vtf --pack ./serverpack
python spray_encode.py submissions/*.png --pack ./serverpack
```

It decodes the image to raw pixels and writes a brand-new VTF from those —
nothing from the submitted file's container survives, so this is safe to run
on files from strangers (see the note below). It also tunes the file's
checksum so the engine's byte-order bug cancels out, meaning one file works
on both the server and the client instead of needing two copies under
different names.

`--pack` writes the correctly-named `.dat` for the server alongside the VTF.

Requires Pillow. No native texture library needed.

### `spray-tools/spray_check.py`

Structural validator for VTF files, and a `.dat` filename generator.

```bash
python spray_check.py somefile.vtf
python spray_check.py --pack ./serverpack sprays/*.vtf
```

Checks the header, dimensions, format and version, and — most usefully —
whether the declared mip chain matches the actual file size. That catches
truncated files and appended payloads, which is the cheapest way to smuggle
something through a file that still opens and renders fine everywhere else.

It re-derives everything from the header rather than trusting
`spray_encode.py`, so it can catch bugs in the encoder as well as in
submissions.

## How sprays work

Worth understanding before debugging anything, because the obvious mental
model is wrong.

**Sprays are sent by checksum, not by path.** When you press your spray key,
the game broadcasts a tiny message containing your player index and where you
sprayed — not the image. Each receiving client then looks up *your* spray by
its CRC in its own local cache. Having the same texture in your game folder
does nothing; only the checksum matters.

**The server acts as a file host.** Normally clients upload their spray on
connect and the server redistributes it. DinoTown keeps uploads disabled for
security and seeds approved sprays manually instead — the server hands out
whatever is sitting in its downloads folder regardless of how it got there.

**The engine's filenames look nothing like a checksum.** They're the bitwise
NOT of the file's CRC-32, written out byte-reversed. A file 7-Zip reports as
`3FAEC62E` becomes `d13951c0.dat`.

**Two bugs break delivery.** The server writes the file under one byte order
while the client looks for the other, and the file lands in a folder that
isn't the one the game converts from. The junction created by the patcher
fixes the second; the checksum tuning in `spray_encode.py` cancels the first.

**Caches never expire.** Received sprays are stored permanently. That's good
in normal use — you download each spray once, ever — but it means testing
changes requires clearing the caches first, or you'll see stale results.
Menu option 4 in the patcher does this.

## Getting your spray on the server

Contact a server admin on Steam or on Discord —
invite at http://dinotown.net/discord

NSFW, gore, or otherwise illegal content is not allowed in sprays.

Square PNGs are easiest to work with. Sprays are rendered at 256×256, so
anything non-square gets stretched.

## Notes for server operators

Keep `sv_allowupload 0`. Client uploads let anyone connecting write arbitrary
content into a directory the engine reads from and have the server
redistribute it to every other player — this was abused in the wild against
Source mods in 2015, and Valve changed the default to 0 in 2018. Seeding the
downloads folder by hand works just as well.

`sv_downloadurl` (fastdl) serves maps but not sprays; custom files always
travel in-band. Configure it anyway — in-band map transfers are very slow.

## Other tools

Nothing to do with sprays.

### `other-tools/bsp_audit.py`

Finds assets a map references but doesn't pack — and, more usefully, which of
those are packed in *another* map of the same rotation.

That second case is the one worth hunting. When a map unloads, the content it
packed goes with it, but a stale entry can survive in the engine. If a later
map references that same path and doesn't pack it either, it hits the
dangling entry and can crash. A player who joined after the earlier map had
already rotated through never had the entry at all, and just gets an error
texture instead. Same map, same rotation, two different symptoms depending on
when you joined — which is why it shows up as a map that's "sometimes
broken".

That mechanism is the working explanation for crashes seen on certain
rotations, not something that's been pinned down in a debugger. What is
certain is the input to it: a map referencing a path it doesn't pack while
another map in the rotation does. That's what this finds.

So **audit the whole rotation in one run.** The cross-map check only compares
the maps passed to a single invocation — audit a map on its own and it will
look clean.

```bash
python bsp_audit.py --game "D:\SteamLibrary\steamapps\common\Dino D-Day\dinodday" "D:\ddd-server\dinodday\maps"
python bsp_audit.py --custom selez maps\ddd_*_selez_*.bsp
```

Python 3.8+, standard library only — no dependencies. It reads maps and never
writes to them. The only thing it creates is the folder you ask for with
`--extract-fixes`.

Point `--game` at a clean client install rather than the server's own
`dinodday`, because the question being asked is what a *player* will be
missing. Folders named `download`, `downloads` and `custom` are left out of
the search paths deliberately — that's where stale copies of other servers'
content pile up, and mounting them hides the exact problem you're looking
for. Without `--game`, it looks for `gameinfo.txt` in the folders above the
first map; with no game content at all it can only report what it's certain
about.

#### What it reports

| Column | Meaning |
|---|---|
| `other-map` | Not packed here, but packed in another map of this run. The rotation crash. |
| `missing` | Not found anywhere. An error texture or model for everyone. |
| `loose-only` | Only present as loose files in a `--custom` folder on this machine. Players won't have them. |

Dino D-Day ships much of its content loose rather than in VPKs, so loose files
in the game folder count as stock by default. `--custom selez` declares that
`materials/selez/`, `models/selez/` and friends are *not* stock, so anything
found only there is reported instead of trusted. Use it for content a mapper
installed locally and might not have shipped.

There's also a cross-map conflict list: the same path packed with *different*
contents in several maps, where which version a player sees depends on which
map they loaded first. Expect this to be noisy if the folder holds several
versions of one map — v3, v4 and v5 are entitled to disagree about their own
materials. Audit what's actually in the rotation.

For every problem file the report says where the map uses it: world faces,
brush entities, overlays and static props with clustered coordinates, and
entities with their targetname, origin and hammerid. Coordinates are world
units, the same as in Hammer — `sv_cheats 1`, `noclip`, `setpos X Y Z` on a
local server to go and look. In Hammer, the texture browser's **Mark** button
selects every face using a material, and `hammerid` is the entity's id in the
VMF.

#### Options

- `--game DIR` — game folder containing `gameinfo.txt`.
- `--extra PATH` — extra stock content: a folder or a `_dir.vpk`. Repeatable.
- `--custom NAME` — a custom content folder name, as above. Repeatable.
- `--no-auto-game` — don't go looking for `gameinfo.txt` above the maps.
- `--extract-fixes DIR` — see below.
- `--brief` — skip the per-map detail; print the conflicts, the summary and
  the list of files to fix.
- `-v` — also list references it couldn't verify, and packed files that
  override stock content.

Exit status is `0` when clean, `1` when it found something and `2` when it
couldn't read any of the maps, so it drops into a pre-deploy check as-is.

#### Fixing what it finds

`--extract-fixes DIR` pulls every `other-map` and `loose-only` file out of
whichever map or folder does have it, writes them under `DIR/<map>/`, and
generates a `bspzip` addlist per map along with the command to run:

```
bspzip -addlist ddd_hilltop_selez_v6.bsp ddd_hilltop_selez_v6_addlist.txt ddd_hilltop_selez_v6_fixed.bsp
```

Paths inside the addlist are absolute, so it works from wherever you run it.
Anything under `missing` exists nowhere in the run, so it has to be tracked
down or remade by hand. **Ship the repacked map under a new name** — clients
cache maps by name, and anyone who already has the old one will carry on
using it.

#### Blind spots

It doesn't chase soundscript or soundscape names, particle systems (`.pcf`
files and particle manifests), materials referenced only from game code or
scripts, or model skins set from code. A clean report means nothing it can
see is missing, not that the map is complete.
