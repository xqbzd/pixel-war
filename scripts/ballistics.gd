@tool
class_name Ballistics
extends RefCounted

## 弹道：射弹的取朝向（随机散射）、按重力下坠的积分、射速换算。
## 全是纯函数（不碰场景），所以测试可以直接打（tests/test_weapon.gd）。
##
## 单位：内部一律用"格 / 格每秒"（世界标定 1 cube = CUBE_METERS 米，见 `PartDef.CUBE_METERS`）。
## 部件文件写的 m/s 在**读取处**换算一次（`PartDef.muzzle_speed_cubes()`），别在中间再乘。


## 初速度方向 + 锥形随机散射：以 `direction` 为轴、半角 `spread_deg` 的圆锥内**均匀**取一个方向。
## 均匀的取法：cosθ 在 [cos(spread), 1] 上均匀、方位角 φ 在 [0, 2π) 均匀 ——
## 直接"yaw/pitch 各取均匀"会把边缘堆得过密（看着像"中间没弹孔、边上挤一堆"）。
## spread_deg <= 0 时原样返回。
static func spread_direction(direction: Vector3, spread_deg: float, rng: RandomNumberGenerator) -> Vector3:
	var dir := direction.normalized()
	if spread_deg <= 0.0 or rng == null:
		return dir
	var spread := deg_to_rad(clampf(spread_deg, 0.0, 90.0))
	var cos_limit := cos(spread)
	var cos_theta := rng.randf_range(cos_limit, 1.0)
	var sin_theta := sqrt(maxf(0.0, 1.0 - cos_theta * cos_theta))
	var phi := rng.randf_range(0.0, TAU)
	# 以 dir 为极轴的局部坐标系（任取一根不平行的参考轴）
	var reference_axis := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var side := dir.cross(reference_axis).normalized()
	var up := side.cross(dir).normalized()
	return (dir * cos_theta + (side * cos(phi) + up * sin(phi)) * sin_theta).normalized()


## 一步弹道积分（半隐式欧拉：先更新速度再更新位置 —— 用"先位置后速度"会持续偏高）。
## 返回 {position, velocity}。gravity 传世界重力（`PartDef.GRAVITY_CUBES` 格/秒²）。
static func advance(
	position: Vector3, velocity: Vector3, gravity: float, delta: float
) -> Dictionary:
	var next_velocity := velocity + Vector3.DOWN * gravity * delta
	return {
		"position": position + next_velocity * delta,
		"velocity": next_velocity,
	}
