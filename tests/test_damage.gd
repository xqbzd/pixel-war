@tool
extends McpTestSuite

## 毁伤判定（VehicleState）：扣血 / 消灭 / 溢出均分 / 断开就死 / 重算重量重心。
##
## 测试用车（核心在下、上面一条 2×2 的方块环 + 一条只挂在环上的尾巴）：
##
##     俯视（z 向上是"前"，x 向右）—— 环在**核心顶上两格**（核心是 2 格高的 2×2×1）：
##         z
##         ↑   2 ─ 3        4 = 尾巴（只挂在 1 上，用来验"断开就死"）
##         │   │   │
##         │   0 ─ 1 ─ 4
##         └── 核心（0 和 1 底下）→ x
##
## ⚠️ 摆的时候踩过两个坑：① 建造场地地板在 y = 0，放到地板下面判"超出建造场地范围"，
## 那个零件根本摆不上去；② 核心的 `cubes = 2 2 1` 在游戏坐标里是 **2 格高**（x/y 各 2、z 是 1），
## 所以环只能放在核心顶上第 2 格（y = 2），放 y = 1 会跟核心穿模。
##
const PART_DIR := "res://data/parts"


func suite_name() -> String:
	return "damage"


## 测试里的伤害数字要**跟着部件文件里的血量走** —— 用户随时会调 hp
## （实测：核心被调成了 30000，写死 1000 的断言当场就红了）。
func _hp(part_id: String) -> float:
	var def: PartDef = _library().get_def(part_id)
	return float(def.hp) if def != null else 1000.0


func _library() -> PartLibrary:
	var library := PartLibrary.new()
	library.load_all(PART_DIR)
	return library


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


## 造一台测试车。返回 {state, hp_of: {零件名: 满血}}。
func _make_state() -> VehicleState:
	var library := _library()
	var text := (
		"name = 毁伤测试车\n"
		+ "part = cube_full 0 2 0 0 0 0\n"
		+ "part = cube_full 1 2 0 0 0 0\n"
		+ "part = cube_full 0 2 1 0 0 0\n"
		+ "part = cube_full 1 2 1 0 0 0\n"
		+ "part = cube_full 2 2 0 0 0 0\n"
		+ "part = core 0 0 0 0 0 0\n"
	)
	var vehicle := VehicleDef.from_text(text, "user://damage_probe.vehicle.txt")
	assert_eq(vehicle.warnings.size(), 0, "测试车不该有解析警告：%s" % str(vehicle.warnings))
	var state := VehicleState.new()
	state.setup(vehicle, library.defs)
	return state


## 连接图要和摆放一致：环上 0-1-2-3、尾巴 4 只挂 1、核心连 0 和 1。
func test_connection_graph_matches_the_layout() -> void:
	var state := _make_state()
	assert_eq(state.part_count(), 6, "6 个零件")
	assert_eq(state.neighbours_of(0).size(), 3, "0 连 1 / 2 / 核心")
	assert_eq(state.neighbours_of(1).size(), 4, "1 连 0 / 3 / 4 / 核心")
	assert_eq(state.neighbours_of(4), [1], "尾巴只挂在 1 上")
	assert_eq(state.neighbours_of(5).size(), 2, "核心连着 0 和 1")
	assert_eq(state.core_index, 5, "核心是第 5 个零件")


## 伤害小于剩余血量：扣血，零件还在，不触发任何重算。
func test_small_hit_only_subtracts() -> void:
	var state := _make_state()
	var cube := _hp("cube_full")
	var result := state.apply_damage(2, 250.0)
	assert_almost_eq(state.remaining_hp(2), cube - 250.0, 0.001, "扣血")
	assert_true(state.part_alive(2), "零件还在")
	assert_eq(result["destroyed"], [], "没有零件被消灭")
	assert_false(bool(result["mass_changed"]), "没消灭零件就不用重算重量/重心")


## 伤害 ≥ 剩余血量：消灭，溢出**沿连接点均分**给还活着的邻居。
func test_overflow_is_split_evenly_among_neighbours() -> void:
	var state := _make_state()
	# 0 号满血 1000、有 3 个邻居（1 / 2 / 核心）→ 溢出 300 每家 100
	var cube := _hp("cube_full")
	var core := _hp("core")
	# 0 号打掉（cube）+ 300 溢出 → 3 个邻居各 100
	var result := state.apply_damage(0, cube + 300.0)
	assert_eq(result["destroyed"], [0], "0 号被消灭")
	assert_false(state.part_alive(0), "0 号没了")
	assert_almost_eq(state.remaining_hp(0), 0.0, 0.001, "被消灭的零件血量归零（不会变成负数）")
	assert_almost_eq(state.remaining_hp(1), cube - 100.0, 0.01, "1 号分到 100 伤害")
	assert_almost_eq(state.remaining_hp(2), cube - 100.0, 0.01, "2 号分到 100 伤害")
	assert_almost_eq(state.remaining_hp(5), core - 100.0, 0.01, "核心分到 100 伤害")
	assert_almost_eq(state.remaining_hp(3), cube, 0.01, "3 号不在 0 的连接点上，不该掉血")
	assert_almost_eq(state.remaining_hp(4), cube, 0.01, "尾巴更不该掉血")
	assert_eq(result["detached"], [], "剩下的零件还连在核心上")
	assert_true(bool(result["mass_changed"]), "消灭了零件就要重算重量/重心")


## 溢出会**连锁**：一环接一环地结算（链上每一环都按同样的规则）。
func test_overflow_chains_along_the_graph() -> void:
	var state := _make_state()
	# 尾巴 4（只有 1 一个邻居）挨 2500：自己死 → 溢出 1500 全给 1 → 1 也死 →
	# 1 的溢出 500 分给 0 / 3 / 核心（4 已死，分不到）
	var cube := _hp("cube_full")
	var core := _hp("core")
	# 尾巴 4 打掉（cube）+ 1.5 倍溢出 → 1 号吃掉 cube 后还剩 0.5 倍，再分给 0 / 3 / 核心
	var result := state.apply_damage(4, cube * 2.5)
	assert_eq(result["destroyed"], [4, 1], "尾巴被打掉、连着的 1 号跟着被溢出打掉")
	var share := (cube * 1.5 - cube) / 3.0     # 1 号吃掉自己那份后剩下的溢出，三家均分
	assert_almost_eq(state.remaining_hp(0), cube - share, 0.01, "0 号分到 1/3 的溢出")
	assert_almost_eq(state.remaining_hp(3), cube - share, 0.01, "3 号分到 1/3 的溢出")
	assert_almost_eq(state.remaining_hp(5), core - share, 0.01, "核心分到 1/3 的溢出")
	assert_almost_eq(state.remaining_hp(2), cube, 0.01, "2 号不在 1 的连接点上")


## 结构垮了：被打掉"必经之路"之后，和核心断开的那部分**立刻一起被消灭**。
func test_parts_detached_from_the_core_die_immediately() -> void:
	var state := _make_state()
	# 1 号挨刚好够死的一击（没有溢出）：尾巴 4 只挂在 1 上 → 和核心断开 → 立刻死；
	# 0/2/3 还连着核心（0 直接连着，2-0、3-2），活着。
	var result := state.apply_damage(1, _hp("cube_full"))
	assert_eq(result["destroyed"], [1], "被直接打掉的只有 1 号")
	assert_eq(result["detached"], [4], "尾巴因为断连被一起消灭")
	assert_true(state.part_alive(0), "0 号还连着核心")
	assert_true(state.part_alive(2), "2 号经 0 连回核心")
	assert_true(state.part_alive(3), "3 号经 2 连回核心")
	assert_false(state.part_alive(4), "尾巴已被消灭")
	assert_eq(state.alive_count(), 4, "剩下 0 / 2 / 3 / 核心")


## 消灭零件之后重量/重心要跟着变（重心往还活着的零件那边偏）。
func test_mass_and_center_of_mass_follow_the_survivors() -> void:
	var state := _make_state()
	var mass_before := state.total_mass()
	var centre_before := state.center_of_mass()
	# 打掉右边的尾巴和 1 号（那一侧最重的一串）→ 重心应该往 -x 偏
	state.apply_damage(4, _hp("cube_full"))
	assert_almost_eq(state.remaining_hp(1), _hp("cube_full"), 0.01, "只是消灭尾巴，1 号没掉血")
	var mass_after := state.total_mass()
	var centre_after := state.center_of_mass()
	assert_true(mass_after < mass_before, "重量应该变小：%s → %s" % [mass_before, mass_after])
	assert_true(mass_after > 0.0, "还有零件活着，重量不该归零")
	assert_true(
		centre_after.x <= centre_before.x + 0.0001,
		"打掉右边之后重心不该往 +x 跑：%s → %s" % [str(centre_before), str(centre_after)]
	)


## 核心被打掉 = 整机全灭（剩下的零件全部按"断连"处理）。
func test_losing_the_core_kills_everything() -> void:
	# ① 刚好打掉核心（没有溢出）：剩下 5 个零件全部"断连"→ 一起被消灭
	var state := _make_state()
	var result := state.apply_damage(5, state.remaining_hp(5))
	assert_true(bool(result["core_lost"]), "核心丢了")
	assert_eq(result["destroyed"], [5], "直接被消灭的只有核心")
	assert_eq(result["detached"].size(), 5, "剩下 5 个零件全算断连：%s" % str(result["detached"]))
	assert_eq(state.alive_count(), 0, "整机全灭")
	# ② 一炮打穿核心（溢出顺着连接图连锁）：结果一样是全灭，但走的是溢出那条路
	var state2 := _make_state()
	var result2 := state2.apply_damage(5, 99999.0)
	assert_true(bool(result2["core_lost"]), "核心还是丢了")
	assert_eq(state2.alive_count(), 0, "溢出连锁也应该把整机打光")


## 边界：打空气（不存在的下标 / 已经没了的零件 / 0 伤害）不该有任何副作用。
func test_invalid_hits_are_ignored() -> void:
	var state := _make_state()
	assert_eq(state.apply_damage(99, 100.0)["destroyed"], [], "下标越界")
	assert_eq(state.apply_damage(0, 0.0)["destroyed"], [], "0 伤害")
	state.apply_damage(2, _hp("cube_full"))
	assert_false(state.part_alive(2), "2 号先被打掉")
	assert_eq(state.apply_damage(2, 500.0)["destroyed"], [], "再打已经没有的零件不产生任何效果")


## 轮体（轮胎）也要有受击判定：轮胎是**附属子模型**，本体的包围盒里没有它 ——
## 以前子弹直接从轮胎中间穿过去（用户报的）。现在 `VehicleRig` 给带轮体的零件
## **多加一个碰撞盒**（按轮胎自己的包围盒），两个盒子的 shape 下标都映射回同一个零件。
func test_wheel_tire_gets_its_own_hit_box() -> void:
	var library := _library()
	var vehicle := VehicleDef.from_text(
		(
			"name = 轮子受击测试\n"
			+ "part = core 0 0 0 0 0 0\n"
			+ "part = toy_wheel_2x2 2 0 0 0 0 0\n"
		),
		"user://wheel_hit_probe.vehicle.txt"
	)
	assert_eq(vehicle.warnings.size(), 0, "测试车不该有警告：%s" % str(vehicle.warnings))
	var body := StaticBody3D.new()
	var rig := VehicleRig.new()
	rig.setup(vehicle, library, body, body, false, Vector3.ZERO)
	var axle: PartDef = library.get_def("toy_wheel_2x2")
	assert_true(axle != null, "缺少轮轴部件")
	if axle == null:
		body.free()
		return
	# 车体物理碰撞 = 每个零件一个盒子（真实外形；受击仍走 hitboxes 的 trimesh）
	# 车体物理碰撞 = 全部并进合并盒（核心 / 轮轴都是不动的部件；只有勾了
	# `weapon_swivel_collider` 的炮塔才单独建盒）
	assert_true(rig.shapes.is_empty(), "没有零件需要独立碰撞盒：%d" % rig.shapes.size())
	assert_true((rig._merged_shapes as Array).size() >= 1, "方块被合并成盒子")
	# 受击盒 body 上按**空间分块**挂 trimesh（掉零件只重建受影响的块，不重建整车）
	assert_true(rig._hit_shapes.size() >= 1, "受击盒至少挂了一块 trimesh")
	assert_eq(rig._hit_shapes.size(), rig._chunk_shapes.size(), "块表和张数对得上")
	for chunk_shape in rig._hit_shapes:
		assert_true(chunk_shape.shape is ConcavePolygonShape3D, "每块都是凹面体")
	assert_eq(rig._hit_shape_part.size(), 3, "受击盒记了 3 个盒：核心本体、轮轴本体、轮胎")
	assert_eq(rig._hit_shape_part, [0, 1, 1], "轮胎那一下算在轮轴头上")
	var tire_box: AABB = rig._hit_box[2]
	var tire_size: Vector3 = tire_box.size
	var body_box: AABB = rig._hit_box[1]
	var sub: VoxVolume = axle.sub_model_volume()
	var tight := PartDef.tight_bounds(sub, axle.sub_model_offset(), Vector3.ONE)
	assert_vec_almost_eq(tire_size, tight.size, 0.001, "轮胎盒 = 轮胎自己的包围盒")
	assert_vec_almost_eq(body_box.size, axle.body_bounds().size, 0.001, "本体盒 = 部件本体包围盒")
	# 关键：轮胎盒不能是零尺寸，也不能只是本体盒的复制（那就等于没加）。
	assert_true(
		tire_size.x > 0.4 and tire_size.y > 1.0 and tire_size.z > 1.0,
		"轮胎盒要有实际大小：%s" % str(tire_size)
	)
	assert_true(tire_size != body_box.size, "轮胎盒应该和本体盒不同：%s vs %s" % [str(tire_size), str(body_box.size)])
	# 命中点落在轮胎盒里 → 算到**这个轮轴**头上；落在核心盒里 → 算核心
	assert_eq(
		rig.part_index_of_hit(rig.hitboxes.get_rid(), 0, tire_box.get_center()), 1, "轮胎上算轮轴"
	)
	assert_eq(
		rig.part_index_of_hit(rig.hitboxes.get_rid(), 0, (rig._hit_box[0] as AABB).get_center()), 0,
		"核心盒上算核心"
	)
	# 受击盒 body 必须**不参与物理碰撞**：专用层 + 掩码 0
	assert_eq(rig.hitboxes.collision_layer, 4, "受击盒在专用层 4")
	assert_eq(rig.hitboxes.collision_mask, 0, "受击盒掩码 0（谁都不碰）")
	assert_eq(rig.hitboxes.collision_layer, VehicleRig.HITBOX_LAYER, "层号用常量，别对不上")
	# 打掉这个零件之后，盒子都还在（只禁用不删除：删了后面 shape 下标会往前挪）
	rig.apply_damage(1, 99999.0)
	rig.flush_visuals()
	assert_true(rig.shapes.is_empty(), "没有零件需要独立碰撞盒")
	assert_true(rig._hit_shapes.size() >= 1, "受击盒的 trimesh 还在（只重建受影响的块）")
	# 打掉之后，打在那个位置应该已经不算这个零件了
	assert_eq(
		rig.part_index_of_hit(rig.hitboxes.get_rid(), 0, tire_box.get_center()), -1,
		"零件没了就不再受击"
	)
	body.free()





## 瞄点要**跟着残骸走**：零件掉了之后 `alive_centre_local()` 必须挪到剩下的零件上，
## 不能还停在原来整车的中心（用户 2026-10-19 报的"打残的对手瞄不中"）。
func test_aim_point_follows_destroyed_parts() -> void:
	var library := _library()
	var vehicle := VehicleDef.from_text(
		(
			"name = 瞄点测试\n"
			+ "part = core 0 0 0 0 0 0\n"
			+ "part = toy_wheel_2x2 3 0 0 0 0 0\n"
		),
		"user://aim_centre_probe.vehicle.txt"
	)
	var body := StaticBody3D.new()
	var rig := VehicleRig.new()
	rig.setup(vehicle, library, body, body, false, Vector3.ZERO)
	var full: Vector3 = rig.alive_centre_local()
	var core_box: AABB = rig.part_box(rig.state.core_index)
	# 把轮轴打掉 -> 只剩核心，视觉中心必须回到核心盒中心
	for i in rig.state.part_count():
		if i == rig.state.core_index:
			continue
		if rig.part_alive(i):
			rig.apply_damage(i, float(rig.state.hp[i]))
	rig.flush_visuals()
	var after: Vector3 = rig.alive_centre_local()
	assert_eq(rig.state.alive_count(), 1, "只剩核心")
	assert_vec_almost_eq(after, core_box.get_center(), 0.001, "只剩核心时瞄点到核心盒中心")
	assert_true(
		full.distance_to(after) > 0.5,
		"打掉偏在一侧的零件后瞄点必须挪动：%s -> %s" % [str(full), str(after)]
	)
	body.free()

## 炮塔的"支架独立碰撞盒"开关：默认关（并进合并盒）；打开才单独一个 shape。
func test_swivel_collider_flag() -> void:
	var library := _library()
	var def := library.get_def("light_mg_x2")
	assert_true(def != null, "缺少 light_mg_x2")
	if def == null:
		return
	# 默认（部件文件里写的是 false）：炮塔也并进合并盒，没有独立 shape
	assert_true(not def.weapon_swivel_collider, "两种机枪默认都不单独建盒")
	var vehicle := VehicleDef.from_text(
		(
			"name = 炮塔碰撞盒测试\n"
			+ "part = core 0 0 0 0 0 0\n"
			+ "part = light_mg_x2 0 1 0 0 0 0\n"
		),
		"user://swivel_probe.vehicle.txt"
	)
	var body := StaticBody3D.new()
	var rig := VehicleRig.new()
	rig.setup(vehicle, library, body, body, false, Vector3.ZERO)
	assert_true(rig.shapes.is_empty(), "默认没有独立碰撞盒：%d" % rig.shapes.size())
	assert_true((rig._merged_shapes as Array).size() >= 1, "炮塔底座并进了合并盒")
	body.free()
	# 打开开关（模拟以后的复杂炮塔）：必须单独一个独立盒，而且对应炮塔零件
	def.weapon_swivel_collider = true
	var body2 := StaticBody3D.new()
	var rig2 := VehicleRig.new()
	rig2.setup(vehicle, library, body2, body2, false, Vector3.ZERO)
	assert_eq(rig2.shapes.size(), 1, "打开开关后有一个独立盒：%d" % rig2.shapes.size())
	assert_eq(rig2._shape_part, [1], "独立盒对应炮塔零件（下标 1）")
	body2.free()

## 命中点反查：格子快路径必须和"暴力扫所有盒子"给出同样的结果。
func test_part_lookup_fast_path_matches_brute_force() -> void:
	var library := _library()
	var vehicle := VehicleDef.from_text(
		(
			"name = 反查测试\n"
			+ "part = core 0 0 0 0 0 0\n"
			+ "part = cube_full 2 0 0 0 0 0\n"
			+ "part = cube_full 2 1 0 0 0 0\n"
			+ "part = toy_wheel_2x2 4 0 0 0 0 0\n"
		),
		"user://lookup_probe.vehicle.txt"
	)
	var body := StaticBody3D.new()
	var rig := VehicleRig.new()
	rig.setup(vehicle, library, body, body, false, Vector3.ZERO)
	assert_true(not (rig.get("_cell_part") as Dictionary).is_empty(), "格子表建起来了")
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var checked := 0
	var mismatched := 0
	for _i in 200:
		# 在所有零件盒的范围内随机撒点（含盒子表面附近）
		var i := rng.randi_range(0, rig.state.part_count() - 1)
		var box: AABB = rig.part_box(i)
		var point := Vector3(
			rng.randf_range(box.position.x - 0.1, box.end.x + 0.1),
			rng.randf_range(box.position.y - 0.1, box.end.y + 0.1),
			rng.randf_range(box.position.z - 0.1, box.end.z + 0.1)
		)
		var fast: int = rig.call("_part_at_local", point)
		# 暴力：所有盒子里"中心最近"的那个活零件
		var brute := -1
		var best := INF
		for j in rig.state.part_count():
			if not rig.part_alive(j):
				continue
			var candidate: AABB = (rig.part_box(j) as AABB).grow(0.02)
			if candidate.has_point(point):
				var distance: float = candidate.get_center().distance_squared_to(point)
				if distance < best:
					best = distance
					brute = j
		checked += 1
		if brute >= 0 and fast != brute:
			mismatched += 1
	assert_eq(mismatched, 0, "快路径和暴力结果一致（查了 %d 个点）" % checked)
	body.free()
