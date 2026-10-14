@tool
class_name VoxVolume
extends RefCounted

## 体素体积 —— 1 cube = 16 x 16 x 16 体素。
##
## data 每体素 1 字节，存 palette 索引；索引 0 恒为“空”。
## 调色板刻意保持极小（空 / 主体 / 棱），因为同一个体积要同时服务两条渲染路线：
##   - 体素路线：直接贪心网格化，顶点色出图（适合斜切等非立方体部件）
##   - 贴图路线：把外表面投影成 16x16 的六面贴图（适合数量巨大的立方体部件）
## 两条路线读同一份数据，所以风格不可能跑偏。

const VOXELS_PER_CUBE := 16
const EMPTY := 0

var size := Vector3i(VOXELS_PER_CUBE, VOXELS_PER_CUBE, VOXELS_PER_CUBE)
var data := PackedByteArray()
var palette: Array[Color] = [Color(0, 0, 0, 0)]


func _init(p_size := Vector3i(VOXELS_PER_CUBE, VOXELS_PER_CUBE, VOXELS_PER_CUBE)) -> void:
	resize(p_size)


static func for_cubes(cubes: Vector3i) -> VoxVolume:
	return VoxVolume.new(cubes * VOXELS_PER_CUBE)


func resize(p_size: Vector3i) -> void:
	size = p_size
	data = PackedByteArray()
	data.resize(maxi(0, size.x * size.y * size.z))
	data.fill(EMPTY)


func index(x: int, y: int, z: int) -> int:
	return x + size.x * (y + size.y * z)


func inside(x: int, y: int, z: int) -> bool:
	return x >= 0 and y >= 0 and z >= 0 and x < size.x and y < size.y and z < size.z


## 越界一律返回 EMPTY，这样网格化和投影都不需要额外的边界分支。
func get_voxel(x: int, y: int, z: int) -> int:
	if not inside(x, y, z):
		return EMPTY
	return data[index(x, y, z)]


func set_voxel(x: int, y: int, z: int, value: int) -> void:
	if inside(x, y, z):
		data[index(x, y, z)] = value


func is_solid(x: int, y: int, z: int) -> bool:
	return get_voxel(x, y, z) != EMPTY


func solid_count() -> int:
	var n := 0
	for value in data:
		if value != EMPTY:
			n += 1
	return n


## 沿某个轴向，最外侧（有实心体素的）那一层的层号；全空返回 -1。
## 用途：判断某个面是不是"这个形状在该方向的外表面"。
## 多数形状铺满整格（返回 0 或 size-1），但内缩的形状（比如外部工具画的轮子）
## 它的外表面在中间某一层 —— 用"是否贴格子边"去判断会误杀。
func outermost_layer(axis: int, positive: bool) -> int:
	var n := size[axis]
	for step in range(n):
		var index := (n - 1 - step) if positive else step
		if _layer_has_solid(axis, index):
			return index
	return -1


func _layer_has_solid(axis: int, index: int) -> bool:
	var a_axis := (axis + 1) % 3
	var b_axis := (axis + 2) % 3
	for a in range(size[a_axis]):
		for b in range(size[b_axis]):
			var c := Vector3i.ZERO
			c[axis] = index
			c[a_axis] = a
			c[b_axis] = b
			if is_solid(c.x, c.y, c.z):
				return true
	return false


func cell_origin(cell: Vector3i) -> Vector3i:
	return cell * VOXELS_PER_CUBE


## 该 cube 单元里是否至少有一个实心体素。
func is_cell_occupied(cell: Vector3i) -> bool:
	var origin := cell_origin(cell)
	for z in range(VOXELS_PER_CUBE):
		for y in range(VOXELS_PER_CUBE):
			for x in range(VOXELS_PER_CUBE):
				if is_solid(origin.x + x, origin.y + y, origin.z + z):
					return true
	return false


## 该单元是否被 16^3 完全填满 —— 贴图路线的硬前提。
func is_cell_full_cube(cell: Vector3i) -> bool:
	var origin := cell_origin(cell)
	for z in range(VOXELS_PER_CUBE):
		for y in range(VOXELS_PER_CUBE):
			for x in range(VOXELS_PER_CUBE):
				if not is_solid(origin.x + x, origin.y + y, origin.z + z):
					return false
	return true


func color_of(value: int) -> Color:
	if value >= 0 and value < palette.size():
		return palette[value]
	return palette[0]


## 顶点色专用的**线性**颜色。
##
## 为什么不能直接用 color_of()：同一个十六进制色，两条路线的入口不一样 ——
##   - 贴图路线：颜色存在 sRGB 纹理里，GPU 采样时会解码成线性；
##   - 体素路线：颜色写进网格 COLOR 数组，Godot 直接把它当**线性**值用。
## 所以顶点色必须自己换算一次，否则体素部件会比贴图部件亮一档（实测更白，肉眼可见）。
## 图集 PNG 导出仍用 color_of()（sRGB），这样外部工具看到的才是你写的那个色号。
func linear_color_of(value: int) -> Color:
	return color_of(value).srgb_to_linear()


func index_of_color(colour: Color) -> int:
	for i in range(palette.size()):
		if palette[i].is_equal_approx(colour):
			return i
	palette.append(colour)
	return palette.size() - 1
