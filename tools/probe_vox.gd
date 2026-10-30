extends SceneTree

## 打印一个 .vox 的场景尺寸和子模型（给新部件定 `cubes` / 子模型序号用）
## godot --headless --path . --script res://tools/probe_vox.gd -- res://data/parts/heavymachinegunx2/重机枪2.vox

func _initialize() -> void:
	var path := ""
	for arg in OS.get_cmdline_user_args():
		path = arg
	if path.is_empty():
		print("用法: --script res://tools/probe_vox.gd -- <res://...vox>")
		quit(1)
		return
	var res := VoxFile.load_vox_models(path)
	if res.has("error"):
		print("ERROR: ", res["error"])
		quit(1)
		return
	print("scene_size = ", res.get("size", res.get("scene_size", "?")))
	var models: Array = res.get("models", [])
	print("models = ", models.size())
	for i in models.size():
		var m: Dictionary = models[i]
		var voxels: Array = m.get("voxels", [])
		var lo := Vector3i(9999, 9999, 9999)
		var hi := Vector3i(-9999, -9999, -9999)
		for v in voxels:
			var p: Vector3i = (v as Dictionary).get("pos", Vector3i.ZERO)
			lo = Vector3i(mini(lo.x, p.x), mini(lo.y, p.y), mini(lo.z, p.z))
			hi = Vector3i(maxi(hi.x, p.x), maxi(hi.y, p.y), maxi(hi.z, p.z))
		print("  model %d: name=%s voxels=%d bounds=%s..%s" % [
			i, str(m.get("name", "")), voxels.size(), str(lo), str(hi)
		])
	quit()
