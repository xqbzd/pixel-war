extends SceneTree

## 真正运行 Jolt 的悬挂回归：落地、俯仰/侧倾收敛、轮数/射线数不改变平衡高度、侧面接触和离地。
## godot --headless --path . --fixed-fps 120 --script res://tools/test_suspension_physics.gd

class WheelBench extends TestField:
	func _ready() -> void:
		_library.load_all("res://data/parts")

	func _process(_delta: float) -> void:
		pass

	func _physics_process(delta: float) -> void:
		_space = get_world_3d().direct_space_state
		for veh: Dictionary in _vehicles:
			for wheel: Dictionary in veh["wheels"]:
				_apply_wheel(veh, wheel, delta)


var _failed := 0
var _checks := 0
var _bench: WheelBench


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		print("FAIL: %s" % message)


func _box(parent: Node3D, size: Vector3, position: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.position = position
	return body


func _vehicle(mass: float, count: int, rays: int, position: Vector3, travel := 1.2) -> Dictionary:
	var body := RigidBody3D.new()
	body.mass = mass
	body.can_sleep = false
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = Vector3.ZERO
	body.inertia = Vector3(2.0, 4.0, 4.0) * mass
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	body.angular_damp = 0.0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.0, 1.0, 2.0)
	shape.shape = box
	shape.position.y = 1.5
	body.add_child(shape)
	_bench.add_child(body)
	body.position = position
	var def := _bench._library.get_def("toy_wheel_2x2")
	def.wheel_rays = rays
	def.wheel_suspension_travel = travel
	var specs := []
	var columns := count / 2
	for i in count:
		var offset := Vector3(lerpf(-2.0, 2.0, float(i / 2) / float(columns - 1)),
			0.0, -1.5 if i % 2 == 0 else 1.5)
		specs.append({
			"part_id": def.id, "part_index": i, "radius": 1.0,
			"transform": Transform3D(Basis(Vector3.UP, PI / 2.0), offset),
			"offset": offset, "local_centre": Vector3.ZERO,
		})
	var veh := {"chassis": body, "wheels": [], "is_player": false}
	_bench._initialize_vehicle_wheels(veh, specs)
	for wheel: Dictionary in veh["wheels"]:
		wheel["drive"] = 0.0
	_bench._vehicles.append(veh)
	return veh


func _run() -> void:
	_bench = WheelBench.new()
	root.add_child(_bench)
	_box(_bench, Vector3(600.0, 4.0, 600.0), Vector3(0.0, -2.0, 0.0))
	var cases := []
	for config in [[230.0, 4, 0], [230.0, 4, 16], [530.0, 4, 16],
		[2270.0, 8, 16], [2270.0, 8, 32]]:
		var veh := _vehicle(config[0], config[1], config[2], Vector3(cases.size() * 25.0, 2.5, 0.0))
		(veh["chassis"] as RigidBody3D).rotation = Vector3(0.04, 0.0, -0.04)
		cases.append({"vehicle": veh, "min_y": INF, "max_y": -INF, "config": config})
	# 含初始倾斜的 1.5 格落地；记录最后一秒是否仍在振荡。
	for frame in 720:
		await physics_frame
		if frame < 600:
			continue
		for item: Dictionary in cases:
			var body: RigidBody3D = item["vehicle"]["chassis"]
			item["min_y"] = minf(item["min_y"], body.position.y)
			item["max_y"] = maxf(item["max_y"], body.position.y)
	for item: Dictionary in cases:
		var veh: Dictionary = item["vehicle"]
		var body: RigidBody3D = veh["chassis"]
		var support := 0.0
		var contacts := 0
		for wheel: Dictionary in veh["wheels"]:
			support += float(wheel["push"])
			contacts += 1 if wheel["contact"] else 0
		var label := str(item["config"])
		print("SETTLED %s y=%.5f speed=%.6f angular=%.6f contact=%d load=%.5f span=%.6f" % [
			label, body.position.y, body.linear_velocity.length(), body.angular_velocity.length(),
			contacts, support / (body.mass * PartDef.GRAVITY_CUBES), item["max_y"] - item["min_y"]])
		_check(absf(body.position.y - 1.0) < 0.025, label + " 保持建造时轮心高度")
		_check(body.linear_velocity.length() < 0.02, label + " 静置线速度收敛")
		_check(body.angular_velocity.length() < 0.02, label + " 俯仰/侧倾收敛")
		_check(float(item["max_y"]) - float(item["min_y"]) < 0.005, label + " 无持续跳动")
		_check(contacts == int(veh["initial_wheel_count"]), label + " 全轮接地")
		_check(absf(support / (body.mass * PartDef.GRAVITY_CUBES) - 1.0) < 0.02, label + " 总力平衡车重")
	# 毁伤后的动力学：失去一半质量和一半轮胎，剩余悬挂保持原快照继续模拟。
	var damaged: Dictionary = cases[3]["vehicle"]
	var damaged_body: RigidBody3D = damaged["chassis"]
	var damaged_wheels: Array = damaged["wheels"]
	var initial_k := float(damaged_wheels[0]["stiffness"])
	var initial_c := float(damaged_wheels[0]["damping"])
	damaged_body.mass *= 0.5
	for index in [5, 4, 3, 2]:
		(damaged_wheels[index]["node"] as Node3D).queue_free()
		damaged_wheels.remove_at(index)
	for frame in 360:
		await physics_frame
	_check(damaged_body.linear_velocity.length() < 0.02, "毁伤后幸存悬挂继续稳定支撑")
	_check(absf(damaged_body.position.y - 1.0) < 0.025, "同比例减重减轮后平衡高度保持")
	for surviving: Dictionary in damaged_wheels:
		_check(float(surviving["stiffness"]) == initial_k and float(surviving["damping"]) == initial_c,
			"毁伤模拟不重算刚度和阻尼")
	# 将首车抬离地面，在轮胎侧面放障碍，验证只靠整圈射线也能形成接触。
	var target: Dictionary = cases[0]["vehicle"]
	var body: RigidBody3D = target["chassis"]
	body.freeze = true
	body.position = Vector3(-40.0, 10.0, 0.0)
	body.rotation = Vector3.ZERO
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	await physics_frame
	await physics_frame
	var wheel: Dictionary = target["wheels"][0]
	_check(not wheel["contact"] and is_zero_approx(wheel["push"]), "腾空立即清空接触和支撑")
	var node: Node3D = wheel["node"]
	var centre := node.global_position + node.global_basis.x * float(wheel["ray_shift"])
	var wall := _box(_bench, Vector3(0.3, 1.0, 1.0), centre + Vector3(0.8, 0.0, 0.0))
	await physics_frame
	await physics_frame
	_check(not wheel["contact"], "主射线不能探测侧方障碍")
	wheel["rays"] = 16
	await physics_frame
	await physics_frame
	_check(wheel["contact"] and float(wheel["push"]) > 0.0, "整圈射线单独命中也算接地")
	_check(absf(float(wheel["dbg_normal_y"])) < 0.001, "侧面接触采用实际表面法线")
	var ring_push := float(wheel["push"])
	wheel["rays"] = 32
	await physics_frame
	await physics_frame
	_check(absf(float(wheel["push"]) - ring_push) < 0.01, "增加射线不会叠加支撑力")
	wall.queue_free()
	await physics_frame
	await physics_frame
	_check(not wheel["contact"] and is_zero_approx(wheel["push"]), "失去侧方接触也清空载荷")
	# 倾斜接触面采用真实法线，不把沿悬挂轴/沿射线方向当成地面法线。
	var slope := _box(_bench, Vector3(6.0, 0.2, 6.0), centre + Vector3(0.0, -0.9, 0.0))
	slope.rotation.z = deg_to_rad(20.0)
	await physics_frame
	await physics_frame
	var slope_contact := _bench._wheel_contact(body, wheel)
	_check(not slope_contact.is_empty(), "主射线能命中坡面")
	if not slope_contact.is_empty():
		_check((slope_contact["normal"] as Vector3).dot(slope.global_basis.y) > 0.999,
			"支撑方向跟随坡面法线")
	slope.queue_free()
	# 参数已经存入车轮快照，后来的部件定义变化不能修改旧车。
	_check(is_equal_approx(float(wheel["travel"]), 1.2), "进场参数快照仍然有效")
	print("SUSPENSION_PHYSICS CHECKS=%d FAILED=%d" % [_checks, _failed])
	_bench.queue_free()
	await process_frame
	quit(1 if _failed > 0 else 0)
