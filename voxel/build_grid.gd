@tool
class_name BuildGrid
extends RefCounted

## 建造网格：纯逻辑，不碰渲染，方便单测。
##
##   - cube 级占位表（cell -> 零件数组）：**多零件可以共享一个格子**，
##     但一个格子只能放一个零件的**基准格**（origin），且谁都不许和别人真的穿模
##     （体素级 mesh_clash）。零件的基准格就是它的放置锚点。
##   - “小面”连接账本：每个 (cell, 朝向) 是一个小面，一个小面最多一对连接
##     —— 从数据层堵死“多对一”
##   - 射线步进（DDA）找目标面、算出候选放置
##
## 坐标：cell 为整数 cube 坐标，y 向上、+x 为车头方向（与 data/vehicles 的约定一致）。
## 地面在 y = 0，地面命中用“虚拟格子 (x, -1, z) + 朝上”表示，
## 这样“新格子 = 命中格子 + 命中面朝向”这条统一规则对地面也成立。

const AREA_MIN := Vector3i(-32, 0, -32)
const AREA_MAX := Vector3i(32, 64, 32)  # 半开区间：[min, max)
const FLOOR_EXTENT := 32.0  # 地板 ±32（64 x 64）
const PP_LIMIT := 2000  # 一台机器人的部件点数上限

## entry 字段：part_id / basis / origin（基准格）/ min + size（足迹盒）/ transform
## 同一个零件占的每个格子都挂着**同一个 entry 对象**；parts 是每个零件一份。
var cells := {}  # cell: Vector3i -> Array（该格里的 entry，可能多个）
var parts := []  # Array（每个零件一个 entry，按放置顺序）
var links := {}  # face_id: String -> face_id: String（双向记录）
## face_id -> 拥有这个小面的零件 entry。只有"已经成对"的小面才有 —— 用来把连接账本
## 还原成零件连通图（进测试场前要检查"所有零件都和核心连着"），查表就是 O(1)。
var link_parts := {}
## **按零件身份**记的邻接表：entry 的 `id` -> Array（邻居 id）。
## ⚠️ 连通性（`robot_status()`）和毁伤（`scripts/vehicle_state.gd`）都读**这一份**，
## 不读上面那本按"格子 + 方向"做 key 的账本 —— 那本账一个 key 只能记一对连接：
##   * 同一格里挤着两个零件时，第二个零件朝同一方向的面对着同一个 key，那条连接永远记不上；
##   * `_remove_entry()` 以前会顺手清掉"对面"的条目，而那可能是**别的零件**在用的。
## 症状就是用户报的假警报：**建造模式说"有零件没连上"，存盘进测试场却没事**。
## 这一份是**增量**维护的（落子/拆除时各 O(连接数)），所以判定是 O(零件数)，不是每次重扫几何。
var _neighbours := {}
var _next_entry_id := 1
var _defs_cache := {}  # part_id -> PartDef（由 build_mode 注入，用于查连接面）
var _volumes := {}  # part_id -> VoxVolume（体素级命中要用）
var _solids := {}  # part_id -> Array（零件在本地空间里的所有实体块：本体 + 附属子模型）
var _full_cube := {}  # part_id -> bool（满方块走快路径）
var _mirror_fold := {}  # part_id -> {ok, basis}（对折旋转；见 mirror_fold_rotation）
var _body_anchor := {}  # part_id -> Vector3（本地坐标里的锚点格心；见 anchor_cell_from）
var _totals := {}  # {pp, weight, hp} 缓存（场地一变就重算）
var _totals_dirty := true


func clear() -> void:
	cells.clear()
	parts.clear()
	links.clear()
	link_parts.clear()
	_neighbours.clear()
	_next_entry_id = 1
	_totals_dirty = true


func part_count() -> int:
	return parts.size()


## 全场零件的数值合计（pp / 重量 / 血量）。带缓存，场地变了才重算 —— HUD 每帧问它也是 O(1)。
func totals() -> Dictionary:
	if not _totals_dirty:
		return _totals
	var sum := {"pp": 0, "weight": 0.0, "hp": 0}
	for entry: Dictionary in parts:
		var def: PartDef = _defs_cache.get(entry["part_id"])
		if def == null:
			continue
		sum["pp"] = int(sum["pp"]) + def.pp
		sum["weight"] = float(sum["weight"]) + def.weight_kg
		sum["hp"] = int(sum["hp"]) + def.hp
	_totals = sum
	_totals_dirty = false
	return _totals


## extra 里那些"还没真正落子"的假 entry 占的部件点数（镜像建造的预览要用：
## 先算本体、再算镜像体时，本体那一件点数得算进镜像体的预算里）。
func _extra_pp(extra: Array) -> int:
	var sum := 0
	for entry: Dictionary in extra:
		var other: PartDef = _defs_cache.get(str(entry.get("part_id", "")))
		if other != null:
			sum += other.pp
	return sum


## 这台机器人装了核心没有（一台最多一个，`can_place()` 会把第二个挡掉）。
func has_core() -> bool:
	for entry: Dictionary in parts:
		var def: PartDef = _defs_cache.get(entry["part_id"])
		if def != null and def.is_core:
			return true
	return false


## 某个格子里挂着的 entry（可能多个；没有就返回空数组）。
func entries_at(cell: Vector3i) -> Array:
	var list: Variant = cells.get(cell)
	return list if list is Array else []


## 基准格压在这一格上的零件（调试 / 测试用；镜像拆除也用它找人）。
## part_id 非空时只要这个部件的（成对的那两个必然是同一个部件）。
func entry_by_anchor(cell: Vector3i, part_id := "") -> Dictionary:
	for entry: Dictionary in parts:
		if (entry.get("anchor", entry["origin"]) as Vector3i) != cell:
			continue
		if not part_id.is_empty() and entry["part_id"] != part_id:
			continue
		return entry
	return {}


## 这一格是不是某个零件的**基准格**（一个格子只允许放一个基准格）。
func _has_basis_at(cell: Vector3i) -> bool:
	return not entry_by_anchor(cell).is_empty()


## 这一格的基准格是谁的（报错提示用；没人就返回 "-"）。
func _basis_owner(cell: Vector3i) -> String:
	var entry := entry_by_anchor(cell)
	return str(entry["part_id"]) if not entry.is_empty() else "-"


## 足迹盒（min + size）里的所有格子。
static func _box_cells(mn: Vector3i, size: Vector3i) -> Array:
	var out := []
	for y in range(size.y):
		for z in range(size.z):
			for x in range(size.x):
				out.append(mn + Vector3i(x, y, z))
	return out


## 整辆载具平移（所有部件一起挪），返回 {ok, reason, moved}。
## 先整体校验再整体搬：任何一个部件会超出场地就直接拒绝，不留下半搬状态。
func translate_all(delta: Vector3i) -> Dictionary:
	if parts.is_empty() or delta == Vector3i.ZERO:
		return {"ok": true, "moved": 0}
	for entry: Dictionary in parts:
		var def: PartDef = _defs_cache.get(entry["part_id"])
		if def == null:
			continue
		if not inside_area(def, entry["basis"], entry["origin"] + delta):
			return {"ok": false, "reason": "整体移动会超出建造场地"}
	var moved := {}
	var shifted_parts := []
	for entry: Dictionary in parts:
		var t: Transform3D = entry["transform"]
		var b: AABB = entry["bounds"]
		var copy := {
			"id": entry["id"],
			"part_id": entry["part_id"],
			"basis": entry["basis"],
			"min": (entry["min"] as Vector3i) + delta,
			"size": entry["size"],
			"origin": (entry["origin"] as Vector3i) + delta,
			"anchor": (entry.get("anchor", entry["origin"]) as Vector3i) + delta,
			"transform": Transform3D(t.basis, t.origin + Vector3(delta)),
			"bounds": AABB(b.position + Vector3(delta), b.size),
		}
		shifted_parts.append(copy)
		for c in _box_cells(copy["min"], copy["size"]):
			if not moved.has(c):
				moved[c] = []
			moved[c].append(copy)
	cells = moved
	parts = shifted_parts
	_totals_dirty = true
	var rekeyed := {}
	for key in links.keys():
		rekeyed[_shift_face_id(key, delta)] = _shift_face_id(links[key], delta)
	links = rekeyed
	var rekeyed_parts := {}
	for key in link_parts.keys():
		rekeyed_parts[_shift_face_id(key, delta)] = link_parts[key]
	link_parts = rekeyed_parts
	return {"ok": true, "moved": shifted_parts.size(), "reason": ""}


## 小面 id 跟着平移：把里面的格子坐标整体加上 delta。
static func _shift_face_id(id: String, delta: Vector3i) -> String:
	var halves := id.split("|")
	var coords := halves[0].split(",")
	var dirs := halves[1].split(",")
	return face_id(
		Vector3i(
			int(coords[0]) + delta.x, int(coords[1]) + delta.y, int(coords[2]) + delta.z
		),
		Vector3i(int(dirs[0]), int(dirs[1]), int(dirs[2]))
	)


func part_at(cell: Vector3i) -> Variant:
	var list := entries_at(cell)
	if list.is_empty():
		return null
	# 优先返回"基准格就在这一格"的零件：多零件共享格子时，它才是这一格的主人
	for entry in list:
		if (entry.get("anchor", entry["origin"]) as Vector3i) == cell:
			return entry
	return list[0]


static func face_id(cell: Vector3i, dir: Vector3i) -> String:
	return "%d,%d,%d|%d,%d,%d" % [cell.x, cell.y, cell.z, dir.x, dir.y, dir.z]


## 轴对齐旋转的干净化：把基向量的分量收成 0/±1，免得 90 度旋转攒出浮点误差。
static func snap_basis(b: Basis) -> Basis:
	return Basis(_snap_axis(b.x), _snap_axis(b.y), _snap_axis(b.z)).orthonormalized()


static func _snap_axis(v: Vector3) -> Vector3:
	return Vector3(roundf(v.x), roundf(v.y), roundf(v.z))


## 零件**实际占的格子** = 碰撞箱（网格包围盒）覆盖到的 cube 格子（向下/向上取整）。
## 注意这里用的是 `mesh_bounds()`（真实模型的实心范围），不是声明的 `cubes` 盒子：
## 轮轴声明 2x2x1，但网格只有 1.19 cube 高，所以声明盒子里空着的那半格必须还给玩家盖东西。
## 反过来说，探出盒子的部分（轮轴下移 3 像素的那一截）会多占下面那一排格子 —— 这是有意的：
## 「碰撞箱压住谁就不能建谁」。
static func cell_box_of(def: PartDef, basis: Basis, cell: Vector3i) -> Dictionary:
	var box := world_bounds(def, basis, cell)
	# 坐标都是 1/16 的整数倍，正好贴在格子边界上的面不该多算一格（轮轴顶面正好在 y = 1.0）
	var lo := Vector3i(
		floori(box.position.x + 0.000001),
		floori(box.position.y + 0.000001),
		floori(box.position.z + 0.000001)
	)
	var hi := Vector3i(
		ceili(box.position.x + box.size.x - 0.000001),
		ceili(box.position.y + box.size.y - 0.000001),
		ceili(box.position.z + box.size.z - 0.000001)
	)
	return {
		"min": lo,
		"size": Vector3i(
			maxi(1, hi.x - lo.x), maxi(1, hi.y - lo.y), maxi(1, hi.z - lo.z)
		),
	}


## 部件占的格子（碰撞箱覆盖到的格子）
static func cells_of(def: PartDef, basis: Basis, cell: Vector3i) -> Array:
	var box := cell_box_of(def, basis, cell)
	var mn: Vector3i = box["min"]
	var size: Vector3i = box["size"]
	var out := []
	for y in range(size.y):
		for z in range(size.z):
			for x in range(size.x):
				out.append(mn + Vector3i(x, y, z))
	return out


## 旋转后 AABB 的格子尺寸：|R| * size（轴对齐旋转下结果是整数）
static func size_of(def: PartDef, basis: Basis) -> Vector3i:
	var m := snap_basis(basis)
	var s := Vector3(def.cubes)
	return Vector3i(
		int(roundf(absf(m.x.x) * s.x + absf(m.y.x) * s.y + absf(m.z.x) * s.z)),
		int(roundf(absf(m.x.y) * s.x + absf(m.y.y) * s.y + absf(m.z.y) * s.z)),
		int(roundf(absf(m.x.z) * s.x + absf(m.y.z) * s.y + absf(m.z.z) * s.z))
	)


## 局部 [0, size] 的盒子被 basis 旋转后，AABB 的最小角相对原点的偏移。
static func rotated_aabb_min(basis: Basis, size: Vector3i) -> Vector3:
	var lo := Vector3(INF, INF, INF)
	for i in range(8):
		var corner := Vector3(
			float(size.x) if (i & 1) != 0 else 0.0,
			float(size.y) if (i & 2) != 0 else 0.0,
			float(size.z) if (i & 4) != 0 else 0.0
		)
		lo = lo.min(basis * corner)
	return lo


## 默认连接点在局部空间的位置：**基准格**（见 `PartDef.anchor_cell()`）朝默认面那一侧的面心。
##
## ⚠️ 必须用基准格，不能写死 (0.5,0.5,0.5) —— 那是"基准格 = 体积原点那一格"的假设。
## 1×1×1 方块、角块、2×2×1 轮轴的基准格恰好都是 (0,0,0)，所以这假设一直没暴露；
## 3×3×3 的转塔（底座中心那格 (1,0,1)）用旧公式贴到别的零件上会整体偏 (1,0,1) 格。
static func default_connection_point(def: PartDef) -> Vector3:
	return (
		Vector3(def.anchor_cell()) + Vector3(0.5, 0.5, 0.5)
		+ Vector3(def.default_connection_face()) * 0.5
	)


## 摆放平移量：让**新零件的默认连接点**与**目标面的面心**重合。
##
## 这是“建造时永远用默认连接点去贴”的直接翻译；旋转是绕该连接点做的，
## 所以滚转档位只会让零件绕连接点转，不会把零件甩到别处。
static func placement_transform(
	def: PartDef, hit_cell: Vector3i, hit_dir: Vector3i, basis: Basis
) -> Transform3D:
	var target := Vector3(hit_cell) + Vector3(0.5, 0.5, 0.5) + Vector3(hit_dir) * 0.5
	var clean := snap_basis(basis)
	return Transform3D(clean, target - clean * default_connection_point(def))


## 等价形式：把旋转后 AABB 的最小角对齐到格子角点。
## 两者必须一致 —— 见 tests/test_build_grid.gd 里的等价断言。
static func cell_transform(def: PartDef, cell: Vector3i, basis: Basis) -> Transform3D:
	var clean := snap_basis(basis)
	return Transform3D(clean, Vector3(cell) - rotated_aabb_min(clean, def.cubes))


## 把一组本地半空间搬到**摆放后**的坐标系（旋转 + 平移，和 `cell_transform()` 一致）。
## 本地平面 (n, d) 表示 `n · p ≤ d`；摆放后 `p_w = basis · p_l + origin`，代入得
## 新平面 `(basis · n, d + (basis · n) · origin)`。法线取单位长度，这样 `d` 的余量就是"格"。
static func transform_planes(planes: Array, placement: Transform3D) -> Array:
	var out := []
	for item in planes:
		var plane: Plane = item
		var normal := (placement.basis * plane.normal).normalized()
		out.append(Plane(normal, plane.d + normal.dot(placement.origin)))
	return out


## 由摆放变换反推零件占据的起始格子。
static func origin_cell_of(def: PartDef, basis: Basis, transform: Transform3D) -> Vector3i:
	var clean := snap_basis(basis)
	var lo := rotated_aabb_min(clean, def.cubes)
	return Vector3i((transform.origin + lo).round())


## 零件的**基准格（锚点）**：绑死在**模型自己的一个格子**上，摆放时只把它按朝向转过去。
##
## 为什么必须绑在本地格子上（踩过的大坑）：以前是"摆放之后按世界坐标算一个点，再取它落在
## 哪一格"——`model_offset` 把本体挪出盒子（轮轴下移 3 像素），本体相对盒子的方向会跟着
## 朝向转，于是那个点有时落在本体上、有时落到本体外面（实测 24 个朝向里 12 个锚点离本体
## 差 1 格）—— 看着就是"锚点飞了"。绑成本地格子之后，锚点永远落在本体上同一个位置。
##
## 本地锚点 = 本体（不含轮体）网格 AABB **中心**所在那一格的格心：
##   * 取格心（半整数）而不是 AABB 中心点：轴对齐旋转 + 整数格平移之后它仍落在格子正中，
##     不会被"正好压在格线上"的取整扔到隔壁格去（镜像也不动它的格子）；
##   * 取"中心那一格"：它落在本体最厚的那一块上（轮轴就是它的安装板），不会跑到薄边上。
## 结果按零件缓存（`set_defs()` 会清空），每个零件只算一次。
## ⚠️ 独占规则早就不看了（锚点只是"户口"），但 `can_place()` 和 `_commit()` 仍然共用这个函数。
func anchor_cell_from(def: PartDef, transform: Transform3D, _basis: Basis) -> Vector3i:
	var local := _body_anchor_local(def)
	var world: Vector3 = transform * local
	return Vector3i(floori(world.x), floori(world.y), floori(world.z))


## 本地锚点（格心）：本体 AABB 中心所在那一格的格心。按零件缓存。
func _body_anchor_local(def: PartDef) -> Vector3:
	if _body_anchor.has(def.id):
		return _body_anchor[def.id]
	# 规则只有一处：`PartDef.anchor_cell()`（压格线时取下面那格）
	var local := Vector3(def.anchor_cell()) + Vector3(0.5, 0.5, 0.5)
	_body_anchor[def.id] = local
	return local


## ── 镜像建造（左右对称）────────────────────────────────────────────────────
##
## 镜面 = 世界 z = mirror_half / 2，所以 mirror_half 以**半格**为单位：
##   偶数 → 镜面落在格线上（0 = 场地中线，格 -1 | 格 0 之间；和 data/vehicles 里的
##   载具中线一致）；奇数 → 镜面落在某一格的正中（1 = 格 0 的中心）。
## 两种都让"整数格 → 整数格"，所以半格挪动不会把镜像体甩到格子外面去。
##
## 做法：**把零件绕自己的 z 中线对折，再对世界做 z 镜像**。
## 对折在大多数零件上就是"什么都不用做"（零件本来就左右轴对称）；少数零件（两个角块）
## 的对称面不平行于坐标轴，对折之后形状变了 —— 但那也没关系：它们的对折结果可以用一个
## **轴对齐旋转**（立方体 24 个旋转里的一个）复原，`mirror_fold_rotation()` 负责把它找出来。
## 于是镜像摆放永远是一个正常的「旋转 + 平移」（行列式 +1，存档的 yaw/pitch/roll 记得下），
## 不需要左手系副本。
## ⚠️ 镜像性**不由代码判定**（2026-10-15 用户要求）：找不到严格对折时按单位阵处理，
## 零件照样能镜像（"放得下就放"）；将来真加非对称零件，由用户单独说明再处理。
const MIRROR_HALF_MIN := -64  # 场地 z ∈ [-32, 32]，半格为单位
const MIRROR_HALF_MAX := 64
## z 取反的反射矩阵 S（绕 z = 0 平面镜像）
const MIRROR_FLIP := Basis(Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1))


static func mirror_plane(mirror_half: int) -> float:
	return float(mirror_half) * 0.5


## 立方体的 24 个轴对齐旋转（都绕盒子中心）。顺序固定，**单位阵排第一** ——
## 这样左右轴对称的零件永远选中"什么都不转"，镜像体的 (cell, basis) 和以前一模一样。
static func cube_rotations() -> Array:
	var axes := [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]
	var out := []
	for perm in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]:
		for sx in [1.0, -1.0]:
			for sy in [1.0, -1.0]:
				for sz in [1.0, -1.0]:
					var rotation := Basis(
						axes[perm[0]] * sx, axes[perm[1]] * sy, axes[perm[2]] * sz
					)
					if absf(rotation.determinant() - 1.0) < 0.001:
						out.append(rotation)
	return out


## 零件的**对折旋转** A：把零件本地几何绕 z 中线对折（z -> cubes.z - z）之后，
## 用 A 转一下能复原回自己（体素级集合相等）就返回 {ok: true, basis: A}。
##
## 左右轴对称的零件 A = 单位阵；两个角块（corner_tetra / corner_cut）的对称面
## 不平行于坐标轴（x+y+z ≤ 15 这种对角切面），但对折结果正好是"绕 x 轴转 -90 度"，
## 所以照样能用同一份模型摆出镜像 —— 这里找的就是那个旋转。
##
## ⚠️ **这里不判定"零件能不能镜像"**（2026-10-15 用户要求）：镜像性由人判断，
## 全部零件都当对称处理，找不到严格对折就按单位阵走，返回值永远是 `ok = true`。
## 分析只用来①给角块那种"对称面不平行于坐标轴"的零件找旋转、②把"对不上几个格子"
## 报在 `mismatch` 里给界面/工具看（0 = 严格对称）。真遇到非对称零件，用户会单独说明，
## 那时再按说明处理（比如另做一份左手系模型），而不是让代码去猜。
## 结果按零件缓存（set_defs() 会清空），每个零件只找一次。
func mirror_fold_rotation(def: PartDef) -> Dictionary:
	if def == null:
		return {"ok": true, "basis": Basis(), "mismatch": 0, "found": false}
	if _mirror_fold.has(def.id):
		return _mirror_fold[def.id]
	var result := _find_mirror_fold_rotation(def)
	_mirror_fold[def.id] = result
	return result


func _find_mirror_fold_rotation(def: PartDef) -> Dictionary:
	# 体素中心（单位 = 1/32 cube 的整数坐标，盒子最小角当原点）+ 对折后的同一套坐标
	var centers := {}
	for solid: Dictionary in _solids_of(def.id):
		var volume: VoxVolume = solid["volume"]
		var origin: Vector3 = solid["origin"]
		var offset := Vector3i(
			roundi(origin.x * 16.0), roundi(origin.y * 16.0), roundi(origin.z * 16.0)
		)
		for z in range(volume.size.z):
			for y in range(volume.size.y):
				for x in range(volume.size.x):
					if not volume.is_solid(x, y, z):
						continue
					var cell := Vector3i(x, y, z) + offset
					centers[Vector3i(cell.x * 2 + 1, cell.y * 2 + 1, cell.z * 2 + 1)] = true
	var folded := {}
	var span := def.cubes.z * 32
	for corner: Vector3i in centers.keys():
		folded[Vector3i(corner.x, corner.y, span - corner.z)] = true
	var centre := Vector3(def.cubes) * 16.0
	# 24 个轴对齐旋转里挑"对不上格子最少"的那个：严格对称是 0（这时才采用它的旋转）
	var best_basis := Basis()
	var best_mismatch := 1 << 30
	for rotation: Basis in cube_rotations():
		var mismatch := _fold_mismatch(centers, folded, rotation, centre)
		if mismatch < best_mismatch:
			best_mismatch = mismatch
			best_basis = rotation
			if mismatch == 0:
				break
	if best_mismatch != 0:
		# 不是严格对称：按单位阵处理（**不拒绝**，镜像性由人判断）
		best_basis = Basis()
	return {
		"ok": true,
		"basis": best_basis,
		"mismatch": best_mismatch,
		"found": best_mismatch == 0,
	}


## 这个旋转把"对折后的形状"复原得像不像：返回**对不上的格子数**（0 = 逐体素完全对称）。
func _fold_mismatch(
	centers: Dictionary, folded: Dictionary, rotation: Basis, centre: Vector3
) -> int:
	var mismatch := 0
	for corner: Vector3i in centers.keys():
		var turned: Vector3 = rotation * (Vector3(corner) - centre) + centre
		if not folded.has(Vector3i(roundi(turned.x), roundi(turned.y), roundi(turned.z))):
			mismatch += 1
	return mismatch


## 单格（1 x 1 x 1）镜像后的格子：格 [z, z+1] 映到 [2mz - z - 1, 2mz - z]。
## 单格的基准格也能用这一条 —— 但零件在 z 上跨多格时，镜像体的基准格**不在**
## "本体基准格的镜像格"上，所以拆除那边是从镜像**摆放**反推基准格（见 remove_with_mirror）。
static func mirror_cell(cell: Vector3i, mirror_half: int) -> Vector3i:
	return Vector3i(cell.x, cell.y, mirror_half - 1 - cell.z)


## 零件的镜像摆放：仍然返回 (cell, basis) 这套表示，可以直接喂给 can_place() / place()。
##
## 推导（A = 对折旋转，L = cubes.z，S = z 取反的反射，B 是本体的朝向）：
##   对折后的形状 A(G) = S(G) + L·ẑ（见 mirror_fold_rotation），
##   真镜像是 M(T(G)) = S·B(G) + S·t + 2mz·ẑ；把 S(G) 换成 A(G) - L·ẑ、两边各乘一次 S
##   （记 B' = S·B·S）就得到
##     M(T(G)) = (B'·A)(G) + S·t + 2mz·ẑ - L·(B'·ẑ) + B'·a
##   其中 a = 盒子中心 - A·(盒子中心)：A 是"绕盒子中心"的旋转，是个仿射变换，
##   这一项就是它的平移部分（A = 单位阵时 a = 0，公式退化成老样子）。
##   所以镜像摆放 = 「转 B'·A」+「平移 S·t + 2mz·ẑ - L·(B'·ẑ) + B'·a」—— 仍是正常的旋转/平移
##   （行列式 +1，存档的 yaw/pitch/roll 记得下），落子 / 碰撞 / 射线全部复用同一套代码。
## 左右轴对称的零件 A = 单位阵，公式退化成老样子。
## （非对称零件也照样算：A 按单位阵处理，结果"放得下就放"，但不再是逐体素的真镜像。）
func mirror_placement(
	def: PartDef, cell: Vector3i, basis: Basis, mirror_half: int
) -> Dictionary:
	var clean := snap_basis(basis)
	var fold := mirror_fold_rotation(def)
	if not bool(fold.get("ok", false)):
		return {}
	var placed := cell_transform(def, cell, clean)
	var flipped := snap_basis(MIRROR_FLIP * clean * MIRROR_FLIP)
	var fold_basis: Basis = fold["basis"]
	var mirrored := snap_basis(flipped * fold_basis)
	# A 是"绕盒子中心"的旋转，仿射平移部分是 a = 盒子中心 - A·(盒子中心)（A = 单位阵时 a = 0）
	var centre := Vector3(def.cubes) * 0.5
	var origin := (
		MIRROR_FLIP * placed.origin
		+ Vector3(0.0, 0.0, float(mirror_half))
		- float(def.cubes.z) * (flipped * Vector3(0.0, 0.0, 1.0))
		+ flipped * (centre - fold_basis * centre)
	)
	var mirrored_cell := Vector3i((origin + rotated_aabb_min(mirrored, def.cubes)).round())
	return {
		"cell": mirrored_cell,
		"basis": mirrored,
		"transform": Transform3D(mirrored, origin),
	}


## 把一整组零件塞进场地所需的最小整体位移（能放下就返回 0）。
## 给"加载载具"用：零件坐标原样保存，万一有零件的网格会探出场地
## （轮轴下探 3 像素、载具又贴在最底排），就整体挪最小的量 —— 绝不归一化，
## 载具在场地里的位置要原样保留。
static func fit_shift(parts: Array, defs: Dictionary) -> Vector3i:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for part: Dictionary in parts:
		var def: PartDef = defs.get(part.get("part_id", ""))
		if def == null:
			continue
		var box := world_bounds(def, part["basis"], part["cell"])
		lo = lo.min(box.position)
		hi = hi.max(box.position + box.size)
	if lo.x > hi.x:
		return Vector3i.ZERO
	var shift := Vector3i.ZERO
	if lo.y < float(AREA_MIN.y):
		shift.y = ceili(float(AREA_MIN.y) - lo.y)
	if hi.y + float(shift.y) > float(AREA_MAX.y):
		shift.y = floori(float(AREA_MAX.y) - hi.y)
	if lo.x < float(AREA_MIN.x):
		shift.x = ceili(float(AREA_MIN.x) - lo.x)
	if hi.x + float(shift.x) > float(AREA_MAX.x):
		shift.x = floori(float(AREA_MAX.x) - hi.x)
	if lo.z < float(AREA_MIN.z):
		shift.z = ceili(float(AREA_MIN.z) - lo.z)
	if hi.z + float(shift.z) > float(AREA_MAX.z):
		shift.z = floori(float(AREA_MAX.z) - hi.z)
	return shift


func inside_area(def: PartDef, basis: Basis, cell: Vector3i) -> bool:
	# 按**网格实际包围盒**判断，而不是按 cube 格数：模型可能带偏移探出部件盒，
	# "连接点合法但会探出场地"这种情况必须在这一层就被判掉（界面据此画红色虚影）
	var clean := snap_basis(basis)
	# 注意要用真正的摆放平移量（cell_transform 会把旋转后的 AABB 最小角对齐到格子），
	# 否则旋转过的零件会凭空"多探出一格"，把合法位置误判成超框。
	var box := world_bounds(def, clean, cell)
	var lo := box.position
	var hi := lo + box.size
	return (
		lo.x >= float(AREA_MIN.x)
		and lo.y >= float(AREA_MIN.y)
		and lo.z >= float(AREA_MIN.z)
		and hi.x <= float(AREA_MAX.x)
		and hi.y <= float(AREA_MAX.y)
		and hi.z <= float(AREA_MAX.z)
	)


## 部件摆到某处后的世界包围盒（含 model_offset 造成的外探部分）。
static func world_bounds(def: PartDef, basis: Basis, cell: Vector3i) -> AABB:
	var clean := snap_basis(basis)
	var placement := cell_transform(def, cell, clean)
	var box := rotate_aabb(clean, def.mesh_bounds())
	return AABB(placement.origin + box.position, box.size)


## 体素级干涉检测：先比包围盒，真的重叠了才逐体素比对。
## 这是**唯一**的碰撞判据（多零件可以共享格子，所以不能再靠"格子被占"来挡穿模）。
## extra 是"还没真正落子、但要一起算进去"的 entry：镜像建造拿本体当参照去查镜像体，
## 所以"两个零件互相压住"也能挡住（entry 结构见 _make_entry()）。
## 返回干涉到的零件的声明格（空字符串 = 没干涉）。
func mesh_clash(def: PartDef, basis: Basis, cell: Vector3i, extra := []) -> String:
	var clean := snap_basis(basis)
	var mine := _solids_of(def.id)
	if mine.is_empty():
		return ""
	var box := world_bounds(def, clean, cell)
	var placement := cell_transform(def, cell, clean)
	var inv := placement.affine_inverse()
	# 本体 / 子模型各自的世界包围盒（粗筛用；子模型也要算碰撞体积）
	var my_boxes: Array = []
	for a: Dictionary in mine:
		my_boxes.append(_solid_world_box(a, clean, placement.origin))
	for entry: Dictionary in parts:
		var hit := _clash_with(mine, my_boxes, box, inv, entry)
		if not hit.is_empty():
			return hit
	for entry: Dictionary in extra:
		var hit := _clash_with(mine, my_boxes, box, inv, entry)
		if not hit.is_empty():
			return hit
	return ""


## 和**某一个**零件（或在 extra 里的假 entry）比体素干涉；真重叠了就返回它的声明格。
func _clash_with(
	mine: Array, my_boxes: Array, box: AABB, inv: Transform3D, entry: Dictionary
) -> String:
	var other_def: PartDef = _defs_cache.get(entry["part_id"])
	if other_def == null:
		return ""
	# 包围盒落子时就存在 entry 里：每帧要跟所有零件比一遍，别重复算
	var overlap := box.intersection(entry["bounds"])
	if overlap.size.x <= 0.001 or overlap.size.y <= 0.001 or overlap.size.z <= 0.001:
		return ""
	var theirs := _solids_of(other_def.id)
	if theirs.is_empty():
		return ""
	# 本体 / 子模型两两比（轮体也算碰撞体积）
	var other_inv: Transform3D = (entry["transform"] as Transform3D).affine_inverse()
	for i in mine.size():
		var a: Dictionary = mine[i]
		for j in theirs.size():
			var b: Dictionary = theirs[j]
			var sub := (my_boxes[i] as AABB).intersection(
				_solid_world_box(b, entry["basis"], (entry["transform"] as Transform3D).origin)
			)
			if sub.size.x <= 0.001 or sub.size.y <= 0.001 or sub.size.z <= 0.001:
				continue
			if _voxels_overlap(
				a["volume"], inv, a["origin"], b["volume"], other_inv, b["origin"], sub
			):
				return str(entry["origin"])
	return ""


## 某个实体块的世界包围盒（本地盒按 basis 旋转后平移到 origin）。
static func _solid_world_box(solid: Dictionary, basis: Basis, origin: Vector3) -> AABB:
	var box := rotate_aabb(snap_basis(basis), solid["box"])
	return AABB(origin + box.position, box.size)


static func _voxels_overlap(
	a_volume: VoxVolume,
	a_inv: Transform3D,
	a_origin: Vector3,
	b_volume: VoxVolume,
	b_inv: Transform3D,
	b_origin: Vector3,
	overlap: AABB
) -> bool:
	var unit := float(VoxVolume.VOXELS_PER_CUBE)
	var lo := (overlap.position * unit).floor()
	var hi := ((overlap.position + overlap.size) * unit).ceil()
	# 规模兜底：正常最多几个 cube，真出意外也不至于卡住
	hi = lo + Vector3(
		minf(hi.x - lo.x, 64.0), minf(hi.y - lo.y, 64.0), minf(hi.z - lo.z, 64.0)
	)
	for z in range(int(lo.z), int(hi.z)):
		for y in range(int(lo.y), int(hi.y)):
			for x in range(int(lo.x), int(hi.x)):
				var centre := (Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5)) / unit
				if not _solid_at(a_volume, a_inv, a_origin, centre):
					continue
				if _solid_at(b_volume, b_inv, b_origin, centre):
					return true
	return false


static func _solid_at(
	volume: VoxVolume, inv: Transform3D, origin: Vector3, world_point: Vector3
) -> bool:
	var local := (inv * world_point - origin) * float(VoxVolume.VOXELS_PER_CUBE)
	return volume.is_solid(floori(local.x), floori(local.y), floori(local.z))


## 轴对齐旋转下的 AABB 变换（取八个角求包围盒）
static func rotate_aabb(basis: Basis, box: AABB) -> AABB:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in range(8):
		var corner := box.position + Vector3(
			box.size.x if (i & 1) != 0 else 0.0,
			box.size.y if (i & 2) != 0 else 0.0,
			box.size.z if (i & 4) != 0 else 0.0
		)
		var world := basis * corner
		lo = lo.min(world)
		hi = hi.max(world)
	return AABB(lo, hi - lo)


## 部件在某个世界朝向上的面是否带连接点。
## 对 1 cube 部件就是“把局部连接面法线用 basis 旋到世界，看有没有匹配”。
static func has_connection_towards(def: PartDef, basis: Basis, dir: Vector3i) -> bool:
	var local_dir := (basis.inverse() * Vector3(dir)).round()
	return def.has_connection_face(Vector3i(local_dir))


## 这一格的这个朝向上，零件网格在**格子外表面**里露出多少格（0..256）。
##
## 为什么要按格子量：零件级"有连接面"不代表**每个**足迹格上都有。
## 轮轴用 `model_offset = 0 -3 0` 整体下移 3 像素，它的安装面在基准那一格里是满的，
## 在下面那一排格子里只被模型底部薄薄一层擦到（甚至完全不露）—— 那里不是能挂东西的面。
##
## `placement` 必须是零件**实际**的摆放变换（已放下的用 entry["transform"]，
## 待放的用 cell_transform/placement_transform）—— 不能拿"把这个格子当基准格"猜出来的变换。
func face_coverage(
	def: PartDef, placement: Transform3D, cell: Vector3i, dir: Vector3i
) -> int:
	var volume := _volume_of(def.id)
	if volume == null:
		return 0
	var local_dir := Vector3i((placement.basis.inverse() * Vector3(dir)).round())
	if local_dir == Vector3i.ZERO:
		return 0
	var axis := VoxMesher.axis_of(local_dir)
	var positive := local_dir[axis] > 0
	var pad := def.model_pad
	# 格子中心 -> 零件本地坐标 -> 体积索引。
	# 用格心而不是角点：零件转过 90 度后，本地轴可能和世界轴反向，
	# 角点会算到隔壁那一格去（格心取整就永远落在正确的本地格子里）。
	var centre := placement.affine_inverse() * (Vector3(cell) + Vector3(0.5, 0.5, 0.5))
	var base := Vector3i(
		floori(centre.x) * 16 + pad.x,
		floori(centre.y) * 16 + pad.y,
		floori(centre.z) * 16 + pad.z
	)
	# 沿 dir 的平面往零件里退一层，就是"格子外表面"那一层体素
	var idx_inner := base[axis] + (15 if positive else 0)
	if idx_inner < 0 or idx_inner >= volume.size[axis]:
		return 0
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	# 直接扫扁平数组：这个函数一帧要跑好几次，别走 is_solid() 的函数调用
	var data := volume.data
	var stride := Vector3i(1, volume.size.x, volume.size.x * volume.size.y)
	var size_u := volume.size[u]
	var size_v := volume.size[v]
	var row0 := idx_inner * stride[axis]
	var count := 0
	for dv in range(16):
		var iv := base[v] + dv
		if iv < 0 or iv >= size_v:
			continue
		var row := row0 + iv * stride[v]
		for du in range(16):
			var iu := base[u] + du
			if iu < 0 or iu >= size_u:
				continue
			if data[row + iu * stride[u]] != VoxVolume.EMPTY:
				count += 1
	return count


## 一个小面 `(cell, dir)` 算不算这个零件的**连接小面**：
## 零件级要有这个朝向的连接面，而且**这一格**上真的露出够大的面
## （判据与连接面自动推导一致：露出 ≥ VoxModel.MIN_CONNECTION_AREA 格）。
func claims_face(
	def: PartDef, basis: Basis, placement: Transform3D, cell: Vector3i, dir: Vector3i
) -> bool:
	if not has_connection_towards(def, basis, dir):
		return false
	return face_coverage(def, placement, cell, dir) >= VoxModel.MIN_CONNECTION_AREA


## 这个小面是不是**埋在自己身体里**（对面那一格上，本零件自己的几何也压着它）。
## 判据是几何的：对面那一格朝回来的那一层上，本零件自己有没有体素。
##
## ⚠️ 别用"对面那一格在不在足迹里"来判：轮体的存在让轮轴的足迹多出一圈，
## 但安装板那两片**薄面（±z）**根本没被轮体挡住 —— 它们是轮轴真正的安装面
## （声明的 4 个连接点里的两个），拿足迹判会把它们当成"内部面"跳过，
## 于是安装板上明明能吸附的位置登记不上连接。
func face_is_internal(
	def: PartDef, placement: Transform3D, cell: Vector3i, dir: Vector3i
) -> bool:
	return face_coverage(def, placement, cell + dir, -dir) > 0


## 候选放置的朝向：把部件的**默认连接面**转到 mating_dir（世界方向），
## 也就是“建造时以默认连接点为连接基点”。roll 是绕该面法线的 90 度档位，
## 传 -1 表示自动挑“尽量保持零件原本朝上”的那一档。
static func candidate_basis(def: PartDef, mating_dir: Vector3i, roll := -1) -> Basis:
	var from := Vector3(def.default_connection_face())
	var to := Vector3(mating_dir)
	var align := Basis()
	if not from.is_equal_approx(to):
		if from.is_equal_approx(-to):
			# 反平行：绕任意垂直轴转 180 度
			if absf(from.y) < 0.9:
				# from 是水平的（轮轴的安装面就是 -x）：绕**世界 UP** 转 180° = 原地掉头。
				# 不要绕 from×UP 那种水平轴 —— 那会顺带把零件上下颠倒，
				# 带 model_offset 的零件（轮轴下移 3 像素）在机身左右两侧就对不上了。
				align = Basis(Vector3.UP, PI)
			else:
				# from 是竖直的（比如挂在顶棚下）：只能倒过来
				align = Basis(Vector3.RIGHT, PI)
		else:
			align = Basis(Quaternion(from, to))
	var roll_index := roll
	if roll_index < 0:
		roll_index = best_roll(align, to)
	var rolled := Basis(to, deg_to_rad(90.0 * float(roll_index))) * align
	return snap_basis(rolled)


## 挑一个“零件原本朝上”保持得最好的 roll 档位。
static func best_roll(align: Basis, axis: Vector3) -> int:
	var best := 0
	var best_score := -INF
	for i in range(4):
		var rolled := Basis(axis, deg_to_rad(90.0 * float(i))) * align
		var score := (rolled * Vector3.UP).dot(Vector3.UP)
		if score > best_score + 0.0001:
			best = i
			best_score = score
	return best


## 检查能不能放（不改状态）。extra = 额外参与干涉检测的假 entry
## （镜像建造查镜像体时把本体传进来）。
##
## **连接不影响能不能放**：零件可以悬空（建造的中间状态），能不能进测试场由
## robot_status() 另外判（没有核心 / 有零件没连上核心就进不去）。
##
## ⚠️ 这一段说的是"**放置本身**"不因为连接账本而失败；**直接放置**仍然要瞄在连接面上
## （那条在 plan() 里：目标面和新零件这一侧都得是连接面）。镜像体按镜像位置落子，
## 不受这条约束 —— 它悬空是允许的。
func can_place(def: PartDef, cell: Vector3i, basis: Basis, extra := []) -> Dictionary:
	if not inside_area(def, basis, cell):
		return {"ok": false, "reason": "超出建造场地范围"}
	# 核心：一台机器人最多一个
	if def.is_core and has_core():
		return {"ok": false, "reason": "这台机器人已经装了一个核心（最多一个）"}
	# 干涉先判：这是**物理上**真正挡人的那一条（体素级），先报它才不会误导 ——
	# 轮轴的安装板只有 2 像素厚，铺满整个格子底面，被它挡住却报"基准格冲突"就说不通了。
	var clash := mesh_clash(def, basis, cell, extra)
	if not clash.is_empty():
		return {"ok": false, "reason": "网格会和 %s 处的零件干涉（穿模）" % clash}
	# 部件点数预算。extra 里那些"还没真正落子"的零件（镜像建造拿本体当参照查镜像体）
	# 也要算进来 —— 这样预览和真正落子时的结果一致（谁超点数就不放谁，见 plan_mirror）。
	var used := int(totals()["pp"]) + _extra_pp(extra)
	if used + def.pp > PP_LIMIT:
		return {
			"ok": false,
			"reason": "点数不够：已经用 %d / %d，这一件还要 %d pp" % [used, PP_LIMIT, def.pp],
		}
	# ⚠️ 基准格**不独占**：它绑在模型的本地格子上，所以位置是"零件身上固定那一处"，
	# 只用来认零件（镜像拆除按它找人）。能不能放只看几何 —— 唯一的碰撞判据是体素级
	# mesh_clash()：两个零件只要不真穿模，就可以共处一格（轮轴安装板中间塞三角块就是
	# 靠这一条；早年用"基准格独占"拦过，结果把本来能共享的位置也拦掉了）。
	return {"ok": true, "pairs": _collect_pairs(def, cell, basis)}


func place(def: PartDef, cell: Vector3i, basis: Basis) -> Dictionary:
	var clean := snap_basis(basis)
	return _commit(def, cell, clean, cell_transform(def, cell, clean))


## 按 plan() 的结果落子（平面已经算好，直接提交）。
func place_plan(def: PartDef, plan: Dictionary) -> Dictionary:
	return _commit(def, plan["cell"], plan["basis"], plan["transform"])


## 镜像模式落子：本体和镜像体**各自独立**落（用户要求）——
## 谁过不了检查就不落谁，另一边照落。plan = plan_mirror() 的结果。
## 本体先落，所以"点数只够一件"时留下的是本体（判镜像体时本体那件已经算进预算了）。
## 返回 {ok, placed, reason}：placed 是真正落了几个零件。
func place_plan_mirror(def: PartDef, plan: Dictionary) -> Dictionary:
	var placed := 0
	var body: Dictionary = plan.get("body", {})
	if not body.is_empty() and bool(plan.get("place_body", false)):
		if bool(_commit(def, body["cell"], body["basis"], body["transform"])["ok"]):
			placed += 1
	var mirror: Dictionary = plan.get("mirror", {})
	if not mirror.is_empty() and bool(plan.get("place_mirror", false)):
		if bool(_commit(def, mirror["cell"], mirror["basis"], mirror["transform"])["ok"]):
			placed += 1
	return {
		"ok": placed > 0,
		"placed": placed,
		"reason": "" if placed > 0 else str(plan.get("reason", "")),
	}


## 由命中信息算出候选放置（不落子）。roll 是绕默认连接点所在轴的 90 度档位。
## include_invalid = true 时，即使放不下也会返回候选（valid=false + reason），
## 供界面画红色虚影。连接点本身不合法（面上没连接点 / 对面没连接点）时仍然返回 {}。
func plan(def: PartDef, hit: Dictionary, roll: int, include_invalid := false) -> Dictionary:
	if def == null or hit.is_empty():
		return {}
	var kind: String = hit.get("type", "none")
	if kind == "none":
		return {}
	var hit_dir: Vector3i = hit["dir"]
	if hit_dir == Vector3i.ZERO:
		return {}
	var basis := snap_basis(candidate_basis(def, -hit_dir, roll))
	var transform := placement_transform(def, hit["cell"], hit_dir, basis)
	var cell := origin_cell_of(def, basis, transform)
	# 直接放置必须**吸附在连接点上**：新零件这一侧要有连接面（默认连接点保证），
	# 命中的那一侧也得是这个零件**在这一格上真的露出来**的连接面（斜切面 / 薄边不算）。
	# ⚠️ 这里判的是"面"，不是"连接账本里真的凑成了一对"：面合格就能放，账本那一对可能
	# 因为那一格已经被别人占着而记不上 —— 那是数据规则，不是放置错误。
	# （镜像体不受这条约束：它是跟着本体镜像过去的，那边悬空是允许的。）
	if not has_connection_towards(def, basis, -hit_dir):
		return {}
	if kind == "part":
		var hit_part_id: String = str(hit.get("part_id", ""))
		var ok := false
		for other: Dictionary in entries_at(hit["cell"]):
			if not hit_part_id.is_empty() and other["part_id"] != hit_part_id:
				continue
			var other_def: PartDef = _defs_cache.get(other["part_id"])
			if (
				other_def != null
				and claims_face(other_def, other["basis"], other["transform"], hit["cell"], hit_dir)
			):
				ok = true
				break
		if not ok:
			return {}
	var check := can_place(def, cell, basis)
	if not check["ok"]:
		if not include_invalid:
			return {}
		return {
			"cell": cell,
			"basis": basis,
			"transform": transform,
			"kind": kind,
			"valid": false,
			"reason": str(check.get("reason", "")),
		}
	return {
		"cell": cell,
		"basis": basis,
		"transform": transform,
		"kind": kind,
		"reason": check.get("reason", ""),
	}


## 镜像模式的规划：本体 + 镜像体**各自独立**判定（界面据此画两个虚影）。
##
## 返回 {valid, reason, body, mirror, place_body, place_mirror}：
##   body / mirror = {cell, basis, transform, kind, valid, reason}
##   valid = 至少有一边能放；place_body / place_mirror 分别说这一边放不放。
##   mirror 为空 = 镜面正好落在零件自己的对称面上（镜像 == 本体，不用多放一个）。
##
## ⚠️ **两边独立**（用户要求）：谁过不了检查就不放谁，另一边照放。
##   * 镜像体的检查用 can_place() 的全套判据，并且**只有本体真的要落子时**才把本体算进去
##     （算进干涉 / 点数预算）—— 本体自己都放不下时，镜像体不该被它牵连；
##   * 点数只够一件时：本体先算，所以是"只放本体、不放镜像体"（用户点名要的行为）。
##   * 镜像性**不在这里判定**：任何零件都出候选（见 mirror_fold_rotation 的说明）。
func plan_mirror(
	def: PartDef, hit: Dictionary, roll: int, mirror_half: int, include_invalid := false
) -> Dictionary:
	var body := plan(def, hit, roll, true)
	if body.is_empty():
		return {}
	var body_ok := bool(body.get("valid", true))
	var m := mirror_placement(def, body["cell"], body["basis"], mirror_half)
	if m.is_empty():
		return _mirror_plan_result(body, {}, body_ok, include_invalid)
	if m["cell"] == body["cell"] and (m["basis"] as Basis).is_equal_approx(body["basis"]):
		# 零件正好骑在镜面上（比如 1x1 方块放在镜面所在那一格）：镜像就是它自己
		return _mirror_plan_result(body, {}, body_ok, include_invalid)
	var extra := []
	if body_ok:
		extra.append(_make_entry(def, body["cell"], body["basis"], body["transform"]))
	var check := can_place(def, m["cell"], m["basis"], extra)
	var mirror_plan := {
		"cell": m["cell"],
		"basis": m["basis"],
		"transform": m["transform"],
		"kind": body["kind"],
		"valid": bool(check["ok"]),
		"reason": _mirror_reason(check, body),
	}
	return _mirror_plan_result(body, mirror_plan, body_ok, include_invalid)


## 把"本体/镜像体各自能不能放"拼成一份方案（含 place_body / place_mirror 两个开关）。
func _mirror_plan_result(
	body: Dictionary, mirror: Dictionary, body_ok: bool, include_invalid: bool
) -> Dictionary:
	var mirror_ok := bool(mirror.get("valid", true)) if not mirror.is_empty() else false
	if not body_ok and not mirror_ok and not include_invalid:
		return {}
	var reasons := PackedStringArray()
	if not body_ok:
		reasons.append("本体：%s" % str(body.get("reason", "")))
	if not mirror.is_empty() and not mirror_ok:
		reasons.append("镜像位置：%s" % str(mirror.get("reason", "")))
	return {
		"valid": body_ok or mirror_ok,
		"reason": "；".join(reasons),
		"body": body,
		"mirror": mirror,
		"place_body": body_ok,
		"place_mirror": mirror_ok,
	}


## 镜像体过不了检查时的说法：撞上本体时别报"和 (x, y, z) 处的零件干涉" ——
## 本体这会儿还没落子，那个坐标在玩家眼里是幽灵。
static func _mirror_reason(check: Dictionary, body: Dictionary) -> String:
	var reason := str(check.get("reason", ""))
	if (
		not bool(check.get("ok", false))
		and reason.contains("干涉")
		and reason.contains(str(body["cell"]))
	):
		return "镜像体会和本体压在一起（镜面离零件太近）"
	return reason


## 造一个 entry（结构和 _commit 挂到场地上的完全一致）。
## 镜像建造要在"检查阶段"把本体当成"已放下的零件"去查镜像体，所以必须能脱离场地造出来。
func _make_entry(def: PartDef, cell: Vector3i, basis: Basis, transform: Transform3D) -> Dictionary:
	var clean := snap_basis(basis)
	var box := cell_box_of(def, clean, cell)
	var local_box := rotate_aabb(clean, def.mesh_bounds())
	var entry := {
		"id": _next_entry_id,
		"part_id": def.id,
		"basis": clean,
		"min": box["min"],
		"size": box["size"],
		"origin": cell,
		"anchor": anchor_cell_from(def, transform, clean),
		"transform": transform,
		"bounds": AABB(transform.origin + local_box.position, local_box.size),
	}
	_next_entry_id += 1
	return entry


func _commit(
	def: PartDef, cell: Vector3i, basis: Basis, transform: Transform3D
) -> Dictionary:
	var check := can_place(def, cell, basis)
	if not check["ok"]:
		return check
	var clean := snap_basis(basis)
	# 一个零件一个 entry 对象，挂在它占的每个格子上。
	# entry 里的字段：origin = 声明盒子那一格（存档用；装载时靠它还原摆放）、
	# anchor = 基准格（锚点，独占规则用；按本体网格算，所以永远有本体体素）、
	# bounds = 网格的世界包围盒（落子时算一次存下来，每帧的干涉检测要跟所有零件比）。
	var entry := _make_entry(def, cell, clean, transform)
	parts.append(entry)
	_totals_dirty = true
	for c in cells_of(def, clean, cell):
		if not cells.has(c):
			cells[c] = []
		cells[c].append(entry)
	for pair in check["pairs"]:
		links[pair["mine"]] = pair["theirs"]
		links[pair["theirs"]] = pair["mine"]
		link_parts[pair["mine"]] = entry
		link_parts[pair["theirs"]] = pair["theirs_entry"]
		# 连通性/毁伤用的那一份：**按零件身份**记（见 _neighbours 的注释）
		_link(int(entry["id"]), int((pair["theirs_entry"] as Dictionary)["id"]))
	return {
		"ok": true,
		"entry": entry,
		"pairs": check["pairs"].size(),
		"cells": cells_of(def, clean, cell).size(),
	}


## 挑出"要拆的是哪一个零件"。cell 可以是这个零件占的任意一格；多零件共享这一格时，
## 优先认 part_id 指定的那个（射线打中的那个），其次是"基准格在这一格"的那个。
## 没得拆就返回 {}。
func victim_at(cell: Vector3i, part_id := "") -> Dictionary:
	var list := entries_at(cell)
	if list.is_empty():
		return {}
	for entry: Dictionary in list:
		if not part_id.is_empty() and entry["part_id"] == part_id:
			return entry
	for entry: Dictionary in list:
		if (entry.get("anchor", entry["origin"]) as Vector3i) == cell:
			return entry
	return list[0]


## 拆零件。cell 可以是这个零件占的任意一格；多零件共享这一格时，
## 优先拆 part_id 指定的那个（射线打中的那个），其次拆"基准格在这一格"的那个。
func remove(cell: Vector3i, part_id := "") -> bool:
	var victim := victim_at(cell, part_id)
	if victim.is_empty():
		return false
	_remove_entry(victim)
	return true


## 镜像模式下的拆除：本体 + **镜像位置的基准格**上那个零件一起拆。
## 不记录"谁是谁的镜像"，也不反推镜像摆放：基准格直接按格子镜像（mirror_cell），
## 谁站在那一格就是谁（基准格一格只归一个零件，天然唯一）。
## 这条成立的前提是基准格**绑在本地格子上**（见 anchor_cell_from）：镜像体用的是同一个
## 本地格子，镜像又把格子映到格子，所以镜像体的基准格正好是本体基准格的镜像格
## （`test_anchor_mirrors_to_the_mirrored_part` 守 6 个零件 × 24 个旋转 × 3 个半格档位）。
##
## 返回 {removed, mirrored}：removed = 实际拆了几个零件，mirrored = 是不是成对拆的。
## 镜像位置没有对应的零件（结构本来就不对称）时只拆本体 —— 不硬凑。
func remove_with_mirror(cell: Vector3i, part_id: String, mirror_half: int) -> Dictionary:
	var victim := victim_at(cell, part_id)
	if victim.is_empty():
		return {"removed": 0, "mirrored": false}
	var anchor: Vector3i = victim.get("anchor", victim["origin"])
	var partner := entry_by_anchor(mirror_cell(anchor, mirror_half), str(victim["part_id"]))
	_remove_entry(victim)
	var paired := not partner.is_empty() and not is_same(partner, victim)
	if paired:
		_remove_entry(partner)
	return {"removed": 2 if paired else 1, "mirrored": paired}


func _remove_entry(entry: Dictionary) -> void:
	# 先断自己的邻接（只动自己那几条 —— 不碰别人的，这是旧账本最容易踩的坑）
	_unlink(entry)
	# 断开这个零件占的每个小面上的连接
	for c in _box_cells(entry["min"], entry["size"]):
		for dir in VoxShapes.AXIS_DIRS:
			var my_face := face_id(c, dir)
			if links.has(my_face):
				var other: String = links[my_face]
				links.erase(other)
				links.erase(my_face)
				link_parts.erase(other)
				link_parts.erase(my_face)
		var arr: Variant = cells.get(c)
		if not (arr is Array):
			continue
		for i in range((arr as Array).size() - 1, -1, -1):
			if is_same((arr as Array)[i], entry):
				(arr as Array).remove_at(i)
		if (arr as Array).is_empty():
			cells.erase(c)
	for i in range(parts.size() - 1, -1, -1):
		if is_same(parts[i], entry):
			parts.remove_at(i)
	_totals_dirty = true


## 找出这个部件所有能对接的成对连接（不需要预先知道玩家瞄的是哪一面）。
## 邻格里可能有多个零件（共享格子），每一个都算一次；一个小面只留一对：
## 已经被别人占着的小面**跳过不记**（不是拒绝放置 —— 连接只是"顺手记上"，不影响能不能放）。
## 连接账本只服务于"连通性"（robot_status：能不能进测试场）。
func _collect_pairs(def: PartDef, cell: Vector3i, basis: Basis) -> Array:
	var clean := snap_basis(basis)
	var placement := cell_transform(def, cell, clean)
	var pairs := []
	var used := {}
	for c in cells_of(def, clean, cell):
		for dir in VoxShapes.AXIS_DIRS:
			# 两边都要"这一格真的露出够大的面"才算一对连接 —— 只按零件级连接面记账，
			# 会让下移过的轮轴在下探那一排格子上凭空多出连接点（撞"一对多"就是这么来的）
			if not claims_face(def, clean, placement, c, dir):
				continue
			if face_is_internal(def, placement, c, dir):
				continue  # 自己身体里的面（对面也压着本零件自己的几何）
			var my_face := face_id(c, dir)
			if used.has(my_face):
				continue
			for neighbour: Dictionary in entries_at(c + dir):
				var other: PartDef = _defs_cache.get(neighbour["part_id"])
				if other == null:
					continue
				if not claims_face(
					other, neighbour["basis"], neighbour["transform"], c + dir, -dir
				):
					continue
				var their_face := face_id(c + dir, -dir)
				# ⚠️ 这里**不再**因为"账本里这对小面已经有人占着"就跳过 —— 账本的小面 key
				# 不带零件身份，同一格里挤着两个零件时，第二个零件那条连接会被它挡掉，
				# 于是"几何上明明贴着，却被判成没连上"（用户报的假警报）。
				# 账本（links/link_parts）照旧写（后写的覆盖先写的，测试守着"一对一面"这条）；
				# 连通性/毁伤读的是 `_neighbours`（按零件身份、允许多对，见 `_link()`）。
				used[my_face] = true
				pairs.append({
					"mine": my_face,
					"theirs": their_face,
					"theirs_entry": neighbour,
				})
				break
	return pairs


func set_defs(defs: Dictionary) -> void:
	_defs_cache = defs
	_volumes.clear()
	_solids.clear()
	_full_cube.clear()
	_mirror_fold.clear()
	_body_anchor.clear()
	_totals_dirty = true


## 进测试场的前置条件：装了核心，并且**所有零件都和核心连通**。
## 连通性走 `link_pairs()`（**按几何现算**，不看连接账本 —— 理由见那边）。
## 返回 {ok, reason, has_core, parts, connected, detached: Array[cell]}
func robot_status() -> Dictionary:
	var core_index := -1
	for i in parts.size():
		var def: PartDef = _defs_cache.get(parts[i]["part_id"])
		if def != null and def.is_core:
			core_index = i
			break
	if parts.is_empty():
		return {"ok": false, "reason": "场上没有零件", "has_core": false, "parts": 0, "connected": 0, "detached": []}
	if core_index < 0:
		return {
			"ok": false, "reason": "还没有装核心", "has_core": false,
			"parts": parts.size(), "connected": 0, "detached": [],
		}
	var parent := []
	parent.resize(parts.size())
	for i in parts.size():
		parent[i] = i
	for pair in link_pairs():
		_union(parent, int(pair[0]), int(pair[1]))
	var root := _find(parent, core_index)
	var connected := 0
	var detached := []
	for i in parts.size():
		if _find(parent, i) == root:
			connected += 1
		else:
			detached.append(parts[i]["origin"])
	var result := {
		"ok": detached.is_empty(),
		"has_core": true,
		"parts": parts.size(),
		"connected": connected,
		"detached": detached,
	}
	result["reason"] = "" if detached.is_empty() else "有 %d 个零件没和核心连在一起" % detached.size()
	return result


## 零件**连通图**（相邻表）：`[[i, j], ...]`，i/j 是 `parts` 里的下标。
##
## 读的是 `_neighbours`（**按零件身份**记的邻接，落子/拆除时增量维护）。
## 为什么不用 `links` / `link_parts` 那本"格子 + 方向"的账本：它一个 key 只能记一对连接，
## 同一格挤两个零件时会漏记、拆除时还会连带删掉别人的条目 —— 于是出现"建造模式说
## 有零件没连上、存盘进测试场却没事"这种假警报（用户报的）。判据本身还是几何的，
## 只是**在落子那一刻算好**（`_collect_pairs()` 的结果），不是每次重扫全场。
## 复杂度 O(零件数 + 连接数)。
##
## `robot_status()`（能不能进测试场）和毁伤判定（scripts/vehicle_state.gd 的"溢流均分 +
## 断开就死"）都走这一张图，不会各算各的。
func link_pairs() -> Array:
	var index_of_id := {}
	for i in parts.size():
		index_of_id[int(parts[i]["id"])] = i
	var out := []
	var seen := {}
	for i in parts.size():
		for other_id in _neighbours.get(int(parts[i]["id"]), []):
			var j: int = int(index_of_id.get(int(other_id), -1))
			if j < 0 or j == i:
				continue
			var key := "%d-%d" % [mini(i, j), maxi(i, j)]
			if seen.has(key):
				continue
			seen[key] = true
			out.append([i, j])
	return out


## 记一条"按零件身份"的邻接（双向、去重）。落子时由 `_commit()` 调。
func _link(a: int, b: int) -> void:
	if a == b:
		return
	for pair in [[a, b], [b, a]]:
		var key := int(pair[0])
		var value := int(pair[1])
		if not _neighbours.has(key):
			_neighbours[key] = []
		var list: Array = _neighbours[key]
		if not list.has(value):
			list.append(value)


## 断开一个零件的邻接。**只动它自己的记录**（旧账本会连别人的条目一起删，见字段注释）。
func _unlink(entry: Dictionary) -> void:
	var id := int(entry.get("id", -1))
	if id < 0 or not _neighbours.has(id):
		return
	for other in (_neighbours[id] as Array):
		var list: Variant = _neighbours.get(int(other), null)
		if list is Array:
			(list as Array).erase(id)
	_neighbours.erase(id)


## 场上这些零件的重心（建造模式现场看重心用）：口径和 `VehicleDef.center_of_mass()` 完全一致，
## 因为两边都调 `VehicleDef.weighted_center_of_mass()` —— 只有一处实现，不会"改一处忘一处"。
func center_of_mass(defs: Dictionary) -> Vector3:
	var list := []
	for entry: Dictionary in parts:
		list.append({
			"part_id": entry["part_id"], "cell": entry["origin"], "basis": entry["basis"],
		})
	return VehicleDef.weighted_center_of_mass(list, defs)


static func _find(parent: Array, i: int) -> int:
	var root := i
	while parent[root] != root:
		root = parent[root]
	while parent[i] != root:  # 路径压缩
		var next: int = parent[i]
		parent[i] = root
		i = next
	return root


static func _union(parent: Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[rb] = ra


## 零件在本地空间里的实体块：本体网格 + 附属子模型（轮体）。
## 每块 = {volume: VoxVolume, origin: Vector3}，origin 是网格原点在零件本地空间的位置。
## 碰撞 / 射线都用这张表，所以子模型一样算碰撞体积。
func _solids_of(part_id: String) -> Array:
	if _solids.has(part_id):
		return _solids[part_id]
	var out := []
	var def: PartDef = _defs_cache.get(part_id)
	var volume := _volume_of(part_id)
	if volume != null and def != null:
		var origin := -Vector3(def.model_pad) / float(VoxVolume.VOXELS_PER_CUBE)
		out.append({
			"volume": volume,
			"origin": origin,
			"box": PartDef.tight_bounds(volume, origin, Vector3(def.cubes)),
		})
	if def != null:
		var sub := def.sub_model_volume()
		if sub != null:
			var off := def.sub_model_offset()
			out.append({
				"volume": sub, "origin": off, "box": PartDef.tight_bounds(sub, off, Vector3.ONE),
			})
	_solids[part_id] = out
	return out


func _volume_of(part_id: String) -> VoxVolume:
	if _volumes.has(part_id):
		return _volumes[part_id]
	var def: PartDef = _defs_cache.get(part_id)
	var volume: VoxVolume = def.build_volume() if def != null else null
	_volumes[part_id] = volume
	return volume


func _is_full_cube_part(part_id: String) -> bool:
	if _full_cube.has(part_id):
		return _full_cube[part_id]
	var volume := _volume_of(part_id)
	var def: PartDef = _defs_cache.get(part_id)
	# 带附属子模型的零件不能走"格子级快路径"，否则轮胎会被整块跳过
	var full := (
		volume != null
		and volume.solid_count() == volume.data.size()
		and (def == null or not def.is_wheel())
	)
	_full_cube[part_id] = full
	return full


## 在单个格子内做体素级命中（1/16 精度）。
## 零件本体和附属子模型（轮体）都要试一遍，挑最近的命中 —— 不然能"透过轮胎"瞄准。
## 非满方块零件的**虚空部分直接穿过去** —— 三角块被斜切掉的那角不该有指向判定。
## 只有命中的体素面落在**格子外表的平面**上时，才把它的法线当作可建造方向；
## 打到斜切台阶就返回 dir = ZERO（不可建造）。
func _raycast_part_voxels(
	origin: Vector3, dir: Vector3, part: Dictionary, entry_dir: Vector3i, entry_t: float
) -> Dictionary:
	var best: Dictionary = {"hit": false}
	for solid: Dictionary in _solids_of(part["part_id"]):
		var hit := _raycast_solid_voxels(origin, dir, part, solid, entry_dir, entry_t)
		if not hit.get("hit", false):
			continue
		if not best.get("hit", false) or float(hit["t"]) < float(best["t"]):
			best = hit
	return best


## 单个实体块（本体或子模型）的体素步进。
func _raycast_solid_voxels(
	origin: Vector3,
	dir: Vector3,
	part: Dictionary,
	solid: Dictionary,
	entry_dir: Vector3i,
	entry_t: float
) -> Dictionary:
	var volume: VoxVolume = solid["volume"]
	var solid_origin: Vector3 = solid["origin"]
	var def: PartDef = _defs_cache.get(part["part_id"])
	var transform: Transform3D = part["transform"]
	var inv := transform.affine_inverse()
	# 从**进入这个格子**的那一点开始步进（不能用射线原点：那还在上一个空格里）
	var start := origin + dir * entry_t
	# 局部坐标（1 格 = 1）-> 体积索引：索引 = (本地 - solid_origin) * 16。
	# 本体那块的 solid_origin = -pad/16，所以这里等价于"本地 * 16 + pad"；
	# 轮体那块的 solid_origin 就是挂载偏移。漏掉这一步就会把零件整体看歪几像素。
	var lo := (inv * start - solid_origin) * 16.0
	var ld := inv.basis * dir
	if ld.length_squared() < 0.000001:
		return {"hit": false}
	lo += ld.normalized() * 0.05  # 往里挪一点，别卡在格子边界上
	var voxel := Vector3i(floori(lo.x), floori(lo.y), floori(lo.z))
	# 这一格在索引空间的范围（格子边界落在 solid_origin + 本地整数 上）
	var base_offset := (solid_origin * 16.0).round()
	var base := Vector3i(
		_cell_base(voxel.x, int(base_offset.x)),
		_cell_base(voxel.y, int(base_offset.y)),
		_cell_base(voxel.z, int(base_offset.z))
	)
	var normal := Vector3i((inv.basis * Vector3(entry_dir)).round())
	var step := Vector3i(_step_of(ld.x), _step_of(ld.y), _step_of(ld.z))
	var t_delta := Vector3(
		INF if step.x == 0 else absf(1.0 / ld.x),
		INF if step.y == 0 else absf(1.0 / ld.y),
		INF if step.z == 0 else absf(1.0 / ld.z)
	)
	var t_max := Vector3(
		INF if step.x == 0 else ((float(voxel.x) + (1.0 if step.x > 0 else 0.0)) - lo.x) / ld.x,
		INF if step.y == 0 else ((float(voxel.y) + (1.0 if step.y > 0 else 0.0)) - lo.y) / ld.y,
		INF if step.z == 0 else ((float(voxel.z) + (1.0 if step.z > 0 else 0.0)) - lo.z) / ld.z
	)
	for _i in range(80):
		var inside_volume := (
			voxel.x >= 0
			and voxel.y >= 0
			and voxel.z >= 0
			and voxel.x < volume.size.x
			and voxel.y < volume.size.y
			and voxel.z < volume.size.z
		)
		if inside_volume and volume.is_solid(voxel.x, voxel.y, voxel.z):
			var axis := VoxMesher.axis_of(normal)
			# 命中面所在的平面在本地坐标里落在整数上才叫"格子外表面"（斜切台阶不算）。
			# 用平面位置而不是 posmod(索引, 16)：索引和格子边界差着 solid_origin。
			var plane_index := voxel[axis] + (1 if normal[axis] > 0 else 0)
			var plane_local := float(plane_index) / 16.0 + solid_origin[axis]
			var on_face := is_equal_approx(plane_local, roundf(plane_local))
			var world_dir := Vector3i((transform.basis * Vector3(normal)).round())
			# 顺便把命中距离算出来（同一格里可能有多个零件，射线要挑最近的那个）
			var axis_vec := Vector3.ZERO
			axis_vec[axis] = 1.0
			var world_normal := transform.basis * axis_vec
			var denom := dir.dot(world_normal)
			var hit_t := -1.0
			if absf(denom) > 0.000001:
				var plane_point := transform * (axis_vec * plane_local)
				hit_t = (plane_point - origin).dot(world_normal) / denom
			return {
				"hit": true,
				"dir": world_dir if on_face else Vector3i.ZERO,
				"voxel": voxel,
				"t": maxf(0.0, hit_t),
			}
		if t_max.x <= t_max.y and t_max.x <= t_max.z:
			voxel.x += step.x
			t_max.x += t_delta.x
			normal = Vector3i(-step.x, 0, 0)
		elif t_max.y <= t_max.z:
			voxel.y += step.y
			t_max.y += t_delta.y
			normal = Vector3i(0, -step.y, 0)
		else:
			voxel.z += step.z
			t_max.z += t_delta.z
			normal = Vector3i(0, 0, -step.z)
		# 走出这个格子就没必要继续了（虚空 -> 让射线穿过去）
		if (
			voxel.x < base.x
			or voxel.y < base.y
			or voxel.z < base.z
			or voxel.x >= base.x + 16
			or voxel.y >= base.y + 16
			or voxel.z >= base.z + 16
		):
			break
	return {"hit": false}


## 射线步进。返回 {type: "part"/"floor"/"none", cell, dir, position, distance}
## part 命中：cell = 被击中的格子，dir = 进入该格子时穿过的面的外法线
## floor 命中：cell = 虚拟格子 (x, -1, z)，dir = UP
func raycast(origin: Vector3, direction: Vector3, max_distance := 256.0) -> Dictionary:
	var dir := direction.normalized()
	if dir == Vector3.ZERO:
		return {"type": "none"}
	var cell := Vector3i(floori(origin.x), floori(origin.y), floori(origin.z))
	if cells.has(cell):
		return {
			"type": "part",
			"cell": cell,
			"part_id": entries_at(cell)[0]["part_id"],
			"dir": Vector3i.ZERO,
			"position": origin,
			"distance": 0.0,
		}
	var step := Vector3i(_step_of(dir.x), _step_of(dir.y), _step_of(dir.z))
	var t_delta := Vector3(
		INF if step.x == 0 else absf(1.0 / dir.x),
		INF if step.y == 0 else absf(1.0 / dir.y),
		INF if step.z == 0 else absf(1.0 / dir.z)
	)
	var t_max := Vector3(
		INF if step.x == 0 else ((float(cell.x) + (1.0 if step.x > 0 else 0.0)) - origin.x) / dir.x,
		INF if step.y == 0 else ((float(cell.y) + (1.0 if step.y > 0 else 0.0)) - origin.y) / dir.y,
		INF if step.z == 0 else ((float(cell.z) + (1.0 if step.z > 0 else 0.0)) - origin.z) / dir.z
	)
	var t := 0.0
	var entered := Vector3i.ZERO
	var guard := 0
	while t <= max_distance and guard < 4096:
		guard += 1
		if t_max.x <= t_max.y and t_max.x <= t_max.z:
			t = t_max.x
			cell.x += step.x
			t_max.x += t_delta.x
			entered = Vector3i(-step.x, 0, 0)
		elif t_max.y <= t_max.z:
			t = t_max.y
			cell.y += step.y
			t_max.y += t_delta.y
			entered = Vector3i(0, -step.y, 0)
		else:
			t = t_max.z
			cell.z += step.z
			t_max.z += t_delta.z
			entered = Vector3i(0, 0, -step.z)
		if t > max_distance:
			break
		if cells.has(cell):
			# 一个格子里可能有多个零件（共享格子）：逐个试，挑**最近**的那个
			var best: Dictionary = {}
			var best_t := INF
			for part: Dictionary in entries_at(cell):
				if _is_full_cube_part(part["part_id"]):
					if t < best_t:
						best_t = t
						best = {"part_id": part["part_id"], "dir": entered, "voxel": null}
					continue
				# 非满方块：按实际体素判定，虚空直接穿过
				var voxel_hit := _raycast_part_voxels(origin, dir, part, entered, t)
				if not voxel_hit.get("hit", false):
					continue
				var voxel_t: float = voxel_hit.get("t", t)
				if voxel_t < best_t:
					best_t = voxel_t
					best = {
						"part_id": part["part_id"],
						"dir": voxel_hit["dir"],
						"voxel": voxel_hit["voxel"],
					}
			if not best.is_empty():
				var result := {
					"type": "part",
					"cell": cell,
					"part_id": best["part_id"],
					"dir": best["dir"],
					"position": origin + dir * best_t,
					"distance": best_t,
				}
				if best.get("voxel") != null:
					result["voxel"] = best["voxel"]
				return result
			# 全场都没打中：继续往下一格走
	if dir.y < -0.0001:
		var t_floor := (0.0 - origin.y) / dir.y
		if t_floor >= 0.0 and t_floor <= max_distance:
			var p := origin + dir * t_floor
			if absf(p.x) <= FLOOR_EXTENT and absf(p.z) <= FLOOR_EXTENT:
				return {
					"type": "floor",
					"cell": Vector3i(floori(p.x), -1, floori(p.z)),
					"dir": Vector3i.UP,
					"position": p,
					"distance": t_floor,
				}
	return {"type": "none"}


static func _step_of(v: float) -> int:
	if v > 0.0:
		return 1
	if v < 0.0:
		return -1
	return 0


## 索引空间里"包含 index 的那一格"的起始索引（格子边界在 pad + k * 16 上）。
static func _cell_base(index: int, pad: int) -> int:
	return index - posmod(index - pad, VoxVolume.VOXELS_PER_CUBE)
