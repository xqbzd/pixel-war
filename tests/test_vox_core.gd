@tool
extends McpTestSuite

## 闭环核心逻辑的自测。这些断言同时是“形状与配色规则”的可执行说明书：
## 换配色、换 edge_band、加新形状时，先让它们通过。

const CUBE_DEF_PATH := "res://data/parts/cube_full.part.txt"
const PRISM_DEF_PATH := "res://data/parts/half_cube.part.txt"


func suite_name() -> String:
	return "vox"


func _def(path: String) -> PartDef:
	return PartDef.from_text(FileAccess.get_file_as_string(path), path)


func _count_value(volume: VoxVolume, value: int) -> int:
	var n := 0
	for v in volume.data:
		if v == value:
			n += 1
	return n


## 网格三角形环绕方向相对“外法线”的奇偶性：+1 = 几何法线与外法线同向，-1 = 反向。
## 本项目顶点法线一律朝外（见 VoxMesher.FACES 与各形状的棱判定）。
func _mesh_winding_parity(mesh: ArrayMesh) -> int:
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var total := 0.0
	for t in range(0, verts.size(), 3):
		var geo := (verts[t + 1] - verts[t]).cross(verts[t + 2] - verts[t])
		total += geo.normalized().dot(normals[t])
	return 1 if total > 0.0 else -1


## 颜色近似比较。网格里的顶点色是 8 位存贮，换算后会有一位量化误差，
## 所以不能用 Color.is_equal_approx（它按 1e-5 比）。
func _color_close(lhs: Color, rhs: Color, tolerance: float) -> bool:
	return (
		absf(lhs.r - rhs.r) < tolerance
		and absf(lhs.g - rhs.g) < tolerance
		and absf(lhs.b - rhs.b) < tolerance
	)


## 用 Godot 自带的 BoxMesh 当基准反推引擎的“正面”环绕方向：BoxMesh 一定渲染正确，
## 所以它的奇偶性就是引擎约定。这样断言不依赖我对约定的记忆，引擎改约定也能自动跟上。
func _godot_box_winding_parity() -> int:
	var box := BoxMesh.new()
	var arrays := box.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var total := 0.0
	for t in range(0, verts.size(), 3):
		var geo := (verts[t + 1] - verts[t]).cross(verts[t + 2] - verts[t])
		var centroid := (verts[t] + verts[t + 1] + verts[t + 2]) / 3.0
		total += geo.normalized().dot(centroid.normalized())  # BoxMesh 以原点为中心
	return 1 if total > 0.0 else -1


## 环绕方向错了不会崩溃：症状是“朝向你的那一面不见了，看到的是被它挡住的里面的背面”。
## 这类错误没有任何异常可看，只能靠断言守住。
func test_mesh_winding_matches_engine_front_face() -> void:
	var expected := _godot_box_winding_parity()
	var prism_mesh: ArrayMesh = _def(PRISM_DEF_PATH).build()["mesh"]
	var cube_mesh: ArrayMesh = _def(CUBE_DEF_PATH).build()["mesh"]
	assert_eq(
		_mesh_winding_parity(prism_mesh),
		expected,
		"棱柱体素网格环绕方向应匹配引擎正面约定（engine=%d, mesh=%d）"
		% [expected, _mesh_winding_parity(prism_mesh)]
	)
	assert_eq(
		_mesh_winding_parity(cube_mesh),
		expected,
		"立方体贴图网格环绕方向应匹配引擎正面约定（engine=%d, mesh=%d）"
		% [expected, _mesh_winding_parity(cube_mesh)]
	)
	assert_eq(cube_mesh.surface_get_array_len(0), 36, "6 quad = 36 顶点")


func test_cube_volume_is_full() -> void:
	var volume := _def(CUBE_DEF_PATH).build_volume()
	assert_eq(volume.size, Vector3i(16, 16, 16), "1 cube 部件的体积应是 16^3")
	assert_eq(volume.solid_count(), 4096, "实心立方体应有 4096 个实心体素")
	assert_true(volume.is_cell_full_cube(Vector3i.ZERO), "立方体单元应是满的（贴图路线的前提）")


func test_cube_crease_is_exactly_the_twelve_edges() -> void:
	var volume := _def(CUBE_DEF_PATH).build_volume()
	var edge_index := volume.index_of_color(Color("8e8e96"))
	# 4 条竖直棱(4x16) + 上下两圈各 60 个轮廓(2x60) - 8 个重复的角 = 176
	assert_eq(_count_value(volume, edge_index), 176, "“棱”应恰好落在 12 条棱上")
	assert_eq(volume.index_of_color(Color("c9c9ce")), 1, "调色板: 1 = 主体")
	assert_eq(edge_index, 2, "调色板: 2 = 棱")


func test_half_prism_volume_is_half_by_staircase_count() -> void:
	var volume := _def(PRISM_DEF_PATH).build_volume()
	# 截面 x + z <= 15 的格数 = 16+15+...+1 = 136，沿 Y 挤出 16 层
	assert_eq(volume.solid_count(), 136 * 16, "斜面台阶按整格计，实心体素数应为 2176")
	assert_false(volume.is_cell_full_cube(Vector3i.ZERO), "三棱柱不是满 cube，不能走贴图路线")
	assert_true(volume.is_solid(15, 0, 0), "直角边（x = 15, y = 0）上的体素应存在")
	assert_false(volume.is_solid(15, 8, 15), "被斜切掉的角应是空的")


func test_half_prism_crease_only_on_true_edges() -> void:
	var volume := _def(PRISM_DEF_PATH).build_volume()
	var body := volume.index_of_color(Color("c9c9ce"))
	var edge := volume.index_of_color(Color("8e8e96"))
	assert_eq(volume.get_voxel(10, 5, 5), body, "斜面中部是“面”，必须是主体色")
	# half_prism_xy：截面在 (x, y)，沿 z 挤出；长棱在截面的三个顶点上
	assert_eq(volume.get_voxel(0, 0, 5), edge, "(0,0,*) 是长棱")
	assert_eq(volume.get_voxel(15, 0, 5), edge, "(15,0,*) 是长棱")
	assert_eq(volume.get_voxel(0, 15, 5), edge, "(0,15,*) 是长棱")
	assert_eq(volume.get_voxel(8, 7, 0), edge, "z=0 封口面上的斜边轮廓是棱")
	assert_eq(volume.get_voxel(6, 6, 0), body, "z=0 封口面内部仍是主体色")
	assert_eq(volume.get_voxel(5, 8, 5), body, "内部体素是主体色")


func test_both_parts_share_the_same_palette() -> void:
	var cube := _def(CUBE_DEF_PATH).build_volume()
	var prism := _def(PRISM_DEF_PATH).build_volume()
	var cube_body := cube.color_of(cube.index_of_color(Color("c9c9ce")))
	var prism_body := prism.color_of(prism.index_of_color(Color("c9c9ce")))
	var cube_edge := cube.color_of(cube.index_of_color(Color("8e8e96")))
	var prism_edge := prism.color_of(prism.index_of_color(Color("8e8e96")))
	assert_true(cube_body.is_equal_approx(prism_body), "两种部件主体色必须一致")
	assert_true(cube_edge.is_equal_approx(prism_edge), "两种部件棱色必须一致")


func test_greedy_mesher_merges_cube_faces() -> void:
	var def := _def(CUBE_DEF_PATH)
	def.render_mode = PartDef.RenderMode.VOXEL
	var build := def.build()
	# 每个面被切成“一圈棱 + 中间主体” = 5 quad，6 个面 = 30；逐体素画会是 1536 面
	assert_eq(build["quads"], 30, "贪心合并后实心 cube 的体素网格应为 30 quad")
	assert_eq(build["tris"], 60, "30 quad = 60 tri")
	assert_true(build["mesh"] != null, "体素路线应产出 mesh")


func test_texture_route_uses_one_quad_per_face() -> void:
	var build := _def(CUBE_DEF_PATH).build()
	assert_eq(build["mode"], "texture", "render = texture 应走贴图路线")
	assert_eq(build["quads"], 6, "单 cube 部件贴图路线 = 6 个四边形")
	assert_eq(build["cells"].size(), 1, "单 cube 部件 = 1 个占用单元")
	assert_true(build["texture"] != null, "贴图路线应产出图集纹理")


## 两条路线最终送进 shader 的颜色必须一致：贴图是 sRGB 纹理（GPU 解码），
## 顶点色则要自己换算成线性。少这一步，体素部件就会比贴图部件白一档。
func test_voxel_vertex_colours_are_linear_to_match_texture() -> void:
	var library := PartLibrary.new()
	library.load_all("res://data/parts")
	var cube_build := library.build_for("cube_full", PartDef.RenderMode.TEXTURE)
	var atlas: Image = cube_build["atlas_image"]
	var atlas_body := atlas.get_pixel(8, 8)  # 面中心 = 主体色（sRGB 字节）

	var prism_build := library.build_for("half_cube", PartDef.RenderMode.VOXEL)
	var arrays := (prism_build["mesh"] as ArrayMesh).surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var has_linear_body := false
	for colour in colors:
		assert_false(
			_color_close(colour, atlas_body, 0.05),
			"顶点色不应直接使用 sRGB 值（会比贴图亮一档）"
		)
		if _color_close(colour, atlas_body.srgb_to_linear(), 0.01):
			has_linear_body = true
	assert_true(has_linear_body, "顶点色应等于图集颜色的 sRGB→线性换算结果")


func test_prism_falls_back_from_texture_to_voxel() -> void:
	var def := _def(PRISM_DEF_PATH)
	def.render_mode = PartDef.RenderMode.TEXTURE
	var build := def.build()
	assert_eq(build["mode"], "voxel", "非立方体部件应自动退回体素路线")
	assert_gt(def.warnings.size(), 0, "退回时应留下警告")


func test_atlas_has_edge_frame() -> void:
	var def := _def(CUBE_DEF_PATH)
	var volume := def.build_volume()
	var atlas := VoxFaceAtlas.build(volume, def.occupied_cells(volume))
	var image: Image = atlas["image"]
	assert_eq(image.get_width(), 96, "6 面 x 16 像素 = 96")
	assert_eq(image.get_height(), 16, "1 个单元 = 16 像素高")
	var body := volume.color_of(volume.index_of_color(Color("c9c9ce")))
	var edge := volume.color_of(volume.index_of_color(Color("8e8e96")))
	assert_true(image.get_pixel(0, 0).is_equal_approx(edge), "面的第一圈像素应是棱色（形成边框）")
	assert_true(image.get_pixel(8, 8).is_equal_approx(body), "面中心应是主体色")


## 实心范围缓存（`solid_bounds_*`）：它是"进场不卡"的关键 —— 网格化和求包围盒都靠它
## 跳过整块空体积。这里钉住"设了体素就更新、清了体素也要缩回去"。
func test_solid_bounds_track_set_voxel() -> void:
	var volume := VoxVolume.new(Vector3i(8, 8, 8))
	assert_false(volume.has_solid(), "空体积没有实心范围")
	assert_eq(volume.outermost_layer(0, true), -1, "空体积最外层应为 -1")

	volume.set_voxel(3, 4, 5, 1)
	volume.set_voxel(6, 1, 7, 1)
	assert_true(volume.has_solid(), "写了体素之后应有实心范围")
	assert_eq(volume.solid_lo(), Vector3i(3, 1, 5), "lo 取各轴最小（含）")
	assert_eq(volume.solid_hi(), Vector3i(7, 5, 8), "hi 取各轴最大 + 1（不含）")
	assert_eq(volume.outermost_layer(1, true), 4, "y 最外层 = 最高的实心层")
	assert_eq(volume.outermost_layer(2, false), 5, "z 最内层 = 最小的实心层")

	volume.set_voxel(6, 1, 7, VoxVolume.EMPTY)
	assert_eq(volume.solid_hi(), Vector3i(4, 5, 6), "清掉最外面的体素后范围要缩回去")

	# 直接写 `data` 的代码（如 VoxShapes.apply）必须调 invalidate_bounds()
	volume.data[volume.index(7, 7, 7)] = 1
	volume.invalidate_bounds()
	assert_eq(volume.solid_hi(), Vector3i(8, 8, 8), "直接写 data + 失效之后要重算")


## 网格化只扫实心范围：小方块摆在 48³ 体积正中，顶点必须都落在方块上，
## 不能因为"体积有 48 格"就把整个盒子画出来（那样枪管模型会多出一大块空壳）。
func test_mesher_only_covers_solid_bounds() -> void:
	var volume := VoxVolume.new(Vector3i(48, 48, 48))
	var value := volume.index_of_color(Color("c9c9ce"))
	for z in range(20, 24):
		for y in range(20, 24):
			for x in range(20, 24):
				volume.set_voxel(x, y, z, value)
	var build := VoxMesher.build(volume, 1.0 / 16.0)
	var mesh: ArrayMesh = build["mesh"]
	assert_true(mesh != null, "应产出网格")
	assert_eq(build["quads"], 6, "实心小方块 = 6 个面")
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(verts.size(), 36, "6 quad = 36 顶点")
	for vert in verts:
		var lo := Vector3(20, 20, 20) / 16.0
		var hi := Vector3(24, 24, 24) / 16.0
		assert_true(
			vert.x >= lo.x - 0.001 and vert.x <= hi.x + 0.001
			and vert.y >= lo.y - 0.001 and vert.y <= hi.y + 0.001
			and vert.z >= lo.z - 0.001 and vert.z <= hi.z + 0.001,
			"顶点应只落在实心方块的范围内（实际 %s）" % str(vert)
		)


func test_goxel_export_round_trip() -> void:
	var volume := _def(PRISM_DEF_PATH).build_volume()
	var path := "user://prism_export_test.vox.txt"
	var count := VoxExporter.write_goxel_text(volume, path)
	assert_eq(count, volume.solid_count(), "导出行数应等于实心体素数")
	var lines := FileAccess.get_file_as_string(path).split("\n", false)
	assert_eq(lines.size(), count + 3, "文件应为 3 行注释 + 每体素一行")
	var first := lines[3].split(" ", false)
	assert_eq(first.size(), 4, "每个体素行应为 X Y Z RRGGBB 四段")
	assert_eq(first[3].length(), 6, "颜色段应是 6 位十六进制")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
