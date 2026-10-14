@tool
extends McpTestSuite

## 建造规则的自测：连接面判定、默认连接点、贴合朝向、占位与小面唯一性、射线命中。
## 这些断言就是“建造规则”的可执行说明书。

const PART_DIR := "res://data/parts"


func suite_name() -> String:
	return "build"


func _library() -> PartLibrary:
	var library := PartLibrary.new()
	library.load_all(PART_DIR)
	return library


func _cube() -> PartDef:
	return _library().get_def("cube_full")


func _ramp() -> PartDef:
	return _library().get_def("half_cube")


func _solid_in_layer(volume: VoxVolume, axis: int, index: int) -> int:
	# 统计指定层里的实心体素
	var total := 0
	for a in range(volume.size[(axis + 1) % 3]):
		for b in range(volume.size[(axis + 2) % 3]):
			var c := Vector3i.ZERO
			c[axis] = index
			c[(axis + 1) % 3] = a
			c[(axis + 2) % 3] = b
			if volume.is_solid(c.x, c.y, c.z):
				total += 1
	return total


## 连接面的判据（启发式）：在**该方向最外侧的那一层**上，露出的体素格数 ≥ 100（约 40%）。
## 不要求贴格子边 —— 内缩的模型（外部工具画的轮子）外表面不在格子边上；也不再单独判平面性，
## 因为这个单条件对库里全部形状都给出了预期结果（见下面的断言）。
func _face_is_connection(volume: VoxVolume, dir: Vector3i) -> bool:
	var axis := VoxMesher.axis_of(dir)
	var positive := dir[axis] > 0
	var outer := volume.outermost_layer(axis, positive)
	if outer < 0:
		return false
	var exposed := 0
	for a in range(volume.size[(axis + 1) % 3]):
		for b in range(volume.size[(axis + 2) % 3]):
			var c := Vector3i.ZERO
			c[axis] = outer
			c[(axis + 1) % 3] = a
			c[(axis + 2) % 3] = b
			var outward := c + dir
			if not volume.is_solid(c.x, c.y, c.z):
				continue
			if not volume.is_solid(outward.x, outward.y, outward.z):
				exposed += 1
	return exposed >= 100


func test_cube_has_six_connection_faces_with_bottom_default() -> void:
	var cube := _cube()
	assert_eq(cube.connection_faces().size(), 6, "立方体六个面都有连接点")
	for dir in VoxShapes.AXIS_DIRS:
		assert_true(cube.has_connection_face(dir), "立方体 %s 面应有连接点" % str(dir))
	assert_eq(cube.default_connection_face(), Vector3i(0, -1, 0), "立方体默认连接点是下方")


func test_ramp_prism_has_four_connection_faces() -> void:
	var ramp := _ramp()
	var faces := ramp.connection_faces()
	assert_eq(faces.size(), 4, "三棱柱有 4 个连接面：2 个正方形面 + 2 个三角面")
	for expected in [Vector3i(-1, 0, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		assert_true(ramp.has_connection_face(expected), "三棱柱 %s 面应有连接点" % str(expected))
	assert_false(ramp.has_connection_face(Vector3i(1, 0, 0)), "斜切出来的 +x 面不该有连接点")
	assert_false(ramp.has_connection_face(Vector3i(0, 1, 0)), "斜切出来的 +y 面不该有连接点")
	assert_eq(ramp.default_connection_face(), Vector3i(0, -1, 0), "三棱柱默认连接点是正下方的正方形面")


func test_default_face_is_a_full_square_on_the_ramp() -> void:
	var ramp := _ramp()
	var volume := ramp.build_volume()
	# 默认连接点所对应的那一层必须是完整正方形（16 x 16 = 256 全实心）
	assert_eq(_solid_in_layer(volume, 1, 0), 256, "三棱柱底面应是完整的正方形")


func test_connection_faces_pass_the_planar_and_big_enough_rule() -> void:
	# 覆盖形状库里的全部形状（含没有数据文件的那些）
	for shape in VoxShapes.known_shapes():
		var volume := VoxVolume.for_cubes(Vector3i.ONE)
		var solid := volume.index_of_color(Color.WHITE)
		VoxShapes.apply(volume, shape, 1, solid, solid)
		var expected_dirs := VoxShapes.connection_dirs(shape)
		for dir in VoxShapes.AXIS_DIRS:
			var expected: bool = expected_dirs.has(dir)
			var actual := _face_is_connection(volume, dir)
			assert_eq(
				actual,
				expected,
				"%s 的 %s 面：判据结果应与 connection_dirs() 一致" % [shape, str(dir)]
			)


func test_candidate_basis_turns_default_face_to_target() -> void:
	var ramp := _ramp()
	# 贴地：默认面（下方）对着世界下方 → 朝向就是单位阵
	var flat := BuildGrid.candidate_basis(ramp, Vector3i(0, -1, 0))
	assert_eq(
		(flat * Vector3(ramp.default_connection_face())).round(),
		Vector3(0, -1, 0),
		"贴地时默认连接面应朝下"
	)
	# 贴在一面朝 +x 的墙上：默认面要被转到 -x
	var wall := BuildGrid.candidate_basis(ramp, Vector3i(-1, 0, 0))
	assert_eq(
		(wall * Vector3(ramp.default_connection_face())).round(),
		Vector3(-1, 0, 0),
		"贴墙时默认连接面应朝向目标面"
	)
	assert_true(
		not wall.is_equal_approx(Basis()),
		"贴墙应当产生一个非平凡的朝向"
	)


## 能不能放只看几何：越界 / 干涉 / 点数 / 基准格独占。
## **悬空是允许的**（建造的中间状态）—— 只是悬空的零件连不上核心，进不了测试场。
func test_placement_requires_free_cells_and_blocks_overlap() -> void:
	var grid := BuildGrid.new()
	grid.set_defs(_library().defs)
	var cube := _cube()
	var core := _library().get_def("core")
	# 第一块：贴地
	assert_true(grid.place(cube, Vector3i(0, 0, 0), Basis())["ok"], "第一块应能贴地放下")
	assert_eq(grid.part_count(), 1, "放下后占 1 格")
	# 同一格再放 → 拒绝（体素级干涉）
	var again := grid.place(cube, Vector3i(0, 0, 0), Basis())
	assert_false(again["ok"], "同一格不能重复放置")
	assert_true(str(again["reason"]).contains("干涉"), "理由应是穿模：%s" % again["reason"])
	# 悬在半空、什么都不挨着 → 允许（记不上连接对而已）
	var floating := grid.place(cube, Vector3i(3, 3, 3), Basis())
	assert_true(floating["ok"], "悬空也要能放：%s" % floating.get("reason", ""))
	assert_eq(int(floating["pairs"]), 0, "悬空没有连接对")
	assert_eq(grid.part_count(), 2, "共 2 格")
	# 贴着上面放 → 成功，并登记一对连接
	var stacked := grid.place(cube, Vector3i(0, 1, 0), Basis())
	assert_true(stacked["ok"], "贴合上面应能建造")
	assert_eq(int(stacked["pairs"]), 1, "应登记一对连接")
	assert_eq(
		grid.links.get(BuildGrid.face_id(Vector3i(0, 0, 0), Vector3i.UP)),
		BuildGrid.face_id(Vector3i(0, 1, 0), Vector3i.DOWN),
		"连接应双向登记在同一对小面上"
	)
	assert_eq(grid.part_count(), 3, "共 3 格")
	# 悬空的进不了测试场：装上核心之后，没连上核心的零件照样挡着
	assert_true(grid.place(core, Vector3i(9, 0, 0), Basis())["ok"], "核心贴地放下")
	var status := grid.robot_status()
	assert_false(bool(status["ok"]), "有零件没连到核心 → 进不了测试场")
	assert_eq(int(status["connected"]), 1, "只有核心自己连着（其余都散着）")


func test_link_bookkeeping_stays_one_to_one() -> void:
	var grid := BuildGrid.new()
	grid.set_defs(_library().defs)
	var cube := _cube()
	grid.place(cube, Vector3i(0, 0, 0), Basis())
	grid.place(cube, Vector3i(0, 1, 0), Basis())
	grid.place(cube, Vector3i(0, 2, 0), Basis())
	# 每个小面最多一个连接，且互为对方
	for face in grid.links.keys():
		var partner: String = grid.links[face]
		assert_eq(grid.links.get(partner), face, "连接必须成对登记")
		assert_ne(face, partner, "不能连到自己")
	assert_eq(grid.links.size(), 4, "两层叠放 = 2 对连接 = 4 个小面")
	# 删掉中间那块：连接应一并清掉
	assert_true(grid.remove(Vector3i(0, 1, 0)), "应能删除")
	assert_eq(grid.part_count(), 2, "剩 2 格")
	assert_true(grid.links.is_empty(), "删除后不应残留连接")


func test_raycast_finds_face_and_direction() -> void:
	var grid := BuildGrid.new()
	grid.set_defs(_library().defs)
	grid.place(_cube(), Vector3i(0, 0, 0), Basis())
	var from_x := grid.raycast(Vector3(3.5, 0.5, 0.5), Vector3(-1, 0, 0))
	assert_eq(from_x["type"], "part", "应命中部件")
	assert_eq(from_x["cell"], Vector3i(0, 0, 0), "命中格子")
	assert_eq(from_x["dir"], Vector3i(1, 0, 0), "从 +x 面进入")
	var from_top := grid.raycast(Vector3(0.5, 9.0, 0.5), Vector3(0, -1, 0))
	assert_eq(from_top["dir"], Vector3i(0, 1, 0), "从上方进入应命中顶面")
	var floor_hit := grid.raycast(Vector3(10.5, 6.0, -4.5), Vector3(0, -1, 0))
	assert_eq(floor_hit["type"], "floor", "没打到部件应落到地面")
	assert_eq(
		floor_hit["cell"],
		Vector3i(10, -1, -5),
		"地面命中的虚拟格子应在 y = -1（负坐标按向下取整）"
	)
	var outside := grid.raycast(Vector3(200.0, 6.0, 0.0), Vector3(0, -1, 0))
	assert_eq(outside["type"], "none", "场地之外的地面不算命中")


## 直接放置要**吸附在连接点上**：瞄到没有连接点的面（斜切面 / 薄边）不给候选。
## ⚠️ "悬空合法"是针对**镜像体**的（镜像体跟着本体镜像过去，那边悬空也不拦），
## 不等于直接放置可以吸附到没有连接点的面上 —— 用户专门澄清过这一条。
func test_direct_placement_snaps_only_to_connection_faces() -> void:
	var grid := BuildGrid.new()
	grid.set_defs(_library().defs)
	var ramp := _ramp()
	var cube := _cube()
	assert_true(grid.place(ramp, Vector3i(0, 0, 0), Basis())["ok"], "斜坡应能贴地放下")
	var entry: Dictionary = grid.part_at(Vector3i(0, 0, 0))
	assert_false(
		BuildGrid.has_connection_towards(ramp, entry["basis"], Vector3i(1, 0, 0)),
		"斜坡的 +x 面是斜切面，不该有连接点"
	)
	# 瞄准斜切面：没有连接点，不给候选（吸附不上）
	var slant_plan := grid.plan(
		cube, {"type": "part", "cell": Vector3i(0, 0, 0), "dir": Vector3i(1, 0, 0)}, -1, true
	)
	assert_true(slant_plan.is_empty(), "瞄着没有连接点的面不该给候选")
	# 贴着 -x 的正方形竖面放：有连接点，给候选并且真的记上一对
	var wall_plan := grid.plan(
		cube, {"type": "part", "cell": Vector3i(0, 0, 0), "dir": Vector3i(-1, 0, 0)}, -1, true
	)
	assert_false(wall_plan.is_empty(), "瞄着有连接点的面该给候选")
	assert_true(bool(wall_plan.get("valid", true)), "而且应该可建造")
	assert_true(grid.place_plan(cube, wall_plan)["ok"], "落子")
	assert_eq(grid.links.size(), 2, "应该登记成一对连接（两个小面）")
	# 默认连接面转到墙面的朝向：滚转角不影响接合面
	for roll in range(4):
		var basis := BuildGrid.candidate_basis(ramp, Vector3i(-1, 0, 0), roll)
		assert_true(
			BuildGrid.has_connection_towards(ramp, basis, Vector3i(-1, 0, 0)),
			"滚转 %d 档时接合面仍应是默认连接面" % roll
		)


## 位置正确性的核心断言（曾经真的踩过）：
## 零件的网格是绕**格子角点**旋转的，一旦朝向不是单位阵（侧面建造必然如此），
## 直接写 Transform3D(basis, 格子角点) 会把几何体甩到隔壁格 ——
## 记账说在 A 格、画面里却在 B 格。
## 正确做法是让“新零件默认连接点 = 目标面面心”，它必须与“旋转后 AABB 最小角对齐格子角点”等价。
func test_placement_lands_in_the_adjacent_cell() -> void:
	var grid := BuildGrid.new()
	grid.set_defs(_library().defs)
	for def: PartDef in [_cube(), _ramp()]:
		var hit_cell := Vector3i(3, 4, 5)
		for hit_dir in VoxShapes.AXIS_DIRS:
			for roll in range(4):
				var basis := BuildGrid.candidate_basis(def, -hit_dir, roll)
				var transform := BuildGrid.placement_transform(def, hit_cell, hit_dir, basis)
				var cell := BuildGrid.origin_cell_of(def, basis, transform)
				# 判据按**基准格**说：吸附过去之后基准格落在相邻格（= 零件"挂"在那一面）
				assert_eq(
					grid.anchor_cell_from(def, transform, basis),
					hit_cell + hit_dir,
					"%s 命中 %s（roll %d）应落在相邻格" % [def.id, str(hit_dir), roll]
				)
				assert_true(
					transform.is_equal_approx(BuildGrid.cell_transform(def, cell, basis)),
					"%s 命中 %s（roll %d）的摆放变换应与 AABB 对齐形式一致"
					% [def.id, str(hit_dir), roll]
				)


func test_out_of_area_is_rejected() -> void:
	var grid := BuildGrid.new()
	grid.set_defs(_library().defs)
	var cube := _cube()
	assert_false(
		grid.can_place(cube, Vector3i(40, 0, 0), Basis())["ok"],
		"场地之外不能建造"
	)
	assert_false(
		grid.can_place(cube, Vector3i(0, 64, 0), Basis())["ok"],
		"超过 64 高不能建造"
	)


## 为什么部件表里只有一个斜坡三棱柱：绕默认连接点转 90 度就能得到侧向斜坡，
## 专门做一个 half_prism_yz 是冗余的。这里逐体素 + 逐棱验证这条等价性
## （映射：局部 (x,y,z) -> (15 - z, y, x)，即绕 Y 轴 -90 度再归位到 0..15）。
func test_yz_ramp_is_the_xy_ramp_rotated() -> void:
	var size := Vector3i(16, 16, 16)
	var xy := VoxShapes.build(VoxShapes.SHAPE_HALF_PRISM_XY, size, 1)
	var yz := VoxShapes.build("half_prism_yz", size, 1)
	var xy_occ: PackedByteArray = xy["occupancy"]
	var yz_occ: PackedByteArray = yz["occupancy"]
	var xy_edge: PackedByteArray = xy["crease"]
	var yz_edge: PackedByteArray = yz["crease"]
	var mismatches := 0
	var edge_mismatches := 0
	for z in range(16):
		for y in range(16):
			for x in range(16):
				var from_index := x + 16 * (y + 16 * z)
				var tx := 15 - z
				var to_index := tx + 16 * (y + 16 * x)
				if xy_occ[from_index] != yz_occ[to_index]:
					mismatches += 1
				if xy_edge[from_index] != yz_edge[to_index]:
					edge_mismatches += 1
	assert_eq(mismatches, 0, "xy 斜坡转 90 度后应与 yz 斜坡逐体素相同")
	assert_eq(edge_mismatches, 0, "两者的棱标记也应完全对应")


## 非满方块要按**实际体素**判定指向：三角块被斜切掉的那角（虚空）不该有指向判定。
func test_prism_void_is_not_aimable() -> void:
	var grid := BuildGrid.new()
	grid.set_defs(_library().defs)
	var ramp := _ramp()
	assert_true(grid.place(ramp, Vector3i(0, 0, 0), Basis())["ok"], "斜坡应能贴地放下")
	# 体素列 (15, 15, *) 整列都在虚空里（判据 x + y <= 15），沿 +z 射过去应该什么都打不到
	var through_void := grid.raycast(Vector3(0.97, 0.97, -1.5), Vector3(0, 0, 1))
	assert_eq(through_void["type"], "none", "射线穿过虚空不该命中零件")
	# 同一方向，但射向实心的那一列 → 命中 -z 面
	var solid_hit := grid.raycast(Vector3(0.2, 0.2, -1.5), Vector3(0, 0, 1))
	assert_eq(solid_hit["type"], "part", "实心那一列应命中")
	assert_eq(solid_hit["cell"], Vector3i(0, 0, 0), "命中格子")
	assert_eq(solid_hit["dir"], Vector3i(0, 0, -1), "从 -z 面进入")
	# 打到斜切台阶：算命中（挡住射线），但方向不是可建造面
	var slope := grid.raycast(Vector3(2.0, 0.8, 0.5), Vector3(-1, 0, 0))
	assert_eq(slope["type"], "part", "斜切面仍然挡射线")
	assert_eq(slope["dir"], Vector3i.ZERO, "斜切台阶不是可建造面")
	assert_eq(slope["voxel"], Vector3i(3, 12, 8), "命中的应是台阶外侧那一格")
	# 朝上的斜面同理：从上前方射进去，先撞到台阶的顶面 → 不可建造
	var top_slope := grid.raycast(Vector3(0.9, 1.6, 0.5), Vector3(0, -1, 0))
	assert_eq(top_slope["type"], "part", "顶面方向应命中台阶")
	assert_eq(top_slope["dir"], Vector3i.ZERO, "台阶顶面不是可建造面")


## 回归：旋转过的斜坡（尤其是贴到三角端面时出现的绕 X 轴 -90°）也必须能命中 / 建造 / 拆除。
## 之前的测试只有正姿零件 + 轴对齐射线，正好漏掉这一组。
func test_hit_build_remove_on_rotated_prisms() -> void:
	var library := _library()
	var cube := _cube()
	var ramp := _ramp()
	var bases := [
		{"name": "正姿", "basis": Basis()},
		{"name": "绕X-90", "basis": BuildGrid.snap_basis(Basis(Vector3.RIGHT, deg_to_rad(-90.0)))},
		{"name": "绕Y90", "basis": BuildGrid.snap_basis(Basis(Vector3.UP, deg_to_rad(90.0)))},
	]
	for entry: Dictionary in bases:
		var grid := BuildGrid.new()
		grid.set_defs(library.defs)
		var basis: Basis = entry["basis"]
		assert_true(
			grid.place(ramp, Vector3i(0, 0, 0), basis)["ok"],
			"%s：应能放下斜坡" % entry["name"]
		)
		var transform: Transform3D = grid.part_at(Vector3i(0, 0, 0))["transform"]
		for local_dir: Vector3i in ramp.connection_faces():
			var world_dir := Vector3i((basis * Vector3(local_dir)).round())
			# 三角形端面（±z）要往三角形内部取点，不能取面心（面心在虚空里）
			var lateral := 0.3 if local_dir.z != 0 else 0.5
			var local_point := Vector3(lateral, lateral, 0.5) + Vector3(local_dir) * 0.5
			var surface := transform * local_point
			var from := transform * (local_point + Vector3(local_dir) * 1.5)
			var hit := grid.raycast(from, surface - from)
			var label := "%s / %s 面" % [entry["name"], str(world_dir)]
			assert_eq(hit.get("type", "-"), "part", "%s：应命中" % label)
			if hit.get("type", "-") != "part":
				continue
			assert_eq(hit.get("dir", Vector3i.ZERO), world_dir, "%s：命中方向" % label)
			var target_cell: Vector3i = hit["cell"] + hit["dir"]
			if not grid.inside_area(cube, Basis(), target_cell):
				# 例如斜坡的底面：新格子会落到地板之下，本就该拒绝
				assert_true(
					grid.plan(cube, hit, 0).is_empty(),
					"%s：场地之外的邻格应拒绝建造" % label
				)
				continue
			var plan := grid.plan(cube, hit, 0)
			assert_true(not plan.is_empty(), "%s：应能规划建造" % label)
			if plan.is_empty():
				continue
			assert_true(grid.place_plan(cube, plan)["ok"], "%s：应能放下" % label)
			assert_true(grid.remove(plan["cell"]), "%s：应能拆除刚放的" % label)
		assert_true(grid.remove(Vector3i(0, 0, 0)), "%s：应能拆除斜坡本身" % entry["name"])
		assert_eq(grid.part_count(), 0, "%s：拆完应该空了" % entry["name"])


## 整辆载具平移：要么整体成功（格子 / 变换 / 连接一起搬），要么整体拒绝（不留半搬状态）。
## 角块：四面体（1/6，3 个连接点）与切角块（5/6，6 个连接点）。
func test_corner_shapes() -> void:
	var library := _library()
	assert_eq(
		library.ids(),
		[
			"cube_full",
			"half_cube",
			"corner_tetra",
			"corner_cut",
			"wheel_axle_2x2",
			"light_mg",
			"core",
		],
		"物品栏顺序应由 order 字段决定：1 方块 / 2 斜坡 / 3 角四面体 / 4 切角块 / 5 车轮 / 6 轻机枪 / 7 核心"
	)
	var tetra := library.get_def("corner_tetra")
	var cut := library.get_def("corner_cut")
	assert_true(tetra != null, "缺少 corner_tetra 部件文件")
	assert_true(cut != null, "缺少 corner_cut 部件文件")
	var tetra_volume := tetra.build_volume()
	var cut_volume := cut.build_volume()
	# 角四面体：判据 x + y + z <= 15 的格数 = C(18,3) = 816
	assert_eq(tetra_volume.solid_count(), 816, "角四面体的体素数（台阶按整格计）")
	# 切角块：切掉的角搬到上方，而且**少切一层** —— 被切掉的是 C(17,3) = 680 格
	assert_eq(cut_volume.solid_count(), 4096 - 680, "切角块少切一层（680 格而不是 816 格）")
	# 默认朝向：被切去的角在上面，所以底面是完整正方形（16 x 16 全实心）
	assert_eq(_solid_in_layer(cut_volume, 1, 0), 256, "切角块的底面应是完整正方形")
	assert_true(
		_solid_in_layer(cut_volume, 1, 15) < 256,
		"切角块的上表面应被削掉一块（切掉的角在上面）"
	)
	assert_eq(tetra.connection_faces().size(), 3, "角四面体只有 3 个连接面")
	for dir in [Vector3i(-1, 0, 0), Vector3i(0, -1, 0), Vector3i(0, 0, -1)]:
		assert_true(tetra.has_connection_face(dir), "角四面体 %s 面应有连接点" % str(dir))
	assert_false(tetra.has_connection_face(Vector3i(1, 0, 0)), "斜切那一侧没有连接点")
	assert_eq(tetra.default_connection_face(), Vector3i(0, -1, 0), "角四面体默认连接点是下方")
	assert_eq(cut.connection_faces().size(), 6, "切角块六个面都是连接点")
	assert_eq(cut.default_connection_face(), Vector3i(0, -1, 0), "切角块默认连接点是下方")


## 角四面体的虚空（被切掉的那角）同样不该有指向判定。
func test_corner_tetra_void_is_not_aimable() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_true(
		grid.place(library.get_def("corner_tetra"), Vector3i(0, 0, 0), Basis())["ok"],
		"角四面体应能贴地放下"
	)
	# 体素列 (15,15,*) 的和是 30+，整列都在虚空里
	assert_eq(
		grid.raycast(Vector3(0.97, 0.97, -1.5), Vector3(0, 0, 1))["type"],
		"none",
		"射线穿过角四面体的虚空不该命中"
	)
	# 对着角点那一列射 → 命中 -z 面，而且 -z 是连接面，能规划建造
	var hit := grid.raycast(Vector3(0.05, 0.05, -1.5), Vector3(0, 0, 1))
	assert_eq(hit["type"], "part", "实心列应命中")
	assert_eq(hit["dir"], Vector3i(0, 0, -1), "应从 -z 面进入")
	assert_true(
		not grid.plan(library.get_def("cube_full"), hit, 0).is_empty(),
		"角四面体的连接面上应能建造"
	)


## 【已停用，待删】旧的手写轮子形状已从形状库移除；等外部模型进来后删掉这段。
func _removed_wheel_shape() -> void:
	var library := _library()
	var wheel := library.get_def("wheel")
	assert_true(wheel != null, "缺少 wheel 部件文件")
	var volume := wheel.build_volume()
	assert_eq(wheel.connection_faces().size(), 2, "轮子只有两个连接面（+z / -z 圆面）")
	assert_true(wheel.has_connection_face(Vector3i(0, 0, 1)), "+z 圆面应能连接")
	assert_true(wheel.has_connection_face(Vector3i(0, 0, -1)), "-z 圆面应能连接")
	assert_false(wheel.has_connection_face(Vector3i(1, 0, 0)), "胎面是曲面，不该有连接点")
	assert_eq(wheel.default_connection_face(), Vector3i(0, 0, 1), "默认连接点是贴齐格子的 +z 面")
	assert_true(volume.solid_count() > 400, "轮子应有实体（%d 格）" % volume.solid_count())
	assert_true(volume.solid_count() < 4096, "轮子不是满方块")
	assert_eq(volume.outermost_layer(2, true), 15, "轮子的 +z 面应与格子贴齐")
	assert_true(volume.outermost_layer(2, false) > 0, "轮子的 -z 面是内缩的（不贴格子边）")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_true(grid.place(wheel, Vector3i(0, 0, 0), Basis())["ok"], "轮子应能放下")
	# 轴孔和四个角都是虚空，不该有指向判定
	assert_eq(
		grid.raycast(Vector3(0.5, 0.5, 2.0), Vector3(0, 0, -1))["type"],
		"none",
		"轴孔里不该命中"
	)
	assert_eq(
		grid.raycast(Vector3(0.06, 0.06, 2.0), Vector3(0, 0, -1))["type"],
		"none",
		"轮子四角是虚空"
	)
	# 轮毂那圈射进去应命中，方向是贴齐的 +z 面
	var hit := grid.raycast(Vector3(0.5, 0.28, 2.0), Vector3(0, 0, -1))
	assert_eq(hit["type"], "part", "轮毂应命中")
	assert_eq(hit["dir"], Vector3i(0, 0, 1), "从 +z 面进入")
	assert_true(
		not grid.plan(library.get_def("cube_full"), hit, 0).is_empty(),
		"轮子的 +z 面上应能建造"
	)


func test_translate_all_is_all_or_nothing() -> void:
	var grid := BuildGrid.new()
	grid.set_defs(_library().defs)
	var cube := _cube()
	grid.place(cube, Vector3i(0, 0, 0), Basis())
	grid.place(cube, Vector3i(0, 1, 0), Basis())
	var moved := grid.translate_all(Vector3i(3, 0, 0))
	assert_true(moved["ok"], "整体平移应成功")
	assert_true(grid.cells.has(Vector3i(3, 0, 0)), "格子应整体搬到 (3,0,0)")
	assert_true(grid.cells.has(Vector3i(3, 1, 0)), "上面的那块也应跟着搬")
	assert_false(grid.cells.has(Vector3i(0, 0, 0)), "原位不该残留")
	assert_eq(
		grid.links.get(BuildGrid.face_id(Vector3i(3, 0, 0), Vector3i.UP)),
		BuildGrid.face_id(Vector3i(3, 1, 0), Vector3i.DOWN),
		"连接关系应跟着平移"
	)
	assert_eq(
		(grid.part_at(Vector3i(3, 0, 0))["transform"] as Transform3D).origin,
		Vector3(3, 0, 0),
		"变换原点应跟着平移"
	)
	# 超出场地：整体拒绝，且状态原封不动
	var refused := grid.translate_all(Vector3i(100, 0, 0))
	assert_false(refused["ok"], "超出场地应被拒绝")
	assert_true(grid.cells.has(Vector3i(3, 0, 0)), "被拒绝后格子不该动")
	assert_eq(grid.links.size(), 2, "被拒绝后连接也不该动")
	# 来回移动应回到原状
	assert_true(grid.translate_all(Vector3i(-3, 0, 0))["ok"], "反向平移应成功")
	assert_true(grid.cells.has(Vector3i(0, 1, 0)), "应回到原位")
	# 竖直方向也要受 64 格高限制
	assert_true(grid.translate_all(Vector3i(0, 20, 0))["ok"], "向上 20 格应允许")
	assert_false(grid.translate_all(Vector3i(0, 50, 0))["ok"], "超过 64 格高应被拒绝")
	assert_true(grid.cells.has(Vector3i(0, 20, 0)), "被拒绝后应停在 20 格高")


## 整体平移要连"足迹盒"一起搬（轮轴探出的那一排格子也得跟着走），否则拆不干净。
func test_translate_all_moves_the_whole_footprint() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var axle := library.get_def("wheel_axle_2x2")
	assert_true(grid.place(axle, Vector3i(0, 2, 0), Basis())["ok"], "轮轴应能放下")
	var before := BuildGrid.cells_of(axle, Basis(), Vector3i(0, 2, 0))
	var before_bounds: AABB = grid.part_at(Vector3i(0, 2, 0))["bounds"]
	# 足迹 = 本体 4 格 + 轮体占掉的格子（轮体挂在本体旁边）
	assert_true(before.has(Vector3i(0, 2, 0)), "本体基准格应在足迹里")
	assert_true(before.size() > 4, "带轮体之后足迹不止 4 格：%s" % str(before))
	assert_true(grid.translate_all(Vector3i(4, 0, 3))["ok"], "整体平移应成功")
	for c: Vector3i in before:
		assert_false(grid.cells.has(c), "原位置的 %s 不该残留" % str(c))
		assert_true(grid.cells.has(c + Vector3i(4, 0, 3)), "%s 应整体搬到新位置" % str(c))
	# 干涉检测用的世界包围盒也得跟着搬（它是落子时缓存下来的）
	var bounds_after: AABB = grid.part_at(Vector3i(4, 2, 3))["bounds"]
	assert_true(
		bounds_after.position.is_equal_approx(before_bounds.position + Vector3(4, 0, 3)),
		"包围盒应整体平移：%s" % str(bounds_after)
	)
	assert_true(grid.remove(Vector3i(4, 2, 3)), "应能拆除搬过去的轮轴")
	assert_eq(grid.part_count(), 0, "拆完应该一格不剩（足迹盒要整体搬过去）")


## 回归（用户报的 bug）：轮轴的**碰撞箱**必须按真实模型算，不能拿声明的 `cubes` 盒子算。
## 这个模型声明 2x2x1（32 像素高），实际只有 19 像素高 —— 用盒子算会凭空多出 13 像素，
## 于是"轮轴上面明明空着"却放不下方块。
##
## 占地格子 = 碰撞箱盖到的格子：下移 3 像素的那一截会占掉下面那一排格子（碰撞箱压着谁，
## 谁就不能建），而声明盒子里空着的上面那一格要还给玩家。
func test_model_overhang_blocks_below_but_frees_the_top() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var axle := library.get_def("wheel_axle_2x2")
	assert_true(axle != null, "缺少 wheel_axle_2x2 部件文件")
	assert_eq(axle.model_offset, Vector3i(0, -3, 0), "轮轴应整体下移 3 像素")
	# 碰撞箱 = 真实体素范围：高 19 像素 = 1.1875 cube，下探 3 像素 = 0.1875
	# （轮体也算碰撞体积，所以这里的"本体盒"要单独按本体的体积算）
	var unit := float(VoxVolume.VOXELS_PER_CUBE)
	var own := PartDef.tight_bounds(
		axle.build_volume(), -Vector3(axle.model_pad) / unit, Vector3(axle.cubes)
	)
	assert_true(
		own.position.is_equal_approx(Vector3(0.0, -0.1875, 0.0)), "本体盒应下探 3 像素：%s" % own
	)
	assert_true(
		own.size.is_equal_approx(Vector3(2.0, 1.1875, 1.0)),
		"本体盒应按真实体素收窄（不是声明的 2 cube 高）：%s" % own
	)
	# 零件的碰撞盒 = 本体盒 ∪ 子模型盒（轮体），所以要比本体大
	var bounds := axle.mesh_bounds()
	assert_true(bounds.encloses(own), "碰撞盒要含住本体：%s" % bounds)
	assert_true(bounds.size.x > own.size.x, "轮体伸出去之后碰撞盒应更宽：%s" % bounds)
	# 轮轴正姿放在 (0,1,0)：网格 y 从 1 - 3/16 = 0.8125 起，网格顶正好在 y = 2.0
	assert_true(grid.place(axle, Vector3i(0, 1, 0), Basis())["ok"], "轮轴应能自己放下")
	# 足迹 = 本体那几格 + 轮体占掉的格子；本体的下探那一排（y = 0）也在里头
	var cells := BuildGrid.cells_of(axle, Basis(), Vector3i(0, 1, 0))
	for c in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0)]:
		assert_true(cells.has(c), "本体足迹应含 %s" % str(c))
	assert_true(cells.has(Vector3i(2, 1, 0)), "轮体占的格子也该在足迹里（射线要能打到轮胎）")
	assert_true(cells.size() > 4, "带上轮体之后足迹更大：%d" % cells.size())
	# 下面一格 (0,0,0)：被下探的 3 像素压住 → 不许建
	var below := grid.can_place(_cube(), Vector3i(0, 0, 0), Basis())
	assert_false(below["ok"], "碰撞箱压住下面那一格，应拒绝")
	# 多零件可以共享格子，所以拦住它的是体素级干涉，而不是"格子被占"
	assert_true(str(below["reason"]).contains("干涉"), "理由应说清是干涉：%s" % below["reason"])
	# 上面一格 (0,2,0)：视觉上完全是空的 → 必须能建（用户的 bug 就在这儿）
	assert_true(
		grid.can_place(_cube(), Vector3i(0, 2, 0), Basis())["ok"],
		"轮轴上面那一格是空的，应该能建"
	)
	# 轮体也算碰撞体积：零件在本地空间里有本体 + 轮体两块实体
	assert_eq(grid._solids_of(axle.id).size(), 2, "本体 + 轮体两块")
	# 反过来验：先在轮体要占的位置放块方块，轮轴就该贴不上去（被轮体挡住）
	var blocked_grid := BuildGrid.new()
	blocked_grid.set_defs(library.defs)
	assert_true(blocked_grid.place(_cube(), Vector3i(2, 1, 0), Basis())["ok"], "先放方块")
	var blocked := blocked_grid.can_place(axle, Vector3i(0, 1, 0), Basis())
	assert_false(blocked["ok"], "轮体会撞到那块方块")
	assert_true(str(blocked["reason"]).contains("干涉"), "理由应说清是干涉：%s" % blocked["reason"])


## 红色虚影的数据来源：`plan(include_invalid = true)` 在"连接点合法但放不下"时
## 必须返回 valid = false + reason；默认（include_invalid = false）不给候选。
func test_plan_reports_invalid_when_overhang_blocks() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_true(
		grid.place(library.get_def("wheel_axle_2x2"), Vector3i(0, 1, 0), Basis())["ok"],
		"轮轴应能自己放下"
	)
	# 瞄地面 (0,-1,0)：方块会落在 (0,0,0)，正好在轮轴下探的那一格
	var hit := {"type": "floor", "cell": Vector3i(0, -1, 0), "dir": Vector3i.UP}
	var plan := grid.plan(_cube(), hit, 0, true)
	assert_false(plan.is_empty(), "连接点合法时应给出候选（哪怕是非法候选）")
	if not plan.is_empty():
		assert_eq(plan["cell"], Vector3i(0, 0, 0), "候选格子")
		assert_false(bool(plan.get("valid", true)), "放不下的候选应标成非法，界面才好画红虚影")
		assert_false(str(plan.get("reason", "")).is_empty(), "非法候选必须带上原因")
	assert_true(
		grid.plan(_cube(), hit, 0, false).is_empty(), "默认（include_invalid = false）不给非法候选"
	)


## 回归（用户报的 bug）：往轮轴**顶面**上建方块曾经完全不行 ——
## 射线在体素格里的坐标换算漏了 `model_pad`，轮轴顶面被判成"内部面"（`dir = 0`，
## 连半透明虚影都不给）。左右两侧都要能建，而且轮轴不能上下颠倒。
func test_building_on_top_of_the_wheel_axle() -> void:
	var library := _library()
	var axle := library.get_def("wheel_axle_2x2")
	var cube := library.get_def("cube_full")
	for hit_dir: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0)]:
		var grid := BuildGrid.new()
		grid.set_defs(library.defs)
		var base := Vector3i(8, 10, 8)
		assert_true(grid.place(cube, base, Basis())["ok"], "%s：底座" % str(hit_dir))
		var plan := grid.plan(axle, {"type": "part", "cell": base, "dir": hit_dir}, 0, true)
		assert_false(plan.is_empty(), "%s：轮轴应能贴上去" % str(hit_dir))
		if plan.is_empty():
			continue
		assert_true(bool(plan.get("valid", true)), "%s：轮轴应放得下" % str(hit_dir))
		grid.place_plan(axle, plan)
		# 两侧都要"立着"：3 像素偏移朝下，而不是翻上去
		var bounds := BuildGrid.world_bounds(axle, plan["basis"], plan["cell"])
		assert_true(
			bounds.position.y < float(plan["cell"].y) + 0.001,
			"%s：轮轴应整体下移，不该上下颠倒：%s" % [str(hit_dir), bounds]
		)
		# 从正上方垂直往下打：扫一遍轮轴碰撞箱，找出能建造的顶面
		var axle_cells := {}
		for c in BuildGrid.cells_of(axle, plan["basis"], plan["cell"]):
			axle_cells[c] = true
		var found_cell := Vector3i(999, 999, 999)
		for xi in range(1, 16):
			for zi in range(1, 8):
				if found_cell != Vector3i(999, 999, 999):
					break
				var p := Vector3(
					bounds.position.x + bounds.size.x * float(xi) / 16.0,
					30.0,
					bounds.position.z + bounds.size.z * float(zi) / 8.0
				)
				var shot := grid.raycast(p, Vector3(0, -1, 0))
				# 只认打在**轮轴**上的射线（不然会扫到轮轴旁边打空、落到地面的那些）
				if shot.get("type", "") != "part" or not axle_cells.has(shot.get("cell")):
					continue
				if shot.get("dir", Vector3i.ZERO) != Vector3i.UP:
					continue
				var top := grid.plan(cube, shot, 0, true)
				if top.is_empty() or not bool(top.get("valid", true)):
					continue
				found_cell = top["cell"]
		assert_true(
			found_cell != Vector3i(999, 999, 999),
			"%s：轮轴顶面应该能建方块（射线漏 pad 时这里一条都建不了）" % str(hit_dir)
		)
		if found_cell != Vector3i(999, 999, 999):
			# 建出来的方块应该在轮轴**上面**，不是塞进轮轴里
			assert_true(
				found_cell.y > int(plan["cell"].y),
				"%s：方块应落在轮轴上方，实际 %s" % [str(hit_dir), found_cell]
			)
			assert_true(grid.place(cube, found_cell, Basis())["ok"], "%s：应能真正放下" % str(hit_dir))


## 造一个"只在自己那格里的一小块有体素"的零件：用来验证共享格子。
## 文本格式是 Z-up 的（体积 x = 文件 x，体积 y = 文件 z，体积 z = 15 - 文件 y），
## 所以这里反着写，让最终的体积体素落在 [start, start + side) 那一小块里、而且离原点有距离。
func _sparse_part(tag: String, start: int, side: int) -> PartDef:
	var path := "user://share_cell_%s.vox.txt" % tag
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_true(file != null, "应能写测试模型")
	if file == null:
		return null
	var raw_y_lo := 16 - start - side  # 体积 z = 15 - 文件 y
	for raw_z in range(start, start + side):  # -> 体积 y
		for raw_y in range(raw_y_lo, raw_y_lo + side):  # -> 体积 z
			for raw_x in range(start, start + side):  # -> 体积 x
				file.store_line("%d %d %d c9c9ce" % [raw_x, raw_y, raw_z])
	file.close()
	var def := PartDef.from_text(
		"name = 稀疏块 %s\nmodel = %s\ncubes = 1 1 1\nconnections = none\n" % [tag, path],
		"res://data/parts/test_sparse_%s.part.txt" % tag
	)
	# 自检：体素确实落在 [start, start + side) 那一小块，而不是贴边
	var volume := def.build_volume()
	assert_eq(volume.solid_count(), side * side * side, "测试模型的体素数")
	assert_eq(volume.outermost_layer(0, false), start, "块在 x 方向的位置")
	assert_eq(volume.outermost_layer(2, false), start, "块在 z 方向的位置")
	return def


## 多零件共享格子（用户要的规则）：
##   - 一个格子只能放一个零件的**基准格**（放置锚点）；
##   - 非满格可以共存 —— 只要两边**真不穿模**（体素级干涉）。
## 轮轴在自己的足迹格 (1,1,0) 里只有一小条体素，那一格里空着的地方就还能塞别的零件。
func test_parts_can_share_a_cell() -> void:
	var library := _library()
	var axle := library.get_def("wheel_axle_2x2")
	var double := library.get_def("cube_full")
	var sparse := _sparse_part("a", 8, 4)
	assert_true(sparse != null, "应能造出测试零件")
	library.defs[sparse.id] = sparse  # 让网格查得到它的定义（体素干涉要用）
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_true(grid.place(axle, Vector3i(0, 1, 0), Basis())["ok"], "轮轴应能放下")
	var shared := Vector3i(1, 1, 0)
	# 轮轴的足迹盒确实盖着这一格
	var box := BuildGrid.cell_box_of(axle, Basis(), Vector3i(0, 1, 0))
	var mn: Vector3i = box["min"]
	var size: Vector3i = box["size"]
	assert_true(
		shared.x >= mn.x and shared.x < mn.x + size.x
		and shared.y >= mn.y and shared.y < mn.y + size.y
		and shared.z >= mn.z and shared.z < mn.z + size.z,
		"(1,1,0) 应该在轮轴足迹里：%s" % str(box)
	)
	assert_eq(grid.entries_at(shared).size(), 1, "这一格先只住着轮轴")
	# 稀疏块放进这一格空着的地方 → 允许（以前会被"已被占用"挡掉）
	assert_eq(grid.mesh_clash(sparse, Basis(), shared), "", "两边不该有体素重叠")
	assert_true(grid.can_place(sparse, shared, Basis())["ok"], "不穿模就该能共享这一格")
	assert_true(grid.place(sparse, shared, Basis())["ok"], "落子")
	assert_eq(grid.entries_at(shared).size(), 2, "这一格现在住着两个零件")
	assert_eq(grid.part_count(), 2, "一共两个零件")
	assert_eq(grid.part_at(shared)["part_id"], sparse.id, "这一格的主人（基准格）是稀疏块")
	# 但完整方块塞不进这一格：会撞上轮轴那一小条体素
	assert_false(grid.can_place(double, shared, Basis())["ok"], "穿模就不许共享")
	# 同一位置再放一次：那是自己和自己穿模（基准格不再独占，拦人的是干涉）
	var twice := grid.can_place(sparse, shared, Basis())
	assert_false(twice["ok"], "同一个位置不能放两次")
	assert_true(
		str(twice.get("reason", "")).contains("干涉"),
		"理由应是穿模：%s" % twice.get("reason", "")
	)
	# 射线要能指出打中的是哪一个零件（拆零件靠它）—— 同一格里两个零件，得挑最近的那个
	var hit_part := ""
	for xi in range(1, 16):
		for zi in range(1, 16):
			var shot := grid.raycast(
				Vector3(
					float(shared.x) + float(xi) / 16.0,
					20.0,
					float(shared.z) + float(zi) / 16.0
				),
				Vector3(0, -1, 0)
			)
			if shot.get("type", "") == "part":
				hit_part = str(shot.get("part_id", ""))
				if hit_part == sparse.id:
					break
		if hit_part == sparse.id:
			break
	assert_eq(hit_part, sparse.id, "射线应该能打中共享格子里的稀疏块")
	# 拆的时候只拆指定的那一个：拆稀疏块，轮轴留着
	assert_true(grid.remove(shared, sparse.id), "应能只拆稀疏块")
	assert_eq(grid.part_count(), 1, "轮轴应该还在")
	assert_eq(grid.part_at(shared)["part_id"], "wheel_axle_2x2", "留下的应是轮轴")
	assert_eq(grid.entries_at(shared).size(), 1, "这一格只剩轮轴")
	# 轮轴自己的基准格不能被别人当基准格
	var onto_axle := grid.can_place(double, Vector3i(0, 1, 0), Basis())
	assert_false(onto_axle["ok"], "轮轴本体那一格放不下完整方块")
	# 这里真正挡人的是干涉（轮轴的安装板铺满整个格子底面），报干涉才是对的
	assert_true(
		str(onto_axle["reason"]).contains("干涉"), "理由应说清是穿模：%s" % onto_axle["reason"]
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://share_cell_a.vox.txt"))


## 造一块"只占格子下半截（或上半截）"的板：16 x (y_hi - y_lo) x 16 体素。
## 下半截那块（0..8）的 -x 面露出 8 x 16 = 128 格（够当连接面），高度只到 y = 0.5，
## 所以和轮轴下探的那 3 像素不会撞上 —— 正好用来验"同格里塞别的零件"。
func _slab_part(tag: String, y_lo: int, y_hi: int) -> PartDef:
	var path := "user://slab_%s.vox.txt" % tag
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_true(file != null, "应能写测试模型")
	if file == null:
		return null
	# 文本格式是 Z-up 的：体积 y = 文件 z，体积 z = 15 - 文件 y
	for raw_z in range(y_lo, y_hi):  # -> 体积 y ∈ [y_lo, y_hi)
		for raw_y in range(0, 16):  # -> 体积 z（镜像后仍是 0..15 全覆盖）
			for raw_x in range(0, 16):  # -> 体积 x
				file.store_line("%d %d %d c9c9ce" % [raw_x, raw_y, raw_z])
	file.close()
	var def := PartDef.from_text(
		"name = 半高板 %s\nmodel = %s\ncubes = 1 1 1\n" % [tag, path],
		"res://data/parts/test_slab_%s.part.txt" % tag
	)
	var volume := def.build_volume()
	assert_eq(volume.solid_count(), 16 * (y_hi - y_lo) * 16, "半高板的体素数")
	assert_eq(volume.outermost_layer(1, false), y_lo, "板的下边界")
	assert_eq(volume.outermost_layer(1, true), y_hi - 1, "板的上边界")
	return def


## 回归（用户报的 bug）：轮轴下移 3 像素后，它的安装面在**下探那一排**格子上会凭空多出
## 一个连接点 —— 那一格只被模型底部的薄层擦到（这里是完全擦不到），
## 于是同格里放别的零件就撞"一对多"，提示还完全看不出真正原因。
## 修法：连接小面不但要"零件级有这个朝向的连接面"，还得**这一格上真的露出够大的面**。
func test_axle_does_not_claim_sliver_faces() -> void:
	var library := _library()
	var axle := library.get_def("wheel_axle_2x2")
	var wall := library.get_def("cube_full")
	var slab := _slab_part("a", 0, 8)
	assert_true(slab != null, "应能造出半高板")
	library.defs[slab.id] = slab
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	# 一面 1 x 2 的墙，上段挂一个轮轴
	assert_true(grid.place(wall, Vector3i(8, 9, 8), Basis())["ok"], "墙下段")
	assert_true(grid.place(wall, Vector3i(8, 10, 8), Basis())["ok"], "墙上段")
	var plan := grid.plan(
		axle, {"type": "part", "cell": Vector3i(8, 10, 8), "dir": Vector3i(1, 0, 0)}, 0, true
	)
	assert_eq(plan.get("cell", Vector3i.ZERO), Vector3i(9, 10, 8), "轮轴的基准格")
	assert_true(grid.place_plan(axle, plan)["ok"], "轮轴应能贴到墙上")
	# 连接账本：只该有墙自己那一对 + 轮轴真正的安装面
	assert_true(
		grid.links.has(BuildGrid.face_id(Vector3i(9, 10, 8), Vector3i(-1, 0, 0))),
		"基准那一格要登记安装连接"
	)
	assert_false(
		grid.links.has(BuildGrid.face_id(Vector3i(9, 9, 8), Vector3i(-1, 0, 0))),
		"下探那一排不该多出连接点"
	)
	# 露出格数也能量出来：基准那一格是满面，下探那一排一点都露不出来
	var placed: Transform3D = grid.part_at(Vector3i(9, 10, 8))["transform"]
	var full := grid.face_coverage(axle, placed, Vector3i(9, 10, 8), Vector3i(-1, 0, 0))
	var sliver := grid.face_coverage(axle, placed, Vector3i(9, 9, 8), Vector3i(-1, 0, 0))
	assert_true(full >= VoxModel.MIN_CONNECTION_AREA, "基准格应露出够大的一面：%d" % full)
	assert_true(sliver < VoxModel.MIN_CONNECTION_AREA, "下探那一排不该算连接面：%d" % sliver)
	# 锚点（基准格）= 本体 AABB 中心那一格（安装板的中间），不是"下探那一排"的薄边格；
	# 而且锚点按硬规则独占：这一格不能再放别的零件的基准格
	var mounted: Dictionary = grid.part_at(Vector3i(9, 10, 8))
	var anchor := grid.anchor_cell_from(axle, mounted["transform"], mounted["basis"])
	assert_true(grid._has_basis_at(anchor), "轮轴的锚点在 %s" % str(anchor))
	assert_true(
		BuildGrid.cells_of(axle, Basis(), Vector3i(9, 10, 8)).has(anchor),
		"锚点应落在零件的足迹里：%s" % str(anchor)
	)
	var blocked := grid.can_place(slab, anchor, Basis())
	assert_false(blocked["ok"], "锚点那一格放不下别的东西")
	assert_true(
		str(blocked.get("reason", "")).contains("干涉")
		or str(blocked.get("reason", "")).contains("基准格"),
		"拒绝理由要说清（穿模 / 基准格冲突）：%s" % str(blocked.get("reason", ""))
	)
	# 足迹里**除锚点外**的格子仍然可以住别的零件（只要不穿模）
	var spare := Vector3i(10, 9, 8)
	assert_true(BuildGrid.cells_of(axle, Basis(), Vector3i(9, 10, 8)).has(spare), "该格在足迹里")
	assert_false(grid._has_basis_at(spare), "该格不是锚点")
	assert_eq(grid.mesh_clash(slab, Basis(), spare), "", "半高板和轮轴不穿模")
	assert_true(
		grid.can_place(slab, spare, Basis())["ok"],
		"半高板应能塞进足迹里的空格：%s" % grid.can_place(slab, spare, Basis()).get("reason", "")
	)


## 基准格绑在模型的本地格子上：每个零件各有一个，落在本体体素上；
## 它**不独占** —— 两个零件可以共处一格，只要不真穿模（下半截板 + 上半截板就是标准例子）。
func test_anchor_is_per_part_and_sharing_is_allowed() -> void:
	var library := _library()
	var lower := _slab_part("lo", 0, 8)
	var upper := _slab_part("hi", 8, 16)
	assert_true(lower != null and upper != null, "应能造出两块半高板")
	library.defs[lower.id] = lower
	library.defs[upper.id] = upper
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var cell := Vector3i(0, 0, 0)
	assert_true(grid.place(lower, cell, Basis())["ok"], "下半截板应先放下")
	# 上半截板：两块刚好在 y = 0.5 处接住，逐体素不重叠 → 允许共处一格
	assert_eq(grid.mesh_clash(upper, Basis(), cell), "", "两块板不该穿模")
	var shared := grid.can_place(upper, cell, Basis())
	assert_true(shared["ok"], "不穿模就能共处一格：%s" % shared.get("reason", ""))
	assert_true(grid.place(upper, cell, Basis())["ok"], "落子")
	assert_eq(grid.part_count(), 2, "两个零件共处一格")
	# 两个零件各自的锚点（都在本体最厚的那一块上）；锚点重合是被允许的
	var lower_anchor := grid.anchor_cell_from(
		lower, BuildGrid.cell_transform(lower, cell, Basis()), Basis()
	)
	var upper_anchor := grid.anchor_cell_from(
		upper, BuildGrid.cell_transform(upper, cell, Basis()), Basis()
	)
	assert_eq(lower_anchor, cell, "下半截板的锚点")
	assert_eq(upper_anchor, cell, "上半截板的锚点")
	assert_true(grid._has_basis_at(cell), "锚点在 (0,0,0)")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://slab_lo.vox.txt"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://slab_hi.vox.txt"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://slab_a.vox.txt"))


## 子模型（轮体）不是零件：摆上轮轴之后零件数还是 1，场地里也只该有本体自己的基准格。
## 锚点 = 本体 AABB 中心所在那一格（绑在模型本地格子上），轮体不参与。
func test_sub_model_creates_no_anchor() -> void:
	var library := _library()
	var axle := library.get_def("wheel_axle_2x2")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var cell := Vector3i(0, 1, 0)
	assert_true(grid.place(axle, cell, Basis())["ok"], "轮轴应能放下")
	assert_eq(grid.part_count(), 1, "轮轴 + 轮体只算 1 个零件")
	var owners := []
	for c in grid.cells.keys():
		if grid._has_basis_at(c):
			owners.append(c)
	var anchor := grid.anchor_cell_from(axle, BuildGrid.cell_transform(axle, cell, Basis()), Basis())
	assert_eq(anchor, cell, "轮轴的锚点落在安装板那一格（本体 AABB 中心那格，压格线时取下面那格）")
	assert_eq(owners, [anchor], "只有轮轴本体的锚点，轮体不产生锚点：%s" % str(owners))
	# 但轮体占的格子确实在足迹里（碰撞 / 射线要认）
	assert_true(
		BuildGrid.cells_of(axle, Basis(), cell).has(Vector3i(2, 1, 0)),
		"轮体的格子应算进足迹"
	)


## 基准格 = 声明盒子的最小角那一格（= 放下去的那一格）；独占是"**真的压着才拦**"。
## 用户报过的症状：第四个轮子（和另外三个镜像对称的位置）提示"已经放着 cube_full 的基准格了"，
## 而它自己的本体其实整个在隔壁（声明格 (4,4,4)、本体 x ≥ 5）—— 本体根本没压着那一格，
## 拦它就是"指着空气拦人"。
func test_anchor_check_uses_the_new_part_own_anchor() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var axle := library.get_def("wheel_axle_2x2")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var cell := Vector3i(4, 4, 4)
	assert_true(grid.place(cube, cell, Basis())["ok"], "方块应先放下")
	# 倒过来挂的轮轴：声明盒子从 (4,4,4) 开始，本体却在 x ≥ 5
	var basis := VehicleDef.euler_basis(90, 0, 90)
	assert_eq(grid.mesh_clash(axle, basis, cell), "", "它和方块不该穿模")
	var check := grid.can_place(axle, cell, basis)
	assert_true(
		check["ok"], "本体没压着那一格时，格子归谁 ≠ 放不下：%s" % check.get("reason", "")
	)
	assert_true(grid.place(axle, cell, basis)["ok"], "应该放得下")
	var anchor := grid.anchor_cell_from(
		axle, BuildGrid.cell_transform(axle, cell, basis), basis
	)
	# 锚点绑在模型的本地格子上：这个朝向下它在本体上（x ≥ 5 那一侧），不是声明格 (4,4,4)
	assert_true(anchor.x >= 5, "锚点跟着本体走（%s）" % str(anchor))
	assert_eq(grid._basis_owner(cell), cube.id, "(4,4,4) 依旧归方块（先来的）")
	# 反过来：同一套 (cell, basis) 再放一个，就和前一个零件本身重叠了（穿模先报，这是设计）
	var again := grid.can_place(axle, cell, basis)
	assert_false(again["ok"], "同一个位置不能放两个轮轴")
	assert_true(
		str(again.get("reason", "")).contains("干涉"), "理由应是穿模：%s" % again.get("reason", "")
	)

# ── 镜像建造（左右对称）──────────────────────────────────────────────────────
#
# 规则：镜面 = 世界 z = mirror_half / 2（半格为单位），零件"绕自己的 z 中线对折"再镜像。
# 轴对称的零件（库里大多数）镜像 == 原零件转个角度，所以镜像体直接用同一份模型，
# 不需要左手系副本；角块那两个不是轴对称的，镜像建造会明确拒绝（见各自的测试）。

## 测试用朝向：单位阵 + 绕三个轴各 90 度（都是轴对齐的摆放档位）
func _test_bases() -> Array:
	return [
		Basis(),
		Basis(Vector3.UP, PI * 0.5),
		Basis(Vector3.RIGHT, PI * 0.5),
		Basis(Vector3.BACK, PI * 0.5),
	]


## 零件本地几何里所有实心体素的**中心点**（单位 = cube，本体 + 附属子模型都算）。
## 用中心而不是角点：体素对折之后，角点会跑到隔壁体素的角上（镜像把最小角点映成最大角点），
## 中心点才是"一个体素映到一个体素"那套坐标。
func _local_voxels(grid: BuildGrid, def: PartDef) -> Array:
	var out := []
	for solid: Dictionary in grid._solids_of(def.id):
		var volume: VoxVolume = solid["volume"]
		var origin: Vector3 = solid["origin"]
		for z in range(volume.size.z):
			for y in range(volume.size.y):
				for x in range(volume.size.x):
					if volume.is_solid(x, y, z):
						out.append(origin + (Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5)) / 16.0)
	return out


## 把本地点摆到世界里，取 1/32 格的整数坐标当集合用（体素中心是半格，乘 32 才是整数）。
func _mapped_voxels(local: Array, transform: Transform3D) -> Dictionary:
	var out := {}
	for point: Vector3 in local:
		var world: Vector3 = transform * point
		out[Vector3i(roundi(world.x * 32.0), roundi(world.y * 32.0), roundi(world.z * 32.0))] = true
	return out


## 半格一档的对称面：单格镜像是**对合**（镜像两次回原地），整数格永远映到整数格。
func test_mirror_cell_is_an_involution_at_half_steps() -> void:
	for half in range(-4, 5):
		for z in range(-5, 6):
			var cell := Vector3i(2, 5, z)
			var mirrored := BuildGrid.mirror_cell(cell, half)
			assert_eq(mirrored.x, cell.x, "镜像只动 z（x）")
			assert_eq(mirrored.y, cell.y, "镜像只动 z（y）")
			assert_eq(
				BuildGrid.mirror_cell(mirrored, half),
				cell,
				"半格 %d：镜像两次应回到原格（z = %d）" % [half, z]
			)
	# 偶数是格线、奇数是格心
	assert_eq(
		BuildGrid.mirror_cell(Vector3i(0, 0, -1), 0), Vector3i(0, 0, 0),
		"mirror_half = 0 是场地中线：格 -1 和格 0 互为镜像（载具数据就是这么对称的）"
	)
	assert_eq(
		BuildGrid.mirror_cell(Vector3i(0, 0, 0), 1), Vector3i(0, 0, 0),
		"mirror_half = 1 是格心：这一格自己就是镜像"
	)
	assert_eq(BuildGrid.mirror_plane(1), 0.5, "半格一档 = 世界坐标 0.5")


## 镜像摆放仍然是**正常**的摆放：朝向是纯旋转（行列式 +1，绝不出现左手系）、
## (cell, basis) 与 transform 自洽（能直接喂给 place()）、坐落在 1/16 格上。
func test_mirror_placement_stays_a_normal_grid_placement() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	for part_id in library.ids():
		var def: PartDef = library.get_def(part_id)
		for basis in _test_bases():
			for half in [-3, -1, 0, 1, 2]:
				var cell := Vector3i(1, 4, 0)
				var m := grid.mirror_placement(def, cell, basis, half)
				var mb: Basis = m["basis"]
				assert_true(
					absf(mb.determinant() - 1.0) < 0.001,
					"%s：镜像的朝向必须还是纯旋转（不能用左手系）" % part_id
				)
				assert_true(
					(m["transform"] as Transform3D).is_equal_approx(
						BuildGrid.cell_transform(def, m["cell"], mb)
					),
					"%s：镜像的 (cell, basis) 要和 transform 自洽" % part_id
				)
				# 足迹格子也要跟着镜像（不写死公式：角块那种"对折旋转不是单位阵"的零件，
				# 镜像摆放的声明盒是转过的盒子，但占的格子照样是逐格镜像过去的）
				var cells := BuildGrid.cells_of(def, basis, cell)
				var mirrored_cells := BuildGrid.cells_of(def, mb, m["cell"])
				var expected := {}
				for c: Vector3i in cells:
					expected[BuildGrid.mirror_cell(c, half)] = true
				assert_eq(
					mirrored_cells.size(), expected.size(),
					"%s：镜像体的足迹格子数应和本体一致" % part_id
				)
				for c: Vector3i in mirrored_cells:
					assert_true(
						expected.has(c),
						"%s 半格 %d：镜像体的足迹格子 %s 不在镜像位置" % [part_id, half, str(c)]
					)
				var origin: Vector3 = (m["transform"] as Transform3D).origin
				var scaled := origin * 16.0
				assert_true(
					absf(scaled.x - roundf(scaled.x)) < 0.001
					and absf(scaled.y - roundf(scaled.y)) < 0.001
					and absf(scaled.z - roundf(scaled.z)) < 0.001,
					"%s：镜像摆放要落在 1/16 格上（origin = %s）" % [part_id, str(origin)]
				)


## 镜像摆放 == **逐体素的真镜像**（本体 + 轮体都算）。
## 这是"同一份模型 + 一个旋转就能摆出镜像"这条前提的可执行证明：库里 6 个零件**全部**
## 通过，包括两个"对称面不平行于坐标轴"的角块（它们靠 mirror_fold_rotation 找的那个旋转）。
func test_mirrored_placement_equals_true_reflection_voxel_by_voxel() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var cases := 0
	for part_id in library.ids():
		assert_true(grid.part_is_mirror_safe(part_id), "%s 应该能镜像" % part_id)
		var def: PartDef = library.get_def(part_id)
		var local := _local_voxels(grid, def)
		for basis in _test_bases():
			for half in [0, 1]:
				var cell := Vector3i(1, 4, 3)
				var mine := _mapped_voxels(local, BuildGrid.cell_transform(def, cell, basis))
				var mirrored := _mapped_voxels(
					local, grid.mirror_placement(def, cell, basis, half)["transform"]
				)
				var missing := 0
				for corner: Vector3i in mine.keys():
					# 镜像：z -> 2 * (half / 2) - z，乘 32 之后就是 half * 32 - z
					if not mirrored.has(Vector3i(corner.x, corner.y, half * 32 - corner.z)):
						missing += 1
				assert_eq(
					mirrored.size(), mine.size(),
					"%s：镜像体和本体的体素数应该一样" % part_id
				)
				assert_eq(
					missing, 0,
					"%s %s 半格 %d：镜像不是逐体素对称（%d 个对不上）"
					% [part_id, str(basis), half, missing]
				)
				cases += 1
	# 零件数会随零件表增长，所以按实际数量断言（以前写死 6，加了轻机枪就红）
	assert_eq(
		cases,
		library.ids().size() * _test_bases().size() * 2,
		"%d 个零件 x %d 种朝向 x 2 个半格档位" % [library.ids().size(), _test_bases().size()]
	)


## 对折旋转：左右轴对称的零件 = 单位阵（不转）；两个角块的对称面不平行于坐标轴，
## 对折之后要靠一个真正的 90 度旋转复原 —— 但仍然是"同一份模型转一下"，不是左手系副本。
func test_mirror_fold_rotation_of_every_part() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	for id in ["cube_full", "core", "half_cube", "wheel_axle_2x2"]:
		var fold := grid.mirror_fold_rotation(library.get_def(id))
		assert_true(bool(fold.get("ok", false)), "%s 应该能找到对折旋转" % id)
		assert_true(
			(fold["basis"] as Basis).is_equal_approx(Basis()),
			"%s 本来就左右轴对称：对折旋转该是单位阵" % id
		)
	for id in ["corner_tetra", "corner_cut"]:
		var fold := grid.mirror_fold_rotation(library.get_def(id))
		assert_true(bool(fold.get("ok", false)), "%s 应该能找到对折旋转" % id)
		assert_false(
			(fold["basis"] as Basis).is_equal_approx(Basis()),
			"%s 不是 z 轴对称的，对折旋转不该是单位阵" % id
		)
		assert_true(
			absf((fold["basis"] as Basis).determinant() - 1.0) < 0.001,
			"%s 的对折旋转必须是纯旋转（不能用左手系）" % id
		)
		assert_true(grid.part_is_mirror_safe(id), "%s 能用同一份模型镜像" % id)


## 造一个**手性**测试零件：4 个体素走一个三维台阶（+x、+y、+z 各拐一次）。
## 它和它的镜像不是"转一下"的关系（24 个轴对齐旋转都还原不出来），镜像建造必须拒绝它。
func _chiral_part() -> PartDef:
	var path := "user://mirror_chiral.vox.txt"
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_true(file != null, "应能写测试模型")
	if file == null:
		return null
	# 文本格式是 Z-up 的：体积 y = 文件 z，体积 z = 15 - 文件 y
	for voxel in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(1, 1, 0), Vector3i(1, 1, 1)]:
		file.store_line("%d %d %d c9c9ce" % [voxel.x, 15 - voxel.z, voxel.y])
	file.close()
	var def := PartDef.from_text(
		"name = 手性块\nmodel = %s\ncubes = 1 1 1\nconnections = none\n" % path,
		"res://data/parts/test_chiral.part.txt"
	)
	assert_eq(def.build_volume().solid_count(), 4, "手性块的体素数")
	return def


## 真正手性的零件（镜像必须另做一份左手系模型）：镜像模式明确拒绝，理由要说清。
func test_mirror_refuses_chiral_parts() -> void:
	var library := _library()
	var chiral := _chiral_part()
	assert_true(chiral != null, "应能造出手性块")
	library.defs[chiral.id] = chiral
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_false(grid.part_is_mirror_safe(chiral.id), "手性块还原不出镜像")
	assert_true(
		not bool(grid.mirror_fold_rotation(chiral).get("ok", false)), "手性块没有对折旋转"
	)
	assert_true(grid.place(chiral, Vector3i(0, 0, 0), Basis())["ok"], "手性块贴地放下")
	var hit := {
		"type": "part", "cell": Vector3i(0, 0, 0), "dir": Vector3i(1, 0, 0),
		"part_id": chiral.id,
	}
	var plan := grid.plan_mirror(chiral, hit, -1, 0, true)
	assert_false(bool(plan.get("valid", true)), "手性零件不给镜像候选")
	assert_true(
		str(plan.get("reason", "")).contains("手性"),
		"理由要说清是手性零件：%s" % plan.get("reason", "")
	)
	assert_true((plan.get("body", {}) as Dictionary).is_empty(), "连本体候选都不给（要么镜像地放，要么不放）")
	var strict := grid.plan_mirror(chiral, hit, -1, 0)
	assert_false(bool(strict.get("valid", true)), "不给候选时也要留下拒绝理由")
	assert_true(str(strict.get("reason", "")).contains("手性"), "拒绝理由不能丢")
	assert_true(grid.mirror_placement(chiral, Vector3i(0, 0, 0), Basis(), 0).is_empty(), "手性块没有镜像摆放")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://mirror_chiral.vox.txt"))


## 镜像模式落子：本体 + 镜像体一起放、一起拆（左键一次放两个）。
func test_mirror_plan_places_and_removes_both_sides() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	# 先手工铺一对左右对称的底座（贴地那次不需要连接）：格 (0,0,0) 和它的镜像格 (0,0,-1)
	assert_true(grid.place(cube, Vector3i(0, 0, 0), Basis())["ok"], "底座右半")
	var base := grid.mirror_placement(cube, Vector3i(0, 0, 0), Basis(), 0)
	assert_true(grid.place(cube, base["cell"], base["basis"])["ok"], "底座左半")
	# 瞄准右半底座的上面：本体 + 镜像体应该落在 (0,1,0) / (0,1,-1)
	var hit := {
		"type": "part", "cell": Vector3i(0, 0, 0), "dir": Vector3i(0, 1, 0),
		"part_id": "cube_full",
	}
	var plan := grid.plan_mirror(cube, hit, -1, 0)
	assert_true(
		bool(plan.get("valid", false)),
		"镜像位置空着，应该能放：%s" % str(plan.get("reason", ""))
	)
	assert_eq((plan["body"]["cell"] as Vector3i), Vector3i(0, 1, 0), "本体落在底座上方")
	assert_eq((plan["mirror"]["cell"] as Vector3i), Vector3i(0, 1, -1), "镜像体落在镜像底座上方")
	var placed := grid.place_plan_mirror(cube, plan)
	assert_true(placed["ok"], "落子")
	assert_eq(int(placed["placed"]), 2, "一次落两个零件")
	assert_eq(grid.part_count(), 4, "底座两个 + 上面两个")
	# 拆：镜像模式下拆右边上面那个，左边上面的也一起拆
	var removed := grid.remove_with_mirror(Vector3i(0, 1, 0), "cube_full", 0)
	assert_eq(int(removed["removed"]), 2, "镜像拆除要成对")
	assert_true(bool(removed["mirrored"]), "要报告是成对拆的")
	assert_eq(grid.part_count(), 2, "只剩底座两个")
	assert_true(grid.part_at(Vector3i(0, 0, -1)) != null, "底座左半还在")


## 镜像位置被占：**只放本体**，镜像体那一边跳过（用户要求：两边独立，谁违规就不放谁）。
func test_mirror_places_only_the_body_when_the_mirror_side_is_blocked() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_true(grid.place(cube, Vector3i(0, 0, 0), Basis())["ok"], "底座右半")
	var base := grid.mirror_placement(cube, Vector3i(0, 0, 0), Basis(), 0)
	assert_true(grid.place(cube, base["cell"], base["basis"])["ok"], "底座左半")
	assert_true(grid.place(cube, Vector3i(0, 1, -1), Basis())["ok"], "先把镜像位置占掉")
	var hit := {
		"type": "part", "cell": Vector3i(0, 0, 0), "dir": Vector3i(0, 1, 0),
		"part_id": "cube_full",
	}
	var plan := grid.plan_mirror(cube, hit, -1, 0, true)
	assert_true(bool(plan.get("valid", false)), "本体那边能放，方案整体有效")
	assert_true(bool(plan.get("place_body", false)), "本体照放")
	assert_false(bool(plan.get("place_mirror", true)), "镜像位置被占，不放镜像体")
	assert_true(
		str(plan["mirror"].get("reason", "")).contains("干涉"),
		"镜像体自己的理由是穿模：%s" % plan["mirror"].get("reason", "")
	)
	var placed := grid.place_plan_mirror(cube, plan)
	assert_true(placed["ok"], "落子成功")
	assert_eq(int(placed["placed"]), 1, "只落了本体")
	assert_eq(grid.part_count(), 4, "底座两个 + 占位那个 + 新加的本体")


## 对称面挪到场地边上：镜像体被推出场地 → 只放本体（越界检查对镜像体一样生效）。
func test_mirror_places_only_the_body_when_the_mirror_copy_leaves_the_arena() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_true(grid.place(cube, Vector3i(0, 0, 0), Basis())["ok"], "底座")
	var hit := {
		"type": "part", "cell": Vector3i(0, 0, 0), "dir": Vector3i(0, 1, 0),
		"part_id": "cube_full",
	}
	# 镜面 = z 32（场地 z 上界）：本体在 (0,1,0)，镜像体会被推到 z = 63 那边去
	var plan := grid.plan_mirror(cube, hit, -1, 64, true)
	assert_true(bool(plan.get("valid", false)), "本体能放")
	assert_true(bool(plan.get("place_body", false)), "本体照放")
	assert_false(bool(plan.get("place_mirror", true)), "镜像体超框，不放")
	assert_eq((plan["mirror"]["cell"] as Vector3i), Vector3i(0, 1, 63), "镜像格算在场地外")
	assert_true(
		str(plan["mirror"].get("reason", "")).contains("场地"),
		"理由应是越界：%s" % plan["mirror"].get("reason", "")
	)
	var placed := grid.place_plan_mirror(cube, plan)
	assert_eq(int(placed["placed"]), 1, "只放本体")
	assert_eq(grid.part_count(), 2, "底座 + 本体")


## 只镜像体那一边合法时：本体违规 → 跳过本体，照放镜像体（两边独立，方向反过来也成立）。
func test_mirror_places_only_the_mirror_when_the_body_is_blocked() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_true(grid.place(cube, Vector3i(0, 0, 0), Basis())["ok"], "地面上的方块")
	assert_true(grid.place(cube, Vector3i(0, 1, 0), Basis())["ok"], "悬空方块（本体要放的位置占着它）")
	var hit := {
		"type": "part", "cell": Vector3i(0, 1, 0), "dir": Vector3i(0, -1, 0),
		"part_id": "cube_full",
	}
	var plan := grid.plan_mirror(cube, hit, -1, 0, true)
	assert_false(bool(plan.get("place_body", true)), "本体撞上悬空方块，不放")
	assert_true(bool(plan.get("place_mirror", false)), "镜像位置空着，照放")
	var placed := grid.place_plan_mirror(cube, plan)
	assert_eq(int(placed["placed"]), 1, "只放镜像体")
	assert_eq(grid.part_count(), 3, "两个方块 + 新加的镜像体")


## 点数只够一件时：只放本体、不放镜像体（用户点名要的行为）。
func test_mirror_prefers_the_body_when_points_only_fit_one() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	# 临时把这个方块的点数调到 3/5 上限：单独一件放得下，两件就超
	cube.pp = BuildGrid.PP_LIMIT * 3 / 5
	var hit := {"type": "floor", "cell": Vector3i(0, -1, 0), "dir": Vector3i(0, 1, 0)}
	var plan := grid.plan_mirror(cube, hit, -1, 0)
	assert_true(bool(plan.get("place_body", false)), "本体放得下")
	assert_false(bool(plan.get("place_mirror", true)), "本体 + 镜像体会超点数 → 不放镜像体")
	assert_true(
		str(plan["mirror"].get("reason", "")).contains("点数"),
		"理由应是点数：%s" % plan["mirror"].get("reason", "")
	)
	var placed := grid.place_plan_mirror(cube, plan)
	assert_eq(int(placed["placed"]), 1, "只放本体")
	assert_eq(grid.part_count(), 1, "场上就一件")


## 零件正好骑在对称面上（镜面过格心）：镜像 == 本体，只放一个就已经是对称的了，
## 不该报"和自己撞上了"。
func test_mirror_plan_places_once_when_the_part_sits_on_the_plane() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_true(grid.place(cube, Vector3i(0, 0, 0), Basis())["ok"], "底座")
	var hit := {
		"type": "part", "cell": Vector3i(0, 0, 0), "dir": Vector3i(0, 1, 0),
		"part_id": "cube_full",
	}
	# 镜面 = 格 0 的中心（z = 0.5）：格 0 里的方块骑在镜面上，它的镜像就是它自己
	var plan := grid.plan_mirror(cube, hit, -1, 1)
	assert_true(bool(plan.get("valid", false)), "应该能放：%s" % str(plan.get("reason", "")))
	assert_eq((plan["body"]["cell"] as Vector3i), Vector3i(0, 1, 0), "本体在底座上方")
	assert_true((plan.get("mirror", {}) as Dictionary).is_empty(), "镜像就是本体，没有第二个候选")
	var placed := grid.place_plan_mirror(cube, plan)
	assert_eq(int(placed["placed"]), 1, "只落一个")
	assert_eq(grid.part_count(), 2, "底座 + 上方那一个")


## 本体和镜像体互相压住也要挡住 —— 这是"对放置本体和镜像体都做碰撞检查"里最容易漏的一条。
## plan_mirror 就是把本体当 extra 传给 can_place 去查的。
func test_can_place_counts_extra_parts_in_the_clash_check() -> void:
	var library := _library()
	# 用核心（2x2x1 的实心方块）验干涉：转 90 度之后声明盒 1 x 2 x 2，z 上跨两格
	var core := library.get_def("core")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var basis := Basis(Vector3.UP, PI * 0.5)
	var cell := Vector3i(20, 4, 0)
	# 镜面过格心（z = 0.5）：镜像体 z ∈ [-1, 1]，和本体 z ∈ [0, 2] 压在一起
	var m := grid.mirror_placement(core, cell, basis, 1)
	assert_eq((m["cell"] as Vector3i), Vector3i(20, 4, -1), "镜像格")
	var body := grid._make_entry(core, cell, basis, BuildGrid.cell_transform(core, cell, basis))
	# 场地里本来就是空的：只查场地的话这一格是通的
	assert_true(
		grid.can_place(core, m["cell"], m["basis"])["ok"],
		"场地是空的，单查这一格应该通"
	)
	# 把还没落子的本体一起算进去：压住，必须挡住
	var check := grid.can_place(core, m["cell"], m["basis"], [body])
	assert_false(check["ok"], "镜像体和本体压在一起，要挡住")
	assert_true(str(check["reason"]).contains("干涉"), "理由应是穿模：%s" % check["reason"])


## 锚点必须永远压在本体体素上（同一个部位），不能跟着朝向"飞"出去。
## 回归（用户报的"诡异问题"）：以前锚点是"摆放之后按世界坐标算的一个点"，`model_offset`
## 把本体挪出盒子之后，24 个朝向里有 12 个锚点离本体体素差 1 格 —— 就是"锚点飞了"。
## 现在锚点绑死在模型的本地格子上，任何朝向都在本体上同一部位。
func test_anchor_always_lands_on_the_body() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var checked := 0
	for part_id in library.ids():
		var def: PartDef = library.get_def(part_id)
		var volume := def.build_volume()
		var pad := Vector3(def.model_pad) / 16.0
		for basis: Basis in BuildGrid.cube_rotations():
			var cell := Vector3i(3, 5, 2)
			var transform := BuildGrid.cell_transform(def, cell, basis)
			var anchor := grid.anchor_cell_from(def, transform, basis)
			var best := 999
			for z in range(volume.size.z):
				for y in range(volume.size.y):
					for x in range(volume.size.x):
						if not volume.is_solid(x, y, z):
							continue
						var local := -pad + (Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5)) / 16.0
						var world: Vector3 = transform * local
						var body_cell := Vector3i(
							floori(world.x), floori(world.y), floori(world.z)
						)
						best = mini(
							best,
							absi(body_cell.x - anchor.x)
							+ absi(body_cell.y - anchor.y)
							+ absi(body_cell.z - anchor.z)
						)
			assert_eq(best, 0, "%s %s：锚点 %s 必须压在本体体素上" % [part_id, str(basis), str(anchor)])
			checked += 1
	assert_eq(checked, library.ids().size() * 24, "%d 个零件 x 24 个旋转" % library.ids().size())


## 轮轴声明的 4 个连接点：-x、+y 和两片**薄面** ±z。
## ±z 那两片以前被"对面那一格在不在足迹里"误判成内部面（轮体的足迹把这两面盖住了），
## 结果安装板上明明能吸附的位置登记不上连接 —— 判据要按几何（对面有没有自己的体素）来。
func test_axle_thin_faces_are_real_connection_points() -> void:
	var library := _library()
	var axle := library.get_def("wheel_axle_2x2")
	var cube := library.get_def("cube_full")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var cell := Vector3i(0, 4, 0)
	assert_true(grid.place(axle, cell, Basis())["ok"], "轮轴应能放下")
	var transform := BuildGrid.cell_transform(axle, cell, Basis())
	var outward := 0
	for c in BuildGrid.cells_of(axle, Basis(), cell):
		for dir in VoxShapes.AXIS_DIRS:
			if not grid.claims_face(axle, Basis(), transform, c, dir):
				continue
			if grid.face_is_internal(axle, transform, c, dir):
				continue
			outward += 1
	assert_eq(outward, 4, "轮轴对外的连接点应该是 4 个（-x / +y / ±z）")
	# 贴着薄面（-z 那一片）放一块方块：要真的登记上一对连接
	assert_true(grid.place(cube, cell + Vector3i(0, 0, -1), Basis())["ok"], "贴着薄面放一块方块")
	assert_true(
		grid.links.has(BuildGrid.face_id(cell, Vector3i(0, 0, -1))),
		"薄面这一侧要登记连接"
	)
	assert_true(
		grid.links.has(BuildGrid.face_id(cell + Vector3i(0, 0, -1), Vector3i(0, 0, 1))),
		"对面那一半也要登记"
	)



## 镜像体可以**悬空**：本体贴在零件上（瞄准的是有连接点的面），镜像体那一侧什么都没有 ——
## 依然允许落子（用户要求的"悬空合法"就是指这一条，不是让直接放置去吸附没连接点的面）。
func test_mirror_copy_may_float() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	# 只在右边（z ≥ 0）立一根柱子，镜像那一侧（z < 0）什么都没有
	assert_true(grid.place(cube, Vector3i(0, 0, 0), Basis())["ok"], "底座")
	assert_true(grid.place(cube, Vector3i(0, 1, 0), Basis())["ok"], "上段")
	var hit := {
		"type": "part", "cell": Vector3i(0, 1, 0), "dir": Vector3i(0, 1, 0),
		"part_id": "cube_full",
	}
	var plan := grid.plan_mirror(cube, hit, -1, 0)
	assert_true(
		bool(plan.get("valid", false)),
		"镜像位置空着就该能放：%s" % str(plan.get("reason", ""))
	)
	assert_eq((plan["body"]["cell"] as Vector3i), Vector3i(0, 2, 0), "本体落在柱子上")
	assert_eq(
		(plan["mirror"]["cell"] as Vector3i), Vector3i(0, 2, -1),
		"镜像体落在镜像格 —— 那一格什么都没有，它悬空"
	)
	assert_true(grid.place_plan_mirror(cube, plan)["ok"], "镜像体悬空也要落子")
	assert_eq(grid.part_count(), 4, "柱子两个 + 上面两个")


## 镜像拆除：拆掉本体 + **镜像位置的基准格**上那个零件（不记配对关系，谁站在镜像基准格
## 上就是谁）。这里特意用"z 上跨两格"的零件（轮轴转 90 度 = 1 x 2 x 2）：跨格零件的
## 基准格最容易跑偏，这条断言就是"基准格镜像自洽"的看门狗。
func test_mirror_delete_pairs_by_mirrored_anchor_cell() -> void:
	var library := _library()
	var axle := library.get_def("wheel_axle_2x2")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var basis := Basis(Vector3.UP, PI * 0.5)  # 轮轴转 90 度：声明盒 1 x 2 x 2
	var cell := Vector3i(4, 4, 0)
	# 对称面放远一点（z = -4）：轮体会探出声明盒，镜像体贴着本体放是真的会撞上
	# （那是正确的：mode 里就是这么判的），这里要验的是"成对拆除"，所以让它们离得开。
	var half := -8
	assert_true(grid.place(axle, cell, basis)["ok"], "放一个轮轴")
	var m := grid.mirror_placement(axle, cell, basis, half)
	assert_eq((m["cell"] as Vector3i), Vector3i(4, 4, -10), "跨两格的零件：镜像格是 z = -10")
	var anchor := grid.anchor_cell_from(
		axle, BuildGrid.cell_transform(axle, cell, basis), basis
	)
	var mirror_anchor := grid.anchor_cell_from(axle, m["transform"], m["basis"])
	assert_eq(
		mirror_anchor, BuildGrid.mirror_cell(anchor, half),
		"镜像体的基准格就是本体基准格的镜像格（%s vs %s）"
		% [str(mirror_anchor), str(BuildGrid.mirror_cell(anchor, half))]
	)
	var second := grid.place(axle, m["cell"], m["basis"])
	assert_true(second["ok"], "镜像那一个也放上：%s" % second.get("reason", ""))
	assert_eq(
		str(grid.entry_by_anchor(mirror_anchor)["part_id"]), "wheel_axle_2x2",
		"镜像基准格上站着镜像体"
	)
	assert_eq(grid.part_count(), 2, "两个轮轴")
	# 成对拆：拆右边那个，左边那个一起走
	var removed := grid.remove_with_mirror(cell, "wheel_axle_2x2", half)
	assert_eq(int(removed["removed"]), 2, "成对拆掉")
	assert_eq(grid.part_count(), 0, "场上清空")


## 镜像拆除：镜像位置没有对应的零件（结构本来就不对称）时只拆本体。
func test_mirror_delete_removes_only_the_body_when_unpaired() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_true(grid.place(cube, Vector3i(3, 4, 2), Basis())["ok"], "孤零零一个方块")
	var removed := grid.remove_with_mirror(Vector3i(3, 4, 2), "cube_full", 0)
	assert_eq(int(removed["removed"]), 1, "只拆本体")
	assert_false(bool(removed["mirrored"]), "没配成对就不许说成对拆了")
	assert_eq(grid.part_count(), 0, "场上清空")


## 镜像建出来的东西要能存能读：镜像体走的是"正常旋转"，所以写进 .vehicle.txt 的
## yaw/pitch/roll 再读回来必须还是同一个摆放 —— 这是"不做左手系副本"这条路线的前提
## （真做了左手系副本，存档格式就得跟着改）。
func test_mirror_build_survives_a_save_load_round_trip() -> void:
	var library := _library()
	var cube := library.get_def("cube_full")
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	assert_true(grid.place(cube, Vector3i(0, 0, 0), Basis())["ok"], "底座右半")
	var base := grid.mirror_placement(cube, Vector3i(0, 0, 0), Basis(), 0)
	assert_true(grid.place(cube, base["cell"], base["basis"])["ok"], "底座左半")
	var hit := {
		"type": "part", "cell": Vector3i(0, 0, 0), "dir": Vector3i(0, 1, 0),
		"part_id": "cube_full",
	}
	var plan := grid.plan_mirror(cube, hit, -1, 0)
	var placed := grid.place_plan_mirror(cube, plan)
	assert_true(placed["ok"], "镜像模式一次盖两个：%s" % placed.get("reason", ""))
	assert_eq(grid.part_count(), 4, "四个零件")
	var entries := []
	for entry: Dictionary in grid.parts:
		entries.append({
			"part_id": entry["part_id"], "cell": entry["origin"], "basis": entry["basis"],
		})
	var path := "user://mirror_roundtrip.vehicle.txt"
	var written := VehicleDef.write_file(path, "mirror", entries)
	assert_true(written["ok"], "写存档：%s" % written.get("reason", ""))
	var vehicle := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)
	assert_eq(vehicle.parts.size(), 4, "读回来的零件数")
	var loaded := BuildGrid.new()
	loaded.set_defs(library.defs)
	var failed := PackedStringArray()
	for part: Dictionary in vehicle.parts:
		var def: PartDef = library.get_def(part["part_id"])
		var result := loaded.place(def, part["cell"], part["basis"])
		if not result.get("ok", false):
			failed.append("%s @%s：%s" % [part["part_id"], part["cell"], result.get("reason", "")])
	assert_true(failed.is_empty(), "读回来要能原样放下：%s" % ", ".join(failed))
	assert_eq(loaded.part_count(), 4, "四个零件都在")
	# 镜像关系也还在：上半对的镜像基准格上能找到零件（说明存的是同一个摆放，不是"看着差不多"）
	var upper := grid.mirror_placement(cube, Vector3i(0, 1, 0), Basis(), 0)
	var upper_anchor := grid.anchor_cell_from(cube, upper["transform"], upper["basis"])
	assert_true(
		not loaded.entry_by_anchor(upper_anchor).is_empty(),
		"读回来之后镜像那一半还在（基准格 %s）" % str(upper_anchor)
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))




## 镜像拆除靠"基准格直接按格子镜像"找人，所以基准格必须**镜像自洽**：
## 镜像体的基准格 == 本体基准格的镜像格（mirror_cell）。这条一破，拆除就找不到人
## （或者更糟：拆到别的零件头上）。全部零件 x 24 个轴对齐旋转 x 3 个半格档位逐一看过。
func test_anchor_mirrors_to_the_mirrored_part() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var checked := 0
	for part_id in library.ids():
		var def: PartDef = library.get_def(part_id)
		for basis: Basis in BuildGrid.cube_rotations():
			for half in [0, 1, -3]:
				var cell := Vector3i(3, 5, 2)
				var anchor := grid.anchor_cell_from(
					def, BuildGrid.cell_transform(def, cell, basis), basis
				)
				var m := grid.mirror_placement(def, cell, basis, half)
				assert_false(m.is_empty(), "%s 应该有镜像摆放" % part_id)
				var mirror_anchor := grid.anchor_cell_from(def, m["transform"], m["basis"])
				# 基准格绑在模型的本地格子上，镜像体用的是同一个本地格子 —— 镜像又把格子
				# 映到格子，所以镜像体的基准格正好就是本体基准格的镜像格（拆除就按这条找人）。
				assert_eq(
					mirror_anchor,
					BuildGrid.mirror_cell(anchor, half),
					"%s 半格 %d：镜像体的基准格应是本体基准格的镜像格（%s vs %s）"
					% [
						part_id, half, str(mirror_anchor),
						str(BuildGrid.mirror_cell(anchor, half)),
					]
				)
				checked += 1
	assert_eq(
		checked,
		library.ids().size() * 24 * 3,
		"%d 个零件 x 24 个旋转 x 3 个半格档位" % library.ids().size()
	)






## 每个零件的镜像朝向都要能过"写进存档再读回来"这一关（euler 只存 90 度一档）。
## 角块那种"对折旋转不是单位阵"的朝向最容易在这里翻车（俯仰 90 度附近有万向锁的等价写法）。
func test_mirror_basis_survives_the_euler_round_trip_for_every_part() -> void:
	var library := _library()
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	for part_id in library.ids():
		var def: PartDef = library.get_def(part_id)
		for basis in _test_bases():
			for half in [0, 1, -3]:
				var m := grid.mirror_placement(def, Vector3i(2, 4, 1), basis, half)
				assert_false(m.is_empty(), "%s 应该有镜像摆放" % part_id)
				var angles := VehicleDef.euler_of(m["basis"])
				# euler_of 返回 (yaw, pitch, roll)，euler_basis 收 (pitch, yaw, roll)
				var restored := VehicleDef.euler_basis(angles.y, angles.x, angles.z)
				assert_true(
					restored.is_equal_approx(m["basis"]),
					"%s（半格 %d，本体朝向 %s）：镜像朝向存盘再读回来要一样：%s -> %s"
					% [part_id, half, str(basis), str(m["basis"]), str(angles)]
				)
