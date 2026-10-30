@tool
class_name BattleRoster
extends RefCounted

## 对战的**名单**：2 队 × 5 格，每格 {kind, vehicle, name}。
##   * kind = "empty"（空位）/ "player"（玩家自己）/ "bot"（人机，vehicle = 载具 id）；
##   * 纯数据 + 纯函数：配置界面（`scripts/battle_setup.gd`）负责画，对战（`battle_mode.gd`）
##     负责按它生成；测试直接打这些静态函数，不用起 UI。

## 每队几个格子
const SLOTS := 5


## 空名单：两队各 `SLOTS` 个空位。
static func empty() -> Array:
	var roster := []
	for _team in 2:
		var slots := []
		for _i in SLOTS:
			slots.append({"kind": "empty", "vehicle": "", "name": ""})
		roster.append(slots)
	return roster


## 默认名单：玩家在左队第 1 格，其余为空（用户 2026-10-19 定的初始状态）。
static func default_roster(player_vehicle := "", player_name := "玩家") -> Array:
	var roster := empty()
	(roster[0] as Array)[0] = {"kind": "player", "vehicle": player_vehicle, "name": player_name}
	return roster


## 找玩家在哪一格：返回 [队伍, 格子]；找不到返回 []。
static func find_player(roster: Array) -> Array:
	for team in roster.size():
		var slots: Array = roster[team]
		for index in slots.size():
			if str((slots[index] as Dictionary).get("kind", "")) == "player":
				return [team, index]
	return []


## 把玩家挪到 (team, index)：原来那格清空，目标格（空位/人机）变成玩家。返回是否成功。
static func move_player(roster: Array, team: int, index: int, player_name := "玩家") -> bool:
	if not _fits(roster, team, index):
		return false
	var at := find_player(roster)
	if not at.is_empty() and int(at[0]) == team and int(at[1]) == index:
		return true                                  # 已经在那一格
	var vehicle := ""
	if not at.is_empty():
		var old_slot: Dictionary = (roster[int(at[0])] as Array)[int(at[1])]
		vehicle = str(old_slot.get("vehicle", ""))
		(roster[int(at[0])] as Array)[int(at[1])] = {"kind": "empty", "vehicle": "", "name": ""}
	(roster[team] as Array)[index] = {"kind": "player", "vehicle": vehicle, "name": player_name}
	return true


## 在 (team, index) 放一个人机。那里是玩家就不覆盖（返回 false）。
static func set_bot(roster: Array, team: int, index: int, vehicle_id: String, name := "人机") -> bool:
	if not _fits(roster, team, index):
		return false
	if str(((roster[team] as Array)[index] as Dictionary).get("kind", "")) == "player":
		return false
	(roster[team] as Array)[index] = {"kind": "bot", "vehicle": vehicle_id, "name": name}
	return true


## 清空一格（玩家那格不清，避免"一个玩家都没有"）。
static func clear_slot(roster: Array, team: int, index: int) -> bool:
	if not _fits(roster, team, index):
		return false
	if str(((roster[team] as Array)[index] as Dictionary).get("kind", "")) == "player":
		return false
	(roster[team] as Array)[index] = {"kind": "empty", "vehicle": "", "name": ""}
	return true


## 某一队有几台车（玩家 + 人机）。
static func team_count(roster: Array, team: int) -> int:
	if team < 0 or team >= roster.size():
		return 0
	var count := 0
	for slot in roster[team]:
		if str((slot as Dictionary).get("kind", "empty")) != "empty":
			count += 1
	return count


## 能不能开始：有玩家，且两队都至少 1 台（不然一开局就判赢/输）。
static func can_start(roster: Array) -> bool:
	if find_player(roster).is_empty():
		return false
	return team_count(roster, 0) > 0 and team_count(roster, 1) > 0


## 队伍 / 格子下标是否在这个名单里。
static func _fits(roster: Array, team: int, index: int) -> bool:
	if team < 0 or team >= roster.size():
		return false
	var slots: Array = roster[team]
	return index >= 0 and index < slots.size()
