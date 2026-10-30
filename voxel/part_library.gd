@tool
class_name PartLibrary
extends RefCounted

## 部件库：扫描 data/parts/*.part.txt，按 (部件, 渲染路线) 缓存构建结果。
##
## 主界面、载具列表、载具编辑器、以及开发用的 part_preview 都从这里取部件，
## 所以同一个部件在所有场景里共享同一个 mesh + 材质 —— 这是"实例再多也不怕"的前提。

const DEFAULT_DIR := "res://data/parts"
const PART_SUFFIX := ".part.txt"

var dir := DEFAULT_DIR
var defs := {}  # id -> PartDef
var warnings: PackedStringArray = PackedStringArray()

var _builds := {}  # "id:mode" -> build dict
var _sub_builds := {}  # id -> build dict（附属子模型，比如轮体）
var _weapon_builds := {}  # "id:index" -> build dict（转塔的子模型：底座/支架/枪管）
var _icons := {}  # "id:size" -> ImageTexture（物品菜单/物品栏的斜向视图图标，按需生成）


func load_all(path := DEFAULT_DIR) -> void:
	dir = path
	defs.clear()
	_builds.clear()
	_sub_builds.clear()
	_weapon_builds.clear()
	_icons.clear()
	warnings.clear()
	var folder := DirAccess.open(dir)
	if folder == null:
		_warn("打不开部件目录 %s" % dir)
		push_error("PartLibrary: 打不开部件目录 %s" % dir)
		return
	# 递归扫描：支持"一个零件一个文件夹"的布局（模型和 .part.txt 放一起）
	for full in find_files_recursive(dir, PART_SUFFIX):
		var def := PartDef.from_text(FileAccess.get_file_as_string(full), full)
		defs[def.id] = def
		for warning in def.warnings:
			_warn("%s: %s" % [full.get_file(), warning])


## 递归找出某个后缀的文件（返回 res:// 路径数组）。deps: 实验室扫描模型也用它。
static func find_files_recursive(root: String, suffix: String, out: Array = []) -> Array:
	var folder := DirAccess.open(root)
	if folder == null:
		return out
	for file_name in folder.get_files():
		if file_name.ends_with(suffix):
			out.append(root.path_join(file_name))
	for sub in folder.get_directories():
		find_files_recursive(root.path_join(sub), suffix, out)
	return out


func ids() -> Array:
	var out := defs.keys()
	# 按 order 再按 id：物品栏里 1=方块、2=斜坡 …… 的顺序由数据文件决定，不靠文件名
	out.sort_custom(func(a: String, b: String) -> bool:
		var da: PartDef = defs[a]
		var db: PartDef = defs[b]
		if da.order != db.order:
			return da.order < db.order
		return a < b
	)
	return out


func has_part(id: String) -> bool:
	return defs.has(id)


func get_def(id: String) -> PartDef:
	return defs.get(id)


## 某个分类里的部件 id（按 order / id 排，和物品栏同一套顺序）。
## 建造界面的零件菜单按分类分页就是问它，别在 UI 里再写一遍过滤逻辑。
func ids_for_category(category: String) -> Array:
	var out := []
	for id in ids():
		var def: PartDef = defs[id]
		if def != null and def.category == category:
			out.append(id)
	return out


## 分类 -> 这一页有几个零件（菜单里给空分类显示一行"这一类还没有零件"）。
func category_counts() -> Dictionary:
	var out := {}
	for key in PartDef.CATEGORIES:
		out[key] = 0
	for id in defs:
		var def: PartDef = defs[id]
		if def == null:
			continue
		out[def.category] = int(out.get(def.category, 0)) + 1
	return out


## 零件图标（斜向视图）。第一次用到才画，之后直接返回缓存的 ImageTexture。
## ⚠️ 别在 `load_all()` 里一次画完所有零件：上百个零件就是上百张 64x64 图，
## 而玩家可能一个菜单都不打开。按需 + 缓存才是能活到"上百种零件"的写法。
func icon(id: String, size := PartIcon.TARGET) -> Texture2D:
	var key := "%s:%d" % [id, size]
	if _icons.has(key):
		return _icons[key]
	var def: PartDef = defs.get(id)
	if def == null:
		return null
	var image := PartIcon.render(def, size)
	var texture := ImageTexture.create_from_image(image)
	_icons[key] = texture
	return texture


## 按指定渲染路线取构建结果（缓存）。mode 用 PartDef.RenderMode 的值。
func build_for(id: String, mode: int) -> Dictionary:
	var key := "%s:%d" % [id, mode]
	if _builds.has(key):
		return _builds[key]
	var def: PartDef = defs.get(id)
	if def == null:
		_warn("找不到部件 %s" % id)
		push_error("PartLibrary: 找不到部件 %s" % id)
		var missing := {"mesh": null, "material": null, "quads": 0, "tris": 0, "mode": "missing"}
		_builds[key] = missing
		return missing
	var result := def.build_as(mode)
	for warning in def.warnings:
		_warn("%s: %s" % [id, warning])
	_builds[key] = result
	return result


## 用部件自己声明的路线构建。
func build_default(id: String) -> Dictionary:
	var def: PartDef = defs.get(id)
	if def == null:
		return build_for(id, PartDef.RenderMode.VOXEL)
	return build_for(id, def.render_mode)


## 附属子模型（轮体）的构建结果（缓存）。没有子模型返回空字典。
func build_sub(id: String) -> Dictionary:
	if _sub_builds.has(id):
		return _sub_builds[id]
	var def: PartDef = defs.get(id)
	var result := def.build_sub_model() if def != null else {}
	for warning in (def.warnings if def != null else []):
		_warn("%s: %s" % [id, warning])
	_sub_builds[id] = result
	return result


## 转塔某个子模型（0 = 底座 / 1 = 支架 / 2 = 枪管）的构建结果（缓存）。
## 网格顶点在零件本地坐标上，转塔节点只要平移 -转点就能绕转点旋转（见 scripts/turret.gd）。
func build_weapon(id: String, index: int) -> Dictionary:
	var key := "%s:%d" % [id, index]
	if _weapon_builds.has(key):
		return _weapon_builds[key]
	var def: PartDef = defs.get(id)
	var result := def.build_weapon_part(index) if def != null else {}
	for warning in (def.warnings if def != null else []):
		_warn("%s: %s" % [id, warning])
	_weapon_builds[key] = result
	return result


## 打包一批实例的渲染节点：零件本体一个 MultiMesh，附属子模型（有的话）再一个。
## 子模型网格的顶点已经按挂载偏移摆好，所以两者共用同一批实例变换。
static func make_part_nodes(transforms: Array, build: Dictionary, sub_build := {}) -> Array:
	var out: Array = []
	out.append(make_multimesh(transforms, build))
	if not sub_build.is_empty() and sub_build.get("mesh") != null:
		out.append(make_multimesh(transforms, sub_build))
	return out


## 用指定路线构建整张部件表，返回 id -> build。载具编辑器切换"质量档"时会用到。
func build_all(mode: int) -> Dictionary:
	var out := {}
	for id in ids():
		out[id] = build_for(id, mode)
	return out


## 把同一部件的若干实例打包成 1 个 MultiMesh（部件本地原点 = cube 单元角点）。
static func make_multimesh(transforms: Array, build: Dictionary) -> MultiMeshInstance3D:
	var node := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	if build.get("mesh") != null:
		mm.mesh = build["mesh"]
		mm.instance_count = transforms.size()
		for i in range(transforms.size()):
			mm.set_instance_transform(i, transforms[i])
	node.multimesh = mm
	if build.get("material") != null:
		node.material_override = build["material"]
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return node


## 贴图路线的前提：该部件的每个占用单元都是实心 16^3。
static func is_full_cube_part(def: PartDef, volume: VoxVolume) -> bool:
	var cells := def.occupied_cells(volume)
	if cells.is_empty():
		return false
	for cell in cells:
		if not volume.is_cell_full_cube(cell):
			return false
	return true


func _warn(message: String) -> void:
	if not warnings.has(message):
		warnings.append(message)
