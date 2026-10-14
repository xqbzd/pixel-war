extends RefCounted

## 全局游戏设置：存到 `user://settings.cfg`，主界面和建造模式的「游戏设置」共用同一份。
##
## 引用方式用 preload + 常量（不依赖 class_name 的全局类表，新脚本不用等编辑器扫一遍）：
##     const GameSettings := preload("res://scripts/game_settings.gd")
##     GameSettings.mouse_sensitivity()
##
## 带 path 参数是为了测试能用临时文件，别把玩家调好的设置覆盖掉。

const PATH := "user://settings.cfg"
const SECTION := "look"
const KEY_SENSITIVITY := "mouse_sensitivity"
const DEFAULT_SENSITIVITY := 0.14   # 度 / 像素
const MIN_SENSITIVITY := 0.02
const MAX_SENSITIVITY := 0.60
## 镜头是否**跟着车头转**（测试场里的环视相机）。**两种模式都能用鼠标自由环视**，
## 区别只在"鼠标转的是哪种角度"：
##   开 = 鼠标转的是**相对车头的偏移**（现在的行为：车一转向，画面跟着转）；
##   关 = 鼠标转的是**世界坐标系里的绝对朝向**（车原地打转时画面一动不动，但照样能环视）。
const KEY_CAMERA_FOLLOW := "camera_follow_vehicle"
const DEFAULT_CAMERA_FOLLOW := true

## ── 音量（0..1 线性；写进音频总线时换成 dB）──────────────────────────────
const SECTION_AUDIO := "audio"
const KEY_MASTER := "volume_master"
const KEY_MUSIC := "volume_music"
const KEY_SFX := "volume_sfx"
const DEFAULT_MASTER := 0.8
const DEFAULT_MUSIC := 0.45
const DEFAULT_SFX := 0.9
## 音频总线名：`apply_audio()` 会按需现造这两条（不额外维护 bus layout 资源）。
const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"

## ── 音频参数（`data/audio.txt`）──────────────────────────────────────────
## 一部分是"素材之间的相对强弱"（dB 偏移，0 = 原始响度），和玩家那三条音量滑条相乘；
## 一部分是引擎声的手感（按"油门按了多久"升调那几个）。放成数据文件是为了**用户能手调**：
## 改完进一次新场景就重读（按修改时间缓存）。
const AUDIO_TXT := "res://data/audio.txt"
const AUDIO_DEFAULTS := {
	"shot": -14.0, "engine_idle": -24.0, "engine_full": -10.0, "music": -8.0,
	"engine_ramp_seconds": 3.0, "engine_pitch_low": 0.90, "engine_pitch_high": 1.65,
}
## 上面哪些是"dB 强度"（测试要按 dB 的合理区间验，音高/时长那几条不参与）
const AUDIO_DB_KEYS := ["shot", "engine_idle", "engine_full", "music"]
## ── 全局手感辅助（`data/handling.txt`）──────────────────────────────────
## 下压力 + 自动回正力矩，都只在"车在地面附近"（按着地轮数判）时生效。
## 参数表和音频那张一样：`键 = 数值`，`#` 注释，改完进一次新场景重读。
const HANDLING_TXT := "res://data/handling.txt"
const HANDLING_DEFAULTS := {
	"downforce": 0.5,          # 下压力系数：力 = 系数 × **当前车重**（系数 = 多少倍车重）
	"upright_torque": 60000.0, # 车身倾到 90° 时的回正力矩（N·m），按 sin(倾角) 缩放
	"upright_damping": 0.6,    # 回正阻尼（相对临界阻尼，1.0 = 刚好不回摆）
	"yaw_center_seconds": 0.35, # 松手回正：偏航角速度衰减的时间常数（秒），0 = 关掉
	"ground_blend_seconds": 0.15, # 腾空↔落地的过渡时间（秒）：0 = 立刻切换
}
static var _audio_values := {}    # path -> {key: value}
static var _audio_mtime := {}     # path -> mtime（0 = 文件不存在）

static var _cache := {}  # path -> {key: value}


static func _values(path: String) -> Dictionary:
	if _cache.has(path):
		return _cache[path]
	var config := ConfigFile.new()
	config.load(path)  # 读不到就用默认值
	var values := {
		KEY_SENSITIVITY: clampf(
			float(config.get_value(SECTION, KEY_SENSITIVITY, DEFAULT_SENSITIVITY)),
			MIN_SENSITIVITY,
			MAX_SENSITIVITY
		),
		KEY_MASTER: clampf(float(config.get_value(SECTION_AUDIO, KEY_MASTER, DEFAULT_MASTER)), 0.0, 1.0),
		KEY_MUSIC: clampf(float(config.get_value(SECTION_AUDIO, KEY_MUSIC, DEFAULT_MUSIC)), 0.0, 1.0),
		KEY_SFX: clampf(float(config.get_value(SECTION_AUDIO, KEY_SFX, DEFAULT_SFX)), 0.0, 1.0),
		KEY_CAMERA_FOLLOW: bool(
			config.get_value(SECTION, KEY_CAMERA_FOLLOW, DEFAULT_CAMERA_FOLLOW)
		),
	}
	_cache[path] = values
	return values


static func _write(key: String, value: float, path: String) -> void:
	(_values(path) as Dictionary)[key] = value
	var config := ConfigFile.new()
	config.load(path)
	config.set_value(SECTION_AUDIO, key, value)
	config.save(path)


static func mouse_sensitivity(path := PATH) -> float:
	return float((_values(path) as Dictionary)[KEY_SENSITIVITY])


static func set_mouse_sensitivity(value: float, path := PATH) -> void:
	var clamped := clampf(value, MIN_SENSITIVITY, MAX_SENSITIVITY)
	(_values(path) as Dictionary)[KEY_SENSITIVITY] = clamped
	var config := ConfigFile.new()
	config.load(path)
	config.set_value(SECTION, KEY_SENSITIVITY, clamped)
	config.save(path)


## 镜头跟随车体转动（测试场）：默认开。读的是缓存，改完进一次新场景就生效。
static func camera_follow(path := PATH) -> bool:
	return bool((_values(path) as Dictionary)[KEY_CAMERA_FOLLOW])


static func set_camera_follow(value: bool, path := PATH) -> void:
	(_values(path) as Dictionary)[KEY_CAMERA_FOLLOW] = value
	var config := ConfigFile.new()
	config.load(path)
	config.set_value(SECTION, KEY_CAMERA_FOLLOW, value)
	config.save(path)


## 丢掉缓存（下次读会重新读文件）。测试用；将来"外部改了配置文件"也用得上。
static func forget(path := PATH) -> void:
	_cache.erase(path)


static func master_volume(path := PATH) -> float:
	return float((_values(path) as Dictionary)[KEY_MASTER])


static func music_volume(path := PATH) -> float:
	return float((_values(path) as Dictionary)[KEY_MUSIC])


static func sfx_volume(path := PATH) -> float:
	return float((_values(path) as Dictionary)[KEY_SFX])


static func set_master_volume(value: float, path := PATH) -> void:
	_write(KEY_MASTER, clampf(value, 0.0, 1.0), path)
	apply_audio(path)


static func set_music_volume(value: float, path := PATH) -> void:
	_write(KEY_MUSIC, clampf(value, 0.0, 1.0), path)
	apply_audio(path)


static func set_sfx_volume(value: float, path := PATH) -> void:
	_write(KEY_SFX, clampf(value, 0.0, 1.0), path)
	apply_audio(path)


## 把三个音量写进音频总线。总线不存在就现造一条（`AudioServer` 运行时加总线，
## 不用维护 `default_bus_layout.tres`）。0 直接静音（`linear_to_db(0)` 是 -inf 会报错）。
## `path` 跟着设置文件走：改临时文件的设置就按那份临时文件生效（测试要用）。
static func apply_audio(path := PATH) -> void:
	for bus_name in [BUS_MUSIC, BUS_SFX]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus_name)
	_set_bus(BUS_MUSIC, music_volume(path))
	_set_bus(BUS_SFX, sfx_volume(path))
	_set_bus("Master", master_volume(path))


static func _set_bus(bus_name: String, volume: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	AudioServer.set_bus_mute(index, volume <= 0.001)
	AudioServer.set_bus_volume_db(index, linear_to_db(clampf(volume, 0.001, 1.0)))


## ── 音频入口（全局音频是 autoload `GameAudio`，这里做一层空安全包装）──────────
## 为什么要绕一层：主界面 / 建造模式是 `@tool` 脚本，编辑器里 autoload 还没实例化，
## 直接在脚本里写全局标识符 `GameAudio` 会解析失败。用 `Engine.get_main_loop()`
## 查节点最省心：编辑器里查不到就当没有，运行时有就调。
static func audio() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("GameAudio")


static func play_music() -> void:
	var node := audio()
	if node != null:
		node.call("play_music")


static func stop_music() -> void:
	var node := audio()
	if node != null:
		node.call("stop_music")


static func play_shot() -> void:
	var node := audio()
	if node != null:
		node.call("play_shot")


## 素材强度（`data/audio.txt`）：拿不到 autoload 就返回 0（不报错）
static func strength(key: String) -> float:
	return audio_strength(key)


## 读一张"`键 = 数值`"的参数表（`data/audio.txt` / `data/handling.txt` 共用这一套解析）：
## `#` 注释（整行或行尾都行）、不认识的键、写歪的行一律忽略（保留默认值）；
## 按文件修改时间缓存，所以改完参数进一次新场景就生效。
static func floats_from_text(path: String, defaults: Dictionary) -> Dictionary:
	var mtime := 0
	if FileAccess.file_exists(path):
		mtime = FileAccess.get_modified_time(path)
	if mtime != 0 and int(_audio_mtime.get(path, -1)) == mtime and _audio_values.has(path):
		return _audio_values[path]
	var values := defaults.duplicate()
	_audio_mtime[path] = mtime
	if mtime == 0:
		_audio_values[path] = values
		return values
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		var line := raw
		var hash_index := line.find(" #")
		if hash_index >= 0:
			line = line.substr(0, hash_index)
		line = line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var key := line.substr(0, eq).strip_edges().to_lower()
		var value := line.substr(eq + 1).strip_edges()
		if not defaults.has(key) or not value.is_valid_float():
			continue
		values[key] = float(value)
	_audio_values[path] = values
	return values


## 读 `data/audio.txt`（素材强度 + 引擎声手感）
static func audio_strengths(path := AUDIO_TXT) -> Dictionary:
	return floats_from_text(path, AUDIO_DEFAULTS)


static func audio_strength(key: String, path := AUDIO_TXT) -> float:
	return float((audio_strengths(path) as Dictionary).get(key, AUDIO_DEFAULTS.get(key, 0.0)))


## 读 `data/handling.txt`（全局手感辅助：下压力 / 自动回正）与取单个键（测试见 test_settings.gd）
static func handling_values(path := HANDLING_TXT) -> Dictionary:
	return floats_from_text(path, HANDLING_DEFAULTS)


static func handling_value(key: String, path := HANDLING_TXT) -> float:
	return float((handling_values(path) as Dictionary).get(key, HANDLING_DEFAULTS.get(key, 0.0)))


## 丢掉缓存（测试用）
static func forget_audio(path := AUDIO_TXT) -> void:
	_audio_values.erase(path)
	_audio_mtime.erase(path)


static func engine_db_idle() -> float:
	return strength("engine_idle")


static func engine_db_full() -> float:
	return strength("engine_full")


## 引擎声"按油门时长升调"的三个参数（秒 / 音高倍率）
static func engine_ramp_seconds() -> float:
	return maxf(0.1, audio_strength("engine_ramp_seconds"))


static func engine_pitch_low() -> float:
	return audio_strength("engine_pitch_low")


static func engine_pitch_high() -> float:
	return audio_strength("engine_pitch_high")


## 引擎循环音流（测试场里的车每台一个 AudioStreamPlayer 用）
static func engine_stream() -> AudioStream:
	var node := audio()
	if node == null:
		return null
	return node.call("engine_stream")


## 造一段设置界面（视角灵敏度 + 三个音量滑条）。主界面和建造模式 ESC 菜单共用同一份代码。
static func build_ui(parent: Control) -> void:
	_add_slider(
		parent, "视角灵敏度", MIN_SENSITIVITY, MAX_SENSITIVITY, 0.01, mouse_sensitivity(),
		func(value: float) -> String: return "%.2f" % value,
		func(value: float) -> void: set_mouse_sensitivity(value)
	)
	var hint := Label.new()
	hint.text = "单位：度 / 像素（鼠标移动 1 像素转多少度）"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.72, 0.75, 0.80))
	parent.add_child(hint)
	_add_toggle(
		parent, "镜头跟随车体转动", camera_follow(),
		func(pressed: bool) -> void: set_camera_follow(pressed)
	)
	var cam_hint := Label.new()
	cam_hint.text = "两种模式都能用鼠标自由环视；区别 = 鼠标转的角度相对车头还是相对世界"
	cam_hint.add_theme_font_size_override("font_size", 13)
	cam_hint.add_theme_color_override("font_color", Color(0.72, 0.75, 0.80))
	parent.add_child(cam_hint)
	# 音量：总音量 / 音乐 / 音效（音乐只在大厅和建造模式放，音效是开火、引擎这些）
	_add_slider(
		parent, "总音量", 0.0, 1.0, 0.01, master_volume(),
		_percent, func(value: float) -> void: set_master_volume(value)
	)
	_add_slider(
		parent, "音乐音量", 0.0, 1.0, 0.01, music_volume(),
		_percent, func(value: float) -> void: set_music_volume(value)
	)
	_add_slider(
		parent, "音效音量", 0.0, 1.0, 0.01, sfx_volume(),
		_percent, func(value: float) -> void: set_sfx_volume(value)
	)
	var audio_hint := Label.new()
	audio_hint.text = "音效 = 引擎声 + 开火声；0% 就是静音"
	audio_hint.add_theme_font_size_override("font_size", 13)
	audio_hint.add_theme_color_override("font_color", Color(0.72, 0.75, 0.80))
	parent.add_child(audio_hint)


static func _percent(value: float) -> String:
	return "%d%%" % roundi(value * 100.0)


## 一行"开关"（CheckButton）：点一下立刻写设置（`apply` 收到新的开关状态）。
static func _add_toggle(parent: Control, title: String, value: bool, apply: Callable) -> CheckButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)
	var button := CheckButton.new()
	button.text = title
	button.button_pressed = value
	row.add_child(button)
	button.toggled.connect(func(pressed: bool) -> void: apply.call(pressed))
	return button


## 一行"标签 + 滑条 + 数值"，滑条一动就写设置（`apply` 里顺手做副作用，比如换总线音量）。
static func _add_slider(
	parent: Control, title: String, min_value: float, max_value: float, step: float,
	value: float, format: Callable, apply: Callable
) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size = Vector2(112.0, 0.0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(220.0, 0.0)
	row.add_child(slider)
	var value_label := Label.new()
	value_label.text = str(format.call(value))
	value_label.custom_minimum_size = Vector2(56.0, 0.0)
	row.add_child(value_label)
	slider.value_changed.connect(func(new_value: float) -> void:
		apply.call(new_value)
		value_label.text = str(format.call(new_value))
	)
	return slider
