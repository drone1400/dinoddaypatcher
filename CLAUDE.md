# CLAUDE.md

Context for working on this repo. Read this before changing anything — it
records findings that took a long debugging session to establish and are not
discoverable from the code alone.

## What this project is

Tooling for running custom sprays on the DinoTown Dino D-Day server
(dinotown.net), plus a patcher that applies community fixes to a player's
game install.

Dino D-Day is a 2011 Source engine title (Steam app id **70000**, VAC
enabled). Its custom-file subsystem is bugged in two independent ways that
together make server-delivered sprays appear not to work at all. Both bugs
are fully characterised below and both are worked around.

## How sprays actually work

### Client-side

- `impulse 201` places a spray. `cl_logofile` points at the VTF to use.
- The stock default is `materials/vgui/logos/spray_bullseye.vtf`, **which
  does not exist in the shipped game files.** Sprays appear broken out of the
  box because of this, not because the feature is disabled.
- `cl_logofile` is read **at connect time**. Changing it mid-session has no
  effect until reconnect. This wastes a lot of time if you don't know it.
- Relevant cvars: `cl_playerspraydisable` (0 = show others' sprays),
  `cl_downloadfilter` (must be `all`), `cl_allowdownload`, `cl_allowupload`.

### Transmission model — the key insight

A spray is **not** sent as an image when someone sprays. `impulse 201`
broadcasts a `TE_PlayerDecal` temp entity containing a player index and a
surface position. Each receiving client then resolves that player's logo
**by CRC**, looked up in its own local cache.

Consequences that are easy to get wrong:

- The receiving client **never** looks at `materials/vgui/logos/`. Having the
  same VTF in your game folder does nothing. The CRC is the only key.
- Temp entities go only to players in PVS at the moment of the spray. Someone
  in another room never receives the message and will not see the decal later.
  This alone produces convincing "sometimes it works" behaviour.
- `decalfrequency` (server, default 10s) rate-limits spraying.

### The checksum naming scheme

Engine filenames are derived from the file's CRC-32, but written in a way
that does not look like CRC-32:

```
crc      = CRC-32 of the file bytes      e.g. 3FAEC62E   (what 7-Zip reports)
N        = ~crc  (bitwise NOT)                C05139D1   (a.k.a. JAMCRC)
filename = N written little-endian, hex       d13951c0
```

Valve's `CRC32_Final()` complements the register to produce the conventional
value; the naming path uses the register *before* that complement, then
writes the four bytes in memory order. Two transformations stacked, which is
why neither a byteswap nor a complement alone reproduces the name.

Verified against a real file: `averi.vtf`, CRC-32 `3FAEC62E`, engine filename
`d13951c0.dat`.

## The two bugs

### Bug 1 — inconsistent byte order

The **client requests** `downloads/<N-little-endian>.dat` while the
**server looks for** `downloads/<N-big-endian>.dat`. Two code paths, two
conventions, same CRC. Server log when it fails:

```
CreateFragmentsFromFile: 'downloads/c05139d1.dat' doesn't exist.
```

Workaround: keep both filenames on the server, **or** tune the file so the
two spellings are identical (see below).

### Bug 2 — wrong directory

The server delivers received files to `<gameroot>\dinodday\downloads\`, but
the step that converts `downloads\*.dat` into renderable
`materials\temp\*.vtf` only ever runs against `<gameroot>\update\downloads\`.
Files arrive correctly and are then ignored.

It also fails if the destination folder does not exist, logging
`Failed to write received file 'downloads/<name>.dat'!` on the client.

Workaround: a directory junction making the two paths the same.

### The combined fix

1. **Junction** `<root>\update\downloads` → `<root>\dinodday\downloads`.
   Delete the old `update\downloads` first. Game must be **closed** — the
   engine caches search paths at startup and will not notice a junction
   created while running.
2. **Tune the checksum** so `N` has the form `0xAABBBBAA`. Then big-endian
   and little-endian spellings are the same string and Bug 1 cancels.
   `spray_encode.py` does this by solving for four bytes of unused VTF header
   padding. CRC-32 is affine over GF(2), so it is a linear solve (33 hashes),
   not a search.

With both applied, server-driven delivery works end to end with no
per-file manual work.

## Paths and caching

Files are cached **twice**, and neither cache is ever pruned by the game:

```
<root>\dinodday\downloads\<N-big-endian>.dat     <- server writes here
<root>\update\downloads\<N-little-endian>.dat    <- conversion reads here
<root>\update\materials\temp\<name>.vtf          <- checked FIRST when rendering
<root>\dinodday\materials\temp\<name>.vtf        <- checked second
```

- `materials\temp` **persists forever**. A client that once received a spray
  keeps it with no further network involvement.
- **This will mislead you when testing.** Wipe both `materials\temp` folders
  and the `.dat` files before every test, or you will be looking at results
  from several iterations ago. `DinoDDayPatcher.ps1` option 4 does this.
- Server-side layout is the flat `<srcds>/dinodday/downloads/`, the older
  Source convention — *not* the newer `download/user_custom/XX/` used by
  TF2-era builds.

### Two-spray warmup

The conversion from `.dat` to `materials\temp` appears to run on receipt of a
decal message rather than on completion of the transfer. So the first spray
of a given image downloads the file, and a second spray is needed to convert
and render it. This is **once per spray per client, permanently** — after
that the temp cache serves it. Pre-seeding `materials\temp` avoids it
entirely.

## Server setup notes

- `sv_allowdownload 1` is needed. `sv_allowupload` should be **0** (see
  Security).
- Custom sprays travel **in-band over the netchannel**. `sv_downloadurl`
  (fastdl) serves maps but does **not** carry custom files. Confirmed by
  testing with the HTTP server both on and off.
- Fastdl is still worth configuring for maps — in-band map transfer is
  painfully slow. Serve from a directory that mirrors the mod structure
  (`maps/x.bsp`), not the mod folder itself, or you will serve `cfg\server.cfg`
  and its passwords to anyone who asks.
- IIS returns 404 for unknown extensions; `.bsp` is unknown. Use
  `python -m http.server`, `npx serve`, or Caddy instead.

## Security posture

**Do not validate submitted images — re-encode them.** Deciding whether
attacker-controlled bytes are safe is the problem we're avoiding. Decode to a
pixel buffer, write a brand-new VTF from those pixels. Nothing from the
submitted container survives.

- The decoder is then the only attack surface. Use Pillow or libvips, never
  ImageMagick (its delegate system invokes external programs based on file
  content — see ImageTragick). Pass an explicit `formats=` allowlist, lower
  `MAX_IMAGE_PIXELS`, cap the upload before decode, and run the decode in a
  sandboxed subprocess with resource limits — not in a web worker.
- `sv_allowupload 1` lets any connecting client write up to 512 KB of
  arbitrary content into a directory the engine reads from, and turns the
  server into a distribution point for it. This was abused in the wild in
  2015 against Source SDK 2013 mods (Fistful of Frags, Fortress Forever, No
  More Room in Hell, TF2 Classic). Valve defaulted `sv_allowupload` to 0 in
  2018. **Keep it 0** — seeding `downloads/` manually works regardless of how
  the file got there.
- Nothing prunes `downloads/`; filenames are content-derived, so an attacker
  can add a new file per connect. Disk exhaustion is cheap.

## VTF format facts

- Engine reads **version 7.2**. Newer (7.4/7.5) files will not load.
- Custom-file cap is **512 KB** (`MAX_CUSTOM_FILE_SIZE`). Files over it import
  fine locally but silently fail to transfer.
- Stock sprays are 256×256 DXT5, 85.6 KB each, with a paired `.vmt`. The VMT
  is **not** required for a custom spray to render — a VTF alone works
  (established by testing).
- 7.2 header is 80 bytes; every defined field ends by offset 65, leaving
  bytes 65–79 as zero padding. `spray_encode.py` patches four bytes at
  offset **68** for checksum tuning — inside `headerSize`, so image data and
  file size are untouched.
- 256×256 uncompressed BGRA8888 with a full mip chain is 349,732 bytes —
  under the cap, and needs no block compressor. This is why the encoder has
  no native dependencies.

## Repo contents

| File | Purpose |
|---|---|
| `spray_encode.py` | Image → clean, checksum-tuned VTF. Optional `--pack` writes the server `.dat`. The main pipeline tool. |
| `spraycheck.py` | Independent structural validator for VTFs, and `.dat` name generator. Re-derives expected size from the header rather than trusting the encoder — keep it independent so it can catch encoder bugs. |
| `DinoDDayPatcher.ps1` | Interactive Windows patcher: spray junction, `autoexec.cfg` tweaks, tier0 thread-count fix. |
| `DinoDDayPatcher.bat` | Double-click launcher for the above. Bypasses the execution policy for that one process so users never reach for `Set-ExecutionPolicy`. |

`vtf_encode.py` and `crc_tune.py` were merged into `spray_encode.py` and
should not reappear.

## DinoDDayPatcher.ps1 notes

- Detects the install via the `Steam App 70000` uninstall key, then Steam's
  registry root, then every library in `libraryfolders.vdf` reading
  `installdir` from `appmanifest_70000.acf`. Validated by checking for
  `dinodday\gameinfo.txt`.
- The **tier0.dll patch** fixes a crash on CPUs with more than 28 threads.
  The game spawns one IO thread per logical processor and overruns a buffer.
  The patch rewrites the tail of `GetCPUInformation` to clamp reported
  logical and physical counts to 0x18 (24).
  - Original SHA-256:
    `4ff85a018222c46a3e6b3eda81ef37e345f67ceac544551161aae5aa32f3ae8a`
  - Offset `0x2193`, replacing `C3 CC CC…` with
    `36 C6 40 05 18 36 C6 40 06 18 C3 90 90`
  - **The game has VAC enabled.** Modifying game DLLs carries ban risk. The
    script requires explicit confirmation and this must not be softened.
  - It refuses outright if the bytes at the offset are not the expected
    original, backs up first, and verifies after writing.
- Config tweaks are a list of hashtables from `New-TweakList`. `{0}` in a line
  is filled from that entry's `Arg`; `OptionalLines` are appended only when
  `Arg` is non-empty. `$AMBIENT_PRESETS` drives the level picker, the bind
  lines and the menu label, so levels get added there and nowhere else.
- Opening the tweak menu reads an existing managed block back into the toggles
  (`Read-ConfigBlock`), matching each option by a regex built from its first
  non-comment line. An option the block does not mention is treated as having
  been switched off, so the defaults in `New-TweakList` apply only when there is
  no block at all.
- Function keys are unbound in Dino D-Day by default, which is why the ambient
  light binds can claim `F1`-`F6` without asking.
- `mat_ambient_light_r/g/b` must always be written together and to the same
  value. Setting them independently tints the scene instead of brightening it.
- `Get-CimInstance Win32_Processor` is cached per session (slow). The tier0
  status check reads 13 bytes via FileStream rather than loading the whole
  DLL — do not revert that to `ReadAllBytes`.
- Removing the junction must use `[System.IO.Directory]::Delete($path, $false)`
  or `rmdir` without `/S`. `Remove-Item -Recurse` follows the junction and
  deletes the **target's** contents.

## Unverified — check before relying on

- **BGRA8888 sprays have never been confirmed to render in game.** Every
  stock spray is DXT5, and only a DXT5 file (`averi.vtf`) has been tested
  end to end. If `spray_encode.py` output does not render, this is the first
  suspect. Fallback is DXT5: Pillow can write DDS with DXT compression in
  recent versions and DDS uses the same block layout as VTF, so the block
  data can be repackaged without pulling in VTFLib.
- Related: the encoder sets flags `CLAMPS|CLAMPT|NOLOD|EIGHTBITALPHA`
  (`0x220C`) while `averi.vtf` has only `0x2000`. If rendering fails, try
  matching the stock flags.
- **`DinoDDayPatcher.ps1` is only partly exercised.** `-h` and `-s` run
  against a real install, and the config-tweak menu has been driven end to end
  (menu, value prompts, block writing, backup) against a scratch game root.
  The junction, cache-clearing and tier0 write paths have not been tested --
  treat those as a draft.
- **Whether `mat_ambient_light_r/g/b` are accepted on a live server.** Not
  checked against this build with `sv_cheats 0`. If the `F1`-`F5` binds do
  nothing online, they are cheat-flagged and the README should say the option
  is single-player only.
- Whether the junction works on first run with the game closed (during the
  session it required a game restart, attributed to cached search paths, but
  not isolated).
- Whether anything validates a received file's CRC against its filename.
  A palindromic name satisfies both spellings, so it should be moot.

## Working style

- Prefer proving a mechanism with an observation over inferring it. Most of
  the findings here came from Process Monitor, WinDbg and server logs, not
  from reasoning about what the engine "should" do.
- When testing spray behaviour, always wipe both caches first.
- Keep `spraycheck.py` independent of `spray_encode.py`.
