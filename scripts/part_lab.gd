@tool
extends Node3D

## 部件实验室 —— 给"你自己建模"用的工具。
##
## 循环：在 Goxel / MagicaVoxel 里画 → 存成 Goxel 文本（每行 x y z rrggbb）
## → 丢进 data/parts/models/ → 这个场景自动重载 → 转着看，连接面自动标出来。
## 满意了就按 G，在 data/parts/ 生成/更新对应的 .part.txt，建造模式里立刻就能用。
##
## 按键：1..9 选模型 · R 暂停自转 · G 生成部件文件 · E 另存一份体素文本到 exports/

const MODEL_DIR := "res://data/parts/models"
const PART_DIR := "res://data/parts"
const EXPORT_DIR := "res://exports"
const RELOAD_INTERVAL := 0.4
const VIEW_SCALE := 14.0
## 预览用的画布（4x4x4 cube = 64^3 体素）：Goxel 场景是无界的，
## 大模型也能完整显示；实际部件体积由生成出的 cubes 字段决定。
const PREVIEW_CUBES := Vector3i(4, 4, 4)

var _models := []
var _index := 0
var _volume: VoxVolume
var _model_root: Node3D
var _markers: Node3D
var _camera: Camera3D
var _hud: Label
var _spin := true
var _yaw := -30.0
var _pitch := 18.0
var _dist := 30.0
var _timer := 0.0
var _stamp := 0
var _dragging := false
var _built := false


func _ready() -> void:
	if _built:
		return
	_built = true
	_build_world()
	_scan_models()
	_show_current()


func _build_world() -> void:
	var world := WorldEnvironment.new()
	world.environment = VehicleViewer.make_garage_environment()
	add_child(world)
	add_child(VehicleViewer.make_garage_sun())

	var floor_node := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	floor_node.mesh = plane
	floor_node.position.y = -0.02
	floor_node.material_override = VehicleViewer.make_floor_material(Vector2(40.0, 40.0))
	add_child(floor_node)

	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 40.0
	add_child(_camera)
	_apply_camera()

	_model_root = Node3D.new()
	_model_root.name = "Model"
	_model_root.scale = Vector3.ONE * VIEW_SCALE
	_model_root.position = Vector3(-0.5, -0.5, -0.5) * VIEW_SCALE  # 模型中心落在原点
	add_child(_model_root)
	_markers = Node3D.new()
	_markers.name = "ConnectionMarkers"
	_model_root.add_child(_markers)

	_hud = Label.new()
	_hud.name = "HUD"
	_hud.position = Vector2(16.0, 12.0)
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color(0.93, 0.94, 0.96))
	_hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_hud.add_theme_constant_override("shadow_offset_x", 1)
	_hud.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_hud)


func _scan_models() -> void:
	_models = []
	# 递归扫 data/parts 下面所有模型文件（支持"一个零件一个文件夹"）
	_models.append_array(PartLibrary.find_files_recursive(PART_DIR, ".vox"))
	_models.append_array(PartLibrary.find_files_recursive(PART_DIR, ".vox.txt"))
	_models.sort()
	if _models.is_empty():
		# 第一次进来给一份带说明的模板，省得对着空目录发呆
		var template := PART_DIR + "/template.vox.txt"
		VoxModel.write_template(template)
		_models.append(template)


func _show_current() -> void:
	for child in _model_root.get_children():
		if child != _markers:
			_model_root.remove_child(child)
			child.queue_free()
	for child in _markers.get_children():
		_markers.remove_child(child)
		child.queue_free()
	_volume = null
	if _models.is_empty():
		_update_hud()
		return
	var path: String = _models[_index % _models.size()]
	_stamp = FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0
	var target := VoxVolume.VOXELS_PER_CUBE * PREVIEW_CUBES
	# 按扩展名选装载器：.vox 走 MagicaVoxel 格式，其余按 Goxel 文本读
	var result := (
		VoxFile.load_vox(path, target)
		if path.to_lower().ends_with(".vox")
		else VoxModel.load_text(path, target)
	)
	_volume = result.get("volume")
	if _volume == null:
		_update_hud()
		return
	var part := PartDef.new()
	part.model_path = path
	part.cubes = PREVIEW_CUBES
	var build := part.build()
	if build.get("mesh") != null:
		var mesh_node := MeshInstance3D.new()
		mesh_node.mesh = build["mesh"]
		mesh_node.material_override = build["material"]
		_model_root.add_child(mesh_node)
	_add_markers()
	_update_hud()


## 连接面：用半透明色块标出来（默认连接面用另一种颜色）
func _add_markers() -> void:
	if _volume == null:
		return
	var dirs := VoxModel.derive_connections(_volume)
	var default_dir := Vector3i.ZERO
	var best := -99
	for dir in dirs:
		if -dir.y > best:
			best = -dir.y
			default_dir = dir
	for dir in dirs:
		var marker := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(1.0, 1.0)
		marker.mesh = quad
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = (
			Color(1.0, 0.85, 0.3, 0.55) if dir == default_dir else Color(0.4, 1.0, 0.5, 0.35)
		)
		marker.material_override = material
		var normal := Vector3(dir)
		marker.look_at_from_position(Vector3(dir) * 0.502, Vector3(dir) * 0.502 + normal, Vector3.UP)
		_markers.add_child(marker)


func _process(delta: float) -> void:
	if _spin and not Engine.is_editor_hint():
		_model_root.rotate_y(deg_to_rad(18.0 * delta))
	_timer += delta
	if _timer >= RELOAD_INTERVAL:
		_timer = 0.0
		_check_reload()


## 模型文件一改就重载 —— 这是"建模 → 存盘 → 立刻看到"的关键
func _check_reload() -> void:
	if _models.is_empty():
		return
	var path: String = _models[_index % _models.size()]
	if not FileAccess.file_exists(path):
		return
	if FileAccess.get_modified_time(path) != _stamp:
		_show_current()
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(4.0, _dist * 0.9)
			_apply_camera()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(200.0, _dist * 1.1)
			_apply_camera()
	elif event is InputEventMouseMotion and _dragging:
		_yaw -= event.relative.x * 0.3
		_pitch = clampf(_pitch + event.relative.y * 0.2, -85.0, 85.0)
		_apply_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			_index = int(event.keycode) - int(KEY_1)
			_show_current()
		elif event.keycode == KEY_R:
			_spin = not _spin
		elif event.keycode == KEY_G:
			_generate_part()
		elif event.keycode == KEY_E:
			_export_copy()


func _apply_camera() -> void:
	if _camera == null:
		return
	var yaw := deg_to_rad(_yaw)
	var pitch := deg_to_rad(_pitch)
	var dir := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	_camera.position = dir * _dist
	_camera.look_at(Vector3.ZERO, Vector3.UP)


## 由当前模型生成/更新部件文件：形状交给模型，连接面由判据自动推导。
func _generate_part() -> void:
	if _models.is_empty() or _volume == null:
		_set_notice("没有可生成的模型")
		return
	var path: String = _models[_index % _models.size()]
	var id := path.get_file().get_basename().get_basename()
	var dirs := VoxModel.derive_connections(_volume)
	if dirs.is_empty():
		_set_notice("这个模型没有任何面够大做连接点（≥40%），先补点体积")
		return
	var tokens := PackedStringArray()
	for dir in dirs:
		var axis := "xyz"[VoxMesher.axis_of(dir)]
		tokens.append(("+" if dir[VoxMesher.axis_of(dir)] > 0 else "-") + axis)
	var cubes := VoxModel.required_cubes(_volume)
	var text := "\n".join(PackedStringArray([
		"# 由部件实验室生成：形状来自外部模型，连接面由判据自动推导",
		"# 要改模型就改 model 指向的文件（画完存盘，实验室会自动重载）",
		"",
		"name = %s" % id,
		"model = %s" % path,
		"cubes = %d %d %d" % [cubes.x, cubes.y, cubes.z],
		"render = voxel",
		"order = 60",
		"connections = %s" % " ".join(tokens),
		"",
	]))
	# 部件文件写在**模型旁边**（一个零件一个文件夹）
	var part_path := path.get_base_dir().path_join("%s.part.txt" % id)
	var file := FileAccess.open(part_path, FileAccess.WRITE)
	if file == null:
		_set_notice("写不了 %s" % part_path)
		return
	file.store_string(text)
	file.close()
	_set_notice("已生成 %s（连接面：%s）" % [part_path, " ".join(tokens)])


func _export_copy() -> void:
	if _volume == null:
		_set_notice("没有可导出的模型")
		return
	var path: String = _models[_index % _models.size()]
	var id := path.get_file().get_basename().get_basename()
	var out_dir := ProjectSettings.globalize_path(EXPORT_DIR)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var out := out_dir.path_join("%s.exported.vox.txt" % id)
	var count := VoxExporter.write_goxel_text(_volume, out)
	_set_notice("已导出 %s（%d 体素）" % [out, count])


func _set_notice(text: String) -> void:
	print("[part_lab] %s" % text)
	_update_hud(text)


func _update_hud(notice := "") -> void:
	if _hud == null:
		return
	var lines := PackedStringArray()
	lines.append("部件实验室 · 1 cube = 16^3 体素")
	lines.append("")
	if _models.is_empty():
		lines.append("data/parts/models/ 里还没有 .vox.txt 模型")
	else:
		var path: String = _models[_index % _models.size()]
		lines.append("模型 %d/%d：%s" % [_index % _models.size() + 1, _models.size(), path.get_file()])
		if _volume != null:
			var dirs := VoxModel.derive_connections(_volume)
			var text := []
			for dir in dirs:
				text.append(("%+d,%+d,%+d" % [dir.x, dir.y, dir.z]))
			lines.append("体素：%d 格" % _volume.solid_count())
			lines.append("自动推导的连接面（绿色，黄色=默认）：%s" % str(text))
	lines.append("")
	lines.append("1..9 选模型 · R 暂停自转 · G 生成部件文件 · E 导出副本")
	lines.append("改完模型存盘即可，这里每 0.4 秒自动重载")
	if not notice.is_empty():
		lines.append("▸ %s" % notice)
	_hud.text = "\n".join(lines)
