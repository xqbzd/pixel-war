@tool
class_name PauseMenu
extends CanvasLayer

## ESC 暂停菜单（测试场 / 人机对战共用）：
## **返回战斗 / 游戏设置 / 自爆 / 返回主界面**。
##
## 打开时 `get_tree().paused = true`（整场停住：物理、AI、子弹、相机都不动），
## 这一层 `process_mode = ALWAYS`，所以按钮和 ESC 仍然能响应。
##
## 游戏设置直接用 `GameSettings.build_ui()` —— 和主界面「游戏设置」是同一页代码，
## 所以两边永远一致（改一处两边都变）。
##
## 自爆是**二段确认**的（先点"自爆"、再点"确认自爆"），免得手滑把自己炸了。

signal resume_requested
signal self_destruct_requested
signal quit_requested

const GameSettings := preload("res://scripts/game_settings.gd")

var _root: Control
var _options: VBoxContainer
var _confirm: VBoxContainer
var _settings: VBoxContainer


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_build()


func _build() -> void:
	_root = Control.new()
	_root.name = "PauseRoot"
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	add_child(_root)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var centre := CenterContainer.new()
	centre.anchor_right = 1.0
	centre.anchor_bottom = 1.0
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(centre)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _panel_style())
	centre.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	card.add_child(box)

	var title := Label.new()
	title.text = "暂停"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	box.add_child(title)
	var hint := Label.new()
	hint.text = "游戏已暂停（按 ESC 返回战斗）"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.72, 0.75, 0.80))
	box.add_child(hint)

	_options = VBoxContainer.new()
	_options.add_theme_constant_override("separation", 8)
	box.add_child(_options)
	_add_button(_options, "返回战斗", func() -> void: resume_requested.emit())
	_add_button(_options, "游戏设置", _show_settings)
	_add_button(_options, "自爆", _show_confirm)
	_add_button(_options, "返回主界面", func() -> void: quit_requested.emit())

	_confirm = VBoxContainer.new()
	_confirm.add_theme_constant_override("separation", 8)
	_confirm.visible = false
	box.add_child(_confirm)
	var confirm_label := Label.new()
	confirm_label.text = "确定要自爆吗？（会直接判定你被击毁）"
	confirm_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	confirm_label.custom_minimum_size = Vector2(300.0, 0.0)
	confirm_label.add_theme_font_size_override("font_size", 14)
	confirm_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.5))
	_confirm.add_child(confirm_label)
	_add_button(_confirm, "确认自爆", func() -> void: self_destruct_requested.emit())
	_add_button(_confirm, "取消", _show_options)

	_settings = VBoxContainer.new()
	_settings.add_theme_constant_override("separation", 10)
	_settings.visible = false
	box.add_child(_settings)
	var body := Label.new()
	body.text = "和主界面的「游戏设置」是同一页。"
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(320.0, 0.0)
	body.add_theme_font_size_override("font_size", 13)
	body.add_theme_color_override("font_color", Color(0.78, 0.81, 0.86))
	_settings.add_child(body)
	GameSettings.build_ui(_settings)
	_add_button(_settings, "返回", _show_options)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.12, 0.16)
	style.border_color = Color(0.26, 0.30, 0.38)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(22.0)
	return style


func _add_button(parent: Node, text: String, handler: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(240.0, 34.0)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(handler)
	parent.add_child(button)


## 打开菜单并暂停游戏。
func open() -> void:
	if _root == null:
		_build()
	visible = true
	_show_options()
	if not Engine.is_editor_hint():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# ⚠️ 只设 `SceneTree.paused` 只停**脚本**（`_physics_process` 不跑了），
	# 物理服务器还在积分：车还会带着速度滑、掉下去。所以连物理一起停。
	get_tree().paused = true
	PhysicsServer3D.set_active(false)


## 关闭菜单并继续游戏。
func close() -> void:
	visible = false
	PhysicsServer3D.set_active(true)
	get_tree().paused = false
	if not Engine.is_editor_hint():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_open() -> bool:
	return visible


## 菜单里的四个主选项（测试 / 调试用）。
func option_buttons() -> Array:
	var out := []
	if _options != null:
		for child in _options.get_children():
			if child is Button:
				out.append(child)
	return out


func _show_options() -> void:
	_options.visible = true
	_confirm.visible = false
	_settings.visible = false


func _show_confirm() -> void:
	_options.visible = false
	_confirm.visible = true
	_settings.visible = false


func _show_settings() -> void:
	_options.visible = false
	_confirm.visible = false
	_settings.visible = true


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# 菜单开着时 ESC = 返回战斗（暂停中这一层仍然会收到输入）
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		resume_requested.emit()
