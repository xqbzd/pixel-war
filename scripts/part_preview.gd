@tool
extends Node3D

## 部件建模闭环的验证场景，也是“车库预览”的雏形。
##
##   data/parts/*.part.txt                    (key = value 文本，AI 和人改的都是这里)
##          │
##          ▼  PartDef.build_volume()   → 16^3 体素体积（解析式形状 + 主体色/棱色）
##          ├─ texture 路线 → 六面 16x16 图集 + 每面 1 个四边形
##          └─ voxel   路线 → 贪心网格化 + 顶点色（斜面保留像素台阶）
##
## 两条路线读同一份体积，所以风格一致；同一部件的所有实例共享 1 个 mesh + 1 个材质，
## 且都塞进一个 MultiMeshInstance3D —— 用来实测“立方体部件数量很多”时到底花多少资源。
##
## T 切换立方体部件的渲染路线，E 导出 Goxel 体素文本 + 图集 PNG。

const PART_DIR := "res://data/parts"
const EXPORT_DIR := "res://exports"
const CUBE_PART_ID := "cube_full"
const PRISM_PART_ID := "half_cube"
const HULL := Vector3i(12, 6, 2)
const HULL_ORIGIN := Vector3(3.0, 3.0, -1.0)
const SHOWCASE_ORIGIN := Vector3(-7.0, 0.0, 3.0)

var auto_rotate_speed := 8.0

var _library := PartLibrary.new()
var _counts := {"cubes": 0, "prisms": 0}
var _cubes: MultiMeshInstance3D
var _prisms: MultiMeshInstance3D
var _camera: Camera3D
var _hud: Label
var _mode: int = PartDef.RenderMode.TEXTURE
var _yaw := -38.0
var _pitch := 22.0
var _dist := 24.0
var _target := Vector3(0.5, 2.6, 0.5)
var _dragging := false
var _hud_timer := 0.0
var _built := false


func _ready() -> void:
	if _built:
		return
	_built = true
	_load_parts()
	_setup_world()
	_build_instances()
	_apply_mode()
	_update_hud()


func _process(delta: float) -> void:
	if _camera == null:
		return
	if not Engine.is_editor_hint() and not _dragging and auto_rotate_speed != 0.0:
		_yaw += auto_rotate_speed * delta
		_apply_camera()
	_hud_timer += delta
	if _hud_timer >= 0.25:
		_hud_timer = 0.0
		_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(4.0, _dist - 1.5)
			_apply_camera()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(60.0, _dist + 1.5)
			_apply_camera()
	elif event is InputEventMouseMotion and _dragging:
		_yaw -= event.relative.x * 0.3
		_pitch = clampf(_pitch + event.relative.y * 0.2, -85.0, 85.0)
		_apply_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_T:
				toggle_mode()
			KEY_E:
				export_all()


func _load_parts() -> void:
	_library.load_all(PART_DIR)
	for warning in _library.warnings:
		push_warning(warning)


func _setup_world() -> void:
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	# 和载具预览共用同一套车库光照（全向柔光）：建模时看到的就是最终效果
	world.environment = VehicleViewer.make_garage_environment()
	add_child(world)

	add_child(VehicleViewer.make_garage_sun())

	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.current = true
	camera.fov = 45.0
	_camera = camera
	add_child(camera)
	_apply_camera()

	var hud := Label.new()
	hud.name = "HUD"
	hud.position = Vector2(16.0, 12.0)
	hud.add_theme_font_size_override("font_size", 14)
	hud.add_theme_color_override("font_color", Color(0.93, 0.94, 0.96))
	hud.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	hud.add_theme_constant_override("shadow_offset_x", 1)
	hud.add_theme_constant_override("shadow_offset_y", 1)
	_hud = hud
	add_child(hud)

	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 40.0)
	ground.mesh = plane
	ground.position = Vector3(0.0, -0.02, 0.0)
	# 同样铺建造场地那块带格线的地板（一格 = 1 cube，顺手当比例尺用）
	ground.material_override = VehicleViewer.make_floor_material(Vector2(60.0, 40.0))
	add_child(ground)


## 载具外壳：HULL 个立方体部件 + 顶部四角的斜切部件 + 一组展示件。
func _build_instances() -> void:
	var cube_transforms := []
	var prism_transforms := []
	var centre := Vector3(HULL) * 0.5

	for z in range(HULL.z):
		for y in range(HULL.y):
			for x in range(HULL.x):
				var pos := Vector3(x, y, z) - centre + HULL_ORIGIN
				cube_transforms.append(Transform3D(Basis(), pos))

	for z in range(2):
		for y in range(2):
			for x in range(2):
				cube_transforms.append(
					Transform3D(Basis(), SHOWCASE_ORIGIN + Vector3(x, y, z))
				)

	# 斜切部件的朝向：把斜面转到朝外
	var corners := [
		{"cell": Vector3i(0, HULL.y, 0), "yaw": 180.0},
		{"cell": Vector3i(HULL.x - 1, HULL.y, 0), "yaw": 90.0},
		{"cell": Vector3i(0, HULL.y, HULL.z - 1), "yaw": 270.0},
		{"cell": Vector3i(HULL.x - 1, HULL.y, HULL.z - 1), "yaw": 0.0},
	]
	for corner in corners:
		var cell: Vector3i = corner["cell"]
		var pos := Vector3(cell) - centre + HULL_ORIGIN
		var yaw_basis := Basis(Vector3.UP, deg_to_rad(float(corner["yaw"])))
		prism_transforms.append(Transform3D(yaw_basis, pos))
	prism_transforms.append(
		Transform3D(Basis(Vector3.UP, deg_to_rad(180.0)), SHOWCASE_ORIGIN + Vector3(2.4, 0.0, 0.0))
	)

	_cubes = _make_multimesh(cube_transforms, _build_for(CUBE_PART_ID, _mode))
	_cubes.name = "CubeParts"
	add_child(_cubes)
	_prisms = _make_multimesh(prism_transforms, _build_for(PRISM_PART_ID, PartDef.RenderMode.VOXEL))
	_prisms.name = "PrismParts"
	add_child(_prisms)
	_counts = {"cubes": cube_transforms.size(), "prisms": prism_transforms.size()}


func _make_multimesh(transforms: Array, build: Dictionary) -> MultiMeshInstance3D:
	return PartLibrary.make_multimesh(transforms, build)


## 部件 + 渲染路线的构建结果会缓存，切换路线只换 mesh/材质引用，节点数不变。
func _build_for(id: String, mode: int) -> Dictionary:
	return _library.build_for(id, mode)


func _apply_mode() -> void:
	var cube_build := _build_for(CUBE_PART_ID, _mode)
	var prism_build := _build_for(PRISM_PART_ID, PartDef.RenderMode.VOXEL)
	if _cubes != null:
		_cubes.multimesh.mesh = cube_build["mesh"]
		_cubes.material_override = cube_build["material"]
	if _prisms != null:
		_prisms.multimesh.mesh = prism_build["mesh"]
		_prisms.material_override = prism_build["material"]
	print("[parts] 立方体部件路线=%s（共享 mesh %d quad / %d tri，%d 个实例）；斜切部件 mesh %d quad / %d tri（%d 个实例）" % [
		cube_build["mode"],
		int(cube_build["quads"]),
		int(cube_build["tris"]),
		int(_counts["cubes"]),
		int(prism_build["quads"]),
		int(prism_build["tris"]),
		int(_counts["prisms"]),
	])


## 切换立方体部件的渲染路线（贴图 <-> 体素）。键盘 T 也走这里。
func toggle_mode() -> void:
	_mode = (
		PartDef.RenderMode.VOXEL
		if _mode == PartDef.RenderMode.TEXTURE
		else PartDef.RenderMode.TEXTURE
	)
	_apply_mode()
	_update_hud()


## 供脚本/自动化直接指定路线。
func set_cube_route(mode: int) -> void:
	_mode = mode
	_apply_mode()
	_update_hud()


## 供脚本/自动化读取两条路线的成本，用来量化“贴图更省”这件事。
func route_stats() -> Dictionary:
	var cube := _build_for(CUBE_PART_ID, _mode)
	var prism := _build_for(PRISM_PART_ID, PartDef.RenderMode.VOXEL)
	return {
		"cube_mode": cube["mode"],
		"cube_quads": int(cube["quads"]),
		"cube_tris": int(cube["tris"]),
		"prism_quads": int(prism["quads"]),
		"prism_tris": int(prism["tris"]),
		"cube_instances": int(_counts["cubes"]),
		"prism_instances": int(_counts["prisms"]),
	}


func export_all() -> Array:
	var dir_abs := ProjectSettings.globalize_path(EXPORT_DIR)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	var written := []
	for id in _library.ids():
		var def: PartDef = _library.get_def(id)
		var volume := def.build_volume()
		var text_path := dir_abs.path_join("%s.vox.txt" % id)
		var count := VoxExporter.write_goxel_text(volume, text_path)
		written.append(text_path)
		print("[export] %s → %s（%d 体素，可在 Goxel 里打开精修）" % [id, text_path, count])
		if PartLibrary.is_full_cube_part(def, volume):
			var png_path := dir_abs.path_join("%s_atlas.png" % id)
			var image := def.build_atlas_image()
			if image.save_png(png_path) == OK:
				written.append(png_path)
				print("[export] %s → %s（六面 16x16 图集）" % [id, png_path])
		else:
			print("[export] %s 不是满 cube 部件，跳过图集（贴图路线不适用）" % id)
	return written


func _apply_camera() -> void:
	if _camera == null:
		return
	var yaw := deg_to_rad(_yaw)
	var pitch := deg_to_rad(_pitch)
	var dir := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	_camera.position = _target + dir * _dist
	_camera.look_at(_target, Vector3.UP)


func _update_hud() -> void:
	if _hud == null:
		return
	var cube_build := _build_for(CUBE_PART_ID, _mode)
	var prism_build := _build_for(PRISM_PART_ID, PartDef.RenderMode.VOXEL)
	var cube_route := "六面 16x16 图集（每单元 6 面 = %d quad）" % int(cube_build["quads"]) \
		if cube_build["mode"] == "texture" \
		else "体素网格（%d quad，顶点色）" % int(cube_build["quads"])
	var lines := PackedStringArray()
	lines.append("部件建模闭环 · 1 cube = 16^3 = 4096 体素")
	lines.append("")
	lines.append("立方体部件：%d 个实例 → 1 个 MultiMesh 绘制" % int(_counts["cubes"]))
	lines.append("    路线 %s   [T 切换]" % cube_build["mode"])
	lines.append("    共享 mesh：%s（%d tri/部件）" % [cube_route, int(cube_build["tris"])])
	lines.append("斜切三棱柱：%d 个实例 → 1 个 MultiMesh 绘制" % int(_counts["prisms"]))
	lines.append("    路线 voxel（斜面保留像素台阶）")
	lines.append("    共享 mesh：%d quad / %d tri" % [int(prism_build["quads"]), int(prism_build["tris"])])
	lines.append("")
	lines.append("场景：%d tri · %d draw call · %.0f FPS · 贴图显存 %.1f KB" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		float(Performance.get_monitor(Performance.TIME_FPS)),
		float(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)) / 1024.0,
	])
	lines.append("[E] 导出 Goxel 体素文本 + 图集 PNG    [左键拖拽] 旋转    [滚轮] 缩放")
	_hud.text = "\n".join(lines)
