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
## 弹头默认颜色（部件文件不写 `weapon_bullet_color` 时）：就是改这个参数之前的那个黄色。
## 曳光轨迹和弹着点火花都用它 —— 同一个颜色，一眼能看出是哪把枪打的。
const DEFAULT_BULLET_COLOR := PartDef.DEFAULT_BULLET_COLOR

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
## 子弹射线要**忽略**的刚体：每台车的车体（现在车体只有一个粗碰撞盒，零件级受击在
## `hitboxes` 那个静态体上）。不忽略的话子弹会打在"整车包围盒"上，判不到零件。
var ignore_rids: Array[RID] = []
## 命中过滤器（`TestField` 注入）：`(body_rid, shape_index, hit_position) -> bool`。
## 返回 false = 打中的是**已经不存在的零件**（受击盒几何没重建完），这一发应该穿过去。
var hit_filter: Callable
## 载具命中查询（`TestField` 注入）：`(from, to, exclude_rids) -> Dictionary`。
## 载具上已经没有受击 trimesh 了，子弹打零件靠**体素 DDA**（`VehicleRig.raycast_hit`）。
## 返回的字典和 `intersect_ray()` 对齐：{collider, shape:-1, position, normal}；没打中返回 {}。
var vehicle_query: Callable
var _rng := RandomNumberGenerator.new()
var _tracer_mesh: BoxMesh   # 所有曳光弹共用（懒创建，见 `_make_tracer()`）
var _hits := 0             # 累计命中别的碰撞体的次数（HUD / 调试用）
var _eaten := 0            # 累计被自己车体吃掉的次数


## 预热多少个曳光弹 / 命中特效节点：**开局就把节点建好（隐藏）**。
## 不预热的话，交火第一秒要边打边 new 网格/材质/渲染实例 —— 正好卡在"开局交火"那几秒
## （用户报的掉到二十多帧）。预热是纯分配，几毫秒，藏在出生那一下里。
const TRACER_PREWARM := 64
const IMPACT_PREWARM := 48


func _ready() -> void:
	_rng.randomize()
	for _i in TRACER_PREWARM:
		var tracer := _make_tracer()
		tracer.visible = false
		_free_bullets.append(tracer)
	for _i in IMPACT_PREWARM:
		var impact := _make_impact()
		impact.visible = false
		_free_impacts.append(impact)
	for _i in BEAM_PREWARM:
		var beam := _make_beam()
		beam.visible = false
		_free_beams.append(beam)


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
		var skip: Array = bullet.get("skip", [])
		var hit_result := _cast(from, to, space, skip)
		while not hit_result.is_empty() and not _hit_is_real(hit_result):
			hit_result = _pass_through(hit_result, skip, from, to, space)
		if not skip.is_empty():
			bullet["skip"] = skip
		if not hit_result.is_empty():
			var hit_position: Vector3 = hit_result["position"]
			# 飞行距离按**命中点**算（不是按这一帧走满的距离）：距离衰减用的是这个数
			bullet["travel"] = float(bullet["travel"]) + from.distance_to(hit_position)
			# 命中：把"上一帧位置 → 命中点"这**一段也画出来**（命中点很近时，
			# 这一帧就是最后一帧，不画就完全看不到弹道），并让这截光带多留一会儿。
			# 最短给到 `TRACER_HIT_MIN_LENGTH`（往回拉），不然命中点近的时候会短成一个方块。
			_place_tracer(bullet, from, hit_position, TRACER_HIT_MIN_LENGTH)
			_spawn_tracer_ghost(bullet["node"], hit_position)
			_bullets.remove_at(index)   # 节点交给"幽灵"列表，不走 _retire（那个会立刻隐藏）
			index -= 1
			var collider: Object = hit_result.get("collider")
			var hit_rid := RID()
			if collider is CollisionObject3D:
				hit_rid = (collider as CollisionObject3D).get_rid()
			# 处置见 `hit_plan()`：打到自己 = **只放特效、不结算伤害**（用户 2026-10-14 的要求）
			var plan := hit_plan(owner_rids, str(bullet.get("owner", "")), hit_rid)
			if bool(plan["impact"]):
				_spawn_impact(hit_position, bullet.get("color", DEFAULT_BULLET_COLOR))
			# 冲击冲量：命中刚体（载具/靶子）就把它推一下（地形是静态体，推不动）
			_push_target(collider, hit_position, bullet)
			if bool(plan["self"]):
				_eaten += 1
			else:
				_hits += 1
				hit.emit(
					hit_rid,
					int(hit_result.get("shape", -1)),
					hit_position,
					damage_before_impact(
						float(bullet["damage"]), float(bullet["falloff"]), float(bullet["travel"])
					),
					str(bullet.get("owner", ""))
				)
			continue
		bullet["travel"] = float(bullet["travel"]) + from.distance_to(to)
		bullet["position"] = to
		bullet["velocity"] = moved["velocity"]
		_place_tracer(bullet, from, to)
		index -= 1
	_update_flashes(delta)
	_update_ghosts(delta)
	_update_beams(delta)


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
## `bullet_spec` = **这一发弹头自己的参数**（都可以不写，见下面 `fire_bullet_spec()`）：
##   * `color`          Color：曳光轨迹 + 弹着点火花（默认 `DEFAULT_BULLET_COLOR`）
##   * `falloff`        float：每飞 100 米损失的伤害比例（见 `damage_before_impact()`）
##   * `impact_impulse` float：命中刚体时施加的冲量（kg·格/秒）
## 返回 false 表示池子满 / 参数不对（这一发丢了）。
func fire(
	origin: Vector3, direction: Vector3, speed: float, spread_deg: float,
	damage: float, life := DEFAULT_LIFE_SECONDS, inherit_velocity := Vector3.ZERO,
	owner_key := "", tracer_start := Vector3.ZERO, bullet_spec := {}
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
	var colour: Color = bullet_spec.get("color", DEFAULT_BULLET_COLOR)
	_tint(node, colour)
	var bullet := {
		"position": origin, "velocity": velocity, "age": 0.0, "damage": damage, "node": node,
		"life": maxf(0.05, life), "owner": owner_key,
		"travel": 0.0,                                # 已经飞了多少格（算距离衰减用）
		"falloff": maxf(0.0, float(bullet_spec.get("falloff", 0.0))),
		"impact_impulse": maxf(0.0, float(bullet_spec.get("impact_impulse", 0.0))),
		"color": colour,
	}   # {position, velocity, age, damage, life, node, owner, travel, falloff, impact_impulse, color}
	# 刚出膛：光带从**真枪口**拉到子弹的生成点（枪口沿轴外推过的那 1 格），
	# 所以近身也看得见"从枪管里出来"的那一段；没给枪口就退化成一个小点。
	var visual_from: Vector3 = tracer_start if tracer_start != Vector3.ZERO else origin
	_place_tracer(bullet, visual_from, origin)
	_bullets.append(bullet)
	return true


## ── 射线类武器（`weapon_projectile = ray`）─────────────────────────────────────
## **瞬间命中**：从枪口打一条射线，没有弹速 / 下坠 / 寿命，只有 `max_range`（最大射程）。
## 扩散（`spread_deg`）和距离伤害衰减（`damage_before_impact()`）照旧。
## 命中结算和普通子弹**完全一致**：同一个 `hit` 信号、命中小爆炸、冲击冲量、自吃判定。
## 尾迹是一条**半透明灰白色的线柱**（池化，`BEAM_LIFE` 秒内淡出）。
const BEAM_WIDTH := 0.16          # 线柱粗细（格）：太细在远处就看不见了
const BEAM_LIFE := 0.09           # 线柱停留多久（秒）
const BEAM_COLOUR := Color(0.90, 0.92, 0.95, 0.55)
const BEAM_PREWARM := 24

var _beams := []                  # [{node, age}]
var _free_beams := []
var _beam_mesh: BoxMesh


func fire_ray(
	space: PhysicsDirectSpaceState3D, origin: Vector3, direction: Vector3,
	spread_deg: float, damage: float, max_range: float, bullet_spec: Dictionary,
	owner_key: String
) -> bool:
	if space == null or direction.length() < 0.001 or max_range <= 0.0:
		return false
	var dir := Ballistics.spread_direction(direction, spread_deg, _rng)
	var end := origin + dir * max_range
	var skip: Array = []
	var hit_result := _cast(origin, end, space, skip)
	while not hit_result.is_empty() and not _hit_is_real(hit_result):
		hit_result = _pass_through(hit_result, skip, origin, end, space)
	var falloff := maxf(0.0, float(bullet_spec.get("falloff", 0.0)))
	var colour: Color = bullet_spec.get("color", DEFAULT_BULLET_COLOR)
	if not hit_result.is_empty():
		end = hit_result["position"]
		var travel := origin.distance_to(end)
		_spawn_impact(end, colour)
		var collider: Object = hit_result.get("collider")
		_push_target(
			collider, end,
			{"velocity": dir, "impact_impulse": float(bullet_spec.get("impact_impulse", 0.0))}
		)
		var hit_rid := RID()
		if collider is CollisionObject3D:
			hit_rid = (collider as CollisionObject3D).get_rid()
		var plan := hit_plan(owner_rids, owner_key, hit_rid)
		if bool(plan["self"]):
			_eaten += 1
		else:
			_hits += 1
			hit.emit(
				hit_rid, int(hit_result.get("shape", -1)), end,
				damage_before_impact(damage, falloff, travel), owner_key
			)
	_spawn_beam(origin, end)
	return true


## 一条射线尾迹：从 `from` 到 `to` 的细线柱（复用池子）。
func _spawn_beam(from: Vector3, to: Vector3) -> void:
	var length := from.distance_to(to)
	if length < 0.01:
		return
	var node: MeshInstance3D = (
		_free_beams.pop_back() if not _free_beams.is_empty() else _make_beam()
	)
	if node == null:
		return
	var direction := (to - from).normalized()
	node.visible = true
	_tint(node, BEAM_COLOUR)
	node.transform = Transform3D(
		Basis.looking_at(direction, Vector3.UP).scaled_local(Vector3(1.0, 1.0, length)),
		from + (to - from) * 0.5
	)
	_beams.append({"node": node, "age": 0.0})


func _make_beam() -> MeshInstance3D:
	if _beam_mesh == null:
		_beam_mesh = BoxMesh.new()
		_beam_mesh.size = Vector3(BEAM_WIDTH, BEAM_WIDTH, 1.0)
	var node := MeshInstance3D.new()
	node.mesh = _beam_mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = BEAM_COLOUR
	material.no_depth_test = false
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


## 尾迹淡出 + 回收（每物理帧一次）。
func _update_beams(delta: float) -> void:
	var index := _beams.size() - 1
	while index >= 0:
		var beam: Dictionary = _beams[index]
		beam["age"] = float(beam["age"]) + delta
		var node: MeshInstance3D = beam["node"]
		var t := clampf(1.0 - float(beam["age"]) / BEAM_LIFE, 0.0, 1.0)
		if node != null and is_instance_valid(node):
			var material := node.material_override as StandardMaterial3D
			if material != null:
				material.albedo_color = Color(
					BEAM_COLOUR.r, BEAM_COLOUR.g, BEAM_COLOUR.b, BEAM_COLOUR.a * t
				)
			if t <= 0.0:
				node.visible = false
				_free_beams.append(node)
				_beams.remove_at(index)
		else:
			_beams.remove_at(index)
		index -= 1


func live_count() -> int:
	return _bullets.size()


## 命中别的碰撞体的累计次数 / 被自己车体吃掉的累计次数（HUD 和调试用）。
func counters() -> Vector2i:
	return Vector2i(_hits, _eaten)


## 飞了 `distance_cubes` 格之后，这一发还剩多少伤害。
## `falloff_per_100m` = 部件文件的 `weapon_damage_falloff`：**每飞 100 米损失多少伤害比例**。
## 距离按真实米数算（`PartDef.CUBE_METERS`：1 格 = 0.5 米），所以 `0.1` 就是"每 200 格 -10%"。
## 夹在 0~1：飞过头就是 0 伤害（不会变成负数回血）。纯函数，测试直接打它。
static func damage_before_impact(
	damage: float, falloff_per_100m: float, distance_cubes: float
) -> float:
	if falloff_per_100m <= 0.0:
		return damage
	var metres := maxf(0.0, distance_cubes) * PartDef.CUBE_METERS
	var keep := clampf(1.0 - falloff_per_100m * metres / 100.0, 0.0, 1.0)
	return maxf(0.0, damage * keep)


## 把池化节点（曳光弹 / 火花共用池子）的材质染成这一发的颜色。
static func _tint(node: MeshInstance3D, colour: Color) -> void:
	var material := node.material_override as StandardMaterial3D
	if material != null:
		material.albedo_color = colour


## 冲击冲量：命中刚体就沿弹道方向推它一下（作用点在命中点，所以会带一点转动）。
## 静态地形 / 受击盒（StaticBody3D）推不动，直接跳过。0 = 不推。
func _push_target(collider: Object, at: Vector3, bullet: Dictionary) -> void:
	var impulse := impact_impulse_vector(
		collider, float(bullet.get("impact_impulse", 0.0)), bullet["velocity"]
	)
	if impulse == Vector3.ZERO:
		return
	(collider as RigidBody3D).apply_impulse(impulse, at - (collider as Node3D).global_position)


## 冲击冲量向量（纯函数，测试直接打它）：只有刚体、有速度方向、冲量 > 0 才推。
static func impact_impulse_vector(
	collider: Object, impulse: float, velocity: Vector3
) -> Vector3:
	if impulse <= 0.0 or not (collider is RigidBody3D):
		return Vector3.ZERO
	var direction := velocity.normalized()
	if direction.length() < 0.001:
		return Vector3.ZERO
	return direction * impulse


func _cast(
	from: Vector3, to: Vector3, space: PhysicsDirectSpaceState3D, skip: Array = []
) -> Dictionary:
	if space == null or from.distance_squared_to(to) < 0.000001:
		return {}
	# 排除所有车的**车体**（打零件走 `hitboxes` 那个静态体）；自己的车体也在里面，
	# 所以"打到自己"由 `hit_plan()` 用 owner_rids（车体 + 受击盒）判定。
	# `skip` = 这一发已经"穿过去"的刚体（打掉的零件还留在旧几何里时用，见 `step`）
	var exclude: Array = ignore_rids
	if not skip.is_empty():
		exclude = ignore_rids.duplicate()
		exclude.append_array(skip)
	var query := PhysicsRayQueryParameters3D.create(from, to, layers, exclude)
	var world_hit := space.intersect_ray(query)
	# 载具命中走**体素 DDA**（测试场注入的 `vehicle_query`），不走物理形状 ——
	# 载具身上已经没有受击 trimesh 了，物理射线只负责世界/地形/静态物。
	if vehicle_query.is_valid():
		var vehicle_hit: Dictionary = vehicle_query.call(from, to, exclude)
		if not vehicle_hit.is_empty():
			if world_hit.is_empty():
				return vehicle_hit
			var to_vehicle := from.distance_squared_to(vehicle_hit["position"])
			var to_world := from.distance_squared_to(world_hit["position"])
			if to_vehicle <= to_world:
				return vehicle_hit
	return world_hit


## 这一发打中的东西算不算"真命中"（`hit_filter` 由测试场注入）：
## 打到的是一块**已经不存在的零件**（受击盒 trimesh 还在 0.2 秒的重建冷却里）时，
## 子弹应该**穿过去**继续打后面的东西 —— 否则就是"虚空挡伤害"（用户 2026-10-19 报的）。
func _hit_is_real(hit_result: Dictionary) -> bool:
	if not hit_filter.is_valid():
		return true
	var collider: Object = hit_result.get("collider")
	var rid := RID()
	if collider is CollisionObject3D:
		rid = (collider as CollisionObject3D).get_rid()
	return bool(hit_filter.call(
		rid, int(hit_result.get("shape", -1)), hit_result.get("position", Vector3.ZERO)
	))


## 命中后判断"要不要真的打上去"；不要的话把那个刚体加进这一发的 `skip` 里，
## 再从命中点往前一点点重新打 —— 最多穿 4 层（防止死循环）。
func _pass_through(
	hit_result: Dictionary, skip: Array, from: Vector3, to: Vector3,
	space: PhysicsDirectSpaceState3D
) -> Dictionary:
	var collider: Object = hit_result.get("collider")
	if collider is CollisionObject3D:
		var rid := (collider as CollisionObject3D).get_rid()
		if not skip.has(rid):
			skip.append(rid)
	var direction := to - from
	if direction.length() < 0.0001 or skip.size() > 4:
		return {}
	return _cast(
		(hit_result["position"] as Vector3) + direction.normalized() * 0.01, to, space, skip
	)


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
	material.albedo_color = DEFAULT_BULLET_COLOR   # 每发会被 `_tint()` 改成弹头自己的颜色
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
	# 一个开火者可以登记**多个** RID（车体 + 受击盒）：两个都算"自己"
	var is_self := false
	if own is Array:
		is_self = (own as Array).has(hit_rid)
	elif own != null:
		is_self = hit_rid == own
	return {"self": is_self, "impact": true, "damage": not is_self}


## 在某个位置放一个命中小爆炸（玩家贴脸自吃时，测试场要指定放哪儿，所以做成公开的）。
## `colour` 用这一发弹头的颜色（不传就是默认黄）。
func spawn_impact(at: Vector3, colour := DEFAULT_BULLET_COLOR) -> void:
	_spawn_impact(at, colour)


func _spawn_impact(at: Vector3, colour := DEFAULT_BULLET_COLOR) -> void:
	var node: MeshInstance3D = (
		_free_impacts.pop_back() if not _free_impacts.is_empty() else _make_impact()
	)
	if node == null:
		return
	node.visible = true
	_tint(node, colour)
	node.global_position = at
	node.scale = Vector3.ONE
	_impacts.append({"node": node, "age": 0.0, "life": IMPACT_LIFE, "peak": IMPACT_PEAK})




func _make_impact() -> MeshInstance3D:
	var node := _make_blob(IMPACT_RADIUS, DEFAULT_BULLET_COLOR)
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
