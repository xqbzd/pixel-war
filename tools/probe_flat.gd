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
		fbox.size = Vector3(400.0, 4.0, 400.0)
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
	print("t      y       速度      角速度    倾角    着地")
	# 前 3 秒**每 4 个物理帧**打一行（含每个轮子的悬挂长度）—— 起跳那一瞬间的跳变全在里面。
	print("--- 逐帧观察（每 4 帧一行，susp = 每个轮子的悬挂长度，格）---")
	for step in range(90):          # 3 秒
		for _i in range(4):
			await physics_frame
		var contact := 0
		var susp := PackedStringArray()
		for w in wheels:
			var entry: Dictionary = w
			if bool(entry.get("contact", false)):
				contact += 1
			# 每轮：压缩量 / 轮子角速度 / 纵向力 / 横向力 / 接触法向的竖直分量
			susp.append("%.3f|%.2f|%+.0f|%+.0f|%.2f" % [
				float(entry.get("dbg_depth", 0.0)),
				float(entry.get("ang_vel", 0.0)),
				float(entry.get("dbg_long", 0.0)),
				float(entry.get("dbg_lat", 0.0)),
				float(entry.get("dbg_normal_y", 0.0)),
			])
		var up: Vector3 = chassis.global_transform.basis.y.normalized()
		print("%.2f  %7.3f  %8.3f  %7.3f  %6.1f°  %d/%d  %s" % [
			float(step + 1) / 30.0, chassis.global_position.y,
			chassis.linear_velocity.length(), chassis.angular_velocity.length(),
			rad_to_deg(acos(clampf(up.y, -1.0, 1.0))), contact, wheels.size(),
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
