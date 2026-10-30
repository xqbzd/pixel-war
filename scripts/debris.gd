@tool
class_name Debris
extends MultiMeshInstance3D

## 零件被摧毁时炸出的**体素碎片**：纯视效 —— 没有碰撞体、不参与物理、不会被子弹打到。
##
## 所有碎片装在**一个 MultiMesh** 里（每块一个实例 + 顶点色），所以几百块也只占 1 个 draw call。
## 运动是简单弹道（初速 + 重力 + 空气阻尼 + 自转），寿命末尾缩小消失。
## 颜色由调用方给（`PartDef.debris_colour()` = 零件体素的平均色，直接来自零件本身）。

const MAX_CHUNKS := 240
## 每块碎片活多久（秒）
const CHUNK_LIFE := 1.15
## 最后多少秒开始"缩小消失"
const SHRINK_TIME := 0.3
## 重力（格/秒²）= 世界重力，碎片和车用同一套标定
const GRAVITY := PartDef.GRAVITY_CUBES
## 空气阻尼（每秒保留比例）：让碎片慢慢停下来，而不是一直飞
const DAMPING := 0.55
## 一块碎片的基础尺寸（格）：0.5 格 = 一个 cube 的 1/2（再乘随机 0.6~1.4）
const CHUNK_SIZE := 0.5
## 每次摧毁一个零件炸出几块
const CHUNKS_PER_PART := 5

var _count := 0
var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _colours := PackedColorArray()
var _sizes := PackedFloat32Array()
var _ages := PackedFloat32Array()
var _spins := PackedFloat32Array()      # 自转角速度（弧度/秒）
var _spin_axes := PackedVector3Array()
var _mesh_ready := false
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ensure_mesh()
	_rng.randomize()
	set_process(false)


## 建/重置 MultiMesh（`burst()` 也会懒调用，所以测试不挂树也能用）。
func _ensure_mesh() -> void:
	if _mesh_ready:
		return
	_mesh_ready = true
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.9
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.mesh = cube
	multi.instance_count = MAX_CHUNKS
	multi.visible_instance_count = 0
	multimesh = multi
	# 碎片是"一堆会动的方块"：不参与物理插值，直接按帧写
	RenderingServer.multimesh_set_physics_interpolated(multi.get_rid(), false)
	material_override = material


## 在 `at` 处炸出一簇碎片，颜色取自 `colours`（零件的体素颜色表，每块随机挑一个）。
## `inherit_velocity` 是车体的速度（碎块跟着飞）。
func burst_colours(
	at: Vector3, colours: PackedColorArray, inherit_velocity := Vector3.ZERO,
	count := CHUNKS_PER_PART
) -> void:
	_ensure_mesh()
	if multimesh == null:
		return
	for _i in maxi(0, count):
		if _count >= MAX_CHUNKS:
			# 池子满了：直接复用最老的那块（数组第 0 块），不扩容
			_count = MAX_CHUNKS - 1
			_remove_at(0)
		var direction := _random_direction()
		var speed := _rng.randf_range(2.5, 6.5)
		_pos.append(at + direction * _rng.randf_range(0.0, 0.25))
		_vel.append(inherit_velocity * 0.6 + direction * speed + Vector3.UP * _rng.randf_range(1.0, 3.0))
		_colours.append(_pick_colour(colours))
		_sizes.append(CHUNK_SIZE * _rng.randf_range(0.6, 1.4))
		_ages.append(0.0)
		_spins.append(_rng.randf_range(-9.0, 9.0))
		_spin_axes.append(_random_direction())
		_count += 1
	# ⚠️ 这里**不整表刷新**：一帧可能炸好几簇，每簇都刷 240 个实例的话开销比逻辑本身还大。
	# 位置/颜色由下一帧的 `advance()` 统一写一次（延迟 1 帧，肉眼看不出来）。
	set_process(true)


## 单色版本（测试 / 简单调用）。
func burst(
	at: Vector3, colour: Color, inherit_velocity := Vector3.ZERO, count := CHUNKS_PER_PART
) -> void:
	var colours := PackedColorArray([colour])
	burst_colours(at, colours, inherit_velocity, count)


## 从零件的颜色表里随机挑一个，再加一点亮度抖动 —— 同一块零件炸出来的碎片也有深有浅。
func _pick_colour(colours: PackedColorArray) -> Color:
	var colour := Color.WHITE
	if not colours.is_empty():
		colour = colours[_rng.randi_range(0, colours.size() - 1)]
	var jitter := _rng.randf_range(0.85, 1.15)
	return Color(
		clampf(colour.r * jitter, 0.0, 1.0),
		clampf(colour.g * jitter, 0.0, 1.0),
		clampf(colour.b * jitter, 0.0, 1.0),
		1.0
	)


## 直接推进一帧（`_process` 调它；测试也可以直接调）。
func advance(delta: float) -> void:
	if _count <= 0:
		set_process(false)
		return
	var index := _count - 1
	while index >= 0:
		var age := _ages[index] + delta
		if age >= CHUNK_LIFE:
			_remove_at(index)
			index -= 1
			continue
		_ages[index] = age
		var velocity := _vel[index]
		velocity.y -= GRAVITY * delta
		velocity *= pow(DAMPING, delta)
		_vel[index] = velocity
		_pos[index] = _pos[index] + velocity * delta
		index -= 1
	_push_instances()
	if _count <= 0:
		set_process(false)


func alive_count() -> int:
	return _count


func _process(delta: float) -> void:
	advance(delta)


## 把当前状态写进 MultiMesh（位置/朝向/大小/颜色）。
func _push_instances() -> void:
	if multimesh == null:
		return
	for i in _count:
		var age := _ages[i]
		var scale := _sizes[i]
		if age > CHUNK_LIFE - SHRINK_TIME:
			# 末尾缩小消失（不玩透明度：MultiMesh 顶点色的 alpha 需要额外开透明材质）
			scale *= clampf((CHUNK_LIFE - age) / SHRINK_TIME, 0.0, 1.0)
		var basis := Basis(_spin_axes[i], _spins[i] * age).scaled(Vector3.ONE * scale)
		multimesh.set_instance_transform(i, Transform3D(basis, _pos[i]))
		multimesh.set_instance_color(i, _colours[i])
	multimesh.visible_instance_count = _count


func _remove_at(index: int) -> void:
	_pos.remove_at(index)
	_vel.remove_at(index)
	_colours.remove_at(index)
	_sizes.remove_at(index)
	_ages.remove_at(index)
	_spins.remove_at(index)
	_spin_axes.remove_at(index)
	_count -= 1


## 均匀球面方向（碎片四散）
func _random_direction() -> Vector3:
	var theta := _rng.randf_range(0.0, TAU)
	var z := _rng.randf_range(-1.0, 1.0)
	var r := sqrt(maxf(0.0, 1.0 - z * z))
	return Vector3(r * cos(theta), z, r * sin(theta))