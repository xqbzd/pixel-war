extends SceneTree

## 跑法：
##   godot --headless --path . --script res://tools/bench_build_delete.gd
##
## 量"建造模式拆一块零件"的代价：
##   NEW = 现在的 `_remove_parts()`（就地重写 MultiMesh）
##   OLD = 旧做法每次拆都调 `_make_group_nodes()` 新建 MultiMesh（含 instance_count 重分配）
##         —— 这里只量那一步，不含节点进出场景树，所以是**偏保守**的旧代价。

const PARTS := "res://data/parts"


func _initialize() -> void:
	var build: Node = (load("res://scenes/build_mode.tscn") as PackedScene).instantiate()
	var library: PartLibrary = build.get("_library")
	library.load_all(PARTS)
	var defs := {}
	for id in library.ids():
		defs[id] = library.get_def(id)
	build.set("_defs", defs)
	var root := Node3D.new()
	root.name = "PlacedParts"
	build.add_child(root)

	var grid: Variant = build.get("_grid")
	var cube: PartDef = library.get_def("cube_full")
	if cube == null or grid == null:
		print("BENCH FAILED: 零件表 / 格子没有")
		quit(1)
		return

	# 8 x 5 x 10 = 400 个方块（一台"大车"的规模）
	var cells: Array = []
	for x in 8:
		for y in 5:
			for z in 10:
				var cell := Vector3i(x, y, z)
				var before: int = grid.parts.size()
				if not bool(grid.place(cube, cell, Basis.IDENTITY)["ok"]):
					continue
				build.call("_append_parts", before)
				cells.append(cell)
	print("放好 %d 个零件" % cells.size())

	# --- NEW：拆 40 块，走真实的 _remove_parts ---
	var rounds := 40
	var t0 := Time.get_ticks_usec()
	for i in rounds:
		var cell: Vector3i = cells[cells.size() - 1 - i]
		var victim: Dictionary = grid.victim_at(cell, "cube_full")
		grid.remove(cell, "cube_full")
		build.call("_remove_parts", [victim])
	var new_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(rounds)

	# --- OLD（估算）：每次拆都新建一组 MultiMesh（容量 = 实例数）再丢掉 ---
	var transforms := []
	for entry: Dictionary in grid.parts:
		transforms.append(entry["transform"])
	if transforms.is_empty():
		print("BENCH FAILED: 没有零件了")
		quit(1)
		return
	var build_mesh: Variant = library.build_default("cube_full")
	var sub_mesh: Variant = library.build_sub("cube_full")
	var old_rounds := 20
	var t1 := Time.get_ticks_usec()
	for i in old_rounds:
		var nodes: Array = build.call("_make_group_nodes", transforms, build_mesh, sub_mesh)
		for node in nodes:
			(node as Node).free()
	var old_ms := float(Time.get_ticks_usec() - t1) / 1000.0 / float(old_rounds)

	print("零件=%d  同型实例=%d" % [grid.parts.size(), transforms.size()])
	print("NEW(就地)   %.3f ms/次" % new_ms)
	print("OLD(重建组) %.3f ms/次  （只算建 MultiMesh，不含节点进出场景树）" % old_ms)
	if new_ms > 0.0:
		print("RATIO %.1fx" % (old_ms / new_ms))

	# --- 标记表重建（拆零件会把 _markers_dirty 标脏，由 _process 限流重建）---
	# 场景没跑 _ready，这两个节点要自己挂上，否则 `_rebuild_markers` 会直接返回
	for prop in ["_anchor_markers", "_joint_markers"]:
		var mm := MultiMeshInstance3D.new()
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		mm.multimesh = multi
		build.add_child(mm)
		build.set(prop, mm)
	var marker_rounds := 5
	var t_first := Time.get_ticks_usec()
	build.call("_rebuild_markers")
	var marker_cold := float(Time.get_ticks_usec() - t_first) / 1000.0
	var t2 := Time.get_ticks_usec()
	for i in marker_rounds:
		build.call("_rebuild_markers")
	var marker_warm := float(Time.get_ticks_usec() - t2) / 1000.0 / float(marker_rounds)
	print("MARKERS     %.3f ms 冷启动（算一遍缓存） / %.3f ms 之后每次  （%d 件规模）" % [
		marker_cold, marker_warm, grid.parts.size()
	])
	build.free()
	quit()
