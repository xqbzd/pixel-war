@tool
class_name VehicleViewer
extends Node3D

## 载具预览器：视角自动环绕 + 左键拖拽环绕 + 滚轮缩放，相机按载具包围盒自动取景。
##
## 放进 SubViewport 就是主界面的主体；将来直接放进载具编辑器的 3D 场景也能复用。
## 自动转的是**视角**而不是载具 —— 建造场地的地板和载具都停在原地，只让相机绕一圈。

const AUTO_ORBIT_DEG_PER_SEC := 16.0
const FIT_MARGIN := 1.32

## 建造场地：64 x 64 x 64 cube（地板固定在 y = 0，载具贴地站在上面）
const BUILD_AREA_CUBES := Vector3i(64, 64, 64)
## 地板贴图：一个 cube 格子 16 x 16 texel（与部件自身的体素密度一致，1 cube = 16）
const FLOOR_TEXELS_PER_CUBE := 16
const FLOOR_FILL := Color("585c66")
const FLOOR_LINE := Color("7488a8")

## 车库光照：全向柔光（建造界面和载具预览共用这套）。
##
## 主光用天空（ProceduralSky + Sky IBL）：所有**水平朝向**的面收到的辐照度几乎相同，
## 所以棱柱的台阶不会出现明暗条纹；上下仍留一点梯度（天空亮、地面暗），形体不至于完全平掉。
## 方向光只留很弱的一盏，用途是给地板留一圈**软**接触阴影（靠 light_angular_distance 拉开半影），
## 不靠它塑形 —— 所以 energy 很低，也不要给它加回去。
const SUN_ENERGY := 0.25
const SUN_ANGULAR_DISTANCE_DEG := 6.0
## 天空刻意接近中性灰（只留一点点冷调）：它是全向光源，太蓝会把地板和部件一起染色，
## 反而埋掉"灰底 + 灰蓝格线"的区分度。想更冷/更暖就调这四个颜色。
const SKY_TOP := Color("aeb3ba")
const SKY_HORIZON := Color("8f9399")
const SKY_GROUND_HORIZON := Color("5d6066")
const SKY_GROUND_BOTTOM := Color("35373c")

## 运行时默认自动旋转；编辑器里默认不转（免得一边改别的东西一边晃）。
var auto_rotate := true
var rotate_in_editor := false

var _scene_ready := false
var _library: PartLibrary
var _vehicle: VehicleDef
var _pivot: Node3D
var _vehicle_root: Node3D
var _floor: MeshInstance3D
var _camera: Camera3D
var _camera_yaw := -34.0
var _camera_pitch := 20.0
var _camera_dist := 10.0
var _target := Vector3.ZERO
var _dragging := false


func _ready() -> void:
	ensure_scene()


func ensure_scene() -> void:
	if _scene_ready:
		return
	_scene_ready = true

	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.environment = make_garage_environment()
	add_child(world)

	add_child(make_garage_sun())

	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.current = true
	_camera.fov = 40.0
	# 相机是每帧手动摆的：不关插值会在每帧刷一条
	# "[Physics interpolation] Interpolated Camera3D triggered from outside physics process" 警告
	# （插值开着以后日志会被刷爆 —— 快照式预览相机不需要插值）。
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_camera)

	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	add_child(_pivot)

	_build_floor()
	# 场地正前方的方向箭头（+x 是车头方向），防止在场地里迷路
	add_child(make_forward_arrow())
	_apply_camera()


static func make_garage_sky() -> Sky:
	var material := ProceduralSkyMaterial.new()
	material.sky_top_color = SKY_TOP
	material.sky_horizon_color = SKY_HORIZON
	material.ground_horizon_color = SKY_GROUND_HORIZON
	material.ground_bottom_color = SKY_GROUND_BOTTOM
	material.sky_curve = 0.15
	material.ground_curve = 0.05
	var sky := Sky.new()
	sky.sky_material = material
	# 柔光不需要高分辨率辐照度贴图，64 足够且只渲染一次
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	return sky


static func make_garage_environment() -> Environment:
	var environment := Environment.new()
	# 背景仍然是深色（UI 要干净），但环境光从天空来 —— 这就是"全向柔光"的来源
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.055, 0.065, 0.085)
	environment.sky = make_garage_sky()
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 1.0
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	return environment


static func make_garage_sun() -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-58.0, -40.0, 0.0)
	sun.light_energy = SUN_ENERGY
	sun.light_angular_distance = SUN_ANGULAR_DISTANCE_DEG
	sun.shadow_enabled = true
	sun.shadow_blur = 2.0
	# 别往天空里画太阳盘：否则 IBL 里出现热点，光又变"有方向"了
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	return sun


## 建造场地地板：一张 64 x 64 cube 的贴图铺满（1 个 draw call），格子边框是灰蓝色，方便对位。
func _build_floor() -> void:
	_floor = MeshInstance3D.new()
	_floor.name = "BuildFloor"
	var plane := PlaneMesh.new()
	plane.size = Vector2(float(BUILD_AREA_CUBES.x), float(BUILD_AREA_CUBES.z))
	_floor.mesh = plane
	_floor.material_override = make_floor_material()
	# 下沉 1/50 cube：避免和载具底面的体素面片共面（俯仰角很大时可能闪）
	_floor.position.y = -0.02
	add_child(_floor)


## area 是地板覆盖的 cube 尺寸；传 Vector2.ZERO（默认）就用建造场地的 64 x 64。
static func make_floor_material(area := Vector2.ZERO) -> StandardMaterial3D:
	var span := area
	if span == Vector2.ZERO:
		span = Vector2(float(BUILD_AREA_CUBES.x), float(BUILD_AREA_CUBES.z))
	var material := StandardMaterial3D.new()
	material.albedo_texture = make_floor_texture()
	material.texture_repeat = true
	# 近处保持像素锐利，远处靠 mipmap 淡掉，避免格线闪烁
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	# UV 0..1 -> 0..area，正好一个 cube 一格
	material.uv1_scale = Vector3(span.x, span.y, 1.0)
	material.roughness = 1.0
	material.metallic = 0.0
	material.metallic_specular = 0.15
	return material


## 一个 cube 格子的小瓦片：灰底 + 上/左各 1 texel 灰蓝边框。
##
## 用「小瓦片 + 重复」而不是烘一张 1024x1024 的整场贴图：1 KB 对 4 MB，
## 而且场地改成 128 / 256 也不用换贴图。将来要按格子做独立标记（区域、禁放区）时，
## 再换成烘焙整场贴图即可，材质接口不变。
static func make_floor_texture() -> ImageTexture:
	var size := FLOOR_TEXELS_PER_CUBE
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	image.fill(FLOOR_FILL)
	for i in range(size):
		image.set_pixel(i, 0, FLOOR_LINE)
		image.set_pixel(0, i, FLOOR_LINE)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


## 场地正前方的方向箭头（+x 就是车头方向）。
##
## 用 1 cube 的方块拼成像素风箭头，琥珀色 + 一点自发光，避免玩家在场地里迷路。
## 摆放位置是场地前沿（x = 25 ~ 31），朝向 +x。
static func make_forward_arrow() -> Node3D:
	var root := Node3D.new()
	root.name = "ForwardArrow"
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("d7b06b")
	material.emission_enabled = true
	material.emission = Color("d7b06b")
	material.emission_energy_multiplier = 0.3
	material.roughness = 0.9
	material.metallic = 0.0
	var box := BoxMesh.new()
	box.size = Vector3(0.9, 0.12, 0.9)
	var cells := []
	for x in range(4):
		cells.append(Vector2i(x, 0))  # 箭杆
	for i in range(3):
		for z in range(-(2 - i), 3 - i):
			cells.append(Vector2i(4 + i, z))  # 三角箭头
	for c in cells:
		var piece := MeshInstance3D.new()
		piece.mesh = box
		piece.material_override = material
		piece.position = Vector3(float(c.x), 0.06, float(c.y))
		root.add_child(piece)
	root.position = Vector3(25.0, 0.0, 0.0)
	return root


## 显示一辆载具：清掉旧的、按包围盒重新取景。返回 instantiate() 的统计信息。
func show_vehicle(vehicle: VehicleDef, library: PartLibrary) -> Dictionary:
	ensure_scene()
	clear_vehicle()
	_library = library
	_vehicle = vehicle
	if vehicle == null:
		return {}
	var result := vehicle.instantiate(library)
	_vehicle_root = result["node"]
	# 载具贴着固定的地板：x/z 居中，y 让**真实车底**落在 y = 0。
	# ⚠️ 必须用 `actual_bounds()`（网格包围盒，含轮体那种挂在盒子外面的附属子模型）——
	# 用 `bounds()`（声明的 cubes 盒子）算车底，半个轮胎会插进地里（用户报的）。
	var box := vehicle.actual_bounds(library)
	var centre := box.get_center()
	_vehicle_root.position = Vector3(-centre.x, -box.position.y, -centre.z)
	_pivot.add_child(_vehicle_root)
	_fit_camera(box)
	return result


func clear_vehicle() -> void:
	if _vehicle_root != null and is_instance_valid(_vehicle_root):
		_pivot.remove_child(_vehicle_root)
		_vehicle_root.queue_free()
	_vehicle_root = null
	_vehicle = null


func current_vehicle_id() -> String:
	return _vehicle.id if _vehicle != null else ""


## 当前视角方位角（度）。自动化用它确认"视角在绕"。
func camera_yaw_degrees() -> float:
	return _camera_yaw


func camera_target() -> Vector3:
	return _target


func camera_distance() -> float:
	return _camera_dist


func _fit_camera(box: AABB) -> void:
	# 看载具的中心；载具已经贴地，所以中心在它自身高度的一半处
	_target = Vector3(0.0, box.size.y * 0.5, 0.0)
	var radius := maxf(box.size.length() * 0.5, 0.75)
	_camera_dist = radius / tan(deg_to_rad(_camera.fov) * 0.5) * FIT_MARGIN
	_apply_camera()


func _apply_camera() -> void:
	if _camera == null:
		return
	var yaw := deg_to_rad(_camera_yaw)
	var pitch := deg_to_rad(_camera_pitch)
	var dir := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	_camera.position = _target + dir * _camera_dist
	_camera.look_at(_target, Vector3.UP)


func _process(delta: float) -> void:
	if not auto_rotate or _camera == null:
		return
	if Engine.is_editor_hint() and not rotate_in_editor:
		return
	# 只转视角：地板和载具都不动
	_camera_yaw = fmod(_camera_yaw + AUTO_ORBIT_DEG_PER_SEC * delta, 360.0)
	_apply_camera()


## 事件会由外层 SubViewportContainer 转发进 SubViewport，所以鼠标落在预览区域时才生效。
func _input(event: InputEvent) -> void:
	if _camera == null:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera_dist = maxf(1.0, _camera_dist * 0.9)
			_apply_camera()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera_dist = minf(400.0, _camera_dist * 1.1)
			_apply_camera()
	elif event is InputEventMouseMotion and _dragging:
		_camera_yaw -= event.relative.x * 0.35
		_camera_pitch = clampf(_camera_pitch + event.relative.y * 0.25, -80.0, 80.0)
		_apply_camera()
