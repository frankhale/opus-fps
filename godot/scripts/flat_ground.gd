class_name FlatGround
## Dead flat grass ground, painted like the levels' ground: the pack's palette material
## dimmed like the terrain (Terrain.ground_brightness), every face on the grass swatch.
## Used by the model gallery and the hub.

const MATERIAL := preload("res://materials/ps1_palette.tres")
const BRIGHTNESS := 0.8
## The palette's grass swatch (column, row).
const GRASS_SWATCH := Vector2(1, 0)
## Size of the ground's faces (small faces keep the PS1 vertex snapping steady up close).
const STEP := 1.0


## Flat grass covering `area` (x/z rectangle) at height 0, solid underfoot (a collision
## box under it). Each face gets its own vertices so it can sit in the grass swatch, as
## the terrain tiles' faces do.
static func build(area: Rect2) -> MeshInstance3D:
	var nx := ceili(area.size.x / STEP)
	var nz := ceili(area.size.y / STEP)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	for j in nz:
		for i in nx:
			var x0 := area.position.x + i * STEP
			var z0 := area.position.y + j * STEP
			for c in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
				verts.append(Vector3(x0 + c.x * STEP, 0.0, z0 + c.y * STEP))
				uvs.append((GRASS_SWATCH * 16.0 + Vector2(2.0, 2.0) + c * 12.0) / Vector2(128.0, 64.0))
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat: ShaderMaterial = MATERIAL.duplicate()
	mat.set_shader_parameter("albedo_scale", BRIGHTNESS)
	mesh.surface_set_material(0, mat)
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = mesh
	var body := StaticBody3D.new()
	body.name = "Collision"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(area.size.x, 1.0, area.size.y)
	shape.shape = box
	shape.position = Vector3(area.get_center().x, -0.5, area.get_center().y)
	body.add_child(shape)
	ground.add_child(body)
	return ground
