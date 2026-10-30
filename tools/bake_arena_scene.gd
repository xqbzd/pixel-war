extends SceneTree

## 把"自动摆放"的对战场地烘焙成**可以在 Godot 编辑器里拖拽的场景**：
##     godot --headless --path . --script res://tools/bake_arena_scene.gd
##
## 生成 `scenes/battle_arena.tscn`，结构：
##   BattleArena（脚本，编辑器里会自动铺一张地面预览）
##     ├─ Cover   ← 石头/崖壁（每个都是 nature_kit 的 .glb 实例，直接用编辑器缩放/移动）
##     ├─ Decor   ← 树/灌木（不挡车，同样可拖）
##     └─ Spawns  ← Team0_0..Team0_4 / Team1_0..Team1_4（Marker3D，拖位置/朝向）
##
## 进游戏时：`Cover` / `Decor` 里的东西会被**按网格合批**成 MultiMesh（省 draw call），
## 每个掩体自动生成一个方块碰撞；源节点只是编辑器里的摆放工具，运行时隐藏。
## 删掉某个节点 = 游戏里也没了；想加就复制一个、拖到想要的位置。
##
## ⚠️ 重新跑这个脚本会**覆盖** `scenes/battle_arena.tscn`（手工改动会丢）。

const SPAWNS_PER_TEAM := 5


func _initialize() -> void:
	var arena := BattleArena.new()
	root.add_child(arena)
	arena.build({}, true)   # 强制走自动摆放（无视布局文件）
	var scene_root := BattleArena.new()
	scene_root.name = "BattleArena"

	var cover_root := Node3D.new()
	cover_root.name = "Cover"
	scene_root.add_child(cover_root)
	cover_root.owner = scene_root
	for i in arena.cover_placed.size():
		var entry: Array = arena.cover_placed[i]
		var node := _instance_piece(str(entry[0]), "cover_%03d" % i)
		if node == null:
			continue
		node.transform = entry[1]
		cover_root.add_child(node)
		node.owner = scene_root

	var decor_root := Node3D.new()
	decor_root.name = "Decor"
	scene_root.add_child(decor_root)
	decor_root.owner = scene_root
	for i in arena.decor_layout.size():
		var entry: Array = arena.decor_layout[i]
		var node := _instance_piece(str(entry[0]), "decor_%03d" % i)
		if node == null:
			continue
		node.transform = entry[1]
		decor_root.add_child(node)
		node.owner = scene_root

	var spawn_root := Node3D.new()
	spawn_root.name = "Spawns"
	scene_root.add_child(spawn_root)
	spawn_root.owner = scene_root
	for team in 2:
		for index in SPAWNS_PER_TEAM:
			var marker := Marker3D.new()
			marker.name = "Team%d_%d" % [team, index]
			var t := arena.spawn_transform(team, index, SPAWNS_PER_TEAM)
			t.origin.y += 1.0   # 抬一格，编辑器里好点选
			marker.transform = t
			spawn_root.add_child(marker)
			marker.owner = scene_root

	var packed := PackedScene.new()
	var err := packed.pack(scene_root)
	if err != OK:
		print("[烘焙] 打包失败：%d" % err)
		quit()
		return
	err = ResourceSaver.save(packed, "res://scenes/battle_arena.tscn")
	print("[烘焙] 掩体 %d 个 / 装饰 %d 个 / 出生点 %d 个 → res://scenes/battle_arena.tscn（%s）" % [
		cover_root.get_child_count(), decor_root.get_child_count(),
		spawn_root.get_child_count(), "成功" if err == OK else "失败 %d" % err,
	])
	scene_root.free()
	arena.free()
	quit()


## 实例化 nature_kit 里的一个 .glb（找不到就警告 + 返回 null）。
func _instance_piece(piece_name: String, node_name: String) -> Node3D:
	var path := "res://assets/arena/nature_kit/%s.glb" % piece_name
	if not ResourceLoader.exists(path):
		push_warning("[烘焙] 找不到模型：%s" % path)
		return null
	var packed: PackedScene = load(path)
	if packed == null:
		push_warning("[烘焙] 加载失败：%s" % path)
		return null
	var node: Node3D = packed.instantiate()
	node.name = node_name
	return node
