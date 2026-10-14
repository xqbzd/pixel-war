@tool
class_name PartDef
extends RefCounted

## 部件定义：从 data/parts/*.part.txt 读出来，负责变成可渲染的 mesh + 材质。
##
## 两条渲染路线，读同一份体素体积：
##   texture —— 立方体部件。每个 cube 单元每面 1 个四边形，走 16x16 图集。
##              面数固定 6/单元，且所有实例共享同一张图集和同一个 mesh。
##   voxel   —— 非立方体部件。贪心网格化的体素网格，顶点色，斜面保留像素台阶。
##
## texture 路线的前提是“每个占用的 cube 都是实心 16^3”；形状不满足时自动退回 voxel 并记一条警告。

enum RenderMode { TEXTURE, VOXEL }

const DEFAULT_BODY := "c9c9ce"
const DEFAULT_EDGE := "8e8e96"
## 世界标定：**1 cube（一格） = 多少米**。2026-10-14 用户要求从 0.2 改成 0.5 ——
## 他发现手感问题很大程度上是比例尺问题（车 25 格长，30 m/s 在旧标定下 = 150 格/秒
## ≈ 每秒跑 6 个车身长，太快、太贼）。改完这一处，下面这些地方**必须一起动**：
##   * `project.godot` → `physics/3d/default_gravity` = 真实 9.8 m/s² ÷ CUBE_METERS；
##   * 部件文件里的**速度**（m/s）不用改：换算全在 `muzzle_speed_cubes()` /
##     `wheel_max_speed_cubes()` 里做一次（1 m/s = 1/CUBE_METERS 格/秒）；
##   * 测试场的速度表按这个常量换算 km/h。
## 关卡：`test_world_calibration_is_consistent`（守"常量 / 重力 / 换算"三者一致）。
## ⚠️ 力和弹簧**不跟着标定变**（它们是"格世界"里的数，见下面悬挂那一段的说明）。
const CUBE_METERS := 0.5
## 真实世界的重力加速度（m/s²）：世界的重力 = 这个数 ÷ CUBE_METERS（格/秒²）。
const EARTH_GRAVITY := 9.8
## 模拟里的重力（格/秒²）：**必须和 `project.godot` 里写的那个数一样**（测试守着）。
const GRAVITY_CUBES := EARTH_GRAVITY / CUBE_METERS

var id := ""
var display_name := ""
var shape := VoxShapes.SHAPE_CUBE
var cubes := Vector3i.ONE
## 用 int 而不是 RenderMode 存：脚本里要把外部传入的 int 路线写回来，
## 声明成枚举类型会触发 INT_AS_ENUM_WITHOUT_CAST 警告。取值仍然用 RenderMode.*。
var render_mode: int = RenderMode.VOXEL
var body_color := Color(DEFAULT_BODY)
var edge_color := Color(DEFAULT_EDGE)
var edge_band := 1
## 物品栏排序权重（小的在前）；同权重按 id 排。默认 100，方便新部件插到后面。
var order := 100
## 基本数值（用户手动调整）：重量 / 血量 / 部件点数。默认 1kg / 1000 点 / 1pp。
var weight_kg := 1.0
var hp := 1000
var pp := 1
## 核心部件：一台机器人最多一个，被摧毁即整机判定被摧毁。
var is_core := false
## 重心的手动覆盖值（单位 = 体素，相对零件本地原点）；留空则用几何中心。
var center_override := Vector3i.ZERO
var center_overridden := false
## 外部工具导出的体素模型（Goxel 文本格式）。设了它就用模型，不用 shape 生成。
var model_path := ""
## 可选：手动指定连接面（如 "+z -z"）；留空则模型自动推导 / shape 用解析式结果。
var connection_override := []
## 是否显式写了 connections 这一行（写空值 / none = 明确"这个部件没有连接面"）
var connections_set := false
## 随本部件一起生成的浮动附属模型（轮体）：它不是独立可放置部件，
## 由轮轴带着走，测试场里对应 VehicleWheel3D 的外观。
var wheel_body := ""
## 附属子模型的挂载偏移（单位 = 体素，相对零件本地原点，可负）。
## 轮体也**算碰撞体积**，所以这个偏移同时决定它的网格位置和碰撞盒。
var wheel_offset := Vector3i.ZERO
## 物理角色："" = 普通部件（刚体）；"wheel" = 测试场里的假轮子（VehicleWheel3D + 像素外观）
var physics := ""
## 模型在部件盒里的体素偏移，可以是负值（模型探出盒子，比如轮轴整体下移 3 像素）。
## 负偏移时体积会自动放大来容纳，网格原点再整体平移回去，所以不会丢体素。
var model_offset := Vector3i.ZERO
## 为容纳负偏移在正方向留出的体素余量（由 model_volume 算出，网格原点与包围盒都用它）
var model_pad := Vector3i.ZERO
## ── 轮子参数（只有带 `wheel_body` 的部件用得上）───────────────────────────
## 动力：engine_force 是每个驱动轮的推力（N），max_speed 到了就收油（m/s）。
var wheel_engine_force := 90.0
var wheel_brake := 60.0
var wheel_max_speed := 14.0
var wheel_friction := 3.0
## 转向：最大转角（度），以及转向**角速度**（度/秒）—— 有了角速度车轮才会"缓启动"，
## 不会一帧就打满方向；0 会在解析时被夹到很小的正数（防止除零 / 卡死）。
var wheel_steer_max := 24.0
var wheel_steer_speed := 90.0
## **回正**角速度（度/秒）：松开方向键后，转角以这个速度回到中位（0°）。
## 不写 / 写 0 = 和 `wheel_steer_speed` 一样（老行为：打方向和回正同速）。
## 想让车"撒手就正"就把它写大（比如转向 60、回正 240）；这**不影响**打方向那段的手感。
var wheel_steer_return_speed := 0.0
## 半径：0 = 按轮胎模型自动算（轮胎盒子 y/z 较大者的一半）。
var wheel_radius := 0.0
## ── 悬挂（**全是可直接调的物理量，没有倍率/参考值**）──────────────────────
## ⚠️ 长度单位一律是**格**（1 格 = CUBE_METERS 米）；力是"格世界"里的 N、阻尼是 N·秒/格。
## 这些是"格世界"里的数值（重力 = GRAVITY_CUBES 格/秒² = 真实 9.8 ÷ CUBE_METERS），
## 别按真实米去算 —— 而且**改标定不用改这些数**：它们决定的是 a/g（动力/重力比），
## 那才是手感。想让"真实 m/s²"不变，才需要按 1/CUBE_METERS 去缩。
## `wheel_rest_length` = 悬挂自由长度（硬点比轮心高这么多）；
## `wheel_suspension_travel` = 行程上限（最多压这么多，压到底就硬了，防止穿透）。
var wheel_rest_length := 0.15
var wheel_suspension_travel := 0.3
## 弹簧刚度 N/格：把悬挂压 1 格需要多少力。**软硬的唯一入口**。
## 静止压缩量 = 这个轮子承担的重量 ÷ 刚度（纯物理，车重了自然压得更多，没有倍率）。
var wheel_stiffness := 150000.0
## ── 悬挂：**按车重自动算**（2026-10-14 用户要求：同一套参数在轻重车上手感一致）──────
## 旧的 `wheel_stiffness` / `wheel_damper_*` / `wheel_suspension_max_force` 是**绝对值**：
## 给两吨车调的 300000 N/格 + 150000 N 上限，套到几百公斤的车上就是"静止几乎不压
## （等于没悬挂）+ 支撑力上限还是车重的几十倍" → 一个小坎就把车弹上天
## （用户报的"更轻的载具会像弹簧一样飞天"）。下面三个量**相对车重**：
##   `wheel_ride_sag`        静止时悬挂压下去多少格 → 刚度 = 该轮静态负载 ÷ 它
##   `wheel_damper_ratio`    阻尼相对**临界阻尼**（1.0 = 刚好不回弹）→ c = 2·ζ·√(刚度 × 单轮质量)
##   `wheel_support_multiple` 单轮最大支撑力 = 该轮静态负载 × 它
## `wheel_ride_sag <= 0` 时退回上面那套旧绝对值（老部件文件不会坏）。
var wheel_ride_sag := 0.0
var wheel_damper_ratio := 0.0
var wheel_support_multiple := 0.0
## 单轮支撑力的**硬截断**（倍**车重**，用户手动调）：一个轮子的力不许超过"整车重量 × 它"。
## 1.0 = 一倍车重；0 = 不截断。射线式悬挂在临界高度上会给出"一帧满力"的尖峰，硬截断能削掉它
## 而且**不改相位**（低通滤波会加滞后、把支撑回路推成自激振荡 —— 试过，连两吨的车都抖）。
## 静止时单轮只有"车重 ÷ 轮数"，离上限很远，所以只有尖峰被削。
var wheel_peak_force_car_weights := 1.0
## ── 轮胎力模型（移植自 nani_raycast_wheel.gd，MIT，见 reference/nani_raycast_wheel/）──
## 抓地倍率：轮胎力整体乘这个（1.0 = 原始）。想整体更粘/更滑就调它。
var wheel_grip_factor := 1.0
## 侧向 / 纵向 **Pacejka 四系数** `peak stiff curve shape`（照搬它的 1,10,0,1.35 / 1,10,0,1.65）。
## 公式：`力 = 法向载荷 × peak × sin(shape·atan(stiff·s − curve·(stiff·s − atan(stiff·s))))`
## 小滑移时侧偏刚度 ≈ 载荷 × peak × stiff × shape，大滑移自动饱和（不会把车掀翻）。
var wheel_lat_pacejka := [1.0, 10.0, 0.0, 1.35]
var wheel_long_pacejka := [1.0, 10.0, 0.0, 1.65]
## 阻尼系数 N·秒/格：压缩（往下压）和回弹（伸出去）可以不一样。
## 参考值（想要"刚好不振荡"）：临界阻尼 c = 2 × √(刚度 × 单轮质量)，
## 取它的 0.4~0.7 倍比较舒服；比临界大 = 发闷，小了 = 过坎会弹几下。
var wheel_damper_compression := 4250.0
var wheel_damper_relaxation := 6400.0
## 支撑力上限 N：安全阀（避免极端情况下弹飞），正常行驶碰不到。
var wheel_suspension_max_force := 30000.0
## ── 自定义整圈射线轮胎的手感旋钮（见 scripts/test_field.gd）─────────────────
## 这些是"每根轮轴各读自己那一份"的调参入口；测试场里的同名 `WHEEL_*` 常量现在只是
## **默认值**（部件文件没写这一行时才用）。除 `wheel_rays` 外都是浮点，且都允许 0（0 有特殊
## 含义的会注明）。
## 抓地力：`wheel_mu` 直接给库仑摩擦系数（> 0 时优先用它，1.0 = 1 g 横向加速度）；
## 写 0 = 退回按 `wheel_friction × wheel_mu_per_friction` 换算，上限 `wheel_mu_max`。
var wheel_mu := 0.0
var wheel_mu_per_friction := 0.08
var wheel_mu_max := 5.0
## 滑移衰减：横向滑得越快，可用横向摩擦越小（0 = 不衰减，抓地拉满；越大越"推头"）。
## `wheel_slip_ref` = 滑移到这个速度时横向摩擦掉 `wheel_slip_falloff` 那么多（格/秒）。
var wheel_slip_falloff := 0.3
var wheel_slip_ref := 16.0
## 整圈射线：条数（每条 360/rays 度）、射线余量（提前发现台阶边缘）、
## 悬挂扇区阈值（射线方向与"下"的点积大于它就跳过 —— 那一片归悬挂那条射线管）。
var wheel_rays := 16
var wheel_ray_slack := 0.04
var wheel_sus_sector := 0.5
## 判定射线的**侧向偏移**（格，沿轮胎轴向，正 = 往车外）：0 = 轮胎中缝（老行为），
## 写"轮胎半宽"（2x2 轮轴是 0.4）就把整套判定挪到**轮胎外侧面**。
## 挪的是射线本身；轮胎网格和轮心不动 —— 贴路缘时"咬合的位置"会从轮胎中缝变到外侧面。
var wheel_ray_offset := 0.0
## 力的增益，都是"相对速度 × 增益 = 目标力"，再按 mu × 法向力截断：
##   wheel_grip_gain  = 横向（抵侧滑）；wheel_brake_gain = 刹车；wheel_roll_gain = 滚动阻力。
var wheel_grip_gain := 2500.0
var wheel_brake_gain := 4000.0
var wheel_roll_gain := 2.0
## 侧倾稳定器（防翻）。**整车共用一份：取第一个轮轴这两个值**（用 `parts[0]` 那根轮轴的）。
## tilt = 横向 1 g 时允许的侧倾角（**度**），0 = 关掉防翻；damping = 阻尼倍率（相对临界阻尼，
## 1.0 = 刚好不振荡；这个倍率是"阻尼 vs 临界阻尼"的直接比值，不是再乘别的数）。
var wheel_anti_roll_tilt_deg := 8.0
var wheel_anti_roll_damping := 0.55
## ── 武器（转塔）────────────────────────────────────────────────────────────
## 一个 .vox 场景里放了多个物体、其中两个要**相对旋转**时用这一组。约定：
##   0 号子模型 = 底座（跟着本体固定不动）、`weapon_yaw_model` = 水平旋转的支架、
##   `weapon_pitch_model` = 俯仰旋转的枪管。
## 转轴/转点**从模型几何推导**（见 weapon_yaw_center / weapon_barrel_axis / weapon_pivot）：
##   竖直回转轴 = 底座包围盒在水平面上的中心；
##   枪管轴线   = 枪管沿"最长轴正方向"最外那一层的截面中心（就是枪口截）；
##   俯仰转点   = 上面两条轴的交点 —— 于是枪管绕自己的轴线转，枪口不画圈。
## 枪口点也由它推出来（weapon_muzzle），测试场从那儿打瞄准射线。
var weapon := ""                  # "" = 普通零件；"turret" = 转塔
var weapon_yaw_model := 1         # 支架（相对底座水平转）的子模型序号
var weapon_pitch_model := 2       # 枪管（相对支架俯仰）的子模型序号
## 水平射界（整角，度）：360 = 全向自由旋转；< 360 时以"枪口正前方"为中心 ± 一半。
var weapon_yaw_limit := 360.0
## 俯仰范围（度，相对水平）：负 = 压枪，正 = 抬枪。
var weapon_pitch_min := -5.0
var weapon_pitch_max := 35.0
## ── 开火（转塔用）──────────────────────────────────────────────────────────
## ⚠️ **速度一律写真实 m/s**（世界标定 1 cube = CUBE_METERS 米，
## 模拟内部用"格"，换算在 `muzzle_speed_cubes()` 里做一次，别在别处再乘一遍）。
var weapon_projectile := "bullet"   # 射弹类型：目前只有 "bullet"（受重力的点状弹丸）
var weapon_muzzle_speed := 120.0    # 子弹初速度，m/s
var weapon_damage := 12.0           # 每发伤害
var weapon_rpm := 600.0             # 射速，发/分钟
var weapon_spread := 1.5            # 初速度的随机角散射，度（±，锥形均匀分布）
var weapon_traverse_speed := 60.0   # 炮塔最高转速，度/秒（水平、俯仰共用一个）
var weapon_energy_cost := 10.0      # 每发消耗的能量
## 弹丸寿命（秒）：打出去多久自动消失。射速 × 寿命 = 同屏最多几发，**这是防卡爆的主要旋钮**
## （另一道保险是射弹池的硬上限 `Projectiles.MAX_LIVE`）。写 0 会被夹到 0.05 秒、## 上限 120 秒 —— 别用"永不消失"来调手感。
var weapon_projectile_life := 8.0
## ── 能量（核心提供）────────────────────────────────────────────────────────
## 整车武器共用一口能量池：上限 + 每秒恢复。不是核心的零件写这两个没有意义。
var energy_max := 0.0
var energy_regen := 0.0
var source_path := ""
var warnings: PackedStringArray = PackedStringArray()
var _model_volume: VoxVolume = null
var _model_mtime := 0
var _sub_volume: VoxVolume = null
var _sub_mtime := 0
var _scene_models := []      # .vox 场景里的全部子模型（武器零件要三个都拿到）
var _scene_palette := []
var _scene_mtime := 0
var _weapon_volumes := {}      # 子模型序号 -> VoxVolume（缓存，见 weapon_volume()）
var _bounds := AABB()
var _bounds_ready := false
var _body := AABB()
var _body_ready := false
var _collision := AABB()       # 碰撞盒（武器零件不含枪管，见 collision_bounds()）
var _collision_ready := false


static func from_text(text: String, path := "") -> PartDef:
	var def := PartDef.new()
	def.source_path = path
	if not path.is_empty():
		# cube_full.part.txt -> cube_full
		def.id = path.get_file().get_basename().get_basename()
		def.display_name = def.id
	var line_no := 0
	for raw in text.split("\n"):
		line_no += 1
		var line := strip_comment(raw).strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq < 0:
			def._warn("第 %d 行不是 key = value，已忽略：%s" % [line_no, line])
			continue
		def._apply(line.substr(0, eq).strip_edges().to_lower(), line.substr(eq + 1).strip_edges(), line_no)
	return def


func mode_name() -> String:
	return "texture" if render_mode == RenderMode.TEXTURE else "voxel"


## 连接点所在的面（局部空间，轴对齐单位向量）。
func connection_faces() -> Array:
	if connections_set:
		return connection_override
	if not model_path.is_empty():
		var loaded := model_volume()
		if loaded != null:
			return VoxModel.derive_connections(loaded)
	return VoxShapes.connection_dirs(shape)


## 外部模型（带修改时间缓存：文件一改就重新读，方便"建模 → 存盘 → 立刻看到"）。
func model_volume() -> VoxVolume:
	if model_path.is_empty() or not FileAccess.file_exists(model_path):
		return null
	var mtime := FileAccess.get_modified_time(model_path)
	if _model_volume != null and mtime == _model_mtime:
		return _model_volume
	# 负偏移要让模型能探出盒子：体积在该轴正方向留余量，装载后整体平移
	model_pad = Vector3i(
		maxi(0, -model_offset.x), maxi(0, -model_offset.y), maxi(0, -model_offset.z)
	)
	var target := VoxVolume.VOXELS_PER_CUBE * cubes + model_pad + Vector3i(
		maxi(0, model_offset.x), maxi(0, model_offset.y), maxi(0, model_offset.z)
	)
	# 按扩展名选装载器：.vox 走 MagicaVoxel 格式，其余按 Goxel 文本读
	if weapon != "":
		# 武器零件：本体 = **全部子模型并起来**（三个物体本来就画在同一个场景空间里），
		# 所以车库/建造网格里看到的是完整的机枪；测试场再把支架/枪管拆成会转的节点。
		_model_volume = weapon_union_volume()
	else:
		var result := (
			VoxFile.load_vox(model_path, target)
			if model_path.to_lower().ends_with(".vox")
			else VoxModel.load_text(model_path, target)
		)
		_model_volume = result.get("volume")
		for warning in result.get("warnings", []):
			_warn(str(warning))
	_model_mtime = mtime
	_bounds_ready = false  # 模型文件换了，包围盒要重算
	_body_ready = false
	_collision_ready = false
	if _model_volume != null and model_offset != Vector3i.ZERO:
		_model_volume = _shift_volume(_model_volume, model_offset + model_pad)
	return _model_volume


## 把体积里的体素整体平移（用于 model_offset）：目标体积按需放大，不丢体素。
func _shift_volume(volume: VoxVolume, delta: Vector3i) -> VoxVolume:
	var target := volume.size + Vector3i(absi(delta.x), absi(delta.y), absi(delta.z))
	var moved := VoxVolume.new(target)
	moved.palette = volume.palette.duplicate()
	var base := Vector3i(
		delta.x if delta.x < 0 else 0, delta.y if delta.y < 0 else 0, delta.z if delta.z < 0 else 0
	)
	for z in range(volume.size.z):
		for y in range(volume.size.y):
			for x in range(volume.size.x):
				var value := volume.get_voxel(x, y, z)
				if value != VoxVolume.EMPTY:
					moved.set_voxel(x - base.x, y - base.y, z - base.z, value)
	return moved


## 附属子模型（轮体）的体积。它不是独立部件：由所属零件带着走，
## 测试场里对应 VehicleWheel3D 的外观。体积大小按 .vox 自己的范围向上取整到 cube。
func sub_model_volume() -> VoxVolume:
	if wheel_body.is_empty() or not FileAccess.file_exists(wheel_body):
		return null
	var mtime := FileAccess.get_modified_time(wheel_body)
	if _sub_volume != null and mtime == _sub_mtime:
		return _sub_volume
	var size := Vector3i.ONE * VoxVolume.VOXELS_PER_CUBE
	var models: Array = VoxFile.load_vox_models(wheel_body).get("models", [])
	if not models.is_empty():
		var extent: Vector3i = (models[0]["offset"] as Vector3i) + (models[0]["size"] as Vector3i)
		size = Vector3i(
			maxi(16, ceili(float(extent.x) / 16.0) * 16),
			maxi(16, ceili(float(extent.y) / 16.0) * 16),
			maxi(16, ceili(float(extent.z) / 16.0) * 16)
		)
	var result := VoxFile.load_vox(wheel_body, size)
	_sub_volume = result.get("volume")
	_sub_mtime = mtime
	_bounds_ready = false  # 子模型换了，碰撞箱要重算
	_collision_ready = false
	for warning in result.get("warnings", []):
		_warn("子模型（%s）：%s" % [wheel_body.get_file(), str(warning)])
	return _sub_volume


## 子模型的原点在零件本地空间的位置（单位 = cube）。
func sub_model_offset() -> Vector3:
	return Vector3(wheel_offset) / float(VoxVolume.VOXELS_PER_CUBE)


## ── 武器（转塔）：把 .vox 场景里的多个子模型按作者画的位置分别取出来 ──────────
## `VoxFile.load_vox()`（单模型路径）只取第 0 个；武器的三个物体要走这一条。
## 返回 [{size, voxels, offset}]，offset = 该物体在**零件本地体素坐标**里的位置
## （VoxFile 已经把 .vox 的 Z-up 转成游戏的 Y-up，所以这些数可以直接用）。
func scene_models() -> Array:
	if model_path.is_empty() or not FileAccess.file_exists(model_path):
		return []
	if not model_path.to_lower().ends_with(".vox"):
		return []   # 文本格式只有一个模型，武器零件请用 .vox
	var mtime := FileAccess.get_modified_time(model_path)
	if _scene_models.is_empty() or mtime != _scene_mtime:
		var result := VoxFile.load_vox_models(model_path)
		_scene_models = result.get("models", [])
		_scene_palette = result.get("palette", [])
		_scene_mtime = mtime
		_weapon_volumes.clear()   # 模型换了：各子模型的体积缓存一起作废
	return _scene_models


## 第 index 个子模型的体积：体素**按它在场景里的位置**摆进一个整机尺寸的体积，
## 于是网格顶点直接就是零件本地坐标（不用再补偏移）。武器零件用。
func weapon_volume(index: int) -> VoxVolume:
	var models := scene_models()
	if index < 0 or index >= models.size():
		return null
	# 缓存：`Turret.setup()` 每台机器要取好几次（转轴推导 + 网格），而每造一次要重画 48³
	# （实测 1.4 ms/次）。武器多了这就是几十毫秒 ×N。换模型时 `scene_models()` 会重载，
	# 那时一起清掉缓存（见下面的 `_scene_volumes.clear()`）。
	if not _weapon_volumes.has(index):
		_weapon_volumes[index] = _scene_volume([models[index]])
	return _weapon_volumes[index]


## 本体体积：全部子模型并起来（武器的静态外观 = 底座 + 支架 + 枪管）。
func weapon_union_volume() -> VoxVolume:
	var models := scene_models()
	if models.is_empty():
		return null
	return _scene_volume(models)


## 按整机尺寸（cubes × 16 体素）造一个体积，把给定的子模型画进去。
func _scene_volume(models: Array) -> VoxVolume:
	var volume := VoxVolume.new(VoxVolume.VOXELS_PER_CUBE * cubes)
	# palette 是类型化数组（Array[Color]），不能直接赋一个普通 Array：先清空再逐个 append
	volume.palette.clear()
	for colour in _scene_palette:
		volume.palette.append(colour)
	while volume.palette.size() < 2:
		volume.palette.append(Color.WHITE)
	if model_offset != Vector3i.ZERO:
		_warn("武器零件还不支持 model_offset（%s），已忽略" % str(model_offset))
	for model in models:
		var offset: Vector3i = model.get("offset", Vector3i.ZERO)
		# 换模型时最容易踩的坑：新模型画得比 `cubes` 大 —— 现在超出的体素会被**静默裁掉**
		# （枪管少一截、底座缺一角，看着像"模型坏了"）。这里提前告警，把两个数都写出来。
		var extent: Vector3i = offset + (model.get("size", Vector3i.ONE) as Vector3i)
		if (
			extent.x > volume.size.x or extent.y > volume.size.y or extent.z > volume.size.z
			or offset.x < 0 or offset.y < 0 or offset.z < 0
		):
			_warn(
				"子模型超出部件体积（子模型 %s，体积 %s）—— 超出的体素被裁掉了，把 cubes 调大"
				% [str(extent), str(volume.size)]
			)
		for entry in model.get("voxels", []):
			var pos: Vector3i = (entry["pos"] as Vector3i) + offset
			if (
				pos.x < 0 or pos.y < 0 or pos.z < 0
				or pos.x >= volume.size.x or pos.y >= volume.size.y or pos.z >= volume.size.z
			):
				continue
			volume.set_voxel(pos.x, pos.y, pos.z, int(entry["color"]))
	return volume


## ── 转塔几何：转轴/转点/枪口全部从模型推导 ─────────────────────────────────

## 竖直回转轴在零件本地水平面上的位置（单位 = cube）：底座（0 号子模型）包围盒的中心。
func weapon_yaw_center() -> Vector2:
	var base := weapon_volume(0)
	if base == null:
		return Vector2.ZERO
	var bounds := tight_bounds(base, Vector3.ZERO, Vector3.ONE)
	var centre := bounds.position + bounds.size * 0.5
	return Vector2(centre.x, centre.z)


## 枪管轴线：{axis, dir, height, lateral, muzzle, ok}
##   axis    = 枪管伸展的轴（0 = x, 1 = y, 2 = z）
##   dir     = 枪口方向（沿该轴的单位向量，取**正方向** —— 枪管要朝正方向伸出）
##   height  = 轴线高度（cube，沿 y）
##   lateral = 轴线在另一个水平轴上的位置（cube，axis = 2 时是 x，axis = 0 时是 z）
##   muzzle  = 枪口点（cube，零件本地）
##
## ⚠️ 轴线取"沿该轴正方向最外那一层"的截面中心，**不是**枪管包围盒中心：
## 枪管下面还挂着机匣/护木，包围盒中心比真正的枪轴低（这一版模型低 1.5 体素）——
## 拿包围盒中心当转点，枪口转起来会画圈。
func weapon_barrel_axis() -> Dictionary:
	var volume := weapon_volume(weapon_pitch_model)
	if volume == null:
		return {}
	var unit := float(VoxVolume.VOXELS_PER_CUBE)
	var axis := 0
	var longest := -1
	for a in 3:
		var span := volume.outermost_layer(a, true) - volume.outermost_layer(a, false)
		if span > longest:
			longest = span
			axis = a
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	# 从正方向最外那一层往里找，取第一层"至少有 2 个体素"的截面 ——
	# 最外那一层可能只有 1 个体素（枪口的一个点），那样中心会偏。
	var layer := volume.outermost_layer(axis, true)
	var centre := Vector2.ZERO
	var found := false
	while layer >= 0 and not found:
		var lo := Vector2i(1 << 20, 1 << 20)
		var hi := -lo
		var count := 0
		for iv in range(volume.size[v]):
			for iu in range(volume.size[u]):
				var pos := Vector3i.ZERO
				pos[axis] = layer
				pos[u] = iu
				pos[v] = iv
				if volume.get_voxel(pos.x, pos.y, pos.z) == VoxVolume.EMPTY:
					continue
				count += 1
				lo = lo.min(Vector2i(iu, iv))
				hi = hi.max(Vector2i(iu, iv))
		if count >= 2:
			# 截面中心：格 i 占 [i, i+1]，所以中心 = (最小 + 最大 + 1) / 2
			centre = Vector2(float(lo.x + hi.x + 1), float(lo.y + hi.y + 1)) * 0.5
			found = true
		layer -= 1
	if not found:
		return {}
	# 枪口点 = 最外那一层的**外面**（正方向）
	var muzzle_index := float(volume.outermost_layer(axis, true) + 1)
	var root := Vector3.ZERO
	root[axis] = muzzle_index
	root[u] = centre.x
	root[v] = centre.y
	var height := (centre.y if axis == 2 else centre.x) / unit
	var lateral := (centre.x if axis == 2 else centre.y) / unit
	var dir := Vector3.ZERO
	dir[axis] = 1.0
	return {
		"ok": true,
		"axis": axis,
		"dir": dir,
		"height": height,
		"lateral": lateral,
		"muzzle": root / unit,
	}


## 枪口点（零件本地，单位 = cube）。瞄准射线从这里出发。
func weapon_muzzle() -> Vector3:
	var axis_info := weapon_barrel_axis()
	return axis_info.get("muzzle", Vector3.ZERO)


## 转塔转点（零件本地，单位 = cube）：**枪管轴线与竖直回转轴的交点**。
## 水平旋转绕竖直轴、俯仰绕枪管的横向轴，两条轴都过这一点 ——
## 于是枪管是绕自己的轴线转的，枪口不会画圈（这是用户要的硬性要求）。
## 返回 {ok, pivot, reason}；两条轴不相交（枪管没对准回转轴）时 ok = false 并说明原因。
func weapon_pivot() -> Dictionary:
	var axis_info := weapon_barrel_axis()
	if axis_info.is_empty():
		return {
			"ok": false,
			"pivot": Vector3.ZERO,
			"reason": "读不出枪管模型（weapon_pitch_model = %d）" % weapon_pitch_model,
		}
	var axis: int = axis_info["axis"]
	if axis == 1:
		return {"ok": false, "pivot": Vector3.ZERO, "reason": "枪管是竖直的，和竖直回转轴平行"}
	var yaw := weapon_yaw_center()
	var lateral: float = axis_info["lateral"]
	# 枪管沿 z 时，它的横向位置是 x；沿 x 时是 z。回转轴的对应坐标必须和它重合。
	var lateral_ok := absf(lateral - (yaw.x if axis == 2 else yaw.y)) < 0.07  # 1 体素
	var pivot := Vector3(yaw.x, float(axis_info["height"]), yaw.y)
	return {
		"ok": lateral_ok,
		"pivot": pivot,
		"reason": (
			""
			if lateral_ok
			else "枪管轴线没穿过回转轴（横向差 %.3f cube）—— 枪口会画圈" % absf(
				lateral - (yaw.x if axis == 2 else yaw.y)
			)
		),
	}


## 零件的**基准格**（本地格子，绑在模型几何上）：本体 AABB 中心所在那一格。
## 压在格线上时取**下面**那一格（轮轴本体正好 2 格厚、中心正好落在格线上，
## 取下面那格才是"最靠 -x 的那半块"）。摆放数学（BuildGrid）和镜像都用它。
func anchor_cell() -> Vector3i:
	var bounds := body_bounds()
	var centre := bounds.position + bounds.size * 0.5
	return Vector3i(_cell_below(centre.x), _cell_below(centre.y), _cell_below(centre.z))


static func _cell_below(value: float) -> int:
	return ceili(value) - 1


## 子弹初速度：部件文件写的是真实 m/s，模拟内部用"格/秒"（×1/CUBE_METERS）。
func muzzle_speed_cubes() -> float:
	return weapon_muzzle_speed / CUBE_METERS


## 车轮限速：同上（部件文件写真实 m/s），内部用"格/秒"。
func wheel_max_speed_cubes() -> float:
	return wheel_max_speed / CUBE_METERS


## 射速换算成"两发之间的秒数"（0 = 不能开火）。
func fire_interval_seconds() -> float:
	if weapon_rpm <= 0.0:
		return INF
	return 60.0 / weapon_rpm


## 悬挂参数：**零件固有（绝对值）** —— `wheel_stiffness`（N/格）、
## `wheel_damper_compression/relaxation`（N·秒/格）、`wheel_suspension_max_force`（N）。
##
## 2026-10-14 试过一版"按车重自动算"（`wheel_ride_sag` / `wheel_damper_ratio` /
## `wheel_support_multiple`）：比值确实能自适应，但**轻车被弹飞的根因不在比值**，
## 而在"射线式悬挂会在临界高度上给出**一帧跳变**的力" —— 那个问题改用**低通滤波**
## 解决（见 `TestField` 的 `SUSP_FORCE_FILTER_SECONDS`），所以这里回到零件固有参数。
## （上面三个相对量还留在解析表里，但不参与计算；老文件写了也不会报错。）
func resolved_suspension(_wheel_load: float, _wheel_mass: float) -> Dictionary:
	# ⚠️ 只有**上限**跟车重走（安全阀），刚度/阻尼仍然是零件固有值：
	# 实测（tools/probe_flat.gd，230 kg 的车）—— 把 `wheel_suspension_max_force` 当绝对值用
	# 时，它是该车单轮静态负载的 **66 倍**，落地后**稳态**就在给这么大的力，小车直接飞，
	# 低通滤波也无能为力（滤波只削尖峰，不动稳态）。所以：
	#   * `wheel_stiffness` / `wheel_damper_*`：绝对值，**你调的手感，不动**；
	#   * `wheel_support_multiple > 0`：上限 = 该轮静态负载 × 它（推荐 4）；
	#   * 不写（=0）：退回 `wheel_suspension_max_force` 绝对值（老部件文件照旧）。
	var max_force := wheel_suspension_max_force
	if wheel_support_multiple > 0.0:
		max_force = minf(max_force, _wheel_load * wheel_support_multiple)
	return {
		"stiffness": wheel_stiffness,
		"damper_c": wheel_damper_compression,
		"damper_r": wheel_damper_relaxation,
		"max_force": max_force,
	}


## 最终用于模拟的抓地力（库仑摩擦系数 mu）：`wheel_mu` > 0 就直接用它，
## 否则按 `wheel_friction × wheel_mu_per_friction` 换算、用 `wheel_mu_max` 夹上限。
## 测试场调这个，别自己再算一遍 —— 老版本把上限写死在 1.2，导致 `wheel_friction`
## 调到 20 以上完全没反应（5000 × 0.06 = 300 → 1.2），"调了像没调"就是这个原因。
func resolved_wheel_mu() -> float:
	if wheel_mu > 0.0:
		return wheel_mu
	return clampf(wheel_friction * wheel_mu_per_friction, 0.0, wheel_mu_max)


## 松手回正用的角速度（度/秒）：写了 `wheel_steer_return_speed` 就用它（下限 1°/s，
## 免得 0 变成"永远回不了中"），没写就退回 `wheel_steer_speed`（老行为）。
func resolved_steer_return_speed() -> float:
	if wheel_steer_return_speed > 0.0:
		return maxf(1.0, wheel_steer_return_speed)
	return maxf(1.0, wheel_steer_speed)


## 附属子模型的网格（顶点已经按挂载偏移摆好，实例变换直接复用零件的）。
## 单独一份是因为测试场里它要挂在 VehicleWheel3D 上随悬挂浮动。
func build_sub_model() -> Dictionary:
	var volume := sub_model_volume()
	if volume == null:
		return {}
	var voxel_size := 1.0 / float(VoxVolume.VOXELS_PER_CUBE)
	var result := VoxMesher.build(volume, voxel_size, sub_model_offset())
	return {
		"mesh": result["mesh"],
		"material": voxel_material(),
		"quads": result["quads"],
		"tris": int(result["quads"]) * 2,
		"mode": "voxel",
	}


## 体素网格统一用的材质（本体 / 子模型 / 转塔子模型共用一份参数）。
static func voxel_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.85
	material.metallic = 0.0
	material.metallic_specular = 0.3
	return material


## 武器某个子模型（底座 / 支架 / 枪管）的网格。
## 顶点就在**零件本地坐标**上（子模型已经按作者画的位置摆好），所以
## "绕整体平移 -转点" 之后就能直接挂到转塔节点上转（见 scripts/turret.gd）。
func build_weapon_part(index: int) -> Dictionary:
	var volume := weapon_volume(index)
	if volume == null:
		return {}
	var voxel_size := 1.0 / float(VoxVolume.VOXELS_PER_CUBE)
	var result := VoxMesher.build(volume, voxel_size, Vector3.ZERO)
	return {
		"mesh": result["mesh"],
		"material": voxel_material(),
		"quads": result["quads"],
		"tris": int(result["quads"]) * 2,
		"mode": "voxel",
	}


## 网格在部件本地空间的包围盒（单位 = cube），也就是这个零件的**碰撞箱**。
## 附属子模型（轮体）也算进来 —— 轮体贴出去的部分一样会挡住别人。
## 带 `model_offset` 时可能超出 [0, cubes]（轮轴整体下移 3 像素）。
##
## 关键：必须按**实际模型的实心体素**算，不能拿 `cubes` 盒子当包围盒 ——
## 模型很少填满声明的盒子（轮轴声明 2x2x1，实际只有 19 像素高），
## 拿盒子算会凭空多出一截碰撞箱，表现成"上面明明空着却放不下零件"。
## 空模型（文件读不出来且没有 shape 兜底）才退回"盒子减 pad"的老算法。
func mesh_bounds() -> AABB:
	# 只在第一次算，之后直接返回 —— 千万别在这里调 build_volume()：
	# 解析形状的 build_volume() 每次都会重建整个体积（4096 体素），
	# 而 world_bounds() 一帧要问几百次，那就是"一瞄准就卡"的来源。
	# 模型文件换了的失效由 model_volume() 负责标脏（render/build 会走到那里）。
	if not _bounds_ready:
		var box := body_bounds()
		var sub := sub_model_volume()
		if sub != null:
			box = box.merge(tight_bounds(sub, sub_model_offset(), Vector3.ONE))
		_bounds = box
		_bounds_ready = true
	return _bounds


## **本体**（不含附属子模型）在本地空间的包围盒。
## 基准格（锚点）用它算：锚点必须落在零件自己真的有体素的那一格上。
func body_bounds() -> AABB:
	if not _body_ready:
		if weapon != "":
			# 武器零件：本体 = 全部子模型并起来 —— 直接用各子模型的**归一化盒子**合并（O(1)）。
			# ⚠️ 别走"建一块 48³ 体积再逐体素扫边界"那条路：`tight_bounds()` 要从空的那一侧
			# 一层层扫过去，实测单个零件就要 100~300 ms，武器一多进场就卡好几秒。
			var merged := AABB()
			var got_any := false
			for index in scene_models().size():
				var piece := weapon_sub_bounds(index)
				if piece.size.x <= 0.0 or piece.size.y <= 0.0 or piece.size.z <= 0.0:
					continue
				merged = piece if not got_any else merged.merge(piece)
				got_any = true
			_body = merged if got_any else _compute_mesh_bounds(build_volume())
		else:
			_body = _compute_mesh_bounds(build_volume())
		_body_ready = true
	return _body


## 第 `index` 个子模型在**零件本地**坐标里的包围盒（单位 = 格），O(1)。
## `.vox` 场景里每个子模型已经给了"归一化 bbox（size）+ 场景偏移（offset）"（单位 = 体素），
## 直接换算即可 —— 不用再去扫体积找边界。
func weapon_sub_bounds(index: int) -> AABB:
	var models := scene_models()
	if index < 0 or index >= models.size():
		return AABB()
	var model: Dictionary = models[index]
	var unit := float(VoxVolume.VOXELS_PER_CUBE)
	var offset: Vector3i = model.get("offset", Vector3i.ZERO)
	var size: Vector3i = model.get("size", Vector3i.ONE)
	return AABB(Vector3(offset) / unit, Vector3(size) / unit)


## **碰撞盒**用的包围盒：武器零件**不含枪管**（只取底座 + 支架）—— 见下面那段说明。
##
## ⚠️ 为什么不能直接用 `body_bounds()`（三件并起来的 AABB）：
## 枪管是**会转**的（水平 360° + 俯仰），而车体上的碰撞盒是**静止**的一块盒子。
## 枪管转走以后，那个盒子里剩下的就是**空气** —— 子弹会打在看不见的盒子上
## （用户报的："接近侧向射击时子弹撞到虚空上，还判到另一个炮台上，离炮台实际判定还很远"）。
## 底座不动、支架绕自己的中心转（AABB 几乎不变），所以碰撞盒只取这两件最稳：
## 子弹打到的就是**看得见的底座/支架**，不会再打进空气。
##
## 代价：**枪管不给子弹判定**（打枪管会穿过去）。想两全就得把枪管的碰撞盒做成
## "跟着 Turret 的 Yaw/Pitch 一起转"的独立受击盒（像轮子的轮胎受击盒那样），
## 那是另一处改动，等有需要再说。
func collision_bounds() -> AABB:
	if _collision_ready:
		return _collision
	if weapon != "turret":
		_collision = body_bounds()
		_collision_ready = true
		return _collision
	var box := AABB()
	var first := true
	for index in [0, weapon_yaw_model]:
		var piece := weapon_sub_bounds(index)
		if piece.size.x <= 0.0 or piece.size.y <= 0.0 or piece.size.z <= 0.0:
			continue
		box = piece if first else box.merge(piece)
		first = false
	_collision = body_bounds() if first else box
	_collision_ready = true
	return _collision


## 重心判定点：零件的**几何中心**（在本地空间，单位 = cube）。
## 只在第一次算（`mesh_bounds()` 本来就缓存），所以游戏里每帧问它也是 O(1)；
## 想微调质量分布可以在部件文件里写 `center = x y z`（单位 = 体素）覆盖掉。
func center_of_mass() -> Vector3:
	if center_overridden:
		return Vector3(center_override) / float(VoxVolume.VOXELS_PER_CUBE)
	return mesh_bounds().get_center()


func _compute_mesh_bounds(volume: VoxVolume) -> AABB:
	var unit := float(VoxVolume.VOXELS_PER_CUBE)
	var pad := Vector3i(
		maxi(0, -model_offset.x), maxi(0, -model_offset.y), maxi(0, -model_offset.z)
	)
	# 空体积退回"容器盒减 pad"，至少不会把碰撞箱算成 0
	var fallback := (Vector3(VoxVolume.VOXELS_PER_CUBE * cubes) - Vector3(pad)) / unit
	return tight_bounds(volume, -Vector3(pad) / unit, fallback)


## 某个体积的实心范围（单位 = cube），摆在本地的 `origin` 上。
## 整个体积是空的时候退回 `fallback_size`（默认 1 cube），不会返回 0 尺寸的盒子。
static func tight_bounds(volume: VoxVolume, origin: Vector3, fallback_size := Vector3.ONE) -> AABB:
	var unit := float(VoxVolume.VOXELS_PER_CUBE)
	var lo_voxel := Vector3i.ZERO
	var hi_voxel := Vector3i.ZERO  # 开区间上界（最后一个实心层 + 1）
	for axis in 3:
		var first := volume.outermost_layer(axis, false)
		var last := volume.outermost_layer(axis, true)
		if first < 0 or last < 0:
			return AABB(origin, fallback_size)
		lo_voxel[axis] = first
		hi_voxel[axis] = last + 1
	# 体积索引 -> 本地坐标：索引 v 落在 origin + v/16
	var lo := origin + Vector3(lo_voxel) / unit
	var hi := origin + Vector3(hi_voxel) / unit
	return AABB(lo, hi - lo)


func _parse_dirs(value: String, line_no: int) -> Array:
	var out := []
	for token in value.replace(",", " ").split(" ", false):
		var text := token.to_lower()
		var axis := -1
		if text.ends_with("x"):
			axis = 0
		elif text.ends_with("y"):
			axis = 1
		elif text.ends_with("z"):
			axis = 2
		if axis < 0:
			_warn("第 %d 行：连接面 '%s' 不认识（用 +x / -x / +y / -y / +z / -z）" % [line_no, token])
			continue
		var dir := Vector3i.ZERO
		dir[axis] = -1 if text.begins_with("-") else 1
		out.append(dir)
	return out


func has_connection_face(dir: Vector3i) -> bool:
	return connection_faces().has(dir)


## 默认连接点所在的面：最朝下的那个连接面（立方体与斜坡型三棱柱都是底面正方形）。
func default_connection_face() -> Vector3i:
	var chosen := Vector3i.ZERO
	var chosen_down := -99
	for dir in connection_faces():
		var down: int = -dir.y  # 越朝下越大
		if down > chosen_down:
			chosen = dir
			chosen_down = down
	return chosen


## 按指定渲染路线构建，不改动本体记录的路线。mode 用 RenderMode 的值。
func build_as(mode: int) -> Dictionary:
	var saved := render_mode
	render_mode = mode
	var result := build()
	render_mode = saved
	return result


func build_volume() -> VoxVolume:
	if not model_path.is_empty():
		var loaded := model_volume()
		if loaded != null:
			return loaded
		_warn("模型读不了：%s（退回用 shape 生成）" % model_path)
	var volume := VoxVolume.for_cubes(cubes)
	var body_index := volume.index_of_color(body_color)
	var edge_index := volume.index_of_color(edge_color)
	VoxShapes.apply(volume, shape, edge_band, body_index, edge_index)
	return volume


func occupied_cells(volume: VoxVolume) -> Array:
	var cells := []
	for z in range(maxi(1, cubes.z)):
		for y in range(maxi(1, cubes.y)):
			for x in range(maxi(1, cubes.x)):
				var cell := Vector3i(x, y, z)
				if volume.is_cell_occupied(cell):
					cells.append(cell)
	return cells


## 返回 {mesh, material, quads, tris, volume, mode, cells, texture, atlas_image}
func build() -> Dictionary:
	var volume := build_volume()
	var mode := render_mode
	if mode == RenderMode.TEXTURE:
		var cells := occupied_cells(volume)
		for cell in cells:
			if not volume.is_cell_full_cube(cell):
				_warn(
					"render = texture 只适用于全部由实心 cube 组成的部件；shape=%s 不满足，已退回 voxel 网格。"
					% shape
				)
				mode = RenderMode.VOXEL
				break
	if mode == RenderMode.TEXTURE:
		return _build_textured(volume)
	return _build_voxel(volume)


func build_atlas_image() -> Image:
	var volume := build_volume()
	var atlas := VoxFaceAtlas.build(volume, occupied_cells(volume))
	return atlas["image"]


func _build_voxel(volume: VoxVolume) -> Dictionary:
	var voxel_size := 1.0 / float(VoxVolume.VOXELS_PER_CUBE)
	# 体积比部件盒多留了 model_pad（用来容纳负偏移），网格原点要平移回去，
	# 模型才会落在"部件盒下方/左侧"的正确位置
	var origin := -Vector3(model_pad) * voxel_size
	var result := VoxMesher.build(volume, voxel_size, origin)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.85
	material.metallic = 0.0
	material.metallic_specular = 0.3
	var quads: int = result["quads"]
	return {
		"mesh": result["mesh"],
		"material": material,
		"quads": quads,
		"tris": quads * 2,
		"volume": volume,
		"mode": "voxel",
		"cells": [],
		"texture": null,
		"atlas_image": null,
	}


func _build_textured(volume: VoxVolume) -> Dictionary:
	var cells := occupied_cells(volume)
	var atlas := VoxFaceAtlas.build(volume, cells)
	var rows: int = atlas["rows"]
	var unit := float(VoxVolume.VOXELS_PER_CUBE)
	var voxel_size := 1.0 / unit
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := 0
	for r in range(rows):
		var cell: Vector3i = cells[r]
		for f in range(VoxMesher.FACES.size()):
			var face: Dictionary = VoxMesher.FACES[f]
			var n: Vector3i = face["n"]
			if volume.is_cell_occupied(cell + n):
				continue  # 部件内部的面不画
			_emit_textured_quad(st, cell, face, unit, voxel_size, VoxFaceAtlas.uv_rect(r, f, rows))
			quads += 1
	var material := StandardMaterial3D.new()
	material.albedo_texture = atlas["texture"]
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.roughness = 0.85
	material.metallic = 0.0
	material.metallic_specular = 0.3
	return {
		"mesh": st.commit(),
		"material": material,
		"quads": quads,
		"tris": quads * 2,
		"volume": volume,
		"mode": "texture",
		"cells": cells,
		"texture": atlas["texture"],
		"atlas_image": atlas["image"],
	}


static func _emit_textured_quad(
	st: SurfaceTool, cell: Vector3i, face: Dictionary, unit: float, voxel_size: float, uv: Rect2
) -> void:
	var n: Vector3i = face["n"]
	var u: Vector3i = face["u"]
	var v: Vector3i = face["v"]
	var d_axis := VoxMesher.axis_of(n)
	var u_axis := VoxMesher.axis_of(u)
	var v_axis := VoxMesher.axis_of(v)
	var base := cell * VoxVolume.VOXELS_PER_CUBE
	var origin := Vector3i.ZERO
	origin[d_axis] = base[d_axis] + (VoxVolume.VOXELS_PER_CUBE if n[d_axis] > 0 else 0)
	origin[u_axis] = base[u_axis]
	origin[v_axis] = base[v_axis]

	var corner := Vector3(origin) * voxel_size
	var du := Vector3(u) * (unit * voxel_size)
	var dv := Vector3(v) * (unit * voxel_size)
	var normal := Vector3(n)
	var uv_a := uv.position
	var uv_b := uv.position + Vector2(uv.size.x, 0.0)
	var uv_c := uv.position + uv.size
	var uv_d := uv.position + Vector2(0.0, uv.size.y)

	# 反序成三角形：与 VoxMesher 一致，配合 Godot 的顺时针正面约定。
	_add_textured_vertex(st, corner, normal, uv_a)
	_add_textured_vertex(st, corner + du + dv, normal, uv_c)
	_add_textured_vertex(st, corner + du, normal, uv_b)
	_add_textured_vertex(st, corner, normal, uv_a)
	_add_textured_vertex(st, corner + dv, normal, uv_d)
	_add_textured_vertex(st, corner + du + dv, normal, uv_c)


static func _add_textured_vertex(st: SurfaceTool, pos: Vector3, normal: Vector3, uv: Vector2) -> void:
	st.set_normal(normal)
	st.set_uv(uv)
	st.add_vertex(pos)


func _apply(key: String, value: String, line_no: int) -> void:
	match key:
		"name":
			display_name = value
		"shape":
			if VoxShapes.known_shapes().has(value):
				shape = value
			else:
				_warn("第 %d 行：未知形状 '%s'；可选 %s" % [
					line_no, value, ", ".join(VoxShapes.known_shapes()),
				])
		"cubes":
			var nums := _parse_ints(value)
			if nums.size() == 3 and nums[0] > 0 and nums[1] > 0 and nums[2] > 0:
				cubes = Vector3i(nums[0], nums[1], nums[2])
			else:
				_warn("第 %d 行：cubes 需要 3 个正整数（单位 = cube），收到 '%s'" % [line_no, value])
		"render":
			match value.to_lower():
				"texture":
					render_mode = RenderMode.TEXTURE
				"voxel":
					render_mode = RenderMode.VOXEL
				_:
					_warn("第 %d 行：render 只能是 texture 或 voxel，收到 '%s'" % [line_no, value])
		"body":
			body_color = _parse_color(value, body_color, line_no)
		"edge":
			edge_color = _parse_color(value, edge_color, line_no)
		"edge_band":
			var nums := _parse_ints(value)
			if nums.size() == 1 and nums[0] >= 1:
				edge_band = nums[0]
			else:
				_warn("第 %d 行：edge_band 需要 >= 1 的整数（单位 = 体素）" % line_no)
		"order":
			var nums := _parse_ints(value)
			if nums.size() == 1:
				order = nums[0]
			else:
				_warn("第 %d 行：order 需要一个整数" % line_no)
		"weight":
			var nums := _parse_floats(value)
			if nums.size() == 1 and nums[0] >= 0.0:
				weight_kg = nums[0]
			else:
				_warn("第 %d 行：weight 需要一个非负数字（单位 kg）" % line_no)
		"hp":
			var nums := _parse_ints(value)
			if nums.size() == 1 and nums[0] > 0:
				hp = nums[0]
			else:
				_warn("第 %d 行：hp 需要一个正整数" % line_no)
		"pp":
			var nums := _parse_ints(value)
			if nums.size() == 1 and nums[0] >= 0:
				pp = nums[0]
			else:
				_warn("第 %d 行：pp 需要一个非负整数" % line_no)
		"core":
			is_core = value.strip_edges().to_lower() in ["true", "yes", "1", "on"]
		"center":
			var nums := _parse_ints(value)
			if nums.size() == 3:
				center_override = Vector3i(nums[0], nums[1], nums[2])
				center_overridden = true
			else:
				_warn("第 %d 行：center 需要 3 个整数（单位 = 体素，相对零件本地原点）" % line_no)
		"wheel_engine_force":
			wheel_engine_force = _parse_float(value, wheel_engine_force, line_no, key, 0.0)
		"wheel_brake":
			wheel_brake = _parse_float(value, wheel_brake, line_no, key, 0.0)
		"wheel_max_speed":
			wheel_max_speed = _parse_float(value, wheel_max_speed, line_no, key, 0.1)
		"wheel_friction":
			wheel_friction = _parse_float(value, wheel_friction, line_no, key, 0.0)
		"wheel_steer_max":
			wheel_steer_max = _parse_float(value, wheel_steer_max, line_no, key, 0.0)
		"wheel_steer_speed":
			# 角速度下限 1°/s：写 0 会让方向永远回不了中（不想转向就写 wheel_steer_max = 0）
			wheel_steer_speed = _parse_float(value, wheel_steer_speed, line_no, key, 1.0)
		"wheel_steer_return_speed":
			# 回正角速度（度/秒）。0 = 跟着 wheel_steer_speed 走（见 resolved_steer_return_speed）
			wheel_steer_return_speed = _parse_float(
				value, wheel_steer_return_speed, line_no, key, 0.0
			)
		"wheel_radius":
			wheel_radius = _parse_float(value, wheel_radius, line_no, key, 0.0)
		"wheel_rest_length":
			wheel_rest_length = _parse_float(value, wheel_rest_length, line_no, key, 0.0)
		"wheel_suspension_travel":
			wheel_suspension_travel = _parse_float(value, wheel_suspension_travel, line_no, key, 0.0)
		"wheel_stiffness":
			wheel_stiffness = _parse_float(value, wheel_stiffness, line_no, key, 0.0)
		"wheel_ride_sag":
			wheel_ride_sag = _parse_float(value, wheel_ride_sag, line_no, key, 0.0)
		"wheel_damper_ratio":
			wheel_damper_ratio = _parse_float(value, wheel_damper_ratio, line_no, key, 0.0)
		"wheel_support_multiple":
			wheel_support_multiple = _parse_float(
				value, wheel_support_multiple, line_no, key, 0.0
			)
		"wheel_peak_force_car_weights":
			# 单轮力硬截断（倍车重）。0 = 不截断
			wheel_peak_force_car_weights = _parse_float(
				value, wheel_peak_force_car_weights, line_no, key, 0.0
			)
		"wheel_grip_factor":
			wheel_grip_factor = _parse_float(value, wheel_grip_factor, line_no, key, 0.0)
		"wheel_lat_pacejka":
			var nums := _parse_floats(value)
			if nums.size() == 4:
				wheel_lat_pacejka = nums
			else:
				_warn("第 %d 行：wheel_lat_pacejka 需要 4 个数 peak stiff curve shape" % line_no)
		"wheel_long_pacejka":
			var nums := _parse_floats(value)
			if nums.size() == 4:
				wheel_long_pacejka = nums
			else:
				_warn("第 %d 行：wheel_long_pacejka 需要 4 个数 peak stiff curve shape" % line_no)
		"wheel_suspension_max_force":
			wheel_suspension_max_force = _parse_float(
				value, wheel_suspension_max_force, line_no, key, 0.0
			)
		"wheel_damper_compression":
			wheel_damper_compression = _parse_float(
				value, wheel_damper_compression, line_no, key, 0.0
			)
		"wheel_damper_relaxation":
			wheel_damper_relaxation = _parse_float(
				value, wheel_damper_relaxation, line_no, key, 0.0
			)
		"wheel_mu":
			wheel_mu = _parse_float(value, wheel_mu, line_no, key, 0.0)
		"wheel_mu_per_friction":
			wheel_mu_per_friction = _parse_float(
				value, wheel_mu_per_friction, line_no, key, 0.0
			)
		"wheel_mu_max":
			wheel_mu_max = _parse_float(value, wheel_mu_max, line_no, key, 0.0)
		"wheel_slip_falloff":
			wheel_slip_falloff = _parse_float(value, wheel_slip_falloff, line_no, key, 0.0)
		"wheel_slip_ref":
			wheel_slip_ref = _parse_float(value, wheel_slip_ref, line_no, key, 0.01)
		"wheel_grip_gain":
			wheel_grip_gain = _parse_float(value, wheel_grip_gain, line_no, key, 0.0)
		"wheel_brake_gain":
			wheel_brake_gain = _parse_float(value, wheel_brake_gain, line_no, key, 0.0)
		"wheel_roll_gain":
			wheel_roll_gain = _parse_float(value, wheel_roll_gain, line_no, key, 0.0)
		"wheel_rays":
			var nums := _parse_ints(value)
			# 0 = 纯单射线模式（整圈射线全关，只剩悬挂那条）；3 以下没有意义但也允许
			if nums.size() == 1 and nums[0] >= 0:
				wheel_rays = nums[0]
			else:
				_warn("第 %d 行：wheel_rays 需要 >= 0 的整数（0 = 单射线模式）" % line_no)
		"wheel_ray_slack":
			wheel_ray_slack = _parse_float(value, wheel_ray_slack, line_no, key, 0.0)
		"wheel_sus_sector":
			wheel_sus_sector = _parse_float(value, wheel_sus_sector, line_no, key, -1.0)
		"wheel_ray_offset":
			# 侧向偏移（格）：0 = 轮胎中缝；正值往车外挪（判断内外由测试场按轮子位置定）
			wheel_ray_offset = _parse_float(value, wheel_ray_offset, line_no, key, 0.0)
		"wheel_anti_roll_tilt":
			# 单位是**度**（横向 1 g 时允许的侧倾角），0 = 关掉防翻
			wheel_anti_roll_tilt_deg = _parse_float(
				value, wheel_anti_roll_tilt_deg, line_no, key, 0.0
			)
		"wheel_anti_roll_damping":
			wheel_anti_roll_damping = _parse_float(
				value, wheel_anti_roll_damping, line_no, key, 0.0
			)
		"weapon":
			var kind := value.strip_edges().to_lower()
			if kind in ["", "none", "-"]:
				weapon = ""
			elif kind == "turret":
				weapon = "turret"
			else:
				_warn("第 %d 行：weapon 目前只认 turret（或 none），收到 '%s'" % [line_no, value])
		"weapon_yaw_model":
			var nums := _parse_ints(value)
			if nums.size() == 1 and nums[0] >= 0:
				weapon_yaw_model = nums[0]
			else:
				_warn("第 %d 行：weapon_yaw_model 需要 >= 0 的整数（子模型序号，0 = 底座）" % line_no)
		"weapon_pitch_model":
			var nums := _parse_ints(value)
			if nums.size() == 1 and nums[0] >= 0:
				weapon_pitch_model = nums[0]
			else:
				_warn("第 %d 行：weapon_pitch_model 需要 >= 0 的整数（子模型序号）" % line_no)
		"weapon_yaw_limit":
			# 射界按整角存：360 = 全向；写大了夹到 360，写负了夹到 0（不能转）
			weapon_yaw_limit = clampf(
				_parse_float(value, weapon_yaw_limit, line_no, key, 0.0), 0.0, 360.0
			)
		"weapon_pitch_min":
			weapon_pitch_min = clampf(
				_parse_float(value, weapon_pitch_min, line_no, key, -180.0), -180.0, 180.0
			)
		"weapon_pitch_max":
			weapon_pitch_max = clampf(
				_parse_float(value, weapon_pitch_max, line_no, key, -180.0), -180.0, 180.0
			)
		"weapon_projectile":
			var kind := value.strip_edges().to_lower()
			if kind in ["bullet", "none", ""]:
				weapon_projectile = "bullet" if kind != "" else "none"
			else:
				_warn("第 %d 行：weapon_projectile 目前只认 bullet，收到 '%s'" % [line_no, value])
		"weapon_muzzle_speed":
			weapon_muzzle_speed = _parse_float(value, weapon_muzzle_speed, line_no, key, 0.0)
		"weapon_damage":
			weapon_damage = _parse_float(value, weapon_damage, line_no, key, 0.0)
		"weapon_rpm":
			# 0 = 不能开火（当成没装武器）；否则射速
			weapon_rpm = _parse_float(value, weapon_rpm, line_no, key, 0.0)
		"weapon_spread":
			weapon_spread = clampf(
				_parse_float(value, weapon_spread, line_no, key, 0.0), 0.0, 90.0
			)
		"weapon_traverse_speed":
			weapon_traverse_speed = _parse_float(
				value, weapon_traverse_speed, line_no, key, 0.0
			)
		"weapon_energy_cost":
			weapon_energy_cost = _parse_float(value, weapon_energy_cost, line_no, key, 0.0)
		"weapon_projectile_life":
			# 夹在 [0.05, 120] 秒：0 会让子弹一出膛就死（没意义），太大就是"永不消失"（卡爆）
			weapon_projectile_life = clampf(
				_parse_float(value, weapon_projectile_life, line_no, key, 0.0), 0.05, 120.0
			)
		"energy_max":
			energy_max = _parse_float(value, energy_max, line_no, key, 0.0)
		"energy_regen":
			energy_regen = _parse_float(value, energy_regen, line_no, key, 0.0)
		"model":
			model_path = value
		"connections":
			connections_set = true
			var text := value.strip_edges().to_lower()
			if text.is_empty() or text == "none" or text == "-":
				connection_override = []
			else:
				connection_override = _parse_dirs(value, line_no)
		"wheel_body":
			wheel_body = value
		"wheel_offset":
			var nums := _parse_ints(value)
			if nums.size() == 3:
				wheel_offset = Vector3i(nums[0], nums[1], nums[2])
			else:
				_warn("第 %d 行：wheel_offset 需要 3 个整数（单位 = 体素，可负）" % line_no)
		"model_offset":
			var nums := _parse_ints(value)
			if nums.size() == 3:
				model_offset = Vector3i(nums[0], nums[1], nums[2])
			else:
				_warn("第 %d 行：model_offset 需要 3 个整数（单位 = 体素，可负）" % line_no)
		"physics":
			var role := value.to_lower()
			if role == "wheel" or role == "":
				physics = role
			else:
				_warn("第 %d 行：physics 只支持 wheel（或留空），收到 '%s'" % [line_no, value])
		_:
			_warn("第 %d 行：未知键 '%s'，已忽略" % [line_no, key])


func _parse_color(value: String, fallback: Color, line_no: int) -> Color:
	var text := value.strip_edges()
	if text.is_empty():
		return fallback
	if not text.begins_with("#"):
		text = "#" + text
	if not Color.html_is_valid(text):
		_warn("第 %d 行：颜色 '%s' 无法解析，保持 %s" % [line_no, value, fallback.to_html(false)])
		return fallback
	return Color.html(text)


static func _parse_ints(value: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	var cleaned := value.replace(",", " ").replace("\t", " ")
	for token in cleaned.split(" ", false):
		out.append(int(token))
	return out


static func _parse_floats(value: String) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var cleaned := value.replace(",", " ").replace("\t", " ")
	for token in cleaned.split(" ", false):
		out.append(float(token))
	return out


## 解析一个非负数字键（轮子参数都是这种），解析不了就保留原值并记一条警告。
func _parse_float(value: String, fallback: float, line_no: int, key: String, minimum: float) -> float:
	var text := value.strip_edges()
	if text.is_valid_float():
		var parsed := float(text)
		if parsed >= minimum:
			return parsed
		_warn("第 %d 行：%s 不能小于 %s" % [line_no, key, str(minimum)])
		return fallback
	_warn("第 %d 行：%s 需要一个数字，收到 '%s'" % [line_no, key, value])
	return fallback


## 去掉行尾注释（" # ..."）。颜色可以带 #，所以只在 # 前面有空白时才当作注释。
static func strip_comment(line: String) -> String:
	var i := line.find(" #")
	if i >= 0:
		return line.substr(0, i)
	return line


func _warn(message: String) -> void:
	if not warnings.has(message):
		warnings.append(message)
