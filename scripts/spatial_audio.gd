extends RefCounted

## 世界音效的**距离衰减 + 左右声道**策略（开火声 / 所有车的引擎声）。
##
## 做法：用 `AudioStreamPlayer3D` —— 它本来就带两件事：
##   * 按距离衰减（`unit_size` = 满音量距离、`max_distance` = 听不见的距离）；
##   * 按声源相对**听者相机**的方向做左右声道（`panning_strength`）。
## 听者就是当前 Camera3D（第三人称镜头），所以我们只要把节点摆在正确的位置上。
##
## 为什么不用手动算 pan：Godot 4 的 `AudioStreamPlayer` **没有 pan 属性**
## （`pan` 只存在于 AudioStreamPlayer2D/3D）。手动方案要用两个单声道声部拼左右，
## 声部翻倍还得自己接，不划算；3D 声部是引擎原生实现，还自带多普勒/衰减曲线。
##
## 世界单位是 cube（1 cube = 0.5 米），所以下面两个"米"的常量进引擎时要换算成格。
##
## 引用方式（和 GameSettings 一样用 preload）：`SpatialAudio.configure(player)`

## 满音量距离（米）：20 米内（40 格）听不出距离差 —— 自己车、贴着的队友都在里面
const FULL_DISTANCE_M := 20.0
## 超过这个距离就听不见了（米）：350 米（700 格）
const MAX_DISTANCE_M := 350.0
## 一格多少米（和 PartDef.CUBE_METERS 一致，这里写死是为了不让这个纯工具依赖部件系统）
const CUBE_METERS := 0.5

## 满音量距离（格）
const FULL_DISTANCE_CUBES := FULL_DISTANCE_M / CUBE_METERS
## 听不见的距离（格）
const MAX_DISTANCE_CUBES := MAX_DISTANCE_M / CUBE_METERS


## 把一台 3D 声部按"世界音效"的要求配好（距离衰减 + 左右声道，关掉多普勒）。
static func configure(player: AudioStreamPlayer3D) -> void:
	if player == null:
		return
	player.unit_size = FULL_DISTANCE_CUBES        # 40 格 = 20 米内满音量
	player.max_distance = MAX_DISTANCE_CUBES      # 700 格 = 350 米外静音
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	player.panning_strength = 1.0                 # 左右声道拉到满
	player.max_db = 3.0
	# 多普勒在车战里会让人误判"谁在动"，直接关掉
	player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED


## 引擎音量映射：`rev` 0 = 刚踩下（低转），1 = 踩满 ramp 秒（高转）。
## 只按转向 = 中间怠速（`rev` 不涨，仍然是 idle 音量）。
static func engine_db(idle_db: float, full_db: float, rev: float) -> float:
	return lerpf(idle_db, full_db, clampf(rev, 0.0, 1.0))
