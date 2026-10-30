extends McpTestSuite

## 零件碎片（纯视效）：爆出几块、会飞会落、寿命到了消失、颜色直接来自零件体素。

func suite_name() -> String:
	return "debris"


## 一个零件炸出 `CHUNKS_PER_PART` 块；会动、受重力、寿命到了全部回收。
func test_burst_flight_and_lifetime() -> void:
	var debris := Debris.new()
	debris.burst(Vector3(10.0, 5.0, 3.0), Color(0.8, 0.2, 0.1))
	assert_eq(debris.alive_count(), Debris.CHUNKS_PER_PART, "每个零件炸出固定块数")
	var start: Vector3 = debris._pos[0]
	debris.advance(1.0 / 60.0)
	assert_true(debris._pos[0].distance_to(start) > 0.0, "碎片会动")
	# 初速向上 + 重力：竖直速度应该被重力往下拉
	var vy_before: float = debris._vel[0].y
	for _i in 20:
		debris.advance(1.0 / 60.0)
	assert_true(debris._vel[0].y < vy_before, "重力把碎片往下拉")
	# 寿命：一直推进到超过 CHUNK_LIFE，全部回收
	for _i in 300:
		debris.advance(0.1)
	assert_eq(debris.alive_count(), 0, "寿命到了碎片就消失")
	debris.free()


## 超出上限时不扩容、总数不超过 `MAX_CHUNKS`（旧的最先被顶掉）。
func test_chunk_pool_is_capped() -> void:
	var debris := Debris.new()
	for _i in 80:
		debris.burst(Vector3.ZERO, Color.WHITE)
	assert_true(
		debris.alive_count() <= Debris.MAX_CHUNKS,
		"碎片总数不能超过上限（实际 %d / %d）" % [debris.alive_count(), Debris.MAX_CHUNKS]
	)
	debris.free()


## 碎片颜色直接来自零件体素（平均色）：不透明、而且第二次调用是缓存的同一个值。
func test_debris_colour_comes_from_the_part() -> void:
	var library := PartLibrary.new()
	library.load_all("res://data/parts")
	var def := library.get_def("light_mg")
	assert_true(def != null, "缺少 light_mg")
	if def == null:
		return
	var colour := def.debris_colour()
	assert_true(absf(colour.a - 1.0) < 0.001, "碎片颜色要是不透明的（a=%.2f）" % colour.a)
	assert_true(
		colour.r + colour.g + colour.b > 0.05, "不能全黑（模型读不出来时会退回 body_color）"
	)
	assert_true(def.debris_colour() == colour, "算过一次就缓存，颜色稳定")

## 碎片颜色跟着零件走：多色零件会给出多种颜色，每块从中随机挑（还带亮度抖动）。
func test_debris_palette_comes_from_the_part() -> void:
	var library := PartLibrary.new()
	library.load_all("res://data/parts")
	var core := library.get_def("core")
	assert_true(core != null, "缺少 core")
	if core == null:
		return
	var palette: PackedColorArray = core.debris_palette()
	assert_true(palette.size() >= 1, "颜色表至少一种颜色")
	# 多色零件（双联装机枪：黑管 + 军绿 + 黄）应该给出多种颜色
	var mg := library.get_def("light_mg_x2")
	if mg != null:
		var mg_palette: PackedColorArray = mg.debris_palette()
		assert_true(
			mg_palette.size() >= 2,
			"双联装机枪应该是多色的（实际 %d 种）" % mg_palette.size()
		)
		# 每块的颜色从中随机挑：抽 24 次至少出现 2 种（亮度抖动后按色相判断）
		var debris := Debris.new()
		var distinct := {}
		for _i in 24:
			var colour := debris._pick_colour(mg_palette)
			distinct[Vector3i(int(colour.r * 8.0), int(colour.g * 8.0), int(colour.b * 8.0))] = true
		assert_true(distinct.size() >= 2, "碎片应该挑出不止一种颜色（实际 %d）" % distinct.size())
		debris.free()
