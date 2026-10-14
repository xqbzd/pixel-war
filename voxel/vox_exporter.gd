@tool
class_name VoxExporter
extends RefCounted

## 闭环的出口：把体素体积导成外部建模工具能直接打开的形式。
##
## 这里采用 Goxel 的纯文本体素格式（每行 “X Y Z RRGGBB”），
## 已对照 Goxel 源码 src/formats/txt.c 的解析器写成，规则是：
##   - 字段之间用单个空格分隔
##   - 颜色是 6 位十六进制、不带 #
##   - 注释行必须以 “# ”（# 后跟空格）开头
## 于是导出的文件可以拖进 Goxel 继续手工精修，也可以当作 AI 再加工的输入；
## 需要 MagicaVoxel 时，从 Goxel 另存 .vox 即可（或后续补一个 .vox 写入器）。

## 坐标映射：Godot(Y up) -> Goxel/MagicaVoxel 的 Z-up 约定。
##   gx = x, gy = (size.z - 1 - z), gz = y
static func to_z_up(volume: VoxVolume, v: Vector3i) -> Vector3i:
	return Vector3i(v.x, volume.size.z - 1 - v.z, v.y)


## 返回写入的体素数；失败返回 -1。
@warning_ignore("integer_division")
static func write_goxel_text(volume: VoxVolume, path: String) -> int:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("VoxExporter: 无法写入 %s" % path)
		return -1
	file.store_line("# %s" % path.get_file())
	file.store_line("# 每行一个体素：X Y Z RRGGBB（Goxel 文本体素格式，Z-up）")
	file.store_line("# 体素尺寸 %d x %d x %d（gz, gy, gx）= (%d, %d, %d) cube" % [
		volume.size.z, volume.size.y, volume.size.x,
		volume.size.z / VoxVolume.VOXELS_PER_CUBE,
		volume.size.y / VoxVolume.VOXELS_PER_CUBE,
		volume.size.x / VoxVolume.VOXELS_PER_CUBE,
	])
	var count := 0
	for z in range(volume.size.z):
		for y in range(volume.size.y):
			for x in range(volume.size.x):
				var value := volume.get_voxel(x, y, z)
				if value == VoxVolume.EMPTY:
					continue
				var p := to_z_up(volume, Vector3i(x, y, z))
				var colour := volume.color_of(value)
				file.store_line("%d %d %d %02x%02x%02x" % [
					p.x,
					p.y,
					p.z,
					int(round(colour.r * 255.0)),
					int(round(colour.g * 255.0)),
					int(round(colour.b * 255.0)),
				])
				count += 1
	file.close()
	return count
