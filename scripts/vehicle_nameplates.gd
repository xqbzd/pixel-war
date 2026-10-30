@tool
class_name VehicleNameplates
extends Control

## 载具头顶的**名字 + 血条**（血条 = 剩余全部零件生命值 / 满血）。
##
## 为什么画在屏幕空间而不是 3D 广告牌：
##   * 文字清晰（Label3D 远了会糊成一团），字号/血条大小可以按距离缩放；
##   * 不用给每台车生成材质/网格，也没有"两个四边形抢深度"的问题；
##   * 被墙挡住的车由**点名逻辑**（对战模式的 `_update_spotting()`）决定画不画，
##     这一层只负责"给我一串屏幕上的行，我画出来"。
##
## 颜色：**我方蓝、敌方红**（血条边框 + 名字同色）。敌方只有在被队友"看到"之后
## 才会出现在这串行里（见 `BattleMode._update_spotting()`）。

const BAR_WIDTH := 96.0        # 血条宽（屏幕像素，基准距离下）
const BAR_HEIGHT := 9.0
const NAME_FONT_SIZE := 13
const NAME_GAP := 4.0          # 名字和血条之间的间距
## 距离缩放：`scale = clamp(BAR_WIDTH_AT / distance)`，近处大、远处小
const SCALE_DISTANCE := 240.0
const MIN_SCALE := 0.55
const MAX_SCALE := 1.25
## 超过这个距离（格）干脆不画（800 格 = 400 米）
const MAX_DISTANCE := 800.0

## 每一行：{world: Vector3, label: String, fraction: float, colour: Color}
var _rows: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 每帧由对战模式喂进来（已经按"该不该看见"过滤过了）。
func set_rows(rows: Array) -> void:
	_rows = rows
	queue_redraw()


## 屏幕坐标：世界点 → 视口像素。相机不在 / 点在背后 → 返回 false（不画）。
static func project(camera: Camera3D, world: Vector3) -> Vector2:
	return camera.unproject_position(world)


func _draw() -> void:
	if _rows.is_empty():
		return
	var font := ThemeDB.fallback_font
	for row in _rows:
		var world: Vector3 = row["world"]
		var camera: Camera3D = row.get("camera")
		if camera == null or camera.is_position_behind(world):
			continue
		var distance := camera.global_position.distance_to(world)
		if distance > MAX_DISTANCE:
			continue
		var pos := project(camera, world)
		var scale := clampf(SCALE_DISTANCE / maxf(60.0, distance), MIN_SCALE, MAX_SCALE)
		var width := BAR_WIDTH * scale
		var height := BAR_HEIGHT * scale
		var colour: Color = row["colour"]
		# 名字在血条**上面**，同样颜色（用户要求）；文字宽度按字号量出来再居中
		var text := str(row["label"])
		var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT_SIZE)
		var text_pos := Vector2(
			pos.x - text_size.x * 0.5,
			pos.y - height * 0.5 - NAME_GAP - 2.0
		)
		draw_string(
			font, text_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT_SIZE,
			Color(0, 0, 0, 0.95)
		)
		draw_string(
			font, text_pos + Vector2(0.0, -1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			NAME_FONT_SIZE, colour
		)
		# 血条：黑底 + 彩色填充 + 同色边框
		var top_left := Vector2(pos.x - width * 0.5, pos.y - height * 0.5)
		var rect := Rect2(top_left, Vector2(width, height))
		draw_rect(rect, Color(0.02, 0.03, 0.05, 0.72))
		var fraction := clampf(float(row["fraction"]), 0.0, 1.0)
		if fraction > 0.001:
			draw_rect(
				Rect2(top_left + Vector2(1.0, 1.0), Vector2((width - 2.0) * fraction, height - 2.0)),
				colour
			)
		draw_rect(rect, Color(colour.r, colour.g, colour.b, 0.9), false, 1.0)
