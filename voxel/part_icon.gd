@tool
class_name PartIcon
extends RefCounted

## 零件图标：把一块体素体积画成"斜向视图"的小图（物品菜单 / 物品栏用）。
##
## 为什么自己画、而不是给每个零件开一个 SubViewport 渲染：
##   * 菜单以后会有上百个零件，每个零件一个 3D 视口就是上百个渲染目标（显存 + 每帧开销）；
##   * 自绘是纯 CPU、算一次缓存成 ImageTexture，无头模式也能跑 —— 测试里可以直接断言像素；
##   * 画的是同一份体素数据（`build_volume()` + 附属子模型的轮体），所以图标和游戏里
##     看到的是同一个来源，不会出现"图标是美术画的一套、实物另一套"。
##
## 投影 = 2:1 的斜向视图（像素画里的标准等距写法），相机在 (+x, +y, +z) 一侧：
##   px = 2 * (x - z)
##   py = (x + z) - 2 * y        （y 越大 py 越小 = 越靠画面顶端）
## 一个体素 = 宽 4 px、高 4 px 的三块面：顶面菱形 + 前面（+z）平行四边形 + 右面（+x）平行四边形。
## 三块面各给一档明暗，于是平面色块也能看出体积。

## 图标边长（像素）。物品栏 / 菜单的格子都按这个尺寸摆，肉眼看不出重采样。
const TARGET := 64
## 三档明暗：顶面最亮，前面次之，右面最暗（1.0 / 0.8 / 0.6，像素游戏里最常见的一组）。
const TOP_SHADE := 1.0
const FRONT_SHADE := 0.8
const SIDE_SHADE := 0.6


## 画一个零件的图标。返回 RGBA8 的 Image；没画到东西时是整张透明图。
static func render(def: PartDef, target := TARGET) -> Image:
	var empty := Image.create_empty(target, target, false, Image.FORMAT_RGBA8)
	empty.fill(Color(0, 0, 0, 0))
	if def == null:
		return empty
	var voxels := collect(def)
	if voxels.is_empty():
		return empty
	return _fit(paint(voxels), target)


## 等比缩放后居中放进正方形（**不**拉伸成目标尺寸）：
## 图标之间的大小关系要能比 —— 玩具轮胎就该比小货车轮胎小一圈、方块就该比机器小。
static func _fit(source: Image, target: int) -> Image:
	var out := Image.create_empty(target, target, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	var scale := minf(
		float(target) / float(source.get_width()), float(target) / float(source.get_height())
	)
	var w := maxi(1, int(round(float(source.get_width()) * scale)))
	var h := maxi(1, int(round(float(source.get_height()) * scale)))
	var scaled := source
	if w != source.get_width() or h != source.get_height():
		scaled = source.duplicate() as Image
		scaled.resize(w, h, Image.INTERPOLATE_NEAREST)
	# blit_rect 是"原样拷贝"（含 alpha），不会和透明底混色
	out.blit_rect(scaled, Rect2i(0, 0, w, h), Vector2i((target - w) / 2, (target - h) / 2))
	return out


## 收集图标要画的体素：`{pos: Vector3i, colour: Color}`，pos 是**部件本地体素坐标**。
## 本体和附属子模型（轮体）都收 —— 不然轮子的图标只剩一根光轴。
static func collect(def: PartDef) -> Array:
	var out := []
	var body := def.build_volume()
	if body != null:
		# 本体的网格原点在 -model_pad（见 PartDef._build_voxel），图标要跟它对齐
		_collect_volume(body, -def.model_pad, out)
	var sub := def.sub_model_volume()
	if sub != null:
		# 轮体：位置走 PartDef 同一套规则（画布相对位置 + model_offset + wheel_offset），
		# ⚠️ 别拿 `wheel_offset` 当位置用 —— 那只是"微调"，单独用会让轮体叠在轮轴上。
		_collect_volume(sub, def.sub_model_offset_voxels(), out)
	return out


static func _collect_volume(volume: VoxVolume, offset: Vector3i, out: Array) -> void:
	for z in range(volume.size.z):
		for y in range(volume.size.y):
			for x in range(volume.size.x):
				var value := volume.get_voxel(x, y, z)
				if value == VoxVolume.EMPTY:
					continue
				out.append({
					"pos": Vector3i(x, y, z) + offset,
					"colour": volume.color_of(value),
				})


## 把体素画成图，尺寸就是投影后的紧包围盒（1 px = 半个体素）。
static func paint(voxels: Array) -> Image:
	var solid := {}
	for entry in voxels:
		solid[entry["pos"]] = true
	var min_px := 1 << 30
	var min_py := 1 << 30
	var max_px := -(1 << 30)
	var max_py := -(1 << 30)
	for entry in voxels:
		var pos: Vector3i = entry["pos"]
		var px := 2 * (pos.x - pos.z)
		var py := (pos.x + pos.z) - 2 * pos.y
		min_px = mini(min_px, px - 2)
		max_px = maxi(max_px, px + 2)
		min_py = mini(min_py, py - 2)
		max_py = maxi(max_py, py + 2)
	var image := Image.create_empty(max_px - min_px + 1, max_py - min_py + 1, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	# 画家算法：相机方向是 (+x, +y, +z)，所以 x+y+z 小的先画，近的盖住远的。
	# 用桶排序而不是 sort_custom：一个 48³ 的轮体有三万个体素，带 lambda 的比较排序
	# 在 GDScript 里要点时间，而"按 x+y+z 分桶"是线性的，还能顺手省掉闭包调用。
	var buckets := {}
	for entry in voxels:
		var depth_pos: Vector3i = entry["pos"]
		var depth := depth_pos.x + depth_pos.y + depth_pos.z
		if not buckets.has(depth):
			buckets[depth] = []
		buckets[depth].append(entry)
	var depths := buckets.keys()
	depths.sort()
	for depth in depths:
		for entry in buckets[depth]:
			_draw_voxel(image, entry, min_px, min_py, solid)
	return image


static func _draw_voxel(
	image: Image, entry: Dictionary, min_px: int, min_py: int, solid: Dictionary
) -> void:
	var pos: Vector3i = entry["pos"]
	var colour: Color = entry["colour"]
	var px := 2 * (pos.x - pos.z) - min_px
	var py := (pos.x + pos.z) - 2 * pos.y - min_py
	# 只画露在外面的面（内部面被更近的体素挡着，还白花钱）
	if not solid.has(pos + Vector3i.UP):
		_fill(image, _top_face(px, py), _shade(colour, TOP_SHADE))
	if not solid.has(pos + Vector3i(0, 0, 1)):
		_fill(image, _front_face(px, py), _shade(colour, FRONT_SHADE))
	if not solid.has(pos + Vector3i(1, 0, 0)):
		_fill(image, _right_face(px, py), _shade(colour, SIDE_SHADE))


## 顶面（+y）：4x2 的菱形
static func _top_face(px: int, py: int) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(px, py - 2),
		Vector2(px + 2, py - 1),
		Vector2(px, py),
		Vector2(px - 2, py - 1),
	])


## 前面（+z）：朝画面左下的平行四边形
static func _front_face(px: int, py: int) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(px - 2, py - 1),
		Vector2(px, py),
		Vector2(px, py + 2),
		Vector2(px - 2, py + 1),
	])


## 右面（+x）：朝画面右下的平行四边形
static func _right_face(px: int, py: int) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(px + 2, py - 1),
		Vector2(px + 2, py + 1),
		Vector2(px, py + 2),
		Vector2(px, py),
	])


## 凸多边形扫描线填充（顶点坐标都是整数，边斜率只有 0 / ±0.5 / ±2 这几种）。
## 用扫描线中心（y + 0.5）配"上闭下开"的区间判定，相邻面之间不会漏缝也不会重复涂满。
static func _fill(image: Image, points: PackedVector2Array, colour: Color) -> void:
	if points.size() < 3:
		return
	var min_y := INF
	var max_y := -INF
	for point in points:
		min_y = minf(min_y, point.y)
		max_y = maxf(max_y, point.y)
	var width := image.get_width()
	var height := image.get_height()
	for row in range(int(ceil(min_y)), int(floor(max_y)) + 1):
		if row < 0 or row >= height:
			continue
		var centre := float(row) + 0.5
		var lo := INF
		var hi := -INF
		for i in points.size():
			var a := points[i]
			var b := points[(i + 1) % points.size()]
			if a.y == b.y:
				continue
			var top := minf(a.y, b.y)
			var bottom := maxf(a.y, b.y)
			if centre < top or centre >= bottom:
				continue
			var x := a.x + (b.x - a.x) * (centre - a.y) / (b.y - a.y)
			lo = minf(lo, x)
			hi = maxf(hi, x)
		if lo > hi:
			continue
		for column in range(maxi(0, int(ceil(lo))), mini(width - 1, int(floor(hi))) + 1):
			image.set_pixel(column, row, colour)


static func _shade(colour: Color, factor: float) -> Color:
	return Color(
		clampf(colour.r * factor, 0.0, 1.0),
		clampf(colour.g * factor, 0.0, 1.0),
		clampf(colour.b * factor, 0.0, 1.0),
		1.0
	)
