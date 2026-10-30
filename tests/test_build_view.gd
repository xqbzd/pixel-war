extends McpTestSuite

## 建造模式的"增量放/拆"：视觉 MultiMesh 的实例数必须和格子里真实的零件数对得上
## （放置走 `_append_parts`、拆除走 `_remove_parts`，都是 O(1) 的增量操作，
## 不再整表重建 —— 零件多的时候放/拆都不能卡）。
##
## ⚠️ 测试方法不能 await（runner 是同步调用），所以这里**不跑**建造模式的 `_ready`：
## 手动装好零件表和 `PlacedParts` 根节点，只测增量视觉那套逻辑。

func suite_name() -> String:
	return "build_view"


func _make_build() -> Node:
	var build: Node = (load("res://scenes/build_mode.tscn") as PackedScene).instantiate()
	var library: PartLibrary = build.get("_library")
	library.load_all("res://data/parts")
	var defs := {}
	for id in library.ids():
		defs[id] = library.get_def(id)
	build.set("_defs", defs)
	var root := Node3D.new()
	root.name = "PlacedParts"
	build.add_child(root)
	return build


func test_incremental_place_and_remove_keeps_multimeshes_in_sync() -> void:
	var build := _make_build()
	var grid = build.get("_grid")
	var library: PartLibrary = build.get("_library")
	var cube: PartDef = library.get_def("cube_full")
	assert_true(cube != null and grid != null, "零件表没读出来")
	if cube == null or grid == null:
		build.free()
		return
	# 放 5×5 的方块墙（走真实 place + 增量追加）
	var cells: Array = []
	for z in 5:
		for y in 5:
			var cell := Vector3i(0, y, z)
			var before: int = grid.parts.size()
			assert_true(bool(grid.place(cube, cell, Basis.IDENTITY)["ok"]), "放下 %s" % str(cell))
			build.call("_append_parts", before)
			cells.append(cell)
	assert_eq(_instance_total(build), 25, "放完 25 块 = 25 个实例")
	# 拆 7 块（走真实 victim_at + 增量移除）
	for i in 7:
		var cell: Vector3i = cells[i]
		var victim: Dictionary = grid.victim_at(cell, "cube_full")
		assert_true(bool(grid.remove(cell, "cube_full")), "拆掉 %s" % str(cell))
		build.call("_remove_parts", [victim])
	assert_eq(grid.parts.size(), 18, "格子里剩 18 个零件")
	assert_eq(_instance_total(build), 18, "MultiMesh 实例数也要是 18（增量移除没漏）")
	# 整表重建（加载载具走这条路）之后，实例数 / 记录也要对得上
	build.call("_rebuild_parts")
	assert_eq(_instance_total(build), grid.parts.size(), "整表重建后实例数 = 零件数")
	for key in (build.get("_part_nodes") as Dictionary).keys():
		var record: Dictionary = (build.get("_part_nodes") as Dictionary)[key]
		assert_eq(
			(record["entries"] as Array).size(),
			(record["nodes"][0] as MultiMeshInstance3D).multimesh.visible_instance_count,
			"每个分组的 entries 要和实例数一致：%s" % key
		)
	# 再拆到空：这一类零件的节点应该被回收
	for i in range(7, 25):
		var cell: Vector3i = cells[i]
		var victim: Dictionary = grid.victim_at(cell, "cube_full")
		if bool(grid.remove(cell, "cube_full")):
			build.call("_remove_parts", [victim])
	assert_eq(grid.parts.size(), 0, "全拆光了")
	assert_eq(_instance_total(build), 0, "实例也清零了")
	assert_eq((build.get("_part_nodes") as Dictionary).size(), 0, "空掉的分组节点要回收")
	build.free()


## `_part_nodes` 里所有 MultiMesh 的实例数之和。
func _instance_total(build: Node) -> int:
	var total := 0
	var records: Dictionary = build.get("_part_nodes")
	for key in records.keys():
		for node in records[key]["nodes"]:
			total += (node as MultiMeshInstance3D).multimesh.visible_instance_count
	return total
