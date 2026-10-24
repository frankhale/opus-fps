"""
Copy the generated asset pack into the Godot project and configure how Godot imports it.

For every model this writes the [params] section of its .import file so that:
  * the GLB's PS1_Palette / PS1_Glow materials are replaced by the project's PS1 shader
    materials (godot/materials/ps1_palette.tres and ps1_glow.tres), and a portal's
    PS1_Portal membrane by the shimmering see-through godot/materials/ps1_portal.tres,
    and a creek's PS1_Water sheet by the flowing godot/materials/ps1_water.tres, and
    grass by the soft godot/materials/grass.tres, and the jellyfish's PS1_Jelly bell by
    the glowing pink-to-blue godot/materials/jelly.tres, and poured PS1_Flow water (the
    rain fountain's) by the rippling godot/materials/flow.tres
  * a model with its own palette (assets/palette_<model>.png, see PALETTE_VARIANTS in
    generate_assets.py) gets PS1 materials of its own sampling that palette, written as
    godot/materials/ps1_palette_<model>.tres and ps1_glow_<model>.tres
  * terrain and solid scenery get a static trimesh collision body

Run from the repo root after regenerating the assets, then let Godot reimport:
  python3 tools/sync_godot_assets.py
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path godot --import
"""
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets")
DST = os.path.join(ROOT, "godot", "assets")
MATERIALS = os.path.join(ROOT, "godot", "materials")
CATEGORIES = ["terrain", "scenery", "weapons", "pickups", "enemies", "viewmodel", "ammo"]

# Scenery you walk through rather than bump into.
NO_COLLISION = {"grass_tuft", "grass_patch", "flowers", "skull_pile", "bush", "bush_short"}
# Models with a walk-through membrane. scripts/portal.gd builds their frame collision
# at runtime, since a trimesh of the whole model would make the membrane solid.
PORTALS = {"portal"}
# Models with a PS1_Water sheet.
WATER = {"terrain_creek"}
# Models with a PS1_Jelly bell.
JELLY = {"enemy_jellyfish"}
# Models with poured PS1_Flow water.
FLOW = {"fountain_rain"}
# Grass, drawn with the soft grass material (godot/materials/grass.tres) instead of the
# sharp PS1 one, since it's scattered by the thousand.
GRASS = {"grass_patch"}
COLLIDES = {"terrain", "scenery"}

PALETTE_IMPORT = """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=0
mipmaps/generate=false
detect_3d/compress_to=0
"""


def glb_import(name, collision):
    palette = "grass.tres" if name in GRASS else "ps1_palette.tres"
    glow = "ps1_glow.tres"
    if os.path.exists(os.path.join(SRC, f"palette_{name}.png")):
        palette, glow = f"ps1_palette_{name}.tres", f"ps1_glow_{name}.tres"
    portal = ""
    if name in PORTALS:
        portal = ''',
"PS1_Portal": {
"use_external/enabled": true,
"use_external/path": "res://materials/ps1_portal.tres"
}'''
    if name in WATER:
        portal += ''',
"PS1_Water": {
"use_external/enabled": true,
"use_external/path": "res://materials/ps1_water.tres"
}'''
    if name in JELLY:
        portal += ''',
"PS1_Jelly": {
"use_external/enabled": true,
"use_external/path": "res://materials/jelly.tres"
}'''
    if name in FLOW:
        portal += ''',
"PS1_Flow": {
"use_external/enabled": true,
"use_external/path": "res://materials/flow.tres"
}'''
    nodes = ""
    if collision:
        # shape_type 2 = trimesh; body_type 0 = static
        nodes = f''',
"nodes": {{
"PATH:{name}": {{
"generate/physics": true,
"physics/body_type": 0,
"physics/shape_type": 2
}}
}}'''
    return f'''[remap]

importer="scene"
importer_version=1
type="PackedScene"

[params]

nodes/root_type=""
nodes/root_name=""
meshes/ensure_tangents=false
meshes/generate_lods=false
meshes/create_shadow_meshes=false
meshes/light_baking=0
animation/import=false
gltf/embedded_image_handling=0
_subresources={{
"materials": {{
"PS1_Glow": {{
"use_external/enabled": true,
"use_external/path": "res://materials/{glow}"
}},
"PS1_Palette": {{
"use_external/enabled": true,
"use_external/path": "res://materials/{palette}"
}}{portal}
}}{nodes}
}}
'''


def write(path, text):
    """Write an .import file, keeping the uid Godot assigned so scene references survive."""
    if os.path.exists(path):
        with open(path) as f:
            uid = next((l for l in f.read().splitlines() if l.startswith("uid=")), None)
        if uid:
            text = text.replace('type="PackedScene"\n', f'type="PackedScene"\n{uid}\n', 1)
            text = text.replace('type="CompressedTexture2D"\n', f'type="CompressedTexture2D"\n{uid}\n', 1)
    with open(path, "w") as f:
        f.write(text)


def variant_materials(name):
    """A model's own PS1 materials: the shared ones, sampling its palette instead."""
    for kind in ("palette", "glow"):
        with open(os.path.join(MATERIALS, f"ps1_{kind}.tres")) as f:
            text = f.read()
        text = text.replace("res://assets/palette.png", f"res://assets/palette_{name}.png")
        with open(os.path.join(MATERIALS, f"ps1_{kind}_{name}.tres"), "w") as f:
            f.write(text)


def main():
    os.makedirs(DST, exist_ok=True)
    for f in sorted(os.listdir(SRC)):
        if f == "palette.png" or f.startswith("palette_") and f.endswith(".png"):
            shutil.copy2(os.path.join(SRC, f), os.path.join(DST, f))
            write(os.path.join(DST, f + ".import"), PALETTE_IMPORT)
            if f != "palette.png":
                variant_materials(f[len("palette_"):-len(".png")])
    count = 0
    for cat in CATEGORIES:
        os.makedirs(os.path.join(DST, cat), exist_ok=True)
        for f in sorted(os.listdir(os.path.join(SRC, cat))):
            if not f.endswith(".glb"):
                continue
            name = f[:-4]
            dst = os.path.join(DST, cat, f)
            shutil.copy2(os.path.join(SRC, cat, f), dst)
            write(dst + ".import", glb_import(name, cat in COLLIDES and name not in NO_COLLISION | PORTALS))
            count += 1
    print(f"synced {count} models + palette into {DST}")


if __name__ == "__main__":
    main()
