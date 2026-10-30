extends SceneTree

## 跑法：
##   godot --headless --path . --script res://tools/bench_hitbox_chunks.gd
##
## 对比"整车一张 trimesh"和"按块重建"的单次代价：
##   * full  = `_rebuild_hitbox_trimesh()`（旧行为：掉一格重建整台车）
##   * chunk = `_rebuild_hit_chunk(一个块)`（新行为：只重建被打到的那一块）
## 车是 8x5x5 = 200 个 cube_full。

const PART_DIR := "res://data/parts"


func _initialize() -> void:
	var library := PartLibrary.new()
	library.load_all(PART_DIR)

	var text := "name = bench\n"
	var n := 0
	for x in 8:
		for y in 5:
			for z in 5:
				text += "part = cube_full %d %d %d 0 0 0\n" % [x, y, z]
				n += 1
	var vehicle := VehicleDef.from_text(text, "user://bench_chunks.vehicle.txt")
	if vehicle == null:
		print("BENCH FAILED: 造不出载具：%s" % str(vehicle))
		quit(1)
		return

	var body := StaticBody3D.new()
	var rig := VehicleRig.new()
	rig.setup(vehicle, library, body, body, false, Vector3.ZERO)

	var chunk_count: int = (rig._chunk_shapes as Dictionary).size()
	var shape_count: int = (rig._hit_shapes as Array).size()
	print("零件=%d  块数=%d  受击盒 trimesh 数=%d" % [n, chunk_count, shape_count])

	# --- 全量重建（旧行为）---
	var rounds := 30
	var t0 := Time.get_ticks_usec()
	for i in rounds:
		rig._rebuild_hitbox_trimesh()
	var full_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(rounds)

	# --- 单块重建（新行为）---
	var chunks: Array = (rig._chunk_shapes as Dictionary).keys()
	var t1 := Time.get_ticks_usec()
	for i in rounds:
		rig._rebuild_hit_chunk(chunks[i % chunks.size()])
	var chunk_ms := float(Time.get_ticks_usec() - t1) / 1000.0 / float(rounds)

	print("FULL  %.2f ms/次  (整车 %d 块)" % [full_ms, chunk_count])
	print("CHUNK %.2f ms/次  (只做 1 块)" % chunk_ms)
	if chunk_ms > 0.0:
		print("RATIO %.1fx" % (full_ms / chunk_ms))

	body.free()
	quit()
