extends SceneTree

## 体检：一台载具**实际生成了哪些碰撞体**（车体形状 / 合并盒 / 受击盒 trimesh）。
##
##   godot --headless --path <项目> --script res://tools/inspect_collision.gd -- [载具id]

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

	print("=== %s ===" % vehicle_id)
	print("零件总数 %d" % rig.state.parts.size())

	# 按"形状 + 占几格"分类：非完整方块（半砖 / 角块）和多方块零件的数量
	var by_shape := {}
	var multi_cell := 0
	for part in vehicle.parts:
		var def: PartDef = library.get_def(str(part["part_id"]))
		if def == null:
			continue
		var key := str(def.shape)
		by_shape[key] = int(by_shape.get(key, 0)) + 1
		var cells: Vector3i = def.cubes
		if cells.x * cells.y * cells.z > 1:
			multi_cell += 1
	print("按形状分类：")
	for key in by_shape.keys():
		print("  %-16s %d 件" % [str(key), int(by_shape[key])])
	print("多格零件（cubes 体积 > 1）%d 件" % multi_cell)

	# 特殊零件（一件一盒）vs 并进合并盒的
	var special := 0
	var merged_parts := 0
	for i in rig.state.parts.size():
		if rig._is_special_part(i):
			special += 1
		else:
			merged_parts += 1
	print("特殊零件（单独建盒，weapon_swivel_collider）%d" % special)
	print("并进合并盒的零件 %d" % merged_parts)

	# 车体上的实际 shape
	var boxes: Array = []
	var box_total := 0
	var shapes := 0
	for child in body.get_children():
		if not (child is CollisionShape3D):
			continue
		shapes += 1
		var shape: CollisionShape3D = child
		if shape.shape is BoxShape3D:
			var size: Vector3 = (shape.shape as BoxShape3D).size
			boxes.append(size)
			box_total += 1
	print("")
	print("车体（RigidBody3D）上的 CollisionShape3D 共 %d 个：其中 BoxShape3D %d 个" % [
		shapes, box_total
	])
	# 合并盒的大小分布
	var big := 0
	var cell_sum := 0.0
	for size: Vector3 in boxes:
		cell_sum += size.x * size.y * size.z
		if size.x * size.y * size.z > 1.5:
			big += 1
	print("  合并盒总体积 %.0f 格（零件格子数约 %d）" % [cell_sum, merged_parts])
	print("  按体积排前 5 个盒子：")
	boxes.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return a.x * a.y * a.z > b.x * b.y * b.z
	)
	for i in mini(5, boxes.size()):
		var s: Vector3 = boxes[i]
		print("    %.0f × %.0f × %.0f = %.0f 格" % [s.x, s.y, s.z, s.x * s.y * s.z])

	# 受击盒
	var hit_count: int = (rig.get("_hit_box") as Array).size()
	var tris := 0
	if rig.hitboxes != null:
		for child in rig.hitboxes.get_children():
			if child is CollisionShape3D and (child as CollisionShape3D).shape is ConcavePolygonShape3D:
				var faces: PackedVector3Array = ((child as CollisionShape3D).shape as ConcavePolygonShape3D).get_faces()
				tris += faces.size() / 3
	print("")
	print("受击盒（StaticBody3D，layer=%d，mask=%d）：" % [
		rig.hitboxes.collision_layer if rig.hitboxes != null else -1,
		rig.hitboxes.collision_mask if rig.hitboxes != null else -1,
	])
	print("  盒子条目 %d 个 → 合成 **1 张 trimesh**，三角形 %d 个" % [hit_count, tris])

	# 凸包路径是否还活着
	var hull: Variant = rig.get("_hull_shape")
	print("")
	print("_hull_shape（带倒角的凸包）目前 = %s" % ("null（不生效）" if hull == null else "存在"))
	quit()
