@tool
class_name ScopeOverlay
extends Control

## 开镜遮罩（**只在开镜时显示**，用 `set_state()` 控制淡入淡出）：
##
##   * 屏幕中央一个圆形镜筒窗口，窗口外压黑 —— 一眼就知道"我在开镜"；
##   * 镜筒里一套简易十字分划 + 中心红点（红点 = 准星真正指的地方，和瞄点标记同色）；
##   * 右侧一条**倍率滑条**：底 → 上 = 2 倍 → 16 倍，滚轮调倍率时滑块跟着走。
##
## 为什么滑条用**对数**刻度：倍率是乘法步进（每格 ×1.25），
## 对数刻度下"一格滚轮"在滑条上走的距离一样长，看着才顺。
##
## 这一切都是画出来的（`_draw()`），没有贴图素材 —— 换风格只用改这个文件。
## 只有状态变了才 `queue_redraw()`，所以开镜不放滚轮时它每帧几乎不花时间。

## 镜筒外面的压黑强度（1 = 全黑）。留一点点透明，能隐约看到外面在动，不至于心慌。
const MASK_ALPHA := 0.97
## 圆窗半径 = 屏幕短边 × 这个比例（0.42 ≈ 直径占短边的 84%）
const WINDOW_RATIO := 0.42
## 分划颜色：**黑边 + 亮芯**（只画黑色的话，对着暗处/房子墙就看不见了；
## 只画白色的话，对着亮草地又糊成一片）。线宽也一样：黑 3px 垫底、白 1px 盖上去。
const RETICLE_DARK := Color(0.0, 0.0, 0.0, 0.72)
const RETICLE_LIGHT := Color(0.93, 0.94, 0.96, 0.85)
const RETICLE_WIDTH := 1.0
## 淡入淡出速度（1/秒）：0.1 秒左右到位；0 = 瞬间
const FADE_SPEED := 10.0

## 右侧倍率滑条
const TRACK_MARGIN_RIGHT := 44.0   # 滑条离屏幕右边的距离（像素）
const TRACK_LENGTH := 240.0        # 滑条总长（像素）
const TRACK_WIDTH := 6.0
const KNOB_RADIUS := 7.0
const TICK_FONT_SIZE := 12
const VALUE_FONT_SIZE := 16

var _zoom := 2.0
var _zoom_min := 2.0
var _zoom_max := 16.0
var _target_alpha := 0.0
var _alpha := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


## 每帧由测试场调：开没开镜、当前倍率、倍率范围。状态没变就不重画。
func set_state(scoped: bool, zoom: float, zoom_min: float, zoom_max: float) -> void:
	_target_alpha = 1.0 if scoped else 0.0
	if (
		not is_equal_approx(zoom, _zoom)
		or not is_equal_approx(zoom_min, _zoom_min)
		or not is_equal_approx(zoom_max, _zoom_max)
	):
		_zoom = zoom
		_zoom_min = zoom_min
		_zoom_max = zoom_max
		queue_redraw()


## 当前不透明度（0 = 完全收起）。测试场用它决定要不要显示原来的白色准星。
func visual_alpha() -> float:
	return _alpha


func _process(delta: float) -> void:
	if is_equal_approx(_alpha, _target_alpha):
		return
	_alpha = (
		_target_alpha
		if FADE_SPEED <= 0.0
		else move_toward(_alpha, _target_alpha, FADE_SPEED * delta)
	)
	queue_redraw()


## 倍率在滑条上的位置：0 = 最小倍率（底），1 = 最大倍率（顶）。
## **对数**刻度：每格滚轮（×1.25）在滑条上走一样长的距离。
static func track_ratio(zoom: float, zoom_min: float, zoom_max: float) -> float:
	if zoom_max <= zoom_min:
		return 0.0
	var lo := log(maxf(zoom_min, 0.001))
	var hi := log(maxf(zoom_max, 0.001))
	return clampf((log(maxf(zoom, 0.001)) - lo) / (hi - lo), 0.0, 1.0)


func _draw() -> void:
	if _alpha <= 0.001:
		return
	var a := clampf(_alpha, 0.0, 1.0)
	var centre := size * 0.5
	var radius := maxf(32.0, minf(size.x, size.y) * WINDOW_RATIO)
	_draw_tube(centre, radius, a)
	_draw_reticle(centre, radius, a)
	_draw_zoom_track(centre, a)


## 镜筒：外面用一条"宽度极大"的圆弧环压黑（内边正好落在圆窗上），
## 比"四块矩形 + 四个角"少一堆接缝；再给镜筒边缘描一圈细灰线。
func _draw_tube(centre: Vector2, radius: float, a: float) -> void:
	var band := maxf(size.x, size.y) * 2.0
	draw_arc(centre, radius + band * 0.5, 0.0, TAU, 96, Color(0, 0, 0, MASK_ALPHA * a), band, false)
	draw_arc(centre, radius, 0.0, TAU, 96, Color(0.0, 0.0, 0.0, 0.55 * a), 5.0, true)
	draw_arc(centre, radius - 1.5, 0.0, TAU, 96, Color(0.78, 0.8, 0.84, 0.9 * a), 2.0, true)


## 十字分划：中心留一个缺口（别挡住瞄点），左右各两档密位刻度，中心一个红点。
func _draw_reticle(centre: Vector2, radius: float, a: float) -> void:
	var gap := maxf(7.0, radius * 0.05)
	var outer := radius - 5.0
	var dirs: Array[Vector2] = [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]
	for dir in dirs:
		_reticle_line(centre + dir * gap, centre + dir * outer, a)
	var sides: Array[Vector2] = [Vector2.RIGHT, Vector2.LEFT]
	for factor in [0.35, 0.65]:
		for dir in sides:
			var p := centre + dir * (radius * float(factor))
			_reticle_line(p - Vector2(0.0, 4.0), p + Vector2(0.0, 4.0), a)
	# 中心红点：和瞄点标记一个颜色 —— 它指的那一点就是转塔瞄的地方
	draw_circle(centre, 2.4, Color(0.0, 0.0, 0.0, 0.6 * a))
	draw_circle(centre, 1.6, Color(1.0, 0.3, 0.26, 0.95 * a))


## 一条分划线：黑边垫底 + 亮芯。在亮草地和暗墙前面都看得清。
func _reticle_line(from: Vector2, to: Vector2, a: float) -> void:
	draw_line(from, to, Color(RETICLE_DARK, RETICLE_DARK.a * a), RETICLE_WIDTH + 2.0, true)
	draw_line(from, to, Color(RETICLE_LIGHT, RETICLE_LIGHT.a * a), RETICLE_WIDTH, true)


## 右侧倍率滑条：底槽 + 已选部分 + 滑块 + 刻度 + 当前倍率数字。
func _draw_zoom_track(centre: Vector2, a: float) -> void:
	var track_x := size.x - TRACK_MARGIN_RIGHT
	var top := centre.y - TRACK_LENGTH * 0.5
	var bottom := centre.y + TRACK_LENGTH * 0.5
	var t := track_ratio(_zoom, _zoom_min, _zoom_max)
	var knob_y := lerpf(bottom, top, t)
	var font := ThemeDB.fallback_font
	# 底槽 + 已选部分（从底往上填，像音量条）
	draw_line(Vector2(track_x, top), Vector2(track_x, bottom), Color(1, 1, 1, 0.16 * a), TRACK_WIDTH, true)
	draw_line(
		Vector2(track_x, knob_y), Vector2(track_x, bottom),
		Color(1.0, 0.72, 0.28, 0.9 * a), TRACK_WIDTH, true
	)
	# 刻度：2 / 4 / 8 / 16 倍（超出范围的跳过）
	for mark in [2.0, 4.0, 8.0, 16.0]:
		if mark < _zoom_min - 0.001 or mark > _zoom_max + 0.001:
			continue
		var y := lerpf(bottom, top, track_ratio(mark, _zoom_min, _zoom_max))
		draw_line(
			Vector2(track_x - 7.0, y), Vector2(track_x + 7.0, y),
			Color(1, 1, 1, 0.35 * a), 1.0, true
		)
		# 滑块正好压在这档上时别写标签：不然"×8"和当前倍率数字挤成一团
		if absf(y - knob_y) < 12.0:
			continue
		draw_string(
			font, Vector2(track_x - 52.0, y + 4.0), "×%d" % int(mark),
			HORIZONTAL_ALIGNMENT_RIGHT, 36.0, TICK_FONT_SIZE, Color(1, 1, 1, 0.45 * a)
		)
	# 滑块 + 当前倍率（数字放刻度标签**左边**，别和最近那档刻度撞在一起）
	draw_circle(Vector2(track_x, knob_y), KNOB_RADIUS, Color(1.0, 0.82, 0.42, a))
	draw_circle(Vector2(track_x, knob_y), KNOB_RADIUS - 2.5, Color(0.12, 0.1, 0.06, a))
	draw_string(
		font, Vector2(track_x - 136.0, knob_y + 6.0), "×%.1f" % _zoom,
		HORIZONTAL_ALIGNMENT_RIGHT, 70.0, VALUE_FONT_SIZE, Color(1.0, 0.85, 0.5, a)
	)
