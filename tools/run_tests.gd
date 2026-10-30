extends SceneTree

## 无编辑器跑测试：
##   godot --headless --path <项目目录> --script res://tools/run_tests.gd
##
## 只跑相关的套件（日常改代码用这个，别每次都全跑）：
##   godot --headless --path . --script res://tools/run_tests.gd -- --suite=weapon
##   godot --headless --path . --script res://tools/run_tests.gd -- --suite=weapon,battle
##   godot --headless --path . --script res://tools/run_tests.gd -- --suite=weapon --filter=twin_mg
## `--suite` 认套件名（`suite_name()`）或文件名（`test_weapon.gd` → `weapon`）。
## `--filter` 是测试方法名的子串。
##
## 为什么需要它：MCP 测试跑在编辑器里，编辑器一断线就什么都验不了；
## 而 "--check-only" 只能查语法，不能跑逻辑。这个脚本复用插件自带的 McpTestRunner，
## 所以结果和编辑器里跑的一致，但只需要命令行。
##
## ⚠️ 统计口径（踩过坑）：
##   * **测试方法** = `func test_*` 的个数；
##   * **断言** = 每个 `assert_true/eq/...` 调用算一条（一个方法里可能有几十条）；
##   * 每个 suite 都要用**新的 runner**：`_results` 是 `Array[Dictionary]` 类型属性，
##     `runner.set("_results", [])` 在类型不匹配时不会真的清空 —— 以前就因为这个，
##     把"累计方法数"（1979）当成了断言总数报出去，实际断言数是它的几十倍。


func _initialize() -> void:
	var wanted := PackedStringArray()
	for entry in _user_arg("--suite=").split(",", false):
		wanted.append(entry.strip_edges().to_lower())
	var name_filter := _user_arg("--filter=")
	if not wanted.is_empty() or not name_filter.is_empty():
		print("（只跑 suite=%s filter=%s）" % [
			"全部" if wanted.is_empty() else ",".join(wanted), name_filter
		])
	var methods := 0
	var asserts := 0
	var failed := 0
	var failures := PackedStringArray()
	var dir := DirAccess.open("res://tests")
	if dir == null:
		print("TOTAL=0 ASSERTS=0 FAILED=1 (打不开 res://tests)")
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
		if not wanted.is_empty():
			var stem := file_name.get_basename().trim_prefix("test_").to_lower()
			var suite_name := str(suite.suite_name()).to_lower()
			var keep := false
			for entry in wanted:
				if entry == stem or entry == suite_name:
					keep = true
					break
			if not keep:
				continue
		var runner: McpTestRunner = McpTestRunner.new()
		runner.run_suite(suite, name_filter)
		var suite_methods := 0
		var suite_asserts := 0
		var suite_failed := 0
		for entry in runner.get("_results"):
			methods += 1
			suite_methods += 1
			asserts += int(entry.get("assertion_count", 0))
			suite_asserts += int(entry.get("assertion_count", 0))
			if not bool(entry.get("passed", false)):
				failed += 1
				suite_failed += 1
				failures.append(
					"%s/%s: %s"
					% [entry.get("suite", "?"), entry.get("test", "?"), entry.get("message", "")]
				)
		print("%-24s 方法 %3d  断言 %4d  失败 %d" % [
			file_name, suite_methods, suite_asserts, suite_failed
		])
	print("TOTAL=%d FAILED=%d ASSERTS=%d（%d 个测试方法 / %d 条断言）" % [
		methods, failed, asserts, methods, asserts
	])
	for line in failures:
		print("FAIL: %s" % line)
	quit()


## `--` 后面的自定义参数，例如 `--suite=weapon`。
static func _user_arg(prefix: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""
