extends SceneTree

## 连通性台架：把 `data/vehicles/*.vehicle.txt` 里的车照测试场的做法摆一遍，
## 报"能不能进测试场"，以及这一判定要花多少毫秒（建造模式每改一次零件都要算一次，
## 所以这个数要小 —— 判定现在走的是按几何现算的 `link_pairs()`）。
##
##   godot --headless --path <项目目录> --script res://tools/probe_connectivity.gd [车辆id ...]
##   不给 id 就把 data/vehicles 里的车全跑一遍。
##
## 常用：用户报"建造模式说有零件没连上、存盘进测试场却没事"时，先跑一遍这台车 ——
## 它走的是**和测试场完全一样**的那条路（照清单重建 + robot_status()）。

const VEHICLE_DIR := "res://data/vehicles"


func _initialize() -> void:
	var library := PartLibrary.new()
	library.load_all()
	var ids := []
	for arg in OS.get_cmdline_user_args():
		ids.append(str(arg))
	if ids.is_empty():
		ids = _all_ids()
	if ids.is_empty():
		print("data/vehicles 下没有 .vehicle.txt")
	for id in ids:
		_check(library, str(id))
	quit()


func _all_ids() -> Array:
	var out := []
	var dir := DirAccess.open(VEHICLE_DIR)
	if dir == null:
		return out
	var names := dir.get_files()
	names.sort()
	for file_name in names:
		if file_name.ends_with(".vehicle.txt"):
			out.append(file_name.trim_suffix(".vehicle.txt"))
	return out


func _check(library: PartLibrary, id: String) -> void:
	var path := "%s/%s.vehicle.txt" % [VEHICLE_DIR, id]
	if not FileAccess.file_exists(path):
		print("%s：找不到 %s" % [id, path])
		return
	var vehicle := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)
	var grid := BuildGrid.new()
	grid.set_defs(library.defs)
	var shift := BuildGrid.fit_shift(vehicle.parts, library.defs)
	var missing := 0
	for part in vehicle.parts:
		var def: PartDef = library.get_def(str(part["part_id"]))
		if def == null:
			missing += 1
			continue
		grid.place(def, (part["cell"] as Vector3i) + shift, part["basis"])
	var started := Time.get_ticks_usec()
	var status := grid.robot_status()
	var pairs := (grid.link_pairs() as Array).size()
	var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
	print(
		"%s：%d 个零件，%s（连到核心 %d，断开 %d），连接对 %d，判定耗时 %.1f ms%s"
		% [
			id, vehicle.parts.size(),
			"能进测试场" if bool(status["ok"]) else "进不了：%s" % str(status["reason"]),
			int(status["connected"]), (status["detached"] as Array).size(), pairs, elapsed_ms,
			"" if missing == 0 else "（有 %d 个零件在库表里找不到！）" % missing,
		]
	)
	if not bool(status["ok"]):
		for cell in status["detached"]:
			print("   断开零件所在格：%s" % str(cell))
