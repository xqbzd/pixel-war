extends SceneTree

## 轮子跑不跑得动：在测试场里把一台车按物理摆进去，看它落地、着地、开动。
##
##   godot --headless --path <项目目录> --script res://tools/test_drive.gd
##
## 造的测试车：一条直线车身（核心 + 方块）+ 首尾各两个侧挂轮轴，长度可调。
## 期望：4 个轮子全部 contact=true，给油后往 **+x**（车头方向）跑起来。
## 推力方向对不上时症状是"车原地不动"（左右轮推力互相抵消）或往 -x 倒着跑。
##
## 改名/改数值后记得跑一遍 —— 轮子好不好使没法靠看代码确认。
##
## 跑两台对照：
##   短车（3 格，轴距 2 格）—— 重心高、轴距短，动力一大就翘头，用来看"翘头门槛"；
##   长车（6 格，轴距 5 格）—— 正常的车，用来验四个动作：
##     ① 落地：4 轮着地  ② 给油：往 +x 位移
##     ③ 反向键：先刹车（速度掉到 0 附近）再倒车  ④ 全轮转向：重心前 +角 / 重心后 -角
##
## 翘头门槛（写进输出里，调参时照着看）：a_max = g × (重心到后轴的水平距离) / 重心离地高度
## 可用加速度 = 驱动轮数 × wheel_engine_force / 整车质量。可用的比门槛大，一给油就抬头。

const PART_DIR := "res://data/parts"
const AXLE_ID := "toy_wheel_2x2"
## {length: 车身长度（格）}。两个都跑：短车大概率翘头，长车才是"能开"的对照。
const CAR_LENGTHS := [3, 6]


func _initialize() -> void:
	var library := PartLibrary.new()
	library.load_all(PART_DIR)
	var axle := library.get_def(AXLE_ID)
	print("轮轴参数（%s.part.txt）：engine=%.0f N/轮 brake=%.0f max_speed=%.0f m/s friction=%.1f steer_max=%.0f°" % [
		AXLE_ID, axle.wheel_engine_force, axle.wheel_brake, axle.wheel_max_speed,
		axle.wheel_friction, axle.wheel_steer_max,
	])
	# 轮胎的旋转中心必须落在轮胎自己坐标系的正中（y=16, z=16 = 32×32 那个面的中心）：
	# 中心取错 = 轮子一边转一边画圈，看着就是"随机乱转"。
	var sub: VoxVolume = axle.sub_model_volume()
	if sub != null:
		var tight := PartDef.tight_bounds(sub, Vector3.ZERO, Vector3.ONE)
		var pivot := Vector3i(
			roundi(tight.get_center().x * 16.0),
			roundi(tight.get_center().y * 16.0),
			roundi(tight.get_center().z * 16.0)
		)
		print("轮胎旋转中心（轮胎自己坐标系，体素）=%s（y=16、z=16 = 轮胎正中）" % [pivot])
	for length in CAR_LENGTHS:
		await _check_car(library, int(length))
	quit()


## 造一台 length 格长的测试车（核心在头一格，其余方块，首尾各两个侧挂轮轴）。
func _make_vehicle(library: PartLibrary, length: int) -> VehicleDef:
	var axle := library.get_def(AXLE_ID)
	var parts := []
	parts.append({"part_id": "core", "cell": Vector3i(0, 2, 0), "basis": Basis()})
	for x in range(2, length):
		parts.append({"part_id": "cube_full", "cell": Vector3i(x, 2, 0), "basis": Basis()})
	for x in [0, length - 1]:
		for z_side in [1, -1]:
			# 贴在车身 ±z 侧面：hit_dir = (0,0,z_side)，轮轴默认面是 -x
			var hit_dir := Vector3i(0, 0, z_side)
			parts.append({
				"part_id": AXLE_ID,
				"cell": Vector3i(x, 2, 0) + hit_dir,
				"basis": BuildGrid.candidate_basis(axle, -hit_dir),
			})
	var text := "name = 测试小车\n"
	for part in parts:
		var angles := VehicleDef.euler_of(part["basis"])
		text += "part = %s %d %d %d %d %d %d\n" % [
			part["part_id"], part["cell"].x, part["cell"].y, part["cell"].z,
			int(angles.x), int(angles.y), int(angles.z),
		]
	return VehicleDef.from_text(text, "user://probe_car.vehicle.txt")


func _check_car(library: PartLibrary, length: int) -> void:
	var axle := library.get_def(AXLE_ID)
	var vehicle := _make_vehicle(library, length)
	var specs := vehicle.wheel_specs(library)
	var mass := vehicle.total_mass(library)
	var com := vehicle.center_of_mass(library)
	# 几何诊断：翘头门槛（重心到后轴的水平距离 / 重心离地高度）
	var min_x := INF
	var ground := INF
	for spec in specs:
		var offset: Vector3 = spec["offset"]
		min_x = minf(min_x, offset.x)
		ground = minf(ground, offset.y - float(spec["radius"]))
	var height := com.y - ground
	# ⚠️ 单位：力（格世界的 N）/ 质量（kg）算出来是**格/秒²**，换成真实 m/s² 要 ×CUBE_METERS。
	# 门槛那头用的是真实重力 9.8，所以不换算就会把可用加速度高估 5 倍（"明明不翘头却报翘头"）。
	var available := axle.wheel_engine_force * specs.size() / mass * PartDef.CUBE_METERS
	var wheelie_limit := 9.8 * (com.x - min_x) / maxf(0.01, height)
	print("\n=== %d 格车：轴距 %.1f 格，重心离地 %.2f，质量 %.0f kg ===" % [
		length, specs[specs.size() - 1]["offset"].x - specs[0]["offset"].x, height, mass
	])
	print("  动力：%d 轮 × %.0f N / %.0f kg = %.1f m/s²；翘头门槛 %.1f m/s² → %s" % [
		specs.size(), axle.wheel_engine_force, mass, available, wheelie_limit,
		"会翘头" if available > wheelie_limit else "不翘头",
	])
	print("部件 %d 个，警告 %s" % [vehicle.part_count(), str(vehicle.warnings)])
	for spec in specs:
		print("  轮子 offset=%s radius=%.3f 转向符号=%+.0f" % [
			spec["offset"], spec["radius"], float(spec["steer_sign"])
		])
	var field: Node = (load("res://scenes/test_field.tscn") as PackedScene).instantiate()
	root.add_child(field)
	await process_frame  # _ready 在下一帧才跑（库、场地都在那里建）
	field.call("_spawn", vehicle)
	for _i in range(90):  # 1.5 秒：落地 + 悬挂稳定
		await physics_frame
	var chassis: RigidBody3D = field.get("_chassis")
	print("落地 1.5s：位置=%s 速度=%.3f" % [chassis.global_position, chassis.linear_velocity.length()])
	var wheels: Array = field.get("_wheels")
	print("  着地 %d/%d 个轮子" % [_contact_count(wheels), wheels.size()])
	# ② 给油：应该往 +x 跑。同时盯住"最大倾角"和"最少着地轮数"：
	# 翘头（前轮离地）是动力/重心问题，而且会把三维速度点积算成负的（见 ③ 的说明）。
	var start_x: float = chassis.global_position.x
	var max_tilt := 0.0
	var min_contact := wheels.size()
	Input.action_press("drive_forward")
	await process_frame
	print("  油门动作按下=%s" % Input.is_action_pressed("drive_forward"))
	var first: Node3D = wheels[0]["node"]
	print("  头一个轮子：转轴(全局 x)=%s 推力方向(全局 -z)=%s" % [
		first.global_transform.basis.x, -first.global_transform.basis.z
	])
	# ⑤ 轮胎视觉滚动：给油 0.15 秒内，轮胎在**世界坐标**里的转动必须和"向前滚"同向
	# （无滑移滚动角速度 ω = up × v / 半径），而且中心不许跑偏（跑偏 = 绕错点画圈）。
	# 两个判据都只看世界量，不依赖"节点本地 -z 是不是车头"这种约定。
	for _i in range(3):
		await physics_frame
	var bases_before := _tire_bases(wheels)
	var orbit := 0.0
	for _i in range(9):
		await physics_frame
		for i in wheels.size():
			var tire: MeshInstance3D = wheels[i]["mesh"]
			if tire != null:
				# 轮胎中心在自己的节点坐标里必须一直待在原点：跑偏了就是旋转中心取错了
				orbit = maxf(orbit, (tire.transform * (specs[i]["local_centre"] as Vector3)).length())
	var bases_after := _tire_bases(wheels)
	var flat_speed := Vector3(chassis.linear_velocity.x, 0.0, chassis.linear_velocity.z)
	var expected := Vector3.UP.cross(flat_speed)
	if expected.length() < 0.01:
		expected = chassis.global_transform.basis.x
	expected = expected.normalized()
	var dots := PackedStringArray()
	for i in wheels.size():
		var delta_basis: Basis = (bases_after[i] as Basis) * (bases_before[i] as Basis).inverse()
		dots.append("%+.2f" % delta_basis.get_rotation_quaternion().get_axis().dot(expected))
	print("⑤ 给油 0.15s：轮胎转动与「向前滚」同向度=%s（+1 = 正确向前滚，四轮应一致）" % ", ".join(dots))
	print("  轮胎中心跑偏最大=%.3f 格（应 ≈ 0；画圈 = 旋转中心取错）" % orbit)
	for _i in range(78):  # 加上前面的 12 帧，一共 1.5 秒
		await physics_frame
		max_tilt = maxf(max_tilt, _tilt_deg(chassis))
		min_contact = mini(min_contact, _contact_count(wheels))
	# 顺带把"限速靠余弦衰减"这件事打出来：接近 wheel_max_speed 时推力应该已经很小，
	# 而不是到点被硬切成 0（硬切会让车顶着限速一顿一顿）。
	print("② 给油 1.5s：x 位移=%.3f 速度=%s 当前每轮推力=%.0f N（满 %.0f）" % [
		chassis.global_position.x - start_x, chassis.linear_velocity,
		float(wheels[0].get("drive", 0.0)), float(wheels[0]["engine_force"]),
	])
	print("  最大倾角=%.0f°（>20° = 翘头）最少着地=%d/%d" % [
		max_tilt, min_contact, wheels.size()
	])
	Input.action_release("drive_forward")
	for _i in range(180):  # 松油门 3 秒：等它落回地面站稳
		await physics_frame
	print("  松油门 3s：速度=%.2f 着地=%d/%d 位置 y=%.2f" % [
		chassis.linear_velocity.length(), _contact_count(wheels), wheels.size(),
		chassis.global_position.y
	])
	# ③ 反向键自动刹车：给一个已知的前进速度，按 S 应该**先刹车**（速度掉到 0 附近），
	# 而不是立刻倒着加速（那就不是刹车，是"瞬间掉头"）。
	# 这一段自己灌速度，不依赖 ② 剩多少 —— 翘头把速度耗光了也不影响判定。
	var forward_dir: Vector3 = chassis.global_transform.basis.x.normalized()
	chassis.linear_velocity = forward_dir * 6.0
	await physics_frame
	var speed_before: float = chassis.linear_velocity.dot(forward_dir)
	var trace := PackedStringArray()
	Input.action_press("drive_back")
	for _step in range(12):   # 0.8 秒，每 0.067 秒采一个点（"先刹车"这一段要看清楚）
		for _i in range(4):
			await physics_frame
		trace.append("%.1f" % chassis.linear_velocity.dot(forward_dir))
	var speed_braked: float = chassis.linear_velocity.dot(forward_dir)
	for _i in range(60):   # 再 1 秒
		await physics_frame
	Input.action_release("drive_back")
	print("③ 反向键：给 %0.1f m/s 前进速度，按 S 后每 0.067s：%s →（再 1s）%.1f" % [
		speed_before, " ".join(trace), chassis.linear_velocity.dot(forward_dir)
	])
	# ④ 全轮转向：原地低速打方向（W + A），车头应该转起来；
	# 各轮转角**重心前为正、重心后为负** —— 前后反转才是"全轮转向"，同号就只是普通前轮转向。
	# 先把速度清零再测：不然"车头转了多少度"里混着上一段倒车的惯性，连方向都会反。
	chassis.linear_velocity = Vector3.ZERO
	chassis.angular_velocity = Vector3.ZERO
	for _i in range(120):   # 站稳
		await physics_frame
	chassis.linear_velocity = Vector3.ZERO
	var heading_before := _heading_deg(chassis)
	Input.action_press("drive_forward")
	Input.action_press("drive_left")
	# 缓启动：按下 A 后**头几帧**的转角应该还很小（受 `wheel_steer_speed` 限制），
	# 而不是一帧就打满 —— 这里采样前 0.05 秒，看一眼它是不是"转过去"而不是"瞬移"。
	var early := 0.0
	var early_trace := PackedStringArray()
	for _i in range(3):
		await physics_frame
		var frame_max := 0.0
		for entry in wheels:
			frame_max = maxf(frame_max, absf(float(entry["steer"])))
		early = maxf(early, frame_max)
		early_trace.append("%.1f°" % rad_to_deg(frame_max))
	for _i in range(60):   # 1 秒
		await physics_frame
	Input.action_release("drive_forward")
	var angles := PackedStringArray()
	for entry in wheels:
		angles.append("%+.0f°" % rad_to_deg(float(entry["steer"])))
	Input.action_release("drive_left")
	var full_lock := 0.0
	for entry in wheels:
		full_lock = maxf(full_lock, rad_to_deg(absf(float(entry["steer_max"]))))
	print("④ 缓启动：按 A 之后 3 帧（120Hz 下 0.025 秒）只转到 %.1f°（满角 %.0f° —— 瞬移就是满角）" % [
		rad_to_deg(early), full_lock
	])
	print("   逐帧（转角的绝对值）：%s" % " → ".join(early_trace))
	print("   车头转了 %+.1f°（非 0 = 转向生效）各轮转角：%s" % [
		wrapf(_heading_deg(chassis) - heading_before, -180.0, 180.0), ", ".join(angles)
	])
	# 换下台车之前把这一台清掉（不然两台车叠在一起，物理互相打架）
	field.queue_free()
	await process_frame


## 还在着地的轮子数
func _contact_count(wheels: Array) -> int:
	var total := 0
	for entry in wheels:
		if bool(entry.get("contact", false)):
			total += 1
	return total


## 每个轮胎网格在**世界坐标**里的朝向（用来算它到底朝哪边转）。
func _tire_bases(wheels: Array) -> Array:
	var out := []
	for i in wheels.size():
		var mesh: MeshInstance3D = wheels[i]["mesh"]
		out.append(mesh.global_transform.basis if mesh != null else Basis())
	return out


## 车体倾角（度，0 = 正立）：翘头/翻车时立刻能从这一个数上看出来。
func _tilt_deg(node: Node3D) -> float:
	var up := node.global_transform.basis.y.normalized()
	return rad_to_deg(acos(clampf(up.y, -1.0, 1.0)))


## 车头朝向（度）：用底盘本地 +x 在地面上的投影算，只看变化量。
func _heading_deg(node: Node3D) -> float:
	var forward := node.global_transform.basis * Vector3(1, 0, 0)
	return rad_to_deg(atan2(forward.z, forward.x))
