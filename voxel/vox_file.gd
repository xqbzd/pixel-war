@tool
class_name VoxFile
extends RefCounted

## MagicaVoxel `.vox`（v150）读写。
##
## 为什么加它：Goxel 的体积框有 32×32 起步的限制，而 MagicaVoxel 的尺寸是显式可设的
## （64 / 128 / 256），工具也更顺手。`.vox` 是 MagicaVoxel 的原生格式，Goxel 也能读能写，
## 所以支持它就等于两家通吃。
##
## 文件结构（小端）：
##   "VOX " + int32(150)
##   然后是 chunk 序列：id(4 字节) + content_size(int32) + children_size(int32) + content + children
##   我们关心三个：
##     SIZE: 12 字节 —— sx, sy, sz
##     XYZI: 4 + 4*n —— n，然后每个体素 4 字节 (x, y, z, colorIndex)
##     RGBA: 1024 字节 —— 256 个 (r,g,b,a)，第 j 个对应颜色索引 j+1
##
## 坐标约定：.vox 是 **Z-up**，导入时换成游戏的 Y-up（和 VoxModel 的 txt 路径同一套映射）。

const MAGIC := "VOX "
const VERSION := 150


## 读取：返回 {volume: VoxVolume, warnings: Array}（单模型部件用；多子模型文件只取第 1 个）。
static func load_vox(path: String, size: Vector3i) -> Dictionary:
	var result := load_vox_models(path)
	var warnings: Array = result["warnings"].duplicate()
	var models: Array = result["models"]
	if models.is_empty():
		return {"volume": null, "warnings": warnings}
	if models.size() > 1:
		warnings.append(
			"这个 .vox 里有 %d 个子模型，单模型部件只取了第 1 个；"
			% models.size()
			+ "要分开用请在部件实验室里用 [ / ] 选子模型，再按 G 分别生成部件"
		)
	var model: Dictionary = models[0]
	var model_size: Vector3i = model["size"]
	# 注意用"偏移 + 尺寸"（场景里的实际范围），而不是归一化后的包围盒尺寸
	var extent: Vector3i = (model["offset"] as Vector3i) + model_size
	if size.x < extent.x or size.y < extent.y or size.z < extent.z:
		warnings.append(
			"模型比部件体积大（模型 %s，部件 %s）—— 超出的部分被裁掉了，把 cubes 调大一点"
			% [str(extent), str(size)]
		)
	var volume := VoxVolume.new(size)
	# 直接替换调色板：result 里的调色板已经含 index 0 = 透明，
	# 再 append 会让所有颜色索引整体偏移，颜色全错。
	volume.palette.clear()
	for colour in result["palette"]:
		volume.palette.append(colour)
	while volume.palette.size() < 2:
		volume.palette.append(Color.WHITE)

	for entry in model["voxels"]:
		var pos: Vector3i = entry["pos"]
		volume.set_voxel(pos.x, pos.y, pos.z, entry["color"])
	return {
		"volume": volume,
		"warnings": warnings,
		"voxels": model["voxels"].size(),
		"model_size": model_size,
	}


## 读取 .vox 里的**全部子模型**（MagicaVoxel 一个场景可以有多个模型，比如轮轴 + 轮体）。
##
## 返回 {models: Array, palette: Array[Color], warnings: Array}
##   models[i] = {size: Vector3i, voxels: [{pos: Vector3i, color: int}], offset: Vector3i}
##   - size/voxels 已经把每个子模型**归一到自己的 0 基包围盒**（可以直接当部件用）
##   - offset 是该子模型在场景里的相对位置（供实验室按原样摆出来看装配关系）
##   颜色索引沿用文件里的编号（1..255，0 = 空），palette[0] 是透明。
static func load_vox_models(path: String) -> Dictionary:
	var warnings := []
	var empty := {"models": [], "palette": [Color(0, 0, 0, 0)], "warnings": warnings}
	if not FileAccess.file_exists(path):
		warnings.append("找不到 %s" % path)
		return empty
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		warnings.append("打不开 %s" % path)
		return empty
	if file.get_buffer(4).get_string_from_ascii() != MAGIC:
		file.close()
		warnings.append("不是 .vox 文件（magic 不对）")
		return empty
	file.get_32()  # version

	var scene_size := Vector3i.ZERO
	var raw_models := []
	var palette := [Color(0, 0, 0, 0)]
	var has_palette_chunk := false
	while file.get_position() < file.get_length():
		var chunk_id := file.get_buffer(4).get_string_from_ascii()
		var content_size := file.get_32()
		var children_size := file.get_32()
		if chunk_id == "MAIN":
			continue  # MAIN 只是容器，继续读它的子 chunk
		var start := file.get_position()
		if chunk_id == "SIZE" and content_size >= 12:
			scene_size = Vector3i(file.get_32(), file.get_32(), file.get_32())
		elif chunk_id == "XYZI" and content_size >= 4:
			var count := file.get_32()
			var voxels := []
			for _i in range(count):
				voxels.append([
					file.get_8(), file.get_8(), file.get_8(), file.get_8()
				])
			raw_models.append(voxels)
		elif chunk_id == "RGBA" and content_size >= 1024:
			for _i in range(256):
				palette.append(Color8(file.get_8(), file.get_8(), file.get_8(), file.get_8()))
			has_palette_chunk = true
		file.seek(start + content_size + children_size)
	file.close()
	if not has_palette_chunk:
		warnings.append("文件里没有 RGBA 调色板块（可能用了 MagicaVoxel 默认调色板）—— 颜色会不对")
	while palette.size() < 2:
		palette.append(Color.WHITE)

	if scene_size == Vector3i.ZERO:
		warnings.append("文件里没有 SIZE 块，按体素范围自行推算")
	var models := []
	for voxels in raw_models:
		models.append(_normalize_model(voxels, scene_size, palette))
	return {"models": models, "palette": palette, "warnings": warnings, "scene_size": scene_size}


## 把一个子模型的体素归一到自己的 0 基包围盒；Z-up -> Y-up 用**同一个场景尺寸**做镜像，
## 这样多个子模型之间的相对关系不会被各自镜像搞乱。
static func _normalize_model(voxels: Array, scene_size: Vector3i, palette: Array) -> Dictionary:
	var unit := scene_size
	if unit == Vector3i.ZERO:
		unit = Vector3i(256, 256, 256)
	var cells := []
	var min_cell := Vector3i(1 << 20, 1 << 20, 1 << 20)
	var max_cell := -min_cell
	for entry in voxels:
		var raw := Vector3i(entry[0], entry[1], entry[2])
		# Z-up（.vox）-> Y-up（Godot）：x 不变、上方向换成 y、深度镜像到正区间
		var cell := Vector3i(raw.x, raw.z, unit.y - 1 - raw.y)
		cells.append({"cell": cell, "color": int(entry[3])})
		min_cell = min_cell.min(cell)
		max_cell = max_cell.max(cell)
	if cells.is_empty():
		return {"size": Vector3i.ONE, "voxels": [], "offset": Vector3i.ZERO}
	var out := []
	for item in cells:
		var cell: Vector3i = item["cell"]
		var value: int = item["color"]
		if value <= 0 or value >= palette.size() + 0:
			value = mini(maxi(value, 1), 255)
		out.append({"pos": cell - min_cell, "color": value})
	return {
		"size": max_cell - min_cell + Vector3i.ONE,
		"voxels": out,
		"offset": min_cell,
	}


## 写出：把体积存成 .vox（palette 索引直接当 .vox 的颜色索引用，0 表示空）。
static func save_vox(path: String, volume: VoxVolume) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(MAGIC.to_ascii_buffer())
	file.store_32(VERSION)

	# 先把体素收集起来（XYZI 的 content 长度要写在前头）
	var solid := PackedByteArray()
	var count := 0
	for z in range(volume.size.z):
		for y in range(volume.size.y):
			for x in range(volume.size.x):
				var value := volume.get_voxel(x, y, z)
				if value == VoxVolume.EMPTY:
					continue
				# 游戏 Y-up -> .vox 的 Z-up
				solid.append(x)
				solid.append(volume.size.z - 1 - z)
				solid.append(y)
				solid.append(value)
				count += 1

	# MAIN 容器：content 0，children 大小 = 后面三个 chunk 的总字节数
	var size_chunk := 12 + 12  # id + size 字段(12) + content(12)
	var xyzi_chunk := 12 + 4 + count * 4
	var rgba_chunk := 12 + 1024
	file.store_buffer("MAIN".to_ascii_buffer())
	file.store_32(0)
	file.store_32(size_chunk + xyzi_chunk + rgba_chunk)

	file.store_buffer("SIZE".to_ascii_buffer())
	file.store_32(12)
	file.store_32(0)
	file.store_32(volume.size.x)
	file.store_32(volume.size.y)
	file.store_32(volume.size.z)

	file.store_buffer("XYZI".to_ascii_buffer())
	file.store_32(4 + count * 4)
	file.store_32(0)
	file.store_32(count)
	file.store_buffer(solid)

	file.store_buffer("RGBA".to_ascii_buffer())
	file.store_32(1024)
	file.store_32(0)
	var bytes := PackedByteArray()
	for i in range(256):
		var colour := Color(0, 0, 0, 0)
		if i + 1 < volume.palette.size():
			colour = volume.palette[i + 1]
		bytes.append(int(round(colour.r * 255.0)))
		bytes.append(int(round(colour.g * 255.0)))
		bytes.append(int(round(colour.b * 255.0)))
		bytes.append(255 if colour.a >= 0.99 else int(round(colour.a * 255.0)))
	file.store_buffer(bytes)
	file.close()
	return true
