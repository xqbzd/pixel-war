extends SceneTree

## 模型体检：打印 data/parts 下所有 .vox / .vox.txt 的体素数、用到几种颜色、
## 需要占几个 cube、以及自动推导出的连接面。不需要编辑器：
##
##   godot --headless --path <项目目录> --script res://tools/inspect_models.gd
##
## 用途：导入模型后先跑这个确认"读进来了、颜色没丢、连接面是你要的那几个"，
## 省得在界面里一个个点着看。
## 顺带列出每个**部件**的基本数值（重量 / 血量 / pp / 是否核心）和重心 —— 调数值时看这里。

const PART_DIR := "res://data/parts"
const CANVAS_CUBES := Vector3i(8, 8, 8)


func _initialize() -> void:
	var paths := []
	paths.append_array(PartLibrary.find_files_recursive(PART_DIR, ".vox"))
	paths.append_array(PartLibrary.find_files_recursive(PART_DIR, ".vox.txt"))
	paths.sort()
	if paths.is_empty():
		print("data/parts 下没找到任何 .vox / .vox.txt 模型")
		quit()
		return
	var target := VoxVolume.VOXELS_PER_CUBE * CANVAS_CUBES
	for path in paths:
		print("=== %s ===" % path)
		# 多物体场景（一个 .vox 里放了底座/支架/枪管这种）：先把每个子模型的位置打出来 ——
		# 转塔的转轴/转点就是从这些位置推导的（见 PartDef.weapon_barrel_axis）。
		if path.to_lower().ends_with(".vox"):
			_inspect_scene_models(path)
		var result := (
			VoxFile.load_vox(path, target)
			if path.to_lower().ends_with(".vox")
			else VoxModel.load_text(path, target)
		)
		for warning in result.get("warnings", []):
			print("  [!] %s" % warning)
		var volume: VoxVolume = result.get("volume")
		if volume == null:
			print("  读不出来")
			continue
		var used := {}
		for value in volume.data:
			if value != VoxVolume.EMPTY:
				used[value] = true
		var cubes := VoxModel.required_cubes(volume)
		var dirs := VoxModel.derive_connections(volume)
		var names := PackedStringArray()
		for dir in dirs:
			names.append("%+d,%+d,%+d" % [dir.x, dir.y, dir.z])
		var default_dir := Vector3i.ZERO
		var best := -99
		for dir in dirs:
			if -dir.y > best:
				best = -dir.y
				default_dir = dir
		print("  体素 %d 格，用到 %d 种颜色（调色板 %d 项）" % [
			volume.solid_count(), used.size(), volume.palette.size()
		])
		print("  占用 cubes = %d %d %d" % [cubes.x, cubes.y, cubes.z])
		print("  自动推导连接面：%s" % str(names))
		print("  默认连接面：%+d,%+d,%+d" % [default_dir.x, default_dir.y, default_dir.z])
	print("")
	_inspect_parts()
	quit()


## 打印 .vox 场景里每个子模型的大小和在场景里的位置（多物体模型用：
## 轻机枪就是"底座 + 支架 + 枪管"三个物体画在同一个 48³ 空间里，位置直接决定转轴）。
func _inspect_scene_models(path: String) -> void:
	var models: Array = VoxFile.load_vox_models(path).get("models", [])
	if models.size() <= 1:
		return
	print("  场景里有 %d 个子模型（序号即 weapon_*_model 要写的值）：" % models.size())
	for i in models.size():
		var model: Dictionary = models[i]
		var offset: Vector3i = model.get("offset", Vector3i.ZERO)
		var size: Vector3i = model.get("size", Vector3i.ONE)
		# 游戏坐标：x 向前、y 向上、z 向右（VoxFile 已经把 .vox 的 Z-up 转过来了）
		print("    [%d] %d 体素  位置 %s  尺寸 %s  体素范围 %s..%s" % [
			i,
			(model.get("voxels", []) as Array).size(),
			str(offset),
			str(size),
			str(offset),
			str(offset + size - Vector3i.ONE),
		])


func _inspect_parts() -> void:
	var library := PartLibrary.new()
	library.load_all(PART_DIR)
	print("=== 部件数值（重量 / 血量 / pp / 重心，单位 cube；core 标记核心）===")
	for id in library.ids():
		var def: PartDef = library.get_def(id)
		var centre := def.center_of_mass()
		print("  %-16s %6.2f kg  %6d 血  %3d pp%s  重心 (%.3f, %.3f, %.3f)  %s" % [
			id,
			def.weight_kg,
			def.hp,
			def.pp,
			"  [核心]" if def.is_core else "        ",
			centre.x,
			centre.y,
			centre.z,
			"texture" if def.render_mode == PartDef.RenderMode.TEXTURE else "voxel",
		])
	if library.warnings.size() > 0:
		print("  警告：%s" % str(library.warnings))
	quit()
