@tool
class_name ArenaKit
extends RefCounted

## Kenney 素材包（CC0，`assets/arena/<pack>/*.glb`）→ 测试场的地形与道具。
##
## 为什么要有这一层：赛道是**模块拼**出来的（直道 / 弯道 / 坡道都是一格格的片子），
## 拼错（弯道拐反、格子没对齐、漏一格）肉眼很难发现。所以这里把"模块"抽象成
## 一个统一的空间：**模块本地 = 把子节点变换烘进去之后的网格空间**，并给出
##   0. `box_of()`：模块在本地空间里的包围盒（多网格模块也合并进来）；
##   1. `piece_transform()`：按"旋转后包围盒最小角贴格角"摆放，和建造模式的摆放约定一致；
##   2. `covers()`：世界里某个点 (x, z) 在不在这个模块的**路面**上（点投影到地面，判断在不在三角形内）。
##     用它沿赛道中心线扫一遍，就能断言"整圈都铺满了路"，也能反推出弯道到底往哪边拐。
##
## `1 个 kit 单位 = UNIT 个 cube`：车的宽度是 4.8 cube，路必须比车宽。

## 素材包目录（一个包一个实例；部件名在包内唯一，跨包可能有重名，所以由调用方加前缀）。
var dir := ""
## 1 个 kit 单位 = 几个 cube。**每个场地自己设**：赛道用 8（路面要够宽），
## 方块地形用 3（一块地形方块 3 米，和 5 米长的车一个量级，看着才像地形而不是碎渣）。
var unit := 8.0
var _boxes := {}   # name -> AABB（本地包围盒，未缩放）
var _parts := {}   # name -> [{mesh, local}]（local = 网格 → 模块本地；旗子/车是多网格）


func has_piece(name: String) -> bool:
	return ResourceLoader.exists("%s/%s.glb" % [dir, name])


## 模块的子网格：旗子 = 杆 + 布，车 = 轮 + 身，所以摆放和命中都要逐子网格来。
func parts_of(name: String) -> Array:
	if _parts.has(name):
		return _parts[name]
	var parts := []
	var path := "%s/%s.glb" % [dir, name]
	if ResourceLoader.exists(path):
		var packed: PackedScene = load(path) as PackedScene
		if packed != null:
			_collect_parts(packed.instantiate(), Transform3D(), parts)
	if parts.is_empty():
		push_warning("ArenaKit：模块 %s 里没有网格" % name)
	_parts[name] = parts
	return parts


## 模块的主网格（多网格时取第一个；材质挂在网格表面上，MultiMesh 直接复用）。
func mesh_of(name: String) -> Mesh:
	var parts := parts_of(name)
	return parts[0]["mesh"] if not parts.is_empty() else null


## 模块在本地空间里的包围盒（未缩放）。
func box_of(name: String) -> AABB:
	if _boxes.has(name):
		return _boxes[name]
	var box := AABB()
	var first := true
	for part in parts_of(name):
		var local: AABB = (part["local"] as Transform3D) * (part["mesh"] as Mesh).get_aabb()
		box = local if first else box.merge(local)
		first = false
	_boxes[name] = box
	return box


## 模块绕 Y 转 yaw 度之后的包围盒（仍然未缩放）。
func rotated_box_of(name: String, yaw: float) -> AABB:
	return BuildGrid.rotate_aabb(Basis(Vector3.UP, deg_to_rad(yaw)), box_of(name))


## 把模块摆在格坐标 `cell` 上（单位 = kit 格，x → 世界 x，y → 世界 z）。
## cell 是**旋转后包围盒最小角**所在的格子 —— 和建造模式一个约定，格子对不齐的问题就不会出现。
func piece_transform(name: String, cell: Vector2, yaw: float, lift := 0.0) -> Transform3D:
	var basis := Basis(Vector3.UP, deg_to_rad(yaw)).scaled(Vector3(unit, unit, unit))
	# 注意：这里必须用**缩放过**的 basis 去算包围盒（结果直接是"相对原点的世界尺度 AABB"）。
	# 曾经写成 basis * rotated_box_of(...)（把旋转算了两遍），转 90° 的模块会飞到隔壁格去。
	var local := BuildGrid.rotate_aabb(basis, box_of(name))
	var target := Vector3(float(cell.x) * unit, lift * unit, float(cell.y) * unit)
	return Transform3D(basis, target - local.position)


## 按**包围盒中心**摆放（摆风景的时候用这个，不用去算最小角在哪）。
func piece_transform_center(
	name: String, center: Vector2, yaw: float, lift := 0.0
) -> Transform3D:
	var basis := Basis(Vector3.UP, deg_to_rad(yaw)).scaled(Vector3(unit, unit, unit))
	var local := rotated_box_of(name, yaw)
	var target := Vector3(center.x * unit, lift * unit, center.y * unit)
	return Transform3D(basis, target - basis * (local.position + local.size * 0.5))


## 模块摆好之后某个子网格的世界变换。
func part_transform(name: String, cell: Vector2, yaw: float, index: int, lift := 0.0) -> Transform3D:
	return piece_transform(name, cell, yaw, lift) * (parts_of(name)[index]["local"] as Transform3D)


## 世界点 (x, z) 在不在这块模块的**路面**上（投影到地面做点在三角形内判定）。
func covers(name: String, cell: Vector2, yaw: float, point: Vector2) -> bool:
	var world := Vector3(point.x, 0.0, point.y)
	for index in parts_of(name).size():
		var local: Vector3 = part_transform(name, cell, yaw, index).affine_inverse() * world
		if _mesh_covers_point(parts_of(name)[index]["mesh"], local):
			return true
	return false


## 一批 transform → MultiMesh 节点（每个子网格一个，多网格模块也只是每类一次 draw call）。
func make_nodes(name: String, transforms: Array, label := "") -> Array:
	var out := []
	var parts := parts_of(name)
	for index in parts.size():
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = parts[index]["mesh"]
		multi.instance_count = transforms.size()
		var local: Transform3D = parts[index]["local"]
		for i in transforms.size():
			multi.set_instance_transform(i, (transforms[i] as Transform3D) * local)
		var node := MultiMeshInstance3D.new()
		node.multimesh = multi
		node.name = "%s_%d" % [label if not label.is_empty() else name, index]
		# 场地很大，阴影重画一遍太贵（测试场本来就把阴影关了）
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		out.append(node)
	return out


## 模块摆好之后的世界包围盒（缩放、旋转、平移都算上）—— 给碰撞箱和体检用。
func world_box_of(name: String, cell: Vector2, yaw: float, lift := 0.0) -> AABB:
	var transform := piece_transform(name, cell, yaw, lift)
	var box := box_of(name)
	var result := AABB(transform * box.position, Vector3.ZERO)
	for i in 8:
		var corner := box.position + Vector3(
			box.size.x if (i & 1) != 0 else 0.0,
			box.size.y if (i & 2) != 0 else 0.0,
			box.size.z if (i & 4) != 0 else 0.0
		)
		result = result.expand(transform * corner)
	return result


func _mesh_covers_point(mesh: Mesh, point: Vector3) -> bool:
	for surface in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			for i in range(0, vertices.size() - 2, 3):
				if _triangle_covers(vertices[i], vertices[i + 1], vertices[i + 2], point):
					return true
			continue
		for i in range(0, indices.size() - 2, 3):
			if _triangle_covers(
				vertices[indices[i]], vertices[indices[i + 1]], vertices[indices[i + 2]], point
			):
				return true
	return false


## 投影到 XZ 平面做三角形包含判定（路面片子是平的，投影就是它的占地）。
func _triangle_covers(a: Vector3, b: Vector3, c: Vector3, p: Vector3) -> bool:
	var d1 := (p.x - b.x) * (a.z - b.z) - (a.x - b.x) * (p.z - b.z)
	var d2 := (p.x - c.x) * (b.z - c.z) - (b.x - c.x) * (p.z - c.z)
	var d3 := (p.x - a.x) * (c.z - a.z) - (c.x - a.x) * (p.z - a.z)
	var has_neg := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (has_neg and has_pos)


func _collect_parts(node: Node, to_root: Transform3D, out: Array) -> void:
	var here := to_root
	if node is Node3D:
		here = to_root * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append({"mesh": (node as MeshInstance3D).mesh, "local": here})
	for child in node.get_children():
		_collect_parts(child, here, out)
