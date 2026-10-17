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
    mat = bpy.data.materials.new({False: "PS1_Palette", True: "PS1_Glow", "portal": "PS1_Portal",
                                  "water": "PS1_Water"}[glow])
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    if glow == "water":
        # Placeholder look (previews, other engines): flat see-through blue-green. Its UVs
        # are flow coordinates, not palette cells, so it doesn't sample the palette.
        bsdf.inputs["Base Color"].default_value = (*hex_rgb("#2A4252"), 1.0)
        bsdf.inputs["Alpha"].default_value = 0.75
        bsdf.inputs["Roughness"].default_value = 0.3
        mat.surface_render_method = "BLENDED"
        return mat
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


# Material slot per `glow` value: plain palette, emissive palette, portal membrane,
# flowing water.
MAT_INDEX = {False: 0, True: 1, "portal": 2, "water": 3}


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
            if f.material_index == MAT_INDEX["water"]:
                # Water UVs are model-space meters, u along the flow (+X), so the engine's
                # shader can scroll ripples downstream however the model is turned.
                for l in f.loops:
                    l[uvl].uv = (l.vert.co.x, l.vert.co.y)
                continue
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


def smoothstep(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def edge_window(x, y):
    return math.sin(math.pi * (x / TILE + 0.5)) * math.sin(math.pi * (y / TILE + 0.5))


def make_noise(rng, amp):
    waves = [(rng.uniform(0.5, 1.4), rng.uniform(0.5, 1.4), rng.uniform(0, 6.3), rng.uniform(0, 6.3))
             for _ in range(4)]
    return lambda x, y: amp * sum(math.sin(x * a + p) * math.sin(y * b + q) for a, b, p, q in waves) / 2


def terrain(b, hfn, color, jit=0.07, seg=TILE_SEG):
    """8x8 m height-field tile. hfn must return 0 on the tile border so tiles connect.
    A finer grid (`seg` a multiple of TILE_SEG) keeps the standard TILE_SEG spacing on
    its y = +-4 m edges, so it meets ordinary tiles there vertex for vertex: an extra
    vertex partway along a neighbour's edge (a T-junction) would be snapped to the pixel
    grid on its own and open a see-through crack along the seam. (Its x edges keep the
    fine spacing, for tiles of the same kind chained along x.)"""
    h, st, n = TILE / 2, TILE / seg, seg
    step = seg // TILE_SEG
    grid = []
    for j in range(n + 1):
        row = []
        for i in range(n + 1):
            if j in (0, n) and i % step:
                row.append(None)  # not on the coarse edge: left out
                continue
            x, y = -h + i * st, -h + j * st
            z = hfn(x, y) + (b.rng.uniform(-jit, jit) if 0 < i < n and 0 < j < n else 0)
            row.append(b.bm.verts.new((x, y, z)))
        grid.append(row)
    for j in range(n):
        for i in range(n):
            if step > 1 and j in (0, n - 1):
                continue  # the edge strips are built below
            b.bm.faces.new((grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]))
    if step > 1:
        # Edge strips: one face per coarse edge segment, fanning to the fine row inside.
        for i0 in range(0, n, step):
            inner = [grid[1][i] for i in range(i0, i0 + step + 1)]
            b.bm.faces.new([grid[0][i0], grid[0][i0 + step]] + inner[::-1])
            inner = [grid[n - 1][i] for i in range(i0, i0 + step + 1)]
            b.bm.faces.new(inner + [grid[n][i0 + step], grid[n][i0]])
    return b.paint([v for row in grid for v in row if v], color)


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
    """Lookout tower with a 3.6 m square deck (top at z=4.7) under a pyramid roof. A ladder
    on the -Y side climbs to a gap in the railing; a second gap on the +Y side is where a
    bridge_plank docks, so two towers facing each other 9.7 m apart (center to center)
    can be joined."""
    top, half = 4.7, 1.8

    def leg(z):  # distance of the splayed legs from the center at height z
        return 1.55 - 0.2 * z / (top - 0.2)
    for sx in (-1, 1):
        for sy in (-1, 1):
            b.beam((sx * leg(0), sy * leg(0), 0), (sx * leg(top), sy * leg(top), top - 0.2), 0.24, color="dbark")
    for side in range(4):
        gap = side in (0, 2)  # ladder (-Y) and bridge (+Y)
        with b.at(rot=(0, 0, 90 * side)):
            for z0, z1 in ((0.3, 2.35), (2.35, 4.4)):  # two tiers of cross braces
                for s in (-1, 1):
                    b.beam((-s * leg(z0), -leg(z0) - 0.13, z0), (s * leg(z1), -leg(z1) - 0.13, z1), 0.08,
                           color="wood")
            b.box((2 * leg(2.35), 0.1, 0.12), (0, -leg(2.35) - 0.13, 2.35), color="wood")
            b.box((3.6, 0.12, 0.25), (0, -half + 0.06, top - 0.32), color="dbark")  # rim joist
            b.box((0.12, 0.12, 2.2), (1.72, -1.72, top + 1.1), color="wood")  # corner post
            for z in (top + 0.5, top + 0.95):
                if gap:
                    for s in (-1, 1):
                        b.box((1.2, 0.08, 0.1), (s * 1.12, -1.75, z), color="lwood")
                else:
                    b.box((3.5, 0.08, 0.1), (0, -1.75, z), color="lwood")
            if gap:
                for s in (-1, 1):
                    b.box((0.1, 0.1, 1.05), (s * 0.55, -1.75, top + 0.52), color="wood")
    b.box((2 * half, 2 * half, 0.2), (0, 0, top - 0.1), color={"lwood": 2, "wood": 1}, cuts=3)
    for x in (-0.9, 0, 0.9):
        b.box((0.14, 2 * half - 0.2, 0.18), (x, 0, top - 0.29), color="dbark")  # floor beams
    b.cyl(2.85, 0, 1.4, seg=4, loc=(0, 0, top + 2.2 + 0.7), rot=(0, 0, 45), color={"roof": 3, "dbark": 1})
    b.box((3.6, 3.6, 0.08), (0, 0, top + 2.2 - 0.04), color="dbark")  # ceiling under the roof
    # Ladder: 0.3 m out from the deck's edge, its rails running on up past the deck as
    # handholds either side of the railing gap.
    ly = -half - 0.3
    for x in (-0.45, 0.45):
        b.box((0.08, 0.08, top + 1.0), (x, ly, (top + 1.0) / 2), color="dbark")
        b.box((0.08, 0.32, 0.08), (x, ly + 0.17, top - 0.15), color="dbark")  # brackets to the deck
        b.box((0.08, 0.52, 0.08), (x, ly + 0.26, 2.35), color="dbark")
    for i in range(1, 16):
        b.box((0.82, 0.07, 0.07), (0, ly, 0.3 * i), color="wood")


@asset("scenery")
def bridge_plank(b):
    """Plank footbridge between two watchtowers, 6.4 m long along Y and 1 m wide, with
    rope handrails. Its deck is at z=0 at both ends and sags 0.15 m in the middle. The
    last 0.15 m at each end rests on a tower's deck, through the railing gap."""
    L, n = 6.4, 17

    def sag(y):
        return -0.15 * (1 - (2 * y / L) ** 2)
    for i in range(n):
        y = -L / 2 + (i + 0.5) * L / n
        tilt = math.degrees(math.atan(0.15 * 8 * y / L ** 2))
        b.box((1.0 + b.rng.uniform(-0.06, 0.06), L / n - 0.04, 0.06),
              (b.rng.uniform(-0.03, 0.03), y, sag(y) - 0.03), rot=(tilt, 0, b.rng.uniform(-2, 2)),
              color={"wood": 3, "lwood": 2, "dbark": 1})
    ys = [-L / 2 + L * k / 8 for k in range(9)]
    for x in (-0.32, 0.32):  # stringers under the planks
        for y0, y1 in zip(ys, ys[1:]):
            b.beam((x, y0, sag(y0) - 0.1), (x, y1, sag(y1) - 0.1), 0.1, color="dbark")
    end = L / 2 - 0.27  # the posts stand just off the towers' decks
    for sy in (-1, 1):
        for x in (-0.5, 0.5):
            b.box((0.1, 0.1, 1.35), (x, sy * end, 0.35), color="dbark")
    # Rope handrails at two heights, hanging in a shallow curve, with hangers down to
    # the deck edge.
    for x in (-0.5, 0.5):
        for h, droop in ((1.0, 0.25), (0.5, 0.15)):
            pts = [(x, y, h + sag(y) / 0.15 * droop) for y in
                   (-end + 2 * end * k / 10 for k in range(11))]
            for p0, p1 in zip(pts, pts[1:]):
                b.beam(p0, p1, 0.045, color="lsand")
        for k in range(1, 8):
            y = -end + 2 * end * k / 8
            b.beam((x, y, sag(y)), (x, y, 1.0 + sag(y) / 0.15 * 0.25), 0.03, color="sand")


@asset("scenery")
def ruins_pillar(b):
    b.box((1.0, 1.0, 0.3), (0, 0, 0.15), color={"lstone": 2, "stone": 1}, jit=0.03)
    v = b.lathe([(0.38, 0.3), (0.35, 1.5), (0.34, 2.7)], seg=8, color="lstone")
    b.jitter([x for x in v if x.co.z > 2.6], (0.04, 0.04, 0.35))
    b.paint(v, lambda f: {"olive": 1, "lstone": 1} if f.calc_center_median().z < 0.9 else {"lstone": 3, "stone": 1})


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
    # Eight rigged legs. Each is one tube from hip to toe skinned to two bones,
    # leg_<side>_<k>_0 (hip to knee) and leg_<side>_<k>_1 (knee to toe), side l (-X) or
    # r (+X) and k = 0 at the front, both chained to the "body" bone, which everything
    # else follows. The game plants the toes on the ground and bends the knees to reach
    # them as it walks (see scripts/enemies/spider.gd).
    b.bone("body", (0, 0, 0.55), (0, 0, 0.85))
    for s, side in ((-1, "l"), (1, "r")):
        for k, y in enumerate((-0.3, -0.12, 0.06, 0.24)):
            spread = (y - 0.0) * 1.8
            p0 = Vector((s * 0.2, y, 0.55))
            p1 = Vector((s * 0.75, y + spread * 0.5, 0.95))
            p2 = Vector((s * 1.15, y + spread, 0.0))
            hip, shin = f"leg_{side}_{k}_0", f"leg_{side}_{k}_1"
            b.bone(hip, p0, p1, "body")
            b.bone(shin, p1, p2, hip)
            pts = [p0, p0.lerp(p1, 0.5), p1, p1.lerp(p2, 0.5), p2]
            rings = b.tube(pts, [0.05, 0.045, 0.04, 0.026, 0.0], seg=4, color={"black": 2, "dbark": 1})
            for ring, w in zip(rings, ({hip: 1.0}, {hip: 1.0}, {hip: 0.5, shin: 0.5}, {shin: 1.0}, {shin: 1.0})):
                b.weigh(ring, w)


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


# How far the arcane eye's lids are turned open at rest (degrees); the game turns them
# back by this much to shut them (scripts/enemies/arcane_eye.gd, LID_OPEN).
LID_OPEN = 50


@asset("enemies")
def enemy_arcane_eye(b):
    """An ornate floating eye; origin at the eyeball's center, looking -Y (offset it above
    the ground in game). A pale, veined eyeball with a glowing violet iris and a black slit
    pupil, set in a thorny brass frame with crescent horns, a crowned gem on top and violet
    gems round the rim. Chains hang from the frame ending in violet crystals, and tattered
    violet cloth hangs at each side.

    Rigged so every hanging can swing and bend: body (the eye and frame) carries each
    chain as pendant_<k>_0 > pendant_<k>_1 > pendant_<k>_2 (top to bottom, the crystal on
    the last; k = 0 to 4 from left to right), and each cloth strip as
    cloth_<side>_<k>_0 > _1 > _2 (top to bottom; side l at -X and r at +X as seen from the
    front, k = 0 to 4 from the inside out). The links of a chain each follow one bone; the
    cloth bends smoothly between its bones. Its eyelids, lid_upper and lid_lower, are
    hinged at the eye's center about X; at rest they're open (folded back above and below
    the iris), and turning them shut by LID_OPEN degrees each (upper down, lower up)
    closes them across the middle of the eye."""
    brass = {"brass": 3, "olive": 1}
    tarnish = {"olive": 2, "brass": 1, "dbark": 1}
    R = 0.38           # eyeball radius
    RING = 0.45        # frame radius, in the XZ plane

    def on_ring(deg, r=RING, y=0.0):
        a = math.radians(deg)
        return Vector((math.cos(a) * r, y, math.sin(a) * r))

    # Pendants: (frame angle in degrees, chain length, crystal size), left to right.
    pendants = [(186, 0.34, 0.8), (238, 0.26, 0.75), (270, 0.36, 1.25), (302, 0.26, 0.75), (354, 0.34, 0.8)]
    tops = []
    for deg, length, _ in pendants:
        top = on_ring(deg, RING + 0.05, 0.0)
        if deg in (186, 354):
            top = Vector((top.x * 1.22, 0.0, -0.06))  # hung from the side horns' roots
        tops.append(top)

    # Cloth strips per side, inside out: (x, y, top, length, width). Laid out here, with
    # their own random numbers, so the bones can be made before the geometry.
    crng = random.Random(77)
    strips = {}
    for side, s in (("l", -1), ("r", 1)):
        strips[side] = [(s * (0.4 + k * 0.055 + crng.uniform(-0.01, 0.01)), 0.08 + k * 0.004, -0.08 - k * 0.03,
                         crng.uniform(0.45, 0.78), crng.uniform(0.05, 0.07)) for k in range(5)]
    SEGS = 3  # bones per chain and per strip

    # Skeleton (before any geometry: adding the weight layer invalidates vertices).
    b.bone("body", (0, 0, 0), (0, 0, 0.3))
    b.bone("lid_upper", (0, 0, 0), (0, -0.25, 0.0), "body")
    b.bone("lid_lower", (0, 0, 0), (0, -0.25, 0.0), "body")
    for k, ((deg, length, size), top) in enumerate(zip(pendants, tops)):
        tip = top + Vector((0, 0, -length - 0.02))
        for j in range(SEGS):
            b.bone(f"pendant_{k}_{j}", top.lerp(tip, j / SEGS), top.lerp(tip, (j + 1) / SEGS),
                   "body" if j == 0 else f"pendant_{k}_{j - 1}")
    for side in strips:
        for k, (x, y, top_z, length, width) in enumerate(strips[side]):
            for j in range(SEGS):
                b.bone(f"cloth_{side}_{k}_{j}", (x, y, top_z - length * j / SEGS), (x, y, top_z - length * (j + 1) / SEGS),
                       "body" if j == 0 else f"cloth_{side}_{k}_{j - 1}")

    def gem(loc, size, rot=(0, 0, 0), stretch=1.6):
        """A violet crystal: a six-sided bipyramid along Z, glowing."""
        return b.lathe([(0.0, -size * stretch), (size, 0.0), (0.0, size * stretch)], seg=6,
                       loc=loc, rot=rot, color="purple", glow=True)

    def thorn(p, d, length, width, color=tarnish):
        p, d = Vector(p), Vector(d).normalized()
        return b.limb(p, p + d * length, width, 0, 4, color)

    # The eyeball, pale with a flush of pink, and red veins creeping in from the back.
    b.sphere(R, 14, 10, color={"bone": 4, "flesh": 1, "white": 1})
    for k in range(9):
        a = 2 * math.pi * k / 9 + b.rng.uniform(-0.2, 0.2)
        pts = []
        for j in range(5):
            polar = math.radians(78 - j * 9)  # from the side of the eye in toward the iris
            twist = a + b.rng.uniform(-0.12, 0.12) * j
            d = Vector((math.sin(polar) * math.cos(twist), -math.cos(polar), math.sin(polar) * math.sin(twist)))
            pts.append(d * (R + 0.003))
        b.tube(pts, [0.008, 0.007, 0.006, 0.004, 0.0], seg=3, color="red")

    # The iris: a glowing violet dome on the front of the eye with a dark rim, a black
    # slit pupil and a white glint.
    Rf = R + 0.004
    iris = math.radians(39)
    with b.at(rot=(90, 0, 0)):  # lathe's +Z now points out of the eye's front (-Y)
        b.lathe([(math.sin(iris + 0.05) * Rf, math.cos(iris + 0.05) * Rf), (math.sin(iris) * Rf, math.cos(iris) * Rf)],
                seg=16, color="black")
        b.lathe([(math.sin(iris) * Rf, math.cos(iris) * Rf), (math.sin(iris * 0.66) * (Rf + 0.004), math.cos(iris * 0.66) * (Rf + 0.004)),
                 (math.sin(iris * 0.33) * (Rf + 0.006), math.cos(iris * 0.33) * (Rf + 0.006)), (0.0, Rf + 0.007)],
                seg=16, color="purple", glow=True)
    front = lambda x, z, lift: -(math.sqrt(max(Rf * Rf - x * x - z * z, 0.0)) + lift)
    slit = [(0, front(0, 0.16, 0.022), 0.16), (-0.04, front(0.04, 0, 0.022), 0), (0, front(0, -0.16, 0.022), -0.16),
            (0.04, front(0.04, 0, 0.022), 0), (0, front(0, 0, 0.026), 0)]
    b.poly(slit, [(0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)], color="black")
    b.ico(0.028, 1, loc=(0.085, front(0.085, 0.1, 0.012), 0.1), scale=(1, 0.4, 1), color="white", glow=True)

    # Eyelids: a curved shell above and below, hugging the eyeball just clear of the iris
    # and pupil, fleshy with a dark red rim along the edge. Each is modeled closed (its
    # edge across the middle of the eye) and then turned open about X, so the rest pose
    # is open; the game turns them back by LID_OPEN to blink.
    def eyelid(upper):
        r_out, r_in = R + 0.058, R + 0.042
        sign = 1 if upper else -1
        span = math.radians(84)
        alphas = [-span + 2 * span * i / 10 for i in range(11)]
        # Reaching 50 degrees up (or down) the eye: shut, that covers the iris (39 degrees)
        # and pupil; open, they tuck in at the top and bottom, under the cage, instead of
        # wrapping over the back.
        betas = [math.radians(sign * d) for d in (0, 10, 20, 30, 40, 50)]

        def pt(r, a, be):
            return (r * math.cos(be) * math.sin(a), -r * math.cos(be) * math.cos(a), r * math.sin(be))
        na, nb = len(alphas), len(betas)
        coords = [pt(r_out, a, be) for be in betas for a in alphas] + [pt(r_in, a, be) for be in betas for a in alphas]
        o = lambda j, i: j * na + i
        n = lambda j, i: na * nb + j * na + i
        faces = []
        for j in range(nb - 1):
            for i in range(na - 1):
                faces.append((o(j, i), o(j, i + 1), o(j + 1, i + 1), o(j + 1, i)))
                faces.append((n(j, i), n(j + 1, i), n(j + 1, i + 1), n(j, i + 1)))
        for i in range(na - 1):  # the edge across the eye, and the far edge
            faces.append((o(0, i), n(0, i), n(0, i + 1), o(0, i + 1)))
            faces.append((o(nb - 1, i), o(nb - 1, i + 1), n(nb - 1, i + 1), n(nb - 1, i)))
        for j in range(nb - 1):  # the two ends
            faces.append((o(j, 0), o(j + 1, 0), n(j + 1, 0), n(j, 0)))
            faces.append((o(j, na - 1), n(j, na - 1), n(j + 1, na - 1), o(j + 1, na - 1)))
        with b.at(rot=(-sign * LID_OPEN, 0, 0)):
            verts = list(b.poly(coords, faces, color={"flesh": 3, "bone": 1}))
            rim = [Vector(pt(r_out - 0.004, a, betas[0] + sign * 0.03)) for a in alphas]
            for ring in b.tube(rim, [0.012] * (len(rim) - 1) + [0.0], seg=4, color="roof"):
                verts += ring
        b.weigh([v for v in verts if v.is_valid], {"lid_upper" if upper else "lid_lower": 1.0})

    eyelid(True)
    eyelid(False)

    # The frame: a heavy brass rim round the eye, a thinner band tilted behind it, and
    # thorns all round.
    b.ring(RING, 0.075, seg=16, width=0.06, rot=(90, 0, 0), color=brass)
    b.ring(RING - 0.05, 0.035, seg=16, width=0.07, loc=(0, -0.04, 0), rot=(90, 0, 0), color=tarnish)
    b.ring(RING + 0.03, 0.035, seg=16, width=0.04, loc=(0, 0.07, 0), rot=(104, 0, 0), color=tarnish)
    for deg in range(0, 360, 24):
        if 60 < deg < 120 or deg in (264, 288):  # the crown, and the center pendant's hook
            continue
        out = on_ring(deg, 1.0)
        thorn(on_ring(deg, RING + 0.03), out + Vector((0, -0.35, 0)) + Vector((0, 0, 0.25)) * (1 if out.z > -0.3 else -0.2),
              b.rng.uniform(0.07, 0.13), 0.022)

    # Crescent horns sweeping up and in from the upper corners, and smaller horns at the
    # sides, each with a barb.
    for s in (-1, 1):
        b.tube([(s * 0.3, 0.02, 0.34), (s * 0.46, 0.03, 0.52), (s * 0.47, 0.04, 0.72), (s * 0.36, 0.05, 0.86), (s * 0.24, 0.05, 0.9)],
               [0.055, 0.045, 0.032, 0.018, 0.0], seg=5, color=brass)
        thorn((s * 0.46, 0.03, 0.55), (-s * 0.6, -0.2, 0.5), 0.1, 0.02, brass)
        b.tube([(s * 0.47, 0.0, 0.02), (s * 0.6, 0.0, 0.12), (s * 0.66, 0.01, 0.3), (s * 0.62, 0.02, 0.42)],
               [0.045, 0.034, 0.018, 0.0], seg=5, color=brass)
        thorn((s * 0.6, 0.0, 0.14), (s, -0.1, -0.5), 0.09, 0.02, brass)

    # The crown: a pointed brass shield above the eye holding a large gem, flanked by spikes.
    b.cyl(0.12, 0.0, 0.42, seg=4, loc=(0, 0.0, 0.66), rot=(0, 0, 45), scale=(1.0, 0.45, 1.0), color=brass)
    b.cyl(0.13, 0.08, 0.08, seg=6, loc=(0, 0.0, 0.47), color=tarnish)
    gem((0, -0.07, 0.6), 0.055, rot=(0, 0, 0), stretch=1.5)
    for s in (-1, 1):
        thorn((s * 0.1, 0.0, 0.5), (s * 0.7, -0.1, 1.0), 0.16, 0.025, brass)

    # Gems set into the rim at the sides and the bottom.
    for deg in (160, 20, 214, 326):
        p = on_ring(deg, RING, -0.05)
        gem(p, 0.04, rot=(0, -deg + 90, 0), stretch=1.3)

    # The back: a brass cage over the eyeball. A strap runs from the crown over the back to
    # the bottom of the rim and another across from side to side, both studded with thorns,
    # and where they cross sits a medallion of rings and spikes round a violet gem. Two
    # violet sashes are draped across the back from the upper corners.
    CAGE = R + 0.075  # clear of the eyelids folded back above and below

    def arc(a, m, c, n, r):
        """Points on a sphere of radius r, curving from direction a through m to c."""
        a, m, c = Vector(a).normalized(), Vector(m).normalized(), Vector(c).normalized()
        return [(a.lerp(m, t).lerp(m.lerp(c, t), t)).normalized() * r for t in (i / n for i in range(n + 1))]

    for path in (arc((0, 0.12, 1), (0, 1, 0), (0, 0.12, -1), 12, CAGE),
                 arc((-1, 0.12, 0), (0, 1, 0), (1, 0.12, 0), 12, CAGE)):
        b.tube(path, [0.03] * len(path), seg=4, color=brass)
        for i in range(1, len(path) - 1, 2):
            p = path[i]
            side = (path[i + 1] - path[i - 1]).cross(p).normalized()
            for s in (-1, 1):
                if abs(p.y) < CAGE * 0.9 or i % 4 == 1:  # leave the medallion clear
                    thorn(p + side * s * 0.02, side * s + p.normalized() * 0.6, 0.06, 0.016)
    with b.at(loc=(0, CAGE + 0.01, 0), rot=(90, 0, 0)):  # the medallion faces out of the back (+Y)
        b.cyl(0.15, 0.13, 0.03, seg=12, color=tarnish)
        b.ring(0.13, 0.03, seg=12, width=0.03, loc=(0, 0, -0.02), color=brass)
        b.ring(0.085, 0.025, seg=10, width=0.03, loc=(0, 0, -0.035), color=brass)
        for k in range(8):
            a = 2 * math.pi * (k + 0.5) / 8
            d = Vector((math.cos(a), math.sin(a), 0))
            thorn(d * 0.14 + Vector((0, 0, -0.02)), d + Vector((0, 0, -0.25)), 0.07, 0.018, brass)
    gem((0, CAGE + 0.055, 0), 0.045, rot=(90, 0, 0), stretch=1.3)
    for s in (-1, 1):
        sash = arc((s * 0.8, 0.25, 0.6), (s * 0.35, 1, 0.1), (s * 0.05, 0.4, -0.95), 10, CAGE - 0.012)
        for p0, p1 in zip(sash, sash[1:]):
            out = p0.normalized()
            along = (p1 - p0).normalized()
            side = along.cross(out).normalized() * 0.04
            q = [p0 - side, p0 + side, p1 + side, p1 - side]
            coords = [v + out * 0.008 for v in q] + [v - out * 0.004 for v in q]
            b.poly(coords, [(0, 1, 2, 3), (7, 6, 5, 4), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)],
                   color={"purple": 4, "black": 1})

    # Chains: links hanging from the frame, each ending in a brass cap and a crystal.
    for k, ((deg, length, size), top) in enumerate(zip(pendants, tops)):
        hook = b.cyl(0.03, 0.03, 0.035, seg=6, loc=top, rot=(0, 90, 0), color=tarnish)
        b.weigh([v for v in hook if v.is_valid], {"body": 1.0})
        n = max(3, round(length / 0.055))
        for j in range(n):
            z = top.z - 0.03 - j * (length / n)
            link = b.box((0.024, 0.01, 0.05), (top.x, top.y, z), rot=(0, 0, 90 * (j % 2)), color=brass)
            seg = min(int((top.z - z) / (length + 0.02) * SEGS), SEGS - 1)  # each link rides one bone
            b.weigh([v for v in link if v.is_valid], {f"pendant_{k}_{seg}": 1.0})
        tip = Vector((top.x, top.y, top.z - length - 0.02))
        verts = list(b.cyl(0.04 * size, 0.012, 0.05 * size, seg=6, loc=tip + Vector((0, 0, 0.01)), rot=(180, 0, 0), color=brass))
        verts += gem(tip + Vector((0, 0, -0.07 * size)), 0.045 * size, rot=(0, 0, 30 * k), stretch=1.6)
        b.weigh([v for v in verts if v.is_valid], {f"pendant_{k}_{SEGS - 1}": 1.0})

    # Tattered cloth at each side: strips of violet hanging from behind the frame, of
    # uneven lengths, ragged along their edges and torn at the ends. Each is a thin slab
    # whose outline has a vertex every row, so it bends along its three bones, blending
    # smoothly from one to the next.
    for side in strips:
        for k, (x, y, top_z, length, width) in enumerate(strips[side]):
            rows = 6
            left, right = [], []
            for r in range(rows + 1):
                z = top_z - length * r / rows
                left.append((x - width / 2 + (crng.uniform(-0.012, 0.012) if r else 0.0), z))
                right.append((x + width / 2 + (crng.uniform(-0.012, 0.012) if r else 0.0), z))
            # A torn end: a jagged point or two below the last row.
            bottom = [(x + width * 0.2, top_z - length - crng.uniform(0.02, 0.07)),
                      (x - width * 0.25, top_z - length - crng.uniform(0.0, 0.05))]
            with b.at(loc=(0, y, 0)):
                strip = b.slab(left + bottom[::-1] + right[::-1], 0.01, plane="XZ", color={"purple": 6, "black": 1})
            for v in strip:
                if not v.is_valid:
                    continue
                # u runs 0 to 3 down the strip; each bone weighs most at its middle.
                u = min(max((top_z - v.co.z) / length * SEGS, 0.0), SEGS)
                w = {j: max(0.0, 1.0 - abs(u - (j + 0.5))) for j in range(SEGS)}
                if u < 0.5:
                    w = {0: 1.0}
                elif u > SEGS - 0.5:
                    w = {SEGS - 1: 1.0}
                total = sum(w.values())
                b.weigh([v], {f"cloth_{side}_{k}_{j}": wj / total for j, wj in w.items() if wj > 0})


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
def enemy_shadow_cat(b):
    """Black shadow cat, faces -Y, ~1.4 m tall to its ear tips: a chibi creature with an
    oversized head, huge fennec ears, glowing red crescent eyes that drip, spiky fur
    tufts on its head, cheeks and chest, and a bushy tail curling up over its back.
    It's caught mid-stride, its right forepaw lifted.

    Rigged for animation (rest pose as modeled). Sides are the cat's own: l is +X, r is -X.
      hips (root, at the rump) > chest > neck > head > ear_<side>_0 > ear_<side>_1
      chest > leg_f<side>_0 (shoulder to elbow) > leg_f<side>_1 (to wrist) > paw_f<side>
      hips > leg_b<side>_0 (hip to knee) > leg_b<side>_1 (to hock) > leg_b<side>_2 (to ankle) > paw_b<side>
      hips > tail_0 (root) > ... > tail_5 (tip)
    Everything on the head (eyes, tufts) follows `head`; the chest ruff follows `chest`.
    Joints are skinned half to each neighbouring bone so they bend smoothly."""
    fur = {"black": 3, "gunmetal": 2}
    dark = {"black": 3, "gunmetal": 1}
    inner = {"dsoil": 3, "roof": 1}
    hc, hr = Vector((0, -0.36, 0.8)), Vector((0.29, 0.26, 0.26))

    def on_head(u, depth=1.0):
        """Point on the head's surface in direction u from its center."""
        u = Vector(u).normalized()
        return hc + Vector((u.x * hr.x, u.y * hr.y, u.z * hr.z)) * depth

    def face(x, z, proud=0.012):
        """Point on the front of the head at (x, z), standing `proud` off it."""
        k = 1 - (x / hr.x) ** 2 - ((z - hc.z) / hr.z) ** 2
        return Vector((x, hc.y - hr.y * math.sqrt(max(k, 0.0)) - proud, z))

    # Layout shared by the skeleton and the mesh.
    ears = {side: (on_head((s * 0.6, 0.15, 0.75), 0.85), (-14, s * 42, 0)) for side, s in (("l", 1), ("r", -1))}
    front_legs = {"l": [(0.1, -0.27, 0.44), (0.11, -0.3, 0.26), (0.11, -0.32, 0.08)],
                  "r": [(-0.1, -0.27, 0.44), (-0.12, -0.4, 0.31), (-0.11, -0.52, 0.18)]}  # lifted, same lengths
    back_legs = {}
    for side, s in (("l", 1), ("r", -1)):
        y = 0.2 if s > 0 else 0.24
        back_legs[side] = [(s * 0.11, y, 0.48), (s * 0.13, y + 0.06, 0.3), (s * 0.12, y + 0.09, 0.19),
                           (s * 0.11, y + 0.02, 0.08)]
    tail = [Vector(p) for p in ((0, 0.32, 0.5), (0, 0.47, 0.58), (0, 0.6, 0.8), (0, 0.58, 1.04),
                                (0, 0.42, 1.2), (0, 0.24, 1.2), (0, 0.16, 1.12))]

    def paw_toe(ankle):
        p = Vector(ankle)
        return Vector((p.x, p.y - 0.11, max(p.z - 0.04, 0.04)))

    # Skeleton (before any geometry: adding the weight layer invalidates vertices).
    b.bone("hips", (0, 0.3, 0.48), (0, 0.02, 0.46))
    b.bone("chest", (0, 0.02, 0.46), (0, -0.25, 0.5), "hips")
    b.bone("neck", (0, -0.25, 0.5), (0, -0.3, 0.62), "chest")
    b.bone("head", (0, -0.3, 0.62), (0, -0.36, 1.06), "neck")
    for side, (base, rot) in ears.items():
        mid, tip = M(base, rot) @ Vector((0, 0, 0.24)), M(base, rot) @ Vector((0, 0, 0.56))
        b.bone(f"ear_{side}_0", base, mid, "head")
        b.bone(f"ear_{side}_1", mid, tip, f"ear_{side}_0")
    for side, pts in front_legs.items():
        b.bone(f"leg_f{side}_0", pts[0], pts[1], "chest")
        b.bone(f"leg_f{side}_1", pts[1], pts[2], f"leg_f{side}_0")
        b.bone(f"paw_f{side}", pts[2], paw_toe(pts[2]), f"leg_f{side}_1")
    for side, pts in back_legs.items():
        b.bone(f"leg_b{side}_0", pts[0], pts[1], "hips")
        b.bone(f"leg_b{side}_1", pts[1], pts[2], f"leg_b{side}_0")
        b.bone(f"leg_b{side}_2", pts[2], pts[3], f"leg_b{side}_1")
        b.bone(f"paw_b{side}", pts[3], paw_toe(pts[3]), f"leg_b{side}_2")
    for k in range(len(tail) - 1):
        b.bone(f"tail_{k}", tail[k], tail[k + 1], "hips" if k == 0 else f"tail_{k - 1}")

    def spike(p, d, length, width, color=fur):
        """A tuft of fur: a four-sided cone from p, `length` along d."""
        p, d = Vector(p), Vector(d).normalized()
        return b.limb(p, p + d * length, width, 0, 4, color)

    def chain(rings, bones):
        """Skin a tube's rings along a bone chain: rings[i] sits at the joint between
        bones[i - 1] and bones[i], so it bends half with each (the ends follow one bone)."""
        for i, ring in enumerate(rings):
            if i == 0 or i >= len(bones):
                b.weigh(ring, {bones[min(i, len(bones)) - 1 if i else 0]: 1.0})
            else:
                b.weigh(ring, {bones[i - 1]: 0.5, bones[i]: 0.5})

    # Head: a wide ellipsoid that the eyes, ears and tufts are placed on.
    head = list(b.ico(1.0, 2, loc=hc, scale=hr, color=fur, jit=0.008))
    head += b.ico(0.08, 1, loc=(0, -0.59, 0.7), scale=(1.15, 0.8, 0.75), color={"gunmetal": 2, "black": 1})
    head += b.box((0.045, 0.02, 0.028), (0, -0.655, 0.725), color="black")

    # Crescent eyes, open toward +X like the reference, conforming to the head, each
    # dripping glowing red from its lower horn.
    for ex in (-0.125, 0.125):
        ez, rad = 0.82, 0.085
        n = 13
        pts, radii = [], []
        for i in range(n + 1):
            t = i / n
            a = math.radians(55 + 250 * t)
            pts.append(face(ex + rad * math.cos(a), ez + rad * math.sin(a)))
            radii.append(0.027 * math.sin(math.pi * t) ** 0.6 if 0 < i < n else (0.004 if i == 0 else 0.0))
        head += [v for r in b.tube(pts, radii, seg=5, color="red", glow=True) for v in r]
        for a, drop in ((255, 0.08), (290, 0.13)):
            x0 = ex + rad * math.cos(math.radians(a))
            z0 = ez + rad * math.sin(math.radians(a))
            run = [face(x0, z0 - drop * t, 0.008) for t in (0.0, 0.5, 1.0)]
            head += [v for r in b.tube(run, [0.011, 0.008, 0.0], seg=4, color="red", glow=True) for v in r]
            head += b.ico(0.016, 1, loc=run[-1] + Vector((0, 0, -0.008)), scale=(1, 1, 1.3), color="red", glow=True)

    # Huge ears, splayed out and tipped back, with a reddish inner ear and a tuft. Each
    # bends at a third of its height: below that it follows ear_0, above it blends to ear_1.
    for side, (base, rot) in ears.items():
        s = 1 if side == "l" else -1
        ear = []
        with b.at(loc=base, rot=rot):
            # A broad leaf: widest a third of the way up, flattened front to back.
            ear += b.lathe([(0.15, 0.0), (0.19, 0.16), (0.12, 0.36), (0.0, 0.54)], seg=6,
                           scale=(1, 0.32, 1), color=dark)
            ear += b.lathe([(0.1, 0.04), (0.13, 0.17), (0.08, 0.34), (0.0, 0.47)], seg=5,
                           loc=(0, -0.04, 0), scale=(1, 0.22, 1), color=inner)
            ear += spike((0, 0, 0.5), (0, 0.2, 1), 0.07, 0.025, "black")
            head += spike((s * -0.08, -0.02, 0.08), (s * -1, -0.6, 0.6), 0.13, 0.04)
        to_local = M(base, rot).inverted()
        for v in ear:
            if v.is_valid:
                w = smoothstep(0.16, 0.32, (to_local @ v.co).z)
                b.weigh([v], {f"ear_{side}_0": 1 - w, f"ear_{side}_1": w})

    # Spiky fur on the head: bangs falling over the brow, a crown and tufts at the cheeks.
    for k in range(7):
        x = -0.6 + 1.2 * k / 6
        u = Vector((x, -0.55, 0.75))
        d = Vector((x * 0.6, -0.8, -0.25 + b.rng.uniform(-0.1, 0.1)))
        head += spike(on_head(u, 0.92), d, b.rng.uniform(0.13, 0.19), 0.05)
    for k in range(6):
        a = math.radians(-60 + 120 * k / 5)
        u = Vector((math.sin(a) * 0.7, 0.25, 0.9))
        head += spike(on_head(u, 0.9), Vector((math.sin(a), 0.5, 0.9)), b.rng.uniform(0.12, 0.17), 0.05)
    for s in (-1, 1):
        for z in (-0.35, -0.6):
            head += spike(on_head((s * 0.95, -0.25, z), 0.9), (s, -0.25, z * 0.8), b.rng.uniform(0.11, 0.15), 0.045)
    b.weigh([v for v in head if v.is_valid], {"head": 1.0})

    # Neck and a lean body, deep at the chest and tucked at the waist.
    rings = b.tube([(0, -0.3, 0.6), (0, -0.27, 0.5)], [0.15, 0.16], seg=8, color=fur)
    b.weigh(rings[0], {"neck": 0.5, "head": 0.5})
    b.weigh(rings[1], {"neck": 0.5, "chest": 0.5})
    spine = [(0, -0.36, 0.46), (0, -0.3, 0.46), (0, -0.17, 0.46), (0, 0.0, 0.45), (0, 0.15, 0.46),
             (0, 0.27, 0.47), (0, 0.34, 0.48)]
    rings = b.tube(spine, [0.06, 0.14, 0.17, 0.15, 0.15, 0.14, 0.0], seg=8, color=fur)
    b.jitter([v for r in rings[1:-1] for v in r], 0.008)
    for ring, w in zip(rings, ({"chest": 1.0},) * 3 + ({"chest": 0.5, "hips": 0.5},) + ({"hips": 1.0},) * 3):
        b.weigh(ring, w)

    # A ruff of fur round the chest, spikes pointing down and out.
    ruff = []
    for k in range(9):
        a = math.radians(-165 + 150 * k / 8)
        radial = Vector((math.cos(a), math.sin(a), 0))
        p = Vector((0, -0.34, 0.54)) + radial * 0.15
        ruff += spike(p, radial * 0.7 + Vector((0, -0.25, -0.75)), b.rng.uniform(0.13, 0.18), 0.05)
    for s in (-1, 1):
        ruff += spike((s * 0.11, -0.18, 0.58), (s * 0.4, 0.6, 0.6), 0.1, 0.04)
    b.weigh([v for v in ruff if v.is_valid], {"chest": 1.0})

    # Legs: one tube from shoulder or hip to the ankle, ending in a soft round paw. The
    # tube runs on past the ankle to a point inside the paw, following the paw bone, so
    # the leg stays sunk in the paw however far the paw curls.
    def leg(pts, radii, bones, paw):
        p = Vector(pts[-1])
        center = Vector((p.x, p.y - 0.03, max(p.z - 0.04, 0.04) + 0.008))
        inside = [p.lerp(center, 0.6), center + Vector((0, -0.01, -0.025))]
        chain(b.tube(list(pts) + inside, list(radii) + [radii[-1] * 0.85, 0.0], seg=6, color=fur),
              bones + [paw])
        verts = b.ico(0.075, 1, loc=center, scale=(1, 1.3, 0.7), color=fur)
        b.weigh(verts, {paw: 1.0})

    leg(front_legs["l"], [0.09, 0.068, 0.058], ["leg_fl_0", "leg_fl_1"], "paw_fl")
    leg(front_legs["r"], [0.09, 0.068, 0.058], ["leg_fr_0", "leg_fr_1"], "paw_fr")
    for side in ("r", "l"):
        leg(back_legs[side], [0.11, 0.085, 0.06, 0.058], [f"leg_b{side}_0", f"leg_b{side}_1", f"leg_b{side}_2"],
            f"paw_b{side}")

    # The tail: a bushy plume rising from the rump and curling forward over the back,
    # bristling with tufts that sweep toward its tip, which follow the joint they grow from.
    bones = [f"tail_{k}" for k in range(len(tail) - 1)]
    radii = [0.06, 0.09, 0.14, 0.16, 0.15, 0.1, 0.0]
    rings = b.tube(tail, radii, seg=7, color=fur)
    b.jitter([v for r in rings[1:-1] for v in r], 0.02)
    chain(rings, bones)
    for i in range(1, len(tail) - 1):
        t = (tail[i + 1] - tail[i - 1]).normalized()
        side = Vector((1, 0, 0))
        up = t.cross(side).normalized()
        for k in range(6):
            a = 2 * math.pi * (k + 0.5 * (i % 2)) / 6
            radial = side * math.cos(a) + up * math.sin(a)
            tuft = spike(tail[i] + radial * radii[i] * 0.7, radial * 0.75 + t * 0.8,
                         b.rng.uniform(0.12, 0.2) * (0.6 + radii[i] * 3), 0.055)
            b.weigh([v for v in tuft if v.is_valid], {bones[i - 1]: 0.5, bones[i]: 0.5})
    tuft = spike(tail[-2], (tail[-1] - tail[-2]) + Vector((0, -0.05, -0.05)), 0.22, 0.06)
    b.weigh([v for v in tuft if v.is_valid], {bones[-1]: 1.0})


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
                        b.box((0.16, 0.12, 0.06), (r + 0.27, 0, side * 0.27), color="yellow", glow=True)
        b.box((0.7, 0.55, 0.75), (0, r + 0.32, 0), color="lstone", jit=0.02)  # keystone
        b.box((0.26, 0.2, 0.8), (0, r + 0.36, 0), color="yellow", glow=True)  # gold, pulsed in game
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


@asset("scenery")
def gas_can(b):
    """20 L steel jerry can (0.35 x 0.17 x 0.47 m body) in red, broad faces toward +-Y.
    The filler neck sits on the chamfered top -X corner with a flexible spout clamped on;
    three carry handles span the rest of the top."""
    W, D, H = 0.345, 0.165, 0.43
    ch = 0.085  # size of the chamfer under the filler neck
    outline = [(-W / 2 + 0.02, 0), (W / 2 - 0.02, 0), (W / 2, 0.02), (W / 2, H - 0.02),
               (W / 2 - 0.02, H), (-W / 2 + ch, H), (-W / 2, H - ch), (-W / 2, 0.02)]

    def inset(pts, d):
        return [(x - math.copysign(d, x), z + (d if z < H / 2 else -d)) for x, z in pts]

    # Two nested slabs give the body softened edges; the welded seam runs round the middle.
    b.slab(outline, D - 0.03, color="red")
    b.slab(inset(outline, 0.015), D, color="red")
    b.slab(inset(outline, -0.006), 0.012, color="roof")

    # Raised stampings on both broad faces: the classic X, a panel where it crosses and a
    # bar across the top. The ridge sides are darker so the pattern reads in flat colors.
    ridge = lambda f: "red" if abs(f.normal.y) > 0.9 else "roof"
    cx, cz, pw, ph = 0.01, 0.2, 0.08, 0.1  # center panel

    def bar(sy, x0, z0, x1, z1, w=0.026):
        dx, dz = x1 - x0, z1 - z0
        b.box((math.hypot(dx, dz) + w, 0.018, w), ((x0 + x1) / 2, sy * (D / 2), (z0 + z1) / 2),
              rot=(0, -math.degrees(math.atan2(dz, dx)), 0), color=ridge)

    for sy in (-1, 1):
        for x0, z0, px, pz in ((-W / 2 + 0.045, 0.045, -1, -1), (W / 2 - 0.045, 0.045, 1, -1),
                               (-W / 2 + 0.05, H - 0.1, -1, 1), (W / 2 - 0.045, H - 0.1, 1, 1)):
            bar(sy, x0, z0, cx + px * pw / 2, cz + pz * ph / 2)
        bar(sy, cx - pw / 2, cz - ph / 2, cx + pw / 2, cz - ph / 2)
        bar(sy, cx - pw / 2, cz + ph / 2, cx + pw / 2, cz + ph / 2)
        bar(sy, cx - pw / 2, cz - ph / 2, cx - pw / 2, cz + ph / 2)
        bar(sy, cx + pw / 2, cz - ph / 2, cx + pw / 2, cz + ph / 2)
        bar(sy, -W / 2 + 0.06, H - 0.06, W / 2 - 0.035, H - 0.06)
        b.cyl(0.032, 0.032, 0.016, seg=10, loc=(0.07, sy * (D / 2 + 0.002), H - 0.11),
              rot=(90, 0, 0), color=ridge)  # capacity boss

    # Three carry handles, each a bar across the top on two welded legs.
    for x in (-0.03, 0.055, 0.14):
        b.cyl(0.011, 0.011, D - 0.02, seg=6, loc=(x, 0, H + 0.035), rot=(90, 0, 0), color="red")
        for sy in (-1, 1):
            b.box((0.02, 0.018, 0.04), (x, sy * (D / 2 - 0.02), H + 0.016), color="roof")
    b.box((0.2, 0.02, 0.018), (0.055, 0, H + 0.005), color="roof")  # spine under the handles

    # Filler neck on the chamfer, pointing up and out at 45 degrees, with the clamp ring
    # and the flipped-open cap (cam lever out) standing on its hinge at the neck's +X side.
    n = Vector((-math.sqrt(0.5), 0, math.sqrt(0.5)))  # out of the chamfer
    t = Vector((math.sqrt(0.5), 0, math.sqrt(0.5)))   # along the chamfer, toward +X
    base = Vector((-W / 2 + ch / 2, 0, H - ch / 2))
    b.cyl(0.026, 0.026, 0.045, seg=8, loc=base + n * 0.015, rot=(0, -45, 0), color="red")
    b.cyl(0.032, 0.032, 0.014, seg=8, loc=base + n * 0.032, rot=(0, -45, 0), color="steel")
    b.box((0.03, 0.02, 0.05), base + n * 0.03 + Vector((0, 0.035, 0)), rot=(0, -45, 0), color="chrome")  # clamp
    hinge = base + n * 0.035 + t * 0.034
    b.box((0.016, 0.03, 0.02), hinge, rot=(0, 45, 0), color="gunmetal")
    b.cyl(0.033, 0.033, 0.014, seg=8, loc=hinge + n * 0.034 + t * 0.008, rot=(0, 45, 0), color="red")
    b.cyl(0.02, 0.02, 0.006, seg=6, loc=hinge + n * 0.034, rot=(0, 45, 0), color="black")  # seal
    b.box((0.065, 0.028, 0.012), hinge + n * 0.04 + t * 0.02, rot=(0, 45, 0), color="red")  # cam lever

    # Flexible spout: a ribbed chrome hose rising out of the neck and arcing over to -X,
    # ending in a straight nozzle that points down and out.
    p0 = base + n * 0.035
    ctrl = [p0, p0 + n * 0.09, p0 + Vector((-0.07, 0, 0.18)), p0 + Vector((-0.2, 0, 0.1))]
    pts = []
    for k in range(25):
        t = k / 24
        u = 1 - t
        pts.append(ctrl[0] * u ** 3 + ctrl[1] * 3 * u * u * t + ctrl[2] * 3 * u * t * t + ctrl[3] * t ** 3)
    b.tube(pts, [0.015 if k % 2 else 0.018 for k in range(25)], seg=6, color="chrome")
    tip = pts[-1] + (pts[-1] - pts[-2]).normalized() * 0.09
    b.limb(pts[-1], tip, 0.017, 0.015, seg=6, color="chrome")
    b.limb(tip, tip + (tip - pts[-1]).normalized() * 0.01, 0.015, 0.012, seg=6, color="steel")


def leafy(f):
    """Foliage color: shaded underneath, mixed greens on top (as on tree_oak)."""
    return {"dgrass": 1} if f.normal.z < -0.3 else {"grass": 3, "lgrass": 1, "dgrass": 1, "olive": 1}


@asset("scenery")
def bush_short(b):
    """Knee-high leafy shrub (about 1.1 m across, 0.65 m tall): a dome of foliage clumps
    over a few woody stems, with ragged leaf sprigs breaking up the outline and a
    scattering of red berries."""
    for k in range(5):  # stems splaying out from the root
        a = 2 * math.pi * (k + b.rng.uniform(-0.2, 0.2)) / 5
        b.limb((0, 0, 0), (0.3 * math.cos(a), 0.3 * math.sin(a), 0.3), 0.035, 0.02, 4, "dbark")
    clumps = [((0, 0, 0.36), 0.36)]
    for k in range(6):
        a = 2 * math.pi * (k + b.rng.uniform(-0.25, 0.25)) / 6
        d = b.rng.uniform(0.28, 0.38)
        clumps.append(((d * math.cos(a), d * math.sin(a), b.rng.uniform(0.2, 0.3)), b.rng.uniform(0.2, 0.26)))
    for loc, r in clumps:
        b.ico(r, 1, loc=loc, scale=(1, 1, 0.85), rot=(b.rng.uniform(0, 90), 0, b.rng.uniform(0, 90)),
              color=leafy, jit=0.05, floor=0.02)
    for _ in range(10):  # leaf sprigs poking out of the dome
        a, tilt = b.rng.uniform(0, 2 * math.pi), b.rng.uniform(20, 70)
        p = Vector((0.42 * math.cos(a) * math.sin(math.radians(tilt)), 0.42 * math.sin(a) * math.sin(math.radians(tilt)),
                    0.16 + 0.4 * math.cos(math.radians(tilt))))
        b.box((0.16, 0.07, 0.01), p, rot=(b.rng.uniform(-30, 30), -tilt, math.degrees(a)),
              color={"lgrass": 2, "grass": 1})
    for _ in range(9):  # berries
        a, z = b.rng.uniform(0, 2 * math.pi), b.rng.uniform(0.18, 0.5)
        rr = 0.5 - 0.3 * (z - 0.18) / 0.32
        b.ico(0.028, 1, loc=(rr * math.cos(a), rr * math.sin(a), z), color="red")


@asset("scenery")
def bush_tall(b):
    """Head-high shrub (about 1.9 m across, 2 m tall): a vase of woody stems fanning out
    from the root, leafy from knee height to a full crown, with the stems showing only
    at the very bottom."""
    for k in range(7):
        a = 2 * math.pi * (k + b.rng.uniform(-0.2, 0.2)) / 7
        out = Vector((math.cos(a), math.sin(a), 0))
        lean = b.rng.uniform(0.45, 0.6)
        top = out * lean + Vector((0, 0, b.rng.uniform(1.3, 1.6)))
        mid = out * lean * 0.6 + Vector((0, 0, 0.6))
        b.limb((0, 0, 0), mid, 0.045, 0.035, 4, "dbark")
        b.limb(mid, top, 0.035, 0.02, 4, "dbark")
        # Foliage all the way up each stem: small low, fuller toward the tip.
        for t, r in ((0.25, 0.26), (0.55, 0.32), (0.8, 0.34), (1.0, 0.36)):
            p = mid * min(t / 0.6, 1.0) if t <= 0.6 else mid.lerp(top, (t - 0.6) / 0.4)
            c = p + out * 0.08 + Vector((0, 0, 0.08))
            r *= b.rng.uniform(0.9, 1.1)
            b.ico(r, 1, loc=c, rot=(b.rng.uniform(0, 90), 0, b.rng.uniform(0, 90)), color=leafy, jit=0.06,
                  floor=0.12)
            # A leaf sprig standing out of the clump's outer face breaks up the outline.
            sa = a + b.rng.uniform(-0.6, 0.6)
            b.box((0.22, 0.08, 0.01), c + Vector((math.cos(sa), math.sin(sa), 0.3)).normalized() * r * 0.95,
                  rot=(b.rng.uniform(-30, 30), -b.rng.uniform(10, 40), math.degrees(sa)),
                  color={"lgrass": 2, "grass": 1})
    b.limb((0, 0, 0), (0.05, -0.04, 1.5), 0.05, 0.025, 4, "dbark")  # leader up the middle
    for loc, r in (((0.05, -0.04, 1.55), 0.45), ((0, 0, 0.9), 0.5), ((0, 0, 0.45), 0.42)):  # fill the heart
        b.ico(r, 1, loc=loc, rot=(30, 0, 40), color=leafy, jit=0.08)


@asset("terrain")
def terrain_creek(b):
    """Creek running along X through an 8x8 m tile: a channel about 4 m wide at the water
    line and 0.75 m deep, meandering gently between grassy banks. Its ends match from tile
    to tile (and the side edges sit at height 0 like every tile). The water is a flat sheet
    0.4 m down (PS1_Water, with flow UVs, for an engine's flowing-water shader); rocks of
    every size fill it: boulders on the banks, stones breaking the surface and pebbles
    on the gravel bed."""
    depth, full, edge, water = 0.75, 1.25, 2.7, -0.4
    noise = make_noise(b.rng, 0.3)

    def bend(x):  # the channel's sideways meander; 0 at both ends so tiles line up
        return 0.45 * math.sin(math.pi * x / (TILE / 2))

    def h(x, y):
        d = abs(y - bend(x))
        channel = -depth * (1 - smoothstep(full, edge, d))
        bed = 0.06 * math.sin(x * 2.3 + y * 1.7) * (1 - smoothstep(0, full, d))  # ripples in the gravel
        return channel + bed + noise(x, y) * edge_window(x, y) * smoothstep(edge, edge + 0.6, d)

    def color(f):
        c = f.calc_center_median()
        if c.z < water - 0.1:
            return {"dsoil": 2, "dirt": 2, "dstone": 1, "sand": 1}  # gravel bed
        if c.z < -0.08:
            return {"dirt": 3, "dsoil": 1, "olive": 1, "stone": 1}  # wet, muddy banks
        return GRASS
    terrain(b, h, color, jit=0.03, seg=24)

    # Water: a flat strip along the channel, tucked into the banks on both sides.
    nx, ny, half = 16, 4, 2.15
    coords, faces = [], []
    for i in range(nx + 1):
        x = -TILE / 2 + TILE * i / nx
        for j in range(ny + 1):
            coords.append((x, bend(x) - half + 2 * half * j / ny, water))
    for i in range(nx):
        for j in range(ny):
            a = i * (ny + 1) + j
            faces.append((a, a + ny + 1, a + ny + 2, a + 1))
    b.poly(coords, faces, color="water", glow="water")

    def rock(x, y, r, z=None, squash=0.7):
        z = h(x, y) + r * squash * 0.35 if z is None else z
        b.ico(r, 1, loc=(x, y, z), scale=(1.2, 1.0, squash), rot=(0, 0, b.rng.uniform(0, 180)),
              color=lambda f: {"lgrass": 1, "olive": 2} if f.normal.z > 0.75 and z + r * squash > -0.1
              else {"stone": 3, "lstone": 2, "dstone": 1}, jit=r * 0.18)

    # Boulders on the banks, half in the water.
    for x, side, r in ((-2.6, 1, 0.75), (1.4, -1, 0.85), (3.3, 1, 0.55), (-0.5, 1, 0.45), (-3.4, -1, 0.5)):
        y = bend(x) + side * b.rng.uniform(1.6, 2.0)
        rock(x, y, r)
    # Stones breaking the surface mid-stream (the water piles up around these).
    for x, off, r in ((-1.6, -0.3, 0.32), (0.4, 0.5, 0.28), (2.3, -0.6, 0.36), (-3.0, 0.7, 0.22), (1.1, -0.1, 0.2)):
        rock(x, bend(x) + off, r, z=-depth + r * 0.9, squash=0.9)
    # Cobbles and pebbles on the bed, under the water.
    for _ in range(26):
        x = b.rng.uniform(-3.8, 3.8)
        y = bend(x) + b.rng.uniform(-1.5, 1.5)
        r = b.rng.choice((0.06, 0.08, 0.1, 0.13, 0.17))
        b.ico(r, 1, loc=(x, y, h(x, y) + r * 0.3), scale=(1.3, 1.0, 0.55), rot=(0, 0, b.rng.uniform(0, 180)),
              color={"lstone": 2, "stone": 2, "sand": 1, "dstone": 1})


# Defined after the terrain so adding it didn't reseed (and change) any earlier model.
@asset("scenery")
def barbed_wire(b):
    """Loose roll of rusty barbed wire lying flat (about 1.4 m across, 0.4 m tall): one
    long wire wound round and round in uneven, wobbling loops that bunch into a thick,
    lumpy ring around an open middle. The last loops have sprung free and lie spread on
    the ground toward -X, ending in a short loose tail; barbs stud the whole length."""
    WR = 0.011  # wire radius, far thicker than real wire so it still reads at PS1 resolution
    wire = {"steel": 3, "dirt": 2, "chrome": 1, "wood": 1}  # galvanized grey patched with rust

    # Each turn gets its own spot in the ring's cross-section (distance out from the middle
    # and height, slumped toward the ground), an off-center shift, a tilt and some lumps;
    # the wire eases from one turn's shape to the next as it winds.
    def key(r, z, off, tilt, lump):
        a, t, ph = (b.rng.uniform(0, 2 * math.pi) for _ in range(3))
        return (r, z, Vector((math.cos(a), math.sin(a))) * off, Vector((math.cos(t), math.sin(t))) * tilt,
                lump, ph)

    keys = [key(b.rng.uniform(0.32, 0.56), 0.03 + 0.3 * b.rng.random() ** 1.3, b.rng.uniform(0, 0.07),
                b.rng.uniform(0.02, 0.1), b.rng.uniform(0.02, 0.06)) for _ in range(22)]
    # Sprung loops: wider, shifted toward -X and lying on the ground.
    for r, cx in ((0.6, -0.2), (0.68, -0.3)):
        k = key(r, 0.02, 0, 0.015, 0.02)
        keys.append((k[0], k[1], Vector((cx, b.rng.uniform(-0.05, 0.05))), *k[3:]))

    per = 13  # points per turn
    pts = []
    for i in range((len(keys) - 1) * per + 1):
        s = i / per
        k0, k1 = keys[min(int(s), len(keys) - 1)], keys[min(int(s) + 1, len(keys) - 1)]
        f = smoothstep(0, 1, s - int(s))
        r, z, c, t, lump = (k0[j] + (k1[j] - k0[j]) * f for j in range(5))
        ph = k0[5] if f < 0.5 else k1[5]
        th = 2 * math.pi * s
        h = z + t.x * math.cos(th) + t.y * math.sin(th) + lump * math.sin(3 * th + ph)
        pts.append(Vector((c.x + r * math.cos(th), c.y + r * math.sin(th), max(h, WR))))
    # The loose end: a short tail kinking off across the ground.
    d = (pts[-1] - pts[-2]).normalized()
    for _ in range(5):
        d = (d + Vector((b.rng.uniform(-0.4, 0.4), b.rng.uniform(-0.4, 0.4), 0))).normalized()
        pts.append(pts[-1] + d * 0.09)
        pts[-1].z = WR
    b.tube(pts, [WR] * (len(pts) - 1) + [0.0], seg=3, color=wire)

    # Barbs: a little X of two spikes across the wire every 30 cm or so. Each spike is a
    # thin double-ended pyramid on a triangle.
    def spike(p, u, d, half=0.03, w=0.006):
        v = d.cross(u)
        mid = [p + (v * math.cos(a) + d * math.sin(a)) * w for a in (0, 2.1, 4.2)]
        b.poly([p + u * half, p - u * half, *mid],
               [(0, 2, 3), (0, 3, 4), (0, 4, 2), (1, 3, 2), (1, 4, 3), (1, 2, 4)], color=wire)

    run = 0.0
    for p0, p1 in zip(pts, pts[1:]):
        seg = p1 - p0
        run += seg.length
        if run < 0.3:
            continue
        run = b.rng.uniform(-0.04, 0.04)
        d = seg.normalized()
        u = Matrix.Rotation(b.rng.uniform(0, math.pi), 3, d) @ d.orthogonal().normalized()
        spike(p1, u, d)
        spike(p1, d.cross(u), d)


# Defined last so adding it didn't reseed (and change) any earlier model.
@asset("enemies")
def enemy_lynx_ranger(b):
    """Chibi lynx kit in a ranger's coat, faces -Y, about 1.7 m tall to its ear tips:
    an oversized head with huge splayed ears (dark, pink inside, fringed with tan fur and
    tipped dark purple), half-lidded amber eyes and a smug little smirk, a cream muzzle
    and cheek fluff, and a dark crest with tan locks. It wears a navy coat, open at the
    front over grey legs, with gold edging and a scalloped gold hem, a rolled collar over
    a white shirt, a gold medallion on its chest, a leather bandolier, a hip belt with a
    gold buckle and pouches, and leather shoulder guards. Furry dark sleeves with navy
    bracers end in white paws; it stands on big grey toed feet.

    Rigged for animation (rest pose as modeled, arms hanging). Sides are its own: l is +X.
      hips (root, at the waist) > chest > head > ear_<side>_0 > ear_<side>_1
      chest > arm_<side>_0 (shoulder to elbow) > arm_<side>_1 (to the wrist) > hand_<side>
      hips > leg_<side>_0 (hip to knee) > leg_<side>_1 (to the ankle) > foot_<side>
    The coat's skirt, belt and pouches follow `hips`; the torso blends from `hips` to
    `chest` up the waist, and the collar, straps, medallion and shoulder guards follow
    `chest`. Everything on the head follows `head`, and joints blend across neighbours."""
    navy = {"dwater": 3, "water": 1}
    gold = "yellow"
    leather = {"dbark": 2, "wood": 1}
    dark_fur = {"dstone": 2, "gunmetal": 1, "stone": 1}
    tan_fur = {"lsand": 2, "sand": 2, "bone": 1}

    def spike(p, d, length, width, color):
        """A tuft of fur: a four-sided cone from p, `length` along d."""
        p, d = Vector(p), Vector(d).normalized()
        return b.limb(p, p + d * length, width, 0, 4, color)

    # Layout shared by the skeleton and the mesh.
    hc, hr = Vector((0, -0.02, 1.04)), Vector((0.27, 0.23, 0.22))  # the head

    def on_head(u, depth=1.0):
        u = Vector(u).normalized()
        return hc + Vector((u.x * hr.x, u.y * hr.y, u.z * hr.z)) * depth

    sides = {"l": 1, "r": -1}
    ears = {side: (on_head((s * 0.55, 0.12, 0.8), 0.85), (-14, s * 48, 0)) for side, s in sides.items()}
    arms = {side: [Vector((s * 0.215, 0.0, 0.76)), Vector((s * 0.275, -0.03, 0.6)), Vector((s * 0.285, -0.07, 0.47)),
                   Vector((s * 0.29, -0.1, 0.36))] for side, s in sides.items()}
    legs = {side: [Vector((s * 0.09, 0.0, 0.42)), Vector((s * 0.1, -0.01, 0.24)), Vector((s * 0.105, -0.03, 0.09)),
                   Vector((s * 0.11, -0.17, 0.04))] for side, s in sides.items()}

    # Skeleton (before any geometry: adding the weight layer invalidates vertices).
    b.bone("hips", (0, 0, 0.42), (0, 0, 0.6))
    b.bone("chest", (0, 0, 0.6), (0, 0, 0.84), "hips")
    b.bone("head", (0, -0.02, 0.86), (0, -0.02, 1.2), "chest")
    for side, (base, rot) in ears.items():
        mid, tip = M(base, rot) @ Vector((0, 0, 0.24)), M(base, rot) @ Vector((0, 0, 0.66))
        b.bone(f"ear_{side}_0", base, mid, "head")
        b.bone(f"ear_{side}_1", mid, tip, f"ear_{side}_0")
    for side, j in arms.items():
        b.bone(f"arm_{side}_0", j[0], j[1], "chest")
        b.bone(f"arm_{side}_1", j[1], j[2], f"arm_{side}_0")
        b.bone(f"hand_{side}", j[2], j[3], f"arm_{side}_1")
    for side, j in legs.items():
        b.bone(f"leg_{side}_0", j[0], j[1], "hips")
        b.bone(f"leg_{side}_1", j[1], j[2], f"leg_{side}_0")
        b.bone(f"foot_{side}", j[2], j[3], f"leg_{side}_1")

    def mark():
        return len(b.bm.verts)

    def since(m):
        """The vertices made since mark() returned m."""
        return [v for v in list(b.bm.verts)[m:] if v.is_valid]

    def skin(m, bone):
        b.weigh(since(m), {bone: 1.0})

    def skin_waist(m):
        """Follows `hips` below the waist and `chest` above it, blending between."""
        for v in since(m):
            w = smoothstep(0.55, 0.68, v.co.z)
            b.weigh([v], {"hips": 1 - w, "chest": w})

    def skin_chain(m, joints, bones):
        """Skins to the nearest bone of a chain, blending across each joint."""
        for v in since(m):
            best = None
            for i, (a, c) in enumerate(zip(joints, joints[1:])):
                d = c - a
                t = min(max((v.co - a).dot(d) / d.length_squared, 0.0), 1.0)
                dist = (v.co - (a + d * t)).length
                if best is None or dist < best[0]:
                    best = (dist, i, t)
            _, i, t = best
            w = {bones[i]: 1.0}
            if t > 0.85 and i + 1 < len(bones):
                k = (t - 0.85) / 0.3
                w = {bones[i]: 1 - k, bones[i + 1]: k}
            elif t < 0.15 and i > 0:
                k = (0.15 - t) / 0.3
                w = {bones[i]: 1 - k, bones[i - 1]: k}
            b.weigh([v], w)

    def shell(rows, half_open, seg, thick, color, lower=None):
        """A coat panel: a thick surface of revolution round Z through `rows` of
        (z, radius) from top to bottom, open at the front by `half_open` radians each side
        of -Y (0: closed all round). lower(angle) drops the last two rows (the hem and the
        band above it), for a shaped hem."""
        bm, closed = b.bm, half_open <= 0
        n = seg if closed else seg + 1
        angles = [half_open + (2 * math.pi - 2 * half_open) * k / seg for k in range(n)]
        outer, inner = [], []
        for i, (z, r) in enumerate(rows):
            o, n_ = [], []
            for a in angles:
                zz = z - (lower(a) if lower and i >= len(rows) - 2 else 0.0)
                d = Vector((math.sin(a), -math.cos(a), 0))
                o.append(bm.verts.new(b.P @ (d * r + Vector((0, 0, zz)))))
                n_.append(bm.verts.new(b.P @ (d * (r - thick) + Vector((0, 0, zz)))))
            outer.append(o)
            inner.append(n_)
        faces = []
        for i in range(len(rows) - 1):
            for k in range(seg):
                k1 = (k + 1) % n
                faces.append(bm.faces.new((outer[i][k], outer[i][k1], outer[i + 1][k1], outer[i + 1][k])))
                faces.append(bm.faces.new((inner[i][k], inner[i + 1][k], inner[i + 1][k1], inner[i][k1])))
        for row_o, row_i in ((outer[0], inner[0]), (outer[-1], inner[-1])):
            for k in range(seg):
                k1 = (k + 1) % n
                faces.append(bm.faces.new((row_o[k], row_i[k], row_i[k1], row_o[k1])))
        if not closed:
            for k in (0, n - 1):
                for i in range(len(rows) - 1):
                    faces.append(bm.faces.new((outer[i][k], outer[i + 1][k], inner[i + 1][k], inner[i][k])))
        bmesh.ops.recalc_face_normals(bm, faces=faces)
        return b.paint([v for r in outer + inner for v in r], color)

    # Legs and big toed feet, mostly hidden under the coat.
    for side, s in sides.items():
        m = mark()
        b.tube(legs[side][:3], [0.075, 0.068, 0.062], seg=7, color={"lstone": 2, "white": 1})
        b.ico(0.09, 1, loc=(s * 0.11, -0.07, 0.055), scale=(1.0, 1.35, 0.62), color={"lstone": 2, "white": 2})
        for t in (-1, 0, 1):
            b.ico(0.032, 1, loc=(s * 0.11 + t * 0.042, -0.18, 0.04), scale=(1, 1.1, 0.9),
                  color={"white": 2, "lstone": 1})
        skin_chain(m, legs[side], [f"leg_{side}_0", f"leg_{side}_1", f"foot_{side}"])

    # The coat's skirt, open at the front, flaring from the hips to a scalloped hem that
    # hangs lower behind. The hem band and the front edges are gold, the lining dark.
    def hem_drop(a):
        back = (1 - math.cos(a)) / 2
        return 0.05 * back + 0.035 * abs(math.sin(a * 5))

    def skirt_color(f):
        c = f.calc_center_median()
        a = math.atan2(c.x, -c.y)
        radial = Vector((c.x, c.y, 0)).normalized()
        if f.normal.dot(radial) < -0.3:
            return "dwater"  # lining
        if c.z < 0.17 - hem_drop(a) or abs(a) < 0.44:
            return gold
        return navy

    skirt = [(0.5, 0.215), (0.34, 0.28), (0.18, 0.35), (0.13, 0.37)]
    m = mark()
    shell(skirt, 0.36, 22, 0.022, skirt_color, lower=hem_drop)
    skin(m, "hips")

    def skirt_r(z):
        """The skirt's radius at height z (above the hem)."""
        for (z0, r0), (z1, r1) in zip(skirt, skirt[1:]):
            if z1 <= z <= z0:
                return r0 + (r1 - r0) * (z0 - z) / (z0 - z1)
        return skirt[0][1]

    # Torso, a little deeper than wide, with gold lapel edges down to the waist.
    m = mark()
    b.lathe([(0.0, 0.42), (0.205, 0.44), (0.215, 0.6), (0.195, 0.74), (0.14, 0.84), (0.0, 0.87)],
                    seg=12, scale=(1, 0.88, 1), color=navy)
    for s in (-1, 1):
        b.beam((s * 0.11, -0.16, 0.81), (s * 0.035, -0.19, 0.5), 0.026, 0.02, color=gold)
    b.prism(0.12, 0.02, 0.12, loc=(0, -0.155, 0.86), rot=(-90 + 15, 180, 0), color="white")  # shirt front
    skin_waist(m)

    # A rolled collar of the coat, sitting on the shoulders round the neck.
    m = mark()
    b.lathe([(0.12, 0.82), (0.2, 0.83), (0.235, 0.875), (0.2, 0.93), (0.14, 0.94), (0.12, 0.9)],
            seg=12, scale=(1, 0.92, 1), color=navy)
    skin(m, "chest")

    # Hip belt with a big gold buckle and a pouch at each side.
    m = mark()
    b.lathe([(0.212, 0.4), (0.222, 0.41), (0.222, 0.47), (0.212, 0.48)], seg=12, scale=(1, 0.9, 1),
            color=leather)
    b.box((0.09, 0.02, 0.07), (0, -0.205, 0.44), color=gold)
    b.box((0.05, 0.022, 0.035), (0, -0.207, 0.44), color="dbark")
    for s in (-1, 1):
        b.box((0.09, 0.08, 0.11), (s * 0.22, -0.11, 0.38), rot=(0, 0, s * 35), color=leather, cuts=1)
        b.box((0.095, 0.085, 0.04), (s * 0.22, -0.11, 0.43), rot=(0, 0, s * 35), color="wood")
        b.box((0.025, 0.012, 0.025), (s * 0.245, -0.165, 0.415), rot=(0, 0, s * 35), color=gold)
    skin(m, "hips")

    # A bandolier from the right shoulder to the left hip, studded gold, and a strap
    # from the left shoulder holding the medallion.
    m = mark()
    strap = [(-0.17, -0.1, 0.8), (-0.1, -0.18, 0.7), (0.06, -0.19, 0.58), (0.19, -0.13, 0.48)]
    for p0, p1 in zip(strap, strap[1:]):
        b.beam(p0, p1, 0.05, 0.018, color=leather)
    for p in strap[1:3]:
        b.box((0.03, 0.02, 0.03), Vector(p) + Vector((0, -0.012, 0)), color=gold)
    b.beam((0.17, -0.1, 0.8), (0.05, -0.19, 0.7), 0.04, 0.016, color=leather)
    skin_waist(m)

    # The medallion: a gold-rimmed navy disc with a gold leaf on it.
    m = mark()
    b.limb((0, -0.16, 0.68), (0, -0.215, 0.68), 0.078, 0.078, seg=12, color=gold)
    b.limb((0, -0.21, 0.68), (0, -0.222, 0.68), 0.06, 0.06, seg=12, color="dwater")
    with b.at(loc=(0, -0.224, 0.68)):
        b.box((0.018, 0.01, 0.07), (0, 0, 0.0), color=gold)
        for s in (-1, 1):
            b.box((0.014, 0.01, 0.05), (s * 0.022, 0, 0.008), rot=(0, s * 40, 0), color=gold)
            b.box((0.012, 0.01, 0.035), (s * 0.02, 0, -0.028), rot=(0, s * -50, 0), color=gold)
    skin(m, "chest")

    # The back of the coat: a gold diamond and gold arcs above the hem.
    m = mark()
    b.box((0.05, 0.02, 0.05), (0, skirt_r(0.39), 0.39), rot=(0, 45, 0), color=gold)
    for k in range(-2, 3):
        a0, a1 = math.pi + (k - 0.5) * 0.42, math.pi + (k + 0.5) * 0.42
        pts = []
        for t in (0.0, 0.5, 1.0):
            a = a0 + (a1 - a0) * t
            z = 0.27 + (0.035 if t == 0.5 else 0.0)
            r = skirt_r(z) + 0.004
            pts.append(Vector((math.sin(a) * r, -math.cos(a) * r, z)))
        for p0, p1 in zip(pts, pts[1:]):
            b.beam(p0, p1, 0.016, 0.012, color=gold)
        b.ico(0.014, 0, loc=pts[0], color=gold)
    skin(m, "hips")

    # Shoulder guards with a gold buckle, then furry dark sleeves with navy bracers
    # (gold-edged) and tan tufts, ending in white paws.
    for side, s in sides.items():
        m = mark()
        b.ico(1.0, 1, loc=(s * 0.21, 0.0, 0.79), scale=(0.11, 0.12, 0.075), color=leather)
        b.box((0.035, 0.03, 0.025), (s * 0.24, -0.09, 0.8), color=gold)
        skin(m, "chest")
        m = mark()
        sh, el, wr = arms[side][:3]
        b.tube([sh, el, wr], [0.08, 0.07, 0.066], seg=7, color=dark_fur)
        b.limb(el.lerp(wr, 0.3), wr, 0.077, 0.074, seg=7, color=navy)
        b.limb(wr + (el - wr).normalized() * 0.01, wr - (el - wr).normalized() * 0.005, 0.081, 0.081, seg=7, color=gold)
        for t in (0.25, 0.55):
            p = sh.lerp(el, t)
            spike(p + Vector((s * 0.06, 0, 0)), (s * 1, 0.2, -0.5), 0.09, 0.035, tan_fur)
        spike(el + Vector((s * 0.06, 0.02, 0)), (s * 1, 0.3, -0.2), 0.08, 0.03, tan_fur)
        for k in range(4):
            a = 2 * math.pi * k / 4 + 0.4
            d = Vector((math.cos(a), math.sin(a), 0))
            spike(wr + d * 0.05 + Vector((0, 0, -0.01)), d + Vector((0, 0, -0.6)), 0.06, 0.03, "white")
        b.ico(0.075, 1, loc=(s * 0.29, -0.085, 0.41), scale=(1, 1.05, 0.95), color={"white": 3, "lstone": 1})
        for t in (-1, 0, 1):
            b.ico(0.027, 0, loc=(s * 0.29 + t * 0.03, -0.15, 0.385), color="white")
        skin_chain(m, arms[side], [f"arm_{side}_0", f"arm_{side}_1", f"hand_{side}"])

    # Head: a big ellipsoid, shaded by region: cream muzzle and cheeks, tan round the
    # eyes, a dark crown and a tan-brown back.
    head_start = mark()

    def face(x, z, proud=0.0):
        """Point on the front of the head at (x, z) and the head's normal there."""
        k = 1 - (x / hr.x) ** 2 - ((z - hc.z) / hr.z) ** 2
        p = Vector((x, hc.y - hr.y * math.sqrt(max(k, 0.0)), z))
        n = Vector(((p.x - hc.x) / hr.x ** 2, (p.y - hc.y) / hr.y ** 2, (p.z - hc.z) / hr.z ** 2)).normalized()
        return p + n * proud, n

    def head_color(f):
        c = f.calc_center_median() - hc
        u = Vector((c.x / hr.x, c.y / hr.y, c.z / hr.z))
        if u.y > 0.25:
            return {"sand": 3, "lsand": 1}
        if u.y < -0.5 and u.z < -0.05:
            return {"white": 3, "bone": 1}
        if u.y < -0.3 and 0.15 < u.z < 0.5 and 0.2 < abs(u.x) < 0.6:
            return {"white": 2, "bone": 1}  # brow patches
        if u.y < -0.35 and u.z < 0.15:
            return {"sand": 2, "lsand": 1} if abs(u.x) > 0.2 else {"bone": 2, "white": 1}
        return dark_fur

    b.ico(1.0, 2, loc=hc, scale=hr, color=head_color, jit=0.006)

    # Muzzle, nose and a lopsided smirk.
    mc, mr = Vector((0, -0.215, 0.945)), Vector((0.12, 0.075, 0.07))
    b.ico(1.0, 1, loc=mc, scale=mr, color={"white": 3, "bone": 1})
    b.ico(1.0, 1, loc=(0, -0.29, 0.975), scale=(0.032, 0.022, 0.022), color={"dirt": 2, "dbark": 1})
    smirk = []
    for x, dz in ((-0.05, 0.0), (-0.02, -0.012), (0.015, -0.01), (0.055, 0.01)):
        k = 1 - (x / mr.x) ** 2 - ((0.925 + dz - mc.z) / mr.z) ** 2
        smirk.append(Vector((x, mc.y - mr.y * math.sqrt(max(k, 0.0)) - 0.003, 0.925 + dz)))
    b.tube(smirk, [0.004, 0.007, 0.007, 0.004], seg=4, color="dbark")

    # Half-lidded amber eyes: a gold iris, a big pupil and a glint, under a heavy dark lid
    # lined in black.
    for s in (-1, 1):
        p, n = face(s * 0.115, 1.015)
        b.limb(p - n * 0.012, p + n * 0.012, 0.064, 0.058, seg=10, color="bone")
        b.limb(p + n * 0.006, p + n * 0.016, 0.05, 0.046, seg=10, color=gold)
        b.limb(p + n * 0.012, p + n * 0.02, 0.03, 0.026, seg=8, color="black")
        b.ico(0.011, 1, loc=p + n * 0.022 + Vector((s * -0.012, 0, 0.014)), color="white")
        lid = [face(s * x, 1.015 + z, 0.012)[0] for x, z in ((0.05, 0.022), (0.1, 0.045), (0.15, 0.04), (0.185, 0.02))]
        b.tube(lid, [0.018, 0.032, 0.03, 0.012], seg=6, color=dark_fur)
        liner = [face(s * x, 1.015 + z, 0.018)[0] for x, z in ((0.05, 0.012), (0.1, 0.024), (0.15, 0.022), (0.2, 0.03))]
        b.tube(liner, [0.008, 0.011, 0.01, 0.0], seg=4, color="black")
        # A white brow tuft above each eye.
        q, m = face(s * 0.11, 1.1)
        spike(q, m + Vector((s * 0.6, 0, 0.5)), 0.08, 0.035, {"white": 2, "bone": 1})

    # Cheek fluff sweeping out and down at the sides of the face.
    for s in (-1, 1):
        for k in range(5):
            z = 0.9 + 0.03 * k + b.rng.uniform(-0.01, 0.01)
            q = on_head((s * 0.95, -0.3 + b.rng.uniform(-0.1, 0.1), (z - hc.z) / hr.z), 0.93)
            d = Vector((s * 1, b.rng.uniform(-0.4, 0.1), -0.45 + 0.15 * k + b.rng.uniform(-0.15, 0.15)))
            spike(q, d, b.rng.uniform(0.09, 0.16), b.rng.uniform(0.05, 0.065), {"white": 2, "lsand": 2, "sand": 1})

    # A dark crest on top streaked with tan, tan locks falling over the brow, and tan
    # fluff on the back of the head.
    for k in range(7):
        x = -0.36 + 0.12 * k
        q = on_head((x, b.rng.uniform(-0.15, 0.25), 1.0), 0.93)
        d = Vector((x * 1.2, 0.5 + b.rng.uniform(-0.3, 0.3), 1.0))
        spike(q, d, b.rng.uniform(0.08, 0.14), b.rng.uniform(0.05, 0.065),
              tan_fur if k in (2, 5) else {"dstone": 2, "purple": 1, "gunmetal": 1})
    for x in (-0.07, 0.0, 0.08):
        q = on_head((x * 3, -0.6, 0.75), 0.97)
        spike(q, (x * 2, -0.7, -0.55), 0.1, 0.04, tan_fur)
    for k in range(5):
        a = math.radians(-60 + 120 * k / 4)
        q = on_head((math.sin(a), 0.8, -0.1 + 0.2 * (k % 2)), 0.93)
        spike(q, (math.sin(a) * 0.6, 1.0, -0.5), b.rng.uniform(0.07, 0.11), 0.05, {"sand": 2, "lsand": 1})

    skin(head_start, "head")

    # Huge ears splayed up and out: dark outside with a tan-brown base, pink inside,
    # fringed with long tan fur along their edges and tipped with dark purple tufts.
    # Each bends a third of the way up: below that it follows ear_0, above it ear_1.
    for side, s in sides.items():
        base, rot = ears[side]
        m = mark()
        with b.at(loc=base, rot=rot):
            prof = [(0.17, 0.0), (0.2, 0.16), (0.15, 0.36), (0.07, 0.54), (0.0, 0.66)]
            to_local = (b.P).inverted()

            def ear_color(f):
                z = (to_local @ f.calc_center_median()).z
                if z > 0.45:
                    return {"purple": 2, "dstone": 1}
                return {"dstone": 1, "purple": 1, "dirt": 1} if z > 0.3 else {"sand": 3, "lsand": 1}

            b.lathe(prof, seg=7, scale=(1, 0.3, 1), color=ear_color)
            b.lathe([(0.12, 0.05), (0.15, 0.17), (0.1, 0.35), (0.0, 0.52)], seg=6,
                    loc=(0, -0.042, 0), scale=(1, 0.2, 1), color="flesh")
            for i in range(1, 8):
                for edge in (-1, 1):
                    z = 0.07 * i + b.rng.uniform(-0.02, 0.02)
                    r = next(p[0] + (q[0] - p[0]) * (z - p[1]) / (q[1] - p[1])
                             for p, q in zip(prof, prof[1:]) if p[1] <= z <= q[1])
                    # The outer edge (away from the head) carries the long fringe.
                    outer = edge == 1
                    length = (0.08 + 0.1 * math.sin(math.pi * i / 8)) * (1.0 if outer else 0.6)
                    length *= b.rng.uniform(0.75, 1.2)
                    spike((edge * r * 0.95, 0, z), (edge * 0.8, b.rng.uniform(-0.25, 0.25), 0.9 + 0.1 * i), length,
                          b.rng.uniform(0.04, 0.06), tan_fur if i < 6 else {"purple": 1, "dstone": 1, "sand": 1})
            for k in range(3):
                spike((0, 0, 0.6), ((k - 1) * 0.35, 0.15, 1), 0.13 - 0.02 * abs(k - 1), 0.035,
                      {"purple": 2, "dstone": 1})
            spike((0, -0.04, 0.12), (0, -0.6, 0.8), 0.14, 0.05, {"lsand": 2, "white": 1})  # inner-ear tuft
        to_local = M(base, rot).inverted()
        for v in since(m):
            w = smoothstep(0.16, 0.32, (to_local @ v.co).z)
            b.weigh([v], {f"ear_{side}_0": 1 - w, f"ear_{side}_1": w})


# Defined last so adding it didn't reseed (and change) any earlier model.
@asset("enemies")
def enemy_jellyfish(b):
    """A sky jellyfish, about 1.6 m across its bell and 3 m tall with its tentacles, with
    its origin at the middle of the bell's rim (hover it in game). The domed bell shades
    from pinkish violet on top through blue round its sides to a glowing orange band
    (PS1_Glow) above a scalloped rim of pale lappets, with ribs running down it. Under it
    hang four frilly oral arms, pale lavender and studded with bulbs, curling at their
    ends, and eight long pale ribbon tentacles from just inside the rim.

    Rigged so it can pulse and its hangings can swing: `body` (the root) carries `bell`,
    which the game scales to pulse the bell, and every hanging as a chain of bones, top to
    bottom: `arm_<k>_0` .. `arm_<k>_4` for the oral arms (k = 0 to 3) and `tentacle_<k>_0`
    .. `tentacle_<k>_3` for the tentacles (k = 0 to 7). Each chain hangs straight down at
    rest in equal segments, and is skinned smoothly along its bones."""
    BELL_R, BELL_H = 0.8, 0.72
    ARM_LEN, ARM_BONES, ARM_ROOT_R = 2.0, 5, 0.13
    TENT_LEN, TENT_BONES, TENT_ROOT_R = 2.5, 4, 0.62
    pale = {"white": 3, "lstone": 2, "chrome": 1}

    arm_roots = [Vector((math.cos(a) * ARM_ROOT_R, math.sin(a) * ARM_ROOT_R, 0.12))
                 for a in (math.radians(45 + 90 * k) for k in range(4))]
    tent_roots = [Vector((math.cos(a) * TENT_ROOT_R, math.sin(a) * TENT_ROOT_R, 0.03))
                  for a in (math.radians(22.5 + 45 * k) for k in range(8))]

    def chain_points(root, length, n):
        return [root + Vector((0, 0, -length * j / n)) for j in range(n + 1)]

    # Skeleton (before any geometry: adding the weight layer invalidates vertices).
    b.bone("body", (0, 0, 0), (0, 0, 0.4))
    b.bone("bell", (0, 0, 0), (0, 0, BELL_H), "body")
    for k, root in enumerate(arm_roots):
        pts = chain_points(root, ARM_LEN, ARM_BONES)
        for j in range(ARM_BONES):
            b.bone(f"arm_{k}_{j}", pts[j], pts[j + 1], "body" if j == 0 else f"arm_{k}_{j - 1}")
    for k, root in enumerate(tent_roots):
        pts = chain_points(root, TENT_LEN, TENT_BONES)
        for j in range(TENT_BONES):
            b.bone(f"tentacle_{k}_{j}", pts[j], pts[j + 1], "body" if j == 0 else f"tentacle_{k}_{j - 1}")

    def mark():
        return len(b.bm.verts)

    def since(m):
        return [v for v in list(b.bm.verts)[m:] if v.is_valid]

    def skin_hanging(m, top, length, bones):
        """Skins a hanging chain by height: each vertex to the bone at its depth below
        `top`, blending into the next across each joint."""
        n = len(bones)
        for v in since(m):
            s = min(max((top - v.co.z) / length * n, 0.0), n - 1e-6)
            j, f = int(s), s - int(s)
            if f > 0.8 and j + 1 < n:
                k = (f - 0.8) / 0.4
                b.weigh([v], {bones[j]: 1 - k, bones[j + 1]: k})
            elif f < 0.2 and j > 0:
                k = (0.2 - f) / 0.4
                b.weigh([v], {bones[j]: 1 - k, bones[j - 1]: k})
            else:
                b.weigh([v], {bones[j]: 1.0})

    # The bell: a broad dome over a shallow hollow underneath, in bands from a pinkish
    # crown through violet to blue round the sides, ribbed with alternating shades, a
    # glowing orange band low down and pale underneath.
    def bell_color(f):
        c = f.calc_center_median()
        if f.normal.z < -0.3 and c.z < 0.25:
            return "lstone"  # the underside
        rib = int((math.degrees(math.atan2(c.y, c.x)) + 371.25) / 22.5) % 2
        if c.z > 0.62:
            return "flesh"
        if c.z > 0.5:
            return "purple" if rib else "flesh"
        if c.z > 0.36:
            return "purple" if rib else "water"
        return "sky" if rib else "water"

    m = mark()
    dome = [(BELL_R * math.sin(math.radians(a)), 0.12 + (BELL_H - 0.12) * math.cos(math.radians(a)))
            for a in (0, 18, 34, 48, 61, 72, 82, 90)]
    b.lathe(dome + [(0.79, 0.06), (0.74, 0.03), (0.6, 0.08), (0.35, 0.14), (0.0, 0.16)], seg=16,
            color=bell_color)
    # The glowing band and the scalloped rim of pale lappets below it.
    b.lathe([(0.802, 0.135), (0.81, 0.11), (0.795, 0.075)], seg=16, color="orange", glow=True)
    for k in range(32):
        a = 2 * math.pi * (k + 0.5) / 32
        b.ico(0.05, 1, loc=(math.cos(a) * 0.765, math.sin(a) * 0.765, 0.045), scale=(1, 1.1, 0.8),
              rot=(0, 0, math.degrees(a)), color="white" if k % 2 else "lstone")
    b.weigh(since(m), {"bell": 1.0})

    # Oral arms: thick, frilly, lumpy columns, studded with bulbs, curling at the ends.
    for k, root in enumerate(arm_roots):
        m = mark()
        out = Vector((root.x, root.y, 0)).normalized()
        side = Vector((-out.y, out.x, 0))
        pts, radii = [], []
        for i in range(13):
            t = i / 12
            curl = smoothstep(0.75, 1.0, t)
            p = root + Vector((0, 0, -ARM_LEN * t)) + out * (0.05 * math.sin(t * 9 + k) + 0.12 * t + 0.2 * curl) \
                + side * 0.06 * math.sin(t * 7 + k * 2) + Vector((0, 0, 0.18 * curl))
            pts.append(p)
            radii.append(0.12 * (1 - 0.6 * t) if i < 12 else 0.0)
        rings = b.tube(pts, radii, seg=6, color=pale)
        b.jitter([v for r in rings[1:-1] for v in r], 0.02)
        for i in range(1, 12):
            for q in range(3 if i < 9 else 2):
                a = b.rng.uniform(0, 2 * math.pi)
                d = out * math.cos(a) + side * math.sin(a)
                size = b.rng.uniform(0.04, 0.075) * (1.1 - 0.4 * i / 12)
                b.ico(size, 1, loc=pts[i] + d * radii[i] * 0.9 + Vector((0, 0, b.rng.uniform(-0.06, 0.06))),
                      color={"white": 2, "sky": 1, "chrome": 1})
        skin_hanging(m, root.z, ARM_LEN, [f"arm_{k}_{j}" for j in range(ARM_BONES)])

    # Tentacles: long pale ribbons from just inside the rim, wavering a little, each with a
    # few small beads near its end.
    for k, root in enumerate(tent_roots):
        m = mark()
        out = Vector((root.x, root.y, 0)).normalized()
        side = Vector((-out.y, out.x, 0))
        length = TENT_LEN * b.rng.uniform(0.85, 1.0)
        pts = [root + Vector((0, 0, -length * i / 10)) + side * 0.04 * math.sin(i * 1.3 + k)
               + out * 0.03 * math.sin(i * 0.9 + k * 1.7) for i in range(11)]
        b.tube(pts, [0.024 * (1 - 0.6 * i / 10) if i < 10 else 0.0 for i in range(11)], seg=4,
               color={"bone": 2, "white": 2, "lsand": 1})
        for i in (6, 8, 9):
            if b.rng.random() < 0.6:
                b.ico(0.028, 0, loc=pts[i] + side * 0.02, color={"white": 1, "sky": 1})
        skin_hanging(m, root.z, TENT_LEN, [f"tentacle_{k}_{j}" for j in range(TENT_BONES)])


@asset("enemies")
def enemy_dachshund(b):
    """Red smooth-haired dachshund, faces -Y, about 0.55 m tall to the top of its head and
    1.45 m from nose to tail tip: a long low body with a deep chest, short sturdy legs,
    a long muzzle with a black nose, big soft ears hanging past its jaw and a thin tail
    sweeping back and curving up at the end.

    Rigged for animation (rest pose as modeled, standing square). Sides are its own: l is +X.
      hips (root, at the rump) > chest > neck > head > ear_<side>
      chest > leg_f<side>_0 (shoulder to elbow) > leg_f<side>_1 (to wrist) > paw_f<side>
      hips > leg_b<side>_0 (hip to hock) > leg_b<side>_1 (to ankle) > paw_b<side>
      hips > tail_0 (root) > ... > tail_3 (tip)
    The body blends from `hips` to `chest` along the back, so the spine can flex; the
    claws follow their paws, and everything on the head follows `head`."""
    coat = "orange"  # one solid red coat all over

    # Layout shared by the skeleton and the mesh.
    sides = {"l": 1, "r": -1}
    spine = [Vector((0, 0.36, 0.3)), Vector((0, 0.06, 0.28)), Vector((0, -0.3, 0.3)),
             Vector((0, -0.47, 0.46)), Vector((0, -0.69, 0.465))]  # rump, mid-back, withers, skull, nose
    ears = {side: (Vector((s * 0.082, -0.47, 0.54)), Vector((s * 0.098, -0.5, 0.345))) for side, s in sides.items()}
    front = {side: [Vector((s * 0.085, -0.25, 0.25)), Vector((s * 0.095, -0.24, 0.13)),
                    Vector((s * 0.09, -0.28, 0.055)), Vector((s * 0.1, -0.36, 0.026))] for side, s in sides.items()}
    hind = {side: [Vector((s * 0.09, 0.28, 0.22)), Vector((s * 0.095, 0.37, 0.11)),
                   Vector((s * 0.095, 0.35, 0.05)), Vector((s * 0.095, 0.27, 0.026))] for side, s in sides.items()}
    tail = [Vector(p) for p in ((0, 0.39, 0.33), (0, 0.5, 0.31), (0, 0.6, 0.29), (0, 0.69, 0.3), (0, 0.75, 0.35))]

    # Skeleton (before any geometry: adding the weight layer invalidates vertices).
    b.bone("hips", spine[0], spine[1])
    b.bone("chest", spine[1], spine[2], "hips")
    b.bone("neck", spine[2], spine[3], "chest")
    b.bone("head", spine[3], spine[4], "neck")
    for side, (top, tip) in ears.items():
        b.bone(f"ear_{side}", top, tip, "head")
    for side in sides:
        j = front[side]
        b.bone(f"leg_f{side}_0", j[0], j[1], "chest")
        b.bone(f"leg_f{side}_1", j[1], j[2], f"leg_f{side}_0")
        b.bone(f"paw_f{side}", j[2], j[3], f"leg_f{side}_1")
        j = hind[side]
        b.bone(f"leg_b{side}_0", j[0], j[1], "hips")
        b.bone(f"leg_b{side}_1", j[1], j[2], f"leg_b{side}_0")
        b.bone(f"paw_b{side}", j[2], j[3], f"leg_b{side}_1")
    for k in range(len(tail) - 1):
        b.bone(f"tail_{k}", tail[k], tail[k + 1], "hips" if k == 0 else f"tail_{k - 1}")

    def mark():
        return len(b.bm.verts)

    def since(m):
        """The vertices made since mark() returned m."""
        return [v for v in list(b.bm.verts)[m:] if v.is_valid]

    def skin(m, bone):
        b.weigh(since(m), {bone: 1.0})

    def skin_chain(m, joints, bones):
        """Skins to the nearest bone of a chain, blending across each joint."""
        for v in since(m):
            best = None
            for i, (a, c) in enumerate(zip(joints, joints[1:])):
                d = c - a
                t = min(max((v.co - a).dot(d) / d.length_squared, 0.0), 1.0)
                dist = (v.co - (a + d * t)).length
                if best is None or dist < best[0]:
                    best = (dist, i, t)
            _, i, t = best
            w = {bones[i]: 1.0}
            if t > 0.85 and i + 1 < len(bones):
                k = (t - 0.85) / 0.3
                w = {bones[i]: 1 - k, bones[i + 1]: k}
            elif t < 0.15 and i > 0:
                k = (0.15 - t) / 0.3
                w = {bones[i]: 1 - k, bones[i - 1]: k}
            b.weigh([v], w)

    def oval_tube(sections, seg=8, color=coat):
        """Tube through `sections` of (center, half-width, half-height): an oval cross
        section, widest across X. A half-width of 0 closes it to a point."""
        rings = b.tube([c for c, _, _ in sections], [1.0 if w > 0 else 0.0 for _, w, _ in sections],
                       seg=seg, color=color)
        for ring, (c, w, h) in zip(rings, sections):
            c = b.P @ Vector(c)
            for v in ring:
                d = v.co - c
                v.co = c + Vector((d.x * w, d.y * w, d.z * h))
        return rings

    # Body: a long barrel, deep at the chest (its keel low between the front legs), tucked
    # up under the loins and rounding off over the rump. It follows `hips` behind the
    # middle of the back and `chest` in front of it, blending between.
    m = mark()
    oval_tube([((0, -0.37, 0.31), 0.09, 0.11), ((0, -0.31, 0.27), 0.13, 0.15),
               ((0, -0.18, 0.25), 0.14, 0.16), ((0, -0.02, 0.27), 0.13, 0.13),
               ((0, 0.14, 0.29), 0.12, 0.11), ((0, 0.28, 0.3), 0.125, 0.115),
               ((0, 0.38, 0.3), 0.09, 0.09), ((0, 0.42, 0.3), 0.0, 0.0)], seg=10, color=coat)
    for v in since(m):
        w = smoothstep(-0.08, 0.16, v.co.y)
        b.weigh([v], {"chest": 1 - w, "hips": w})

    # Neck, rising forward out of deep in the chest and on up inside the skull, so it never
    # parts from either as the head turns. It follows `chest` at its root, bends along
    # `neck`, and its upper part (where it meets and runs into the skull) follows `head`.
    m = mark()
    oval_tube([((0, -0.2, 0.28), 0.09, 0.1), ((0, -0.3, 0.3), 0.1, 0.12), ((0, -0.4, 0.38), 0.088, 0.1),
               ((0, -0.46, 0.45), 0.075, 0.08), ((0, -0.5, 0.5), 0.06, 0.06)], seg=8, color=coat)
    root, top = spine[2], spine[3]
    for v in since(m):
        t = (v.co - root).dot(top - root) / (top - root).length_squared
        head = smoothstep(0.55, 0.9, t)
        chest = smoothstep(0.35, 0.0, t)
        b.weigh([v], {k: w for k, w in (("chest", chest), ("neck", 1 - head - chest), ("head", head)) if w > 0})

    # Head: a domed skull, then a long tapering muzzle with a stop at the brow, the lower
    # jaw tucked in under it, and a big black nose at the tip.
    m = mark()
    hc = Vector((0, -0.49, 0.5))
    b.ico(1, 1, loc=hc, scale=(0.085, 0.09, 0.08), color=coat)
    oval_tube([((0, -0.53, 0.5), 0.055, 0.05), ((0, -0.6, 0.48), 0.042, 0.04),
               ((0, -0.67, 0.465), 0.032, 0.03), ((0, -0.69, 0.462), 0.0, 0.0)], seg=8, color=coat)
    oval_tube([((0, -0.52, 0.455), 0.04, 0.025), ((0, -0.6, 0.445), 0.03, 0.02),
               ((0, -0.655, 0.44), 0.0, 0.0)], seg=6, color=coat)
    b.ico(0.02, 1, loc=(0, -0.685, 0.468), scale=(1.1, 0.8, 0.8), color="black")
    b.box((0.05, 0.08, 0.006), (0, -0.62, 0.452), color="dsoil")  # the line of the mouth

    # Eyes: dark and set to the sides of the stop, under a soft brow.
    for s in (-1, 1):
        b.ico(0.016, 1, loc=(s * 0.042, -0.545, 0.525), color="black")
        b.ico(0.004, 0, loc=(s * 0.046, -0.557, 0.533), color="white")
        b.box((0.03, 0.02, 0.012), (s * 0.04, -0.54, 0.545), rot=(0, s * -15, 0), color=coat)
    skin(m, "head")

    # Ears: long soft flaps set high at the back of the skull, hanging past the jaw and
    # turned a little forward. They're hinged at the top, blending into `head` there.
    for side, s in sides.items():
        m = mark()
        flap = [(Vector((s * 0.082, -0.47, 0.54)), 0.03), (Vector((s * 0.096, -0.475, 0.49)), 0.054),
                (Vector((s * 0.102, -0.485, 0.42)), 0.06), (Vector((s * 0.1, -0.495, 0.37)), 0.045),
                (Vector((s * 0.098, -0.5, 0.345)), 0.0)]
        rings = b.tube([p for p, _ in flap], [w for _, w in flap], seg=8, color=coat)
        for ring, (p, w) in zip(rings, flap):
            for v in ring:  # pressed flat against the side of the head
                v.co.x = p.x + (v.co.x - p.x) * 0.016 / max(w, 1e-6)
        for v in since(m):
            w = smoothstep(0.47, 0.53, v.co.z) * 0.8
            b.weigh([v], {f"ear_{side}": 1 - w, "head": w})

    # Legs: short and sturdy. The front ones come out from under the deep chest, bowed in
    # a little at the wrist, their paws turned slightly out; the back ones from muscular
    # thighs, angled back to the hock and then straight down.
    for side, s in sides.items():
        j = front[side]
        m = mark()
        b.tube([j[0], j[1], j[2], (s * 0.095, -0.3, 0.035)], [0.05, 0.04, 0.032, 0.03], seg=6, color=coat)
        skin_chain(m, [j[0] + Vector((0, 0, 0.1))] + j, ["chest", f"leg_f{side}_0", f"leg_f{side}_1", f"paw_f{side}"])
        m = mark()
        b.ico(1, 1, loc=(s * 0.1, -0.31, 0.026), rot=(0, 0, s * -12), scale=(0.042, 0.062, 0.03),
              color=coat, floor=0.0)
        for k in (-1, 0, 1):  # claws
            b.box((0.008, 0.014, 0.009), (s * 0.1 + k * 0.016 - s * k * 0.004, -0.358, 0.01), color="black")
        skin(m, f"paw_f{side}")

        j = hind[side]
        m = mark()
        b.ico(1, 1, loc=(s * 0.085, 0.27, 0.24), scale=(0.06, 0.1, 0.1), color=coat)
        b.tube([j[0], j[1], j[2], (s * 0.095, 0.335, 0.035)], [0.045, 0.032, 0.03, 0.028], seg=6, color=coat)
        skin_chain(m, [j[0] + Vector((0, -0.08, 0.12))] + j, ["hips", f"leg_b{side}_0", f"leg_b{side}_1", f"paw_b{side}"])
        m = mark()
        b.ico(1, 1, loc=(s * 0.095, 0.32, 0.026), scale=(0.04, 0.058, 0.028), color=coat, floor=0.0)
        for k in (-1, 0, 1):
            b.box((0.008, 0.014, 0.009), (s * 0.095 + k * 0.015, 0.272, 0.01), color="black")
        skin(m, f"paw_b{side}")

    # Tail: thin and tapering, sweeping back and a little down from the rump, then curving
    # up at the end.
    m = mark()
    b.tube(tail, [0.034, 0.027, 0.02, 0.013, 0.0], seg=6, color=coat)
    skin_chain(m, [spine[0] + Vector((0, -0.06, 0))] + tail, ["hips"] + [f"tail_{k}" for k in range(len(tail) - 1)])


@asset("scenery")
def ruins_gate(b):
    """An overgrown standing-stone gateway, faces -Y, about 5.1 m wide and 3.9 m tall:
    two pillars of rough pale stone blocks, each with a glowing cyan rune channel
    cracked with light down its front, carry a heavy split lintel and two capstones over
    a 2 m wide opening with corbelled corners. Ivy spills over the top, front and back,
    and trails down the stones on both sides, and flagstones sunk in moss pave the
    threshold, with a carved marker stone and rubble in front."""
    stone = {"lstone": 7, "stone": 1}
    W = 0.35  # how far each pillar stands out from the middle beyond a 1.3 m opening

    def block(x0, x1, z0, z1, y0=-0.42, y1=0.42, rot=(0, 0, 0), color=stone):
        """A rough stone block spanning these ranges, chipped a little at the corners."""
        return b.box((x1 - x0, y1 - y0, z1 - z0), ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), rot=rot,
                     color=color, cuts=1, jit=0.03)

    # Left pillar: a tall slab in two courses, and an outer stone leaning against it.
    with b.at((-W, 0, 0)):
        block(-1.75, -0.65, 0.0, 1.45)
        block(-1.72, -0.66, 1.45, 2.75, y0=-0.4, y1=0.43)
        block(-2.3, -1.72, 0.0, 2.4, y0=-0.34, y1=0.34, rot=(0, -4, 0))

    # Right pillar: a stack of smaller blocks on the inner side, set slightly in and out,
    # beside a tall outer slab in two courses.
    with b.at((W, 0, 0)):
        for i, (z0, z1) in enumerate(((0.0, 0.62), (0.62, 1.22), (1.22, 1.82), (1.82, 2.32), (2.32, 2.75))):
            d = 0.03 if i % 2 else -0.02
            block(0.64 + d, 1.06, z0, z1, y0=-0.4 - d, y1=0.4)
        block(1.06, 1.95, 0.0, 1.32)
        block(1.08, 1.96, 1.32, 2.75, y0=-0.43, y1=0.41)

    # The lintel, split into two great blocks of slightly different heights, and two
    # capstones laid on top, one tipped a little.
    block(-2.05 - W, 0.08, 2.75, 3.35, y0=-0.46, y1=0.44)
    block(0.08, 2.05 + W, 2.75, 3.32, y0=-0.44, y1=0.46)
    block(-1.85 - W, -0.05, 3.35, 3.85, y0=-0.4, y1=0.38, rot=(0, 2, 0))
    block(0.02, 1.92 + W, 3.33, 3.88, y0=-0.38, y1=0.4, rot=(0, -1.5, 0))

    # Corbels: wedges in the opening's top corners, rounding it off.
    for s in (-1, 1):
        b.box((0.42, 0.78, 0.42), (s * (0.66 + W), 0, 2.72), rot=(0, 45, 0), color=stone, jit=0.02)
        b.box((0.24, 0.76, 0.24), (s * (0.5 + W), 0, 2.72), rot=(0, 45, 0), color=stone, jit=0.02)

    def zigzag(x, z0, z1, wander, y, width, color, glow=False, forks=0):
        """A jagged line up a face (at depth y) from z0 to z1 about x, with forks
        branching off it."""
        n = max(3, int((z1 - z0) / 0.18))
        pts = [Vector((x + (b.rng.uniform(-wander, wander) if 0 < i < n else 0), y, z0 + (z1 - z0) * i / n))
               for i in range(n + 1)]
        for p0, p1 in zip(pts, pts[1:]):
            b.beam(p0, p1, width, 0.012, color=color, glow=glow)
        for _ in range(forks):
            p0 = b.rng.choice(pts[1:-1])
            p1 = p0 + Vector((b.rng.choice((-1, 1)) * wander * 1.2, 0, b.rng.uniform(0.08, 0.2)))
            b.beam(p0, p1, width * 0.8, 0.012, color=color, glow=glow)

    # Rune channels: a dark recess down the front of each pillar holding a glowing cyan
    # seam, crackling with jagged white light.
    for x in (-1.2 - W, 1.5 + W):
        b.box((0.3, 0.06, 2.2), (x, -0.43, 1.42), color="dstone")
        b.box((0.2, 0.04, 2.08), (x, -0.45, 1.42), color="cyan", glow=True)
        zigzag(x, 0.4, 2.44, 0.065, -0.474, 0.034, "white", glow=True, forks=5)

    # Cracks across the stones' faces.
    for x, z0, z1 in ((-0.85 - W, 0.3, 1.2), (-1.55 - W, 1.7, 2.6), (-2.05 - W, 0.4, 1.6), (0.8 + W, 1.3, 2.2),
                      (1.85 + W, 0.2, 1.0), (-1.0, 2.85, 3.3), (1.2, 2.8, 3.25), (0.5, 3.4, 3.8)):
        zigzag(x, z0, z1, 0.07, -0.47 if z0 < 2.75 else -0.48, 0.016, "dstone", forks=1)

    # Threshold: a bed of moss, through the gate and out in front, paved with worn
    # flagstones, some missing.
    moss = {"olive": 3, "grass": 2, "dgrass": 1}
    b.cyl(1.0, 0.95, 0.06, seg=12, loc=(0, -0.75, 0.03), scale=(2.05 + W, 1.55, 1), color=moss, jit=0.02)
    for y in (-2.0, -1.45, -0.9, -0.35, 0.2):
        x = -1.9 - W + b.rng.uniform(0.0, 0.3)
        while x < 1.9 + W:
            w = b.rng.uniform(0.45, 0.75)
            inside = abs(x + w / 2) < 0.6 + W or y < -0.5  # in the opening, or out in front
            ring = ((x + w / 2) / (2.1 + W)) ** 2 + ((y + 0.75) / 1.6) ** 2 < 1.0
            if inside and ring and b.rng.random() < 0.8:
                b.box((w - 0.08, b.rng.uniform(0.42, 0.52), 0.1), (x + w / 2, y + b.rng.uniform(-0.04, 0.04), 0.06),
                      rot=(0, 0, b.rng.uniform(-6, 6)), color={"lstone": 4, "stone": 2}, jit=0.015)
            x += w

    # A marker stone in front, carved with two rows of worn letters.
    with b.at((-1.55 - W, -1.75, 0), (0, 0, 14)):
        b.ico(1, 1, loc=(0, 0, 0.3), scale=(0.55, 0.22, 0.5), color=stone, jit=0.02, floor=0.0)
        for row, z in ((0, 0.5), (1, 0.33)):
            for k in range(4 - row):
                x = -0.24 + k * 0.15 + row * 0.07
                b.beam((x, -0.22, z - 0.05), (x + b.rng.uniform(-0.03, 0.03), -0.22, z + 0.05), 0.022, 0.02, color="dstone")
                b.beam((x - 0.03, -0.22, z + b.rng.uniform(-0.03, 0.04)), (x + 0.04, -0.22, z + b.rng.uniform(-0.03, 0.04)),
                       0.02, 0.02, color="dstone")

    # Rubble: fallen blocks and stones to the right, and pebbles strewn about.
    b.ico(0.42, 1, loc=(2.2 + W, -1.25, 0.22), scale=(1.1, 0.9, 0.8), color=stone, jit=0.07, floor=0.0)
    b.ico(0.28, 1, loc=(2.55 + W, -0.6, 0.12), color=stone, jit=0.05, floor=0.0)
    b.box((0.45, 0.35, 0.3), (1.75 + W, -1.95, 0.13), rot=(4, 0, 25), color=stone, jit=0.03)
    for _ in range(9):
        a = b.rng.uniform(0, 2 * math.pi)
        r = b.rng.uniform(1.9, 2.6)
        b.ico(b.rng.uniform(0.06, 0.12), 0, loc=(math.cos(a) * (r * 1.1 + W), -0.75 + math.sin(a) * r * 0.8, 0.03),
              color=STONE, jit=0.02, floor=0.0)

    # Ivy: leafy masses spilling over the lintel and capstones, vines trailing down the
    # stones from them, front and back, and clumps at the pillars' feet. Each leaf is a
    # low four-sided pyramid, tipped every which way.
    leafy = {"grass": 3, "dgrass": 2, "lgrass": 2}

    def leaf(p, size):
        rot = (b.rng.uniform(-70, 70), b.rng.uniform(-70, 70), b.rng.uniform(0, 360))
        b.cyl(size, 0, size * 0.5, seg=4, loc=p, rot=rot, color=leafy)

    def clump(p, radius, n, size=0.2):
        p = Vector(p)
        for _ in range(n):
            q = p + Vector([b.rng.uniform(-radius, radius) for _ in range(3)]) * 0.8
            q.z = max(q.z, size * 1.2)  # however it tips, no leaf sinks below the ground
            leaf(q, size * b.rng.uniform(0.8, 1.2))

    def vine(top, length, y, lean=0.0):
        """A vine trailing down a face (at depth y: negative the front, positive the
        back) from `top`, a leaf pair every step standing off the face."""
        p = Vector((top[0], y, top[1]))
        out = -0.04 if y < 0 else 0.04
        steps = int(length / 0.14)
        for i in range(steps):
            q = p + Vector((b.rng.uniform(-0.05, 0.05) + lean, 0, -0.14))
            b.beam(p, q, 0.025, 0.025, color="olive")
            for s in (-1, 1):
                if b.rng.random() < 0.85:
                    size = 0.17 * (1.0 - 0.35 * i / steps)
                    leaf(q + Vector((s * size * 0.8, out, b.rng.uniform(-0.03, 0.03))), size)
            p = q

    def masses(x0, x1, z, y, chance=0.8):
        x = x0
        while x < x1:
            if b.rng.random() < chance:
                clump((x, y, z), 0.2, 6)
            x += b.rng.uniform(0.16, 0.28)

    # Front: over the capstones and the lintel's front edge, and trailing down the faces.
    masses(-1.8 - W, -0.1, 3.86, -0.25)
    masses(0.1, 1.85 + W, 3.9, -0.25)
    masses(-1.95 - W, 1.95 + W, 3.36, -0.48)
    for top, length, y, lean in (((-0.72 - W, 2.75), 2.2, -0.47, 0.004), ((-1.62 - W, 2.75), 0.9, -0.47, 0.0),
                                 ((0.62 + W, 2.7), 1.6, -0.45, 0.0), ((1.92 + W, 2.75), 1.3, -0.47, 0.01),
                                 ((-0.3, 3.3), 0.6, -0.49, 0.0), ((1.0, 3.3), 0.5, -0.49, 0.0),
                                 ((-2.2 - W, 2.35), 1.0, -0.38, -0.01)):
        vine(top, length, y, lean)
    # Back: over the capstones' and the lintel's back edges, and down the backs of the
    # pillars.
    masses(-1.8 - W, -0.1, 3.86, 0.25, 0.7)
    masses(0.1, 1.85 + W, 3.9, 0.25, 0.7)
    masses(-1.95 - W, 1.95 + W, 3.34, 0.48)
    for top, length, y, lean in (((-0.8 - W, 2.75), 1.9, 0.47, 0.006), ((-1.5 - W, 2.75), 1.4, 0.47, -0.004),
                                 ((0.75 + W, 2.75), 2.1, 0.45, -0.004), ((1.6 + W, 2.75), 1.1, 0.46, 0.0),
                                 ((-0.6, 3.3), 0.5, 0.49, 0.0), ((0.4, 3.3), 0.7, 0.49, 0.0),
                                 ((1.2, 3.3), 0.45, 0.49, 0.0), ((-2.2 - W, 2.35), 1.3, 0.38, -0.01)):
        vine(top, length, y, lean)
    # Clumps at the feet, front and back (none in the opening, which stays clear to walk
    # through), and out among the flagstones and rubble.
    for p in ((-1.1 - W, -0.55, 0.12), (1.2 + W, -0.55, 0.12), (1.95 + W, -0.55, 0.15),
              (-2.15 - W, -0.45, 0.12), (-1.3 - W, -2.05, 0.08), (2.0 + W, -1.55, 0.1), (1.3, -2.15, 0.05),
              (-1.2 - W, 0.55, 0.12), (1.4 + W, 0.55, 0.12), (-2.3 - W, 0.45, 0.1)):
        clump(p, 0.28, 9, 0.2)


@asset("enemies")
def enemy_lovebird(b):
    """Rosy-faced (peach-faced) lovebird in flight, faces -Y, life size: 0.18 m from beak
    to tail tip and 0.37 m across its spread wings, with its origin at the middle of its
    body (hover it in game). A stocky bright green bird with a big round head, a red
    forehead fading to salmon-pink cheeks and throat, a white ring round each dark eye
    and a pale hooked beak. Its rump is blue. Its wings are spread wide and flat, every
    flight feather its own piece: green and blue coverts over green-and-blue secondaries
    and grey-brown primaries fanning out to the tip. Its short tail is a fan of green and
    blue feathers, and its grey-brown feet hang under its belly.

    Rigged for a flying animation (rest pose as modeled, wings spread level). Sides are
    its own: l is +X.
      body (root, at the middle of the body) > head
      body > wing_<side>_0 (shoulder to elbow) > wing_<side>_1 (to the wrist) > wing_<side>_2 (to the tip of the hand)
      body > tail_0 (root) > tail_1 (tip)
      body > leg_<side> (hip to ankle)
    Each feather follows the bone it grows from, blended across the joint when it grows
    near one, so the wing folds and flaps without gaps. The tail feathers bend from
    tail_0 into tail_1, so spreading or bending the tail curls them smoothly."""
    S = 0.01  # laid out in centimeters
    sides = {"l": 1, "r": -1}

    def cm(*p):
        return Vector(p) * S

    # Wing joints (left side; the right mirrors in X): shoulder, elbow, wrist, hand tip.
    wing = [Vector((2.0, -0.8, 1.4)), Vector((5.0, 0.0, 1.7)), Vector((8.5, -1.0, 1.8)), Vector((11.0, -0.3, 1.8))]
    tail = [Vector((0, 5.0, -0.4)), Vector((0, 7.5, -0.8)), Vector((0, 11.5, -1.3))]
    hips = {side: (Vector((s * 1.0, -0.8, -1.6)), Vector((s * 1.1, -1.8, -3.7))) for side, s in sides.items()}
    head_c = Vector((0, -5.2, 1.5))

    # Skeleton (before any geometry: adding the weight layer invalidates vertices).
    b.bone("body", cm(0, 0, 0), cm(0, -3, 0.4))
    b.bone("head", cm(0, -3.6, 0.8), cm(0, -7.0, 1.9), "body")
    for side, s in sides.items():
        j = [cm(p.x * s, p.y, p.z) for p in wing]
        b.bone(f"wing_{side}_0", j[0], j[1], "body")
        b.bone(f"wing_{side}_1", j[1], j[2], f"wing_{side}_0")
        b.bone(f"wing_{side}_2", j[2], j[3], f"wing_{side}_1")
    b.bone("tail_0", cm(*tail[0]), cm(*tail[1]), "body")
    b.bone("tail_1", cm(*tail[1]), cm(*tail[2]), "tail_0")
    for side, (hip, ankle) in hips.items():
        b.bone(f"leg_{side}", cm(*hip), cm(*ankle), "body")
    b.P = M(scale=S)  # the geometry is laid out in centimeters too

    def mark():
        return len(b.bm.verts)

    def since(m):
        """The vertices made since mark() returned m."""
        return [v for v in list(b.bm.verts)[m:] if v.is_valid]

    def local(f):
        """A face's center in the centimeter layout."""
        return f.calc_center_median() / S

    def oval_tube(sections, seg=8, color="toxic"):
        """Tube through `sections` of (center, half-width, half-height): an oval cross
        section, widest across X. A half-width of 0 closes it to a point."""
        rings = b.tube([c for c, _, _ in sections], [1.0 if w > 0 else 0.0 for _, w, _ in sections],
                       seg=seg, color=color)
        for ring, (c, w, h) in zip(rings, sections):
            c = b.P @ Vector(c)
            for v in ring:
                d = v.co - c
                v.co = c + Vector((d.x * w, d.y * w, d.z * h))
        return rings

    def feather(root, u, length, width, color, thick=0.1, droop=0.2):
        """A flat feather from `root` along the unit vector `u`, lying in the plane of u
        and the horizontal (its flat side up), rounded at the tip and drooping a little
        toward it. Returns its vertices."""
        root, u = Vector(root), Vector(u).normalized()
        v = u.cross(Vector((0, 0, 1)))
        if v.length < 1e-6:
            v = Vector((1, 0, 0))
        v.normalize()
        n = v.cross(u)
        if n.z < 0:
            n = -n
        outline = [(0, -0.3), (0.5, -0.5), (0.94, -0.26), (0.94, 0.26), (0.5, 0.5), (0, 0.3)]
        top = [root + u * length * a + v * width * c - n * droop * a * a for a, c in outline]
        coords = top + [p - n * thick for p in top]
        k = len(outline)
        faces = [tuple(range(k)), tuple(range(2 * k - 1, k - 1, -1))]
        faces += [(i, (i + 1) % k, k + (i + 1) % k, k + i) for i in range(k)]
        return b.poly(coords, faces, color=color)

    # Body: a plump egg, deepest at the breast, tapering back to the rump and running
    # forward up into the head. Green all over, with a blue rump above the tail and the
    # salmon pink of the throat spilling onto the upper breast. It follows `body`, and
    # its front, inside the neck, blends into `head`.
    def body_color(f):
        c = local(f)
        if c.y > 3.0 and c.z > 0.2:
            return "cyan"
        if c.y < -2.6 and c.z < 1.0:
            return "flesh"
        return {"toxic": 8, "lgrass": 1}
    m = mark()
    oval_tube([((0, 6.0, -0.4), 0.4, 0.35), ((0, 5.6, -0.35), 0.9, 0.8), ((0, 4.3, -0.2), 1.8, 1.6),
               ((0, 2.4, -0.1), 2.5, 2.4), ((0, 0.0, 0.0), 2.8, 2.8), ((0, -2.4, 0.3), 2.6, 2.7),
               ((0, -3.9, 0.9), 2.3, 2.4), ((0, -4.8, 1.3), 0.0, 0.0)], seg=10, color=body_color)
    for v in since(m):
        w = smoothstep(-3.0, -4.4, v.co.y / S)
        b.weigh([v], {k: x for k, x in (("body", 1 - w), ("head", w)) if x > 0})

    # Head: big and round. A red forehead and fore-crown, salmon-pink cheeks and throat,
    # green behind; a white ring round each dark eye; a pale hooked beak.
    def head_color(f):
        c = local(f) - head_c
        if c.y < -0.3 and c.z > 0.3 or c.y < -1.2 and c.z > -0.2:
            return "orange"
        if c.y < 0.6 and c.z <= 0.3:
            return "flesh"
        return {"toxic": 8, "lgrass": 1}
    m = mark()
    def on_head(x, y, z):
        return tuple(head_c + Vector((x, y, z)))
    b.ico(1, 2, loc=head_c, scale=(2.3, 2.4, 2.3), color=head_color)
    for s in (-1, 1):
        b.ico(0.72, 1, loc=on_head(s * 1.9, -0.95, 0.55), scale=(0.35, 1, 1), color="white")
        b.ico(0.5, 1, loc=on_head(s * 2.05, -1.0, 0.55), scale=(0.5, 1, 1), color="black")
        b.ico(0.13, 0, loc=on_head(s * 2.2, -1.25, 0.75), color="white")
    oval_tube([(on_head(0, -1.6, 0.4), 0.85, 0.95), (on_head(0, -2.5, 0.1), 0.7, 0.75),
               (on_head(0, -3.1, -0.6), 0.45, 0.5), (on_head(0, -3.0, -1.4), 0.2, 0.2),
               (on_head(0, -2.7, -1.7), 0.0, 0.0)], seg=6, color="bone")
    oval_tube([(on_head(0, -1.4, -0.9), 0.75, 0.6), (on_head(0, -2.3, -1.0), 0.5, 0.4),
               (on_head(0, -2.6, -0.8), 0.0, 0.0)], seg=6, color="bone")
    b.weigh(since(m), {"head": 1.0})

    # Tail: a blue upper-tail covert over a short fan of eight feathers, green in the
    # middle and blue at the sides, sloping back and a little down. Each feather bends
    # from `tail_0` into `tail_1` along its length.
    m = mark()
    oval_tube([((0, 3.4, 0.6), 1.6, 1.0), ((0, 5.4, 0.2), 1.3, 0.6), ((0, 7.2, -0.3), 0.8, 0.3),
               ((0, 8.2, -0.6), 0.0, 0.0)], seg=8, color="cyan")
    oval_tube([((0, 3.6, -1.2), 1.4, 0.9), ((0, 5.6, -1.0), 1.1, 0.5), ((0, 7.0, -1.1), 0.0, 0.0)],
              seg=8, color="toxic")
    fan = 8
    for k in range(fan):
        x = (k + 0.5) / fan * 2 - 1  # -1 at the right edge to 1 at the left
        a = math.radians(24 * x)
        u = Vector((math.sin(a), math.cos(a), -0.12))
        length = 6.6 - 1.2 * abs(x)
        root = tail[0] + Vector((x * 0.6, 0, -0.04 * abs(x)))
        color = "toxic" if abs(x) < 0.3 else ("cyan" if abs(x) < 0.8 else {"cyan": 1, "lgrass": 1})
        feather(root, u, length, 1.5, color, droop=0.4)
    for v in since(m):
        y = v.co.y / S
        w1 = smoothstep(6.6, 8.6, y)
        w0 = smoothstep(3.8, 5.2, y) - w1
        b.weigh([v], {k: x for k, x in (("body", 1 - w0 - w1), ("tail_0", w0), ("tail_1", w1)) if x > 0})

    # Wings, spread wide and level. A slim leading edge runs out along the bones, and
    # under rows of green and blue coverts the flight feathers fan out behind it: the
    # secondaries along the forearm, green shading to blue toward the wrist, and the long
    # grey-brown primaries from the hand, swinging round from back to out to make the tip.
    def chain_point(p):
        """A point on the wing's bones: 0 is the shoulder, 1 the elbow, 2 the wrist, 3 the tip."""
        i = min(int(p), 2)
        return i, p - i, wing[i].lerp(wing[i + 1], p - i)

    def wing_weights(side, i, t):
        bones = [f"wing_{side}_{k}" for k in range(3)]
        prev = bones[i - 1] if i > 0 else "body"
        if t > 0.8 and i < 2:
            k = (t - 0.8) / 0.4
            return {bones[i]: 1 - k, bones[i + 1]: k}
        if t < 0.2:
            k = (0.2 - t) / 0.4
            return {bones[i]: 1 - k, prev: k}
        return {bones[i]: 1.0}

    primary_len = [6.0, 6.4, 6.8, 7.1, 7.4, 7.6, 7.6, 7.3, 6.8]
    for side, s in sides.items():
        def grow(p, angle, length, width, color, lift=0.0, droop=0.2):
            """A feather at `p` along the bones, `angle` degrees round from straight back
            toward the tip, skinned to the bones at its root."""
            i, t, root = chain_point(p)
            a = math.radians(angle)
            m = mark()
            feather(Vector((root.x * s, root.y, root.z + lift)), (s * math.sin(a), math.cos(a), 0),
                    length, width, color, droop=droop)
            b.weigh(since(m), wing_weights(side, i, t))

        # The leading edge, from inside the body's shoulder out to the hand's tip, skinned
        # to the nearest bone and blended across each joint.
        m = mark()
        pts = [Vector((0.8, -0.6, 1.2))] + wing
        oval_tube([((p.x * s, p.y, p.z), r, r * 0.5) for p, r in
                   zip(pts, (1.1, 0.8, 0.55, 0.4, 0.0))], seg=6, color="toxic")
        joints = [cm(p.x * s, p.y, p.z) for p in pts]
        bones = ["body"] + [f"wing_{side}_{k}" for k in range(3)]
        for v in since(m):
            best = None
            for i, (a, c) in enumerate(zip(joints, joints[1:])):
                d = c - a
                t = min(max((v.co - a).dot(d) / d.length_squared, 0.0), 1.0)
                dist = (v.co - (a + d * t)).length
                if best is None or dist < best[0]:
                    best = (dist, i, t)
            _, i, t = best
            w = {bones[i]: 1.0}
            if t > 0.8 and i + 1 < len(bones):
                k = (t - 0.8) / 0.4
                w = {bones[i]: 1 - k, bones[i + 1]: k}
            elif t < 0.2 and i > 0:
                k = (0.2 - t) / 0.4
                w = {bones[i]: 1 - k, bones[i - 1]: k}
            b.weigh([v], w)

        # Flight feathers, outermost (lowest) first so each lies over the one beyond it.
        for k in range(9):
            q = 8 - k
            grow(2.0 + 0.98 * q / 8, 18 + 64 * q / 8, primary_len[q], 1.6,
                 {"lstone": 2, "sand": 2, "lsand": 1}, lift=-0.05 - 0.03 * k, droop=0.35)
        for k in range(9):
            q = 8 - k
            x = q / 8
            color = "toxic" if x < 0.35 else ({"toxic": 1, "cyan": 1} if x < 0.7 else {"cyan": 2, "lgrass": 1})
            grow(0.35 + 1.6 * x, -6 + 18 * x, 4.6 + 0.8 * x, 1.8, color, lift=-0.1 - 0.03 * k)
        # Coverts over the bases of the flight feathers: greater coverts and primary
        # coverts, then a short row of lesser coverts along the front of the arm.
        for k in range(6):
            x = k / 5
            grow(2.05 + 0.85 * x, 22 + 45 * x, 3.3, 1.5, {"toxic": 2, "cyan": 1}, lift=0.14, droop=0.15)
        for k in range(9):
            x = k / 8
            grow(0.4 + 1.55 * x, -4 + 16 * x, 2.9, 1.6, {"toxic": 3, "cyan": 1, "lgrass": 1}, lift=0.2, droop=0.15)
        for k in range(7):
            x = k / 6
            grow(0.5 + 2.2 * x, -2 + 30 * x, 1.8, 1.5, {"toxic": 4, "lgrass": 1}, lift=0.3, droop=0.1)

    # Legs: green feathered thighs tucked into the belly, and short grey-brown legs
    # hanging down and a little forward, each with two toes forward and two back, curled.
    for side, s in sides.items():
        hip, ankle = hips[side]
        m = mark()
        b.ico(0.9, 1, loc=(s * 1.1, -0.7, -2.0), scale=(0.9, 1.2, 1), color="toxic")
        b.tube([hip + Vector((0, 0, 0.3)), hip.lerp(ankle, 0.5), ankle], [0.4, 0.3, 0.3], seg=5, color="lwood")
        for dx, dy, dz in ((0.35, -1.3, -0.3), (-0.15, -1.25, -0.35), (0.4, 1.0, -0.4), (-0.1, 1.05, -0.3)):
            toe = ankle + Vector((s * dx, dy, dz))
            mid = ankle.lerp(toe, 0.55) + Vector((0, 0, 0.2))
            b.tube([ankle, mid, toe, toe + Vector((0, 0, -0.35))], [0.22, 0.18, 0.12, 0.0], seg=4,
                   color="lwood")
        for v in since(m):
            w = smoothstep(-1.9, -2.6, v.co.z / S)
            b.weigh([v], {k: x for k, x in (("body", 1 - w), (f"leg_{side}", w)) if x > 0})


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
    mats = tuple(make_material(img, g) for g in (False, True, "portal", "water"))
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
