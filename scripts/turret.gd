@tool
class_name Turret
extends Node3D

## 转塔（武器）：一个部件里的三个子模型 —— 底座（固定）+ 支架（相对底座水平转）+
## 枪管（相对支架俯仰）。
##
## 节点层级（本节点挂在**底盘**下面，自身变换 = 零件的摆放变换）：
##
##     Turret            ← 底座网格（不动）
##       └── Yaw         ← 位置 = 转点，只改 basis（水平转）
##             └── Pitch ← 位置 = 0（同一个转点），只改 basis（俯仰）
##                   └── 支架 / 枪管网格（往 -转点 平移过，就相对转点了）
##
## 因为两个节点都摆在**转点**上、旋转天然绕节点自己的原点，所以只需要写两个 basis ——
## 不用自己拼"绕世界某点转"的变换，也不会把零件甩到别处。
##
## 两条轴都过转点（`PartDef.weapon_pivot()` 推出来的）：
##   * 水平转 = 绕零件本地 **+Y**；
##   * 俯仰   = 绕枪管的横向轴（垂直于枪管的那根水平轴）。
## 所以枪管转的永远是它自己的轴线，枪口不画圈。
##
## 射界：水平 ±`wheel_yaw_limit`/2（360 = 全向，不夹）、俯仰 `weapon_pitch_min`~`max`。
## **角度一律走最短路径**（用带符号的夹角算，跨 ±180° 也是 20° 就是 20°，不绕远）。

var part_id := ""
var yaw_model := 1
var pitch_model := 2
var yaw_limit_deg := 360.0
var pitch_min_deg := -5.0
var pitch_max_deg := 35.0
var traverse_speed_deg := 60.0   # 炮塔最高转速（度/秒），水平、俯仰共用
## 开火参数（都在部件文件里，速度已从 m/s 换算成格/秒）
var projectile := "bullet"       # 射弹类型（目前只有 bullet）
var muzzle_speed := 0.0          # 子弹初速度（格/秒）
var damage := 0.0
var spread_deg := 0.0
var energy_cost := 0.0
var projectile_life := 8.0       # 弹丸寿命（秒），见部件文件的 weapon_projectile_life
var fire_interval := INF         # 两发之间的秒数（rpm 换算），INF = 不能开火
## 子弹从**枪口沿枪轴再外推**多少格生成：枪口正好贴在模型的面上，
## 不外推的话第一段射线会立刻打到自己车体的碰撞盒（用户定的"沿轴线向正方向补一格"）。
## ⚠️ 2026-10-14 从 1.0 收到 0.05：那 1 格是**射线完全覆盖不到的死区**（子弹的连续检测
## 从生成点才开始），于是"离枪口三格以内的零件"打不中、看着像穿透（用户报的）。
## 收小之后不用再担心自吃：武器的碰撞盒**不含枪管**（见 `PartDef.collision_bounds()`），
## 枪口本来就在自己的碰撞盒外面；留 0.05 只是防浮点擦边。
const MUZZLE_PAD := 0.05
## 枪口闪光持续时间（秒）；火舌从枪口再往外伸 `FLASH_REACH` 格，闪完直接不画。
const FLASH_TIME := 0.07
## 火舌从枪口往外的伸出量（格）
const FLASH_REACH := 0.25

var _yaw_node: Node3D
var _pitch_node: Node3D
var _pivot := Vector3.ZERO        # 转点（零件本地，cube）
var _muzzle := Vector3.ZERO       # 枪口点（零件本地，cube）
var _barrel_dir := Vector3.FORWARD  # 枪口方向（零件本地；静止时枪管朝哪儿）
var _pitch_axis := Vector3.RIGHT    # 俯仰轴（零件本地，垂直于枪管）
var _pitch_sign := 1.0              # 让"正的俯仰角 = 抬枪"的符号
var _yaw := 0.0                     # 当前角度（弧度；调试/HUD 用）
var _pitch := 0.0
var _cooldown := 0.0                # 开火冷却（秒）
var _flash: MeshInstance3D          # 枪口闪光（挂在 Pitch 节点上，见 setup）
var _flash_left := 0.0              # 闪光还剩多久
var _ready_ok := false
## ── 真实射界（用户 2026-10-14 的设计）────────────────────────────────────
## 把射界（水平 × 俯仰的**角网格**）切成 `ARC_SECTORS` × `ARC_BANDS` 格，
## 每格判一次"枪管摆到那个角度会不会压到别的零件"（几何，见 `_pose_clips()`）；
## 再 **flood fill** 出**和初始枪口朝向连通**的那一片 —— 那才是**真实射界**。
##   * 中间被挡、绕过去又空出来的方向**不算**：枪管转过去会穿过那个零件
##     （长管武器最明显，视觉上会插进车体里）。
##   * **每台转塔各算各的** —— 一把武器被挡不会连坐别的武器（用户报的）。
##   * 零件被打掉之后射界会变大 → 重新算（`TestField._refresh_turret_arcs()`）。
const ARC_SECTORS := 16      # 水平方向切成几个扇区（用户建议先 16）
const ARC_BANDS := 8         # 俯仰方向切成几带
## 判据是**枪口到转点那条线段**（用户 2026-10-14 要求简化）：线段给这么粗的余量，
## 约等于枪管半宽（1 体素 = 0.0625 格）。写 0 = 纯射线（最省、也最宽松）。
const ARC_SEGMENT_PAD := 0.0625
## 非空 = 当前朝向不在真实射界里（HUD 显示 / 开火前自检）
var arc_blocked_by := ""
## 枪口相对**转点**的偏移（零件本地坐标，单位 = 格）：判射界时就转这一条线段。
var _muzzle_offset := Vector3.ZERO
var _arc_free := []          # 下标 sector * ARC_BANDS + band -> 这一格几何上不穿模
var _arc_reach := []         # 同上，但只标"和初始朝向连通"的那一片 = 真实射界
var _arc_ready := false
var _arc_blocked_by := {}    # 格子 -> 挡住它的零件名（调试 / 原因）


## 建好转塔节点。place = 零件在**底盘坐标**里的摆放变换（BuildGrid.cell_transform）。
## 返回 "" 表示没问题，否则是没法转的原因（调用方去告警 / 显示）。
func setup(def: PartDef, place: Transform3D, library: PartLibrary) -> String:
	part_id = def.id
	yaw_model = def.weapon_yaw_model
	pitch_model = def.weapon_pitch_model
	yaw_limit_deg = def.weapon_yaw_limit
	pitch_min_deg = def.weapon_pitch_min
	pitch_max_deg = def.weapon_pitch_max
	traverse_speed_deg = def.weapon_traverse_speed
	projectile = def.weapon_projectile
	muzzle_speed = def.muzzle_speed_cubes()
	damage = def.weapon_damage
	spread_deg = def.weapon_spread
	energy_cost = def.weapon_energy_cost
	projectile_life = def.weapon_projectile_life
	fire_interval = def.fire_interval_seconds()
	name = "Turret_%s" % def.id
	transform = place
	var axis_info := def.weapon_barrel_axis()
	if axis_info.is_empty():
		return "读不出枪管模型（子模型 %d）" % pitch_model
	_barrel_dir = axis_info["dir"]
	_muzzle = axis_info["muzzle"]
	var pivot_info := def.weapon_pivot()
	_pivot = pivot_info["pivot"]
	# 俯仰轴 = 垂直于枪管的另一根水平轴；符号保证"正俯仰 = 抬枪"
	var axis: int = axis_info["axis"]
	_pitch_axis = Vector3.RIGHT if axis == 2 else Vector3.FORWARD
	_pitch_sign = pitch_sign_for(_pitch_axis, _barrel_dir)
	# 底座：本体网格直接贴在 Turret 上（它不动）
	_attach_mesh(self, library, 0, Vector3.ZERO)
	_yaw_node = Node3D.new()
	_yaw_node.name = "Yaw"
	_yaw_node.position = _pivot
	add_child(_yaw_node)
	_pitch_node = Node3D.new()
	_pitch_node.name = "Pitch"
	_pitch_node.position = Vector3.ZERO
	_yaw_node.add_child(_pitch_node)
	# 支架 / 枪管的网格：顶点是零件本地坐标，节点在转点上，所以整体平移 -转点
	_attach_mesh(_yaw_node, library, yaw_model, -_pivot)
	_attach_mesh(_pitch_node, library, pitch_model, -_pivot)
	# 枪口闪光：**挂在 Pitch（枪管）节点上** —— 结构上就是枪管的子节点，
	# 所以它必然跟着枪管一起转（上一版是"世界坐标里的池化小球"：位置算得没错，
	# 但球是对称的、又和枪管没有父子关系，看着就是"火光没跟着枪口转向"，用户报的）。
	# 这里做成一截**沿枪管伸出的火舌**，方向一眼可见。
	_flash = MeshInstance3D.new()
	_flash.name = "MuzzleFlash"
	var flame := BoxMesh.new()
	flame.size = Vector3(0.16, 0.16, 0.5)   # 长轴 = 本地 z
	_flash.mesh = flame
	var flame_material := StandardMaterial3D.new()
	flame_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flame_material.albedo_color = Color(1.0, 0.95, 0.7)
	_flash.material_override = flame_material
	_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 位置：枪口（零件本地）减去转点（Pitch 节点的原点在转点上）+ 沿枪轴往外伸一点
	_flash.transform = Transform3D(
		Basis.looking_at(_barrel_dir, Vector3.UP),
		(_muzzle - _pivot) + _barrel_dir * FLASH_REACH
	)
	_flash.visible = false
	_pitch_node.add_child(_flash)
	# 判射界只需要一条线：**转点 → 枪口**（相对转点存下来，判定时按角度转一下）
	_muzzle_offset = _muzzle - _pivot
	_ready_ok = true
	if not bool(pivot_info["ok"]):
		return str(pivot_info["reason"])
	return ""


## 开火前自检：**枪械（支架 + 枪管）当前姿态下有没有压在别的零件上**。
##
## 重算真实射界。`part_boxes` = 底盘上每个零件的包围盒（下标 = 零件下标），
## 每项 {box: AABB（**底盘本地**坐标）, name: String}；自己那一件（`part_index`）跳过。
## 进场时算一次，零件被打掉之后再算（`TestField._refresh_turret_arcs()`）。
func rebuild_arc(part_boxes: Array) -> void:
	_arc_free = []
	_arc_reach = []
	_arc_blocked_by = {}
	_arc_ready = false
	if not _ready_ok:
		return
	# ⚠️ 下标口径是 `sector * ARC_BANDS + band`（见 `_arc_cell_of()`）——
	# 按循环顺序 append 会写成"带优先"，整张角网格就被转置了（踩过）。
	_arc_free.resize(ARC_SECTORS * ARC_BANDS)
	_arc_free.fill(false)
	# 预筛：只有**转点附近**的零件才可能被枪管碰到（枪管最远伸到 |枪口-转点|）。
	# 一辆车 200 多个零件，不筛的话 128 个格子 × 全表 = 每次重算几万次比对。
	# ⚠️ 距离必须在**同一套坐标**里比：`part_boxes` 是**底盘本地**的，所以转点也要先用
	# `transform` 搬到车身系（`transform * _pivot`）。踩过的坑：直接拿**零件本地**的 `_pivot`
	# 去比 → 离原点远的转塔会把**所有**障碍都筛掉、射界变成"全通"，
	# 表现出来就是"并排八个机枪一起转，靠右几台正常被挡、靠左几台横穿别人"（用户报的）。
	var pivot_local: Vector3 = transform * _pivot
	var near := []
	for i in part_boxes.size():
		if i == int(get_meta("part_index", -1)):
			continue
		var entry: Dictionary = part_boxes[i]
		var box: AABB = entry.get("box", AABB())
		if box.size.x <= 0.001 or box.size.y <= 0.001 or box.size.z <= 0.001:
			continue
		var centre := box.get_center()
		if centre.distance_to(pivot_local) > _gun_reach() + box.size.length() * 0.5 + 0.1:
			continue
		near.append(entry)
	for band in ARC_BANDS:
		var pitch := _arc_pitch_of(band)
		for sector in ARC_SECTORS:
			var hit := _pose_clips(_arc_yaw_of(sector), pitch, near)
			var cell := sector * ARC_BANDS + band
			_arc_free[cell] = hit.is_empty()
			if not hit.is_empty():
				_arc_blocked_by[cell] = hit
	# 连通域：从**初始枪口朝向**（yaw = 0、pitch = 0）那一格 flood fill
	_arc_reach.resize(_arc_free.size())
	_arc_reach.fill(false)
	var start := _arc_cell_of(0.0, 0.0)
	if start >= 0 and bool(_arc_free[start]):
		var queue := [start]
		_arc_reach[start] = true
		while not queue.is_empty():
			var cell: int = queue.pop_back()
			for next in _arc_neighbours(cell):
				if bool(_arc_reach[next]) or not bool(_arc_free[next]):
					continue
				_arc_reach[next] = true
				queue.append(next)
	_arc_ready = true


## 当前朝向在不在真实射界里（开火前自检）；没算过就当"可以"（别把枪憋死）
func arc_allows_current() -> bool:
	if not _arc_ready:
		return true
	return arc_allows(_yaw, _pitch)


## 真实射界算出来了没有（测试场用它做诊断：算不出来 = 这条枪形同没装转塔）
func arc_ready() -> bool:
	return _arc_ready


func arc_allows(yaw_rad: float, pitch_rad: float) -> bool:
	var cell := _arc_cell_of(yaw_rad, pitch_rad)
	return cell >= 0 and bool(_arc_reach[cell])


## 真实射界里"能打的方向"占整个射界的比例（HUD / 调试用；没算过返回 1）
func arc_free_ratio() -> float:
	if not _arc_ready or _arc_reach.is_empty():
		return 1.0
	var open := 0
	for ok in _arc_reach:
		if bool(ok):
			open += 1
	return float(open) / float(_arc_reach.size())


## 当前朝向为什么不能在真实射界里（HUD 用）：挡住它的零件名，或"" 
func arc_reason() -> String:
	if not _arc_ready:
		return ""
	var cell := _arc_cell_of(_yaw, _pitch)
	if cell < 0:
		return "超出射界"
	if bool(_arc_reach[cell]):
		return ""
	var blocker := str(_arc_blocked_by.get(cell, ""))
	if not blocker.is_empty():
		return "枪管压在 %s 上" % blocker
	return "被挡在射界外（转过去会穿过零件）"


## 把目标角夹到真实射界里：**水平和俯仰各夹各的**，尽量靠近目标。
##
## ⚠️ 原来是"从当前姿态朝目标走直线，撞墙就停" —— 于是水平被挡时**俯仰也被一起冻住**
## （用户报的："枪械被左右障碍物挡住时，上下也被锁死"）。现在分两步：
##   ① 保持当前俯仰，先往目标水平角走，走到不能走为止；
##   ② 在那个水平角上，再往目标俯仰角走，走到不能走为止。
## 每一步都是"合法姿态之间连续移动"，所以不会跨过被挡的那一片（连通域语义不变），
## 但俯仰该动就动 —— 贴着障碍"顺着边滑"，尽可能接近瞄准位置。
func _clamp_to_arc(target_yaw: float, target_pitch: float) -> Vector2:
	if not _arc_ready or arc_allows(target_yaw, target_pitch):
		return Vector2(target_yaw, target_pitch)
	var steps := 16
	var yaw := _yaw
	for i in range(1, steps + 1):
		var probe := _yaw + (target_yaw - _yaw) * float(i) / float(steps)
		if not arc_allows(probe, _pitch):
			break
		yaw = probe
	var pitch := _pitch
	for i in range(1, steps + 1):
		var probe := _pitch + (target_pitch - _pitch) * float(i) / float(steps)
		if not arc_allows(yaw, probe):
			break
		pitch = probe
	return Vector2(yaw, pitch)


## 枪口离转点多远（格）：`rebuild_arc()` 预筛"附近零件"用。
func _gun_reach() -> float:
	return _muzzle_offset.length()


## **线段**有没有压在某个零件盒上：返回挡住的零件名（空 = 没挡）。
## 两处共用：真实射界（枪口→转点那条线）和"枪口贴脸"自吃判定（枪口→子弹生成点）。
## `skip_index >= 0` 时跳过那个下标（`part_boxes` 按零件下标对齐时用它排除自己）；
## `pad` = 给盒子加粗的余量（格）。`intersects_segment` 是纯数学，不碰场景树。
static func segment_blocker(
	from: Vector3, to: Vector3, part_boxes: Array, skip_index := -1, pad := 0.0
) -> String:
	for i in part_boxes.size():
		if i == skip_index:
			continue
		var entry: Dictionary = part_boxes[i]
		var box: AABB = entry.get("box", AABB())
		if box.size.x <= 0.001 or box.size.y <= 0.001 or box.size.z <= 0.001:
			continue
		var probe := box.grow(pad) if pad > 0.0 else box
		if probe.intersects_segment(from, to):
			return str(entry.get("name", "零件 %d" % i))
	return ""


## 枪管摆到 (yaw, pitch) 时压到别的零件没有。返回挡住它的零件名（空 = 没压）。
## 全在**底盘本地坐标**里算（用 `transform` 和本地包围盒），所以不依赖场景树。
##
## ⚠️ 判据就是**枪口→转点那条线段**（用户 2026-10-14 要求简化掉逐体素判定：
## 684 个体素 × 128 个格子 × 200 多个零件，进场会明显卡）。代价是"只擦着枪管侧面
## 过去的零件"不算挡 —— `ARC_SEGMENT_PAD` 给了 1 体素的余量，写 0 就是纯射线。
## `part_boxes` 里**不该**含自己那一件（`rebuild_arc()` 已经按 part_index 滤掉了）。
func _pose_clips(yaw_rad: float, pitch_rad: float, part_boxes: Array) -> String:
	if part_boxes.is_empty():
		return ""
	var spin := Basis(Vector3.UP, yaw_rad) * Basis(_pitch_axis, _pitch_sign * pitch_rad)
	var to_local := transform * Transform3D(spin, _pivot)
	return segment_blocker(
		to_local * Vector3.ZERO, to_local * _muzzle_offset, part_boxes, -1, ARC_SEGMENT_PAD
	)


## ── 角网格的坐标换算 ────────────────────────────────────────────────────
## yaw 满 360° 时网格绕成一圈（最后一格和第一格相邻）；有射界限制时只覆盖那段。
func _arc_yaw_of(sector: int) -> float:
	var step := _arc_yaw_span() / float(ARC_SECTORS)
	return _arc_yaw_min() + (float(sector) + 0.5) * step


func _arc_pitch_of(band: int) -> float:
	var lo := deg_to_rad(pitch_min_deg)
	var hi := deg_to_rad(pitch_max_deg)
	return lo + (float(band) + 0.5) * (hi - lo) / float(ARC_BANDS)


func _arc_yaw_min() -> float:
	if yaw_limit_deg >= 360.0 - 0.001:
		return -PI
	return -deg_to_rad(yaw_limit_deg) * 0.5


func _arc_yaw_span() -> float:
	if yaw_limit_deg >= 360.0 - 0.001:
		return TAU
	return deg_to_rad(yaw_limit_deg)


## 某个角度落在角网格的哪一格（超出射界返回 -1）
func _arc_cell_of(yaw_rad: float, pitch_rad: float) -> int:
	var span := _arc_yaw_span()
	var offset := wrapf(yaw_rad - _arc_yaw_min(), 0.0, span)
	var sector := int(floor(offset / span * float(ARC_SECTORS))) % ARC_SECTORS
	var lo := deg_to_rad(pitch_min_deg)
	var hi := deg_to_rad(pitch_max_deg)
	if hi - lo <= 0.0001:
		return -1
	if pitch_rad < lo - 0.0001 or pitch_rad > hi + 0.0001:
		return -1
	var band := int(floor((pitch_rad - lo) / (hi - lo) * float(ARC_BANDS)))
	band = clampi(band, 0, ARC_BANDS - 1)
	return sector * ARC_BANDS + band


## 相邻的格子：同一条带里左右相邻（**只有满 360° 时首尾才相接**），加上上/下一条带。
func _arc_neighbours(cell: int) -> Array:
	var sector := cell / ARC_BANDS
	var band := cell % ARC_BANDS
	var full := yaw_limit_deg >= 360.0 - 0.001
	var out := []
	for side in [-1, 1]:
		var next_sector: int = sector + int(side)
		if next_sector < 0 or next_sector >= ARC_SECTORS:
			if not full:
				continue          # 有射界限制时，两头**不相接**（差着 120° 呢）
			next_sector = (next_sector + ARC_SECTORS) % ARC_SECTORS
		out.append(next_sector * ARC_BANDS + band)
	if band + 1 < ARC_BANDS:
		out.append(sector * ARC_BANDS + band + 1)
	if band - 1 >= 0:
		out.append(sector * ARC_BANDS + band - 1)
	return out


func _attach_mesh(parent: Node3D, library: PartLibrary, index: int, offset: Vector3) -> void:
	var build := library.build_weapon(part_id, index)
	if build.get("mesh") == null:
		return
	var node := MeshInstance3D.new()
	node.name = "Model%d" % index
	node.mesh = build["mesh"]
	node.material_override = build["material"]
	node.transform = Transform3D(Basis(), offset)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(node)


## 朝世界坐标里的某个点转（点在天空里也没关系 —— 射线打不到时测试场会给一个远点）。
## `delta` 用来限制转速（度/秒，见 `traverse_speed_deg`）；要瞬间对准就传 0。
func update_aim(global_target: Vector3, delta: float) -> void:
	if not _ready_ok:
		return
	_tick_flash(delta)
	# 目标换算到**零件本地**：转点就是原点附近，于是两条轴就是本地 +Y / 横向轴
	var local_target := global_transform.affine_inverse() * global_target
	var to_target := local_target - _pivot
	if to_target.length() < 0.001:
		return
	var solved := solve_aim(to_target, _barrel_dir, yaw_limit_deg, pitch_min_deg, pitch_max_deg)
	var target_yaw: float = solved["yaw"]
	var target_pitch: float = solved["pitch"]
	# 真实射界：目标够不着就夹到"沿连通域能走到的最远处"（枪管不会穿过零件，
	# 但可以贴着障碍滑动）。射界没算过时原样返回。
	var clamped := _clamp_to_arc(target_yaw, target_pitch)
	target_yaw = clamped.x
	target_pitch = clamped.y
	if delta > 0.0:
		# 目标角先折到"离当前角最近的那个等价角"：跨 ±180° 也走最短路径，不绕远
		target_yaw = _yaw + wrapf(target_yaw - _yaw, -PI, PI)
		var step := deg_to_rad(traverse_speed_deg) * delta
		_yaw = move_toward(_yaw, target_yaw, step)
		_pitch = move_toward(_pitch, target_pitch, step)
	else:
		_yaw = target_yaw
		_pitch = target_pitch
	_apply_angles()


## 瞬间对准（调试 / 测试用；正式流程走 update_aim，会按转速限制慢慢跟）
func aim_at(global_target: Vector3) -> void:
	update_aim(global_target, 0.0)


## 开火闪光：每发调用一次（火舌"砰"地伸出来再缩回去）。
func flash() -> void:
	if _flash == null or not is_instance_valid(_flash):
		return
	_flash_left = FLASH_TIME
	_flash.visible = true
	_flash.scale = Vector3.ONE * 0.25


func _tick_flash(delta: float) -> void:
	if _flash == null or not is_instance_valid(_flash):
		return
	if _flash_left <= 0.0:
		_flash.visible = false
		return
	_flash_left -= delta
	if _flash_left <= 0.0:
		# 这一步跨过了闪光寿命：立刻灭掉（不能等下一帧才灭，否则会拖出一帧的残影）
		_flash.visible = false
		return
	var t := 1.0 - maxf(0.0, _flash_left) / FLASH_TIME
	var k := t / 0.35 if t < 0.35 else (1.0 - (t - 0.35) / 0.65)
	_flash.scale = Vector3(1.0, 1.0, maxf(0.15, k * 1.6))


func _apply_angles() -> void:
	_yaw_node.basis = Basis(Vector3.UP, _yaw)
	_pitch_node.basis = Basis(_pitch_axis, _pitch_sign * _pitch)


## 这一帧"按 rpm 该打几发"（会推进冷却；能量够不够由调用方判断）。
## 松开扳机时冷却照常走完，所以点按不会攒出一串子弹。
func ready_shots(delta: float) -> int:
	if fire_interval == INF or fire_interval <= 0.0:
		return 0
	_cooldown -= delta
	var shots := 0
	while _cooldown <= 0.0 and shots < 8:   # 一帧最多 8 发（rpm 写爆了也不会一帧刷屏）
		shots += 1
		_cooldown += fire_interval
	if _cooldown < 0.0:
		_cooldown = 0.0
	return shots


## 子弹生成点：枪口沿当前枪轴再外推 `MUZZLE_PAD` 格（见上面的注释）。
func fire_origin() -> Vector3:
	return muzzle_position() + barrel_direction() * MUZZLE_PAD


func reset_cooldown() -> void:
	_cooldown = 0.0


## 解算水平/俯仰角（弧度）。纯函数，测试直接打这个（test_weapon.gd）。
##
##   to_target  = 转点 → 目标（零件本地）
##   barrel_dir = 枪管静止时的朝向（零件本地，单位向量）
## 返回 {yaw, pitch, yaw_clamped, pitch_clamped}：
##   yaw   = 绕本地 +Y 的有符号夹角（**最短路径**：跨 ±180° 也只是一小段）
##   pitch = 相对水平面的仰角，夹在 [pitch_min, pitch_max]、以及 ±90° 之内
static func solve_aim(
	to_target: Vector3, barrel_dir: Vector3, yaw_limit_deg: float,
	pitch_min_deg: float, pitch_max_deg: float
) -> Dictionary:
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	# ⚠️ 水平距离要**先存下来**：下面 `flat` 会被归一化，归一化之后长度恒为 1，
	# 拿它当水平距离算俯仰 —— 远处的目标会一路顶到俯仰上限（踩过：斜向上 1.6° 的目标
	# 被算成 35°，枪口一直翘着）。
	var flat_length := flat.length()
	var barrel_flat := Vector3(barrel_dir.x, 0.0, barrel_dir.z)
	var yaw := 0.0
	if flat_length > 0.0001 and barrel_flat.length() > 0.0001:
		flat = flat.normalized()
		barrel_flat = barrel_flat.normalized()
		# 带符号夹角：绕 +Y 从枪管方向转到目标方向（右手法则），
		# 结果天然落在 (-π, π] —— 这就是"不要绕远"
		yaw = atan2(barrel_flat.cross(flat).y, barrel_flat.dot(flat))
	var yaw_clamped := false
	if yaw_limit_deg < 359.999:
		var half := deg_to_rad(yaw_limit_deg) * 0.5
		var limited := clampf(yaw, -half, half)
		yaw_clamped = not is_equal_approx(limited, yaw)
		yaw = limited
	var pitch := atan2(to_target.y, flat_length)
	var low := clampf(deg_to_rad(pitch_min_deg), -PI * 0.5, PI * 0.5)
	var high := clampf(deg_to_rad(pitch_max_deg), -PI * 0.5, PI * 0.5)
	if low > high:
		var swap := low
		low = high
		high = swap
	var pitch_clamped := pitch < low or pitch > high
	pitch = clampf(pitch, low, high)
	return {"yaw": yaw, "pitch": pitch, "yaw_clamped": yaw_clamped, "pitch_clamped": pitch_clamped}


## 枪口在世界里的位置 / 枪管当前朝向（开火和调试用）。
## 俯仰的旋转方向：绕 `pitch_axis` 正转到底是抬枪还是压枪，由"枪管 × 轴"的上下定，
## 这里算一次符号。枪管沿 +z 时俯仰轴是 +x，符号 = -1（绕 +x 正转是压枪）。
static func pitch_sign_for(pitch_axis: Vector3, barrel_dir: Vector3) -> float:
	return 1.0 if pitch_axis.cross(barrel_dir).dot(Vector3.UP) > 0.0 else -1.0


func muzzle_position() -> Vector3:
	if not _ready_ok:
		return global_position
	# 枪管跟着 Pitch 节点转；网格顶点是零件本地坐标，节点在转点上，所以整体减转点
	return _pitch_node.global_transform * (_muzzle - _pivot)


func barrel_direction() -> Vector3:
	if not _ready_ok:
		return -global_transform.basis.z
	return (_pitch_node.global_transform.basis * _barrel_dir).normalized()


## 当前角度（度），调试 / HUD 用。
func angles_deg() -> Vector2:
	return Vector2(rad_to_deg(_yaw), rad_to_deg(_pitch))


func is_ready() -> bool:
	return _ready_ok


func pivot_local() -> Vector3:
	return _pivot
