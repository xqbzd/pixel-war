extends Node3D
class_name TestField

## 测试场：把载具按物理摆进一整块现成场地（Truck Town 的城镇 + 赛道模型）里，验证轮子能不能跑。
##
##   - 轮轴（带 `wheel_body` 的部件）→ **自定义轮胎节点**：从轮心朝圆周打 16 条等距射线
##     （每 22.5° 一条，整圈判定），合并接触后每轮只计算一份弹簧、阻尼和摩擦。
##     为什么不用 `VehicleWheel3D`：它每个轮子只有一条竖直射线、不可配，骑台阶/路缘/坡脚时
##     "感觉不到"，越野很差（试过一簇多射线 + 视觉去穿透，都不划算，已回滚）。
##     轮胎**转动**也是自己按地面速度驱动的（`_spin_tire()`）。
##   - 其余零件 → 合成一个 `RigidBody3D` 底盘：每个零件一个 BoxShape（本体包围盒，
##     不含轮胎），质量取部件数值之和，质心取各零件重心按重量加权；毁伤更新刚体，悬挂参数保持进场快照。
##   - 场地：**一整块现成模型** `assets/arena/truck_town/town_model.gltf`
##     （Godot 官方 demo "Truck Town"，MIT；里面是 10 栋房子 + 赛道 + 5 个坡道 +
##     巨型轮胎障碍 + 2 公里见方的地面，本来就是给车开的场景）。
##     碰撞直接拿模型网格做 trimesh；整块场地挂在一个根节点下，**缩放根节点就能整体缩放**
##     （连碰撞一起缩放）。进游戏按 `[` `]` 现场调，HUD 上显示当前倍数。
##   - 出生点：在赛道附近的候选点上竖直探测模型网格，落在最上面的那一片路面上。
##   - WASD 开车（W/S 油门·反向、A/D 全轮转向），环视相机，ESC 回主界面。
##     空格**不参与**驾驶（改成开火了），反方向键自动先刹车（见 REVERSE_BRAKE_SPEED_CUBES）。

const MENU_SCENE := "res://scenes/main_menu.tscn"
const VEHICLE_DIR := "res://data/vehicles"
const GameSettings := preload("res://scripts/game_settings.gd")
## 出生高度（格）：车底离地 0.3 格（0.15 米），让悬挂轻轻落地。
const SPAWN_HEIGHT := 0.3
## 场地：一整块现成模型（Truck Town，MIT）。1 模型单位 ≈ 1 米左右（房子 6~10 单位高）。
## 想改倍数：进游戏按 `[` / `]` 现场调（HUD 显示当前倍数），定了告诉我我改这个默认值。
const ARENA_SCENE := "res://assets/arena/truck_town/town_model.gltf"
## 场地校准：**1 cube = PartDef.CUBE_METERS 米**（见 `voxel/part_def.gd` 的说明）。
## 城镇模型的单位≈米，所以倍数 = ARENA_SCALE 个"模型单位"换 1 格。
## ⚠️ 只有"改 CUBE_METERS 的世界标定"时这一套才会跟着动（重力在 project.godot）。
const ARENA_SCALE := 5.0
const ARENA_SCALE_MIN := 0.15
const ARENA_SCALE_MAX := 40.0
const ARENA_SCALE_STEP := 1.25
## 隐形围墙（模型单位）：把可开区域围起来，别开到 2 公里外的空地上去。
const ARENA_BOUNDS := 170.0
## 出生点在哪些网格上找（按优先级）：先马路、再赛道、最后才是那 2 公里见方的地面。
## **只在这三类网格上找**，所以永远不会像上次那样落在屋顶上（那次就是屋顶被当成"地面"了）。
const ARENA_SPAWN_SURFACES := ["RoadMesh", "RacetrackMesh", "OuterGroundMesh"]
## 出生点候选范围（模型单位）+ 每边取几个点：在城镇/赛道范围内撒点，挑最低的那一个。
const ARENA_SPAWN_AREA := Rect2(-115.0, -80.0, 175.0, 125.0)
const ARENA_SPAWN_STEPS := 7
## **固定出生点**（模型单位）：非零就直接用，不再自动搜索。
## 这个数是"在场地里推车找出来的"：进游戏按 ↑↓←→ 推车、`<` `>` 升降，
## HUD 上会显示"车的位置（模型单位）"，把满意的那三个数填到这里即可。
## 当前值 = 用户 2026-10-11 选定的位置（那时车停的地方）。
const ARENA_SPAWN_MODEL := Vector3(-19.42, 5.13, 15.30)
## 相机：绕"环视中心"（见 CAMERA_CENTER_CLEARANCE）自由环视，滚轮变焦，不自动回正。
## 中心抬到车上 10 米之后，8 米的距离会把车挤出画面，所以默认距离跟着放大
## （70° FOV 下 28 米时，车大约落在画面下缘往上一点）。
const CAMERA_DISTANCE := 28.0
const CAMERA_MIN_DISTANCE := 5.0
const CAMERA_MAX_DISTANCE := 90.0
const CAMERA_MIN_PITCH := -70.0
const CAMERA_MAX_PITCH := 65.0
## 环视（瞄准）中心：x/z 取载具**重心**，y 取"整车最高点 + 这个高度"（单位 = 格）。
## 抬高是为了以后接武装系统：准星对着的是一块空中的点，绕着它转就能扫到周围。
## 5 格（标定 0.5 米/格 ⇒ 2.5 米；一开始写的 10 格，用户觉得太高了）。
const CAMERA_CENTER_CLEARANCE := 5.0
## 世界标定：1 cube 等于多少米。速度表的"km/h"就是拿它换算出来的
## （和 `project.godot` 的重力是一套：重力 = 真实 9.8 ÷ CUBE_METERS）。
## 部件文件里的速度一律写真实 m/s，这里换算成"格/秒"（内部模拟单位）。
const CUBE_METERS := PartDef.CUBE_METERS
## 速度表字号（左上角那个大数字）
const SPEEDO_FONT_SIZE := 34
## 方向光阴影：**默认关**。开着时相机和车每帧都在动 => 每帧重画一遍阴影图
## （默认 4096² + 模糊），这是测试场里最贵的一项。想看阴影把它改成 true。
const SHADOWS := false
## 驾驶动作 → 默认按键。走 InputMap 动作（不只为了手感：动作能在无头测试里按下去）。
## 空格**不绑驾驶**（另有他用）：反方向键先自动刹车，停稳了再反向起步。
const DRIVE_ACTIONS := {
	"drive_forward": KEY_W,
	"drive_back": KEY_S,
	"drive_left": KEY_A,
	"drive_right": KEY_D,
}
## 开火动作：左键 / 空格都能按（枪是持续开火，松手才停；射速由部件文件的 rpm 管）。
const FIRE_KEY := KEY_SPACE
const FIRE_ACTION := "fire_weapon"
## 反向键当刹车用的速度门槛（**格/秒** —— 下面比的是 `forward_speed`，它是内部单位格/秒；
## 名字里的单位别省，标成 m/s 会看错 1/CUBE_METERS 倍。0.6 格/秒 = 0.3 m/s）
const REVERSE_BRAKE_SPEED_CUBES := 0.6
## 低速静摩擦的上限速度（格/秒）：没给油、速度低于它就当"停住"，
## 用刹车那套增益把残余速度按平（不然静止的车会被支撑力的横向分量慢慢推走 ——
## 实测 0.1 格/秒²，小车滑到轮子射线的临界点就会被弹飞）。
const STOP_GRIP_SPEED := 1.0
## 轮胎**视觉**转速（和物理无关，纯给玩家看的）：
##   - 不跟 `VehicleWheel3D.get_rpm()` 走 —— 滑行时它恒为 0、给油时又乱跳（"看着像随机乱转"）；
##   - 自己按"地面速度 / 半径"算滚动，再在**这个轮子正在输出**时叠加一个指示转速，
##     所以静止时按油门也能看出轮子朝哪转（转速上限压住，别快得看不清）。
const TIRE_SPIN_MAX := TAU * 2.5        # 视觉上限（圈/秒）：真车 15 m/s 也就 2.4 圈/秒
const TIRE_SPIN_INDICATE := TAU * 0.6   # 正在输出时额外给 0.6 圈/秒，做方向指示

## ── 武器（转塔）──────────────────────────────────────────────────────────
## 瞄点 = 从**相机沿准星（屏幕中心）**打一条射线，取与"敌人或地形"的**首个交点**；
## 打不到（对着天）就用射线远端。转塔再朝这个点转（见 scripts/turret.gd）。
## 碰撞层：1 = 场地/世界，2 = 预留给敌人（以后敌人放这一层就会被瞄准，不用改代码）。
const AIM_LAYERS := 1 | 2 | HITBOX_LAYER
## 射线长度（格）：射线本身是无限长的，这里只是"打不到东西时瞄哪儿"的近似远端。
## 要够长 —— 靶子摆在**测试场外圈**（离城镇中心 135 模型单位 = 675 格），
## 准星得能瞄到它们（600 格会半路打在地面上，转塔就一直对着近处的地）。
const AIM_RANGE := 2500.0
## 瞄点标记球半径（格）—— 调武器时能直接看见转塔在对准哪儿。
const AIM_MARKER_RADIUS := 0.12
## 重心显示（按 O 开关）：球 + 一条垂到地面的线 + 地面上的投影点。
## 调驾驶手感时最该看的两个数就是"重心多高、在前后轴之间偏哪儿"。
## 具体形状在 `scripts/com_marker.gd`（建造界面共用同一个）。
## 敌方（靶子）碰撞层：`AIM_LAYERS` 已经包含它，所以准星和子弹都会认。
const ENEMY_LAYER := 2
## 射弹专用层（轮胎那类"只给子弹看"的受击盒，见 `VehicleRig.HITBOX_LAYER`）：
## 加进 `AIM_LAYERS` 之后，子弹和准星射线能打到轮胎，但车/地形谁都不会和它碰撞。
const HITBOX_LAYER := VehicleRig.HITBOX_LAYER
## 开火者标识：玩家车（以后敌人开火就各用各的键，`Projectiles.owner_rids` 里一一对应）。
const PLAYER_KEY := "player"
## 场地里放几台"我方载具的复制品"当靶子（用户要求 4 台，默认为敌方）。
const ENEMY_COUNT := 4
## 靶子摆在**测试场外圈的平地**上（模型单位，1 单位≈1 米）：绕城镇一圈的四个方向。
## 之前按"出生点附近 13~21 单位"放，结果卡进地形/建筑里了（用户报的）——
## 外圈那片是 `OuterGroundMesh` 的大平地，放那儿既平又不会插进房子里，
## 半径还要留在隐形围墙（`ARENA_BOUNDS = 170`）以内。
const ENEMY_RING_RADIUS := 135.0
## 生成高度：抬高一点让它们**落到自己的轮胎上**（和玩家车一样靠悬挂站住）
const ENEMY_SPAWN_LIFT := 1.5

## ── 自定义轮胎：整圈等距射线 ──────────────────────────────────────────────
## 每帧从轮心朝**轮平面里的圆周**打 WHEEL_RAYS 条等距射线（每 22.5° 一条），
## 射线只收集接触，选取最深接触后，每个车轮只施加一次支撑力和轮胎摩擦。
## 这样做的好处是**整圈都能判定**：台阶、路缘、坡脚从任何角度顶到轮胎上，轮子都感觉得到，
## 于是能被顶开/爬上去 —— 原生 VehicleWheel3D 只有一条向下的射线，这些全都感觉不到。
##
## ⚠️ 下面这一整组常量现在只是**默认值**：真正调参请改
## `data/parts/wheel2x2/wheel_axle_2x2.part.txt`（键名 = `wheel_` + 这里的小写名，
## 见 `PartDef` 的"自定义整圈射线轮胎的手感旋钮"一段），测试场按**部件文件**里的值跑。
## 这里改只影响"没写那一行的轮轴"。
const WHEEL_RAYS := 16   # 0 = 纯单射线模式（只留悬挂那条射线 = 最早的单射线手感）
## 射线长度 = 半径 + 这个余量（提前一点点发现台阶边缘）
const WHEEL_RAY_SLACK := 0.04
## 摩擦：先按"速度 × 增益"算目标力，再按 mu × 法向力截断（近似静摩擦，超了就滑）
const WHEEL_GRIP_GAIN := 2500.0
const WHEEL_BRAKE_GAIN := 4000.0
## 滚动阻力（滑行时会慢慢停下；很小，别把最高速压低）
const WHEEL_ROLL_GAIN := 2.0
## 抓地力（库仑摩擦系数 mu）：部件文件里的 `wheel_mu` 优先；写 0 才按
## `wheel_friction × WHEEL_MU_PER_FRICTION` 换算，上限 `WHEEL_MU_MAX`。
## ⚠️ 老版本这里上限是 1.2，所以 `wheel_friction` 调到 20 以上**完全没有效果**
## （5000 × 0.06 = 300 → 被夹到 1.2，这就是"调 friction 像没反应"的原因）。
## 现在上限 5.0（≈ 5 g），想靠 `wheel_friction` 调抓地就换算成 `friction ≈ mu / 0.08`。
const WHEEL_MU_PER_FRICTION := 0.08
const WHEEL_MU_MAX := 5.0
## 轮胎的"滑移衰减"：**横向**滑得越快，可用横向摩擦越小（真轮胎过了峰值就滑）。
## 这样硬拐时先响胎推头、而不是把全部横向力灌进车身把人掀翻。
## ⚠️ 只作用在横向！曾经把"前进滚动速度"也算进滑移里，结果车一超过 12 格/秒
## 抓地力就掉一半 —— 直线也滑、刹车也滑，手感像在冰面上（2026-10-12 修）。
const WHEEL_SLIP_FALLOFF := 0.3
const WHEEL_SLIP_REF := 16.0   # 横向滑移到这个速度时，横向摩擦只剩 (1 - FALLOFF)
## 侧倾稳定器（防翻）。真车靠低重心 + 防倾杆；这台机器人的零件权重是一样的，
## 重心天生偏高，光靠轮胎摩擦硬拐就会打滚（实测 85 格/秒打方向翻车）。
## 做法：**有轮子着地时**，绕车身前后轴加一个"侧倾弹簧 + 阻尼"：
##   弹簧劲度按"车重 × 重心高度 ÷ ANTI_ROLL_MAX_TILT"算 —— 也就是横向 1 g 时车身最多倾这么多；
##   阻尼取 ANTI_ROLL_DAMPING 倍临界阻尼（转动惯量直接读车身自己的 inertia.x）。
## 腾空时不生效（飞出去该翻就翻）。
## 整车共用一份参数：取**第一个轮轴**的 `wheel_anti_roll_tilt`（度）/ `wheel_anti_roll_damping`
## （默认值见下，tilt 写 0 = 关掉防翻）。
const ANTI_ROLL_MAX_TILT := 0.14      # 弧度（= 8°）：横向 1 g 时的侧倾角上限
const ANTI_ROLL_DAMPING := 0.55       # 相对临界阻尼（单一的比值，不再乘别的数）
## 整圈射线里，dir·down 超过阈值的下方扇区交给主射线，避免重复探测平地接触。
const WHEEL_SUS_SECTOR := 0.5   # dir·down > 0.5 → 与"下"夹角 < 60°


## 整圈射线里，"轮子正下方那一扇区"归悬挂那条射线管，整圈这一层要跳过它。
## 判据是 `dir · down`，不能写成 `dir · up`。最终接触仍会合并为每轮一次施力。
static func ring_ray_belongs_to_suspension(dir: Vector3, down: Vector3, sector: float) -> bool:
	return dir.dot(down) > sector


## Godot 单射线车轮的弹簧 + 速度阻尼模型。参数是进场快照，单位为格世界的力。
## 压缩速度 > 0 表示压入接触面；负速度表示回弹。支撑只推不拉。
## 不把弹簧项除以阻尼积分系数，保证静态 F = kx、触底 F = 倍率 × 初始单轮静载。
static func suspension_force(compression: float, compression_speed: float, params: Dictionary) -> float:
	var spring := float(params["stiffness"]) * clampf(compression, 0.0, float(params["travel"]))
	var damper := float(params["damping"]) * compression_speed
	return clampf(spring + damper, 0.0, float(params["max_force"]))


## 判定射线该往哪边挪多少（返回**带符号**的标量，沿轮轴方向）：
## 正数 = 远离底盘中心那一侧（车外），也就是"轮胎最外侧"。用户要求把射线从中缝挪到外侧。
## `wheel_centre` / `chassis_centre` 用同一套坐标（建造坐标或底盘本地都行），`axle` 是轮轴方向。
static func outboard_shift(
	wheel_centre: Vector3, chassis_centre: Vector3, axle: Vector3, offset: float
) -> float:
	var arm := wheel_centre - chassis_centre
	var along := arm.dot(axle.normalized())
	if absf(along) < 0.0001:
		return offset          # 轮子在中心线上（理论情况）：没法判断内外，就按正方向
	return offset if along > 0.0 else -offset


## `outboard_shift()` 给的是"沿**轮轴**的带符号偏移"，而实际施加时沿的是"**轮胎节点的局部 x**"
## （本地 X = 轮胎转轴，见 `_add_wheel` 的节点朝向说明）。左右两侧的挂载是镜像的，
## 节点局部 x 可能和轮轴方向相反 —— 照抄符号会把射线挪到轮胎**里侧**（那就是反效果了）。
## （本地 X = 轮胎转轴，见 `_add_wheel` 的节点朝向说明）。左右两侧的挂载是镜像的，
## 节点局部 x 可能和轮轴方向相反 —— 照抄符号就会把射线挪到轮胎**里侧**。
## 这里按两者的点积翻一次符号。
static func shift_along_local_x(outboard: float, local_x: Vector3, axle: Vector3) -> float:
	var alignment := local_x.normalized().dot(axle.normalized())
	if absf(alignment) < 0.5:
		return 0.0             # 局部 x 和轮轴不平行（理论上不会）：不动，别乱挪
	return outboard if alignment > 0.0 else -outboard

## 传参：{id, name} —— 主界面 / 建造模式在 change_scene 之前塞进来。
static var pending_vehicle := {}

var _library := PartLibrary.new()
var _chassis: RigidBody3D
var _wheels := []          # [{node: Node3D, radius, stiffness, ...}] —— 见 _add_wheel()
var _turrets := []         # [Turret] —— 每个转塔零件一个（见 scripts/turret.gd）
var _player_rig: VehicleRig # 玩家车的车体（零件血量 / 碰撞盒 / 分组视觉）
var _enemies := []         # [VehicleRig] —— 场地里的靶子：**我方载具的复制品**
## 每台车一条：{rig, chassis, wheels, is_player}。轮胎物理对所有车一视同仁 ——
## 玩家车读键盘输入，靶子输入恒为 0（所以它们只是"站得住、推得动"的完整刚体）。
## （`_wheels` 就是玩家那条 `wheels` 数组本身，camera/瞄准/工具都还认它。）
var _vehicles := []
var _vehicles_by_rid := {} # RID -> VehicleRig（子弹打中谁，靠它反查）
var _kills := 0            # 被彻底打光的靶子数
var _last_hit := ""        # 最近一次命中的结算文字（HUD 上显示）
var _projectiles: Projectiles     # 射弹管理（挂在场地根上，子弹不跟车走）
var _energy := 0.0         # 能量池（整车共用；参数写在核心零件里）
var _energy_max := 0.0
var _energy_regen := 0.0
var _shots_fired := 0
var _dry_fires := 0        # 能量不够、没打出去的发数
var _jam_fires := 0        # 枪械压在别的零件上、被自检挡下的发数（见 _update_weapons）
var _muzzle_eaten := 0     # 枪口贴脸就打在自己零件上、当场吃掉的发数（见 _update_weapons）
## 开火自检用的"每个零件的包围盒"（底盘本地坐标，下标 = 零件下标）：
## {box: AABB, name: String}。进场时算一次（见 _collect_clip_boxes）。
var _clip_boxes := []
var _aim_marker: MeshInstance3D   # 瞄点标记（调武器时看转塔在对准哪儿）
## 重心显示（O 键开关）：见 scripts/com_marker.gd（建造界面共用同一个标记）
var _com_marker: ComMarker
var _com_visible := false
var _com_height := 0.0            # 重心离地高度（HUD 用；每帧更新）
var _turret_problem := ""  # 转塔装不上时的原因（显示在 HUD 上）
var _aim_point := Vector3.ZERO
var _aim_hit := false
var _space: PhysicsDirectSpaceState3D  # 整圈射线用的空间状态（每帧取一次）
var _arena_root: Node3D    # 场地根节点：缩放它 = 整体缩放（含碰撞）
var _arena_scale := ARENA_SCALE
var _arena_model: Node3D
var _arena_body: StaticBody3D
var _vehicle: VehicleDef   # 记着当前这台车，改缩放后重新出生用
var _spawn_model_point := Vector3.ZERO   # 出生点（模型坐标系，只算一次）
var _spawn_model_ready := false
var _faces_cache := {}     # 网格 id -> PackedVector3Array（找出生点时反复用）
var _last_nudge_ms := 0    # 按住方向键连发时的节流（和机库同一套手感）
var _cam_center_local := Vector3.ZERO   # 环视中心用的重心（底盘本地坐标）
var _cam_box_local := AABB()            # 整车（含轮胎）在底盘本地坐标里的包围盒
var _camera: Camera3D
var _hud: Label
var _speedo: Label      # 左上角速度表（每帧刷，和 0.25 秒刷一次的 HUD 分开）
var _status := ""
var _spawn_center := Vector3.ZERO
var _hud_timer := 0.0
var _render_info := ""
var _built := false
var _camera_yaw := 0.0     # 相对车头的水平偏移（度）
var _camera_pitch := -12.0 # 俯仰（度），正数向上
var _camera_distance := CAMERA_DISTANCE
## 镜头是否**跟着车头转**（设置里的开关，见 GameSettings.camera_follow）：
## 两种模式下鼠标都能自由环视，区别只在"鼠标转的是哪种角度"：
##   开 = `_camera_yaw` 是**相对车头的偏移** → 车一转向，画面跟着转（车头始终在正前方）；
##   关 = `_camera_yaw` 是**世界坐标系里的绝对朝向** → 车原地打转时画面一动不动（鼠标照样能环视），
##        想让车回到画面正前方得自己用鼠标找。
var _camera_follow := true
var _crosshair: Control


func _ready() -> void:
	# 只建一次：脚本被重复 ready（编辑器/重载）时不能把场地和车再建一遍 ——
	# 重复建的表现就是 draw / 图元成倍上涨、帧率断崖。
	if _built:
		return
	_built = true
	# 测试场里不放大厅那首循环音乐 —— 这里该听的是引擎声和枪声
	GameSettings.stop_music()
	ensure_actions()
	_library.load_all()
	_collect_render_info()
	_build_arena()
	_build_camera()
	_build_hud()
	# 镜头跟不跟车头转：设置里的开关（读一次就够 —— 设置界面不在测试场里）
	_camera_follow = GameSettings.camera_follow()
	enter_vehicle(str(pending_vehicle.get("id", "")))


## 把"当前用哪块显卡、走哪条渲染路径、窗口多大"记下来 ——
## 卡到 2 FPS 时这几个字就是判据：出现 Basic Render Driver / WARP 就是软件渲染。
func _collect_render_info() -> void:
	var adapter := RenderingServer.get_video_adapter_name()
	var api := RenderingServer.get_video_adapter_api_version()
	var size := DisplayServer.window_get_size()
	_render_info = "%s | %s / %s | %dx%d" % [
		adapter,
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_current_rendering_driver_name(),
		size.x,
		size.y,
	]
	print("[测试场] 渲染：%s（API %s）" % [_render_info, api])


## 把驾驶动作注册进 InputMap（已经在项目设置里就不动它）。
static func ensure_actions() -> void:
	for action in DRIVE_ACTIONS.keys():
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		if not InputMap.action_get_events(action).is_empty():
			continue   # 已经绑过就别再加一遍（重复绑定会让"按住"被算成多次）
		var key := InputEventKey.new()
		key.keycode = DRIVE_ACTIONS[action]
		InputMap.action_add_event(action, key)
	# 开火：空格 + 鼠标左键（枪口指向靠鼠标环视，所以左键顺手）
	if not InputMap.has_action(FIRE_ACTION):
		InputMap.add_action(FIRE_ACTION)
	if InputMap.action_get_events(FIRE_ACTION).is_empty():
		var fire_key := InputEventKey.new()
		fire_key.keycode = FIRE_KEY
		InputMap.action_add_event(FIRE_ACTION, fire_key)
		var fire_mouse := InputEventMouseButton.new()
		fire_mouse.button_index = MOUSE_BUTTON_LEFT
		InputMap.action_add_event(FIRE_ACTION, fire_mouse)


## 把某辆载具摆进测试场。前置条件不满足就只显示原因（不摆车）。
func enter_vehicle(vehicle_id: String) -> bool:
	# 换车先清掉旧车，避免叠加
	if _chassis != null and is_instance_valid(_chassis):
		_chassis.queue_free()
	_chassis = null
	# 靶子的根节点不是底盘的子节点，得自己清（不然重进一次就多 4 台）
	for rig in _enemies:
		if rig.host != null and is_instance_valid(rig.host):
			rig.host.queue_free()
	_wheels.clear()
	_com_marker = null        # 重心标记是底盘的子节点，跟着旧底盘一起没了
	_com_visible = false
	_vehicles.clear()
	_turrets.clear()
	_enemies.clear()
	_vehicles_by_rid.clear()
	_kills = 0
	_last_hit = ""
	_shots_fired = 0
	_dry_fires = 0
	_jam_fires = 0
	_muzzle_eaten = 0
	if vehicle_id.is_empty():
		_status = "没有指定载具"
		_update_hud()
		return false
	var path := "%s/%s.vehicle.txt" % [VEHICLE_DIR, vehicle_id]
	if not FileAccess.file_exists(path):
		_status = "找不到 %s" % path
		_update_hud()
		return false
	var vehicle := VehicleDef.from_text(FileAccess.get_file_as_string(path), path)
	# 前置条件：装了核心，而且所有零件都和核心连通（测试场只放合法整机）
	var check := BuildGrid.new()
	check.set_defs(_library.defs)
	var shift := BuildGrid.fit_shift(vehicle.parts, _library.defs)
	for part in vehicle.parts:
		var def: PartDef = _library.get_def(part["part_id"])
		if def != null:
			check.place(def, part["cell"] + shift, part["basis"])
	var robot := check.robot_status()
	if not bool(robot.get("ok", false)):
		_status = "进不了测试场：%s" % str(robot.get("reason", ""))
		_update_hud()
		return false
	_spawn(vehicle)
	_status = (
		"开车：W/S 油门·反向（先自动刹车）· A/D 转向 · 空格/左键 开火（打准星瞄点）\n"
		+ "鼠标环视瞄准 · 滚轮变焦 · [ ] 缩放场地 · O 显示重心 · ESC 回主界面\n"
		+ "↑↓←→ 推车、< > 升降（找出生点用）"
	)
	_update_hud()
	return true


func _spawn(vehicle: VehicleDef) -> void:
	_vehicle = vehicle
	# 载具坐标先平移到"**真实**包围盒中心 = 底盘原点"，底盘再摆到出生点。
	# ⚠️ 必须用 `actual_bounds()`（网格包围盒，含轮胎那种挂在盒子外面的附属子模型）——
	# 用 `bounds()`（声明 cubes 盒子）会让"车底"算高一截，出生时半个轮胎埋进地里（用户报的）。
	var actual := vehicle.actual_bounds(_library)
	_spawn_center = actual.get_center()
	# 底盘就是个刚体：轮胎的力由我们自己的整圈射线模型算（`_apply_wheel()`），
	# 不再用 VehicleBody3D + VehicleWheel3D 那套（它每个轮子只有一条竖直射线）。
	_chassis = RigidBody3D.new()
	_chassis.name = "Chassis"
	# 悬挂是每帧自己施力的：刚体一旦睡着就不再受力，车会"僵"在原地 —— 别让它睡
	_chassis.can_sleep = false
	# 出生点：在场地模型上竖着探一条线，落在那里最上面的路面/地面上；车头朝 +x
	_chassis.transform = Transform3D(Basis(), _chassis_spawn_point(actual))
	print("[测试场] 出生点 %s（场地缩放 ×%.2f）" % [_chassis.transform.origin, _arena_scale])
	_chassis.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	# 层 1 = 世界/车体（对地形碰撞）；掩码里加上层 2，这样还能撞到当靶子的敌方复制品
	_chassis.collision_layer = 1
	_chassis.collision_mask = 1 | ENEMY_LAYER
	add_child(_chassis)

	# 车体 = VehicleRig：**一个零件一个碰撞盒**（下标 = 零件下标，射线打回来就知道打中了谁）
	# + 按 (部件, 路线) 分组的视觉。转塔零件在玩家车上由 Turret 节点画，这里跳过。
	_player_rig = VehicleRig.new()
	_player_rig.static_skip_weapon = true
	_player_rig.label_text = "我方"
	_player_rig.setup(vehicle, _library, _chassis, _chassis, true, -_spawn_center)
	_cam_box_local = _player_rig.bounds_local()
	_cam_center_local = _chassis.center_of_mass
	_clip_boxes = _collect_clip_boxes(_player_rig, vehicle)
	_vehicles_by_rid[_chassis.get_rid()] = _player_rig
	if _player_rig.hitboxes != null:
		# 轮胎那种"只给子弹看"的受击盒是独立 body：也登记到这台车上，
		# 打中轮胎的伤害照样算在这个轮轴上
		_vehicles_by_rid[_player_rig.hitboxes.get_rid()] = _player_rig
	# 转塔零件：网格由 Turret 节点画（支架/枪管要转），带上零件下标（零件被打掉时好清理）
	var weapon_parts := []
	for i in vehicle.parts.size():
		var wdef: PartDef = _library.get_def(str(vehicle.parts[i]["part_id"]))
		if wdef != null and wdef.weapon == "turret":
			weapon_parts.append([wdef, i])
	# 轮子：每个轮轴一个自定义轮胎节点（轮胎网格挂它下面，整圈射线在 _apply_wheel 里算）。
	# 玩家车也是一条普通 `_vehicles` 记录 —— 靶子走同一套轮胎物理（用户要求"完整物理行为"）。
	var player_entry := {
		"rig": _player_rig, "chassis": _chassis, "wheels": [], "is_player": true,
	}
	_vehicles.append(player_entry)
	_wheels = player_entry["wheels"]
	var specs := vehicle.wheel_specs(_library)
	_initialize_vehicle_wheels(player_entry, specs)
	# 武器：每个转塔一个节点组（底座固定 / 支架水平 / 枪管俯仰），每帧朝准星瞄点转
	for pair in weapon_parts:
		var wplace := BuildGrid.cell_transform(
			pair[0], vehicle.parts[pair[1]]["cell"], vehicle.parts[pair[1]]["basis"]
		)
		wplace.origin -= _spawn_center
		var turret := Turret.new()
		_chassis.add_child(turret)
		var problem: String = turret.setup(pair[0], wplace, _library)
		if not problem.is_empty():
			_turret_problem = "%s：%s" % [str(pair[0].id), problem]
			push_warning("测试场：转塔 %s —— %s" % [str(pair[0].id), problem])
		turret.set_meta("part_index", int(pair[1]))
		_turrets.append(turret)
	# 瞄点标记（调武器时直接看转塔在瞄哪儿）
	if not _turrets.is_empty():
		_build_aim_marker()
		_refresh_turret_arcs()     # 真实射界：一进场就算一次（零件打掉之后再算）
	# 能量池 + 射弹管理
	var core_energy := _core_energy(vehicle)
	_energy_max = core_energy.x
	_energy_regen = core_energy.y
	_energy = _energy_max
	_projectiles = Projectiles.new()
	_projectiles.name = "Projectiles"
	add_child(_projectiles)     # 挂在**场地根**上（世界系）：子弹不能跟着车走
	_projectiles.gravity = _world_gravity()
	_projectiles.layers = AIM_LAYERS
	_projectiles.owner_rids[PLAYER_KEY] = _chassis.get_rid()
	_projectiles.hit.connect(_on_projectile_hit)
	# 靶子：**我方这台车的复制品**（同零件、同摆放、同血量规则），默认为敌方
	_spawn_enemy_replicas(vehicle)
	# 轮胎也算进"整车最高点"（虽然一般比车身低，但先算全了免得漏）
	for entry in _wheels:
		var wheel: Node3D = entry["node"]
		var radius: float = entry["radius"]
		_cam_box_local = _cam_box_local.merge(
			AABB(wheel.position - Vector3(radius, radius, radius), Vector3(radius, radius, radius) * 2.0)
		)
	_update_hud()


## 世界重力（格/秒²）：`project.godot` 里写的就是 `PartDef.GRAVITY_CUBES`
## （= 真实 9.8 ÷ CUBE_METERS 米/格）。改标定的时候两处必须一起改，测试守着这条。
func _world_gravity() -> float:
	return float(
		ProjectSettings.get_setting("physics/3d/default_gravity", PartDef.GRAVITY_CUBES)
	)


## 整车能量池（x = 上限，y = 每秒恢复）：只有**核心**零件提供（写在核心的部件文件里）。
func _core_energy(vehicle: VehicleDef) -> Vector2:
	for part in vehicle.parts:
		var def: PartDef = _library.get_def(str(part["part_id"]))
		if def != null and def.is_core:
			return Vector2(def.energy_max, def.energy_regen)
	return Vector2.ZERO


## ── 靶子：我方载具的**复制品** ──────────────────────────────────────────────
## 用户要求：测试场外圈的平地上放 4 台"进入测试场那台车"的复制品，默认为敌方，用来测毁伤；
## 而且它们要有**完整的物理碰撞与物理行为**（不是插在地上的静态道具）。
##
## 所以每台靶子 = 一个 `RigidBody3D` 底盘 + 自己的**整套轮胎物理**（`_add_wheel` /
## `_drive_vehicle`，和玩家车同一套代码）+ `VehicleRig`（零件血量 / 碰撞盒 / 分组视觉，
## 连**轮体子模型**都会一起生成 —— 之前只画了轮轴本体，看着就是"子零件没加载全"）。
## 位置：绕城镇中心一圈半径 `ENEMY_RING_RADIUS`（模型单位）的**外圈平地**上，
## 车头朝向玩家出生点；出生时抬高一点，让它们自己落到轮胎上站住。
func _spawn_enemy_replicas(vehicle: VehicleDef) -> void:
	if _arena_model == null or vehicle.parts.is_empty():
		return
	var town_centre := ARENA_SPAWN_AREA.get_center()
	var specs := vehicle.wheel_specs(_library)
	for i in ENEMY_COUNT:
		var angle := TAU * float(i) / float(ENEMY_COUNT)
		var model_point := Vector2(
			town_centre.x + cos(angle) * ENEMY_RING_RADIUS,
			town_centre.y + sin(angle) * ENEMY_RING_RADIUS
		)
		# 外圈那片是 OuterGroundMesh 的大平地（平、没房子）；探不到就退回任意网格
		var height := _mesh_height_at(model_point.x, model_point.y, "OuterGroundMesh")
		if not is_finite(height):
			height = _mesh_height_at(model_point.x, model_point.y, "")
		if not is_finite(height):
			push_warning("测试场：靶子 %d 那个位置探不到地面，跳过" % i)
			continue
		var chassis := RigidBody3D.new()
		chassis.name = "TargetChassis%d" % i
		chassis.can_sleep = false          # 轮胎力是每帧自己施的，别让它睡
		chassis.collision_layer = ENEMY_LAYER
		# 掩码：撞地形(1)、撞彼此(2)、被玩家车撞(玩家车掩码里也有 2)
		chassis.collision_mask = 1 | ENEMY_LAYER
		chassis.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		add_child(chassis)
		var rig := VehicleRig.new()
		rig.label_text = "靶子%d" % i
		rig.setup(vehicle, _library, chassis, chassis, true, -_spawn_center)
		# 摆到外圈：抬高一点扔下去，轮胎悬挂会接住（和玩家车一个玩法）。
		# 用 `geometry_bounds_local()`（本体盒 ∪ 轮胎盒），不然"车底"算高一截、轮胎陷进地里。
		var bounds := rig.geometry_bounds_local()
		chassis.global_position = Vector3(
			model_point.x * _arena_scale,
			height * _arena_scale - bounds.position.y + ENEMY_SPAWN_LIFT,
			model_point.y * _arena_scale
		)
		var to_spawn := _chassis.global_position - chassis.global_position
		chassis.global_rotation = Vector3(0.0, atan2(-to_spawn.z, to_spawn.x), 0.0)
		var entry := {"rig": rig, "chassis": chassis, "wheels": [], "is_player": false}
		_vehicles.append(entry)
		_initialize_vehicle_wheels(entry, specs)
		_enemies.append(rig)
		_vehicles_by_rid[chassis.get_rid()] = rig
		if rig.hitboxes != null:
			_vehicles_by_rid[rig.hitboxes.get_rid()] = rig
	print("[测试场] 放了 %d 台靶子（我方载具的复制品，带完整轮胎物理）" % _enemies.size())


## ── 毁伤：子弹打中别人的车 ─────────────────────────────────────────────────
## `shape_index` 就是**零件下标**（VehicleRig 一个零件一个碰撞盒、只禁用不删除）。
## 自己的车体在 Projectiles 里就已经被"吃掉"了，不会走到这里。
func _on_projectile_hit(
	body_rid: RID, shape_index: int, _position: Vector3, damage: float, owner_key: String
) -> void:
	var rig: VehicleRig = _vehicles_by_rid.get(body_rid)
	if rig == null:
		return                       # 地形之类：火花已经放过了，这里没事可做
	if rig == _player_rig and owner_key == PLAYER_KEY:
		return                       # 兜底：打自己（Projectiles 那边已经处理）
	# 打中的可能是车体上的本体盒，也可能是"只给子弹看"的轮胎受击盒 —— 各查各的表
	var part := rig.part_index_of_hit(body_rid, shape_index)
	if part < 0 or not rig.part_alive(part):
		return
	var result := rig.apply_damage(part, damage)
	if not bool(result["mass_changed"]):
		_last_hit = "%s 零件 %d 掉了 %.0f 血" % [rig.label(), part, damage]
		return
	var dead := []
	dead.append_array(result["destroyed"])
	dead.append_array(result["detached"])
	_last_hit = "%s 打掉 %d 个零件（溢流 %d）" % [
		rig.label(), dead.size(), int(result["destroyed"].size())
	]
	_on_parts_destroyed(rig, dead)


## 零件被消灭之后，挂在这些零件上的东西要一起清掉：
## 轮胎（整圈射线那套）和转塔节点。玩家车和靶子走同一条路。
func _on_parts_destroyed(rig: VehicleRig, dead: Array) -> void:
	var dead_set := {}
	for index in dead:
		dead_set[int(index)] = true
	# 轮胎：按**这台车**自己的记录删（玩家车 / 靶子一视同仁；`_wheels` 就是玩家那条数组本身）
	for veh in _vehicles:
		if veh["rig"] != rig:
			continue
		var wheels: Array = veh["wheels"]
		for i in range(wheels.size() - 1, -1, -1):
			if not dead_set.has(int(wheels[i]["part_index"])):
				continue
			var wheel_node: Node3D = wheels[i]["node"]
			if wheel_node != null and is_instance_valid(wheel_node):
				wheel_node.queue_free()
			wheels.remove_at(i)
	if rig == _player_rig:
		var turrets_left := []
		for turret in _turrets:
			if dead_set.has(int(turret.get_meta("part_index", -1))):
				if is_instance_valid(turret):
					turret.queue_free()
				continue
			turrets_left.append(turret)
		_turrets = turrets_left
		if _turrets.is_empty() and _aim_marker != null and is_instance_valid(_aim_marker):
			_aim_marker.visible = false
		_cam_box_local = rig.bounds_local()
		# 零件掉了之后体积盒也变了：**真实射界重新算**（打掉挡枪管的零件 → 射界变大）
		_clip_boxes = _collect_clip_boxes(rig, _vehicle)
		_refresh_turret_arcs()
	if rig.state.alive_count() == 0:
		_kills += 1


## 玩家与靶子共用的进场初始化。毁伤只移除车轮，不能重新分摊负载或改动幸存轮参数。
func _initialize_vehicle_wheels(veh: Dictionary, specs: Array) -> void:
	if veh.has("initial_mass"):
		return
	var chassis: RigidBody3D = veh["chassis"]
	veh["initial_mass"] = chassis.mass
	veh["initial_wheel_count"] = specs.size()
	veh["initial_gravity"] = _world_gravity() * chassis.gravity_scale
	for spec in specs:
		_add_wheel(veh, spec)


## 一个轮轴 → 一个自定义轮胎节点：节点放在轮胎几何中心，轮胎网格作为子节点
## （轮胎的转动是我们自己贴的，见 `_spin_tire()`）。
##
## 节点朝向：绕世界 UP 转到"轮轴 = 零件本地 x"上，于是
##   本地 X = 轮胎转轴（径向射线的圆心轴）· 本地 Y/Z 张成轮平面（16 条射线在这个平面里）
## 转向就是把整个节点绕**底盘的上方向**再转一个角度（`_steer_wheel()`）。
##
## **判定射线的侧向位置**（`wheel_ray_offset`）：射线默认打在轮胎的**中缝**平面上，
## 写 `wheel_ray_offset = 0.4` 这种正值就把整套射线沿轴向**往外侧**挪（0.4 ≈ 这张轮胎
## 0.81 格宽的一半 = 外侧面）。挪的是**射线**，轮胎网格和轮心不动。
func _add_wheel(veh: Dictionary, spec: Dictionary) -> void:
	var chassis: RigidBody3D = veh["chassis"]
	var place: Transform3D = spec["transform"]
	var offset: Vector3 = (spec["offset"] as Vector3) - _spawn_center
	# 轮胎的转轴 = 零件本地的 x（轮轴那根轴）。节点绕世界 UP 转到这个轴上。
	var axis: Vector3 = (place.basis * Vector3(1, 0, 0)).normalized()
	if absf(axis.y) > 0.5:
		push_warning("测试场：轮子的轴不是水平的（%s），悬挂方向会不对" % str(axis))
	var yaw := atan2(-axis.z, axis.x)
	if (Basis(Vector3.UP, yaw) * Vector3(0, 0, -1)).dot(Vector3.RIGHT) > 0.0:
		yaw += PI
	var node_basis := Basis(Vector3.UP, yaw)
	# 动力 / 悬挂参数全部从**这个轮轴自己的部件文件**读（每个轮轴可以不一样）
	var def: PartDef = _library.get_def(str(spec["part_id"]))
	var radius := float(spec["radius"])
	if def != null and def.wheel_radius > 0.0:
		radius = def.wheel_radius
	radius = maxf(0.2, radius)
	# 判定射线的侧向偏移：正数 = 沿轮胎轴向**往车外挪**，0 = 轮胎中缝（老行为）。
	# 挪的是射线本身（轮胎网格和轮心不动），所以"贴路缘时咬合的位置"会从轮胎中缝挪到外侧面。
	var ray_shift := 0.0
	if def != null and def.wheel_ray_offset > 0.0:
		ray_shift = shift_along_local_x(
			outboard_shift(offset + _spawn_center, _spawn_center, axis, def.wheel_ray_offset),
			node_basis * Vector3(1.0, 0.0, 0.0),
			axis
		)
	# 只在进场时按这台车的初始质量、轮数计算。刚体质量日后可以变，参数快照不变。
	var suspension_def := def if def != null else PartDef.new()
	var sus := suspension_def.resolved_suspension(
		float(veh["initial_mass"]), int(veh["initial_wheel_count"]), float(veh["initial_gravity"])
	)
	var rest := float(sus["rest"])
	var travel := float(sus["travel"])
	var static_compression := float(sus["static_compression"])
	var mu := 1.0
	# 手感旋钮：默认取模块常量，部件文件里写了就用文件里的（每个轮轴可以不一样）
	var grip_gain := WHEEL_GRIP_GAIN
	var brake_gain := WHEEL_BRAKE_GAIN
	var roll_gain := WHEEL_ROLL_GAIN
	var slip_falloff := WHEEL_SLIP_FALLOFF
	var slip_ref := WHEEL_SLIP_REF
	var rays := WHEEL_RAYS
	var ray_slack := WHEEL_RAY_SLACK
	var sus_sector := WHEEL_SUS_SECTOR
	var anti_roll_tilt := ANTI_ROLL_MAX_TILT
	var anti_roll_damping := ANTI_ROLL_DAMPING
	if def != null:
		# 抓地力：`wheel_mu` 直接给就优先用它，否则按 `wheel_friction` 换算（上限 `wheel_mu_max`）。
		# 下限 0.05 只是防止"写了 0 摩擦 → 轮子完全不抓地、车停在原地漂"，不是手感钳制。
		mu = maxf(0.05, def.resolved_wheel_mu())
		grip_gain = def.wheel_grip_gain
		brake_gain = def.wheel_brake_gain
		roll_gain = def.wheel_roll_gain
		slip_falloff = def.wheel_slip_falloff
		slip_ref = maxf(0.01, def.wheel_slip_ref)
		# rays = 0 = **纯单射线模式**（整圈射线全关，只剩悬挂那条）—— 想 A/B "单射线手感"就写 0
		rays = maxi(0, def.wheel_rays)
		ray_slack = def.wheel_ray_slack
		sus_sector = def.wheel_sus_sector
		anti_roll_tilt = deg_to_rad(def.wheel_anti_roll_tilt_deg)   # 文件里写的是度
		anti_roll_damping = def.wheel_anti_roll_damping
	# 硬点按自由长度减静态压缩量摆放，保留建造时的轮心高度。
	var hub: Vector3 = offset + Vector3(0.0, 1.0, 0.0) * (rest - static_compression)
	var wheel := Node3D.new()
	wheel.name = "Wheel%d" % (veh["wheels"] as Array).size()
	wheel.transform = Transform3D(
		node_basis, hub + Vector3(0.0, -1.0, 0.0) * (rest - static_compression)
	)
	chassis.add_child(wheel)   # 挂在**这一台车**的底盘下（靶子也一样）
	# 轮胎网格：顶点在"零件本地坐标系"里，所以子节点的变换要把零件坐标系搬过来
	var local_centre: Vector3 = spec["local_centre"]
	var child_basis := node_basis.inverse() * place.basis
	var mesh_node := MeshInstance3D.new()
	mesh_node.name = "Tire"
	var build := _library.build_sub(str(spec["part_id"]))
	if build.get("mesh") != null:
		mesh_node.mesh = build["mesh"]
		mesh_node.material_override = build["material"]
		mesh_node.transform = Transform3D(child_basis, -(child_basis * local_centre))
		mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		wheel.add_child(mesh_node)
	(veh["wheels"] as Array).append({
		"node": wheel,
		"base_basis": node_basis,     # 转向 = 这个朝向再绕底盘上方向转一个角
		# 轮胎视觉滚动用的家当：网格（绕轮子本地 x 转，轴心 = 轮胎几何中心 local_centre）、
		# 零件本地 x 映射到轮子节点的 ±x（自己转轮胎时要用这个符号，否则前进时倒着滚）
		"mesh": mesh_node if mesh_node.mesh != null else null,
		"child_basis": child_basis,
		"local_centre": local_centre,
		"radius": radius,
		"spin": 0.0,
		# 全轮转向：重心之前的轮子正转、之后的轮子反转
		"steer_sign": float(spec.get("steer_sign", 1.0)),
		"steer": 0.0,                 # 当前转角（弧度，带 steer_sign 的符号）
		"hub": hub,                   # 悬挂硬点（底盘本地坐标）
		"offset": offset,             # 作者摆的轮胎中心（静止位置）
		"suspension": rest - static_compression,  # 当前悬挂长度（硬点 → 轮心），每帧更新
		# 整圈射线的轮胎参数
		"stiffness": float(sus["stiffness"]),
		"rest": rest,
		"travel": travel,
		"max_force": float(sus["max_force"]),
		# 单轮初始分摊质量，毁伤后保持不变。
		"corner_mass": float(sus["corner_mass"]),
		"static_compression": static_compression,
		# ── 轮胎力模型（Pacejka，移植自 nani_raycast_wheel.gd，MIT）──
		"grip_factor": def.wheel_grip_factor if def != null else 1.0,
		"lat_pacejka": (def.wheel_lat_pacejka if def != null else [1.0, 10.0, 0.0, 1.35]),
		"long_pacejka": (def.wheel_long_pacejka if def != null else [1.0, 10.0, 0.0, 1.65]),
		"damping": float(sus["damping"]),   # c = 2√(k × 初始单轮质量)
		"mu": mu,                     # 库仑摩擦系数
		# 整圈射线的形状 / 摩擦手感（全部来自部件文件，见 _add_wheel 开头）
		"grip_gain": grip_gain,       # 横向抓地增益（速度 × 增益 = 力）
		"brake_gain": brake_gain,
		"roll_gain": roll_gain,       # 滚动阻力
		"slip_falloff": slip_falloff, # 横向滑移掉多少摩擦（只作用横向！）
		"slip_ref": slip_ref,
		"rays": rays,                 # 整圈射线条数
		"ray_slack": ray_slack,
		"sus_sector": sus_sector,
		# 判定射线的侧向偏移（沿轮胎轴向，正 = 车外）：见 _add_wheel 与 outboard_shift()
		"ray_shift": ray_shift,
		# 防翻是整车效应，_apply_anti_roll() 取**第一个轮轴**的这两个值
		"anti_roll_tilt": anti_roll_tilt,
		"anti_roll_damping": anti_roll_damping,
		# 每帧要用的动力参数先抄下来（别每帧查部件表）
		"part_index": int(spec.get("part_index", -1)),   # 毁伤：轮轴被打掉 → 轮胎一起没
		"engine_force": def.wheel_engine_force if def != null else 90.0,
		"brake": def.wheel_brake if def != null else 60.0,
		# 部件文件写的是**真实 m/s**，内部速度是"格/秒"：换算在 PartDef 里做一次
		"max_speed": def.wheel_max_speed_cubes() if def != null else 70.0,
		"steer_max": deg_to_rad(def.wheel_steer_max) if def != null else deg_to_rad(24.0),
		# 转向角速度（弧度/秒）：车轮朝目标转角靠拢的速度，写在部件文件里
		"steer_speed": deg_to_rad(def.wheel_steer_speed) if def != null else deg_to_rad(90.0),
		# **回正**角速度（弧度/秒）：松开方向键后转角回中位的速度（可与打方向不同速）
		"steer_return_speed": (
			deg_to_rad(def.resolved_steer_return_speed()) if def != null else deg_to_rad(90.0)
		),
	})


func _build_arena() -> void:
	# 光照 / 环境：和车库一套
	var env := WorldEnvironment.new()
	env.environment = VehicleViewer.make_garage_environment()
	add_child(env)
	var sun := VehicleViewer.make_garage_sun()
	# 场地比车库大得多，而且一直在动：阴影图每帧重画，先关掉（见 SHADOWS）。
	sun.shadow_enabled = SHADOWS
	if SHADOWS:
		sun.directional_shadow_max_distance = 45.0
		sun.shadow_blur = 1.5
	add_child(sun)
	# 整块现成场地：Truck Town 的城镇 + 赛道（一个 gltf 就是完整场景）
	_arena_root = Node3D.new()
	_arena_root.name = "Arena"
	_arena_root.scale = Vector3.ONE * _arena_scale
	add_child(_arena_root)
	var packed: PackedScene = load(ARENA_SCENE)
	if packed == null:
		push_error("测试场：载入不了场地模型 %s" % ARENA_SCENE)
	else:
		_arena_model = packed.instantiate() as Node3D
		_arena_model.name = "Town"
		_arena_root.add_child(_arena_model)
	_add_arena_physics()
	print("[测试场] 场地：%s，缩放 ×%.2f，网格 %d 个，trimesh 碰撞 %d 个，边长约 %.0f 米" % [
		ARENA_SCENE.get_file(), _arena_scale, _mesh_count(_arena_model),
		_count_nodes_of("CollisionShape3D"), _arena_extent() * _arena_scale,
	])


## 场地的物理：直接拿模型网格做 trimesh（房子、坡道、赛道、地面全都有），
## 再加一圈隐形围墙把可开区域围住。整套都挂在 `_arena_root` 下 —— **缩放根节点就整体缩放**，
## 碰撞会跟着一起缩放，所以按 `[` `]` 调倍数不用重建。
func _add_arena_physics() -> void:
	_arena_body = StaticBody3D.new()
	_arena_body.name = "ArenaBody"
	_arena_body.collision_layer = 1
	_arena_root.add_child(_arena_body)
	if _arena_model != null:
		var stack: Array = [_arena_model]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
				var mesh_node: MeshInstance3D = node
				var shape := CollisionShape3D.new()
				shape.shape = mesh_node.mesh.create_trimesh_shape()
				shape.transform = _relative_transform(mesh_node, _arena_root)
				_arena_body.add_child(shape)
			for child in node.get_children():
				stack.append(child)
	var height := 40.0
	var thickness := 4.0
	var sides := [
		[Vector3(0.0, 0.0, -ARENA_BOUNDS - thickness * 0.5), Vector3(ARENA_BOUNDS * 2.0, height, thickness)],
		[Vector3(0.0, 0.0, ARENA_BOUNDS + thickness * 0.5), Vector3(ARENA_BOUNDS * 2.0, height, thickness)],
		[Vector3(-ARENA_BOUNDS - thickness * 0.5, 0.0, 0.0), Vector3(thickness, height, ARENA_BOUNDS * 2.0)],
		[Vector3(ARENA_BOUNDS + thickness * 0.5, 0.0, 0.0), Vector3(thickness, height, ARENA_BOUNDS * 2.0)],
	]
	for side in sides:
		var size: Vector3 = side[1]
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = size
		shape.shape = box
		shape.transform = Transform3D(Basis(), side[0] + Vector3(0.0, height * 0.5, 0.0))
		_arena_body.add_child(shape)


## `node` 相对 `ancestor` 的变换（模型里的网格节点可能嵌好几层）
func _relative_transform(node: Node3D, ancestor: Node) -> Transform3D:
	var result := Transform3D()
	var current: Node = node
	while current != null and current != ancestor:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


## 出生点（世界坐标）：在城镇范围内撒一圈候选点，按"先马路、再赛道、最后地面"的优先级，
## 在**指定的那几类网格**上竖着探高度，取最低的一个（最平、最不会卡住的地方）。
## 结果在模型坐标系里只算一次并缓存 —— 换缩放不用重算。
func _arena_spawn_point() -> Vector3:
	if not _spawn_model_ready:
		_spawn_model_point = _find_spawn_in_model()
		_spawn_model_ready = true
	return _spawn_model_point * _arena_scale + Vector3(0.0, SPAWN_HEIGHT, 0.0)


## 底盘摆哪儿：把载具的**最低点**抬到"地面 + SPAWN_HEIGHT"，而不是把底盘原点摆上去。
##
## 底盘原点 = 真实包围盒中心（见 `_spawn`），所以最低点在底盘坐标里是
## `actual.position.y - _spawn_center.y`（负的、比"半个盒子高"更低）—— 减去它就对了。
## 用户报的"进游戏车卡在地下"就是这里：以前没算这一截（轮胎挂在盒子外面）。
func _chassis_spawn_point(actual: AABB) -> Vector3:
	var point := _arena_spawn_point()
	point.y += _spawn_center.y - actual.position.y
	return point


func _find_spawn_in_model() -> Vector3:
	# 手填了就用手的（见 ARENA_SPAWN_MODEL），否则自动在马路/赛道/地面上撒点找最低的一个
	if ARENA_SPAWN_MODEL != Vector3.ZERO:
		print("[测试场] 出生点用手填的模型坐标 %s" % ARENA_SPAWN_MODEL)
		return ARENA_SPAWN_MODEL
	for surface in ARENA_SPAWN_SURFACES:
		var best := INF
		var found := false
		var point := Vector2.ZERO
		for i in ARENA_SPAWN_STEPS:
			for j in ARENA_SPAWN_STEPS:
				var candidate := Vector2(
					ARENA_SPAWN_AREA.position.x
						+ ARENA_SPAWN_AREA.size.x * (float(i) + 0.5) / float(ARENA_SPAWN_STEPS),
					ARENA_SPAWN_AREA.position.y
						+ ARENA_SPAWN_AREA.size.y * (float(j) + 0.5) / float(ARENA_SPAWN_STEPS)
				)
				var height := _mesh_height_at(candidate.x, candidate.y, str(surface))
				if is_finite(height) and height < best:
					best = height
					point = candidate
					found = true
		if found:
			print("[测试场] 出生点按 %s 找到：模型坐标 %s 高度 %.2f" % [surface, point, best])
			return Vector3(point.x, best, point.y)
	# 什么都没探到：退到城镇范围中心上方，让车自己落地
	return Vector3(ARENA_SPAWN_AREA.get_center().x, 20.0, ARENA_SPAWN_AREA.get_center().y)


## 模型本地空间里，(x, z) 处**指定网格**（名字包含 `surface`）上最上面的面高度；没有就 -INF。
func _mesh_height_at(x: float, z: float, surface := "") -> float:
	if _arena_model == null:
		return -INF
	var best := -INF
	var stack: Array = [_arena_model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var mesh_node: MeshInstance3D = node
			if surface.is_empty() or mesh_node.name.contains(surface):
				var to_model := _relative_transform(mesh_node, _arena_model)
				var faces: PackedVector3Array = _mesh_faces(mesh_node)
				var i := 0
				while i + 2 < faces.size():
					var y := _triangle_height_at(
						to_model * faces[i], to_model * faces[i + 1], to_model * faces[i + 2], x, z
					)
					if is_finite(y) and y > best:
						best = y
					i += 3
		for child in node.get_children():
			stack.append(child)
	return best


## 网格的三角面（三角面数组挺大，缓存起来 —— 撒点找出生点会反复查同一批网格）
func _mesh_faces(mesh_node: MeshInstance3D) -> PackedVector3Array:
	var key := mesh_node.get_instance_id()
	if not _faces_cache.has(key):
		_faces_cache[key] = mesh_node.mesh.get_faces()
	return _faces_cache[key]


## 竖直射线 (x, z) 打在三角形上的高度（打不到返回 NAN）
func _triangle_height_at(a: Vector3, b: Vector3, c: Vector3, x: float, z: float) -> float:
	var d1 := (x - b.x) * (a.z - b.z) - (a.x - b.x) * (z - b.z)
	var d2 := (x - c.x) * (b.z - c.z) - (b.x - c.x) * (z - c.z)
	var d3 := (x - a.x) * (c.z - a.z) - (c.x - a.x) * (z - a.z)
	var has_neg := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	if has_neg and has_pos:
		return NAN
	var denominator := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(denominator) < 0.00001:
		return NAN
	var wa := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / denominator
	var wb := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / denominator
	return wa * a.y + wb * b.y + (1.0 - wa - wb) * c.y


## 现场缩放场地：`[` 缩小、`]` 放大。整套（含碰撞）挂在同一个根节点下，改根节点缩放即可。
func _rescale_arena(step: float) -> void:
	_arena_scale = clampf(_arena_scale * step, ARENA_SCALE_MIN, ARENA_SCALE_MAX)
	if _arena_root != null:
		_arena_root.scale = Vector3.ONE * _arena_scale
	# 场地变了，车得重新落到（新的）地面上
	if _vehicle != null and _chassis != null and is_instance_valid(_chassis):
		_chassis.queue_free()
		_chassis = null
		_wheels.clear()
		_spawn(_vehicle)
	_update_hud()


## 找出生点用的"推车"（键位和机库完全一样）：↑↓←→ 前后左右（世界轴）、`<` `>` 升降。
## 直接把底盘挪过去（速度清零），挪到合适的地方后把 HUD 上的模型坐标告诉我，
## 我把默认出生点固定到那儿。
func _nudge_vehicle(delta: Vector3) -> void:
	if _chassis == null or not is_instance_valid(_chassis):
		return
	var step := maxf(1.0, _arena_scale)
	_chassis.global_position += delta * step
	_chassis.linear_velocity = Vector3.ZERO
	_chassis.angular_velocity = Vector3.ZERO
	_chassis.sleeping = false
	_update_hud()


## 方向键 / `<` `>` → 位移方向（和 scripts/build_mode.gd 里的 _move_delta_for_key 一致）
static func nudge_delta_for_key(keycode: int) -> Vector3:
	match keycode:
		KEY_UP:
			return Vector3(1, 0, 0)
		KEY_DOWN:
			return Vector3(-1, 0, 0)
		KEY_LEFT:
			return Vector3(0, 0, -1)
		KEY_RIGHT:
			return Vector3(0, 0, 1)
		KEY_COMMA, KEY_LESS:
			return Vector3(0, -1, 0)
		KEY_PERIOD, KEY_GREATER:
			return Vector3(0, 1, 0)
	return Vector3.ZERO


## 场地模型在本地空间里的边长（取水平方向较大的那个）
func _arena_extent() -> float:
	if _arena_model == null:
		return 0.0
	var best := 0.0
	var stack: Array = [_arena_model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var mesh_node: MeshInstance3D = node
			var box := _relative_transform(mesh_node, _arena_model) * mesh_node.mesh.get_aabb()
			best = maxf(best, maxf(box.size.x, box.size.z))
		for child in node.get_children():
			stack.append(child)
	return best


func _mesh_count(root: Node) -> int:
	if root == null:
		return 0
	var total := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			total += 1
		for child in node.get_children():
			stack.append(child)
	return total


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "Chase"
	# 相机是每帧在 _process 里手动摆的，不要参与物理插值（否则会被拉回旧位置）
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_camera.fov = 70.0
	# 初始位置只是个占位：每帧由 _process 按 yaw/pitch/距离重算
	_camera.position = Vector3(-CAMERA_DISTANCE, 3.0, 0.0)
	add_child(_camera)


func _build_hud() -> void:
	# 左上角速度表：大字号，每帧刷新。下面的信息块（FPS/缩放/位置…）让开它的高度。
	_speedo = Label.new()
	_speedo.name = "Speedo"
	_speedo.position = Vector2(16.0, 8.0)
	_speedo.add_theme_font_size_override("font_size", SPEEDO_FONT_SIZE)
	_speedo.add_theme_color_override("font_color", Color(0.98, 0.99, 1.0))
	_speedo.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_speedo.add_theme_constant_override("shadow_offset_x", 2)
	_speedo.add_theme_constant_override("shadow_offset_y", 2)
	_speedo.text = "0 km/h"
	add_child(_speedo)
	_hud = Label.new()
	_hud.name = "HUD"
	_hud.position = Vector2(16.0, 8.0 + float(SPEEDO_FONT_SIZE) * 2.6)
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color(0.93, 0.94, 0.96))
	_hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_hud.add_theme_constant_override("shadow_offset_x", 1)
	_hud.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_hud)
	# 准星：屏幕正中一个小十字，开车时对着敌人瞄
	_crosshair = Control.new()
	_crosshair.name = "Crosshair"
	_crosshair.anchor_left = 0.5
	_crosshair.anchor_top = 0.5
	_crosshair.anchor_right = 0.5
	_crosshair.anchor_bottom = 0.5
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_crosshair)
	for offset in [Vector2(0, -10), Vector2(0, 10), Vector2(-10, 0), Vector2(10, 0)]:
		var tick := ColorRect.new()
		tick.color = Color(1, 1, 1, 0.8)
		tick.size = Vector2(2, 6) if offset.x == 0 else Vector2(6, 2)
		tick.position = offset - tick.size * 0.5
		tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_crosshair.add_child(tick)


func _update_hud() -> void:
	if _hud == null:
		return
	var name := str(pending_vehicle.get("name", pending_vehicle.get("id", "")))
	# 卡顿时把这行发出来就能定位：FPS 低 + draw 少 = 驱动/阴影之类的固定开销；
	# 物理 ms 高 = 载具太重或轮子参数不对；draw 爆了 = 零件/批次太多。
	_hud.text = "测试场 · %s\n%s\nFPS %d   draw %d   图元 %d   物理 %.1f ms" % [
		name,
		_status,
		Engine.get_frames_per_second(),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
	]
	if not _render_info.is_empty():
		_hud.text += "\n渲染：%s" % _render_info
	# 场地缩放：按 `[` `]` 现场调，定了倍数就去改 ARENA_SCALE
	_hud.text += "\n场地缩放 ×%.2f（[ 缩小 · ] 放大）" % _arena_scale
	# 出生点位置（模型坐标系）：按 ↑↓←→ 推车、`<` `>` 升降，找到好地方把这几个数告诉我
	if _chassis != null and is_instance_valid(_chassis):
		var model_pos := _chassis.global_position / maxf(_arena_scale, 0.001)
		_hud.text += "\n车的位置（模型单位）%.1f, %.1f, %.1f —— ↑↓←→ 推车 · < > 升降" % [
			model_pos.x, model_pos.y, model_pos.z
		]
	# 网格节点数：正常是一只手数得过来的。要是几百，就是场景被重复建了。
	_hud.text += "\n网格 %d   场地 %d   载具 %d" % [
		_count_mesh_nodes(), _count_nodes_of("WorldEnvironment"), _count_nodes_of("RigidBody3D")
	]
	# 重心（O 键开关）：本地坐标 + 离地高度 + 整车质量 —— 调驾驶手感时盯这一行
	if _com_visible and _chassis != null and is_instance_valid(_chassis):
		var com := _chassis.center_of_mass
		_hud.text += "\n重心（O 关闭）本地 %.2f, %.2f, %.2f · 离地 %.2f 格 · 质量 %.0f kg" % [
			com.x, com.y, com.z, _com_height, _chassis.mass
		]
	# 武器：转塔在瞄哪儿（距离 / 打到没打到 / 当前两个角），调武器时盯这一行
	if not _turrets.is_empty():
		var turret: Turret = _turrets[0]
		var angles := turret.angles_deg()
		_hud.text += "\n武器 %s：瞄点 %.1f 格（%s）· 水平 %.0f° · 俯仰 %.0f°" % [
			turret.part_id,
			_aim_point.distance_to(turret.muzzle_position()),
			"命中" if _aim_hit else "空中",
			angles.x,
			angles.y,
		]
		# 想去的角（夹射界之后，单位 = 度）：和上面"实际角"并排看，
		# 一眼能分辨是"夹错了"还是"解算/转速"的问题（用户报左转时回跳，就是靠这个看）。
		_hud.text += "（想去 %.0f°/%.0f°）" % [
			rad_to_deg(wrapf(turret.aim_yaw, -PI, PI)), rad_to_deg(turret.aim_pitch)
		]
		# 真实射界：和初始枪口朝向连通的那一片才算数（射界里允许有零件，但不能穿过去）
		_hud.text += " · 射界 %.0f%%" % (turret.arc_free_ratio() * 100.0)
		if not turret.arc_blocked_by.is_empty():
			_hud.text += " · ⛔ %s（不能开火）" % turret.arc_blocked_by
		# 武器多了以后，光看第一台不够用 —— 顺带报一下"现在有几台被挡"
		if _turrets.size() > 1:
			var stuck := 0
			for other in _turrets:
				if not other.arc_reason().is_empty():
					stuck += 1
			if stuck > 0:
				_hud.text += " · 共 %d/%d 台被挡" % [stuck, _turrets.size()]
	elif not _turret_problem.is_empty():
		_hud.text += "\n武器装不上：%s" % _turret_problem
	# 能量 / 开火记账（核心提供能量；打出去的每发都扣能量）
	if _energy_max > 0.0 and not _turrets.is_empty():
		var counters := _projectiles.counters() if _projectiles != null else Vector2i.ZERO
		_hud.text += "\n能量 %.0f/%.0f（+%.0f/s）· 开火 %d 发 · 在飞 %d · 命中 %d · 自吃 %d%s%s%s" % [
			_energy,
			_energy_max,
			_energy_regen,
			_shots_fired,
			_projectiles.live_count() if _projectiles != null else 0,
			counters.x,
			counters.y,
			"（能量不足 %d 发）" % _dry_fires if _dry_fires > 0 else "",
			"（射界外 %d 发）" % _jam_fires if _jam_fires > 0 else "",
			"（枪口自吃 %d 发）" % _muzzle_eaten if _muzzle_eaten > 0 else "",
		]
	# 靶子 / 毁伤：靶子是**我方载具的复制品**，命中结算和玩家车同一套规则
	if not _enemies.is_empty():
		var alive_parts := 0
		var all_parts := 0
		for rig in _enemies:
			alive_parts += rig.state.alive_count()
			all_parts += rig.state.part_count()
		var mine := ""
		if _player_rig != null:
			mine = " · 我方零件 %d/%d" % [
				_player_rig.state.alive_count(), _player_rig.state.part_count()
			]
		_hud.text += "\n靶子 %d 台：零件 %d/%d 还在 · 打光 %d 台%s · %s" % [
			_enemies.size(), alive_parts, all_parts, _kills, mine, _last_hit
		]


func _count_mesh_nodes() -> int:
	var total := 0
	var stack: Array = [self]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			total += 1
		for child in node.get_children():
			stack.append(child)
	return total


func _count_nodes_of(cls: String) -> int:
	var total := 0
	var stack: Array = [self]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.is_class(cls):
			total += 1
		for child in node.get_children():
			stack.append(child)
	return total


func _physics_process(delta: float) -> void:
	if _chassis == null:
		return
	var throttle := 0.0
	if Input.is_action_pressed("drive_forward"):
		throttle += 1.0
	if Input.is_action_pressed("drive_back"):
		throttle -= 1.0
	var steer := 0.0
	if Input.is_action_pressed("drive_left"):
		steer += 1.0
	if Input.is_action_pressed("drive_right"):
		steer -= 1.0
	_space = _chassis.get_world_3d().direct_space_state
	# 每台车各跑一遍轮胎物理：玩家车吃键盘，靶子输入恒为 0
	# （它们照样有完整的碰撞 + 悬挂 + 轮胎，只是没人开 —— 推得动、会被打瘸）
	for veh in _vehicles:
		_drive_vehicle(veh, delta, throttle if bool(veh["is_player"]) else 0.0,
			steer if bool(veh["is_player"]) else 0.0)
	# 引擎声只看玩家按键（不看车的实际状态，见 _update_engine_audio 注释）
	if not _vehicles.is_empty():
		_update_engine_audio(_vehicles[0], throttle, steer, delta)
	_update_com_marker()
	_update_turrets(delta)
	_update_weapons(delta)
	if _projectiles != null:
		_projectiles.step(delta, _space)


## 一台车的轮胎物理（原来只给玩家车写死，现在按 `_vehicles` 逐台跑：玩家车 + 靶车）。
func _drive_vehicle(veh: Dictionary, delta: float, throttle: float, steer: float) -> void:
	var chassis: RigidBody3D = veh["chassis"]
	if chassis == null or not is_instance_valid(chassis):
		return
	var wheels: Array = veh["wheels"]
	# 反方向键 = 先刹车：还朝原方向走就先上刹车，等慢下来才真正反向给油。
	# 速度必须取**地面平面上的投影**：车加速翘头、悬挂起伏、腾空时，车头方向会上仰，
	# 拿三维点积算出来的 "前进速度" 会变成负数 —— 于是踩着 W 反而被判成"在反方向"，
	# 一边给油一边刹车（实测症状：给油 2 秒只走 2 米、末速≈0）。
	var up := chassis.global_transform.basis.y
	var forward := chassis.global_transform.basis.x
	var flat_forward := forward - up * forward.dot(up)
	flat_forward = (
		flat_forward.normalized() if flat_forward.length() > 0.05 else forward.normalized()
	)
	var velocity := chassis.linear_velocity
	var flat_velocity := velocity - up * velocity.dot(up)
	var forward_speed := flat_velocity.dot(flat_forward)
	var grounded := false
	var ground_y := INF
	for entry in wheels:
		# 每个轮子用自己的部件参数：推力/刹车/限速/转向角都写在 .part.txt 里
		var braking := (
			throttle != 0.0
			and signf(throttle) != signf(forward_speed)
			and absf(forward_speed) > REVERSE_BRAKE_SPEED_CUBES
		)
		var force := 0.0 if braking else float(entry["engine_force"]) * throttle
		# 限速不是"到点就断油"（硬截断会让车顶着限速一顿一顿），而是**余弦衰减**：
		# 速度 0 时给满推力，越接近 `wheel_max_speed` 推力越小，正好到限速时降到 0。
		#   scale = cos(π/2 × |v| / v_max)   → 0 时 1、v_max 时 0
		# 只在"油门方向和车速同向"时衰减：反打方向（刹车/倒车）时该给满推力。
		var max_speed := float(entry["max_speed"])
		if not braking and max_speed > 0.0 and signf(throttle) == signf(forward_speed):
			var ratio := clampf(absf(forward_speed) / max_speed, 0.0, 1.0)
			force *= cos(ratio * PI * 0.5)
		entry["drive"] = force
		entry["braking"] = braking
		# 全轮转向：重心之前正转、之后反转。转角**不是瞬移到位**的：
		# 每帧朝目标角靠拢，速度上限 = 部件文件里的角速度（度/秒）。
		#   * **打方向**用 `wheel_steer_speed` —— 有"缓启动"，不是一帧打满（以前是瞬移，手感硬）；
		#   * **松手回正**（输入回中）单独用 `wheel_steer_return_speed` —— 想"撒手就正"
		#     就把它写得比打方向快，而打方向那段的手感一点不变（用户报的"松开还在转"）。
		# 每个轮轴各读自己那一份，所以不同轮轴可以有不同的转向 / 回正速度。
		var target_steer := float(entry["steer_sign"]) * steer * float(entry["steer_max"])
		var steer_rate := (
			float(entry["steer_return_speed"]) if absf(steer) <= 0.01
			else float(entry["steer_speed"])
		)
		entry["steer"] = move_toward(float(entry["steer"]), target_steer, steer_rate * delta)
		_steer_wheel(entry)
		_apply_wheel(veh, entry, delta)
		if bool(entry.get("contact", false)):
			grounded = true
			ground_y = minf(ground_y, (entry["node"] as Node3D).global_position.y - float(entry["radius"]))
		_spin_tire(entry, flat_forward, flat_velocity, force, delta)
	_apply_anti_roll(veh, grounded, ground_y)
	_apply_handling_aids(veh, chassis, steer, delta)


## ── 全局手感辅助（参数在 `data/handling.txt`）─────────────────────────────
## 三条都**只在车在地面上时**生效：**有轮着地就是满效果，一个都没着地就完全不生效**
## （不按着地轮数的比例缩放）；切换时按 `ground_blend_seconds` 过渡，
## 所以落地是平滑恢复，不会"啪"地跳一下。
##
##   ① **下压力**（模拟气动力）：F = 系数 × **当前车重**（N），朝**世界下方**压在车身上。
##      系数是"多少倍车重"（0.5 = 额外压上半个车身重量）。
##      车重取**当前**值：零件被打掉 → 车变轻 → 下压力跟着变小
##      （`VehicleRig.sync_body()` 会把剩下的重量同步给 `chassis.mass`）。
##      **不随速度变** —— 要的是"一直更贴地"，不是"越快越贴"。
##      压在车身上 → 悬挂被压得更紧 → 轮胎法向力更大 → 抓地更大（这就是它改善手感的原理）。
##   ② **自动回正力矩**：把车身往竖直方向拧回来（滚转 + 俯仰都管），
##      力矩大小按 sin(倾角) 缩放，再加一份阻尼防止来回摆。
##   ③ **松手回正（偏航）**：只在**没给转向输入**时，把偏航角速度按时间常数
##      `yaw_center_seconds` 衰减 —— 松开方向键后车身很快就不转了（不影响打方向时的转向手感）。
##      生效强度和上面两条一样（见 `handling_blend`）。
##
## ⚠️ 和轮子文件里的 `wheel_anti_roll_*`（只防滚转）是**叠加**关系 —— 两个一起开会很硬。
func _apply_handling_aids(veh: Dictionary, chassis: RigidBody3D, steer: float, delta: float) -> void:
	var wheels: Array = veh["wheels"]
	if wheels.is_empty():
		return
	var contacts := 0
	for wheel in wheels:
		if bool((wheel as Dictionary).get("contact", false)):
			contacts += 1
	var blend := handling_blend(
		float(veh.get("handling_blend", 0.0)),
		contacts > 0,
		delta,
		GameSettings.handling_value("ground_blend_seconds")
	)
	veh["handling_blend"] = blend
	if blend <= 0.0:
		return                       # 腾空（过渡还没起来）：三条都不生效
	var tensor := _inertia_of(chassis)
	# ① 下压力：F = 系数 × 当前车重（朝世界下方）
	var ratio := GameSettings.handling_value("downforce")
	if ratio > 0.0:
		var weight := chassis.mass * _world_gravity()
		chassis.apply_force(Vector3.DOWN * (ratio * weight * blend))
	# ② 自动回正：力矩沿"把车身 up 拧向世界 up"的轴，大小按 sin(倾角) 缩放
	var wave := GameSettings.handling_value("upright_torque")
	if wave > 0.0:
		var up := chassis.global_transform.basis.y.normalized()
		var inertia := maxf(1.0, (tensor.x + tensor.z) * 0.5)
		chassis.apply_torque(
			upright_torque(up, chassis.angular_velocity, wave, inertia) * blend
		)
	# ③ 松手回正（偏航）：不给转向时，偏航角速度按时间常数衰减（τ = -I × ω / 秒）
	var center_seconds := GameSettings.handling_value("yaw_center_seconds")
	if center_seconds > 0.0 and absf(steer) <= 0.01:
		var basis := chassis.global_transform.basis
		var up_now := basis.y.normalized()
		var i_up := inertia_about(up_now, basis, tensor)
		chassis.apply_torque(
			yaw_center_torque(up_now, chassis.angular_velocity, center_seconds, i_up)
				* blend
		)
	# ④ 车身角阻尼：把车身"转的震动本身"整体系数化衰减（滚转/俯仰/偏航三个轴一起）。
	#    单位是 **1/秒**：角速度按 1/(1 + 系数 × dt) 衰减，时间常数 ≈ 1/系数 秒
	#      （0.5 → 2 秒衰减到 37%；3 → 0.33 秒；10 → 0.1 秒，基本"转不动"）。0 = 关掉。
	#    ⚠️ 这里直接按比例缩放角速度，**不是**加一个 -c·ω 的力矩：那种显式力矩的稳定条件是
	#      `c·dt/I < 2`，我们的转动惯量不大（几百 kg·格²），系数稍大就自激 —— 这个形式
	#      无条件稳定，和 Godot 自带 `angular_damp` 是同一个算法，你随便往大调都安全。
	var ang_damp := GameSettings.handling_value("angular_damp")
	if ang_damp > 0.0:
		chassis.angular_velocity /= 1.0 + ang_damp * delta * blend


## 手感辅助的"生效强度"：**有轮着地 → 目标 1，一个都没着地 → 目标 0**（不看轮数比例），
## 但每帧只朝目标走 `delta / seconds`，所以落地是**平滑恢复**、不会"啪"地跳一下。
## `seconds <= 0` = 立即到位（不过渡）。状态存在每台车自己的 `handling_blend` 上
## （玩家车和靶子车各算各的）。
static func handling_blend(
	current: float, any_contact: bool, delta: float, seconds: float
) -> float:
	var target := 1.0 if any_contact else 0.0
	if seconds <= 0.0:
		return target
	return move_toward(current, target, delta / seconds)


## 车身的惯性张量（**本地** x/y/z 主轴上的对角分量，kg·格²）。
## ⚠️ Godot 的 `RigidBody3D.inertia` 有时读出来是全 0（形状还没同步给刚体），
## 而 ②③ 的阻尼项都乘着它 —— 那样会**静默变成没有效果**。所以这里做一次合理性检查：
## 张量总和连"实心长方体粗估"的 3% 都不到，就整个换成粗估值。
func _inertia_of(chassis: RigidBody3D) -> Vector3:
	var guess := box_inertia_guess(chassis.mass, _cam_box_local.size)
	var tensor := chassis.inertia
	if tensor.x + tensor.y + tensor.z >= guess * 0.03:
		return tensor
	return Vector3.ONE * guess


## 整车绕**竖直轴**转动惯量的粗估（kg·格²）：把它当成实心长方体，I = m(a²+b²)/12，
## a / b = 俯视的长和宽。只用来兜底 / 做合理性判断，不是精确值（见 `_inertia_of`）。
static func box_inertia_guess(mass: float, footprint: Vector3) -> float:
	return maxf(1.0, mass * (footprint.x * footprint.x + footprint.z * footprint.z) / 12.0)


## 松手回正（偏航）的力矩：只吃**绕车身 up 的那一份**角速度（打转），不吃滚转 / 俯仰。
## 大小取 `-I × ω / 秒数` —— 没有别的力时正好让 ω 按 `秒数` 这个时间常数指数衰减
## （0.35 秒 → 0.35 秒后剩 37%）。`seconds <= 0` = 关掉。
static func yaw_center_torque(
	up: Vector3, angular_velocity: Vector3, seconds: float, inertia_up: float
) -> Vector3:
	if seconds <= 0.0:
		return Vector3.ZERO
	var axis := up.normalized()
	var rate := angular_velocity.dot(axis)
	if absf(rate) <= 0.0001:
		return Vector3.ZERO
	return axis * (-rate * maxf(1.0, inertia_up) / seconds)


## 车身绕**世界方向 `axis_dir`** 转动时的转动惯量（kg·格²）。
## Godot 的 `RigidBody3D.inertia` 是**车身本地**三根主轴上的对角分量（本地 x/y/z），
## 所以：把世界方向投到本地上（`basis.transposed() * axis_dir`），按分量平方加权求和。
## （各主轴不正交 / 非对角项非零时是近似 —— 对这套方块拼出来的车够用。）
static func inertia_about(axis_dir: Vector3, basis: Basis, inertia: Vector3) -> float:
	var local := (basis.transposed() * axis_dir.normalized())
	return maxf(
		1.0,
		inertia.x * local.x * local.x
			+ inertia.y * local.y * local.y
			+ inertia.z * local.z * local.z
	)


## 自动回正力矩（不含"地面附近"的强度系数）：把车身 up 拧向世界 up，再加一份倾斜阻尼。
##   * 方向 = `up × 世界up`（绕它正转就是"最短路径"把 up 转到世界 up，见测试）；
##   * 大小 = `max_torque × sin(倾角)`，倾得越厉害拉得越狠、正了就松手；
##   * 阻尼只吃**倾斜速率**（沿车身 up 的那一份是自转，不该被拉住）。
## `damping < 0` = 读 `data/handling.txt` 里的值（正常路径）；传具体值是为了让测试能定性判断方向。
static func upright_torque(
	up: Vector3, angular_velocity: Vector3, max_torque: float, inertia: float, damping := -1.0
) -> Vector3:
	var axis := up.normalized().cross(Vector3.UP)
	var tilt := axis.length()              # |up × UP| = sin(倾角)，正好当缩放系数
	if tilt <= 0.0001:
		return Vector3.ZERO
	var critical := 2.0 * sqrt(max_torque * maxf(1.0, inertia))
	var body_up := up.normalized()
	var tilt_rate := angular_velocity - body_up * angular_velocity.dot(body_up)
	var damp := damping if damping >= 0.0 else GameSettings.handling_value("upright_damping")
	return axis.normalized() * max_torque * tilt - tilt_rate * critical * damp


## 引擎声（用户要求：**只管玩家的按键**，不看车的实际状态；变化依据 = **按下油门的时长**）。
##
## 为什么不用车速驱动：以前音量和音高都跟车速，停车时还剩一点怠速底噪，
## 听感就是"停下来了引擎还在响、背景里一直有个声"（用户报的）。现在改成：
##   按下油门 → 引擎起，**按得越久音高/音量越高**（`engine_ramp_seconds` 秒内从
##   `pitch_low`/`idle` 升到 `pitch_high`/`full`，像"给油给上去了"）；只按转向 = 中间怠速；
##   **全松开 → 淡出并真正停掉**。三个参数和两个响度都在 `data/audio.txt`。
## 素材强度和音色都在 `data/audio.txt` / `assets/audio/engine_loop.wav`（CC0）。
## 只有玩家车有引擎声（靶子没人开，不需要）。
func _update_engine_audio(veh: Dictionary, throttle: float, steer: float, delta: float) -> void:
	var player: AudioStreamPlayer = veh.get("audio")
	if player == null:
		var stream := GameSettings.engine_stream()
		if stream == null:
			return                    # 编辑器里 / 素材没导入：安静就好，别报错
		player = AudioStreamPlayer.new()
		player.name = "EngineAudio"
		player.stream = stream
		player.bus = GameSettings.BUS_SFX
		player.volume_db = -80.0      # 先"关着"，等按键再响
		(veh["chassis"] as RigidBody3D).add_child(player)
		veh["audio"] = player
	var gas := absf(throttle)
	var active := gas > 0.01 or absf(steer) > 0.01
	# 油门按住多久了（松开/换向就归零）—— 引擎的"上扬"只看这个，不看车速
	var hold := float(veh.get("throttle_hold", 0.0))
	hold = (hold + delta) if gas > 0.01 else 0.0
	veh["throttle_hold"] = hold
	# 0 = 刚按下（低转），1 = 按满 ramp_seconds 秒（高转）
	var rev := clampf(hold / GameSettings.engine_ramp_seconds(), 0.0, 1.0)
	var pitch_low := GameSettings.engine_pitch_low()
	var pitch_high := GameSettings.engine_pitch_high()
	# 音高：只按转向 = 中间怠速；给油 = 从 low 一路升到 high
	var target_pitch := lerpf(pitch_low, pitch_high, rev) if gas > 0.01 else (pitch_low + pitch_high) * 0.5
	var target_db := -80.0
	if active:
		target_db = (
			GameSettings.engine_db_idle()
			if gas <= 0.01
			else lerpf(GameSettings.engine_db_idle(), GameSettings.engine_db_full(), rev)
		)
		if not player.playing:
			player.play()
	# 平滑系数别太大：升调本身就是"按时间慢慢上去"的，再叠一层快平滑会显得生硬
	player.pitch_scale = lerpf(player.pitch_scale, target_pitch, 0.12)
	player.volume_db = lerpf(player.volume_db, target_db, 0.12)
	# 松开键、淡出到底之后**真的停掉** —— 不然总有一个循环在背景里响
	if not active and player.playing and player.volume_db < -55.0:
		player.stop()


## ── 武器：瞄点 + 转塔 ──────────────────────────────────────────────────────
## 瞄准规则（用户定的）：瞄点 = **瞄准视线的首个敌人/地形交点**；
## 视线就是相机准星（屏幕中心）那条射线 —— 对着天打不到东西时取射线的远端。
## 拿到瞄点后，每个转塔朝它转（射界/俯仰的夹紧在 Turret.solve_aim 里，走最短路径）。
func _update_turrets(delta: float) -> void:
	if _turrets.is_empty():
		return
	_aim_point = _aim_point_from_camera()
	for turret in _turrets:
		# 按炮塔转速限制慢慢跟（不是瞬间对准）：转速写在部件文件里（度/秒）
		turret.update_aim(_aim_point, delta)
	if _aim_marker != null and is_instance_valid(_aim_marker):
		_aim_marker.global_position = _aim_point


## 枪口 → 子弹生成点那一段里，**第一个**被自家零件挡住的地方（世界坐标）。
## "枪口贴脸自吃"时把命中小爆炸放在这儿 —— 弹丸压根没生成，得靠这个特效才看得见打在哪儿。
## 这一段只有 1 格，采 8 个点足够；一个都没采到就退回起点。
func _first_blocked_point(from: Vector3, to: Vector3, skip_index: int) -> Vector3:
	if _chassis == null:
		return from
	var to_local := _chassis.global_transform.affine_inverse()
	var a := to_local * from
	var b := to_local * to
	for i in range(1, 9):
		var point := a.lerp(b, float(i) / 8.0)
		for j in _clip_boxes.size():
			if j == skip_index:
				continue
			var box: AABB = _clip_boxes[j]["box"]
			if box.size.x <= 0.001 or box.size.y <= 0.001 or box.size.z <= 0.001:
				continue
			if box.has_point(point):
				return _chassis.global_transform * point
	return from


## 转塔自检要用的"每个零件的包围盒"（底盘本地坐标，下标 = 零件下标）。
## 直接用 VehicleRig 已经建好的碰撞盒：它就是"这个零件占的那块地方"，
## 和受击/毁伤用的是同一份口径。名字里带上部件 id，HUD 里能直接看出"被谁挡住"。
func _collect_clip_boxes(rig: VehicleRig, vehicle: VehicleDef) -> Array:
	var out := []
	for i in rig.shapes.size():
		var box := AABB()
		var shape: CollisionShape3D = rig.shapes[i]
		# 已经被打掉的零件不再挡射界（它的 shape 还留着占位，但已经 disabled）
		if rig.part_alive(i) and shape != null and shape.shape is BoxShape3D:
			var size: Vector3 = (shape.shape as BoxShape3D).size
			box = AABB(shape.position - size * 0.5, size)
		var part_id := "--"
		if i < vehicle.parts.size():
			part_id = str(vehicle.parts[i]["part_id"])
		out.append({"box": box, "name": "%s #%d" % [part_id, i]})
	return out


## 重算每台转塔的**真实射界**（角网格 + 连通域，见 `Turret.rebuild_arc()`）。
## 时机：进场看到车体之后、以及**零件被打掉之后**（打掉挡路的零件，射界就变大了）。
func _refresh_turret_arcs() -> void:
	if _clip_boxes.is_empty():
		return
	var all_blocked := 0
	for turret in _turrets:
		turret.rebuild_arc(_clip_boxes)
		# 诊断（用户报"有些武器无法正常判定遮挡转动"）：射界**算不出来**（转塔没装好）或者
		# **整片被挡**（枪管一转就穿零件）时必须留一句话 —— 否则那条枪会静默地"随便转、
		# 被挡也照打"，查起来一头雾水。
		if not turret.arc_ready():
			push_warning("测试场：%s 的真实射界算不出来（转塔节点没装起来）" % turret.part_id)
		elif turret.arc_free_ratio() <= 0.001:
			all_blocked += 1
	if all_blocked > 0:
		push_warning(
			"测试场：%d 台转塔的真实射界整片被挡（周围有零件压着枪管），它们转不了也打不了"
			% all_blocked
		)


## 能量 + 开火：整车一口能量池（核心提供上限与恢复），所有武器共用。
## 扳机按住时按 rpm 决定这一帧打几发；每发先扣能量，不够就哑火（`_dry_fires` 记账）。
func _update_weapons(delta: float) -> void:
	if _energy_max > 0.0:
		_energy = minf(_energy_max, _energy + _energy_regen * delta)
	if _turrets.is_empty() or _projectiles == null:
		return
	if not Input.is_action_pressed(FIRE_ACTION):
		for turret in _turrets:
			turret.arc_blocked_by = ""   # 松手就把"射界外"的提示清掉
		return
	var inherit := _chassis.linear_velocity
	for turret in _turrets:
		# 开火自检（用户规则）：射界里允许有零件，但只有在**真实射界**（和初始枪口朝向连通、
		# 且枪管不穿模的那一片）里才能开火。每帧查一次格子，代价可以忽略。
		var blocked: String = turret.arc_reason()
		turret.arc_blocked_by = blocked
		for _shot in turret.ready_shots(delta):
			if not blocked.is_empty():
				_jam_fires += 1
				continue
			if _energy < turret.energy_cost:
				_dry_fires += 1
				continue
			# 枪口贴脸：子弹是从"枪口沿枪轴再外推 1 格"生成的（`Turret.MUZZLE_PAD`），
			# 那 1 格里的自家方块会被**整个跨过去** —— 症状就是"近处方块打不中自己、子弹穿过去"。
			# 这里先把枪口→生成点这一段查一遍：有东西就直接算打在自己身上（吃掉这一发）。
			var spawn: Vector3 = turret.fire_origin()
			var muzzle_now: Vector3 = turret.muzzle_position()
			var slam := Turret.segment_blocker(
				muzzle_now, spawn, _clip_boxes, int(turret.get_meta("part_index", -1))
			)
			_energy -= turret.energy_cost
			_shots_fired += 1
			# 显式写类型：`turret` 是数组里的 Variant，`:=` 推不出类型（本项目把这种当错误）
			var dir: Vector3 = turret.barrel_direction()
			# 枪口闪光（挂在枪管上的火舌）+ 从**真枪口**拉出来的第一段光带（近身也看得见弹道）
			turret.flash()
			GameSettings.play_shot()   # 机枪开火音（响度在 data/audio.txt 的 shot，池子能叠）
			if not slam.is_empty():
				# 打在自己身上：不生成弹丸（弹丸的射线是从生成点开始的，跨过的那 1 格它永远看不到）
				_muzzle_eaten += 1
				_last_hit = "枪口被 %s 挡住，这一发打在自己身上" % slam
				# 照样给个命中小爆炸（用户要看得见），位置取那 1 格里**第一个被挡住的地方**
				if _projectiles != null:
					_projectiles.spawn_impact(
						_first_blocked_point(
							muzzle_now, spawn, int(turret.get_meta("part_index", -1))
						)
					)
				continue
			_projectiles.fire(
				spawn,
				dir,
				turret.muzzle_speed,
				turret.spread_deg,
				turret.damage,
				turret.projectile_life,
				inherit,
				PLAYER_KEY,
				muzzle_now
			)


## 相机准星射线 → 瞄点。自家底盘要按 RID 排除（它和地形同在碰撞层 1）。
func _aim_point_from_camera() -> Vector3:
	if _camera == null:
		return _chassis.global_position + _chassis.global_transform.basis.x * AIM_RANGE
	var centre := get_viewport().get_visible_rect().size * 0.5
	var from := _camera.project_ray_origin(centre)
	var dir := _camera.project_ray_normal(centre).normalized()
	var to := from + dir * AIM_RANGE
	_aim_hit = false
	if _space != null:
		var exclude: Array[RID] = [_chassis.get_rid()]
		var query := PhysicsRayQueryParameters3D.create(from, to, AIM_LAYERS, exclude)
		var hit := _space.intersect_ray(query)
		if not hit.is_empty():
			_aim_hit = true
			return hit["position"]
	return to


## 瞄点标记：一个小球，一眼看出转塔在对准哪儿（调武器时最有用）。
func _build_aim_marker() -> void:
	_aim_marker = MeshInstance3D.new()
	_aim_marker.name = "AimMarker"
	var sphere := SphereMesh.new()
	sphere.radius = AIM_MARKER_RADIUS
	sphere.height = AIM_MARKER_RADIUS * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	_aim_marker.mesh = sphere
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.25, 0.2, 0.9)
	_aim_marker.material_override = material
	_aim_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_aim_marker)


## 重心显示（O 键）：一个亮球标在重心上 + 一条垂到地面的线 + 地面上的投影点。
## 顺手把"离地高度"记到 `_com_height`（HUD 上会显示）——
## 调驾驶手感时最该看的就是这两个数：重心多高、在前后轴之间偏哪儿。
func _build_com_marker() -> void:
	if _com_marker != null and is_instance_valid(_com_marker):
		return
	_com_marker = ComMarker.new()
	_com_marker.name = "ComMarker"
	_com_marker.visible = false
	# 挂在**底盘**下：局部坐标 = 刚体的 center_of_mass，车翻滚/侧倾时它跟着走
	_chassis.add_child(_com_marker)


func _toggle_com_marker() -> void:
	if _chassis == null:
		return
	_build_com_marker()
	_com_visible = not _com_visible
	_com_marker.visible = _com_visible
	if _com_visible:
		_com_marker.place_local(_chassis.center_of_mass)


## 每帧更新重心标记（位置由刚体自己的 `center_of_mass` 给，标记是底盘的子节点）
func _update_com_marker() -> void:
	if not _com_visible or _com_marker == null or not is_instance_valid(_com_marker):
		return
	if _chassis == null or not is_instance_valid(_chassis):
		return
	_com_marker.place_local(_chassis.center_of_mass)
	_com_height = _com_marker.update_drop(_space)


## 侧倾稳定器：有轮子着地时，绕车身前后轴给一个"回正弹簧 + 阻尼"。
## 系数不是拍脑袋：劲度 = 车重 × 重心高度 ÷ 允许的侧倾角（见 ANTI_ROLL_MAX_TILT），
## 阻尼 = 倍率 × 临界阻尼，转动惯量读车身自己的 inertia.x（车身本地 x = 前后轴）。
func _apply_anti_roll(veh: Dictionary, grounded: bool, ground_y: float) -> void:
	var chassis: RigidBody3D = veh["chassis"]
	if not grounded or chassis == null or not is_instance_valid(chassis):
		return
	var wheels: Array = veh["wheels"]
	# 整车共用一份：取第一个轮轴的部件参数（见 `wheel_anti_roll_tilt`）；0 = 关掉防翻
	var max_tilt := ANTI_ROLL_MAX_TILT
	var damping := ANTI_ROLL_DAMPING
	if not wheels.is_empty():
		max_tilt = float(wheels[0]["anti_roll_tilt"])
		damping = float(wheels[0]["anti_roll_damping"])
	if max_tilt <= 0.0:
		return
	var xform := chassis.global_transform
	var forward := (xform.basis * Vector3(1.0, 0.0, 0.0))
	forward.y = 0.0
	if forward.length() < 0.05:
		return
	forward = forward.normalized()
	var up := xform.basis.y
	var right := forward.cross(up).normalized()
	var roll_amount := up.dot(right)                       # > 0 = 车身向右倾
	var roll_rate := chassis.angular_velocity.dot(forward)
	var com_height := maxf(0.5, (xform * chassis.center_of_mass).y - ground_y)
	var weight := chassis.mass * float(
		ProjectSettings.get_setting("physics/3d/default_gravity", PartDef.GRAVITY_CUBES)
	)
	var k_roll := weight * com_height / max_tilt
	var c_roll := 2.0 * damping * sqrt(k_roll * maxf(1.0, chassis.inertia.x))
	chassis.apply_torque(forward * (-k_roll * roll_amount - c_roll * roll_rate))


## 转向：把轮胎节点绕**底盘上方向**转当前转角（转向角的缓启动在 _physics_process 里算）
func _steer_wheel(entry: Dictionary) -> void:
	var node: Node3D = entry["node"]
	if node == null or not is_instance_valid(node):
		return
	node.transform = Transform3D(
		Basis(Vector3.UP, float(entry["steer"])) * (entry["base_basis"] as Basis),
		node.position   # 位置由悬挂每帧算好（见 _apply_wheel），这里只改朝向
	)


## 接触探测：悬挂主射线决定轮心高度，整圈射线探测台阶、路缘及上方障碍。
## 多条命中只选最深的一个，沿命中面的真实法线施力，避免射线数量放大弹簧力。
func _wheel_contact(chassis: RigidBody3D, entry: Dictionary) -> Dictionary:
	var node: Node3D = entry["node"]
	var xform := chassis.global_transform
	var down := -xform.basis.y.normalized()
	var radius := float(entry["radius"])
	var rest := float(entry["rest"])
	var travel := float(entry["travel"])
	var exclude: Array[RID] = [chassis.get_rid()]
	var axle := node.global_transform.basis.x.normalized()
	var shift := axle * float(entry["ray_shift"])
	var hub := xform * (entry["hub"] as Vector3) + shift
	var reach := rest + radius
	var query := PhysicsRayQueryParameters3D.create(hub, hub + down * reach, 1, exclude)
	var hit := _space.intersect_ray(query)
	var compression := 0.0
	var best := {}
	if not hit.is_empty():
		compression = clampf(rest + radius - hub.distance_to(hit["position"]), 0.0, travel)
		best = {"depth": compression, "point": hit["position"], "normal": hit["normal"]}
	entry["suspension"] = rest - compression
	node.position = (entry["hub"] as Vector3) + Vector3.DOWN * (rest - compression)
	var centre := node.global_position + shift
	var up := -down
	var sus := up - axle * up.dot(axle)
	sus = sus.normalized() if sus.length() > 0.001 else up
	var fwd := axle.cross(sus).normalized()
	if fwd.dot(xform.basis.x) < 0.0:
		fwd = -fwd
	var rays := int(entry["rays"])
	var ring_reach := radius + float(entry["ray_slack"])
	for i in rays:
		var angle := TAU * float(i) / float(rays)
		var dir := (sus * cos(angle) + fwd * sin(angle)).normalized()
		if ring_ray_belongs_to_suspension(dir, down, float(entry["sus_sector"])):
			continue
		query = PhysicsRayQueryParameters3D.create(centre, centre + dir * ring_reach, 1, exclude)
		hit = _space.intersect_ray(query)
		if hit.is_empty():
			continue
		var depth := radius - centre.distance_to(hit["position"])
		if depth <= 0.0 or (not best.is_empty() and depth <= float(best["depth"])):
			continue
		best = {"depth": depth, "point": hit["position"], "normal": hit["normal"]}
	return best


## 参考 Godot VehicleBody3D::_update_suspension 和项目内 nani_raycast_wheel.gd：
## 接触判定 → 弹簧 + 速度阻尼 → 轮胎力 → 在接触点施力。离地时立即清空载荷。
## Godot 源码：https://github.com/godotengine/godot/blob/master/scene/3d/physics/vehicle_body_3d.cpp
func _apply_wheel(veh: Dictionary, entry: Dictionary, delta: float) -> void:
	entry["contact"] = false
	entry["push"] = 0.0
	entry["ray_depth"] = 0.0
	for key in ["dbg_depth", "dbg_normal_y", "dbg_long", "dbg_lat", "dbg_along", "dbg_side"]:
		entry[key] = 0.0
	var chassis: RigidBody3D = veh["chassis"]
	var node: Node3D = entry["node"]
	if not is_instance_valid(node) or _space == null or delta <= 0.0:
		return
	var contact := _wheel_contact(chassis, entry)
	if contact.is_empty():
		return
	entry["contact"] = true
	var best_point: Vector3 = contact["point"]
	var best_normal: Vector3 = (contact["normal"] as Vector3).normalized()
	var chassis_xform := chassis.global_transform
	var com := chassis_xform * chassis.center_of_mass
	# 包含角速度引起的接触点速度，俯仰/侧倾也由悬挂阻尼衰减。
	# 使用速度投影而非跨射线位置差分，避免切换接触点时产生虚假的压缩速度。
	var best_velocity := chassis.linear_velocity + chassis.angular_velocity.cross(best_point - com)
	var depth := minf(float(contact["depth"]), float(entry["travel"]))
	var push := suspension_force(depth, -best_velocity.dot(best_normal), entry)
	entry["ray_depth"] = depth
	var braking := bool(entry.get("braking", false))
	var brake_gain := float(entry["brake_gain"]) * clampf(float(entry["brake"]) / 60.0, 0.25, 3.0)
	# ── 轮胎力 ──
	#   接触面上的两个方向：`fwd_now` = 车轮前进方向，`axle_now` = 横向（轮轴）。
	var axle_now := (node.global_transform.basis * Vector3(1.0, 0.0, 0.0)).normalized()
	axle_now = (axle_now - best_normal * axle_now.dot(best_normal)).normalized()
	var fwd_now := best_normal.cross(axle_now).normalized()
	if fwd_now.dot(chassis_xform.basis.x) < 0.0:
		fwd_now = -fwd_now
	var along := best_velocity.dot(fwd_now)     # 车轮处的**前进速度**（格/秒）
	var side := best_velocity.dot(axle_now)     # 车轮处的**侧向速度**（格/秒）
	var grip := float(entry["grip_factor"])
	var lat_peak := float((entry["lat_pacejka"] as Array)[0])
	var long_peak := float((entry["long_pacejka"] as Array)[0])
	# 轮胎能给的最大力 = 法向载荷 × peak（就是 Pacejka 饱和时的值）× 抓地倍率
	var lat_cap := push * lat_peak * grip
	var long_cap := push * long_peak * grip
	# ── 横向：Pacejka 曲线（照抄 nani_raycast_wheel 的 `calc_tire_force()`）──
	#   滑移角 = 车轮速度方向与车轮朝向的夹角（速度很小时按方向算，看下一段的防抖闸）。
	var planar := sqrt(side * side + along * along)
	var lat_slip := asin(clampf(-side / maxf(0.000001, planar), -1.0, 1.0))
	var lat_force := pacejka(push, lat_slip, entry["lat_pacejka"] as Array) * grip
	# ★ **低速防抖闸（必须有）**：速度很小时滑移角被数值噪声推到 ±90°（饱和），
	#   轮胎力就变成"每帧顶满 → 把速度推过头 → 反向再顶满"的 bang-bang，
	#   车在原地一直抖（台架实测横向力 ±19 kN 来回、速度 ±0.5 格/秒不衰减）。
	#   多这一道上限就没事：力**不超过"一步之内把这个轮子的滑移速度削平"所需的力** ——
	#   低速时它 ∝ 速度（线性、不抖、一步到位），高速时它远大于摩擦上限（完全不参与）。
	var anti_chatter := maxf(1.0, float(entry["corner_mass"])) / delta
	var lat_bound := minf(lat_cap, absf(side) * anti_chatter)
	lat_force = clampf(lat_force, -lat_bound, lat_bound)
	# ── 纵向：**直接给力**（不是力矩）──
	#   推力 = 每轮推力 × 油门 × 限速余弦衰减（`wheel_max_speed`），在 `_drive_vehicle` 里算好。
	#   ⚠️ 2026-10-15 一度按 nani 那份改成"驱动轮力矩 + 轮子自转 ω 积分"，在这个尺度下不成立：
	#   驱动轮力矩 15000 N·m 远大于轮胎能给的反作用力矩（摩擦上限 × 半径 ≈ 3.5 kN·m），
	#   轮子会**无限加速自转**（台架实测 2142 弧度/秒）→ 推力被摩擦上限顶死、和油门脱钩 →
	#   极速设 30 m/s 却开到 60、松油门还在加速。直接给力才是可调、可控、极速准的形式
	#   （原生 VehicleWheel3D 也是这么干的）。
	var long_force := 0.0
	var drive := float(entry["drive"])
	if braking:
		long_force = clampf(-along * brake_gain, -long_cap, long_cap)
	elif absf(drive) < 0.001 and absf(along) < STOP_GRIP_SPEED:
		# 没油门又几乎不动：低速驻车（不然会一直"漂"着走）
		long_force = clampf(-along * brake_gain, -long_cap, long_cap)
	else:
		long_force = clampf(drive, -long_cap, long_cap)
	var total := best_normal * push + fwd_now * long_force + axle_now * lat_force
	chassis.apply_force(total, best_point - chassis.global_position)
	# 调试用：把这一帧的接触/轮胎量记在 entry 上（`tools/probe_flat.gd` 会打出来，
	# 用来定位"静止自己走"/"超过极速"这类问题 —— 看哪个量在静止时就不为零）。
	entry["dbg_depth"] = depth
	entry["dbg_normal_y"] = best_normal.y
	entry["dbg_long"] = long_force
	entry["dbg_lat"] = lat_force
	entry["dbg_along"] = along
	entry["dbg_side"] = side
	entry["push"] = push


## Pacejka 轮胎公式（照搬 `nani_raycast_wheel.gd` 的 `pacejka()`，MIT）：
## `力 = 法向载荷 × peak × sin(shape·atan(stiff·s − curve·(stiff·s − atan(stiff·s))))`
## 小滑移时近似"载荷 × 侧偏刚度 × 滑移"，大滑移自动饱和 —— 所以轮胎力天生正比于支撑力。
static func pacejka(vert_load: float, slip: float, coeffs: Array) -> float:
	if coeffs.size() < 4:
		return 0.0
	var stiff := float(coeffs[1])
	var x := stiff * slip
	return vert_load * float(coeffs[0]) * sin(
		float(coeffs[3]) * atan(x - float(coeffs[2]) * (x - atan(x)))
	)


## 轮胎的**视觉**滚动：全程在世界坐标里算，不碰"节点本地 z 是不是车头"这种约定 ——
##   1. 物理上正确的滚动角速度 `ω = up × v / 半径`（无滑移：轮子接地点相对地面静止）；
##   2. 轮胎自己的转轴在世界里的方向 = (轮子节点世界朝向 × child_basis) × (1,0,0)；
##   3. 把这根轴上的有符号角速度积分成角度，再作为**零件本地 x** 的旋转贴到网格上。
## 于是左右镜像、挂载翻转都不会造成"一半轮子倒着滚"。
## 有输出（force ≠ 0）时当成"多了一个 0.6 圈/秒的虚拟速度"，所以静止踩油门也看得出方向；
## 刹车（force = 0）不叠加，滑行时就是纯滚动，不会突然倒着转。
func _spin_tire(
	entry: Dictionary, flat_forward: Vector3,
	flat_velocity: Vector3, force: float, delta: float
) -> void:
	var mesh: MeshInstance3D = entry["mesh"]
	if mesh == null:
		return
	var node: Node3D = entry["node"]
	if node == null or not is_instance_valid(node):
		return
	var radius := float(entry["radius"])
	var visual_velocity := flat_velocity
	if force != 0.0:
		# 输出方向 = 车头方向（推力方向在 _add_wheel 里已经统一到车头一侧了）
		visual_velocity += flat_forward * (signf(force) * TIRE_SPIN_INDICATE * radius)
	var omega := Vector3.UP.cross(visual_velocity) / radius
	var child: Basis = entry["child_basis"]
	var frame := node.global_transform.basis * child
	var axle_world := (frame * Vector3(1, 0, 0)).normalized()
	# ⚠️ 轮胎网格挂在**零件本地坐标系**里，左右两侧的挂载可能是镜像的（det < 0）。
	# 在镜像帧里"绕本地 x 转 +θ"在世界里是绕 -x 转 θ —— 不乘 det 轮胎就全都在倒着滚
	# （实测：四轮同向度 -1.00），乘上才是物理上的向前滚。
	var rate := omega.dot(axle_world) * signf(frame.determinant())
	rate = clampf(rate, -TIRE_SPIN_MAX, TIRE_SPIN_MAX)
	entry["spin"] = float(entry["spin"]) + rate * delta
	# 绕**轮胎中心**（零件本地的 local_centre = 轮胎自己坐标系里的 y=16, z=16）转：
	# 平移量必须跟着旋转一起算 `-(child_basis × R × centre)`。
	# 曾经写成固定的 `-(child_basis × centre)` —— 那等于绕**零件原点**转，
	# 而零件原点到轮胎中心差 0.5 格，于是轮子一边转一边画圈（看着就是"随机乱转"）。
	var rotation := Basis(Vector3(1, 0, 0), float(entry["spin"]))
	mesh.transform = Transform3D(child * rotation, -(child * rotation * (entry["local_centre"] as Vector3)))


func _process(delta: float) -> void:
	_update_speedometer()
	# FPS / 物理耗时每 0.25 秒刷一次，方便回报卡不卡
	_hud_timer += delta
	if _hud_timer >= 0.25:
		_hud_timer = 0.0
		_update_hud()
	if _chassis == null or _camera == null:
		return
	# 环视相机：以车为圆心，鼠标控制 yaw/pitch（yaw 相对车头，pitch 相对**地面**），滚轮控制距离。
	# ⚠️ 整条视线都必须在**世界系**里算：
	#   先把车头投到地面上得到水平方向，再绕世界 UP 转 yaw，最后绕世界水平横轴转 pitch。
	# 以前的写法（`chassis.basis * Basis(BACK, pitch) * x`）是拿**车体**的上下当极轴 ——
	# 车一抬头/侧倾，视角的上下也跟着翻，手感很怪（用户报的）。
	# ⚠️ 相机必须用**渲染时刻**的变换（get_global_transform_interpolated），不能用
	# `global_transform`：后者是物理时刻的。物理 120Hz、渲染 ~120FPS 时两者能差一个整
	# 物理步的位移（实测 80 格/秒时差 0.65 格 ≈ 车长的 1/8），相位每帧还在变 ——
	# 表现就是**车在画面里来回漂（暂留/拖影），而静态的建筑物看着完全正常**（用户报的）。
	var chassis_xform := _chassis.get_global_transform_interpolated()
	var car_forward := chassis_xform.basis * Vector3(1, 0, 0)
	var flat_forward := car_forward - Vector3.UP * car_forward.dot(Vector3.UP)
	if flat_forward.length() < 0.05:
		flat_forward = Vector3.RIGHT
	flat_forward = flat_forward.normalized()
	# 鼠标环视是"相对什么"转：跟车 = 相对车头（车转弯画面跟着转）；
	# 不跟车 = 相对世界（`_camera_yaw` 就是世界朝向，车转弯画面不动）。两种模式下鼠标都能自由转。
	var yawed := camera_yaw_reference(flat_forward, _camera_follow).rotated(
		Vector3.UP, deg_to_rad(_camera_yaw)
	)
	var pitch_axis := yawed.cross(Vector3.UP).normalized()   # 世界水平横轴（右手系：正角度 = 抬头）
	var look_dir := yawed.rotated(pitch_axis, deg_to_rad(_camera_pitch)).normalized()
	# 旋转（瞄准）中心：x/z = 载具**重心**在世界的投影，y = **整车最高点 + CAMERA_CENTER_CLEARANCE**。
	# 最高点在当前姿态下算（把本地包围盒 8 个角变换到世界取最大 y），所以车翻滚/侧倾时
	# 中心跟着车走，不会突然窜到天上；重心也按当前姿态变换，翻过来时中心就贴在车上。
	var target := _camera_center(chassis_xform)
	var desired := target - look_dir * _camera_distance
	# 别让相机穿到墙外：从车心往相机方向打一条射线，撞到就贴上去
	var space := get_world_3d().direct_space_state
	if space != null:
		var query := PhysicsRayQueryParameters3D.create(target, desired)
		query.exclude = [_chassis.get_rid()]
		var hit := space.intersect_ray(query)
		if hit.has("position"):
			desired = (hit["position"] as Vector3) + look_dir * 0.25
	# 不做平滑（用户要"关了平滑视角"）：相机硬贴在环视位置上，转视角没有拖影
	_camera.global_position = desired
	if _camera.global_position.distance_to(target) > 0.01:
		_camera.look_at(target, Vector3.UP)


## 环视相机的**基准朝向**：鼠标的 `_camera_yaw` 是相对它转的。
##   跟车（follow = true）→ 车头的水平投影：车一转向，画面跟着转；
##   不跟（follow = false）→ 世界 +x：鼠标转的是世界绝对朝向，车怎么转画面都不动。
## 抽成静态函数是为了让这条语义能被测试钉住（见 test_robot.gd）。
static func camera_yaw_reference(flat_forward: Vector3, follow: bool) -> Vector3:
	return flat_forward if follow else Vector3.RIGHT


## 环视中心（世界坐标）：重心给 x/z，最高点 + CAMERA_CENTER_CLEARANCE 给 y。
## `chassis_xform` **必须**由调用方传**渲染时刻**的变换
## （`_chassis.get_global_transform_interpolated()`）—— 故意不给默认值，
## 免得以后有人顺手写成 `global_transform`（物理时刻），高速时车又会漂。
func _camera_center(chassis_xform: Transform3D) -> Vector3:
	var com_world := chassis_xform * _cam_center_local
	var top := -INF
	for i in 8:
		var corner := _cam_box_local.position + Vector3(
			_cam_box_local.size.x if (i & 1) != 0 else 0.0,
			_cam_box_local.size.y if (i & 2) != 0 else 0.0,
			_cam_box_local.size.z if (i & 4) != 0 else 0.0
		)
		top = maxf(top, (chassis_xform * corner).y)
	return Vector3(com_world.x, top + CAMERA_CENTER_CLEARANCE, com_world.z)


## 左上角速度表：车身速度换算到"你那套标定"（1 cube = CUBE_METERS 米）。
## 大数字是 km/h，下面小字是 cube/s（带正负：负 = 倒车）。
## 每帧刷，但只有文字变了才写回 Label（省一次重排）。
func _update_speedometer() -> void:
	if _speedo == null:
		return
	if _chassis == null or not is_instance_valid(_chassis):
		if _speedo.text != "0 km/h":
			_speedo.text = "0 km/h"
		return
	var velocity := _chassis.linear_velocity
	var speed := velocity.length()
	# 前进方向的速度（带符号），用来区分正开和倒车
	var forward := (_chassis.global_transform.basis * Vector3(1, 0, 0)).normalized()
	var signed_speed := velocity.dot(forward)
	var text := "%d km/h\n%s%.1f cube/s" % [
		roundi(speed * CUBE_METERS * 3.6),
		"-" if signed_speed < 0.0 else "",
		signed_speed,
	]
	if text != _speedo.text:
		_speedo.text = text


func _unhandled_input(event: InputEvent) -> void:
	# 鼠标 = 自由环视（相对车头）；滚轮 = 变焦。开车和瞄准都用它。
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sensitivity := GameSettings.mouse_sensitivity()  # 游戏设置里的灵敏度
		_camera_yaw = wrapf(
			_camera_yaw - event.relative.x * sensitivity, -180.0, 180.0
		)
		_camera_pitch = clampf(
			_camera_pitch - event.relative.y * sensitivity, CAMERA_MIN_PITCH, CAMERA_MAX_PITCH
		)
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera_distance = maxf(CAMERA_MIN_DISTANCE, _camera_distance - 0.8)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera_distance = minf(CAMERA_MAX_DISTANCE, _camera_distance + 0.8)
			return
	if event is InputEventKey and event.pressed:
		# 找出生点的推车键（和机库一样）：↑↓←→ + < >。允许按住连发（自己节流，
		# 比键盘 echo 稳），所以这一支要排在下面那个 `not event.echo` 闸门前面。
		var nudge := nudge_delta_for_key(event.keycode)
		if nudge != Vector3.ZERO:
			var now := Time.get_ticks_msec()
			if not (event.echo and now - _last_nudge_ms < 110):
				_last_nudge_ms = now
				_nudge_vehicle(nudge)
			return
	if event is InputEventKey and event.pressed and not event.echo:
		# 现场调场地缩放：`[` 缩小、`]` 放大（定了倍数告诉我，我改 ARENA_SCALE 默认值）
		if event.keycode == KEY_BRACKETLEFT:
			_rescale_arena(1.0 / ARENA_SCALE_STEP)
			return
		if event.keycode == KEY_BRACKETRIGHT:
			_rescale_arena(ARENA_SCALE_STEP)
			return
		# O = 显示/隐藏重心（帮你看驾驶手感：重心多高、在前后轴之间偏哪儿）
		if event.keycode == KEY_O:
			_toggle_com_marker()
			return
		if event.keycode == KEY_ESCAPE:
			# 走之前把鼠标放出来，否则回到主界面点不到东西
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			get_tree().change_scene_to_file(MENU_SCENE)
