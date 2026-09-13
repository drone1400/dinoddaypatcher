# Dino D-Day spray tools

> ⚠️ **Work in progress — not yet fully tested.**
>
> These scripts are still undergoing testing and should be treated as
> pre-release. Back up anything you care about before running them, and don't
> rely on them working correctly yet. In particular, `DinoDDayPatcher.ps1`
> modifies files in your game install, including an optional patch to a game
> DLL. This notice will be removed once everything has been properly
> re-tested.

Tooling for custom player sprays on [DinoTown](http://dinotown.net), plus a
patcher that applies community fixes to a Dino D-Day install.

Dino D-Day supports Team Fortress–style sprays via `impulse 201`, but they
appear broken out of the box: the default `cl_logofile` points at a texture
that isn't in the shipped game files, and two bugs in the engine's
custom-file handling stop server-delivered sprays from ever rendering. These
scripts work around both.

## Scripts

### `DinoDDayPatcher.ps1`

Interactive Windows patcher. Run it with no arguments for a menu; it finds
your install through Steam automatically.

```powershell
.\DinoDDayPatcher.ps1          # menu
.\DinoDDayPatcher.ps1 -s       # status only
.\DinoDDayPatcher.ps1 -h       # help
```

Three patches:

- **Spray fix** — creates the directory junction that lets server-delivered
  sprays download and render.
- **Config tweaks** — writes a managed block to `dinodday\cfg\autoexec.cfg`:
  skip warmup rounds, brightness fix for dark rendering on some Intel
  systems, download settings, show other players' sprays, a spray keybind,
  and picking your own `cl_logofile`. Each is individually toggleable, and
  anything already in your `autoexec.cfg` outside the managed block is
  preserved.
- **Thread-count fix** — patches `bin\tier0.dll` to fix a crash on map load
  for CPUs with more than 28 threads.

> **The thread-count fix modifies a game DLL, and Dino D-Day has VAC
> enabled.** The community runs this patch widely without reported problems,
> but modifying game files carries a risk of a VAC ban. The script backs up
> the original and asks for explicit confirmation. Use at your own risk.

Close the game before running — the engine caches its file search paths at
startup.

### `spray_encode.py`

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

### `spraycheck.py`

Structural validator for VTF files, and a `.dat` filename generator.

```bash
python spraycheck.py somefile.vtf
python spraycheck.py --pack ./serverpack sprays/*.vtf
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
