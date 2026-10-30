extends SceneTree

## 测试场"进场耗时"的体检脚本（无头也能跑）：把进场拆成**场地 / 车体 / 轮胎 / 转塔 / 射界**
## 几段分别计时，并支持在车上"加 N 把枪"复现"枪多了进场卡很久"。
##
##   godot --headless --path <项目目录> --script res://tools/profile_field_entry.gd -- [车辆id] [额外枪数]
##   （注意中间那个 `--`：Godot 只把它后面的参数当"用户参数"传给脚本。）
##
## 跑完看这几行：
##   * `Turret.setup ×N` —— **每把枪**的转塔几何，必须很小（缓存后 ~0.1 ms/台）。
##     它曾经是 0.6 秒/台（每次都从 48³ 体积的最外层重新扫），枪一多就把进场拖成十几秒。
##   * `_refresh_turret_arcs` —— 每把枪 128 个角度格子 × 附近零件数；零件被打掉后还会重算。
##   * `VehicleRig.setup` —— 玩家车 + 4 台靶子各建一遍（每件一个碰撞盒 + 一组 MultiMesh），
##     和枪数无关、和零件总数成正比。
##
## 注意：这里直接调 `_spawn()`（跳过"核心是否连通"的校验），加出来的枪只是用来计时，
## 不保证摆位合法 —— 要玩的话请在建造模式里真摆。

const VEHICLE_DIR := "res://data/vehicles"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var vehicle_id := "custom_1" if args.is_empty() else String(args[0])
	var extra_guns := 0 if args.size() < 2 else int(args[1])
	var path := "%s/%s.vehicle.txt" % [VEHICLE_DIR, vehicle_id]
	if not FileAccess.file_exists(path):
		print("找不到 %s" % path)
		quit()
		return
	var text := FileAccess.get_file_as_string(path)
	if extra_guns > 0:
		text = _pad_with_guns(text, extra_guns)
	var vehicle := VehicleDef.from_text(text, path)
	print("车辆 %s：%d 件（额外枪 %d）" % [vehicle_id, vehicle.part_count(), extra_guns])

	var t0 := Time.get_ticks_usec()
	var library := PartLibrary.new()
	library.load_all()
	print("  部件库 load_all          %7.1f ms" % _ms(t0))

	# 各个网格第一次生成要多久（每个 PartLibrary 实例各算一次，换场景就重来）
	for id in library.ids():
		t0 = Time.get_ticks_usec()
		var build := library.build_default(str(id))
		var one := _ms(t0)
		t0 = Time.get_ticks_usec()
		library.build_default(str(id))   # 第二次：走缓存，应该是 0
		print("    网格 %-16s %8.1f ms  缓存后 %5.2f ms  quads=%d" % [
			str(id), one, _ms(t0), int(build.get("quads", 0))
		])
		if library.get_def(str(id)).weapon == "turret":
			for index in 3:
				t0 = Time.get_ticks_usec()
				library.build_weapon(str(id), index)
				print("      子模型 %d %8.1f ms" % [index, _ms(t0)])

	# 场地：模型载入 + 每个网格建 trimesh 碰撞（和枪数无关，但它是进场的一部分）
	t0 = Time.get_ticks_usec()
	var field := (load("res://scenes/test_field.tscn") as PackedScene).instantiate()
	root.add_child(field)
	print("  场地 _ready（含模型/碰撞）%7.1f ms" % _ms(t0))

	# 车体：玩家 + 4 台靶子，每个零件一个碰撞盒 + 一组 MultiMesh
	for pass_index in 2:
		t0 = Time.get_ticks_usec()
		var probe_body := RigidBody3D.new()
		probe_body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		root.add_child(probe_body)
		var probe_rig := VehicleRig.new()
		probe_rig.setup(vehicle, library, probe_body, probe_body, true, Vector3.ZERO)
		print("  VehicleRig.setup 第%d份     %7.1f ms（进场要 5 份）" % [pass_index + 1, _ms(t0)])
		probe_body.queue_free()

	# 整段 _spawn
	await process_frame
	t0 = Time.get_ticks_usec()
	field.call("_spawn", vehicle)
	print("  _spawn 整段              %7.1f ms" % _ms(t0))
	print("  转塔 %d 台  零件 %d 件  靶子 %d 台" % [
		(field.get("_turrets") as Array).size(),
		(vehicle.parts as Array).size(),
		(field.get("_enemies") as Array).size(),
	])

	# 单看射界重算（零件被打掉之后也会重算，所以它是**每次**的代价）
	var runs := 5
	t0 = Time.get_ticks_usec()
	for _i in range(runs):
		field.call("_refresh_turret_arcs")
	print("  _refresh_turret_arcs ×%d   %7.1f ms（每次 %.1f）" % [
		runs, _ms(t0), _ms(t0) / float(runs)
	])

	# 单看转塔节点 + 网格（不含射界）
	t0 = Time.get_ticks_usec()
	var count := 0
	for part in vehicle.parts:
		var def: PartDef = library.get_def(str(part["part_id"]))
		if def == null or def.weapon != "turret":
			continue
		var turret := Turret.new()
		root.add_child(turret)
		turret.setup(def, BuildGrid.cell_transform(def, part["cell"], part["basis"]), library)
		turret.free()
		count += 1
	print("  Turret.setup ×%d            %7.1f ms" % [count, _ms(t0)])

	# 进场后稳定跑 120 帧：看每帧武器 + 轮胎的开销（枪多的时候是不是**一直**卡）
	var frames := 120
	t0 = Time.get_ticks_usec()
	for _i in range(frames):
		await process_frame
	var per_frame := _ms(t0) / float(frames)
	print("  进场后 %d 帧              %7.1f ms（每帧 %.2f ms）" % [frames, _ms(t0), per_frame])
	print("  物理 %.2f ms" % (Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0))

	# 真实进场路径：换一个全新场地，走 `enter_vehicle()`（含"核心连通性"校验 + 换车清理）
	for child in root.get_children():
		if child != field:
			child.queue_free()
	await process_frame
	var field2 := (load("res://scenes/test_field.tscn") as PackedScene).instantiate()
	root.add_child(field2)
	await process_frame
	t0 = Time.get_ticks_usec()
	var ok: bool = field2.call("enter_vehicle", vehicle_id)
	print("  enter_vehicle 整段        %7.1f ms（成功=%s）" % [_ms(t0), str(ok)])
	quit()


static func _ms(since: int) -> float:
	return float(Time.get_ticks_usec() - since) / 1000.0


## 在最后一行的零件后面追加 N 把轻机枪（随便找空格子，只为计时用）。
static func _pad_with_guns(text: String, count: int) -> String:
	var out := text
	for i in range(count):
		out += "\npart = light_mg %d %d %d 0 0 0" % [i * 4, 20 + i * 4, 20]
	return out
