extends SceneTree

## 逐段帧预算：**不改游戏代码**，把 `TestField._physics_process` 停掉，
## 由这个脚本按同样的顺序逐段调用 + 计时，把 20~35 ms 拆成"谁吃掉的"。
##
##   godot --headless --path <项目> --script res://tools/profile_sections.gd -- \
##         --bot=custom_1 --frames=150
##
## 参数：
##   --bot=<id>      9 台人机统一用这台车（默认 custom_1，对齐"10 台大车"的场景）
##   --frames=<n>    采样帧数（默认 150）

var FRIENDLY_BOTS := ["bot_gunner", "bot_gunner", "bot_light", "bot_light"]
var ENEMY_BOTS := ["bot_light", "bot_light", "bot_gunner", "bot_gunner", "bot_light"]
const BattleModeScript := preload("res://scripts/battle_mode.gd")

var _acc := {}
var _frame_acc := {}
var _frames: Array = []
var _engine_only: Array[float] = []


func _initialize() -> void:
	var bot_vehicle := "custom_1"
	var player_vehicle := ""
	var frames := 150
	var drop_hitboxes := false
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=", true, 1)
		if parts.size() != 2:
			continue
		match parts[0]:
			"--bot": bot_vehicle = parts[1]
			"--player": player_vehicle = parts[1]
			"--frames": frames = int(parts[1])
			"--nohitbox": drop_hitboxes = parts[1] != "0"
	if player_vehicle.is_empty():
		player_vehicle = bot_vehicle
	for i in FRIENDLY_BOTS.size():
		FRIENDLY_BOTS[i] = bot_vehicle
	for i in ENEMY_BOTS.size():
		ENEMY_BOTS[i] = bot_vehicle

	TestField.pending_vehicle = {"id": player_vehicle, "name": "玩家"}
	var roster := BattleRoster.empty()
	(roster[0] as Array)[0] = {"kind": "player", "vehicle": player_vehicle, "name": "玩家"}
	for i in FRIENDLY_BOTS.size():
		(roster[0] as Array)[i + 1] = {
			"kind": "bot", "vehicle": FRIENDLY_BOTS[i], "name": "队友%d" % (i + 2)
		}
	for i in ENEMY_BOTS.size():
		(roster[1] as Array)[i] = {
			"kind": "bot", "vehicle": ENEMY_BOTS[i], "name": "敌人%d" % (i + 1)
		}
	BattleModeScript.pending_roster = roster

	var mode: Node = (load("res://scenes/battle_mode.tscn") as PackedScene).instantiate()
	root.add_child(mode)
	await process_frame

	var vehicles: Array = mode.get("_vehicles")
	var cfg: Dictionary = mode.get("_ai_cfg")
	cfg["bot_fire_range"] = 5000.0
	cfg["bot_aim_tolerance"] = -1.0
	cfg["bot_reaction_seconds"] = 0.0
	cfg["bot_retarget_seconds"] = 0.2
	cfg["bot_standoff"] = 40.0
	cfg["bot_too_close"] = 10.0

	print("=== 逐段帧预算 | 10 台 × %s | 零件总数 %d ===" % [bot_vehicle, _parts_total(vehicles)])

	for i in 180:
		await physics_frame
	Input.action_press("fire_weapon")

	# 接管：停掉引擎驱动的 _physics_process，改成这个脚本逐段调用
	mode.set_physics_process(false)
	# 剔除实验：把每台车的「受击盒」那张 541 盒 trimesh 从物理世界摘掉，
	# 只留车体碰撞。若引擎物理耗时因此大跌，说明大头是这张会动的凹面体。
	if drop_hitboxes:
		var dropped := 0
		for veh in vehicles:
			var rig: VehicleRig = veh.get("rig")
			if rig != null and rig.hitboxes != null and is_instance_valid(rig.hitboxes):
				rig.hitboxes.queue_free()
				dropped += 1
		print("（剔除实验：摘掉 %d 张受击盒 trimesh）" % dropped)
		for i in 30:
			await physics_frame
	var delta := 1.0 / 60.0
	var arc_limit := int(mode.get("ARC_REBUILDS_PER_FRAME"))

	for frame in frames:
		await physics_frame
		# 这一行必须在跑任何分段之前采：此时刚结束的那个物理帧里 `_physics_process` 是**关掉**的，
		# 所以这个数 = 引擎物理（Jolt 求解 + 碰撞体 broadphase/narrowphase）+ 其余节点脚本。
		# 它和"各段之和"的差，就是脚本之外的真实开销。
		var engine_only := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		_engine_only.append(engine_only)
		_frame_acc = {}
		var space: PhysicsDirectSpaceState3D = mode.get("_chassis").get_world_3d().direct_space_state
		mode.set("_space", space)
		var frame_start := Time.get_ticks_usec()
		var before := _snapshot(mode)

		_section("① AI 决策", func() -> void: mode.call("_update_battle", delta))

		_section("② 轮胎物理", func() -> void:
			for veh in vehicles:
				var input: Vector2 = mode.call("_vehicle_input", veh, delta)
				mode.call("_drive_vehicle", veh, delta, input.x, input.y)
		)

		_section("③ 引擎音", func() -> void:
			for veh in vehicles:
				var body: RigidBody3D = veh.get("chassis")
				if body == null or not is_instance_valid(body):
					continue
				var throttle := 0.0
				if not bool(veh.get("is_player", false)):
					throttle = clampf(body.linear_velocity.length() / 50.0, 0.0, 1.0)
				mode.call("_update_engine_audio", veh, throttle, 0.0, delta)
		)

		_section("④ 转塔瞄准", func() -> void: mode.call("_update_turrets", delta))

		_section("⑤ 开火判定", func() -> void: mode.call("_update_weapons", delta))

		_section("⑥ 弹道推进", func() -> void:
			mode.get("_projectiles").call("step", delta, space)
		)

		_section("⑦ 伤害结算", func() -> void: mode.call("_flush_damage_batches"))

		_section("⑧ 开火音", func() -> void: mode.call("_flush_shot_sfx"))

		_section("⑨ 视觉重建", func() -> void:
			for veh in vehicles:
				var rig: VehicleRig = veh.get("rig")
				if rig != null:
					rig.flush_visuals()
		)

		_section("⑩ 射界重算", func() -> void:
			for veh in vehicles:
				var rig: VehicleRig = veh.get("rig")
				if bool(veh.get("arc_dirty", false)):
					mode.call("_flush_damage_work", veh, rig)
				var arc_queue: Array = veh.get("arc_queue", [])
				if not arc_queue.is_empty():
					var arc_boxes: Array = veh.get("clip_boxes", [])
					for _i in mini(arc_limit, arc_queue.size()):
						var queued: Variant = arc_queue.pop_front()
						if queued == null or not is_instance_valid(queued):
							continue
						(queued as Turret).rebuild_arc(arc_boxes)
		)

		var frame_ms := float(Time.get_ticks_usec() - frame_start) / 1000.0
		var after := _snapshot(mode)
		_frames.append({
			"ms": frame_ms,
			"sections": _frame_acc.duplicate(),
			"hits": int(after.x) - int(before.x),
			"kills": int(before.y) - int(after.y),
		})

	_frames.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["ms"]) > float(b["ms"])
	)

	print("")
	print("%-24s %10s %8s %10s" % ["环节", "平均 ms", "占比", "最慢一帧 ms"])
	var total := 0.0
	for key in _acc.keys():
		total += float(_acc[key]) / float(frames)
	var worst_sections: Dictionary = (_frames[0]["sections"] as Dictionary) if not _frames.is_empty() else {}
	for key in _acc.keys():
		var avg := float(_acc[key]) / float(frames)
		print("%-24s %10.3f %7.1f%% %10.3f" % [
			key, avg, avg * 100.0 / maxf(total, 0.001), float(worst_sections.get(key, 0.0))
		])
	print("%-24s %10.3f" % ["合计（各段之和）", total])
	print("%-24s %10.3f   p95 %.2f   最慢 %.2f" % [
		"引擎物理（脚本已停）", _avg_f(_engine_only), _pct_f(_engine_only, 0.95), _max_f(_engine_only)
	])
	print("")
	print("最慢 4 帧的逐段拆解：")
	for i in mini(4, _frames.size()):
		var w: Dictionary = _frames[i]
		print("  ---- %.2f ms（命中 %d / 掉零件 %d）----" % [
			float(w["ms"]), int(w["hits"]), int(w["kills"])
		])
		var secs: Dictionary = w["sections"]
		var items: Array = []
		for key in secs.keys():
			items.append({"k": key, "v": float(secs[key])})
		items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["v"]) > float(b["v"])
		)
		for j in mini(4, items.size()):
			print("     %-24s %8.2f ms" % [str(items[j]["k"]), float(items[j]["v"])])
	quit()


func _section(label: String, fn: Callable) -> void:
	var t := Time.get_ticks_usec()
	fn.call()
	var ms := float(Time.get_ticks_usec() - t) / 1000.0
	_acc[label] = float(_acc.get(label, 0.0)) + ms
	_frame_acc[label] = float(_frame_acc.get(label, 0.0)) + ms


## 返回 (累计命中, 存活零件数)
func _snapshot(mode: Node) -> Vector2i:
	var hits := 0
	var proj: Node = mode.get("_projectiles")
	if proj != null and is_instance_valid(proj) and proj.has_method("counters"):
		hits = int((proj.call("counters") as Vector2i).x)
	return Vector2i(hits, _alive_total(mode.get("_vehicles")))


static func _parts_total(vehicles: Array) -> int:
	var total := 0
	for entry in vehicles:
		var rig: Variant = (entry as Dictionary).get("rig")
		if rig != null and is_instance_valid(rig):
			total += (rig.state.parts as Array).size()
	return total


static func _alive_total(vehicles: Array) -> int:
	var total := 0
	for entry in vehicles:
		var rig: Variant = (entry as Dictionary).get("rig")
		if rig != null and is_instance_valid(rig):
			total += int(rig.state.alive_count())
	return total


static func _avg_f(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


static func _max_f(values: Array[float]) -> float:
	var best := 0.0
	for v in values:
		best = maxf(best, v)
	return best


static func _pct_f(values: Array[float], ratio: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(int(ratio * float(sorted.size())), 0, sorted.size() - 1)
	return sorted[index]
