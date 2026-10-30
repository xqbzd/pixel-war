@tool
extends McpTestSuite

## 世界音效的"距离衰减 + 左右声道"策略（scripts/spatial_audio.gd）。
##
## 实际的空间化交给 `AudioStreamPlayer3D`（引擎原生实现：`unit_size` / `max_distance` /
## `panning_strength`）。这里钉住的是**我们配的值**：配错了表现是"远处和近处一样响"、
## "左右不分"或者"声音从身后飘来"，在游戏里很难一眼看出来。

const SpatialAudio := preload("res://scripts/spatial_audio.gd")


func suite_name() -> String:
	return "audio"


## 满音量距离 20 米 = 40 格，听不见距离 350 米 = 700 格（世界单位是 cube）。
func test_spatial_constants() -> void:
	assert_almost_eq(
		SpatialAudio.FULL_DISTANCE_CUBES, 40.0, 0.001, "满音量距离（20 米 = 40 格）"
	)
	assert_almost_eq(
		SpatialAudio.MAX_DISTANCE_CUBES, 700.0, 0.001, "听不见距离（350 米 = 700 格）"
	)


## 配好的 3D 声部：距离衰减开着、左右声道拉满、多普勒关掉。
func test_configure_3d_player() -> void:
	var player := AudioStreamPlayer3D.new()
	SpatialAudio.configure(player)
	assert_almost_eq(player.unit_size, 40.0, 0.001, "unit_size = 满音量距离（格）")
	assert_almost_eq(player.max_distance, 700.0, 0.001, "max_distance = 静音距离（格）")
	assert_almost_eq(player.panning_strength, 1.0, 0.001, "左右声道拉满")
	assert_true(
		player.attenuation_model != AudioStreamPlayer3D.ATTENUATION_DISABLED,
		"距离衰减必须是开着的"
	)
	assert_eq(
		player.doppler_tracking, AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED,
		"车战里关掉多普勒（不然分不清谁在动）"
	)
	player.free()


## 引擎音量：怠速 → 高转单调变大。
func test_engine_volume_mapping() -> void:
	assert_almost_eq(SpatialAudio.engine_db(-24.0, -10.0, 0.0), -24.0, 0.001, "刚踩下 = 怠速")
	assert_almost_eq(SpatialAudio.engine_db(-24.0, -10.0, 1.0), -10.0, 0.001, "踩满 = 全速")
	assert_almost_eq(SpatialAudio.engine_db(-24.0, -10.0, 0.5), -17.0, 0.001, "中间 = 一半")
	assert_almost_eq(SpatialAudio.engine_db(-24.0, -10.0, 2.0), -10.0, 0.001, "超出范围夹住")


func assert_almost_eq(actual: float, expected: float, tol: float, msg: String = "") -> void:
	assert_true(absf(actual - expected) <= tol, "%s（实际 %.3f，期望 %.3f）" % [msg, actual, expected])
