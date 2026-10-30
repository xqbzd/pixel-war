@tool
extends McpTestSuite

## MagicaVoxel `.vox` 读写自测。
## 关键的一条是"手工按规范拼一个 .vox 来读"—— 否则测试只能证明读写器互相自洽，
## 证明不了它符合 .vox 规范（那样 MagicaVoxel 里打开会是坏的）。

func suite_name() -> String:
	return "voxfile"


func test_vox_round_trip() -> void:
	var volume := VoxVolume.for_cubes(Vector3i.ONE)
	var body := volume.index_of_color(Color("c9c9ce"))
	var edge := volume.index_of_color(Color("8e8e96"))
	VoxShapes.apply(volume, VoxShapes.SHAPE_HALF_PRISM_XY, 1, body, edge)
	var path := "user://round_trip.vox"
	assert_true(VoxFile.save_vox(path, volume), "写出 .vox 应成功")
	var loaded := VoxFile.load_vox(path, Vector3i(16, 16, 16))
	assert_eq(loaded["warnings"].size(), 0, "读回不该有警告：%s" % str(loaded["warnings"]))
	var back: VoxVolume = loaded["volume"]
	assert_eq(back.solid_count(), volume.solid_count(), "体素数应一致")
	var mismatches := 0
	for z in range(16):
		for y in range(16):
			for x in range(16):
				if volume.is_solid(x, y, z) != back.is_solid(x, y, z):
					mismatches += 1
	assert_eq(mismatches, 0, ".vox 往返应逐体素相同（含 Z-up 换轴）")
	assert_true(back.color_of(back.get_voxel(5, 5, 8)).is_equal_approx(Color("c9c9ce")), "主体色应保留")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_reads_handcrafted_vox() -> void:
	var path := "user://handcrafted.vox"
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_true(file != null, "应能写测试文件")
	file.store_buffer("VOX ".to_ascii_buffer())
	file.store_32(150)
	file.store_buffer("MAIN".to_ascii_buffer())
	file.store_32(0)
	file.store_32((12 + 12) + (12 + 4 + 2 * 4) + (12 + 1024))
	file.store_buffer("SIZE".to_ascii_buffer())
	file.store_32(12)
	file.store_32(0)
	file.store_32(4)
	file.store_32(4)
	file.store_32(4)
	file.store_buffer("XYZI".to_ascii_buffer())
	file.store_32(4 + 2 * 4)
	file.store_32(0)
	file.store_32(2)
	file.store_8(0)
	file.store_8(0)
	file.store_8(0)
	file.store_8(1)  # 体素 (0,0,0) 颜色索引 1
	file.store_8(1)
	file.store_8(0)
	file.store_8(0)
	file.store_8(2)  # 体素 (1,0,0) 颜色索引 2
	file.store_buffer("RGBA".to_ascii_buffer())
	file.store_32(1024)
	file.store_32(0)
	for i in range(256):
		if i == 0:
			file.store_8(255)
			file.store_8(0)
			file.store_8(0)
		elif i == 1:
			file.store_8(0)
			file.store_8(255)
			file.store_8(0)
		else:
			file.store_8(0)
			file.store_8(0)
			file.store_8(0)
		file.store_8(255)
	file.close()

	# 注意：读进来的模型会**归一到自己的 0 基包围盒**（画在 .vox 的哪个角落都一样），
	# 所以这里两个体素归一化后落在 (0,0,0) 和 (1,0,0)。
	var loaded := VoxFile.load_vox(path, Vector3i(16, 16, 16))
	assert_eq(loaded["warnings"].size(), 0, "读手工文件不该有警告：%s" % str(loaded["warnings"]))
	var volume: VoxVolume = loaded["volume"]
	assert_eq(volume.solid_count(), 2, "应读到两个体素")
	assert_true(volume.is_solid(0, 0, 0), "第一个体素应被归一化到原点")
	assert_true(volume.is_solid(1, 0, 0), "第二个体素位置")
	assert_true(volume.color_of(volume.get_voxel(0, 0, 0)).is_equal_approx(Color.RED), "索引 1 应是红色")
	assert_true(volume.color_of(volume.get_voxel(1, 0, 0)).is_equal_approx(Color.GREEN), "索引 2 应是绿色")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## 模型比部件体积大时要给警告（提示把 cubes 调大），而不是静默裁掉
func test_oversized_model_warns() -> void:
	var volume := VoxVolume.new(Vector3i(32, 32, 32))
	volume.palette = [Color(0, 0, 0, 0), Color("c9c9ce")]
	volume.set_voxel(0, 0, 0, 1)
	volume.set_voxel(31, 31, 31, 1)
	var path := "user://oversized.vox"
	assert_true(VoxFile.save_vox(path, volume), "写出应成功")
	var loaded := VoxFile.load_vox(path, Vector3i(16, 16, 16))
	assert_gt(loaded["warnings"].size(), 0, "模型比部件大时应留下警告")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## 反过来：画在画布角落、但自己很小的模型**不算**超框（不能报假警告）。
## 判据是模型自己的包围盒 —— 体素在 load_vox_models() 里已经归一到 0 基，
## 作者把物体画在画布哪个角落都不影响它落地在部件盒里的位置（那件事由 model_offset 管）。
## 以前按"场景偏移 + 尺寸"判断，随手画在画布边上的模型就会被误报成超框
## （小货车轮胎的轮轴就踩到了这条）。
func test_small_model_in_a_canvas_corner_is_not_oversized() -> void:
	var volume := VoxVolume.new(Vector3i(48, 48, 48))
	volume.palette = [Color(0, 0, 0, 0), Color("c9c9ce")]
	volume.set_voxel(40, 40, 40, 1)
	var path := "user://corner_model.vox"
	assert_true(VoxFile.save_vox(path, volume), "写出应成功")
	var loaded := VoxFile.load_vox(path, Vector3i(16, 16, 16))
	assert_eq(
		loaded["warnings"].size(), 0, "一格大的模型不该报超框：%s" % str(loaded["warnings"])
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
