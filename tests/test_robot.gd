@tool
extends McpTestSuite

## 机器人层面的规则：部件数值（重量/血量/pp）、核心唯一、点数预算、进测试场的前置条件。

const PART_DIR := "res://data/parts"


func suite_name() -> String:
	return "robot"


func _library() -> PartLibrary:
	var library := PartLibrary.new()
	library.load_all(PART_DIR)
	return library


## 浮点比较（测试框架只给了 assert_eq）：差值超过 tol 就当失败。
func assert_almost_eq(actual: float, expected: float, tol: float, msg: String = "") -> void:
	assert_true(
		absf(actual - expected) <= tol,
		"%s（实际 %s，期望 %s）" % [msg, str(actual), str(expected)]
	)


## 所有部件都要有这三个基本数值（具体数字由用户手调，测试只看"有没有、合不合理"）。
func test_every_part_has_the_three_stats() -> void:
	var library := _library()
	for id in library.ids():
		var def: PartDef = library.get_def(id)
		assert_true(def.weight_kg > 0.0, "%s 应有重量" % id)
		assert_true(def.hp > 0, "%s 应有血量" % id)
		# pp 可以是 0（比如把核心调成不花点数），但不能是负数
		assert_true(def.pp >= 0, "%s 的 pp 不该是负数：%d" % [id, def.pp])
	# 没写这三行的部件走默认值：1kg / 1000 血 / 1pp
	var bare := PartDef.from_text(
		"name = 裸参数\nshape = cube\ncubes = 1 1 1\n", "res://data/parts/test_bare.part.txt"
	)
	assert_true(is_equal_approx(bare.weight_kg, 1.0), "默认重量 1kg：%s" % str(bare.weight_kg))
	assert_eq(bare.hp, 1000, "默认血量 1000")
	assert_eq(bare.pp, 1, "默认 1pp")


## 核心：2x2x1、亮蓝主体 + 灰色棱、带 core 标记。
func test_core_part_is_flagged_and_shaped_2x2x1() -> void:
	var library := _library()
	var core := library.get_def("core")
	assert_true(core != null, "应有 core 部件文件")
	assert_true(core.is_core, "core 应带 core = true")
	assert_eq(core.cubes, Vector3i(2, 2, 1), "核心是 2 x 2 x 1")
	assert_eq(core.connection_faces().size(), 6, "核心六个面都能接")
	assert_eq(core.default_connection_face(), Vector3i(0, -1, 0), "默认连接点在下方")
	# 亮蓝主体（蓝分量明显压过红/绿）+ 灰色棱
	assert_true(
		core.body_color.b > core.body_color.r + 0.3 and core.body_color.b > core.body_color.g + 0.2,
		"主体应偏亮蓝：%s" % core.body_color
	)
	assert_true(
		absf(core.edge_color.r - core.edge_color.g) < 0.1
		and absf(core.edge_color.g - core.edge_color.b) < 0.1,
		"棱应是灰色：%s" % core.edge_color
	)
	assert_false(library.get_def("cube_full").is_core, "方块不是核心")


## 重心 = 零件几何中心（读的是缓存的包围盒，游戏里每帧问也是 O(1)）；`center` 可覆盖。
func test_center_of_mass_is_geometric_center() -> void:
	var library := _library()
	var axle := library.get_def("wheel_axle_2x2")
	var centre := axle.center_of_mass()
	assert_true(centre.is_equal_approx(axle.mesh_bounds().get_center()), "重心应等于几何中心")
	assert_true(axle.center_of_mass().is_equal_approx(centre), "重心应稳定（缓存）")
	var overridden := PartDef.from_text(
		"name = 测试重心\nshape = cube\ncubes = 1 1 1\ncenter = 0 16 0\n",
		"res://data/parts/test_center.part.txt"
	)
	assert_eq(overridden.warnings.size(), 0, "center 不该有警告：%s" % str(overridden.warnings))
	assert_true(
		overridden.center_of_mass().is_equal_approx(Vector3(0, 1, 0)),
		"center 覆盖应生效：%s" % overridden.center_of_mass()
	)


## 一台机器人最多一个核心。
func test_two_cores_are_refused() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var core := library.get_def("core")
	assert_true(grid.place(core, Vector3i(0, 0, 0), Basis())["ok"], "第一个核心应能放下")
	assert_true(grid.has_core(), "has_core 应为真")
	var second := grid.can_place(core, Vector3i(4, 0, 0), Basis())
	assert_false(second["ok"], "第二个核心应被拒绝")
	assert_true(str(second["reason"]).contains("核心"), "理由应提到核心：%s" % second["reason"])


## 部件点数上限 2000：超了就放不下，理由里要说清。
func test_pp_budget_blocks_over_limit() -> void:
	var library := _library()
	var pricey := PartDef.from_text(
		"name = 占满预算\nshape = cube\ncubes = 1 1 1\npp = 2000\n",
		"res://data/parts/test_pricey.part.txt"
	)
	library.defs[pricey.id] = pricey
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_true(
		grid.place(pricey, Vector3i(0, 0, 0), Basis())["ok"], "占满预算的那件应能放下"
	)
	assert_eq(int(grid.totals()["pp"]), BuildGrid.PP_LIMIT, "总点数应正好到上限")
	var blocked := grid.can_place(library.get_def("cube_full"), Vector3i(3, 0, 0), Basis())
	assert_false(blocked["ok"], "超过 2000 点应被拒绝")
	var reason := str(blocked["reason"])
	assert_true(reason.contains("点数"), "理由应说清是点数不够：%s" % reason)
	assert_true(reason.contains("2000"), "理由里应带上限：%s" % reason)


## totals()：总点数 / 总重量 / 总血量，带缓存但会随场地变化失效。
func test_totals_track_the_grid() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var core := library.get_def("core")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_eq(int(grid.totals()["pp"]), 0, "空场地 0pp")
	assert_true(grid.place(cube, Vector3i(0, 0, 0), Basis())["ok"], "放方块")
	assert_true(grid.place(core, Vector3i(2, 0, 0), Basis())["ok"], "放核心")
	var totals := grid.totals()
	assert_eq(int(totals["pp"]), cube.pp + core.pp, "总点数 = 两件之和")
	assert_true(
		is_equal_approx(float(totals["weight"]), cube.weight_kg + core.weight_kg), "总重量 = 两件之和"
	)
	assert_eq(int(totals["hp"]), cube.hp + core.hp, "总血量 = 两件之和")
	assert_true(grid.remove(Vector3i(2, 0, 0), "core"), "拆掉核心")
	assert_eq(int(grid.totals()["pp"]), cube.pp, "拆掉核心后只剩方块的点数")


## 进测试场的前置条件：有核心，而且所有零件都和核心连通。
func test_entry_requires_core_and_full_connection() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var cube := library.get_def("cube_full")
	var core := library.get_def("core")
	# 空场：没有核心
	assert_false(bool(grid.robot_status()["ok"]), "空场地不能进测试场")
	assert_false(bool(grid.robot_status()["has_core"]), "空场地 has_core 应为假")
	# 有零件但没核心：理由要说清是缺核心
	assert_true(grid.place(cube, Vector3i(0, 5, 0), Basis())["ok"], "先放一块没核心的方块")
	var no_core := grid.robot_status()
	assert_false(bool(no_core["ok"]), "没核心不能进测试场")
	assert_true(str(no_core["reason"]).contains("核心"), "理由应说还没装核心：%s" % no_core["reason"])
	assert_true(grid.remove(Vector3i(0, 5, 0), cube.id), "清掉")
	# 只有核心：它自己跟自己连着，算合法
	assert_true(grid.place(core, Vector3i(0, 0, 0), Basis())["ok"], "放核心")
	assert_true(bool(grid.robot_status()["ok"]), "只有核心时应合法：%s" % str(grid.robot_status()))
	# 贴一块方块：仍然合法
	assert_true(grid.place(cube, Vector3i(2, 0, 0), Basis())["ok"], "贴一块方块")
	assert_true(bool(grid.robot_status()["ok"]), "连着核心的方块合法")
	# 再放一块**没连**的方块：整体就不合法了，而且要报出是哪一个
	assert_true(grid.place(cube, Vector3i(0, 5, 0), Basis())["ok"], "悬空方块放得下（建造期不管）")
	var status := grid.robot_status()
	assert_false(bool(status["ok"]), "有零件没连到核心 → 不能进测试场")
	assert_eq(status["connected"], 2, "连到核心的应是 2 件（核心 + 贴着的方块）")
	assert_eq(
		(status["detached"] as Array).size(), 1, "应报出 1 个未连接零件：%s" % str(status["detached"])
	)
	assert_true(str(status["reason"]).contains("没和核心连"), "理由应说清未连接：%s" % status["reason"])


## 拆一个零件再装回去之后，"能不能进测试场"的结论要跟着回来。
##
## 这条守的是用户报的那个**假警报**：连接账本（`links` / `link_parts`）的小面 key 是
## "格子 + 方向"、不带零件身份，而且一对一面是**覆盖写**；拆除时 `_remove_entry()` 还会
## 顺手清掉"对面"的条目（那可能是别的零件在用的）。账本一旦被拆坏，就会误报
## "有零件没和核心连在一起"—— 而同一台车存盘后照清单重建又能过，症状就是
## "建造模式说没连上、存盘进测试场却没事"。
##
## 现在判定按**几何现算**（`link_pairs()`），和账本无关，所以这条必须稳。
func test_entry_check_survives_remove_and_replace() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var cube := library.get_def("cube_full")
	var core := library.get_def("core")
	assert_true(grid.place(core, Vector3i(0, 0, 0), Basis())["ok"], "放核心")
	assert_true(grid.place(cube, Vector3i(2, 0, 0), Basis())["ok"], "贴第一块")
	assert_true(grid.place(cube, Vector3i(3, 0, 0), Basis())["ok"], "再贴第二块（挂在第一块上）")
	assert_true(bool(grid.robot_status()["ok"]), "三件都连着")
	# 拆中间那块：最外那块几何上确实跟着断了
	assert_true(grid.remove(Vector3i(2, 0, 0), cube.id), "拆中间那块")
	var broken := grid.robot_status()
	assert_false(bool(broken["ok"]), "断开的零件要报出来")
	assert_eq(broken["connected"], 1, "只剩核心连着：%s" % str(broken))
	# 装回去：必须重新合法，而且理由清空（这就是用户报的那一步）
	assert_true(grid.place(cube, Vector3i(2, 0, 0), Basis())["ok"], "把中间那块装回去")
	var fixed := grid.robot_status()
	assert_true(bool(fixed["ok"]), "装回去之后必须重新合法：%s" % str(fixed))
	assert_eq(fixed["connected"], 3, "三件都连着")
	assert_true(str(fixed["reason"]).is_empty(), "合法时不该有理由")
	# 再拆最外那块（它只连着中间那块）也不该影响别的零件
	assert_true(grid.remove(Vector3i(3, 0, 0), cube.id), "拆最外那块")
	assert_true(bool(grid.robot_status()["ok"]), "剩下的仍然连着")


## 连通图按**几何**数：挨着的才算一对；悬空的零件不产生任何连接。
func test_link_pairs_counts_geometric_neighbours() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var cube := library.get_def("cube_full")
	var core := library.get_def("core")
	grid.place(core, Vector3i(0, 0, 0), Basis())
	assert_eq((grid.link_pairs() as Array).size(), 0, "只有一个核心：没有任何一对")
	grid.place(cube, Vector3i(2, 0, 0), Basis())
	assert_eq((grid.link_pairs() as Array).size(), 1, "贴一块：正好一对")
	grid.place(cube, Vector3i(3, 0, 0), Basis())
	assert_eq((grid.link_pairs() as Array).size(), 2, "再贴一块：链式两对")
	grid.place(cube, Vector3i(0, 9, 0), Basis())
	assert_eq((grid.link_pairs() as Array).size(), 2, "悬空那件不算连接（几何上没挨着）")


## 轮子的动力/悬挂参数写在**部件文件**里（用户自己调）：解析要稳，
## 没写这些键的部件要有能用的默认值（不能变成 0 导致车不动）。
func test_wheel_parameters_live_in_the_part_file() -> void:
	var library := _library()
	var axle := library.get_def("wheel_axle_2x2")
	assert_true(axle != null, "缺少轮轴部件")
	assert_true(axle.wheel_engine_force > 0.0, "推力应 > 0：%s" % axle.wheel_engine_force)
	assert_true(axle.wheel_brake > 0.0, "刹车力应 > 0：%s" % axle.wheel_brake)
	assert_true(axle.wheel_max_speed > 0.0, "限速应 > 0：%s" % axle.wheel_max_speed)
	assert_true(axle.wheel_friction > 0.0, "抓地力应 > 0：%s" % axle.wheel_friction)
	assert_true(axle.wheel_steer_max > 0.0, "转向角应 > 0：%s" % axle.wheel_steer_max)
	assert_true(
		axle.wheel_steer_speed > 0.0,
		"转向角速度应 > 0（车轮缓启动的速率）：%s" % axle.wheel_steer_speed
	)
	assert_true(axle.wheel_rest_length > 0.0, "悬挂静止压缩量应 > 0：%s" % axle.wheel_rest_length)
	assert_true(axle.wheel_suspension_travel > 0.0, "悬挂行程应 > 0：%s" % axle.wheel_suspension_travel)
	# 悬挂现在是**直接值**：刚度 N/格、阻尼 N·秒/格（不再有倍率/参考值那一套）
	assert_true(axle.wheel_stiffness > 0.0, "弹簧刚度应 > 0：%s" % axle.wheel_stiffness)
	assert_true(axle.wheel_damper_compression > 0.0, "压缩阻尼应 > 0：%s" % axle.wheel_damper_compression)
	assert_true(axle.wheel_damper_relaxation > 0.0, "回弹阻尼应 > 0：%s" % axle.wheel_damper_relaxation)
	assert_true(
		axle.wheel_suspension_max_force > 0.0, "悬挂最大力应 > 0：%s" % axle.wheel_suspension_max_force
	)
	assert_true(axle.wheel_radius >= 0.0, "半径 0 表示按模型自动算")
	# 自定义轮胎的手感旋钮：都必须能从部件文件读到（用户直接调这些）
	assert_true(axle.wheel_rays >= 3, "整圈射线条数应 >= 3：%s" % axle.wheel_rays)
	assert_true(axle.wheel_slip_ref > 0.0, "滑移参考速度应 > 0：%s" % axle.wheel_slip_ref)
	assert_true(axle.wheel_grip_gain > 0.0, "横向抓地增益应 > 0：%s" % axle.wheel_grip_gain)
	assert_true(axle.wheel_brake_gain > 0.0, "刹车增益应 > 0：%s" % axle.wheel_brake_gain)
	assert_true(
		axle.wheel_anti_roll_tilt_deg > 0.0,
		"防翻倾角上限应 > 0（单位是度，0 = 关掉）：%s" % axle.wheel_anti_roll_tilt_deg
	)
	# 抓地力：2026-10-15 起住在 `wheel_grip_factor` 和 `wheel_lat_pacejka` 的 peak 里
	# （`wheel_mu` 那套是老模型的换算，已经不用了）。验证"能从部件文件读到、并且能超过老上限"。
	assert_true(axle.wheel_grip_factor > 0.0, "抓地倍率应 > 0：%s" % axle.wheel_grip_factor)
	var grippy := PartDef.from_text(
		"name = 粘地\nshape = cube\ncubes = 1 1 1\nwheel_grip_factor = 1.8\nwheel_lat_pacejka = 1.8 10 0 1.35\n",
		"res://data/parts/test_grip_high.part.txt"
	)
	assert_true(
		grippy.wheel_grip_factor > 1.2 and float(grippy.wheel_lat_pacejka[0]) > 1.2,
		"抓地力应能超过老版本的 1.2 上限：%s / %s"
			% [grippy.wheel_grip_factor, str(grippy.wheel_lat_pacejka)]
	)
	# 默认值：普通方块没写这些键，也得有一组能用的
	var bare := PartDef.from_text(
		"name = 裸轮参数\nshape = cube\ncubes = 1 1 1\n", "res://data/parts/test_bare_wheel.part.txt"
	)
	assert_eq(bare.warnings.size(), 0, "不该有警告：%s" % str(bare.warnings))
	assert_true(
		bare.wheel_engine_force > 0.0 and bare.wheel_suspension_max_force > 0.0
		and bare.wheel_max_speed > 0.0,
		"默认轮子参数要能用：%s / %s / %s"
		% [bare.wheel_engine_force, bare.wheel_suspension_max_force, bare.wheel_max_speed]
	)
	# 写歪了要各留一条警告，并且保留原值
	var bad := PartDef.from_text(
		"name = 歪参数\nshape = cube\ncubes = 1 1 1\nwheel_engine_force = abc\nwheel_max_speed = -1\n",
		"res://data/parts/test_bad_wheel.part.txt"
	)
	assert_true(bad.warnings.size() >= 2, "写歪的轮子参数应各留一条警告：%s" % str(bad.warnings))
	assert_true(
		bad.wheel_engine_force > 0.0 and bad.wheel_max_speed > 0.0, "解析失败应保留原值（车还能开）"
	)


## 抓地力（mu）和 `wheel_friction` 的关系 —— 用户踩过的坑：
## 旧版 `mu = clamp(friction × 0.06, 0.2, 1.2)`，5000 被夹成 1.2，所以"调 friction 完全没反应"。
func test_wheel_grip_is_tunable_past_the_old_cap() -> void:
	# ① wheel_mu 直接生效，和 wheel_friction 无关
	var direct := PartDef.from_text(
		"name = 直接给 mu\nshape = cube\ncubes = 1 1 1\nwheel_mu = 1.8\nwheel_friction = 3\n",
		"res://data/parts/test_mu_direct.part.txt"
	)
	assert_eq(direct.warnings.size(), 0, "不该有警告：%s" % str(direct.warnings))
	assert_almost_eq(direct.resolved_wheel_mu(), 1.8, 0.0001, "wheel_mu 应直接生效")
	# ② 不写 wheel_mu 才走换算，而且上限不再是 1.2（旧版这里会被夹成 1.2）
	var derived := PartDef.from_text(
		"name = 换算\nshape = cube\ncubes = 1 1 1\nwheel_friction = 20\n",
		"res://data/parts/test_mu_derived.part.txt"
	)
	assert_almost_eq(derived.resolved_wheel_mu(), 1.6, 0.0001, "20 × 0.08 = 1.6")
	var big := PartDef.from_text(
		"name = 大数\nshape = cube\ncubes = 1 1 1\nwheel_friction = 5000\n",
		"res://data/parts/test_mu_big.part.txt"
	)
	assert_almost_eq(big.resolved_wheel_mu(), 5.0, 0.0001, "5000 × 0.08 = 400 → 夹到上限 5.0")
	# ③ 上限本身可调
	var capped := PartDef.from_text(
		"name = 改上限\nshape = cube\ncubes = 1 1 1\nwheel_friction = 100\nwheel_mu_max = 2.0\n",
		"res://data/parts/test_mu_capped.part.txt"
	)
	assert_almost_eq(capped.resolved_wheel_mu(), 2.0, 0.0001, "100 × 0.08 = 8 → 夹到 2.0")


## 手感旋钮写歪了要保留原值 + 告警（不能出现"参数写歪 → 车动不了"）。
func test_wheel_tuning_keys_are_parsed_and_guarded() -> void:
	var tuned := PartDef.from_text(
		"name = 调过\nshape = cube\ncubes = 1 1 1\n"
		+ "wheel_rays = 12\nwheel_ray_slack = 0.1\nwheel_sus_sector = 0.7\n"
		+ "wheel_slip_falloff = 0.15\nwheel_slip_ref = 30\nwheel_grip_gain = 1800\n"
		+ "wheel_brake_gain = 5000\nwheel_roll_gain = 1.5\nwheel_mu_per_friction = 0.05\n"
		+ "wheel_mu_max = 3.0\nwheel_stiffness = 80000\nwheel_damper_compression = 1200\n"
		+ "wheel_damper_relaxation = 1800\nwheel_rest_length = 0.2\n"
		+ "wheel_suspension_travel = 0.25\nwheel_suspension_max_force = 40000\n"
		+ "wheel_anti_roll_tilt = 10\nwheel_anti_roll_damping = 0.7\n"
		+ "wheel_steer_speed = 120\nwheel_steer_return_speed = 300\n",
		"res://data/parts/test_wheel_tuned.part.txt"
	)
	assert_eq(tuned.warnings.size(), 0, "不该有警告：%s" % str(tuned.warnings))
	assert_eq(tuned.wheel_rays, 12, "射线条数")
	assert_almost_eq(tuned.wheel_ray_slack, 0.1, 0.0001, "射线余量")
	assert_almost_eq(tuned.wheel_sus_sector, 0.7, 0.0001, "悬挂扇区阈值")
	assert_almost_eq(tuned.wheel_slip_falloff, 0.15, 0.0001, "滑移衰减")
	assert_almost_eq(tuned.wheel_slip_ref, 30.0, 0.0001, "滑移参考速度")
	assert_almost_eq(tuned.wheel_grip_gain, 1800.0, 0.0001, "横向抓地增益")
	assert_almost_eq(tuned.wheel_brake_gain, 5000.0, 0.0001, "刹车增益")
	assert_almost_eq(tuned.wheel_roll_gain, 1.5, 0.0001, "滚动阻力")
	assert_almost_eq(tuned.wheel_mu_per_friction, 0.05, 0.0001, "换算比例")
	assert_almost_eq(tuned.wheel_mu_max, 3.0, 0.0001, "抓地上限")
	# 悬挂是直接值：写多少就是多少
	assert_almost_eq(tuned.wheel_stiffness, 80000.0, 0.0001, "弹簧刚度 N/格")
	assert_almost_eq(tuned.wheel_damper_compression, 1200.0, 0.0001, "压缩阻尼 N·秒/格")
	assert_almost_eq(tuned.wheel_damper_relaxation, 1800.0, 0.0001, "回弹阻尼 N·秒/格")
	assert_almost_eq(tuned.wheel_rest_length, 0.2, 0.0001, "悬挂自由长度（格）")
	assert_almost_eq(tuned.wheel_suspension_travel, 0.25, 0.0001, "行程上限（格）")
	assert_almost_eq(tuned.wheel_suspension_max_force, 40000.0, 0.0001, "支撑力上限")
	assert_almost_eq(tuned.wheel_anti_roll_tilt_deg, 10.0, 0.0001, "防翻倾角（度）")
	assert_almost_eq(tuned.wheel_anti_roll_damping, 0.7, 0.0001, "防翻阻尼")
	assert_almost_eq(tuned.wheel_steer_speed, 120.0, 0.0001, "打方向角速度（度/秒）")
	assert_almost_eq(
		tuned.resolved_steer_return_speed(), 300.0, 0.0001, "写了回正速度就用它（度/秒）"
	)
	# 写歪：保留原值 + 告警（射线条数太少也不行）
	var bad := PartDef.from_text(
		"name = 歪\nshape = cube\ncubes = 1 1 1\nwheel_rays = -1\nwheel_slip_ref = 0\nwheel_mu = -1\n",
		"res://data/parts/test_wheel_bad_tuning.part.txt"
	)
	assert_eq(bad.wheel_rays, 16, "射线条数写 -1 应保留默认 16（0 是合法的单射线模式）")
	assert_almost_eq(bad.wheel_slip_ref, 16.0, 0.0001, "滑移参考写了 0 应保留默认")
	assert_almost_eq(bad.wheel_mu, 0.0, 0.0001, "mu 负值应保留默认 0")
	assert_eq(bad.warnings.size(), 3, "三个写歪的键应各留一条警告：%s" % str(bad.warnings))


## `wheel_rays = 0` = 纯单射线模式（整圈射线全关）——用户可以用它 A/B "最早那种单射线手感"。
func test_zero_rays_means_single_ray_mode() -> void:
	var single := PartDef.from_text(
		"name = 单射线\nshape = cube\ncubes = 1 1 1\nwheel_rays = 0\n",
		"res://data/parts/test_wheel_single_ray.part.txt"
	)
	assert_eq(single.warnings.size(), 0, "0 是合法值，不该有警告：%s" % str(single.warnings))
	assert_eq(single.wheel_rays, 0, "整圈射线应被关掉")
	# 漏掉这一行 / 写歪时还是回到默认的 16 条
	var dflt := PartDef.from_text(
		"name = 默认\nshape = cube\ncubes = 1 1 1\n", "res://data/parts/test_wheel_default_rays.part.txt"
	)
	assert_eq(dflt.wheel_rays, 16, "没写 wheel_rays 应取默认 16")


## 整圈射线的"悬挂扇区"判据：**轮子正下方那一片必须跳过**。
## 这条测试给符号上锁 —— 判据曾经写成 `dir · up`（写反了），结果正下方 5 条射线全留在场上：
## 平地上每个轮子多出 2~3 个接触点，支撑刚度/阻尼/抓地随压缩量跳变（"平地也飘、还不稳"）。
func test_ring_rays_skip_the_suspension_sector_under_the_wheel() -> void:
	var down := Vector3(0.0, -1.0, 0.0)
	var sus := Vector3(0.0, 1.0, 0.0)
	var fwd := Vector3(1.0, 0.0, 0.0)
	var cast := 0
	var cast_under := 0
	for i in 16:
		var angle := TAU * float(i) / 16.0
		var dir := (sus * cos(angle) + fwd * sin(angle)).normalized()
		if TestField.ring_ray_belongs_to_suspension(dir, down, 0.5):
			continue
		cast += 1
		if dir.dot(down) > 0.5:
			cast_under += 1
	assert_eq(cast_under, 0, "平地上不该有射线落在轮子正下方（那会跟悬挂射线并联）")
	assert_eq(cast, 11, "16 条射线应只剩 11 条（正下方 60° 那 5 条归悬挂）")
	# 正下方 / 正下方斜 22.5° 必须跳过；正前方、正上方不跳
	assert_true(TestField.ring_ray_belongs_to_suspension(down, down, 0.5), "正下方要跳过")
	assert_true(
		TestField.ring_ray_belongs_to_suspension(Vector3(0.3827, -0.9239, 0.0), down, 0.5), "正下方斜 22.5° 要跳过"
	)
	assert_false(TestField.ring_ray_belongs_to_suspension(fwd, down, 0.5), "正前方不能跳")
	assert_false(TestField.ring_ray_belongs_to_suspension(sus, down, 0.5), "正上方不能跳")


## 悬挂现在是"一个物理量一个参数"：刚度 N/格直接填，静止压缩量 = 负载 ÷ 刚度（算出来的）。
## 硬点按它抬，所以静止时轮心正好落在作者摆的位置（轮胎底面贴地、不入地）。
## 这条测试盯的就是"硬点用的压缩量 == 弹簧真正的平衡位置"。
func test_wheel_hub_keeps_the_authored_ride_height() -> void:
	var rest := 0.15
	for wheel_load: float in [400.0, 1972.0, 8000.0]:
		for stiffness: float in [20000.0, 62000.0, 250000.0, 2480000.0]:
			var settled := wheel_load / stiffness        # 弹簧平衡位置（纯物理）
			var assumed := TestField.compression_at_rest(wheel_load, stiffness, rest)
			if settled > rest:
				# 软到压穿：模型会夹在 `rest`（不然轮心会跑到硬点上面去）
				assert_almost_eq(assumed, rest, 0.0001, "压穿时夹在 rest")
				continue
			if settled < 0.005:
				# 硬到几乎压不动：模型会夹在最小值 0.005 格（3 毫米），别让轮心跑到作者位上面去
				assert_almost_eq(assumed, 0.005, 0.0001, "压不动时夹在下限 0.005 格")
				continue
			assert_almost_eq(
				assumed, settled, 0.0005,
				"负载 %s / 刚度 %s：硬点用的压缩量要等于弹簧平衡位置" % [wheel_load, stiffness]
			)
	# 一台车的实际数（举例）：608 kg / 8 轮 = 76 kg → 重量 76 kg × 19.6 格/秒² = 1490 N
	assert_almost_eq(
		TestField.compression_at_rest(1490.0, 62000.0, rest), 0.024, 0.001, "62000 刚度 → 压 0.024 格"
	)
	# 2480000 刚度下物理压缩量只有 0.0006 格 → 会被夹到下限 0.005（等于几乎压不动）
	assert_almost_eq(
		TestField.compression_at_rest(1490.0, 2480000.0, rest), 0.005, 0.0001, "硬到夹下限"
	)


## 行程够不够：压到行程就到底、支撑力不再涨（车身贴地走、看着像"入地"）。
## 这条把判据钉住 —— 用户踩过：行程只有静态下沉的几倍，8 个轮子里 4 个卡在行程上。
## （下面的 0.3 / 0.06 只是"一组数"，验的是判据 = 5 倍，不是某台车的实际值。）
func test_suspension_travel_must_be_several_times_the_static_sag() -> void:
	# 静态下沉 0.06 格（62000 刚度、3724 N 负载）时，0.3 的行程只有 5 倍 → 太短
	assert_true(TestField.travel_is_too_short(0.3, 0.06), "5 倍以内要判太短（用户那套就是 0.3/0.06）")
	assert_true(TestField.travel_is_too_short(0.2, 0.06), "3 倍更要判太短")
	assert_false(TestField.travel_is_too_short(0.6, 0.06), "10 倍够用")
	assert_false(TestField.travel_is_too_short(1.2, 0.06), "20 倍（软悬挂推荐）够用")
	# 硬悬挂（静态只压 0.005）时短行程也没问题：底盘几乎不动
	assert_false(TestField.travel_is_too_short(0.3, 0.005), "压不动就不需要长行程")


## 判定射线挪到**轮胎外侧**：`outboard_shift()` 要按"轮心相对底盘中心在轴的哪一侧"
## 决定符号 —— 左右两侧的挂载是镜像的，符号搞反就会把射线挪到轮胎**里侧**。
func test_ray_offset_goes_outboard_on_both_sides() -> void:
	var axle := Vector3(0.0, 0.0, 1.0)      # 轮轴朝 +z
	# 右侧轮子在 +z 一侧：rxle
	assert_almost_eq(
		TestField.outboard_shift(Vector3(0, 0, 3), Vector3.ZERO, axle, 0.4), 0.4, 0.0001,
		"+z 侧的轮子要往 +z 挪"
	)
	# 左侧轮子在 -z 一侧，但轮轴方向是镜像的：沿轴算出来是负 → 符号要翻
	assert_almost_eq(
		TestField.outboard_shift(Vector3(0, 0, -3), Vector3.ZERO, axle, 0.4), -0.4, 0.0001,
		"-z 侧的轮子要往 -z 挪（不能挪进车里）"
	)
	# 轮轴指向反了也一样判断（关键看轮心在哪一侧，不是轴的写法）
	assert_almost_eq(
		TestField.outboard_shift(Vector3(0, 0, -3), Vector3.ZERO, -axle, 0.4), 0.4, 0.0001,
		"轴反向写也是往外挪"
	)
	# 施加时沿的是"轮胎节点的局部 x"：它和轮轴可能反向（镜像挂载），符号要跟着翻
	assert_almost_eq(
		TestField.shift_along_local_x(0.4, axle, axle), 0.4, 0.0001,
		"局部 x 和轮轴同向：照抄"
	)
	assert_almost_eq(
		TestField.shift_along_local_x(0.4, -axle, axle), -0.4, 0.0001,
		"局部 x 和轮轴反向：翻号（否则会挪到轮胎里侧）"
	)
	assert_almost_eq(
		TestField.shift_along_local_x(0.4, Vector3(1, 0, 0), axle), 0.0, 0.0001,
		"局部 x 和轮轴不平行：不动（别乱挪）"
	)


## 全局"自动回正"力矩（`data/handling.txt` 第 ② 条）：方向必须是把车身的 up
## 往世界竖直方向拧。判据：力矩产生的角加速度会让 up 朝世界 up 转 ——
## 也就是 `(τ × up) · 世界up > 0`（τ × up 正是 up 的转动速度方向）。
func test_upright_torque_twists_up_toward_vertical() -> void:
	var inertia := 100.0
	# 正了就不出力（不然平地也会一直拧，车自己抖）
	assert_eq(
		TestField.upright_torque(Vector3.UP, Vector3.ZERO, 60000.0, inertia, 0.0), Vector3.ZERO,
		"车身竖直时回正力矩为 0"
	)
	# 往几个方向倾斜（含斜后），力矩都得把 up 往 +y 拧
	for raw in [Vector3(0.5, 0.8, 0.0), Vector3(0.0, 0.8, 0.5), Vector3(-0.4, 0.7, 0.3)]:
		var up: Vector3 = (raw as Vector3).normalized()
		var tau := TestField.upright_torque(up, Vector3.ZERO, 60000.0, inertia, 0.0)
		assert_true(tau.length() > 0.0, "倾了就要有力矩：up=%s" % up)
		var vertical_gain := tau.cross(up).dot(Vector3.UP)
		assert_true(vertical_gain > 0.0, "力矩要把 up 拧向竖直：gain=%s" % vertical_gain)
	# 倾角越大越狠（按 sin 缩放）：90° 最大，小倾角最弱
	var small := TestField.upright_torque(
		Vector3(0.17, 0.985, 0.0).normalized(), Vector3.ZERO, 60000.0, inertia, 0.0
	)
	var flat := TestField.upright_torque(Vector3.RIGHT, Vector3.ZERO, 60000.0, inertia, 0.0)
	assert_true(flat.length() > small.length(), "倾得越厉害拉得越狠")
	assert_almost_eq(flat.length(), 60000.0, 0.5, "90° 时正好等于设定的最大力矩")


## 回正阻尼：只吃"倾斜速率"（把车身正在往哪边倒的那份速度吃掉），不碰自转。
func test_upright_damping_only_brakes_tilt_rate() -> void:
	var up: Vector3 = Vector3(0.0, 0.8, 0.5).normalized()
	var inertia := 100.0
	var free := TestField.upright_torque(up, Vector3.ZERO, 60000.0, inertia, 0.0)
	# 倾速率沿世界 +x（与车身 up 垂直）：阻尼要让力矩朝 -x 偏
	var rate := Vector3(1.0, 0.0, 0.0)
	var damped := TestField.upright_torque(up, rate, 60000.0, inertia, 0.6)
	var delta := damped - free
	assert_true(delta.dot(rate) < 0.0, "阻尼要和倾倒速度反着来：delta=%s" % delta)
	assert_true(delta.length() > 0.0, "有阻尼就该和没阻尼不一样")
	# 沿车身 up 的自转（打转）不该被回正力矩管
	var spin := TestField.upright_torque(up, up * 5.0, 60000.0, inertia, 0.6)
	assert_true(
		(spin - free).length() < 0.0001, "绕着车身 up 自转不该被回正阻尼拉住"
	)


## 松手回正（偏航）：没写 `wheel_steer_return_speed` 时回正速度 = 打方向速度（老行为）；
## 写了就用写的那个（下限 1°/s，免得写成 0 变成"永远回不了中"）。
func test_steer_return_speed_falls_back_to_steer_speed() -> void:
	var plain := PartDef.from_text(
		"name = 普通\nshape = cube\ncubes = 1 1 1\nwheel_steer_speed = 45\n",
		"res://data/parts/test_wheel_return_plain.part.txt"
	)
	assert_almost_eq(plain.resolved_steer_return_speed(), 45.0, 0.0001, "没写 → 跟打方向同速")
	var fast := PartDef.from_text(
		"name = 快回正\nshape = cube\ncubes = 1 1 1\n"
		+ "wheel_steer_speed = 45\nwheel_steer_return_speed = 240\n",
		"res://data/parts/test_wheel_return_fast.part.txt"
	)
	assert_almost_eq(fast.resolved_steer_return_speed(), 240.0, 0.0001, "写了就用写的")
	var zero := PartDef.from_text(
		"name = 零\nshape = cube\ncubes = 1 1 1\n"
		+ "wheel_steer_speed = 45\nwheel_steer_return_speed = 0\n",
		"res://data/parts/test_wheel_return_zero.part.txt"
	)
	assert_almost_eq(zero.resolved_steer_return_speed(), 45.0, 0.0001, "写 0 = 当没写（老行为）")


## 松手回正（偏航）力矩：方向要和"自转"反着来，大小 = I × ω / 秒数
## （这样没有别的力时，自转就按这个时间常数指数衰减）。滚转 / 俯仰不该被它管。
func test_yaw_center_torque_brakes_only_yaw() -> void:
	var up := Vector3.UP
	var inertia := 1200.0
	# 绕竖直轴转 2 弧度/秒：力矩应该反过来、大小 = 1200 × 2 / 0.5 = 4800
	var tau := TestField.yaw_center_torque(up, Vector3.UP * 2.0, 0.5, inertia)
	assert_almost_eq(tau.dot(up), -4800.0, 0.001, "力矩 = -I × ω / 秒，方向反着来")
	# 时间常数越小 → 力矩越大（回正越快）
	var quick := TestField.yaw_center_torque(up, Vector3.UP * 2.0, 0.25, inertia)
	assert_true(quick.length() > tau.length(), "秒数写小 = 回正更狠")
	# 0 / 负数 = 关掉
	assert_eq(TestField.yaw_center_torque(up, Vector3.UP * 2.0, 0.0, inertia), Vector3.ZERO, "0 = 关")
	# 纯滚转 / 纯俯仰（角速度垂直于 up）不该被偏航回正管
	var pitch := TestField.yaw_center_torque(up, Vector3.RIGHT * 3.0, 0.5, inertia)
	assert_true(pitch.length() < 0.0001, "纯俯仰不该出力矩：%s" % pitch)
	# 车身歪着的时候，按**车身 up** 取自转分量
	var tilted_up: Vector3 = Vector3(0.4, 0.9, 0.0).normalized()
	var tilted := TestField.yaw_center_torque(tilted_up, tilted_up * 2.0, 0.5, inertia)
	assert_almost_eq(tilted.dot(tilted_up), -4800.0, 0.001, "歪着也是绕车身 up 自转")


## 绕某个世界轴转动时的转动惯量：竖直轴、水平轴要按车身朝向把本地惯性投过去。
func test_inertia_about_world_axis() -> void:
	var tensor := Vector3(1.0, 2.0, 3.0)   # 本地 x/y/z 的对角惯性
	# 车正着放：世界 up = 本地 y
	assert_almost_eq(
		TestField.inertia_about(Vector3.UP, Basis(), tensor), 2.0, 0.0001, "正放时取本地 y"
	)
	# 绕 z 转 90°：世界 up 变成本地 x
	var rolled := Basis(Vector3.FORWARD, PI * 0.5)
	assert_almost_eq(
		TestField.inertia_about(Vector3.UP, rolled, tensor), 1.0, 0.0001, "侧翻 90° 取本地 x"
	)
	# 永远给正数（别把 0 当除数）
	assert_true(
		TestField.inertia_about(Vector3.ZERO, Basis(), Vector3.ZERO) >= 1.0, "兜底给正数"
	)
	# 包围盒粗估：2270kg 的车（25 长 × 12 宽）→ 2270 × (625 + 144) / 12 ≈ 145462
	assert_almost_eq(
		TestField.box_inertia_guess(2270.0, Vector3(25.0, 8.0, 12.0)),
		2270.0 * 769.0 / 12.0,
		1.0,
		"实心长方体 m(a²+b²)/12"
	)
	assert_true(
		TestField.box_inertia_guess(0.0, Vector3.ZERO) >= 1.0, "别返回 0（会被当除数）"
	)


## 环视相机的基准朝向：跟车 = 车头（鼠标转的是相对车头的偏移）；
## 不跟车 = 世界 +x（鼠标转的是世界绝对朝向）。两种模式鼠标都能自由环视，
## 区别只在"车的转动会不会一起带动画面"。
func test_camera_yaw_reference_follows_or_not() -> void:
	var heading: Vector3 = Vector3(0.3, 0.0, 0.95).normalized()
	assert_eq(
		TestField.camera_yaw_reference(heading, true), heading,
		"跟车：基准 = 车头方向（车转向 → 画面跟着转）"
	)
	assert_eq(
		TestField.camera_yaw_reference(heading, false), Vector3.RIGHT,
		"不跟车：基准 = 世界 +x（车怎么转，画面朝向都不动）"
	)
	assert_eq(
		TestField.camera_yaw_reference(Vector3.ZERO, false), Vector3.RIGHT,
		"不跟车时连车头都不用看（车头没定义也照样有基准）"
	)


## 世界标定（1 格 = 多少米）必须**三处一致**：常量 / `project.godot` 的重力 / 速度换算。
## 2026-10-14 用户把标定从 0.2 米改成 0.5 米（"手感问题很大程度上是比例尺问题"）：
## 车还是 25 格长，但 30 m/s 从 150 格/秒 变成 60 格/秒 —— 相对车身慢下来了。
## 改标定时**必须**同时改重力，不然世界自相矛盾（车"变重/变轻"、跳跃高度全变）。
func test_world_calibration_is_consistent() -> void:
	assert_almost_eq(PartDef.CUBE_METERS, 0.5, 0.0001, "1 格 = 0.5 米")
	assert_almost_eq(PartDef.EARTH_GRAVITY, 9.8, 0.0001, "真实重力 9.8 m/s²")
	assert_almost_eq(
		PartDef.GRAVITY_CUBES,
		PartDef.EARTH_GRAVITY / PartDef.CUBE_METERS,
		0.0001,
		"模拟重力 = 真实 9.8 ÷ 格长"
	)
	assert_almost_eq(PartDef.GRAVITY_CUBES, 19.6, 0.0001, "0.5 米/格 → 19.6 格/秒²")
	assert_almost_eq(
		float(ProjectSettings.get_setting("physics/3d/default_gravity", 0.0)),
		PartDef.GRAVITY_CUBES,
		0.0001,
		"project.godot 的重力必须和常量一致"
	)
	# 速度：部件文件写真实 m/s，内部换算 1 m/s = 1/CUBE_METERS 格/秒
	assert_almost_eq(1.0 / PartDef.CUBE_METERS, 2.0, 0.0001, "1 m/s = 2 格/秒")
	assert_almost_eq(
		TestField.CUBE_METERS, PartDef.CUBE_METERS, 0.0001,
		"测试场（速度表 / 卡钳）必须用同一个标定"
	)


## 悬挂参数就是**零件固有绝对值**（刚度/阻尼/上限都照文件里的数），不按车重缩放 ——
## 轻车被弹飞是**数值稳定性**问题（显式阻尼的稳定条件 dt < 2m/c，小车 m 小会翻过界），
## 现在改用**隐式阻尼**（Godot/Bullet 那套）从根上解决，见 `TestField._apply_wheel()`。
func test_suspension_params_are_intrinsic() -> void:
	var library := _library()
	var axle: PartDef = library.get_def("wheel_axle_2x2")
	if axle == null:
		return
	var gravity := PartDef.GRAVITY_CUBES
	var heavy_load := 2270.0 * gravity / 8.0    # 你那台 111：2.27 吨 / 8 轮
	var light_load := 230.0 * gravity / 4.0     # 那台未命名小车：230 kg / 4 轮
	var heavy := axle.resolved_suspension(heavy_load, heavy_load / gravity)
	var light := axle.resolved_suspension(light_load, light_load / gravity)
	assert_almost_eq(
		float(heavy["stiffness"]), float(light["stiffness"]), 0.001, "刚度是零件固有值，不随车重变"
	)
	assert_almost_eq(
		float(heavy["damper_c"]), float(light["damper_c"]), 0.001, "阻尼也是零件固有值"
	)
	assert_almost_eq(
		float(light["max_force"]), axle.wheel_suspension_max_force, 1.0,
		"支撑力上限就是文件里的绝对值（不按车重缩放）"
	)
	assert_true(
		TestField.SUSP_FORCE_FILTER_SECONDS >= 0.0, "低通滤波时间常数存在（0 = 关掉滤波）"
	)


## 手感辅助的生效强度：**有轮着地就朝满、一个没着地就朝 0**（不看轮数比例），
## 各按 `ground_blend_seconds` 过渡 —— 所以落地是平滑恢复，不是"啪"地跳一下。
func test_handling_blend_switches_on_any_contact() -> void:
	# 有任何一个轮子着地，目标就是满效果
	assert_almost_eq(TestField.handling_blend(0.0, true, 0.1, 0.2), 0.5, 0.0001, "0.1/0.2 秒 → 一半")
	assert_almost_eq(TestField.handling_blend(0.0, true, 0.2, 0.2), 1.0, 0.0001, "到时间就满")
	assert_almost_eq(TestField.handling_blend(1.0, true, 0.05, 0.2), 1.0, 0.0001, "满了不许超 1")
	# 腾空：朝 0 过渡，不是立刻掉到 0
	assert_almost_eq(TestField.handling_blend(1.0, false, 0.05, 0.2), 0.75, 0.0001, "腾空逐步掉")
	assert_almost_eq(TestField.handling_blend(1.0, false, 0.2, 0.2), 0.0, 0.0001, "到时间就归零")
	assert_almost_eq(TestField.handling_blend(0.3, false, 0.001, 0.2), 0.295, 0.0001, "没到点不夹到 0")
	# 过渡时间写 0 = 立刻切换（旧行为那种"有就是有、没有就是没有"）
	assert_almost_eq(TestField.handling_blend(0.0, true, 0.016, 0.0), 1.0, 0.0001, "0 秒 = 立即满")
	assert_almost_eq(TestField.handling_blend(1.0, false, 0.016, 0.0), 0.0, 0.0001, "0 秒 = 立即 0")
