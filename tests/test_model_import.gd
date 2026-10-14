@tool
extends McpTestSuite

## 外部建模工具的导入通道自测：
##   1) 导出 → 导入必须逐体素一致（含 Z-up ↔ Y-up 换轴）且颜色保留；
##   2) 模型驱动的部件：形状来自 model 文件，连接面自动推导，也能手动覆盖。

func suite_name() -> String:
	return "model"


func _library_parts() -> PartLibrary:
	var library := PartLibrary.new()
	library.load_all("res://data/parts")
	return library


func test_export_import_round_trip() -> void:
	var source := VoxVolume.for_cubes(Vector3i.ONE)
	var body := source.index_of_color(Color("c9c9ce"))
	var edge := source.index_of_color(Color("8e8e96"))
	# 用不对称的斜坡，换轴映射写错的话这里会立刻暴露
	VoxShapes.apply(source, VoxShapes.SHAPE_HALF_PRISM_XY, 1, body, edge)
	var path := "user://model_round_trip.vox.txt"
	assert_gt(VoxExporter.write_goxel_text(source, path), 0, "导出应成功")
	var loaded := VoxModel.load_text(path, Vector3i(16, 16, 16))
	assert_eq(loaded["warnings"].size(), 0, "导入不该有警告：%s" % str(loaded["warnings"]))
	var volume: VoxVolume = loaded["volume"]
	assert_eq(volume.solid_count(), source.solid_count(), "体素数应一致")
	var mismatches := 0
	for z in range(16):
		for y in range(16):
			for x in range(16):
				if source.is_solid(x, y, z) != volume.is_solid(x, y, z):
					mismatches += 1
	assert_eq(mismatches, 0, "导出再导入应逐体素相同")
	assert_eq(
		VoxModel.required_cubes(source),
		Vector3i.ONE,
		"16^3 的模型只需要 1 个 cube"
	)
	assert_true(
		volume.color_of(volume.get_voxel(5, 5, 8)).is_equal_approx(Color("c9c9ce")),
		"主体色应保留"
	)
	assert_true(
		volume.color_of(volume.get_voxel(0, 0, 8)).is_equal_approx(Color("8e8e96")),
		"棱色也应保留（(0,0,*) 是长棱）"
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_model_driven_part_derives_connections() -> void:
	var model_path := "user://slab_model.vox.txt"
	var file := FileAccess.open(model_path, FileAccess.WRITE)
	assert_true(file != null, "应能写测试模型")
	file.store_line("# 16 x 16 x 4 的板（导出坐标是 Z-up：raw.y 是厚度方向）")
	for z in range(4):
		for y in range(16):
			for x in range(16):
				file.store_line("%d %d %d c9c9ce" % [x, 12 + z, y])
	file.close()
	var def := PartDef.from_text(
		"name = 测试板\nmodel = %s\ncubes = 1 1 1\n" % model_path,
		"res://data/parts/test_slab.part.txt"
	)
	assert_eq(def.warnings.size(), 0, "解析不该有警告：%s" % str(def.warnings))
	var volume := def.build_volume()
	assert_eq(volume.solid_count(), 16 * 16 * 4, "板应是 1024 格")
	assert_eq(
		VoxModel.required_cubes(volume),
		Vector3i(1, 1, 1),
		"16x16x4 也只要 1 个 cube（厚度 4 也落在同一格里）"
	)
	# 厚度在 z 方向：±z 露出 256 格（算连接面），±x / ±y 只露 64 格（不算）
	assert_eq(def.connection_faces().size(), 2, "应只有两个连接面：%s" % str(def.connection_faces()))
	assert_true(def.has_connection_face(Vector3i(0, 0, 1)), "+z 应算连接面")
	assert_true(def.has_connection_face(Vector3i(0, 0, -1)), "-z 应算连接面")
	assert_false(def.has_connection_face(Vector3i(1, 0, 0)), "+x 只有 64 格，不算连接面")


func test_model_driven_part_connection_override() -> void:
	var model_path := "user://slab_model2.vox.txt"
	var file := FileAccess.open(model_path, FileAccess.WRITE)
	file.store_line("# 8 x 8 x 8 的方块堆")
	for z in range(8):
		for y in range(8):
			for x in range(8):
				file.store_line("%d %d %d c9c9ce" % [x, z, y])
	file.close()
	var def := PartDef.from_text(
		"name = 覆盖测试\nmodel = %s\nconnections = +y -x\n" % model_path,
		"res://data/parts/test_override.part.txt"
	)
	assert_eq(def.connection_faces().size(), 2, "手动覆盖应生效")
	assert_true(def.has_connection_face(Vector3i(0, 1, 0)), "覆盖里的 +y 应生效")
	assert_true(def.has_connection_face(Vector3i(-1, 0, 0)), "覆盖里的 -x 应生效")
	assert_false(def.has_connection_face(Vector3i(0, 0, 1)), "没写进覆盖的面不该出现")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(model_path))


## 画得比 16 大时，生成的部件要把 cubes 写够，否则会被 16³ 的默认体积截掉。
func test_required_cubes_for_big_model() -> void:
	var big := VoxVolume.new(Vector3i(64, 64, 64))
	var colour := big.index_of_color(Color("c9c9ce"))
	big.set_voxel(20, 5, 5, colour)
	big.set_voxel(0, 40, 0, colour)
	assert_eq(
		VoxModel.required_cubes(big),
		Vector3i(2, 3, 1),
		"跨过 16 的边界就要多占 cube（x 到 20 -> 2，y 到 40 -> 3）"
	)


## "一个零件一个文件夹"的布局：递归扫描要能找到子文件夹里的 .part.txt。
func test_library_scans_subfolders() -> void:
	var root := "user://parts_scan_test"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root + "/sub"))
	var file := FileAccess.open(root + "/sub/nested.part.txt", FileAccess.WRITE)
	assert_true(file != null, "应能写测试部件文件")
	file.store_string("name = 嵌套部件\nshape = cube\ncubes = 1 1 1\nrender = voxel\n")
	file.close()
	var library := PartLibrary.new()
	library.load_all(root)
	assert_true(
		library.has_part("nested"),
		"子文件夹里的部件也应被扫到：%s" % str(library.ids())
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root + "/sub/nested.part.txt"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root + "/sub"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root))


## 用 MagicaVoxel 模型做出来的两个真实部件：轮轴的四个连接面 + 轮体的假轮子标记。
func _replaced_by_test_wheel_axle_part() -> void:
	var library := PartLibrary.new()
	library.load_all("res://data/parts")
	assert_eq(library.warnings.size(), 0, "部件加载不该有警告：%s" % str(library.warnings))
	var axle := library.get_def("wheel_axle_2x2")
	var wheel := library.get_def("wheel_2x2")
	assert_true(axle != null, "缺少轮轴部件")
	assert_true(wheel != null, "缺少轮体部件")
	# 轮轴：2x2x1 cube，四个连接面
	assert_eq(axle.cubes, Vector3i(2, 2, 1), "轮轴占 2x2x1 cube")
	assert_eq(axle.connection_faces().size(), 4, "轮轴应有 4 个连接面：%s" % str(axle.connection_faces()))
	for dir in [Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		assert_true(axle.has_connection_face(dir), "轮轴 %s 面应是连接面" % str(dir))
	# 轮体：1x2x2 cube，标记成假轮子，连接面收成两个圆面
	assert_eq(wheel.cubes, Vector3i(1, 2, 2), "轮体占 1x2x2 cube")
	assert_eq(wheel.physics, "wheel", "轮体应标记为 physics = wheel（假轮子）")
	assert_eq(wheel.connection_faces().size(), 2, "轮体连接面应只有两个圆面")
	# 模型体积也要读得到（不是空的）
	assert_gt(axle.build_volume().solid_count(), 1000, "轮轴模型应有实体")
	assert_gt(wheel.build_volume().solid_count(), 1000, "轮体模型应有实体")


## 用 MagicaVoxel 模型做出来的部件：轮轴可放置（4 个连接面），
## 轮体不可放置、只作为轮轴的浮动附属模型被引用。
func test_wheel_axle_part() -> void:
	var library := PartLibrary.new()
	library.load_all("res://data/parts")
	assert_eq(library.warnings.size(), 0, "部件加载不该有警告：%s" % str(library.warnings))
	var axle := library.get_def("wheel_axle_2x2")
	assert_true(axle != null, "缺少轮轴部件")
	assert_eq(axle.cubes, Vector3i(2, 2, 1), "轮轴占 2x2x1 cube")
	assert_eq(axle.connection_faces().size(), 4, "轮轴应有 4 个连接面：%s" % str(axle.connection_faces()))
	for dir in [Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		assert_true(axle.has_connection_face(dir), "轮轴 %s 面应是连接面" % str(dir))
	assert_gt(axle.build_volume().solid_count(), 1000, "轮轴模型应有实体")
	# 轮体：只是模型，不是部件
	assert_false(library.has_part("wheel_2x2"), "轮体不该是可放置部件")
	assert_true(
		axle.wheel_body.ends_with("2x2轮体.vox"),
		"轮轴应引用轮体模型，实际是 '%s'" % axle.wheel_body
	)
	assert_true(FileAccess.file_exists(axle.wheel_body), "轮体模型文件应存在")


## connections 显式写空 / none = 这个部件没有连接面（挂不上任何东西）。
func test_explicit_no_connections() -> void:
	var def := PartDef.from_text(
		"name = 无连接\nshape = cube\nconnections = none\n",
		"res://data/parts/test_none.part.txt"
	)
	assert_eq(def.warnings.size(), 0, "解析不该有警告：%s" % str(def.warnings))
	assert_eq(def.connection_faces().size(), 0, "显式写 none 应得出零个连接面")
	assert_false(def.has_connection_face(Vector3i(0, -1, 0)), "没有任何面可连接")
	assert_eq(def.default_connection_face(), Vector3i.ZERO, "没有连接面时默认面为零向量")
	# 不写 connections 的部件仍然走自动推导
	var auto := PartDef.from_text("name = 自动\nshape = cube\n", "res://data/parts/test_auto.part.txt")
	assert_eq(auto.connection_faces().size(), 6, "没写 connections 时立方体仍是 6 个面")


## "连接点合法但放不下"要给出 valid=false + 原因（界面据此画红色虚影）；
## 连接点本身不合法时什么都不给（不画虚影）。
func test_plan_reports_invalid_with_reason() -> void:
	var library := _library_parts()
	var cube := library.get_def("cube_full")
	var ramp := library.get_def("half_cube")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	# 超框：贴着场地 -z 边界那块，再往 -z 贴一块
	grid.place(cube, Vector3i(0, 0, BuildGrid.AREA_MIN.z), Basis())
	var hit := grid.raycast(
		Vector3(0.5, 0.5, float(BuildGrid.AREA_MIN.z) - 1.5), Vector3(0, 0, 1)
	)
	assert_eq(hit["type"], "part", "应命中边界那块")
	var plan := grid.plan(cube, hit, 0, true)
	assert_false(bool(plan.get("valid", true)), "超框时 valid 应为 false")
	assert_true(
		str(plan.get("reason", "")).contains("场地"),
		"原因应提到场地：%s" % str(plan.get("reason", ""))
	)
	assert_true(grid.plan(cube, hit, 0).is_empty(), "默认行为不变：放不下就返回空")
	# 连接点本身不合法：瞄斜切面 → 连红虚影都不该有
	var grid2 := BuildGrid.new()
	grid2.set_defs(library.defs)
	grid2.place(ramp, Vector3i(0, 0, 0), Basis())
	var slope := grid2.raycast(Vector3(2.0, 0.8, 0.5), Vector3(-1, 0, 0))
	assert_true(grid2.plan(cube, slope, 0, true).is_empty(), "斜面没有连接点，不该给候选")


## 模型偏移允许负值（模型探出部件盒）：不能丢体素，包围盒要跟着变大。
func test_model_offset_can_overhang() -> void:
	var path := "user://offset_model.vox.txt"
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_true(file != null, "应能写测试模型")
	file.store_line("# 8x8x8 的小方块")
	for z in range(8):
		for y in range(8):
			for x in range(8):
				file.store_line("%d %d %d c9c9ce" % [x, y, z])
	file.close()
	var def := PartDef.from_text(
		"name = 下移测试\nmodel = %s\ncubes = 1 1 1\nmodel_offset = 0 -3 0\n" % path,
		"res://data/parts/test_offset.part.txt"
	)
	assert_eq(def.warnings.size(), 0, "解析不该有警告：%s" % str(def.warnings))
	assert_eq(def.model_offset, Vector3i(0, -3, 0), "偏移应被读进来")
	assert_eq(def.build_volume().solid_count(), 512, "下移不能丢体素")
	assert_eq(def.model_pad.y, 3, "负偏移应产生 3 行余量")
	assert_true(def.mesh_bounds().position.y < 0.0, "包围盒应探出部件盒底部：%s" % str(def.mesh_bounds()))
	var grid := BuildGrid.new()
	grid.set_defs(_library_parts().defs)
	assert_false(grid.inside_area(def, Basis(), Vector3i(0, 0, 0)), "贴地放会探出地面，应判超框")
	assert_true(grid.inside_area(def, Basis(), Vector3i(0, 3, 0)), "抬高 3 格后应合法")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## 轮轴按用户要求整体下移 3 像素，所以贴地那一层应该被判超框（这正是红色虚影的用处）。
func test_wheel_axle_drops_below_floor_at_bottom_row() -> void:
	var library := _library_parts()
	var axle := library.get_def("wheel_axle_2x2")
	assert_eq(axle.model_offset, Vector3i(0, -3, 0), "轮轴应带 3 像素下移")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_false(grid.inside_area(axle, Basis(), Vector3i(0, 0, 0)), "轮轴贴地会探出地面")
	assert_true(grid.inside_area(axle, Basis(), Vector3i(0, 1, 0)), "抬高 1 格应合法")


## 轮体是轮轴的**附属子模型**：按 wheel_offset 挂上去，而且**算碰撞体积**。
## 它在测试场里要挂到 VehicleWheel3D 上随悬挂浮动，所以网格是单独一份。
func test_wheel_body_is_a_sub_model_with_collision() -> void:
	var library := _library_parts()
	var axle := library.get_def("wheel_axle_2x2")
	assert_true(axle != null, "缺少轮轴部件")
	assert_false(axle.wheel_body.is_empty(), "轮轴应声明 wheel_body")
	# 数值是**游戏内**坐标（y = 高度、z = 深度）：.vox 装载时做过 (x, z, 镜像 y) 换算
	assert_eq(axle.wheel_offset, Vector3i(32, -16, -8), "轮体的挂载偏移应读进来")
	var sub := axle.sub_model_volume()
	assert_true(sub != null, "轮体模型应该能读出来")
	assert_true(sub.solid_count() > 0, "轮体应该有体素")
	# 体积大小按 .vox 自己的范围向上取整到 cube：碰撞是逐体素比的，
	# 两块体积必须落在同一个 1/16 栅格上（体积整 cube 就保证了这一点）
	assert_eq(sub.size.x % 16, 0, "轮体体积 x 应是整 cube：%s" % str(sub.size))
	assert_eq(sub.size.y % 16, 0, "轮体体积 y 应是整 cube：%s" % str(sub.size))
	assert_eq(sub.size.z % 16, 0, "轮体体积 z 应是整 cube：%s" % str(sub.size))
	assert_true(
		axle.sub_model_offset().is_equal_approx(Vector3(2.0, -1.0, -0.5)), "偏移换算成 cube"
	)
	# 碰撞盒 = 本体 ∪ 轮体
	var full := axle.mesh_bounds()
	var sub_box := PartDef.tight_bounds(sub, axle.sub_model_offset(), Vector3.ONE)
	assert_true(full.encloses(sub_box), "碰撞盒要含住轮体：%s 不含 %s" % [full, sub_box])
	# 渲染：轮体有独立网格
	var build := library.build_sub(axle.id)
	assert_true(build.get("mesh") != null, "轮体应该有独立网格（测试场要挂到悬挂上）")


func test_missing_model_falls_back_with_warning() -> void:
	var def := PartDef.from_text(
		"name = 缺模型\nmodel = res://data/parts/models/definitely_missing.vox.txt\nshape = cube\n",
		"res://data/parts/test_missing.part.txt"
	)
	var volume := def.build_volume()
	assert_eq(volume.solid_count(), 4096, "模型缺失时应退回用 shape 生成")
	assert_gt(def.warnings.size(), 0, "应留下一条警告")
