@tool
class_name PartPicker
extends Control

## 建造模式的零件选择界面：
##   * 底部 **10 格物品栏**（1..0 选格子）—— 一直显示
##   * `Tab` 呼出的**零件菜单**（悬浮在屏幕中间）—— 左边 5 个分类按钮，右边这一类的零件
## 每一格 / 每一项都是"斜向视图图标 + 名字"，图标来自 `PartLibrary.icon()`（按需生成 + 缓存）。
##
## 拖拽是自己实现的，没用引擎自带的 `_get_drag_data`：规则里有一条
## "拖回菜单区域 = 清空这一格"，而引擎的拖放只认"鼠标底下那个控件肯不肯接"，
## 铺满全屏的遮罩层会让这条规则变得很别扭。自己实现只要三个判断：
## 落在哪个格子上 / 落在菜单区域里 / 都不在（= 取消）。
##
## 只管"选零件"这一件事：建造枪的瞄准、投影、放置还在 scripts/build_mode.gd。

signal slot_selected(index: int)   # 选中了第几格（数字键 / 点格子 / 拖完自动选中）
signal slot_changed(index: int)    # 某一格的内容变了（手上的模型要重刷）
signal menu_toggled(open: bool)    # 菜单开 / 关（外部据此决定鼠标锁不锁）
signal notify(text: String)        # 给 HUD 的一行提示

const SLOT_COUNT := PartLoadout.SLOT_COUNT
const ICON_SIZE := float(PartIcon.TARGET)
## 按下之后移动超过这么多像素才算"拖拽"，否则当点击 —— 免得点格子的时候手抖变成拖动
const DRAG_THRESHOLD := 6.0
const SLOT_BOX := Vector2(84.0, 96.0)
const ITEM_BOX := Vector2(96.0, 112.0)
const PREVIEW_SIZE := Vector2(48.0, 48.0)

var _library: PartLibrary
var _loadout: PartLoadout
var _category := PartDef.CATEGORIES[0]

var _hotbar: HBoxContainer
var _slot_views: Array = []
var _menu_layer: Control
var _card: PanelContainer
var _grid: GridContainer
var _header: Label
var _category_buttons := {}
var _preview: TextureRect

var _press_view: Variant = null    # 按下时记住"从哪儿按的"（可能是点击，也可能是拖拽）
var _drag_view: Variant = null
var _press_origin := Vector2.ZERO
var _highlight := -1               # 拖拽时高亮的格子（只在变化时重画样式，别每帧新建一堆 StyleBox）


## 物品栏的一个格子 / 菜单里的一个零件项。自己认按下，交给 picker 处理。
class ItemView extends PanelContainer:
	var picker: PartPicker
	var source := "slot"     # "slot" | "menu"
	var index := 0           # source == "slot" 时是格子序号
	var part_id := ""
	var icon: TextureRect
	var name_label: Label
	var number_label: Label

	func _gui_input(event: InputEvent) -> void:
		if (
			event is InputEventMouseButton
			and event.button_index == MOUSE_BUTTON_LEFT
			and event.pressed
		):
			picker.begin_press(self)


func setup(library: PartLibrary, loadout: PartLoadout) -> void:
	_library = library
	_loadout = loadout
	name = "PartPicker"
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ⚠️ 顺序有意义：先建菜单（带全屏遮罩），后建物品栏 —— 后加的兄弟姐妹在上面，
	# 于是"菜单开着"时物品栏照常点得到，遮罩只挡住菜单四周的空白区域。
	_build_menu()
	_build_hotbar()
	_build_preview()
	refresh_slots()


# ---------------------------------------------------------------- 物品栏

func _build_hotbar() -> void:
	var centre := CenterContainer.new()
	centre.name = "Hotbar"
	centre.anchor_right = 1.0
	centre.anchor_top = 1.0
	centre.anchor_bottom = 1.0
	centre.offset_top = -SLOT_BOX.y - 10.0
	centre.offset_bottom = -10.0
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	_hotbar = HBoxContainer.new()
	_hotbar.add_theme_constant_override("separation", 6)
	_hotbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(_hotbar)
	for i in range(SLOT_COUNT):
		var view := _make_view("slot", i, SLOT_BOX, 11)
		# 序号：1..9 然后 0（和键盘上那排一样）
		view.number_label.text = str((i + 1) % 10)
		_hotbar.add_child(view)
		_slot_views.append(view)


## 一格 / 一项的骨架：左上角序号 + 中间图标 + 下方名字
func _make_view(source: String, index: int, box: Vector2, name_font: int) -> ItemView:
	var view := ItemView.new()
	view.picker = self
	view.source = source
	view.index = index
	view.custom_minimum_size = box
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	# PanelContainer 会把子控件撑满，所以内容层用绝对定位，尺寸自己说了算
	var layer := Control.new()
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.custom_minimum_size = box
	view.add_child(layer)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.position = Vector2((box.x - ICON_SIZE) * 0.5, (box.y - ICON_SIZE) * 0.5 - 8.0)
	icon.size = Vector2(ICON_SIZE, ICON_SIZE)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(icon)
	var name_label := Label.new()
	name_label.name = "Name"
	name_label.position = Vector2(2.0, box.y - 17.0)
	name_label.size = Vector2(box.x - 4.0, 15.0)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.add_theme_font_size_override("font_size", name_font)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(name_label)
	var number_label := Label.new()
	number_label.name = "Number"
	number_label.position = Vector2(5.0, 2.0)
	number_label.add_theme_font_size_override("font_size", 11)
	number_label.add_theme_color_override("font_color", Color(0.70, 0.76, 0.86))
	number_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(number_label)
	view.icon = icon
	view.name_label = name_label
	view.number_label = number_label
	return view


## 按 loadout 的当前状态重画物品栏（选中高亮 / 图标 / 名字）。
func refresh_slots() -> void:
	for i in range(_slot_views.size()):
		var view: ItemView = _slot_views[i]
		var part_id := _loadout.part_at(i)
		view.part_id = part_id
		var def: PartDef = null if part_id.is_empty() else _library.get_def(part_id)
		view.icon.texture = null if def == null else _library.icon(part_id)
		view.name_label.text = "" if def == null else def.short_name()
		_apply_view_style(view, i == _loadout.selected, false, def != null)


## 格子 / 菜单项的样式。
##
## ⚠️ 底色是**白**的（2026-10-15 用户要求）：零件本身是浅灰/浅蓝的体素，深蓝底看不清楚。
## 底白了，字就必须是深的 —— 所以序号和名字的颜色也在这里一起定，别在别处单独改。
func _apply_view_style(view: ItemView, selected: bool, highlight: bool, filled: bool) -> void:
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(6)
	style.set_content_margin_all(2.0)
	# 空格子淡一点：一眼看得出"这里没东西"
	style.bg_color = Color(1.0, 1.0, 1.0, 0.95 if filled else 0.5)
	style.border_color = Color(0.13, 0.15, 0.19, 0.55)
	if selected:
		style.bg_color = Color(0.86, 0.93, 1.0, 0.98)
		style.border_color = Color(0.43, 0.66, 1.0)
	elif highlight:
		style.bg_color = Color(0.92, 0.97, 1.0, 0.98)
		style.border_color = Color(0.30, 0.60, 1.0, 0.95)
	style.set_border_width_all(2 if selected or highlight else 1)
	view.add_theme_stylebox_override("panel", style)
	view.number_label.add_theme_color_override("font_color", Color(0.28, 0.31, 0.36))
	view.name_label.add_theme_color_override(
		"font_color", Color(0.12, 0.14, 0.18) if filled else Color(0.52, 0.55, 0.60)
	)


# ---------------------------------------------------------------- 零件菜单

func _build_menu() -> void:
	_menu_layer = Control.new()
	_menu_layer.name = "PartMenu"
	_menu_layer.anchor_right = 1.0
	_menu_layer.anchor_bottom = 1.0
	_menu_layer.visible = false
	_menu_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_menu_layer)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	# 挡住建造：菜单开着的时候鼠标在界面上，点到面板外面也不该放零件
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu_layer.add_child(dim)

	var centre := CenterContainer.new()
	centre.anchor_right = 1.0
	centre.anchor_bottom = 1.0
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_layer.add_child(centre)

	_card = PanelContainer.new()
	_card.name = "Card"
	_card.add_theme_stylebox_override("panel", _card_style())
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	centre.add_child(_card)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	_card.add_child(row)

	# 左列：五个分类按钮
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	row.add_child(column)
	var title := Label.new()
	title.text = "零件类型"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(0.90, 0.92, 0.96))
	column.add_child(title)
	var group := ButtonGroup.new()
	for key in PartDef.CATEGORIES:
		var button := Button.new()
		button.text = PartDef.category_label(key)
		button.toggle_mode = true
		button.button_group = group
		button.custom_minimum_size = Vector2(118.0, 34.0)
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_show_category.bind(key))
		column.add_child(button)
		_category_buttons[key] = button

	# 右列：这一类的零件（图标 + 名字），多了就滚
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(content)
	_header = Label.new()
	_header.add_theme_font_size_override("font_size", 15)
	_header.add_theme_color_override("font_color", Color(0.90, 0.92, 0.96))
	content.add_child(_header)
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.custom_minimum_size = Vector2(556.0, 384.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.columns = 5
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	var hint := Label.new()
	hint.text = (
		"拖到物品栏 = 放进那一格 · 物品栏之间拖 = 换位置 · 拖回这里 = 清空那一格\n"
		+ "左键点零件 = 放进当前选中格 · 数字键 / 点击 = 选格子 · Tab / ESC 关闭"
	)
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.70, 0.74, 0.82))
	content.add_child(hint)


func _card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.12, 0.16, 0.98)
	style.border_color = Color(0.26, 0.30, 0.38)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(18.0)
	return style


## 切换分类页：**只建这一页的零件项**（上百个零件时别在开局一次全建出来）。
func _show_category(key: String) -> void:
	if not PartDef.CATEGORIES.has(key):
		return
	_category = key
	if _category_buttons.has(key):
		(_category_buttons[key] as Button).set_pressed_no_signal(true)
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	var ids := _library.ids_for_category(key)
	_header.text = "%s · %d 个零件" % [PartDef.category_label(key), ids.size()]
	if ids.is_empty():
		var empty := Label.new()
		empty.text = "这一类还没有零件（部件文件里写 category = %s）" % PartDef.category_label(key)
		empty.add_theme_font_size_override("font_size", 13)
		empty.add_theme_color_override("font_color", Color(0.62, 0.66, 0.74))
		_grid.add_child(empty)
		return
	for id in ids:
		var view := _make_view("menu", -1, ITEM_BOX, 12)
		view.part_id = id
		view.icon.texture = _library.icon(id)
		view.name_label.text = _library.get_def(id).short_name()
		# 菜单项和物品栏格子一个样式（白底 + 深字）—— 别让它们用主题默认的深色面板
		_apply_view_style(view, false, false, true)
		_grid.add_child(view)


## 打开菜单时跳到"当前选中那个零件所在的分类"，省得每次都要自己找
func _sync_category_to_selection() -> void:
	var part_id := _loadout.selected_part()
	if part_id.is_empty():
		_show_category(_category)
		return
	var def: PartDef = _library.get_def(part_id)
	_show_category(def.category if def != null else _category)


# ---------------------------------------------------------------- 对外接口

func is_menu_open() -> bool:
	return _menu_layer != null and _menu_layer.visible


## 菜单当前停在哪一页（分类键）
func current_category() -> String:
	return _category


## 切到某一页（点左边的分类按钮走的就是这里）
func show_category(key: String) -> void:
	_show_category(key)


func toggle_menu() -> void:
	set_menu_open(not is_menu_open())


func set_menu_open(open: bool) -> void:
	if _menu_layer == null or _menu_layer.visible == open:
		return
	_menu_layer.visible = open
	_cancel_interaction()
	if open:
		_sync_category_to_selection()
	refresh_slots()
	menu_toggled.emit(open)


## 选中第几格（数字键走这里）。
func select(index: int) -> void:
	if not _loadout.select(index):
		return
	refresh_slots()
	slot_selected.emit(index)


## ── 给测试 / 以后的快捷操作留的只读接口（别在游戏逻辑里绕开 loadout 直接改）──

func slot_view_count() -> int:
	return _slot_views.size()


## 第 i 格显示的零件 id（"" = 空）
func slot_view_part(index: int) -> String:
	if index < 0 or index >= _slot_views.size():
		return ""
	return (_slot_views[index] as ItemView).part_id


## 第 i 格的名字文字（界面上真正显示的那一行）
func slot_view_text(index: int) -> String:
	if index < 0 or index >= _slot_views.size():
		return ""
	return (_slot_views[index] as ItemView).name_label.text


func menu_item_count() -> int:
	if _grid == null:
		return 0
	var count := 0
	for child in _grid.get_children():
		if child is ItemView:
			count += 1
	return count


func menu_item_part(index: int) -> String:
	var items := _menu_items()
	if index < 0 or index >= items.size():
		return ""
	return (items[index] as ItemView).part_id


## 等价于玩家左键点菜单里的第 index 个零件（= 放进当前选中格）
func click_menu_item(index: int) -> void:
	var items := _menu_items()
	if index < 0 or index >= items.size():
		return
	_handle_click(items[index])


func _menu_items() -> Array:
	var out := []
	for child in _grid.get_children():
		if child is ItemView:
			out.append(child)
	return out


# ---------------------------------------------------------------- 交互（按下 / 拖拽 / 放开）

func begin_press(view: ItemView) -> void:
	_press_view = view
	_drag_view = null
	_press_origin = get_global_mouse_position()


func _input(event: InputEvent) -> void:
	# Tab 在这里处理（不是 _unhandled_input）：Godot 的 UI 焦点系统会先吃掉 Tab，
	# 轮到 _unhandled_input 时已经晚了。
	if (
		event is InputEventKey
		and event.pressed
		and not event.echo
		and event.keycode == KEY_TAB
	):
		toggle_menu()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		if _press_view != null and _drag_view == null:
			if _press_origin.distance_to(get_global_mouse_position()) >= DRAG_THRESHOLD:
				_start_drag()
		if _drag_view != null:
			_move_preview()
	elif (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		_finish_interaction()


func _start_drag() -> void:
	_drag_view = _press_view
	var view: ItemView = _drag_view
	_preview.texture = view.icon.texture
	_preview.visible = _preview.texture != null
	_move_preview()


func _move_preview() -> void:
	_preview.position = get_global_mouse_position() - PREVIEW_SIZE * 0.5
	var target := _slot_at(get_global_mouse_position())
	if target == _highlight:
		return
	# 拖到哪一格就把那一格点亮（松开就在这里落地）
	_highlight = target
	for i in range(_slot_views.size()):
		var view: ItemView = _slot_views[i]
		_apply_view_style(view, i == _loadout.selected, i == target, not view.part_id.is_empty())


func _finish_interaction() -> void:
	if _press_view == null and _drag_view == null:
		return   # 没按过任何格子/项（比如建造时的左键）：什么都不用做
	var view: ItemView = _press_view
	_press_view = null
	_highlight = -1
	_preview.visible = false
	if _drag_view == null:
		refresh_slots()
		if view != null:
			_handle_click(view)
		return
	_drag_view = null
	_handle_drop(view, get_global_mouse_position())
	refresh_slots()


## 没拖动 = 点击：点物品栏 = 选这一格；点菜单里的零件 = 放进当前选中格
func _handle_click(view: ItemView) -> void:
	if view.source == "slot":
		select(view.index)
		return
	if view.part_id.is_empty():
		return
	_assign_to_selected(view.part_id)


func _handle_drop(view: ItemView, mouse: Vector2) -> void:
	if view == null:
		return
	var target := _slot_at(mouse)
	if target >= 0:
		if view.source == "slot":
			if target != view.index:
				_loadout.swap(view.index, target)
				slot_changed.emit(view.index)
				slot_changed.emit(target)
			select(target)
		else:
			_loadout.assign(target, view.part_id)
			slot_changed.emit(target)
			select(target)
			notify.emit("%s 号格：%s" % [str((target + 1) % 10), view.name_label.text])
		return
	if view.source == "slot" and is_menu_open():
		# 拖回菜单区域 = 把这一格清空
		_loadout.clear_slot(view.index)
		slot_changed.emit(view.index)
		select(view.index)
		notify.emit("%d 号格已清空" % (view.index + 1))


func _assign_to_selected(part_id: String) -> void:
	var index := _loadout.selected
	_loadout.assign(index, part_id)
	slot_changed.emit(index)
	refresh_slots()
	select(index)
	notify.emit("%d 号格：%s" % [index + 1, _library.get_def(part_id).short_name()])


## 鼠标底下是第几格；不在任何格子上返回 -1
func _slot_at(mouse: Vector2) -> int:
	for i in range(_slot_views.size()):
		if (_slot_views[i] as Control).get_global_rect().has_point(mouse):
			return i
	return -1


func _cancel_interaction() -> void:
	_press_view = null
	_drag_view = null
	_highlight = -1
	if _preview != null:
		_preview.visible = false


func _build_preview() -> void:
	_preview = TextureRect.new()
	_preview.name = "DragPreview"
	_preview.size = PREVIEW_SIZE
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.z_index = 40
	_preview.visible = false
	add_child(_preview)
