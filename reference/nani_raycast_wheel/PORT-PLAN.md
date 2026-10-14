# 把 nani_raycast_wheel 的轮胎力模型移植进测试场（方案 B）

参照文件（MIT，Copyright (c) 2024 omiya io，原文见同目录 `LICENSE-MIT-omiya-io.txt`）：
`nani_raycast_wheel.gd`（128 行）。**这个目录有 `.gdignore`，Godot 不编译它**，只是移植参照。

## 为什么用它

它的轮胎力**正比于法向载荷**（`pacejka(susp_force, slip, ...)`），而且作者踩过同一个坑：
低速时方程发散 → 抖动，他直接**在低速切到"按速度取消"的简单模型**（第 98-99 / 104-105 行）。
我们这两天反复自激的那个问题，他给的解法是**换模型**，不是调参数。

## 移植清单（对照我们的 `TestField`）

### ① 骨架：已经做好了（第一步）
`_apply_wheel()` 现在**一个轮子只算一次力**：悬挂射线 + 16 条整圈射线只用来**探测**，
取**最深**的那个接触（法向/接触点/速度都取它），然后一次性施加。
→ Pacejka 模型需要一个"单接触、单法向载荷"，正好接在这里。

### ② 悬挂（照抄它的算法）
```
actual_length = 轮心到接触点的距离 − tire_radius
compression   = susp_rest_length − actual_length
力 = clamp(compression × 弹簧刚度 + 阻尼刚度 × compression 的变化率, 0, 上限)
```
差异：它用 `(compression − prev)/delta` 的**位置差分**当压缩速度（显式），
我们在这一步已经换成**隐式阻尼**（吃"更新后的速度"，无条件稳定）+ 硬截断上限，
**这两条要保留**（它的显式形式正是低速发散的原因之一，它靠"低速换模型"绕开）。

### ③ 轮胎力（这是移植的核心）
```
lat_slip  = asin(clamp(−平面速度.x 归一化, −1, 1))          # 滑移角
lat_force = pacejka(法向载荷, lat_slip, 1, 10, 0, 1.35)
long_slip = (前进速度 − 轮子角速度 × 半径) / max(|前进速度|, ε)
long_force = pacejka(法向载荷, long_slip, 1, 10, 0, 1.65)
pacejka(N, s, peak, stiff, curve, shape)
    = N × peak × sin(shape × atan(stiff·s − curve·(stiff·s − atan(stiff·s))))
```
与我们现在的差别：**不再用 `mu × 法向力` 截断 + `slip_falloff`**，改用**载荷乘曲线**——
小滑移时力 ∝ N × 13.5 × slip（正确的侧偏刚度），大滑移时自动饱和（不会把车掀翻）。
→ 需要**每轮一个角速度状态** `ang_vel`（它用 `net_torque = long_force × 半径 + 驱动/刹车力矩` 积分得到），
  这样才谈得上"轮子打滑/抱死"。我们的 `drive_in` / `brake_gain` 换成**力矩**（油门/刹车力矩）。

### ④ 低速切换（**这是治抖的关键，别漏**）
```
if |前进速度| < 0.1 且 |侧向速度| < 0.1:
    lat_force = −侧向速度 / delta × wheel_mass        # 直接按速度取消
    （刹车时同理：long_force = −前进速度 / delta × wheel_mass）
```
→ 低速/静止时**不走 Pacejka**，直接给一个"这一帧把残余速度削平"的力。没有它就会抖。

## 映射到部件文件（用户手调）

| 新键 | 含义 | 对应它的参数 | 起始值 |
|---|---|---|---|
| `wheel_susp_rest` | 悬挂自由长度（格） | `susp_rest_length` | 现有 `wheel_rest_length` |
| `wheel_spring_stiffness` | 弹簧刚度（N/格） | `susp_spring_stiffness` | 现有 `wheel_stiffness` |
| `wheel_damper_stiffness` | 阻尼（N·秒/格） | `susp_damper_stiffness` | 现有 `wheel_damper_*` |
| `wheel_tire_radius` | 轮胎半径（格） | `tire_radius` | 自动算（保留现有） |
| `wheel_mass` | 单轮簧上质量（kg） | `wheel_mass` | 自动按车重算（保留现有） |
| `wheel_grip_factor` | 抓地倍率 | `grip_factor` | 1.0 |
| `wheel_lat_peak/stiff/curve/shape` | 侧向 Pacejka 四系数 | `pacejka(...,1,10,0,1.35)` | 1 / 10 / 0 / 1.35 |
| `wheel_long_peak/stiff/curve/shape` | 纵向 Pacejka 四系数 | `pacejka(...,1,10,0,1.65)` | 1 / 10 / 0 / 1.65 |
| `wheel_drive_torque` / `wheel_brake_torque` | 驱动/刹车**力矩**（N·格） | `drive_torque` / `brake_torque` | 由现有 `wheel_engine_force`/`wheel_brake` 换算 |
| `wheel_low_speed_cutoff` | 低速切换阈值（格/秒） | 0.1 | 0.1 |

## 验证步骤（不许跳过）

1. `godot --headless --path . --script res://tools/probe_flat.gd -- <车id> arena`
   静置 6 秒：y 不动、着地轮数满、倾角 < 1°（两台车都要过）。
2. **过坎场景**（待做进 `probe_flat`）：平地上放一块 0.1~0.2 格的方块，
   定油门开过去 —— 这是原问题（"稍微不平就抖着升空"）的复现场景，必须过。
3. 全量测试 `run_tests.gd`；然后重出 Windows 包。

## 授权

MIT：**必须保留版权声明**（已放同目录 `LICENSE-MIT-omiya-io.txt`），
并且在移植过去的代码里注明来源（脚本头写清 `nani_raycast_wheel.gd` + 作者 + 链接）。
