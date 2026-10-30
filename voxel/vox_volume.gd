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

## 实心范围的缓存（见 `solid_bounds_*`）。`data` 只有两种人改：`set_voxel()` 和
## 少数直接写 `data[i]` 的地方（如 `VoxShapes.apply()`，改完要 `invalidate_bounds()`）。
var _bounds_dirty := true
var _solid_lo := Vector3i.ZERO    # 含
var _solid_hi := Vector3i.ZERO    # 不含（空体积时 lo == hi）


func _init(p_size := Vector3i(VOXELS_PER_CUBE, VOXELS_PER_CUBE, VOXELS_PER_CUBE)) -> void:
	resize(p_size)


static func for_cubes(cubes: Vector3i) -> VoxVolume:
	return VoxVolume.new(cubes * VOXELS_PER_CUBE)


func resize(p_size: Vector3i) -> void:
	size = p_size
	data = PackedByteArray()
	data.resize(maxi(0, size.x * size.y * size.z))
	data.fill(EMPTY)
	_bounds_dirty = true


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
	if not inside(x, y, z):
		return
	var at := index(x, y, z)
	if data[at] == value:
		return
	data[at] = value
	_bounds_dirty = true


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
##
## ⚠️ 走的是实心范围缓存（一次扫描，之后 O(1)）。原来是"从外往里一层层找、
## 每层扫一整片"：武器体积 48³，枪管挂在中间，外侧 16 层全是空的 —— 单次最坏要扫
## 3.7 万个体素，而转塔进场每把枪要问十几次，**一把枪就 0.6 秒**（枪一多就是十几秒）。
func outermost_layer(axis: int, positive: bool) -> int:
	if not has_solid():
		return -1
	return _solid_hi[axis] - 1 if positive else _solid_lo[axis]


## 实心范围（单位 = 体素）：`lo` 含、`hi` 不含；空体积 `lo == hi`。
## 提供它是为了让"求包围盒"和"网格化"都**只扫实心那一小块**，别每次把整块体积
## （武器 48³ = 11 万个体素）从头扫一遍 —— 那是进场卡顿的主因，见 `outermost_layer()`。
func has_solid() -> bool:
	_ensure_bounds()
	return _solid_hi.x > _solid_lo.x


func solid_lo() -> Vector3i:
	_ensure_bounds()
	return _solid_lo


func solid_hi() -> Vector3i:
	_ensure_bounds()
	return _solid_hi


## 直接写了 `data[i]` 之后必须调它（`set_voxel()` 会自己标脏）。
func invalidate_bounds() -> void:
	_bounds_dirty = true


func _ensure_bounds() -> void:
	if not _bounds_dirty:
		return
	_bounds_dirty = false
	var nx := size.x
	var ny := size.y
	if nx <= 0 or ny <= 0 or size.z <= 0:
		_solid_lo = Vector3i.ZERO
		_solid_hi = Vector3i.ZERO
		return
	var stride_z := nx * ny
	var lo := Vector3i(nx, ny, size.z)
	var hi := Vector3i(-1, -1, -1)
	for i in range(data.size()):
		if data[i] == EMPTY:
			continue
		var z := i / stride_z
		var rest := i - z * stride_z
		var y := rest / nx
		var x := rest - y * nx
		lo = lo.min(Vector3i(x, y, z))
		hi = hi.max(Vector3i(x, y, z))
	if hi.x < 0:
		_solid_lo = Vector3i.ZERO
		_solid_hi = Vector3i.ZERO
	else:
		_solid_lo = lo
		_solid_hi = hi + Vector3i.ONE


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
