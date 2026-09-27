#!/usr/bin/env python3
"""
bsp_audit.py - find assets a Source-engine map uses but doesn't pack.

Written for Dino D-Day custom maps, but it should work on most Source 1
BSPs (versions 19-21). Python 3.8+, standard library only.

What it collects for each map
  * world / brush-entity / overlay / displacement materials (texdata strings)
  * entity references: models, sprites, sounds, infodecals, projected
    textures, rope materials, skybox faces, the detail sprite material
  * static prop and detail prop models (game lumps)
  * recursively, for everything the map packs: VMT textures, Patch includes,
    $bottommaterial-style material references, model materials (searched
    through $cdmaterials like the engine does), .vvd / .dx90.vtx companions,
    .phy for models used by physics entities, and $includemodel

How each reference is resolved (the same order the game uses)
  1. the map's own pakfile
  2. stock game content: the search paths in gameinfo.txt, EXCLUDING the
     download/ and custom/ folders (that's where stale copies of other
     servers' and maps' content live, which would hide the problem)

What gets reported
  * NOT PACKED, BUT PACKED IN ANOTHER MAP of the same run. This is the
    hilltop crash: a player who loaded the other map earlier in the same
    game session still has a stale material entry and can crash; a player
    who didn't just sees an error texture. Audit every map in the rotation
    together so these show up.
  * NOT FOUND anywhere.
  * FOUND ONLY AS LOOSE FILES in a --custom folder of the game directory
    (e.g. materials/selez/ on the machine you ran this on). Players won't
    have these unless they got them some other way. Without --custom, loose
    files count as stock, since Dino D-Day ships much of its content loose.
  * The same path packed with different contents in several maps.

For every problem file it also says where the map uses it: world faces,
brush entities, overlays and static props with coordinates (grouped when
close together), and entities with their targetname, origin and hammerid.

Examples
  python bsp_audit.py --game "D:\\SteamLibrary\\steamapps\\common\\Dino D-Day\\dinodday" "D:\\ddd-server\\dinodday\\maps"
  python bsp_audit.py --custom selez maps\\ddd_*_selez_*.bsp
  python bsp_audit.py --extract-fixes fixes maps

If --game isn't given, the script looks for gameinfo.txt in the folders
above the first map. Without any game content it can't tell stock assets
from missing ones, so it only reports what it can be sure about.

--extract-fixes DIR copies every file a map is missing out of the other
map (or loose folder) that has it, and writes a bspzip addlist per map:
  bspzip -addlist ddd_hilltop_selez_v6.bsp ddd_hilltop_selez_v6_addlist.txt ddd_hilltop_selez_v7.bsp
Ship the result under a new map name; clients cache maps by name.

Known blind spots: soundscript names and soundscapes, particle systems
(.pcf / particle manifests), materials only referenced from game code or
scripts, and model skins set purely from code.
"""

import argparse
import glob
import io
import lzma
import os
import re
import struct
import sys
import zipfile
from collections import defaultdict, deque

LUMP_ENTITIES = 0
LUMP_TEXDATA = 2
LUMP_VERTEXES = 3
LUMP_TEXINFO = 6
LUMP_FACES = 7
LUMP_EDGES = 12
LUMP_SURFEDGES = 13
LUMP_MODELS = 14
LUMP_GAME_LUMP = 35
LUMP_PAKFILE = 40
LUMP_TEXDATA_STRING_DATA = 43
LUMP_TEXDATA_STRING_TABLE = 44
LUMP_OVERLAYS = 45
LUMP_FACES_HDR = 58

FACE_FMT = '<HBBihhhh4Bif5iHHI'      # dface_t, 56 bytes
OVERLAY_FMT = '<ihH64i4f12f3f3f'     # doverlay_t, 352 bytes

SOUND_PREFIX_CHARS = '*#@<>^)(}$!?&~`+%'
SKY_SUFFIXES = ('bk', 'dn', 'ft', 'lf', 'rt', 'up')
EXCLUDED_MOUNT_DIRS = ('download', 'downloads', 'custom')


# --------------------------------------------------------------------------
# small helpers

def norm(p):
    """Normalise a game path the way Source compares them."""
    p = p.replace('\\', '/').strip().lower()
    p = re.sub(r'/+', '/', p)
    while p.startswith('./'):
        p = p[2:]
    return p.strip('/')


def unlzma(data):
    """Source 2013 lumps can be LZMA-compressed behind a 17-byte Valve header."""
    if len(data) >= 17 and data[:4] == b'LZMA':
        actual, packed = struct.unpack_from('<II', data, 4)
        raw = data[12:17] + struct.pack('<Q', actual) + data[17:17 + packed]
        return lzma.decompress(raw, format=lzma.FORMAT_ALONE)
    return data


def cstr(data, ofs, limit=512):
    if ofs < 0 or ofs >= len(data):
        return ''
    end = data.find(b'\0', ofs, ofs + limit)
    if end < 0:
        end = min(len(data), ofs + limit)
    return data[ofs:end].decode('latin-1')


def material_path(v):
    v = norm(v)
    if v.startswith('materials/'):
        v = v[len('materials/'):]
    for ext in ('.vmt', '.spr'):
        if v.endswith(ext):
            v = v[:-len(ext)]
    return 'materials/' + v + '.vmt'


def texture_path(v):
    v = norm(v)
    if v.startswith('materials/'):
        v = v[len('materials/'):]
    if v.endswith('.vtf'):
        v = v[:-4]
    return 'materials/' + v + '.vtf'


def sound_path(v):
    v = norm(v.strip().lstrip(SOUND_PREFIX_CHARS))
    return v if v.startswith('sound/') else 'sound/' + v


def model_path(v):
    v = norm(v)
    return v if v.startswith('models/') else 'models/' + v


def looks_like_path(v):
    if not v or v[0] in '$[{_' or any(c.isspace() for c in v):
        return False
    if v.lower() == 'env_cubemap':
        return False
    try:
        float(v)
        return False
    except ValueError:
        pass
    return any(c.isalpha() for c in v)


TEXTURE_KEY = re.compile(r'(texture|map|mask|masks|detail|iris)\d?$')
MATERIAL_KEY = re.compile(r'(material|overlay)\d?$')


def parse_vec(s):
    try:
        v = [float(x) for x in (s or '').split()]
        return tuple(v) if len(v) == 3 else (0.0, 0.0, 0.0)
    except ValueError:
        return (0.0, 0.0, 0.0)


def fmt_vec(v):
    return '(%d %d %d)' % tuple(int(round(c)) for c in v)


def entity_label(d):
    """d: lower-cased keyvalues of one entity."""
    s = d.get('classname', '?')
    if d.get('targetname'):
        s += " '%s'" % d['targetname']
    if d.get('origin'):
        s += ' @ ' + fmt_vec(parse_vec(d['origin']))
    if d.get('hammerid'):
        s += ' [hammerid %s]' % d['hammerid']
    return s


def cluster(points, radius=512.0):
    """Group points that lie within radius of a group's centre.
    Returns [(centre, count)], biggest group first."""
    groups = []                        # [count, sx, sy, sz]
    r2 = radius * radius
    for pt in points:
        for g in groups:
            c = (g[1] / g[0], g[2] / g[0], g[3] / g[0])
            if sum((a - b) ** 2 for a, b in zip(pt, c)) <= r2:
                g[0] += 1
                g[1] += pt[0]
                g[2] += pt[1]
                g[3] += pt[2]
                break
        else:
            groups.append([1, pt[0], pt[1], pt[2]])
    out = [((g[1] / g[0], g[2] / g[0], g[3] / g[0]), g[0]) for g in groups]
    out.sort(key=lambda t: -t[1])
    return out


def is_physics_class(cls):
    return 'physics' in cls or cls.startswith('prop_ragdoll') or cls == 'prop_sphere'


class SubFile(io.RawIOBase):
    """A read-only window onto part of a file, so zipfile can read the pak
    lump without loading whole BSPs into memory."""

    def __init__(self, path, offset, length):
        super().__init__()
        self._f = open(path, 'rb')
        self._off = offset
        self._len = length
        self._pos = 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self._pos

    def seek(self, pos, whence=0):
        if whence == 0:
            new = pos
        elif whence == 1:
            new = self._pos + pos
        else:
            new = self._len + pos
        if new < 0:
            raise OSError('negative seek')
        self._pos = new
        return new

    def readinto(self, b):
        n = max(0, min(len(b), self._len - self._pos))
        if n == 0:
            return 0
        self._f.seek(self._off + self._pos)
        data = self._f.read(n)
        b[:len(data)] = data
        self._pos += len(data)
        return len(data)

    def close(self):
        try:
            self._f.close()
        finally:
            super().close()


# --------------------------------------------------------------------------
# KeyValues (VMT / gameinfo.txt)

def kv_tokenize(text):
    toks = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
            continue
        if text.startswith('//', i):
            j = text.find('\n', i)
            i = n if j < 0 else j
            continue
        if c in '{}':
            toks.append((c, False))
            i += 1
            continue
        if c == '"':
            j = text.find('"', i + 1)
            if j < 0:
                j = n
            toks.append((text[i + 1:j], True))
            i = j + 1
            continue
        j = i
        while j < n and not text[j].isspace() and text[j] not in '{}"':
            j += 1
        toks.append((text[i:j], False))
        i = j
    # drop platform conditionals like [$WIN32]
    return [t for t in toks if t[1] or not (t[0].startswith('[') and t[0].endswith(']'))]


def kv_parse(text):
    """Returns a nested list of (key, value-or-list)."""
    toks = kv_tokenize(text)
    pos = 0

    def block():
        nonlocal pos
        items = []
        while pos < len(toks):
            tok, quoted = toks[pos]
            if not quoted and tok == '}':
                pos += 1
                return items
            if not quoted and tok == '{':
                pos += 1
                items.append(('', block()))
                continue
            pos += 1
            if pos >= len(toks):
                break
            nxt, nq = toks[pos]
            if not nq and nxt == '{':
                pos += 1
                items.append((tok, block()))
            elif not nq and nxt == '}':
                continue
            else:
                pos += 1
                items.append((tok, nxt))
        return items

    return block()


def kv_walk(items):
    for k, v in items:
        if isinstance(v, list):
            yield from kv_walk(v)
        else:
            yield k, v


def kv_find_block(items, name):
    for k, v in items:
        if isinstance(v, list):
            if k.lower() == name:
                return v
            found = kv_find_block(v, name)
            if found is not None:
                return found
    return None


# --------------------------------------------------------------------------
# BSP

class Bsp:
    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path)
        self.size = os.path.getsize(path)
        with open(path, 'rb') as f:
            hdr = f.read(8 + 64 * 16 + 4)
        if len(hdr) < 8 + 64 * 16:
            raise ValueError('file too small to be a BSP')
        ident, self.version = struct.unpack_from('<4si', hdr, 0)
        if ident != b'VBSP':
            raise ValueError('not a VBSP file')
        raw = [struct.unpack_from('<iii4s', hdr, 8 + i * 16) for i in range(64)]

        def valid(lumps):
            return all(ln == 0 or (ofs >= 0 and ln > 0 and ofs + ln <= self.size)
                       for ofs, ln in lumps)

        standard = [(a, b) for a, b, c, d in raw]
        l4d2 = [(b, c) for a, b, c, d in raw]   # version, fileofs, filelen
        if valid(standard):
            self.lumps = standard
        elif valid(l4d2):
            self.lumps = l4d2
        else:
            raise ValueError('lump directory looks corrupt')
        self._pak = None
        self._zip = None
        self.pak_error = None
        self._entities = None
        self._game_lumps = None
        self._surfaces = None
        self._props = None
        self._brush_ents = None

    def read_at(self, ofs, ln):
        if ln <= 0 or ofs < 0:
            return b''
        with open(self.path, 'rb') as f:
            f.seek(ofs)
            return f.read(ln)

    def lump(self, idx):
        ofs, ln = self.lumps[idx]
        return unlzma(self.read_at(ofs, ln))

    def texture_names(self):
        sd = self.lump(LUMP_TEXDATA_STRING_DATA)
        st = self.lump(LUMP_TEXDATA_STRING_TABLE)
        names = []
        for (o,) in struct.iter_unpack('<i', st[:len(st) // 4 * 4]):
            names.append(cstr(sd, o, 1024) if 0 <= o < len(sd) else '')
        return names

    def entities(self):
        if self._entities is not None:
            return self._entities
        text = self.lump(LUMP_ENTITIES).decode('latin-1', 'replace')
        ents, cur, pending = [], None, None
        for m in re.finditer(r'"([^"]*)"|([{}])', text):
            if m.group(2) == '{':
                cur, pending = [], None
            elif m.group(2) == '}':
                if cur is not None:
                    ents.append(cur)
                cur, pending = None, None
            elif cur is not None:
                if pending is None:
                    pending = m.group(1)
                else:
                    cur.append((pending, m.group(1)))
                    pending = None
        self._entities = ents
        return ents

    def game_lumps(self):
        if self._game_lumps is not None:
            return self._game_lumps
        data = self.lump(LUMP_GAME_LUMP)
        out = {}
        self._game_lumps = out
        if len(data) < 4:
            return out
        (count,) = struct.unpack_from('<i', data, 0)
        for i in range(max(0, min(count, 128))):
            base = 4 + i * 16
            if base + 16 > len(data):
                break
            gid, flags, ver, ofs, ln = struct.unpack_from('<iHHii', data, base)
            name = struct.pack('>i', gid).decode('latin-1')
            blob = self.read_at(ofs, ln)
            if (flags & 1) or blob[:4] == b'LZMA':
                try:
                    blob = unlzma(blob)
                except Exception:
                    blob = b''
            out[name] = (ver, blob)
        return out

    def prop_models(self):
        """(kind, model) from the static prop and detail prop dictionaries."""
        out = []
        gl = self.game_lumps()
        for key, kind in (('sprp', 'static prop'), ('dprp', 'detail prop')):
            if key not in gl:
                continue
            blob = gl[key][1]
            if len(blob) < 4:
                continue
            (n,) = struct.unpack_from('<i', blob, 0)
            if 0 <= n <= 65536 and 4 + n * 128 <= len(blob):
                for i in range(n):
                    name = cstr(blob, 4 + i * 128, 128)
                    if name:
                        out.append((kind, name))
        return out

    # locations ---------------------------------------------------------
    def _array(self, idx, fmt):
        data = self.lump(idx)
        size = struct.calcsize(fmt)
        return list(struct.iter_unpack(fmt, data[:len(data) // size * size]))

    def surface_index(self):
        """texture name -> [(model index, centre, is_displacement)]; model -1 = overlay.
        Brush-entity faces are in the entity's local space."""
        if self._surfaces is not None:
            return self._surfaces
        idx = defaultdict(list)
        self._surfaces = idx
        try:
            names = self.texture_names()
            texdata = self._array(LUMP_TEXDATA, '<3f5i')
            texinfo = self._array(LUMP_TEXINFO, '<16f2i')
            verts = self._array(LUMP_VERTEXES, '<3f')
            edges = self._array(LUMP_EDGES, '<HH')
            surfedges = [x for (x,) in self._array(LUMP_SURFEDGES, '<i')]
            faces = self._array(LUMP_FACES, FACE_FMT) or self._array(LUMP_FACES_HDR, FACE_FMT)
            models = self._array(LUMP_MODELS, '<9f3i')
            overlays = self._array(LUMP_OVERLAYS, OVERLAY_FMT)
        except Exception:
            return idx

        def name_of(ti):
            if not 0 <= ti < len(texinfo):
                return None
            td = texinfo[ti][17]
            if not 0 <= td < len(texdata):
                return None
            sid = texdata[td][3]
            return norm(names[sid]) if 0 <= sid < len(names) else None

        face_model = [0] * len(faces)
        for m, mod in enumerate(models):
            first, num = mod[10], mod[11]
            for fi in range(max(0, first), min(len(faces), first + num)):
                face_model[fi] = m

        for fi, f in enumerate(faces):
            name = name_of(f[5])
            if not name:
                continue
            xs = ys = zs = 0.0
            n = 0
            for k in range(f[3], f[3] + f[4]):
                if not 0 <= k < len(surfedges):
                    break
                se = surfedges[k]
                if abs(se) >= len(edges):
                    break
                v = edges[abs(se)][0 if se >= 0 else 1]
                if v >= len(verts):
                    break
                x, y, z = verts[v]
                xs += x
                ys += y
                zs += z
                n += 1
            if n:
                idx[name].append((face_model[fi], (xs / n, ys / n, zs / n), f[6] != -1))

        for o in overlays:
            name = name_of(o[1])
            if name:
                idx[name].append((-1, (o[83], o[84], o[85]), False))
        return idx

    def brush_entities(self):
        """brush model index -> (entity label, entity origin)"""
        if self._brush_ents is None:
            self._brush_ents = {}
            for ent in self.entities():
                d = {}
                for k, v in ent:
                    d.setdefault(k.lower(), v)
                m = d.get('model', '')
                if m.startswith('*') and m[1:].isdigit():
                    self._brush_ents[int(m[1:])] = (entity_label(d), parse_vec(d.get('origin')))
        return self._brush_ents

    def static_prop_instances(self):
        """model path -> [origin] for placed static props"""
        if self._props is not None:
            return self._props
        out = defaultdict(list)
        self._props = out
        gl = self.game_lumps()
        if 'sprp' not in gl:
            return out
        blob = gl['sprp'][1]
        try:
            (n,) = struct.unpack_from('<i', blob, 0)
            pos = 4
            names = [cstr(blob, pos + i * 128, 128) for i in range(n)]
            pos += n * 128
            (nleaf,) = struct.unpack_from('<i', blob, pos)
            pos += 4 + nleaf * 2
            (count,) = struct.unpack_from('<i', blob, pos)
            pos += 4
            if count <= 0:
                return out
            stride = (len(blob) - pos) // count
            if stride < 26:
                return out
            for i in range(count):
                b = pos + i * stride
                origin = struct.unpack_from('<3f', blob, b)
                (t,) = struct.unpack_from('<H', blob, b + 24)
                if t < len(names):
                    out[model_path(names[t])].append(origin)
        except struct.error:
            pass
        return out

    def describe_surfaces(self, name):
        entries = self.surface_index().get(name, [])
        by_model = defaultdict(list)
        for m, centre, disp in entries:
            by_model[m].append((centre, disp))
        lines = []
        for m in sorted(by_model):
            items = by_model[m]
            if m == -1:
                spots = ', '.join(fmt_vec(c) for c, _ in items[:4])
                more = ' (+%d more)' % (len(items) - 4) if len(items) > 4 else ''
                lines.append('overlay%s at %s%s' % ('s' if len(items) > 1 else '', spots, more))
                continue
            offset, where = (0.0, 0.0, 0.0), 'world brushes'
            if m > 0:
                where, offset = self.brush_entities().get(m, ('brush entity *%d' % m, (0.0, 0.0, 0.0)))
            pts = [(c[0] + offset[0], c[1] + offset[1], c[2] + offset[2]) for c, _ in items]
            what = '%d face%s' % (len(items), 's' if len(items) != 1 else '')
            ndisp = sum(1 for _, d in items if d)
            if ndisp:
                what += ' (%d displacement)' % ndisp
            groups = cluster(pts)
            spots = ', '.join(fmt_vec(c) + (' x%d' % k if k > 1 else '') for c, k in groups[:3])
            more = ' ...' if len(groups) > 3 else ''
            lines.append('%s: %s around %s%s' % (where, what, spots, more))
        return lines

    def pak(self):
        if self._pak is None:
            self._pak = {}
            ofs, ln = self.lumps[LUMP_PAKFILE]
            if ln > 0:
                try:
                    self._zip = zipfile.ZipFile(io.BufferedReader(SubFile(self.path, ofs, ln)))
                    for zi in self._zip.infolist():
                        if not zi.filename.endswith('/'):
                            self._pak[norm(zi.filename)] = zi
                except Exception as e:
                    self.pak_error = str(e)
        return self._pak

    def read_packed(self, path):
        zi = self.pak().get(path)
        if zi is None or self._zip is None:
            return None
        try:
            return self._zip.read(zi)
        except Exception:
            return None


# --------------------------------------------------------------------------
# stock game content

class Vpk:
    """Directory reader only; we need names and CRCs, not file data."""

    def __init__(self, dir_path):
        self.path = dir_path
        self.entries = {}
        with open(dir_path, 'rb') as f:
            data = f.read()
        sig, ver, tree = struct.unpack_from('<III', data, 0)
        if sig != 0x55AA1234 or ver not in (1, 2):
            raise ValueError('unsupported VPK')
        pos = 12 if ver == 1 else 28

        def rstr():
            nonlocal pos
            end = data.index(b'\0', pos)
            s = data[pos:end].decode('latin-1')
            pos = end + 1
            return s

        while True:
            ext = rstr()
            if not ext:
                break
            while True:
                folder = rstr()
                if not folder:
                    break
                while True:
                    fname = rstr()
                    if not fname:
                        break
                    crc, preload = struct.unpack_from('<IH', data, pos)
                    pos += 18 + preload
                    full = fname if ext == ' ' else fname + '.' + ext
                    if folder != ' ':
                        full = folder + '/' + full
                    self.entries[norm(full)] = crc


class GameContent:
    SUBDIRS = ('materials', 'models', 'sound', 'particles')

    def __init__(self):
        self.files = {}        # path -> ('vpk', vpk path, crc) | ('loose', full path, None)
        self.mounted = []      # (description, file count)
        self._seen = set()

    def add_dir(self, d):
        d = os.path.abspath(d)
        key = ('dir', d.lower())
        if key in self._seen or not os.path.isdir(d):
            return
        self._seen.add(key)
        count = 0
        for sub in self.SUBDIRS:
            for dirpath, _, filenames in os.walk(os.path.join(d, sub)):
                for fn in filenames:
                    full = os.path.join(dirpath, fn)
                    rel = norm(os.path.relpath(full, d))
                    if rel not in self.files:
                        self.files[rel] = ('loose', full, None)
                        count += 1
        self.mounted.append(('loose files in ' + d, count))
        for vpk in sorted(glob.glob(os.path.join(d, '*_dir.vpk'))):
            self.add_vpk(vpk)

    def add_vpk(self, path):
        path = os.path.abspath(path)
        key = ('vpk', path.lower())
        if key in self._seen or not os.path.isfile(path):
            return
        self._seen.add(key)
        try:
            v = Vpk(path)
        except Exception as e:
            self.mounted.append(('UNREADABLE %s (%s)' % (path, e), 0))
            return
        count = 0
        for p, crc in v.entries.items():
            if p not in self.files:
                self.files[p] = ('vpk', path, crc)
                count += 1
        self.mounted.append((path, count))

    def add_path(self, p):
        if p.lower().endswith('.vpk'):
            if not p.lower().endswith('_dir.vpk'):
                p = p[:-4] + '_dir.vpk'
            self.add_vpk(p)
        else:
            self.add_dir(p)

    def mount_game(self, game_dir):
        game_dir = os.path.abspath(game_dir)
        root = os.path.dirname(game_dir)
        gi = os.path.join(game_dir, 'gameinfo.txt')
        search = None
        if os.path.isfile(gi):
            with open(gi, 'r', encoding='latin-1') as f:
                search = kv_find_block(kv_parse(f.read()), 'searchpaths')
        if not search:
            self.add_dir(game_dir)
            return
        for key, val in search:
            if isinstance(val, list):
                continue
            kinds = set(key.lower().split('+'))
            if not kinds & {'game', 'mod', 'platform'}:
                continue
            p = val.replace('|gameinfo_path|', game_dir + os.sep)
            p = p.replace('|all_source_engine_paths|', root + os.sep)
            if p.endswith('*'):
                continue                       # custom/* style folders
            if not os.path.isabs(p):
                p = os.path.join(root, p)
            p = os.path.normpath(p)
            if os.path.basename(p).lower() in EXCLUDED_MOUNT_DIRS:
                continue
            self.add_path(p)


# --------------------------------------------------------------------------
# audit

class Context:
    def __init__(self, bsps, game, has_game, custom):
        self.bsps = bsps
        self.game = game
        self.has_game = has_game
        self.custom = {c.strip('/\\').lower() for c in custom if c.strip('/\\')}
        self.pak_owners = defaultdict(list)
        for b in bsps:
            for p in b.pak():
                self.pak_owners[p].append(b)

    def is_custom(self, path):
        """True for paths under a --custom folder, e.g. materials/selez/..."""
        parts = path.split('/')
        return len(parts) > 2 and parts[1] in self.custom


class MapAudit:
    def __init__(self, bsp, ctx):
        self.bsp = bsp
        self.ctx = ctx
        self.refs = {}          # path -> [reasons (max 3), total count]
        self.status = {}        # path -> (kind, info)
        self.queue = deque()
        self.physics_models = set()
        self.parents = defaultdict(set)   # path -> assets that reference it
        self.roots = defaultdict(set)     # path -> ('tex', name) | ('ent', label) | ('sprp', model)

    # references ---------------------------------------------------------
    def ref(self, path, why, parent=None, root=None):
        path = norm(path)
        if not path:
            return
        if parent:
            self.parents[path].add(parent)
        if root:
            self.roots[path].add(root)
        entry = self.refs.get(path)
        if entry is None:
            self.refs[path] = [[why], 1]
            self.queue.append(path)
        else:
            entry[1] += 1
            if len(entry[0]) < 3 and why not in entry[0]:
                entry[0].append(why)

    def ref_any(self, candidates, why, parent=None):
        """A model texture: the engine uses the first $cdmaterials hit."""
        candidates = list(dict.fromkeys(candidates))
        for wanted in (('pak', 'stock', 'loose'), ('other',)):
            for c in candidates:
                if self.locate(c)[0] in wanted:
                    self.ref(c, why, parent=parent)
                    return
        extra = len(candidates) - 1
        self.ref(candidates[0], why + (' (also searched %d other $cdmaterials dir(s))' % extra if extra else ''),
                 parent=parent)

    def locate(self, path):
        if path in self.bsp.pak():
            return 'pak', None
        g = self.ctx.game.files.get(path)
        if g:
            return ('loose' if g[0] == 'loose' else 'stock'), g
        others = [b for b in self.ctx.pak_owners.get(path, []) if b is not self.bsp]
        if others:
            return 'other', others
        return 'missing', None

    # seeding -------------------------------------------------------------
    def seed(self):
        for name in self.bsp.texture_names():
            if name:
                self.ref(material_path(name), 'brush/overlay/displacement texture',
                         root=('tex', norm(name)))

        for ent in self.bsp.entities():
            d = {}
            for k, v in ent:
                d.setdefault(k.lower(), v)
            cls = d.get('classname', '?').lower()
            label = entity_label(d)
            root = ('ent', label)

            if cls == 'worldspawn':
                sky = d.get('skyname', '').strip()
                if sky:
                    for s in SKY_SUFFIXES:
                        self.ref(material_path('skybox/' + sky + s), 'worldspawn skyname', root=root)
                dm = d.get('detailmaterial', '').strip()
                if dm:
                    self.ref(material_path(dm), 'worldspawn detailmaterial', root=root)

            for k, v in ent:
                kl, v = k.lower(), v.strip()
                if not v or '\x1b' in v or v.count(',') >= 2:     # skip outputs
                    continue
                ext = os.path.splitext(v.lower())[1]
                if ext == '.mdl':
                    p = model_path(v)
                    self.ref(p, label, root=root)
                    if is_physics_class(cls):
                        self.physics_models.add(p)
                elif ext in ('.vmt', '.spr'):
                    self.ref(material_path(v), label, root=root)
                elif ext == '.vtf':
                    self.ref(texture_path(v), label, root=root)
                elif ext in ('.wav', '.mp3', '.ogg'):
                    self.ref(sound_path(v), label, root=root)
                elif kl == 'texture' and cls == 'infodecal':
                    self.ref(material_path(v), label, root=root)
                elif kl == 'material' and cls.startswith('info_overlay'):
                    self.ref(material_path(v), label, root=root)
                elif kl == 'texturename' and cls == 'env_projectedtexture':
                    self.ref(texture_path(v), label, root=root)
                elif kl == 'ropematerial':
                    self.ref(material_path(v), label, root=root)

        for kind, name in self.bsp.prop_models():
            mp = model_path(name)
            self.ref(mp, kind, root=('sprp', mp) if kind == 'static prop' else None)

    # expansion -----------------------------------------------------------
    def expand_vmt(self, p, data):
        items = kv_parse(data.decode('latin-1', 'replace'))
        for k, v in kv_walk(items):
            kl, v = k.lower(), v.strip()
            if kl.startswith('%'):
                continue                       # compile-time only
            if kl == 'include':
                inc = norm(v)
                if not inc.endswith('.vmt'):
                    inc += '.vmt'
                if not inc.startswith('materials/'):
                    inc = 'materials/' + inc
                self.ref(inc, p + ' (Patch include)', parent=p)
                continue
            if not kl.startswith('$') or not looks_like_path(v):
                continue
            if MATERIAL_KEY.search(kl):
                self.ref(material_path(v), '%s %s' % (p, k), parent=p)
            elif TEXTURE_KEY.search(kl):
                self.ref(texture_path(v), '%s %s' % (p, k), parent=p)

    def expand_mdl(self, p, data):
        base = p[:-4]
        self.ref(base + '.vvd', p, parent=p)
        self.ref(base + '.dx90.vtx', p, parent=p)
        if p in self.physics_models:
            self.ref(base + '.phy', p + ' (used by a physics entity)', parent=p)
        if len(data) < 344 or data[:4] != b'IDST':
            return
        numtex, texidx, numcd, cdidx = struct.unpack_from('<iiii', data, 204)
        if not (0 <= numtex <= 1024 and 0 <= numcd <= 64):
            return
        cds = []
        for i in range(numcd):
            o = cdidx + i * 4
            if o + 4 > len(data):
                break
            cds.append(norm(cstr(data, struct.unpack_from('<i', data, o)[0])))
        cds = cds or ['']
        for i in range(numtex):
            t = texidx + i * 64
            if t + 4 > len(data):
                break
            (nameofs,) = struct.unpack_from('<i', data, t)
            tex = norm(cstr(data, t + nameofs))
            if tex:
                cands = [material_path(cd + '/' + tex if cd else tex) for cd in cds]
                self.ref_any(cands, "%s texture '%s'" % (p, tex), parent=p)
        numinc, incidx = struct.unpack_from('<ii', data, 336)
        if 0 < numinc <= 64:
            for i in range(numinc):
                g = incidx + i * 8
                if g + 8 > len(data):
                    break
                (nameofs,) = struct.unpack_from('<i', data, g + 4)
                inc = cstr(data, g + nameofs)
                if inc.lower().endswith('.mdl') and all(32 <= ord(c) < 127 for c in inc):
                    self.ref(model_path(inc), p + ' $includemodel', parent=p)

    def read_content(self, path, kind, info):
        if kind == 'pak':
            return self.bsp.read_packed(path)
        if kind == 'other':
            for b in info:
                data = b.read_packed(path)
                if data is not None:
                    return data
        if kind == 'loose' and self.ctx.is_custom(path):
            try:
                with open(info[1], 'rb') as f:
                    return f.read()
            except OSError:
                return None
        return None                            # stock: don't recurse

    def run(self):
        self.seed()
        while self.queue:
            p = self.queue.popleft()
            kind, info = self.locate(p)
            self.status[p] = (kind, info)
            if not p.endswith(('.vmt', '.mdl')):
                continue
            data = self.read_content(p, kind, info)
            if data is None:
                continue
            if p.endswith('.vmt'):
                self.expand_vmt(p, data)
            else:
                self.expand_mdl(p, data)

    # results -------------------------------------------------------------
    def classify(self):
        other, missing, loose, unverified = [], [], [], []
        for p in sorted(self.status):
            kind, info = self.status[p]
            if kind == 'other':
                other.append((p, info))
            elif kind == 'missing':
                if self.ctx.has_game or self.ctx.is_custom(p):
                    missing.append(p)
                else:
                    unverified.append(p)
            elif kind == 'loose' and self.ctx.is_custom(p):
                loose.append((p, info))
        return other, missing, loose, unverified

    def where_lines(self, p, limit=8):
        """Where in the map the things that (eventually) use p are placed."""
        found, seen, stack = [], {p}, [(p, True)]
        while stack:
            cur, direct = stack.pop()
            for r in sorted(self.roots.get(cur, ())):
                found.append((r, direct))
            for par in sorted(self.parents.get(cur, ())):
                if par not in seen and len(seen) < 500:
                    seen.add(par)
                    stack.append((par, False))
        lines, done = [], set()
        for (kind, val), direct in found:
            if (kind, val) in done:
                continue
            done.add((kind, val))
            if kind == 'tex':
                lines += self.bsp.describe_surfaces(val)
            elif kind == 'sprp':
                origins = self.bsp.static_prop_instances().get(val, [])
                if origins:
                    spots = ', '.join(fmt_vec(c) + (' x%d' % k if k > 1 else '')
                                      for c, k in cluster(origins, 256.0)[:3])
                    lines.append('%s: %d static prop%s around %s'
                                 % (val, len(origins), 's' if len(origins) != 1 else '', spots))
            elif kind == 'ent' and not direct:
                lines.append('entity ' + val)
        if len(lines) > limit:
            lines = lines[:limit] + ['(+%d more places)' % (len(lines) - limit)]
        return lines

    def used_by(self, p):
        reasons, total = self.refs[p]
        s = '; '.join(reasons)
        if total > len(reasons):
            s += ' (+%d more)' % (total - len(reasons))
        return s


# --------------------------------------------------------------------------
# output

def expand_inputs(args):
    out = []
    for a in args:
        if os.path.isdir(a):
            out += sorted(glob.glob(os.path.join(a, '*.bsp')))
        elif any(ch in a for ch in '*?['):
            out += sorted(glob.glob(a))
        else:
            out.append(a)
    seen, res = set(), []
    for p in out:
        ap = os.path.abspath(p).lower()
        if ap not in seen:
            seen.add(ap)
            res.append(p)
    return res


def find_game_dir(start):
    d = os.path.dirname(os.path.abspath(start))
    for _ in range(6):
        if os.path.isfile(os.path.join(d, 'gameinfo.txt')):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def print_where(a, p, indent):
    lines = a.where_lines(p)
    for i, line in enumerate(lines):
        print('%s%s%s' % (indent, 'where:     ' if i == 0 else ' ' * 11, line))


def main():
    ap = argparse.ArgumentParser(
        description="Find assets Source maps use but don't pack.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split('Examples', 1)[1].split('Known blind', 1)[0])
    ap.add_argument('maps', nargs='+', help='.bsp files, folders of .bsp files, or wildcards')
    ap.add_argument('--game', help='game folder containing gameinfo.txt (e.g. ...\\Dino D-Day\\dinodday)')
    ap.add_argument('--extra', action='append', default=[],
                    help='extra stock content: a folder or a _dir.vpk (repeatable)')
    ap.add_argument('--custom', action='append', default=[], metavar='FOLDER',
                    help='a custom content folder name, e.g. selez for materials/selez/, models/selez/ '
                         '(repeatable). Loose files in these folders are reported instead of '
                         'being treated as stock.')
    ap.add_argument('--no-auto-game', action='store_true',
                    help="don't look for gameinfo.txt above the maps")
    ap.add_argument('--extract-fixes', metavar='DIR',
                    help='copy the missing files out of the maps/folders that have them, plus bspzip addlists')
    ap.add_argument('--brief', action='store_true',
                    help='skip the long per-map sections; print conflicts, the summary and the files to fix')
    ap.add_argument('-v', '--verbose', action='store_true',
                    help='also list unverifiable references and packed files that override stock content')
    args = ap.parse_args()

    try:
        sys.stdout.reconfigure(errors='replace')
    except Exception:
        pass

    paths = expand_inputs(args.maps)
    bsps = []
    for p in paths:
        try:
            bsps.append(Bsp(p))
        except Exception as e:
            print('skipping %s: %s' % (p, e), file=sys.stderr)
    if not bsps:
        print('no readable .bsp files given', file=sys.stderr)
        return 2

    game = GameContent()
    game_dir = args.game
    if not game_dir and not args.no_auto_game:
        game_dir = find_game_dir(paths[0])
    if game_dir:
        print('Indexing game content from %s ...' % game_dir, file=sys.stderr)
        game.mount_game(game_dir)
    for x in args.extra:
        game.add_path(x)
    has_game = bool(game.files)

    ctx = Context(bsps, game, has_game, args.custom)
    audits = []
    for b in bsps:
        print('Auditing %s ...' % b.name, file=sys.stderr)
        a = MapAudit(b, ctx)
        a.run()
        audits.append(a)

    rule = '=' * 78
    print(rule)
    print('Source map pack audit: %d map(s)' % len(bsps))
    if has_game:
        print('Stock content (download/ and custom/ excluded):')
        for desc, count in game.mounted:
            print('  %6d files  %s' % (count, desc))
    else:
        print('WARNING: no game content found. Pass --game <folder with gameinfo.txt> so stock')
        print('assets can be told apart from missing ones. Only custom-folder misses are shown.')
    if ctx.custom:
        print('Custom folders (loose copies reported, not trusted as stock): ' +
              ', '.join(sorted(ctx.custom)))
    elif has_game:
        print('Loose files in the game folder count as stock. Add --custom <folder>')
        print('(e.g. --custom selez) to flag custom assets that only exist loose here.')

    summary = []
    issues = []                        # (audit, other, missing, loose) for the end-of-report list
    fixes = defaultdict(list)          # map -> [(path, source description, reader)]
    for a in audits:
        other, missing, loose, unverified = a.classify()
        summary.append((a.bsp.name, len(other), len(missing), len(loose)))
        issues.append((a, other, missing, loose))
        for p, owners in other:
            fixes[a.bsp.name].append((p, owners[0].name, lambda p=p, o=owners[0]: o.read_packed(p)))
        for p, info in loose:
            def reader(f=info[1]):
                with open(f, 'rb') as fh:
                    return fh.read()
            fixes[a.bsp.name].append((p, info[1], reader))
        if args.brief:
            continue
        print()
        print(rule)
        print('%s  (BSP v%d, %d packed files, %d assets referenced)'
              % (a.bsp.name, a.bsp.version, len(a.bsp.pak()), len(a.status)))
        if a.bsp.pak_error:
            print('  !! could not read the pakfile: %s' % a.bsp.pak_error)
        if not (other or missing or loose):
            print('  OK - everything it references is packed or stock.')

        if other:
            print()
            print('  NOT PACKED, BUT PACKED IN ANOTHER MAP (%d)' % len(other))
            print('  Players who loaded that map earlier in their session can crash here;')
            print('  everyone else gets an error texture/model.')
            if not has_game:
                print('  (Without --game this can include stock assets that another map overrides.)')
            for p, owners in other:
                print('    %s' % p)
                print('        packed in: %s' % ', '.join(o.name for o in owners))
                print('        used by:   %s' % a.used_by(p))
                print_where(a, p, ' ' * 8)

        if missing:
            print()
            print('  NOT FOUND ANYWHERE (%d)' % len(missing))
            print('  Error texture/model for everyone, and a crash risk if any map outside')
            print('  this run packs the same path.')
            for p in missing:
                print('    %s' % p)
                print('        used by:   %s' % a.used_by(p))
                print_where(a, p, ' ' * 8)

        if loose:
            print()
            print('  ONLY FOUND AS LOOSE FILES IN A CUSTOM FOLDER (%d)' % len(loose))
            print("  Present on this machine, but players won't have them unless they got")
            print('  them from somewhere else.')
            for p, info in loose:
                print('    %s' % p)
                print('        loose at:  %s' % info[1])
                print('        used by:   %s' % a.used_by(p))
                print_where(a, p, ' ' * 8)

        if args.verbose and unverified:
            print()
            print('  NOT PACKED, UNVERIFIED (%d) - probably stock; pass --game to check' % len(unverified))
            for p in unverified:
                print('    %s   <- %s' % (p, a.used_by(p)))

        if args.verbose and has_game:
            shadows = []
            for p, zi in sorted(a.bsp.pak().items()):
                g = game.files.get(p)
                if g:
                    same = '' if g[2] is None else (' (identical)' if g[2] == zi.CRC else ' (different)')
                    shadows.append(p + same)
            if shadows:
                print()
                print('  PACKED FILES THAT OVERRIDE STOCK CONTENT (%d)' % len(shadows))
                for s in shadows:
                    print('    %s' % s)

    conflicts = []
    for p, owners in sorted(ctx.pak_owners.items()):
        if len(owners) > 1:
            crcs = {b.name: b.pak()[p].CRC for b in owners}
            if len(set(crcs.values())) > 1:
                conflicts.append((p, crcs))
    print()
    print(rule)
    if conflicts:
        print('SAME PATH PACKED WITH DIFFERENT CONTENTS (%d)' % len(conflicts))
        print('Which version a player sees can depend on which map they loaded first.')
        for p, crcs in conflicts:
            print('  %s' % p)
            for name, crc in sorted(crcs.items()):
                print('      %08x  %s' % (crc, name))
    else:
        print('No conflicting copies of the same path across these maps.')

    print()
    print(rule)
    print('SUMMARY')
    width = max(len(s[0]) for s in summary) + 2
    print('  %-*s %11s %9s %11s' % (width, 'map', 'other-map', 'missing', 'loose-only'))
    for name, o, m, l in summary:
        print('  %-*s %11d %9d %11d' % (width, name, o, m, l))

    if any(o or m or l for _, o, m, l in summary):
        print()
        print(rule)
        print('FILES TO FIX, BY MAP')
        print('Coordinates are world units, the same as in Hammer. To look in game on a')
        print('local server: sv_cheats 1, noclip, setpos X Y Z. In Hammer, the texture')
        print("browser's Mark button selects every face using a material; an entity's")
        print('hammerid is its id in the VMF. Brush-entity positions ignore rotation.')
        for a, other, missing, loose in issues:
            if not (other or missing or loose):
                continue
            print()
            print('  %s' % a.bsp.name)
            for p, owners in other:
                print('    other-map   %s' % p)
                print('                packed in: %s' % ', '.join(o.name for o in owners))
                print('                used by:   %s' % a.used_by(p))
                print_where(a, p, ' ' * 16)
            for p in missing:
                print('    missing     %s' % p)
                print('                used by:   %s' % a.used_by(p))
                print_where(a, p, ' ' * 16)
            for p, info in loose:
                print('    loose-only  %s' % p)
                print('                loose at:  %s' % info[1])
                print('                used by:   %s' % a.used_by(p))
                print_where(a, p, ' ' * 16)

    if args.extract_fixes and fixes:
        out_root = os.path.abspath(args.extract_fixes)
        print()
        print('Extracting fixes to %s' % out_root)
        for mapname, items in fixes.items():
            stem = os.path.splitext(mapname)[0]
            lines = []
            for p, source, reader in items:
                data = reader()
                if data is None:
                    print('  could not read %s from %s' % (p, source))
                    continue
                dest = os.path.join(out_root, stem, *p.split('/'))
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, 'wb') as f:
                    f.write(data)
                lines += [p, dest]
            addlist = os.path.join(out_root, stem + '_addlist.txt')
            with open(addlist, 'w', encoding='latin-1') as f:
                f.write('\n'.join(lines) + '\n')
            print('  %s: %d file(s); bspzip -addlist %s %s %s_fixed.bsp'
                  % (mapname, len(lines) // 2, mapname, os.path.basename(addlist), stem))

    problems = sum(o + m + l for _, o, m, l in summary)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
