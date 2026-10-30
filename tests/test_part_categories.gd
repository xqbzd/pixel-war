@tool
extends McpTestSuite

## 零件分类（建造界面按 Tab 呼出的菜单分五页）+ 两种"轮子"写法的数据守门。
## 分类是纯数据，所以这里同时是 `category = ` 这一行的可执行说明书。

const PART_DIR := "res://data/parts"


func suite_name() -> String:
	return "category"


func _library() -> PartLibrary:
	var library := PartLibrary.new()
	library.load_all(PART_DIR)
	return library


func test_the_five_pages_are_the_ones_the_user_asked_for() -> void:
	assert_eq(PartDef.CATEGORIES.size(), 5, "用户要的五类")
	assert_eq(
		PartDef.CATEGORIES, ["structure", "mobility", "weapon", "utility", "special"], "顺序"
	)
	assert_eq(PartDef.category_label("structure"), "结构")
	assert_eq(PartDef.category_label("mobility"), "行驶")
	assert_eq(PartDef.category_label("weapon"), "武器")
	assert_eq(PartDef.category_label("utility"), "辅助")
	assert_eq(PartDef.category_label("special"), "特殊")
	assert_eq(PartDef.category_label("nope"), "nope", "不认识的分类原样返回（方便定位写错的部件文件）")


func test_every_part_declares_a_known_category() -> void:
	var library := _library()
	assert_eq(library.warnings.size(), 0, "部件文件应无警告：%s" % str(library.warnings))
	for id in library.ids():
		var def: PartDef = library.get_def(id)
		assert_true(
			PartDef.CATEGORIES.has(def.category),
			"%s 的分类 '%s' 不在五类里" % [id, def.category]
		)


func test_chinese_and_english_values_both_parse() -> void:
	var chinese := PartDef.from_text(
		"name = 中文分类\ncategory = 行驶\n", "res://data/parts/test_cat_cn.part.txt"
	)
	assert_eq(chinese.warnings.size(), 0, "写法正确不该有警告：%s" % str(chinese.warnings))
	assert_eq(chinese.category, "mobility")
	var english := PartDef.from_text(
		"name = 英文分类\ncategory = utility\n", "res://data/parts/test_cat_en.part.txt"
	)
	assert_eq(english.category, "utility")
	assert_eq(
		PartDef.from_text("name = 没写分类\n", "res://data/parts/test_cat_none.part.txt").category,
		"structure",
		"不写 = 结构"
	)
	var wrong := PartDef.from_text(
		"name = 写错了\ncategory = 飞天\n", "res://data/parts/test_cat_bad.part.txt"
	)
	assert_eq(wrong.warnings.size(), 1, "未知分类要留一条警告：%s" % str(wrong.warnings))
	assert_eq(wrong.category, "structure", "写错了退回默认值，不该崩")


func test_pages_match_the_part_files() -> void:
	var library := _library()
	assert_eq(
		library.ids_for_category("structure"),
		["cube_full", "half_cube", "corner_tetra", "corner_cut"],
		"结构页：四个解析形状"
	)
	assert_eq(
		library.ids_for_category("mobility"),
		["toy_wheel_2x2", "light_truck_wheel_3x3"],
		"行驶页：两种轮胎（按 order 排）"
	)
	assert_eq(
		library.ids_for_category("weapon"), ["light_mg", "light_mg_x2", "heavy_mg"],
		"武器页：单连装 + 双联装 + 重机枪"
	)
	assert_eq(library.ids_for_category("special"), ["core"], "特殊页：核心一台一个")
	assert_eq(library.ids_for_category("utility"), [], "辅助页现在还没零件（菜单会显示提示）")
	var counts := library.category_counts()
	assert_eq(counts["structure"], 4)
	assert_eq(counts["mobility"], 2)
	assert_eq(counts["weapon"], 3)
	assert_eq(counts["utility"], 0)


## 所有轮子都是一个 .vox 里画两个物体（约定：一个零件 = 一个建模文件）。
## 这一条同时守着"轮体和轮轴是同心的"—— 偏心的话轮子会绕着轮轴画圈。
func test_light_truck_wheel_uses_one_vox_scene_for_axle_and_tire() -> void:
	var library := _library()
	var wheel := library.get_def("light_truck_wheel_3x3")
	assert_true(wheel != null, "应该有 小货车轮胎 的部件文件")
	assert_eq(wheel.category, "mobility")
	assert_true(wheel.is_wheel(), "是轮子：测试场里要变成一个驱动轮")
	assert_eq(wheel.wheel_body_model, 1, "轮体 = 同一个 .vox 里的第 1 号子模型（0 = 轮轴）")
	assert_eq(wheel.wheel_offset, Vector3i.ZERO, "位置由画布决定，不用手写微调")
	assert_eq(wheel.cubes, Vector3i(2, 2, 1), "轮轴 2x1x1 格 + 给轮胎留的高度")
	assert_eq(wheel.default_connection_face(), Vector3i(-1, 0, 0), "装车用 -x 那一面")
	var sub := wheel.sub_model_volume()
	assert_true(sub != null, "应能读出轮体体积")
	var box := PartDef.tight_bounds(sub, wheel.sub_model_offset(), Vector3.ONE)
	assert_true(
		absf(box.size.y - 3.0) < 0.07,
		"大轮胎：画布里是 48 体素 = 3 格外径（实际 %.3f）" % box.size.y
	)
	assert_true(
		absf(box.get_center().y - 0.5) < 0.07,
		"轮心要落在轮轴轴线上（轮轴占 y 0..1 格）：实际 %.3f" % box.get_center().y
	)
	assert_true(
		absf(box.get_center().z - 0.5) < 0.07, "轮心 z 对齐轴心：实际 %.3f" % box.get_center().z
	)
	assert_true(
		box.get_center().x > 2.0,
		"轮体挂在 +x 外侧那一格（轮胎在整个零件盒的 +x 面外）：实际 %.3f" % box.get_center().x
	)


## 玩具轮胎也改成了一个文件两个物体：位置同样由画布决定（这是"不写 wheel_offset"的回归测试，
## 数字和当初"两个文件 + 手写偏移"调出来的完全一样）。
func test_toy_wheel_places_its_tire_by_the_canvas_layout() -> void:
	var library := _library()
	var wheel := library.get_def("toy_wheel_2x2")
	assert_true(wheel != null, "玩具轮胎部件文件（原来叫 wheel_axle_2x2）")
	assert_eq(wheel.category, "mobility")
	assert_eq(wheel.wheel_body_model, 1, "轮体 = 第 1 号子模型")
	assert_true(wheel.is_wheel(), "是轮子")
	assert_true(
		FileAccess.file_exists(wheel.model_path), "轮轴模型文件要真的存在：%s" % wheel.model_path
	)
	var sub := wheel.sub_model_volume()
	assert_true(sub != null, "应能读出轮体体积")
	var box := PartDef.tight_bounds(sub, wheel.sub_model_offset(), Vector3.ONE)
	assert_true(absf(box.size.y - 2.0) < 0.07, "玩具轮胎外径 2 格（实际 %.3f）" % box.size.y)
	assert_true(absf(box.get_center().y - 0.0) < 0.07, "轮心在本地 y = 0（实际 %.3f）" % box.get_center().y)
	assert_true(absf(box.get_center().z - 0.5) < 0.07, "轮心在本地 z = 0.5（实际 %.3f）" % box.get_center().z)
	assert_true(
		absf(box.get_center().x - 2.40625) < 0.07,
		"轮体挂在 +x 外侧那一格（实际 %.3f）" % box.get_center().x
	)


## 老写法（轮体另存一个文件）已弃用：写了要留一条**能照着改**的警告，而不是默默生效。
func test_separate_wheel_body_file_is_deprecated_with_a_hint() -> void:
	var def := PartDef.from_text(
		"name = 老写法\nmodel = res://nope.vox\nwheel_body = res://nope_body.vox\n",
		"res://data/parts/test_old_wheel.part.txt"
	)
	var found := ""
	for warning in def.warnings:
		if str(warning).contains("wheel_body"):
			found = str(warning)
	assert_true(
		found.contains("wheel_body_model"),
		"弃用警告要说清楚改成 wheel_body_model 写法：%s" % str(def.warnings)
	)
	assert_false(def.is_wheel(), "老写法不再算轮子（数据里已经没有它了）")


## 名字里带括号的显示名要能取到短名（界面上一律显示短名，不显示 id / 文件名）。
func test_short_name_is_the_chinese_half() -> void:
	var library := _library()
	assert_eq(library.get_def("toy_wheel_2x2").short_name(), "玩具轮胎（2x2）")
	assert_eq(library.get_def("light_truck_wheel_3x3").short_name(), "小货车轮胎（3x3）")
