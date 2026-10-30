extends McpTestSuite

## 载具存档位置：**任何启动方式都能改**（导出版 `res://` 只读 → 写 `user://`）。
## 这里用 `VehicleStore.force_exported` 模拟导出版，验证 user:// 那条路径。

func suite_name() -> String:
	return "vehicle_store"


func test_reads_project_vehicles() -> void:
	var vehicles := VehicleStore.load_all()
	assert_true(vehicles.size() >= 1, "工程里自带的载具应该能读到（实际 %d）" % vehicles.size())
	var ids := []
	for vehicle in vehicles:
		ids.append(vehicle.id)
	assert_true(ids.has("custom_1"), "应该有 custom_1：%s" % str(ids))


## 导出版：写入目录必须是 user://，保存 / 改名 / 删除 / 列表都得走通。
func test_writes_to_user_dir_when_exported() -> void:
	VehicleStore.force_exported = true
	assert_true(VehicleStore.is_exported(), "force_exported 生效")
	assert_eq(VehicleStore.write_dir(), VehicleStore.USER_DIR, "导出版写入目录 = user://")
	var dirs := VehicleStore.read_dirs()
	assert_true(dirs.has(VehicleStore.USER_DIR), "读取目录包含 user://")
	assert_true(dirs.has(VehicleStore.PROJECT_DIR), "读取目录也包含工程目录（自带的车还要能读）")
	var text := "name = 存档路径测试\npart = core 0 0 0 0 0 0\n"
	var error := VehicleStore.save("__store_probe", text)
	assert_eq(error, "", "保存到 user:// 应该成功：%s" % error)
	var path := VehicleStore.find_path("__store_probe")
	assert_true(path.begins_with("user://"), "找到的文件应该在 user://：%s" % path)
	# 列表里能同时看到"工程自带"和"user:// 新存"的
	var ids := []
	for vehicle in VehicleStore.load_all():
		ids.append(vehicle.id)
	assert_true(ids.has("__store_probe"), "列表里有刚存的车：%s" % str(ids))
	assert_true(ids.has("custom_1"), "列表里也还有工程自带的车：%s" % str(ids))
	# 改名
	assert_true(VehicleStore.rename("__store_probe", "改过的名字"), "改名要成功")
	var renamed := ""
	for vehicle in VehicleStore.load_all():
		if vehicle.id == "__store_probe":
			renamed = vehicle.display_name
	assert_eq(renamed, "改过的名字", "改名生效")
	# 删除
	assert_true(VehicleStore.delete("__store_probe"), "删除 user:// 里的车应该成功")
	assert_true(VehicleStore.find_path("__store_probe").is_empty(), "删完就找不到了")
	VehicleStore.force_exported = false


## 导出版里**工程自带**的车是只读的：改名要复制一份到 user:// 再改，原文件不能坏。
func test_rename_shipped_vehicle_copies_to_user_dir() -> void:
	VehicleStore.force_exported = true
	var original := FileAccess.get_file_as_string(
		"%s/custom_1%s" % [VehicleStore.PROJECT_DIR, VehicleStore.SUFFIX]
	)
	assert_true(not original.is_empty(), "工程里的 custom_1 应该存在")
	assert_true(VehicleStore.rename("custom_1", "复制出来的名字"), "改名（复制）应该成功")
	var path := VehicleStore.find_path("custom_1")
	assert_true(path.begins_with("user://"), "改名后文件应该在 user://：%s" % path)
	assert_true(
		FileAccess.get_file_as_string(path).contains("复制出来的名字"), "新文件里是新名字"
	)
	assert_true(
		FileAccess.get_file_as_string(
			"%s/custom_1%s" % [VehicleStore.PROJECT_DIR, VehicleStore.SUFFIX]
		) == original,
		"工程里那份原文件不能被改坏"
	)
	VehicleStore.delete("custom_1")
	VehicleStore.force_exported = false
