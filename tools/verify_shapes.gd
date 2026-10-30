extends SceneTree

## 校验"约化形状"（`VoxShapes.clip_planes()`）和**体素实心区**是否对得上。
##
##   godot --headless --path <项目> --script res://tools/verify_shapes.gd
##
## 做法：对每种形状按 1×1×1 格（16³ 体素）建一次实心掩码，然后在格子里撒点：
##   * 体素是实心、但凸包说"在外面" → **漏挡**（子弹/射界会穿过看着是实心的东西）
##   * 体素是空、但凸包说"在里面" → **多挡**（射界比实际小）
## 凸包是台阶的**外包络**，所以"多挡"为 0 才算理想（宁可稍微漏一点，也不能多挡）……

func _initialize() -> void:
	var n := VoxVolume.VOXELS_PER_CUBE
	var size := Vector3i(n, n, n)
	var bounds := AABB(Vector3.ZERO, Vector3.ONE)
	var shapes := ["half_prism_xy", "half_prism_xz", "half_prism_yz", "corner_tetra", "corner_cut"]
	for shape in shapes:
		var masks: Dictionary = VoxShapes.build(shape, size, 1)
		var occ: PackedByteArray = masks["occupancy"]
		var planes: Array = VoxShapes.clip_planes(shape, bounds)
		var solid_voxels := 0
		for v in occ:
			if v != 0:
				solid_voxels += 1
		var miss := 0        # 实心但凸包说外面（漏挡）
		var extra := 0       # 空但凸包说里面（多挡）
		var samples := 4000
		var rng := RandomNumberGenerator.new()
		rng.seed = 12345
		for _i in samples:
			var p := Vector3(rng.randf(), rng.randf(), rng.randf())
			# 体素判定：落在格子边界上的点取靠里的那个体素
			var vx := clampi(int(p.x * n), 0, n - 1)
			var vy := clampi(int(p.y * n), 0, n - 1)
			var vz := clampi(int(p.z * n), 0, n - 1)
			var solid := occ[vx + n * (vy + n * vz)] != 0
			# 平面法线朝外：`n·p - d > 0` = 在凸包**外面**
			var inside := true
			for item in planes:
				var plane: Plane = item
				if plane.normal.dot(p) - plane.d > 0.0:
					inside = false
					break
			if solid and not inside:
				miss += 1
			elif not solid and inside:
				extra += 1
		print("%-16s 体素实心 %5d/%d（%.1f%%）  漏挡 %4d  多挡 %4d  （采样 %d）" % [
			shape, solid_voxels, n * n * n, solid_voxels * 100.0 / float(n * n * n),
			miss, extra, samples
		])
	quit()
