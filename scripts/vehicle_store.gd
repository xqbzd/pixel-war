class_name VehicleStore

## 载具文件放哪儿 —— **任何启动方式都能改**：
##
## * 导出版里 `res://` 是**只读**的（内容打进 .pck），所以**写入一律去 `user://`**
##   （Windows: `%APPDATA%\Godot\app_userdata\<项目名>\data\vehicles\`）；
## * 编辑器 / 直接跑工程时仍然写工程里的 `res://data/vehicles`，文件在文件系统里看得见、能进版本库；
## * 读取时两个目录都扫：`user://` 优先（同 id 覆盖工程里的），再读工程自带的车 ——
##   所以导出包里原来的载具都还在，玩家改过的版本也不会丢。
##
## 所有"载具文件在哪"的问题都走这里，别再在别的脚本里写死 `res://data/vehicles`。

const PROJECT_DIR := "res://data/vehicles"
const USER_DIR := "user://data/vehicles"
const SUFFIX := ".vehicle.txt"


## 测试钩子：强制当成"导出版"（`res://` 只读），用来验证 `user://` 那条路径。
static var force_exported := false


## 是不是导出版（`res://` 只读）。
static func is_exported() -> bool:
	return force_exported or not OS.has_feature("editor")


## 写入目录：导出包 = `user://`，编辑器 = 工程目录。
static func write_dir() -> String:
	return USER_DIR if is_exported() else PROJECT_DIR


## 要扫描的所有目录（写入目录优先）。导出时 = [user://..., res://data/vehicles]。
static func read_dirs() -> PackedStringArray:
	var dirs := PackedStringArray([write_dir()])
	if write_dir() != PROJECT_DIR:
		dirs.append(PROJECT_DIR)
	return dirs


## 建好写入目录（导出后第一次保存时 `user://data/vehicles` 还不存在）。
static func ensure_write_dir() -> void:
	var dir := write_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)


## `<写入目录>/<id>.vehicle.txt`
static func path_for(id: String) -> String:
	return "%s/%s%s" % [write_dir(), id, SUFFIX]


## 这个 id 的载具文件在哪里（写入目录优先，其次工程目录）；找不到返回 ""。
static func find_path(id: String) -> String:
	for dir in read_dirs():
		var path := "%s/%s%s" % [dir, id, SUFFIX]
		if FileAccess.file_exists(path):
			return path
	return ""


## 读所有载具（同 id 以写入目录为准）。目录不存在就跳过（导出版第一次启动时很常见）。
static func load_all() -> Array:
	var by_id := {}
	for dir in read_dirs():
		if not DirAccess.dir_exists_absolute(dir):
			continue
		for vehicle in VehicleDef.load_all(dir):
			if not by_id.has(vehicle.id):
				by_id[vehicle.id] = vehicle
	var ids: Array = by_id.keys()
	ids.sort()
	var out := []
	for id in ids:
		out.append(by_id[id])
	return out


## 下一个可用的载具 id（两个目录都查，不会覆盖任何已存在的车）。
static func next_id() -> String:
	var index := 0
	while index < 10000:
		var id := "custom_%d" % index
		if find_path(id).is_empty():
			return id
		index += 1
	return "custom_0"


## 删掉一个载具文件。工程目录里的文件在导出版里是只读的 → 返回 false。
static func delete(id: String) -> bool:
	var path := find_path(id)
	if path.is_empty():
		return false
	if not path.begins_with("user://") and is_exported():
		return false
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK


## 改显示名（只改文件里的 `name =`，id 不变）。
static func rename(id: String, new_name: String) -> bool:
	var path := find_path(id)
	if path.is_empty():
		return false
	if is_exported() and not path.begins_with("user://"):
		# 工程里自带的只读车：**复制一份**到 user:// 再改，不破坏安装包
		var text := FileAccess.get_file_as_string(path)
		ensure_write_dir()
		var target := path_for(id)
		var file := FileAccess.open(target, FileAccess.WRITE)
		if file == null:
			return false
		file.store_string(text)
		file.close()
		path = target
	return VehicleDef.rename_file(path, new_name)


## 写一个载具文件（写入目录）。返回 "" = 成功，否则是失败原因。
static func save(id: String, text: String) -> String:
	ensure_write_dir()
	var path := path_for(id)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "写不进 %s（%s）" % [path, error_string(FileAccess.get_open_error())]
	file.store_string(text)
	file.close()
	return ""
