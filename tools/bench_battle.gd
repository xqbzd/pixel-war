extends SceneTree

## 无头跑"10 台车对战"，**A/B 对比开火与不开火**的物理耗时。
##
##   godot --headless --path <项目目录> --script res://tools/bench_battle.gd -- [每阶段帧数]
##
## 阶段 A：人机正常开火
## 阶段 B：把 `bot_fire_range` 置 0（人机不开火，但照样开、照样跑同样的路线）
## 两阶段的车、场地、AI 决策全部相同 —— 差别**只有子弹**。

const VEHICLE_PLAYER := "custom_1"
const FRIENDLY_BOTS := ["bot_gunner", "bot_gunner", "bot_light", "bot_light"]
const ENEMY_BOTS := ["bot_light", "bot_light", "bot_gunner", "bot_gunner", "bot_light"]
const BattleModeScript := preload("res://scripts/battle_mode.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var frames := 800 if args.is_empty() else int(args[0])

	TestField.pending_vehicle = {"id": VEHICLE_PLAYER, "name": "玩家"}
	var roster := BattleRoster.empty()
	(roster[0] as Array)[0] = {"kind": "player", "vehicle": VEHICLE_PLAYER, "name": "玩家"}
	for i in FRIENDLY_BOTS.size():
		(roster[0] as Array)[i + 1] = {
			"kind": "bot", "vehicle": FRIENDLY_BOTS[i], "name": "队友%d" % (i + 2)
		}
	for i in ENEMY_BOTS.size():
		(roster[1] as Array)[i] = {
			"kind": "bot", "vehicle": ENEMY_BOTS[i], "name": "敌人%d" % (i + 1)
		}
	BattleModeScript.pending_roster = roster

	print("=== 10 台车对战（1 台 %s + 9 台人机），无头，%d 帧/阶段 ===" % [VEHICLE_PLAYER, frames])
	var mode: Node = (load("res://scenes/battle_mode.tscn") as PackedScene).instantiate()
	root.add_child(mode)
	await process_frame

	var vehicles: Array = mode.get("_vehicles")
	print("场上载具 %d 台，零件总数 %d" % [vehicles.size(), _parts_total(vehicles)])
	print("")

	# 预热：让 AI 进入交战距离
	for i in 240:
		await physics_frame

	print(await _phase(mode, "A · 正常开火", frames))

	# 关掉开火：射线武器全部停手（AI 的其它行为不变）
	var cfg: Dictionary = mode.get("_ai_cfg")
	cfg["bot_fire_range"] = 0.0
	print("")
	print("（已把 bot_fire_range 置 0：人机不再开火）")
	for i in 120:
		await physics_frame
	print("")
	print(await _phase(mode, "B · 不开火", frames))

	quit()


func _phase(mode: Node, label: String, frames: int) -> String:
	var vehicles: Array = mode.get("_vehicles")
	var projectiles: Node = mode.get("_projectiles")
	var phys: Array[float] = []
	var kill_frames: Array[float] = []
	var quiet_frames: Array[float] = []
	var hit_frames: Array[float] = []
	var idle_frames: Array[float] = []
	var prev_alive := _alive_total(vehicles)
	var prev_hits := _hits(projectiles)
	var total_hits := 0
	var total_kills := 0
	var slowest: Array = []

	for i in frames:
		await physics_frame
		var p := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		phys.append(p)
		var alive_now := _alive_total(vehicles)
		var killed := maxi(0, prev_alive - alive_now)
		prev_alive = alive_now
		var hits_now := _hits(projectiles)
		var hits_delta := hits_now - prev_hits
		prev_hits = hits_now
		total_hits += hits_delta
		total_kills += killed
		if killed > 0:
			kill_frames.append(p)
		else:
			quiet_frames.append(p)
		if hits_delta > 0:
			hit_frames.append(p)
		else:
			idle_frames.append(p)
		slowest.append({"ms": p, "hits": hits_delta, "kills": killed})

	slowest.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["ms"]) > float(b["ms"])
	)
	var over := 0
	for v in phys:
		if v > 16.7:
			over += 1

	var text := "%s：物理耗时 平均 %.2f ms  中位 %.2f  p95 %.2f  最慢 %.2f" % [
		label, _avg(phys), _pct(phys, 0.5), _pct(phys, 0.95), _max(phys)
	]
	text += "\n    超 16.7ms 的帧 %d/%d（%d%%）· 命中 %d 次 · 掉零件 %d 个（%d 帧）" % [
		over, phys.size(), int(over * 100 / phys.size()), total_hits, total_kills, kill_frames.size()
	]
	if not kill_frames.is_empty():
		text += "\n    掉零件帧 平均 %.2f ms  ·  其余帧 平均 %.2f ms" % [
			_avg(kill_frames), _avg(quiet_frames)
		]
	if not hit_frames.is_empty():
		text += "\n    有命中的帧 %d 帧 平均 %.2f ms  ·  无命中帧 %d 帧 平均 %.2f ms" % [
			hit_frames.size(), _avg(hit_frames), idle_frames.size(), _avg(idle_frames)
		]
	var top: Array[String] = []
	for i in mini(5, slowest.size()):
		var s: Dictionary = slowest[i]
		top.append("%.1fms(命中%d/掉%d)" % [float(s["ms"]), int(s["hits"]), int(s["kills"])])
	text += "\n    最慢 5 帧：%s" % ", ".join(top)
	return text


static func _hits(projectiles: Node) -> int:
	if projectiles == null or not is_instance_valid(projectiles):
		return 0
	if not projectiles.has_method("counters"):
		return 0
	return int((projectiles.call("counters") as Vector2i).x)


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


static func _avg(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


static func _max(values: Array[float]) -> float:
	var best := 0.0
	for v in values:
		best = maxf(best, v)
	return best


static func _pct(values: Array[float], ratio: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(int(ratio * float(sorted.size())), 0, sorted.size() - 1)
	return sorted[index]
