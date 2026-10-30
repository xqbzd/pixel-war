extends SceneTree

## 交火开销基准：把"十台车互相射击时可能变慢"的每个环节**单独计时**。
##
##   godot --headless --path <项目目录> --script res://tools/bench_firefight.gd -- [载具id]
##
## 测的东西（都是射击链路里真会跑到的）：
##   1. PhysicsRayQueryParameters3D.create —— 每一发子弹/射线都 new 一个（见 projectiles._cast）
##   2. part_index_at / part_index_of_hit —— 命中反查零件（快路径 + 兜底线性扫描）
##   3. VehicleState.detached_parts —— 死一个零件就整机并查集重算
##   4. VehicleRig._rebuild_hitbox_trimesh —— 受击盒 trimesh 重建
##   5. VehicleRig.flush_visuals —— 掉零件那一帧的整段善后
##   6. apply_damage（会真死零件的）—— 含溢出伤害链 + 并查集
##   7. 真实 intersect_ray —— 打在受击盒 trimesh 上
##
## 输出最后会给一张"每帧预算换算"：按实测射击频率折算成 60 Hz 下的毫秒数。

const VEHICLE_DIR := "res://data/vehicles"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var vehicle_id := "custom_1" if args.is_empty() else String(args[0])
	var path := "%s/%s.vehicle.txt" % [VEHICLE_DIR, vehicle_id]
	if not FileAccess.file_exists(path):
		print("找不到 %s" % path)
		quit()
		return

	var library := PartLibrary.new()
	library.load_all()
	var vehicle := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)
	print("=== 基准载具 %s：%d 个零件 ===" % [vehicle_id, vehicle.part_count()])
	print("")

	# 建一台真实的载具（和进场同一套代码路径）
	var host := Node3D.new()
	root.add_child(host)
	var body := RigidBody3D.new()
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	host.add_child(body)
	await process_frame

	var t0 := Time.get_ticks_usec()
	var rig := VehicleRig.new()
	rig.setup(vehicle, library, host, body, true, Vector3.ZERO)
	_log("VehicleRig.setup（%d 件）" % vehicle.part_count(), _ms(t0), 1)

	var n_parts := rig.part_boxes().size()
	var shapes := rig.shape_counts()
	print("  车体 shape 数 = %d   受击盒 shape 数 = %d" % [shapes.x, shapes.y])
	print("")

	# ── 1. 查询对象分配 ────────────────────────────────────────────────────
	var from := Vector3(0, 0, 0)
	var to := Vector3(0, 0, 10)
	var sink := 0
	t0 = Time.get_ticks_usec()
	for i in 30000:
		var q := PhysicsRayQueryParameters3D.create(from, to, 1)
		sink += int(q.hit_from_inside)
	_log("PhysicsRayQueryParameters3D.create", _ms(t0), 30000)

	# ── 2. 命中反查零件 ────────────────────────────────────────────────────
	# 命中点取在零件盒**表面**上（子弹打中的就是表面，不是中心）
	var points: Array[Vector3] = []
	for i in n_parts:
		var box: AABB = rig.part_box(i)
		if box.size.length() < 0.01:
			continue
		points.append(box.get_center() + Vector3(box.size.x * 0.5, 0, 0))
	if points.is_empty():
		print("没有可用零件盒，退出")
		quit()
		return
	var n_lookup := 2000
	t0 = Time.get_ticks_usec()
	var found := 0
	for i in n_lookup:
		var p: Vector3 = points[i % points.size()]
		if rig.part_index_at(p) >= 0:
			found += 1
	var fast_ms := _ms(t0)
	var part_fast_us := fast_ms * 1000.0 / float(n_lookup)
	_log("part_index_at（命中成功率 %d%%）" % int(found * 100.0 / n_lookup), fast_ms, n_lookup)

	# 兜底路径：命中点不在任何格子里（穿模/擦边）→ 线性扫全部盒子
	var far := Vector3(9999, 9999, 9999)
	t0 = Time.get_ticks_usec()
	for i in 200:
		rig.part_index_at(far)
	var slow_ms := _ms(t0)
	var part_slow_us := slow_ms * 1000.0 / 200.0
	_log("part_index_at（兜底线性扫描 %d 盒）" % n_parts, slow_ms, 200)

	# ── 3. 并查集连通性 ────────────────────────────────────────────────────
	t0 = Time.get_ticks_usec()
	for i in 50:
		rig.state.detached_parts()
	_log("VehicleState.detached_parts（满员）", _ms(t0), 50)

	# ── 4. 受击盒 trimesh 重建 ─────────────────────────────────────────────
	t0 = Time.get_ticks_usec()
	for i in 10:
		rig._rebuild_hitbox_trimesh()
	_log("_rebuild_hitbox_trimesh（%d 盒）" % n_parts, _ms(t0), 10)

	# ── 5. 方块合并盒重建 ──────────────────────────────────────────────────
	t0 = Time.get_ticks_usec()
	for i in 10:
		rig._rebuild_merged_hull()
	_log("_rebuild_merged_hull", _ms(t0), 10)

	# ── 6. 质量/重心同步 ───────────────────────────────────────────────────
	t0 = Time.get_ticks_usec()
	for i in 100:
		rig.sync_body()
	_log("sync_body（质量+重心）", _ms(t0), 100)

	# ── 7. 真实射线（打在受击盒的 trimesh 上）──────────────────────────────
	var space := root.world_3d.direct_space_state
	if space != null:
		var origin := Vector3(0, 0, -60)
		var target: Vector3 = rig.part_box(0).get_center()
		var dir := (target - origin).normalized()
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 200.0, 1 | 4)
		var got := 0
		t0 = Time.get_ticks_usec()
		for i in 1000:
			q.from = origin
			q.to = origin + dir * 200.0
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				got += 1
		_log("intersect_ray（受击盒 trimesh，命中 %d/1000）" % got, _ms(t0), 1000)
	else:
		print("  （拿不到 direct_space_state，跳过射线测试）")

	# ── 8. 没打死零件的那种命中（最常见：扣血但不掉零件）─────────────────────
	var live_part := -1
	for i in n_parts:
		if rig.part_alive(i) and rig.part_box(i).size.length() > 0.01:
			live_part = i
			break
	t0 = Time.get_ticks_usec()
	for i in 500:
		rig.apply_damage(live_part, 1.0)      # 只扣 1 点血，打不死
	_log("apply_damage（只扣血、不掉零件）", _ms(t0), 500)
	# 把刚才扣的血补回来，避免影响后面的击杀测试
	rig.state.hp[live_part] = rig.state.max_hp[live_part]

	print("")
	print("--- 打死 1 个零件：整条链路（这是交火掉帧的核心）---")
	var kill_chain: Array[float] = []
	var flush_chain: Array[float] = []
	for round_index in 8:
		var victim := -1
		for i in n_parts:
			if rig.part_alive(i):
				victim = i
				break
		if victim < 0:
			break
		t0 = Time.get_ticks_usec()
		rig.apply_damage(victim, 1.0e9)
		kill_chain.append(_ms(t0))
		t0 = Time.get_ticks_usec()
		rig.flush_visuals()
		flush_chain.append(_ms(t0))
	print("  apply_damage（含并查集 + 质量/重心）  平均 %6.2f ms   最慢 %6.2f ms" % [
		_avg(kill_chain), _max(kill_chain)
	])
	print("  flush_visuals（受击盒/合并盒/视觉）   平均 %6.2f ms   最慢 %6.2f ms" % [
		_avg(flush_chain), _max(flush_chain)
	])
	print("  → 掉 1 个零件那一帧合计              平均 %6.2f ms" % (_avg(kill_chain) + _avg(flush_chain)))
	print("  → 一帧掉 3 个零件                    约   %6.2f ms（60 Hz 预算 16.7 ms）" % (
		3.0 * _avg(kill_chain) + _avg(flush_chain)
	))

	print("")
	print("=== 结论用的对照组 ===")
	print("  逐发命中反查零件（快路径）        %6.3f ms / 发" % (part_fast_us / 1000.0))
	print("  逐发命中反查零件（兜底路径）      %6.3f ms / 发" % (part_slow_us / 1000.0))
	print("  4 发/帧 × 快路径                  %6.3f ms / 帧" % (4.0 * part_fast_us / 1000.0))
	print("")

	quit()


func _log(label: String, ms: float, n: int) -> void:
	var per := ms * 1000.0 / float(n)
	print("%-46s %9.3f ms / %5d 次   %9.3f µs/次" % [label, ms, n, per])


static func _ms(since: int) -> float:
	return float(Time.get_ticks_usec() - since) / 1000.0


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
