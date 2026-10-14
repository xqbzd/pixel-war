extends SceneTree

## 无编辑器跑测试：
##   godot --headless --path <项目目录> --script res://tools/run_tests.gd
##
## 为什么需要它：MCP 测试跑在编辑器里，编辑器一断线就什么都验不了；
## 而 "--check-only" 只能查语法，不能跑逻辑。这个脚本复用插件自带的 McpTestRunner，
## 所以结果和编辑器里跑的一致，但只需要命令行。


func _initialize() -> void:
	var runner: McpTestRunner = McpTestRunner.new()
	var total := 0
	var failed := 0
	var failures := PackedStringArray()
	var dir := DirAccess.open("res://tests")
	if dir == null:
		print("TOTAL=0 FAILED=1 (打不开 res://tests)")
		quit()
		return
	var names := dir.get_files()
	names.sort()
	for file_name in names:
		if not file_name.begins_with("test_") or not file_name.ends_with(".gd"):
			continue
		var script: Variant = load("res://tests/" + file_name)
		if script == null or not script.can_instantiate():
			failed += 1
			failures.append("%s 加载失败（语法错误？）" % file_name)
			continue
		var suite: Variant = script.new()
		if not (suite is McpTestSuite):
			continue
		runner.set("_results", [])
		runner.run_suite(suite)
		for entry in runner.get("_results"):
			total += 1
			if not entry.get("passed", false):
				failed += 1
				failures.append(
					"%s/%s: %s"
					% [entry.get("suite", "?"), entry.get("test", "?"), entry.get("message", "")]
				)
	print("TOTAL=%d FAILED=%d" % [total, failed])
	for line in failures:
		print("FAIL: %s" % line)
	quit()
