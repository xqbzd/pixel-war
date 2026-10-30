extends SceneTree

## A/B：**同一帧打掉 3 个零件**，逐个 `apply_damage()`（旧路径）vs `apply_damage_batch()`（新路径）。
##
##   godot --headless --path <项目> --script res://tools/bench_damage_batch.gd -- [载具id] [每帧打掉几个]

const VEHICLE_DIR := "res://data/vehicles"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var vehicle_id := "custom_1" if args.is_empty() else String(args[0])
	var per_frame := 3 if args.size() < 2 else int(args[1])
	var path := "%s/%s.vehicle.txt" % [VEHICLE_DIR, vehicle_id]
	var library := PartLibrary.new()
	library.load_all()
	var vehicle := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)
	print("=== %s（%d 件）· 每帧打掉 %d 个零件 ===" % [vehicle_id, vehicle.part_count(), per_frame])

	var rounds := 6
	await _measure(library, vehicle, per_frame, rounds, false)
	await _measure(library, vehicle, per_frame, rounds, true)
	quit()


func _measure(
	library: PartLibrary, vehicle: VehicleDef, per_frame: int, rounds: int, batched: bool
) -> void:
	var mode_name := "批量 apply_damage_batch" if batched else "逐个 apply_damage（旧）"
	var total := 0.0
	var worst := 0.0
	for round_index in rounds:
		var host := Node3D.new()
		root.add_child(host)
		var body := RigidBody3D.new()
		body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		host.add_child(body)
		await process_frame
		var rig := VehicleRig.new()
		rig.setup(vehicle, library, host, body, true, Vector3.ZERO)
		await process_frame

		# 挑 per_frame 个还活着的零件：**跳过核心**（打死核心会让连通性判定走"整机全灭"的短路，
		# 测不出并查集的真实开销）
		var victims: Array[int] = []
		var core := rig.state.core_index
		for i in rig.part_boxes().size():
			if victims.size() >= per_frame:
				break
			if i == core:
				continue
			if rig.part_alive(i):
				victims.append(i)
		if victims.size() < per_frame:
			host.queue_free()
			return

		var t0 := Time.get_ticks_usec()
		var alive_before := rig.state.alive_count()
		var destroyed_count := 0
		if batched:
			var amounts := {}
			for v in victims:
				amounts[v] = maxf(0.01, rig.state.remaining_hp(v))
			var res := rig.apply_damage_batch(amounts)
			destroyed_count = (res["destroyed"] as Array).size() + (res["detached"] as Array).size()
		else:
			for v in victims:
				var res := rig.apply_damage(v, maxf(0.01, rig.state.remaining_hp(v)))
				destroyed_count += (res["destroyed"] as Array).size() + (res["detached"] as Array).size()
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("    回合 %d：core_index=%d 存活 %d → %d（掉 %d）  用时 %.2f ms" % [
			round_index, int(rig.state.core_index), alive_before, rig.state.alive_count(),
			destroyed_count, ms
		])
		total += ms
		worst = maxf(worst, ms)
		rig.flush_visuals()
		host.queue_free()
		await process_frame

	print("%-28s 平均 %6.2f ms   最慢 %6.2f ms" % [mode_name, total / float(rounds), worst])
