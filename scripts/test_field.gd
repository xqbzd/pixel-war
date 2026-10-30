extends Node3D
class_name TestField

## 测试场：把载具按物理摆进一整块现成场地（Truck Town 的城镇 + 赛道模型）里，验证轮子能不能跑。
##
##   - 轮轴（`is_wheel()` 的部件，见 `PartDef.wheel_body_model`）→ **自定义轮胎节点**：
##     从轮心朝圆周打 16 条等距射线
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
##   - WASD 开车（W/S 油门·反向、A/D 全轮转向），环视相机，ESC 弹暂停菜单。
##     空格**不参与**驾驶（改成开火了），反方向键自动先刹车（见 REVERSE_BRAKE_SPEED_CUBES）。

const MENU_SCENE := "res://scenes/main_menu.tscn"
const VEHICLE_DIR := "res://data/vehicles"
const GameSettings := preload("res://scripts/game_settings.gd")
## 世界音效（距离衰减 + 左右声道）：开火声和所有车的引擎声都用它算
const SpatialAudio := preload("res://scripts/spatial_audio.gd")
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
## 相机：绕"环视中心"（见 CAMERA_CENTER_CLEARANCE）自由环视，不自动回正。
## **镜头远近是固定的**（CAMERA_DISTANCE）—— 滚轮调的是**视野 FOV**，不是远近：
## 调 FOV 时车在画面里会变大变小、但相机和车之间的距离不变（视角中心也不动）。
## 中心抬到车上 10 米之后，8 米的距离会把车挤出画面，所以距离取大一点
## （70° FOV 下 28 米时，车大约落在画面下缘往上一点）。
const CAMERA_DISTANCE := 28.0
## 相机被墙/掩体挤到最近时也不小于这个距离（格）。
## ⚠️ 太小会让 `look_at` 的方向变成零向量 → 相机朝瞬间失效（画面闪一下另一个视角），
## 而且会钻进车里看见内壁。8 格 = 4 米，比车身还长，稳定。
const CAMERA_MIN_DISTANCE := 8.0
## 单帧鼠标事件的 relative 上限（像素）：超过就当"系统跳变"忽略，见 `_unhandled_input()`
const MOUSE_MAX_DELTA := 220.0
## 腰射（不按右键）的视野：滚轮在 FOV_MIN ~ FOV_MAX 之间调，每格 ±FOV_STEP 度。
## 2026-10-18 用户要求："拉远的最大 FOV 太远了"——只改上限：最窄 30° 不动，
## 可调行程从 70° 缩到 23°（约 1/3），默认视野 = 上限 53°（滚轮只能往里收）。
const CAMERA_FOV := 53.0
const CAMERA_FOV_MIN := 30.0
const CAMERA_FOV_MAX := 53.0
const CAMERA_FOV_STEP := 2.5
## 视野变化速度（度/秒）：0 = 瞬间到位。默认 70→4 度约 0.12 秒，
## 这样**按住右键是"刷"地推近**、松开是"刷"地拉回，而不是咔一下跳（会晕）。
const CAMERA_FOV_SPEED := 540.0
## 右键按住 = 开镜（动作名，见 `ensure_actions()`；走 InputMap 是为了无头测试也能按）。
## 开镜后的视野 = 腰射视野 ÷ 倍率（2 倍镜 = 视野减半），滚轮改的是**倍率**。
## 倍率在**这一场**里记住：松开右键不清零，下次按下去还是上次那个倍数。
const SCOPE_ACTION := "aim_scope"
const SCOPE_ZOOM_MIN := 2.0
const SCOPE_ZOOM_MAX := 16.0
## 每格滚轮的倍率变化（乘法）：2→2.5→3.1→…→16 一共 10 格，各倍率下手感一致。
const SCOPE_ZOOM_STEP := 1.25
const SCOPE_ZOOM_DEFAULT := 2.0
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
## 标记敌人（对战模式：准星对准敌人按 Q —— 见 `BattleMode._try_mark_target()`）
const MARK_KEY := KEY_Q
const MARK_ACTION := "mark_target"
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

## ── 队伍 / 碰撞层 ──────────────────────────────────────────────────────────
## 地形 = 1；两台车按**队伍**分层（2 = 我方、3 = 敌方）。这样"谁能撞谁"只看层，
## 而敌我判定走 `VehicleRig.team`（不看层）—— 人类玩家 / 人机队友 / 人机敌人都是同一套代码。
const TEAM_PLAYER := 0
const TEAM_ENEMY := 1
const WORLD_LAYER := 1
const TEAM_LAYER_PLAYER := 2
const TEAM_LAYER_ENEMY := 3
const TEAM_LAYERS := [TEAM_LAYER_PLAYER, TEAM_LAYER_ENEMY]

## ── 武器（转塔）──────────────────────────────────────────────────────────
## 瞄点 = 从**相机沿准星（屏幕中心）**打一条射线，取与"敌人或地形"的**首个交点**；
## 打不到（对着天）就用射线远端。转塔再朝这个点转（见 scripts/turret.gd）。
## 碰撞层：1 = 场地、2 = 我方车体、3 = 敌方车体（子弹/准星都能认，不用改代码）。
const AIM_LAYERS := WORLD_LAYER | TEAM_LAYER_PLAYER | TEAM_LAYER_ENEMY | HITBOX_LAYER
## 射线长度（格）：射线本身是无限长的，这里只是"打不到东西时瞄哪儿"的近似远端。
## 要够长 —— 靶子摆在**测试场外圈**（离城镇中心 135 模型单位 = 675 格），
## 准星得能瞄到它们（600 格会半路打在地面上，转塔就一直对着近处的地）。
const AIM_RANGE := 2500.0
## 瞄点标记球半径（格）—— 调武器时能直接看见转塔在对准哪儿。
const AIM_MARKER_RADIUS := 0.12
## 重心显示（按 O 开关）：球 + 一条垂到地面的线 + 地面上的投影点。
## 调驾驶手感时最该看的两个数就是"重心多高、在前后轴之间偏哪儿"。
## 具体形状在 `scripts/com_marker.gd`（建造界面共用同一个）。
## 敌方（靶子）碰撞层：和"对战模式里的敌人"同一层，`AIM_LAYERS` 已经包含它。
const ENEMY_LAYER := TEAM_LAYER_ENEMY
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
## `data/parts/toywheel2x2/toy_wheel_2x2.part.txt`（键名 = `wheel_` + 这里的小写名，
## 见 `PartDef` 的"自定义整圈射线轮胎的手感旋钮"一段），测试场按**部件文件**里的值跑。
## 这里改只影响"没写那一行的轮轴"。
const WHEEL_RAYS := 8    # 0 = 纯单射线模式（只留悬挂那条射线 = 最早的单射线手感）
## 人机 / 靶子每个轮子的整圈射线数（玩家用 `WHEEL_RAYS`）：10 台车一起跑时这是最贵的一项
const BOT_WHEEL_RAYS := 0
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
var _turrets := []         # [Turret] —— 玩家车的转塔（= `_player_veh["turrets"]` 本身）
var _player_rig: VehicleRig # 玩家车的车体（零件血量 / 碰撞盒 / 分组视觉）
var _enemies := []         # [VehicleRig] —— 测试场的靶子 / 对战模式里的敌方
## 每台车一条：{rig, chassis, wheels, turrets, is_player, team, owner_key, centre, ...}。
## 轮胎物理对所有车一视同仁 —— 玩家车读键盘输入，人机由子类（对战模式）喂输入，
## 测试场的靶子输入恒为 0（所以它们只是"站得住、推得动"的完整刚体）。
## （`_wheels` / `_turrets` / `_clip_boxes` 就是玩家那条记录的数组本身，camera/HUD 还认它们。）
var _vehicles := []
var _player_veh := {}      # `_vehicles` 里玩家那一条（对战模式要按队伍统计，靠它认人）
var _vehicles_by_rid := {} # RID -> VehicleRig（子弹打中谁，靠它反查）
## 开火者键 -> 队伍：友军伤害判定用（`owner_key` 见 `_spawn_vehicle()`）。
var _team_of_key := {}
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
## 镜头视野（度）：腰射时滚轮直接改它；开镜时按倍率换算，见 `target_fov()`。
var _fov := CAMERA_FOV
## 开镜倍率（2~16）：滚轮在开镜时改它 —— **收镜不清零**，单场内一直记着。
var _scope_zoom := SCOPE_ZOOM_DEFAULT
## 右键是不是按住（每帧从 InputMap 同步，见 `_process`）。
var _scoped := false
## 镜头是否**跟着车头转**（设置里的开关，见 GameSettings.camera_follow）：
## 两种模式下鼠标都能自由环视，区别只在"鼠标转的是哪种角度"：
##   开 = `_camera_yaw` 是**相对车头的偏移** → 车一转向，画面跟着转（车头始终在正前方）；
##   关 = `_camera_yaw` 是**世界坐标系里的绝对朝向** → 车原地打转时画面一动不动（鼠标照样能环视），
##        想让车回到画面正前方得自己用鼠标找。
var _camera_follow := true
var _crosshair: Control
## 开镜遮罩（镜筒 + 十字分划 + 右侧倍率滑条），只在开镜时淡入 —— 见 scripts/scope_overlay.gd
var _scope_overlay: ScopeOverlay
## ESC 暂停菜单（返回战斗 / 游戏设置 / 自爆 / 返回主界面）—— 测试场和对战共用
var _pause_menu: PauseMenu
## 世界音效的声部池（开火声）：10 台车一起开火时能叠，轮着用。
## 引擎声不走这里 —— 每台车一个长期循环的 3D 声部（存在 veh["audio"]）。
var _sfx_pool: Array[AudioStreamPlayer3D] = []
var _sfx_next := 0
## 引擎音效的调参缓存：`GameSettings.engine_*()` 每次都要读文件字典，10 台车 × 120 Hz 时
## 光这几组取值就是 1 ms+/tick（实测）—— 进场缓存一次，改完设置重新进一局就生效。
var _eng_pitch_low := 1.0
var _eng_pitch_high := 1.6
var _eng_ramp := 0.35
var _eng_db_idle := -34.0
var _eng_db_full := -8.0
## F1：HUD 上显示"车坐标 / 准星落点"（米）—— 手动摆放场地时照着抄数字用
var _show_coords := false
## 零件摧毁时的体素碎片（纯视效；`Debris` = 一个 MultiMesh 装所有碎块）
var _debris: Debris
## 这一物理帧攒下来的伤害（`VehicleRig` -> {parts: {零件: 伤害}, point: 命中点, hits: 发数}）
## 高射速武器不逐发结算，帧末按零件合并（见 `_on_projectile_hit` / `_flush_damage_batches`）
var _damage_batches := {}




func _ready() -> void:
	# 只建一次：脚本被重复 ready（编辑器/重载）时不能把场地和车再建一遍 ——
	# 重复建的表现就是 draw / 图元成倍上涨、帧率断崖。
	if _built:
		return
	_built = true
	# 测试场里不放大厅那首循环音乐 —— 这里该听的是引擎声和枪声
	GameSettings.stop_music()
	# 提前把开火音**加载**进来（只是读盘 + 解码一次）：第一次开枪时再加载会卡一下，
	# 而"第一次开枪"恰好就是开局交火那一下。
	GameSettings.shot_stream()
	ensure_actions()
	_library.load_all()
	_collect_render_info()
	_build_arena()
	_build_debris()
	_build_camera()
	_build_hud()
	_build_pause_menu()
	# 镜头跟不跟车头转：设置里的开关（读一次就够 —— 设置界面不在测试场里）
	_camera_follow = GameSettings.camera_follow()
	_cache_engine_audio()
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
	# 开镜：鼠标右键按住（和开火一样走动作，方便无头测试按）
	if not InputMap.has_action(SCOPE_ACTION):
		InputMap.add_action(SCOPE_ACTION)
	if InputMap.action_get_events(SCOPE_ACTION).is_empty():
		var scope_mouse := InputEventMouseButton.new()
		scope_mouse.button_index = MOUSE_BUTTON_RIGHT
		InputMap.action_add_event(SCOPE_ACTION, scope_mouse)
	# 手动标记：Q（对战模式里准星对准敌人按一下，立刻点亮；测试场里没人可标）
	if not InputMap.has_action(MARK_ACTION):
		InputMap.add_action(MARK_ACTION)
	if InputMap.action_get_events(MARK_ACTION).is_empty():
		var mark_key := InputEventKey.new()
		mark_key.keycode = MARK_KEY
		InputMap.action_add_event(MARK_ACTION, mark_key)


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
	var path := VehicleStore.find_path(vehicle_id)
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
		+ "鼠标环视瞄准 · 滚轮调视野 · 右键按住开镜（开镜时滚轮调 2~16 倍）\n"
		+ "[ ] 缩放场地 · O 显示重心 · ESC 暂停菜单\n"
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
	# 射弹管理先建：车队（对战模式）里的每台车都要往 `owner_rids` 里登记，子弹才不会打自己
	_projectiles = Projectiles.new()
	_projectiles.name = "Projectiles"
	add_child(_projectiles)     # 挂在**场地根**上（世界系）：子弹不能跟着车走
	_projectiles.gravity = _world_gravity()
	_projectiles.layers = AIM_LAYERS
	# 命中过滤器：打掉的零件还留在受击盒几何里（重建限流 0.2 秒）时让子弹**穿过去**，
	# 否则就是"虚空挡伤害"（用户 2026-10-19 报的）
	_projectiles.hit_filter = Callable(self, "_hit_is_real")
	_projectiles.hit.connect(_on_projectile_hit)
	# 玩家车：一条普通 `_vehicles` 记录（和靶子/人机同一套轮胎物理与毁伤）
	_player_veh = _spawn_vehicle(
		vehicle, TEAM_PLAYER, _player_spawn_transform(actual), _spawn_center,
		true, PLAYER_KEY, "我方"
	)
	_chassis = _player_veh["chassis"]
	_player_rig = _player_veh["rig"]
	_wheels = _player_veh["wheels"]
	_turrets = _player_veh["turrets"]
	_clip_boxes = _player_veh["clip_boxes"]
	_cam_box_local = _player_rig.bounds_local()
	_cam_center_local = _chassis.center_of_mass
	_energy = float(_player_veh["energy"])
	_energy_max = float(_player_veh["energy_max"])
	_energy_regen = float(_player_veh["energy_regen"])
	# 瞄点标记（调武器时直接看转塔在瞄哪儿）
	if not _turrets.is_empty():
		_build_aim_marker()
	# 靶子 / 队友 / 敌人：测试场是"我方载具的复制品"，对战模式由子类换成真人机队伍
	_spawn_enemy_replicas(vehicle)
	# 轮胎也算进"整车最高点"（虽然一般比车身低，但先算全了免得漏）
	for entry in _wheels:
		var wheel: Node3D = entry["node"]
		var radius: float = entry["radius"]
		_cam_box_local = _cam_box_local.merge(
			AABB(wheel.position - Vector3(radius, radius, radius), Vector3(radius, radius, radius) * 2.0)
		)
	_update_hud()


## 玩家出生点（世界坐标 + 车头朝向）：测试场在城镇模型上竖直探地面；
## 对战模式覆盖成"我方这一侧的出生区"（见 `battle_mode.gd`）。
func _player_spawn_transform(actual: AABB) -> Transform3D:
	return Transform3D(Basis(), _chassis_spawn_point(actual))


## 一台载具进场的**通用**流程（玩家 / 友军 / 人机敌人都走这一条）：
## 底盘刚体 + 车体（VehicleRig）+ 轮胎 + 转塔 + 能量池。返回 `_vehicles` 里的那条记录。
##
## `centre` = 载具坐标系里的包围盒中心（每台车自己的，**不能**共用玩家的 `_spawn_center`）。
## `team` = TEAM_PLAYER / TEAM_ENEMY，决定碰撞层与友军伤害；
## `owner_key` = 射弹归属键（`Projectiles.owner_rids` 里一一对应）。
func _spawn_vehicle(
	vehicle: VehicleDef, team: int, xform: Transform3D, centre: Vector3,
	is_player: bool, owner_key: String, label: String
) -> Dictionary:
	var chassis := RigidBody3D.new()
	chassis.name = "Chassis_%s" % owner_key
	# 悬挂是每帧自己施力的：刚体一旦睡着就不再受力，车会"僵"在原地 —— 别让它睡
	chassis.can_sleep = false
	chassis.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	# 只和地形 + 两台车碰撞（自己的层也在掩码里：车和车撞，不分敌我）
	chassis.collision_layer = int(TEAM_LAYERS[team])
	chassis.collision_mask = WORLD_LAYER | TEAM_LAYER_PLAYER | TEAM_LAYER_ENEMY
	chassis.transform = xform
	add_child(chassis)

	# 车体 = VehicleRig：一个零件一个碰撞盒 + 按 (部件, 路线) 分组的视觉。
	# **所有**车辆的武器都由 `Turret` 节点画（枪管要转），静态网格里跳过武器。
	var rig := VehicleRig.new()
	rig.team = team
	rig.label_text = label
	rig.static_skip_weapon = true
	rig.setup(vehicle, _library, chassis, chassis, true, -centre)
	var entry := {
		"rig": rig, "chassis": chassis, "wheels": [], "turrets": [],
		"is_player": is_player, "team": team, "owner_key": owner_key,
		"centre": centre, "vehicle": vehicle, "clip_boxes": [],
		"aim_point": Vector3.ZERO, "wants_fire": false,
		"energy": 0.0, "energy_max": 0.0, "energy_regen": 0.0, "alive": true,
		# 头顶血条 / 小地图要用的东西：车名（人机就用载具名）+ 车高（血条挂头顶）
		"display_name": (
			vehicle.display_name if not vehicle.display_name.is_empty() else vehicle.id
		),
		"height": rig.geometry_bounds_local().size.y,
	}
	_vehicles.append(entry)
	_vehicles_by_rid[chassis.get_rid()] = rig
	if rig.hitboxes != null:
		# 轮胎那种"只给子弹看"的受击盒是独立 body：也登记到这台车上
		_vehicles_by_rid[rig.hitboxes.get_rid()] = rig
	_team_of_key[owner_key] = team
	# 轮子：每个轮轴一个自定义轮胎节点（轮胎网格挂它下面，整圈射线在 _apply_wheel 里算）
	_initialize_vehicle_wheels(entry, vehicle.wheel_specs(_library))
	# 武器：每个转塔一个节点组（底座固定 / 支架水平 / 枪管俯仰）
	_add_turrets(entry, vehicle)
	entry["clip_boxes"] = _collect_clip_boxes(rig, vehicle)
	# 能量池（核心提供；人机也一样要能量才能开火）
	var energy := _core_energy(vehicle)
	entry["energy_max"] = energy.x
	entry["energy_regen"] = energy.y
	entry["energy"] = energy.x
	if _projectiles != null:
		# 子弹射线**忽略车体**（车体只有整车包围盒），零件级命中走 `hitboxes` 那张 trimesh。
		# 自己车的判定要把车体 + 受击盒都登记（两个都算"自己"）。
		_projectiles.ignore_rids.append(chassis.get_rid())
		var own_rids: Array = [chassis.get_rid()]
		var rig_for_hit: VehicleRig = entry.get("rig")
		if rig_for_hit != null and rig_for_hit.hitboxes != null:
			own_rids.append(rig_for_hit.hitboxes.get_rid())
		_projectiles.owner_rids[owner_key] = own_rids
	if not (entry["turrets"] as Array).is_empty():
		_refresh_vehicle_arcs(entry)
	print("[进场] %s（队伍 %d）：零件 %d，轮轴 %d，转塔 %d" % [
		label, team, vehicle.parts.size(), (entry["wheels"] as Array).size(),
		(entry["turrets"] as Array).size(),
	])
	return entry


## 给一台车建转塔节点（玩家 / 人机通用），把零件下标记在节点 meta 上（零件被打掉时清）。
func _add_turrets(veh: Dictionary, vehicle: VehicleDef) -> void:
	var chassis: RigidBody3D = veh["chassis"]
	var centre: Vector3 = veh["centre"]
	var turrets: Array = veh["turrets"]
	for i in vehicle.parts.size():
		var def: PartDef = _library.get_def(str(vehicle.parts[i]["part_id"]))
		if def == null or def.weapon != "turret":
			continue
		var place := BuildGrid.cell_transform(def, vehicle.parts[i]["cell"], vehicle.parts[i]["basis"])
		place.origin -= centre
		var turret := Turret.new()
		chassis.add_child(turret)
		var problem: String = turret.setup(def, place, _library)
		if not problem.is_empty():
			if bool(veh["is_player"]):
				_turret_problem = "%s：%s" % [str(def.id), problem]
			push_warning("转塔 %s（%s）—— %s" % [str(def.id), str(veh["owner_key"]), problem])
		turret.set_meta("part_index", int(i))
		turrets.append(turret)


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
		# 掩码：撞地形 + 撞两台车（自己的层也在里面）
		chassis.collision_mask = WORLD_LAYER | TEAM_LAYER_PLAYER | TEAM_LAYER_ENEMY
		chassis.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		add_child(chassis)
		var rig := VehicleRig.new()
		rig.team = TEAM_ENEMY
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
		var entry := {
			"rig": rig, "chassis": chassis, "wheels": [], "turrets": [],
			"is_player": false, "team": TEAM_ENEMY, "owner_key": "target%d" % i,
			"centre": _spawn_center, "vehicle": vehicle, "clip_boxes": [],
			"aim_point": Vector3.ZERO, "wants_fire": false, "alive": true,
		}
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
	body_rid: RID, shape_index: int, position: Vector3, damage: float, owner_key: String
) -> void:
	var rig: VehicleRig = _vehicles_by_rid.get(body_rid)
	if rig == null:
		return                       # 地形之类：火花已经放过了，这里没事可做
	if rig == _player_rig and owner_key == PLAYER_KEY:
		return                       # 兜底：打自己（Projectiles 那边已经处理）
	# **友军伤害关掉**：队友打队友不掉血（火花照放）。敌方打敌方同理 —— 对战模式里
	# 人机一多，误伤会让"谁在打谁"完全看不懂；判定只看队伍，不看碰撞层。
	var shooter_team := int(_team_of_key.get(owner_key, -1))
	if shooter_team >= 0 and rig.team == shooter_team:
		return
	# ── 伤害**打包**：高射速机炮一秒能打几十上百发，逐发结算的话每一发都要走
	# ① 命中点反查零件（原来每发扫一遍 300 个盒子）、② `apply_damage()`（连通性检查 /
	# 禁用 shape / 同步质量重心）+ 一套毁伤善后 —— 集中交火时就是掉帧的主因。
	# 现在这里**两个都不做**，只把（命中点, 伤害）记进队列，每物理帧末统一结算一次：
	# 同一零件这一帧吃的伤害加起来、只调一次 apply_damage、零件反查也只在帧末做一遍。
	# 参考做法：Unity 的 `RaycastCommand.ScheduleBatch`（一批射线合并成一个 job）、
	# 以及"每 tick 结算一次伤害"的服务器模型（低 tick 率有假命中/延迟的取舍）。
	var part := rig.part_index_at(position)
	if part < 0 or not rig.part_alive(part):
		return
	var batch: Dictionary = _damage_batches.get(rig, {})
	var parts: Dictionary = batch.get("parts", {})
	parts[part] = float(parts.get(part, 0.0)) + maxf(0.0, damage)
	batch["parts"] = parts
	batch["point"] = position
	batch["count"] = int(batch.get("count", 0)) + 1
	_damage_batches[rig] = batch


## 把这一物理帧攒下来的伤害**按车、按零件合并**结算一次（见 `_on_projectile_hit`）。
func _flush_damage_batches() -> void:
	if _damage_batches.is_empty():
		return
	var batches := _damage_batches
	_damage_batches = {}
	for key in batches.keys():
		var rig: VehicleRig = key
		if rig == null or not is_instance_valid(rig):
			continue
		var batch: Dictionary = batches[key]
		var point: Vector3 = batch.get("point", Vector3.ZERO)
		var parts: Dictionary = batch.get("parts", {})
		if parts.is_empty():
			continue
		var dead := []
		var changed := false
		# 整车的伤害**一次结算**（`apply_damage_batch`）：连同连通性判定、质量/重心同步、
		# shape 禁用都只做一遍。逐个零件调 `apply_damage()` 时，每死一个零件就要重跑一次
		# `detached_parts()`（541 件的车 2.25 ms）+ 一次 `sync_body()`（原 2.9 ms）——
		# 一帧掉 3 个零件就是 15 ms 的纯浪费（实测 20.35 → 见 tools/repro_firefight.gd）。
		var result := rig.apply_damage_batch(parts)
		changed = bool(result["mass_changed"])
		var destroyed := (result["destroyed"] as Array).size()
		dead.append_array(result["destroyed"])
		dead.append_array(result["detached"])
		# 跨队命中（友军伤害在 `_on_projectile_hit` 已经挡掉）—— 对战模式用它做"被命中就点亮"
		_on_vehicle_damaged(rig)
		if not changed:
			_last_hit = "%s 这一帧吃了 %d 发（没掉零件）" % [rig.label(), int(batch.get("count", 1))]
			continue
		_last_hit = "%s 这一帧 %d 发打掉 %d 个零件（溢流 %d）" % [
			rig.label(), int(batch.get("count", 1)), dead.size(), destroyed
		]
		_on_parts_destroyed(rig, dead, point)


## 手动标记（Q）：测试场里没有敌人，什么也不做 —— 对战模式覆盖它。
func _on_mark_pressed() -> void:
	pass


## 某台车被子弹打中（友军伤害在上面已经挡掉了）—— 对战模式用它做"被命中就点亮"。
func _on_vehicle_damaged(_rig: VehicleRig) -> void:
	pass


## 零件被消灭之后，挂在这些零件上的东西要一起清掉：
## 轮胎（整圈射线那套）和转塔节点。玩家车和靶子走同一条路。
func _on_parts_destroyed(rig: VehicleRig, dead: Array, hit_point := Vector3.ZERO) -> void:
	var dead_set := {}
	for index in dead:
		dead_set[int(index)] = true
	# 轮胎：按**这台车**自己的记录删（玩家车 / 靶子一视同仁；`_wheels` 就是玩家那条数组本身）
	# 轮胎 + 转塔：按**这台车**自己的记录删（玩家 / 靶子 / 人机一视同仁）
	for veh in _vehicles:
		if veh["rig"] != rig:
			continue
		# 射界的原料（`clip_boxes`）：只有死掉的那几件变了 —— **就地置空**，不整表重建
		# （旧写法每次掉零件都重建 541 个字典，探针里算在「善后/射界」里）。
		var clip: Array = veh.get("clip_boxes", [])
		for index_dead in dead_set.keys():
			var dead_index := int(index_dead)
			if dead_index >= 0 and dead_index < clip.size():
				(clip[dead_index] as Dictionary)["box"] = AABB()
		var wheels: Array = veh["wheels"]
		for i in range(wheels.size() - 1, -1, -1):
			if not dead_set.has(int(wheels[i]["part_index"])):
				continue
			var wheel_node: Node3D = wheels[i]["node"]
			if wheel_node != null and is_instance_valid(wheel_node):
				wheel_node.queue_free()
			wheels.remove_at(i)
		var turrets: Array = veh.get("turrets", [])
		for i in range(turrets.size() - 1, -1, -1):
			var turret: Turret = turrets[i]
			if not dead_set.has(int(turret.get_meta("part_index", -1))):
				continue
			if is_instance_valid(turret):
				turret.queue_free()
			turrets.remove_at(i)
		# 零件掉了之后体积盒 / 真实射界都变了 —— 但**不是每台转塔都要重算**：
		# 射界只关心"转点 → 枪口"那一小段，离得远的零件掉不掉跟它没关系
		# （实测一台转塔重扫要 1.1 ms，你这台车 6 台 = 6.7 ms/轮）。
		# 这里只把**真被影响**的转塔排进队列，帧末再按队列逐台重算（每帧 1 台）。
		var affected: Array = []
		if not turrets.is_empty():
			var dead_boxes: Array = []
			for index in dead_set.keys():
				var dead_box: AABB = rig.part_box(int(index))
				if dead_box.size.length() > 0.001:
					dead_boxes.append(dead_box)
			for turret in turrets:
				if not is_instance_valid(turret):
					continue
				for dead_box in dead_boxes:
					if (turret as Turret).may_be_affected_by(dead_box):
						affected.append(turret)
						break
		# 零件炸成体素碎片：纯视效（不参与物理），颜色取零件体素的平均色
		_spawn_debris(veh, rig, dead_set, hit_point)
		if not affected.is_empty():
			var queue: Array = veh.get("arc_queue", [])
			queue.append_array(affected)
			veh["arc_queue"] = queue
			veh["arc_dirty"] = true
	if rig.state.alive_count() == 0:
		_on_vehicle_eliminated(rig)


## 这一发打中的东西是不是"还活着"：打掉的零件在受击盒几何里还会残留最多 0.2 秒（重建限流），
## 打在这种"已经不存在的零件"上必须当作没打中 —— 子弹穿过去继续飞，而不是被吞掉。
func _hit_is_real(body_rid: RID, shape_index: int, position: Vector3) -> bool:
	var rig: VehicleRig = _vehicles_by_rid.get(body_rid)
	if rig == null:
		return true                       # 地形 / 看不到的车：照常结算
	return rig.part_index_of_hit(body_rid, shape_index, position) >= 0


## 载具命中查询：**体素 DDA**（`VehicleRig.raycast_hit`），不走物理形状。
## 载具身上已经没有任何受击 trimesh，所以这一层是子弹打零件的唯一入口。
## `exclude` 里是这一发已经穿过的刚体（自己的车 / 打穿的车），车体 rid 对得上就跳过。
func _query_vehicle_hit(from: Vector3, to: Vector3, exclude: Array) -> Dictionary:
	var best := {}
	var best_distance := INF
	for entry: Dictionary in _vehicles:
		var rig: VehicleRig = entry.get("rig")
		if rig == null or rig.body == null or not is_instance_valid(rig.body):
			continue
		if exclude.has(rig.body.get_rid()):
			continue
		var hit := rig.raycast_hit(from, to)
		if hit.is_empty():
			continue
		var distance := from.distance_squared_to(hit["position"])
		if distance >= best_distance:
			continue
		best_distance = distance
		best = {
			"collider": rig.body,
			"shape": -1,
			"position": hit["position"],
			"normal": hit["normal"],
		}
	return best


## 零件被摧毁：炸出一簇体素碎片（纯视效，不参与物理）。
## `hit_point` = 子弹的命中点：碎片**就爆在打中的地方**。以前按"每个死零件盒的中心"爆，
## 而一发穿透串起来的断连零件可能分布在全车（甚至另一头），看着就是"打这里、别处虚空爆"
## （用户 2026-10-19 报的）。现在以命中点为准，只保留命中点附近的零件位置。
const DEBRIS_HIT_RADIUS := 2.5

func _spawn_debris(
	veh: Dictionary, rig: VehicleRig, dead: Dictionary, hit_point := Vector3.ZERO
) -> void:
	if _debris == null or not is_instance_valid(_debris):
		return
	var body: Node3D = rig.body
	if body == null or not is_instance_valid(body):
		return
	var inherit := Vector3.ZERO
	var chassis: RigidBody3D = veh.get("chassis")
	if chassis != null and is_instance_valid(chassis):
		# 只继承一小部分车速：碎片是要"炸在原地"，不是被车带着飞（继承太多时
		# 高速行驶的车身后会拖一串碎片，看着像"别处在虚空爆"，用户 2026-10-19 报的）
		inherit = chassis.linear_velocity * 0.35
	var xform := body.global_transform
	for index in dead.keys():
		var part := int(index)
		var box: AABB = rig.part_box(part)
		if box.size.length() < 0.01:
			continue
		var centre := xform * box.get_center()
		var at := centre
		if hit_point != Vector3.ZERO:
			# 离命中点太远的零件（断连/溢流）不在它自己的位置爆，免得看着像"虚空爆炸"
			if centre.distance_to(hit_point) > DEBRIS_HIT_RADIUS:
				continue
			at = hit_point
		# 碎片颜色直接来自零件：从它的体素颜色表里每块随机挑一个（多色零件炸出来是混色的）
		var palette := PackedColorArray([Color(0.72, 0.72, 0.72)])
		if part >= 0 and part < rig.state.parts.size():
			var def: PartDef = _library.get_def(str(rig.state.parts[part]["part_id"]))
			if def != null:
				palette = def.debris_palette()
		_debris.burst_colours(at, palette, inherit, Debris.CHUNKS_PER_PART)


## 一台车被打光：基类只记"打光了几台靶子"；对战模式覆盖它来统计队伍 / 判胜负。
func _on_vehicle_eliminated(rig: VehicleRig) -> void:
	# 自己自爆不算"打光一台靶子"
	if rig != _player_rig:
		_kills += 1
	for veh in _vehicles:
		if veh["rig"] == rig:
			veh["alive"] = false
			veh["wants_fire"] = false
			break


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
	# 每台车自己的包围盒中心（玩家 / 人机车型不同，不能共用 `_spawn_center`）。
	# 老调用方（测试里手搓的 veh）没写 centre 时退回玩家车那个。
	var centre: Vector3 = veh.get("centre", _spawn_center)
	var place: Transform3D = spec["transform"]
	var offset: Vector3 = (spec["offset"] as Vector3) - centre
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
			outboard_shift(offset + centre, centre, axis, def.wheel_ray_offset),
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
		# 人机 / 靶子的整圈射线压到 `BOT_WHEEL_RAYS`（默认 4）：
		# 10 台车 × 10 根轴 × 16 条射线是测试场里最贵的一项（实测每 tick 6 ms+），
		# 而人机不需要玩家那么精确的悬挂手感（它们走开阔地，靠前向射线绕障碍）。
		if not bool(veh.get("is_player", true)):
			rays = mini(rays, BOT_WHEEL_RAYS)
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
		# 转向行程比例：最前/最后的轮轴 1.0，中间的按离中点距离缩小（见 VehicleDef.steer_travel_factor）
		"steer_factor": float(spec.get("steer_factor", 1.0)),
		"steer": 0.0,                 # 当前转角（弧度，带 steer_sign 的符号）
		"hub": hub,                   # 悬挂硬点（底盘本地坐标）
		# 悬挂/整圈射线共用的排除表（只排自己的车体）：预先建一次，射线循环里复用
		"exclude": [chassis.get_rid()],
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


## 零件碎片系统（纯视效）：一个 MultiMesh 节点，挂在整个场景里（世界坐标）。
func _build_debris() -> void:
	_debris = Debris.new()
	_debris.name = "Debris"
	add_child(_debris)


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
	_camera.fov = _fov
	# 初始位置只是个占位：每帧由 _process 按 yaw/pitch/固定距离重算
	_camera.position = Vector3(-CAMERA_DISTANCE, 3.0, 0.0)
	add_child(_camera)


func _build_hud() -> void:
	# 开镜遮罩：**先加**（画在最底下），这样左上角的速度表/HUD 文字不会被压黑。
	# 它自己按开镜状态淡入淡出，平时 alpha = 0、几乎不花时间。
	_scope_overlay = ScopeOverlay.new()
	_scope_overlay.name = "ScopeOverlay"
	_scope_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_scope_overlay)
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
	_hud.text = "%s · %s\n%s\nFPS %d   draw %d   图元 %d   物理 %.1f ms" % [
		_hud_title(),
		name,
		_status,
		Engine.get_frames_per_second(),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
	]
	if not _render_info.is_empty():
		_hud.text += "\n渲染：%s" % _render_info
	# 下面这几行是**测试场专用**的调试信息（对战模式会关掉）
	if _show_debug_hud():
		# 场地缩放：按 `[` `]` 现场调，定了倍数就去改 ARENA_SCALE
		_hud.text += "\n场地缩放 ×%.2f（[ 缩小 · ] 放大）" % _arena_scale
	# 镜头：滚轮调**视野**；右键按住开镜、滚轮调倍率（倍率这一场里记着，收镜不清零）
	var view_text := "视野 %.1f°（滚轮）" % target_fov()
	if _scoped:
		view_text += " ← 开镜 ×%.1f（平时 %.1f° · 滚轮调 %d~%d 倍）" % [
			_scope_zoom, _fov, int(SCOPE_ZOOM_MIN), int(SCOPE_ZOOM_MAX)
		]
	else:
		view_text += " · 右键按住开镜（上次 ×%.1f）" % _scope_zoom
	_hud.text += "\n" + view_text
	if _show_debug_hud():
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
	# 坐标（F1 开关）：车在哪、准星落在哪、车头朝哪 —— 手动摆场地时照着抄
	if _show_coords and _chassis != null and is_instance_valid(_chassis):
		var car_m := _chassis.global_position * PartDef.CUBE_METERS
		var aim_m := _aim_point * PartDef.CUBE_METERS
		_hud.text += (
			"\n坐标 车 (%.1f, %.1f) 米 · 准星落点 (%.1f, %.1f) 米 · 车头 %.0f°（F1 关）"
			% [car_m.x, car_m.z, aim_m.x, aim_m.z, rad_to_deg(_chassis.global_rotation.y)]
		)
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
		_hud.text += "\n%s %d 台：零件 %d/%d 还在 · 打光 %d 台%s · %s" % [
			_enemy_word(), _enemies.size(), alive_parts, all_parts, _kills, mine, _last_hit
		]


## ── ESC 暂停菜单 ───────────────────────────────────────────────────────────
## 测试场和人机对战共用：ESC 不再直接回主界面，而是**暂停 + 弹菜单**。
func _build_pause_menu() -> void:
	_pause_menu = PauseMenu.new()
	_pause_menu.name = "PauseMenu"
	add_child(_pause_menu)
	_pause_menu.resume_requested.connect(_close_pause_menu)
	_pause_menu.self_destruct_requested.connect(_pause_self_destruct)
	_pause_menu.quit_requested.connect(_pause_quit_to_menu)


func _open_pause_menu() -> void:
	if _pause_menu == null:
		return
	_pause_menu.open()
	_set_audio_paused(true)


func _close_pause_menu() -> void:
	if _pause_menu == null:
		return
	_pause_menu.close()
	_set_audio_paused(false)


## 暂停时把引擎循环音也停住（否则菜单里一直嗡嗡响）；恢复时接着播。
func _set_audio_paused(value: bool) -> void:
	for veh in _vehicles:
		# 引擎声部现在是 3D 的（距离衰减 + 左右声道），类型别写回 2D —— 会报
		# "Trying to assign AudioStreamPlayer3D to AudioStreamPlayer"
		var player: AudioStreamPlayer3D = veh.get("audio")
		if player != null and is_instance_valid(player):
			player.stream_paused = value


## 自爆（菜单里点"确认自爆"）：把玩家车的零件**按正常毁伤流程**全部打爆 ——
## 所以对战里会走 `_on_vehicle_eliminated()`（算你被击毁），测试场里就是车炸了。
func _pause_self_destruct() -> void:
	_close_pause_menu()
	_self_destruct_player()


## 返回主界面：先解除暂停、把这一场**拆干净**再换场景。
## 用户报过"返回再进战斗会回到上一场 / 东西渲染两次"——换场景本来会释放整棵树，
## 这里再显式拆一遍，保证下一场一定是全新的一局。
func _pause_quit_to_menu() -> void:
	_quit_to_menu()


## 回主界面的唯一入口（暂停菜单的"返回主界面"、战斗结束后的 ESC 都走这里）：
## 解除暂停 → 恢复物理 → 拆场 → 换场景。
func _quit_to_menu() -> void:
	_close_pause_menu()
	teardown_match()
	get_tree().change_scene_to_file(MENU_SCENE)


## 把这一场拆掉：车（含转塔/轮胎）、射弹、场地、相机、暂停菜单引用。
func teardown_match() -> void:
	get_tree().paused = false
	PhysicsServer3D.set_active(true)
	pending_vehicle = {}
	_pause_menu = null
	for veh in _vehicles:
		var chassis: RigidBody3D = veh.get("chassis")
		if chassis != null and is_instance_valid(chassis):
			chassis.queue_free()
	_vehicles.clear()
	_vehicles_by_rid.clear()
	_team_of_key.clear()
	_wheels.clear()
	_turrets.clear()
	_clip_boxes.clear()
	_player_veh = {}
	_player_rig = null
	_enemies.clear()
	_teardown_mode()
	_sfx_pool.clear()
	_sfx_next = 0
	if _projectiles != null and is_instance_valid(_projectiles):
		_projectiles.queue_free()
		_projectiles = null
	if _aim_marker != null and is_instance_valid(_aim_marker):
		_aim_marker.queue_free()
		_aim_marker = null
	if _camera != null and is_instance_valid(_camera):
		_camera.queue_free()
		_camera = null
	_chassis = null
	if _arena_root != null and is_instance_valid(_arena_root):
		_arena_root.queue_free()
		_arena_root = null
	_arena_model = null


## 子类（对战模式）在拆场时清自己的状态（视野计时 / 目标等）。
func _teardown_mode() -> void:
	pass


## 自爆的实际效果：所有零件按毁伤流程打爆 + 一圈爆炸火光 + 一声枪响兜底。
func _self_destruct_player() -> void:
	if _player_rig == null or _chassis == null:
		return
	var dead := []
	for i in _player_rig.state.part_count():
		if not _player_rig.state.part_alive(i):
			continue
		var result := _player_rig.apply_damage(i, 1.0e12)
		dead.append_array(result["destroyed"])
		dead.append_array(result["detached"])
	if not dead.is_empty():
		_on_parts_destroyed(_player_rig, dead)
	if _projectiles != null:
		var at := _chassis.global_position + Vector3.UP * 2.0
		for i in 10:
			var dir := Vector3(cos(float(i) * TAU / 10.0), 0.5 + 0.4 * float(i % 3), sin(float(i) * TAU / 10.0))
			_projectiles.spawn_impact(at + dir * 3.5, Color(1.0, 0.58, 0.22))
		_projectiles.spawn_impact(at, Color(1.0, 0.85, 0.4))
		_projectiles.spawn_impact(at, Color(1.0, 0.45, 0.15))
	# 自爆的响：用开火音压低音高、加响度，在车的位置播（有距离衰减/左右声道）
	_play_world_sfx(
		_chassis.global_position + Vector3.UP * 2.0,
		GameSettings.shot_stream(), GameSettings.audio_strength("shot") + 6.0, 0.7
	)


## HUD 标题（对战模式改成"对战"）。
func _hud_title() -> String:
	return "测试场"


## HUD 里那些"调载具用"的调试行（场地缩放 / 出生点 / 节点计数）要不要显示。
## 对战模式覆盖成 false —— 那是给测试场调载具用的，对战里只会挡视线。
func _show_debug_hud() -> bool:
	return true


## HUD 里把对面那一队叫什么（测试场是"靶子"，对战是"敌人"）。
func _enemy_word() -> String:
	return "靶子"


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
	if _prof_on:
		_prof_start = Time.get_ticks_usec()
		_prof_t = _prof_start
		_prof_frame = {}
	_space = _chassis.get_world_3d().direct_space_state
	# 每台车各跑一遍轮胎物理：输入来自 `_vehicle_input()`（玩家读键盘，人机由子类给）。
	# 靶子 / 没人开的车输入恒为 0（它们照样有完整的碰撞 + 悬挂 + 轮胎，推得动、会被打瘸）。
	var player_input := Vector2.ZERO
	for veh in _vehicles:
		var input := _vehicle_input(veh, delta)
		if bool(veh.get("is_player", false)):
			player_input = input
		_drive_vehicle(veh, delta, input.x, input.y)
	if _prof_on:
		_prof_t = _prof_lap("轮胎")
	# 引擎声：**每台车一个循环声部**（以前只有玩家有声音，队友/敌人是哑的）。
	# 玩家的油门来自按键；人机没有单独存油门，就用"实际速度"当负载 —— 听着足够像。
	for veh in _vehicles:
		var body: RigidBody3D = veh.get("chassis")
		if body == null or not is_instance_valid(body):
			continue
		var throttle := 0.0
		var steer := 0.0
		if bool(veh.get("is_player", false)):
			throttle = player_input.x
			steer = player_input.y
		else:
			throttle = clampf(body.linear_velocity.length() / 50.0, 0.0, 1.0)
		_update_engine_audio(veh, throttle, steer, delta)
	if _prof_on:
		_prof_t = _prof_lap("引擎音")
	_update_com_marker()
	_update_battle(delta)
	if _prof_on:
		_prof_t = _prof_lap("战斗/AI")
	_update_turrets(delta)
	if _prof_on:
		_prof_t = _prof_lap("转塔瞄准")
	_update_weapons(delta)
	if _prof_on:
		_prof_t = _prof_lap("开火判定")
	if _projectiles != null:
		_projectiles.step(delta, _space)
	if _prof_on:
		_prof_t = _prof_lap("弹道推进")
	# 伤害打包：这一帧所有命中合并成"每车每零件一次"的结算（集中交火时的最大开销）
	_flush_damage_batches()
	if _prof_on:
		_prof_t = _prof_lap("伤害结算")
	# 开火声也按帧合并（见 `_queue_shot_sfx` / `_flush_shot_sfx`）
	_flush_shot_sfx()
	if _prof_on:
		_prof_t = _prof_lap("开火音")
	# 毁伤善后：这一帧里所有命中合并成一次（视觉重建 / 射界重算）——
	# 一帧中好几发子弹是常态，逐发做的话开局交火就会一顿一顿（用户报的掉帧）。
	# 射界重算有一个**全局**预算（`ARC_REBUILDS_PER_TICK`）：一台 ~1.1 ms，而 10 台车各自
	# 排着 1 台的话，旧写法等于一帧算 10 台 = 11 ms（探针实测「善后/射界」11~18 ms 的主因）。
	var arc_budget := ARC_REBUILDS_PER_TICK
	# 受击盒 trimesh / 合并盒重建的**全场**预算：一台 ~5 ms + ~3 ms，10 台车同帧各掉零件时
	# 旧写法一帧要背 10 份（探针实测「善后/射界」26.8 ms）。限成 1 台/帧，最多晚一两帧。
	var flush_budget := FLUSH_HEAVY_PER_TICK
	for veh in _vehicles:
		var rig: VehicleRig = veh.get("rig")
		if rig != null:
			var allow_heavy := flush_budget > 0 and rig.needs_heavy_rebuild()
			if allow_heavy:
				flush_budget -= 1
			rig.flush_visuals(allow_heavy)
		if bool(veh.get("arc_dirty", false)):
			_flush_damage_work(veh, rig)
		# 射界：每帧最多重算 `ARC_REBUILDS_PER_FRAME` 台转塔，且全场合计不超过 `arc_budget`
		var arc_queue: Array = veh.get("arc_queue", [])
		if arc_budget > 0 and not arc_queue.is_empty():
			var arc_boxes: Array = veh.get("clip_boxes", [])
			for _i in mini(mini(ARC_REBUILDS_PER_FRAME, arc_budget), arc_queue.size()):
				# 队列里的转塔可能在排队期间就被打掉了（它所在的零件死了 → queue_free）：
				# 先拿 Variant 再用 `is_instance_valid()` 判，别直接赋给带类型的变量（会报"已释放实例"）
				var queued: Variant = arc_queue.pop_front()
				if queued == null or not is_instance_valid(queued):
					continue
				(queued as Turret).rebuild_arc(arc_boxes)
				_arc_rebuilds += 1
				arc_budget -= 1
	if _prof_on:
		_prof_t = _prof_lap("善后/射界")
		_prof_end_frame()


## 掉零件后重算射界：每台车每帧最多重算这么多台转塔（一台 ~1.1 ms，6 台一起算就是 6.7 ms）
const ARC_REBUILDS_PER_FRAME := 1
## **全场合计**每帧最多重算几台转塔的射界。10 台车各自排 1 台时，旧写法一帧要算 10 台（11 ms）。
## 取 2 表示"最多让一帧多背 ~2.2 ms"，其余排到后面几帧（射界晚几帧才放开，玩家看不出来）。
const ARC_REBUILDS_PER_TICK := 2
## **全场合计**每帧最多允许几台车做"重活"（受击盒 trimesh 重建 / 方块合并盒重建）。
## 一台约 5 ms + 3 ms；10 台车同帧各掉零件时旧写法一帧背 10 份（实测 26.8 ms）。
## 取 1 表示最坏一帧只多背 ~8 ms，其余车晚 1~2 帧更新（这几帧里死零件靠命中过滤器挡掉）。
const FLUSH_HEAVY_PER_TICK := 1
## 射界累计重算次数（调试 / 基准用）
var _arc_rebuilds := 0

## ── 帧预算探针（F9 开关）────────────────────────────────────────────────────
## 打开后每个物理帧给各段打时间戳，每秒打印**这一秒里最慢那一帧**的拆解。
## 用途：交火掉帧时不用猜是轮胎 / 转塔 / 开火 / 伤害结算哪一段 —— 直接看数字。
## 关掉时每个标记只多一次 `if` 判断，可以忽略。
var _prof_on := false
var _prof_t := 0
var _prof_start := 0
var _prof_frame := {}
var _prof_worst := {}
var _prof_worst_ms := 0.0
var _prof_report := 1.0


## 打一个时间戳，把"距离上一个标记"记到当前帧；返回新的时间戳。
func _prof_lap(label: String) -> int:
	var now := Time.get_ticks_usec()
	_prof_frame[label] = float(now - _prof_t) / 1000.0
	return now


## 帧末：记下这一秒里最慢的一帧（包括各段拆解）。
func _prof_end_frame() -> void:
	var total := float(Time.get_ticks_usec() - _prof_start) / 1000.0
	if total <= _prof_worst_ms:
		return
	_prof_worst_ms = total
	_prof_worst = _prof_frame.duplicate()
	_prof_worst["（合计）"] = total


## 每秒打印一次当前窗口里最慢的那帧。
func _prof_dump() -> void:
	if _prof_worst.is_empty():
		print("[探针] 这一秒没有采样到物理帧")
		return
	print("[探针] 最慢一帧 %.2f ms（60 Hz 预算 16.7 ms）" % _prof_worst_ms)
	var items: Array = []
	for key in _prof_worst.keys():
		if key == "（合计）":
			continue
		items.append({"k": key, "v": float(_prof_worst[key])})
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["v"]) > float(b["v"])
	)
	for entry in items:
		if float(entry["v"]) < 0.05:
			continue
		print("    %-16s %7.2f ms" % [str(entry["k"]), float(entry["v"])])
	_prof_worst = {}
	_prof_worst_ms = 0.0


## 一台车的毁伤善后（每物理帧最多一次）：更新体积盒（射界的原料）。
## 注意：**不在这里把转塔全排进队列** —— 队列由 `_on_parts_destroyed()` 只填"真被影响的那些"。
## `clip_boxes` 也**不再整表重建**：掉的那几个零件在 `_on_parts_destroyed()` 里已经就地置空了
## （541 个字典重建一次 ~1 ms，而真正变的通常只有 1~3 件）。
func _flush_damage_work(veh: Dictionary, rig: VehicleRig) -> void:
	veh["arc_dirty"] = false
	if rig == null:
		return
	if bool(veh.get("is_player", false)):
		_cam_box_local = rig.bounds_local()
		_clip_boxes = veh.get("clip_boxes", [])
		if (veh.get("turrets", []) as Array).is_empty() and _aim_marker != null and is_instance_valid(_aim_marker):
			_aim_marker.visible = false
	# 这里不再一次性重算所有转塔（见上面的 `arc_queue`）


## 这台车这一帧的输入：(油门, 转向)，各 [-1, 1]。玩家读键盘；
## 人机 / 靶子默认 0，对战模式覆盖成 AI（见 `battle_mode.gd`）。
func _vehicle_input(veh: Dictionary, _delta: float) -> Vector2:
	if not bool(veh.get("is_player", false)):
		return Vector2.ZERO
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
	return Vector2(throttle, steer)


## 对战模式每物理帧的钩子（选目标 / 判胜负）。测试场里什么都不做。
func _update_battle(_delta: float) -> void:
	pass


## 一台车的轮胎物理（原来只给玩家车写死，现在按 `_vehicles` 逐台跑：玩家车 + 靶车）。
func _drive_vehicle(veh: Dictionary, delta: float, throttle: float, steer: float) -> void:
	var chassis: RigidBody3D = veh["chassis"]
	if chassis == null or not is_instance_valid(chassis):
		return
	var wheels: Array = veh["wheels"]

	const BOT_WHEEL_INTERVAL := 1
	var bot := not bool(veh.get("is_player", false))
	var phase := int(veh.get("wheel_phase", 0)) + 1
	veh["wheel_phase"] = phase
	# 人机 / 靶子每 `BOT_WHEEL_INTERVAL` 个物理帧真正算一次轮子，其余帧沿用上一帧的力。
	# ⚠️ 这个间隔**不能大**：60 Hz 下取 3（= 20 Hz）时 AI 车会**不停弹跳** —— 悬挂力过期 50 ms，
	# 车已经离地/换姿态了、力还在按老方向往上顶（用户 2026-10-19 报的）。现在每帧都算（和玩家一样）：
	# 60 Hz × 每帧 = 每秒 60 次，和"以前 120 Hz × 隔帧"的总量相同，性能不吃亏。
	var reuse_force := bot and BOT_WHEEL_INTERVAL > 1 and phase % BOT_WHEEL_INTERVAL != 0
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
	# 轮胎自转只是**视觉**：太远（>200 米）就跳过，10 台车 100 个轮子时这里也是几毛秒
	var spin_visible := true
	if _camera != null and is_instance_valid(_camera):
		spin_visible = (
			_camera.global_position.distance_squared_to(chassis.global_position) < 400.0 * 400.0
		)
	for entry in wheels:
		if reuse_force:
			# 沿用上一帧的接触力和作用点（几乎不变），省掉整轮 math
			if bool(entry.get("contact", false)):
				grounded = true
				var cached: Vector3 = entry.get("last_force", Vector3.ZERO)
				if cached != Vector3.ZERO:
					chassis.apply_force(
						cached,
						(entry.get("last_point", chassis.global_position) as Vector3)
						- chassis.global_position
					)
			continue
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
		var target_steer := (
			float(entry["steer_sign"]) * steer * float(entry["steer_max"])
			* float(entry.get("steer_factor", 1.0))
		)
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
		if spin_visible:
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
## **每台车都有引擎声**（玩家 / 队友 / 敌人），用 `AudioStreamPlayer3D` 挂在底盘上：
## 距离衰减和左右声道由 3D 音频自己算（听者是玩家相机，见 scripts/spatial_audio.gd）。
## 把引擎音效的调参读一次（`GameSettings.engine_*()` 每组都要读文件字典）。
func _cache_engine_audio() -> void:
	_eng_pitch_low = GameSettings.engine_pitch_low()
	_eng_pitch_high = GameSettings.engine_pitch_high()
	_eng_ramp = maxf(0.01, GameSettings.engine_ramp_seconds())
	_eng_db_idle = GameSettings.engine_db_idle()
	_eng_db_full = GameSettings.engine_db_full()


func _update_engine_audio(veh: Dictionary, throttle: float, steer: float, delta: float) -> void:
	# 太远（超过 3D 声部的最大距离）就直接静音：既听不见，也算这堆插值是浪费 ——
	# 10 台车同场时这一项实测 ~1.5 ms/tick。
	var chassis_body: RigidBody3D = veh.get("chassis")
	if chassis_body == null or not is_instance_valid(chassis_body):
		return
	if _camera != null and is_instance_valid(_camera):
		if (
			_camera.global_position.distance_squared_to(chassis_body.global_position)
			> SpatialAudio.MAX_DISTANCE_CUBES * SpatialAudio.MAX_DISTANCE_CUBES
		):
			var far: AudioStreamPlayer3D = veh.get("audio")
			if far != null and far.playing:
				far.stop()
			return
	# 引擎音效：玩家每 2 个物理帧更新一次（60 Hz）；AI 车每 3 帧（40 Hz）—— 听感没区别
	var phase := int(veh.get("audio_phase", 0)) + 1
	veh["audio_phase"] = phase
	var audio_interval := 2 if bool(veh.get("is_player", false)) else 3
	if phase % audio_interval != 1:
		return
	var player: AudioStreamPlayer3D = veh.get("audio")
	if player == null:
		var stream := GameSettings.engine_stream()
		if stream == null:
			return                    # 编辑器里 / 素材没导入：安静就好，别报错
		player = AudioStreamPlayer3D.new()
		player.name = "EngineAudio"
		player.stream = stream
		player.bus = GameSettings.BUS_SFX
		player.volume_db = -80.0      # 先"关着"，等按键再响
		SpatialAudio.configure(player)   # 距离衰减 + 左右声道，关多普勒
		(veh["chassis"] as RigidBody3D).add_child(player)
		veh["audio"] = player
	var gas := absf(throttle)
	var active := gas > 0.01 or absf(steer) > 0.01
	# 车被打光（对战里 `alive` 会置 false）就不该再有引擎声
	if not bool(veh.get("alive", true)):
		if player.playing:
			player.stop()
		return
	# 油门按住多久了（松开/换向就归零）—— 引擎的"上扬"只看这个，不看车速
	var hold := float(veh.get("throttle_hold", 0.0))
	hold = (hold + delta) if gas > 0.01 else 0.0
	veh["throttle_hold"] = hold
	# 0 = 刚按下（低转），1 = 按满 ramp_seconds 秒（高转）
	var rev := clampf(hold / _eng_ramp, 0.0, 1.0)
	var pitch_low := _eng_pitch_low
	var pitch_high := _eng_pitch_high
	# 音高：只按转向 = 中间怠速；给油 = 从 low 一路升到 high
	var target_pitch := lerpf(pitch_low, pitch_high, rev) if gas > 0.01 else (pitch_low + pitch_high) * 0.5
	var target_db := -80.0
	if active:
		target_db = (
			_eng_db_idle
			if gas <= 0.01
			else SpatialAudio.engine_db(_eng_db_idle, _eng_db_full, rev)
		)
		if not player.playing:
			player.play()
	# 平滑系数别太大：升调本身就是"按时间慢慢上去"的，再叠一层快平滑会显得生硬
	player.pitch_scale = lerpf(player.pitch_scale, target_pitch, 0.12)
	player.volume_db = lerpf(player.volume_db, target_db, 0.12)
	# 松开键、淡出到底之后**真的停掉** —— 不然总有一个循环在背景里响
	if not active and player.playing and player.volume_db < -55.0:
		player.stop()


## ── 世界音效（开火声）──────────────────────────────────────────────────────
## 在声源的世界坐标上播一个 3D 声部：距离越远越轻、左右按声源相对相机的方向给。
## 用池子轮着播（10 台车一起开火也不会互相打断）。
## 同一帧的开火音效先**排队**，帧末合并播放。
## 60 台枪同时打的时候一帧可能有好几发，逐发播的话每发都要动一个 3D 声部，
## 32 个声部被反复抢占（声音糊成一片、还白花引擎调用）。规则：
## * 一帧最多播 `SFX_MAX_PER_FRAME` 发，优先离镜头近的；
## * 被丢掉的按数量补一点音量（多出来的枪声"叠"成更响的一发，听感上还是连着打）。
const SFX_MAX_PER_FRAME := 3
var _sfx_queue: Array = []


func _queue_shot_sfx(at: Vector3, stream: AudioStream, base_db: float, pitch := 1.0) -> void:
	if stream == null:
		return
	_sfx_queue.append({"at": at, "stream": stream, "db": base_db, "pitch": pitch})


## 把这一帧排队的开火声合并播放（见 `_queue_shot_sfx`）。
func _flush_shot_sfx() -> void:
	if _sfx_queue.is_empty():
		return
	var requests := _sfx_queue
	_sfx_queue = []
	var camera_pos := Vector3.ZERO
	var has_camera := _camera != null and is_instance_valid(_camera)
	if has_camera:
		camera_pos = _camera.global_position
	var alive: Array = []
	for request in requests:
		var at: Vector3 = request["at"]
		if has_camera and camera_pos.distance_to(at) > SpatialAudio.MAX_DISTANCE_CUBES:
			continue        # 太远：连声部都不占
		alive.append(request)
	if alive.is_empty():
		return
	if has_camera:
		alive.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return (
				camera_pos.distance_squared_to(a["at"])
				< camera_pos.distance_squared_to(b["at"])
			)
		)
	var play_count := mini(alive.size(), SFX_MAX_PER_FRAME)
	var dropped := alive.size() - play_count
	# 丢掉的枪声按数量补音量（+6 dB 封顶）：听感上是"更密更响"，不会变成静音
	var boost := clampf(20.0 * log(1.0 + float(dropped) * 0.5) / log(10.0), 0.0, 6.0)
	for i in play_count:
		var request: Dictionary = alive[i]
		_play_world_sfx(
			request["at"], request["stream"], float(request["db"]) + boost,
			float(request["pitch"])
		)


func _play_world_sfx(at: Vector3, stream: AudioStream, base_db: float, pitch := 1.0) -> void:
	if stream == null:
		return
	if _sfx_pool.is_empty():
		for i in 32:
			var voice := AudioStreamPlayer3D.new()
			voice.name = "Sfx%d" % i
			voice.bus = GameSettings.BUS_SFX
			voice.volume_db = -80.0
			SpatialAudio.configure(voice)   # 距离衰减 + 左右声道
			add_child(voice)
			_sfx_pool.append(voice)
	var player := _sfx_pool[_sfx_next]
	_sfx_next = (_sfx_next + 1) % _sfx_pool.size()
	if _camera != null and is_instance_valid(_camera):
		# 太远就别占声部了（引擎那边同样距离也会静音）
		if _camera.global_position.distance_to(at) > SpatialAudio.MAX_DISTANCE_CUBES:
			return
	player.global_position = at
	player.stream = stream
	player.volume_db = base_db
	player.pitch_scale = pitch
	player.play()


## ── 武器：瞄点 + 转塔 ──────────────────────────────────────────────────────
## 瞄准规则（用户定的）：瞄点 = **瞄准视线的首个敌人/地形交点**；
## 视线就是相机准星（屏幕中心）那条射线 —— 对着天打不到东西时取射线的远端。
## 拿到瞄点后，每个转塔朝它转（射界/俯仰的夹紧在 Turret.solve_aim 里，走最短路径）。
func _update_turrets(delta: float) -> void:
	var any_turrets := false
	for veh in _vehicles:
		if not (veh.get("turrets", []) as Array).is_empty():
			any_turrets = true
			break
	if not any_turrets:
		return
	# 玩家的瞄点来自相机准星；玩家没枪也照样算（HUD 要显示），人机的瞄点由 AI 给。
	_aim_point = _aim_point_from_camera()
	for veh in _vehicles:
		var turrets: Array = veh.get("turrets", [])
		if turrets.is_empty():
			continue
		var target: Vector3 = _aim_point if bool(veh.get("is_player", false)) else veh["aim_point"]
		for turret in turrets:
			# 按炮塔转速限制慢慢跟（不是瞬间对准）：转速写在部件文件里（度/秒）
			turret.update_aim(target, delta)
	if _aim_marker != null and is_instance_valid(_aim_marker):
		_aim_marker.global_position = _aim_point


## 枪口 → 子弹生成点那一段里，**第一个**被自家零件挡住的地方（世界坐标）。
## "枪口贴脸自吃"时把命中小爆炸放在这儿 —— 弹丸压根没生成，得靠这个特效才看得见打在哪儿。
## 这一段只有 1 格，采 8 个点足够；一个都没采到就退回起点。
## `boxes` / `chassis` 不传就用玩家车那一套（测试直接打这个函数时只传前三个参数）。
func _first_blocked_point(
	from: Vector3, to: Vector3, skip_index: int,
	boxes: Array = [], chassis: RigidBody3D = null
) -> Vector3:
	var body: RigidBody3D = chassis if chassis != null else _chassis
	var clip: Array = boxes if not boxes.is_empty() else _clip_boxes
	if body == null:
		return from
	var to_local := body.global_transform.affine_inverse()
	var a := to_local * from
	var b := to_local * to
	for i in range(1, 9):
		var point := a.lerp(b, float(i) / 8.0)
		for j in clip.size():
			if j == skip_index:
				continue
			var box: AABB = clip[j]["box"]
			if box.size.x <= 0.001 or box.size.y <= 0.001 or box.size.z <= 0.001:
				continue
			if box.has_point(point):
				return body.global_transform * point
	return from


## 转塔自检要用的"每个零件的包围盒"（底盘本地坐标，下标 = 零件下标）。
## 直接用 VehicleRig 已经建好的碰撞盒：它就是"这个零件占的那块地方"，
## 和受击/毁伤用的是同一份口径。名字里带上部件 id，HUD 里能直接看出"被谁挡住"。
func _collect_clip_boxes(rig: VehicleRig, vehicle: VehicleDef) -> Array:
	var out := []
	# ⚠️ 读**每个零件的本体盒**（`VehicleRig.part_boxes()`），不是车体的 shape：
	# 车体现在只有一个整车包围盒（性能优化），拿它当"零件盒"会把所有转塔的射界全堵死。
	var boxes: Array = rig.part_boxes()
	var all_planes: Array = rig.part_planes()
	for i in boxes.size():
		var box: AABB = boxes[i]
		var part_id := "--"
		# 手搓的 veh（测试）可能没带 vehicle：那就只用下标当名字
		if vehicle != null and i < vehicle.parts.size():
			part_id = str(vehicle.parts[i]["part_id"])
		# `planes` = 这一件的凸包半空间（射界按真实形状挡，半砖不再当成整格方块）
		var planes: Array = (all_planes[i] as Array) if i < all_planes.size() else []
		out.append({"box": box, "name": "%s #%d" % [part_id, i], "planes": planes})
	return out


## 重算每台转塔的**真实射界**（角网格 + 连通域，见 `Turret.rebuild_arc()`）。
## 时机：进场看到车体之后、以及**零件被打掉之后**（打掉挡路的零件，射界就变大了）。
func _refresh_turret_arcs() -> void:
	for veh in _vehicles:
		_refresh_vehicle_arcs(veh)


## 重算**某一台车**所有转塔的真实射界（进场时一次，零件被打掉之后再算一次）。
## 每台车用自己的 `clip_boxes` —— 人机和玩家的车体不是同一块体积。
func _refresh_vehicle_arcs(veh: Dictionary) -> void:
	var turrets: Array = veh.get("turrets", [])
	var boxes: Array = veh.get("clip_boxes", [])
	if turrets.is_empty() or boxes.is_empty():
		return
	var all_blocked := 0
	for turret in turrets:
		turret.rebuild_arc(boxes)
		# 诊断（用户报"有些武器无法正常判定遮挡转动"）：射界**算不出来**（转塔没装好）或者
		# **整片被挡**（枪管一转就穿零件）时必须留一句话 —— 否则那条枪会静默地"随便转、
		# 被挡也照打"，查起来一头雾水。人机车不刷这个（10 台车会把日志刷爆）。
		if not turret.arc_ready():
			if bool(veh.get("is_player", false)):
				push_warning(
					"转塔 %s 的真实射界算不出来（转塔节点没装起来）" % turret.part_id
				)
		elif turret.arc_free_ratio() <= 0.001:
			all_blocked += 1
	if all_blocked > 0 and bool(veh.get("is_player", false)):
		push_warning(
			"测试场：%d 台转塔的真实射界整片被挡（周围有零件压着枪管），它们转不了也打不了"
			% all_blocked
		)


## 能量 + 开火：**每台车**一口能量池（核心提供上限与恢复），它的所有武器共用。
## 玩家：按住开火键就打；人机：由 `veh["wants_fire"]` 决定（对战模式的 AI 设）。
## 每发先扣能量，不够就哑火（HUD 只记玩家那台的账）。
func _update_weapons(delta: float) -> void:
	if _projectiles == null:
		return
	for veh in _vehicles:
		var turrets: Array = veh.get("turrets", [])
		if turrets.is_empty():
			continue
		var is_player := bool(veh.get("is_player", false))
		var energy_max := float(veh.get("energy_max", 0.0))
		var energy := float(veh.get("energy", 0.0))
		if energy_max > 0.0:
			energy = minf(energy_max, energy + float(veh.get("energy_regen", 0.0)) * delta)
		var wants := Input.is_action_pressed(FIRE_ACTION) if is_player else bool(veh.get("wants_fire", false))
		if not wants:
			for turret in turrets:
				turret.arc_blocked_by = ""   # 松手就把"射界外"的提示清掉
			veh["energy"] = energy
			if is_player:
				_energy = energy
			continue
		var chassis: RigidBody3D = veh["chassis"]
		var inherit := chassis.linear_velocity
		var boxes: Array = veh.get("clip_boxes", [])
		var owner_key := str(veh.get("owner_key", PLAYER_KEY))
		for turret in turrets:
			# 开火自检（用户规则）：射界里允许有零件，但只有在**真实射界**（和初始枪口朝向连通、
			# 且枪管不穿模的那一片）里才能开火。每帧查一次格子，代价可以忽略。
			var blocked: String = turret.arc_reason()
			turret.arc_blocked_by = blocked
			for _shot in turret.ready_shots(delta):
				if not blocked.is_empty():
					if is_player:
						_jam_fires += 1
					continue
				if energy < turret.energy_cost:
					if is_player:
						_dry_fires += 1
					continue
				# 枪口贴脸：子弹是从"枪口沿枪轴再外推 `MUZZLE_PAD` 格"生成的，
				# 那 1 格里的自家方块会被**整个跨过去**。先把枪口→生成点这一段查一遍：
				# 有东西就直接算打在自己身上（吃掉这一发）。
				var spawn: Vector3 = turret.fire_origin()
				var muzzle_now: Vector3 = turret.muzzle_position()
				var slam := Turret.segment_blocker(
					muzzle_now, spawn, boxes, int(turret.get_meta("part_index", -1))
				)
				energy -= turret.energy_cost
				if is_player:
					_shots_fired += 1
				# 显式写类型：`turret` 是数组里的 Variant，`:=` 推不出类型（本项目把这种当错误）
				var dir: Vector3 = turret.barrel_direction()
				# 枪口闪光（挂在枪管上的火舌）+ 从**真枪口**拉出来的第一段光带（近身也看得见弹道）
				turret.flash()
				# 开火音：**所有车**都按世界坐标播（距离衰减 + 左右声道），不再只有玩家能听见。
				# 枪口位置当声源 —— 对面的枪声会从屏幕对应的一侧传过来。
				# 开火音先排队，帧末合并播放（同一帧几十发只占几个声部，见 `_flush_shot_sfx`）
				# 音高乘上这把枪的 `weapon_pitch`：重机枪 0.78 → 比轻机枪低沉
				_queue_shot_sfx(
					muzzle_now, GameSettings.shot_stream(),
					GameSettings.audio_strength("shot"),
					randf_range(0.94, 1.06) * turret.weapon_pitch
				)
				if not slam.is_empty():
					# 打在自己身上：不生成弹丸（弹丸的射线是从生成点开始的，跨过的那 1 格它永远看不到）
					if is_player:
						_muzzle_eaten += 1
						_last_hit = "枪口被 %s 挡住，这一发打在自己身上" % slam
					# 照样给个命中小爆炸（用户要看得见），位置取那 1 格里**第一个被挡住的地方**
					var blocked_point := _first_blocked_point(
						muzzle_now, spawn, int(turret.get_meta("part_index", -1)),
						boxes, chassis
					)
					_projectiles.spawn_impact(blocked_point, turret.bullet_color)
					continue
				var fired := false
				if turret.is_ray():
					# 射线类武器（`weapon_projectile = ray`）：**瞬间命中**，从真枪口打出去。
					# 没有弹速 / 下坠 / 寿命，只有最大射程；扩散和伤害衰减照旧。
					fired = _projectiles.fire_ray(
						_space,
						muzzle_now,
						dir,
						turret.spread_deg,
						turret.damage,
						turret.ray_range,
						turret.bullet_spec(),
						owner_key
					)
				else:
					fired = _projectiles.fire(
						spawn,
						dir,
						turret.muzzle_speed,
						turret.spread_deg,
						turret.damage,
						turret.projectile_life,
						inherit,
						owner_key,
						muzzle_now,
						turret.bullet_spec()
					)
				# 后坐：每发把车沿枪管反方向推一下，作用点在**枪口** ——
				# 所以偏心装的枪会带一点力矩（车会被推得歪一下），和真枪一样。
				if fired:
					var recoil := recoil_impulse_vector(dir, turret.recoil_impulse)
					if recoil != Vector3.ZERO:
						chassis.apply_impulse(recoil, muzzle_now - chassis.global_position)
		veh["energy"] = energy
		if is_player:
			_energy = energy


## 后坐冲量向量（纯函数，测试直接打它）：方向 = **枪管反方向**（把车往后推），
## 大小 = 部件文件的 `weapon_recoil_impulse`。0 = 没后坐。
static func recoil_impulse_vector(barrel_dir: Vector3, impulse: float) -> Vector3:
	if impulse <= 0.0:
		return Vector3.ZERO
	var direction := barrel_dir.normalized()
	if direction.length() < 0.001:
		return Vector3.ZERO
	return -direction * impulse


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
		# 排除**所有车的车体**（那是整车包围盒，不是真实外形）—— 不然准星瞄车顶时，
		# 射线先打到"比真实外形更高的方盒顶面"，瞄点飘在车顶上方几格，子弹就全打天上
		# （用户 2026-10-19 报的）。排除车体后，射线打的是 `hitboxes` 上的**真实零件几何**；
		# 自己车的受击盒也排除（否则准星会先打到自己的车）。
		var exclude: Array[RID] = []
		for veh in _vehicles:
			var chassis_body: CollisionObject3D = veh.get("chassis")
			if chassis_body != null and is_instance_valid(chassis_body):
				exclude.append(chassis_body.get_rid())
		if _player_rig != null and _player_rig.hitboxes != null:
			exclude.append(_player_rig.hitboxes.get_rid())
		var query := PhysicsRayQueryParameters3D.create(from, to, AIM_LAYERS, exclude)
		var hit := _space.intersect_ray(query)
		if not hit.is_empty():
			_aim_hit = true
			# 瞄点 = 准星指到的地方（命中点）。**不能**吸到敌人的中心 ——
			# 那样"准星只要在对方车上，枪就无脑锁质心"，完全不听玩家指挥（用户 2026-10-19 报的）。
			# 打掉的零件残影问题由"受击盒每帧重建"解决（见 `VehicleRig.flush_visuals()`）。
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
	var axle := node.global_transform.basis.x.normalized()
	var shift := axle * float(entry["ray_shift"])
	var hub := xform * (entry["hub"] as Vector3) + shift
	var reach := rest + radius
	# ⚠️ 复用**同一个** query 对象：以前每条射线都 `create()` 一个新的 RefCounted +
	# 一个新的 exclude 数组 —— 10 台车 × 10 根轴 × 16 条射线时每 tick 上千次分配，
	# 光是分配/回收就是这一项耗时的很大一块（实测 `_drive_vehicle` 每 tick 6 ms+）。
	var query := PhysicsRayQueryParameters3D.create(hub, hub + down * reach, 1, (entry["exclude"] as Array))
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
		query.from = centre
		query.to = centre + dir * ring_reach
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
	# （调试量只给 tools/probe_flat.gd 用；每轮每 tick 写 6 次字典是白开销，改成按需读）
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
	# 缓存给"人机隔帧复用"用（见 `_drive_vehicle`）
	entry["last_force"] = total
	entry["last_point"] = best_point
	# 调试用：把这一帧的接触/轮胎量记在 entry 上（`tools/probe_flat.gd` 会打出来，
	# 用来定位"静止自己走"/"超过极速"这类问题 —— 看哪个量在静止时就不为零）。
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
	if _prof_on:
		_prof_report -= delta
		if _prof_report <= 0.0:
			_prof_report = 1.0
			_prof_dump()
	if _chassis == null or _camera == null:
		return
	# 开镜：右键按住（InputMap 动作，无头测试也能按）。视野每帧朝目标值靠拢。
	_scoped = Input.is_action_pressed(SCOPE_ACTION)
	_update_camera_fov(delta)
	_update_scope_view()
	# 环视相机：以车为圆心，鼠标控制 yaw/pitch（yaw 相对车头，pitch 相对**地面**），
	# 距离**固定**（CAMERA_DISTANCE）—— 远近由视野（滚轮 / 开镜倍数）决定，见 `target_fov()`。
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
	var desired := target - look_dir * CAMERA_DISTANCE
	# 别让相机穿到墙外：从车心往相机方向打一条射线，撞到就贴上去
	var space := get_world_3d().direct_space_state
	if space != null:
		# 排除自己车的车体**和受击盒**：受击盒就贴在车身上，不排掉的话镜头会被
		# "自己的轮胎盒"挡住、一下拽到车里（用户报的"画面突然闪一下别的视角又回来"）。
		var exclude: Array[RID] = [_chassis.get_rid()]
		if _player_rig != null and _player_rig.hitboxes != null:
			exclude.append(_player_rig.hitboxes.get_rid())
		var query := PhysicsRayQueryParameters3D.create(target, desired)
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.has("position"):
			var clearance := target.distance_to(hit["position"]) - 0.25
			# ⚠️ 至少留 CAMERA_MIN_DISTANCE：贴太近时 `look_at` 的方向几乎是零向量，
			# 相机朝向会瞬间失效 → 画面闪一下别的视角再回来（就是这一帧的 bug）。
			desired = target - look_dir * clampf(clearance, CAMERA_MIN_DISTANCE, CAMERA_DISTANCE)
	# 不做平滑（用户要"关了平滑视角"）：相机硬贴在环视位置上，转视角没有拖影
	_camera.global_position = desired
	if _camera.global_position.distance_to(target) > CAMERA_MIN_DISTANCE * 0.5:
		_camera.look_at(target, Vector3.UP)


## 环视相机的**基准朝向**：鼠标的 `_camera_yaw` 是相对它转的。
##   跟车（follow = true）→ 车头的水平投影：车一转向，画面跟着转；
##   不跟（follow = false）→ 世界 +x：鼠标转的是世界绝对朝向，车怎么转画面都不动。
## 抽成静态函数是为了让这条语义能被测试钉住（见 test_robot.gd）。
static func camera_yaw_reference(flat_forward: Vector3, follow: bool) -> Vector3:
	return flat_forward if follow else Vector3.RIGHT


## ── 镜头：视野（FOV）/ 开镜倍率 ─────────────────────────────────────────────
## 用户定的规则：**滚轮调视野，不调远近**（相机和车的距离固定）；**右键按住开镜**，
## 开镜时滚轮调 2~16 倍，倍率在这一场里记着（收镜不清零，下次按下去还是它）。
## 为什么用视野而不是距离：距离一变，"环视中心"到眼睛的臂长就变了，瞄准的手感和
## 遮挡关系全跟着漂；视野只改画面的广角/长焦，相机位置不动。

## 开镜后的视野：倍率越大视野越窄（2 倍镜 = 视野减半）。纯函数，测试直接打它。
static func scoped_fov(hip_fov: float, zoom: float) -> float:
	return clampf(hip_fov / maxf(1.0, zoom), 1.0, 179.0)


## 滚轮一格（正 = 往前滚 = 放大）：腰射视野变小，夹在 FOV_MIN~FOV_MAX。
static func fov_after_wheel(current: float, notches: int) -> float:
	return clampf(current - float(notches) * CAMERA_FOV_STEP, CAMERA_FOV_MIN, CAMERA_FOV_MAX)


## 滚轮一格（正 = 往前滚 = 放大）：倍率按**乘法**走（2→2.5→3.1→…→16），
## 各倍率下"一格"的观感一致；夹在 SCOPE_ZOOM_MIN~MAX。
static func zoom_after_wheel(current: float, notches: int) -> float:
	return clampf(
		current * pow(SCOPE_ZOOM_STEP, float(notches)), SCOPE_ZOOM_MIN, SCOPE_ZOOM_MAX
	)


## 这一帧该用的视野：开镜 = 腰射视野 ÷ 倍率，没开镜 = 腰射视野。
func target_fov() -> float:
	return scoped_fov(_fov, _scope_zoom) if _scoped else _fov


## 鼠标灵敏度要跟着**视野**缩放（用户 2026-10-18 提的：不缩放的话开镜后手感很怪）。
##
## 为什么用 tan(FOV/2) 的比例而不是 FOV 的比例：投影的缩放本身就是 1/tan(FOV/2)，
## 所以按 `tan(当前/2) / tan(参考/2)` 缩完，"一个鼠标计数走过的屏幕像素"在任何倍率下都一样 ——
## 16 倍镜下也能稳稳跟枪，不会轻轻一动画面就飞出去。参考视野 = 没开镜时的默认视野，
## 也就是设置里那条灵敏度滑条标定的那个视野。
##
## 下限 0.02 防止极端倍率下灵敏度变成 0（鼠标像卡住）。
static func look_sensitivity_scale(view_fov: float, reference_fov := CAMERA_FOV) -> float:
	var reference := tan(deg_to_rad(maxf(1.0, reference_fov)) * 0.5)
	if reference <= 0.000001:
		return 1.0
	return maxf(0.02, tan(deg_to_rad(clampf(view_fov, 1.0, 179.0)) * 0.5) / reference)


## 开镜时显示镜筒遮罩 + 倍率滑条，同时把原来的白色准星收起来（遮罩里有分划）。
func _update_scope_view() -> void:
	if _scope_overlay != null:
		_scope_overlay.set_state(_scoped, _scope_zoom, SCOPE_ZOOM_MIN, SCOPE_ZOOM_MAX)
	if _crosshair != null:
		_crosshair.visible = not _scoped


## 滚轮：开镜时调倍率、平时调腰射视野。正数 = 往前滚 = 放大。
func zoom_wheel(notches: int) -> void:
	if notches == 0:
		return
	if _scoped:
		_scope_zoom = zoom_after_wheel(_scope_zoom, notches)
	else:
		_fov = fov_after_wheel(_fov, notches)


## 把 `_camera.fov` 朝 `target_fov()` 推（CAMERA_FOV_SPEED = 0 = 瞬间到位）。
func _update_camera_fov(delta: float) -> void:
	if _camera == null:
		return
	var target := target_fov()
	if CAMERA_FOV_SPEED <= 0.0:
		_camera.fov = target
		return
	_camera.fov = move_toward(_camera.fov, target, CAMERA_FOV_SPEED * delta)


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
	# 鼠标 = 自由环视（相对车头）；滚轮 = 视野（平时）/ 开镜倍率（按住右键时）。
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# 忽略"离谱"的鼠标跳变：切窗口 / 系统把光标拉回中心 / 抓取模式刚生效时，系统会送来一帧
		# 巨大的 relative（几百上千像素），表现就是**视角突然甩到别处再回来**（用户报的"闪烁"）。
		# 正常的快速甩枪一帧也就几十像素，220 足够宽。
		if absf(event.relative.x) > MOUSE_MAX_DELTA or absf(event.relative.y) > MOUSE_MAX_DELTA:
			return
		var base := GameSettings.mouse_sensitivity()  # 游戏设置里的灵敏度
		# 灵敏度跟着**当前**视野缩放（不是目标值）：看到多窄，就按多窄的手感转，
		# 这样调 FOV（滚轮）和开镜（倍率）都不会出现"一动就飞"或"怎么推都不动"。
		var view_fov := _camera.fov if _camera != null else _fov
		var sensitivity := base * look_sensitivity_scale(view_fov)
		_camera_yaw = wrapf(
			_camera_yaw - event.relative.x * sensitivity, -180.0, 180.0
		)
		_camera_pitch = clampf(
			_camera_pitch - event.relative.y * sensitivity, CAMERA_MIN_PITCH, CAMERA_MAX_PITCH
		)
		return
	if event is InputEventMouseButton and event.pressed:
		# 往前滚 = 放大：平时 FOV 变小，开镜时倍率变大（见 `zoom_wheel()`）
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_wheel(1)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_wheel(-1)
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
		# F1 = 显示坐标（米）：手动摆放对战场地（data/arena/battle_layout.txt）时抄数字用
		if event.keycode == KEY_F1:
			_show_coords = not _show_coords
			return
		# F9 = 帧预算探针：每秒在控制台打印**最慢那一帧**拆到各段的耗时
		# （交火掉帧时用，看是轮胎 / 转塔 / 开火 / 伤害结算哪一段）
		if event.keycode == KEY_F9:
			_prof_on = not _prof_on
			_prof_worst = {}
			_prof_worst_ms = 0.0
			_prof_report = 1.0
			print("[探针] %s（每秒打印一次最慢帧的拆解）" % ("已开启" if _prof_on else "已关闭"))
			return
		if event.keycode == KEY_ESCAPE:
			# ESC = 暂停 + 弹菜单（返回战斗 / 游戏设置 / 自爆 / 返回主界面）。
			# 注意：暂停之后这一帧的输入就由菜单自己处理了（菜单是 PROCESS_MODE_ALWAYS）。
			_open_pause_menu()
			return
		# Q = 手动标记敌人（对战模式覆盖 `_on_mark_pressed()`；测试场里什么也不做）
		if event.is_action_pressed(MARK_ACTION):
			_on_mark_pressed()
			return