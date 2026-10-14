extends SceneTree

## 测试场体检（**要有窗口**，不带头部无渲染统计是 0）：把某辆车摆进测试场，
## 点清场景里到底有多少节点/网格，并读引擎的 draw / 图元统计。
##
##   godot --path <项目目录> --script res://tools/inspect_field.gd [车辆id]
##
## 用途：帧率不对时先跑这个。正常规模参考（custom_1，33 件）：
##   MeshInstance3D ≈ 10（3 个 MultiMesh 批次 + 4 条轮胎 + 场地）、draw ≈ 50、图元 ≈ 9000。
##   draw / 图元成倍上涨 = 场景内容被重复建了（WorldEnvironment / 载具数量会直接显示出来）。

const VEHICLE_DIR := "res://data/vehicles"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var vehicle_id := "custom_1" if args.is_empty() else String(args[0])
	var path := "%s/%s.vehicle.txt" % [VEHICLE_DIR, vehicle_id]
	if not FileAccess.file_exists(path):
		print("找不到 %s" % path)
		quit()
		return
	var vehicle := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)
	print("车辆 %s：%d 件" % [vehicle_id, vehicle.part_count()])
	# 车重 / 重心 / 轮子布局：全轮转向靠"重心前 +1、重心后 -1"分正反，
	# 前后分错（比如轮子挂在车头面上、轮胎中心被推出重心之外）一眼能看出来。
	var library := PartLibrary.new()
	library.load_all()
	var mass := vehicle.total_mass(library)
	var com := vehicle.center_of_mass(library)
	print("质量 %.0f kg   重心 %s（x 大于重心的轮子正转、小于的反转）" % [mass, com])
	for spec in vehicle.wheel_specs(library):
		print("  轮子 %s offset=%s 半径=%.2f 转向符号=%+.0f" % [
			spec["part_id"], spec["offset"], float(spec["radius"]), float(spec["steer_sign"])
		])
	var field: Node = (load("res://scenes/test_field.tscn") as PackedScene).instantiate()
	root.add_child(field)
	await process_frame
	field.call("_spawn", vehicle)
	for _i in range(40):
		await process_frame
	var counts := {}
	var mesh_nodes := 0
	var mm_instances := 0
	var listing := PackedStringArray()
	var stack: Array = [field]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var cls := node.get_class()
		counts[cls] = 1 + int(counts.get(cls, 0))
		if node is WorldEnvironment or node is DirectionalLight3D or node is MeshInstance3D:
			listing.append("%s [%s] ← %s" % [str(node.name), cls, str(node.get_parent().get_path() if node.get_parent() != null else "-")])
		if node is MeshInstance3D:
			mesh_nodes += 1
			if node is MultiMeshInstance3D:
				var mm: MultiMesh = node.get("multimesh")
				if mm != null:
					mm_instances += mm.instance_count
		for child in node.get_children():
			stack.append(child)
	var keys := counts.keys()
	keys.sort()
	print("节点清点：")
	for key in keys:
		print("   %-24s %d" % [key, counts[key]])
	listing.sort()
	for line in listing:
		print("   · %s" % line)
	print("MeshInstance3D 共 %d 个（其中 MultiMesh 实例 %d 个）" % [mesh_nodes, mm_instances])
	print("FPS=%d  draw=%d  图元=%d  物理=%.1fms" % [
		Engine.get_frames_per_second(),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
	])
	# 哨兵：灌一堆输入事件后再点一次名。输入处理里要是混进了"建东西"的代码，
	# 这里的数字就会涨（曾经把整段 _build_arena 误贴进 _unhandled_input，
	# 结果鼠标一动就多一套光照+地板，帧率断崖）。
	var before := counts
	for i in range(200):
		var motion := InputEventMouseMotion.new()
		motion.relative = Vector2(float(i % 7) - 3.0, float(i % 5) - 2.0)
		Input.parse_input_event(motion)
		var key := InputEventKey.new()
		key.keycode = KEY_W if i % 2 == 0 else KEY_A
		key.pressed = true
		Input.parse_input_event(key)
	for _i in range(10):
		await process_frame
	var after := {}
	stack = [field]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		after[node.get_class()] = 1 + int(after.get(node.get_class(), 0))
		for child in node.get_children():
			stack.append(child)
	var grew := []
	for key2 in after.keys():
		if int(after[key2]) > int(before.get(key2, 0)):
			grew.append("%s %d→%d" % [key2, int(before.get(key2, 0)), int(after[key2])])
	if grew.is_empty():
		print("输入 400 个事件后节点数不变 ✓")
	else:
		print("!! 输入事件把场景撑大了：%s" % str(grew))
	# 刚出生时还在下落/悬挂回弹，物理耗时会虚高；静置几秒再看一次才是稳态
	for _i in range(180):
		await process_frame
	print("静置 3 秒后：物理=%.1fms  FPS=%d" % [
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Engine.get_frames_per_second(),
	])
	quit()
