@tool
extends McpTestSuite

## 游戏设置（`user://settings.cfg`）：默认值、读写、限位。
## 用临时文件测，不去动玩家那份调好的设置。

const GameSettings := preload("res://scripts/game_settings.gd")
const TEMP_PATH := "user://tmp_settings.cfg"


func suite_name() -> String:
	return "settings"


func _clean() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_PATH))
	GameSettings.forget(TEMP_PATH)  # 顺手把内存缓存也丢掉，免得读到上一次测试的值


## 没有文件时用默认值；写进去能读回来，而且真的落盘。
func test_defaults_and_round_trip() -> void:
	_clean()
	assert_true(
		is_equal_approx(GameSettings.mouse_sensitivity(TEMP_PATH), GameSettings.DEFAULT_SENSITIVITY),
		"没有配置文件时用默认灵敏度"
	)
	GameSettings.set_mouse_sensitivity(0.33, TEMP_PATH)
	assert_true(is_equal_approx(GameSettings.mouse_sensitivity(TEMP_PATH), 0.33), "写进去要能读回来")
	var config := ConfigFile.new()
	assert_eq(config.load(TEMP_PATH), OK, "应该真的写出了配置文件")
	assert_true(
		is_equal_approx(
			float(config.get_value(GameSettings.SECTION, GameSettings.KEY_SENSITIVITY, 0.0)), 0.33
		),
		"文件里存的就是 0.33"
	)
	_clean()


## 三个音量（总 / 音乐 / 音效）：默认值、读写、限位都在 0..1。
## 注意：写设置会顺手把音量写进音频总线（`apply_audio()`），所以这里顺便确认总线存在。
func test_volume_settings() -> void:
	_clean()
	assert_true(
		is_equal_approx(GameSettings.master_volume(TEMP_PATH), GameSettings.DEFAULT_MASTER),
		"总音量默认值"
	)
	assert_true(
		is_equal_approx(GameSettings.music_volume(TEMP_PATH), GameSettings.DEFAULT_MUSIC),
		"音乐音量默认值"
	)
	assert_true(
		is_equal_approx(GameSettings.sfx_volume(TEMP_PATH), GameSettings.DEFAULT_SFX),
		"音效音量默认值"
	)
	GameSettings.set_master_volume(0.42, TEMP_PATH)
	assert_true(is_equal_approx(GameSettings.master_volume(TEMP_PATH), 0.42), "写进去要能读回来")
	GameSettings.set_music_volume(99.0, TEMP_PATH)
	assert_true(is_equal_approx(GameSettings.music_volume(TEMP_PATH), 1.0), "超过 1 夹到 1")
	GameSettings.set_sfx_volume(-3.0, TEMP_PATH)
	assert_true(is_equal_approx(GameSettings.sfx_volume(TEMP_PATH), 0.0), "小于 0 夹到 0")
	# 总线必须存在（apply_audio 会现造 Music / SFX 两条）
	assert_true(AudioServer.get_bus_index(GameSettings.BUS_MUSIC) >= 0, "Music 总线应该被建出来")
	assert_true(AudioServer.get_bus_index(GameSettings.BUS_SFX) >= 0, "SFX 总线应该被建出来")
	# 0 = 静音（不是 -inf dB）
	GameSettings.set_master_volume(0.0, TEMP_PATH)
	var master := AudioServer.get_bus_index("Master")
	assert_true(AudioServer.is_bus_mute(master), "0% 应该是静音")
	GameSettings.set_master_volume(GameSettings.DEFAULT_MASTER, TEMP_PATH)
	assert_false(AudioServer.is_bus_mute(master), "调回来就不静音了")
	_clean()


## 超出范围要夹住（别让手滑把灵敏度设成 0 或者 99）。
func test_clamped_to_range() -> void:
	_clean()
	GameSettings.set_mouse_sensitivity(99.0, TEMP_PATH)
	assert_true(
		is_equal_approx(GameSettings.mouse_sensitivity(TEMP_PATH), GameSettings.MAX_SENSITIVITY),
		"超过上限应夹到上限"
	)
	GameSettings.set_mouse_sensitivity(-5.0, TEMP_PATH)
	assert_true(
		is_equal_approx(GameSettings.mouse_sensitivity(TEMP_PATH), GameSettings.MIN_SENSITIVITY),
		"低于下限应夹到下限"
	)
	_clean()


## 素材强度表（`data/audio.txt`，用户手调）：四个键都在、值是合理 dB；
## 解析要能忽略注释 / 歪行 / 不认识的键，认识的行是哪个就用哪个。
func test_audio_strength_table() -> void:
	var values := GameSettings.audio_strengths()
	for key in GameSettings.AUDIO_DEFAULTS.keys():
		assert_true(values.has(key), "强度表里应该有 %s" % key)
	# 只有 dB 那几个按 [-80, 0] 验；音高/时长那几条不参与
	for key in GameSettings.AUDIO_DB_KEYS:
		var db := float(values[key])
		assert_true(
			db <= 0.0 and db >= -80.0, "%s 的 dB 要在 [-80, 0] 这个合理区间：%s" % [key, db]
		)
	# 引擎声"按油门时长升调"的三个参数：升调时间 > 0、音高是正数且 high > low
	assert_true(GameSettings.engine_ramp_seconds() > 0.0, "升调时间要 > 0")
	assert_true(
		GameSettings.engine_pitch_low() > 0.0
			and GameSettings.engine_pitch_high() > GameSettings.engine_pitch_low(),
		"音高应该是正数、而且 high > low：%s → %s"
		% [GameSettings.engine_pitch_low(), GameSettings.engine_pitch_high()]
	)
	# 解析规则：临时文件里塞注释、行尾注释、歪行、不认识的键、非数字
	var path := "user://tmp_audio.txt"
	# ⚠️ 临时文件名**不能以 test_ 开头**：`user://` 下的 `test_*` 会被测试发现机制扫到、
	# 当成脚本去加载（上次跑挂留下的残留文件就是这么把整套测试带崩的）。
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_line("# 整行注释")
	file.store_line("shot = -22   # 行尾注释")
	file.store_line("engine_full = 3")
	file.store_line("unknown_key = -5")
	file.store_line("music = abc")
	file.store_line("这不是 key = value 的行")
	file.close()
	GameSettings.forget_audio(path)
	assert_true(
		is_equal_approx(GameSettings.audio_strength("shot", path), -22.0),
		"认识的键要生效（行尾注释要剥掉）"
	)
	assert_true(
		is_equal_approx(GameSettings.audio_strength("engine_full", path), 3.0),
		"正值也照收（只是会变响，由人来判断）"
	)
	assert_true(
		is_equal_approx(
			GameSettings.audio_strength("music", path), float(GameSettings.AUDIO_DEFAULTS["music"])
		),
		"写歪了的键保留默认值"
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	GameSettings.forget_audio(path)


## 镜头跟随车体转动（测试场的环视相机）：默认开；关掉要能读回来、而且真的落盘。
func test_camera_follow_setting() -> void:
	_clean()
	assert_true(GameSettings.camera_follow(TEMP_PATH), "默认跟着车头转")
	GameSettings.set_camera_follow(false, TEMP_PATH)
	assert_false(GameSettings.camera_follow(TEMP_PATH), "关掉要能读回来")
	var config := ConfigFile.new()
	assert_eq(config.load(TEMP_PATH), OK, "应该真的写出了配置文件")
	assert_false(
		bool(config.get_value(GameSettings.SECTION, GameSettings.KEY_CAMERA_FOLLOW, true)),
		"文件里存的就是 false"
	)
	GameSettings.set_camera_follow(true, TEMP_PATH)
	assert_true(GameSettings.camera_follow(TEMP_PATH), "再打开就是 true")
	_clean()


## 全局手感辅助参数表（`data/handling.txt`，用户手调）：三个键都在、非负；
## 解析走的是和音频同一套"`键 = 数值`"，注释 / 歪行 / 不认识的键要能忽略。
func test_handling_table() -> void:
	var values := GameSettings.handling_values()
	for key in GameSettings.HANDLING_DEFAULTS.keys():
		assert_true(values.has(key), "手感表里应该有 %s" % key)
	assert_true(float(values["downforce"]) >= 0.0, "下压力系数不能是负数")
	assert_true(float(values["upright_torque"]) >= 0.0, "回正力矩不能是负数")
	assert_true(float(values["upright_damping"]) >= 0.0, "回正阻尼不能是负数")
	assert_true(float(values["angular_damp"]) >= 0.0, "车身角阻尼不能是负数")
	# 解析规则：临时文件里塞注释、行尾注释、歪行、不认识的键、非数字
	var path := "user://tmp_handling.txt"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_line("# 整行注释")
	file.store_line("downforce = 42   # 行尾注释")
	file.store_line("upright_damping = 0.25")
	file.store_line("unknown_key = 7")
	file.store_line("upright_torque = abc")
	file.store_line("这不是 key = value 的行")
	file.close()
	GameSettings.forget_audio(path)   # 手感和音频共用一份 mtime 缓存，丢掉就重读
	assert_true(
		is_equal_approx(GameSettings.handling_value("downforce", path), 42.0),
		"认识的键要生效（行尾注释要剥掉）"
	)
	assert_true(
		is_equal_approx(GameSettings.handling_value("upright_damping", path), 0.25),
		"小数要能读"
	)
	assert_true(
		is_equal_approx(
			GameSettings.handling_value("upright_torque", path),
			float(GameSettings.HANDLING_DEFAULTS["upright_torque"])
		),
		"写歪了的键保留默认值"
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	GameSettings.forget_audio(path)


## 机库选择记忆：没存过 = 空串；写进去能读回来、能覆盖；空 id 不擦记录。
## 主界面就用这两个函数记住"上次选的那台车"（切场景 / 退出重进都不跳回第一台）。
func test_garage_remembers_selection() -> void:
	var path := "user://tmp_garage_settings.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	GameSettings.forget(path)
	assert_eq(GameSettings.selected_vehicle(path), "", "没存过 = 空串")
	GameSettings.set_selected_vehicle("custom_2", path)
	assert_eq(GameSettings.selected_vehicle(path), "custom_2", "存进去能读回来")
	GameSettings.set_selected_vehicle("bot_light", path)
	assert_eq(GameSettings.selected_vehicle(path), "bot_light", "能覆盖上一次的选择")
	GameSettings.set_selected_vehicle("", path)
	assert_eq(GameSettings.selected_vehicle(path), "bot_light", "空 id 不覆盖（不会把记录擦掉）")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	GameSettings.forget(path)
