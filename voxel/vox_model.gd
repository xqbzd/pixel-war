@tool
class_name VoxModel
extends RefCounted

## 外部工具建模的导入通道。
##
## 格式用 Goxel 的纯文本体素格式（每行 `x y z rrggbb`）：这个格式我对照过 Goxel 源码
## `src/formats/txt.c` 的解析器，而且**我们的导出器写的也是它** ——
## 所以"从游戏导出 → 在 Goxel / MagicaVoxel 里改 → 再导回来"用的是同一个格式。
##
## MagicaVoxel 也能用：在 Goxel 里打开 .vox 另存成 txt 即可（以后也可以补一个 .vox 读取器）。

## 一个面在该方向最外侧那一层至少露出这么多格，才算连接面（约 40%）
const MIN_CONNECTION_AREA := 100


## 读取体素文本。返回 {volume: VoxVolume, voxels: int, warnings: Array}
## 坐标按 Z-up → Y-up 换算，与 VoxExporter 的导出映射互为逆运算（有往返测试守着）。
static func load_text(path: String, size: Vector3i) -> Dictionary:
	var volume := VoxVolume.new(size)
	volume.palette = [Color(0, 0, 0, 0)]
	if not FileAccess.file_exists(path):
		return {"volume": null, "voxels": 0, "warnings": ["找不到 %s" % path]}
	var warnings := []
	var count := 0
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"volume": null, "voxels": 0, "warnings": ["打不开 %s" % path]}
	var line_no := 0
	while not file.eof_reached():
		line_no += 1
		var line := PartDef.strip_comment(file.get_line()).strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var tokens := line.split(" ", false)
		if tokens.size() < 4:
			if warnings.size() < 5:
				warnings.append("第 %d 行格式不对（应为 x y z rrggbb）：%s" % [line_no, line])
			continue
		var raw := Vector3i(int(tokens[0]), int(tokens[1]), int(tokens[2]))
		# Z-up（Goxel/MagicaVoxel）-> Y-up（Godot），与导出时相反
		var cell := Vector3i(raw.x, raw.z, size.z - 1 - raw.y)
		var hex := "#" + tokens[3]
		var colour := Color.html(hex) if Color.html_is_valid(hex) else Color.WHITE
		volume.set_voxel(cell.x, cell.y, cell.z, volume.index_of_color(colour))
		count += 1
	file.close()
	return {"volume": volume, "voxels": count, "warnings": warnings}


## 连接面自动推导：某方向最外侧那一层露出的格数 ≥ MIN_CONNECTION_AREA 就算连接面。
## 判据与 tests/test_build_grid.gd 里用的一致。
static func derive_connections(volume: VoxVolume) -> Array:
	var out := []
	for dir in VoxShapes.AXIS_DIRS:
		if exposed_on_outer_layer(volume, dir) >= MIN_CONNECTION_AREA:
			out.append(dir)
	return out


static func exposed_on_outer_layer(volume: VoxVolume, dir: Vector3i) -> int:
	var axis := VoxMesher.axis_of(dir)
	var outer := volume.outermost_layer(axis, dir[axis] > 0)
	if outer < 0:
		return 0
	var a_axis := (axis + 1) % 3
	var b_axis := (axis + 2) % 3
	var exposed := 0
	for a in range(volume.size[a_axis]):
		for b in range(volume.size[b_axis]):
			var c := Vector3i.ZERO
			c[axis] = outer
			c[a_axis] = a
			c[b_axis] = b
			if not volume.is_solid(c.x, c.y, c.z):
				continue
			var outward := c + dir
			if not volume.is_solid(outward.x, outward.y, outward.z):
				exposed += 1
	return exposed


## 写一份带说明的空白模板，方便直接开工。
## 这个模型需要占几个 cube（按包围盒向上取整，至少 1 个）。
## 用途：实验室按 G 生成部件文件时，把 cubes 写成实际需要的大小，
## 不然大模型会被 16³ 的默认部件体积截掉。
static func required_cubes(volume: VoxVolume) -> Vector3i:
	var max_voxel := Vector3i(-1, -1, -1)
	for z in range(volume.size.z):
		for y in range(volume.size.y):
			for x in range(volume.size.x):
				if volume.is_solid(x, y, z):
					max_voxel = max_voxel.max(Vector3i(x, y, z))
	if max_voxel.x < 0:
		return Vector3i.ONE
	var unit := VoxVolume.VOXELS_PER_CUBE
	return Vector3i(
		maxi(1, int(ceil(float(max_voxel.x + 1) / float(unit)))),
		maxi(1, int(ceil(float(max_voxel.y + 1) / float(unit)))),
		maxi(1, int(ceil(float(max_voxel.z + 1) / float(unit))))
	)


static func write_template(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_line("# 体素模型模板（Goxel 文本格式）：每行 X Y Z RRGGBB")
	file.store_line("# 坐标是 Z-up（与 Goxel / MagicaVoxel 一致），导入时自动换成游戏的 Y-up。")
	file.store_line("# 1 cube = 16x16x16 体素，坐标范围 0..15；颜色用 6 位十六进制。")
	file.store_line("# 用 Goxel 打开这个文件、画完再另存覆盖，游戏里会自动重载。")
	file.store_line("# 0 0 0 c9c9ce")
	file.close()
	return true
