extends McpTestSuite

## 对战名单（2 队 × 5 格）的规则：默认位置、添加人机、换位、开始条件。
## 这些是 `scripts/battle_roster.gd` 里的纯函数 —— 配置界面和开局生成都走它。

func suite_name() -> String:
	return "roster"


## 默认：玩家在左队第 1 格，其余 9 格全空；两队都只有 1 台才允许开始。
func test_default_roster() -> void:
	var roster := BattleRoster.default_roster("custom_1", "玩家")
	assert_eq(roster.size(), 2, "两队")
	assert_eq((roster[0] as Array).size(), BattleRoster.SLOTS, "每队 5 格")
	assert_eq((roster[1] as Array).size(), BattleRoster.SLOTS, "每队 5 格")
	assert_eq(str((roster[0] as Array)[0].get("kind", "")), "player", "玩家默认在左队第 1 格")
	assert_eq(str((roster[0] as Array)[0].get("vehicle", "")), "custom_1", "记住玩家的载具 id")
	var at := BattleRoster.find_player(roster)
	assert_eq(at, [0, 0], "find_player 返回 [队伍, 格子]")
	var empties := 0
	for team in 2:
		for slot in roster[team]:
			if str((slot as Dictionary).get("kind", "")) == "empty":
				empties += 1
	assert_eq(empties, 2 * BattleRoster.SLOTS - 1, "除玩家之外都是空位")
	# 只有一边有人 → 不能开始
	assert_true(not BattleRoster.can_start(roster), "敌方一个人都没有，不能开始")


## 添加人机：占用选中的格子；玩家那格不许覆盖。
func test_set_bot() -> void:
	var roster := BattleRoster.default_roster("custom_1")
	assert_true(BattleRoster.set_bot(roster, 1, 0, "bot_light", "人机"), "右队第 1 格放人机")
	assert_eq(str((roster[1] as Array)[0].get("kind", "")), "bot", "类型 = 人机")
	assert_eq(str((roster[1] as Array)[0].get("vehicle", "")), "bot_light", "记住载具 id")
	assert_true(BattleRoster.can_start(roster), "两边都有人 → 可以开始")
	# 玩家那格不能被覆盖
	assert_true(
		not BattleRoster.set_bot(roster, 0, 0, "bot_gunner"), "玩家格子放人机会被拒绝"
	)
	assert_eq(str((roster[0] as Array)[0].get("kind", "")), "player", "玩家还在")
	# 越界
	assert_true(not BattleRoster.set_bot(roster, 2, 0, "bot_light"), "队伍越界")
	assert_true(not BattleRoster.set_bot(roster, 0, 99, "bot_light"), "格子越界")
	assert_eq(BattleRoster.team_count(roster, 0), 1, "我方 1 台")
	assert_eq(BattleRoster.team_count(roster, 1), 1, "敌方 1 台")


## 换位到此：玩家挪到目标格，原来那格清空，载具 id 跟着走；目标格的人机被挤掉。
func test_move_player() -> void:
	var roster := BattleRoster.default_roster("custom_1")
	BattleRoster.set_bot(roster, 1, 3, "bot_gunner", "人机3")
	assert_true(BattleRoster.move_player(roster, 1, 3, "玩家"), "换到右队第 4 格")
	assert_eq(BattleRoster.find_player(roster), [1, 3], "玩家现在在 [1,3]")
	assert_eq(str((roster[0] as Array)[0].get("kind", "")), "empty", "左队第 1 格空了")
	assert_eq(
		str((roster[1] as Array)[3].get("vehicle", "")), "custom_1", "载具 id 跟玩家一起走"
	)
	assert_eq(BattleRoster.team_count(roster, 0), 0, "左队没人了")
	assert_eq(BattleRoster.team_count(roster, 1), 1, "右队 1 台")
	assert_true(not BattleRoster.can_start(roster), "左队没人 → 不能开始")
	# 换到已经空着的位置也一样
	assert_true(BattleRoster.move_player(roster, 0, 2, "玩家"), "再换到左队第 3 格")
	assert_eq(BattleRoster.find_player(roster), [0, 2], "玩家在 [0,2]")
	# 换到同一个格子：无事发生，返回 true
	assert_true(BattleRoster.move_player(roster, 0, 2, "玩家"), "原地换位也返回成功")
	assert_eq(BattleRoster.find_player(roster), [0, 2], "位置没变")


## 清空：人机能清、玩家不能清。
func test_clear_slot() -> void:
	var roster := BattleRoster.default_roster("custom_1")
	BattleRoster.set_bot(roster, 1, 1, "bot_light")
	assert_true(BattleRoster.clear_slot(roster, 1, 1), "人机那格可以清空")
	assert_eq(str((roster[1] as Array)[1].get("kind", "")), "empty", "清空后是空位")
	assert_true(not BattleRoster.clear_slot(roster, 0, 0), "玩家那格不能清空")
	assert_eq(BattleRoster.find_player(roster), [0, 0], "玩家还在")


## 名单的格子数必须和对战里的 `TEAM_SIZE` 一致（场地每队也是 5 个出生点 Marker）。
func test_team_size_matches() -> void:
	var battle := preload("res://scripts/battle_mode.gd")
	assert_eq(BattleRoster.SLOTS, battle.TEAM_SIZE, "名单格子数 == 对战队伍上限")
