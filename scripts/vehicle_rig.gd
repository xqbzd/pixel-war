@tool
class_name VehicleRig
extends RefCounted

## 一台载具在场景里的"壳"：**一个零件一个碰撞盒 + 分组视觉 + 毁伤状态**。
##
## 玩家车和测试场里的敌方复制品都用它 —— 区别只有两点：
##   * 玩家车：host/body 就是底盘（RigidBody3D，会动），零件被打掉要同步重量/重心；
##   * 敌方复制品：host = 根节点、body = StaticBody3D（当靶子站着不动，不做轮胎/转塔）。
##
## 为什么"一个零件一个 CollisionShape3D"：被打中的时候只拿得到
## `intersect_ray()` 给的 **shape 下标**，所以下标必须**永远等于零件下标**。
## 零件被打掉时**不删** shape（删了后面所有下标都会往前挪），而是把它 `disabled`
## —— 射线立刻就打不到了，下标也还稳。
##
## 视觉还是按 (部件, 渲染路线) 分组的 MultiMesh（省 draw call）；有零件被打掉就
## 重建那一组（只把活着的实例塞回去）。转塔零件在玩家车上由 `Turret` 节点画，
## 这里要跳过（`static_skip_weapon`），不然会和转起来的那份重叠。

var state: VehicleState
var host: Node3D
var body: PhysicsBody3D
## body 是刚体（玩家车 / 靶车都一样）：零件被打掉就把剩下的重量/重心同步给它。
## 只有"站着不动的道具"才传 false。
var sync_mass := false
var static_skip_weapon := false      # 玩家车：转塔零件不画静态网格（由 Turret 画）
var label_text := "载具"             # HUD / 结算文字里显示的名字（"我方" / "靶子2"…）

var shapes := []                     # [CollisionShape3D]，下标 = 零件下标
## **只给射弹看**的受击盒（轮胎那类附属子模型的碰撞体）挂在 `hitboxes` 这个独立 body 上。
## 它在专用层 `HITBOX_LAYER` 上、掩码 0：**车/地形的掩码都不含这一层**，所以它不参与
## 任何物理碰撞（曾经把轮胎盒加到车体刚体上 → 车被地面卡死走不动，用户报的），
## 只有子弹 / 准星这类射线（掩码里带 `HITBOX_LAYER`）才打得到。
const HITBOX_LAYER := 4
var hitboxes: StaticBody3D

var _library: PartLibrary
var _local_offset := Vector3.ZERO    # 底盘本地原点相对载具坐标原点的偏移（玩家车 = -_spawn_center）
var _groups := {}                    # key -> {build, parts: Array[int], node: MultiMeshInstance3D}
var _part_group := []                # 零件下标 -> 分组 key
## shape 下标 -> 零件下标。**不是一一对应**：带轮体的零件（轮轴）会多一个"轮胎碰撞盒"，
## 那样子弹打在轮胎上也能算到这个零件头上（以前只有本体盒，子弹从轮胎之间穿过去）。
var _shape_part := []
var _hit_shape_part := []            # `hitboxes` 上的 shape 下标 -> 零件下标
var _hit_shapes := []                # `hitboxes` 上的 CollisionShape3D
var _hit_box := []                   # `hitboxes` 上每个盒子的 AABB（算真实包围盒用）
var _part_centre := []               # 零件下标 -> 本地中心（算包围盒用）
var _part_box := []                  # 零件下标 -> 本体的本地 AABB


func label() -> String:
	return label_text


func setup(
	vehicle: VehicleDef, library: PartLibrary, host_node: Node3D, body_node: PhysicsBody3D,
	sync_rigid_body := false, local_offset := Vector3.ZERO
) -> void:
	_library = library
	host = host_node
	body = body_node
	sync_mass = sync_rigid_body
	_local_offset = local_offset
	state = VehicleState.new()
	state.setup(vehicle, library.defs)
	shapes.clear()
	_hit_shape_part.clear()
	_groups.clear()
	_part_group.clear()
	_part_centre.clear()
	_part_box.clear()
	for i in vehicle.parts.size():
		var part: Dictionary = vehicle.parts[i]
		var def: PartDef = library.get_def(str(part["part_id"]))
		if def == null:
			continue
		# 摆放变换（host 本地空间：玩家车就是底盘本地空间）
		var place := BuildGrid.cell_transform(def, part["cell"], part["basis"])
		place.origin += _local_offset
		# 碰撞盒①：**本体**包围盒（轮胎是视觉件，靠整圈射线管车的支撑）
		var local := BuildGrid.rotate_aabb(part["basis"], def.body_bounds())
		var box := AABB(place.origin + local.position, local.size)
		_add_shape(box, i)
		_part_box.append(box)
		_part_centre.append(box.get_center())
		# 受击盒②：**轮体（轮胎）**—— 子弹必须打得到轮胎，但它**不能参与物理碰撞**
		# （不然轮子会跟地面打架、车开不动）。所以它挂到独立的 `hitboxes` body 上，
		# 那一层只有射弹射线会查。
		var sub := def.sub_model_volume()
		if sub != null:
			var sub_local := PartDef.tight_bounds(sub, def.sub_model_offset(), Vector3.ONE)
			var sub_rotated := BuildGrid.rotate_aabb(part["basis"], sub_local)
			_add_hit_shape(AABB(place.origin + sub_rotated.position, sub_rotated.size), i)
		# 视觉分组
		var skip := static_skip_weapon and def.weapon == "turret"
		if skip:
			_part_group.append("")
			continue
		var key := "%s:%d" % [str(part["part_id"]), def.render_mode]
		if not _groups.has(key):
			_groups[key] = {
				"build": library.build_default(str(part["part_id"])),
				"parts": [],
				"node": null,
			}
		(_groups[key]["parts"] as Array).append(i)
		_part_group.append(key)
	_rebuild_visuals()
	if sync_mass:
		sync_body()


## 被打中的时候把 shape 下标当零件下标用 —— 挪不了的保证见类注释。
func part_index_of_shape(shape_index: int) -> int:
	if shape_index < 0 or shape_index >= _shape_part.size():
		return -1
	return _shape_part[shape_index]


func _add_shape(box: AABB, part_index: int) -> void:
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box.size
	shape.shape = box_shape
	shape.position = box.get_center()
	body.add_child(shape)
	shapes.append(shape)
	_shape_part.append(part_index)


## 只给射弹看的受击盒（轮胎）。挂在 `hitboxes` 上：不参与物理碰撞，射线才看得到。
func _add_hit_shape(box: AABB, part_index: int) -> void:
	if hitboxes == null:
		hitboxes = StaticBody3D.new()
		hitboxes.name = "Hitboxes"
		hitboxes.collision_layer = HITBOX_LAYER
		hitboxes.collision_mask = 0
		# 挂在车体下（跟着车走），但它是**独立 body**，层/掩码和车体完全分开
		body.add_child(hitboxes)
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box.size
	shape.shape = box_shape
	shape.position = box.get_center()
	hitboxes.add_child(shape)
	_hit_shapes.append(shape)
	_hit_shape_part.append(part_index)
	_hit_box.append(box)


## 打中的是**哪个零件**：受击盒 body（轮胎）和车体 body 各有自己的 shape 表，
## 按打中的是哪个 body 的 RID 来选表。
func part_index_of_hit(body_rid: RID, shape_index: int) -> int:
	if hitboxes != null and hitboxes.get_rid() == body_rid:
		if shape_index < 0 or shape_index >= _hit_shape_part.size():
			return -1
		return _hit_shape_part[shape_index]
	return part_index_of_shape(shape_index)


## 车体上的 shape 数 / 受击盒上的 shape 数（调试 / 测试用）
func shape_counts() -> Vector2i:
	return Vector2i(shapes.size(), _hit_shapes.size())


func part_alive(index: int) -> bool:
	return state != null and state.part_alive(index)


## 活着的零件的本地包围盒并集（相机取"整车最高点"用；零件被打掉会跟着缩）。
func bounds_local() -> AABB:
	var box := AABB()
	var first := true
	for i in _part_box.size():
		if not part_alive(i):
			continue
		box = (_part_box[i] as AABB) if first else box.merge(_part_box[i] as AABB)
		first = false
	return box


## **真实**几何包围盒（本体盒 ∪ 轮胎那种受击盒）—— 贴地/摆位要用它：
## 轮胎挂在车体盒下面，只按本体盒算就会把轮胎埋进地里（用户报的"进游戏车卡在地下"）。
func geometry_bounds_local() -> AABB:
	var box := bounds_local()
	var has := box.size != Vector3.ZERO
	for i in _hit_box.size():
		var shape: CollisionShape3D = _hit_shapes[i] if i < _hit_shapes.size() else null
		if shape != null and is_instance_valid(shape) and shape.disabled:
			continue              # 这个零件被打掉了：它挂的轮胎盒不算
		box = box.merge(_hit_box[i] as AABB) if has else (_hit_box[i] as AABB)
		has = true
	return box


## 打伤害：走 VehicleState 的规则，然后把场景改掉。
## 返回 {destroyed, detached, mass_changed, core_lost} —— destroyed/detached 里是被消灭的**零件下标**，
## 调用方拿它去清理挂在这些零件上的东西（轮胎、转塔）。
func apply_damage(index: int, amount: float) -> Dictionary:
	if state == null:
		return {"destroyed": [], "detached": [], "mass_changed": false, "core_lost": false}
	var result := state.apply_damage(index, amount)
	if not bool(result["mass_changed"]):
		return result
	var dead := {}
	for index_dead in _all_dead(result):
		dead[int(index_dead)] = true
	# 这个零件的**所有**盒子都关掉：车体上的本体盒 + 受击盒 body 上的轮胎盒。
	# 延迟禁用：这一步是在物理帧里跑的，直接改状态可能撞上"查询中途"的报错
	for shape_index in _shape_part.size():
		if not dead.has(int(_shape_part[shape_index])):
			continue
		var shape: CollisionShape3D = shapes[shape_index]
		if shape != null and is_instance_valid(shape):
			shape.set_deferred("disabled", true)
	for shape_index in _hit_shape_part.size():
		if not dead.has(int(_hit_shape_part[shape_index])):
			continue
		var hit_shape: CollisionShape3D = _hit_shapes[shape_index]
		if hit_shape != null and is_instance_valid(hit_shape):
			hit_shape.set_deferred("disabled", true)
	_rebuild_visuals()
	if sync_mass:
		sync_body()
	return result


## 刚刚这一发造成的全部死亡零件（直接打掉的 + 因为断连被一起消灭的）。
static func _all_dead(result: Dictionary) -> Array:
	var out: Array = []
	for i in result.get("destroyed", []):
		out.append(int(i))
	for i in result.get("detached", []):
		out.append(int(i))
	return out


## 玩家车：把剩下的重量/重心同步给刚体（零件被打掉之后车会变轻、重心会偏）。
func sync_body() -> void:
	var rigid := body as RigidBody3D
	if rigid == null:
		return
	var total := state.total_mass()
	if total <= 0.0:
		return
	rigid.mass = total
	rigid.center_of_mass = state.center_of_mass() + _local_offset


## 重建某几组的分组网格（零件被打掉之后只塞活着的实例）。
func _rebuild_visuals() -> void:
	for key in _groups.keys():
		var group: Dictionary = _groups[key]
		var parts: Array = group["parts"]
		var transforms := []
		for i in parts:
			if not part_alive(int(i)):
				continue
			var def: PartDef = _library.get_def(str(state.parts[int(i)]["part_id"]))
			var place := BuildGrid.cell_transform(
				def, state.parts[int(i)]["cell"], state.parts[int(i)]["basis"]
			)
			place.origin += _local_offset
			transforms.append(place)
		var old: MultiMeshInstance3D = group["node"]
		if old != null and is_instance_valid(old):
			old.queue_free()
		if transforms.is_empty():
			group["node"] = null
			continue
		var node := PartLibrary.make_multimesh(transforms, group["build"])
		node.name = str(key).replace(":", "_")
		host.add_child(node)
		group["node"] = node
