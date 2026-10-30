@tool
extends McpTestSuite

## 物品栏（10 格）的规则 —— 纯逻辑，所以在无头模式里就能把"中键拾取"那三条分支守死。
## 规则是用户定死的，别在界面里另写一套：
##   已有该零件 → 跳到那一格 / 有空位 → 放进第一个空格 / 全满 → 顶掉当前选中格。


func suite_name() -> String:
	return "loadout"


func test_starts_with_ten_empty_slots() -> void:
	var loadout := PartLoadout.new()
	assert_eq(PartLoadout.SLOT_COUNT, 10, "用户要求：物品栏 10 格，按 1..0 选")
	assert_eq(loadout.slots.size(), 10, "格子数")
	assert_eq(loadout.selected, 0, "一进来选第 1 格")
	for i in range(PartLoadout.SLOT_COUNT):
		assert_eq(loadout.part_at(i), "", "第 %d 格一开始是空的" % (i + 1))
	assert_eq(loadout.first_empty(), 0)


func test_prefill_puts_the_first_ten_parts_in_order() -> void:
	var loadout := PartLoadout.new()
	loadout.fill_from(["a", "b", "c"])
	assert_eq(loadout.part_at(0), "a")
	assert_eq(loadout.part_at(2), "c")
	assert_eq(loadout.part_at(3), "", "装不下的格子留空")
	var many := []
	for i in range(14):
		many.append("p%d" % i)
	loadout.fill_from(many)
	assert_eq(loadout.slots.size(), 10, "预填不会把物品栏撑大")
	assert_eq(loadout.part_at(9), "p9", "第 10 格")
	assert_eq(loadout.part_at(10), "", "越界读返回空串，不崩")


func test_middle_click_jumps_when_the_part_is_already_in_the_bar() -> void:
	var loadout := PartLoadout.new()
	loadout.set_slot(7, "light_mg")
	var result := loadout.pick("light_mg")
	assert_eq(result["action"], PartLoadout.ACTION_JUMP, "物品栏里已经有这个零件 → 跳过去")
	assert_eq(result["slot"], 7)
	assert_eq(loadout.selected, 7, "跳过去 = 光标也跟过去")
	assert_eq(loadout.part_at(7), "light_mg", "不会把零件挪走")


func test_middle_click_fills_the_first_empty_slot() -> void:
	var loadout := PartLoadout.new()
	loadout.set_slot(0, "cube_full")
	loadout.set_slot(1, "half_cube")
	var result := loadout.pick("core")
	assert_eq(result["action"], PartLoadout.ACTION_FILL, "不在物品栏、有空格 → 放进去")
	assert_eq(result["slot"], 2, "放进**第一个**空格")
	assert_eq(loadout.part_at(2), "core")
	assert_eq(loadout.selected, 2, "放完就切过去")
	assert_eq(loadout.part_at(0), "cube_full", "别的格子不动")


func test_middle_click_replaces_the_selected_slot_when_full() -> void:
	var loadout := PartLoadout.new()
	for i in range(PartLoadout.SLOT_COUNT):
		loadout.set_slot(i, "p%d" % i)
	loadout.select(4)
	var result := loadout.pick("core")
	assert_eq(result["action"], PartLoadout.ACTION_REPLACE, "全满且没有 → 顶掉当前选中格")
	assert_eq(result["slot"], 4, "顶掉的是**当前选中**那一格")
	assert_eq(loadout.part_at(4), "core")
	assert_eq(loadout.part_at(5), "p5", "别的格子不动")
	assert_eq(loadout.first_empty(), -1, "全满")


func test_empty_or_unknown_parts_are_ignored() -> void:
	var loadout := PartLoadout.new()
	assert_eq(loadout.pick("")["action"], PartLoadout.ACTION_NONE, "空 id 什么都不做")
	assert_eq(loadout.find(""), -1, "空 id 不算命中")
	assert_eq(loadout.find("nope"), -1)
	assert_eq(loadout.part_at(-1), "", "负数下标返回空串，不崩")


func test_swap_moves_parts_between_slots() -> void:
	var loadout := PartLoadout.new()
	loadout.set_slot(0, "a")
	loadout.set_slot(3, "b")
	loadout.swap(0, 3)
	assert_eq(loadout.part_at(0), "b")
	assert_eq(loadout.part_at(3), "a")
	loadout.swap(0, 1)
	assert_eq(loadout.part_at(1), "b", "和空格换：零件挪过去")
	assert_eq(loadout.part_at(0), "", "原来的位置空出来")
	loadout.swap(0, 99)
	assert_eq(loadout.part_at(1), "b", "越界的交换直接忽略")
	loadout.swap(1, 1)
	assert_eq(loadout.part_at(1), "b", "和自己换没有副作用")


func test_clear_slot_is_how_dragging_back_to_the_menu_works() -> void:
	var loadout := PartLoadout.new()
	loadout.set_slot(2, "core")
	loadout.clear_slot(2)
	assert_eq(loadout.part_at(2), "", "拖回菜单区域 = 这一格变空")
	assert_eq(loadout.first_empty(), 0, "空出来的格子会被下一个放进来的零件用上")


func test_assign_replaces_and_selects() -> void:
	var loadout := PartLoadout.new()
	loadout.set_slot(5, "old")
	loadout.assign(5, "new")
	assert_eq(loadout.part_at(5), "new", "拖进已有零件的那一格 = 替换")
	assert_eq(loadout.selected, 5, "换完就选中它")
	loadout.clear_all()
	assert_eq(loadout.selected, 0)
	assert_eq(loadout.first_empty(), 0, "清空后 10 格全空")
