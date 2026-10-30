extends SceneTree

## 把**自动摆放**的对战场地导出成 `data/arena/battle_layout.txt`（手动摆放的起点）。
##
## 用法（项目根目录）：
##     godot --headless --path . --script res://tools/export_arena_layout.gd
##
## 导出后会生成/覆盖 data/arena/battle_layout.txt：
##   * 10 个出生点（队伍 0 的**第一条 = 玩家自己**，后面 4 条是队友；队伍 1 是敌人）
##   * 当前自动撒的 120 个掩体（名字 / 位置 / 朝向 / 大小倍数）
## 之后进战局就**完全按这个文件摆**，想挪哪块就改哪一行；删掉文件就退回自动摆放。

const SPAWNS_PER_TEAM := 5


func _initialize() -> void:
	var arena := BattleArena.new()
	root.add_child(arena)
	arena.build({}, true)   # 强制走自动摆放（忽略已有布局文件）
	var spawns := []
	for team in 2:
		for index in SPAWNS_PER_TEAM:
			var t := arena.spawn_transform(team, index, SPAWNS_PER_TEAM)
			var m := t.origin * PartDef.CUBE_METERS
			spawns.append([team, m.x, m.z, rad_to_deg(t.basis.get_euler().y)])
	var ok := arena.write_layout_file(BattleArena.LAYOUT_PATH, spawns)
	print("[导出] 出生点 %d 条 / 掩体 %d 条 → %s（%s）" % [
		spawns.size(), arena.cover_layout.size(), BattleArena.LAYOUT_PATH,
		"成功" if ok else "失败",
	])
	quit()
