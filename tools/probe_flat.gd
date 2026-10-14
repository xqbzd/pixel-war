extends SceneTree

## 平地板台架：把某台车放在**一块平地板**上（不进城镇模型，排除出生点/地形干扰），
## 落地后静置几秒，每 0.25 秒打印位置/速度/倾角/着地轮数 —— 用来定位"落地就自己跳"这类自激振荡。
##
##   godot --headless --path <项目目录> --script res://tools/probe_flat.gd [车辆id]

const VEHICLE_DIR := "res://data/vehicles"


func _initialize() -> void:
## 第二个参数写 `arena` = **保留城镇场地和靶子、用游戏自己的出生点**（和进游戏一模一样）；
## 不写 = 拆掉场地、铺一块纯平地板（排除地形/出生点干扰）。
##   godot --headless --path . --script res://tools/probe_flat.gd -- custom_2 arena
	var car := "custom_2"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		car = str(args[0])
	var keep_arena := args.size() > 1 and str(args[1]) == "arena"
	var trace := args.size() > 1 and str(args[1]) == "trace"
	var drive_test := args.size() > 1 and str(args[1]) == "drive"
	var TestField := load("res://scripts/test_field.gd")
	TestField.pending_vehicle = {}
	var field: Node = (load("res://scenes/test_field.tscn") as PackedScene).instantiate()
	root.add_child(field)
	await process_frame
	# 拆掉城镇模型，铺一块 400×400 的平板（顶面 y = 0）；`arena` 模式则原样保留
	var arena: Node = field.get("_arena_root")
	if not keep_arena and arena != null:
		field.remove_child(arena)
		arena.queue_free()
		field.set("_arena_model", null)
	if not keep_arena:
		var floor_body := StaticBody3D.new()
		floor_body.collision_layer = 1
		var fshape := CollisionShape3D.new()
		var fbox := BoxShape3D.new()
		fbox.size = Vector3(6000.0, 4.0, 6000.0)
		fshape.shape = fbox
		fshape.position = Vector3(0.0, -2.0, 0.0)
		floor_body.add_child(fshape)
		field.add_child(floor_body)
	if not bool(field.call("enter_vehicle", car)):
		print("进不了车：%s" % str(field.get("_status")))
		quit()
		return
	var chassis: RigidBody3D = field.get("_chassis")
	var rig: VehicleRig = field.get("_player_rig")
	if not keep_arena:
		var box: AABB = rig.geometry_bounds_local()
		chassis.global_position = Vector3(0.0, 0.2 - box.position.y, 0.0)
		chassis.global_rotation = Vector3.ZERO
		chassis.linear_velocity = Vector3.ZERO
		chassis.angular_velocity = Vector3.ZERO
	var wheels: Array = field.get("_wheels")
	print("=== %s：质量 %.0f kg，%d 个轮子 ===" % [car, chassis.mass, wheels.size()])
	if wheels.size() > 0:
		var first: Dictionary = wheels[0]
		print("每轮半径 %.3f 格；单角簧上质量 %.0f kg" % [
			float(first["radius"]),
			float(first.get("corner_mass", 0.0)),
		])
	if trace:
		# 逐**物理帧**打印 2 秒：看静置时到底是谁在推车（周期 / 相位 / 力矩来源）。
		print("--- 逐物理帧（dt = 1/physics_ticks）y=%.3f 起 ---" % chassis.global_position.y)
		print("帧     t       y        vy      |w|     每轮 push|深度")
		for frame in range(240):
			await physics_frame
			var cols := PackedStringArray()
			for w in wheels:
				var e: Dictionary = w
				cols.append("%+.0f|%.4f" % [float(e.get("push", 0.0)), float(e.get("dbg_depth", 0.0))])
			print("%4d %7.4f %8.5f %+8.4f %7.4f  %s" % [
				frame, float(frame) / 120.0, chassis.global_position.y,
				chassis.linear_velocity.y, chassis.angular_velocity.length(),
				" ".join(cols),
			])
		quit()
		return
	if drive_test:
		# 平地直线加速台架：前 1 秒静置（看会不会自己走）→ 全油门 12 秒 → 松油门滑行 3 秒。
		# 打出来的是**真实 m/s**（1 格 = 0.5 米），和部件文件里 `wheel_max_speed` 同一口径。
		print("--- 直线加速（静置 1 秒 → 全油门 12 秒 → 松油门 3 秒）每 0.5 秒一行 ---")
		if wheels.size() > 0:
			print("目标极速 wheel_max_speed = %.1f m/s（内部 %.1f 格/秒）；每轮推力 %.0f N" % [
				float((wheels[0] as Dictionary)["max_speed"]) * PartDef.CUBE_METERS,
				float((wheels[0] as Dictionary)["max_speed"]),
				float((wheels[0] as Dictionary)["engine_force"]),
			])
		print("t      车速     前进速度  y      着地 轮处前进|深度")
		for step in range(32):
			if step == 2:
				Input.action_press("drive_forward")
			if step == 26:
				Input.action_release("drive_forward")
			for _i in range(60):
				await physics_frame
			var upv: Vector3 = chassis.global_transform.basis.y.normalized()
			var rawf: Vector3 = chassis.global_transform.basis.x
			var fwdv := rawf - upv * rawf.dot(upv)
			fwdv = fwdv.normalized() if fwdv.length() > 0.05 else rawf.normalized()
			var cols := PackedStringArray()
			var contact := 0
			for w in wheels:
				var e: Dictionary = w
				if bool(e.get("contact", false)):
					contact += 1
				cols.append("%+.2f|%.3f" % [
					float(e.get("dbg_along", 0.0)), float(e.get("dbg_depth", 0.0)),
				])
			print("%5.1f  %7.2f  %8.2f  %6.3f  %d/%d  %s" % [
				float(step) * 0.5,
				chassis.linear_velocity.length() * PartDef.CUBE_METERS,
				chassis.linear_velocity.dot(fwdv) * PartDef.CUBE_METERS,
				chassis.global_position.y, contact, wheels.size(),
				" ".join(cols),
			])
		quit()
		return
	print("t      y       速度      角速度    倾角    着地     前进      侧向")
	# 前 3 秒**每 4 个物理帧**打一行（含每个轮子的接触量）—— 起跳那一瞬间的跳变全在里面。
	# 每轮五个数：接触深度(格)|轮子自转角速度(rad/s)|纵向力(N)|横向力(N)|接触法向竖直分量
	print("--- 逐帧观察（每 4 帧一行，每轮：深度|轮处前进速度|纵向力|横向力|法向y）---")
	for step in range(90):          # 3 秒
		for _i in range(4):
			await physics_frame
		var contact := 0
		var susp := PackedStringArray()
		for w in wheels:
			var entry: Dictionary = w
			if bool(entry.get("contact", false)):
				contact += 1
			# 每轮：压缩量 / 轮处前进速度 / 纵向力 / 横向力 / 接触法向的竖直分量
			susp.append("%.3f|%.2f|%+.0f|%+.0f|%.2f" % [
				float(entry.get("dbg_depth", 0.0)),
				float(entry.get("dbg_along", 0.0)),
				float(entry.get("dbg_long", 0.0)),
				float(entry.get("dbg_lat", 0.0)),
				float(entry.get("dbg_normal_y", 0.0)),
			])
		var up: Vector3 = chassis.global_transform.basis.y.normalized()
		var raw_fwd: Vector3 = chassis.global_transform.basis.x
		var fwd := raw_fwd - up * raw_fwd.dot(up)
		fwd = fwd.normalized() if fwd.length() > 0.05 else raw_fwd.normalized()
		var right := fwd.cross(up).normalized()
		print("%.2f  %7.3f  %8.3f  %7.3f  %6.1f°  %d/%d  %+7.2f  %+7.2f  %s" % [
			float(step + 1) / 30.0, chassis.global_position.y,
			chassis.linear_velocity.length(), chassis.angular_velocity.length(),
			rad_to_deg(acos(clampf(up.y, -1.0, 1.0))), contact, wheels.size(),
			chassis.linear_velocity.dot(fwd), chassis.linear_velocity.dot(right),
			" ".join(susp),
		])
	for step in range(12):          # 再 3 秒（每 0.25 秒）
		for _i in range(30):
			await physics_frame
		pass
	quit()
	return
	for step in range(24):          # 共 6 秒
		for _i in range(30):        # 0.25 秒（120 Hz）
			await physics_frame
		var contact := 0
		for w in wheels:
			if bool((w as Dictionary).get("contact", false)):
				contact += 1
		var up: Vector3 = chassis.global_transform.basis.y.normalized()
		print("%.2f  %7.3f  %8.3f  %7.3f  %6.1f°  %d/%d" % [
			float(step + 1) * 0.25, chassis.global_position.y,
			chassis.linear_velocity.length(), chassis.angular_velocity.length(),
			rad_to_deg(acos(clampf(up.y, -1.0, 1.0))), contact, wheels.size(),
		])
	quit()
