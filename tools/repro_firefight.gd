extends SceneTree

## 交火复现器：用现有 AI 参数把"10 台车对射"压到极限，逐物理帧采样。
##
##   godot --headless --path <项目> --script res://tools/repro_firefight.gd -- \
##         --player=custom_1 --frames=900 --heavy=1 --fire=1
##
## 参数（都可选）：
##   --player=<id>   玩家开哪台车（默认 custom_1，541 件；换成 bot_light 就是 16 件对照）
##   --frames=<n>    采样帧数（默认 900）
##   --heavy=0|1     是否把人机压成"持续开火"（默认 1）
##   --fire=0|1      人机是否开火（默认 1；0 用来做 A/B）
##
## 输出：物理耗时 平均/中位/p95/最慢、超 16.7ms 的帧占比、命中/掉零件统计，
##       以及**最慢的 8 帧**各自当时的命中数、掉零件数。

var FRIENDLY_BOTS := ["bot_gunner", "bot_gunner", "bot_light", "bot_light"]
var ENEMY_BOTS := ["bot_light", "bot_light", "bot_gunner", "bot_gunner", "bot_light"]
const BattleModeScript := preload("res://scripts/battle_mode.gd")


func _initialize() -> void:
	var player_vehicle := "custom_1"
	## 基准场景 = **10 台 541 件的主战车**（`custom_1`）。这是用户实际会卡的那个场面；
	## 16 件的人机车本来就不卡，不作为对照基准（要多台小车才显出来，用 --bot=bot_light）。
	var bot_vehicle := "custom_1"
	var frames := 600
	var heavy := true
	var fire := true
	var player_fire := false
	var prof := false
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=", true, 1)
		if parts.size() != 2:
			continue
		match parts[0]:
			"--player": player_vehicle = parts[1]
			"--bot": bot_vehicle = parts[1]
			"--frames": frames = int(parts[1])
			"--heavy": heavy = parts[1] != "0"
			"--fire": fire = parts[1] != "0"
			"--playerfire": player_fire = parts[1] != "0"
			"--prof": prof = parts[1] != "0"
	if not bot_vehicle.is_empty():
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
	print("=== %s | player=%s | heavy=%s | fire=%s | %d 帧 ===" % [
		"10 车对战", player_vehicle, str(heavy), str(fire), frames
	])
	print("场上载具 %d 台，零件总数 %d" % [vehicles.size(), _parts_total(vehicles)])

	# 把人机压成"贴脸持续开火"：放宽射程 / 取消瞄准容差 / 零反应时间
	var cfg: Dictionary = mode.get("_ai_cfg")
	if heavy:
		cfg["bot_fire_range"] = 5000.0
		cfg["bot_aim_tolerance"] = -1.0
		cfg["bot_reaction_seconds"] = 0.0
		cfg["bot_retarget_seconds"] = 0.2
		cfg["bot_standoff"] = 40.0
		cfg["bot_too_close"] = 10.0
	if not fire:
		cfg["bot_fire_range"] = 0.0
	if prof:
		mode.set("_prof_on", true)

	for i in 180:
		await physics_frame

	# 让玩家车自己那 10 座转塔也开火（无头下没有键鼠，直接按动作）
	if player_fire:
		Input.action_press("fire_weapon")
		print("（玩家开火：按住 fire_weapon）")

	var projectiles: Node = mode.get("_projectiles")
	var phys: Array[float] = []
	var prev_alive := _alive_total(vehicles)
	var prev_hits := _hits(projectiles)
	var total_hits := 0
	var total_kills := 0
	var over_frames := 0
	var slowest: Array = []

	for i in frames:
		await physics_frame
		var p := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		phys.append(p)
		if p > 16.7:
			over_frames += 1
		var alive_now := _alive_total(vehicles)
		var killed := maxi(0, prev_alive - alive_now)
		prev_alive = alive_now
		var hits_now := _hits(projectiles)
		var hits_delta := hits_now - prev_hits
		prev_hits = hits_now
		total_hits += hits_delta
		total_kills += killed
		slowest.append({"ms": p, "hits": hits_delta, "kills": killed})

	slowest.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["ms"]) > float(b["ms"])
	)

	print("物理耗时 平均 %5.2f ms  中位 %5.2f  p95 %5.2f  最慢 %5.2f" % [
		_avg(phys), _pct(phys, 0.5), _pct(phys, 0.95), _max(phys)
	])
	print("超 16.7ms：%d/%d 帧（%d%%）   超 25ms：%d 帧" % [
		over_frames, phys.size(), int(over_frames * 100 / phys.size()), _count_over(phys, 25.0)
	])
	print("命中 %d 次（%.1f 次/秒）· 掉零件 %d 个" % [
		total_hits, total_hits * 60.0 / float(frames), total_kills
	])
	print("最慢 8 帧：")
	for i in mini(8, slowest.size()):
		var s: Dictionary = slowest[i]
		print("   %6.2f ms   当帧命中 %d   当帧掉零件 %d" % [
			float(s["ms"]), int(s["hits"]), int(s["kills"])
		])
	quit()


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


static func _count_over(values: Array[float], limit: float) -> int:
	var n := 0
	for v in values:
		if v > limit:
			n += 1
	return n


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
