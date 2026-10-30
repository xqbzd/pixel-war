@tool
class_name BattleCombatHud
extends Control

## 战斗时的"自己状态"：屏幕**底部中央**一条蓝色能量条（半屏宽）+ 左边一个绿色血圈。
##
##   * 能量条：`[=====      ]` 半透明黑底 + 蓝填充 + 亮边；
##   * 血圈：绿色圆弧 = 剩余全部零件生命值 / 满血，圈里写百分比；
##   * 全用 `_draw()` 画（分辨率无关，窗口多大都居中）。
##
## 数据由 `BattleMode` 每帧喂进来（`set_state()`），这一层不碰游戏逻辑。

## 能量条占屏幕宽度的比例（用户要"大约 1/2"）
const BAR_WIDTH_RATIO := 0.5
const BAR_HEIGHT := 16.0
## 能量条离屏幕底边的距离（像素）
const BOTTOM_MARGIN := 28.0
## 血圈半径 / 圆环粗细 / 和能量条的间距（像素）
const HEALTH_RADIUS := 34.0
const HEALTH_RING := 9.0
const HEALTH_GAP := 16.0

const ENERGY_COLOUR := Color(0.28, 0.60, 1.0)
const ENERGY_EDGE := Color(0.62, 0.78, 1.0, 0.9)
const HEALTH_COLOUR := Color(0.34, 0.95, 0.42)
const HEALTH_BACK := Color(0.20, 0.24, 0.27, 0.95)

var _energy := 0.0
var _energy_max := 0.0
var _health := 1.0
var _dead := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 每帧由对战模式喂进来：能量当前值 / 上限、血量比例 0~1、是否已被击毁。
func set_state(energy: float, energy_max: float, health: float, dead: bool) -> void:
	_energy = energy
	_energy_max = energy_max
	_health = clampf(health, 0.0, 1.0)
	_dead = dead
	queue_redraw()


## 能量条的屏幕矩形（纯函数，测试直接打它）：底部居中、宽度 = 屏幕宽的 `BAR_WIDTH_RATIO`。
static func bar_rect(view: Vector2) -> Rect2:
	var width := view.x * BAR_WIDTH_RATIO
	return Rect2(
		Vector2((view.x - width) * 0.5, view.y - BOTTOM_MARGIN - BAR_HEIGHT),
		Vector2(width, BAR_HEIGHT)
	)


## 血圈的圆心（纯函数）：在能量条**左上方**。
## 用户要求：不必和能量条中心对齐 —— 抬高一点、放大一点，看起来更像"生命值"而不是"能量条配件"。
static func health_center(view: Vector2) -> Vector2:
	var bar := bar_rect(view)
	return Vector2(
		bar.position.x - HEALTH_GAP - HEALTH_RADIUS,
		bar.position.y + bar.size.y * 0.5 - HEALTH_RADIUS * 0.85
	)


func _draw() -> void:
	var view := size
	if view.x < 120.0 or view.y < 80.0:
		return
	_draw_energy_bar(view)
	_draw_health_ring(view)


func _draw_energy_bar(view: Vector2) -> void:
	var bar := bar_rect(view)
	# 底
	draw_rect(bar, Color(0.03, 0.05, 0.09, 0.72))
	var fraction := 0.0
	if _energy_max > 0.0:
		fraction = clampf(_energy / _energy_max, 0.0, 1.0)
	if fraction > 0.001:
		var fill := Rect2(
			bar.position + Vector2(2.0, 2.0),
			Vector2((bar.size.x - 4.0) * fraction, bar.size.y - 4.0)
		)
		draw_rect(fill, ENERGY_COLOUR)
		# 顶部一条浅色高光，看着像"有厚度"
		draw_rect(
			Rect2(fill.position, Vector2(fill.size.x, 3.0)), Color(1.0, 1.0, 1.0, 0.20)
		)
	# 外框
	draw_rect(bar, ENERGY_EDGE, false, 1.5)


func _draw_health_ring(view: Vector2) -> void:
	var centre := health_center(view)
	var outer := HEALTH_RADIUS + HEALTH_RING * 0.5
	# 深色底盘：让圆环和文字在任何背景上都看得清
	draw_circle(centre, outer + 2.0, Color(0.02, 0.03, 0.05, 0.55))
	draw_circle(centre, outer, Color(0.06, 0.08, 0.09, 0.92))
	# 圆环底（暗绿灰）+ 血量弧（亮绿），从 12 点方向顺时针
	draw_arc(centre, HEALTH_RADIUS, 0.0, TAU, 48, HEALTH_BACK, HEALTH_RING, true)
	if not _dead and _health > 0.001:
		draw_arc(
			centre, HEALTH_RADIUS, -PI * 0.5, -PI * 0.5 + TAU * _health, 48,
			HEALTH_COLOUR, HEALTH_RING, true
		)
	# 圈里写百分比
	var font := ThemeDB.fallback_font
	var text := "--" if _dead else "%d%%" % int(round(_health * 100.0))
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16)
	var colour := Color(0.75, 0.80, 0.84) if _dead else Color(0.92, 1.0, 0.92)
	draw_string(
		font, centre - text_size * 0.5 + Vector2(0.0, text_size.y * 0.36), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, colour
	)
