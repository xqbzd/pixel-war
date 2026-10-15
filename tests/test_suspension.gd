@tool
extends McpTestSuite


func suite_name() -> String:
	return "suspension"


func _near(actual: float, expected: float, message: String) -> void:
	assert_true(absf(actual - expected) <= maxf(0.0001, absf(expected) * 0.00001),
		"%s：实际 %s，期望 %s" % [message, actual, expected])


func test_bottom_force_and_static_sag_across_masses_and_wheel_counts() -> void:
	var def := PartDef.new()
	for mass: float in [230.0, 530.0, 2270.0, 10000.0]:
		for count: int in [2, 4, 8, 16]:
			for travel: float in [0.05, 0.3, 1.2, 2.0]:
				def.wheel_suspension_travel = travel
				for multiple: float in [2.0, 8.0, 12.0]:
					def.wheel_support_multiple = multiple
					var params := def.resolved_suspension(mass, count)
					var weight := mass * PartDef.GRAVITY_CUBES
					_near(TestField.suspension_force(travel, 0.0, params) * count,
						weight * multiple, "触底弹簧总力必须按整车重量计算")
					_near(TestField.suspension_force(travel / multiple, 0.0, params) * count,
						weight, "静态平衡载荷不受阻尼稀释")
					_near(params["rest"], travel, "触底长度应恰好为零")
					_near(params["static_compression"], travel / multiple, "平衡位置一致")


func test_damping_is_critical_for_the_initial_corner_mass() -> void:
	var def := PartDef.new()
	var light := def.resolved_suspension(230.0, 4)
	var heavy := def.resolved_suspension(2300.0, 4)
	_near(heavy["stiffness"], light["stiffness"] * 10.0, "刚度随初始单轮质量缩放")
	_near(heavy["damping"], light["damping"] * 10.0, "临界阻尼同样随质量缩放")
	for params: Dictionary in [light, heavy, def.resolved_suspension(2300.0, 8)]:
		_near(pow(float(params["damping"]), 2.0),
			4.0 * float(params["stiffness"]) * float(params["corner_mass"]), "临界阻尼判别式")


func test_compression_and_rebound_force_are_bounded() -> void:
	var params := PartDef.new().resolved_suspension(800.0, 4)
	var sag := float(params["static_compression"])
	var rest_force := TestField.suspension_force(sag, 0.0, params)
	assert_true(TestField.suspension_force(sag, 0.1, params) > rest_force, "压缩时阻尼增加支撑")
	assert_true(TestField.suspension_force(sag, -0.1, params) < rest_force, "回弹时阻尼减小支撑")
	_near(TestField.suspension_force(sag, -1000.0, params), 0.0, "不能把车拉进地面")
	_near(TestField.suspension_force(100.0, 1000.0, params), params["max_force"], "触底限力")
	_near(TestField.suspension_force(0.0, 0.0, params), 0.0, "未压缩时无弹簧力")


func test_new_tuning_defaults_and_invalid_values() -> void:
	var bare := PartDef.new()
	_near(bare.wheel_support_multiple, 8.0, "未配置时倍率为 8")
	var bad := PartDef.from_text(
		"name = invalid\nshape = cube\nwheel_suspension_travel = 0\nwheel_support_multiple = -1\n",
		"user://bad_suspension.part.txt"
	)
	assert_eq(bad.warnings.size(), 2, "非法行程/倍率各有一条警告")
	_near(bad.wheel_suspension_travel, bare.wheel_suspension_travel, "行程保留默认值")
	_near(bad.wheel_support_multiple, 8.0, "倍率保留默认值")
	var nonfinite := PartDef.from_text(
		"name = overflow\nshape = cube\nwheel_suspension_travel = 1e999\nwheel_support_multiple = 1e999\n",
		"user://nonfinite_suspension.part.txt"
	)
	_near(nonfinite.wheel_suspension_travel, bare.wheel_suspension_travel, "无穷行程不进入物理")
	_near(nonfinite.wheel_support_multiple, 8.0, "无穷倍率不进入物理")


func test_legacy_limits_cannot_override_the_bottom_multiplier() -> void:
	var def := PartDef.from_text(
		"name = legacy\nshape = cube\nwheel_support_multiple = 8\n"
		+ "wheel_stiffness = 300000\nwheel_damper_compression = 2000\n"
		+ "wheel_suspension_max_force = 1\nwheel_peak_force_car_weights = 0.01\n",
		"user://legacy_suspension.part.txt"
	)
	assert_eq(def.warnings.size(), 4, "旧悬挂参数明确提示弃用")
	var params := def.resolved_suspension(800.0, 8)
	_near(TestField.suspension_force(params["travel"], 0.0, params) * 8.0,
		8.0 * 800.0 * PartDef.GRAVITY_CUBES, "旧限力不影响新倍率")


func test_damage_keeps_surviving_wheel_parameters_and_initial_counts() -> void:
	var library := PartLibrary.new()
	library.load_all("res://data/parts")
	var path := "res://data/vehicles/custom_2.vehicle.txt"
	var vehicle := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)
	var field := TestField.new()
	track(field)
	field._library = library
	var chassis := RigidBody3D.new()
	chassis.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	field.add_child(chassis)
	var rig := VehicleRig.new()
	rig.setup(vehicle, library, chassis, chassis, true)
	var veh := {"rig": rig, "chassis": chassis, "wheels": [], "is_player": false}
	field._vehicles.append(veh)
	var specs := vehicle.wheel_specs(library)
	field._initialize_vehicle_wheels(veh, specs)
	var initial_mass := chassis.mass
	var wheels: Array = veh["wheels"]
	assert_true(wheels.size() >= 4, "回归样车至少四轮")
	if wheels.size() < 4:
		return
	var before := {}
	var keys := ["stiffness", "damping", "corner_mass", "max_force", "rest", "travel", "hub"]
	for wheel: Dictionary in wheels:
		var values := []
		for key in keys:
			values.append(wheel[key])
		before[wheel["part_index"]] = values
		assert_true((wheel["node"] as Node3D).position.is_equal_approx(wheel["offset"]),
			"初始轮心保留建造高度")
	var result := rig.apply_damage(int(wheels[0]["part_index"]), 4000.0)
	field._on_parts_destroyed(rig, VehicleRig._all_dead(result))
	assert_true(chassis.mass < initial_mass, "实际毁伤应更新刚体质量")
	assert_true(wheels.size() > 0 and wheels.size() < specs.size(), "损坏车轮被移除")
	# 即使误触初始化入口，也不能按剩余车重/轮数重算或复活损坏轮。
	var remaining := wheels.size()
	field._initialize_vehicle_wheels(veh, specs)
	assert_eq(wheels.size(), remaining, "初始化幂等")
	_near(veh["initial_mass"], initial_mass, "初始整车质量快照")
	assert_eq(veh["initial_wheel_count"], specs.size(), "初始轮胎总数快照")
	for wheel: Dictionary in wheels:
		for i in keys.size():
			assert_eq(wheel[keys[i]], before[wheel["part_index"]][i], "毁伤不能改变 %s" % keys[i])


func test_wheelless_vehicle_initializes_without_division_by_zero() -> void:
	var field := TestField.new()
	track(field)
	var chassis := RigidBody3D.new()
	field.add_child(chassis)
	var veh := {"chassis": chassis, "wheels": []}
	field._initialize_vehicle_wheels(veh, [])
	assert_eq(veh["initial_wheel_count"], 0, "无轮车辆也保留正确初始轮数")
	assert_true((veh["wheels"] as Array).is_empty(), "无轮车不创建悬挂")
