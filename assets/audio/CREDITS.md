# 音频素材来源与授权

这个目录下所有素材都是**免费**的，可以随项目一起分发。授权分类记在下面 ——
CC0 不需要署名，CC-BY 需要署名（署名就写在这里）。

| 文件 | 用途 | 来源 | 作者 | 授权 |
| --- | --- | --- | --- | --- |
| `engine_loop.wav` | 车轮/车的引擎循环声 | [OpenGameArt: racing car engine sound loops](https://opengameart.org/content/racing-car-engine-sound-loops) | 见该页作者栏 | **CC0 1.0**（公有领域） |
| `music_loop.wav` | 大厅 / 建造模式的循环音乐 | [OpenGameArt: Menu Loop](https://opengameart.org/content/menu-loop) | 见该页作者栏 | **CC0 1.0**（公有领域） |
| `machine_gun_shot.mp3` | 轻机枪开火声 | [OpenGameArt: Light Machine Gun](https://opengameart.org/content/light-machine-gun) | 见该页作者栏 | **CC-BY 4.0** —— 署名见下 |

## 署名（CC-BY 4.0）

> 机枪开火音 `machine_gun_shot.mp3`：来自 OpenGameArt 的 "Light Machine Gun"
> （https://opengameart.org/content/light-machine-gun），授权 CC-BY 4.0
> （https://creativecommons.org/licenses/by/4.0/）。作者信息见上面的来源页。

## 换素材时记得

* **响度不用改文件**：每个素材的强弱写在 [`data/audio.txt`](../../data/audio.txt)
  （`shot` / `engine_idle` / `engine_full` / `music`，单位 dB 偏移），改完进一次新场景就生效。
* 换文件后要**重新导入**（编辑器里 `filesystem_manage(op="reimport")`，或者让编辑器自己扫一遍）；
  `.wav` 默认不循环，循环是运行时在 `scripts/game_audio.gd` 里打开的（`AudioStreamWAV.loop_mode`），
  换文件不用改导入设置。
* 引擎循环最好选**短、无缝**的（现在是 0.86 秒、44.1kHz 单声道）——
  音高会被按车速拉到 0.75~2.3 倍，太长/太"具体"的录音拉起来会很怪。
