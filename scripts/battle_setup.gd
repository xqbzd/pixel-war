extends Control

## 进入战斗前的**配置界面**（用户 2026-10-19 的要求）：
##
##   ① 先选模式：左 = 匹配模式（暂未开放，占位）；右 = 自定义房间（可用）。
##   ② 进自定义房间后：
##      * 中间上：游戏模式 / 地图（现在各只有一个：歼灭模式·不可复活、平原草地）；
##      * 左右：两队各 **5 个格子**，玩家默认在左队第 1 格，其余为空；
##      * 下方：添加人机（下拉选所有存储载具）/ 换位到此 / 邀请朋友（占位）/ 开始游戏。
##
## 位置规则全在**纯函数**里（`default_roster()` / `move_player()` / `set_bot()` / `can_start()`），
## 测试直接打它们；这个脚本只负责把状态画出来、把点击转成状态变化。

const BATTLE_MODE_SCENE := "res://scenes/battle_mode.tscn"
const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const VEHICLE_DIR := "res://data/vehicles"
const GameSettings := preload("res://scripts/game_settings.gd")
const BattleMode := preload("res://scripts/battle_mode.gd")

## 每队几个格子
const SLOTS := 5
## 队伍名（左 / 右）
const TEAM_NAMES := ["我方", "敌方"]
const TEAM_COLOURS := [Color(0.36, 0.62, 1.0), Color(1.0, 0.32, 0.28)]

const GAME_MODES := [{"id": "elimination", "name": "歼灭模式", "detail": "一条命 · 不可复活 · 打光对面获胜"}]
const MAPS := [{"id": "plains", "name": "平原草地", "detail": "500 米缓坡草原 + 岩石掩体"}]

var _library := PartLibrary.new()
var _vehicles: Array = []
var _roster := []
## 当前选中的格子（team, index）；(-1, -1) = 没选
var _selected := Vector2i(-1, -1)

var _mode_pick: Control
var _room: Control
var _slot_buttons := {}          # "队伍:格子" -> Button
var _start_button: Button
var _hint: Label
var _dropdown: PopupMenu
## 点过"开始游戏"之后为 true：防止连点，也方便在换场景失败时退回来
var _starting := false
## 换场景时的"正在进入战斗…"（平时隐藏）
var _loading: Label
var _built := false


func _ready() -> void:
	if _built:
		return
	_built = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_load_vehicles()
	_roster = BattleRoster.default_roster(_player_vehicle_id())
	_build_ui()
	_show_mode_pick()


# ──────────────────────────────────────────────────────────── 数据 / 界面

func _load_vehicles() -> void:
	_library.load_all()
	_vehicles = VehicleStore.load_all()


func _player_vehicle_id() -> String:
	var pending: Variant = TestField.pending_vehicle
	if pending is Dictionary and not (pending as Dictionary).is_empty():
		var id := str((pending as Dictionary).get("id", ""))
		if not id.is_empty():
			return id
	return GameSettings.selected_vehicle()


func _player_vehicle_name() -> String:
	for vehicle in _vehicles:
		if str(vehicle.id) == _player_vehicle_id():
			return str(vehicle.display_name)
	return "玩家"


func _vehicle_display(vehicle_id: String) -> String:
	for vehicle in _vehicles:
		if str(vehicle.id) == vehicle_id:
			return str(vehicle.display_name)
	return vehicle_id


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color(0.05, 0.06, 0.08)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 42)
	margin.add_theme_constant_override("margin_right", 42)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 28)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	margin.add_child(column)
	# 标题
	var title := Label.new()
	title.text = "进入战斗"
	_style_label(title, 34)
	column.add_child(title)
	# 两个页面：选模式 / 自定义房间
	_mode_pick = _build_mode_pick()
	column.add_child(_mode_pick)
	_room = _build_room()
	_room.visible = false
	column.add_child(_room)
	# 换场景时盖住整屏的一行提示（平时隐藏，见 `_show_loading()`）
	_loading = Label.new()
	_loading.name = "Loading"
	_loading.text = "正在进入战斗…"
	_style_label(_loading, 26)
	_loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_loading.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading.visible = false
	add_child(_loading)
	# 人机载具下拉
	_dropdown = PopupMenu.new()
	_dropdown.name = "VehicleDropdown"
	for i in _vehicles.size():
		_dropdown.add_item("%s  ·  %s" % [_vehicles[i].display_name, _vehicles[i].id], i)
	_dropdown.id_pressed.connect(_on_vehicle_picked)
	add_child(_dropdown)


func _build_mode_pick() -> Control:
	var box := HBoxContainer.new()
	box.name = "ModePick"
	box.add_theme_constant_override("separation", 22)
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var match_button := _big_card("匹配模式", "暂未开放\n以后在这里找房间", false)
	match_button.name = "MatchMode"
	match_button.disabled = true
	box.add_child(match_button)
	var room_button := _big_card("自定义房间", "自己配两队 5 个格子\n选模式 / 地图 / 人机", true)
	room_button.name = "CustomRoom"
	room_button.pressed.connect(_show_room)
	box.add_child(room_button)
	return box


## 一张大卡片按钮（上半是标题，下面是小字说明）。
func _big_card(title: String, detail: String, primary: bool) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(0, 220)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.text = "%s\n\n%s" % [title, detail]
	button.add_theme_font_size_override("font_size", 22)
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_button(button, primary)
	if not primary:
		button.add_theme_color_override("font_disabled_color", Color(0.55, 0.58, 0.64))
		button.add_theme_stylebox_override("disabled", _button_style(Color(1, 1, 1, 0.02), Color(1, 1, 1, 0.06)))
	return button


func _build_room() -> Control:
	var box := VBoxContainer.new()
	box.name = "Room"
	box.add_theme_constant_override("separation", 14)
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 顶部：返回 + 标题
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	box.add_child(top)
	var back := Button.new()
	back.text = "← 返回"
	_style_button(back, false)
	back.pressed.connect(_show_mode_pick)
	top.add_child(back)
	var room_title := Label.new()
	room_title.text = "自定义房间"
	_style_label(room_title, 20)
	top.add_child(room_title)
	# 中间：左队格子 | 模式 / 地图 | 右队格子
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 26)
	box.add_child(body)
	body.add_child(_team_column(0))
	body.add_child(_center_column())
	body.add_child(_team_column(1))
	# 底部按钮
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_theme_constant_override("separation", 14)
	box.add_child(footer)
	var add_bot := Button.new()
	add_bot.text = "添加人机"
	_style_button(add_bot, false)
	add_bot.pressed.connect(_on_add_bot)
	footer.add_child(add_bot)
	var move_here := Button.new()
	move_here.text = "换位到此"
	_style_button(move_here, false)
	move_here.pressed.connect(_on_move_player)
	footer.add_child(move_here)
	var invite := Button.new()
	invite.text = "邀请朋友"
	invite.disabled = true
	invite.tooltip_text = "联机功能以后再加"
	_style_button(invite, false)
	footer.add_child(invite)
	_start_button = Button.new()
	_start_button.text = "开始游戏"
	_start_button.custom_minimum_size = Vector2(240, 46)
	_style_button(_start_button, true)
	# 主按钮是**填色**的：一眼看出"点这里开打"（其它按钮都是描边）
	_start_button.add_theme_stylebox_override(
		"normal", _button_style(Color(0.17, 0.36, 0.66, 0.95), Color(0.43, 0.66, 1.0))
	)
	_start_button.add_theme_stylebox_override(
		"hover", _button_style(Color(0.22, 0.44, 0.78, 1.0), Color(0.58, 0.78, 1.0))
	)
	_start_button.add_theme_stylebox_override(
		"pressed", _button_style(Color(0.13, 0.28, 0.54, 1.0), Color(0.58, 0.78, 1.0))
	)
	_start_button.add_theme_stylebox_override(
		"disabled", _button_style(Color(0.11, 0.13, 0.17, 0.9), Color(1, 1, 1, 0.07))
	)
	_start_button.add_theme_color_override("font_disabled_color", Color(0.50, 0.54, 0.60))
	_start_button.pressed.connect(_on_start)
	footer.add_child(_start_button)
	_hint = Label.new()
	_style_label(_hint, 14)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.text = "点一个格子选中它，再用下面的按钮操作（两队都至少要有 1 台才能开始）"
	box.add_child(_hint)
	return box


## 中间一列：游戏模式 + 地图 + 当前选项的说明。
func _center_column() -> Control:
	var center := VBoxContainer.new()
	center.custom_minimum_size = Vector2(320, 0)
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 10)
	center.add_child(_mode_picker())
	center.add_child(_map_picker())
	var detail := Label.new()
	detail.name = "Detail"
	_style_label(detail, 14)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.custom_minimum_size = Vector2(320, 0)
	detail.add_theme_color_override("font_color", Color(0.66, 0.70, 0.78))
	detail.text = "%s\n%s\n\n%s\n%s" % [
		GAME_MODES[0]["name"], GAME_MODES[0]["detail"], MAPS[0]["name"], MAPS[0]["detail"],
	]
	center.add_child(detail)
	return center


func _mode_picker() -> Control:
	var wrap := VBoxContainer.new()
	var label := Label.new()
	label.text = "游戏模式"
	_style_label(label, 13)
	label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.74))
	wrap.add_child(label)
	var button := OptionButton.new()
	for mode in GAME_MODES:
		button.add_item(str(mode["name"]))
	button.selected = 0
	button.custom_minimum_size = Vector2(220, 34)
	button.tooltip_text = str(GAME_MODES[0]["detail"])
	wrap.add_child(button)
	return wrap


func _map_picker() -> Control:
	var wrap := VBoxContainer.new()
	var label := Label.new()
	label.text = "地图"
	_style_label(label, 13)
	label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.74))
	wrap.add_child(label)
	var button := OptionButton.new()
	for map in MAPS:
		button.add_item(str(map["name"]))
	button.selected = 0
	button.custom_minimum_size = Vector2(220, 34)
	button.tooltip_text = str(MAPS[0]["detail"])
	wrap.add_child(button)
	return wrap


func _team_column(team: int) -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 8)
	var header := Label.new()
	header.text = TEAM_NAMES[team]
	_style_label(header, 20)
	header.add_theme_color_override("font_color", TEAM_COLOURS[team])
	column.add_child(header)
	for index in SLOTS:
		var button := Button.new()
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(0, 56)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_slot_pressed.bind(team, index))
		_style_button(button, false)
		column.add_child(button)
		_slot_buttons["%d:%d" % [team, index]] = button
	return column


func _refresh() -> void:
	for team in 2:
		for index in SLOTS:
			var button: Button = _slot_buttons.get("%d:%d" % [team, index])
			if button == null:
				continue
			var slot: Dictionary = (_roster[team] as Array)[index]
			button.text = "  %d   %s" % [index + 1, _slot_text(slot)]
			var selected: bool = _selected == Vector2i(team, index)
			button.add_theme_stylebox_override(
				"normal",
				_button_style(
					Color(TEAM_COLOURS[team].r, TEAM_COLOURS[team].g, TEAM_COLOURS[team].b, 0.18 if selected else 0.03),
					TEAM_COLOURS[team] if selected else Color(1, 1, 1, 0.10)
				)
			)
	var ready_to_start := BattleRoster.can_start(_roster)
	_start_button.disabled = not ready_to_start
	var counts := "我方 %d 台  ·  敌方 %d 台" % [
		BattleRoster.team_count(_roster, 0), BattleRoster.team_count(_roster, 1),
	]
	_hint.text = counts + (
		"" if ready_to_start else "    —— 两队都至少要有 1 台才能开始（点右边格子 → 添加人机）"
	)
	# 没准备好时提示**变红**：按钮是灰的，不说明原因的话"点了没反应"很像 bug
	_hint.add_theme_color_override(
		"font_color", Color(0.66, 0.70, 0.78) if ready_to_start else Color(1.0, 0.62, 0.45)
	)


func _slot_text(slot: Dictionary) -> String:
	match str(slot.get("kind", "empty")):
		"player":
			return "玩家（%s）" % _vehicle_display(str(slot.get("vehicle", "")))
		"bot":
			return "人机（%s）" % _vehicle_display(str(slot.get("vehicle", "")))
		_:
			return "空位"


func _show_mode_pick() -> void:
	_mode_pick.visible = true
	_room.visible = false


func _show_room() -> void:
	_mode_pick.visible = false
	_room.visible = true
	if _selected.x < 0:
		var at := BattleRoster.find_player(_roster)
		_selected = Vector2i(int(at[0]), int(at[1])) if not at.is_empty() else Vector2i(0, 0)
	_refresh()


func _on_slot_pressed(team: int, index: int) -> void:
	_selected = Vector2i(team, index)
	_refresh()


## 添加人机：把下拉栏弹在按钮旁边，选一个载具放到**当前选中的格子**。
func _on_add_bot() -> void:
	if _selected.x < 0:
		_hint.text = "先点一个格子选中它，再点「添加人机」"
		return
	var slot: Dictionary = (_roster[_selected.x] as Array)[_selected.y]
	if str(slot.get("kind", "")) == "player":
		_hint.text = "这一格是玩家，不能放人机（想换位置用「换位到此」）"
		return
	if _vehicles.is_empty():
		_hint.text = "没有可用载具（%s）" % VehicleStore.write_dir()
		return
	var button := _slot_buttons.get("%d:%d" % [_selected.x, _selected.y]) as Button
	var at := button.global_position + Vector2(0, button.size.y + 4.0) if button != null else get_global_mouse_position()
	_dropdown.position = Vector2i(at)
	_dropdown.reset_size()
	_dropdown.popup()


func _on_vehicle_picked(index: int) -> void:
	if _selected.x < 0 or index < 0 or index >= _vehicles.size():
		return
	var vehicle: VehicleDef = _vehicles[index]
	if BattleRoster.set_bot(_roster, _selected.x, _selected.y, str(vehicle.id), str(vehicle.display_name)):
		_refresh()
		_hint.text = "第 %d 格：人机 · %s" % [_selected.y + 1, vehicle.display_name]


## 换位到此：把玩家挪到选中的格子（只在自己这一队里换 —— 右边那队是敌方）。
func _on_move_player() -> void:
	if _selected.x < 0:
		_hint.text = "先点一个格子选中它，再点「换位到此」"
		return
	var at: Array = BattleRoster.find_player(_roster)
	var my_team := int(at[0]) if not at.is_empty() else 0
	if _selected.x != my_team:
		_hint.text = "玩家只能在%s这边换位（右边那队是敌方）" % TEAM_NAMES[my_team]
		return
	if BattleRoster.move_player(_roster, _selected.x, _selected.y, "玩家"):
		_refresh()
		_hint.text = "玩家已换到 %s 第 %d 格" % [TEAM_NAMES[_selected.x], _selected.y + 1]


func _on_start() -> void:
	if _starting:
		return
	if not BattleRoster.can_start(_roster):
		_hint.text = "还不能开始：两队都至少要有 1 台 —— 先点右边那队的格子，再点「添加人机」"
		_hint.add_theme_color_override("font_color", Color(1.0, 0.55, 0.50))
		return
	_starting = true
	_hint.add_theme_color_override("font_color", Color(0.66, 0.70, 0.78))
	BattleMode.pending_roster = _roster.duplicate(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# ⚠️ `change_scene_to_file()` 是**帧末**才生效的：战局场景要加载 10 台车 + 场地，
	# 这一两秒里旧界面还会继续画在游戏画面上（用户报的"进战斗后 UI 没消失"）。
	# 所以先把界面收起来，只留一行"正在进入战斗…"。
	_show_loading()
	var error := get_tree().change_scene_to_file(BATTLE_MODE_SCENE)
	if error != OK:
		# 换场景失败（文件缺失之类）：退回来，别让玩家对着黑屏
		_starting = false
		_room.visible = true
		_loading.visible = false
		_hint.text = "进不去对战场景（%s），错误码 %d" % [BATTLE_MODE_SCENE, error]
		_hint.add_theme_color_override("font_color", Color(1.0, 0.55, 0.50))


## 开始游戏时把整个配置界面收起来，只显示"正在进入战斗…"。
func _show_loading() -> void:
	_mode_pick.visible = false
	_room.visible = false
	if _loading != null:
		_loading.visible = true


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _room != null and _room.visible:
			_show_mode_pick()
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# ──────────────────────────────────────────────────────────── 样式（和主界面一致）

func _style_label(label: Label, font_size: int) -> void:
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(0.90, 0.92, 0.96))
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)


func _button_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
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