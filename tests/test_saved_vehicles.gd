@tool
extends McpTestSuite

## 存档载入回归：`data/vehicles/*.vehicle.txt` 里的**每个零件**都必须能原样放下。
##
## 建造规则一改（基准格怎么算、跟谁比），最先碎的往往是"存档载入" —— 载入时放不下
## 就等于读出来少零件，用户直接看到（"保存退出再进来，轮子没了"就是这么来的）。
## 这些文件是玩家在建造模式里存下来的，本来就个个合法，所以任何一个放不下都是我们的回归。

const VEHICLE_DIR := "res://data/vehicles"


func suite_name() -> String:
	return "saved"


func test_every_saved_vehicle_loads_all_parts() -> void:
	var library := PartLibrary.new()
	library.load_all()
	var folder := DirAccess.open(VEHICLE_DIR)
	assert_true(folder != null, "打不开 %s" % VEHICLE_DIR)
	if folder == null:
		return
	var names := folder.get_files()
	names.sort()
	var checked := 0
	for file_name in names:
		if not file_name.ends_with(VehicleDef.SUFFIX):
			continue
		checked += 1
		var path := "%s/%s" % [VEHICLE_DIR, file_name]
		var vehicle := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)
		var grid := BuildGrid.new()
		grid.set_defs(library.defs)
		var failed := PackedStringArray()
		for part in vehicle.parts:
			var def: PartDef = library.get_def(part["part_id"])
			if def == null:
				failed.append("%s（没有这个部件）" % part["part_id"])
				continue
			var result := grid.place(def, part["cell"], part["basis"])
			if not result.get("ok", false):
				failed.append(
					"%s @%s：%s" % [part["part_id"], part["cell"], result.get("reason", "")]
				)
		assert_true(
			failed.is_empty(),
			"%s（%d 件）有零件放不下：%s" % [file_name, vehicle.part_count(), ", ".join(failed)]
		)
	assert_true(checked > 0, "%s 里一个存档都没找到？" % VEHICLE_DIR)
