extends Node

## 全局音频（作为 autoload 常驻，见 project.godot 的 [autoload]）。
##
## 为什么用 autoload：音乐要**跨场景不断**（主界面 → 建造模式不该重头放），
## 音量设置也要一启动就生效。它只做三件事：
##   * 一条循环音乐（`play_music()` / `stop_music()`，走 `Music` 总线）；
##   * 一个音效播放池（`play_sfx()`，走 `SFX` 总线，能同时叠好几发）；
##   * 启动时调一次 `GameSettings.apply_audio()` 把音量写进总线。
##
## 素材来源与授权见 `assets/audio/CREDITS.md`（引擎循环 / 菜单音乐是 CC0，
## 机枪单发是 CC-BY 4.0，需要署名 —— 已经记在那个文件里）。

const GameSettings := preload("res://scripts/game_settings.gd")

const MUSIC_PATH := "res://assets/audio/music_loop.wav"
const ENGINE_PATH := "res://assets/audio/engine_loop.wav"
const SHOT_PATH := "res://assets/audio/machine_gun_shot.mp3"
## 素材之间的相对强弱写在 `data/audio.txt`（用户手调，改完进一次新场景就生效）；
## 解析在 `GameSettings.audio_strength()` 里，测试也跟着那份走，只有一处实现。
## 同时能叠几个音效（机枪 600 rpm、每发间隔 0.1 秒，6 个够用）
const SFX_VOICES := 6

var _music: AudioStreamPlayer
var _sfx: Array[AudioStreamPlayer] = []
var _next_voice := 0
var _streams := {}      # path -> AudioStream（带循环设置的缓存）


func _ready() -> void:
	_music = AudioStreamPlayer.new()
	_music.name = "MusicPlayer"
	_music.stream = _load_stream(MUSIC_PATH, true)
	_music.bus = GameSettings.BUS_MUSIC
	_music.volume_db = GameSettings.audio_strength("music")
	add_child(_music)
	for i in SFX_VOICES:
		var player := AudioStreamPlayer.new()
		player.name = "Sfx%d" % i
		player.bus = GameSettings.BUS_SFX
		add_child(player)
		_sfx.append(player)
	GameSettings.apply_audio()


## 取一个音频流；`looped = true` 时把循环点设成整段
## （.wav 默认不循环，要在运行时打开 —— 导入设置里改要动 .import，这里一行搞定）。
func _load_stream(path: String, looped := false) -> AudioStream:
	var key := "%s|%s" % [path, str(looped)]
	if _streams.has(key):
		return _streams[key]
	var stream: AudioStream = load(path)
	if stream is AudioStreamWAV and looped:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = int(wav.get_length() * float(wav.mix_rate))
	_streams[key] = stream
	return stream


## 引擎循环音（测试场里的车用；音量和音高由驾驶状态每帧驱动）。
func engine_stream() -> AudioStream:
	return _load_stream(ENGINE_PATH, true)


## 机枪开火音流（项目里现在按**世界坐标**播：每发按距离衰减 + 左右声道，见 spatial_audio.gd）。
func shot_stream() -> AudioStream:
	return _load_stream(SHOT_PATH)


func play_music(stream_path := MUSIC_PATH) -> void:
	if _music == null:
		return
	_music.volume_db = GameSettings.audio_strength("music")
	var wanted := _load_stream(stream_path, true)
	if _music.stream != wanted:
		_music.stream = wanted
	if not _music.playing:
		_music.play()


func stop_music() -> void:
	if _music != null and _music.playing:
		_music.stop()


## 放一个音效（轮着用池子，能叠）。`volume_db` 是 dB 偏移（0 = 原始响度）。
func play_sfx(stream_path: String, volume_db := 0.0, pitch := 1.0) -> void:
	if _sfx.is_empty():
		return
	var player := _sfx[_next_voice]
	_next_voice = (_next_voice + 1) % _sfx.size()
	player.stream = _load_stream(stream_path)
	player.volume_db = volume_db
	player.pitch_scale = pitch
	player.play()


## 机枪开火音（测试场里每发调一次）。响度取 `data/audio.txt` 的 `shot`，
## 音高每发随机抖一点（不然连射听着像电子音）。
func play_shot(pitch := 1.0) -> void:
	# `pitch` 来自部件文件的 `weapon_pitch`（重机枪 0.78 → 更低沉）
	play_sfx(SHOT_PATH, GameSettings.audio_strength("shot"), randf_range(0.94, 1.06) * pitch)
