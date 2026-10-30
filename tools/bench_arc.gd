extends SceneTree

## A/B：**射界按真实形状挡** vs **按整格方盒挡**。
##
##   godot --headless --path <项目> --script res://tools/bench_arc.gd -- [载具id]
##
## 对车上每一台转塔各算一遍射界角网格，统计"可开火格子"的占比：
##   * A：`clip_boxes` 只有 AABB（改之前的行为）
##   * B：`clip_boxes` 带上每件的凸包半空间（现在的行为，半砖=三角柱、角块=四面体）
## 两者占比的差 = 你说的"射界被整块方块吃掉"的量。

const VEHICLE_DIR := "res://data/vehicles"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var vehicle_id := "custom_1" if args.is_empty() else String(args[0])
	var path := "%s/%s.vehicle.txt" % [VEHICLE_DIR, vehicle_id]
	var library := PartLibrary.new()
	library.load_all()
	var vehicle := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)

	var host := Node3D.new()
	root.add_child(host)
	var body := RigidBody3D.new()
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	host.add_child(body)
	await process_frame

	var rig := VehicleRig.new()
	rig.setup(vehicle, library, host, body, true, Vector3.ZERO)
	await process_frame

	# 两种 `clip_boxes`：A = 只有盒子；B = 盒子 + 凸包半空间
	var boxes: Array = rig.part_boxes()
	var planes: Array = rig.part_planes()
	var entries_a: Array = []
	var entries_b: Array = []
	for i in boxes.size():
		var box: AABB = boxes[i]
		var name := "p%d" % i
		entries_a.append({"box": box, "name": name})
		entries_b.append({
			"box": box, "name": name,
			"planes": (planes[i] as Array) if i < planes.size() else [],
		})

	print("=== %s（%d 件）===" % [vehicle_id, vehicle.parts.size()])
	var free_a := 0
	var free_b := 0
	var cells := 0
	var turrets := 0
	var widened := 0
	for i in vehicle.parts.size():
		var part: Dictionary = vehicle.parts[i]
		var def: PartDef = library.get_def(str(part["part_id"]))
		if def == null or def.weapon != "turret":
			continue
		turrets += 1
		var turret := Turret.new()
		root.add_child(turret)
		turret.setup(def, BuildGrid.cell_transform(def, part["cell"], part["basis"]), library)
		turret.set_meta("part_index", i)

		turret.rebuild_arc(entries_a)
		var a := _free_count(turret)
		turret.rebuild_arc(entries_b)
		var b := _free_count(turret)
		var total := (turret.get("_arc_free") as Array).size()

		free_a += a
		free_b += b
		cells += total
		if b > a:
			widened += 1
		if b != a:
			print("  转塔 #%d：可开火 %d/%d → %d/%d（+%d 格）" % [
				i, a, total, b, total, b - a
			])
		turret.free()

	if cells == 0 or turrets == 0:
		print("这台上没有转塔，或角网格没建起来")
		quit()
		return
	print("")
	print("转塔 %d 台，角格子总数 %d" % [turrets, cells])
	print("A 整格方盒：可开火 %d 格（%.1f%%）" % [free_a, free_a * 100.0 / float(cells)])
	print("B 真实形状：可开火 %d 格（%.1f%%）" % [free_b, free_b * 100.0 / float(cells)])
	print("差：+%d 格（+%.1f 个百分点），%d/%d 台转塔变宽" % [
		free_b - free_a, (free_b - free_a) * 100.0 / float(cells), widened, turrets
	])
	quit()


static func _free_count(turret: Turret) -> int:
	var cells: Array = turret.get("_arc_free")
	if cells == null:
		return 0
	var n := 0
	for value in cells:
		if bool(value):
			n += 1
	return n
