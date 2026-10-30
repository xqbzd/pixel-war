extends TestField

## 人机对战模式（5v5）：**玩家 + 4 个人机队友 vs 5 个人机敌人**。
##
## 复用测试场那一整套东西（轮胎物理 / 转塔 / 弹道 / 毁伤 / 相机 / HUD）—— 这里只加三样：
##   1. 场地：`BattleArena`（1000m × 1000m，起伏 ≤20° + 掩体）；
##   2. 队伍：玩家车和别人机的车分两队（碰撞层 2 / 3），**友军伤害关掉**；
##   3. 人机：每台车一个"大脑"（`_ai_input()`）—— 选目标、开过去、绕圈、瞄准、开火、卡住倒车。
##
## 规则（第一版）：一条命，一队全灭就结束；玩家死了也能看队友打完。
## 敌人的车用 `data/vehicles/bot_light.vehicle.txt` / `bot_gunner.vehicle.txt`
## （都是能开、有枪的轻车；改它们就改人机的强度）。

## 一队几个格子（5v5）—— 和 `BattleRoster.SLOTS` 必须一致（`test_roster_team_size_matches` 守着）
const TEAM_SIZE := 5

## 配置界面（`scripts/battle_setup.gd`）塞进来的两队名单：2 队 × 5 格，
## 每格 {kind: "empty"|"player"|"bot", vehicle, name}。空 = 老流程（全人机）。
static var pending_roster := []

## 场地场景（**在 Godot 编辑器里能直接拖石头/出生点**；没烘焙过就退回程序化场地）
const BATTLE_ARENA_SCENE := "res://scenes/battle_arena.tscn"

## 人机用的车（轻型 1 枪 / 双枪）
const BOT_LIGHT := "bot_light"
const BOT_GUNNER := "bot_gunner"

## ── 人机的手感旋钮（**运行时从 data/battle_ai.txt 读**；这里只是默认值）─────
## 到这个距离之前"冲过去"，到了就绕圈（260 格 = 130 米）
const BOT_STANDOFF := 260.0
## 比这更近就倒车拉开（120 格 = 60 米）—— 免得贴脸互相顶
const BOT_TOO_CLOSE := 120.0
## 开火距离上限（700 格 = 350 米；子弹寿命 0.5 秒 × 1000 格/秒，够得着）
const BOT_FIRE_RANGE := 700.0
## 炮口方向和瞄准方向的点积阈值（0.997 ≈ 4.4°）—— 没对准就不浪费子弹
const BOT_AIM_TOLERANCE := 0.997
## 换目标间隔（秒）
const BOT_RETARGET := 2.0
## 低于这个速度算"卡住"（格/秒）；卡住超过 `BOT_STUCK_TIME` 就倒车 `BOT_REVERSE_TIME`
const BOT_STUCK_SPEED := 1.5
const BOT_STUCK_TIME := 1.5
const BOT_REVERSE_TIME := 1.2
## 障碍探测距离（格）与偏转角度（弧度）
const BOT_PROBE := 42.0
const BOT_AVOID_ANGLE := 1.2
## 反应时间（秒）：看到敌人之后要等这么久才允许开火
const BOT_REACTION_SECONDS := 0.3
## 瞄点相对核心的最大随机偏差（度）：刚看到时随机抖，持续开火后衰减到 0
const BOT_AIM_SPREAD_DEG := 2.0
## 连续开火多少秒后偏差衰减到 0
const BOT_AIM_SETTLE_SECONDS := 2.0

## 人机参数文件（`键 = 数值`，注释用 `#`）：改完重新进一次战局就生效。
## 想调人机强弱/手感，**只改这个文件**，不用动代码。
const AI_TXT := "res://data/battle_ai.txt"
const AI_DEFAULTS := {
	"bot_standoff": BOT_STANDOFF,
	"bot_too_close": BOT_TOO_CLOSE,
	"bot_fire_range": BOT_FIRE_RANGE,
	"bot_aim_tolerance": BOT_AIM_TOLERANCE,
	"bot_retarget_seconds": BOT_RETARGET,
	"bot_stuck_speed": BOT_STUCK_SPEED,
	"bot_stuck_seconds": BOT_STUCK_TIME,
	"bot_reverse_seconds": BOT_REVERSE_TIME,
	"bot_probe": BOT_PROBE,
	"bot_avoid_angle": BOT_AVOID_ANGLE,
	"bot_reaction_seconds": BOT_REACTION_SECONDS,
	"bot_aim_spread_deg": BOT_AIM_SPREAD_DEG,
	"bot_aim_settle_seconds": BOT_AIM_SETTLE_SECONDS,
}

## ── 队伍颜色（用户定的：我方蓝、敌方红）──────────────────────────────────
const FRIENDLY_COLOUR := Color(0.36, 0.62, 1.0)
const ENEMY_COLOUR := Color(1.0, 0.32, 0.28)

## ── 视野 / 标记（小地图红点与敌人血条）────────────────────────────────────
## 敌人必须**连续**出现在某个友方载具的视野里这么久，才会被整队自动"标记"
const SPOT_TIME := 1.0
## 全部友方都看不见之后，还要留这么久才熄灭（用户要求：0.5 秒）
const SPOT_LOST_TIME := 0.5
## **自动标记只在 200 米内生效**（400 格）：再远就得手动按 Q 或让子弹打中
const AUTO_SPOT_RANGE := 400.0
## 手动标记（Q）的射线长度（格）：1500 格 = 750 米，基本覆盖整个场地
const MANUAL_MARK_RANGE := 1500.0
## 手动标记的"准星容差"：敌人重心投到屏幕上，离屏幕中心多少像素内算"对着它"
## （给一点余量 —— 远处的车只有几个像素宽，要求像素级对准太难受）
const MANUAL_MARK_SCREEN_RADIUS := 90.0
## 人机的视野半角（弧度）：车头 ±75°
const BOT_VIEW_HALF_ANGLE := deg_to_rad(75.0)
## 玩家视野在相机 FOV 基础上再多给一点余量（弧度）
const PLAYER_VIEW_MARGIN := deg_to_rad(4.0)

var _arena: BattleArena
var _battle_over := false
var _battle_won := false
var _banner: Label
var _player_dead := false
## 敌车 owner_key -> {seen: float, lost: float, spotted: bool}（全队共享的视野计时）
var _spot := {}
var _nameplates: VehicleNameplates
var _minimap: BattleMinimap
## 底部中央的能量条 + 绿色血圈（玩家自己的状态）
var _combat_hud: BattleCombatHud
## 人机参数（从 `data/battle_ai.txt` 读；读不到就用 `AI_DEFAULTS`）
var _ai_cfg := {}
## 瞄点随机偏差用的随机数（固定种子可复现；这里用真随机，每局手感不同）
var _ai_rng := RandomNumberGenerator.new()


# ──────────────────────────────────────────────────────────── 场地 / 队伍

func _ready() -> void:
	super._ready()
	if _chassis == null:
		return
	# 人机参数：data/battle_ai.txt（键 = 数值）。改完重新进一次战局就生效。
	_ai_cfg = GameSettings.floats_from_text(AI_TXT, AI_DEFAULTS)
	_ai_rng.randomize()
	_status = (
		"人机对战：目标 = 打光对面 %d 台（一条命，不可复活）\n"
		% BattleRoster.team_count(_roster_or_default(), TEAM_ENEMY)
		+ "开车：W/S 油门·反向 · A/D 转向 · 空格/左键 开火\n"
		+ "Q 标记敌人（准星对准）· 200 米内持续看见 1 秒自动标记 · 被友方子弹命中也会标记\n"
		+ "鼠标环视瞄准 · 滚轮调视野 · 右键按住开镜（滚轮调 2~16 倍）\n"
		+ "ESC 暂停菜单"
	)
	_update_hud()


## 对战场地：一整块程序化生成的地形 + 掩体（见 scripts/battle_arena.gd）。
func _build_arena() -> void:
	var env := WorldEnvironment.new()
	env.environment = BattleArena.make_outdoor_environment()
	add_child(env)
	var sun := BattleArena.make_outdoor_sun()
	sun.shadow_enabled = SHADOWS
	if SHADOWS:
		sun.directional_shadow_max_distance = 90.0
		sun.shadow_blur = 1.5
	add_child(sun)
	_arena_root = Node3D.new()
	_arena_root.name = "Arena"
	add_child(_arena_root)
	# 场地用**编辑器里能拖拽的场景**（scenes/battle_arena.tscn）；场景缺失就退回纯程序化。
	var packed: PackedScene = (
		load(BATTLE_ARENA_SCENE) if ResourceLoader.exists(BATTLE_ARENA_SCENE) else null
	)
	if packed != null:
		_arena = packed.instantiate() as BattleArena
	else:
		push_warning("[对战] 没有 %s，退回程序化场地" % BATTLE_ARENA_SCENE)
		_arena = BattleArena.new()
	_arena.name = "BattleArena"
	_arena_root.add_child(_arena)   # 它的 `_ready()` 负责 build（编辑器里只铺地面预览）
	_arena.build()


## 玩家出生在名单里自己那一格（默认左队第 1 格），车头朝敌方。
func _player_spawn_transform(actual: AABB) -> Transform3D:
	var at: Array = BattleRoster.find_player(_roster_or_default())
	var index := 0
	if not at.is_empty():
		index = int(at[1])
	var t := _arena.spawn_transform(TEAM_PLAYER, index, TEAM_SIZE)
	t.origin.y += actual.size.y * 0.5 + 2.0
	return t


## 配置界面给的两队名单（空 = 老流程：玩家 + 4 个人机 vs 5 个人机）。
func _roster_or_default() -> Array:
	if not pending_roster.is_empty():
		return pending_roster
	return BattleRoster.default_roster(
		str(TestField.pending_vehicle.get("id", "")), str(TestField.pending_vehicle.get("name", "玩家"))
	)


## 按名单生成：每个队伍里不是"player"也不是"empty"的格子放一台人机。
func _spawn_enemy_replicas(_vehicle: VehicleDef) -> void:
	var roster := _roster_or_default()
	for team in 2:
		if team >= roster.size():
			continue
		var slots: Array = roster[team]
		for index in slots.size():
			var slot: Dictionary = slots[index]
			var kind := str(slot.get("kind", "empty"))
			if kind != "bot":
				continue                                  # 空位 / 玩家（玩家由测试场自己生成）
			var vehicle_id := str(slot.get("vehicle", ""))
			if vehicle_id.is_empty():
				continue
			var label := "%s%d" % ["队友" if team == TEAM_PLAYER else "敌人", index + 1]
			_spawn_bot(vehicle_id, team, index, label)
	print("[对战] 我方 %d 台（含玩家）/ 敌方 %d 台" % [_team_alive(TEAM_PLAYER), _team_alive(TEAM_ENEMY)])


## 放一台人机车：从 `data/vehicles` 读（合法整机，带核心 / 轮子 / 枪）。
func _spawn_bot(vehicle_id: String, team: int, index: int, label: String) -> void:
	var path := VehicleStore.find_path(vehicle_id)
	if not FileAccess.file_exists(path):
		push_warning("[对战] 找不到人机车 %s" % path)
		return
	var vehicle := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)
	var actual := vehicle.actual_bounds(_library)
	var t := _arena.spawn_transform(team, index, TEAM_SIZE)
	t.origin.y += actual.size.y * 0.5 + 2.0
	var entry := _spawn_vehicle(
		vehicle, team, t, actual.get_center(), false,
		"%s_%d_%d" % ["ally" if team == TEAM_PLAYER else "enemy", team, index], label
	)
	entry["ai"] = {
		"target": {}, "retarget": 0.0, "stuck": 0.0, "reverse": 0.0,
		"reverse_steer": 0.0, "strafe": 1.0 if index % 2 == 0 else -1.0,
		# 反应 / 精度状态（见 `_ai_input`）：是否看得见、看了多久、连开火多久、随机偏差方向
		"visible": false, "seen": 0.0, "fire_time": 0.0, "aim_dir": Vector3.ZERO,
	}
	if team == TEAM_ENEMY:
		_enemies.append(entry["rig"])


# ──────────────────────────────────────────────────────────── 人机

## 每台车的输入：玩家读键盘，人机走 AI（返回 (油门, 转向)）。
func _vehicle_input(veh: Dictionary, delta: float) -> Vector2:
	if bool(veh.get("is_player", false)):
		return super._vehicle_input(veh, delta)
	return _ai_input(veh, delta)


## 人机的"大脑"：选目标 → 算瞄准点 → 决定开不开火 → 决定往哪开。
## 全部是每物理帧一次，没有寻路 —— 场地是开阔的缓坡，靠"前方射线 + 卡住倒车"就够了。
##
## 开火流程（2026-10-18 用户要求"人机别像自瞄"）：
##   1. **反应时间**：看到敌人（视线通）之后要等 `bot_reaction_seconds` 秒才允许开火；
##   2. **瞄点随机偏差**：刚看到时瞄点相对核心随机偏最多 `bot_aim_spread_deg` 度；
##   3. **越打越准**：连续开火 `bot_aim_settle_seconds` 秒内把偏差线性衰减到 0；
##   4. 换目标 / 视线断了重新发现 → 偏差和反应计时**重置**。
func _ai_input(veh: Dictionary, delta: float) -> Vector2:
	var ai: Dictionary = veh.get("ai", {})
	veh["wants_fire"] = false
	if _battle_over or not bool(veh.get("alive", true)) or ai.is_empty():
		return Vector2.ZERO
	var target := _ai_target(veh, ai, delta)
	if target.is_empty():
		_reset_aim_state(ai)
		return Vector2.ZERO
	var chassis: RigidBody3D = veh["chassis"]
	var target_chassis: RigidBody3D = target["chassis"]
	var to := target_chassis.global_position - chassis.global_position
	var dist := Vector2(to.x, to.z).length()
	# 瞄准点 = 目标重心 + 提前量（子弹飞过去要 time = 距离 / 初速）
	var aim := _ai_aim_point(veh, target, dist)
	# ── 反应时间 + 随机偏差（"看到" = 视线通；断一次就当重新发现）──
	var visible := _ai_sees(veh, target)
	if visible:
		if not bool(ai.get("visible", false)):
			# 重新发现：换一组随机偏差，反应计时归零
			ai["visible"] = true
			ai["aim_dir"] = _random_direction()
			ai["fire_time"] = 0.0
			ai["seen"] = 0.0
		ai["seen"] = float(ai["seen"]) + delta
	else:
		_reset_aim_state(ai)
	# 偏差大小 = tan(角度) × 距离 × 剩余比例（连续开火时间越长越小）
	var spread := deg_to_rad(_ai_p("bot_aim_spread_deg"))
	var decay := aim_spread_decay(float(ai["fire_time"]), _ai_p("bot_aim_settle_seconds"))
	var aim_dir: Vector3 = ai.get("aim_dir", Vector3.UP)
	aim += aim_spread_offset(aim_dir, spread, dist, decay)
	veh["aim_point"] = aim
	# 能被瞄准 = 有视线 + 反应时间到了 + 枪口基本对准 + 没被打断
	var aimed := _ai_can_fire(veh, aim, dist)
	veh["wants_fire"] = visible and aimed and float(ai["seen"]) >= _ai_p("bot_reaction_seconds")
	if bool(veh["wants_fire"]):
		ai["fire_time"] = float(ai["fire_time"]) + delta
	# 期望方向：远 → 冲过去；近 → 倒车；中距离 → 绕圈（左右交替）
	var standoff := _ai_p("bot_standoff")
	var too_close := _ai_p("bot_too_close")
	var desired := Vector3(to.x, 0.0, to.z).normalized() if dist > 0.01 else Vector3.ZERO
	if dist < too_close:
		desired = -desired
	elif dist < standoff:
		desired = desired.rotated(Vector3.UP, float(ai["strafe"]) * 1.15)
	if desired != Vector3.ZERO:
		desired = _ai_avoid(veh, chassis, desired)
	# 转向：把车头拧到期望方向（+Y 转角为正 = 往左，和玩家按 A 一致）
	var steer := steer_towards(chassis.global_transform.basis.x, desired)
	var throttle := 1.0
	if dist < too_close:
		throttle = -1.0
	elif dist < standoff:
		throttle = 0.7
	# 倒车状态（被卡住 / 翻不过来时先退一段，同时反打方向）
	if float(ai["reverse"]) > 0.0:
		ai["reverse"] = float(ai["reverse"]) - delta
		return Vector2(-1.0, float(ai["reverse_steer"]))
	# 卡住检测：给油但几乎不动 → 记时，超时就倒车
	var speed := Vector2(chassis.linear_velocity.x, chassis.linear_velocity.z).length()
	if absf(throttle) > 0.3 and speed < _ai_p("bot_stuck_speed"):
		ai["stuck"] = float(ai["stuck"]) + delta
		if float(ai["stuck"]) > _ai_p("bot_stuck_seconds"):
			ai["stuck"] = 0.0
			ai["reverse"] = _ai_p("bot_reverse_seconds")
			ai["reverse_steer"] = -signf(steer) if absf(steer) > 0.05 else -float(ai["strafe"])
	else:
		ai["stuck"] = 0.0
	return Vector2(throttle, steer)


## 清掉"看到目标"的状态：反应计时、连续开火时间、随机偏差方向。
## 换目标 / 视线断了 / 目标没了都走这里（用户要求：重新发现要重置偏差）。
func _reset_aim_state(ai: Dictionary) -> void:
	ai["visible"] = false
	ai["seen"] = 0.0
	ai["fire_time"] = 0.0
	ai["aim_dir"] = Vector3.ZERO


## 人机的"视野"：从车顶到目标重心打一条射线，地形/掩体/别的车挡住就不算看到。
func _ai_sees(veh: Dictionary, target: Dictionary) -> bool:
	var chassis: RigidBody3D = veh["chassis"]
	var target_chassis: RigidBody3D = target["chassis"]
	if chassis == null or target_chassis == null:
		return false
	var eye := chassis.global_position + Vector3.UP * 2.0
	var point := target_chassis.global_transform * target_chassis.center_of_mass
	var space := chassis.get_world_3d().direct_space_state
	if space == null:
		return false
	var exclude: Array[RID] = [chassis.get_rid()]
	var rig: VehicleRig = veh["rig"]
	if rig.hitboxes != null:
		exclude.append(rig.hitboxes.get_rid())
	var hit := space.intersect_ray(
		PhysicsRayQueryParameters3D.create(eye, point, AIM_LAYERS, exclude)
	)
	if hit.is_empty():
		return true
	var collider: Object = hit.get("collider")
	if collider is CollisionObject3D:
		var hit_rig: VehicleRig = _vehicles_by_rid.get((collider as CollisionObject3D).get_rid())
		return hit_rig != null and hit_rig == target["rig"]
	return false


## 随机单位向量（瞄点抖动用；均匀分布，别老往同一个方向偏）。
func _random_direction() -> Vector3:
	var theta := _ai_rng.randf_range(0.0, TAU)
	var z := _ai_rng.randf_range(-1.0, 1.0)
	var r := sqrt(maxf(0.0, 1.0 - z * z))
	return Vector3(r * cos(theta), z, r * sin(theta))


## 瞄点偏差（纯函数，测试直接打它）：`direction` 是单位方向，
## 偏移量 = tan(角度) × 距离 × `decay`。`decay` 从 1（刚看到）线性降到 0（打准了）。
static func aim_spread_offset(
	direction: Vector3, spread_rad: float, distance: float, decay: float
) -> Vector3:
	if direction.length() < 0.001 or distance <= 0.0 or decay <= 0.0:
		return Vector3.ZERO
	return direction.normalized() * tan(maxf(0.0, spread_rad)) * maxf(0.0, distance) * clampf(decay, 0.0, 1.0)


## 偏差衰减比例（纯函数）：连续开火 `fire_seconds` 秒后还剩多少（1 → 0）。
static func aim_spread_decay(fire_seconds: float, settle_seconds: float) -> float:
	if settle_seconds <= 0.0001:
		return 0.0
	return clampf(1.0 - maxf(0.0, fire_seconds) / settle_seconds, 0.0, 1.0)


## 人机参数（`data/battle_ai.txt`）：没有就用 `AI_DEFAULTS`。
func _ai_p(key: String) -> float:
	if _ai_cfg.has(key):
		return float(_ai_cfg[key])
	return float(AI_DEFAULTS.get(key, 0.0))


## 选目标：最近的、还活着的敌人；每 `bot_retarget_seconds` 秒重新挑一次（或者目标死了）。
## 换了目标（或者旧目标没了）就**重置瞄点偏差/反应计时**。
func _ai_target(veh: Dictionary, ai: Dictionary, delta: float) -> Dictionary:
	ai["retarget"] = float(ai["retarget"]) - delta
	var current: Dictionary = ai.get("target", {})
	if (
		float(ai["retarget"]) > 0.0 and not current.is_empty()
		and bool(current.get("alive", false))
		and (current["rig"] as VehicleRig).state.alive_count() > 0
	):
		return current
	ai["retarget"] = _ai_p("bot_retarget_seconds")
	var best := {}
	var best_distance := INF
	var mine: Vector3 = (veh["chassis"] as RigidBody3D).global_position
	for other in _vehicles:
		if int(other["team"]) == int(veh["team"]) or not bool(other.get("alive", true)):
			continue
		var rig: VehicleRig = other["rig"]
		if rig.state.alive_count() <= 0:
			continue
		var distance := (other["chassis"] as RigidBody3D).global_position.distance_squared_to(mine)
		if distance < best_distance:
			best_distance = distance
			best = other
	# 换了个人打 → 反应计时和随机偏差都从头来（用户要求）
	if best.is_empty() or current.is_empty() or best["rig"] != current["rig"]:
		_reset_aim_state(ai)
	ai["target"] = best
	return best


## 瞄准点：目标重心 + 提前量（速度 × 飞行时间）。打移动的靶子不用一直"猜前面"。
func _ai_aim_point(veh: Dictionary, target: Dictionary, dist: float) -> Vector3:
	var target_chassis: RigidBody3D = target["chassis"]
	var point := target_chassis.global_transform * target_chassis.center_of_mass
	# 用"活着零件的视觉中心"：打残之后重心可能落在空处，瞄点要跟着剩下的残骸走
	var target_rig: VehicleRig = target.get("rig")
	if target_rig != null:
		point = target_rig.alive_centre_world()
	var speed := 1000.0
	var turrets: Array = veh.get("turrets", [])
	if not turrets.is_empty():
		var turret: Turret = turrets[0]
		# 射线类武器是**瞬间命中**：不用提前量，直接瞄目标重心
		if turret.is_ray():
			return point
		speed = maxf(1.0, float(turret.muzzle_speed))
	return lead_point(point, target_chassis.linear_velocity, dist, speed)


## 提前量（纯函数，测试直接打它）：目标以 `velocity` 走 `distance / bullet_speed` 秒后到哪儿。
static func lead_point(
	target_position: Vector3, target_velocity: Vector3, distance: float, bullet_speed: float
) -> Vector3:
	if bullet_speed <= 0.001:
		return target_position
	return target_position + target_velocity * (maxf(0.0, distance) / bullet_speed)


## 期望方向 → 转向量（+1 = 左打满，和玩家按 A 一致；只有水平分量参与）。
## 纯函数，测试直接打它（AI 的左右打反过一次，这条断言就是防它再犯的）。
static func steer_towards(forward: Vector3, desired: Vector3) -> float:
	var f := Vector3(forward.x, 0.0, forward.z)
	var d := Vector3(desired.x, 0.0, desired.z)
	if f.length() < 0.001 or d.length() < 0.001:
		return 0.0
	f = f.normalized()
	d = d.normalized()
	return clampf(atan2(f.cross(d).y, f.dot(d)) * 2.0, -1.0, 1.0)


## 能不能开火：距离够近 + 至少一台转塔的枪口基本对准 + 视线没被**地形/掩体/队友**挡住。
## ⚠️ 队友挡枪必须跳过：10 台车挤在一起，不判的话子弹全打在队友背上（友军伤害是关的，
## 等于白打），实测 30 秒一枪不中。
func _ai_can_fire(veh: Dictionary, aim: Vector3, dist: float) -> bool:
	if dist > _ai_p("bot_fire_range"):
		return false
	var chassis: RigidBody3D = veh["chassis"]
	var space := chassis.get_world_3d().direct_space_state
	if space == null:
		return false
	var team := int(veh["team"])
	var turrets: Array = veh.get("turrets", [])
	for turret in turrets:
		var muzzle: Vector3 = (turret as Turret).muzzle_position()
		var direction := (aim - muzzle).normalized()
		if direction.dot((turret as Turret).barrel_direction()) < _ai_p("bot_aim_tolerance"):
			continue
		var query := PhysicsRayQueryParameters3D.create(muzzle, aim, AIM_LAYERS)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return true
		var collider: Object = hit.get("collider")
		if collider is CollisionObject3D:
			var rig: VehicleRig = _vehicles_by_rid.get((collider as CollisionObject3D).get_rid())
			if rig == null:
				continue              # 地形 / 掩体挡住，这台炮位别打
			if rig.team == team:
				continue              # 队友挡在枪线上
			return true               # 前面是敌人 → 开火
		return true
	return false


## 前方有石头/坡就绕：正前方打一条，再各歪 50° 打一条，往空的那边转。
func _ai_avoid(veh: Dictionary, chassis: RigidBody3D, desired: Vector3) -> Vector3:
	var space := chassis.get_world_3d().direct_space_state
	var from := chassis.global_position + Vector3.UP * 2.0
	var exclude: Array[RID] = [chassis.get_rid()]
	var forward := desired.normalized()
	var hit := space.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, from + forward * _ai_p("bot_probe"), WORLD_LAYER, exclude)
	)
	if hit.is_empty():
		return desired
	var left := forward.rotated(Vector3.UP, 0.9)
	var right := forward.rotated(Vector3.UP, -0.9)
	var left_clear := space.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, from + left * _ai_p("bot_probe"), WORLD_LAYER, exclude)
	).is_empty()
	var right_clear := space.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, from + right * _ai_p("bot_probe"), WORLD_LAYER, exclude)
	).is_empty()
	if left_clear and not right_clear:
		return forward.rotated(Vector3.UP, _ai_p("bot_avoid_angle"))
	if right_clear and not left_clear:
		return forward.rotated(Vector3.UP, -_ai_p("bot_avoid_angle"))
	if left_clear and right_clear:
		return forward.rotated(Vector3.UP, _ai_p("bot_avoid_angle") * float(veh["ai"]["strafe"]))
	return forward.rotated(Vector3.UP, PI * 0.75)


# ──────────────────────────────────────────────────────────── 视野 / 点亮

## 推进一个敌人的"被点亮"状态机（纯函数，测试直接打它）：
##   * 连续被看到 `SPOT_TIME` 秒 → `spotted = true`（**中间断一帧就重新计时**）；
##   * 已经点亮之后，全部友方都看不见要满 `SPOT_LOST_TIME` 秒才熄灭
##     （用户要求："消失在所有友方载具的视野内一秒后再度消失"）。
static func advance_spot(state: Dictionary, seen: bool, delta: float) -> Dictionary:
	if seen:
		state["seen"] = float(state.get("seen", 0.0)) + delta
		state["lost"] = 0.0
		if float(state["seen"]) >= SPOT_TIME:
			state["spotted"] = true
	else:
		# "持续出现"才算：这一帧没看到就重新计时（已经点亮的靠下面的一秒宽限）
		state["seen"] = 0.0
		state["lost"] = float(state.get("lost", 0.0)) + delta
		if float(state["lost"]) >= SPOT_LOST_TIME:
			state["spotted"] = false
	return state


## 目标在不在视野锥里（纯函数，测试直接打它）：forward / to_target 都不用归一化。
static func in_view_cone(forward: Vector3, to_target: Vector3, half_angle: float) -> bool:
	if forward.length() < 0.001 or to_target.length() < 0.001:
		return false
	var angle := clampf(half_angle, 0.0, PI)
	return forward.normalized().dot(to_target.normalized()) >= cos(angle)


## 这一帧把 5 个敌人的视野计时都推进一步（全队共享：任何一个友方看到都算）。
func _update_spotting(delta: float) -> void:
	for veh in _vehicles:
		if int(veh.get("team", -1)) != TEAM_ENEMY:
			continue
		var key := str(veh.get("owner_key", ""))
		var alive: bool = (veh["rig"] as VehicleRig).state.alive_count() > 0
		var seen := alive and _team_sees(veh)
		_spot[key] = advance_spot(_spot.get(key, {}), seen, delta)


## 敌人这台车现在该不该显示（血条 / 名字 / 小地图红点）。
func _is_spotted(veh: Dictionary) -> bool:
	return bool((_spot.get(str(veh.get("owner_key", "")), {}) as Dictionary).get("spotted", false))


## 立刻标记一台敌车（手动 Q / 被友方子弹命中）：整队马上看得见，
## 之后仍然按"离开所有友方视野 SPOT_LOST_TIME 秒"的规则消失。
func _mark_enemy(veh: Dictionary, reason: String) -> void:
	var key := str(veh.get("owner_key", ""))
	if key.is_empty():
		return
	var state: Dictionary = _spot.get(key, {})
	var already := bool(state.get("spotted", false))
	state["spotted"] = true
	state["seen"] = maxf(float(state.get("seen", 0.0)), SPOT_TIME)
	state["lost"] = 0.0
	_spot[key] = state
	if not already:
		_last_hit = "已标记 %s（%s）" % [str(veh.get("display_name", "")), reason]


## Q：把准星附近的敌人标记出来。
## 做法不是"从屏幕中心打一条射线"，而是**把每台敌车的重心投到屏幕上**，
## 取离屏幕中心最近、且在视线内的那台 —— 远处的车只有几个像素宽，
## 纯射线要求像素级对准，手感太差；这样给了 `MANUAL_MARK_SCREEN_RADIUS` 的容差。
func _try_mark_target() -> void:
	if _camera == null or _vehicles.is_empty():
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var screen_centre := get_viewport().get_visible_rect().size * 0.5
	# ⚠️ 视线射线要**排除玩家自己的车**：相机在车后 28 格、准星压在车顶上，
	# 从相机往远处打，第一下必定打在自己车上（不排除的话 Q 永远"附近没有敌人"）。
	var exclude: Array[RID] = []
	if _chassis != null and is_instance_valid(_chassis):
		exclude.append(_chassis.get_rid())
	if _player_rig != null and _player_rig.hitboxes != null:
		exclude.append(_player_rig.hitboxes.get_rid())
	var best := {}
	var best_pixels := MANUAL_MARK_SCREEN_RADIUS
	for veh in _vehicles:
		if int(veh.get("team", -1)) != TEAM_ENEMY:
			continue
		var rig: VehicleRig = veh["rig"]
		if rig.state.alive_count() <= 0:
			continue
		var body: RigidBody3D = veh.get("chassis")
		if body == null or not is_instance_valid(body):
			continue
		# 瞄点用**活着零件的视觉中心**（在车体内部），不能用"底盘原点 + 固定高度"：
		# 被打成只剩一个核心的车很矮，抬高 1.5 格会从残骸头顶飘过去，Q 就永远标不中。
		var point := body.global_transform * body.center_of_mass
		if rig != null:
			point = rig.alive_centre_world()
		if _camera.is_position_behind(point):
			continue
		if _camera.global_position.distance_to(point) > MANUAL_MARK_RANGE:
			continue
		var pixels := _camera.unproject_position(point).distance_to(screen_centre)
		if pixels > best_pixels:
			continue
		# 视线：从相机到车体中心，先打到的必须就是这台车（被地形/掩体/队友挡住就不标）
		var hit := space.intersect_ray(
			PhysicsRayQueryParameters3D.create(_camera.global_position, point, AIM_LAYERS, exclude)
		)
		if hit.is_empty():
			continue
		var collider: Object = hit.get("collider")
		if not (collider is CollisionObject3D):
			continue
		var hit_rig: VehicleRig = _vehicles_by_rid.get((collider as CollisionObject3D).get_rid())
		if hit_rig != rig:
			continue
		best = veh
		best_pixels = pixels
	if best.is_empty():
		_last_hit = "准星附近没有敌人（按 Q 需要把准星对着敌人）"
		return
	_mark_enemy(best, "手动标记")


## Q 键（基类 `_unhandled_input` 调到这里）。
func _on_mark_pressed() -> void:
	_try_mark_target()


## 被子弹打中（跨队）→ 立刻标记。谁打的都算：玩家自己、队友人机都行。
func _on_vehicle_damaged(rig: VehicleRig) -> void:
	if rig.team != TEAM_ENEMY:
		return
	var veh := _vehicle_for_rig(rig)
	if veh.is_empty():
		return
	_mark_enemy(veh, "被友方子弹命中")


## RID → 车字典（标记用）。
func _vehicle_for_rig(rig: VehicleRig) -> Dictionary:
	for veh in _vehicles:
		if veh["rig"] == rig:
			return veh
	return {}


## 全队有没有人看得见这台敌车。
func _team_sees(enemy_veh: Dictionary) -> bool:
	for viewer in _vehicles:
		if int(viewer.get("team", -1)) != TEAM_PLAYER:
			continue
		if not bool(viewer.get("alive", true)):
			continue
		if (viewer["rig"] as VehicleRig).state.alive_count() <= 0:
			continue
		if _vehicle_sees(viewer, enemy_veh):
			return true
	return false


## 一台友方载具能不能看到这台敌车：距离（**自动标记只认 200 米以内**）→ 视野锥 → 视线
## （地形/掩体/别的车挡住就不算）。200 米外只能靠手动 Q 或"被子弹命中"标记。
func _vehicle_sees(viewer: Dictionary, target: Dictionary) -> bool:
	var viewer_body: RigidBody3D = viewer["chassis"]
	var target_body: RigidBody3D = target["chassis"]
	if viewer_body == null or target_body == null:
		return false
	var eye := viewer_body.global_position + Vector3.UP * 1.6
	var point := target_body.global_transform * target_body.center_of_mass
	# 视野判定也看"活着零件的中心"：残骸很小的时候瞄重心可能飘到空处
	var target_rig: VehicleRig = target.get("rig")
	if target_rig != null:
		point = target_rig.alive_centre_world()
	var to := point - eye
	var distance := to.length()
	var is_player := bool(viewer.get("is_player", false))
	if distance < 0.01 or distance > AUTO_SPOT_RANGE:
		return false
	# 视野锥：玩家用**当前相机 FOV**（开镜会变窄，和看到的画面一致）；人机用车头 ±75°
	var forward: Vector3
	var half_angle: float
	if is_player:
		if _camera == null:
			return false
		forward = -_camera.global_transform.basis.z
		var viewport := get_viewport().get_visible_rect().size
		var aspect := viewport.x / maxf(1.0, viewport.y)
		half_angle = atan(tan(deg_to_rad(_camera.fov) * 0.5) * aspect) + PLAYER_VIEW_MARGIN
	else:
		forward = viewer_body.global_transform.basis.x
		half_angle = BOT_VIEW_HALF_ANGLE
	if not in_view_cone(forward, to, half_angle):
		return false
	# 视线：从观察者眼睛到目标重心，先打到的必须就是这台敌车
	var space := viewer_body.get_world_3d().direct_space_state
	if space == null:
		return false
	var exclude: Array[RID] = [viewer_body.get_rid()]
	var viewer_rig: VehicleRig = viewer["rig"]
	if viewer_rig.hitboxes != null:
		exclude.append(viewer_rig.hitboxes.get_rid())
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, point, AIM_LAYERS, exclude))
	if hit.is_empty():
		return true
	var collider: Object = hit.get("collider")
	if collider is CollisionObject3D:
		var rig: VehicleRig = _vehicles_by_rid.get((collider as CollisionObject3D).get_rid())
		return rig != null and rig == target["rig"]
	return false


## 头顶血条 + 小地图的每帧刷新：**敌方只有被点亮才进列表**，友方一直显示。
func _refresh_tactical_hud() -> void:
	if _nameplates == null or _minimap == null or _camera == null:
		return
	var plates := []
	var dots := []
	for veh in _vehicles:
		var rig: VehicleRig = veh["rig"]
		if bool(veh.get("is_player", false)) or rig.state.alive_count() <= 0:
			continue
		var friendly := int(veh.get("team", -1)) == TEAM_PLAYER
		if not friendly and not _is_spotted(veh):
			continue
		var colour := FRIENDLY_COLOUR if friendly else ENEMY_COLOUR
		var chassis: RigidBody3D = veh["chassis"]
		var head := float(veh.get("height", 2.0)) * 0.5 + 1.4
		plates.append({
			"world": chassis.global_position + Vector3.UP * head,
			"label": str(veh.get("display_name", "")),
			"fraction": rig.state.health_fraction(),
			"colour": colour,
			"camera": _camera,
		})
		dots.append({
			"pos": Vector2(chassis.global_position.x, chassis.global_position.z) * PartDef.CUBE_METERS,
			"colour": colour,
			"radius": BattleMinimap.DOT_RADIUS,
		})
	_nameplates.set_rows(plates)
	var player_pos := Vector2.ZERO
	var player_yaw := 0.0
	var has_player := _chassis != null and is_instance_valid(_chassis)
	if has_player:
		player_pos = Vector2(_chassis.global_position.x, _chassis.global_position.z) * PartDef.CUBE_METERS
		player_yaw = _chassis.global_rotation.y
	_minimap.set_rows(dots, player_pos, player_yaw, has_player)


# ──────────────────────────────────────────────────────────── 胜负 / HUD

func _update_battle(delta: float) -> void:
	if _battle_over:
		return
	# 视野计时（全队共享）先推进：小地图/血条用的是**上一帧**的状态，晚一帧无所谓
	_update_spotting(delta)
	# 队友/敌人被打光就结束（`_on_vehicle_eliminated` 也会立刻判一次，这里是兜底）
	if _team_alive(TEAM_ENEMY) <= 0:
		_finish_battle(true)
	elif _team_alive(TEAM_PLAYER) <= 0:
		_finish_battle(false)


## 相机/HUD 是每帧刷的，所以血条和小地图也挂在 `_process` 上（物理 120Hz 会白跑两遍）。
func _process(delta: float) -> void:
	super._process(delta)
	_update_combat_hud()
	_refresh_tactical_hud()


## 底部能量条 + 血圈：玩家的能量和"剩余全部零件血量"。
func _update_combat_hud() -> void:
	if _combat_hud == null:
		return
	var energy := float(_player_veh.get("energy", 0.0))
	var energy_max := float(_player_veh.get("energy_max", 0.0))
	var health := 0.0
	if _player_rig != null:
		health = _player_rig.state.health_fraction()
	_combat_hud.set_state(energy, energy_max, health, _player_dead or health <= 0.0)


func _on_vehicle_eliminated(rig: VehicleRig) -> void:
	# 不走基类：基类把每次消灭都记进 `_kills`（那是测试场"打光几台靶子"的口径），
	# 对战里只统计**敌方**被击毁的台数，队友掉了不算战果。
	for veh in _vehicles:
		if veh["rig"] == rig:
			veh["alive"] = false
			veh["wants_fire"] = false
			break
	if rig.team == TEAM_ENEMY:
		_kills += 1
	_last_hit = "%s 被击毁" % rig.label()
	if rig == _player_rig:
		_player_dead = true
		_status = "你被击毁了 —— 看队友打完（ESC 暂停菜单）"
	if _battle_over:
		return
	if _team_alive(TEAM_ENEMY) <= 0:
		_finish_battle(true)
	elif _team_alive(TEAM_PLAYER) <= 0:
		_finish_battle(false)


## 战斗已经结束（胜利/失败画面）：ESC 直接回主界面。
## 结束之后没有别的事可做，再弹暂停菜单反而要多点一次 —— 用户要的就是"按 ESC 走人"。
func _unhandled_input(event: InputEvent) -> void:
	if (
		_battle_over
		and event is InputEventKey and event.pressed and not event.echo
		and event.keycode == KEY_ESCAPE
	):
		get_viewport().set_input_as_handled()
		_quit_to_menu()
		return
	super._unhandled_input(event)


func _finish_battle(won: bool) -> void:
	if _battle_over:
		return
	_battle_over = true
	_battle_won = won
	for veh in _vehicles:
		veh["wants_fire"] = false
	# ⚠️ 这一下可能是从子弹回调里进来的（`Projectiles.step()` → 命中 → 打光一队），
	# 在物理回调里改鼠标模式/刷 HUD 会出怪问题 —— 延到本帧末尾再做。
	_apply_battle_finish.call_deferred()


## 结束画面的收尾（延迟执行）：放鼠标 + 写状态 + 刷 HUD。
func _apply_battle_finish() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_status = "胜利！按 ESC 回主界面" if _battle_won else "失败……按 ESC 回主界面"
	_update_hud()


func _team_alive(team: int) -> int:
	var count := 0
	for veh in _vehicles:
		if int(veh.get("team", -1)) != team or not bool(veh.get("alive", true)):
			continue
		if (veh["rig"] as VehicleRig).state.alive_count() > 0:
			count += 1
	return count


## 拆场时清掉对战自己的状态（视野计时）。下一场是全新的节点，这里只是保险。
func _teardown_mode() -> void:
	_spot.clear()
	_arena = null


func _build_hud() -> void:
	super._build_hud()
	# 小地图占左上角，速度表 / 信息块往右挪，别叠在一起
	_speedo.position = Vector2(BattleMinimap.MAP_SIZE + 26.0, 10.0)
	_hud.position = Vector2(BattleMinimap.MAP_SIZE + 26.0, 10.0 + float(SPEEDO_FONT_SIZE) * 2.6)
	_minimap = BattleMinimap.new()
	_minimap.name = "Minimap"
	_minimap.position = Vector2(12.0, 12.0)
	_minimap.setup(_arena)
	add_child(_minimap)
	# 头顶血条：画在所有 HUD 的**最下面**（开镜时的镜筒遮罩会盖住它，不会出现"黑圈里还浮着血条"）
	_nameplates = VehicleNameplates.new()
	_nameplates.name = "Nameplates"
	_nameplates.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_nameplates)
	move_child(_nameplates, 0)
	# 自己的状态条：底部中央蓝色能量条 + 左边绿色血圈（画在最上层）
	_combat_hud = BattleCombatHud.new()
	_combat_hud.name = "CombatHud"
	_combat_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_combat_hud)
	_banner = Label.new()
	_banner.name = "Banner"
	_banner.anchor_left = 0.0
	_banner.anchor_right = 1.0
	_banner.anchor_top = 0.34
	_banner.anchor_bottom = 0.34
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 46)
	_banner.add_theme_color_override("font_color", Color(1.0, 0.96, 0.86))
	_banner.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_banner.add_theme_constant_override("shadow_offset_x", 3)
	_banner.add_theme_constant_override("shadow_offset_y", 3)
	add_child(_banner)


func _update_hud() -> void:
	super._update_hud()
	if _hud == null:
		return
	var allies := _team_alive(TEAM_PLAYER)
	var enemies := _team_alive(TEAM_ENEMY)
	var roster := _roster_or_default()
	_hud.text = "⚔ 人机对战 · 我方 %d/%d · 敌方 %d/%d%s\n%s" % [
		allies, BattleRoster.team_count(roster, TEAM_PLAYER),
		enemies, BattleRoster.team_count(roster, TEAM_ENEMY),
		" · 你已被击毁" if _player_dead else "",
		_hud.text,
	]
	if _banner != null:
		_banner.text = "" if not _battle_over else ("胜利！" if _battle_won else "失败")


## 对战模式的 HUD 不打测试场那几行调试信息（缩放 / 出生点 / 节点计数）。
func _show_debug_hud() -> bool:
	return false


func _hud_title() -> String:
	return "对战"


func _enemy_word() -> String:
	return "敌人"
