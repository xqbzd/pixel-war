@tool
class_name BattleArena
extends Node3D

## 对战模式场地：**500 m × 500 m** 的平缓起伏地面 + 掩体。
##
## 单位：内部一律用**格**（1 格 = `PartDef.CUBE_METERS` = 0.5 米）。500 米 = 1000 格。
##
## 为什么是程序化地形而不是直接铺模型：
##   * 需求是"起伏不超过 20°"——**生成时就能夹住坡度**（`_clamp_slopes()`），拿现成模型
##     反而没法保证；
##   * 1 km 见方要铺满地面砖得几万块，只做地形面 + 掩体是 5000 个三角形，碰撞也便宜；
##   * 素材用项目里已有的 Kenney Nature Kit（CC0）：岩石 / 崖壁当掩体，树和灌木只做装饰。
##
## 对外只暴露三样东西给对战模式：`build()`、`ground_y()`、`spawn_transform()`。

## 场地边长（米）：**500 米**（2026-10-18 用户要求从 1000 缩到一半，"1 公里太大"）。
## 内部 1 格 = 0.5 米，所以边长 1000 格；地形 50 × 50 格 → 每格 10 米。
const SIZE_METERS := 500.0
## 地形网格：每边几个格子。50 × 50 → 每格 10 米，5000 个三角形。
const CELLS := 50
## 起伏幅度的量级（米）：四层正弦叠加，实测落差约 18.5 米、最陡 6.6°，远低于 20° 上限。
const HEIGHT_AMPLITUDE_M := 18.5
## **硬性坡度上限**（度）：生成完把相邻格高差夹到 tan(20°) × 格距 以内。
const MAX_SLOPE_DEG := 20.0
## 掩体：分成几堆、一共多少个、每堆半径多大（米）
const COVER_CLUSTERS := 12
const COVER_COUNT := 120
const COVER_CLUSTER_RADIUS_M := 55.0
## 装饰（树 / 灌木）数量：想改场景里的树多不多，改这两个数再重新烘焙
## （也可以直接在 `scenes/battle_arena.tscn` 的 `Decor` 里删/加节点 —— 运行时全部常驻，不按距离加载）。
const TREE_COUNT := 130
const BUSH_COUNT := 170
## 出生区周围多少米内不放**掩体**（免得一出生就卡在石头里）。
## 装饰（树/灌木）不挡车，可以长到出生点旁边 —— 所以它们用另一套"只避开地图边缘"的取点。
const SPAWN_CLEAR_RADIUS_M := 60.0
## 固定的随机种子：同一张图每次生成都一模一样（测试和联机复现都靠它）
const SEED := 20261018
## 素材包
const KIT_DIR := "res://assets/arena/nature_kit"
## ── 手动布局 ──────────────────────────────────────────────────────────────
## 这个文件存在且有内容时，**掩体和出生点完全按文件摆**（不再自动撒石头）。
## 格式（每行一条，`#` 开头是注释）：
##   spawn <队伍 0/1> <x 米> <z 米> <朝向 度>
##   cover <kit 里的名字> <x 米> <z 米> <朝向 度> <大小倍数>
## 坐标原点 = 场地中心；x 向右（东）、z 向下（南），范围 ±500 米。
## 大小 1.0 = 默认块头（约 8 米高的岩石），1.5 = 1.5 倍大。
const LAYOUT_PATH := "res://data/arena/battle_layout.txt"
## "大小 1.0" 对应 kit 的 16 格（= 8 米）
const LAYOUT_UNIT := 16.0
## 掩体往地里埋多少格（按大小倍数缩放）：石头看着像长在地里，不是摆在地上的积木
const COVER_SINK_CUBES := 1.5

## 掩体种类：名字 → 放大倍数（1 个 kit 单位 = 多少格）。岩石给的是"半埋进地里"的块头。
const COVER_KINDS := [
	{"name": "cliff_block_rock", "size": 14.0, "weight": 3},
	{"name": "cliff_large_rock", "size": 17.0, "weight": 2},
	{"name": "rock_largeA", "size": 16.0, "weight": 2},
	{"name": "rock_largeC", "size": 16.0, "weight": 2},
	{"name": "rock_tallA", "size": 13.0, "weight": 3},
	{"name": "rock_tallE", "size": 14.0, "weight": 1},
	{"name": "cliff_top_rock", "size": 18.0, "weight": 1},
]
const TREE_KINDS := ["tree_pineTallA", "tree_default", "tree_oak", "tree_pineDefaultA"]
const BUSH_KINDS := ["plant_bush", "plant_bushLarge", "grass_large"]

## 场地根（地面 + 掩体 + 墙都挂这下面）
var _ground: MeshInstance3D
var _body: StaticBody3D
var _heights := PackedFloat32Array()   # (CELLS+1)² 个顶点的高度（格）
var _rng := RandomNumberGenerator.new()
var _kits := {}                        # 放大倍数 -> ArenaKit
var cover_count := 0
var tree_count := 0
## 掩体位置（米，相对场地中心）：小地图画灰点用。
var cover_points: Array = []
## 已摆好的掩体（[名字, x 米, z 米, 朝向 度, 大小倍数]）—— 自动摆放时会记下来，
## 导出成 `data/arena/battle_layout.txt` 之后就能手动改。
var cover_layout: Array = []
## 已摆好的掩体（[模型名, Transform3D]）—— 一键生成"可编辑场景"（tools/bake_arena_scene.gd）用
var cover_placed: Array = []
## 已摆好的装饰（[模型名, Transform3D]），同上
var decor_layout: Array = []
## 掩体碰撞的三角形数（日志/调试用）：现在碰撞是**和外观一致**的 trimesh
var cover_collision_triangles := 0
## 手动布局（`data/arena/battle_layout.txt` 读出来的东西）：
##   spawns: [[队伍, x 米, z 米, 朝向 度], ...]
##   covers: [[名字, x 米, z 米, 朝向 度, 大小倍数], ...]
var layout := {"spawns": [], "covers": []}


## 造整块场地。重复调用只建一次。
## `layout_override` 只给测试用（直接塞一份布局，不用去写 `res://` 文件）；
## `force_procedural` 只给导出工具用（无视布局文件、强制走自动摆放）。
func build(layout_override: Dictionary = {}, force_procedural := false) -> void:
	if _ground != null:
		return
	if force_procedural:
		layout = {}
	else:
		layout = layout_override if not layout_override.is_empty() else _load_layout()
	_build_heights()
	_build_ground()
	_build_walls()
	# 场景里手摆的优先（`Cover` / `Decor` 有子节点就用它们）；没摆才自动生成
	if not _build_props_from_scene("Cover", true):
		_build_cover()
	if not _build_props_from_scene("Decor", false):
		_build_decor()
	print(
		"[对战场地] %.0f×%.0f 米，地形 %d 格（每格 %.0f 米，最大坡度 %.1f°），掩体 %d 个 / 碰撞 %d 三角%s"
		% [
			SIZE_METERS, SIZE_METERS, CELLS, SIZE_METERS / float(CELLS), MAX_SLOPE_DEG,
			cover_count, cover_collision_triangles,
			"（手动布局 %d 个）" % (layout.get("covers", []) as Array).size()
			if not (layout.get("covers", []) as Array).is_empty() else "（自动摆放）",
		]
	)


## 编辑器里只铺一张**地面预览**（不建碰撞、不摆东西），方便你对着地面拖石头。
## 预览节点 `owner = null`，所以保存场景时不会被写进 .tscn。
func _ready() -> void:
	if Engine.is_editor_hint():
		_build_editor_preview()
		return
	build()


## 地形高度（**格**）：x / z 是世界坐标（格），返回地面 y（格）。
## 网格点之间按双线性插值 —— 出生点、掩体摆放都用它，保证和碰撞面贴合。
func ground_y(x: float, z: float) -> float:
	var half := SIZE_METERS / PartDef.CUBE_METERS * 0.5
	var u := clampf((x + half) / (half * 2.0), 0.0, 1.0) * float(CELLS)
	var v := clampf((z + half) / (half * 2.0), 0.0, 1.0) * float(CELLS)
	var ix := clampi(int(floor(u)), 0, CELLS - 1)
	var iz := clampi(int(floor(v)), 0, CELLS - 1)
	var fx := u - float(ix)
	var fz := v - float(iz)
	var h00 := _height(ix, iz)
	var h10 := _height(ix + 1, iz)
	var h01 := _height(ix, iz + 1)
	var h11 := _height(ix + 1, iz + 1)
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)


## 队伍 `team` 的第 `index` 个出生点：手动布局里有就用它，没有就自动列阵
## （两队沿 ±x 排开、相隔约 220 米、车头朝对面）。
## 返回的 y 是**地面**高度；调用方自己加上车高再抬高一点扔下去。
func spawn_transform(team: int, index: int, team_size: int) -> Transform3D:
	# ① 场景里的 Marker3D（编辑器里拖的）
	var marker := _marker_spawn(team, index)
	if marker.size() == 3:
		var mx := float(marker[0]) / PartDef.CUBE_METERS
		var mz := float(marker[1]) / PartDef.CUBE_METERS
		var myaw := deg_to_rad(float(marker[2]))
		return Transform3D(Basis(Vector3.UP, myaw), Vector3(mx, ground_y(mx, mz), mz))
	# ② 布局文件里的 spawn 行
	var custom := _layout_spawn(team, index)
	if custom.size() == 4:
		var x_m := float(custom[1])
		var z_m := float(custom[2])
		var x := x_m / PartDef.CUBE_METERS
		var z := z_m / PartDef.CUBE_METERS
		var yaw := deg_to_rad(float(custom[3]))
		return Transform3D(Basis(Vector3.UP, yaw), Vector3(x, ground_y(x, z), z))
	var side := -1.0 if team == 0 else 1.0
	var x_auto_m := side * SIZE_METERS * 0.22
	var spread := 34.0
	var z_auto_m := (float(index) - (float(team_size) - 1.0) * 0.5) * spread
	var x_auto := x_auto_m / PartDef.CUBE_METERS
	var z_auto := z_auto_m / PartDef.CUBE_METERS
	var yaw_auto := 0.0 if team == 0 else PI          # 车头朝 +x / -x
	var t := Transform3D(Basis(Vector3.UP, yaw_auto), Vector3(x_auto, ground_y(x_auto, z_auto), z_auto))
	return t


## 手动布局里这台队伍的第 `index` 个出生点（没有就返回空数组）。
func _layout_spawn(team: int, index: int) -> Array:
	var found := 0
	for entry in layout.get("spawns", []):
		if int(entry[0]) != team:
			continue
		if found == index:
			return entry
		found += 1
	return []


## 出生点（米）—— HUD / 测试用。
func team_spawn_meters(team: int, index: int, team_size: int) -> Vector3:
	var t := spawn_transform(team, index, team_size)
	return t.origin * PartDef.CUBE_METERS


# ──────────────────────────────────────────────────────────── 地形

## 平缓起伏：四层正弦叠加 —— 两个 1~2 公里的大起伏 + 两个 200~300 米的小起伏，
## 实测落差 18.5 米、最陡 6.6°（远低于 20° 上限），开起来有起伏感但不至于翻车。
## 用固定函数而不是噪声纹理：同一张图每次开局都一样，测试也能直接断言坡度。
static func height_m(x: float, z: float) -> float:
	var h := 6.0 * sin(x * 0.0055 + 1.9) * sin(z * 0.0047 - 0.8)     # 约 1.1 公里波长
	h += 2.5 * sin(x * 0.0032 + 0.7) * cos(z * 0.0027 - 0.4)          # 约 2 公里波长
	h += 2.2 * sin((x + z) * 0.020 + 1.3)                             # 约 310 米波长
	h += 1.2 * sin((x - z) * 0.033 - 0.6)                             # 约 190 米波长
	return h


func _height(ix: int, iz: int) -> float:
	return _heights[iz * (CELLS + 1) + ix]


func _build_heights() -> void:
	_heights.resize((CELLS + 1) * (CELLS + 1))
	var step_m := SIZE_METERS / float(CELLS)
	for iz in CELLS + 1:
		for ix in CELLS + 1:
			var x := (float(ix) / float(CELLS) - 0.5) * SIZE_METERS
			var z := (float(iz) / float(CELLS) - 0.5) * SIZE_METERS
			_heights[iz * (CELLS + 1) + ix] = height_m(x, z) / PartDef.CUBE_METERS
	# ⚠️ 坡度上限是**硬需求**（用户："起伏不要太大、最好别超过 20 度"）。
	# 生成完把相邻格高差夹到 tan(20°) × 格距以内；夹三轮，避免一处的修改又让邻居超限。
	var max_step := tan(deg_to_rad(MAX_SLOPE_DEG)) * step_m / PartDef.CUBE_METERS
	for _pass in 3:
		for iz in CELLS + 1:
			for ix in CELLS:
				_clamp_pair(iz * (CELLS + 1) + ix, iz * (CELLS + 1) + ix + 1, max_step)
		for ix in CELLS + 1:
			for iz in CELLS:
				_clamp_pair(iz * (CELLS + 1) + ix, (iz + 1) * (CELLS + 1) + ix, max_step)


## 相邻两格高差超过 `max_step` 时，两边各退一步（保持平均高度不变）。
func _clamp_pair(a: int, b: int, max_step: float) -> void:
	var delta := _heights[b] - _heights[a]
	if absf(delta) <= max_step:
		return
	var excess := (absf(delta) - max_step) * 0.5 * signf(delta)
	_heights[a] += excess
	_heights[b] -= excess


func _build_ground() -> void:
	var mesh := make_ground_mesh()
	_ground = MeshInstance3D.new()
	_ground.name = "Ground"
	_ground.mesh = mesh
	_ground.material_override = _ground_material()
	_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ground)
	# 碰撞：直接拿这张网格做 trimesh（5000 三角，建一次）
	_body = StaticBody3D.new()
	_body.name = "GroundBody"
	_body.collision_layer = 1
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	_body.add_child(shape)
	add_child(_body)


## 地面网格（顶点色 + 法线）：运行时和编辑器预览共用同一份。
func make_ground_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var n := CELLS + 1
	var cell := SIZE_METERS / PartDef.CUBE_METERS / float(CELLS)
	var half := SIZE_METERS / PartDef.CUBE_METERS * 0.5
	verts.resize(n * n)
	normals.resize(n * n)
	colors.resize(n * n)
	for iz in n:
		for ix in n:
			var x := -half + float(ix) * cell
			var z := -half + float(iz) * cell
			var y := _height(ix, iz)
			verts[iz * n + ix] = Vector3(x, y, z)
			# 法线用中心差分（边缘退化成单侧差分）
			var hx0 := _height(maxi(0, ix - 1), iz)
			var hx1 := _height(mini(CELLS, ix + 1), iz)
			var hz0 := _height(ix, maxi(0, iz - 1))
			var hz1 := _height(ix, mini(CELLS, iz + 1))
			var dx := (hx1 - hx0) / (2.0 * cell)
			var dz := (hz1 - hz0) / (2.0 * cell)
			normals[iz * n + ix] = Vector3(-dx, 1.0, -dz).normalized()
			colors[iz * n + ix] = terrain_colour(x, z, y, Vector2(dx, dz).length())
	for iz in CELLS:
		for ix in CELLS:
			var a := iz * n + ix
			var b := (iz + 1) * n + ix
			var c := (iz + 1) * n + ix + 1
			var d := iz * n + ix + 1
			# 和 VoxMesher 的顶面同一套环绕（正面朝上，Godot 是顺时针正面）
			indices.append_array([a, c, b, a, d, c])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 地面材质（顶点色当 albedo）：地面和"编辑器里的预览"共用，保证看起来一样。
func _ground_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.95
	material.metallic = 0.0
	return material


## 编辑器预览：只有一张地面网格，没有碰撞、没有掩体（`owner = null` 不存盘）。
func _build_editor_preview() -> void:
	var old := get_node_or_null("TerrainPreview")
	if old != null:
		old.queue_free()
	_build_heights()
	var preview := MeshInstance3D.new()
	preview.name = "TerrainPreview"
	preview.mesh = make_ground_mesh()
	preview.material_override = _ground_material()
	preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(preview)
	preview.owner = null   # 只是预览：保存 .tscn 时不写进去


## 地面颜色：低处深绿、高处偏黄；陡一点的地方掺灰（岩石感）；再加大块深浅斑块。
## **小地图的缩略图也用这一套**（`map_image()`），所以图和地面看起来是同一片地。
static func terrain_colour(x: float, z: float, y: float, slope: float) -> Color:
	var t := clampf(0.5 + y / 22.0, 0.0, 1.0)
	var green := Color(0.16, 0.28, 0.10).lerp(Color(0.31, 0.40, 0.16), t)
	# 三层不同尺度的色斑：1 公里级、300 米级、80 米级 —— 远看有丘陵、近看也不是一块纯色
	var patch := (
		1.0
		+ 0.16 * sin(x * 0.011 + z * 0.007)
		+ 0.10 * sin(x * 0.027 - z * 0.019)
		+ 0.07 * sin(x * 0.082 + 0.4) * cos(z * 0.071)
	)
	green = Color(green.r * patch, green.g * patch, green.b * patch)
	var rock := clampf((slope - 0.10) / 0.22, 0.0, 1.0)
	return green.lerp(Color(0.36, 0.34, 0.30), rock * 0.7)


## 小地图用的缩略图：俯视的地形颜色 + 掩体灰点（掩体是静态的，**烘进图里**，
## 小地图每帧就不用再画 120 个圆点了 —— 少几百个 draw command）。
func map_image(pixels := 128) -> Image:
	var image := Image.create(pixels, pixels, false, Image.FORMAT_RGB8)
	var half_m := SIZE_METERS * 0.5
	var step_m := SIZE_METERS / float(pixels)
	# 先把高度采样一遍（每像素只算一次 height_m），再用邻居差分做"西北光照"
	var heights := PackedFloat32Array()
	heights.resize(pixels * pixels)
	for py in pixels:
		for px in pixels:
			var x_m := (float(px) + 0.5) * step_m - half_m
			var z_m := (float(py) + 0.5) * step_m - half_m
			heights[py * pixels + px] = height_m(x_m, z_m)
	for py in pixels:
		for px in pixels:
			var x1 := maxi(0, px - 1)
			var x2 := mini(pixels - 1, px + 1)
			var z1 := maxi(0, py - 1)
			var z2 := mini(pixels - 1, py + 1)
			var dx := (heights[py * pixels + x2] - heights[py * pixels + x1]) / maxf(
				0.001, float(x2 - x1) * step_m
			)
			var dz := (heights[z2 * pixels + px] - heights[z1 * pixels + px]) / maxf(
				0.001, float(z2 - z1) * step_m
			)
			image.set_pixel(px, py, map_colour(heights[py * pixels + px], dx, dz))
	# 掩体：3×3 的暖灰点（静态，直接画进缩略图）—— 比 2×2 更好认，也不至于糊成一片
	var cover_colour := Color(0.34, 0.29, 0.22)
	for point in cover_points:
		var px := int(clampf((point.x / SIZE_METERS + 0.5) * float(pixels), 0.0, float(pixels - 3)))
		var py := int(clampf((point.y / SIZE_METERS + 0.5) * float(pixels), 0.0, float(pixels - 3)))
		for dy in 3:
			for dx in 3:
				image.set_pixel(px + dx, py + dy, cover_colour)
	return image


## 小地图配色（纯函数）：**亮色**地图 = 高度分色 + 西北方向的"光照"（hillshade）。
## 为什么不直接用地面的 albedo（`terrain_colour`）：那套颜色是给 3D 打光用的，
## 贴到小地图上（没有太阳）会黑成一片；而且它那几层高频色斑缩到 190 像素就成了"阴影网格"。
static func map_colour(y_m: float, dx: float, dz: float) -> Color:
	# 低处草绿、高处浅黄褐
	var t := clampf((y_m + 8.0) / 20.0, 0.0, 1.0)
	var base := Color(0.40, 0.60, 0.33).lerp(Color(0.76, 0.72, 0.50), t)
	# 光从西北（-x, -z）来：朝西北的坡亮、朝东南的坡暗 —— 一眼能看出起伏
	var light := clampf(0.88 + (dx + dz) * 2.5, 0.60, 1.15)
	return Color(base.r * light, base.g * light, base.b * light)


## 户外天空 + 远景雾：对战场地是开阔地，用深色车库背景会像在真空里。
static func make_outdoor_environment() -> Environment:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var material := ProceduralSkyMaterial.new()
	material.sky_top_color = Color(0.22, 0.42, 0.72)
	material.sky_horizon_color = Color(0.70, 0.79, 0.88)
	material.ground_bottom_color = Color(0.16, 0.19, 0.17)
	material.ground_horizon_color = Color(0.52, 0.58, 0.50)
	material.sun_angle_max = 22.0
	sky.sky_material = material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 1.1
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# 500 米场地：给一点远景雾，远处不刺眼、也能看出纵深（1000 格 ≈ 500 米处约 30%）
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.66, 0.73, 0.80)
	environment.fog_density = 0.00035
	environment.fog_sky_affect = 0.35
	return environment


## 户外太阳：亮、偏暖，默认不投影（阴影是这套里最贵的一项，见 `SHADOWS`）。
static func make_outdoor_sun() -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52.0, -35.0, 0.0)
	sun.light_energy = 1.3
	sun.light_color = Color(1.0, 0.97, 0.90)
	sun.light_angular_distance = 1.0
	sun.shadow_enabled = false
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	return sun


# ──────────────────────────────────────────────────────────── 掩体 / 装饰

func _kit(size: float) -> ArenaKit:
	if not _kits.has(size):
		var kit := ArenaKit.new()
		kit.dir = KIT_DIR
		kit.unit = size
		_kits[size] = kit
	return _kits[size]


func _build_cover() -> void:
	# 手动布局优先：文件里写了 cover 就**只摆这些**（不再自动撒石头）
	if not (layout.get("covers", []) as Array).is_empty():
		_build_cover_from_layout()
		return
	_rng.seed = SEED
	var transforms := {}   # name -> [Transform3D]
	var per_cluster := int(ceil(float(COVER_COUNT) / float(COVER_CLUSTERS)))
	for _cluster in COVER_CLUSTERS:
		# 先挑一个"干净的"堆中心，再围着它撒石头 —— 这样地图上有几处像样的交火点，
		# 而不是把 120 块石头均匀撒在 1 平方公里里（那样看着像空地）。
		var centre_m := _random_point()
		for _i in per_cluster:
			if cover_count >= COVER_COUNT:
				break
			var angle := _rng.randf_range(0.0, TAU)
			var radius := _rng.randf_range(0.0, COVER_CLUSTER_RADIUS_M)
			var point := centre_m + Vector2(cos(angle), sin(angle)) * radius
			if not _is_spawn_clear(point):
				continue
			var kind: Dictionary = COVER_KINDS[_rng.randi_range(0, COVER_KINDS.size() - 1)]
			var name := str(kind["name"])
			var size := float(kind["size"])
			var yaw_deg := _rng.randf_range(0.0, 360.0)
			# 自动摆放的也记下来 —— 导出成布局文件就是"手动摆放的起点"
			cover_layout.append([name, point.x, point.y, yaw_deg, size / LAYOUT_UNIT])
			_place_cover(name, point, yaw_deg, size, transforms)
	_flush_cover_nodes(transforms)
	_build_cover_shape_from_placed()


## 手动布局：每行 `cover <名字> <x 米> <z 米> <朝向 度> <大小倍数>`。
func _build_cover_from_layout() -> void:
	var transforms := {}
	for entry in layout.get("covers", []):
		var name := str(entry[0])
		var x_m := float(entry[1])
		var z_m := float(entry[2])
		var yaw_deg := float(entry[3])
		var size := LAYOUT_UNIT * maxf(0.1, float(entry[4]))
		_place_cover(name, Vector2(x_m, z_m), yaw_deg, size, transforms)
	_flush_cover_nodes(transforms)
	_build_cover_shape_from_placed()


## 一批掩体 → 每种模型一块 MultiMesh（一个 draw call）。
func _flush_cover_nodes(transforms: Dictionary) -> void:
	for name in transforms.keys():
		for node in _kit(1.0).make_nodes(str(name), transforms[name], str(name)):
			add_child(node)


# ──────────────────────────────────────────────────────── 场景里手摆的物件

## `Cover` / `Decor` 下面的子节点（在 **Godot 编辑器**里拖出来的石头和树）：
##   * 视觉：按 mesh 合批成 MultiMesh（和自动摆放一样省 draw call），源节点运行时隐藏；
##   * 碰撞（只给 Cover）：把所有石头的三角形合成一张 trimesh（和外观一致）；
##   * 装饰（树/灌木）**全部常驻**（2026-10-18 用户要求：不要按距离加载/卸载，
##     那种"远处整批消失/出现"会看成闪一下；数量由场景里摆多少自己定）。
## 返回 false 表示这个容器是空的（调用方走自动摆放）。
func _build_props_from_scene(node_name: String, with_collision: bool) -> bool:
	var root := get_node_or_null(node_name)
	if root == null or root.get_child_count() == 0:
		return false
	var buckets := {}   # Mesh -> Array[Transform3D]
	for child in root.get_children():
		_collect_meshes(child, buckets)
	var index := 0
	for mesh in buckets.keys():
		_make_multimesh_node("CoverBatch" if with_collision else "DecorBatch", index, mesh, buckets[mesh])
		index += 1
	if with_collision:
		# 碰撞：把所有掩体的**三角形**合成一张 trimesh —— 和看得见的石头一模一样，
		# 不再是"一个方盒子"（以前 88% AABB 会把斜石头周围一大圈都挡成空气墙）。
		var faces := PackedVector3Array()
		for child in root.get_children():
			_append_node_faces(child, faces)
			var box := _subtree_aabb(child)
			if box.size.length() < 0.01:
				continue
			cover_count += 1
			cover_points.append(
				Vector2(box.get_center().x, box.get_center().z) * PartDef.CUBE_METERS
			)
		_add_cover_body(faces)
	# 源节点只是"编辑器里的摆放工具"，运行时别重复画
	for child in root.get_children():
		child.visible = false
	return true



## 建一个 MultiMeshInstance3D（掩体用：实例变换直接是世界坐标）。
func _make_multimesh_node(prefix: String, index: int, mesh: Mesh, transforms: Array) -> void:
	if transforms.is_empty():
		return
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for i in transforms.size():
		multi.set_instance_transform(i, transforms[i])
	var batched := MultiMeshInstance3D.new()
	batched.name = "%s_%d" % [prefix, index]
	batched.multimesh = multi
	batched.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 掩体的实例数组是静态的，但同样关掉实例插值（和装饰保持一致，省得以后改了忘）
	RenderingServer.multimesh_set_physics_interpolated(multi.get_rid(), false)
	add_child(batched)


## 递归收集子树里所有 MeshInstance3D 的（网格, 世界变换）。
func _collect_meshes(node: Node, buckets: Dictionary) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh_instance := node as MeshInstance3D
		var mesh := mesh_instance.mesh
		if not buckets.has(mesh):
			buckets[mesh] = []
		(buckets[mesh] as Array).append(mesh_instance.global_transform)
	for child in node.get_children():
		_collect_meshes(child, buckets)


# ──────────────────────────────── 掩体碰撞：和外观一致的 trimesh

## 把一个网格实例的所有三角形（世界坐标）追加到 `faces`。
func _append_mesh_faces(mesh: Mesh, xform: Transform3D, faces: PackedVector3Array) -> void:
	if mesh == null:
		return
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices is PackedInt32Array and (indices as PackedInt32Array).size() >= 3:
			var idx := indices as PackedInt32Array
			for i in idx.size():
				faces.append(xform * verts[idx[i]])
		else:
			# 没有索引的网格：顶点本来就是三角形序列
			for v in verts:
				faces.append(xform * v)


## 递归把子树里所有网格的三角形（世界坐标）追加到 `faces`。
func _append_node_faces(node: Node, faces: PackedVector3Array) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh_instance := node as MeshInstance3D
		_append_mesh_faces(mesh_instance.mesh, mesh_instance.global_transform, faces)
	for child in node.get_children():
		_append_node_faces(child, faces)


## 用一张 trimesh 作为全部掩体的碰撞（一个 StaticBody + 一个 ConcavePolygonShape3D）。
## 和"每个掩体一个方盒"相比：凹进去的地方真能塞进去了，斜石头也不会挡住周围空气。
func _add_cover_body(faces: PackedVector3Array) -> void:
	if faces.size() < 3:
		return
	var body := StaticBody3D.new()
	body.name = "CoverBody"
	body.collision_layer = 1
	var shape := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(faces)
	shape.shape = concave
	body.add_child(shape)
	add_child(body)
	cover_collision_triangles = faces.size() / 3


## 子树的世界 AABB（小地图点 / 计数用）。
func _subtree_aabb(node: Node) -> AABB:
	var box := AABB()
	var first := true
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh_instance := node as MeshInstance3D
		box = mesh_instance.global_transform * mesh_instance.mesh.get_aabb()
		first = false
	for child in node.get_children():
		var child_box := _subtree_aabb(child)
		if child_box.size.length() < 0.0001:
			continue
		box = child_box if first else box.merge(child_box)
		first = false
	return AABB() if first else box


## 场景里 `Spawns/Team0_0 ... Team1_4` 的 Marker3D（编辑器里拖位置/朝向）。
## 返回 [x 米, z 米, 朝向 度]；没有这个标记就返回空数组。
## 用 marker 的**本地**变换（相对 `Spawns`）：不要在编辑器里挪/转/缩放 `Spawns` 本身。
func _marker_spawn(team: int, index: int) -> Array:
	var root := get_node_or_null("Spawns")
	if root == null:
		return []
	var node := root.get_node_or_null("Team%d_%d" % [team, index])
	if not (node is Node3D):
		return []
	var marker := node as Node3D
	var point := marker.transform.origin * PartDef.CUBE_METERS
	return [point.x, point.z, rad_to_deg(marker.rotation.y)]


## 摆一块掩体（世界米坐标 + 朝向度 + kit 缩放）。
## `transforms` 按名字收集，最后一次性 make_nodes（每种一块 MultiMesh）；
## 碰撞不在这里加 —— 摆完由 `_build_cover_shape_from_placed()` 合成一张 trimesh。
func _place_cover(
	name: String, point_m: Vector2, yaw_deg: float, size: float, transforms: Dictionary
) -> bool:
	var kit := _kit(size)
	if not kit.has_piece(name):
		push_warning("[对战场地] 没有这个掩体模型：%s" % name)
		return false
	# `piece_transform_center` 的 center 单位是"kit 格"（1 kit 格 = size 个 cube），
	# 所以世界格坐标要再除以 size —— 直接传世界格会把掩体摆到 16 倍远的地方去。
	var centre := point_m / PartDef.CUBE_METERS / size
	# ⚠️ yaw 是**度**（ArenaKit 内部 deg_to_rad）—— 以前自动摆放传的是 0..TAU 弧度，
	# 实际只转了 0~6°，等于没转；现在统一用度。
	var t := kit.piece_transform_center(name, centre, yaw_deg, 0.0)
	var box := world_box(t, kit.box_of(name))
	# 往地里埋一点（按大小缩放）：石头像"长在地里"，不是摆在地上的积木
	t.origin.y += ground_y(centre.x * size, centre.y * size) - box.position.y - COVER_SINK_CUBES * (size / LAYOUT_UNIT)
	if not transforms.has(name):
		transforms[name] = []
	(transforms[name] as Array).append(t)
	cover_count += 1
	cover_points.append(Vector2(centre.x * size, centre.y * size) * PartDef.CUBE_METERS)
	cover_placed.append([name, t])
	return true


## 程序化摆放之后：把所有覆盖物的三角形合成一张 trimesh（和外观一致）。
func _build_cover_shape_from_placed() -> void:
	var faces := PackedVector3Array()
	var kit := _kit(1.0)
	for entry in cover_placed:
		var piece_name := str(entry[0])
		var xform: Transform3D = entry[1]
		for part in kit.parts_of(piece_name):
			_append_mesh_faces(part["mesh"], xform * (part["local"] as Transform3D), faces)
	_add_cover_body(faces)


## 把自动摆放的结果导出成布局文件（tools/export_arena_layout.gd 用；游戏里不调用）。
func write_layout_file(path := LAYOUT_PATH, spawns: Array = []) -> bool:
	var lines := PackedStringArray()
	lines.append("# 对战场地手动布局 —— 改完直接进战局就生效（不用重开编辑器）")
	lines.append("# 坐标：原点 = 场地中心，x 向右、z 向下，单位**米**，范围 ±500")
	lines.append("# 大小：倍数，1.0 = 默认块头（约 8 米高）")
	lines.append("#")
	lines.append("# 出生点：spawn <队伍 0/1> <x 米> <z 米> <朝向 度>")
	lines.append("#   队伍 0 的**第一条**是玩家自己的出生点；后面 4 条是队友。队伍 1 是敌人。")
	lines.append("#   朝向 0 = 车头朝 +x（东），90 = 朝 +z（南），180 = 朝 -x（西）")
	lines.append("#")
	lines.append("# 掩体：cover <模型名> <x 米> <z 米> <朝向 度> <大小倍数>")
	lines.append("#   可选模型见 scripts/battle_arena.gd 的 COVER_KINDS / 下面的示例")
	for entry in spawns:
		lines.append(
			"spawn %d %.1f %.1f %.1f" % [int(entry[0]), float(entry[1]), float(entry[2]), float(entry[3])]
		)
	lines.append("")
	for entry in cover_layout:
		lines.append(
			"cover %s %.1f %.1f %.1f %.2f" % [
				str(entry[0]), float(entry[1]), float(entry[2]), float(entry[3]), float(entry[4])
			]
		)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string("\n".join(lines) + "\n")
	file.close()
	return true


## 读手动布局文件；没有文件 / 读不到 → 空布局（自动摆放）。
func _load_layout() -> Dictionary:
	var empty := {"spawns": [], "covers": []}
	if not FileAccess.file_exists(LAYOUT_PATH):
		return empty
	var file := FileAccess.open(LAYOUT_PATH, FileAccess.READ)
	if file == null:
		push_warning("[对战场地] 读不了布局文件：%s" % LAYOUT_PATH)
		return empty
	var parsed := parse_layout(file.get_as_text())
	file.close()
	return parsed


## 解析布局文本（纯函数，测试直接打它）。格式见 `LAYOUT_PATH` 注释。
static func parse_layout(text: String) -> Dictionary:
	var spawns := []
	var covers := []
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with("//"):
			continue
		# 逗号/制表符也当分隔符，少踩"复制粘贴带了逗号"的坑
		var bits := line.replace(",", " ").replace("\t", " ").split(" ", false)
		if bits.is_empty():
			continue
		var kind := str(bits[0]).to_lower()
		if kind == "spawn" and bits.size() >= 5:
			spawns.append([
				int(bits[1]), float(bits[2]), float(bits[3]), float(bits[4])
			])
		elif kind == "cover" and bits.size() >= 6:
			covers.append([
				str(bits[1]), float(bits[2]), float(bits[3]), float(bits[4]),
				maxf(0.1, float(bits[5])),
			])
		else:
			push_warning("[对战场地] 布局文件这行看不懂，跳过：%s" % line)
	return {"spawns": spawns, "covers": covers}


## 装饰（树 / 灌木）：只有视觉，不挡车也不挡子弹（省碰撞、也免得人机一头撞树上）。
func _build_decor() -> void:
	_rng.seed = SEED + 1
	var transforms := {}
	for i in TREE_COUNT:
		var name: String = TREE_KINDS[_rng.randi_range(0, TREE_KINDS.size() - 1)]
		var size := _rng.randf_range(14.0, 22.0)
		var kit := _kit(size)
		if not kit.has_piece(name):
			continue
		var centre := _random_point_decor() / PartDef.CUBE_METERS / size
		var t := kit.piece_transform_center(name, centre, _rng.randf_range(0.0, 360.0), 0.0)
		t.origin.y += ground_y(centre.x * size, centre.y * size) - world_box(t, kit.box_of(name)).position.y
		if not transforms.has(name):
			transforms[name] = []
		(transforms[name] as Array).append(t)
		decor_layout.append([name, t])
		tree_count += 1
	for i in BUSH_COUNT:
		var name: String = BUSH_KINDS[_rng.randi_range(0, BUSH_KINDS.size() - 1)]
		var size := _rng.randf_range(7.0, 11.0)
		var kit := _kit(size)
		if not kit.has_piece(name):
			continue
		var centre := _random_point_decor() / PartDef.CUBE_METERS / size
		var t := kit.piece_transform_center(name, centre, _rng.randf_range(0.0, 360.0), 0.0)
		t.origin.y += ground_y(centre.x * size, centre.y * size) - world_box(t, kit.box_of(name)).position.y
		if not transforms.has(name):
			transforms[name] = []
		(transforms[name] as Array).append(t)
		decor_layout.append([name, t])
	for name in transforms.keys():
		for node in _kit(1.0).make_nodes(str(name), transforms[name], str(name)):
			add_child(node)


## 出生区（两队 5 个点周围 `SPAWN_CLEAR_RADIUS_M`）是不是干净的（不在里面）。
func _is_spawn_clear(point_m: Vector2) -> bool:
	for team in 2:
		for index in 5:
			var spawn := team_spawn_meters(team, index, 5)
			if Vector2(spawn.x, spawn.z).distance_to(point_m) < SPAWN_CLEAR_RADIUS_M:
				return false
	return true


## 随机点（米），避开两队出生区（`SPAWN_CLEAR_RADIUS_M`）和场地边缘 —— 掩体用这个。
func _random_point() -> Vector2:
	var half_m := SIZE_METERS * 0.5 - 30.0
	for _try in 40:
		var point := Vector2(
			_rng.randf_range(-half_m, half_m), _rng.randf_range(-half_m, half_m)
		)
		if _is_spawn_clear(point):
			return point
	return Vector2(-half_m, -half_m)


## 装饰用的随机点（米）：树和灌木不挡车，可以长到出生点旁边（否则出生点周围是一大片空地）。
func _random_point_decor() -> Vector2:
	var half_m := SIZE_METERS * 0.5 - 12.0
	return Vector2(_rng.randf_range(-half_m, half_m), _rng.randf_range(-half_m, half_m))


## 隐形围墙：把可开区域围起来（不然能一路开出地图掉下去）。
func _build_walls() -> void:
	var half := SIZE_METERS * 0.5 / PartDef.CUBE_METERS
	var height := 80.0
	var thickness := 4.0
	for side in 4:
		var body := StaticBody3D.new()
		body.name = "Wall%d" % side
		body.collision_layer = 1
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var pos := Vector3.ZERO
		if side < 2:
			box.size = Vector3(thickness, height, half * 2.0)
			pos = Vector3((-half - thickness * 0.5) if side == 0 else (half + thickness * 0.5), height * 0.5, 0.0)
		else:
			box.size = Vector3(half * 2.0, height, thickness)
			pos = Vector3(0.0, height * 0.5, (-half - thickness * 0.5) if side == 2 else (half + thickness * 0.5))
		shape.shape = box
		body.position = pos
		body.add_child(shape)
		add_child(body)


## 把一个局部 AABB 按 `t` 变换成世界 AABB（ArenaKit 里只对"按格摆放"的变换做了这件事）。
static func world_box(t: Transform3D, box: AABB) -> AABB:
	var out := BuildGrid.rotate_aabb(t.basis, box)
	out.position += t.origin
	return out