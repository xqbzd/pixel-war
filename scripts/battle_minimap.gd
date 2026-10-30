@tool
class_name BattleMinimap
extends Control

## 左上角的战斗小地图：**地形缩略图 + 掩体灰点 + 敌我位置点 + 玩家白色箭头**。
##
##   * 我方 = 蓝点，敌方 = 红点（和头顶血条同色）；
##   * 敌方的红点只在"被队友看到"时才会被喂进来（见 `BattleMode._update_spotting()`）——
##     这一层不判断可见性，只画调用方给的点；
##   * 地形缩略图由 `BattleArena.map_image()` 用同一套高度/配色函数生成，所以小地图
##     和实际地形是一致的（不是随手画的一张图）。
##
## 坐标换算：世界格（cube）→ 米 → 小地图像素。地图中心 = 场地中心。

const MAP_SIZE := 190.0
const DOT_RADIUS := 3.2
## 位置点的深色描边宽度（亮色地图上纯色小点容易糊）
const DOT_OUTLINE := 1.6
const COVER_RADIUS := 1.3
const PLAYER_ARROW := 7.5
const BORDER := 2.0

var _texture: ImageTexture
var _arena_size_m := 1000.0
var _cover_points: Array = []     # Vector2（米，相对场地中心）
var _rows: Array = []             # [{pos: Vector2 米, colour: Color, radius: float}]
var _player_pos := Vector2.ZERO
var _player_yaw := 0.0
var _has_player := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 建小地图：生成地形缩略图（掩体已经烘进图里）+ 记下掩体位置。
func setup(arena: BattleArena) -> void:
	custom_minimum_size = Vector2(MAP_SIZE, MAP_SIZE)
	size = Vector2(MAP_SIZE, MAP_SIZE)
	_arena_size_m = BattleArena.SIZE_METERS
	_cover_points = arena.cover_points.duplicate()
	# 缩略图按小地图实际像素 1:1 生成（不放大、不糊）
	var image := arena.map_image(int(MAP_SIZE))
	_texture = ImageTexture.create_from_image(image)
	queue_redraw()


## 每帧由对战模式喂：位置点（已经过滤过可见性）+ 玩家自己的位置/朝向。
func set_rows(rows: Array, player_pos_m: Vector2, player_yaw: float, has_player: bool) -> void:
	_rows = rows
	_player_pos = player_pos_m
	_player_yaw = player_yaw
	_has_player = has_player
	queue_redraw()


## 世界坐标（米，相对场地中心）→ 小地图像素坐标。
static func map_position(world_m: Vector2, arena_m: float, map_px: float) -> Vector2:
	if arena_m <= 0.001:
		return Vector2.ZERO
	return (world_m / arena_m + Vector2(0.5, 0.5)) * map_px


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	if _texture != null:
		draw_texture_rect(_texture, rect, false)
	else:
		draw_rect(rect, Color(0.52, 0.66, 0.44))
	var map_size := size.x
	# 敌我位置点（掩体已经烘在缩略图里，这里每帧只画几个点 → 省 draw command）
	# 每个点先画一圈深色描边：亮色地图上纯色小圆点很容易糊进背景。
	for row in _rows:
		var point := map_position(row["pos"], _arena_size_m, map_size)
		draw_circle(point, float(row["radius"]) + DOT_OUTLINE, Color(0.05, 0.06, 0.08, 0.85))
		draw_circle(point, float(row["radius"]), row["colour"])
	# 玩家：白色箭头，指车头方向（世界里的 +x 是车头 → 地图上向右）
	if _has_player:
		var centre := map_position(_player_pos, _arena_size_m, map_size)
		var forward := Vector2(cos(_player_yaw), -sin(_player_yaw))
		var side := Vector2(-forward.y, forward.x)
		var points := PackedVector2Array([
			centre + forward * PLAYER_ARROW,
			centre - forward * PLAYER_ARROW * 0.6 + side * PLAYER_ARROW * 0.6,
			centre - forward * PLAYER_ARROW * 0.6 - side * PLAYER_ARROW * 0.6,
		])
		# 先画一圈放大的深色三角形当描边，再画白色箭头
		var outline := PackedVector2Array()
		for point in points:
			outline.append(centre + (point - centre) * 1.45)
		draw_colored_polygon(outline, Color(0.05, 0.06, 0.08, 0.85))
		draw_colored_polygon(points, Color(1.0, 1.0, 1.0, 0.98))
	# 边框：里面一道亮边（和亮色地图分界）、外面一道深色（压住 HUD 背景）
	draw_rect(rect, Color(0.92, 0.95, 0.98, 0.55), false, 1.0)
	draw_rect(rect.grow(1.0), Color(0.03, 0.04, 0.06, 0.85), false, 1.0)
