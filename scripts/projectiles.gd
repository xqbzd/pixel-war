@tool
class_name Projectiles
extends Node3D

## 射弹管理：池化的点状弹丸 + 逐帧弹道 + **连续**碰撞检测（一段一段打射线，
## 所以子弹再快也不会"穿过"薄墙）。
##
## 弹道只受重力（`Ballistics.advance()`）：出膛速度来自部件文件（真实 m/s）换算成格/秒。
## 命中判定：
##   * 打到**自己的车体**（`own_rid`）→ 子弹**直接消失**、**不造成伤害**（`hit` 不发），
##     但会放一个命中小爆炸 —— 用户 2026-10-14 改的：抛物线和散射让子弹有机会绕回来
##     打到自己，要看得见它打在自己哪儿（调枪口 / 射界 / 贴脸自吃时全靠它）；
##   * 打到别的碰撞体 → 记一发命中（伤害现在还没有接收方）、放一个小的命中火花。
##
## 视觉：每个弹丸是一个沿速度方向拉长的小方块（曳光弹），长度随速度变；
## 节点是**池化**的（`MAX_LIVE` 个），所以射速再高也只是复用节点，不会一直 new。

## 同屏最多多少发（超了就丢最老的那发）
const MAX_LIVE := 256
## 一发子弹的默认寿命（秒）：真正的值来自**武器部件的 `weapon_projectile_life`**，
## 这个常量只是没传 life 时的兜底。射速 × 寿命 = 同屏最多几发。
const DEFAULT_LIFE_SECONDS := 8.0
## 曳光弹的粗细（格）：**2 体素 = 0.125 格**（1 体素 = 1/16 格）。## 取 2 体素是跟**枪口那截枪管一样粗**（轻机枪的枪管是 2×2 体素的细管），
## 看着就像子弹从枪口里出来；再粗就挡视线了。
const TRACER_WIDTH := 2.0 / 16.0
## 曳光弹的**最短**长度（格）：子弹慢 / 刚出膛（这一步还没走远）时也不至于缩成看不见的点。
## 最长的**不设上限** —— 见 `_place_tracer()`：光带要盖住整条走过的线段。
const TRACER_MIN_LENGTH := 0.25
## **命中那一下**的光带最短长度（格）：命中的位置常常只离上一帧零点几格，
## 那样画出来的"方块"和它自己的粗细（0.125 格）差不多长。所以命中这一段**尖端锚定**：头落在命中点上，
## 长度不够就顺着弹道往回拉这么长，仍然是条光带。
const TRACER_HIT_MIN_LENGTH := 1.2
## 幽灵光带的**合并距离**（格）：连着命中同一处时，新幽灵离已有幽灵的命中点这么近就**只续命、不叠一条**。
## 用户报的"最末一段突然变粗"实测就是这个：600 rpm 两挺机枪打同一个点，一次抓到 **4 条光带挤在 3 格内**
## （L=6.9 / 11.5 / 1.2 / 1.2）—— 弹道本身各段粗细是完全一致的（测试直接量了横截面）。
const GHOST_MERGE_DISTANCE := 1.5
## 命中那一截光带额外留多久（秒）：命中点离枪口很近时，子弹在**同一帧**就没了，
## 不留这一会儿就完全看不到弹道（用户报的"开火到命中很近就不会出现射弹轨迹"）。
## 0.05 秒 ≈ 6 帧，够看清那一段。
const TRACER_GHOST_LIFE := 0.05
## 命中爆炸：小球先胀后缩（峰值 = 半径 × PEAK），够小但看得见
const IMPACT_RADIUS := 0.14
const IMPACT_LIFE := 0.18
const IMPACT_PEAK := 2.6

var gravity := PartDef.GRAVITY_CUBES  # 世界重力（格/秒²），测试场按 project.godot 传进来
var layers := 1            # 子弹能打到哪些碰撞层
## 开火者键 -> 其车体的 RID：子弹打回**自己的车**时直接"吃掉"（不造成伤害，但会放命中小爆炸）。
## 每个键可以是一台车（玩家/某个靶子），以后敌人开火也是往这里加一条。
var owner_rids := {}

## 子弹打到了**别人的**碰撞体（自己的车体不会走这条，见 owner_rids）。
## body_rid = 打中的物理体；shape_index = 它身上的第几个碰撞盒（载具用它反查零件）；
## damage = 这一发的净伤害；owner_key = 谁打的。火花已经在 Projectiles 里放过了。
signal hit(body_rid: RID, shape_index: int, position: Vector3, damage: float, owner_key: String)

var _bullets := []         # [{position, velocity, age, damage, node}]
var _free_bullets := []    # 池子（空闲的曳光弹节点）
var _ghosts := []          # 命中那一下的最后一段光带（[{node, age}]，见 TRACER_GHOST_LIFE）
var _impacts := []         # [{node, age, life, peak}] 命中爆炸
var _free_impacts := []
var _no_exclude: Array[RID] = []   # 打射线用：不排除任何东西（自己的车体也要能被打到）
var _rng := RandomNumberGenerator.new()
var _tracer_mesh: BoxMesh   # 所有曳光弹共用（懒创建，见 `_make_tracer()`）
var _hits := 0             # 累计命中别的碰撞体的次数（HUD / 调试用）
var _eaten := 0            # 累计被自己车体吃掉的次数


func _ready() -> void:
	_rng.randomize()


## 每帧调一次（物理帧）：把在飞的都推进一步。要先把 `layers` / `own_rid` 设好。
func step(delta: float, space: PhysicsDirectSpaceState3D) -> void:
	var index := _bullets.size() - 1
	while index >= 0:
		var bullet: Dictionary = _bullets[index]
		bullet["age"] = float(bullet["age"]) + delta
		var moved := Ballistics.advance(
			bullet["position"], bullet["velocity"], gravity, delta
		)
		if float(bullet["age"]) > float(bullet["life"]):
			_retire(index)
			index -= 1
			continue
		var from: Vector3 = bullet["position"]
		var to: Vector3 = moved["position"]
		var hit_result := _cast(from, to, space)
		if not hit_result.is_empty():
			# 命中：把"上一帧位置 → 命中点"这**一段也画出来**（命中点很近时，
			# 这一帧就是最后一帧，不画就完全看不到弹道），并让这截光带多留一会儿。
			# 最短给到 `TRACER_HIT_MIN_LENGTH`（往回拉），不然命中点近的时候会短成一个方块。
			_place_tracer(bullet, from, hit_result["position"], TRACER_HIT_MIN_LENGTH)
			_spawn_tracer_ghost(bullet["node"], hit_result["position"])
			_bullets.remove_at(index)   # 节点交给"幽灵"列表，不走 _retire（那个会立刻隐藏）
			index -= 1
			var collider: Object = hit_result.get("collider")
			var hit_rid := RID()
			if collider is CollisionObject3D:
				hit_rid = (collider as CollisionObject3D).get_rid()
			# 处置见 `hit_plan()`：打到自己 = **只放特效、不结算伤害**（用户 2026-10-14 的要求）
			var plan := hit_plan(owner_rids, str(bullet.get("owner", "")), hit_rid)
			if bool(plan["impact"]):
				_spawn_impact(hit_result["position"])
			if bool(plan["self"]):
				_eaten += 1
			else:
				_hits += 1
				hit.emit(
					hit_rid,
					int(hit_result.get("shape", -1)),
					hit_result["position"],
					float(bullet["damage"]),
					str(bullet.get("owner", ""))
				)
			continue
		bullet["position"] = to
		bullet["velocity"] = moved["velocity"]
		_place_tracer(bullet, from, to)
		index -= 1
	_update_flashes(delta)
	_update_ghosts(delta)


## 命中那一下的最后一段光带：留 `TRACER_GHOST_LIFE` 秒，然后回收给曳光弹池复用。
##
## ⚠️ **同一处的连续命中不能叠**：600 rpm 两挺机枪打同一个点，以前是每一发都留一条幽灵，
## 一次能抓到 4 条光带挤在 3 格内（实测 L=6.9 / 11.5 / 1.2 / 1.2），看着就是"最末一段突然变粗、
## 像判定了好几次"（用户报的，而且弹道本身各段粗细是一致的 —— 有横截面测试量过）。
## 所以新幽灵离已有幽灵的**命中点**小于 `GHOST_MERGE_DISTANCE` 时：只给旧的那条**续命**
## （这一处仍是"刚命中"），新节点立刻还回池子，不再叠一条。
func _spawn_tracer_ghost(node: MeshInstance3D, tip: Vector3) -> void:
	if node == null or not is_instance_valid(node):
		return
	for ghost: Dictionary in _ghosts:
		if (ghost["tip"] as Vector3).distance_to(tip) > GHOST_MERGE_DISTANCE:
			continue
		ghost["age"] = 0.0          # 续命：这条光带继续代表"这一处刚命中"
		node.visible = false
		_free_bullets.append(node)
		return
	_ghosts.append({"node": node, "age": 0.0, "tip": tip})


func _update_ghosts(delta: float) -> void:
	var i := _ghosts.size() - 1
	while i >= 0:
		var ghost: Dictionary = _ghosts[i]
		var age := float(ghost["age"]) + delta
		var node: MeshInstance3D = ghost["node"]
		if age >= TRACER_GHOST_LIFE:
			if node != null and is_instance_valid(node):
				node.visible = false
				_free_bullets.append(node)
			_ghosts.remove_at(i)
		else:
			ghost["age"] = age
		i -= 1


## 命中爆炸：先"砰"地胀开、再缩回去。
## 膨胀期占前 35%，所以一帧内就有明显变化；缩到 0 就是消失（不玩透明度，省一份材质）。
func _update_flashes(delta: float) -> void:
	var i := _impacts.size() - 1
	while i >= 0:
		var effect: Dictionary = _impacts[i]
		var age := float(effect["age"]) + delta
		if age >= float(effect["life"]):
			var node: MeshInstance3D = effect["node"]
			if node != null and is_instance_valid(node):
				node.visible = false
				_free_impacts.append(node)
			_impacts.remove_at(i)
		else:
			effect["age"] = age
			var t := age / float(effect["life"])
			var k := t / 0.35 if t < 0.35 else (1.0 - (t - 0.35) / 0.65)
			(effect["node"] as MeshInstance3D).scale = Vector3.ONE * maxf(0.01, k * float(effect["peak"]))
		i -= 1


## 打一发。origin 已经在车体外面（枪口沿枪轴外推过），所以第一段射线不会立刻打到自己。
## `tracer_start` = **真枪口的位置**：第一段光带从它拉到 origin，近身也看得见弹道
## （传 ZERO 就退化成 origin 上的一个短点）。物理判定仍然从 origin 开始，不会打到自己。
## `life` = 这一发的寿命（秒），来自武器部件的 `weapon_projectile_life`。
## `inherit_velocity` = 车体速度（子弹跟着车走，物理上对；不想要就传 0）。
## 返回 false 表示池子满 / 参数不对（这一发丢了）。
func fire(
	origin: Vector3, direction: Vector3, speed: float, spread_deg: float,
	damage: float, life := DEFAULT_LIFE_SECONDS, inherit_velocity := Vector3.ZERO,
	owner_key := "", tracer_start := Vector3.ZERO
) -> bool:
	if speed <= 0.0 or direction.length() < 0.001:
		return false
	if _bullets.size() >= MAX_LIVE:
		_retire(0)
	var velocity := Ballistics.spread_direction(direction, spread_deg, _rng) * speed
	velocity += inherit_velocity
	# 池子里取一个（`pop_back()` 返回 Variant，所以要写显式类型；本项目把
	# "从 Variant 推断类型"当成错误）
	var node: MeshInstance3D = (
		_free_bullets.pop_back() if not _free_bullets.is_empty() else _make_tracer()
	)
	if node == null:
		return false
	node.visible = true
	var bullet := {
		"position": origin, "velocity": velocity, "age": 0.0, "damage": damage, "node": node,
		"life": maxf(0.05, life), "owner": owner_key,
	}   # {position, velocity, age, damage, life, node}
	# 刚出膛：光带从**真枪口**拉到子弹的生成点（枪口沿轴外推过的那 1 格），
	# 所以近身也看得见"从枪管里出来"的那一段；没给枪口就退化成一个小点。
	var visual_from: Vector3 = tracer_start if tracer_start != Vector3.ZERO else origin
	_place_tracer(bullet, visual_from, origin)
	_bullets.append(bullet)
	return true


func live_count() -> int:
	return _bullets.size()


## 命中别的碰撞体的累计次数 / 被自己车体吃掉的累计次数（HUD 和调试用）。
func counters() -> Vector2i:
	return Vector2i(_hits, _eaten)


func _cast(from: Vector3, to: Vector3, space: PhysicsDirectSpaceState3D) -> Dictionary:
	if space == null or from.distance_squared_to(to) < 0.000001:
		return {}
	# 不排除任何 RID：自己的车体也要能被打到（打到就吃掉，见 step()）
	var query := PhysicsRayQueryParameters3D.create(from, to, layers, _no_exclude)
	return space.intersect_ray(query)


## 曳光弹 = **这一帧走过的整条线段**（上一帧的位置 → 这一帧的位置，整段点亮）。
## 朝向取位移方向、粗细不跟着放大；**尖端（`to`）永远落在子弹/命中点上** ——
## 段太短就按 `min_length` 往回拉，免得短成一个"和粗细一样宽的方块"。
##
## 以前是"固定长度、夹在 1.5 格以内"：子弹一快（600 m/s ≈ 3000 格/秒，一帧走 25 格）
## 那 1.5 格的光几乎就是个点，看着"子弹太不显眼"（用户报的）。现在光带长度 = 这一帧的位移，
## 位置取线段中点、朝向取速度方向，所以正好覆盖这一帧扫过的路径 —— 高速时就是一条明亮的光线。
func _place_tracer(
	bullet: Dictionary, from: Vector3, to: Vector3, min_length := TRACER_MIN_LENGTH
) -> void:
	var node: MeshInstance3D = bullet["node"]
	var velocity: Vector3 = bullet["velocity"]
	var travel := to - from
	var direction := travel.normalized() if travel.length() > 0.001 else velocity.normalized()
	if direction.length() < 0.001:
		return
	# 长轴指向这一帧的位移方向（looking_at 的 -Z 对准 direction），长度 = 这一步走了多远
	var length := maxf(travel.length(), min_length)
	var tracer_basis := Basis.looking_at(direction, Vector3.UP)
	# ⚠️ 必须用 `scaled_local()`（沿**本地**轴拉伸）—— `Basis.scaled()` 是**全局**缩放
	# （沿世界轴），斜着飞的时候光带会被拉成歪的：看着像子弹"横着打出去"（用户报的）。
	# 网格的 x/y 已经是 TRACER_WIDTH、z 是 1，所以只需要把本地 z 缩到 length。
	# 位置 = 从 `to` 往回退半段：长度正好等于位移时它就是线段中点；被 min_length 拉长时
	# 就是"顺着弹道往回延伸"，尖端仍然贴在 `to` 上。
	node.transform = Transform3D(
		tracer_basis.scaled_local(Vector3(1.0, 1.0, length)), to - direction * (length * 0.5)
	)


func _make_tracer() -> MeshInstance3D:
	# 所有曳光弹共用一个网格（省一点内存/实例化开销）：长轴 = z，长度靠节点缩放
	if _tracer_mesh == null:
		_tracer_mesh = BoxMesh.new()
		_tracer_mesh.size = Vector3(TRACER_WIDTH, TRACER_WIDTH, 1.0)
	var node := MeshInstance3D.new()
	node.mesh = _tracer_mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.85, 0.35)
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


## 命中时的处置（纯函数，测试直接打它）：`owner_rows` = `owner_rids`，
## `owner_key` = 这一发是谁打的，`hit_rid` = 打中的物理体。
## 返回 {self, impact, damage}：
##   * 打到自己车体（`self`）→ **impact = true, damage = false** ——
##     用户 2026-10-14 的要求：不造成伤害，但**要放命中小爆炸**（看得见这一发打在自己哪儿，
##     调枪口 / 射界 / 贴脸自吃时全靠它）；
##   * 打到别人（或有登记的 owner 都没匹配上）→ damage = true（走 `hit` 信号结算）。
static func hit_plan(owner_rows: Dictionary, owner_key: String, hit_rid: RID) -> Dictionary:
	var own: Variant = owner_rows.get(owner_key)
	var is_self: bool = own != null and hit_rid == own
	return {"self": is_self, "impact": true, "damage": not is_self}


## 在某个位置放一个命中小爆炸（玩家贴脸自吃时，测试场要指定放哪儿，所以做成公开的）。
func spawn_impact(at: Vector3) -> void:
	_spawn_impact(at)


func _spawn_impact(at: Vector3) -> void:
	var node: MeshInstance3D = (
		_free_impacts.pop_back() if not _free_impacts.is_empty() else _make_impact()
	)
	if node == null:
		return
	node.visible = true
	node.global_position = at
	node.scale = Vector3.ONE
	_impacts.append({"node": node, "age": 0.0, "life": IMPACT_LIFE, "peak": IMPACT_PEAK})




func _make_impact() -> MeshInstance3D:
	var node := _make_blob(IMPACT_RADIUS, Color(1.0, 0.75, 0.3))
	add_child(node)
	return node


## 光效小球（开火闪光 / 命中爆炸共用）：自发光感的纯色球，不投影、不打光。
func _make_blob(radius: float, colour: Color) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 6
	sphere.rings = 3
	var node := MeshInstance3D.new()
	node.mesh = sphere
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = colour
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


func _retire(index: int) -> void:
	var bullet: Dictionary = _bullets[index]
	var node: MeshInstance3D = bullet["node"]
	if node != null and is_instance_valid(node):
		node.visible = false
		_free_bullets.append(node)
	_bullets.remove_at(index)
