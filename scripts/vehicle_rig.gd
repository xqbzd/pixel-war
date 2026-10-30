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
## 队伍（0 = 我方、1 = 敌方；-1 = 没分队伍）：只用于**友军伤害**判定，
## 碰撞层由生成方（TestField._spawn_vehicle）按队伍设。
var team := -1

var shapes := []                     # [CollisionShape3D]，下标 = 零件下标
## **只给射弹看**的受击盒（轮胎那类附属子模型的碰撞体）挂在 `hitboxes` 这个独立 body 上。
## 它在专用层 `HITBOX_LAYER` 上、掩码 0：**车/地形的掩码都不含这一层**，所以它不参与
## 任何物理碰撞（曾经把轮胎盒加到车体刚体上 → 车被地面卡死走不动，用户报的），
## 只有子弹 / 准星这类射线（掩码里带 `HITBOX_LAYER`）才打得到。
const HITBOX_LAYER := 4
## 打在整车包围盒上的命中点，离最近的活零件盒多远以内还归给它（格）
const HULL_HIT_SNAP := 1.5
var hitboxes: StaticBody3D

var _library: PartLibrary
var _local_offset := Vector3.ZERO    # 底盘本地原点相对载具坐标原点的偏移（玩家车 = -_spawn_center）
var _groups := {}                    # key -> {build, parts: Array[int], node: MultiMeshInstance3D}
var _part_group := []                # 零件下标 -> 分组 key
## shape 下标 -> 零件下标。**不是一一对应**：带轮体的零件（轮轴）会多一个"轮胎碰撞盒"，
## 那样子弹打在轮胎上也能算到这个零件头上（以前只有本体盒，子弹从轮胎之间穿过去）。
var _shape_part := []
var _hit_shape_part := []            # `hitboxes` 上的 shape 下标 -> 零件下标
## 受击盒按**空间分块**（每块 HIT_CHUNK 格一条棱）：零件被打掉只重建它所在的那一块，
## 而不是整台车。这是 Robocraft 客户端 `ChunkMeshUpdater` 的做法 —— 那边把整车的方块
## 按块合并成网格，破坏时只刷受影响的块，所以"掉一格重建整台车"的开销不存在。
## 分块之后单次重建的代价 ≈ 整车 / 块数。
const HIT_CHUNK := 4
var _hit_shapes := []                # `hitboxes` 上全部 CollisionShape3D（调试 / 测试 / shape_counts 用）
var _chunk_shapes := {}              # Vector3i(块坐标) -> CollisionShape3D
var _chunk_cells := {}               # Vector3i(块坐标) -> Array[Vector3i] 这块里所有格子
var _part_cells := []                # 零件下标 -> Array[Vector3i] 它占的格子（掉零件时标脏用）
var _dirty_hit_chunks := {}          # Vector3i -> true：下一物理帧要重建的块
var _tire_chunk := []                # 轮胎面所属块（和 `_tire_faces` 同下标）
## 轮胎在 `_hit_box` 里的下标 + 所属零件：射线判定用（轮子是圆的，用静止时的 AABB 够了）
var _tire_hit_boxes: Array[int] = []
var _tire_hit_part: Array[int] = []
var _hitbox_dirty := false           # 整张受击盒都要重建（进场 / 兜底）
## 活着零件的视觉中心（车体本地坐标）：损伤后瞄点/视野靠它重新定位
var _alive_centre_local := Vector3.ZERO
## 掉零件后要更新"活着零件的视觉中心"（很便宜，只是合并几个盒子）
var _hull_dirty := false
## 方块合并出来的碰撞盒（不是"一件一盒"的那些）
var _merged_shapes: Array[CollisionShape3D] = []
## 合并盒重建的脏标记 + 冷却（用户说"更新速度不用太快"）
var _merged_dirty := false
var _merged_cooldown := 0.0
var _hit_box := []                   # `hitboxes` 上每个盒子的 AABB（算真实包围盒用）
## 轮胎那种**格子外**的子模型盒：三角形 + 所属零件下标（受击盒几何的一部分）
var _tire_faces: Array = []
var _tire_part: Array = []
## 整数格 → 零件下标（命中点反查的快路径；零件都摆在整数格上）
var _cell_part := {}
var _part_centre := []               # 零件下标 -> 本地中心（算包围盒用）
var _part_box := []                  # 零件下标 -> 本体的本地 AABB
## 零件下标 -> 本体的**凸包半空间**（底盘本地坐标，已按摆放变换搬好）。
## 射界判定（`Turret.segment_blocker()`）用它按**真实形状**挡：半砖是三角柱、角块是四面体，
## 拿整格 AABB 去挡会让射界凭空小掉一大块（用户 2026-10-26 报的）。
var _part_planes := []
## 这一帧有零件死了、还没重建的视觉分组（key -> true）。
## 一发子弹可能同时打掉好几个零件、一帧里可能中好几发：合并成"每物理帧最多重建一次"，
## 免得开局交火时连续重建整台车（用户报的"开局交火卡、掉到二十多帧"）。
var _dirty_groups := {}


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
	_hit_box.clear()
	_tire_faces.clear()
	_tire_part.clear()
	_tire_chunk.clear()
	_tire_hit_boxes.clear()
	_tire_hit_part.clear()
	_hit_shapes.clear()
	_chunk_shapes.clear()
	_chunk_cells.clear()
	_part_cells.clear()
	_dirty_hit_chunks.clear()
	_hitbox_dirty = false
	_groups.clear()
	_part_group.clear()
	_part_centre.clear()
	_part_box.clear()
	_part_planes.clear()
	for i in vehicle.parts.size():
		var part: Dictionary = vehicle.parts[i]
		var def: PartDef = library.get_def(str(part["part_id"]))
		if def == null:
			continue
		# 摆放变换（host 本地空间：玩家车就是底盘本地空间）
		var place := BuildGrid.cell_transform(def, part["cell"], part["basis"])
		place.origin += _local_offset
		# 碰撞盒①：**本体**包围盒（轮胎是视觉件，靠整圈射线管车的支撑）。
		# ⚠️ 武器零件用 `collision_bounds()`：**不含会转的枪管** —— 拿"三件并起来"的盒子当碰撞盒时，
		# 枪管转走以后盒子里剩下的就是空气，子弹会打在看不见的盒子上
		# （用户报的"侧向射击撞到虚空、还判到另一个炮台上"）。
		var local := BuildGrid.rotate_aabb(part["basis"], def.collision_bounds())
		var box := AABB(place.origin + local.position, local.size)
		# ⚠️ 零件盒**不再挂物理车体**，全部挂到 `hitboxes`（静态、只给子弹射线看）。
		# 挂在刚体上时 293 个零件 × 10 台车 = 2930 个盒子，Jolt 每步都要和地形 trimesh
		# 做接触查询（实测物理 21 ms/步、9 FPS）；车体只留一个整车包围盒（见 `_add_chassis_hull`）。
		_add_hit_shape(box, i)
		_part_box.append(box)
		# 只有**非立方**零件才带凸包半空间：立方体的 AABB 本来就是精确形状，
		# 走 C++ 的 `intersects_segment` 比在 GDScript 里裁 6 个平面快得多。
		_part_planes.append(
			[] if def.shape == VoxShapes.SHAPE_CUBE
			else BuildGrid.transform_planes(
				VoxShapes.clip_planes(def.shape, def.collision_bounds()), place
			)
		)
		_part_centre.append(box.get_center())
		# 受击盒②：**轮体（轮胎）**—— 子弹必须打得到轮胎，但它**不能参与物理碰撞**
		# （不然轮子会跟地面打架、车开不动）。所以它挂到独立的 `hitboxes` body 上，
		# 那一层只有射弹射线会查。
		var sub := def.sub_model_volume()
		if sub != null:
			var sub_local := PartDef.tight_bounds(sub, def.sub_model_offset(), Vector3.ONE)
			var sub_rotated := BuildGrid.rotate_aabb(part["basis"], sub_local)
			_add_hit_shape(AABB(place.origin + sub_rotated.position, sub_rotated.size), i, true)
		var skip := static_skip_weapon and def.weapon == "turret"
		if skip:
			_part_group.append("")
			continue
		# 视觉也按**块**分组（和受击盒同一套块坐标）：掉一个零件只重建它所在那一块的那一组，
		# 而不是"所有同型号方块"那一大组（一台车里同型号方块可能几百个）。
		# 同样是 Robocraft `ChunkMeshUpdater` 的思路：破坏只影响局部。
		var cell: Vector3i = part["cell"]
		var chunk := chunk_of_cell(cell)
		var key := "%s:%d:%d_%d_%d" % [
			str(part["part_id"]), def.render_mode, chunk.x, chunk.y, chunk.z
		]
		if not _groups.has(key):
			_groups[key] = {
				"build": library.build_default(str(part["part_id"])),
				"parts": [],
				"node": null,
			}
		(_groups[key]["parts"] as Array).append(i)
		_part_group.append(key)
	_fill_cell_map()
	_add_chassis_hull()
	_rebuild_hitbox_trimesh()
	_rebuild_visuals()
	if sync_mass:
		sync_body()


## 被打中的时候把 shape 下标当零件下标用 —— 挪不了的保证见类注释。
func part_index_of_shape(shape_index: int) -> int:
	if shape_index < 0 or shape_index >= _shape_part.size():
		return -1
	return _shape_part[shape_index]


## 车体地形碰撞 = **特殊零件一件一盒 + 其余方块合并成少数几个大盒子**（用户 2026-10-19 的折中方案）。
## * 特殊零件 = `weapon != ""` **且** `weapon_swivel_collider`（支架会跟着转的大炮塔）：
##   它们有可动几何，必须一件一盒，否则转走以后盒子里剩下的是空气；
## * 其余**所有**固定零件（核心、轮轴、炮塔底座、普通方块、半砖、角块）都并进合并盒；
## * 半砖 / 角块目前**按整格算**（`roundi`），所以缺角会被补满 —— 这条对**地形碰撞**是
##   有意的简化，但对**射界**（`clip_boxes`）会显得"比实际更挡"，见 `_collect_clip_boxes()`；
## * 掉零件时重建（限流，见 `flush_visuals()`），不需要很快。
func _add_chassis_hull() -> void:
	for i in _part_box.size():
		var box: AABB = _part_box[i]
		if box.size.length() < 0.01:
			continue
		if _is_special_part(i):
			_add_shape(box, i)
	_rebuild_merged_hull()
	_update_alive_centre()


## 这个零件要不要单独一个碰撞盒。
## 只有**勾了 `weapon_swivel_collider` 的炮塔**才单独建盒（支架会跟着水平旋转的那种大炮塔，
## 以后做复杂炮塔时打开）；轮轴 / 核心 / 炮塔底座这些不动的部件全部并进合并盒
## （用户 2026-10-19 的要求：它们不会动，没必要各占一个 shape）。
func _is_special_part(index: int) -> bool:
	var def := _part_def(index)
	if def == null:
		return true
	return def.weapon != "" and def.weapon_swivel_collider


func _part_def(index: int) -> PartDef:
	if _library == null or state == null or index < 0 or index >= state.parts.size():
		return null
	return _library.get_def(str(state.parts[index]["part_id"]))


## 重建"方块合并盒"：把所有活着的**非特殊**零件按整数格贪心合并成矩形盒子。
## 半砖/角块按整格算（用户要求：地形碰撞不用精确到模型内部）。
func _rebuild_merged_hull() -> void:
	for shape in _merged_shapes:
		if is_instance_valid(shape):
			body.remove_child(shape)
			shape.queue_free()
	_merged_shapes.clear()
	var cells := {}
	for i in _part_box.size():
		if not part_alive(i) or _is_special_part(i):
			continue
		var box: AABB = _part_box[i]
		if box.size.length() < 0.01:
			continue
		var lo := Vector3i(roundi(box.position.x), roundi(box.position.y), roundi(box.position.z))
		var size := Vector3i(
			maxi(1, roundi(box.size.x)), maxi(1, roundi(box.size.y)), maxi(1, roundi(box.size.z))
		)
		for ix in size.x:
			for iy in size.y:
				for iz in size.z:
					cells[lo + Vector3i(ix, iy, iz)] = true
	for entry in _greedy_merge(cells):
		var origin: Vector3i = entry["origin"]
		var size: Vector3i = entry["size"]
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = Vector3(size)
		shape.shape = box_shape
		shape.position = Vector3(origin) + Vector3(size) * 0.5
		body.add_child(shape)
		_merged_shapes.append(shape)


## 整数格 → 矩形（贪心：先沿 X 拉长，再沿 Z 铺宽，最后沿 Y 叠高）。
static func _greedy_merge(cells: Dictionary) -> Array:
	var out := []
	var keys: Array = cells.keys()
	# 排序决定合并的起点：先按 Y、再按 Z、最后按 X（同一层的方块先合并成一片）
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		if a.z != b.z:
			return a.z < b.z
		return a.x < b.x
	)
	var used := {}
	for key in keys:
		var start: Vector3i = key
		if used.has(start):
			continue
		var sx := 1
		while cells.has(start + Vector3i(sx, 0, 0)) and not used.has(start + Vector3i(sx, 0, 0)):
			sx += 1
		var sz := 1
		while true:
			var ok := true
			for ix in sx:
				var cell := start + Vector3i(ix, 0, sz)
				if not cells.has(cell) or used.has(cell):
					ok = false
					break
			if not ok:
				break
			sz += 1
		var sy := 1
		while true:
			var ok := true
			for ix in sx:
				for iz in sz:
					var cell := start + Vector3i(ix, sy, iz)
					if not cells.has(cell) or used.has(cell):
						ok = false
						break
				if not ok:
					break
			if not ok:
				break
			sy += 1
		for ix in sx:
			for iy in sy:
				for iz in sz:
					used[start + Vector3i(ix, iy, iz)] = true
		out.append({"origin": start, "size": Vector3i(sx, sy, sz)})
	return out


## 活着零件包围盒的中心（瞄准 / 视野用，见 `alive_centre_local()`）。只在掉零件时算一次。
func _update_alive_centre() -> void:
	var hull := AABB()
	var has := false
	for i in _part_box.size():
		if not part_alive(i):
			continue
		hull = (_part_box[i] as AABB) if not has else hull.merge(_part_box[i] as AABB)
		has = true
	# 轮胎那种附属盒也算进来（残骸的包围盒要盖住轮子）
	for i in _hit_box.size():
		if not part_alive(int(_hit_shape_part[i])):
			continue
		hull = (_hit_box[i] as AABB) if not has else hull.merge(_hit_box[i] as AABB)
		has = true
	_alive_centre_local = hull.get_center() if has else Vector3.ZERO


func _add_shape(box: AABB, part_index: int) -> void:
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box.size
	shape.shape = box_shape
	shape.position = box.get_center()
	body.add_child(shape)
	shapes.append(shape)
	_shape_part.append(part_index)


## 受击盒：**每个零件一个本地 AABB**，最后合成**一张 trimesh** 挂在 `hitboxes` 上
## （不参与物理碰撞，只有子弹射线看得到）。
## 为什么不是"每个零件一个 BoxShape"：一个 body 上 293 个 shape 时，Jolt 每一步都要
## 把这些 shape 的包围盒在 broadphase 里更新一遍（10 台车 = 2930 个，实测掉 30% 帧率）。
func _add_hit_shape(box: AABB, part_index: int, is_tire := false) -> void:
	if hitboxes == null:
		hitboxes = StaticBody3D.new()
		hitboxes.name = "Hitboxes"
		hitboxes.collision_layer = HITBOX_LAYER
		hitboxes.collision_mask = 0
		body.add_child(hitboxes)
	_hit_box.append(box)
	_hit_shape_part.append(part_index)
	# 轮胎那种**不在整数格上**的子模型盒要单独记账：受击盒几何现在由"合并后的方块 +
	# 这些子模型盒"组成（本体盒不再逐件出面）。
	if is_tire:
		_tire_faces.append(box_faces(box))
		_tire_part.append(part_index)
		_tire_chunk.append(chunk_of_cell(Vector3i(
			roundi(box.get_center().x), roundi(box.get_center().y), roundi(box.get_center().z)
		)))
		# 射线判定用：轮胎盒在 `_hit_box` 里的下标（轮子是圆的，静止时的 AABB 够用）
		_tire_hit_boxes.append(_hit_box.size() - 1)
		_tire_hit_part.append(part_index)


## 受击盒的几何：**所有活着零件按整数格合并**后的方块 + 轮胎那种格子外的子模型盒。
##
## 为什么不再逐件出面：命中反查零件走的是"命中点落在哪个格子"（`part_index_at`），
## 根本不依赖 shape 下标、也不需要零件各自的面 —— 而逐件出面是 541 盒 × 12 = **6612 个三角形**，
## 这张凹面体还跟着车每帧移动（实测 10 台车时引擎物理里它占 ~7.5 ms）。
## 合并后约 40~60 个盒子 ≈ 590 个三角形，覆盖的体素体积完全一样。
func _rebuild_hitbox_trimesh() -> void:
	if hitboxes == null:
		return
	for chunk in _chunk_shapes.keys():
		var old: CollisionShape3D = _chunk_shapes[chunk]
		if old != null and is_instance_valid(old):
			hitboxes.remove_child(old)
			old.queue_free()
	_chunk_shapes.clear()
	_hit_shapes.clear()
	_dirty_hit_chunks.clear()
	_hitbox_dirty = false
	# 要重建的块 = 有零件的块 ∪ 有轮胎面的块
	var chunks := {}
	for chunk in _chunk_cells.keys():
		chunks[chunk] = true
	for chunk in _tire_chunk:
		chunks[chunk as Vector3i] = true
	for chunk in chunks.keys():
		_rebuild_hit_chunk(chunk)


## 重画**一块**受击盒：这一块里还活着的格子贪心合并成盒子 + 落在这块里的轮胎面。
## 块不存在 / 全打光了就把这张 shape 摘掉（空 trimesh 某些版本上会报错）。
func _rebuild_hit_chunk(chunk: Vector3i) -> void:
	if hitboxes == null:
		return
	var cells := {}
	for cell in ((_chunk_cells.get(chunk, []) as Array) as Array):
		var cell_v: Vector3i = cell
		var part := int(_cell_part.get(cell_v, -1))
		if part >= 0 and part_alive(part):
			cells[cell_v] = true
	var faces := PackedVector3Array()
	for entry in _greedy_merge(cells):
		var origin: Vector3i = entry["origin"]
		var size: Vector3i = entry["size"]
		faces.append_array(box_faces(AABB(Vector3(origin), Vector3(size))))
	for i in _tire_faces.size():
		if (_tire_chunk[i] as Vector3i) != chunk:
			continue
		if not part_alive(int(_tire_part[i])):
			continue
		faces.append_array(_tire_faces[i] as PackedVector3Array)
	var shape: CollisionShape3D = _chunk_shapes.get(chunk)
	if faces.is_empty():
		if shape != null and is_instance_valid(shape):
			hitboxes.remove_child(shape)
			shape.queue_free()
		_chunk_shapes.erase(chunk)
		_hit_shapes = _chunk_shapes.values()
		return
	var concave := ConcavePolygonShape3D.new()
	# 六个面用的是同一套顶点顺序（有半数是背面）：不开背面碰撞，射线会直接穿过去
	concave.backface_collision = true
	concave.set_faces(faces)
	if shape == null or not is_instance_valid(shape):
		shape = CollisionShape3D.new()
		shape.name = "HitShape_%d_%d_%d" % [chunk.x, chunk.y, chunk.z]
		hitboxes.add_child(shape)
		_chunk_shapes[chunk] = shape
	# 复用同一个 CollisionShape3D：只换里面的 shape 资源，不删节点
	shape.shape = concave
	_hit_shapes = _chunk_shapes.values()


## 整数格 → 它属于哪一块（负数向下取整，别用整数除法：负数会往 0 方向截断）
static func chunk_of_cell(cell: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(cell.x) / float(HIT_CHUNK)),
		floori(float(cell.y) / float(HIT_CHUNK)),
		floori(float(cell.z) / float(HIT_CHUNK))
	)


## 某个零件占的所有格子 → 把它们所在的块标脏（掉零件时用，O(零件的格子数)）
func _mark_part_chunks_dirty(part_index: int) -> void:
	if part_index < 0 or part_index >= _part_cells.size():
		return
	for cell in (_part_cells[part_index] as Array):
		_dirty_hit_chunks[chunk_of_cell(cell)] = true
	# 轮胎面可能在零件本体格子之外（轮子在格子外）：按轮胎自己的块单独标
	for i in _tire_part.size():
		if int(_tire_part[i]) == part_index:
			_dirty_hit_chunks[_tire_chunk[i] as Vector3i] = true


## 一个 AABB 的 12 个三角形（36 个顶点）。三角形必须**朝外绕**：六个面用同一套顶点顺序时
## 有一半是背面，而 `backface_collision` 在 Jolt 下靠不住 —— 从上往下打（比如准星瞄车顶）
## 射线会**直接穿过**受击盒打到车体包围盒，看着就是"瞄着车顶却打天上"（用户 2026-10-19 报的）。
## 这里按面的外法线检查，反了就翻过来。
static func box_faces(box: AABB) -> PackedVector3Array:
	var faces := PackedVector3Array()
	var lo := box.position
	var hi := box.end
	for axis in 3:
		for side in 2:
			var a := axis
			var b := (axis + 1) % 3
			var c := (axis + 2) % 3
			var plane := lo[a] if side == 0 else hi[a]
			var p0 := Vector3.ZERO
			var p1 := Vector3.ZERO
			var p2 := Vector3.ZERO
			var p3 := Vector3.ZERO
			p0[a] = plane
			p1[a] = plane
			p2[a] = plane
			p3[a] = plane
			p0[b] = lo[b]
			p0[c] = lo[c]
			p1[b] = hi[b]
			p1[c] = lo[c]
			p2[b] = hi[b]
			p2[c] = hi[c]
			p3[b] = lo[b]
			p3[c] = hi[c]
			var outward := Vector3.ZERO
			outward[a] = -1.0 if side == 0 else 1.0
			if (p1 - p0).cross(p2 - p0).dot(outward) < 0.0:
				faces.append_array([p0, p3, p2, p0, p2, p1])
			else:
				faces.append_array([p0, p1, p2, p0, p2, p3])
	return faces


## 世界坐标点 → 零件下标（供"伤害打包"在帧末反查用；内部走整数格表，O(1)）
func part_index_at(world_point: Vector3) -> int:
	if body == null or not is_instance_valid(body):
		return -1
	return _part_at_local(body.global_transform.affine_inverse() * world_point)


## 体素 DDA 射线：世界坐标 from→to，返回最近的**活零件**命中。
## 完全不依赖物理形状（没有 trimesh、没有 broadphase）：命中查询就是按整数格步进，
## 开销只跟"射线穿过多少格"有关 —— 这就是 Robocraft 客户端拿方块 BVH 查命中的等价物。
## 返回 {part, position, normal, distance}；没打中返回 {}。
func raycast_hit(from_world: Vector3, to_world: Vector3) -> Dictionary:
	if body == null or not is_instance_valid(body):
		return {}
	var inv := body.global_transform.affine_inverse()
	var from: Vector3 = inv * from_world
	var to: Vector3 = inv * to_world
	var delta := to - from
	var max_t := delta.length()
	if max_t < 0.0001:
		return {}
	var dir := delta / max_t
	var best_t := max_t
	var best_part := -1
	# ① 轮胎（格子外的子模型盒）：用**静止时的盒子**判定 —— 轮子是圆的，
	#    绕轴旋转不会改变它的外接盒，所以没必要跟着转。
	for i in _tire_hit_boxes.size():
		var tire_part := int(_tire_hit_part[i])
		if tire_part < 0 or not part_alive(tire_part):
			continue
		var tire_box: AABB = _hit_box[int(_tire_hit_boxes[i])]
		var tire_t := _ray_aabb(from, dir, tire_box)
		if tire_t >= 0.0 and tire_t < best_t:
			best_t = tire_t
			best_part = tire_part
	# ② 本体：按整数格步进（Amanatides-Woo），碰到活着的零件就停
	var cell := Vector3i(floori(from.x), floori(from.y), floori(from.z))
	var step := Vector3i(
		1 if dir.x > 0.0 else -1, 1 if dir.y > 0.0 else -1, 1 if dir.z > 0.0 else -1
	)
	var t_delta := Vector3(
		absf(1.0 / dir.x) if absf(dir.x) > 0.000001 else INF,
		absf(1.0 / dir.y) if absf(dir.y) > 0.000001 else INF,
		absf(1.0 / dir.z) if absf(dir.z) > 0.000001 else INF
	)
	var nx := _next_cell_t(from.x, dir.x, cell.x, step.x)
	var ny := _next_cell_t(from.y, dir.y, cell.y, step.y)
	var nz := _next_cell_t(from.z, dir.z, cell.z, step.z)
	var guard := 0
	while true:
		guard += 1
		if guard > 4096:
			break
		var part := int(_cell_part.get(cell, -1))
		if part >= 0 and part_alive(part):
			var box: AABB = (_part_box[part] as AABB).grow(0.02)
			var t := _ray_aabb(from, dir, box)
			if t >= 0.0 and t <= max_t:
				if t < best_t:
					best_t = t
					best_part = part
				# 从近到远步进：第一个真正命中的格子就是最近的命中，直接收工
				# （以前的写法会一路走到车尾，实测 264 µs/发，收工后降到 ~1/4）
				break
		if nx < ny:
			if nx < nz:
				if nx > max_t:
					break
				cell.x += step.x
				nx += t_delta.x
			else:
				if nz > max_t:
					break
				cell.z += step.z
				nz += t_delta.z
		else:
			if ny < nz:
				if ny > max_t:
					break
				cell.y += step.y
				ny += t_delta.y
			else:
				if nz > max_t:
					break
				cell.z += step.z
				nz += t_delta.z
	if best_part < 0:
		return {}
	var local_point := from + dir * best_t
	return {
		"part": best_part,
		"position": body.global_transform * local_point,
		"normal": body.global_transform.basis * _face_normal(dir),
		"distance": best_t,
	}


## 射线与 AABB 的入射 t（没打中返回 -1）。标准 slab 法。
static func _ray_aabb(from: Vector3, dir: Vector3, box: AABB) -> float:
	var tmin := -INF
	var tmax := INF
	for axis in 3:
		var d: float = dir[axis]
		var lo: float = box.position[axis]
		var hi: float = box.end[axis]
		if absf(d) < 0.000001:
			if from[axis] < lo or from[axis] > hi:
				return -1.0
			continue
		var t1 := (lo - from[axis]) / d
		var t2 := (hi - from[axis]) / d
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return -1.0
	if tmax < 0.0:
		return -1.0
	return maxf(tmin, 0.0)


## 起点到"下一条格线"的距离参数（DDA 用）
static func _next_cell_t(from_axis: float, dir_axis: float, cell: int, step: int) -> float:
	if absf(dir_axis) < 0.000001:
		return INF
	var boundary := float(cell + (1 if step > 0 else 0))
	return (boundary - from_axis) / dir_axis


## 命中法线：取射线主方向的反向（做火花朝向够用）
static func _face_normal(dir: Vector3) -> Vector3:
	var abs_dir := dir.abs()
	if abs_dir.x >= abs_dir.y and abs_dir.x >= abs_dir.z:
		return Vector3(-signf(dir.x), 0.0, 0.0)
	if abs_dir.y >= abs_dir.z:
		return Vector3(0.0, -signf(dir.y), 0.0)
	return Vector3(0.0, 0.0, -signf(dir.z))


## 打中的是**哪个零件**：子弹打的是 `hitboxes` 那张 trimesh，
## 靠"命中点落在哪个零件盒里"反查（命中很稀疏，几次/秒，O(零件数) 完全够用）。
func part_index_of_hit(_body_rid: RID, _shape_index: int, world_point := Vector3.ZERO) -> int:
	var local := body.global_transform.affine_inverse() * world_point
	return _part_at_local(local)


## 建"整数格 → 零件"表（命中点反查的快路径，见 `_part_at_local()`）。
func _fill_cell_map() -> void:
	_cell_part.clear()
	_chunk_cells.clear()
	_part_cells.clear()
	for i in _part_box.size():
		_part_cells.append([])
	for i in _part_box.size():
		var box: AABB = _part_box[i]
		if box.size.length() < 0.01:
			continue
		var lo := Vector3i(roundi(box.position.x), roundi(box.position.y), roundi(box.position.z))
		var size := Vector3i(
			maxi(1, roundi(box.size.x)), maxi(1, roundi(box.size.y)), maxi(1, roundi(box.size.z))
		)
		var part_cells: Array = _part_cells[i]
		for ix in size.x:
			for iy in size.y:
				for iz in size.z:
					var cell := lo + Vector3i(ix, iy, iz)
					_cell_part[cell] = i
					part_cells.append(cell)
					var chunk := chunk_of_cell(cell)
					if not _chunk_cells.has(chunk):
						_chunk_cells[chunk] = []
					(_chunk_cells[chunk] as Array).append(cell)


## 本地坐标点 → 零件下标（点在某个盒子里；没落进任何盒子时取最近的活零件）。
func _part_at_local(point: Vector3) -> int:
	# ① 快路径：零件都摆在整数格上，先用"格子 → 零件"表做 O(1) 反查
	#    （8 个相邻格子兜住"点正好压在格子边界上"的情况）。高射速武器一秒几百发，
	#    每发扫一遍 300 个盒子的线性查找就是集中交火时的开销之一。
	var base := Vector3i(floori(point.x), floori(point.y), floori(point.z))
	var candidates := {}
	for dx in 2:
		for dy in 2:
			for dz in 2:
				var cell := base + Vector3i(dx, dy, dz)
				if _cell_part.has(cell):
					candidates[int(_cell_part[cell])] = true
	# 候选里取"盒中心最近"的那个（和慢路径同一套选择规则：薄板/重叠盒才不会反查到隔壁零件）
	var fast_part := -1
	var fast_distance := INF
	for candidate in candidates.keys():
		var part_index := int(candidate)
		if not part_alive(part_index):
			continue
		var candidate_box: AABB = (_part_box[part_index] as AABB).grow(0.02)
		if not candidate_box.has_point(point):
			continue
		var centre_distance := candidate_box.get_center().distance_squared_to(point)
		if centre_distance < fast_distance:
			fast_distance = centre_distance
			fast_part = part_index
	if fast_part >= 0:
		return fast_part
	# ② 慢路径（兜底）：穿模 / 擦边 / 盒子跨界时线性扫（和原来一样）
	var best := -1
	var best_distance := INF
	for i in _hit_box.size():
		var part := int(_hit_shape_part[i])
		if not part_alive(part):
			continue
		var box: AABB = (_hit_box[i] as AABB).grow(0.02)
		if box.has_point(point):
			# 多个盒子重叠时取中心最近的（薄板零件的盒子会互相压住）
			var centre := box.get_center()
			var distance := centre.distance_squared_to(point)
			if distance < best_distance:
				best_distance = distance
				best = part
	if best >= 0:
		return best
	# 命中点是打在**整车包围盒**表面上的：包围盒比零件大，命中点可能落在零件之间的小空隙里。
	# 差 `HULL_HIT_SNAP` 格以内就归给最近的那个活零件 —— 否则"打剩一个核心"时，
	# 命中点离核心盒子差一点点就判 -1（打中不掉血，2026-10-19 用户报的）。
	var nearest := -1
	best_distance = INF
	for i in _hit_box.size():
		var part := int(_hit_shape_part[i])
		if not part_alive(part):
			continue
		var box: AABB = _hit_box[i]
		var closest := point.clamp(box.position, box.end)
		var distance := closest.distance_squared_to(point)
		if distance < best_distance:
			best_distance = distance
			nearest = part
	if nearest >= 0 and best_distance <= HULL_HIT_SNAP * HULL_HIT_SNAP:
		return nearest
	return -1


## 车体上的 shape 数 / 受击盒上的 shape 数（调试 / 测试用）
func shape_counts() -> Vector2i:
	return Vector2i(shapes.size(), _hit_shapes.size())


func part_alive(index: int) -> bool:
	return state != null and state.part_alive(index)


## 活着零件的**视觉中心**（车体本地坐标，含轮胎）：打残之后瞄点/视野要跟着残骸走。
func alive_centre_local() -> Vector3:
	return _alive_centre_local


## 同上，世界坐标。
func alive_centre_world() -> Vector3:
	if body == null or not is_instance_valid(body):
		return Vector3.ZERO
	return body.global_transform * _alive_centre_local


## 单个零件的本体盒（车体本地坐标）。越界返回空盒。射界"按需重算"要用死零件的盒子。
func part_box(index: int) -> AABB:
	if index < 0 or index >= _part_box.size():
		return AABB()
	return _part_box[index]


## 每个零件的**本体盒**（本地 AABB，下标 = 零件下标；死了的给空盒）：
## 射界判定（`Turret.rebuild_arc()`）用它 —— 以前是读车体上的 shape，现在车体只有一个
## 整车包围盒，所以改成读这里（2026-10-19 的性能优化之后必须走这里）。
func part_boxes() -> Array:
	var out := []
	for i in _part_box.size():
		out.append((_part_box[i] as AABB) if part_alive(i) else AABB())
	return out


## 每个零件的**凸包半空间**（底盘本地，下标 = 零件下标；死了的给空数组）。
## 射界判定用它按真实形状挡（半砖的斜面、角块的切口），比 AABB 准。
func part_planes() -> Array:
	var out := []
	for i in _part_planes.size():
		out.append((_part_planes[i] as Array) if part_alive(i) else [])
	return out


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
		if not part_alive(int(_hit_shape_part[i])):
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
	if bool(result["mass_changed"]):
		_after_damage(result)
	return result


## 一帧里打中多个零件的合并结算（`{零件下标: 净伤害}`）：规则和逐个 `apply_damage()` 一样，
## 但连通性判定、禁用 shape、质量/重心同步、视觉脏标记这些"整车级"善后**只做一次**。
## 调用方：`TestField._flush_damage_batches()`（它本来就按 车 + 零件 攒了这一帧的伤害）。
func apply_damage_batch(amounts: Dictionary) -> Dictionary:
	if state == null:
		return {"destroyed": [], "detached": [], "mass_changed": false, "core_lost": false}
	var result := state.apply_damage_batch(amounts)
	if bool(result["mass_changed"]):
		_after_damage(result)
	return result


## 一次毁伤结算之后的**整车级善后**（单发和批量共用，别写成两份）。
## 注意：这里跑在物理帧里，改物理状态一律用 `set_deferred`。
func _after_damage(result: Dictionary) -> void:
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
	# 受击盒按块重建：只把"死掉零件所在的块"标脏，下一物理帧重画那几块（不是整车）
	_hull_dirty = true
	for index_dead in dead.keys():
		_mark_part_chunks_dirty(int(index_dead))
	_merged_dirty = true
	# ⚠️ 不在这里重建视觉：只记下受影响的组，等这一物理帧结束由 `flush_visuals()`
	# 合并做一次（同一帧连吃几发也不会重复重建整台车）。
	for index_dead in dead.keys():
		var key := str(_part_group[int(index_dead)])
		if not key.is_empty():
			_dirty_groups[key] = true
	# 重量 / 重心立刻同步（一次 0.007 ms，可以忽略）—— 物理这一帧就要用新质量；
	# 只有**视觉重建**值得合并，见 `flush_visuals()`。
	if sync_mass:
		sync_body()


## 每物理帧调一次（子弹结算之后）：把这一帧的毁伤合并成**一次**视觉重建。
## 一发子弹可能打掉好几个零件，开局交火时一帧能中好几发 —— 不合并就会反复重建整台车。
## 这一帧有没有"重活"要做（受击盒 trimesh 重建 / 方块合并盒重建）。
## `TestField` 用它把全场每帧的重活数量限住：10 台车同一帧各掉一个零件时，
## 旧写法会在同一帧叠 10 份（每份 ~5 ms + ~3 ms），实测「善后/射界」能到 26 ms。
func needs_heavy_rebuild() -> bool:
	return _hitbox_dirty or not _dirty_hit_chunks.is_empty() \
		or (_merged_dirty and _merged_cooldown <= 0.0)


## `allow_heavy = false` 时只做便宜的活（视觉分组），受击盒 / 合并盒留到后面几帧再做。
## 留着的期间受击盒几何是"旧的"：已经打掉的零件靠 `hit_filter`（`_hit_is_real`）被当成没打中，
## 所以最多是几帧的残影，不会掉血错误、也不会"打不中"。
func flush_visuals(allow_heavy := true) -> void:
	# ⚠️ 不能"没有脏组就直接返回"：受击盒的重建**不在** `_dirty_groups` 里（见下面），
	# 否则零件全打光之后 trimesh 永远不更新 —— 子弹打在"已经不存在的零件"上，
	# 命中却查不到任何零件 → 打中不掉血（2026-10-19 用户报的"只剩核心时打不死"）。
	if not _dirty_groups.is_empty():
		var keys := _dirty_groups.keys()
		_dirty_groups.clear()
		for key in keys:
			_rebuild_group(str(key))
	if _hull_dirty:
		# 瞄准用的"活着零件中心"跟着剩余零件走（很便宜：只是合并几个盒子）
		_hull_dirty = false
		_update_alive_centre()
	if allow_heavy and (_hitbox_dirty or not _dirty_hit_chunks.is_empty()):
		if _hitbox_dirty:
			# 全量重建（进场 / 兜底）：内部会清空脏块表
			_rebuild_hitbox_trimesh()
		else:
			# 只重画这一帧有零件死掉的那几块 —— 从 Robocraft 的 ChunkMeshUpdater 搬来的：
			# 破坏只影响局部，块外的几何保持不动。
			var chunks := _dirty_hit_chunks.keys()
			_dirty_hit_chunks.clear()
			for chunk in chunks:
				_rebuild_hit_chunk(chunk)
	if _merged_dirty:
		# 方块合并盒重建：限流到 0.2 秒一次（用户说更新速度不用太快，掉零件时不必每帧重建）
		_merged_cooldown = maxf(0.0, _merged_cooldown - 0.0083)
		if _merged_cooldown <= 0.0 and allow_heavy:
			_merged_dirty = false
			_merged_cooldown = 0.2
			_rebuild_merged_hull()


## 刚刚这一发造成的全部死亡零件（直接打掉的 + 因为断连被一起消灭的）。
static func _all_dead(result: Dictionary) -> Array:
	var out: Array = []
	for i in result.get("destroyed", []):
		out.append(int(i))
	for i in result.get("detached", []):
		out.append(int(i))
	return out


## 玩家车：把剩下的重量/重心同步给刚体（零件被打掉之后车会变轻、重心会偏）。
## ⚠️ 一次遍历同时拿质量和重心：原来是 `total_mass()` + `center_of_mass()` 各调一次，
## 每个都 `alive_parts()` 分配一个 541 元素的数组再扫一遍 —— 实测 2.9 ms/次，
## 而掉零件那一帧本来就很贵。现在 ~0.3 ms。
func sync_body() -> void:
	var rigid := body as RigidBody3D
	if rigid == null:
		return
	var both := state.mass_and_com()
	var total := float(both[0])
	if total <= 0.0:
		return
	rigid.mass = total
	rigid.center_of_mass = (both[1] as Vector3) + _local_offset


## 重建全部分组（进场时用一次）。
func _rebuild_visuals() -> void:
	for key in _groups.keys():
		_rebuild_group(str(key))


## 重建**一组**：零件被打掉之后只把活着的实例塞回去。
## 优先**就地改**已有的 MultiMesh（不新建节点 / 不新建 GPU 缓冲），实在没有才新建。
func _rebuild_group(key: String) -> void:
	if not _groups.has(key):
		return
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
	var multi: MultiMesh = null
	if old != null and is_instance_valid(old):
		multi = old.multimesh
	if transforms.is_empty():
		if multi != null:
			# 整组都没了：只把可见数量清零，**别缩 instance_count**（那会重新分配缓冲）
			multi.visible_instance_count = 0
		return
	# 这些分组的实例数组会在零件被打掉时**整体重排**（活着的零件往前塞）。
	# 关掉 MultiMesh 的物理插值：否则重排那一帧渲染器会把新实例和上一帧同下标的实例
	# 插值一遍 —— 表现就是**车身突然少了/歪了几个零件，一帧后又正常**（用户报的闪烁）。
	# 车体的移动靠父节点（刚体）的插值，实例本身不需要插值。
	if multi != null:
		RenderingServer.multimesh_set_physics_interpolated(multi.get_rid(), false)
	if multi != null and multi.mesh != null:
		# 就地更新：网格（部件外观）没变，只是实例变少了。
		# ⚠️ **不缩** `instance_count`：改它要重新分配 GPU 缓冲，交火时零件一直掉、
		# 每掉一次就 stall 一下（开局卡顿的元凶之一）。只改 `visible_instance_count`（不重分配）。
		if transforms.size() > multi.instance_count:
			multi.instance_count = transforms.size()
		for i in transforms.size():
			multi.set_instance_transform(i, transforms[i])
		if multi.instance_count > transforms.size():
			multi.visible_instance_count = transforms.size()
		return
	if old != null and is_instance_valid(old):
		old.queue_free()
	var node := PartLibrary.make_multimesh(transforms, group["build"])
	node.name = str(key).replace(":", "_")
	if node.multimesh != null:
		RenderingServer.multimesh_set_physics_interpolated(node.multimesh.get_rid(), false)
	host.add_child(node)
	group["node"] = node
