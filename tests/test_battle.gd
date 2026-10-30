@tool
extends McpTestSuite

## 人机对战模式（5v5）的"硬指标"：场地尺寸 / 坡度 / 出生点 / AI 的转向与提前量 / 胜负状态机。
##
## 整局对战太重（10 台车 + 地形），不进测试套件 —— 这里只钉住"改坏了会静默出错"的那几条：
##   * 场地必须是 1000 米见方，起伏 ≤20°（用户明确提的要求）；
##   * 两队的出生点在场地里、贴地、面对面；
##   * AI 的"左打方向"和玩家一致（打反过一次就完全没法打）；
##   * 提前量算得对（不然打移动靶永远打不中）。

const Battle := preload("res://scripts/battle_mode.gd")
const GameSettings := preload("res://scripts/game_settings.gd")


func suite_name() -> String:
	return "battle"


## 场地边长 / 起伏幅度 / 坡度上限 / 掩体数量。
func test_arena_size_and_slope() -> void:
	var arena := BattleArena.new()
	arena.build()
	assert_almost_eq(BattleArena.SIZE_METERS, 500.0, 0.001, "场地边长 500 米（1 公里的 1/2）")
	# 网格点间距（格）：10 米 / 0.5 = 20 格
	var step := BattleArena.SIZE_METERS / float(BattleArena.CELLS) / PartDef.CUBE_METERS
	var max_step := tan(deg_to_rad(BattleArena.MAX_SLOPE_DEG)) * step
	var n := BattleArena.CELLS + 1
	var half := step * float(BattleArena.CELLS) * 0.5
	var lowest := INF
	var highest := -INF
	var steepest := 0.0
	for iz in n:
		for ix in n:
			var x := -half + float(ix) * step
			var z := -half + float(iz) * step
			var y := arena.ground_y(x, z)
			lowest = minf(lowest, y)
			highest = maxf(highest, y)
			if ix < BattleArena.CELLS:
				steepest = maxf(steepest, absf(arena.ground_y(x + step, z) - y))
			if iz < BattleArena.CELLS:
				steepest = maxf(steepest, absf(arena.ground_y(x, z + step) - y))
	assert_true(
		(highest - lowest) * PartDef.CUBE_METERS < 25.0,
		"起伏幅度应小于 25 米（实际 %.1f 米）" % ((highest - lowest) * PartDef.CUBE_METERS)
	)
	assert_true(
		steepest <= max_step + 0.001,
		"相邻格高差不能超过 20° 坡度（最陡 %.3f 格 / 上限 %.3f 格）" % [steepest, max_step]
	)
	assert_gt(arena.cover_count, 0, "场地里要有掩体（当前 %d 个）" % arena.cover_count)
	assert_gt(arena.tree_count, 0, "场地里要有树/灌木装饰")
	# 地面网格 + 掩体的碰撞体都要在"世界"层（子弹/轮胎射线认这一层）
	var world_bodies := 0
	for child in arena.get_children():
		if child is StaticBody3D and (child as StaticBody3D).collision_layer == 1:
			world_bodies += 1
	assert_gt(world_bodies, 1, "地面 / 掩体 / 围墙都要有第 1 层的碰撞体")
	arena.free()


## 两队出生点：在场地内、贴地、面对面、彼此拉开足够远。
func test_arena_spawns_face_each_other_on_the_ground() -> void:
	var arena := BattleArena.new()
	arena.build()
	var half_m := BattleArena.SIZE_METERS * 0.5
	var first_a := arena.spawn_transform(0, 0, 5)
	var first_b := arena.spawn_transform(1, 0, 5)
	for team in 2:
		for index in 5:
			var t := arena.spawn_transform(team, index, 5)
			var p := t.origin
			assert_almost_eq(
				p.y, arena.ground_y(p.x, p.z), 0.01, "出生点必须贴着地面（队伍 %d）" % team
			)
			assert_true(
				absf(p.x) * PartDef.CUBE_METERS < half_m
				and absf(p.z) * PartDef.CUBE_METERS < half_m,
				"出生点要在场地内：%s" % str(p)
			)
	# 两队面对面（车头朝对方），并且隔开足够远（500 米场地 → 约 220 米）
	assert_true(
		first_a.basis.x.dot(Vector3.RIGHT) > 0.9, "我方车头朝 +x（敌方在那边）"
	)
	assert_true(
		first_b.basis.x.dot(Vector3.RIGHT) < -0.9, "敌方车头朝 -x（我方在那边）"
	)
	var team_gap := absf(first_a.origin.x - first_b.origin.x) * PartDef.CUBE_METERS
	assert_gt(team_gap, 150.0, "两队出生点至少隔开 150 米（实际 %.0f 米）" % team_gap)
	assert_true(team_gap < BattleArena.SIZE_METERS, "又不能超过场地边长")
	# 同队 5 个人不能挤在一起
	var gap := absf(arena.spawn_transform(0, 0, 5).origin.z - arena.spawn_transform(0, 1, 5).origin.z)
	assert_gt(gap * PartDef.CUBE_METERS, 20.0, "同队相邻出生点至少隔开 20 米")
	arena.free()


## AI 的转向：+1 = 往左（和玩家按 A 一致）。左 = -z（车头是 +x）。
func test_ai_steers_left_for_left_target() -> void:
	var forward := Vector3(1, 0, 0)
	assert_almost_eq(
		Battle.steer_towards(forward, Vector3(0, 0, -1)), 1.0, 0.001, "左边 → 左打满"
	)
	assert_almost_eq(
		Battle.steer_towards(forward, Vector3(0, 0, 1)), -1.0, 0.001, "右边 → 右打满"
	)
	assert_almost_eq(
		Battle.steer_towards(forward, Vector3(1, 0, 0)), 0.0, 0.001, "正前方 → 不回方向"
	)
	assert_almost_eq(
		Battle.steer_towards(forward, Vector3(0, 9, 0)), 0.0, 0.001, "竖直方向不参与转向"
	)
	assert_almost_eq(
		Battle.steer_towards(Vector3.ZERO, Vector3(0, 0, 1)), 0.0, 0.001, "没有车头方向 → 不转"
	)
	# 小角度：转向量和角度成正比（20° → 约 0.7 舵）；45° 已经打满
	var small := Battle.steer_towards(forward, Vector3(1, 0, -0.364))   # ≈ 20°
	assert_true(small > 0.6 and small < 0.8, "20° 目标约 0.7 舵：%.2f" % small)
	assert_almost_eq(
		Battle.steer_towards(forward, Vector3(1, 0, -1)), 1.0, 0.001, "45° 已经打满舵"
	)


## AI 的提前量：distance / bullet_speed 秒之后目标在哪。
func test_ai_leads_moving_targets() -> void:
	var target := Vector3(0, 0, 100)
	var velocity := Vector3(0, 0, 40)
	# 1000 格 / 1000 格每秒 = 1 秒 → 提前 40 格
	assert_vec_almost_eq(
		Battle.lead_point(target, velocity, 1000.0, 1000.0),
		target + Vector3(0, 0, 40), 0.001, "按飞行时间提前"
	)
	assert_vec_almost_eq(
		Battle.lead_point(target, velocity, 0.0, 1000.0), target, 0.001, "距离 0 不提前"
	)
	assert_vec_almost_eq(
		Battle.lead_point(target, velocity, 500.0, 0.0), target, 0.001, "初速 0 不提前（别除零）"
	)


## 胜负状态机：结束后标记住，再调也不会被改写。
func test_battle_finish_locks_the_result() -> void:
	var battle := Battle.new()
	battle._vehicles = []
	battle._finish_battle(true)
	assert_true(battle._battle_over, "应该标记成已结束")
	assert_true(battle._battle_won, "应该是胜利")
	# 结束收尾是**延迟**做的（避免在子弹回调里改鼠标模式）—— 测试里手动补上
	battle._apply_battle_finish()
	assert_true(battle._status.contains("胜利"), "状态文字要是胜利")
	battle._finish_battle(false)
	assert_true(battle._battle_won, "结束之后输赢不能再被改写")
	battle.free()


## 队伍颜色：用户明确要求**我方蓝、敌方红**（之前说反过一次，这条守住）。
func test_team_colours_are_blue_and_red() -> void:
	assert_true(
		Battle.FRIENDLY_COLOUR.b > Battle.FRIENDLY_COLOUR.r,
		"我方必须是蓝色：%s" % str(Battle.FRIENDLY_COLOUR)
	)
	assert_true(
		Battle.ENEMY_COLOUR.r > Battle.ENEMY_COLOUR.b,
		"敌方必须是红色：%s" % str(Battle.ENEMY_COLOUR)
	)


## 头顶血条 = 剩余全部零件生命值 / 满血。
func test_vehicle_health_fraction() -> void:
	var library := PartLibrary.new()
	library.load_all()
	var vehicle := VehicleDef.from_text(
		"name = 血条测试\npart = core 0 0 0 0 0 0\n", "user://tmp_battle_health.vehicle.txt"
	)
	var state := VehicleState.new()
	state.setup(vehicle, library.defs)
	assert_gt(state.max_hp_total(), 0.0, "满血总血量要 > 0")
	assert_almost_eq(state.health_fraction(), 1.0, 0.001, "满血 = 1")
	var full := state.max_hp_total()
	state.apply_damage(state.core_index, full * 0.25)
	assert_almost_eq(state.health_fraction(), 0.75, 0.001, "掉 1/4 血 = 0.75")
	assert_almost_eq(state.remaining_hp_total(), full * 0.75, 1.0, "剩余血量按零件求和")
	state.apply_damage(state.core_index, full)
	assert_almost_eq(state.health_fraction(), 0.0, 0.001, "核心没了 = 0")


## 视野标记状态机：连续看满 1 秒才亮，消失满 0.5 秒才灭。
func test_spotting_requires_a_continuous_second() -> void:
	var state := {}
	state = Battle.advance_spot(state, true, 0.5)
	assert_false(bool(state.get("spotted", false)), "不到 1 秒不点亮")
	# 中间断一帧 → 重新计时（用户要的是"持续出现在视野内"）
	state = Battle.advance_spot(state, false, 0.05)
	assert_almost_eq(float(state["seen"]), 0.0, 0.001, "断一帧就重新计时")
	state = Battle.advance_spot(state, true, 0.5)
	assert_false(bool(state.get("spotted", false)), "重新计时后还不到 1 秒")
	state = Battle.advance_spot(state, true, 0.5)
	assert_true(bool(state.get("spotted", false)), "连续看满 1 秒点亮")
	# 全部友方都看不见：0.5 秒宽限内仍然显示
	state = Battle.advance_spot(state, false, 0.3)
	assert_true(bool(state.get("spotted", false)), "消失不到 0.5 秒仍然可见")
	state = Battle.advance_spot(state, false, 0.3)
	assert_false(bool(state.get("spotted", false)), "消失满 0.5 秒后熄灭")


## 自动标记只在 200 米以内生效；手动 Q 可以立刻标记（不用等 1 秒）。
func test_mark_rules() -> void:
	assert_almost_eq(
		Battle.AUTO_SPOT_RANGE * PartDef.CUBE_METERS, 200.0, 0.001,
		"自动标记范围必须正好 200 米"
	)
	var battle := Battle.new()
	battle._vehicles = []
	var enemy := {"owner_key": "enemy_1_0", "team": 1, "display_name": "人机·轻型"}
	battle._mark_enemy(enemy, "手动标记")
	var state: Dictionary = battle._spot.get("enemy_1_0", {})
	assert_true(bool(state.get("spotted", false)), "标记后立刻可见（不用等 1 秒）")
	assert_true(battle._is_spotted(enemy), "查询接口也要是可见")
	# 被子弹命中 → 同样立刻标记
	var other := {"owner_key": "enemy_1_1", "team": 1, "display_name": "人机·双枪"}
	var rig := VehicleRig.new()
	rig.team = 1
	battle._vehicles = [other]
	other["rig"] = rig
	battle._on_vehicle_damaged(rig)
	assert_true(battle._is_spotted(other), "被友方子弹命中也会标记")
	battle.free()


## 视野锥：正前方看得到，侧面/背后看不到。
func test_view_cone_blocks_behind_and_side() -> void:
	var forward := Vector3(1, 0, 0)
	assert_true(Battle.in_view_cone(forward, Vector3(1, 0, 0), deg_to_rad(30.0)), "正前方")
	assert_true(
		Battle.in_view_cone(forward, Vector3(1, 0, -0.5), deg_to_rad(30.0)), "偏左 27° 仍在 30° 内"
	)
	assert_false(
		Battle.in_view_cone(forward, Vector3(0, 0, 1), deg_to_rad(30.0)), "正侧面 90° 看不到"
	)
	assert_false(
		Battle.in_view_cone(forward, Vector3(-1, 0, 0), deg_to_rad(30.0)), "背后看不到"
	)
	assert_false(Battle.in_view_cone(Vector3.ZERO, Vector3(1, 0, 0), 1.0), "没有前向就不算")


## 小地图坐标换算：场地中心 → 地图正中，四角贴着地图边。
func test_minimap_projection() -> void:
	var centre := BattleMinimap.map_position(Vector2.ZERO, 1000.0, 190.0)
	assert_almost_eq(centre.x, 95.0, 0.001, "中心 x")
	assert_almost_eq(centre.y, 95.0, 0.001, "中心 y")
	var top_left := BattleMinimap.map_position(Vector2(-500.0, -500.0), 1000.0, 190.0)
	assert_almost_eq(top_left.x, 0.0, 0.001, "左上角 x")
	assert_almost_eq(top_left.y, 0.0, 0.001, "左上角 y")
	var bottom_right := BattleMinimap.map_position(Vector2(500.0, 500.0), 1000.0, 190.0)
	assert_almost_eq(bottom_right.x, 190.0, 0.001, "右下角 x")
	assert_almost_eq(bottom_right.y, 190.0, 0.001, "右下角 y")


func assert_almost_eq(actual: float, expected: float, tol: float, msg: String = "") -> void:
	assert_true(absf(actual - expected) <= tol, "%s（实际 %s，期望 %s）" % [msg, str(actual), str(expected)])


func assert_vec_almost_eq(actual: Vector3, expected: Vector3, tol: float, msg: String = "") -> void:
	assert_true(actual.distance_to(expected) <= tol, "%s（实际 %s，期望 %s）" % [msg, str(actual), str(expected)])


## 手动布局（data/arena/battle_layout.txt）：解析 / 只摆文件里的掩体 / 出生点按文件走 / 导出再读回。
func test_manual_layout() -> void:
	# 解析：注释、逗号、多空格、看不懂的行都不能崩
	var parsed := BattleArena.parse_layout(
		"# 注释\nspawn 0 -100.5 20 90\n\ncover rock_tallA 10, 20, 30, 1.5\n这行看不懂\n"
	)
	assert_eq((parsed["spawns"] as Array).size(), 1, "解析出 1 个出生点")
	assert_eq((parsed["covers"] as Array).size(), 1, "解析出 1 个掩体")
	assert_almost_eq(float(parsed["spawns"][0][2]), 20.0, 0.001, "出生点 z")
	assert_almost_eq(float(parsed["covers"][0][3]), 30.0, 0.001, "掩体朝向（度）")
	assert_almost_eq(float(parsed["covers"][0][4]), 1.5, 0.001, "掩体大小（倍数）")

	# 只写 1 个掩体 + 1 个出生点：掩体就只有一个，出生点按文件走
	var arena := BattleArena.new()
	arena.build({
		"spawns": [[0, -120.0, 44.0, 90.0]],
		"covers": [["rock_tallA", 10.0, 20.0, 30.0, 1.2]],
	})
	assert_eq(arena.cover_count, 1, "手动布局只摆文件里的掩体")
	var spawn := arena.spawn_transform(0, 0, 5)
	assert_almost_eq(spawn.origin.x * PartDef.CUBE_METERS, -120.0, 0.5, "出生点 x 按文件")
	assert_almost_eq(spawn.origin.z * PartDef.CUBE_METERS, 44.0, 0.5, "出生点 z 按文件")
	assert_almost_eq(rad_to_deg(spawn.basis.get_euler().y), 90.0, 0.5, "出生点朝向按文件")
	arena.free()

	# 只写出生点、不写掩体 → 掩体仍然自动摆（可能因为避开出生区少几块，允许 ~15% 损耗）
	var auto := BattleArena.new()
	auto.build({"spawns": [[1, 300.0, -300.0, 0.0]], "covers": []})
	assert_gt(
		auto.cover_count, int(BattleArena.COVER_COUNT * 0.85),
		"没写掩体就自动摆满（实际 %d / %d）" % [auto.cover_count, BattleArena.COVER_COUNT]
	)
	assert_almost_eq(
		auto.spawn_transform(1, 0, 5).origin.x * PartDef.CUBE_METERS, 300.0, 0.5,
		"敌人出生点也按文件"
	)
	auto.free()

	# 导出 → 再解析：数量一致（工具和游戏用的是同一套格式）
	var dump := BattleArena.new()
	dump.build({}, true)
	var path := "user://tmp_arena_layout.txt"
	assert_true(dump.write_layout_file(path, [[0, -220.0, -68.0, 0.0]]), "导出成功")
	var file := FileAccess.open(path, FileAccess.READ)
	var text := file.get_as_text()
	file.close()
	var again := BattleArena.parse_layout(text)
	assert_eq(
		(again["covers"] as Array).size(), dump.cover_layout.size(), "导出再解析，掩体数一致"
	)
	assert_eq((again["spawns"] as Array).size(), 1, "出生点数一致")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	dump.free()


## 场景里的出生点 Marker3D（编辑器里拖的那些）优先于文本布局 / 自动列阵。
func test_scene_spawn_markers() -> void:
	var arena := BattleArena.new()
	var spawns := Node3D.new()
	spawns.name = "Spawns"
	arena.add_child(spawns)
	var marker := Marker3D.new()
	marker.name = "Team1_0"
	# 世界格坐标：x=400（200 米）、z=-300（-150 米），车头转 90°
	marker.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(90.0)), Vector3(400, 0, -300))
	spawns.add_child(marker)
	arena.build({"spawns": [[1, 10.0, 20.0, 0.0]], "covers": []})
	var spawn := arena.spawn_transform(1, 0, 5)
	assert_almost_eq(spawn.origin.x * PartDef.CUBE_METERS, 200.0, 0.5, "Marker 的 x（米）")
	assert_almost_eq(spawn.origin.z * PartDef.CUBE_METERS, -150.0, 0.5, "Marker 的 z（米）")
	assert_almost_eq(rad_to_deg(spawn.basis.get_euler().y), 90.0, 0.5, "Marker 的朝向")
	# 没有 Marker 的那个位置仍然走后面的兜底（文本布局 / 自动）
	var fallback := arena.spawn_transform(0, 0, 5)
	assert_true(fallback.origin.length() > 1.0, "没有 Marker 的位置照常兜底")
	arena.free()


## AI 反应/精度（2026-10-18 用户要求）：偏差随连续开火衰减到 0；参数在 data/battle_ai.txt。
func test_ai_aim_spread() -> void:
	# 衰减比例：0 秒 = 1（最大偏差），settle 秒 = 0
	assert_almost_eq(Battle.aim_spread_decay(0.0, 2.0), 1.0, 0.001, "刚看到 = 满偏差")
	assert_almost_eq(Battle.aim_spread_decay(1.0, 2.0), 0.5, 0.001, "过半 = 一半")
	assert_almost_eq(Battle.aim_spread_decay(2.0, 2.0), 0.0, 0.001, "打满 settle 秒 = 0")
	assert_almost_eq(Battle.aim_spread_decay(5.0, 2.0), 0.0, 0.001, "超过也不会变负")
	# 偏移量 = tan(角度) × 距离 × 衰减
	var full := Battle.aim_spread_offset(Vector3.UP, deg_to_rad(2.0), 100.0, 1.0)
	assert_almost_eq(full.length(), tan(deg_to_rad(2.0)) * 100.0, 0.01, "2° 在 100 格处 ≈ 3.5 格")
	assert_almost_eq(
		Battle.aim_spread_offset(Vector3.UP, deg_to_rad(2.0), 100.0, 0.5).length(),
		tan(deg_to_rad(2.0)) * 50.0, 0.01, "衰减一半 → 偏移一半"
	)
	assert_true(
		Battle.aim_spread_offset(Vector3.UP, deg_to_rad(2.0), 100.0, 0.0).length() < 0.0001,
		"衰减到 0 → 完全对准核心"
	)
	# 默认值就是用户要的：0.3 秒反应、最多 2°
	assert_almost_eq(float(Battle.AI_DEFAULTS["bot_reaction_seconds"]), 0.3, 0.001, "反应时间 0.3 秒")
	assert_almost_eq(float(Battle.AI_DEFAULTS["bot_aim_spread_deg"]), 2.0, 0.001, "偏差最大 2°")
	# 参数文件真的存在且能被解析（用户手动调的那份）
	assert_true(FileAccess.file_exists(Battle.AI_TXT), "参数文件要在：%s" % Battle.AI_TXT)
	var cfg := GameSettings.floats_from_text(Battle.AI_TXT, Battle.AI_DEFAULTS)
	assert_true(cfg.has("bot_aim_settle_seconds"), "参数文件里的键要能读出来")


## 战斗 HUD 布局（底部能量条 + 血圈）：半屏宽、底部居中，血圈在左边。
func test_combat_hud_layout() -> void:
	var view := Vector2(1600.0, 900.0)
	var bar := BattleCombatHud.bar_rect(view)
	assert_almost_eq(bar.size.x, 800.0, 0.001, "能量条 = 半屏宽")
	assert_almost_eq(bar.position.x, 400.0, 0.001, "水平居中")
	assert_almost_eq(
		bar.position.y + bar.size.y, 900.0 - BattleCombatHud.BOTTOM_MARGIN, 0.001,
		"贴着底边（留一点边距）"
	)
	var centre := BattleCombatHud.health_center(view)
	assert_true(centre.x < bar.position.x, "血圈在能量条左边")
	assert_true(
		centre.y < bar.position.y + bar.size.y * 0.5, "血圈比能量条中心**更高**（左上，不必对齐）"
	)
	assert_true(
		centre.x - BattleCombatHud.HEALTH_RADIUS > 0.0, "血圈不能跑出屏幕（实际圆心 %.0f）" % centre.x
	)
