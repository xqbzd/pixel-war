@tool
class_name ComMarker
extends Node3D

## 重心标记（建造界面 + 测试场共用）：一个亮球 + 一条垂到地面的线 + 地面上的十字。
##
## ⚠️ 材质开 **`no_depth_test`**：重心在车体内部，正常渲染会被外壳挡住 ——
## 用户要求"不能被车体遮挡，要穿透车体显示"，所以这里关掉深度测试（画在所有东西之上）。
##
## 用法：
##     var marker := ComMarker.new()
##     add_child(marker)                  # 挂在**零件所在的同一坐标系**下
##     marker.place_local(com_local)      # 重心坐标（本地）
##     var height := marker.update_drop(space)   # 每帧：垂线落到地面，返回离地高度

const BALL_RADIUS := 0.14

var _ball: MeshInstance3D
var _line: MeshInstance3D
var _spot: MeshInstance3D


func _ready() -> void:
	if _ball == null:
		_build()


func _build() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.2, 1.0, 0.35, 0.95)
	# 穿透车体：不做深度测试（不然重心总被自己的外壳挡住）
	material.no_depth_test = true
	material.render_priority = 1
	var ball := MeshInstance3D.new()
	ball.name = "ComBall"
	var sphere := SphereMesh.new()
	sphere.radius = BALL_RADIUS
	sphere.height = BALL_RADIUS * 2.0
	sphere.radial_segments = 10
	sphere.rings = 5
	ball.mesh = sphere
	ball.material_override = material
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ball)
	var line := MeshInstance3D.new()
	line.name = "ComDrop"
	var bar := BoxMesh.new()
	bar.size = Vector3(0.05, 1.0, 0.05)      # 长轴 = 本地 y，长度靠缩放拉到地面
	line.mesh = bar
	line.material_override = material
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(line)
	var spot := MeshInstance3D.new()
	spot.name = "ComSpot"
	var cross := BoxMesh.new()
	cross.size = Vector3(0.7, 0.04, 0.08)
	spot.mesh = cross
	spot.material_override = material
	spot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(spot)
	var cross2 := MeshInstance3D.new()
	cross2.mesh = cross
	cross2.material_override = material
	cross2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cross2.rotation.y = PI * 0.5
	spot.add_child(cross2)
	_ball = ball
	_line = line
	_spot = spot


## 重心位置（本地坐标，单位 = cube）
func place_local(com_local: Vector3) -> void:
	if _ball == null:
		_build()
	_ball.position = com_local


## 每帧调：从重心竖直往下打，垂线和地面十字落在那儿；返回"离地高度"（格）。
## 打不到地面（腾空/探不到）时按 `fallback` 算。
func update_drop(space: PhysicsDirectSpaceState3D, fallback := 1.0) -> float:
	if _ball == null:
		_build()
	var com := _ball.position
	var drop := fallback
	if space != null:
		var from := global_transform * com
		var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 60.0, 1)
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			drop = from.distance_to(hit["position"])
	_line.scale = Vector3(1.0, maxf(0.01, drop), 1.0)
	_line.position = com + Vector3.DOWN * (drop * 0.5)
	_spot.position = com + Vector3.DOWN * drop
	return drop
