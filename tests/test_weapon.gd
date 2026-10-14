@tool
extends McpTestSuite

## 武器（转塔）：零件定义 / 转轴推导 / 瞄准解算。
##
## 这一套的全部要求都来自用户对轻机枪那三个物体（底座 / 支架 / 枪管）的描述：
##   * 一个零件、三个子模型、**一个基准格**（最底层中心格）、1 个朝下的连接点
##     （2026-10-14 换模型后底座缩成 1×1 的小底板，所以连接点就剩基准格那一格）；
##   * 枪管绕**自己的轴线**俯仰、支架绕竖直轴水平转，两条轴都过同一个转点（枪口不画圈）；
##   * 水平射界 360° = 全向，转的时候走最短路径（不绕远）。

const PART_DIR := "res://data/parts"
const MG_ID := "light_mg"


func suite_name() -> String:
	return "weapon"


func _library() -> PartLibrary:
	var library := PartLibrary.new()
	library.load_all(PART_DIR)
	return library


func _mg() -> PartDef:
	return _library().get_def(MG_ID)


## 浮点比较（测试框架只给了 assert_eq）。
func assert_almost_eq(actual: float, expected: float, tol: float, msg: String = "") -> void:
	assert_true(
		absf(actual - expected) <= tol,
		"%s（实际 %s，期望 %s）" % [msg, str(actual), str(expected)]
	)


func assert_vec_almost_eq(actual: Vector3, expected: Vector3, tol: float, msg: String = "") -> void:
	assert_true(
		(actual - expected).length() <= tol,
		"%s（实际 %s，期望 %s）" % [msg, str(actual), str(expected)]
	)


## 零件文件：三个子模型 + 武器字段都读进来了。
func test_light_mg_part_file_is_a_turret() -> void:
	var def := _mg()
	assert_true(def != null, "缺少部件 %s" % MG_ID)
	if def == null:
		return
	assert_eq(def.warnings.size(), 0, "不该有警告：%s" % str(def.warnings))
	assert_eq(def.weapon, "turret", "轻机枪应该是转塔")
	assert_eq(def.weapon_yaw_model, 1, "支架 = 1 号子模型")
	assert_eq(def.weapon_pitch_model, 2, "枪管 = 2 号子模型")
	# 注意：射界/俯仰这些是**用户手调的**，别把具体数写死（写了用户一改就红）——
	# 只验"范围合理、上下限没写反"
	assert_true(
		def.weapon_yaw_limit > 0.0 and def.weapon_yaw_limit <= 360.0,
		"水平射界应在 (0, 360]：%s" % def.weapon_yaw_limit
	)
	assert_true(
		def.weapon_pitch_min < def.weapon_pitch_max,
		"俯仰下限（%s）要小于上限（%s）" % [def.weapon_pitch_min, def.weapon_pitch_max]
	)
	assert_true(
		def.weapon_pitch_max <= 90.0 and def.weapon_pitch_min >= -90.0,
		"俯仰范围应在 ±90° 内：%s ~ %s" % [def.weapon_pitch_min, def.weapon_pitch_max]
	)
	assert_eq(def.cubes, Vector3i(3, 3, 3), "体积 = 3×3×3（模型是 48³ 的场景）")
	# 三个子模型都要能单独取出来（转塔要把它们挂到不同节点上）
	for index in range(3):
		assert_true(def.weapon_volume(index) != null, "%d 号子模型的体积读不出来" % index)
	assert_true(def.weapon_volume(9) == null, "越界的子模型序号应该返回空")


## 转轴推导：回转轴在底座中心、枪轴在**枪口那截**的中心、两者相交于转点。
## 具体数值是"当前模型"的（换模型会自动变），所以这里同时钉住**判据本身**：
## 枪轴高度**不能等于枪管包围盒中心**（机匣/护木挂在枪管下面，拿盒中心当转点枪口会画圈）。
func test_light_mg_turret_axes() -> void:
	var def := _mg()
	if def == null:
		return
	# 底座 16×16 体素、居中 → 回转轴在本地 (1.5, 1.5)
	var yaw := def.weapon_yaw_center()
	assert_true(absf(yaw.x - 1.5) < 0.01 and absf(yaw.y - 1.5) < 0.01, "回转轴应在底座中心：%s" % str(yaw))
	# 枪口那截的截面中心 = 本地 x 1.5、高 0.8125（13 体素），方向 +z
	var axis := def.weapon_barrel_axis()
	assert_true(not axis.is_empty(), "枪管轴线推不出来")
	if axis.is_empty():
		return
	assert_eq(int(axis["axis"]), 2, "枪管沿本地 z 伸展")
	assert_vec_almost_eq(axis["dir"], Vector3(0, 0, 1), 0.001, "枪口朝本地 +z")
	assert_almost_eq(float(axis["lateral"]), 1.5, 0.01, "枪轴横向位置 = 底座中心")
	assert_almost_eq(float(axis["height"]), 0.8125, 0.01, "枪轴高度 = 枪口那截的中心")
	# 枪口点 = 枪管最前一层的**外面**：x/y 必须落在枪轴上（枪口才不会画圈），
	# 而且应当**顶到体积前脸**附近（容 1 体素 = 0.0625 格，模型摆位的余量）。
	var muzzle: Vector3 = axis["muzzle"]
	assert_almost_eq(muzzle.x, float(axis["lateral"]), 0.001, "枪口的横向位置 = 枪轴")
	assert_almost_eq(muzzle.y, float(axis["height"]), 0.001, "枪口的高度 = 枪轴")
	assert_true(
		absf(muzzle.z - float(def.cubes.z)) <= 0.0625 + 0.001,
		"枪口要顶到体积前脸：枪口 z = %.4f，体积深 %d 格" % [muzzle.z, def.cubes.z]
	)
	# ★ 这条才是这段推导的意义：枪轴高度**不是**枪管包围盒中心
	var barrel := def.weapon_volume(def.weapon_pitch_model)
	assert_true(barrel != null, "枪管子模型要读得出来")
	if barrel != null:
		var box := PartDef.tight_bounds(barrel, Vector3.ZERO, Vector3.ONE)
		var box_height := box.position.y + box.size.y * 0.5
		assert_true(
			absf(float(axis["height"]) - box_height) > 0.05,
			"枪轴高度必须取枪口那截的中心，不能拿包围盒中心（轴 %.3f / 盒中心 %.3f）"
				% [float(axis["height"]), box_height]
		)
	# 转点 = 两条轴的交点
	var pivot := def.weapon_pivot()
	assert_true(bool(pivot["ok"]), "转点应该推得出来：%s" % str(pivot.get("reason", "")))
	assert_vec_almost_eq(pivot["pivot"], Vector3(1.5, 0.8125, 1.5), 0.01, "转点 = 枪轴与回转轴交点")


## 基准格 + 连接点：一个基准格（最底层中心格）、**只有它那一格**朝下有连接点。
## 2026-10-14 换模型后底座从 44×44 的十字板变成 16×16 的小底板：
## 原来十字上那 5 格（露出 194~256 体素）现在只剩中心一格，四个邻格和四个角都是 0。
func test_light_mg_anchor_and_the_single_downward_connection() -> void:
	var library := _library()
	var def: PartDef = library.get_def(MG_ID)
	if def == null:
		return
	assert_eq(def.anchor_cell(), Vector3i(1, 0, 1), "基准格 = 最底层中心格")
	assert_eq(def.connection_faces(), [Vector3i(0, -1, 0)], "只有底面有连接点")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var place := BuildGrid.cell_transform(def, Vector3i.ZERO, Basis())
	var down := Vector3i(0, -1, 0)
	# 基准格那一格：整面露出（1×1 格 = 256 体素，判据 ≥ 100）
	assert_true(
		grid.claims_face(def, Basis(), place, Vector3i(1, 0, 1), down),
		"基准格 (1,0,1) 应该是那个连接点"
	)
	# 底板只有 1×1，所以四个邻格 + 四个角**一个体素都没露**，都不是连接点
	for cell in [
		Vector3i(0, 0, 1), Vector3i(2, 0, 1), Vector3i(1, 0, 0), Vector3i(1, 0, 2),
		Vector3i(0, 0, 0), Vector3i(2, 0, 0), Vector3i(0, 0, 2), Vector3i(2, 0, 2),
	]:
		assert_false(
			grid.claims_face(def, Basis(), place, cell, down),
			"%s 不该有连接点（底板只有基准格那一格）" % str(cell)
		)


## 摆到别人身上时，落子的是**基准格**（不是体积角格）——3×3×3 的零件最容易踩这个坑。
func test_turret_places_by_its_anchor_cell() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var def: PartDef = library.get_def(MG_ID)
	if def == null:
		return
	var hit_cell := Vector3i(3, 4, 5)
	for hit_dir in VoxShapes.AXIS_DIRS:
		for roll in range(4):
			var basis := BuildGrid.candidate_basis(def, -hit_dir, roll)
			var transform := BuildGrid.placement_transform(def, hit_cell, hit_dir, basis)
			var cell := BuildGrid.origin_cell_of(def, basis, transform)
			assert_eq(
				grid.anchor_cell_from(def, transform, basis),
				hit_cell + hit_dir,
				"轻机枪命中 %s（roll %d）时基准格应落在相邻格" % [str(hit_dir), roll]
			)
			assert_true(
				transform.is_equal_approx(BuildGrid.cell_transform(def, cell, basis)),
				"轻机枪命中 %s（roll %d）的摆放变换应与 AABB 对齐形式一致" % [str(hit_dir), roll]
			)


## 瞄准解算：最短路径、射界夹紧、俯仰夹紧。360° = 不夹，只走最短路径。
func test_turret_aim_solves_shortest_path_and_limits() -> void:
	var barrel := Vector3(0, 0, 1)
	# ① 360°：转到 ±170° 都是走最近的那边（不是绕 340°）
	var right := Turret.solve_aim(Vector3(0.1736, 0, -0.9848), barrel, 360.0, -90.0, 90.0)
	assert_almost_eq(rad_to_deg(right["yaw"]), 170.0, 0.5, "偏 +170° 应该就是 +170°")
	assert_false(bool(right["yaw_clamped"]), "360° 射界不该夹")
	var left := Turret.solve_aim(Vector3(-0.1736, 0, -0.9848), barrel, 360.0, -90.0, 90.0)
	assert_almost_eq(rad_to_deg(left["yaw"]), -170.0, 0.5, "偏 -170° 应该就是 -170°")
	# ② 射界 120° = 以正前方为中心 ±60°：90° 的目标夹到 60°
	var limited := Turret.solve_aim(Vector3(1, 0, 0), barrel, 120.0, -90.0, 90.0)
	assert_almost_eq(rad_to_deg(limited["yaw"]), 60.0, 0.5, "超出射界要夹到边缘")
	assert_true(bool(limited["yaw_clamped"]), "夹了要标记出来")
	# ③ 俯仰：抬 78° / 压 45° 都夹回 [-5°, +35°]
	var up := Turret.solve_aim(Vector3(0, 1, 0.2), barrel, 360.0, -5.0, 35.0)
	assert_almost_eq(rad_to_deg(up["pitch"]), 35.0, 0.5, "抬枪上限")
	assert_true(bool(up["pitch_clamped"]), "夹了要标记出来")
	var down := Turret.solve_aim(Vector3(0, -1, 1), barrel, 360.0, -5.0, 35.0)
	assert_almost_eq(rad_to_deg(down["pitch"]), -5.0, 0.5, "压枪下限")
	# ④ 射界内的目标：解出来的角度转过去正好指回目标
	var target := Vector3(0.3, 0.4, 1.0).normalized()
	var solved := Turret.solve_aim(target, barrel, 360.0, -5.0, 35.0)
	var sign := Turret.pitch_sign_for(Vector3.RIGHT, barrel)
	var landed := Basis(Vector3.UP, solved["yaw"]) * Basis(Vector3.RIGHT, sign * solved["pitch"]) * barrel
	# 阈值要**紧**：0.999 太松，俯仰算错 1° 都能过（真踩过，见下 ⑤）
	assert_true(
		landed.dot(target) > 0.99999,
		"解出来的角转过去应该指回目标：%s vs %s" % [str(landed), str(target)]
	)
	# ⑤ 斜 45° 方向：仰角 = atan2(1, √2) ≈ 35.26°（水平距离是 √2，不是归一化后的 1）。
	# 这里曾经把归一化过的平面向量当水平距离用 → 算成 45°，远目标一律顶到俯仰上限。
	var diagonal := Turret.solve_aim(Vector3(1, 1, 1), barrel, 360.0, -90.0, 90.0)
	assert_almost_eq(rad_to_deg(diagonal["pitch"]), 35.264, 0.05, "俯仰角要按**水平距离**算")


## 核心提供能量（用户定的数：10000 上限 + 1000/s 恢复），武器每发都要耗能。
func test_core_energy_and_weapon_fire_parameters() -> void:
	var library := _library()
	var core := library.get_def("core")
	assert_true(core != null, "缺少核心部件")
	if core == null:
		return
	# ⚠️ 具体数值是**用户手调的**（最初填 10000 / 1000，后来自己改成别的了），
	# 所以只验"有、且量级合理"，别把数写死（写死了用户一调就红）。
	assert_true(core.energy_max >= 1000.0, "核心能量上限应该够用（>= 1000）：%s" % core.energy_max)
	assert_true(core.energy_regen > 0.0, "核心能量恢复应 > 0（每秒）：%s" % core.energy_regen)
	var def := _mg()
	if def == null:
		return
	assert_eq(def.weapon_projectile, "bullet", "射弹类型：普通子弹")
	assert_gt(def.weapon_muzzle_speed, 0.0, "子弹初速度要 > 0")
	assert_gt(def.weapon_damage, 0.0, "伤害要 > 0")
	assert_gt(def.weapon_rpm, 0.0, "射速要 > 0")
	assert_gt(def.weapon_traverse_speed, 0.0, "炮塔转速要 > 0")
	assert_gt(def.weapon_energy_cost, 0.0, "每发耗能要 > 0")
	assert_gt(def.weapon_projectile_life, 0.0, "弹丸寿命要 > 0")
	# 弹丸寿命夹在 [0.05, 120] 秒：0 会让子弹一出膛就死，太大就是"永不消失"（卡爆）
	var short_life := PartDef.from_text(
		"name = 短命弹\nshape = cube\ncubes = 1 1 1\nweapon_projectile_life = 0\n",
		"res://data/parts/test_short_life.part.txt"
	)
	assert_almost_eq(short_life.weapon_projectile_life, 0.05, 0.0001, "写 0 应夹到 0.05 秒")
	var long_life := PartDef.from_text(
		"name = 长寿弹\nshape = cube\ncubes = 1 1 1\nweapon_projectile_life = 9999\n",
		"res://data/parts/test_long_life.part.txt"
	)
	assert_almost_eq(long_life.weapon_projectile_life, 120.0, 0.0001, "写太大应夹到 120 秒")
	# **速度单位统一成真实 m/s**：内部换算 ×1/CUBE_METERS
	assert_almost_eq(
		def.muzzle_speed_cubes(),
		def.weapon_muzzle_speed / PartDef.CUBE_METERS,
		0.001,
		"初速度换算成格/秒"
	)
	# rpm → 两发之间的秒数
	assert_almost_eq(def.fire_interval_seconds(), 60.0 / def.weapon_rpm, 0.0001, "射速换算")
	# ⚠️ "每发耗能 ÷ 射击间隔"和"核心恢复速度"谁大谁小是**设计选择**（用户手调：
	# 小于恢复 = 能一直突突，大于恢复 = 扫一会儿就得等回能），所以这里**不断言**这个比例。
	# 只验两个数都是正的（单位/换算别写错），具体数值交给部件文件。
	assert_gt(def.weapon_energy_cost / def.fire_interval_seconds(), 0.0, "耗能速率要 > 0")


## 车轮限速的单位统一成 m/s：部件文件写 m/s，内部是格/秒（×1/CUBE_METERS）。
## 只验标定和量级 —— 具体限速是用户手调的（别写死 30 这种数）。
func test_wheel_max_speed_is_in_real_meters_per_second() -> void:
	var axle := _library().get_def("wheel_axle_2x2")
	assert_true(axle != null, "缺少轮轴部件")
	if axle == null:
		return
	assert_almost_eq(
		1.0 / PartDef.CUBE_METERS,
		2.0,
		0.001,
		"世界标定：1 cube = 0.5 米 → 1 m/s = 2 格/秒"
	)
	assert_almost_eq(
		axle.wheel_max_speed_cubes(),
		axle.wheel_max_speed / PartDef.CUBE_METERS,
		0.001,
		"限速换算：部件文件写 m/s，内部用格/秒"
	)
	# 量级检查：这里是**真实 m/s**，不该是格/秒那种大数（以前标着 m/s 实际写 150 格/秒）
	assert_true(
		axle.wheel_max_speed >= 5.0 and axle.wheel_max_speed <= 120.0,
		"车轮限速应在 5~120 m/s 这个真实量级：%s（写的是 m/s 吧？）" % axle.wheel_max_speed
	)


## 散射：所有样本都落在 ±spread 的锥里，而且**锥内是均匀的**（不是"边缘挤一圈"）。
func test_spread_stays_inside_the_cone_and_is_uniform() -> void:
	var axis := Vector3(0, 0, 1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261012
	# ① spread = 0：一动不动
	assert_true(
		Ballistics.spread_direction(axis, 0.0, rng).is_equal_approx(axis),
		"spread = 0 时朝向不该变"
	)
	# ② spread = 5°：全部落在锥内，而且**不是**全挤在边缘
	var spread := 5.0
	var samples := 400
	var inside := 0
	var inner := 0
	for _i in samples:
		var dir := Ballistics.spread_direction(axis, spread, rng)
		var angle := rad_to_deg(dir.angle_to(axis))
		if angle <= spread + 0.001:
			inside += 1
		if angle <= spread * 0.5:
			inner += 1
	assert_eq(inside, samples, "所有弹着都该在 ±%.1f° 的锥内" % spread)
	assert_true(inner > 0, "不能全挤在边缘（锥内要均匀）")
	# 均匀分布（cosθ 均匀）时，落在半角内的比例 = (1-cos(spread/2))/(1-cos(spread)) ≈ 25%
	var ratio := float(inner) / float(samples)
	assert_true(
		ratio > 0.17 and ratio < 0.33,
		"锥内分布不均匀：半角内 %.0f%%（均匀分布应约 25%%）" % (ratio * 100.0)
	)


## 弹道按重力下坠（半隐式欧拉：先加速度、再按新速度走这一步）。
func test_bullet_falls_under_gravity() -> void:
	var start := Vector3(0, 10, 0)
	var speed := 120.0 / PartDef.CUBE_METERS   # 120 m/s 换算成格/秒
	var velocity := Vector3(0, 0, speed)
	var gravity := PartDef.GRAVITY_CUBES
	var delta := 1.0 / 120.0
	var position := start
	var steps := 120          # 1 秒
	for _i in steps:
		var moved := Ballistics.advance(position, velocity, gravity, delta)
		position = moved["position"]
		velocity = moved["velocity"]
	assert_true(position.z > speed * 0.95, "水平方向基本匀速：%s" % str(position))
	# 1 秒自由落体 = g t²/2（半隐式欧拉会略大一点点，用 5% 余量）
	assert_true(
		position.y < start.y - gravity * 0.5 * 0.95, "子弹应该明显下坠：y = %.1f" % position.y
	)
	assert_almost_eq(velocity.y, -gravity, 0.5, "1 秒后竖直速度 = -g")


## 射弹池：打一发就在飞、到寿命自己收回（不传空间状态 = 打不到东西，纯飞）。
func test_projectile_pool_fires_and_expires() -> void:
	var shots := Projectiles.new()
	assert_true(shots != null, "射弹脚本应该能加载（Projectiles）")
	if shots == null:
		return
	assert_eq(shots.live_count(), 0, "一开始没有在飞的子弹")
	# 寿命按参数走（这里是 2 秒），而不是写死的默认 8 秒
	var fired := shots.fire(Vector3(0, 5, 0), Vector3(0, 0, 1), 600.0, 0.0, 10.0, 2.0)
	assert_true(fired, "开火应该成功")
	assert_eq(shots.live_count(), 1, "应该有一发在飞")
	# 走 1 秒（空间状态传 null = 不打碰撞）：子弹还在飞，而且掉下去了
	for _i in 120:
		shots.step(1.0 / 120.0, null)
	assert_eq(shots.live_count(), 1, "1 秒后子弹还在飞")
	var bullet: Dictionary = shots._bullets[0]
	assert_true(
		(bullet["position"] as Vector3).y < 5.0, "子弹应该下坠：%s" % str(bullet["position"])
	)
	assert_true(
		(bullet["position"] as Vector3).z > 500.0, "水平方向应该往前飞：%s" % str(bullet["position"])
	)
	# 超过 2 秒寿命就收回去（打飞的子弹不能永远算）
	for _i in 180:
		shots.step(1.0 / 120.0, null)
	assert_eq(shots.live_count(), 0, "过了 2 秒寿命应该收回")
	shots.free()


## 两把不同的武器可以有不同寿命：先打的那发到点自己走，后打的还在。
func test_projectile_lifetime_is_per_shot() -> void:
	var shots := Projectiles.new()
	assert_eq(shots.live_count(), 0, "一开始是空的")
	shots.fire(Vector3.ZERO, Vector3(0, 0, 1), 600.0, 0.0, 10.0, 0.1)   # 0.1 秒寿命
	shots.fire(Vector3.ZERO, Vector3(0, 0, 1), 600.0, 0.0, 10.0, 5.0)   # 5 秒寿命
	assert_eq(shots.live_count(), 2, "两发都在飞")
	for _i in 24:   # 0.2 秒
		shots.step(1.0 / 120.0, null)
	assert_eq(shots.live_count(), 1, "短命那发该没了，长命那发还在")
	assert_almost_eq(float(shots._bullets[0]["life"]), 5.0, 0.0001, "剩下的是 5 秒那发")
	shots.free()


## 曳光弹要**盖住整条走过的线段**：用户报"子弹太不显眼"就是因为高速子弹只给 1.5 格的光。
func test_tracer_covers_the_whole_step() -> void:
	var shots := Projectiles.new()
	shots.gravity = 0.0   # 这一条只验光带长度，去掉重力算得干净
	shots.fire(Vector3.ZERO, Vector3(0, 0, 1), 600.0, 0.0, 10.0, 5.0)
	# 刚出膛那一帧：先给一个短点（不能一上来就闪出几十格的光）
	var node: MeshInstance3D = shots._bullets[0]["node"]
	assert_almost_eq(
		node.transform.basis.get_scale().z, Projectiles.TRACER_MIN_LENGTH, 0.001, "出膛当帧是个短点"
	)
	shots.step(0.1, null)
	# 走了一步（0.1 秒 × 600 格/秒 = 60 格）：光带长度应该 = 这一帧的位移
	var scale := node.transform.basis.get_scale()
	assert_almost_eq(scale.z, 60.0, 0.1, "光带要拉满整段（60 格）")
	# 位置取线段中点：从 (0,0,0) 走到 (0,0,60)，中点 = (0,0,30)
	assert_vec_almost_eq(node.transform.origin, Vector3(0, 0, 30), 0.01, "光带盖住这一整段")
	assert_almost_eq(scale.x, 1.0, 0.001, "粗细不该跟着长度放大")
	shots.free()


## 光带的朝向要**始终沿着子弹飞的方向**（斜着飞也一样）。
## 踩过的坑：`Basis.scaled()` 是**全局**缩放（沿世界轴拉），斜射时光带被拉歪 ——
## 看着像"子弹横着打出去"。要用 `scaled_local()`（沿本地轴拉）。
func test_tracer_points_along_the_flight_path_at_any_angle() -> void:
	var shots := Projectiles.new()
	shots.gravity = 0.0
	# 斜着飞（三个轴都有分量，最能暴露"沿世界轴拉"的错）
	var direction := Vector3(1.0, -0.5, 1.0).normalized()
	shots.fire(Vector3.ZERO, direction, 600.0, 0.0, 10.0, 5.0)
	shots.step(0.1, null)
	var to_world := shots._bullets[0]["node"].transform as Transform3D
	var step := direction * 60.0        # 0.1 秒 × 600 格/秒
	# ① 本地 z 轴（光带的长轴）映射到世界后：方向要平行于飞行方向、长度要等于这一步的位移
	var axis: Vector3 = to_world.basis.z
	assert_almost_eq(axis.length(), step.length(), 0.01, "光带长度 = 这一步的位移")
	assert_true(
		absf(axis.normalized().dot(direction)) > 0.9999,
		"光带长轴要沿飞行方向（不是世界轴）：%s vs %s" % [str(axis.normalized()), str(direction)]
	)
	# ② 另外两个轴不该被拉长（没有剪切：长度还是 1）
	assert_almost_eq(to_world.basis.x.length(), 1.0, 0.001, "光带被拉歪了（x 轴变长）")
	assert_almost_eq(to_world.basis.y.length(), 1.0, 0.001, "光带被拉歪了（y 轴变长）")
	shots.free()


## 枪口闪光必须挂在**枪管（Pitch）节点下面** —— 结构上就不可能不跟着枪管转。
## （上一版是"世界坐标里的池化小球"：位置算得没错，但和枪管没有父子关系，也没方向，
## 看着就是"火光没跟着枪口转向"，用户报的。）
func test_muzzle_flash_is_a_child_of_the_barrel() -> void:
	var library := _library()
	var def: PartDef = library.get_def(MG_ID)
	if def == null:
		return
	var turret := Turret.new()
	assert_eq(turret.setup(def, Transform3D(Basis(), Vector3.ZERO), library), "", "转塔能装起来")
	var flash := turret.get_node_or_null("Yaw/Pitch/MuzzleFlash")
	assert_true(flash != null, "枪口闪光应该是枪管子节点")
	if flash == null:
		turret.free()
		return
	# 位置 = 枪口（零件本地）− 转点 + 沿枪轴再伸出去一点
	var pivot: Vector3 = def.weapon_pivot()["pivot"]
	var axis: Dictionary = def.weapon_barrel_axis()
	var want: Vector3 = (def.weapon_muzzle() - pivot) + (axis["dir"] as Vector3) * Turret.FLASH_REACH
	assert_vec_almost_eq((flash as Node3D).position, want, 0.001, "火舌要贴在枪口外侧")
	turret.flash()
	assert_true((flash as Node3D).visible, "开火时闪光要亮")
	turret.update_aim(Vector3(10, 0, 0), Turret.FLASH_TIME + 0.01)
	assert_false((flash as Node3D).visible, "闪完要灭（不用透明度，直接不画）")
	turret.free()


## 武器零件的**碰撞盒不含枪管**。
##
## ⚠️ 用户报的 bug：车体上的碰撞盒是**静止**的，而枪管会转（水平 360° + 俯仰）——
## 用"三件并起来"的 AABB 当碰撞盒时，枪管转走以后盒子里剩下的就是**空气**：
## 近距侧向射击的子弹会打在看不见的盒子上，还判到另一个炮台身上
## （"明明离炮台实际判定还很远"）。所以碰撞盒只取**底座 + 支架**（1×1×1，基本不空）。
func test_weapon_collision_box_excludes_the_sweeping_barrel() -> void:
	var library := _library()
	var def: PartDef = library.get_def(MG_ID)
	if def == null:
		return
	var box := def.collision_bounds()
	var body := def.body_bounds()
	var muzzle: Vector3 = def.weapon_muzzle()
	# 本体盒本来就该包住枪管（它是"三件并起来"的，车库/建造网格用）
	assert_true(
		body.position.z + body.size.z >= muzzle.z - 0.001,
		"本体盒该包住枪管：盒 %s / 枪口 z %.4f" % [body, muzzle.z]
	)
	# 但**碰撞盒不该包住枪口** —— 枪管伸出去的那一截就是"虚空"的来源
	assert_true(
		box.position.z + box.size.z < muzzle.z - 0.1,
		"碰撞盒不该包住枪口（枪管转走后那片是空气）：盒 %s / 枪口 z %.4f" % [box, muzzle.z]
	)
	# 底座 + 支架就是 1×1×1，不会因为枪管朝向变来变去而空出一大片
	assert_true(
		box.size.x <= 1.01 and box.size.y <= 1.01 and box.size.z <= 1.01,
		"碰撞盒应该只有底座 + 支架：%s" % box
	)
	# 普通零件不受影响：碰撞盒 = 本体盒
	var cube: PartDef = library.get_def("cube_full")
	if cube != null:
		assert_eq(cube.collision_bounds(), cube.body_bounds(), "普通零件的碰撞盒不变")


## 跨 ±180° 的目标角：**先**折到"离当前角最近的那个等价角"，再夹射界。
## 用户报的 bug：`_yaw` 已经累加到 −200°（unwrap 状态），而 `solve_aim()` 给的是 +153°
## （同一个方向，等价于 −207°）—— 归一化放在夹取之后时，线性插值会朝**反方向**走，
## 枪就"掉头"了（"想去从 −135° 跳到 +153°，方向反转"）。
func test_turret_aim_wrap_does_not_reverse_direction() -> void:
	var library := _library()
	var def: PartDef = library.get_def(MG_ID)
	if def == null:
		return
	var turret := Turret.new()
	assert_eq(turret.setup(def, Transform3D(Basis(), Vector3.ZERO), library), "", "转塔能装起来")
	turret.set_meta("part_index", 7)
	turret.rebuild_arc([])                  # 不放障碍：这一条只验"归一化"
	turret._yaw = deg_to_rad(-200.0)        # 已经绕着转过去 20°（超出 ±180）
	turret._pitch = 0.0
	var aim_dir := Basis(Vector3.UP, deg_to_rad(153.0)) * Vector3(0.0, 0.0, 1.0)
	var target: Vector3 = def.weapon_pivot()["pivot"] + aim_dir * 50.0
	turret.update_aim(target, 1.0 / 60.0)
	assert_true(
		rad_to_deg(turret._yaw) < -200.0,
		"★ 该继续往负方向走（−200° → −207°），不能翻回 +153°：现在 %.1f°"
			% rad_to_deg(turret._yaw)
	)
	turret.free()


## 被水平挡住的枪**不能连俯仰一起冻死**（用户报的："被左右障碍挡住时上下也锁死"）。
## `_clamp_to_arc()` 现在两个轴分别夹：保持当前俯仰先把水平走到头，再在那个水平角上走俯仰。
func test_turret_clamp_keeps_pitch_free_when_yaw_is_blocked() -> void:
	var library := _library()
	var def: PartDef = library.get_def(MG_ID)
	if def == null:
		return
	var turret := Turret.new()
	assert_eq(turret.setup(def, Transform3D(Basis(), Vector3.ZERO), library), "", "转塔能装起来")
	turret.set_meta("part_index", 7)
	# 正侧方、和枪轴**同高**的位置放一块零件：俯仰 0° 时枪管会撞上它，
	# 抬起来（枪管越过它）就不挡了 —— 正好用来验"水平挡了、俯仰还能动"。
	var pivot: Vector3 = def.weapon_pivot()["pivot"]
	var wall := AABB(pivot + Vector3(1.2, 0.0, 0.0) - Vector3.ONE * 0.5, Vector3.ONE)
	turret.rebuild_arc([{"box": wall, "name": "侧面的零件"}])
	assert_true(turret.arc_ready(), "射界要算得出来")
	assert_true(turret.arc_allows(0.0, 0.0), "当前朝向（正前）本来是通的")
	var wanted_yaw := deg_to_rad(60.0)
	assert_false(turret.arc_allows(wanted_yaw, 0.0), "那个水平方向确实被挡着")
	var clamped := turret._clamp_to_arc(wanted_yaw, deg_to_rad(25.0))
	assert_true(clamped.x < wanted_yaw - 0.01, "水平被夹住，没转到障碍里：%.1f°" % rad_to_deg(clamped.x))
	assert_almost_eq(
		rad_to_deg(clamped.y), 25.0, 0.6, "★ 俯仰不该被水平连坐冻死（用户报的）"
	)
	# ★ 反过来（往左转、负角）必须**对称**：夹住之后只能停在 0 和 −60° 之间，
	# 绝不能翻到对面（+60° 那一侧）去 —— 用户报的"往左被挡时会立刻跳到右侧被挡的位置"。
	var left := turret._clamp_to_arc(-wanted_yaw, deg_to_rad(-5.0))
	assert_true(
		left.x <= 0.01 and left.x > -wanted_yaw - 0.01,
		"往左夹只能落在 [−60°, 0] 里，不能翻到右边：%.1f°" % rad_to_deg(left.x)
	)
	turret.free()


## 真实射界的"障碍预筛"必须用**同一套坐标**比距离（零件盒是底盘本地的）。
## ⚠️ 踩过的坑：拿"底盘本地的盒中心"去比"**零件本地**的转点"，两个坐标系混在一起，
## 离原点远的转塔会把所有障碍都筛掉 → 射界全通、转起来横穿别人的主体。
## 用户的原话："并排紧贴放八个机枪一起左转，右边四台正常被左侧主体遮挡，左边四台穿模了"。
func test_turret_arc_sees_neighbours_far_from_the_origin() -> void:
	var library := _library()
	var def: PartDef = library.get_def(MG_ID)
	if def == null:
		return
	var turret := Turret.new()
	# 把这台转塔摆到离原点很远的地方（底盘本地 x = 30，模拟"并排第八台"）
	var place := Transform3D(Basis(), Vector3(30.0, 0.0, 0.0))
	assert_eq(turret.setup(def, place, library), "", "转塔能装起来")
	turret.set_meta("part_index", 7)   # 自己那件不在这个数组里（数组是"别的零件"）
	# 它旁边放一块零件，**压在枪管路径中段**（位置同样在底盘本地坐标里）
	var pivot: Vector3 = def.weapon_pivot()["pivot"]
	var mid: Vector3 = pivot + (def.weapon_muzzle() - pivot) * 0.6
	var blocker := AABB(place * mid - Vector3.ONE * 0.5, Vector3.ONE)
	turret.rebuild_arc([{"box": blocker, "name": "旁边的机枪 #1"}])
	assert_true(turret.arc_ready(), "射界要算得出来")
	assert_true(
		turret.arc_free_ratio() < 0.999,
		"★ 离原点很远的转塔也必须看得见旁边的零件（不能因为坐标混了就全通）：%.3f"
			% turret.arc_free_ratio()
	)
	assert_true(
		turret.arc_reason().contains("旁边的机枪"),
		"而且要说清是它挡的：%s" % turret.arc_reason()
	)
	turret.free()


## **真实射界**（用户 2026-10-14 的设计）：射界按"水平扇区 × 俯仰带"切格子，
## 逐格判"枪管摆到那儿会不会压到别的零件"，再取**和初始枪口朝向连通**的那一片 ——
## 只有这一片能开火。
##
## ★ 关键性质：中间被一块零件**切开**时，对面明明空着也打不到 —— 因为枪管要转过去
## 就得穿过那块零件（长管武器最明显）。这条正是"连通域"存在的理由。
## 另一条：**每台转塔各算各的**（一把武器被挡不连坐别人），所以判定挂在 Turret 上。
func test_turret_real_firing_arc_is_the_connected_clear_region() -> void:
	var library := _library()
	# 用真模型造一个"窄射界"的测试转塔（±45°、俯仰 ±5°）：格子少，好断言
	var def := PartDef.from_text(
		"name = 测试转塔\n"
		+ "model = res://data/parts/lightmachinegunx1/轻机枪1 .vox\n"
		+ "cubes = 3 3 3\nrender = voxel\nconnections = -y\n"
		+ "weapon = turret\nweapon_yaw_model = 1\nweapon_pitch_model = 2\n"
		+ "weapon_yaw_limit = 90\nweapon_pitch_min = -5\nweapon_pitch_max = 5\n",
		"res://data/parts/test_turret_arc.part.txt"
	)
	assert_eq(def.warnings.size(), 0, "测试转塔不该有警告：%s" % str(def.warnings))
	var turret := Turret.new()
	assert_eq(turret.setup(def, Transform3D(Basis(), Vector3.ZERO), library), "", "转塔能装起来")
	# `part_index` 是"自己那件在零件表里的下标"：这里给它一个数组里没有的下标，
	# 好让下面的"别的零件"都算数（最后 ④ 再把它指回 0 验一次"跳过自己"）。
	turret.set_meta("part_index", 5)
	var pivot: Vector3 = def.weapon_pivot()["pivot"]
	var reach: float = (def.weapon_muzzle() - pivot).length()
	var barrel_dir: Vector3 = def.weapon_barrel_axis()["dir"]
	# ① 空场：整片射界都通，当前朝向当然能开火
	turret.rebuild_arc([])
	assert_almost_eq(turret.arc_free_ratio(), 1.0, 0.0001, "没零件时整片射界都通")
	assert_true(turret.arc_allows_current(), "空场能开火")
	assert_true(turret.arc_reason().is_empty(), "空场不该有理由")
	# ② 在 yaw = -20° 那一列上立一块"墙"（小盒子，正好压在枪管前端那一段、全俯仰高度）
	var wall_dir: Vector3 = Basis(Vector3.UP, deg_to_rad(-20.0)) * barrel_dir
	var wall := AABB(
		pivot + wall_dir * (reach - 0.15) - Vector3(0.125, 0.25, 0.125), Vector3(0.25, 0.5, 0.25)
	)
	var blockers := [{"box": wall, "name": "cube_full #3"}]
	turret.rebuild_arc(blockers)
	assert_true(turret.arc_allows_current(), "初始朝向（yaw 0）没被挡 → 还能开火")
	assert_true(
		turret.arc_allows(deg_to_rad(30.0), 0.0), "墙的另一侧还连着（走另一边绕过去）"
	)
	assert_false(
		turret.arc_allows(deg_to_rad(-40.0), 0.0),
		"★ 墙左边明明空着，但和初始朝向不连通 → 打不到（枪管要穿过去）"
	)
	# ③ 同一块零件挡住的**当前朝向**：报出是谁挡的，而且不能开火
	turret.rebuild_arc([{"box": AABB(pivot + barrel_dir * reach - Vector3.ONE * 0.5, Vector3.ONE), "name": "cube_full #9"}])
	assert_false(turret.arc_allows_current(), "枪管正前方被挡 → 当前朝向打不了")
	assert_true(
		turret.arc_reason().contains("cube_full #9"),
		"理由里要说清是谁挡的：%s" % turret.arc_reason()
	)
	# ④ 自己那一件（part_index = 0）永远跳过：底座/支架/枪管不算挡自己
	turret.set_meta("part_index", 0)
	turret.rebuild_arc([{"box": AABB(Vector3(-9, -9, -9), Vector3(30, 30, 30)), "name": "自己"}])
	assert_almost_eq(turret.arc_free_ratio(), 1.0, 0.0001, "自己的零件盒要跳过")
	turret.free()


## 线段 × 零件盒这条判据：真实射界（枪口→转点）和"枪口贴脸自吃"（枪口→生成点）共用它。
func test_segment_blocker_checks_the_line_against_part_boxes() -> void:
	var boxes := [
		{"box": AABB(Vector3(1, -0.5, -0.5), Vector3(1, 1, 1)), "name": "挡在中间的"},
		{"box": AABB(Vector3(9, 9, 9), Vector3.ONE), "name": "在很远的地方"},
	]
	assert_eq(
		Turret.segment_blocker(Vector3.ZERO, Vector3(5, 0, 0), boxes),
		"挡在中间的",
		"穿过线段要报出是谁"
	)
	assert_true(
		Turret.segment_blocker(Vector3.ZERO, Vector3(0, 5, 0), boxes).is_empty(),
		"从旁边过去的零件不算挡"
	)
	assert_true(
		Turret.segment_blocker(Vector3.ZERO, Vector3(5, 0, 0), boxes, 0).is_empty(),
		"skip_index 指到谁就跳过谁（用来排除自己那一件）"
	)
	# pad：贴着我们但不碰到的盒子，加粗一点就算挡（枪管有粗细）
	var nearby := [{"box": AABB(Vector3(1, 0.05, -0.5), Vector3(1, 1, 1)), "name": "擦着枪管"}]
	assert_true(
		Turret.segment_blocker(Vector3.ZERO, Vector3(5, 0, 0), nearby).is_empty(),
		"纯线段：擦不到就不算"
	)
	assert_eq(
		Turret.segment_blocker(Vector3.ZERO, Vector3(5, 0, 0), nearby, -1, 0.1),
		"擦着枪管",
		"加粗 0.1 格后就算挡（ARC_SEGMENT_PAD 干的就是这个）"
	)


## 第一段光带必须从**真枪口**拉出来（枪口到子弹生成点那一段），近身才看得见弹道。
func test_first_tracer_segment_starts_at_the_muzzle() -> void:
	var shots := Projectiles.new()
	shots.gravity = 0.0
	# ⚠️ 枪口不能正好是 (0,0,0)：那个值是"没给枪口"的哨兵值（会用生成点兜底）
	var muzzle := Vector3(0, 0, -1)
	var spawn := Vector3(0, 0, 0)     # 枪口沿枪轴外推 1 格 = 子弹生成点
	shots.fire(spawn, Vector3(0, 0, 1), 600.0, 0.0, 10.0, 5.0, Vector3.ZERO, "player", muzzle)
	var tracer: Transform3D = shots._bullets[0]["node"].transform
	assert_almost_eq(tracer.basis.z.length(), 1.0, 0.01, "第一段长度 = 枪口到生成点")
	assert_vec_almost_eq(tracer.origin, Vector3(0, 0, -0.5), 0.01, "第一段要盖住枪口→生成点")
	# 不给枪口时退化成"生成点上的一个短点"（以前的行为，不报错）
	shots.fire(spawn, Vector3(0, 0, 1), 600.0, 0.0, 10.0, 5.0, Vector3.ZERO, "player")
	var fallback: Transform3D = shots._bullets[1]["node"].transform
	assert_almost_eq(
		fallback.basis.z.length(), Projectiles.TRACER_MIN_LENGTH, 0.01, "没给枪口就是个短点"
	)
	shots.free()


## 命中爆炸：会"砰"地胀开、再缩回去，节点池化复用。
func test_impact_expands_then_recycles() -> void:
	var shots := Projectiles.new()
	shots._spawn_impact(Vector3(1, 2, 3))
	assert_eq(shots._impacts.size(), 1, "命中爆炸应该出现")
	shots.step(Projectiles.IMPACT_LIFE * 0.35, null)
	var scale := (shots._impacts[0]["node"] as MeshInstance3D).scale.x
	assert_almost_eq(
		scale, Projectiles.IMPACT_PEAK, 0.05, "膨胀期应该胀到峰值（IMPACT_PEAK）"
	)
	shots.step(Projectiles.IMPACT_LIFE, null)
	assert_eq(shots._impacts.size(), 0, "到点应该收回去")
	assert_eq(shots._free_impacts.size(), 1, "应该回收进池子（复用，不一直 new）")
	shots.free()


## 命中的处置（`Projectiles.hit_plan()`）：打到自己车体是**只放特效、不结算伤害**。
## 用户 2026-10-14 的要求：抛物线和散射让子弹有机会绕回来打到自己，
## 调枪口 / 射界 / 贴脸自吃的时候得**看得见**这一发打在自己哪儿。
##
## （为什么测这个纯函数而不是跑一发真的：`step()` 那条路要真实的物理空间查询，
##   而测试跑在编辑器进程里、根窗口没有 3D world —— 拿不到 `direct_space_state`。）
func test_self_hit_is_effect_only() -> void:
	var mine_body := StaticBody3D.new()
	var other_body := StaticBody3D.new()
	var rows := {"player": mine_body.get_rid()}
	var self_plan := Projectiles.hit_plan(rows, "player", mine_body.get_rid())
	assert_true(bool(self_plan["self"]), "打到自己要认出来")
	assert_true(bool(self_plan["impact"]), "★ 打到自己也要放命中小爆炸（看得见打在哪）")
	assert_false(bool(self_plan["damage"]), "但绝不能结算伤害")
	var other_plan := Projectiles.hit_plan(rows, "player", other_body.get_rid())
	assert_false(bool(other_plan["self"]), "打到别人不算自己")
	assert_true(bool(other_plan["damage"]), "打到别人要结算伤害")
	assert_true(
		bool(Projectiles.hit_plan(rows, "敌方", mine_body.get_rid())["damage"]),
		"没在 owner_rids 里登记的开火者，一律按别人算"
	)
	mine_body.free()
	other_body.free()


## "枪口贴脸自吃"要把命中小爆炸放在**第一个被挡住的地方**（弹丸压根没生成，
## 全靠这个特效才看得见打在哪 —— 用户 2026-10-14 要的）。
func test_muzzle_self_hit_supplies_an_impact_point() -> void:
	var field := TestField.new()
	var chassis := RigidBody3D.new()   # `TestField._chassis` 是 RigidBody3D 类型
	field._chassis = chassis        # 只用局部坐标换算，不进场景树
	field._clip_boxes = [
		{"box": AABB(), "name": "（自己那一件，空盒）"},
		{"box": AABB(Vector3(0.4, -0.5, -0.5), Vector3(1, 1, 1)), "name": "挡在枪口前"},
	]
	var from := Vector3(0, 0, 0)
	var to := Vector3(1, 0, 0)
	var point := field._first_blocked_point(from, to, 0)   # 跳过下标 0（自己）
	assert_true(
		point.x > 0.39 and point.x < 0.71,
		"落点应该在挡路那块零件上（枪口 → 生成点之间）：%s" % point
	)
	assert_eq(field._first_blocked_point(from, to, 1), from, "没东西挡就退回起点")
	chassis.free()
	field.free()


## 命中那一下的最后一段光带：子弹在同帧就没了，这一截要留一会儿才看得见
## （用户报的"开火到命中很近就不会出现射弹轨迹"）。
func test_hit_ghost_keeps_the_last_segment_visible() -> void:
	var shots := Projectiles.new()
	var node := shots._make_tracer()
	shots._spawn_tracer_ghost(node, Vector3(1, 2, 3))
	assert_eq(shots._ghosts.size(), 1, "命中后应该留一截光带")
	shots.step(Projectiles.TRACER_GHOST_LIFE * 0.5, null)
	assert_eq(shots._ghosts.size(), 1, "半程还在")
	assert_true(node.visible, "这期间必须是可见的（不然等于没画）")
	shots.step(Projectiles.TRACER_GHOST_LIFE, null)
	assert_eq(shots._ghosts.size(), 0, "留够了要收回去")
	assert_false(node.visible, "收回时隐藏")
	assert_true(shots._free_bullets.has(node), "节点回收进曳光弹池复用")
	shots.free()


## 同一处的连续命中**不能叠**幽灵光带：贴着已有幽灵的新命中只续命（用户报的"最末一段突然变粗、
## 像判定了好几次"实测就是 4 条光带挤在 3 格内）。
func test_ghosts_merge_at_the_same_impact_point() -> void:
	var shots := Projectiles.new()
	var first := shots._make_tracer()
	var tip := Vector3(0.0, 5.0, 0.0)
	shots._spawn_tracer_ghost(first, tip)
	assert_eq(shots._ghosts.size(), 1, "第一条留下")
	# 贴着命中点再来一发（比如 1 格以内）：不新增，只续命
	var second := shots._make_tracer()
	shots._spawn_tracer_ghost(second, tip + Vector3(0.4, 0.2, 0.0))
	assert_eq(shots._ghosts.size(), 1, "同一处不该叠第二条")
	assert_true(shots._free_bullets.has(second), "新节点直接还回池子")
	shots._ghosts[0]["age"] = Projectiles.TRACER_GHOST_LIFE * 0.9   # 假装它快过期
	var third := shots._make_tracer()
	shots._spawn_tracer_ghost(third, tip + Vector3(0.1, 0.0, 0.0))
	assert_almost_eq(
		float(shots._ghosts[0]["age"]), 0.0, 0.0001, "贴着的那条要续命（重新计时）"
	)
	# 远处命中（超过合并距离）照常新增一条
	shots._spawn_tracer_ghost(third, tip + Vector3(4.0, 0.0, 0.0))
	assert_eq(shots._ghosts.size(), 2, "隔得远就是另一处命中，要单独一条")
	shots.free()


## 光带的**尖端永远在 `to` 上**：段太短就按 `min_length` 往回拉 —— 不然命中点离上一帧很近时，
## 光带会短成"和粗细差不多宽的方块"，看着像"最末一段突然变粗"（用户报的）。
func test_tracer_tip_is_anchored_at_the_end_point() -> void:
	var shots := Projectiles.new()
	shots.gravity = 0.0
	shots.fire(Vector3.ZERO, Vector3(0, 0, 1), 600.0, 0.0, 10.0, 5.0)
	var node: MeshInstance3D = shots._bullets[0]["node"]
	var bullet: Dictionary = shots._bullets[0]
	var direction := Vector3(0, 0, 1)
	# ① 命中很短的一段（0.1 格）：长度按命中用的最小值拉长，**尖端仍在命中点上**
	var hit_point := Vector3(0, 0, 0.1)
	shots._place_tracer(bullet, Vector3.ZERO, hit_point, Projectiles.TRACER_HIT_MIN_LENGTH)
	var traced: Transform3D = node.transform
	assert_almost_eq(
		traced.basis.z.length(), Projectiles.TRACER_HIT_MIN_LENGTH, 0.001, "长度要拉到位"
	)
	var tip := traced.origin + traced.basis.z * 0.5
	# 注意本地 z 的朝向是 -direction（looking_at 把 -Z 对准方向），所以外面那一端看绝对值
	assert_true(
		minf(tip.distance_to(hit_point), (traced.origin - traced.basis.z * 0.5).distance_to(hit_point))
			< 0.001,
		"光带有一端必须落在命中点上：%s / 目标 %s" % [str(tip), str(hit_point)]
	)
	# ② 正常的一步（比最小值长）：起点/终点正好盖住这一步
	shots._place_tracer(bullet, Vector3.ZERO, Vector3(0, 0, 3.0))
	var step: Transform3D = node.transform
	assert_almost_eq(step.basis.z.length(), 3.0, 0.001, "长度 = 这一步的位移")
	assert_vec_almost_eq(step.origin, Vector3(0, 0, 1.5), 0.001, "位置 = 线段中点")
	# ③ 粗细不跟着长度走：横截面的**缩放**保持 1（实际粗细 = 网格的 TRACER_WIDTH × 1）
	assert_almost_eq(step.basis.x.length(), 1.0, 0.0001, "横截面不该被拉长/压扁")
	assert_almost_eq(step.basis.y.length(), 1.0, 0.0001, "横截面不该被拉长/压扁")
	shots.free()


## 弹道本身各段的粗细**必须一致**（用户两次报"最后一段更粗"，一次是枪口、一次是命中点）：
## 把渲染盒子的 8 个角换算到世界、量垂直于轴线的横截面半径 —— 长短两段必须一样。
func test_tracer_thickness_does_not_depend_on_length() -> void:
	var dir := Vector3(0.6, -0.5, 0.62).normalized()
	var half := Vector3(Projectiles.TRACER_WIDTH * 0.5, Projectiles.TRACER_WIDTH * 0.5, 0.5)
	var widest_of := {}
	for length: float in [25.0, 6.0, Projectiles.TRACER_HIT_MIN_LENGTH]:
		var basis := Basis.looking_at(dir, Vector3.UP).scaled_local(Vector3(1.0, 1.0, length))
		var axis := (basis * Vector3(0, 0, 1)).normalized()
		var widest := 0.0
		for i in 8:
			var corner := Vector3(
				half.x if (i & 1) != 0 else -half.x,
				half.y if (i & 2) != 0 else -half.y,
				half.z if (i & 4) != 0 else -half.z
			)
			var world := basis * corner
			var along := world.dot(axis)
			widest = maxf(widest, (world - axis * along).length())
		widest_of[length] = widest
	var reference: float = widest_of[25.0]
	assert_almost_eq(reference, Projectiles.TRACER_WIDTH * 0.5 * sqrt(2.0), 0.001, "横截面半径")
	for length: float in widest_of.keys():
		assert_almost_eq(
			float(widest_of[length]), reference, 0.001,
			"长度 %.2f 的横截面半径必须和长段一致" % length
		)


