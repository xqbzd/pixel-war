@tool
extends McpTestSuite

## 零件图标（物品菜单 / 物品栏里的"斜向视图"）：纯 CPU 画出来的 Image，
## 所以在无头模式里可以直接验像素 —— 尺寸、透明背景、三档明暗、轮体算进去了。

const PART_DIR := "res://data/parts"


func suite_name() -> String:
	return "icon"


func _library() -> PartLibrary:
	var library := PartLibrary.new()
	library.load_all(PART_DIR)
	return library


func _opaque_count(image: Image) -> int:
	var count := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a > 0.5:
				count += 1
	return count


func test_icon_is_a_square_with_transparent_corners() -> void:
	var library := _library()
	var image := PartIcon.render(library.get_def("cube_full"))
	assert_eq(image.get_width(), PartIcon.TARGET, "图标是正方形（用户要求）")
	assert_eq(image.get_height(), PartIcon.TARGET)
	assert_eq(image.get_format(), Image.FORMAT_RGBA8, "要带 alpha，格子里才会是透明的")
	var last := PartIcon.TARGET - 1
	for corner in [Vector2i(0, 0), Vector2i(last, 0), Vector2i(0, last), Vector2i(last, last)]:
		assert_eq(image.get_pixelv(corner).a, 0.0, "斜向视图的四角应该是空的：%s" % str(corner))
	assert_gt(_opaque_count(image), 0, "应该画到东西了")


func test_three_faces_get_three_shades() -> void:
	var library := _library()
	var image := PartIcon.render(library.get_def("cube_full"))
	var shades := {}
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var colour := image.get_pixel(x, y)
			if colour.a > 0.5:
				shades[snappedf(colour.g, 0.01)] = true
	assert_gt(
		shades.size(), 2, "顶面 / 前面 / 右面该是三档不同明暗，实际 %s" % str(shades.keys())
	)


## 轮体的体素也要画进图标 —— 不然轮子的图标只剩一根光轴（看不出来是什么零件）。
func test_wheel_icon_includes_the_tire() -> void:
	var library := _library()
	var wheel := library.get_def("light_truck_wheel_3x3")
	# 同一份模型，但当作"只有轮轴"的零件来画一次做对照（路径直接抄部件里的，别写死）
	var axle_only := PartDef.from_text(
		"name = 只有轮轴\nmodel = %s\ncubes = 2 2 1\n" % wheel.model_path,
		"res://data/parts/test_axle_only.part.txt"
	)
	var wheel_voxels := PartIcon.collect(wheel)
	var axle_voxels := PartIcon.collect(axle_only)
	assert_gt(
		wheel_voxels.size(), axle_voxels.size() * 3, "轮子的体素要远多于光轴（说明轮体收进来了）"
	)
	# 轮体是一只 2.875 格直径的大轮胎，挂在轮轴外侧：投影该比光轴又高又宽
	var wheel_native := PartIcon.paint(wheel_voxels)
	var axle_native := PartIcon.paint(axle_voxels)
	assert_gt(wheel_native.get_height(), axle_native.get_height(), "大轮胎的投影该比光轴高")
	assert_gt(wheel_native.get_width(), axle_native.get_width(), "轮体和轮轴并排 → 也该更宽")
	assert_gt(_opaque_count(PartIcon.render(wheel)), 0, "图标本身要画得出来")


func test_missing_part_renders_an_empty_icon() -> void:
	var image := PartIcon.render(null)
	assert_eq(image.get_width(), PartIcon.TARGET)
	assert_eq(_opaque_count(image), 0, "没有零件 = 整张透明，不许崩")
	# 模型路径写错了：退回解析式形状（画一个方块），也不许崩
	var broken := PartDef.from_text(
		"name = 读不到的模型\nmodel = res://nope/missing.vox\ncubes = 1 1 1\n",
		"res://data/parts/test_icon_broken.part.txt"
	)
	assert_eq(PartIcon.render(broken).get_width(), PartIcon.TARGET, "退回 shape 画方块")


## 回归：图标里的轮体必须按 `PartDef` 的**挂载偏移**摆。
## 曾经这里误用了 `wheel_offset`（那只是微调，默认 0），于是轮体被画在零件原点、
## 和轮轴叠在一起 —— 就是用户看到的"图标里轮轴和轮子穿模"。
func test_wheel_icon_places_the_tire_at_its_mounting_offset() -> void:
	var library := _library()
	for id in ["toy_wheel_2x2", "light_truck_wheel_3x3"]:
		var def: PartDef = library.get_def(id)
		assert_true(def != null, "缺少 %s" % id)
		var voxels := PartIcon.collect(def)
		var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
		var hi := -lo
		for entry in voxels:
			var pos: Vector3i = entry["pos"]
			lo = lo.min(pos)
			hi = hi.max(pos)
		# 画出来的体素范围 = 本体盒 ∪ 轮体盒（两者都在"零件本地体素"坐标里）
		var body_box := PartDef.tight_bounds(
			# 网格原点在 -model_pad（单位 = 体素），换算成立方
			def.build_volume(), -Vector3(def.model_pad) / 16.0, Vector3.ONE
		)
		var tyre_box := PartDef.tight_bounds(
			def.sub_model_volume(), def.sub_model_offset(), Vector3.ONE
		)
		var want := body_box.merge(tyre_box)
		assert_true(
			(Vector3(lo) - want.position * 16.0).length() <= 1.0,
			"%s：图标体素下界应是本体∪轮体的下界（实际 %s，期望 %s）" % [
				id, str(lo), str(want.position * 16.0)
			]
		)
		assert_true(
			(Vector3(hi + Vector3i.ONE) - (want.position + want.size) * 16.0).length() <= 1.0,
			"%s：图标体素上界应是本体∪轮体的上界（实际 %s，期望 %s）" % [
				id, str(hi + Vector3i.ONE), str((want.position + want.size) * 16.0)
			]
		)


func test_library_generates_icons_lazily_and_caches_them() -> void:
	var library := _library()
	var first := library.icon("cube_full")
	var second := library.icon("cube_full")
	assert_true(first != null, "能拿到图标")
	assert_true(first == second, "同一个零件取两次应该是同一张（按需生成 + 缓存）")
	assert_eq(library.icon("没有这个零件"), null, "不存在的零件返回 null")
	assert_gt(library.icon("toy_wheel_2x2").get_width(), 0, "轮子也要有图标")
