@tool
class_name BuildMode
extends Node3D

## 建造模式：自由飞行视角 + 像素风建造枪 + 半透明投影 + 左键放置。
##
## 规则层全在 voxel/build_grid.gd（纯逻辑，被 tests/test_build_grid.gd 覆盖）：
##   - 连接面 / 默认连接面：voxel/part_def.gd + voxel/vox_shapes.gd
##   - 小面唯一配对的账本、射线步进、候选放置：voxel/build_grid.gd
## 这个脚本只负责：相机、输入、投影、摆放、HUD。
##
## 镜像建造（`M` 开关，左右对称）也走规则层：镜像体的 (cell, basis) 由
## BuildGrid.mirror_placement() 算出来（零件对折 + 一个轴对齐旋转，不需要左手系副本），
## 本体和镜像体各自过一遍**完整**检查（越界 / 干涉 / 点数预算 / 基准格独占 / 连接对）；
## 镜像体放不下就连本体一起不放。拆除时按"镜像位置的基准格"找成对的那个零件。

const PART_DIR := "res://data/parts"
const MENU_SCENE := "res://scenes/main_menu.tscn"
const TEST_FIELD_SCENE := "res://scenes/test_field.tscn"
const GameSettings := preload("res://scripts/game_settings.gd")
const SPAWN := Vector3(34.0, 10.0, 0.0)  # 生成在场地前方（+x 是车头方向）
const SPAWN_YAW := 90.0  # 回头看场地
const SPAWN_PITCH := -15.0  # 一进来准星就落在场地地面上
const FLY_SPEED := 14.0
const LOOK_SPEED := 0.15  # 度 / 像素
const BUILD_REACH := 26.0
## 建造虚影：用零件自己的材质，只把它变半透明
const GHOST_ALPHA := 0.45
## 镜像体虚影：同一套材质染青一点，和本体虚影区分开
const MIRROR_TINT := Color(0.60, 0.86, 1.0)
## 对称面（竖直半透明面 + 地板上一条线）的高度
const MIRROR_PLANE_HEIGHT := 26.0
## 调试可视化：基准格 = 绿色半透明方块，能对接的连接点 = 小蓝球
## （只在场地变化时重建，不占每帧预算；零件一多开销就看得出，是纯调试用的）
const ANCHOR_COLOR := Color(0.35, 1.0, 0.45, 0.30)
const JOINT_COLOR := Color(0.35, 0.72, 1.0, 0.55)
const JOINT_RADIUS := 0.07
## 枪上悬浮零件的大小
const HOLO_SCALE := 0.10
const PP_BAR_SIZE := Vector2(220.0, 18.0)

const VEHICLE_DIR := "res://data/vehicles"
const DEFAULT_VEHICLE_NAME := "未命名载具"

## 主界面切场景前设置：要编辑哪辆车（id 为空 = 新建）。
## 用静态变量传参是 Godot 里最省事的做法（change_scene 不带参数）。
static var pending_vehicle := {}

var _library := PartLibrary.new()
var _grid := BuildGrid.new()
var _defs := {}
## 物品栏（10 格）。规则层是 voxel/part_loadout.gd（纯逻辑，被 tests/test_part_loadout.gd 守着），
## 界面是 scripts/part_picker.gd —— 这个脚本只当"中间人"。
var _loadout := PartLoadout.new()
var _picker: PartPicker
var _roll := 0
var _yaw := SPAWN_YAW
var _pitch := SPAWN_PITCH
var _bob := 0.0
var _moving := false
var _hit := {}
var _candidate := {}
var _mirror_plan := {}  # plan_mirror() 的结果（本体 + 镜像体）；镜像关着时是空的
var _mirror_on := false  # M 开关：左右对称建造
var _mirror_half := 0  # 对称面 = 世界 z = _mirror_half / 2（半格为单位，【/】各挪半格）
var _last_mirror_ms := 0  # 按住【/】的节流（和整体移动一样自己做，比键盘 echo 稳）
var _built := 0
## 重心显示（O 键开关）：标记本身在 scripts/com_marker.gd（和测试场共用）
var _com_marker: ComMarker
var _com_visible := false
var _com_height := 0.0        # 重心离地高度（HUD 用）

var _camera: Camera3D
var _viewmodel: Node3D
var _holo_pivot: Node3D
var _holo: MeshInstance3D
var _ghost: MeshInstance3D
var _ghost_sub: MeshInstance3D
var _mirror_ghost: MeshInstance3D
var _mirror_ghost_sub: MeshInstance3D
var _mirror_plane: MeshInstance3D
var _mirror_line: MeshInstance3D
var _anchor_markers: MultiMeshInstance3D
var _joint_markers: MultiMeshInstance3D
var _holo_sub: MeshInstance3D
var _aim_key := ""  # 上一次瞄准的输入指纹（用来跳过重复的 plan()）
var _grid_epoch := 0  # 场地改动计数：建/拆/整体移动后自增，用来作废瞄准缓存
## 连接点/基准格标记的"脏"标记 + 下次允许重建的时间（限流：拆零件时不每块都全量重扫）
var _markers_dirty := false
var _markers_due := 0
var _hud_text := ""
var _pp_bar: Control
var _pp_fill: ColorRect
var _pp_bar_text: Label
var _stats_label: Label
var _robot_ok := false
var _robot_reason := ""
## "能不能进测试场"这条结论是不是**还是最新的**：改动零件会把它置 false。
## 用户要求：**别每改一个零件就算一遍**（200+ 零件的大车白花钱），只在保存 / 去测试场时算。
var _robot_checked := false
var _hud: Label
var _crosshair: Control
var _ghost_materials := {}  # part_id -> 半透明材质（按部件缓存，别每帧 duplicate）
var _notice := ""  # 临时提示（整体移动失败原因 / 中键拾取结果）
var _notice_until := 0
var _last_move_ms := 0  # 按住方向键时的节流
var _vehicle_id := ""
var _vehicle_name := DEFAULT_VEHICLE_NAME
var _wall_label: Label3D
var _escape_layer: Control
var _escape_options: VBoxContainer
var _escape_settings: VBoxContainer
var _menu_open := false
var _scene_ready := false


func _ready() -> void:
	if _scene_ready:
		return
	_scene_ready = true
	_library.load_all(PART_DIR)
	GameSettings.play_music()   # 建造模式继续放同一首（跨场景不断）
	_defs = _library.defs
	_grid.set_defs(_defs)
	# 物品栏预填：按 order 排的前 10 个零件（原来的物品栏就是"全部零件"，现在只有 10 格）
	_loadout.fill_from(_library.ids())
	_build_world()
	_build_viewmodel()
	_build_hud()
	_build_picker()
	_build_markers()
	_apply_pending_vehicle()
	_build_wall()
	_build_escape_menu()
	if not Engine.is_editor_hint():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply_camera()
	_refresh_holo()
	_update_hud()


## 主界面选了哪辆车就载入哪辆；id 为空表示新建（空场地）。
func _apply_pending_vehicle() -> void:
	_vehicle_id = str(pending_vehicle.get("id", ""))
	_vehicle_name = str(pending_vehicle.get("name", DEFAULT_VEHICLE_NAME))
	if _vehicle_name.is_empty():
		_vehicle_name = DEFAULT_VEHICLE_NAME
	if _vehicle_id.is_empty():
		return
	# 载具文件可能在工程目录（自带车）也可能在 user://（玩家改过的）：交给 VehicleStore 找
	var path := VehicleStore.find_path(_vehicle_id)
	if path.is_empty():
		_set_notice("找不到载具文件 %s（工程目录和 user:// 都没有）" % _vehicle_id)
		return
	var vehicle := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)
	# 万一有零件的网格会探出场地（轮轴的轮体会往下探、载具又贴在最底下），
	# 就整体挪最小的量把它塞进场地 —— 但绝不"归一化"：载具在场地里的位置要原样保留。
	var shift := BuildGrid.fit_shift(vehicle.parts, _defs)
	if shift != Vector3i.ZERO:
		_set_notice("载具整体上移 %d 格以放进场地" % shift.y)
	var skipped := 0
	for part in vehicle.parts:
		var def: PartDef = _defs.get(part["part_id"])
		if def == null:
			skipped += 1
			continue
		# 载入已有部件：不需要再验证连接（文件本身就是合法结构）
		var placed := _grid.place(def, part["cell"] + shift, part["basis"])
		if not placed["ok"]:
			skipped += 1
			push_warning("加载 %s 的 %s 失败：%s" % [_vehicle_id, part["part_id"], placed.get("reason", "")])
	if skipped > 0:
		_set_notice("有 %d 个零件放不下，已跳过（其余已加载）" % skipped, 3000)
	_rebuild_parts()


## 场地背后的墙 + 载具名称（字大一点，方便确认自己在编辑哪辆）
func _build_wall() -> void:
	var wall := MeshInstance3D.new()
	wall.name = "BackWall"
	var quad := QuadMesh.new()
	quad.size = Vector2(46.0, 22.0)
	wall.mesh = quad
	var wall_material := StandardMaterial3D.new()
	wall_material.albedo_color = Color(0.15, 0.16, 0.19)
	wall_material.roughness = 1.0
	wall_material.metallic = 0.0
	wall.material_override = wall_material
	wall.position = Vector3(-32.1, 9.0, 0.0)
	wall.rotation_degrees = Vector3(0.0, 90.0, 0.0)  # 面朝 +x（玩家出生方向）
	add_child(wall)

	_wall_label = Label3D.new()
	_wall_label.name = "VehicleName"
	_wall_label.font_size = 256
	_wall_label.pixel_size = 0.017
	_wall_label.outline_size = 24
	_wall_label.modulate = Color(0.88, 0.91, 0.96)
	_wall_label.outline_modulate = Color(0.04, 0.05, 0.07)
	_wall_label.position = Vector3(-31.95, 13.0, 0.0)
	_wall_label.rotation_degrees = Vector3(0.0, 90.0, 0.0)
	add_child(_wall_label)
	_refresh_wall_name()


func _refresh_wall_name() -> void:
	if _wall_label != null:
		_wall_label.text = _vehicle_name


## ESC 菜单：游戏设置 / 保存 / 保存并退出 / 不保存退出
func _build_escape_menu() -> void:
	_escape_layer = Control.new()
	_escape_layer.name = "EscapeMenu"
	_escape_layer.anchor_right = 1.0
	_escape_layer.anchor_bottom = 1.0
	_escape_layer.visible = false
	add_child(_escape_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_escape_layer.add_child(dim)

	var centre := CenterContainer.new()
	centre.anchor_right = 1.0
	centre.anchor_bottom = 1.0
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_escape_layer.add_child(centre)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _panel_style())
	centre.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	card.add_child(box)

	var title := Label.new()
	title.text = "菜单"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	box.add_child(title)

	_escape_options = VBoxContainer.new()
	_escape_options.add_theme_constant_override("separation", 8)
	box.add_child(_escape_options)
	_add_menu_button(_escape_options, "游戏设置", _menu_show_settings)
	_add_menu_button(_escape_options, "保存", _menu_save)
	_add_menu_button(_escape_options, "去测试场（先保存）", _menu_go_test_field)
	_add_menu_button(_escape_options, "保存并退出", _menu_save_and_quit)
	_add_menu_button(_escape_options, "不保存退出", _menu_quit)
	_add_menu_button(_escape_options, "继续建造", _close_escape_menu)

	_escape_settings = VBoxContainer.new()
	_escape_settings.add_theme_constant_override("separation", 10)
	_escape_settings.visible = false
	box.add_child(_escape_settings)
	var body := Label.new()
	body.text = "和主界面的「游戏设置」是同一页，目前只有视角灵敏度。"
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(320.0, 0.0)
	body.add_theme_font_size_override("font_size", 14)
	body.add_theme_color_override("font_color", Color(0.80, 0.83, 0.88))
	_escape_settings.add_child(body)
	GameSettings.build_ui(_escape_settings)
	_add_menu_button(_escape_settings, "返回", _menu_hide_settings)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.12, 0.16)
	style.border_color = Color(0.26, 0.30, 0.38)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(22.0)
	return style


func _add_menu_button(parent: Node, text: String, handler: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(240.0, 34.0)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(handler)
	parent.add_child(button)


func _open_escape_menu() -> void:
	# 零件菜单和这个菜单不能同时开着（都抢鼠标）
	if _picker != null:
		_picker.set_menu_open(false)
	_menu_open = true
	_escape_layer.visible = true
	_menu_hide_settings()
	if not Engine.is_editor_hint():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_escape_menu() -> void:
	_menu_open = false
	_escape_layer.visible = false
	if not Engine.is_editor_hint():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _menu_show_settings() -> void:
	_escape_options.visible = false
	_escape_settings.visible = true


func _menu_hide_settings() -> void:
	_escape_settings.visible = false
	_escape_options.visible = true


func _menu_save() -> void:
	_save_vehicle()


## 去测试场：先验"有核心 + 所有零件都连到核心"，再存盘，然后切场景。
## 不合法（缺核心 / 有零件没连上）就不让进，理由直接弹在界面上。
func _menu_go_test_field() -> void:
	var robot := _refresh_robot_status()
	if not bool(robot.get("ok", false)):
		_set_notice("进不了测试场：%s" % str(robot.get("reason", "")), 3000)
		return
	if not _save_vehicle()["ok"]:
		return
	TestField.pending_vehicle = {"id": _vehicle_id, "name": _vehicle_name}
	_menu_open = false
	if not Engine.is_editor_hint():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().change_scene_to_file(TEST_FIELD_SCENE)


func _menu_save_and_quit() -> void:
	if _save_vehicle()["ok"]:
		_leave()


func _menu_quit() -> void:
	_leave()


func _leave() -> void:
	_menu_open = false
	if not Engine.is_editor_hint():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MENU_SCENE)


## 把场地上的零件写成 data/vehicles/<id>.vehicle.txt（坐标自动归一化）。
func _save_vehicle() -> Dictionary:
	var entries := []
	# _grid.parts 是"每个零件一份"，多零件共享格子也不会重复写
	for entry: Dictionary in _grid.parts:
		entries.append({
			"part_id": entry["part_id"],
			"cell": entry["origin"],
			"basis": entry["basis"],
		})
	if entries.is_empty():
		_set_notice("还没有放任何零件，没法保存")
		return {"ok": false, "reason": "没有零件"}
	if _vehicle_id.is_empty():
		_vehicle_id = _next_vehicle_id()
	# 导出版里 res:// 只读：写入目录由 VehicleStore 决定（导出 = user://，编辑器 = 工程目录）
	VehicleStore.ensure_write_dir()
	var path := VehicleStore.path_for(_vehicle_id)
	var result := VehicleDef.write_file(path, _vehicle_name, entries)
	# 保存时顺手做一次"能不能进测试场"的判定（顺带把结论刷到 HUD 上）。
	# 这是用户要的：判定只在**保存 / 去测试场**时做，不在每次改动时做。
	var status := _refresh_robot_status()
	if result["ok"]:
		var verdict := (
			"；全部连到核心，可以进测试场"
			if bool(status["ok"]) else "；⚠ %s" % str(status["reason"])
		)
		_set_notice("已保存：%s（%d 个零件）%s" % [path, int(result["count"]), verdict], 3000)
	else:
		_set_notice(str(result["reason"]))
	return result


## 判定"能不能进测试场"（装了核心 + 所有零件都连到核心），并把结论记下来给 HUD 用。
## **只在保存 / 去测试场时调**（用户要求：不要每改一个零件就算一遍）。
## 走的还是 `BuildGrid.robot_status()`，和测试场进场用的是同一段代码、同一张连接图。
func _refresh_robot_status() -> Dictionary:
	var status := _grid.robot_status()
	_robot_ok = bool(status.get("ok", false))
	_robot_reason = str(status.get("reason", ""))
	_robot_checked = true
	return status


func _next_vehicle_id() -> String:
	# 两个目录都查（工程自带 + user://），绝不覆盖已有的车
	return VehicleStore.next_id()


func _build_world() -> void:
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.environment = VehicleViewer.make_garage_environment()
	add_child(world)
	add_child(VehicleViewer.make_garage_sun())

	# 建造场地：64 x 64 格线地板 + 正前方的方向箭头
	var floor_node := MeshInstance3D.new()
	floor_node.name = "BuildFloor"
	var plane := PlaneMesh.new()
	plane.size = Vector2(
		float(VehicleViewer.BUILD_AREA_CUBES.x), float(VehicleViewer.BUILD_AREA_CUBES.z)
	)
	floor_node.mesh = plane
	floor_node.material_override = VehicleViewer.make_floor_material()
	floor_node.position.y = -0.02
	add_child(floor_node)
	add_child(VehicleViewer.make_forward_arrow())

	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	# 相机是每帧在 _process 里手动飞的，别参与物理插值（否则会被拉回旧位置）
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_camera.current = true
	_camera.fov = 75.0
	_camera.near = 0.05
	_camera.far = 500.0
	_camera.position = SPAWN  # 生成在场地前方（+x 是车头方向）
	add_child(_camera)

	_ghost = MeshInstance3D.new()
	_ghost.name = "Ghost"
	_ghost.visible = false
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # 虚影不该投影
	add_child(_ghost)
	# 虚影也要带上附属子模型（轮体），否则瞄准预览里只有轮轴没有轮胎
	_ghost_sub = MeshInstance3D.new()
	_ghost_sub.name = "GhostSub"
	_ghost_sub.visible = false
	_ghost_sub.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ghost_sub)

	# 镜像体虚影：镜像开着时和本体虚影一起画（偏青），拆/建都要看得见镜像落在哪
	_mirror_ghost = MeshInstance3D.new()
	_mirror_ghost.name = "MirrorGhost"
	_mirror_ghost.visible = false
	_mirror_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mirror_ghost)
	_mirror_ghost_sub = MeshInstance3D.new()
	_mirror_ghost_sub.name = "MirrorGhostSub"
	_mirror_ghost_sub.visible = false
	_mirror_ghost_sub.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mirror_ghost_sub)

	# 对称面：一片竖直半透明面 + 地板上一条青线（半格一挪，得看得出来落在哪）
	_mirror_plane = MeshInstance3D.new()
	_mirror_plane.name = "MirrorPlane"
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(float(VehicleViewer.BUILD_AREA_CUBES.x), MIRROR_PLANE_HEIGHT)
	_mirror_plane.mesh = plane_mesh
	# PlaneMesh 默认躺在 XZ；绕 x 转 -90 度立起来（size.x 沿世界 x、size.y 沿世界 y）
	_mirror_plane.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_mirror_plane.position = Vector3(0.0, MIRROR_PLANE_HEIGHT * 0.5, 0.0)
	_mirror_plane.material_override = _mirror_plane_material()
	_mirror_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mirror_plane.visible = false
	add_child(_mirror_plane)
	_mirror_line = MeshInstance3D.new()
	_mirror_line.name = "MirrorLine"
	var line_mesh := BoxMesh.new()
	line_mesh.size = Vector3(float(VehicleViewer.BUILD_AREA_CUBES.x), 0.02, 0.05)
	_mirror_line.mesh = line_mesh
	_mirror_line.position = Vector3(0.0, 0.012, 0.0)
	_mirror_line.material_override = _mirror_plane_material()
	_mirror_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mirror_line.visible = false
	add_child(_mirror_line)


## 对称面的材质：不投影（别挡住后面的零件看），正反面都画，alpha 很低。
## 透明材质默认不写深度（DEPTH_DRAW_OPAQUE_ONLY），所以不用再手动关。
static func _mirror_plane_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.40, 0.82, 1.0, 0.10)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


## 对称面的位置与可见性：世界 z = _mirror_half / 2（半格为单位）。
func _update_mirror_plane() -> void:
	if _mirror_plane == null:
		return
	var plane_z := BuildGrid.mirror_plane(_mirror_half)
	_mirror_plane.visible = _mirror_on
	_mirror_plane.position.z = plane_z
	_mirror_line.visible = _mirror_on
	_mirror_line.position.z = plane_z


## 调试标记：基准格（绿方块）+ 能对接的连接点（小蓝球）。
## 连接点画的是"真的能对上的小面"：零件级有这个朝向的连接面，**而且这一格上真的露出
## 够大的面**（和连接账本同一套判据 `claims_face()`），零件自己的内部面不画。
func _build_markers() -> void:
	_anchor_markers = _make_marker_node("AnchorMarkers", _marker_box(), ANCHOR_COLOR)
	_joint_markers = _make_marker_node("JointMarkers", _marker_sphere(), JOINT_COLOR)


func _make_marker_node(node_name: String, mesh: Mesh, colour: Color) -> MultiMeshInstance3D:
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = 0
	node.multimesh = multi
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = colour
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


## 比格子略小一点，免得和邻格的方块糊在一起
func _marker_box() -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * 0.94
	return mesh


func _marker_sphere() -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = JOINT_RADIUS
	mesh.height = JOINT_RADIUS * 2.0
	return mesh


## 标记表重建。
## ⚠️ 每个零件的标记（基准点 + 连接点）**只跟它自己的几何有关**：`claims_face()` 和
## `face_is_internal()` 都只吃 def / basis / transform，不看别的零件。所以**算一次就存进
## entry**（`_entry_markers`），之后每次重建只是把缓存拼起来。
## 以前每次都是全场重算 —— 360 件时实测 11.2 ms，而拆一块零件就会把标记表标脏，
## 于是"删零件卡一下"。Robocraft 编辑时也只动受影响的方块。
func _rebuild_markers() -> void:
	if _anchor_markers == null or _joint_markers == null:
		return
	var anchors := []
	var joints := []
	for entry: Dictionary in _grid.parts:
		var data := _entry_markers(entry)
		anchors.append(data["anchor"])
		joints.append_array(data["joints"])
	_fill_markers(_anchor_markers, anchors)
	_fill_markers(_joint_markers, joints)


## 单个零件的标记（缓存进 entry，零件被拆掉时跟着 entry 一起消失）。
## 缓存带签名：整车平移（`_grid.translate_all`）会改 origin/transform，缓存要跟着失效。
func _entry_markers(entry: Dictionary) -> Dictionary:
	var signature := [entry["origin"], entry["transform"]]
	if entry.has("_markers") and (entry["_markers"] as Dictionary).get("sig") == signature:
		return entry["_markers"]
	var anchor := Vector3(entry.get("anchor", entry["origin"])) + Vector3(0.5, 0.5, 0.5)
	var joints := []
	var def: PartDef = _defs.get(entry["part_id"])
	if def != null:
		var basis: Basis = entry["basis"]
		var transform: Transform3D = entry["transform"]
		for c in BuildGrid.cells_of(def, basis, entry["origin"]):
			for dir in VoxShapes.AXIS_DIRS:
				if not _grid.claims_face(def, basis, transform, c, dir):
					continue
				if _grid.face_is_internal(def, transform, c, dir):
					continue  # 自己身体里的面不是连接点
				joints.append(Vector3(c) + Vector3(0.5, 0.5, 0.5) + Vector3(dir) * 0.5)
	var data := {"anchor": anchor, "joints": joints, "sig": signature}
	entry["_markers"] = data
	return data


## 写标记实例：**不缩 `instance_count`**（改它要重新分配 GPU 缓冲，删零件时会 stall），
## 只在需要变大时扩容，其余时候只改 `visible_instance_count`。
func _fill_markers(node: MultiMeshInstance3D, positions: Array) -> void:
	var multi := node.multimesh
	if multi == null:
		return
	var needed := positions.size()
	if needed > multi.instance_count:
		multi.instance_count = needed
	for i in needed:
		multi.set_instance_transform(i, Transform3D(Basis(), positions[i]))
	multi.visible_instance_count = needed


## 像素风建造枪（右下角手持）+ 枪上方悬浮的当前零部件。
func _build_viewmodel() -> void:
	_viewmodel = Node3D.new()
	_viewmodel.name = "Viewmodel"
	_camera.add_child(_viewmodel)

	var gun := Node3D.new()
	gun.name = "BuildGun"
	_viewmodel.add_child(gun)
	var dark := _gun_material(Color("4a4e55"))
	var mid := _gun_material(Color("7b818a"))
	var glow := _gun_material(Color("6fd8e8"))
	glow.emission_enabled = true
	glow.emission = Color("6fd8e8")
	glow.emission_energy_multiplier = 1.4
	_gun_piece(gun, Vector3(0.10, 0.10, 0.34), Vector3(0.0, 0.0, -0.10), dark)  # 机身
	_gun_piece(gun, Vector3(0.05, 0.05, 0.24), Vector3(0.0, 0.02, -0.30), mid)  # 枪管
	_gun_piece(gun, Vector3(0.06, 0.06, 0.04), Vector3(0.0, 0.02, -0.43), glow)  # 枪口
	_gun_piece(gun, Vector3(0.04, 0.04, 0.12), Vector3(0.0, 0.08, -0.16), mid)  # 导轨
	_gun_piece(gun, Vector3(0.06, 0.16, 0.08), Vector3(0.0, -0.13, 0.02), dark)  # 握把
	_gun_piece(gun, Vector3(0.07, 0.12, 0.06), Vector3(0.0, -0.10, -0.08), mid)  # 弹匣
	# 摆到画面右下角
	gun.position = Vector3(0.44, -0.22, -0.52)
	gun.rotation_degrees = Vector3(2.0, -9.0, 3.0)

	_holo_pivot = Node3D.new()
	_holo_pivot.name = "HoloPart"
	_holo_pivot.position = Vector3(0.44, -0.05, -0.56)
	_viewmodel.add_child(_holo_pivot)
	_holo = MeshInstance3D.new()
	_holo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_holo.scale = Vector3.ONE * HOLO_SCALE
	# 让零件自身的中心落在挂点上（否则会偏出去半格）
	_holo.position = Vector3.ONE * (-0.5 * HOLO_SCALE)
	_holo_pivot.add_child(_holo)
	# 附属子模型（轮体）跟着一起画：网格顶点已经按挂载偏移摆好，所以缩放/位移和本体一致
	_holo_sub = MeshInstance3D.new()
	_holo_sub.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_holo_sub.scale = _holo.scale
	_holo_sub.position = _holo.position
	_holo_sub.visible = false
	_holo_pivot.add_child(_holo_sub)


static func _gun_material(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.75
	material.metallic = 0.1
	return material


static func _gun_piece(parent: Node3D, size: Vector3, offset: Vector3, material: Material) -> void:
	var box := BoxMesh.new()
	box.size = size
	var piece := MeshInstance3D.new()
	piece.mesh = box
	piece.material_override = material
	piece.position = offset
	piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(piece)


func _build_hud() -> void:
	# 左上角：部件点数占比条 + 条下方的总重量 / 总血量（用户要求的位置）
	_pp_bar = Control.new()
	_pp_bar.name = "PointsBar"
	_pp_bar.position = Vector2(16.0, 12.0)
	_pp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_pp_bar)
	var bg := Panel.new()
	bg.name = "BarBG"
	bg.size = Vector2(PP_BAR_SIZE.x, PP_BAR_SIZE.y)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.06, 0.07, 0.09, 0.72)
	bg_style.border_color = Color(1, 1, 1, 0.22)
	bg_style.set_border_width_all(1)
	bg.add_theme_stylebox_override("panel", bg_style)
	_pp_bar.add_child(bg)
	_pp_fill = ColorRect.new()
	_pp_fill.name = "BarFill"
	_pp_fill.color = Color("4fd08a")
	_pp_fill.size = Vector2(0.0, PP_BAR_SIZE.y - 4.0)
	_pp_fill.position = Vector2(2.0, 2.0)
	_pp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pp_bar.add_child(_pp_fill)
	_pp_bar_text = Label.new()
	_pp_bar_text.name = "PointsText"
	_pp_bar_text.position = Vector2(0.0, -1.0)
	_pp_bar_text.add_theme_font_size_override("font_size", 13)
	_pp_bar_text.add_theme_color_override("font_color", Color(0.93, 0.94, 0.96))
	_pp_bar_text.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_pp_bar_text.add_theme_constant_override("shadow_offset_x", 1)
	_pp_bar_text.add_theme_constant_override("shadow_offset_y", 1)
	_pp_bar_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pp_bar.add_child(_pp_bar_text)
	_stats_label = Label.new()
	_stats_label.name = "Stats"
	_stats_label.position = Vector2(16.0, 12.0 + PP_BAR_SIZE.y + 2.0)
	_stats_label.add_theme_font_size_override("font_size", 14)
	_stats_label.add_theme_color_override("font_color", Color(0.93, 0.94, 0.96))
	_stats_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_stats_label.add_theme_constant_override("shadow_offset_x", 1)
	_stats_label.add_theme_constant_override("shadow_offset_y", 1)
	_stats_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stats_label)

	_hud = Label.new()
	_hud.name = "HUD"
	# 帮助文字排在数值区下方
	_hud.position = Vector2(16.0, 12.0 + PP_BAR_SIZE.y + 44.0)
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color(0.93, 0.94, 0.96))
	_hud.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	_hud.add_theme_constant_override("shadow_offset_x", 1)
	_hud.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_hud)

	_crosshair = Control.new()
	_crosshair.name = "Crosshair"
	_crosshair.anchor_left = 0.5
	_crosshair.anchor_top = 0.5
	_crosshair.anchor_right = 0.5
	_crosshair.anchor_bottom = 0.5
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_crosshair)
	for offset in [Vector2(0, -9), Vector2(0, 9), Vector2(-9, 0), Vector2(9, 0)]:
		var tick := ColorRect.new()
		tick.color = Color(1, 1, 1, 0.75)
		tick.size = Vector2(2, 6) if offset.x == 0 else Vector2(6, 2)
		tick.position = offset - tick.size * 0.5
		tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_crosshair.add_child(tick)


## 零件选择界面：底部 10 格物品栏 + Tab 呼出的零件菜单。
## 界面细节全在 scripts/part_picker.gd（那里只管画和拖），这里只接信号。
func _build_picker() -> void:
	_picker = PartPicker.new()
	add_child(_picker)
	_picker.setup(_library, _loadout)
	_picker.slot_selected.connect(_on_slot_changed)
	_picker.slot_changed.connect(_on_slot_changed)
	_picker.menu_toggled.connect(_on_menu_toggled)
	_picker.notify.connect(_set_notice)


## 选中格变了 / 格子内容变了：手上的模型、虚影、HUD 都要跟着来一遍。
## 瞄准缓存不用手动作废 —— `_aim()` 的指纹里带了零件 id，换了零件指纹自然就变了。
func _on_slot_changed(_index: int) -> void:
	_refresh_holo()
	_update_hud()


## 菜单开着的时候要拖拽，所以把鼠标交还给玩家；关掉再锁回去。
func _on_menu_toggled(open: bool) -> void:
	if Engine.is_editor_hint():
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED


## 物品栏格子在提示文字里的编号：第 10 格显示成 0（和键盘上那排一致）。
func _slot_label(index: int) -> String:
	return str((index + 1) % 10)


func _short_name(part_id: String) -> String:
	var def: PartDef = _defs.get(part_id)
	return part_id if def == null else def.short_name()


# ---------------------------------------------------------------- 输入

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * LOOK_SPEED
		_pitch = clampf(_pitch - event.relative.y * LOOK_SPEED, -89.0, 89.0)
		_apply_camera()
	elif event is InputEventMouseButton and event.pressed:
		# 零件菜单开着：鼠标在界面上（滚轮别转零件，左右键也别建造 —— 那是给拖拽用的）
		if _picker != null and _picker.is_menu_open():
			return
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# 鼠标没锁定时先收回控制权，锁定时才是建造
				if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				else:
					_try_build()
			MOUSE_BUTTON_RIGHT:
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					_try_remove()
			MOUSE_BUTTON_WHEEL_UP:
				_rotate(1)
			MOUSE_BUTTON_WHEEL_DOWN:
				_rotate(-1)
			MOUSE_BUTTON_MIDDLE:
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					_pick_part()
	elif event is InputEventKey and event.pressed:
		# 整体移动允许按住连发（自己做节流，比键盘 echo 稳）
		if _move_delta_for_key(event.keycode) != Vector3i.ZERO:
			_move_from_key(event.keycode, event.echo)
			return
		# 【/】挪对称面（半格一档），也允许按住连发
		if event.keycode == KEY_BRACKETLEFT or event.keycode == KEY_BRACKETRIGHT:
			_move_mirror(-1 if event.keycode == KEY_BRACKETLEFT else 1, event.echo)
			return
		if event.echo:
			return
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			_select_slot(int(event.keycode) - int(KEY_1))
		elif event.keycode == KEY_0:
			_select_slot(9)   # 第 10 格挂在 0 上
		elif event.keycode == KEY_R:
			_rotate(1)
		elif event.keycode == KEY_M:
			_toggle_mirror()
		elif event.keycode == KEY_O:
			_toggle_com_marker()
		elif event.keycode == KEY_ESCAPE:
			if _picker != null and _picker.is_menu_open():
				_picker.set_menu_open(false)
			elif _menu_open:
				_close_escape_menu()
			else:
				_open_escape_menu()


func _process(delta: float) -> void:
	if _camera == null:
		return
	if _menu_open:
		return  # 菜单打开时暂停飞行与瞄准
	if not Engine.is_editor_hint():
		_fly(delta)
	_aim()
	# 标记整表重建限流（见 `_rebuild_parts()`）：最多 6 Hz，拆零件时不会卡
	if _markers_dirty and Time.get_ticks_msec() >= _markers_due:
		_markers_dirty = false
		_markers_due = Time.get_ticks_msec() + 160
		_rebuild_markers()
	_update_com_marker()
	_update_hud()


## 重心显示（O 键）：标记挂在建造场地的同一个坐标系里（地板在 y = 0，所以"离地高度"
## 就是重心自己的 y）—— 建造时就能看见"重心多高、前后偏不偏"，不用等进测试场。
func _toggle_com_marker() -> void:
	if _com_marker == null or not is_instance_valid(_com_marker):
		_com_marker = ComMarker.new()
		_com_marker.name = "ComMarker"
		add_child(_com_marker)
	_com_visible = not _com_visible
	_com_marker.visible = _com_visible
	_notice = "重心显示：%s（O 键切换）" % ("开" if _com_visible else "关")
	_notice_until = Time.get_ticks_msec() + 1500
	_update_com_marker()


func _update_com_marker() -> void:
	if not _com_visible or _com_marker == null or not is_instance_valid(_com_marker):
		return
	if _grid.parts.is_empty():
		_com_marker.visible = false
		return
	_com_marker.visible = true
	var com := _grid.center_of_mass(_defs)
	_com_marker.place_local(com)
	# 建造场地没有物理世界，直接用"重心自己的 y"当离地高度（地板固定在 y = 0）
	_com_height = _com_marker.update_drop(null, com.y)


func _fly(delta: float) -> void:
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		move.z += 1.0
	if Input.is_key_pressed(KEY_A):
		move.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		move.x += 1.0
	var vertical := 0.0
	if Input.is_key_pressed(KEY_SPACE):
		vertical += 1.0
	if Input.is_key_pressed(KEY_SHIFT):
		vertical -= 1.0
	var yaw_basis := Basis(Vector3.UP, deg_to_rad(_yaw))
	var step := (yaw_basis * move).normalized() if move.length() > 0.0 else Vector3.ZERO
	_moving = step.length() > 0.0 or not is_zero_approx(vertical)
	if _moving:
		_camera.position += (step + Vector3.UP * vertical).normalized() * FLY_SPEED * delta
		_bob += delta * 7.0
	# 别飞出场外太远，省得找不到场地
	_camera.position.x = clampf(_camera.position.x, -70.0, 70.0)
	_camera.position.z = clampf(_camera.position.z, -70.0, 70.0)
	_camera.position.y = clampf(_camera.position.y, 0.4, 80.0)
	var sway := Vector3(sin(_bob) * 0.004, cos(_bob * 2.0) * 0.003, 0.0) if _moving else Vector3.ZERO
	_viewmodel.position = sway


func _apply_camera() -> void:
	if _camera == null:
		return
	_camera.rotation_degrees = Vector3(_pitch, _yaw, 0.0)


# ---------------------------------------------------------------- 建造

func _current_def() -> PartDef:
	# 空格子返回 null（= 手上没东西），下面每个用到的地方都要能接受 null
	return _defs.get(_loadout.selected_part())


## 滚轮 / R：绕默认连接点所在的轴旋转当前部件（默认连接点始终留在底部那一侧）
func _rotate(step: int) -> void:
	_roll = posmod(_roll + step, 4)
	_refresh_holo()
	_update_hud()


## 数字键 1..0 / 点物品栏格子：切换物品栏里的一格
func _select_slot(slot: int) -> void:
	if _picker == null:
		return
	_picker.select(slot)


func _refresh_holo() -> void:
	var def := _current_def()
	if _holo == null:
		return
	if def == null:
		# 空格子：手上什么都不拿
		_holo.mesh = null
		_holo.material_override = null
		if _holo_sub != null:
			_holo_sub.mesh = null
			_holo_sub.visible = false
		return
	# 用零件自己的模型与材质（不再用蓝色投影），并且不随滚转档位转动
	var build := _library.build_default(def.id)
	_holo.mesh = build["mesh"]
	_holo.material_override = build["material"]
	# 附属子模型（轮体）：单独一份网格，跟着一起挂出来
	if _holo_sub != null:
		var sub := _library.build_sub(def.id)
		_holo_sub.mesh = sub.get("mesh")
		_holo_sub.material_override = sub.get("material")
		_holo_sub.visible = sub.get("mesh") != null


## 每一帧：射线找目标 → 算候选放置 → 更新半透明投影
func _aim() -> void:
	var origin := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	_hit = _grid.raycast(origin, dir, BUILD_REACH)
	# 瞄准的「输入」没变就不用重算：射线沿同一个小面滑动时格子/朝向/拾取的零件都一样，
	# 这时候 plan() 的结果必然也一样 —— 省下的正是每帧最贵的那一段。
	# 镜像状态也在里面：开关镜像、挪对称面都必须让缓存作废
	var key := "%s|%s|%s|%s|%s|%d|%d|%d|%d" % [
		_hit.get("type", "none"),
		_hit.get("cell", ""),
		_hit.get("dir", ""),
		_hit.get("part_id", ""),
		_loadout.selected_part(),   # 手上的零件（空格子 = 空串）也是指纹的一部分
		_roll,
		_grid_epoch,
		int(_mirror_on),
		_mirror_half,
	]
	if key == _aim_key:
		return
	_aim_key = key
	var def := _current_def()
	if def == null:
		# 空格子：没有东西可规划，虚影全收起来
		_mirror_plan = {}
		_candidate = {}
		_show_ghost({}, null, false)
		_show_ghost({}, null, true)
		return
	if _mirror_on:
		# 镜像模式：本体 + 镜像体一起规划（镜像体放不下就两个都不给）
		_mirror_plan = _grid.plan_mirror(def, _hit, _roll, _mirror_half, true)
		_candidate = _mirror_plan.get("body", {})
	else:
		_mirror_plan = {}
		_candidate = _grid.plan(def, _hit, _roll, true)
	_show_ghost(_candidate, def, false)
	_show_ghost(_mirror_plan.get("mirror", {}), def, true)


## 把一个候选摆放（本体或镜像体）画成半透明虚影。
## 检查没过时也照样画，只是画成红的 —— 镜像体被挡住时，"哪半边放不下"要一眼看得出来。
func _show_ghost(plan: Dictionary, def: PartDef, mirror: bool) -> void:
	var ghost := _mirror_ghost if mirror else _ghost
	var sub_node := _mirror_ghost_sub if mirror else _ghost_sub
	if ghost == null:
		return
	if plan.is_empty() or def == null:
		ghost.visible = false
		if sub_node != null:
			sub_node.visible = false
		return
	# 连接点合法但放不下（超框 / 撞到别的零件）时：红色虚影 + 不能放置
	var valid: bool = bool(plan.get("valid", true))
	ghost.mesh = _library.build_default(def.id)["mesh"]
	ghost.material_override = _ghost_material(def.id, not valid, mirror)
	# 用“连接点重合”算出来的变换，别自己拼 Transform3D(basis, 格子角点)：
	# 那样侧向建造时零件会被甩到隔壁格（踩过）。
	ghost.transform = plan["transform"]
	ghost.visible = true
	if sub_node != null:
		var sub := _library.build_sub(def.id)
		sub_node.mesh = sub.get("mesh")
		sub_node.material_override = _sub_ghost_material(def.id, not valid, mirror)
		sub_node.transform = plan["transform"]
		sub_node.visible = sub.get("mesh") != null


## 零件自己的材质 + 半透明（贴图/顶点色都保留），按 (部件, 是否非法, 是否镜像体) 缓存。
func _ghost_material(part_id: String, invalid := false, mirror := false) -> Material:
	var key := "%s:%s:%s" % [part_id, invalid, mirror]
	if _ghost_materials.has(key):
		return _ghost_materials[key]
	if invalid:
		# 红色虚影：明确"这里放不下"，所以用平涂红（不叠零件贴图，看得更清楚）
		var red := StandardMaterial3D.new()
		red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		red.albedo_color = Color(1.0, 0.25, 0.25, 0.32)
		_ghost_materials[key] = red
		return red
	var base: StandardMaterial3D = _library.build_default(part_id)["material"]
	if base == null:
		return null
	var ghost := base.duplicate() as StandardMaterial3D
	ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# albedo 的 RGB 保持白色（= 不改颜色，贴图/顶点色原样），只把 alpha 压下来
	# 镜像体再染一层青色（同一个零件要出两个虚影，得分得清哪个是镜像）
	var tint := MIRROR_TINT if mirror else Color(1.0, 1.0, 1.0)
	ghost.albedo_color = Color(tint.r, tint.g, tint.b, GHOST_ALPHA)
	_ghost_materials[key] = ghost
	return ghost


## 附属子模型（轮体）的虚影材质：规则和本体一样（非法 = 平涂红，合法 = 自己的材质压 alpha）。
func _sub_ghost_material(part_id: String, invalid := false, mirror := false) -> Material:
	var key := "%s:sub:%s:%s" % [part_id, invalid, mirror]
	if _ghost_materials.has(key):
		return _ghost_materials[key]
	var material: Material = null
	if invalid:
		var red := StandardMaterial3D.new()
		red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		red.albedo_color = Color(1.0, 0.25, 0.25, 0.32)
		material = red
	else:
		var base: StandardMaterial3D = _library.build_sub(part_id).get("material")
		if base != null:
			var ghost := base.duplicate() as StandardMaterial3D
			ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			var tint := MIRROR_TINT if mirror else Color(1.0, 1.0, 1.0)
			ghost.albedo_color = Color(tint.r, tint.g, tint.b, GHOST_ALPHA)
			material = ghost
	_ghost_materials[key] = material
	return material


func _try_build() -> void:
	var def := _current_def()
	if def == null:
		_set_notice("物品栏这一格是空的：Tab 打开零件菜单，把零件拖进来")
		return
	var parts_before: int = _grid.parts.size()
	if not _mirror_on:
		if _candidate.is_empty():
			return
		if not bool(_candidate.get("valid", true)):
			_set_notice("这里放不下：%s" % str(_candidate.get("reason", "")))
			return
		if _grid.place_plan(def, _candidate)["ok"]:
			_built += 1
			# 只把新放的那一件追加进去（以前整表重建，零件一多每放一块都卡一下）
			_append_parts(parts_before)
		return
	# 镜像模式：本体和镜像体各放各的 —— 谁违规就不放谁，另一边照放
	if _mirror_plan.is_empty():
		return
	if not bool(_mirror_plan.get("valid", true)):
		_set_notice("这里放不下：%s" % str(_mirror_plan.get("reason", "")))
		return
	var result := _grid.place_plan_mirror(def, _mirror_plan)
	if not result["ok"]:
		_set_notice("这里放不下：%s" % str(result.get("reason", "")))
		return
	_built += 1
	_append_parts(parts_before)
	if int(result["placed"]) == 1:
		# 只落了一边：把另一边被拒的理由说清楚
		if not bool(_mirror_plan.get("place_body", false)):
			_set_notice("只放下了镜像体：本体位置%s" % _side_reason(_mirror_plan.get("body", {})))
		elif not bool(_mirror_plan.get("place_mirror", false)):
			_set_notice("只放下了本体：镜像位置%s" % _side_reason(_mirror_plan.get("mirror", {})))


## 把某一侧的拒绝理由写成"（理由）"的样子（没有理由就给空串）。
func _side_reason(plan: Dictionary) -> String:
	var reason := str(plan.get("reason", ""))
	return "（%s）" % reason if not reason.is_empty() else ""


## M：开关镜像建造（左右对称）。对称面位置记着，下次开还是那儿（半格一档）。
func _toggle_mirror() -> void:
	_mirror_on = not _mirror_on
	_update_mirror_plane()
	_aim()
	_set_notice(
		"镜像建造：%s（对称面 z = %.1f，【/】挪半格）"
		% ["开" if _mirror_on else "关", BuildGrid.mirror_plane(_mirror_half)]
	)


## 【/】：把对称面左右挪**半格**（step 是半格数，±1）。
## 半格为单位是有讲究的：偶数停在格线上、奇数停在格子正中，两种都让"整数格 → 整数格"，
## 所以半格挪动不会把镜像体挪到格子外面去（见 BuildGrid.mirror_cell 的注释）。
func _move_mirror(step: int, echo := false) -> void:
	if not _mirror_on:
		return  # 没开镜像时【/】不做事，免得玩家以为没反应是坏了
	var now := Time.get_ticks_msec()
	if echo and now - _last_mirror_ms < 110:
		return
	_last_mirror_ms = now
	var wanted := clampi(
		_mirror_half + step, BuildGrid.MIRROR_HALF_MIN, BuildGrid.MIRROR_HALF_MAX
	)
	if wanted == _mirror_half:
		return
	_mirror_half = wanted
	_update_mirror_plane()
	_aim()
	_update_hud()


func _try_remove() -> void:
	if _hit.is_empty() or _hit.get("type", "none") != "part":
		return
	var part_id := str(_hit.get("part_id", ""))
	if _mirror_on:
		# 拆除前先把"要拆的那一件"记下来（拆完就找不到它了），拆完只从 MultiMesh 里挪掉这几件
		var victim: Dictionary = _grid.victim_at(_hit["cell"], part_id)
		var partner := {}
		if not victim.is_empty():
			var anchor: Vector3i = victim.get("anchor", victim["origin"])
			partner = _grid.entry_by_anchor(
				_grid.mirror_cell(anchor, _mirror_half), str(victim["part_id"])
			)
		var result := _grid.remove_with_mirror(_hit["cell"], part_id, _mirror_half)
		if int(result["removed"]) > 0:
			_built = maxi(0, _built - int(result["removed"]))
			if bool(result["mirrored"]):
				_set_notice("镜像拆除：对称位置那一个也拆了")
			var removed := []
			if not victim.is_empty():
				removed.append(victim)
			if not partner.is_empty() and not is_same(partner, victim):
				removed.append(partner)
			_remove_parts(removed)
		return
	# 多零件共享格子时，拆的必须是射线真正打中的那一个
	var target: Dictionary = _grid.victim_at(_hit["cell"], part_id)
	if _grid.remove(_hit["cell"], part_id):
		_built = maxi(0, _built - 1)
		_remove_parts([target])



## 中键点零件 = 把当前建造部件切成它（像 MC 的拾取方块）。
func _pick_part() -> void:
	if _hit.is_empty() or _hit.get("type", "none") != "part":
		return
	var part_id := str(_hit.get("part_id", ""))
	if part_id.is_empty():
		var entry: Variant = _grid.part_at(_hit["cell"])
		if entry == null:
			return
		part_id = str(entry["part_id"])
	if not _defs.has(part_id):
		return
	# 三条规则（已有就跳过去 / 有空位就放进去 / 全满就顶掉当前格）都在 PartLoadout 里，
	# 那边是纯逻辑、有测试；这里只负责把它变成人话提示。
	var result := _loadout.pick(part_id)
	var action := str(result["action"])
	if action == PartLoadout.ACTION_NONE:
		return
	_picker.refresh_slots()
	_on_slot_changed(_loadout.selected)
	var name := _short_name(part_id)
	match action:
		PartLoadout.ACTION_JUMP:
			_set_notice("已切到 %s 号格的 %s" % [_slot_label(int(result["slot"])), name])
		PartLoadout.ACTION_FILL:
			_set_notice(
				"%s 不在物品栏里：放进 %s 号格" % [name, _slot_label(int(result["slot"]))]
			)
		PartLoadout.ACTION_REPLACE:
			_set_notice(
				"物品栏满了：%s 号格换成 %s" % [_slot_label(int(result["slot"])), name]
			)


## 方向键 = 载具前后左右（+x 是车头），< / > = 下降 / 上升
func _move_delta_for_key(keycode: int) -> Vector3i:
	match keycode:
		KEY_UP:
			return Vector3i(1, 0, 0)
		KEY_DOWN:
			return Vector3i(-1, 0, 0)
		KEY_LEFT:
			return Vector3i(0, 0, -1)
		KEY_RIGHT:
			return Vector3i(0, 0, 1)
		KEY_COMMA:
			return Vector3i(0, -1, 0)
		KEY_PERIOD:
			return Vector3i(0, 1, 0)
	return Vector3i.ZERO


func _move_from_key(keycode: int, echo: bool) -> void:
	var delta := _move_delta_for_key(keycode)
	if delta == Vector3i.ZERO:
		return
	var now := Time.get_ticks_msec()
	if echo and now - _last_move_ms < 110:
		return
	_last_move_ms = now
	_move_vehicle(delta)


## 整体平移载具；超出场地就整体拒绝并提示。
func _move_vehicle(delta: Vector3i) -> void:
	var result := _grid.translate_all(delta)
	if not result["ok"]:
		_set_notice(str(result["reason"]))
		return
	_rebuild_parts()
	_aim()
	_update_hud()


func _set_notice(text: String, hold_ms := 1500) -> void:
	_notice = text
	_notice_until = Time.get_ticks_msec() + hold_ms
	_update_hud()


## 把网格里的部件重建为 MultiMesh（按 (部件, 路线) 分批），和载具预览同一套打包方式。
func _rebuild_parts() -> void:
	_grid_epoch += 1  # 场地变了：_aim() 的缓存作废
	# ⚠️ 这里**不算**"能不能进测试场"（用户要求：改动零件时别判）。改动只是把结论标脏，
	# 真正花时间的那次判定推迟到**保存 / 去测试场**（见 `_refresh_robot_status()`）。
	_robot_checked = false
	var old := get_node_or_null("PlacedParts")
	if old != null:
		remove_child(old)
		old.queue_free()
	var groups := {}
	# _grid.parts 每个零件一份（多格零件只画一次，多零件共享格子也不会重复画）
	for entry: Dictionary in _grid.parts:
		var key := "%s:%d" % [entry["part_id"], _default_mode(entry["part_id"])]
		if not groups.has(key):
			groups[key] = {
				"build": _library.build_default(entry["part_id"]),
				"sub": _library.build_sub(entry["part_id"]),
				"transforms": [],
				"entries": [],
			}
		groups[key]["transforms"].append(entry["transform"])
		(groups[key]["entries"] as Array).append(entry)
	var root := Node3D.new()
	root.name = "PlacedParts"
	add_child(root)
	# 记下"每一类零件对应哪几个 MultiMesh 节点"，之后放零件走 `_append_parts()` 增量追加
	_part_nodes = {}
	for key in groups.keys():
		var group: Dictionary = groups[key]
		var nodes := _make_group_nodes(group["transforms"], group["build"], group["sub"])
		for i in nodes.size():
			var node: Node3D = nodes[i]
			node.name = "%s_%d" % [str(key).replace(":", "_"), i]
			root.add_child(node)
		_part_nodes[str(key)] = {
			"nodes": nodes, "build": group["build"], "sub": group["sub"],
			"entries": group["entries"],
		}
	# 基准格 / 连接点标记：整表重算要扫所有零件的所有面（400 件时 ~45 ms！），
	# 这里只标脏，由 `_process()` 限流重建（拆零件时不会每拆一块卡一下）
	_markers_dirty = true
	_markers_due = 0


func _default_mode(part_id: String) -> int:
	var def: PartDef = _defs.get(part_id)
	return def.render_mode if def != null else PartDef.RenderMode.VOXEL


## 左上角的数值区：部件点数占比条 + 下方总重量 / 总血量（`totals()` 有缓存，每帧问也便宜）。
func _update_stats() -> void:
	if _stats_label == null or _pp_bar_text == null:
		return
	var totals := _grid.totals()
	var used := int(totals["pp"])
	var ratio := clampf(float(used) / float(BuildGrid.PP_LIMIT), 0.0, 1.0)
	_pp_fill.size = Vector2(maxf(0.0, (PP_BAR_SIZE.x - 4.0) * ratio), PP_BAR_SIZE.y - 4.0)
	if ratio < 0.9:
		_pp_fill.color = Color("4fd08a")
	elif ratio < 1.0:
		_pp_fill.color = Color("e8b44f")
	else:
		_pp_fill.color = Color("e05a5a")
	_pp_bar_text.text = "  部件点数 %d / %d pp" % [used, BuildGrid.PP_LIMIT]
	# 判定只在保存 / 去测试场时做（用户要求），所以这里可能显示"改了之后还没校验"
	var status := ""
	if not _robot_checked:
		status = "改动后未校验（保存 / 去测试场时自动校验）"
	elif _robot_ok:
		status = "核心已装、全部相连（可以进测试场）"
	else:
		status = _robot_reason
	_stats_label.text = "总重量 %.0f kg    总血量 %d\n核心：%s" % [
		float(totals["weight"]), int(totals["hp"]), status
	]


func _update_hud() -> void:
	if _hud == null:
		return
	_update_stats()
	var def := _current_def()
	var aim := "无目标"
	if def == null:
		aim = "物品栏这一格是空的：Tab 打开零件菜单选零件"
	elif not _candidate.is_empty():
		var where := "地面" if _candidate["kind"] == "floor" else "零件表面"
		var body_ok := bool(_candidate.get("valid", true))
		if not _mirror_on:
			aim = (
				"可建造 → %s" % where
				if body_ok
				else "放不下（红色虚影）：%s" % str(_candidate.get("reason", ""))
			)
		else:
			# 镜像模式：本体和镜像体各放各的 —— 谁违规就不放谁，另一边照放
			var mirror_ok := bool(_mirror_plan.get("place_mirror", false))
			if body_ok and mirror_ok:
				aim = "可建造 → %s（本体 + 镜像体）" % where
			elif body_ok and _mirror_plan.get("mirror", {}).is_empty():
				aim = "可建造 → %s（镜面对称，只放一个）" % where
			elif body_ok:
				aim = "可建造 → %s（只放本体：镜像位置%s）" % [
					where, _side_reason(_mirror_plan.get("mirror", {}))
				]
			elif mirror_ok:
				aim = "可建造 → 只放镜像体（本体%s）" % _side_reason(_candidate)
			else:
				aim = "放不下（%s）" % str(_mirror_plan.get("reason", ""))
	elif _mirror_on and not str(_mirror_plan.get("reason", "")).is_empty():
		# 镜像规划给了整体理由（两边都放不下之类）：没有虚影可画，但把原因说清楚。
		# 注意：镜像性不由代码判定（见 BuildGrid.mirror_fold_rotation），所以这里
		# 不会再出现"这个零件不支持镜像"那种理由。
		aim = str(_mirror_plan.get("reason", ""))
	elif not _hit.is_empty() and _hit.get("type", "none") == "part":
		if _hit.get("dir", Vector3i.ZERO) == Vector3i.ZERO:
			# 打到斜切台阶 / 零件内部面：没有可用的朝向，这里给不出候选
			aim = "这面不能建造（斜切面 / 内部面）"
		else:
			aim = "该面没有连接点（不能吸附到这里）"
	var lines := PackedStringArray()
	lines.append("建造模式 · 场地 64 x 64 x 64")
	lines.append("WASD 移动 · 空格升 / Shift 降 · 鼠标转向")
	lines.append("滚轮 / R 旋转部件（绕默认连接点，默认连接点始终在底部）")
	lines.append("Tab 零件菜单 · 1-0 选物品栏 · 左键建造 · 右键拆除")
	lines.append("中键点零件 = 收进物品栏（已有就切过去 / 有空位就放进去 / 全满顶掉当前格）")
	lines.append("方向键整体移动载具（+x 是车头）· < 下降 / > 上升")
	lines.append("调试标记：绿方块 = 基准格 · 小蓝球 = 能对接的连接点")
	if _com_visible:
		var com := _grid.center_of_mass(_defs)
		lines.append(
			"重心（O 关闭）本地 %.2f, %.2f, %.2f · 离地 %.2f 格 · 质量 %.0f kg"
			% [com.x, com.y, com.z, _com_height, float(_grid.totals()["weight"])]
		)
	else:
		lines.append("重心：O 键显示（穿透车体画出来，调驾驶手感用）")
	if _mirror_on:
		lines.append(
			"镜像建造：开 · 对称面 z = %.1f · 【/】挪半格 · M 关闭 · 拆除会连镜像一起拆"
			% BuildGrid.mirror_plane(_mirror_half)
		)
	else:
		lines.append("镜像建造：关（M 开启左右对称建造）")
	lines.append("ESC 关零件菜单 / 解锁鼠标（再按一次回主界面）")
	lines.append("")
	# 显示名字（车轮（2x2）这种），不显示内部 id —— 文件名是给数据用的
	lines.append(
		"当前部件：%s 号格 · %s"
		% [_slot_label(_loadout.selected), _short_name(def.id) if def != null else "（空）"]
	)
	lines.append("朝向档位：%d   已放置：%d" % [_roll, _grid.part_count()])
	lines.append("瞄准：%s" % aim)
	if not _notice.is_empty() and Time.get_ticks_msec() < _notice_until:
		lines.append("▸ %s" % _notice)
	var text := "\n".join(lines)
	if text == _hud_text:
		return  # 文字没变就别重排 UI（每帧都重排同样一段文字是白花的时间）
	_hud_text = text
	_hud.text = text

## 建造模式：放零件走**增量追加**（不再整表重建），零件多的时候才不会一顿一顿。
var _part_nodes := {}   # key -> {nodes: Array[MultiMeshInstance3D], build, sub}


func _part_key(entry: Dictionary) -> String:
	return "%s:%d" % [str(entry["part_id"]), _default_mode(str(entry["part_id"]))]


## 场地里**新增**了零件（`from_index` 之后的那几件）：只把这几件追加进已有的 MultiMesh，
## 不重建整张表（以前每放一块都把几百个实例重新塞一遍，零件一多就卡）。
func _append_parts(from_index: int) -> void:
	_grid_epoch += 1
	_robot_checked = false
	var root := get_node_or_null("PlacedParts")
	if root == null:
		_rebuild_parts()
		return
	for i in range(from_index, _grid.parts.size()):
		var entry: Dictionary = _grid.parts[i]
		var key := _part_key(entry)
		var transform: Transform3D = entry["transform"]
		if not _part_nodes.has(key):
			# 这一类零件还没画过：单独建一组（只有 1 个实例）
			var build := _library.build_default(str(entry["part_id"]))
			var sub := _library.build_sub(str(entry["part_id"]))
			var nodes := _make_group_nodes([transform], build, sub)
			for index in nodes.size():
				var node: Node3D = nodes[index]
				node.name = "%s_%d" % [key.replace(":", "_"), index]
				root.add_child(node)
			_part_nodes[key] = {
				"nodes": nodes, "build": build, "sub": sub, "entries": [entry],
			}
			continue
		_append_group_instance(_part_nodes[key], entry)
	_append_markers(from_index)


## 连接点 / 基准格标记也只**追加**新零件那一件（整表重算在零件多时很贵）。
func _append_markers(from_index: int) -> void:
	if _anchor_markers == null or _joint_markers == null:
		return
	for i in range(from_index, _grid.parts.size()):
		var entry: Dictionary = _grid.parts[i]
		_grow_marker(
			_anchor_markers, Vector3(entry.get("anchor", entry["origin"])) + Vector3(0.5, 0.5, 0.5)
		)
		var def: PartDef = _defs.get(str(entry["part_id"]))
		if def == null:
			continue
		var basis: Basis = entry["basis"]
		var transform: Transform3D = entry["transform"]
		for c in BuildGrid.cells_of(def, basis, entry["origin"]):
			for dir in VoxShapes.AXIS_DIRS:
				if not _grid.claims_face(def, basis, transform, c, dir):
					continue
				if _grid.face_is_internal(def, transform, c, dir):
					continue
				_grow_marker(
					_joint_markers,
					Vector3(c) + Vector3(0.5, 0.5, 0.5) + Vector3(dir) * 0.5
				)


func _grow_marker(node: MultiMeshInstance3D, at: Vector3) -> void:
	var multi: MultiMesh = node.multimesh
	if multi == null:
		return
	var needed := multi.visible_instance_count + 1
	# 改 `instance_count` 会重新分配缓冲：这里**成倍预留**，别每放一块就重分配一次
	if needed > multi.instance_count:
		multi.instance_count = maxi(needed, maxi(64, multi.instance_count * 2))
	multi.set_instance_transform(needed - 1, Transform3D(Basis(), at))
	multi.visible_instance_count = needed

## 场地里**删掉**了零件：只重建**受影响的那几组**（不是整张表）。
##
## ⚠️ 为什么不用"把末尾实例搬过来缩 1"那种做法：MultiMesh 的实例数据在
## `instance_count` 变化时会**被清空**，swap/缩容很容易和 `entries` 错位 ——
## 一旦错位就会出"幽灵零件"：格子里还有、外观却没了（或者反过来）。
## 按组重建是 O(这一组的零件数)，400 块同类零件也只要 ~0.3 ms，换来的是一定对得上。
func _remove_parts(entries: Array) -> void:
	_grid_epoch += 1
	_robot_checked = false
	# 连接点/基准格标记：整表重算交给 `_process()` 限流做（拆一块不会卡）
	_markers_dirty = true
	var root := get_node_or_null("PlacedParts")
	if root == null:
		return
	var affected := {}
	for entry in entries:
		affected[_part_key(entry)] = true
	for key in affected.keys():
		_rebuild_group(NodePath(str(key)), root)


## 重建**一组**零件（同一 part_id + 渲染路线）。
## ⚠️ 拆零件时**就地改**已有的 MultiMesh（只重写变换 + 缩 `visible_instance_count`），
## **不再**销毁节点重造：`_make_group_nodes()` 会新建 MultiMesh 并把 `instance_count`
## 设成容量（等于重新分配 GPU 缓冲），400 件的车里拆一块最常见的方块就要重分配一次。
## Robocraft 拆掉方块也只是把网格里那一块的顶点关掉，不会重造网格。
func _rebuild_group(key_path: NodePath, root: Node3D) -> void:
	var key := str(key_path)
	var transforms := []
	var entries := []
	for entry: Dictionary in _grid.parts:
		if _part_key(entry) != key:
			continue
		transforms.append(entry["transform"])
		entries.append(entry)
	var record: Dictionary = _part_nodes.get(key, {})
	var nodes: Array = record.get("nodes", [])
	if entries.is_empty():
		# 这一组全没了：回收节点（只剩 0 个还占着 MultiMesh 节点会漏；同类零件再加回来
		# 会走下面的新建路径）。只在"拆掉某类最后一件"时发生，常见情况走就地更新。
		for node in nodes:
			if is_instance_valid(node):
				root.remove_child(node)
				node.queue_free()
		_part_nodes.erase(key)
		return
	if nodes.is_empty():
		# 这类零件第一次出现（或节点被清掉了）：建节点，含容量预留
		var part_id := str((entries[0] as Dictionary)["part_id"])
		var build: Variant = _library.build_default(part_id)
		var sub: Variant = _library.build_sub(part_id)
		nodes = _make_group_nodes(transforms, build, sub)
		for index in nodes.size():
			var created: Node3D = nodes[index]
			created.name = "%s_%d" % [key.replace(":", "_"), index]
			root.add_child(created)
		_part_nodes[key] = {"nodes": nodes, "build": build, "sub": sub, "entries": entries}
		return
	# 已有节点：就地重写实例。只有"变多了"才扩容（扩容会清空缓冲，之后必须重写全部）
	var needed := transforms.size()
	for node in nodes:
		if not is_instance_valid(node) or not (node is MultiMeshInstance3D):
			continue
		var multi: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if multi == null:
			continue
		if needed > multi.instance_count:
			multi.instance_count = needed
		for i in needed:
			multi.set_instance_transform(i, transforms[i])
		multi.visible_instance_count = needed
	record["entries"] = entries
	_part_nodes[key] = record


## 用给定变换造一组 MultiMesh 节点，并**预留容量**。
## ⚠️ Godot 里改 `MultiMesh.instance_count` 会**清空所有实例数据**，所以顺序必须是：
## 先定容量 → 再写变换 → 最后设 `visible_instance_count`。增量放/拆只用
## `visible_instance_count` 加减，不再动 `instance_count`（动一次就把已画的全清掉 ——
## 这正是"幽灵零件"的成因：格子有零件、但视觉全被清到原点/消失）。
func _make_group_nodes(transforms: Array, build: Dictionary, sub: Dictionary) -> Array:
	var nodes := PartLibrary.make_part_nodes(transforms, build, sub)
	for node in nodes:
		var multi: MultiMesh = (node as MultiMeshInstance3D).multimesh
		var capacity := maxi(64, transforms.size())
		multi.instance_count = capacity
		for i in transforms.size():
			multi.set_instance_transform(i, transforms[i])
		multi.visible_instance_count = transforms.size()
	return nodes


## 往一组里追加一件：容量够就直接写（只加 visible_instance_count）；不够才扩容并重写全部。
func _append_group_instance(record: Dictionary, entry: Dictionary) -> void:
	var entries: Array = record["entries"]
	var needed := entries.size() + 1
	for node in (record["nodes"] as Array):
		var multi: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if multi.instance_count < needed:
			var capacity := maxi(64, multi.instance_count * 2)
			while capacity < needed:
				capacity *= 2
			multi.instance_count = capacity     # 会清空：下面把已有变换重写一遍
			for i in entries.size():
				multi.set_instance_transform(i, (entries[i] as Dictionary)["transform"])
			multi.visible_instance_count = entries.size()
		multi.set_instance_transform(entries.size(), entry["transform"])
		multi.visible_instance_count = needed
	entries.append(entry)

