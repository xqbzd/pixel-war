@tool
class_name VehicleDef
extends RefCounted

## 载具定义：一串「部件 + cube 网格坐标 + 绕 Y 朝向」。
##
## 文件格式（data/vehicles/*.vehicle.txt，AI 和人改的都是它）：
##
##   name = 侦查艇 / Scout
##   part = cube_full 0 0 0 0        # 部件id x y z yaw(度)
##   part = half_cube 4 0 1 90
##
## 约定：单位是 cube；y 向上，-z 为车头方向（沿用 Godot 约定）；
## 朝向支持 yaw / pitch / roll 三个角度（都只支持 90 度一档），
## 因为它们要能表达建造模式里产生的一切朝向 —— 贴到侧面或三角面时零件会绕 X 或 Z 翻倒，
## 只用 yaw 是存不下来的。省略后面两个角度时按老格式（只给 yaw）解析。
## 注意：**两个部件可以共享同一格**（多零件共享格子），只要体素不穿模、且"基准格"不同 ——
## 详见 BuildGrid。`overlap_cells()` 只能当"声明格子撞了"的提示看，不是错误。

const SUFFIX := ".vehicle.txt"
const DEFAULT_DIR := "res://data/vehicles"

var id := ""
var display_name := ""
var parts: Array = []  # [{part_id: String, cell: Vector3i, yaw: float}]
var warnings: PackedStringArray = PackedStringArray()
var source_path := ""


static func from_text(text: String, path := "") -> VehicleDef:
	var vehicle := VehicleDef.new()
	vehicle.source_path = path
	if not path.is_empty():
		# scout.vehicle.txt -> scout
		vehicle.id = path.get_file().get_basename().get_basename()
		vehicle.display_name = vehicle.id
	var line_no := 0
	for raw in text.split("\n"):
		line_no += 1
		var line := PartDef.strip_comment(raw).strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq < 0:
			vehicle._warn("第 %d 行不是 key = value，已忽略：%s" % [line_no, line])
			continue
		var key := line.substr(0, eq).strip_edges().to_lower()
		var value := line.substr(eq + 1).strip_edges()
		vehicle._apply(key, value, line_no)
	return vehicle


static func load_all(path := DEFAULT_DIR) -> Array:
	var out := []
	var folder := DirAccess.open(path)
	if folder == null:
		push_error("VehicleDef: 打不开载具目录 %s" % path)
		return out
	var names := folder.get_files()
	names.sort()
	for file_name in names:
		if not file_name.ends_with(SUFFIX):
			continue
		var full := path + "/" + file_name
		out.append(VehicleDef.from_text(FileAccess.get_file_as_string(full), full))
	return out


func _apply(key: String, value: String, line_no: int) -> void:
	match key:
		"name":
			display_name = value
		"part":
			var tokens := value.replace(",", " ").split(" ", false)
			if tokens.size() < 4:
				_warn("第 %d 行：part 至少需要「部件id x y z [yaw]」，收到 '%s'" % [line_no, value])
				return
			var angles := [0.0, 0.0, 0.0]  # yaw, pitch, roll
			var labels := ["yaw", "pitch", "roll"]
			for i in range(3):
				if tokens.size() <= 4 + i:
					break
				var raw := float(tokens[4 + i])
				# 注意用 roundf 而不是 round：round() 是返回 Variant 的多态全局函数，无法推断类型
				var snapped := roundf(raw / 90.0) * 90.0
				if not is_equal_approx(snapped, raw):
					_warn(
						"第 %d 行：%s %s 度会被吸附到 %s 度（只支持 90 度一档）"
						% [line_no, labels[i], raw, snapped]
					)
				angles[i] = snapped
			parts.append({
				"part_id": tokens[0],
				"cell": Vector3i(int(tokens[1]), int(tokens[2]), int(tokens[3])),
				"yaw": wrapf(angles[0], 0.0, 360.0),
				"pitch": wrapf(angles[1], 0.0, 360.0),
				"roll": wrapf(angles[2], 0.0, 360.0),
				"basis": euler_basis(angles[1], angles[0], angles[2]),
			})
		_:
			_warn("第 %d 行：未知键 '%s'，已忽略" % [line_no, key])


## 用 (pitch 绕 X, yaw 绕 Y, roll 绕 Z) 构造朝向。
## 顺序与 Godot 默认的 EULER_ORDER_YXZ 一致，所以能和 basis.get_euler() 来回转换。
static func euler_basis(pitch: float, yaw: float, roll: float) -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), deg_to_rad(roll)))


## 从 basis 反推 (yaw, pitch, roll)（度，吸附到 90 度一档、规整到 [0, 360)）。
static func euler_of(basis: Basis) -> Vector3:
	var e := basis.get_euler()
	return Vector3(
		_snap_angle(rad_to_deg(e.y)),
		_snap_angle(rad_to_deg(e.x)),
		_snap_angle(rad_to_deg(e.z))
	)


static func _snap_angle(degrees: float) -> float:
	return wrapf(roundf(degrees / 90.0) * 90.0, 0.0, 360.0)


## 把一批部件写成 .vehicle.txt。坐标会归一化（最小角搬到 0,0,0），
## entries: [{part_id: String, cell: Vector3i, basis: Basis}]
static func write_file(path: String, display_name: String, entries: Array) -> Dictionary:
	if entries.is_empty():
		return {"ok": false, "reason": "还没有放任何零件"}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "reason": "无法写入 %s" % path}
	# 坐标**原样保存**，不归一化：载具在场地里的位置要能原样还原。
	# （曾经归一化到最小角 0,0,0 —— 结果轮子被压到最底排，再加载就整排消失）
	file.store_line("# 由建造模式保存（坐标就是建造场地里的坐标，原样还原）")
	file.store_line("# 格式：part = <部件id> <x> <y> <z> yaw pitch roll（角度 90 度一档）")
	file.store_line("name = %s" % display_name)
	file.store_line("")
	for entry in entries:
		var cell: Vector3i = entry["cell"]
		var angles := euler_of(entry["basis"])
		file.store_line("part = %s %d %d %d %d %d %d" % [
			entry["part_id"],
			cell.x,
			cell.y,
			cell.z,
			int(angles.x),
			int(angles.y),
			int(angles.z),
		])
	file.close()
	return {"ok": true, "path": path, "count": entries.size(), "reason": ""}


## 只改文件里的 name 行，其余内容原样保留（用于「重命名」）。
static func rename_file(path: String, new_name: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var text := FileAccess.get_file_as_string(path)
	var lines := text.split("\n")
	var out := PackedStringArray()
	var replaced := false
	for line in lines:
		if not replaced and line.strip_edges().begins_with("name") and line.find("=") != -1:
			out.append("name = %s" % new_name)
			replaced = true
		else:
			out.append(line)
	if not replaced:
		out.insert(0, "name = %s" % new_name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string("\n".join(out))
	file.close()
	return true


func part_count() -> int:
	return parts.size()


## 返回重复占用的格子（同一格放两个部件）。
func overlap_cells() -> Array:
	var seen := {}
	var duplicates := []
	for part in parts:
		var key := str(part["cell"])
		if seen.has(key):
			duplicates.append(part["cell"])
		seen[key] = true
	return duplicates


func used_part_ids() -> Array:
	var out := {}
	for part in parts:
		out[part["part_id"]] = true
	var ids := out.keys()
	ids.sort()
	return ids


## 轮子规格：每个"带 `wheel_body` 的部件"（轮轴）在测试场里变成一个驱动轮。
## 返回 [{offset: 轮胎几何中心（载具坐标系）, radius, steer_sign, transform, local_box}]。
## steer_sign：在**重心之前**的轮子 +1（正转），重心之后 -1（反转）—— 全轮转向，
## 这样任一侧的轮子掉光了还能靠剩下的轮子转方向。
func wheel_specs(library: PartLibrary) -> Array:
	var out := []
	var centre_x := center_of_mass(library).x
	for index in parts.size():
		var part: Dictionary = parts[index]
		var def: PartDef = library.get_def(part["part_id"])
		if def == null or def.wheel_body.is_empty():
			continue
		var sub := def.sub_model_volume()
		if sub == null:
			continue
		var local := PartDef.tight_bounds(sub, def.sub_model_offset(), Vector3.ONE)
		var transform := BuildGrid.cell_transform(def, part["cell"], part["basis"])
		var offset: Vector3 = transform * local.get_center()
		out.append({
			"part_index": index,     # 零件下标（毁伤：这个轮轴被打掉时轮胎要跟着没）
			"part_id": part["part_id"],
			"offset": offset,
			"radius": maxf(local.size.y, local.size.z) * 0.5,
			"steer_sign": 1.0 if offset.x > centre_x else -1.0,
			"transform": transform,
			"local_box": local,
			"local_centre": local.get_center(),
		})
	return out


## 整机质量（kg）：各部件 weight 之和。
func total_mass(library: PartLibrary) -> float:
	var mass := 0.0
	for part in parts:
		var def: PartDef = library.get_def(part["part_id"])
		if def != null:
			mass += def.weight_kg
	return mass


## 整体重心（载具坐标系，单位 = cube）：各部件**本体包围盒中心**按重量加权。
## 和测试场里给刚体设的质心用的是同一个算法 —— 转向的正负分界也就跟着重量走。
func center_of_mass(library: PartLibrary) -> Vector3:
	return weighted_center_of_mass(parts, library.defs, bounds(library).get_center())


## 重心计算的**唯一实现**：`parts` = [{part_id, cell, basis}]（可以是载具的全部零件，
## 也可以是"毁伤后还活着的那些"），`defs` = `PartLibrary.defs`。
##
## 三个地方共用它：建造模式（现场看重心）、测试场（驾驶）、毁伤状态（打掉零件后重算）——
## 以前是各写一份，容易改一处忘一处（"驾驶手感不对"时就分不清是重心算错还是车本身偏）。
## `fallback` 是"所有零件都没有重量"时的兜底（一般用不到）。
static func weighted_center_of_mass(parts: Array, defs: Dictionary, fallback := Vector3.ZERO) -> Vector3:
	var mass := 0.0
	var moment := Vector3.ZERO
	for part: Dictionary in parts:
		var def: PartDef = defs.get(str(part.get("part_id", "")))
		if def == null or def.weight_kg <= 0.0:
			continue
		var local := BuildGrid.rotate_aabb(part["basis"], def.body_bounds())
		var centre := BuildGrid.cell_transform(def, part["cell"], part["basis"]).origin + local.get_center()
		mass += def.weight_kg
		moment += centre * def.weight_kg
	if mass <= 0.0:
		return fallback
	return moment / mass


## 整机质量（同上：`parts` 可以是全部零件，也可以是还活着的那些）。
static func weighted_mass(parts: Array, defs: Dictionary) -> float:
	var mass := 0.0
	for part: Dictionary in parts:
		var def: PartDef = defs.get(str(part.get("part_id", "")))
		if def != null:
			mass += def.weight_kg
	return mass


## 载具包围盒（单位 = cube）。多 cube 部件按 def.cubes 计入，yaw 为 90/270 时交换 x/z 尺寸。
func bounds(library: PartLibrary) -> AABB:
	if parts.is_empty():
		return AABB(Vector3.ZERO, Vector3.ONE)
	var mn := Vector3.INF
	var mx := -Vector3.INF
	for part in parts:
		var cell: Vector3i = part["cell"]
		var size := Vector3.ONE
		var def: PartDef = library.get_def(part["part_id"]) if library != null else null
		if def != null:
			# 用旋转后的 AABB 尺寸（与 BuildGrid 的摆放约定一致：AABB 最小角贴在格子角点上）
			size = Vector3(BuildGrid.size_of(def, part["basis"]))
		mn = mn.min(Vector3(cell))
		mx = mx.max(Vector3(cell) + size)
	return AABB(mn, mx - mn)


## 载具的**真实**包围盒（单位 = cube）：用每个零件的**网格**包围盒
## （`PartDef.mesh_bounds()` —— 含轮体这种附属子模型，也含 `model_offset` 造成的下探），
## 再按零件的摆放变换摆到载具坐标里。
##
## ⚠️ 为什么不能拿 `bounds()` 当"车底"：那个用的是**声明的 cubes 盒子**，轮体是挂在
## 盒子外面的附属子模型，它**探不到** —— 主界面预览和出生点拿它算贴地，半个轮胎就会插进地里
## （用户报的"预览时轮胎卡在地里、进游戏车也卡在地下"）。贴地/量最低点一律用这个。
func actual_bounds(library: PartLibrary) -> AABB:
	if parts.is_empty():
		return AABB(Vector3.ZERO, Vector3.ONE)
	var mn := Vector3.INF
	var mx := -Vector3.INF
	for part in parts:
		var def: PartDef = library.get_def(part["part_id"]) if library != null else null
		if def == null:
			continue
		var local := BuildGrid.rotate_aabb(part["basis"], def.mesh_bounds())
		var place := BuildGrid.cell_transform(def, part["cell"], part["basis"])
		var lo := place.origin + local.position
		mn = mn.min(lo)
		mx = mx.max(lo + local.size)
	if not is_finite(mn.x):
		return bounds(library)
	return AABB(mn, mx - mn)


## 最低点的 y（载具坐标，单位 = cube）—— 贴地时抬多少就按它算。
func lowest_y(library: PartLibrary) -> float:
	return actual_bounds(library).position.y


func cube_count(library: PartLibrary) -> int:
	var total := 0
	for part in parts:
		var def: PartDef = library.get_def(part["part_id"]) if library != null else null
		if def == null:
			total += 1
			continue
		total += int(def.cubes.x) * int(def.cubes.y) * int(def.cubes.z)
	return total


## 实例化：每个 (部件, 渲染路线) 打包成一个 MultiMesh，返回统计信息。
## mode < 0 表示用部件自己声明的路线。
func instantiate(library: PartLibrary, mode := -1) -> Dictionary:
	var groups := {}
	var missing := []
	for part in parts:
		var part_id: String = part["part_id"]
		if not library.has_part(part_id):
			missing.append(part_id)
			continue
		var def: PartDef = library.get_def(part_id)
		var part_mode: int = def.render_mode if mode < 0 else mode
		var key := "%s:%d" % [part_id, part_mode]
		if not groups.has(key):
			groups[key] = {
				"build": library.build_for(part_id, part_mode),
				"sub": library.build_sub(part_id),
				"transforms": [],
			}
		var basis: Basis = part["basis"]
		# 用与建造网格相同的摆放约定，避免绕格子角点旋转把零件甩到隔壁格
		groups[key]["transforms"].append(BuildGrid.cell_transform(def, part["cell"], basis))

	var root := Node3D.new()
	root.name = "Vehicle"
	var instances := 0
	var tris := 0
	for key in groups.keys():
		var group: Dictionary = groups[key]
		# 零件本体 + 附属子模型（轮体）各一个批次，共用同一批实例变换
		var nodes := PartLibrary.make_part_nodes(group["transforms"], group["build"], group["sub"])
		for i in nodes.size():
			var node: Node3D = nodes[i]
			node.name = "%s_%d" % [str(key).replace(":", "_"), i]
			root.add_child(node)
		instances += group["transforms"].size()
		tris += group["transforms"].size() * int(group["build"].get("tris", 0))
		tris += group["transforms"].size() * int(group["sub"].get("tris", 0))
	for part_id in missing:
		push_warning("VehicleDef[%s]: 找不到部件 %s，已跳过" % [id, part_id])
	return {
		"node": root,
		"groups": groups.size(),
		"instances": instances,
		"tris": tris,
		"missing": missing,
	}


func _warn(message: String) -> void:
	if not warnings.has(message):
		warnings.append(message)
