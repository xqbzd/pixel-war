@tool
class_name PartLoadout
extends RefCounted

## 建造模式的物品栏（10 格）—— **纯逻辑，不碰 UI**，所以"中键拾取"那三条规则可以直接测。
##
## 规则（用户定的）：
##   * 1..0 选格子；格子可以是空的（空 = 建造枪手上没东西）
##   * 从菜单拖进格子 = 替换这一格；格子之间拖 = 交换位置；拖回菜单区域 = 清空这一格
##   * 鼠标中键点一个已经造出来的零件：
##       物品栏里已经有这个零件 → 跳到那一格
##       没有、但有空格           → 放进第一个空格并跳过去
##       没有、且格子全满         → 替换**当前选中**那一格

const SLOT_COUNT := 10
const ACTION_JUMP := "jump"        # 已经在这一格里
const ACTION_FILL := "fill"        # 塞进一个空格
const ACTION_REPLACE := "replace"  # 全满，顶掉当前选中的那一格
const ACTION_NONE := "none"

var slots: Array[String] = []
var selected := 0


func _init() -> void:
	clear_all()


## 全部清空（退出建造模式 / 测试里重置用）。
func clear_all() -> void:
	slots.clear()
	for _i in range(SLOT_COUNT):
		slots.append("")
	selected = 0


## 进入建造模式时的预填：按 order 把零件放进前几格，装不下的留在菜单里。
## （原来的物品栏就是"全部零件"，现在只有 10 格，所以按顺序装满就行。）
func fill_from(ids: Array) -> void:
	clear_all()
	for i in range(mini(SLOT_COUNT, ids.size())):
		slots[i] = str(ids[i])


func part_at(index: int) -> String:
	if index < 0 or index >= slots.size():
		return ""
	return slots[index]


func selected_part() -> String:
	return part_at(selected)


func is_empty(index: int) -> bool:
	return part_at(index).is_empty()


func set_slot(index: int, part_id: String) -> void:
	if index < 0 or index >= slots.size():
		return
	slots[index] = part_id


func select(index: int) -> bool:
	if index < 0 or index >= slots.size():
		return false
	selected = index
	return true


## 把零件放进某一格（原来那格的东西被顶掉），并把光标移到这一格。
func assign(index: int, part_id: String) -> void:
	set_slot(index, part_id)
	select(index)


## 两格互换位置（格子里拖拽）。空格子也照换，不会丢零件。
func swap(a: int, b: int) -> void:
	if a == b:
		return
	if a < 0 or b < 0 or a >= slots.size() or b >= slots.size():
		return
	var tmp := slots[a]
	slots[a] = slots[b]
	slots[b] = tmp


## 清空某一格（把零件从物品栏拖回菜单区域）。
func clear_slot(index: int) -> void:
	set_slot(index, "")


## 这个零件在第几格；不在物品栏里返回 -1。
func find(part_id: String) -> int:
	if part_id.is_empty():
		return -1
	return slots.find(part_id)


## 第一个空格；全满返回 -1。
func first_empty() -> int:
	return slots.find("")


## 中键拾取：按上面那三条规则处理，返回 {action, slot}（同时会改好光标位置）。
func pick(part_id: String) -> Dictionary:
	if part_id.is_empty():
		return {"action": ACTION_NONE, "slot": -1}
	var found := find(part_id)
	if found >= 0:
		select(found)
		return {"action": ACTION_JUMP, "slot": found}
	var empty := first_empty()
	if empty >= 0:
		assign(empty, part_id)
		return {"action": ACTION_FILL, "slot": empty}
	assign(selected, part_id)
	return {"action": ACTION_REPLACE, "slot": selected}
