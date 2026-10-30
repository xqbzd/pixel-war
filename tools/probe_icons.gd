extends SceneTree

## 临时探针：把每个零件的图标渲染成 PNG，并打印投影尺寸 / 不透明像素数。
## 用来肉眼确认"斜向视图"画得对不对（也让图标测试里的数字有据可查）。
## 跑法：godot --headless --path . --script res://tools/_icon_probe.gd


func _initialize() -> void:
	var library := PartLibrary.new()
	library.load_all("res://data/parts")
	var out_dir := "user://icons"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	for id in library.ids():
		var def: PartDef = library.get_def(id)
		var voxels := PartIcon.collect(def)
		# 体素包围盒：图标画歪了（比如轮体叠在轮轴上）一眼就能从这几个数看出来
		var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
		var hi := -lo
		for entry in voxels:
			var pos: Vector3i = entry["pos"]
			lo = lo.min(pos)
			hi = hi.max(pos)
		var native := PartIcon.paint(voxels)
		var icon := PartIcon.render(def)
		var opaque := 0
		for y in range(icon.get_height()):
			for x in range(icon.get_width()):
				if icon.get_pixel(x, y).a > 0.5:
					opaque += 1
		var path := out_dir.path_join("%s.png" % id)
		icon.save_png(path)
		print(
			"%-24s 体素%6d  体素范围 %s..%s  原生%4dx%-4d 图标 %dx%d 不透明%5d"
			% [
				id,
				voxels.size(),
				str(lo),
				str(hi),
				native.get_width(),
				native.get_height(),
				icon.get_width(),
				icon.get_height(),
				opaque,
			]
		)
		_ascii(icon)
	print("图标目录：%s" % ProjectSettings.globalize_path(out_dir))
	quit()


## 把 64x64 的图标压成字符画（每 2x2 像素取一格），在无头模式里也能"看"出形状：
## 亮 = 顶面、+ = 前面、. = 右面、空 = 透明。
func _ascii(image: Image) -> void:
	var lines := PackedStringArray()
	for row in range(0, image.get_height(), 2):
		var line := ""
		for column in range(0, image.get_width(), 2):
			var best := " "
			var best_alpha := 0.2
			for dy in range(2):
				for dx in range(2):
					var colour := image.get_pixel(column + dx, row + dy)
					if colour.a <= best_alpha:
						continue
					best_alpha = colour.a
					best = "#" if colour.v > 0.78 else ("+" if colour.v > 0.48 else ".")
			line += best
		lines.append(line)
	print("\n".join(lines))
