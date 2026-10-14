extends SceneTree

## 场地体检：不开窗口，直接量**现成场地模型**（Truck Town 的城镇 + 赛道）的规模，
## 并把不同缩放倍数下的实际尺寸列出来，方便定"缩放多少倍"。
##
##   godot --headless --path <项目目录> --script res://tools/inspect_arena.gd

const SCENE := "res://assets/arena/truck_town/town_model.gltf"
## 我们的车大概多长：**单位是格**（车 ~25 格）。这里只用来对比"车和房子/赛道的比例"，
## 所以用格就够 —— 换算成米要乘 `PartDef.CUBE_METERS`（1 格 = 0.5 米 ⇒ 12.5 米）。
const CAR_CUBES := 25.0


func _initialize() -> void:
	var packed: PackedScene = load(SCENE)
	if packed == null:
		print("载入失败：%s" % SCENE)
		quit()
		return
	var root: Node3D = packed.instantiate()
	var meshes := []
	var total_tris := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var mesh_node: MeshInstance3D = node
			var faces := mesh_node.mesh.get_faces()
			var tris := faces.size() / 3
			total_tris += tris
			meshes.append({
				"name": mesh_node.name,
				"tris": tris,
				"box": _relative(mesh_node, root) * mesh_node.mesh.get_aabb(),
			})
		for child in node.get_children():
			stack.append(child)
	print("模型：%s（Truck Town，Godot 官方 demo，MIT）" % SCENE.get_file())
	print("网格 %d 个，三角面 %d 个" % [meshes.size(), total_tris])
	# 房子和赛道是判断"该缩多少倍"最直观的两个参照物
	var house := Vector3.ZERO
	for entry in meshes:
		if str(entry["name"]).contains("House"):
			house = (entry["box"] as AABB).size
			print("  一栋房子 %-16s 尺寸 %s（模型单位）" % [entry["name"], house])
			break
	for entry in meshes:
		if str(entry["name"]).contains("Racetrack"):
			print("  赛道       %-16s 尺寸 %s 最低点 y=%.2f" % [
				entry["name"], entry["box"].size, entry["box"].position.y
			])
	# 全部网格的范围（不含那张 2 公里见方的地面）
	var town := AABB()
	var first := true
	for entry in meshes:
		if str(entry["name"]).contains("OuterGround"):
			continue
		var box: AABB = entry["box"]
		town = box if first else town.merge(box)
		first = false
	print("城镇 + 赛道范围（不含外圈地面）：%s 到 %s" % [
		town.position, town.position + town.size
	])
	print("")
	print("缩放对照（车长 %.0f 格 = %.1f 米）：" % [CAR_CUBES, CAR_CUBES * PartDef.CUBE_METERS])
	for scale in [1.0, 1.5, 2.0, 3.0, 4.0]:
		print("  ×%.1f → 城镇+赛道 %.0f×%.0f 格，一栋房子 %.1f×%.1f×%.1f 格（车长 %.0f 格）" % [
			scale, town.size.x * scale, town.size.z * scale,
			house.x * scale, house.y * scale, house.z * scale, CAR_CUBES,
		])
	root.free()
	quit()


func _relative(node: Node3D, ancestor: Node) -> Transform3D:
	var result := Transform3D()
	var current: Node = node
	while current != null and current != ancestor:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result
