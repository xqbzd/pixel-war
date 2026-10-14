@tool
class_name VoxMesher
extends RefCounted

## 贪心网格化：体素体积 -> ArrayMesh（顶点色）。
##
## 同色相邻的面会合并成矩形，所以一个实心 16^3 cube 只花 30 个四边形就能表达
## “主体 + 一圈棱色”，而逐体素画会是 1536 个面。这一步是省资源的关键。

## 每个朝向：n = 外法线，u / v = 面内两轴，且满足 u x v = n（让朝向判定确定且可验证）。
##
## 注意环绕方向：Godot 的正面是**顺时针**（从外面看），也就是三角形几何法线指向观察者反方向。
## 所以这里 u x v = n 之后再反过来发顶点（见 _emit_quad 的注释），
## 否则背面剔除会让你看到“朝向你的面不见了、反而看到被挡住的里面”——
## 这种错误不会报任何异常，只有 tests/test_vox_core.gd 里的引擎约定断言能守住。
const FACES: Array[Dictionary] = [
	{"n": Vector3i(1, 0, 0), "u": Vector3i(0, 1, 0), "v": Vector3i(0, 0, 1)},
	{"n": Vector3i(-1, 0, 0), "u": Vector3i(0, 0, 1), "v": Vector3i(0, 1, 0)},
	{"n": Vector3i(0, 1, 0), "u": Vector3i(0, 0, 1), "v": Vector3i(1, 0, 0)},
	{"n": Vector3i(0, -1, 0), "u": Vector3i(1, 0, 0), "v": Vector3i(0, 0, 1)},
	{"n": Vector3i(0, 0, 1), "u": Vector3i(1, 0, 0), "v": Vector3i(0, 1, 0)},
	{"n": Vector3i(0, 0, -1), "u": Vector3i(0, 1, 0), "v": Vector3i(1, 0, 0)},
]


## 返回 {mesh: ArrayMesh, quads: int}
static func build(volume: VoxVolume, voxel_size: float, origin := Vector3.ZERO) -> Dictionary:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := 0
	for face in FACES:
		quads += _emit_face(volume, st, face, voxel_size, origin)
	return {"mesh": st.commit(), "quads": quads}


static func axis_of(dir: Vector3i) -> int:
	if dir.x != 0:
		return 0
	if dir.y != 0:
		return 1
	return 2


static func _emit_face(
	volume: VoxVolume, st: SurfaceTool, face: Dictionary, voxel_size: float, origin: Vector3
) -> int:
	var n: Vector3i = face["n"]
	var u: Vector3i = face["u"]
	var v: Vector3i = face["v"]
	var d_axis := axis_of(n)
	var u_axis := axis_of(u)
	var v_axis := axis_of(v)
	var du: int = volume.size[u_axis]
	var dv: int = volume.size[v_axis]
	var dd: int = volume.size[d_axis]
	var positive: bool = n[d_axis] > 0
	var step := 1 if positive else -1

	var mask := PackedInt32Array()
	mask.resize(du * dv)
	var quads := 0

	for d in range(dd):
		var any := false
		mask.fill(0)
		for j in range(dv):
			for i in range(du):
				var value := _sample(volume, d_axis, d, u_axis, i, v_axis, j)
				if value == VoxVolume.EMPTY:
					continue
				if _sample(volume, d_axis, d + step, u_axis, i, v_axis, j) != VoxVolume.EMPTY:
					continue
				mask[j * du + i] = value
				any = true
		if any:
			quads += _emit_slab(
				volume, st, mask, du, dv, d, face, voxel_size, origin
			)
	return quads


static func _emit_slab(
	volume: VoxVolume,
	st: SurfaceTool,
	mask: PackedInt32Array,
	du: int,
	dv: int,
	d: int,
	face: Dictionary,
	voxel_size: float,
	origin: Vector3
) -> int:
	var used := PackedByteArray()
	used.resize(du * dv)
	var quads := 0
	for j in range(dv):
		for i in range(du):
			var value := mask[j * du + i]
			if value == VoxVolume.EMPTY or used[j * du + i] == 1:
				continue
			var w := 1
			while i + w < du and mask[j * du + i + w] == value and used[j * du + i + w] == 0:
				w += 1
			var h := 1
			while j + h < dv:
				var fits := true
				for k in range(w):
					var mi := (j + h) * du + i + k
					if mask[mi] != value or used[mi] == 1:
						fits = false
						break
				if not fits:
					break
				h += 1
			for jj in range(j, j + h):
				for ii in range(i, i + w):
					used[jj * du + ii] = 1
			_emit_quad(
				st, d, i, j, w, h, face, volume.linear_color_of(value), voxel_size, origin
			)
			quads += 1
	return quads


static func _emit_quad(
	st: SurfaceTool,
	d: int,
	i: int,
	j: int,
	w: int,
	h: int,
	face: Dictionary,
	colour: Color,
	voxel_size: float,
	origin: Vector3
) -> void:
	var n: Vector3i = face["n"]
	var u: Vector3i = face["u"]
	var v: Vector3i = face["v"]
	var d_axis := axis_of(n)
	var u_axis := axis_of(u)
	var v_axis := axis_of(v)
	# 正法线的面在体素栅格的上侧，负法线在下侧
	var plane := d + (1 if n[d_axis] > 0 else 0)

	var base := Vector3i.ZERO
	base[d_axis] = plane
	base[u_axis] = i
	base[v_axis] = j

	var p0 := origin + Vector3(base) * voxel_size
	var p1 := p0 + Vector3(u) * (voxel_size * float(w))
	var p2 := p1 + Vector3(v) * (voxel_size * float(h))
	var p3 := p0 + Vector3(v) * (voxel_size * float(h))
	var normal := Vector3(n)

	# 反序成三角形（p0,p2,p1 / p0,p3,p2）：u x v = n 是逆时针，而 Godot 正面是顺时针。
	_add_vertex(st, p0, normal, colour)
	_add_vertex(st, p2, normal, colour)
	_add_vertex(st, p1, normal, colour)
	_add_vertex(st, p0, normal, colour)
	_add_vertex(st, p3, normal, colour)
	_add_vertex(st, p2, normal, colour)


static func _add_vertex(st: SurfaceTool, pos: Vector3, normal: Vector3, colour: Color) -> void:
	st.set_normal(normal)
	st.set_color(colour)
	st.add_vertex(pos)


## 按 (d_axis, u_axis, v_axis) 三轴坐标取值，越界即 EMPTY。
static func _sample(
	volume: VoxVolume, d_axis: int, d: int, u_axis: int, i: int, v_axis: int, j: int
) -> int:
	var c := Vector3i.ZERO
	c[d_axis] = d
	c[u_axis] = i
	c[v_axis] = j
	return volume.get_voxel(c.x, c.y, c.z)
