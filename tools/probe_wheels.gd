extends SceneTree

## 轮胎体检：把每个轮子部件的"轮轴 / 轮体 / 轮心 / 半径 / 贴地余量"打出来。
##
##   godot --headless --path <项目目录> --script res://tools/probe_wheels.gd [部件id]
##
## 加新轮胎、或者把模型挪过位置之后先跑这个：
##   * **Δy / Δz** = 轮心 与 轮轴轴线 的差。差得远 = 轮子会绕着轮轴画圈（该挪画布里的轮体）；
##   * **半径** = 测试场里悬挂/射线算力的依据（`wheel_radius = 0` 时按轮体盒子自动取）；
##   * **轮体最低点** = 相对零件盒底（本地 y = 0）低多少 —— 车贴地时轮胎压到哪儿看这个。

const PART_DIR := "res://data/parts"


func _initialize() -> void:
	var wanted := ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		wanted = str(args[0])
	var library := PartLibrary.new()
	library.load_all(PART_DIR)
	for warning in library.warnings:
		print("[!] %s" % str(warning))
	var found := 0
	for id in library.ids():
		var def: PartDef = library.get_def(id)
		if not def.is_wheel():
			continue
		if not wanted.is_empty() and wanted != id:
			continue
		found += 1
		_dump(def)
	if found == 0:
		print("没有找到轮子部件（写了 wheel_body_model 的才是）")
	print("轮胎体检完毕：%d 个轮子" % found)
	quit()


func _dump(def: PartDef) -> void:
	print("=== %s（%s）===" % [def.short_name(), def.id])
	print("  模型 %s  占 %s 格  轮体 = 第 %d 号子模型" % [
		def.model_path.get_file(), str(def.cubes), def.wheel_body_model
	])
	var body := def.body_bounds()
	var axis := body.get_center()
	var sub := def.sub_model_volume()
	if sub == null:
		print("  [!] 轮体读不出来 —— 检查 wheel_body_model 序号和模型文件")
		return
	var box := PartDef.tight_bounds(sub, def.sub_model_offset(), Vector3.ONE)
	var centre := box.get_center()
	var radius := maxf(box.size.y, box.size.z) * 0.5
	if def.wheel_radius > 0.0:
		radius = def.wheel_radius
	print("  轴心（本体盒中心）  本地 y %.3f  z %.3f" % [axis.y, axis.z])
	print("  轮心（轮体盒中心）  本地 x %.3f  y %.3f  z %.3f" % [centre.x, centre.y, centre.z])
	print("  Δ轮心−轮轴盒中心    y %+.3f  z %+.3f   %s" % [
		centre.y - axis.y,
		centre.z - axis.z,
		(
			"✓ 重合"
			if absf(centre.y - axis.y) < 0.07 and absf(centre.z - axis.z) < 0.07
			else "⚠ 不重合（本体盒中心只是轴线近似：模型不对称时本来就会差；看图决定要不要挪轮体）"
		)
	])
	print("  轮体尺寸 %.3f x %.3f x %.3f 格 → 半径 %.3f 格（%.2f 米）" % [
		box.size.x, box.size.y, box.size.z, radius, radius * PartDef.CUBE_METERS
	])
	print("  轮体最低点 本地 y %.3f（比零件盒底低 %.3f 格）· 整机包围盒 %s" % [
		box.position.y, maxf(0.0, -box.position.y), str(def.mesh_bounds())
	])
	print("  轮体在 .vox 里的相对位移 %s 体素（= 画布位置；wheel_offset 微调 %s）" % [
		str(def.wheel_body_scene_shift()), str(def.wheel_offset)
	])
