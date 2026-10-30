@tool
extends McpTestSuite

## 零件选择界面的接线：10 格物品栏、Tab 菜单的分类页、点击菜单项落进当前格。
## 规则本身在 tests/test_part_loadout.gd 里守；这里只验"界面和规则接上了"。
## 无头模式也能跑：Control 节点不需要真的显示在屏幕上。

const PART_DIR := "res://data/parts"

var _root: Node = null
var _picker: PartPicker = null
var _loadout: PartLoadout = null


func suite_name() -> String:
	return "picker"


func setup() -> void:
	_make_picker()


func teardown() -> void:
	_free_picker()


func _make_picker() -> void:
	if _picker != null:
		return
	var library := PartLibrary.new()
	library.load_all(PART_DIR)
	_loadout = PartLoadout.new()
	_loadout.fill_from(library.ids())
	_picker = PartPicker.new()
	# 得挂进场景树：界面的锚点 / 全局矩形这些都要靠父节点
	_root = Node.new()
	Engine.get_main_loop().root.add_child(_root)
	_root.add_child(_picker)
	_picker.setup(library, _loadout)


func _free_picker() -> void:
	if _root != null:
		_root.queue_free()
	_root = null
	_picker = null
	_loadout = null


func test_hotbar_has_ten_slots_in_order() -> void:
	assert_eq(_picker.slot_view_count(), 10, "物品栏是 10 格（1..0 选）")
	assert_eq(_picker.slot_view_part(0), "cube_full", "第 1 格 = 方块")
	assert_eq(_picker.slot_view_part(4), "toy_wheel_2x2", "第 5 格 = 玩具轮胎")
	assert_eq(_picker.slot_view_part(5), "light_truck_wheel_3x3", "第 6 格 = 小货车轮胎")
	assert_eq(_picker.slot_view_part(7), "light_mg_x2", "第 8 格 = 双联装机枪")
	assert_eq(_picker.slot_view_part(8), "heavy_mg", "第 9 格 = 重机枪")
	assert_eq(_picker.slot_view_part(9), "core", "第 10 格 = 核心")
	assert_eq(_picker.slot_view_text(0), "立方体块", "格子上写零件名字（不是 id）")
	assert_eq(_picker.slot_view_text(9), "核心（2x2）", "最后一格是核心")


func test_menu_starts_closed_and_shows_five_pages() -> void:
	assert_false(_picker.is_menu_open(), "菜单默认关着（要按 Tab）")
	_picker.set_menu_open(true)
	assert_true(_picker.is_menu_open(), "Tab 之后打开")
	assert_eq(_picker.current_category(), "structure", "打开时跳到当前零件的分类（方块 = 结构）")
	assert_eq(_picker.menu_item_count(), 4, "结构页：4 个零件")
	assert_eq(_picker.menu_item_part(0), "cube_full")
	_picker.show_category("mobility")
	assert_eq(_picker.menu_item_count(), 2, "行驶页：两种轮胎")
	assert_eq(_picker.menu_item_part(1), "light_truck_wheel_3x3")
	_picker.show_category("utility")
	assert_eq(_picker.menu_item_count(), 0, "辅助页还没零件")
	_picker.set_menu_open(false)
	assert_false(_picker.is_menu_open(), "再按一次 Tab 关掉")


func test_clicking_a_menu_item_puts_it_in_the_selected_slot() -> void:
	_picker.set_menu_open(true)
	_picker.select(9)                 # 先选最后一个空格
	_picker.show_category("special")
	assert_eq(_picker.menu_item_count(), 1, "特殊页：核心")
	_picker.click_menu_item(0)
	assert_eq(_loadout.selected_part(), "core", "点菜单里的零件 → 落进当前选中格")
	assert_eq(_picker.slot_view_part(9), "core", "符号和名字跟着更新")
	assert_eq(_picker.slot_view_text(9), "核心（2x2）")


func test_selecting_a_slot_updates_the_highlight_source_of_truth() -> void:
	_picker.select(3)
	assert_eq(_loadout.selected, 3, "选中格 = loadout 里的光标（建造枪按这个拿零件）")
	_picker.select(99)
	assert_eq(_loadout.selected, 3, "越界的选择直接忽略")
