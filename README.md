<<<<<<< HEAD
a build-drive-flight game like robocraft or corssout.made by godot with llm, i dont understand its code very much. if you like this game please give me advise and fix its bugs
=======
# pixel war

a build-drive-fight game like Robocraft or Crossout. made by godot with llm,
i don't understand its code very much. if you like this game please give me advice and fix its bugs.

玩法一句话：**一个体素载具沙盒** —— 在建造模式里用方块拼一台车（装核心、装轮轴/轮胎、装机枪），
然后开进测试场跑赛道、打靶子。

> 现在还是**开发中的原型**：核心玩法（建造 / 驾驶 / 开火 / 毁伤）都能用，但还没有关卡目标、
> 没有存档 UI、美术基本都是体素占位。

## 怎么玩

* **Web 版**：等发布后直接点仓库首页的链接（GitHub Pages），浏览器里就能玩。
* **Windows 版**：到 [Releases](../../releases) 下载 zip，解压后运行里面的 exe。
* **从源码跑**：见下面「从源码运行」。

游戏流程：主界面 →「进入载具编辑」拼一台车 → ESC →「去测试场（先保存）」→ 开车、开火。
进测试场要求：**装了核心，而且所有零件都和核心连在一起**（HUD 上会写清楚差什么）。

## 操作

**建造模式**

| 操作 | 作用 |
| --- | --- |
| 左键 | 放置手上的零件（贴着别的零件/地面的连接面） |
| 右键 | 拆除瞄准的零件（镜像开着时会连镜像位置那件一起拆） |
| `1`~`9` | 选物品栏里的零件 |
| `R` | 换放置朝向（绕连接面转 90°） |
| `M` | 开/关**镜像建造**（左右对称） |
| `[` `]` | 移动对称面（每次半格） |
| `O` | 显示重心 |
| WASD / 空格 / Shift | 飞相机（空格上升、Shift 下降） |
| ESC | 菜单（保存 / 拉载具列表 / 游戏设置 / 去测试场） |

**测试场**

| 操作 | 作用 |
| --- | --- |
| `W` `S` | 油门 / 反向（反方向键 = 先自动刹车，停稳再倒车） |
| `A` `D` | 转向 |
| 鼠标 | 环视 + 瞄准（准星是屏幕中心那颗十字） |
| 左键 / 空格 | 开火（按住连发，射速由部件文件的 rpm 管） |
| 滚轮 | 相机远近 |
| `O` | 显示重心 |
| `[` `]` | 缩放场地 |
| `↑↓←→` / `<` `>` | 推车 / 升降（调出生点用） |
| ESC | 回主界面 |

## 从源码运行

1. 装 **Godot 4.7.2**（标准版即可，不需要 .NET 版）。
2. 用 Godot 打开本目录（导入项目），或者命令行：

   ```
   godot --path .
   ```

3. 主界面 → 建造模式拼车 → ESC →「去测试场（先保存）」。

跑测试（不需要编辑器）：

```
godot --headless --path . --script res://tools/run_tests.gd
```

## 目录

| 目录 | 内容 |
| --- | --- |
| `voxel/` | 体素/零件模型层：部件定义、体素体积、建造网格（放置 / 连接 / 镜像） |
| `scripts/` | 游戏层：主界面、建造模式、测试场（轮胎物理 / 武器 / 伤害 / 音频） |
| `data/parts/` | 部件文件（`.part.txt`：形状、数值、连接面、轮子/武器参数） |
| `data/vehicles/` | 保存的载具（`.vehicle.txt`） |
| `data/*.txt` | 用户可手调的表（音频强度、全局手感辅助） |
| `scenes/` | 场景：主界面 / 建造模式 / 测试场 / 部件实验室 |
| `tools/` | 命令行体检脚本（场地、模型、驾驶、连通性…） |
| `tests/` | 测试套件（`test_*.gd`，见上面的命令） |
| `docs/parts-pipeline.md` | **设计文档**：每一处为什么这么写、踩过哪些坑 |

## 素材与授权

* **代码**：MIT（见 [LICENSE](LICENSE)）。
* 第三方素材各自的授权如下（都允许随项目分发）：

* `assets/arena/truck_town/` —— Godot 官方 demo **Truck Town**（MIT）。其中 tree / lamp 两个模型
  来自 Sketchfab，是 **CC-BY**，署名要求见该目录里的 `CREDITS_truck_town_README.md`。
* `assets/audio/` —— 引擎声/音乐是 **CC0**，机枪开火音是 **CC-BY 4.0**；
  来源与署名见 `assets/audio/CREDITS.md`。
* `addons/godot_ai/` —— 第三方 Godot 编辑器插件（MCP 工具，自带上游 `LICENSE`）。
  **只是开发时用的，游戏本身不依赖它。**

## 已知问题 / 待办

* 没有撤销、复制粘贴、部件分类与成本显示。
* 没有关卡目标、没有存档 UI、没有联机。
* 美术是体素占位（枪口火焰、爆炸都是简单方块）。
* 性能：建造模式部件多了以后，进场时会做一次连通性 / 射界计算（实测 200 多个零件约几毫秒）。
>>>>>>> 2c98c73 (pixel war：可玩原型（建造模式 + 测试场：轮胎物理 / 转塔武器 / 毁伤 / 音频）)
