@tool
class_name VehicleState
extends RefCounted

## 一台载具的**毁伤状态**：每个零件一份血量 + 一张连接图，负责按规则结算伤害。
##
## 规则（用户定的，2026-10-12）：
##   * 伤害 **<** 这个零件剩下的血量 → 扣血，零件还在；
##   * 伤害 **≥** 剩下血量 → 这个零件被消灭，**溢出伤害沿它的连接点均分**给相邻零件，
##     一个一个继续结算（会连锁，链上每一环都按上面两条走）；
##   * 一次结算里只要有零件被消灭，就**重算重量/重心**，并按连接图重新判定连通性 ——
##     **和核心断开的那部分零件立刻一起被消灭**（这种"连不上"的消灭不再往外传溢出伤害）。
##   核心自己被打掉 = 整机全灭（和核心的部件说明一致：核心被摧毁 => 整机判定被摧毁）。
##
## 连接图来自 `BuildGrid.link_pairs()`（和"能不能进测试场"用的是同一张图：
## 按**零件身份**记的邻接 `_neighbours`，不是那本"格子 + 方向"的账本）。
## 这个类是**纯逻辑**，不碰场景：测试直接造一个 VehicleState 打 `apply_damage()`。

var parts := []                     # 直接引用 VehicleDef.parts（[{part_id, cell, basis}]）
var hp := PackedFloat32Array()      # 每个零件**剩下**的血量
var max_hp := PackedFloat32Array()  # 满血（HUD / 血条用）
var alive := []                     # Array[bool]
var destroyed_order := []           # 被消灭的顺序（HUD / 调试用）
var core_index := -1

var _defs := {}                     # part_id -> PartDef
var _neighbours := []               # [[j, k, ...], ...] 每个零件的相邻零件下标
var _pairs := []                    # [[i, j], ...] 原始连接对（连通性重算用）
## 每个零件的**质量**和"质量 × 重心"（在 `setup()` 里算一次）。
## 零件的质量和几何在毁伤过程中不会变，只有"活着/死了"会变 —— 所以这两张表是常量，
## `mass_and_com()` 每帧只需要对活着的零件做**累加**，不用再逐件算 `rotate_aabb`/`cell_transform`
## （541 件的车实测：每次 2.9 ms → 约 0.05 ms）。
var _part_mass := PackedFloat32Array()
var _part_moment := PackedVector3Array()


## 建图 + 初始化血量。`defs` = part_id -> PartDef（PartLibrary.defs）。
func setup(vehicle: VehicleDef, defs: Dictionary) -> void:
	parts = vehicle.parts
	_defs = defs
	hp.resize(parts.size())
	max_hp.resize(parts.size())
	alive.clear()
	destroyed_order.clear()
	core_index = -1
	for i in parts.size():
		var def: PartDef = defs.get(str(parts[i]["part_id"]))
		var full := float(def.hp) if def != null else 1000.0
		max_hp[i] = full
		hp[i] = full
		alive.append(true)
		if def != null and def.is_core:
			core_index = i
	_build_graph(vehicle)
	_build_part_tables()


## 连接图：先从建造账本拿连接对（和进测试场的前置检查同一本账），
## 账本里没有的（比如测试里手搓的零件表）就退回几何判定 —— 用 BuildGrid 自己摆一遍。
func _build_graph(vehicle: VehicleDef) -> void:
	var grid := BuildGrid.new()
	grid.set_defs(_defs)
	for part in vehicle.parts:
		grid.place(_defs[str(part["part_id"])], part["cell"], part["basis"])
	_pairs = grid.link_pairs()
	_neighbours.clear()
	for _i in parts.size():
		_neighbours.append([])
	for pair: Array in _pairs:
		(_neighbours[pair[0]] as Array).append(pair[1])
		(_neighbours[pair[1]] as Array).append(pair[0])


func part_count() -> int:
	return parts.size()


func part_alive(index: int) -> bool:
	return index >= 0 and index < alive.size() and bool(alive[index])


func alive_count() -> int:
	var count := 0
	for flag in alive:
		if flag:
			count += 1
	return count


## 这个零件当前连到谁（相邻下标）。测试和调试用。
func neighbours_of(index: int) -> Array:
	if index < 0 or index >= _neighbours.size():
		return []
	return _neighbours[index]


func remaining_hp(index: int) -> float:
	if index < 0 or index >= hp.size():
		return 0.0
	return hp[index]


## 整车剩余生命值（所有活着的零件按**各自剩余血量**相加）。
## 头顶血条 / 小地图就是用它：被打掉一个零件，整条立刻短一截。
func remaining_hp_total() -> float:
	var total := 0.0
	for value in hp:
		total += value
	return total


## 满血时所有零件的生命值总和（血条的分母）。
func max_hp_total() -> float:
	var total := 0.0
	for value in max_hp:
		total += value
	return total


## 血量比例 0~1（满血 = 1；核心被打掉 = 0）。头顶血条用它。
func health_fraction() -> float:
	var total := max_hp_total()
	if total <= 0.0:
		return 0.0
	return clampf(remaining_hp_total() / total, 0.0, 1.0)


## 整机剩余重量（只算活着的零件）：和 `VehicleDef.total_mass()` 同一套口径。
func total_mass() -> float:
	return VehicleDef.weighted_mass(alive_parts(), _defs)


## 剩余零件的重心（载具坐标系，单位 = cube）：口径和 `VehicleDef.center_of_mass()` 一致
## （本体包围盒中心按重量加权），只是**跳过已经被打掉的零件**。
func center_of_mass() -> Vector3:
	return VehicleDef.weighted_center_of_mass(alive_parts(), _defs)


## 预计算"每零件的质量 / 质量×重心"（见 `_part_mass` 的说明）。
## 口径必须和 `VehicleDef.weighted_mass()` + `weighted_center_of_mass()` 一致。
func _build_part_tables() -> void:
	var count := parts.size()
	_part_mass.resize(count)
	_part_moment.resize(count)
	for i in count:
		var part: Dictionary = parts[i]
		var def: PartDef = _defs.get(str(part.get("part_id", "")))
		_part_mass[i] = 0.0
		_part_moment[i] = Vector3.ZERO
		if def == null:
			continue
		var weight := def.weight_kg
		_part_mass[i] = weight
		if weight <= 0.0:
			continue
		var local := BuildGrid.rotate_aabb(part["basis"], def.body_bounds())
		var centre := BuildGrid.cell_transform(def, part["cell"], part["basis"]).origin
		centre += local.get_center()
		_part_moment[i] = centre * weight


## 还活着的零件（[{part_id, cell, basis}]）—— 重心/质量都按它算
func alive_parts() -> Array:
	var out := []
	for i in parts.size():
		if alive[i]:
			out.append(parts[i])
	return out


## **一次遍历**同时算整机质量和重心，口径和 `total_mass()` + `center_of_mass()` 完全一致
## （质量 = 各零件 `weight_kg` 之和；重心 = 有重量的零件按重量加权）。
##
## 零件的质量和几何是常量（见 `_part_mass`），所以这里只是对活着的零件累加 —— 零分配、一遍出结果。
## 返回 `[质量: float, 重心: Vector3]`。
func mass_and_com() -> Array:
	if _part_mass.size() != parts.size():
		_build_part_tables()   # 兜底：没走 `setup()` 的构造方式（部分测试会这样）
	var mass := 0.0
	var moment := Vector3.ZERO
	for i in parts.size():
		if not alive[i]:
			continue
		mass += _part_mass[i]
		moment += _part_moment[i]
	var com := Vector3.ZERO if mass <= 0.0 else moment / mass
	return [mass, com]


## 打一发伤害（已经减过护甲之类的东西了，这里是净伤害）。
## 返回 {destroyed: Array[int], detached: Array[int], mass_changed: bool, core_lost: bool}
func apply_damage(index: int, amount: float) -> Dictionary:
	var destroyed := []
	if not part_alive(index) or amount <= 0.0:
		return _result(destroyed, [])
	_damage(index, amount, destroyed)
	if destroyed.is_empty():
		return _result(destroyed, [])
	# 有零件被消灭 → 重新判定连通性：和核心断开的立刻一起消灭
	var detached := detached_parts()
	for i in detached:
		_destroy(i)   # 不再往外传溢出伤害（它们不是被"打"掉的，是结构垮了）
	return _result(destroyed, detached)


## **一帧里打中多个零件**的合并结算（`{零件下标: 净伤害}`）：
## 逐个走同一套溢出伤害规则，但**连通性只判定一次**。
##
## 为什么：`apply_damage()` 每打死一个零件就要跑一遍 `detached_parts()`（541 件的车
## 实测 2.25 ms）。集中交火时一帧掉 3 个零件，就是白白多跑 2 遍 —— 而"这一帧结束时谁和核心
## 断开"本来就该按帧末的整体状态算，逐发算反而更啰嗦。
## 溢出伤害的传递规则和单发完全一致（`_damage()` 一个字节没改）。
func apply_damage_batch(amounts: Dictionary) -> Dictionary:
	var destroyed := []
	for key in amounts.keys():
		var index := int(key)
		var amount := float(amounts[key])
		if not part_alive(index) or amount <= 0.0:
			continue
		_damage(index, amount, destroyed)
	if destroyed.is_empty():
		return _result(destroyed, [])
	var detached := detached_parts()
	for i in detached:
		_destroy(i)
	return _result(destroyed, detached)


## 溢出伤害递归：均分给**还活着的**相邻零件（已经没了的那些分不到，份额就消耗掉）。
## 每个零件在 `_damage` 里先被置为"死"再往下递归，所以不会绕回来重复扣。
func _damage(index: int, amount: float, destroyed: Array) -> void:
	if not part_alive(index) or amount <= 0.0:
		return
	if amount < hp[index]:
		hp[index] -= amount
		return
	var overflow := amount - hp[index]
	_destroy(index)
	destroyed.append(index)
	var targets := []
	for other in _neighbours[index]:
		if part_alive(int(other)):
			targets.append(int(other))
	if targets.is_empty():
		return   # 没有邻居接得住，剩下的溢出就浪费掉
	var share := overflow / float(targets.size())
	for target in targets:
		_damage(int(target), share, destroyed)


func _destroy(index: int) -> void:
	if not part_alive(index):
		return
	hp[index] = 0.0
	alive[index] = false
	destroyed_order.append(index)


## 和核心断开（或核心自己没了）的**活零件**下标。并查集，和 `robot_status()` 同一套判法。
func detached_parts() -> Array:
	var indices := []
	for i in parts.size():
		if part_alive(i):
			indices.append(i)
	if indices.is_empty():
		return []
	var parent := {}
	for i in indices:
		parent[i] = i
	for pair: Array in _pairs:
		if not part_alive(pair[0]) or not part_alive(pair[1]):
			continue
		_union(parent, int(pair[0]), int(pair[1]))
	if not part_alive(core_index):
		# 核心没了 = 整机全灭（核心的部件说明就是这么定的）
		return indices
	var root := _find(parent, core_index)
	var out := []
	for i in indices:
		if _find(parent, i) != root:
			out.append(i)
	return out


func _result(destroyed: Array, detached: Array) -> Dictionary:
	var core_lost := core_index >= 0 and not part_alive(core_index)
	return {
		"destroyed": destroyed,
		"detached": detached,
		"mass_changed": not destroyed.is_empty() or not detached.is_empty(),
		"core_lost": core_lost,
	}


static func _find(parent: Dictionary, i: int) -> int:
	var root := i
	while int(parent[root]) != root:
		root = int(parent[root])
	while int(parent[i]) != root:
		var next := int(parent[i])
		parent[i] = root
		i = next
	return root


static func _union(parent: Dictionary, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[rb] = ra
