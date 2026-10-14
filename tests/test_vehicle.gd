@tool
extends McpTestSuite

## 载具数据 + 部件库的自测：文件能解析、引用的部件存在、没有同格重叠、
## 包围盒与实例化统计符合预期。这些断言同时是 *.vehicle.txt 格式的可执行说明书。

const PART_DIR := "res://data/parts"
const VEHICLE_DIR := "res://data/vehicles"


func suite_name() -> String:
	return "vehicle"


func _library() -> PartLibrary:
	var library := PartLibrary.new()
	library.load_all(PART_DIR)
	return library


func _vehicle(id: String) -> VehicleDef:
	for vehicle in VehicleDef.load_all(VEHICLE_DIR):
		if vehicle.id == id:
			return vehicle
	return null


func assert_vec_almost_eq(actual: Vector3, expected: Vector3, tol: float, msg: String = "") -> void:
	assert_true(
		(actual - expected).length() <= tol,
		"%s（实际 %s，期望 %s）" % [msg, str(actual), str(expected)]
	)


## `bounds()`（声明 cubes 盒子）和 `actual_bounds()`（网格包围盒，含轮胎）的区别。
## 主界面预览和出生点贴地**必须**用 `actual_bounds()` —— 轮胎挂在车体盒子外面，
## 用 `bounds()` 算"车底"会算高一截、半个轮胎插进地里（用户报的）。
func test_actual_bounds_catches_the_wheels_below_the_declared_box() -> void:
	var library := _library()
	var vehicle := VehicleDef.from_text(
		(
			"name = 贴地测试\n"
			+ "part = core 0 2 0 0 0 0\n"
			+ "part = wheel_axle_2x2 2 0 0 0 0 0\n"
		),
		"user://ground_probe.vehicle.txt"
	)
	assert_eq(vehicle.warnings.size(), 0, "测试车不该有警告：%s" % str(vehicle.warnings))
	var declared := vehicle.bounds(library)
	var actual := vehicle.actual_bounds(library)
	# 轮体是挂在轮轴盒子下面的：真实包围盒必须**更低**、也更高一点
	assert_true(
		actual.position.y < declared.position.y - 0.01,
		"真实车底应该比声明盒子低（轮胎挂在外头）：声明 %s vs 真实 %s"
		% [declared.position.y, actual.position.y]
	)
	assert_true(
		actual.size.y > declared.size.y + 0.01,
		"真实高度应该更高：%s vs %s" % [declared.size.y, actual.size.y]
	)
	# 贴地时按它抬：抬完之后最低点正好落在 y = 0
	var lifted := -actual.position.y
	assert_true(
		is_equal_approx(actual.position.y + lifted, 0.0), "抬高量应该让最低点刚好落在 y = 0"
	)
	# 拿声明盒子抬就会差出"轮胎那一截"（这正是以前预览/出生点埋地的量）
	var wrong := -declared.position.y
	assert_true(
		actual.position.y + wrong < -0.01,
		"拿声明盒子抬，车底会留在 -%.2f 处（就是那一截埋进地里的量）" % -(actual.position.y + wrong)
	)
	# 没有轮子的车：两个包围盒的最低点应该一样（这条防"改过头"）
	var plain := VehicleDef.from_text(
		"name = 平板\npart = core 0 0 0 0 0 0\n", "user://plain_probe.vehicle.txt"
	)
	assert_true(
		is_equal_approx(
			plain.actual_bounds(library).position.y, plain.bounds(library).position.y
		),
		"没有附属子模型的零件，两种包围盒的最低点应该一致"
	)


func test_part_files_load_without_warnings() -> void:
	var library := _library()
	assert_eq(library.warnings.size(), 0, "部件文件应无警告：%s" % str(library.warnings))
	assert_eq(
		library.ids().size(),
		7,
		"应有 7 个可放置部件：4 个解析形状 + 车轮 + 轻机枪 + 核心（轮体只是浮在轮轴上的模型，不是部件）"
	)


func test_vehicle_files_parse_without_warnings() -> void:
	var vehicles := VehicleDef.load_all(VEHICLE_DIR)
	assert_gt(vehicles.size(), 0, "至少要有一个载具文件")
	for vehicle in vehicles:
		assert_eq(vehicle.warnings.size(), 0, "%s 的解析警告：%s" % [vehicle.id, str(vehicle.warnings)])
		assert_gt(vehicle.part_count(), 0, "%s 应该至少有一个部件" % vehicle.id)
		assert_false(vehicle.display_name.is_empty(), "%s 应该有名字" % vehicle.id)


func test_vehicle_parts_exist_and_do_not_overlap() -> void:
	var library := _library()
	for vehicle in VehicleDef.load_all(VEHICLE_DIR):
		for part_id in vehicle.used_part_ids():
			assert_true(library.has_part(part_id), "%s 引用了不存在的部件 %s" % [vehicle.id, part_id])
		# 注意：**声明格子相同不算错**（多零件共享格子是允许的：一个格子只放一个"基准格"，
		# 但别的零件的非基准格可以共存）。真正的判据是"能不能原样摆回去" ——
		# 体素不穿模 + 基准格不撞，这两条走 BuildGrid 的规则，和装载时用的是同一套。
		# 用户报过：第四个轮子的声明格 (4,4,4) 正好压着一个方块的格子，但两者根本没碰面。
		var grid := BuildGrid.new()
		grid.set_defs(library.defs)
		var failed := PackedStringArray()
		for part in vehicle.parts:
			var def: PartDef = library.get_def(part["part_id"])
			if def == null:
				continue
			var result := grid.place(def, part["cell"], part["basis"])
			if not result.get("ok", false):
				failed.append("%s @%s：%s" % [part["part_id"], part["cell"], result.get("reason", "")])
		assert_true(failed.is_empty(), "%s 有零件摆不回去：%s" % [vehicle.id, ", ".join(failed)])


func test_scout_bounds_and_counts() -> void:
	var library := _library()
	var scout := _vehicle("scout")
	assert_true(scout != null, "缺少 scout.vehicle.txt")
	var box := scout.bounds(library)
	assert_eq(box.position, Vector3(0, 0, 0), "scout 包围盒起点")
	assert_eq(box.size, Vector3(5, 2, 2), "scout 包围盒尺寸（长 5，含楔形车头那一格）")
	assert_eq(scout.part_count(), 14, "scout 部件数")
	assert_eq(scout.cube_count(library), 14, "scout cube 数（全是 1 cube 部件）")


func test_instantiate_groups_by_part() -> void:
	var library := _library()
	var scout := _vehicle("scout")
	var result := scout.instantiate(library)
	assert_eq(result["missing"].size(), 0, "不应有缺失部件")
	assert_eq(result["instances"], scout.part_count(), "实例数应等于部件数")
	assert_eq(result["groups"], 2, "scout 用 cube_full + half_cube_xy → 2 个批次")
	var mesh_instances := 0
	for child in (result["node"] as Node3D).get_children():
		if child is MultiMeshInstance3D:
			mesh_instances += 1
	assert_eq(mesh_instances, 2, "每个批次一个 MultiMeshInstance3D")
	assert_gt(int(result["tris"]), 0, "应统计出三角形数")


func test_missing_part_is_skipped_not_crashing() -> void:
	var library := _library()
	var vehicle := VehicleDef.from_text("part = does_not_exist 0 0 0 0\npart = cube_full 1 0 0 0\n")
	var result := vehicle.instantiate(library)
	assert_eq(result["missing"].size(), 1, "缺失部件应被记录而不是崩掉")
	assert_eq(result["instances"], 1, "存在的部件照常实例化")


func test_yaw_is_snapped_to_90_degrees() -> void:
	var odd := VehicleDef.from_text("part = cube_full 0 0 0 20\n")
	assert_eq(odd.parts[0]["yaw"], 0.0, "20 度应吸附到 0 度")
	assert_gt(odd.warnings.size(), 0, "非 90 倍数应留下警告")
	var fine := VehicleDef.from_text("part = cube_full 0 0 0 270\n")
	assert_eq(fine.parts[0]["yaw"], 270.0, "270 度保持不变")
	assert_eq(fine.warnings.size(), 0, "90 的倍数不该有警告")


## 建造场地地板：灰色底 + 灰蓝格线，一格 = 一个 cube，带 mipmap 防止远处闪烁。
func test_build_floor_tile_is_gray_with_gray_blue_grid() -> void:
	assert_eq(
		VehicleViewer.BUILD_AREA_CUBES,
		Vector3i(64, 64, 64),
		"建造场地是 64 x 64 x 64 cube"
	)
	var image := VehicleViewer.make_floor_texture().get_image()
	assert_eq(
		image.get_size(),
		Vector2i(VehicleViewer.FLOOR_TEXELS_PER_CUBE, VehicleViewer.FLOOR_TEXELS_PER_CUBE),
		"一个 cube 格子 = 16 x 16 texel"
	)
	assert_true(image.has_mipmaps(), "地板贴图要有 mipmap，远处才不闪")
	assert_true(
		image.get_pixel(0, 0).is_equal_approx(VehicleViewer.FLOOR_LINE),
		"格子左上角应是灰蓝格线"
	)
	assert_true(
		image.get_pixel(8, 8).is_equal_approx(VehicleViewer.FLOOR_FILL),
		"格子内部应是灰色底"
	)
	var line := VehicleViewer.FLOOR_LINE
	assert_gt(
		line.get_luminance(),
		VehicleViewer.FLOOR_FILL.get_luminance() + 0.08,
		"格线要比底色亮，否则看不出格子"
	)
	assert_gt(line.b - line.r, 0.1, "格线要偏蓝（灰蓝），不是纯灰")


## 车库光照必须是“全向柔光”：环境光来自天空（IBL），方向光只负责软接触阴影。
## 这条断言防止有人为了把画面调亮，又把方向光调回“塑形”的强度（棱柱会重新出现明暗条纹）。
func test_garage_lighting_is_omnidirectional_and_soft() -> void:
	var environment := VehicleViewer.make_garage_environment()
	assert_eq(
		environment.ambient_light_source,
		Environment.AMBIENT_SOURCE_SKY,
		"环境光应来自天空（全向柔光），而不是一个固定色"
	)
	assert_true(environment.sky != null, "要有天空才谈得上 IBL")
	var sun := VehicleViewer.make_garage_sun()
	assert_gt(sun.light_angular_distance, 2.0, "方向光要拉开半影，阴影才不锐利")
	assert_true(sun.light_energy < 0.5, "方向光只做接触阴影，不该拿来塑形")


## 朝向要能存进文件：贴墙 / 贴三角面会产生绕 X 或 Z 的旋转，只用 yaw 表达不了。
## 这里验证 (yaw, pitch, roll) 与 Basis 的双向转换在轴对齐朝向上是精确的
## （Godot 的 YXZ 欧拉分解在万向锁附近可能给出怪值，所以必须用断言守住）。
func test_orientation_euler_round_trip() -> void:
	var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	var orders := [
		[0], [1], [2],
		[0, 1], [1, 0], [0, 2], [2, 0], [1, 2], [2, 1],
		[0, 1, 2], [2, 1, 0], [1, 0, 2], [1, 2, 0], [0, 2, 1], [2, 0, 1],
	]
	for order in orders:
		var basis := Basis()
		for axis_index in order:
			basis = basis * Basis(axes[axis_index], deg_to_rad(90.0))
		basis = BuildGrid.snap_basis(basis)
		var angles := VehicleDef.euler_of(basis)
		var back := VehicleDef.euler_basis(angles.y, angles.x, angles.z)
		assert_true(
			back.is_equal_approx(basis),
			"朝向 %s（euler %s）转成角度 %s 后再转回来应完全相同" % [
				str(basis.get_euler()), str(basis.get_euler()), str(angles)
			]
		)


## 保存 → 重新解析 → 摆放：格子**原样**保存（不归一化）、朝向、几何位置都要对得上。
## 曾经归一化到最小角 0,0,0，结果装着轮子的车一存一读，轮子被压到最底排就整排消失。
func test_save_reload_round_trip() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var ramp := library.get_def("half_cube")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var cells := [Vector3i(0, 0, 0), Vector3i(2, 1, 0), Vector3i(2, 1, 2), Vector3i(-3, 0, 4)]
	var bases := [
		Basis(),
		BuildGrid.snap_basis(Basis(Vector3.RIGHT, deg_to_rad(-90.0))),
		BuildGrid.snap_basis(Basis(Vector3.UP, deg_to_rad(90.0))),
		BuildGrid.snap_basis(Basis(Vector3.BACK, deg_to_rad(90.0))),
	]
	for i in range(cells.size()):
		var def: PartDef = cube if i == 0 else ramp
		var placed := grid.place(def, cells[i], bases[i])
		assert_true(placed["ok"], "应能放下第 %d 块：%s" % [i, str(placed.get("reason", ""))])
	var entries := []
	# _grid.parts 每个零件一份（多零件共享格子也不会重复）
	for entry: Dictionary in grid.parts:
		entries.append({
			"part_id": entry["part_id"], "cell": entry["origin"], "basis": entry["basis"],
		})
	var path := "user://round_trip_test.vehicle.txt"
	var written := VehicleDef.write_file(path, "往返测试", entries)
	assert_true(written["ok"], "写出应成功：%s" % str(written.get("reason", "")))
	var reloaded := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)
	assert_eq(reloaded.warnings.size(), 0, "重新解析不该有警告：%s" % str(reloaded.warnings))
	assert_eq(reloaded.part_count(), entries.size(), "部件数应一致")
	var before_by_key := {}
	for entry in entries:
		before_by_key[str(entry["cell"])] = entry
	for part in reloaded.parts:
		var key := str(part["cell"])
		assert_true(before_by_key.has(key), "重解析出现多余部件 %s" % key)
		if not before_by_key.has(key):
			continue
		var before: Dictionary = before_by_key[key]
		assert_eq(part["part_id"], before["part_id"], "%s 的部件类型应一致" % key)
		assert_true((part["basis"] as Basis).is_equal_approx(before["basis"]), "%s 的朝向应一致" % key)
		var def_after: PartDef = library.get_def(part["part_id"])
		var t_after := BuildGrid.cell_transform(def_after, part["cell"], part["basis"])
		var t_before := BuildGrid.cell_transform(def_after, before["cell"], before["basis"])
		assert_true(
			t_after.origin.is_equal_approx(t_before.origin),
			"%s 的几何摆放应**一格不差**（不归一化）" % key
		)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## 回归（用户报的 bug）：带轮子的车"保存退出 → 再进"以后轮子整排消失。
## 原因是保存时把坐标归一化到最小角 0,0,0，轮子被压到最底排，而它的网格要往下探
## 3 像素 → 加载时判定超框，整排被跳过。现在保存不归一化，加载只在**必要时**
## 整体挪最小的量把载具塞进场地（`BuildGrid.fit_shift`），一个零件都不丢。
func test_wheel_vehicle_survives_floor_shift_on_load() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var axle := library.get_def("wheel_axle_2x2")
	# 一辆小车的布局：轮子在最底排（cell y = 0），车身在它上面
	var parts := [
		{"part_id": "cube_full", "cell": Vector3i(0, 1, 0), "basis": Basis()},
		{"part_id": "cube_full", "cell": Vector3i(0, 2, 0), "basis": Basis()},
		{"part_id": "wheel_axle_2x2", "cell": Vector3i(1, 0, 0), "basis": Basis()},
	]
	# 轮子的网格会往下探 → 需要整体上移 1 格
	var shift := BuildGrid.fit_shift(parts, library.defs)
	assert_eq(shift, Vector3i(0, 1, 0), "轮子探出地面 → 整体上移 1 格")
	# 按 shift 摆放：一个都不该被跳过
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var placed := 0
	for part in parts:
		var def: PartDef = library.get_def(part["part_id"])
		assert_true(def != null, "部件应存在")
		var result := grid.place(def, part["cell"] + shift, part["basis"])
		assert_true(
			result["ok"], "%s@%s 应能放下：%s" % [part["part_id"], str(part["cell"]), result.get("reason", "")]
		)
		if result["ok"]:
			placed += 1
	assert_eq(placed, parts.size(), "零件一个都不能少（轮子必须还在）")
	# 而且每个零件的网格都真正落在场地里（不是靠"跳过"换来的）
	for entry: Dictionary in grid.parts:
		var def: PartDef = library.get_def(entry["part_id"])
		assert_true(
			grid.inside_area(def, entry["basis"], entry["origin"]),
			"%s 的网格应在场地内" % entry["part_id"]
		)


## 测试场用：带 `wheel_body` 的部件（轮轴）→ 一个驱动轮。
## `wheel_specs()` 给出轮胎中心、半径、以及**转向正负号**（重心之前 +1 / 之后 -1）。
## 轮胎好不好使没法靠看代码确认 —— 物理验证跑 `tools/test_drive.gd`。
func test_wheel_specs() -> void:
	var library := _library()
	var axle := library.get_def("wheel_axle_2x2")
	# 车身两格（核心），前后各挂一个侧轮：车头朝 +x，轮子挂在 +z 侧
	var side := BuildGrid.candidate_basis(axle, Vector3i(0, 0, -1))
	var vehicle := VehicleDef.new()
	vehicle.parts = [
		{"part_id": "core", "cell": Vector3i(0, 0, 0), "basis": Basis()},
		{"part_id": "wheel_axle_2x2", "cell": Vector3i(0, 0, 1), "basis": side},
		{"part_id": "wheel_axle_2x2", "cell": Vector3i(2, 0, 1), "basis": side},
	]
	var specs := vehicle.wheel_specs(library)
	assert_eq(specs.size(), 2, "两个轮轴 → 两个驱动轮")
	assert_true(float(specs[0]["radius"]) > 0.5, "轮子半径应差不多 1 cube：%s" % specs[0]["radius"])
	var signs := []
	for spec in specs:
		signs.append(float(spec["steer_sign"]))
	signs.sort()
	assert_eq(signs, [-1.0, 1.0], "全轮转向：重心前一正一后一反：%s" % str(signs))
	var offset: Vector3 = specs[0]["offset"]
	assert_true(offset.y <= 0.001, "轮胎中心应落在车身格子底面上：%s" % offset)
	assert_true(absf(offset.z) > 1.0, "轮胎应挂在车身侧面：%s" % offset)
	# 重心的正负分界要跟着重量走：把重心往一边压，两侧的符号应该翻过来。
	# ⚠️ 核心只有 30 kg、每个轮轴 100 kg，所以"把核心摆远"只能把重心拉到 x ≈ 2.4 ——
	#    想让两个轮子都落在重心之后，轮子得摆得更近些（x = 0.5 / 1.5 都在 2.4 之前）。
	var heavy := VehicleDef.new()
	heavy.parts = [
		{"part_id": "core", "cell": Vector3i(8, 0, 0), "basis": Basis()},
		{"part_id": "wheel_axle_2x2", "cell": Vector3i(0, 0, 1), "basis": side},
		{"part_id": "wheel_axle_2x2", "cell": Vector3i(1, 0, 1), "basis": side},
	]
	var heavy_specs := heavy.wheel_specs(library)
	assert_eq(
		[float(heavy_specs[0]["steer_sign"]), float(heavy_specs[1]["steer_sign"])],
		[-1.0, -1.0],
		"重心被压到车头那侧之后，两个轮子都在重心之后 → 都该反转"
	)


## 重心两套实现的**交叉校验**：`VehicleDef.center_of_mass()`（建造/进场的口径）和
## `VehicleState.center_of_mass()`（毁伤后按活着的零件重算的口径）必须是同一个算法 ——
## 车还是完整的时候两个数要一样，不然"驾驶手感不对"就没法判断到底是重心算错了、还是车本身就偏。
## 附带把每个载具的重心/离地高度写进断言消息（测试红了就能直接看到数）。
func test_center_of_mass_implementations_agree() -> void:
	var library := _library()
	var reported := []
	# 循环变量写显式类型：`load_all()` 返回的是弱类型数组，元素当作 Variant 时
	# `var x := vehicle.xxx()` 会报"推不出类型"（本项目把这种当错误）
	for vehicle: VehicleDef in VehicleDef.load_all(VEHICLE_DIR):
		var intact: Vector3 = vehicle.center_of_mass(library)
		var state := VehicleState.new()
		state.setup(vehicle, library.defs)
		var after := state.center_of_mass()
		assert_vec_almost_eq(
			after, intact, 0.0001,
			"%s：毁伤用的重心和建造用的重心算法必须一致（%s vs %s）" % [vehicle.id, str(after), str(intact)]
		)
		var box: AABB = vehicle.actual_bounds(library)
		# 顺手算一份"按真实网格包围盒加权"的重心（含轮胎），看物理用的口径差多少
		var geo_mass := 0.0
		var geo_moment := Vector3.ZERO
		for part: Dictionary in vehicle.parts:
			var def: PartDef = library.get_def(part["part_id"])
			if def == null or def.weight_kg <= 0.0:
				continue
			var local := BuildGrid.rotate_aabb(part["basis"], def.mesh_bounds())
			var place := BuildGrid.cell_transform(def, part["cell"], part["basis"])
			geo_mass += def.weight_kg
			geo_moment += (place.origin + local.get_center()) * def.weight_kg
		var geo := geo_moment / maxf(0.001, geo_mass)
		var wheel_x := []
		for spec in vehicle.wheel_specs(library):
			wheel_x.append("%.1f" % ((spec["offset"] as Vector3).x))
		reported.append(
			"%s: 重心 x=%.2f 高=%.2f（离地 %.2f）质量 %.0f ｜ x 范围 %.1f~%.1f（中点 %.1f）"
			% [vehicle.id, intact.x, intact.y, intact.y - box.position.y, vehicle.total_mass(library),
				box.position.x, box.position.x + box.size.x, box.position.x + box.size.x * 0.5]
			+ " ｜ 轮子 x=[%s] ｜ 宽 %.1f 高 %.1f ｜ 网格重心高 %.2f（物理用 %.2f）"
			% [", ".join(wheel_x), box.size.z, box.size.y, geo.y, intact.y]
		)
	assert_true(reported.size() > 0, "至少要有台车：%s" % " | ".join(reported))


## 建造模式现场看的重心：`BuildGrid.center_of_mass()` 和 `VehicleDef.center_of_mass()`
## 必须给出同一个数（两边都调 `VehicleDef.weighted_center_of_mass()`，这条是把它钉住）。
func test_build_grid_center_of_mass_matches_the_vehicle_one() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var entries := [
		{"part_id": "core", "cell": Vector3i(0, 4, 0), "basis": Basis()},
		{"part_id": "cube_full", "cell": Vector3i(2, 4, 0), "basis": Basis()},
	]
	var text := "name = 重心测试\n"
	for entry: Dictionary in entries:
		var cell: Vector3i = entry["cell"]
		text += "part = %s %d %d %d 0 0 0\n" % [entry["part_id"], cell.x, cell.y, cell.z]
	var vehicle := VehicleDef.from_text(text, "user://com_probe.vehicle.txt")
	for entry: Dictionary in entries:
		var placed := grid.place(library.get_def(entry["part_id"]), entry["cell"], entry["basis"])
		assert_true(bool(placed["ok"]), "落子 %s：%s" % [entry["part_id"], placed.get("reason", "")])
	assert_vec_almost_eq(
		grid.center_of_mass(library.defs), vehicle.center_of_mass(library), 0.0001,
		"建造模式现场算的重心要和载具口径一致"
	)


## 重心标记：球落在给它的坐标上；**材质必须不测深度**（用户要求"不能被车体遮挡、要穿透显示"）；
## 垂线长度 = 离地高度、且从重心垂到地面。
func test_com_marker_renders_through_the_body() -> void:
	var marker := ComMarker.new()
	marker.place_local(Vector3(1.0, 2.0, 3.0))
	var ball := marker.get_node_or_null("ComBall") as MeshInstance3D
	var line := marker.get_node_or_null("ComDrop") as MeshInstance3D
	var spot := marker.get_node_or_null("ComSpot") as MeshInstance3D
	assert_true(ball != null and line != null and spot != null, "标记要有球 / 垂线 / 地面十字")
	if ball == null or line == null or spot == null:
		marker.free()
		return
	assert_vec_almost_eq(ball.position, Vector3(1.0, 2.0, 3.0), 0.0001, "球要落在重心上")
	var material := ball.material_override as StandardMaterial3D
	assert_true(material != null, "球要有材质")
	if material != null:
		assert_true(material.no_depth_test, "重心标记必须关掉深度测试（穿透车体显示）")
		assert_true(material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "别再受光照影响")
	# 没有物理世界时用兜底高度；垂线长 = 离地高度、中点在地面与重心之间
	var height := marker.update_drop(null, 4.5)
	assert_almost_eq(height, 4.5, 0.0001, "兜底高度要原样返回")
	assert_almost_eq(line.scale.y, 4.5, 0.001, "垂线长度 = 离地高度")
	assert_vec_almost_eq(
		line.position, Vector3(1.0, 2.0, 3.0) + Vector3.DOWN * 2.25, 0.001, "垂线要从重心垂到地面"
	)
	assert_vec_almost_eq(
		spot.position, Vector3(1.0, 2.0, 3.0) + Vector3.DOWN * 4.5, 0.001, "地面十字落在地面上"
	)
	marker.free()


func assert_almost_eq(actual: float, expected: float, tol: float, msg: String = "") -> void:
	assert_true(
		absf(actual - expected) <= tol,
		"%s（实际 %s，期望 %s）" % [msg, str(actual), str(expected)]
	)
