@tool
class_name VoxShapes
extends RefCounted

## 形状库：解析式定义形状，而不是逐格手绘。
##
## 为什么必须解析式？因为“棱”的判定在体素里有个陷阱：
## 45 度斜面在体素里是台阶，局部邻域看它和 90 度拐角长得一模一样，
## 任何纯邻域规则都会把整个斜面误判成棱。所以形状在这里给出两件事：
##   occupancy —— 哪些体素是实心（斜面自然是台阶，保留像素味）
##   crease    —— 哪些体素落在真正的棱上（面与面相交处，厚度 edge_band）
## 结果：斜面保持主体色，只有真正的棱才用棱色，两种部件风格一致。
##
## 每个形状 = 一个 2D 截面（u, w）沿 e 轴挤出：
##   cube          截面 = 实心矩形
##   half_prism_xz 截面 = 直角三角形（斜切），沿 Y 挤出
##   half_prism_xy / half_prism_yz 同理，挤出轴不同

const SHAPE_CUBE := "cube"
const SHAPE_HALF_PRISM_XZ := "half_prism_xz"
const SHAPE_HALF_PRISM_XY := "half_prism_xy"
const SHAPE_HALF_PRISM_YZ := "half_prism_yz"
const SHAPE_CORNER_TETRA := "corner_tetra"  # 切掉一个角得到的 1/6 四面体
const SHAPE_CORNER_CUT := "corner_cut"  # 反过来：从立方体上切掉那个角（5/6）

## 六个轴向（顺序固定，便于测试与序列化）
const AXIS_DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]


static func known_shapes() -> PackedStringArray:
	return PackedStringArray([
		SHAPE_CUBE,
		SHAPE_HALF_PRISM_XZ,
		SHAPE_HALF_PRISM_XY,
		SHAPE_HALF_PRISM_YZ,
		SHAPE_CORNER_TETRA,
		SHAPE_CORNER_CUT,
	])


## 连接点所在的面（体积轴空间）。
##
## 判据是“平面且够大”：立方体 6 个面全都算；三棱柱是两条直角边所在的两个正方形面
## （-u、-w）加上两个三角端面（±e），共 4 个；斜切出来的台阶不算 ——
## 那是由多段轴向面拼成的斜面，跟别的部件贴合不了。
static func connection_dirs(shape: String) -> Array:
	if shape == SHAPE_CORNER_TETRA:
		# 三个贴在角上的半格正方形面算连接面；斜切面不算
		return [Vector3i(-1, 0, 0), Vector3i(0, -1, 0), Vector3i(0, 0, -1)]
	if shape == SHAPE_CORNER_CUT:
		# 切掉一个角后，六个面都还够大，全部保留成连接面
		var six := []
		six.assign(AXIS_DIRS)
		return six
	var layout := default_layout(shape)
	if not layout["half"]:
		var all_dirs := []
		all_dirs.assign(AXIS_DIRS)
		return all_dirs
	var axes: Vector2i = layout["section_axes"]
	var e_axis: int = layout["extrude_axis"]
	return [
		_axis_dir(axes.x, -1),
		_axis_dir(axes.y, -1),
		_axis_dir(e_axis, 1),
		_axis_dir(e_axis, -1),
	]


static func _axis_dir(axis: int, sign: int) -> Vector3i:
	var dir := Vector3i.ZERO
	dir[axis] = sign
	return dir


## 返回 {section_axes: Vector2i, extrude_axis: int, half: bool}
static func default_layout(shape: String) -> Dictionary:
	match shape:
		SHAPE_HALF_PRISM_XY:
			return {"section_axes": Vector2i(0, 1), "extrude_axis": 2, "half": true}
		SHAPE_HALF_PRISM_YZ:
			return {"section_axes": Vector2i(1, 2), "extrude_axis": 0, "half": true}
		SHAPE_HALF_PRISM_XZ:
			return {"section_axes": Vector2i(0, 2), "extrude_axis": 1, "half": true}
		_:
			return {"section_axes": Vector2i(0, 2), "extrude_axis": 1, "half": false}


static func build(shape: String, size: Vector3i, band: int) -> Dictionary:
	if shape == SHAPE_CORNER_TETRA or shape == SHAPE_CORNER_CUT:
		return _build_corner(shape, size, band)
	var layout := default_layout(shape)
	var axes: Vector2i = layout["section_axes"]
	var e_axis: int = layout["extrude_axis"]
	var is_half: bool = layout["half"]
	var du: int = size[axes.x]
	var dw: int = size[axes.y]
	var de: int = size[e_axis]
	var b: int = maxi(1, band)

	var occ := PackedByteArray()
	occ.resize(size.x * size.y * size.z)
	var crease := PackedByteArray()
	crease.resize(occ.size())

	if is_half and du != dw:
		push_warning(
			"VoxShapes: half_prism 的截面必须是正方形，收到 %d x %d；按较小边处理（形状会缺角）。"
			% [du, dw]
		)
	var n := mini(du, dw)

	for u in range(du):
		for w in range(dw):
			var solid := true
			if is_half:
				solid = (u + w) <= (n - 1)
			if not solid:
				continue

			var long_crease := false
			var on_outline := false
			if is_half:
				# 截面的三个顶点 → 三条平行长棱
				long_crease = (
					(u < b and w < b)
					or (u >= n - b and w < b)
					or (u < b and w >= n - b)
				)
				# 截面轮廓：两条直角边 + 斜面的最外一层（斜面本身是“面”，只有贴边那层算轮廓）
				on_outline = u < b or w < b or (u + w) >= (n - b)
			else:
				long_crease = (u < b or u >= du - b) and (w < b or w >= dw - b)
				on_outline = u < b or u >= du - b or w < b or w >= dw - b

			for e in range(de):
				# 两端封口面上的轮廓也是真棱（端面与侧面相交）
				var cap_crease := on_outline and (e < b or e >= de - b)
				var ci := _coord_to_index(axes, e_axis, u, w, e, size)
				occ[ci] = 1
				crease[ci] = 1 if (cap_crease or long_crease) else 0

	return {"occupancy": occ, "crease": crease}


## 【已废弃，待删】这版轮子形状是 AI 拍脑袋定的，外形不对。
## 轮子改为"外部工具建模 + 文本导入"（见 voxel/vox_model.gd），
## 这个函数不再被形状库引用，等模型进来后连同 data/parts 的旧文件一起删掉。
static func _build_wheel(size: Vector3i, band: int) -> Dictionary:
	var occ := PackedByteArray()
	occ.resize(size.x * size.y * size.z)
	var crease := PackedByteArray()
	crease.resize(occ.size())
	var b: int = maxi(1, band)
	var centre := Vector2(float(size.x - 1) * 0.5, float(size.y - 1) * 0.5)
	var outer := minf(centre.x, centre.y) + 0.5  # 外半径（贴满格子）
	var hole := maxf(1.5, outer - 6.0)  # 轴孔半径
	var thickness: int = mini(8, size.z)
	for z in range(size.z - thickness, size.z):
		for y in range(size.y):
			for x in range(size.x):
				var d := Vector2(float(x) - centre.x, float(y) - centre.y).length()
				if d > outer or d <= hole:
					continue
				var index := x + size.x * (y + size.y * z)
				occ[index] = 1
				# 棱：胎面外缘 + 轴孔内缘（像素轮的视觉全靠这两圈）
				if d > outer - float(b) or d <= hole + float(b):
					crease[index] = 1
	return {"occupancy": occ, "crease": crease}


## 角块：四面体（1/6）与「切掉一个角」（5/6）。
##
## 两个形状共用同一套判据，但"角点"和切深不同：
##   corner_tetra：角点在原点 (0,0,0)，判据 x+y+z <= n-1；
##   corner_cut  ：被切掉的角在 (n-1,n-1,n-1)（**切在上方**，默认朝向就是完整底面朝下），
##                 而且比四面体**少切一层**（判据是 mirrored > n-2）。
## 台阶按整格计，所以体积都比理论值略大（和斜面同理）。
static func _build_corner(shape: String, size: Vector3i, band: int) -> Dictionary:
	var occ := PackedByteArray()
	occ.resize(size.x * size.y * size.z)
	var crease := PackedByteArray()
	crease.resize(occ.size())
	var b: int = maxi(1, band)
	var limit := corner_limit(size)
	var tetra := shape == SHAPE_CORNER_TETRA
	for z in range(size.z):
		for y in range(size.y):
			for x in range(size.x):
				# u/v/w 是相对"那个角"的坐标：四面体取原点角，切角块取对角
				var u := x if tetra else limit - x
				var v := y if tetra else limit - y
				var w := z if tetra else limit - z
				var total := u + v + w
				var solid := (total <= limit) if tetra else (total > limit - 1)
				if not solid:
					continue
				var index := x + size.x * (y + size.y * z)
				occ[index] = 1
				if _corner_is_crease(u, v, w, size, b, tetra):
					crease[index] = 1
	return {"occupancy": occ, "crease": crease}


## 切面经过角点相邻的三个顶点，即 x + y + z = n - 1
static func corner_limit(size: Vector3i) -> int:
	return mini(mini(size.x, size.y), size.z) - 1


## 角块的棱：从角点出发的三条坐标轴棱 + 切面与三个坐标平面相交的三条半对角线；
## 补块还要保留立方体自身剩下的棱。
static func _corner_is_crease(
	x: int, y: int, z: int, size: Vector3i, band: int, tetra: bool
) -> bool:
	var limit := corner_limit(size)
	if (y < band and z < band) or (x < band and z < band) or (x < band and y < band):
		return true
	if (
		(z < band and absi(x + y - limit) <= band)
		or (x < band and absi(y + z - limit) <= band)
		or (y < band and absi(x + z - limit) <= band)
	):
		return true
	if tetra:
		return false
	return (
		((x < band or x >= size.x - band) and (y < band or y >= size.y - band))
		or ((x < band or x >= size.x - band) and (z < band or z >= size.z - band))
		or ((y < band or y >= size.y - band) and (z < band or z >= size.z - band))
	)


## 把形状 + 配色写进体积。返回实心体素数。
static func apply(
	volume: VoxVolume,
	shape: String,
	band: int,
	body_index: int,
	edge_index: int
) -> int:
	var masks := build(shape, volume.size, band)
	var occ: PackedByteArray = masks["occupancy"]
	var crease: PackedByteArray = masks["crease"]
	var solid := 0
	for i in range(volume.data.size()):
		if occ[i] == 0:
			continue
		volume.data[i] = edge_index if crease[i] == 1 else body_index
		solid += 1
	return solid


static func _coord_to_index(
	axes: Vector2i, e_axis: int, u: int, w: int, e: int, size: Vector3i
) -> int:
	var c := Vector3i.ZERO
	c[axes.x] = u
	c[axes.y] = w
	c[e_axis] = e
	return c.x + size.x * (c.y + size.y * c.z)
