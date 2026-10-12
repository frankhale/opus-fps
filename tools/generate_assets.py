"""
PS1-style low-poly asset generator for Blender 5.x.

Every model is textured with one shared 128x64 palette texture (assets/palette.png).
Each face's UVs land inside a single palette swatch, and the texture is sampled with
nearest-neighbour filtering, so faces read as flat colors with a little pixel grit.
Glowing parts use a second, emissive material that samples the same texture, and
portal membranes a third (PS1_Portal) that engines swap for an animated see-through shader.

Conventions (Blender Z-up, exported as glTF Y-up, 1 unit = 1 meter):
  * terrain tiles are 8x8 m, origin at the center, edges at height 0 so they tile
  * props, pickups and enemies have their origin at ground level
  * enemies face -Y in Blender (+Z in glTF), the glTF "front"
  * weapons have their origin at the grip and point +Y in Blender (-Z in glTF),
    the direction a glTF/three.js camera looks

Usage:
  Blender -b --factory-startup -P tools/generate_assets.py -- <out_dir> [--preview <dir>] [--only <category>]
"""
import bpy
import bmesh
import math
import os
import random
import sys
from contextlib import contextmanager
from mathutils import Euler, Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = os.path.abspath(argv[0] if argv else "assets")
PREVIEW_DIR = os.path.abspath(argv[argv.index("--preview") + 1]) if "--preview" in argv else None
ONLY = argv[argv.index("--only") + 1] if "--only" in argv else None  # one category or asset name

# ---------------------------------------------------------------------------
# Palette: 8 columns x 4 rows. A somber, dusk-lit world: cold deep greens, muddy
# earth, heavy stone and dried-blood roofs. The accent row stays saturated so blood,
# fire, pickups and energy weapons stand out against the muted surroundings.
# ---------------------------------------------------------------------------
PALETTE = [
    # nature / ground
    ("dgrass", "#1E2B1F"), ("grass", "#34452E"), ("lgrass", "#586B3E"), ("olive", "#4F4A2A"),
    ("dsoil", "#251B16"), ("dirt", "#4A3628"), ("sand", "#8A7A5C"), ("lsand", "#A89A7A"),
    # stone / wood
    ("dstone", "#24262B"), ("stone", "#4A4D52"), ("lstone", "#7A7A74"), ("dbark", "#2E211A"),
    ("wood", "#5C4030"), ("lwood", "#806248"), ("roof", "#5E2522"), ("white", "#C8C4B8"),
    # water / sky / metal
    ("dwater", "#141F2B"), ("water", "#2A4252"), ("sky", "#5C6E7A"), ("gunmetal", "#1E2024"),
    ("steel", "#44484E"), ("chrome", "#868C90"), ("brass", "#8C6E30"), ("black", "#0C0C0C"),
    # accents
    ("red", "#8E1A16"), ("orange", "#C85A1E"), ("yellow", "#D6A83A"), ("toxic", "#6FB83A"),
    ("cyan", "#3FB6C4"), ("purple", "#4E2A6A"), ("flesh", "#A8705F"), ("bone", "#BFB08C"),
]
COLS, ROWS, SW = 8, 4, 16  # swatch grid and swatch size in pixels
IDX = {name: i for i, (name, _) in enumerate(PALETTE)}


def hex_rgb(h):
    return tuple(int(h[i:i + 2], 16) / 255 for i in (1, 3, 5))


def build_palette_image():
    w, h = COLS * SW, ROWS * SW
    img = bpy.data.images.new("ps1_palette", w, h, alpha=False)
    rng = random.Random(7)
    px = [1.0] * (w * h * 4)
    for i, (_, hx) in enumerate(PALETTE):
        r, g, b = hex_rgb(hx)
        x0, y0 = (i % COLS) * SW, h - (i // COLS + 1) * SW
        for y in range(SW):
            for x in range(SW):
                k = 1 + rng.choice((-0.07, -0.035, 0, 0, 0.035, 0.07))  # subtle grit
                o = ((y0 + y) * w + x0 + x) * 4
                px[o:o + 3] = (min(1, r * k), min(1, g * k), min(1, b * k))
    img.pixels.foreach_set(px)
    img.filepath_raw = os.path.join(OUT, "palette.png")
    img.file_format = "PNG"
    img.save()
    return img


def cell_rect(i, margin=2):
    w, h = COLS * SW, ROWS * SW
    col, row = i % COLS, i // COLS
    return ((col * SW + margin) / w, (h - (row + 1) * SW + margin) / h,
            ((col + 1) * SW - margin) / w, (h - row * SW - margin) / h)


def make_material(img, glow):
    mat = bpy.data.materials.new({False: "PS1_Palette", True: "PS1_Glow", "portal": "PS1_Portal"}[glow])
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    tex.interpolation = "Closest"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 1.0
    bsdf.inputs["Metallic"].default_value = 0.0
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.0
    if glow:
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = 1.0
    return mat


# ---------------------------------------------------------------------------
# Mesh builder
# ---------------------------------------------------------------------------
def M(loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)):
    if isinstance(scale, (int, float)):
        scale = (scale, scale, scale)
    return Matrix.LocRotScale(Vector(loc), Euler([math.radians(a) for a in rot]), Vector(scale))


# Material slot per `glow` value: plain palette, emissive palette, portal membrane.
MAT_INDEX = {False: 0, True: 1, "portal": 2}


class Builder:
    def __init__(self, seed):
        self.bm = bmesh.new()
        self.pal = self.bm.faces.layers.int.new("pal")
        self.rng = random.Random(seed)
        self.P = Matrix.Identity(4)
        # Optional skeleton: (name, head, tail, parent) per bone. Vertices get skin
        # weights through weigh(); any left unweighted are bound to the first bone.
        self.bones = []
        self.deform = None

    @contextmanager
    def at(self, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)):
        old = self.P
        self.P = old @ M(loc, rot, scale)
        yield
        self.P = old

    # -- coloring -----------------------------------------------------------
    def _resolve(self, c, f):
        while True:
            if callable(c):
                c = c(f)
            elif isinstance(c, dict):
                c = self.rng.choices(list(c), weights=list(c.values()))[0]
            elif isinstance(c, (list, tuple)):
                c = self.rng.choice(c)
            else:
                return c

    def paint(self, verts, color, glow=False):
        self.bm.faces.index_update()
        self.bm.normal_update()
        faces = sorted({f for v in verts if v.is_valid for f in v.link_faces}, key=lambda f: f.index)
        for f in faces:
            f[self.pal] = IDX[self._resolve(color, f)]
            f.material_index = MAT_INDEX[glow]
        return verts

    def jitter(self, verts, amt, keep=None):
        a = amt if isinstance(amt, (tuple, list)) else (amt, amt, amt)
        for v in verts:
            if v.is_valid and not (keep and keep(v)):
                v.co += Vector(tuple(self.rng.uniform(-k, k) for k in a))

    # -- primitives ---------------------------------------------------------
    def _cube(self, m, color, glow, jit, cuts):
        verts = bmesh.ops.create_cube(self.bm, size=1.0, matrix=m)["verts"]
        if cuts:
            edges = list({e for v in verts for e in v.link_edges})
            res = bmesh.ops.subdivide_edges(self.bm, edges=edges, cuts=cuts, use_grid_fill=True)
            extra = [g for k in ("geom_inner", "geom_split", "geom") for g in res[k]
                     if isinstance(g, bmesh.types.BMVert)]
            verts = list(dict.fromkeys(list(verts) + extra))
        if jit:
            self.jitter(verts, jit)
        return self.paint(verts, color, glow)

    def box(self, size, loc=(0, 0, 0), rot=(0, 0, 0), color="stone", glow=False, jit=0, cuts=0):
        return self._cube(self.P @ M(loc, rot, size), color, glow, jit, cuts)

    def beam(self, p0, p1, w, h=None, color="stone", glow=False, jit=0):
        p0, p1 = Vector(p0), Vector(p1)
        d = p1 - p0
        q = Vector((0, 0, 1)).rotation_difference(d.normalized())
        m = Matrix.LocRotScale((p0 + p1) / 2, q, Vector((w, h or w, d.length)))
        return self._cube(self.P @ m, color, glow, jit, 0)

    def cyl(self, r1, r2, depth, seg=8, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1),
            color="stone", glow=False, jit=0, m=None):
        mat = self.P @ (m if m is not None else M(loc, rot, scale))
        verts = bmesh.ops.create_cone(self.bm, cap_ends=True, cap_tris=False, segments=seg,
                                      radius1=r1, radius2=r2, depth=depth, matrix=mat)["verts"]
        if r1 < 1e-6 or r2 < 1e-6:
            bmesh.ops.remove_doubles(self.bm, verts=verts, dist=1e-5)
            verts = [v for v in verts if v.is_valid]
        if jit:
            self.jitter(verts, jit)
        return self.paint(verts, color, glow)

    def limb(self, p0, p1, r0, r1, seg=6, color="stone", glow=False):
        p0, p1 = Vector(p0), Vector(p1)
        d = p1 - p0
        q = Vector((0, 0, 1)).rotation_difference(d.normalized())
        return self.cyl(r0, r1, d.length, seg, m=Matrix.LocRotScale((p0 + p1) / 2, q, Vector((1, 1, 1))),
                        color=color, glow=glow)

    def ico(self, radius, subdiv=1, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1),
            color="stone", glow=False, jit=0, floor=None):
        verts = bmesh.ops.create_icosphere(self.bm, subdivisions=subdiv, radius=radius,
                                           matrix=self.P @ M(loc, rot, scale))["verts"]
        if jit:
            self.jitter(verts, jit)
        if floor is not None:
            for v in verts:
                v.co.z = max(v.co.z, floor)
        return self.paint(verts, color, glow)

    def sphere(self, radius, useg=8, vseg=6, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1),
               color="stone", glow=False, jit=0):
        verts = bmesh.ops.create_uvsphere(self.bm, u_segments=useg, v_segments=vseg, radius=radius,
                                          matrix=self.P @ M(loc, rot, scale))["verts"]
        if jit:
            self.jitter(verts, jit)
        return self.paint(verts, color, glow)

    def lathe(self, prof, seg=8, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1),
              color="stone", glow=False, jit=0, keep=None, phase=0.0):
        """Surface of revolution around local Z from a list of (radius, z) pairs."""
        m, bm = self.P @ M(loc, rot, scale), self.bm
        rings = []
        for r, z in prof:
            if r <= 1e-9:
                rings.append([bm.verts.new(m @ Vector((0, 0, z)))])
            else:
                rings.append([bm.verts.new(m @ Vector((r * math.cos(phase + 2 * math.pi * k / seg),
                                                       r * math.sin(phase + 2 * math.pi * k / seg), z)))
                              for k in range(seg)])
        faces = []
        for a, b in zip(rings, rings[1:]):
            for k in range(seg):
                k1 = (k + 1) % seg
                if len(a) == 1 and len(b) > 1:
                    faces.append(bm.faces.new((a[0], b[k1], b[k])))
                elif len(b) == 1 and len(a) > 1:
                    faces.append(bm.faces.new((a[k], a[k1], b[0])))
                elif len(a) > 1:
                    faces.append(bm.faces.new((a[k], a[k1], b[k1], b[k])))
        if len(rings[0]) > 1:
            faces.append(bm.faces.new(list(reversed(rings[0]))))
        if len(rings[-1]) > 1:
            faces.append(bm.faces.new(rings[-1]))
        verts = [v for r in rings for v in r]
        if jit:
            self.jitter(verts, jit, keep)
        bmesh.ops.recalc_face_normals(bm, faces=faces)
        return self.paint(verts, color, glow)

    def poly(self, coords, faces, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1), color="stone", glow=False):
        m = self.P @ M(loc, rot, scale)
        vs = [self.bm.verts.new(m @ Vector(c)) for c in coords]
        fs = [self.bm.faces.new([vs[i] for i in f]) for f in faces]
        bmesh.ops.recalc_face_normals(self.bm, faces=fs)
        return self.paint(vs, color, glow)

    def prism(self, w, d, h, **kw):
        """Triangular prism (gable roof / tent): ridge along local Y, base on z=0."""
        c = [(-w / 2, -d / 2, 0), (w / 2, -d / 2, 0), (0, -d / 2, h),
             (-w / 2, d / 2, 0), (w / 2, d / 2, 0), (0, d / 2, h)]
        return self.poly(c, [(0, 1, 2), (3, 5, 4), (0, 3, 4, 1), (1, 4, 5, 2), (0, 2, 5, 3)], **kw)

    def slab(self, pts, thick, plane="XZ", **kw):
        """Extrude a 2D outline (u, v) by `thick`. XZ: faces -Y, YZ: faces +X."""
        n = len(pts)

        def p3(u, v, t):
            return {"XZ": (u, t, v), "YZ": (t, u, v), "XY": (u, v, t)}[plane]
        coords = [p3(u, v, -thick / 2) for u, v in pts] + [p3(u, v, thick / 2) for u, v in pts]
        faces = [tuple(range(n)), tuple(range(2 * n - 1, n - 1, -1))]
        faces += [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
        return self.poly(coords, faces, **kw)

    def ring(self, radius, thick, seg=8, width=None, loc=(0, 0, 0), rot=(0, 0, 0), color="steel", glow=False):
        """Torus-like ring in local XY made of box segments."""
        seg_len = 2 * radius * math.tan(math.pi / seg) * 1.04
        with self.at(loc, rot):
            for k in range(seg):
                a = 360 * k / seg
                with self.at(rot=(0, 0, a)):
                    self.box((thick, seg_len, width or thick), (radius, 0, 0), color=color, glow=glow)

    def tube(self, pts, radii, seg=5, color="stone", glow=False):
        """Smooth tube through `pts` (one ring per point, radius 0 closes it to a tip).
        Returns the rings (lists of verts) so they can be skinned."""
        bm, m = self.bm, self.P
        pts = [Vector(p) for p in pts]
        rings, ref = [], None
        for i, (p, r) in enumerate(zip(pts, radii)):
            d = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
            # Carry the side vector along the tube (parallel transport) so it doesn't twist.
            ref = (ref - d * ref.dot(d)) if ref is not None else d.orthogonal()
            ref.normalize()
            side2 = d.cross(ref)
            if r <= 1e-9:
                rings.append([bm.verts.new(m @ p)])
            else:
                rings.append([bm.verts.new(m @ (p + (ref * math.cos(2 * math.pi * k / seg) +
                                                     side2 * math.sin(2 * math.pi * k / seg)) * r))
                              for k in range(seg)])
        faces = []
        for a, b in zip(rings, rings[1:]):
            for k in range(seg):
                k1 = (k + 1) % seg
                if len(b) == 1:
                    faces.append(bm.faces.new((a[k], a[k1], b[0])))
                else:
                    faces.append(bm.faces.new((a[k], a[k1], b[k1], b[k])))
        faces.append(bm.faces.new(list(reversed(rings[0]))))
        bmesh.ops.recalc_face_normals(bm, faces=faces)
        self.paint([v for r in rings for v in r], color, glow)
        return rings

    # -- skinning -----------------------------------------------------------
    def bone(self, name, head, tail, parent=None):
        # Adding the weight layer invalidates held vertex references, so it's made
        # here, before any skinned geometry is built.
        if self.deform is None:
            self.deform = self.bm.verts.layers.deform.verify()
        self.bones.append((name, Vector(head), Vector(tail), parent))

    def weigh(self, verts, weights):
        """weights: {bone name: weight}."""
        names = [b[0] for b in self.bones]
        for v in verts:
            for bone, w in weights.items():
                v[self.deform][names.index(bone)] = w

    # -- output -------------------------------------------------------------
    def to_object(self, name, mats):
        bm = self.bm
        bm.normal_update()
        if self.bones:
            for v in bm.verts:
                if not v[self.deform]:
                    v[self.deform][0] = 1.0
        uvl = bm.loops.layers.uv.new("UVMap")
        for f in bm.faces:
            u0, v0, u1, v1 = cell_rect(f[self.pal])
            n = f.normal
            ax = max(range(3), key=lambda i: abs(n[i]))
            a, b = ((1, 2), (0, 2), (0, 1))[ax]
            pts = [(l.vert.co[a], l.vert.co[b]) for l in f.loops]
            mnx, mxx = min(p[0] for p in pts), max(p[0] for p in pts)
            mny, mxy = min(p[1] for p in pts), max(p[1] for p in pts)
            sx, sy = max(mxx - mnx, 1e-6), max(mxy - mny, 1e-6)
            for l, (x, y) in zip(f.loops, pts):
                l[uvl].uv = (u0 + (x - mnx) / sx * (u1 - u0), v0 + (y - mny) / sy * (v1 - v0))
        used = max(f.material_index for f in bm.faces)
        mesh = bpy.data.meshes.new(name)
        bm.to_mesh(mesh)
        bm.free()
        for p in mesh.polygons:
            p.use_smooth = False
        for m in mats[:used + 1]:
            mesh.materials.append(m)
        obj = bpy.data.objects.new(name, mesh)
        bpy.context.scene.collection.objects.link(obj)
        if self.bones:
            self._rig(obj)
        return obj

    def _rig(self, obj):
        for b in self.bones:
            obj.vertex_groups.new(name=b[0])
        arm = bpy.data.armatures.new(obj.name + "_rig")
        rig = bpy.data.objects.new(obj.name + "_rig", arm)
        bpy.context.scene.collection.objects.link(rig)
        bpy.context.view_layer.objects.active = rig
        bpy.ops.object.mode_set(mode="EDIT")
        for name, head, tail, parent in self.bones:
            eb = arm.edit_bones.new(name)
            eb.head, eb.tail = head, tail
            if parent:
                eb.parent = arm.edit_bones[parent]
                eb.use_connect = (arm.edit_bones[parent].tail - head).length < 1e-6
        bpy.ops.object.mode_set(mode="OBJECT")
        obj.parent = rig
        obj.modifiers.new("Armature", "ARMATURE").object = rig


# ---------------------------------------------------------------------------
# Helpers shared by several assets
# ---------------------------------------------------------------------------
TILE, TILE_SEG = 8.0, 8


def bump(t):
    return (math.cos(math.pi * min(max(t, 0), 1)) + 1) / 2


def edge_window(x, y):
    return math.sin(math.pi * (x / TILE + 0.5)) * math.sin(math.pi * (y / TILE + 0.5))


def make_noise(rng, amp):
    waves = [(rng.uniform(0.5, 1.4), rng.uniform(0.5, 1.4), rng.uniform(0, 6.3), rng.uniform(0, 6.3))
             for _ in range(4)]
    return lambda x, y: amp * sum(math.sin(x * a + p) * math.sin(y * b + q) for a, b, p, q in waves) / 2


def terrain(b, hfn, color, jit=0.07):
    """8x8 m height-field tile. hfn must return 0 on the tile border so tiles connect."""
    h, st, n = TILE / 2, TILE / TILE_SEG, TILE_SEG
    grid = []
    for j in range(n + 1):
        row = []
        for i in range(n + 1):
            x, y = -h + i * st, -h + j * st
            z = hfn(x, y) + (b.rng.uniform(-jit, jit) if 0 < i < n and 0 < j < n else 0)
            row.append(b.bm.verts.new((x, y, z)))
        grid.append(row)
    for j in range(n):
        for i in range(n):
            b.bm.faces.new((grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]))
    return b.paint([v for row in grid for v in row], color)


GRASS = {"grass": 6, "dgrass": 2, "lgrass": 2}
STONE = {"stone": 5, "dstone": 2, "lstone": 2}


def mossy(f):
    return {"olive": 2, "grass": 1} if f.normal.z > 0.6 else STONE


# ---------------------------------------------------------------------------
# Asset registry
# ---------------------------------------------------------------------------
ASSETS = []


def asset(category):
    def deco(fn):
        ASSETS.append((category, fn.__name__, fn))
        return fn
    return deco


# ============================== TERRAIN ====================================
@asset("terrain")
def terrain_grass(b):
    noise = make_noise(b.rng, 0.35)
    terrain(b, lambda x, y: noise(x, y) * edge_window(x, y), GRASS)


@asset("terrain")
def terrain_dirt_path(b):
    noise = make_noise(b.rng, 0.35)

    def color(f):
        x = abs(f.calc_center_median().x)
        if x < 1:
            return {"dirt": 5, "dsoil": 1, "sand": 1}
        if x < 2:
            return {"dirt": 1, "grass": 2, "olive": 1}
        return GRASS
    terrain(b, lambda x, y: noise(x, y) * edge_window(x, y) * min(1, abs(x) / 2.5), color, jit=0.04)


@asset("terrain")
def terrain_path_cross(b):
    """Crossroads: dirt paths along both axes, matching terrain_dirt_path's edges."""
    noise = make_noise(b.rng, 0.35)

    def color(f):
        c = f.calc_center_median()
        near = min(abs(c.x), abs(c.y))
        if near < 1:
            return {"dirt": 5, "dsoil": 1, "sand": 1}
        if near < 2:
            return {"dirt": 1, "grass": 2, "olive": 1}
        return GRASS
    terrain(b, lambda x, y: noise(x, y) * edge_window(x, y) * min(1, abs(x) / 2.5, abs(y) / 2.5), color, jit=0.04)


@asset("terrain")
def terrain_sand(b):
    noise = make_noise(b.rng, 0.3)
    terrain(b, lambda x, y: noise(x, y) * edge_window(x, y), {"sand": 6, "lsand": 3, "dirt": 1})


@asset("terrain")
def terrain_hill(b):
    noise = make_noise(b.rng, 0.4)

    def h(x, y):
        return 2.6 * bump(math.hypot(x, y) / 4.0) + noise(x, y) * edge_window(x, y) * 0.5

    terrain(b, h, lambda f: STONE if f.normal.z < 0.62 else GRASS, jit=0.15)


@asset("terrain")
def terrain_pond(b):
    noise = make_noise(b.rng, 0.25)

    def h(x, y):
        return -1.1 * bump(math.hypot(x, y) / 3.3) + noise(x, y) * edge_window(x, y)

    def color(f):
        z = f.calc_center_median().z
        return {"sand": 2, "dirt": 1} if z < -0.3 else ({"lgrass": 2, "sand": 1} if z < -0.08 else GRASS)
    terrain(b, h, color)
    b.cyl(2.9, 2.9, 0.02, seg=10, loc=(0, 0, -0.42), color={"water": 3, "dwater": 1})


@asset("terrain")
def terrain_cliff(b):
    """8 m wide rock wall, 6 m tall; the ends stay flat so segments line up along X."""
    v = b._cube(M((0, 0, 3), scale=(8, 3, 6)), "stone", False, 0, 3)
    b.jitter(v, (0.3, 0.7, 0.35), keep=lambda v: abs(v.co.x) > 3.99 or v.co.z < 0.01)
    b.paint(v, lambda f: GRASS if f.normal.z > 0.7 else STONE)


@asset("terrain")
def terrain_mountain(b):
    """Big backdrop mountain (30 m wide, 18 m tall) for the skyline."""
    prof = [(15, 0), (12.5, 4), (9.5, 8), (6.5, 11.5), (3.5, 15), (0, 18)]
    v = b.lathe(prof, seg=10, color="stone", jit=(1.2, 1.2, 0.8), keep=lambda v: v.co.z < 0.1)

    def color(f):
        z = f.calc_center_median().z
        if z > 12.5:
            return {"white": 4, "lstone": 1}
        return STONE if z > 6 else {"dgrass": 3, "dstone": 2, "olive": 1}
    b.paint(v, color)


# ============================== SCENERY ====================================
@asset("scenery")
def tree_pine(b):
    # Bare lower trunk, like a real pine, so you can walk under the branches.
    b.lathe([(0.2, 0), (0.13, 2.1)], seg=6, color="dbark")
    for r, z0, h in ((1.5, 1.6, 1.9), (1.15, 2.7, 1.7), (0.8, 3.8, 1.5)):
        b.cyl(r, 0, h, seg=7, loc=(0, 0, z0 + h / 2), rot=(0, 0, b.rng.uniform(0, 60)),
              color={"dgrass": 3, "grass": 1}, jit=0.08)


@asset("scenery")
def tree_pine_tall(b):
    b.lathe([(0.26, 0), (0.15, 3.0)], seg=6, color="dbark")
    for i in range(5):
        r, h = 1.8 - i * 0.32, 1.9
        b.cyl(r, 0, h, seg=7, loc=(0, 0, 2.3 + i * 1.15 + h / 2), rot=(0, 0, i * 25),
              color={"dgrass": 3, "grass": 1}, jit=0.1)


@asset("scenery")
def tree_oak(b):
    b.lathe([(0.32, 0), (0.24, 1.0), (0.2, 2.4)], seg=6, color="dbark", jit=0.03)
    b.limb((0, 0, 1.9), (0.9, 0.3, 2.7), 0.1, 0.06, 5, "dbark")
    b.limb((0, 0, 2.0), (-0.8, -0.4, 2.8), 0.1, 0.06, 5, "dbark")

    def leaf(f):
        return {"dgrass": 1} if f.normal.z < -0.3 else {"grass": 3, "lgrass": 1, "dgrass": 1}
    for loc, r in (((0, 0, 3.4), 1.4), ((1.0, 0.3, 2.9), 1.0), ((-0.9, -0.3, 3.0), 1.0),
                   ((0.1, -0.7, 3.9), 0.85), ((-0.2, 0.8, 3.6), 0.9)):
        b.ico(r, 1, loc=loc, rot=(b.rng.uniform(0, 90), 0, b.rng.uniform(0, 90)), color=leaf, jit=0.15)


@asset("scenery")
def tree_dead(b):
    b.lathe([(0.24, 0), (0.17, 1.5), (0.09, 3.0)], seg=5, color={"dbark": 3, "dstone": 1}, jit=0.03)
    for p0, p1 in (((0, 0, 1.4), (0.9, 0.2, 2.3)), ((0, 0, 2.0), (-0.8, 0.4, 2.8)),
                   ((0, 0, 2.5), (0.3, -0.7, 3.3)), ((0.6, 0.13, 2.0), (1.1, -0.3, 2.4))):
        b.limb(p0, p1, 0.07, 0.025, 4, "dbark")


@asset("scenery")
def bush(b):
    for loc, r in (((0, 0, 0.4), 0.55), ((0.45, 0.15, 0.32), 0.42), ((-0.4, -0.1, 0.3), 0.4),
                   ((0.05, 0.35, 0.3), 0.38)):
        b.ico(r, 1, loc=loc, scale=(1, 1, 0.8), rot=(0, 0, b.rng.uniform(0, 90)),
              color={"dgrass": 2, "grass": 2, "olive": 1}, jit=0.06, floor=0)


@asset("scenery")
def grass_tuft(b):
    for _ in range(9):
        a = b.rng.uniform(0, 2 * math.pi)
        r = b.rng.uniform(0, 0.12)
        h = b.rng.uniform(0.25, 0.5)
        b.limb((r * math.cos(a), r * math.sin(a), 0),
               (r * math.cos(a) * 3 + b.rng.uniform(-0.08, 0.08), r * math.sin(a) * 3 + b.rng.uniform(-0.08, 0.08), h),
               0.035, 0.0, 3, {"lgrass": 2, "grass": 2, "olive": 1})


@asset("scenery")
def flowers(b):
    for _ in range(7):
        x, y = b.rng.uniform(-0.35, 0.35), b.rng.uniform(-0.35, 0.35)
        h = b.rng.uniform(0.2, 0.4)
        b.limb((x, y, 0), (x, y, h), 0.012, 0.01, 3, "grass")
        b.box((0.035, 0.12, 0.01), (x + 0.04, y, h * 0.4), rot=(0, 0, b.rng.uniform(0, 180)), color="lgrass")
        petal = b.rng.choice(("yellow", "red", "purple", "white"))
        b.ico(0.05, 1, loc=(x, y, h), scale=(1, 1, 0.6), color=petal)
        b.box((0.03, 0.03, 0.03), (x, y, h + 0.025), color="yellow" if petal != "yellow" else "orange")


@asset("scenery")
def rock_small(b):
    b.ico(0.45, 1, loc=(0, 0, 0.18), scale=(1.2, 1, 0.65), color=STONE, jit=0.07, floor=0)


@asset("scenery")
def rock_large(b):
    v = b.ico(1.4, 2, loc=(0, 0, 0.75), scale=(1.3, 1, 0.8), rot=(0, 0, 20), color="stone", jit=0.22, floor=0)
    b.paint(v, mossy)


@asset("scenery")
def rock_cluster(b):
    for loc, r, s in (((0, 0, 0.5), 0.9, (1.1, 1, 0.9)), ((1.0, 0.4, 0.3), 0.6, (1, 1.2, 0.8)),
                      ((-0.8, 0.6, 0.25), 0.5, (1.2, 1, 0.7)), ((0.3, -0.9, 0.15), 0.35, (1, 1, 0.8))):
        v = b.ico(r, 1, loc=loc, scale=s, rot=(0, 0, b.rng.uniform(0, 90)), color="stone", jit=r * 0.15, floor=0)
        b.paint(v, mossy)


@asset("scenery")
def log_fallen(b):
    b.cyl(0.3, 0.27, 3.0, seg=7, loc=(0, 0, 0.28), rot=(0, 90, 0),
          color=lambda f: "lwood" if abs(f.normal.x) > 0.9 else {"dbark": 3, "wood": 1}, jit=0.02)
    b.limb((0.5, 0, 0.45), (0.7, -0.5, 0.8), 0.07, 0.03, 4, "dbark")


@asset("scenery")
def tree_stump(b):
    b.lathe([(0.48, 0), (0.36, 0.15), (0.32, 0.55)], seg=7,
            color=lambda f: "lwood" if f.normal.z > 0.9 else "dbark", jit=0.03)
    for a in (20, 150, 260):
        r = math.radians(a)
        b.limb((0.3 * math.cos(r), 0.3 * math.sin(r), 0.12), (0.7 * math.cos(r), 0.7 * math.sin(r), 0),
               0.08, 0.04, 4, "dbark")


@asset("scenery")
def fence_wood(b):
    """2 m fence segment with one post at x=-1; place them every 2 m and cap with fence_post."""
    b.box((0.12, 0.12, 1.1), (-1, 0, 0.55), color="wood")
    b.cyl(0.085, 0, 0.15, seg=4, loc=(-1, 0, 1.175), rot=(0, 0, 45), color="wood")
    for z in (0.45, 0.85):
        b.box((2.0, 0.05, 0.14), (0, -0.08, z), rot=(0, b.rng.uniform(-1.5, 1.5), 0), color={"lwood": 2, "wood": 1})


@asset("scenery")
def fence_post(b):
    b.box((0.12, 0.12, 1.1), (0, 0, 0.55), color="wood")
    b.cyl(0.085, 0, 0.15, seg=4, loc=(0, 0, 1.175), rot=(0, 0, 45), color="wood")


@asset("scenery")
def stone_wall(b):
    """4 m long wall segment, tiles along X."""
    b.box((4.0, 0.42, 1.15), (0, 0, 0.575), color="dstone")
    for row in range(3):
        x = -2.0 + (0.0 if row % 2 == 0 else -0.4)
        z = 0.2 + row * 0.39
        while x < 2.0:
            w = b.rng.uniform(0.55, 0.9)
            x1 = min(x + w, 2.0)
            x0 = max(x, -2.0)
            if x1 - x0 > 0.15:
                b.box((x1 - x0 - 0.04, 0.5, 0.36), ((x0 + x1) / 2, 0, z), color=STONE, jit=0.015)
            x += w
    b.box((4.0, 0.56, 0.12), (0, 0, 1.21), color={"lstone": 2, "stone": 1}, cuts=1, jit=0.015)


@asset("scenery")
def crate(b):
    b.box((1, 1, 1), (0, 0, 0.5), color={"lwood": 3, "wood": 1}, cuts=1)
    t, o = 0.1, 0.5 - 0.05 + 0.015
    for s1 in (-1, 1):
        for s2 in (-1, 1):
            b.box((1.03, t, t), (0, s1 * o, 0.5 + s2 * o), color="wood")
            b.box((t, 1.03, t), (s1 * o, 0, 0.5 + s2 * o), color="wood")
            b.box((t, t, 1.03), (s1 * o, s2 * o, 0.5), color="wood")
    for y in (-0.515, 0.515):
        b.box((1.2, 0.03, 0.1), (0, y, 0.5), rot=(0, 45, 0), color="wood")


@asset("scenery")
def barrel(b):
    b.lathe([(0.32, 0), (0.37, 0.25), (0.4, 0.5), (0.37, 0.75), (0.32, 1.0)], seg=8,
            color=lambda f: "dbark" if abs(f.normal.z) > 0.9 else {"wood": 2, "lwood": 1})
    for z, r in ((0.12, 0.355), (0.32, 0.39), (0.68, 0.39), (0.88, 0.355)):
        b.cyl(r, r, 0.06, seg=8, loc=(0, 0, z), color="gunmetal")


@asset("scenery")
def barrel_explosive(b):
    b.lathe([(0.3, 0), (0.3, 0.9)], seg=8, color=lambda f: "steel" if abs(f.normal.z) > 0.9 else "red")
    for z in (0.05, 0.3, 0.6, 0.85):
        b.cyl(0.315, 0.315, 0.04, seg=8, loc=(0, 0, z), color="gunmetal")
    b.cyl(0.305, 0.305, 0.14, seg=8, loc=(0, 0, 0.45), color="yellow")
    b.cyl(0.05, 0.05, 0.04, seg=6, loc=(0.15, 0, 0.92), color="gunmetal")


@asset("scenery")
def cabin(b):
    b.box((4.3, 5.3, 0.3), (0, 0, 0.15), color={"dstone": 2, "stone": 1}, cuts=2)
    b.box((4, 5, 2.3), (0, 0, 1.45), color={"lwood": 2, "wood": 2}, cuts=3)
    b.prism(4.9, 5.8, 1.7, loc=(0, 0, 2.6), color={"roof": 4, "dbark": 1})
    b.box((4.0, 5.0, 0.1), (0, 0, 2.55), color="dbark")
    b.box((0.95, 0.08, 1.85), (0, -2.52, 1.22), color="dbark")
    b.box((0.06, 0.06, 0.06), (0.3, -2.58, 1.2), color="brass")
    b.box((1.5, 0.7, 0.2), (0, -2.9, 0.1), color="wood")
    for x in (-1.35, 1.35):
        b.box((0.95, 0.06, 0.85), (x, -2.51, 1.55), color="lwood")
        b.box((0.75, 0.08, 0.65), (x, -2.52, 1.55), color="black")
    for x in (-2.01, 2.01):
        b.box((0.06, 0.95, 0.85), (x, 0.6, 1.55), color="lwood")
        b.box((0.08, 0.75, 0.65), (x, 0.6, 1.55), color="black")
    b.box((0.6, 0.6, 2.4), (1.2, 1.4, 3.3), color=STONE, cuts=1, jit=0.02)


@asset("scenery")
def watchtower(b):
    for sx in (-1, 1):
        for sy in (-1, 1):
            b.beam((sx * 1.15, sy * 1.15, 0), (sx * 1.0, sy * 1.0, 4.0), 0.2, color="dbark")
    for side in range(4):
        with b.at(rot=(0, 0, 90 * side)):
            b.box((0.08, 0.08, 2.9), (0, -1.07, 1.6), rot=(0, 43, 0), color="wood")
            b.box((0.08, 0.08, 2.9), (0, -1.07, 1.6), rot=(0, -43, 0), color="wood")
            b.box((2.2, 0.08, 0.1), (0, -1.03, 3.0), color="wood")
            b.box((2.8, 0.08, 0.1), (0, -1.4, 4.9), color="lwood")
            b.box((2.8, 0.08, 0.1), (0, -1.4, 4.5), color="lwood")
            b.box((0.12, 0.12, 2.1), (1.32, -1.32, 5.05), color="wood")
    b.box((2.9, 2.9, 0.2), (0, 0, 4.0), color={"lwood": 2, "wood": 1}, cuts=2)
    b.cyl(2.3, 0, 1.3, seg=4, loc=(0, 0, 6.75), rot=(0, 0, 45), color={"roof": 3, "dbark": 1})
    for z in (0.4 * i for i in range(1, 10)):
        b.box((0.55, 0.06, 0.06), (0, -1.35, z), color="wood")
    for x in (-0.3, 0.3):
        b.box((0.07, 0.07, 4.1), (x, -1.38, 2.05), color="dbark")


@asset("scenery")
def ruins_pillar(b):
    b.box((1.0, 1.0, 0.3), (0, 0, 0.15), color={"lstone": 2, "stone": 1}, jit=0.03)
    v = b.lathe([(0.38, 0.3), (0.35, 1.5), (0.34, 2.7)], seg=8, color="lstone")
    b.jitter([x for x in v if x.co.z > 2.6], (0.04, 0.04, 0.35))
    b.paint(v, lambda f: {"olive": 1, "lstone": 1} if f.calc_center_median().z < 0.9 else {"lstone": 3, "stone": 1})
    b.ico(0.3, 1, loc=(0.8, 0.5, 0.15), scale=(1.2, 1, 0.6), color="lstone", jit=0.05, floor=0)


@asset("scenery")
def ruins_arch(b):
    for x in (-1.5, 1.5):
        b.box((0.9, 0.9, 0.3), (x, 0, 0.15), color="stone", jit=0.03)
        b.box((0.7, 0.7, 3.0), (x, 0, 1.75), color={"lstone": 3, "stone": 1}, cuts=2, jit=0.03)
    b.box((4.2, 0.85, 0.6), (0, 0, 3.55), color={"lstone": 3, "stone": 1, "olive": 1}, cuts=2, jit=0.04)
    b.box((0.7, 0.6, 0.5), (0.4, 1.2, 0.25), rot=(8, 0, 25), color="lstone", jit=0.05)


@asset("scenery")
def campfire(b):
    b.cyl(0.55, 0.5, 0.04, seg=8, loc=(0, 0, 0.02), color={"dsoil": 2, "black": 1})
    for k in range(9):
        a = 2 * math.pi * k / 9
        b.ico(0.13, 1, loc=(0.6 * math.cos(a), 0.6 * math.sin(a), 0.07), scale=(1.2, 1, 0.8),
              color=STONE, jit=0.02, floor=0)
    for k in range(4):
        a = math.radians(45 + 90 * k)
        b.limb((0.4 * math.cos(a), 0.4 * math.sin(a), 0.03), (0.05 * math.cos(a), 0.05 * math.sin(a), 0.45),
               0.055, 0.04, 5, {"dbark": 2, "black": 1})
    b.cyl(0.25, 0, 0.6, seg=5, loc=(0, 0, 0.33), color="orange", glow=True)
    b.cyl(0.14, 0, 0.75, seg=4, loc=(0.03, 0.02, 0.4), rot=(0, 0, 30), color="yellow", glow=True)
    b.cyl(0.08, 0, 0.35, seg=4, loc=(-0.14, 0.08, 0.25), color="orange", glow=True)


@asset("scenery")
def signpost(b):
    b.box((0.12, 0.12, 1.8), (0, 0, 0.9), color="wood")
    b.slab([(-0.1, -0.13), (0.7, -0.13), (0.85, 0), (0.7, 0.13), (-0.1, 0.13)], 0.05, loc=(0, -0.09, 1.5),
           color="lwood")
    b.slab([(0.1, -0.12), (-0.6, -0.12), (-0.75, 0), (-0.6, 0.12), (0.1, 0.12)], 0.05, loc=(0, -0.09, 1.15),
           rot=(0, 0, -25), color="lwood")


@asset("scenery")
def bridge_wood(b):
    """6 m long wooden bridge along Y, deck at z=0."""
    for i in range(16):
        y = -2.85 + i * 0.38
        b.box((2.1, 0.33, 0.07), (b.rng.uniform(-0.04, 0.04), y, -0.035), rot=(0, 0, b.rng.uniform(-2, 2)),
              color={"wood": 3, "lwood": 2, "dbark": 1})
    for x in (-0.8, 0.8):
        b.box((0.2, 6.2, 0.25), (x, 0, -0.2), color="dbark")
    for x in (-1.08, 1.08):
        for y in (-3.0, 0.0, 3.0):
            b.box((0.12, 0.12, 1.5), (x, y, 0.2), color="dbark")
        b.box((0.08, 6.1, 0.1), (x, 0, 0.9), color="wood")


@asset("scenery")
def well(b):
    b.cyl(0.85, 0.85, 0.02, seg=10, loc=(0, 0, 0.55), color="dwater")
    for course in range(2):
        for k in range(10):
            a = 360 * (k + course * 0.5) / 10
            with b.at(rot=(0, 0, a)):
                b.box((0.34, 0.6, 0.38), (0.82, 0, 0.2 + course * 0.4), color=STONE, jit=0.015)
    for x in (-0.95, 0.95):
        b.box((0.14, 0.14, 2.0), (x, 0, 1.4), color="wood")
    b.prism(1.3, 2.5, 0.7, loc=(0, 0, 2.35), rot=(0, 0, 90), color={"roof": 3, "dbark": 1})
    b.cyl(0.06, 0.06, 1.9, seg=6, loc=(0, 0, 1.9), rot=(0, 90, 0), color="lwood")
    b.box((0.02, 0.02, 0.6), (0, 0, 1.6), color="lsand")
    b.lathe([(0.12, 0), (0.15, 0.22)], seg=6, loc=(0, 0, 1.08), color="wood")


@asset("scenery")
def lamp_post(b):
    b.box((0.14, 0.14, 2.4), (0, 0, 1.2), color="dbark")
    b.box((0.5, 0.08, 0.08), (0.22, 0, 2.3), color="dbark")
    b.box((0.02, 0.02, 0.15), (0.42, 0, 2.2), color="gunmetal")
    with b.at(loc=(0.42, 0, 1.98)):
        b.box((0.2, 0.2, 0.03), (0, 0, 0.13), color="gunmetal")
        b.cyl(0.14, 0, 0.1, seg=4, loc=(0, 0, 0.19), rot=(0, 0, 45), color="gunmetal")
        b.box((0.2, 0.2, 0.03), (0, 0, -0.13), color="gunmetal")
        b.box((0.15, 0.15, 0.24), (0, 0, 0), color="yellow", glow=True)
        for sx in (-1, 1):
            for sy in (-1, 1):
                b.box((0.025, 0.025, 0.26), (sx * 0.09, sy * 0.09, 0), color="gunmetal")


@asset("scenery")
def tent(b):
    b.prism(2.2, 2.6, 1.5, color={"olive": 3, "dgrass": 1})
    b.poly([(-0.45, -1.31, 0), (0.45, -1.31, 0), (0, -1.31, 0.95)], [(0, 1, 2)], color="black")
    for y in (-1.35, 1.35):
        b.box((0.05, 0.05, 1.7), (0, y, 0.8), color="wood")
    for sx in (-1, 1):
        for sy in (-1, 1):
            b.limb((sx * 1.1, sy * 1.3, 0.02), (sx * 1.5, sy * 1.6, 0.0), 0.02, 0.02, 3, "lsand")


@asset("scenery")
def skull_pile(b):
    """Grim set dressing for enemy lairs."""
    for _ in range(6):
        x, y = b.rng.uniform(-0.35, 0.35), b.rng.uniform(-0.35, 0.35)
        with b.at(loc=(x, y, 0), rot=(0, 0, b.rng.uniform(-50, 50))):
            b.ico(0.12, 1, loc=(0, 0, 0.12), scale=(0.9, 1.1, 1), color="bone")
            b.box((0.12, 0.1, 0.08), (0, -0.07, 0.05), color="bone")
            for sx in (-1, 1):
                b.box((0.045, 0.02, 0.045), (sx * 0.045, -0.125, 0.13), color="black")
    for _ in range(4):
        a = b.rng.uniform(0, 6.3)
        b.limb((0.5 * math.cos(a), 0.5 * math.sin(a), 0.03),
               (0.5 * math.cos(a) + 0.4 * math.cos(a + 1.3), 0.5 * math.sin(a) + 0.4 * math.sin(a + 1.3), 0.03),
               0.025, 0.025, 4, "bone")


# ============================== WEAPONS ====================================
FWD = (-90, 0, 0)  # rotates a primitive's +Z axis to +Y (forward)


@asset("weapons")
def weapon_knife(b):
    b.cyl(0.016, 0.014, 0.11, seg=6, loc=(0, 0, 0), rot=FWD, color="black")
    b.box((0.06, 0.012, 0.025), (0, 0.06, 0.001), color="gunmetal")
    b.slab([(0.065, -0.012), (0.18, -0.012), (0.255, 0.004), (0.2, 0.016), (0.065, 0.016)], 0.005,
           plane="YZ", color="chrome")
    b.box((0.032, 0.012, 0.022), (0, -0.06, 0), color="gunmetal")


@asset("weapons")
def weapon_pistol(b):
    b.box((0.032, 0.2, 0.038), (0, 0.06, 0.07), color="gunmetal")
    b.box((0.03, 0.17, 0.028), (0, 0.045, 0.04), color="black")
    b.cyl(0.009, 0.009, 0.02, seg=6, loc=(0, 0.165, 0.07), rot=FWD, color="black")
    b.box((0.03, 0.05, 0.12), (0, -0.01, -0.02), rot=(-14, 0, 0), color={"dbark": 1})
    b.box((0.032, 0.035, 0.08), (0, -0.012, -0.015), rot=(-14, 0, 0), color="black")
    b.box((0.006, 0.05, 0.006), (0, 0.04, 0.0), color="black")
    b.box((0.006, 0.006, 0.03), (0, 0.065, 0.015), color="black")
    b.box((0.005, 0.008, 0.022), (0, 0.035, 0.018), rot=(20, 0, 0), color="steel")
    b.box((0.006, 0.01, 0.012), (0, 0.15, 0.094), color="black")
    b.box((0.022, 0.01, 0.012), (0, -0.033, 0.094), color="black")


@asset("weapons")
def weapon_shotgun(b):
    b.cyl(0.016, 0.016, 0.62, seg=8, loc=(0, 0.48, 0.045), rot=FWD, color="steel")
    b.cyl(0.014, 0.014, 0.5, seg=8, loc=(0, 0.42, 0.012), rot=FWD, color="gunmetal")
    b.box((0.045, 0.22, 0.07), (0, 0.07, 0.03), color="gunmetal")
    b.box((0.052, 0.18, 0.042), (0, 0.38, 0.005), color={"wood": 2, "lwood": 1}, cuts=1)
    b.box((0.04, 0.3, 0.07), (0, -0.17, 0.0), rot=(8, 0, 0), color="wood")
    b.box((0.044, 0.02, 0.085), (0, -0.32, -0.015), rot=(8, 0, 0), color="black")
    b.box((0.034, 0.055, 0.095), (0, -0.02, -0.04), rot=(-22, 0, 0), color="wood")
    b.box((0.006, 0.06, 0.006), (0, 0.04, -0.012), color="black")
    b.box((0.012, 0.012, 0.012), (0, 0.78, 0.066), color="brass")
    b.box((0.046, 0.06, 0.01), (0, 0.08, 0.066), color="steel")


@asset("weapons")
def weapon_rifle(b):
    b.box((0.05, 0.3, 0.08), (0, 0.1, 0.03), color="gunmetal", cuts=1)
    b.box((0.056, 0.22, 0.06), (0, 0.36, 0.03), color={"olive": 2, "dgrass": 1}, cuts=2)
    b.cyl(0.011, 0.011, 0.26, seg=6, loc=(0, 0.58, 0.04), rot=FWD, color="black")
    b.cyl(0.017, 0.017, 0.06, seg=6, loc=(0, 0.72, 0.04), rot=FWD, color="steel")
    b.box((0.032, 0.075, 0.17), (0, 0.15, -0.07), rot=(20, 0, 0), color="black")
    b.box((0.034, 0.05, 0.1), (0, -0.02, -0.045), rot=(-20, 0, 0), color="black")
    b.box((0.042, 0.24, 0.07), (0, -0.17, 0.015), color={"olive": 2, "dgrass": 1})
    b.box((0.046, 0.02, 0.1), (0, -0.29, 0.0), color="black")
    b.box((0.014, 0.14, 0.03), (0, 0.1, 0.085), color="black")
    b.box((0.01, 0.01, 0.045), (0, 0.45, 0.075), color="black")
    b.box((0.006, 0.006, 0.01), (0.026, 0.06, 0.04), color="red")


@asset("weapons")
def weapon_rocket_launcher(b):
    b.cyl(0.07, 0.07, 1.0, seg=8, loc=(0, 0.2, 0.08), rot=FWD, color={"olive": 3, "dgrass": 1})
    b.cyl(0.086, 0.086, 0.1, seg=8, loc=(0, 0.66, 0.08), rot=FWD, color="gunmetal")
    b.cyl(0.095, 0.07, 0.12, seg=8, loc=(0, -0.33, 0.08), rot=FWD, color="gunmetal")
    b.cyl(0.075, 0.075, 0.04, seg=8, loc=(0, 0.2, 0.08), rot=FWD, color="yellow")
    b.cyl(0.055, 0, 0.15, seg=6, loc=(0, 0.775, 0.08), rot=FWD, color="red")
    b.box((0.035, 0.05, 0.11), (0, 0.0, -0.03), rot=(-18, 0, 0), color="black")
    b.box((0.035, 0.05, 0.1), (0, 0.32, -0.02), color="black")
    b.box((0.03, 0.12, 0.06), (-0.085, 0.18, 0.15), color="gunmetal")
    b.box((0.026, 0.01, 0.045), (-0.085, 0.245, 0.15), color="cyan", glow=True)
    b.box((0.09, 0.2, 0.03), (0, -0.12, 0.165), color="black")


@asset("weapons")
def weapon_plasma_rifle(b):
    b.box((0.07, 0.42, 0.09), (0, 0.12, 0.03), color={"steel": 2, "purple": 1}, cuts=1)
    b.box((0.075, 0.2, 0.03), (0, 0.15, 0.09), color="purple")
    b.cyl(0.02, 0.02, 0.24, seg=6, loc=(0, 0.43, 0.04), rot=FWD, color="gunmetal")
    for y in (0.36, 0.42, 0.48):
        b.cyl(0.045, 0.045, 0.022, seg=8, loc=(0, y, 0.04), rot=FWD, color="cyan", glow=True)
    b.cyl(0.035, 0.018, 0.06, seg=8, loc=(0, 0.56, 0.04), rot=FWD, color="chrome")
    b.box((0.04, 0.09, 0.05), (0.04, 0.0, 0.03), color="cyan", glow=True)
    b.box((0.036, 0.05, 0.1), (0, -0.04, -0.05), rot=(-20, 0, 0), color="black")
    b.box((0.05, 0.18, 0.07), (0, -0.17, 0.02), rot=(5, 0, 0), color="purple")
    b.box((0.012, 0.1, 0.02), (0, 0.1, 0.11), color="black")


@asset("weapons")
def weapon_grenade(b):
    b.lathe([(0, 0), (0.025, 0.005), (0.033, 0.025), (0.031, 0.05), (0.018, 0.068), (0, 0.072)], seg=8,
            color={"olive": 3, "dgrass": 1})
    b.cyl(0.012, 0.012, 0.025, seg=6, loc=(0, 0, 0.078), color="gunmetal")
    b.box((0.012, 0.008, 0.06), (0.025, 0, 0.06), rot=(0, 20, 0), color="steel")
    b.ring(0.012, 0.004, 6, loc=(-0.018, 0, 0.084), rot=(90, 0, 0), color="chrome")


# ============================== PICKUPS ====================================
@asset("pickups")
def pickup_health_vial(b):
    b.lathe([(0.08, 0), (0.11, 0.05), (0.11, 0.2), (0.05, 0.25)], seg=8, color="red", glow=True)
    b.lathe([(0.05, 0.25), (0.045, 0.31)], seg=8, color="chrome")
    b.lathe([(0.052, 0.31), (0.048, 0.36)], seg=6, color="lwood")


@asset("pickups")
def pickup_medkit(b):
    b.box((0.5, 0.3, 0.26), (0, 0, 0.13), color="white", cuts=1)
    b.box((0.3, 0.08, 0.012), (0, 0, 0.266), color="red")
    b.box((0.08, 0.24, 0.012), (0, 0, 0.266), color="red")
    b.box((0.2, 0.012, 0.06), (0, -0.155, 0.13), color="red")
    b.box((0.06, 0.012, 0.18), (0, -0.155, 0.13), color="red")
    for x in (-0.07, 0.07):
        b.box((0.025, 0.04, 0.06), (x, 0, 0.29), color="gunmetal")
    b.box((0.17, 0.04, 0.025), (0, 0, 0.32), color="gunmetal")
    for x in (-0.2, 0.2):
        b.box((0.05, 0.02, 0.04), (x, -0.155, 0.22), color="steel")


@asset("pickups")
def pickup_armor(b):
    b.box((0.5, 0.2, 0.56), (0, 0, 0.3), color={"olive": 2, "dgrass": 1}, cuts=1)
    for x in (-0.11, 0.11):
        b.box((0.19, 0.03, 0.24), (x, -0.11, 0.42), color="steel")
        b.box((0.1, 0.22, 0.06), (x * 1.6, 0, 0.6), color="olive")
    b.box((0.42, 0.03, 0.14), (0, -0.11, 0.15), color="steel")
    b.box((0.52, 0.22, 0.05), (0, 0, 0.08), color="black")
    b.box((0.18, 0.02, 0.06), (0, -0.13, 0.25), color="cyan", glow=True)


@asset("pickups")
def pickup_armor_shard(b):
    b.slab([(-0.15, 0.35), (0.15, 0.35), (0.15, 0.15), (0, 0), (-0.15, 0.15)], 0.05, loc=(0, 0, 0.1),
           color="steel")
    b.slab([(-0.08, 0.3), (0.08, 0.3), (0.08, 0.18), (0, 0.09), (-0.08, 0.18)], 0.06, loc=(0, 0, 0.1),
           color="cyan", glow=True)


@asset("pickups")
def pickup_ammo_bullets(b):
    b.box((0.32, 0.2, 0.15), (0, 0, 0.075), color={"olive": 3, "dgrass": 1})
    b.box((0.33, 0.012, 0.04), (0, -0.1, 0.09), color="yellow")
    for i in range(5):
        x = -0.12 + i * 0.06
        b.lathe([(0.014, 0), (0.014, 0.05), (0.012, 0.065), (0, 0.085)], seg=6, loc=(x, 0.03, 0.15),
                color=lambda f: "brass" if f.calc_center_median().z < 0.2 else "orange")


@asset("pickups")
def pickup_ammo_shells(b):
    b.box((0.3, 0.2, 0.1), (0, 0, 0.05), color={"dirt": 2, "dsoil": 1})
    for i in range(6):
        y = -0.075 + i * 0.03
        b.cyl(0.013, 0.013, 0.06, seg=6, loc=(-0.02, y, 0.115), rot=(0, 90, 0), color="red")
        b.cyl(0.0135, 0.0135, 0.025, seg=6, loc=(0.0225, y, 0.115), rot=(0, 90, 0), color="brass")


@asset("pickups")
def pickup_ammo_rockets(b):
    b.box((0.7, 0.3, 0.18), (0, 0, 0.09), color={"olive": 3, "dgrass": 1}, cuts=1)
    b.box((0.71, 0.02, 0.04), (0, -0.15, 0.1), color="yellow")
    for y in (-0.07, 0.07):
        b.cyl(0.05, 0.05, 0.45, seg=8, loc=(-0.05, y, 0.23), rot=(0, 90, 0), color="gunmetal")
        b.cyl(0.05, 0, 0.12, seg=8, loc=(0.235, y, 0.23), rot=(0, 90, 0), color="red")
        b.cyl(0.06, 0.06, 0.05, seg=4, loc=(-0.28, y, 0.23), rot=(0, 90, 0), color="steel")


@asset("pickups")
def pickup_ammo_cells(b):
    b.box((0.22, 0.22, 0.32), (0, 0, 0.16), color="gunmetal")
    b.box((0.16, 0.23, 0.2), (0, 0, 0.16), color="cyan", glow=True)
    for z in (0.02, 0.3):
        b.box((0.24, 0.24, 0.04), (0, 0, z), color="steel")
    for x in (-0.05, 0.05):
        b.cyl(0.02, 0.02, 0.04, seg=6, loc=(x, 0, 0.34), color="brass" if x < 0 else "chrome")


def key(b, color):
    b.ring(0.08, 0.03, 8, width=0.03, loc=(0, 0, 0.34), rot=(90, 0, 0), color=color, glow=True)
    b.box((0.03, 0.03, 0.24), (0, 0, 0.15), color=color, glow=True)
    b.box((0.06, 0.03, 0.03), (0.045, 0, 0.05), color=color, glow=True)
    b.box((0.045, 0.03, 0.03), (0.037, 0, 0.11), color=color, glow=True)
    b.box((0.04, 0.035, 0.04), (0, 0, 0.34), color="gunmetal")


@asset("pickups")
def pickup_key_red(b):
    key(b, "red")


@asset("pickups")
def pickup_key_yellow(b):
    key(b, "yellow")


@asset("pickups")
def pickup_key_cyan(b):
    key(b, "cyan")


@asset("pickups")
def powerup_quad_damage(b):
    b.ico(0.22, 1, loc=(0, 0, 0.35), color="purple", glow=True)
    b.ring(0.32, 0.03, 10, loc=(0, 0, 0.35), rot=(70, 0, 20), color="chrome")
    b.ring(0.32, 0.03, 10, loc=(0, 0, 0.35), rot=(70, 0, 110), color="chrome")


@asset("pickups")
def powerup_speed(b):
    b.slab([(-0.02, 0.62), (0.12, 0.62), (0.03, 0.36), (0.12, 0.36), (-0.06, 0.02), (0.0, 0.28),
            (-0.1, 0.28)], 0.06, loc=(0.0, 0, 0.08), color="yellow", glow=True)


@asset("pickups")
def powerup_invulnerability(b):
    b.sphere(0.2, 8, 6, loc=(0, 0, 0.35), color="cyan", glow=True)
    for rot in ((0, 0, 0), (90, 0, 0), (90, 0, 90)):
        b.ring(0.27, 0.025, 10, loc=(0, 0, 0.35), rot=rot, color="brass")


@asset("pickups")
def powerup_mega_health(b):
    b.box((0.42, 0.14, 0.14), (0, 0, 0.35), color="red", glow=True)
    b.box((0.14, 0.14, 0.42), (0, 0, 0.35), color="red", glow=True)
    b.box((0.14, 0.42, 0.14), (0, 0, 0.35), color="red", glow=True)
    b.ring(0.3, 0.025, 10, loc=(0, 0, 0.35), rot=(90, 0, 45), color="white")


@asset("pickups")
def pickup_gem(b):
    b.lathe([(0, 0), (0.13, 0.18), (0.1, 0.24), (0, 0.27)], seg=6, loc=(0, 0, 0.12), color="toxic", glow=True)


# ============================== ENEMIES ====================================
@asset("enemies")
def enemy_grunt(b):
    """Helmeted soldier, ~1.8 m."""
    for s in (-1, 1):
        b.box((0.15, 0.24, 0.12), (s * 0.11, -0.03, 0.06), color="black")
        b.box((0.13, 0.14, 0.42), (s * 0.11, 0, 0.33), color={"olive": 3, "dgrass": 1})
        b.box((0.15, 0.16, 0.4), (s * 0.11, 0, 0.73), color={"olive": 3, "dgrass": 1})
    b.box((0.38, 0.22, 0.08), (0, 0, 0.96), color="black")
    b.box((0.06, 0.02, 0.05), (0, -0.115, 0.96), color="brass")
    b.box((0.42, 0.24, 0.5), (0, 0, 1.24), color="olive")
    b.box((0.44, 0.27, 0.34), (0, 0, 1.3), color={"dgrass": 3, "gunmetal": 1}, cuts=1)
    for x in (-0.12, 0.0, 0.12):
        b.box((0.09, 0.05, 0.1), (x, -0.15, 1.18), color="olive")
    b.box((0.1, 0.1, 0.08), (0, 0, 1.52), color="flesh")
    b.box((0.22, 0.24, 0.25), (0, 0, 1.66), color="flesh")
    b.lathe([(0.16, 0), (0.16, 0.06), (0.13, 0.14), (0, 0.18)], seg=8, loc=(0, 0.01, 1.7), scale=(1, 1.12, 1),
            color={"olive": 2, "dgrass": 1})
    b.box((0.2, 0.03, 0.055), (0, -0.125, 1.69), color="black")
    b.box((0.16, 0.035, 0.025), (0, -0.13, 1.69), color="red", glow=True)
    for s in (-1, 1):
        b.box((0.13, 0.15, 0.2), (s * 0.27, 0, 1.42), color="olive")
        b.beam((s * 0.27, 0, 1.4), (s * 0.24, -0.02, 1.12), 0.11, color="olive")
        b.beam((s * 0.24, -0.02, 1.12), (s * 0.08, -0.3, 1.12), 0.1, color="olive")
        b.box((0.08, 0.08, 0.08), (s * 0.07, -0.33, 1.12), color="flesh")
    b.box((0.06, 0.6, 0.09), (0.0, -0.4, 1.17), color="gunmetal")
    b.box((0.04, 0.08, 0.14), (0.0, -0.3, 1.07), rot=(20, 0, 0), color="black")
    b.cyl(0.012, 0.012, 0.15, seg=6, loc=(0, -0.76, 1.19), rot=FWD, color="black")


@asset("enemies")
def enemy_demon(b):
    """Hulking red imp with horns, ~2.2 m."""
    skin = {"red": 4, "roof": 1}
    for s in (-1, 1):
        b.beam((s * 0.17, 0.0, 1.0), (s * 0.19, -0.12, 0.6), 0.2, color=skin)
        b.beam((s * 0.19, -0.12, 0.6), (s * 0.18, 0.06, 0.12), 0.15, color=skin)
        b.box((0.17, 0.24, 0.12), (s * 0.18, -0.02, 0.06), color="black")
    b.box((0.42, 0.3, 0.3), (0, 0.03, 1.08), color=skin)
    b.box((0.62, 0.4, 0.55), (0, 0.04, 1.45), color=skin, cuts=1, jit=0.02)
    b.box((0.36, 0.05, 0.3), (0, -0.17, 1.35), color={"flesh": 2, "bone": 1}, cuts=1)
    b.box((0.32, 0.32, 0.3), (0, -0.05, 1.88), color=skin, jit=0.015)
    b.box((0.26, 0.12, 0.1), (0, -0.16, 1.76), color=skin)
    b.box((0.2, 0.03, 0.04), (0, -0.215, 1.78), color="black")
    for x in (-0.06, -0.02, 0.02, 0.06):
        b.cyl(0.012, 0, 0.04, seg=3, loc=(x, -0.22, 1.785), rot=(180, 0, 0), color="bone")
    for s in (-1, 1):
        b.box((0.08, 0.03, 0.04), (s * 0.075, -0.215, 1.92), color="yellow", glow=True)
        b.limb((s * 0.13, -0.05, 2.0), (s * 0.3, 0.05, 2.25), 0.05, 0.0, 5, "bone")
        b.ico(0.17, 1, loc=(s * 0.4, 0.04, 1.62), color=skin, jit=0.02)
        b.beam((s * 0.42, 0.04, 1.55), (s * 0.48, -0.05, 1.15), 0.15, color=skin)
        b.beam((s * 0.48, -0.05, 1.15), (s * 0.46, -0.2, 0.82), 0.13, color=skin)
        for k in (-1, 0, 1):
            b.limb((s * 0.46 + k * 0.04, -0.22, 0.79), (s * 0.48 + k * 0.05, -0.3, 0.64), 0.018, 0, 4, "bone")
    for z in (1.4, 1.58, 1.74):
        b.limb((0, 0.22, z), (0, 0.38, z + 0.08), 0.05, 0, 4, "bone")
    b.limb((0, 0.15, 1.0), (0, 0.6, 0.6), 0.07, 0.02, 5, skin)


@asset("enemies")
def enemy_slime(b):
    v = b.ico(0.6, 2, loc=(0, 0, 0.42), scale=(1, 1, 0.72), color="toxic", jit=0.04, floor=0.02)
    b.paint(v, lambda f: {"lgrass": 1, "toxic": 1} if f.normal.z < 0.2 else {"toxic": 3, "lgrass": 1})
    for s in (-1, 1):
        b.ico(0.11, 1, loc=(s * 0.18, -0.48, 0.55), color="white")
        b.box((0.06, 0.04, 0.07), (s * 0.18, -0.58, 0.55), color="black")
    b.box((0.26, 0.04, 0.06), (0, -0.56, 0.32), rot=(0, 0, 0), color="dgrass")
    for loc in ((0.5, 0.3, 0.1), (-0.55, 0.0, 0.08), (0.2, 0.55, 0.06)):
        b.ico(0.1, 1, loc=loc, scale=(1, 1, 0.6), color="toxic")
    b.ico(0.12, 1, loc=(0.05, 0.1, 0.42), color="yellow", glow=True)


@asset("enemies")
def enemy_spider(b):
    """Giant spider, ~2.2 m leg span."""
    b.ico(0.45, 1, loc=(0, 0.35, 0.6), scale=(0.95, 1.2, 0.75), color={"black": 2, "dbark": 1}, jit=0.03)
    b.box((0.16, 0.04, 0.2), (0, 0.55, 0.92), rot=(-35, 0, 0), color="red")
    b.ico(0.28, 1, loc=(0, -0.2, 0.55), scale=(1, 1.1, 0.8), color={"dbark": 2, "black": 1})
    for x, z in ((-0.08, 0.65), (0.08, 0.65), (-0.14, 0.6), (0.14, 0.6)):
        b.box((0.05, 0.03, 0.05), (x, -0.48, z), color="red", glow=True)
    for s in (-1, 1):
        b.limb((s * 0.06, -0.48, 0.47), (s * 0.04, -0.55, 0.32), 0.03, 0, 4, "bone")
    for s in (-1, 1):
        for k, y in enumerate((-0.3, -0.12, 0.06, 0.24)):
            spread = (y - 0.0) * 1.8
            p0 = (s * 0.2, y, 0.55)
            p1 = (s * 0.75, y + spread * 0.5, 0.95)
            p2 = (s * 1.15, y + spread, 0.0)
            b.limb(p0, p1, 0.05, 0.04, 4, {"black": 2, "dbark": 1})
            b.limb(p1, p2, 0.04, 0.012, 4, {"black": 2, "dbark": 1})


TENTACLE_BONES = 4


@asset("enemies")
def enemy_floating_eye(b):
    """Hovering eyeball; origin at its body's center (offset it above ground in game)."""
    b.sphere(0.4, 10, 8, color={"bone": 3, "flesh": 1})
    b.cyl(0.21, 0.19, 0.06, seg=10, loc=(0, -0.385, 0), rot=(90, 0, 0), color="red")
    b.cyl(0.09, 0.09, 0.03, seg=8, loc=(0, -0.42, 0), rot=(90, 0, 0), color="black")
    b.box((0.04, 0.01, 0.04), (0.04, -0.44, 0.04), color="white", glow=True)
    for a in range(4):
        with b.at(rot=(0, 90 * a + 45, 0)):
            b.box((0.05, 0.3, 0.2), (0.45, 0.1, 0), color="gunmetal")
    b.cyl(0.42, 0.42, 0.05, seg=10, loc=(0, 0, 0), rot=(0, 0, 0), color="purple")
    # Five rigged tentacles hanging below and sweeping back. Each is one smooth tube
    # skinned to a chain of TENTACLE_BONES bones (tentacle_<k>_0 at the root to
    # tentacle_<k>_3 at the tip), all parented to the "body" bone, so the game can
    # sway, curl and trail them.
    b.bone("body", (0, 0, 0), (0, 0, 0.3))
    for k in range(5):
        a = 2 * math.pi * k / 5
        x, y = 0.18 * math.cos(a), 0.18 * math.sin(a) + 0.05
        p0, p1, p2 = Vector((x, y, -0.32)), Vector((x * 1.4, y * 1.4 + 0.1, -0.65)), Vector((x * 1.1, y * 1.1 + 0.25, -0.95))

        def at(t):
            return (1 - t) ** 2 * p0 + 2 * (1 - t) * t * p1 + t ** 2 * p2
        n = TENTACLE_BONES
        for j in range(n):
            b.bone(f"tentacle_{k}_{j}", at(j / n), at((j + 1) / n), "body" if j == 0 else f"tentacle_{k}_{j - 1}")
        ts = [i / (2 * n) for i in range(2 * n + 1)]   # a ring at every joint and mid-bone, then the tip
        rings = b.tube([at(t) for t in ts], [0.045 - 0.033 * t if t < 1 else 0 for t in ts], seg=5, color="purple")
        for i, ring in enumerate(rings):
            j, joint = min(i // 2, n - 1), i % 2 == 0 and 0 < i < 2 * n
            # Joint rings bend half with each neighbouring bone; the rest follow their own bone.
            b.weigh(ring, {f"tentacle_{k}_{j - 1}": 0.5, f"tentacle_{k}_{j}": 0.5} if joint else {f"tentacle_{k}_{j}": 1.0})


@asset("enemies")
def enemy_golem(b):
    """Moss-covered rock golem, ~2.6 m."""
    def rock(r, loc, scale=(1, 1, 1), subdiv=1):
        v = b.ico(r, subdiv, loc=loc, scale=scale, rot=(b.rng.uniform(0, 90), 0, b.rng.uniform(0, 90)),
                  color="stone", jit=r * 0.12)
        b.paint(v, mossy)
    rock(0.75, (0, 0.05, 1.6), (1.25, 0.9, 1.0), 2)
    rock(0.45, (0, 0.05, 0.95), (1.1, 0.9, 0.8))
    rock(0.32, (0, -0.12, 2.3), (1.1, 1.1, 0.9))
    for s in (-1, 1):
        rock(0.32, (s * 0.25, 0.0, 0.32), (1, 1.2, 1))
        rock(0.45, (s * 0.88, 0.05, 1.95))
        rock(0.38, (s * 1.0, -0.05, 1.4))
        rock(0.44, (s * 1.02, -0.12, 0.88))
        b.box((0.09, 0.03, 0.05), (s * 0.1, -0.45, 2.33), color="cyan", glow=True)
    b.slab([(-0.08, 0.3), (0.06, 0.12), (-0.03, 0.0), (0.08, -0.25), (-0.06, -0.05), (0.02, 0.1)], 0.08,
           loc=(0, -0.62, 1.65), color="cyan", glow=True)


@asset("enemies")
def enemy_wolf(b):
    """Feral grey wolf, faces -Y."""
    fur = {"stone": 3, "dstone": 2, "lstone": 1}
    b.box((0.36, 0.95, 0.38), (0, 0.05, 0.78), color=fur, cuts=1, jit=0.02)
    b.box((0.44, 0.4, 0.48), (0, -0.35, 0.82), color=fur, jit=0.02)
    b.box((0.3, 0.34, 0.28), (0, -0.66, 0.98), color=fur)
    b.box((0.17, 0.26, 0.14), (0, -0.9, 0.92), color={"lstone": 1})
    b.box((0.07, 0.04, 0.05), (0, -1.03, 0.97), color="black")
    b.box((0.15, 0.2, 0.04), (0, -0.9, 0.84), color="black")
    for x in (-0.05, 0.05):
        b.cyl(0.012, 0, 0.04, seg=3, loc=(x, -0.98, 0.875), rot=(180, 0, 0), color="bone")
    for s in (-1, 1):
        b.cyl(0.06, 0, 0.14, seg=4, loc=(s * 0.1, -0.6, 1.18), rot=(0, s * 15, 0), color="dstone")
        b.box((0.06, 0.03, 0.035), (s * 0.08, -0.83, 1.04), color="yellow", glow=True)
        for y, ry in ((-0.38, -1), (0.38, 1)):
            b.limb((s * 0.15, y, 0.65), (s * 0.16, y + 0.06 * ry, 0.33), 0.07, 0.055, 5, fur)
            b.limb((s * 0.16, y + 0.06 * ry, 0.33), (s * 0.16, y - 0.02, 0.05), 0.05, 0.045, 5, fur)
            b.box((0.1, 0.14, 0.06), (s * 0.16, y - 0.06, 0.03), color="dstone")
    b.limb((0, 0.5, 0.85), (0, 0.95, 0.55), 0.08, 0.03, 5, fur)


@asset("enemies")
def enemy_turret(b):
    b.lathe([(0.5, 0), (0.45, 0.18), (0.28, 0.28), (0.25, 0.62)], seg=8, color="gunmetal")
    b.cyl(0.46, 0.46, 0.06, seg=8, loc=(0, 0, 0.12), color="yellow")
    with b.at(loc=(0, 0, 0.82)):
        b.box((0.55, 0.6, 0.36), color={"steel": 2, "gunmetal": 1}, cuts=1)
        b.box((0.3, 0.05, 0.1), (0, -0.31, 0.08), color="red", glow=True)
        for x in (-0.13, 0.13):
            b.cyl(0.045, 0.045, 0.55, seg=6, loc=(x, -0.5, -0.06), rot=(90, 0, 0), color="black")
            b.cyl(0.06, 0.06, 0.08, seg=6, loc=(x, -0.76, -0.06), rot=(90, 0, 0), color="gunmetal")
        b.box((0.04, 0.04, 0.25), (0.2, 0.2, 0.3), color="gunmetal")


# ============================== VIEWMODEL ==================================
# First-person arms. Hands wear brown leather fingerless gloves (they separate from
# the mostly black guns, and skin-toned fingers read clearly); sleeves are an olive
# field jacket.
#   * grip hands: origin at the centre of a vertical pistol-style grip (grip axis +Z,
#     barrel/forward +Y), fingers wrapping the front, thumb over the top of the far side
#   * support hand: origin at the centre of a horizontal barrel/handguard along +Y,
#     palm underneath, fingers curling up the right side, thumb along the left
#   * forearm: origin at the wrist, running along +Y toward the elbow (0.7 m)
# Each hand's wrist sits where the forearm attaches; the game positions forearms
# from that point toward a shoulder just off-screen.
GLOVE = {"dbark": 3, "wood": 1}


def grip_hand(b, s):
    """s = +1 builds the right hand, -1 its mirror image (left)."""
    b.box((0.03, 0.075, 0.095), (s * 0.03, -0.012, 0.0), color=GLOVE)            # palm / back of hand
    b.box((0.05, 0.026, 0.09), (s * 0.006, -0.04, 0.0), color=GLOVE)             # web against the backstrap
    for i, z in enumerate((0.03, 0.008, -0.014, -0.035)):
        w = 0.018 if i < 3 else 0.015                                            # little finger is thinner
        b.box((0.05, 0.02, w), (s * 0.008, 0.034, z), color="flesh")             # across the front
        b.box((0.018, 0.03, w * 0.95), (-s * 0.024, 0.02, z), color="flesh")     # curled round the far side
        b.box((0.008, 0.02, w * 0.9), (s * 0.034, 0.034, z), color=GLOVE)        # glove edge at the knuckles
    b.box((0.02, 0.052, 0.02), (-s * 0.02, 0.004, 0.047), rot=(0, 0, s * 12), color="flesh")  # thumb
    b.box((0.022, 0.03, 0.024), (-s * 0.006, -0.03, 0.044), color=GLOVE)          # thumb base
    b.box((0.058, 0.055, 0.06), (s * 0.022, -0.058, -0.036), rot=(-25, 0, 0), color=GLOVE)  # wrist


@asset("viewmodel")
def hand_right_grip(b):
    grip_hand(b, 1)


@asset("viewmodel")
def hand_left_grip(b):
    grip_hand(b, -1)


@asset("viewmodel")
def hand_left_support(b):
    b.box((0.06, 0.09, 0.022), (-0.012, 0.0, -0.042), rot=(0, -20, 0), color=GLOVE)  # palm under the barrel
    for y in (-0.03, -0.01, 0.01, 0.03):
        b.box((0.018, 0.017, 0.036), (0.036, y, -0.02), rot=(0, -12, 0), color="flesh")  # up the right side
        b.box((0.016, 0.016, 0.022), (0.03, y, 0.016), rot=(0, 30, 0), color="flesh")    # curling over the top
    b.box((0.018, 0.055, 0.018), (-0.04, 0.018, 0.0), rot=(0, 0, -8), color="flesh")    # thumb along the left
    b.box((0.03, 0.035, 0.03), (-0.04, -0.02, -0.02), color=GLOVE)                      # thumb base
    b.box((0.058, 0.06, 0.05), (-0.034, -0.062, -0.052), rot=(-15, 0, 0), color=GLOVE)  # wrist


@asset("viewmodel")
def forearm(b):
    b.lathe([(0.032, 0.0), (0.035, 0.05)], seg=6, rot=(-90, 0, 0), color="black")       # glove cuff
    b.lathe([(0.04, 0.04), (0.046, 0.3), (0.054, 0.7)], seg=6, rot=(-90, 0, 0),
            color={"olive": 3, "dgrass": 1})                                              # jacket sleeve
    b.lathe([(0.05, 0.2), (0.05, 0.26)], seg=6, rot=(-90, 0, 0), color="dgrass")          # rolled cuff band


# =============================== AMMO ======================================
# Single rounds for the HUD ammo counter, one per ammo type. Each stands upright on
# its base (origin at the bottom centre) and is real-world scale.
@asset("ammo")
def ammo_round_bullet(b):
    b.lathe([(0.0145, 0), (0.0145, 0.004), (0.012, 0.006), (0.013, 0.05)], seg=6, color="brass")  # rim + case
    b.lathe([(0.013, 0.05), (0.0115, 0.058), (0.007, 0.075), (0, 0.085)], seg=6, color="orange")  # bullet


@asset("ammo")
def ammo_round_shell(b):
    b.lathe([(0.0145, 0), (0.0145, 0.004), (0.0135, 0.005), (0.0135, 0.02)], seg=8, color="brass")  # head
    b.lathe([(0.013, 0.02), (0.013, 0.07), (0.011, 0.074), (0, 0.074)], seg=8, color="red")         # hull
    b.lathe([(0.0132, 0.03), (0.0132, 0.036)], seg=8, color="roof")                                  # crimp ring


@asset("ammo")
def ammo_round_rocket(b):
    b.lathe([(0.03, 0.03), (0.04, 0.05), (0.04, 0.3)], seg=8, color="gunmetal")      # nozzle + body
    b.lathe([(0.041, 0.24), (0.041, 0.265)], seg=8, color="yellow")                    # warning band
    b.lathe([(0.04, 0.3), (0.03, 0.36), (0.012, 0.4), (0, 0.41)], seg=8, color="red")  # warhead
    for a in (0, 90, 180, 270):
        with b.at(rot=(0, 0, a)):
            b.slab([(0.035, 0.0), (0.075, 0.0), (0.07, 0.04), (0.035, 0.1)], 0.008, plane="XZ",
                   color="steel")                                                      # tail fins


@asset("ammo")
def ammo_round_cell(b):
    b.box((0.05, 0.05, 0.016), (0, 0, 0.008), color="steel")               # base cap
    b.box((0.044, 0.044, 0.07), (0, 0, 0.051), color="gunmetal")            # casing
    b.box((0.03, 0.046, 0.05), (0, 0, 0.051), color="cyan", glow=True)      # charge window
    b.box((0.05, 0.05, 0.012), (0, 0, 0.092), color="steel")                # top cap
    b.cyl(0.008, 0.008, 0.014, seg=6, loc=(0, 0, 0.105), color="chrome")   # terminal


# ============================== PORTALS ====================================
# Kept last so adding it doesn't shift the random seeds of the assets above.
@asset("scenery")
def portal(b):
    """Stone ring gate on a low dais, facing -Y (+Z in glTF); walk through either side.
    The membrane filling the ring (center 0.885 m up, radius 1.45 m) uses the PS1_Portal
    material, so engines can swap in a shimmering see-through shader for it. The ring is
    sunk into a low dais with gently sloped sides you walk up, so the way through is a
    flat floor about 2.5 m wide; its lowest stones, buried completely, are left out."""
    cz, r = 0.16 + 1.45 / 2, 1.45
    b.cyl(2.5, 2.0, 0.16, seg=10, loc=(0, 0, 0.08), rot=(0, 0, 18), color={"stone": 3, "dstone": 1})
    for x in (-1.9, 1.9):  # buttresses bracing the ring's foot
        b.box((0.55, 0.9, 0.9), (x, 0, 0.55), color={"lstone": 2, "stone": 1}, jit=0.03)
    seg = 14
    with b.at(loc=(0, 0, cz), rot=(90, 0, 0)):
        for k in range(seg):
            a = 360 * (k + 0.5) / seg
            top = abs(a - 90) < 360 / seg
            if math.sin(math.radians(a)) < -0.85:
                continue
            with b.at(rot=(0, 0, a)):
                size = (0.5, 2 * (r + 0.25) * math.tan(math.pi / seg) * 1.04, 0.62 if top else 0.5)
                b.box(size, (r + 0.25, 0, 0), color={"lstone": 3, "stone": 1} if k % 2 else {"stone": 2, "lstone": 1},
                      jit=0.012)
                if k % 2 == 0 and not top:  # rune studs on both faces
                    for side in (-1, 1):
                        b.box((0.16, 0.12, 0.06), (r + 0.27, 0, side * 0.27), color="cyan", glow=True)
        b.box((0.7, 0.55, 0.75), (0, r + 0.32, 0), color="lstone", jit=0.02)  # keystone
        b.box((0.26, 0.2, 0.8), (0, r + 0.36, 0), color="cyan", glow=True)
        # Membrane: a flat 20-gon disc of one-sided faces; the engine draws it double-sided.
        n = 20
        coords = [(0, 0, 0)] + [(r * math.cos(2 * math.pi * k / n), r * math.sin(2 * math.pi * k / n), 0)
                                 for k in range(n)]
        b.poly(coords, [(0, 1 + k, 1 + (k + 1) % n) for k in range(n)], color="cyan", glow="portal")



@asset("scenery")
def conex(b):
    """20 ft military CONEX shipping container (6.06 x 2.44 x 2.59 m), long along X,
    cargo doors at the +X end. Corrugated olive-drab walls inside a dark steel frame."""
    L, W, H = 6.06, 2.44, 2.59
    body = {"olive": 8, "dirt": 1}  # the odd rust-stained panel
    # The wall behind the ribs is dark so the grooves between them read as shadow.
    b.box((L - 0.2, W - 0.12, H - 0.24), (0, 0, H / 2), color="dsoil")
    # Corrugation: vertical ribs standing proud of the long walls and the closed end.
    n = 20
    for k in range(n):
        x = -L / 2 + 0.3 + (L - 0.6) * (k + 0.5) / n
        for sy in (-1, 1):
            b.box((0.15, 0.05, H - 0.3), (x, sy * (W / 2 - 0.06), H / 2), color=body)
    for k in range(7):
        y = -W / 2 + 0.25 + (W - 0.5) * (k + 0.5) / 7
        b.box((0.05, 0.15, H - 0.3), (-L / 2 + 0.06, y, H / 2), color=body)
    b.box((L - 0.3, W - 0.3, 0.04), (0, 0, H - 0.1), color="olive")  # roof panel
    # Frame: corner posts, top and bottom rails, with corner castings at every corner.
    frame = "dgrass"
    for sx in (-1, 1):
        for sy in (-1, 1):
            b.box((0.16, 0.16, H), (sx * (L / 2 - 0.08), sy * (W / 2 - 0.08), H / 2), color=frame)
            for z in (0.06, H - 0.06):
                b.box((0.19, 0.17, 0.12), (sx * (L / 2 - 0.09), sy * (W / 2 - 0.085), z), color="gunmetal")
    for sy in (-1, 1):
        b.box((L - 0.3, 0.12, 0.16), (0, sy * (W / 2 - 0.06), 0.08), color=frame)
        b.box((L - 0.3, 0.12, 0.12), (0, sy * (W / 2 - 0.06), H - 0.06), color=frame)
        for x in (-0.9, 0.9):  # forklift pockets
            b.box((0.36, 0.02, 0.1), (x, sy * (W / 2 - 0.005), 0.08), color="black")
    for sx in (-1, 1):
        b.box((0.12, W - 0.3, 0.16), (sx * (L / 2 - 0.06), 0, 0.08), color=frame)
        b.box((0.12, W - 0.3, 0.2), (sx * (L / 2 - 0.06), 0, H - 0.1), color=frame)
    # Cargo doors: two leaves, each with two locking bars, cam keepers and a handle.
    dx = L / 2 - 0.04
    for side in (-1, 1):
        y0 = side * (W / 4 - 0.02)
        b.box((0.04, W / 2 - 0.2, H - 0.42), (dx, y0, H / 2), color="olive")
        for k in range(4):  # shallow horizontal door corrugation
            b.box((0.03, W / 2 - 0.28, 0.12), (dx + 0.03, y0, 0.55 + k * 0.5), color=body)
        for y in (y0 - side * 0.22, y0 + side * 0.22):
            b.cyl(0.022, 0.022, H - 0.36, seg=6, loc=(dx + 0.08, y, H / 2), color="steel")
            for z in (0.25, H - 0.25):
                b.box((0.06, 0.08, 0.08), (dx + 0.06, y, z), color="gunmetal")
            b.box((0.05, 0.03, 0.32), (dx + 0.11, y + side * 0.1, 1.15), rot=(0, 0, 0), color="steel")
        for z in (0.5, 1.3, 2.1):  # hinges on the outer edge
            b.box((0.06, 0.1, 0.14), (dx + 0.03, side * (W / 2 - 0.16), z), color="gunmetal")
    b.box((0.02, 0.3, 0.18), (dx + 0.06, -W / 4, 1.75), color="white")  # data plate
    b.box((0.03, 0.04, H - 0.4), (dx + 0.02, 0, H / 2), color="black")  # seam between leaves


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
def clear_objects(keep=()):
    for o in list(bpy.data.objects):
        if o.name not in keep:
            bpy.data.objects.remove(o, do_unlink=True)
    for m in list(bpy.data.meshes):
        bpy.data.meshes.remove(m)
    for a in list(bpy.data.armatures):
        bpy.data.armatures.remove(a)


def export_glb(obj, path):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    if obj.parent:
        obj.parent.select_set(True)  # the rig of a skinned model
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True,
                              export_apply=True, export_yup=True)


def generate():
    os.makedirs(OUT, exist_ok=True)
    clear_objects()
    img = build_palette_image()
    mats = (make_material(img, False), make_material(img, True), make_material(img, "portal"))
    results = []
    for i, (cat, name, fn) in enumerate(ASSETS):
        if ONLY and ONLY not in (cat, name):
            continue
        clear_objects()
        b = Builder(seed=1000 + i)
        fn(b)
        obj = b.to_object(name, mats)
        tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
        os.makedirs(os.path.join(OUT, cat), exist_ok=True)
        export_glb(obj, os.path.join(OUT, cat, name + ".glb"))
        results.append((cat, name, tris, tuple(obj.dimensions)))
    clear_objects()
    for cat, name, tris, dims in results:
        print(f"ASSET {cat:8} {name:26} {tris:5} tris  {dims[0]:.2f} x {dims[1]:.2f} x {dims[2]:.2f} m")
    return results


def render_previews(results):
    import numpy as np
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    sh = scene.display.shading
    sh.light, sh.color_type = "STUDIO", "TEXTURE"
    sh.show_shadows = False
    scene.render.resolution_x = scene.render.resolution_y = 256
    scene.render.film_transparent = False
    if scene.world is None:
        scene.world = bpy.data.worlds.new("w")
    scene.world.color = (0.55, 0.62, 0.66)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.data.type = "ORTHO"
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    by_cat = {}
    for cat, name, _, _ in results:
        clear_objects(keep=("cam",))
        bpy.ops.import_scene.gltf(filepath=os.path.join(OUT, cat, name + ".glb"))
        pts = [o.matrix_world @ v.co for o in scene.objects if o.type == "MESH" for v in o.data.vertices]
        lo = Vector([min(p[i] for p in pts) for i in range(3)])
        hi = Vector([max(p[i] for p in pts) for i in range(3)])
        c, rad = (lo + hi) / 2, (hi - lo).length / 2
        d = Vector((1.0, -1.4, 0.75)).normalized()
        cam.location = c + d * rad * 4
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        cam.data.ortho_scale = rad * 2.1
        cam.data.clip_end = rad * 10
        path = os.path.join(PREVIEW_DIR, name + ".png")
        scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        by_cat.setdefault(cat, []).append(path)
    for cat, paths in by_cat.items():
        cols = 5
        rows = math.ceil(len(paths) / cols)
        sheet = np.zeros((rows * 256, cols * 256, 4), dtype=np.float32)
        for i, p in enumerate(paths):
            im = bpy.data.images.load(p)
            a = np.empty(256 * 256 * 4, dtype=np.float32)
            im.pixels.foreach_get(a)
            r, c = rows - 1 - i // cols, i % cols
            sheet[r * 256:(r + 1) * 256, c * 256:(c + 1) * 256] = a.reshape(256, 256, 4)
            bpy.data.images.remove(im)
        out = bpy.data.images.new("sheet_" + cat, cols * 256, rows * 256)
        out.pixels.foreach_set(sheet.ravel())
        out.filepath_raw = os.path.join(PREVIEW_DIR, f"sheet_{cat}.png")
        out.file_format = "PNG"
        out.save()


if __name__ == "__main__":
    res = generate()
    if PREVIEW_DIR:
        render_previews(res)
