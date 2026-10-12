"""
Render preview images for the asset pack produced by generate_assets.py.

Writes to <assets>/previews/:
  models/<name>.png   labeled thumbnail of every model
  sheet_<cat>.png     labeled contact sheet per category
  showcase.png        an outdoor scene assembled from the pack

Usage:
  Blender -b --factory-startup -P tools/render_previews.py -- <assets_dir>
"""
import bpy
import math
import os
import random
import sys

import numpy as np
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ASSETS = os.path.abspath(argv[0] if argv else "assets")
OUT = os.path.join(ASSETS, "previews")
CATEGORIES = ["terrain", "scenery", "weapons", "pickups", "enemies", "viewmodel"]
THUMB, LABEL_H, HEADER_H, PAD, COLS = 384, 72, 96, 8, 5
BG = (0.11, 0.12, 0.13)            # label / sheet background (display space)
VIEW = {"weapons": (1.0, -0.35, 0.45), "enemies": (0.7, -1.4, 0.55)}
PREFIXES = ("terrain_", "weapon_", "pickup_", "enemy_")

scene = bpy.context.scene


# ---------------------------------------------------------------------------
# Scene setup
# ---------------------------------------------------------------------------
def setup_scene():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    scene.render.engine = "BLENDER_EEVEE"
    scene.eevee.taa_render_samples = 16
    scene.view_settings.view_transform = "Standard"  # keep palette colors faithful
    scene.render.film_transparent = False
    if scene.world is None:
        scene.world = bpy.data.worlds.new("World")
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3.5
    sun.data.color = (1.0, 0.95, 0.85)
    sun.data.angle = math.radians(2)
    sun.rotation_euler = (math.radians(50), 0, math.radians(35))
    scene.collection.objects.link(sun)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    return sun, cam


def set_world(rgb, strength=1.0):
    w = scene.world
    bg = w.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (*rgb, 1)
    bg.inputs["Strength"].default_value = strength


def emission_mat(name, rgb):
    m = bpy.data.materials.new(name)
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*rgb, 1)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
    return m


def import_glb(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before]


def bounds(objs):
    pts = [o.matrix_world @ v.co for o in objs if o.type == "MESH" for v in o.data.vertices]
    lo = Vector([min(p[i] for p in pts) for i in range(3)])
    hi = Vector([max(p[i] for p in pts) for i in range(3)])
    return lo, hi


def render(path, w, h):
    scene.render.resolution_x, scene.render.resolution_y = w, h
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def load_pixels(path):
    im = bpy.data.images.load(path)
    w, h = im.size
    a = np.empty(w * h * 4, dtype=np.float32)
    im.pixels.foreach_get(a)
    bpy.data.images.remove(im)
    return a.reshape(h, w, 4)


def save_pixels(arr, path):
    h, w = arr.shape[:2]
    im = bpy.data.images.new(os.path.basename(path), w, h)
    im.pixels.foreach_set(arr.astype(np.float32).ravel())
    im.filepath_raw = path
    im.file_format = "PNG"
    im.save()
    bpy.data.images.remove(im)


def pretty(name):
    for p in PREFIXES:
        if name.startswith(p):
            name = name[len(p):]
    return name.replace("_", " ").title()


# ---------------------------------------------------------------------------
# Text strips (rendered far below the stage with an emissive backdrop)
# ---------------------------------------------------------------------------
class TextRig:
    ORIGIN = Vector((0, 0, -1000))

    def __init__(self):
        self.cam = bpy.data.objects.new("text_cam", bpy.data.cameras.new("text_cam"))
        self.cam.data.type = "ORTHO"
        self.cam.location = self.ORIGIN + Vector((0, 0, 10))
        scene.collection.objects.link(self.cam)
        plane = bpy.data.meshes.new("backdrop")
        plane.from_pydata([(-500, -500, 0), (500, -500, 0), (500, 500, 0), (-500, 500, 0)], [], [(0, 1, 2, 3)])
        plane.materials.append(emission_mat("bg", [c ** 2.2 for c in BG]))
        bd = bpy.data.objects.new("backdrop", plane)
        bd.location = self.ORIGIN
        scene.collection.objects.link(bd)
        self.mats = {"title": emission_mat("txt_title", (0.92, 0.9, 0.84)),
                     "sub": emission_mat("txt_sub", (0.42, 0.45, 0.48)),
                     "accent": emission_mat("txt_accent", (0.8, 0.55, 0.12))}
        self.items = []

    def _text(self, body, size, y, mat, max_w):
        cu = bpy.data.curves.new("t", "FONT")
        cu.body = body
        cu.size = size
        cu.align_x, cu.align_y = "CENTER", "CENTER"
        cu.materials.append(self.mats[mat])
        ob = bpy.data.objects.new("t", cu)
        ob.location = self.ORIGIN + Vector((0, y, 0.01))
        scene.collection.objects.link(ob)
        bpy.context.view_layer.update()
        if ob.dimensions.x > max_w:
            ob.scale *= max_w / ob.dimensions.x
        self.items.append(ob)

    def strip(self, path, w, h, lines):
        """lines: [(text, size, y_offset, material)] in units where the strip is 10 wide."""
        for o in self.items:
            bpy.data.objects.remove(o, do_unlink=True)
        self.items = []
        for text, size, y, mat in lines:
            self._text(text, size, y, mat, 9.4)
        self.cam.data.ortho_scale = 10
        prev = scene.camera
        scene.camera = self.cam
        render(path, w, h)
        scene.camera = prev
        return load_pixels(path)


# ---------------------------------------------------------------------------
# Thumbnails and sheets
# ---------------------------------------------------------------------------
def collect():
    out = []
    for cat in CATEGORIES:
        d = os.path.join(ASSETS, cat)
        for f in sorted(os.listdir(d)):
            if f.endswith(".glb"):
                out.append((cat, f[:-4]))
    return out


def thumbnails(cam, text, items):
    os.makedirs(os.path.join(OUT, "models"), exist_ok=True)
    tmp = os.path.join(OUT, "_tmp")
    os.makedirs(tmp, exist_ok=True)
    cam.data.type = "ORTHO"
    set_world((0.30, 0.36, 0.40), 1.0)
    cells = {}
    for cat, name in items:
        objs = import_glb(os.path.join(ASSETS, cat, name + ".glb"))
        lo, hi = bounds(objs)
        tris = sum(len(p.vertices) - 2 for o in objs if o.type == "MESH" for p in o.data.polygons)
        c, rad = (lo + hi) / 2, (hi - lo).length / 2
        d = Vector(VIEW.get(cat, (1.0, -1.4, 0.75))).normalized()
        cam.location = c + d * rad * 4
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        cam.data.ortho_scale = rad * 2.15
        cam.data.clip_start, cam.data.clip_end = rad * 0.1, rad * 10
        render(os.path.join(tmp, name + ".png"), THUMB, THUMB)
        img = load_pixels(os.path.join(tmp, name + ".png"))
        dims = hi - lo
        label = text.strip(os.path.join(tmp, name + "_label.png"), THUMB, LABEL_H, [
            (pretty(name), 1.15, 0.35, "title"),
            (f"{tris} tris   {dims.x:.1f} x {dims.z:.1f} x {dims.y:.1f} m (WxHxD)", 0.62, -0.62, "sub")])
        cell = np.concatenate([label, img], axis=0)  # rows run bottom-up
        save_pixels(cell, os.path.join(OUT, "models", name + ".png"))
        cells.setdefault(cat, []).append(cell)
        for o in objs:
            bpy.data.objects.remove(o, do_unlink=True)
    return cells


def sheets(text, cells):
    ch, cw = THUMB + LABEL_H, THUMB
    for cat, cs in cells.items():
        cols = min(COLS, len(cs))
        rows = math.ceil(len(cs) / cols)
        W = cols * (cw + PAD) + PAD
        H = rows * (ch + PAD) + PAD + HEADER_H
        sheet = np.ones((H, W, 4), dtype=np.float32)
        sheet[..., :3] = BG
        for i, cell in enumerate(cs):
            r, c = i // cols, i % cols
            y0 = H - HEADER_H - (r + 1) * (ch + PAD)
            x0 = PAD + c * (cw + PAD)
            sheet[y0:y0 + ch, x0:x0 + cw] = cell
        aspect = W / HEADER_H
        hdr = text.strip(os.path.join(OUT, "_tmp", f"hdr_{cat}.png"), W, HEADER_H, [
            (f"{cat.upper()}   -   {len(cs)} models", 10 / aspect * 0.42, 0, "accent")])
        sheet[H - HEADER_H:] = hdr
        save_pixels(sheet, os.path.join(OUT, f"sheet_{cat}.png"))


# ---------------------------------------------------------------------------
# Showcase scene
# ---------------------------------------------------------------------------
def showcase(cam, sun):
    lib = {}

    def place(name, x, y, rot=0.0, z=None, scale=1.0, lift=0.0):
        if name not in lib:
            cat = next(c for c in CATEGORIES if os.path.exists(os.path.join(ASSETS, c, name + ".glb")))
            src = import_glb(os.path.join(ASSETS, cat, name + ".glb"))
            lib[name] = src[0]
            ob = src[0]
        else:
            ob = lib[name].copy()
            scene.collection.objects.link(ob)
        if z is None:
            z = ground(x, y)
        ob.location = (x, y, z + lift)
        ob.rotation_mode = "XYZ"
        ob.rotation_euler = (0, 0, math.radians(rot))
        ob.scale = (scale, scale, scale)
        return ob

    terrain = []

    def ground(x, y):
        bpy.context.view_layer.update()
        dg = bpy.context.evaluated_depsgraph_get()
        best = 0.0
        for t in terrain:
            inv = t.matrix_world.inverted()
            o = inv @ Vector((x, y, 50))
            d = (inv.to_3x3() @ Vector((0, 0, -1))).normalized()
            hit, loc, _, _ = t.evaluated_get(dg).ray_cast(o, d)
            if hit:
                best = (t.matrix_world @ loc).z
        return best

    layout = {(-16, -8): "terrain_grass", (-8, -8): "terrain_grass", (0, -8): "terrain_dirt_path",
              (8, -8): "terrain_grass", (16, -8): "terrain_sand",
              (-16, 0): "terrain_grass", (-8, 0): "terrain_grass", (0, 0): "terrain_dirt_path",
              (8, 0): "terrain_pond", (16, 0): "terrain_grass",
              (-16, 8): "terrain_grass", (-8, 8): "terrain_hill", (0, 8): "terrain_dirt_path",
              (8, 8): "terrain_grass", (16, 8): "terrain_hill",
              (-16, 16): "terrain_grass", (-8, 16): "terrain_grass", (0, 16): "terrain_grass",
              (8, 16): "terrain_grass", (16, 16): "terrain_grass"}
    for x in range(-32, 33, 8):
        for y in range(-24, 17, 8):
            layout.setdefault((x, y), "terrain_dirt_path" if x == 0 else "terrain_grass")
    for (x, y), name in layout.items():
        terrain.append(place(name, x, y, z=0))
    for x in range(-32, 33, 8):
        place("terrain_cliff", x, 21.5, z=0)
    for x, y, s in ((-34, 48, 1.3), (-6, 55, 1.6), (22, 50, 1.2), (44, 44, 1.0), (-52, 40, 1.0)):
        place("terrain_mountain", x, y, z=-1, scale=s, rot=x * 7)

    rng = random.Random(3)
    for x, y in ((-18, 4), (-14, 10), (-19, 14), (-4, 18), (6, 18), (13, 15), (19, 12), (19, -2),
                 (-19, -6), (-11, 15), (10, 13)):
        place(rng.choice(("tree_pine", "tree_pine_tall")), x, y, rot=rng.uniform(0, 360))
    place("tree_oak", 6, -5, rot=30)
    place("tree_oak", -13, -10, rot=80)
    place("tree_dead", 12, 2.5, rot=120)
    place("cabin", -9, 1, rot=0)
    place("crate", -5.6, -0.6, rot=12)
    place("crate", -5.4, 0.6, rot=-8)
    place("barrel", -6.1, -1.6)
    place("barrel_explosive", 3.6, 9.5)
    for x in (-13, -11, -9, -7):
        place("fence_wood", x, -4.5)
    place("fence_post", -6, -4.5)
    place("lamp_post", -2.2, -3, rot=180)
    place("signpost", 2.2, -9, rot=-20)
    place("ruins_arch", 0, 9.5)
    place("ruins_pillar", -3.5, 12, rot=40)
    place("watchtower", 15, 7)
    place("well", -3.5, 4, rot=20)
    place("campfire", 3.5, -2)
    place("tent", 6.5, 1.5, rot=-75)
    place("rock_large", -4.5, 14, rot=40)
    place("rock_cluster", 11, -9, rot=10)
    place("rock_small", 2.4, 3.5, rot=60)
    place("log_fallen", 4.3, -0.6, rot=75)
    place("tree_stump", -15, -1)
    place("skull_pile", 12.5, 9.5)
    for _ in range(35):
        x, y = rng.uniform(-19, 19), rng.uniform(-12, 18)
        if abs(x) < 1.6 or (abs(x - 8) < 3 and abs(y) < 3):
            continue
        place(rng.choice(("grass_tuft", "grass_tuft", "bush", "flowers")), x, y, rot=rng.uniform(0, 360))

    place("enemy_grunt", 0.8, 4.5, rot=-10)
    place("enemy_grunt", -1.2, 7, rot=15)
    place("enemy_wolf", -4, -6, rot=-40)
    place("enemy_demon", 1.5, 13.5, rot=5)
    place("enemy_slime", 7.5, -4.5, rot=30)
    place("enemy_spider", -9.5, 7.5, rot=-30)
    place("enemy_golem", 13, 4.5, rot=-50)
    place("enemy_turret", 15, 7, z=ground(15, 7) + 4.1, rot=-30)
    place("enemy_floating_eye", -2.5, 1.5, lift=2.6, rot=20)
    place("pickup_medkit", -0.5, -6.5, rot=20)
    place("pickup_ammo_shells", 0.6, -5.2, rot=-30)
    place("powerup_quad_damage", 0, -1.5, lift=0.3)
    place("pickup_key_red", 0.4, 1.5, lift=0.3, rot=-20)
    place("pickup_armor", -0.7, -3.2, rot=15)
    place("pickup_gem", 3.6, 3.2, lift=0.3)
    place("pickup_ammo_cells", -0.8, 10.5, rot=10)

    cam.data.type = "PERSP"
    cam.data.lens = 24
    cam.data.clip_start, cam.data.clip_end = 0.1, 400
    cam.location = (3, -24, 7.5)
    cam.rotation_euler = (Vector((-0.5, 6, 1.5)) - cam.location).to_track_quat("-Z", "Y").to_euler()
    sun.rotation_euler = (math.radians(55), 0, math.radians(-40))
    sun.data.energy = 3.0
    set_world((0.50, 0.68, 0.80), 0.9)
    render(os.path.join(OUT, "showcase.png"), 1920, 1080)


def main():
    sun, cam = setup_scene()
    text = TextRig()
    cells = thumbnails(cam, text, collect())
    sheets(text, cells)
    showcase(cam, sun)
    tmp = os.path.join(OUT, "_tmp")
    for f in os.listdir(tmp):
        os.remove(os.path.join(tmp, f))
    os.rmdir(tmp)


main()
