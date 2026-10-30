@tool
extends Control

## 主界面（车库）：
##   - 主体 = 当前载具的自动旋转预览（VehicleViewer 跑在 SubViewport 里）
##   - 顶栏 = 游戏设置 / 部件百科 / 进入战斗 / 进入载具编辑 / 读取载具列表（严格按此从左到右）
##   - 读取载具列表 = 点击弹出下拉栏，选中即切换预览中的载具
##   - 其余页暂时是占位（改 PANELS 的文案即可；将来把占位页换成真正的场景/脚本）
##
## 自动化/脚本接口：select_vehicle() / open_panel() / close_panel() / vehicle_ids() 等。

const PART_DIR := "res://data/parts"
const VEHICLE_DIR := "res://data/vehicles"
const BUILD_MODE_SCENE := "res://scenes/build_mode.tscn"
const TEST_FIELD_SCENE := "res://scenes/test_field.tscn"
const BATTLE_SETUP_SCENE := "res://scenes/battle_setup.tscn"
const GameSettings := preload("res://scripts/game_settings.gd")
const TOP_BAR_HEIGHT := 52.0

const TOOLBAR := [
	{"id": "settings", "label": "游戏设置"},
	{"id": "codex", "label": "部件百科"},
	{"id": "battle", "label": "进入战斗"},
	{"id": "editor", "label": "进入载具编辑"},
	{"id": "testfield", "label": "测试场"},
	{"id": "vehicles", "label": "读取载具列表", "primary": true},
]

const PANELS := {
	"settings": {
		"title": "游戏设置",
		"body": "目前只有视角灵敏度；画质、音量、按键、语言之后再补。",
	},
	"codex": {
		"title": "部件百科",
		"body": "这一页暂时留空。\n\n按计划直接读 data/parts，展示每个部件的形状、尺寸、渲染路线与成本。",
	},
}

var _library := PartLibrary.new()
var _vehicles: Array = []
var _viewer: VehicleViewer
var _preview_viewport: SubViewport
var _vehicle_catcher: Control
var _vehicle_panel: PanelContainer
var _vehicle_rows: VBoxContainer
var _dialog_layer: Control
var _dialog_title: Label
var _dialog_body: Label
var _dialog_input: LineEdit
var _dialog_mode := ""  # "rename" / "confirm"
var _dialog_target := ""  # 目标载具 id
var _info: Label
var _hint: Label
var _panel: Control
var _panel_title: Label
var _panel_body: Label
var _panel_extra: VBoxContainer
var _buttons := {}  # id -> Button
var _current_id := ""
var _last_stats := {}
var _built := false


func _ready() -> void:
	if _built:
		return
	_built = true
	# 主界面永远用可见鼠标（从测试场/建造模式回来时上一场景可能把鼠标锁住了）
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# 大厅 / 建造模式放同一首循环音乐（跨场景不断，见 scripts/game_audio.gd）
	GameSettings.play_music()
	_library.load_all(PART_DIR)
	for warning in _library.warnings:
		push_warning("part: %s" % warning)
	_vehicles = VehicleStore.load_all()
	for vehicle in _vehicles:
		for warning in vehicle.warnings:
			push_warning("vehicle[%s]: %s" % [vehicle.id, warning])
	_build_preview()
	_build_toolbar()
	_build_panel()
	_build_dialog()
	_refresh_vehicle_list()
	_hint.text = "视角自动环绕 · 左键拖拽旋转 · 滚轮缩放"
	if _vehicles.is_empty():
		_update_info()
	else:
		# 记住上次选的机库：切场景 / 退出重进都回到那一台；
		# 记录的 id 已经不存在（车被删了）才退回列表第一台。
		var remembered := GameSettings.selected_vehicle()
		if remembered.is_empty() or not select_vehicle(remembered):
			select_vehicle(_vehicles[0].id)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		close_panel()


# ---------------------------------------------------------------- 对外接口

func vehicle_ids() -> Array:
	var out := []
	for vehicle in _vehicles:
		out.append(vehicle.id)
	return out


func current_vehicle_id() -> String:
	return _current_id


func toolbar_labels() -> PackedStringArray:
	var out := PackedStringArray()
	for entry in TOOLBAR:
		var button: Button = _buttons.get(entry["id"])
		out.append(button.text if button != null else "")
	return out


func info_text() -> String:
	return _info.text if _info != null else ""


func panel_visible() -> bool:
	return _panel != null and _panel.visible


## 切换预览中的载具（下拉栏和自动化都走这里）。
func select_vehicle(id: String) -> bool:
	var vehicle := _find_vehicle(id)
	if vehicle == null:
		push_warning("MainMenu: 没有载具 '%s'" % id)
		return false
	_current_id = vehicle.id
	_last_stats = _viewer.show_vehicle(vehicle, _library)
	_update_info()
	_refresh_vehicle_list()
	# 记住这台：下次进主界面（切场景回来 / 退出重进）还选它
	GameSettings.set_selected_vehicle(vehicle.id)
	return true


func open_panel(id: String) -> bool:
	if not PANELS.has(id):
		return false
	_panel_title.text = PANELS[id]["title"]
	_panel_body.text = PANELS[id]["body"]
	# 设置页放真正的控件（视角灵敏度），其它页收回
	for child in _panel_extra.get_children():
		_panel_extra.remove_child(child)
		child.queue_free()
	_panel_extra.visible = id == "settings"
	if id == "settings":
		GameSettings.build_ui(_panel_extra)
	_panel.visible = true
	return true


func close_panel() -> void:
	if _panel != null:
		_panel.visible = false


# ---------------------------------------------------------------- 构建 UI

func _build_preview() -> void:
	var container := SubViewportContainer.new()
	container.name = "Preview"
	container.stretch = true
	container.anchor_right = 1.0
	container.anchor_bottom = 1.0
	container.offset_right = 0.0
	container.offset_bottom = 0.0
	add_child(container)

	_preview_viewport = SubViewport.new()
	_preview_viewport.name = "PreviewViewport"
	_preview_viewport.own_world_3d = true
	_preview_viewport.transparent_bg = false
	_preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_preview_viewport.size = Vector2i(1152, 648)
	container.add_child(_preview_viewport)

	_viewer = VehicleViewer.new()
	_viewer.name = "VehicleViewer"
	_preview_viewport.add_child(_viewer)

	_info = Label.new()
	_info.name = "Info"
	_info.anchor_top = 1.0
	_info.anchor_bottom = 1.0
	_info.offset_left = 16.0
	_info.offset_right = 700.0
	_info.offset_top = -46.0
	_info.offset_bottom = -20.0
	_style_label(_info, 15)
	add_child(_info)

	_hint = Label.new()
	_hint.name = "Hint"
	_hint.anchor_left = 1.0
	_hint.anchor_right = 1.0
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_left = -460.0
	_hint.offset_right = -16.0
	_hint.offset_top = -46.0
	_hint.offset_bottom = -20.0
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_style_label(_hint, 14)
	add_child(_hint)


func _build_toolbar() -> void:
	var bar := PanelContainer.new()
	bar.name = "TopBar"
	bar.anchor_right = 1.0
	bar.offset_bottom = TOP_BAR_HEIGHT
	bar.add_theme_stylebox_override("panel", _bar_style())
	add_child(bar)

	var row := HBoxContainer.new()
	row.name = "Buttons"
	row.add_theme_constant_override("separation", 8)
	bar.add_child(row)

	for entry in TOOLBAR:
		var button := Button.new()
		button.name = "Btn_" + str(entry["id"])
		button.text = str(entry["label"])
		button.custom_minimum_size = Vector2(0.0, 32.0)
		button.focus_mode = Control.FOCUS_NONE
		_style_button(button, bool(entry.get("primary", false)))
		button.pressed.connect(_on_toolbar_pressed.bind(entry["id"]))
		row.add_child(button)
		_buttons[entry["id"]] = button

	# 载具列表不用原生 PopupMenu —— 每行右侧要放「重命名 / 删除」按钮
	_vehicle_catcher = Control.new()
	_vehicle_catcher.name = "VehiclePanelCatcher"
	_vehicle_catcher.anchor_right = 1.0
	_vehicle_catcher.anchor_bottom = 1.0
	_vehicle_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_vehicle_catcher.visible = false
	_vehicle_catcher.gui_input.connect(_on_catcher_input)
	add_child(_vehicle_catcher)

	_vehicle_panel = PanelContainer.new()
	_vehicle_panel.name = "VehiclePanel"
	_vehicle_panel.visible = false
	_vehicle_panel.z_index = 10
	_vehicle_panel.add_theme_stylebox_override("panel", _card_style())
	add_child(_vehicle_panel)
	_vehicle_rows = VBoxContainer.new()
	_vehicle_rows.add_theme_constant_override("separation", 6)
	_vehicle_panel.add_child(_vehicle_rows)


func _build_panel() -> void:
	_panel = Control.new()
	_panel.name = "Placeholder"
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0
	_panel.visible = false
	add_child(_panel)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_child(dim)

	var centre := CenterContainer.new()
	centre.name = "Centre"
	centre.anchor_right = 1.0
	centre.anchor_bottom = 1.0
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(centre)

	var card := PanelContainer.new()
	card.name = "Card"
	card.add_theme_stylebox_override("panel", _card_style())
	centre.add_child(card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	card.add_child(box)

	_panel_title = Label.new()
	_panel_title.add_theme_font_size_override("font_size", 22)
	_panel_title.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	box.add_child(_panel_title)

	_panel_body = Label.new()
	_panel_body.custom_minimum_size = Vector2(420.0, 0.0)
	_panel_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_body.add_theme_font_size_override("font_size", 15)
	_panel_body.add_theme_color_override("font_color", Color(0.80, 0.83, 0.88))
	box.add_child(_panel_body)

	# 设置页要放控件（滑块），其它页只放文案
	_panel_extra = VBoxContainer.new()
	_panel_extra.add_theme_constant_override("separation", 8)
	_panel_extra.visible = false
	box.add_child(_panel_extra)

	var back := Button.new()
	back.text = "返回"
	back.custom_minimum_size = Vector2(0.0, 32.0)
	back.focus_mode = Control.FOCUS_NONE
	_style_button(back, false)
	back.pressed.connect(close_panel)
	box.add_child(back)


# ---------------------------------------------------------------- 内部

func _on_toolbar_pressed(id: String) -> void:
	if id == "vehicles":
		_open_vehicle_panel()
		return
	if id == "editor":
		var vehicle := _find_vehicle(_current_id)
		_enter_build_mode(_current_id, vehicle.display_name if vehicle != null else "")
		return
	if id == "testfield":
		# 进测试场的就是"当前预览的这辆车"
		var vehicle := _find_vehicle(_current_id)
		_enter_test_field(_current_id, vehicle.display_name if vehicle != null else "")
		return
	if id == "battle":
		# 人机对战 5v5：用"当前预览的这辆车"当玩家座驾
		var vehicle := _find_vehicle(_current_id)
		_enter_battle(_current_id, vehicle.display_name if vehicle != null else "")
		return
	open_panel(id)


func _open_vehicle_panel() -> void:
	_refresh_vehicle_list()
	var button: Button = _buttons.get("vehicles")
	if button == null:
		return
	_vehicle_panel.position = button.position + Vector2(0.0, button.size.y + 4.0)
	_vehicle_panel.visible = true
	_vehicle_catcher.visible = true


func _close_vehicle_panel() -> void:
	if _vehicle_panel != null:
		_vehicle_panel.visible = false
	if _vehicle_catcher != null:
		_vehicle_catcher.visible = false


func _on_catcher_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_close_vehicle_panel()


func _refresh_vehicle_list() -> void:
	if _vehicle_rows == null:
		return
	for child in _vehicle_rows.get_children():
		_vehicle_rows.remove_child(child)
		child.queue_free()
	for vehicle in _vehicles:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var select := Button.new()
		select.text = vehicle.display_name
		select.custom_minimum_size = Vector2(200.0, 30.0)
		select.focus_mode = Control.FOCUS_NONE
		if vehicle.id == _current_id:
			select.add_theme_color_override("font_color", Color(0.62, 0.83, 1.0))
		select.pressed.connect(_on_vehicle_picked.bind(vehicle.id))
		row.add_child(select)
		var rename_button := Button.new()
		rename_button.text = "重命名"
		rename_button.focus_mode = Control.FOCUS_NONE
		rename_button.pressed.connect(_on_rename_pressed.bind(vehicle.id))
		row.add_child(rename_button)
		var delete_button := Button.new()
		delete_button.text = "删除"
		delete_button.focus_mode = Control.FOCUS_NONE
		delete_button.pressed.connect(_on_delete_pressed.bind(vehicle.id))
		row.add_child(delete_button)
		_vehicle_rows.add_child(row)
	_vehicle_rows.add_child(HSeparator.new())
	var create := Button.new()
	create.text = "＋ 新建载具"
	create.custom_minimum_size = Vector2(200.0, 30.0)
	create.focus_mode = Control.FOCUS_NONE
	create.pressed.connect(_on_new_vehicle)
	_vehicle_rows.add_child(create)


func _on_vehicle_picked(id: String) -> void:
	select_vehicle(id)
	_close_vehicle_panel()


func _on_new_vehicle() -> void:
	_close_vehicle_panel()
	_enter_build_mode("", "未命名载具")


## 进入建造模式；id 为空 = 新建。
func _enter_build_mode(id: String, display_name: String) -> void:
	if Engine.is_editor_hint():
		return
	BuildMode.pending_vehicle = {"id": id, "name": display_name}
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(BUILD_MODE_SCENE)


## 进测试场：车辆合法性（有核心 + 全部连到核心）交给测试场自己判，判不过会在那边提示。
func _enter_test_field(id: String, display_name: String) -> void:
	if Engine.is_editor_hint():
		return
	if id.is_empty():
		open_panel("vehicles")
		return
	TestField.pending_vehicle = {"id": id, "name": display_name}
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().change_scene_to_file(TEST_FIELD_SCENE)


## 进"进入战斗"：先开**配置界面**（选模式 / 自定义房间 / 排两队 5 格），
## 在那边点"开始游戏"才真的切到对战场景（见 scripts/battle_setup.gd）。
func _enter_battle(id: String, display_name: String) -> void:
	if Engine.is_editor_hint():
		return
	if id.is_empty():
		open_panel("vehicles")
		return
	# 玩家用"当前预览的这辆车"；配置界面拿它填玩家那一格
	TestField.pending_vehicle = {"id": id, "name": display_name}
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(BATTLE_SETUP_SCENE)


func _on_rename_pressed(id: String) -> void:
	var vehicle := _find_vehicle(id)
	if vehicle == null:
		return
	_open_rename_dialog(id, vehicle.display_name)


func _on_delete_pressed(id: String) -> void:
	var vehicle := _find_vehicle(id)
	if vehicle == null:
		return
	_open_confirm_dialog(
		"删除载具",
		"确定删除「%s」吗？\n\n文件会被真的删除，不进回收站。\n%s" % [
			vehicle.display_name, VehicleStore.find_path(id)
		],
		id
	)


func _do_rename(id: String, new_name: String) -> void:
	var text := new_name.strip_edges()
	if text.is_empty():
		return
	if VehicleStore.rename(id, text):
		_reload_vehicles()
	else:
		_info.text = "改名失败：%s" % id


func _do_delete(id: String) -> void:
	if not VehicleStore.delete(id):
		_info.text = "删不掉：%s（工程自带的车在导出版里是只读的）" % id
	_reload_vehicles()


func _reload_vehicles() -> void:
	_vehicles = VehicleStore.load_all()
	if _find_vehicle(_current_id) == null:
		if _vehicles.is_empty():
			_current_id = ""
			_viewer.clear_vehicle()
			_update_info()
		else:
			select_vehicle(_vehicles[0].id)
	_refresh_vehicle_list()


## 通用弹窗：标题 + 说明 + （可选）输入框 + 取消/确定
func _build_dialog() -> void:
	_dialog_layer = Control.new()
	_dialog_layer.name = "Dialog"
	_dialog_layer.anchor_right = 1.0
	_dialog_layer.anchor_bottom = 1.0
	_dialog_layer.visible = false
	add_child(_dialog_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.65)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dialog_layer.add_child(dim)

	var centre := CenterContainer.new()
	centre.anchor_right = 1.0
	centre.anchor_bottom = 1.0
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dialog_layer.add_child(centre)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	centre.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	card.add_child(box)

	_dialog_title = Label.new()
	_dialog_title.add_theme_font_size_override("font_size", 20)
	_dialog_title.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	box.add_child(_dialog_title)

	_dialog_body = Label.new()
	_dialog_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialog_body.custom_minimum_size = Vector2(360.0, 0.0)
	_dialog_body.add_theme_font_size_override("font_size", 14)
	_dialog_body.add_theme_color_override("font_color", Color(0.80, 0.83, 0.88))
	box.add_child(_dialog_body)

	_dialog_input = LineEdit.new()
	_dialog_input.custom_minimum_size = Vector2(360.0, 32.0)
	box.add_child(_dialog_input)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(buttons)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.pressed.connect(_on_dialog_cancel)
	buttons.add_child(cancel)
	var confirm := Button.new()
	confirm.text = "确定"
	confirm.focus_mode = Control.FOCUS_NONE
	confirm.pressed.connect(_on_dialog_confirm)
	buttons.add_child(confirm)


func _open_rename_dialog(id: String, current_name: String) -> void:
	_dialog_mode = "rename"
	_dialog_target = id
	_dialog_title.text = "重命名载具"
	_dialog_body.visible = false
	_dialog_input.visible = true
	_dialog_input.text = current_name
	_dialog_layer.visible = true
	_dialog_input.grab_focus()


func _open_confirm_dialog(title_text: String, body: String, target_id: String) -> void:
	_dialog_mode = "confirm"
	_dialog_target = target_id
	_dialog_title.text = title_text
	_dialog_body.text = body
	_dialog_body.visible = true
	_dialog_input.visible = false
	_dialog_layer.visible = true


func _on_dialog_confirm() -> void:
	_dialog_layer.visible = false
	var mode := _dialog_mode
	var target := _dialog_target
	_dialog_mode = ""
	_dialog_target = ""
	if mode == "rename":
		_do_rename(target, _dialog_input.text)
	elif mode == "confirm":
		_do_delete(target)


func _on_dialog_cancel() -> void:
	_dialog_layer.visible = false
	_dialog_mode = ""
	_dialog_target = ""


func _find_vehicle(id: String) -> VehicleDef:
	for vehicle in _vehicles:
		if vehicle.id == id:
			return vehicle
	return null


func _update_info() -> void:
	if _info == null:
		return
	var vehicle := _find_vehicle(_current_id)
	if vehicle == null:
		_info.text = "没有可用载具 —— 在 %s 里放一个 *.vehicle.txt" % VehicleStore.write_dir()
		return
	_info.text = "%s · %d 个部件 · %d cube · %d tri · %d 个批次" % [
		vehicle.display_name,
		vehicle.part_count(),
		vehicle.cube_count(_library),
		int(_last_stats.get("tris", 0)),
		int(_last_stats.get("groups", 0)),
	]


func _style_label(label: Label, font_size: int) -> void:
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(0.90, 0.92, 0.96))
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)


func _bar_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.10, 0.13, 0.94)
	style.border_color = Color(0.22, 0.25, 0.32)
	style.border_width_bottom = 1
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 9.0
	style.content_margin_bottom = 9.0
	return style


func _button_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	return style


func _card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.12, 0.16)
	style.border_color = Color(0.26, 0.30, 0.38)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(22.0)
	return style


func _style_button(button: Button, primary: bool) -> void:
	var accent := Color(0.43, 0.66, 1.0) if primary else Color(0.56, 0.61, 0.71)
	button.add_theme_stylebox_override("normal", _button_style(Color(1, 1, 1, 0.02), Color(1, 1, 1, 0.07)))
	button.add_theme_stylebox_override("hover", _button_style(Color(accent.r, accent.g, accent.b, 0.20), accent))
	button.add_theme_stylebox_override("pressed", _button_style(Color(accent.r, accent.g, accent.b, 0.32), accent))
	button.add_theme_stylebox_override("focus", _button_style(Color(0, 0, 0, 0), Color(0, 0, 0, 0)))
	button.add_theme_color_override("font_color", Color(0.88, 0.90, 0.94))
	button.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	button.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
