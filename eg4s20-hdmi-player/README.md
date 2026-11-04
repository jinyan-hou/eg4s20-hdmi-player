# EG4S20 HDMI Multimedia Player

An interactive HDMI multimedia display system based on the Anlogic EG4S20 FPGA.

基于安路 **EG4S20BG256 / HX4S20** 开发板的TF卡多媒体显示工程。终端运行时由FPGA完成读卡、缓存、音画字幕同步及HDMI输出；电脑在素材准备阶段转换媒体格式。

## 功能与实际参数

- HDMI有效画面640×480，像素时钟25MHz，刷新率约59.52Hz。
- 视频内容640×480、10帧/秒，读取离线转换的RGB565数据；FPGA不解码MP4。
- 48kHz、16位单声道PCM，按素材原始音量输出到HDMI左右声道，AUDIO_SHIFT=0。
- 以实际消费的音频样本计数同步视频与时间戳字幕。
- 640×480、24位无压缩BMP；封装内嵌SDRAM双帧缓存。
- 四档亮度、亮度与播放状态OSD、实时音频时域波形。
- 图片预读、自动轮播和淡出淡入；KEY2长按暂停/继续。

**验证范围：** 基础视频、音频、字幕及亮度OSD已有实板正常反馈，波形已有可见反馈。最新版轮播、转场和暂停完成仿真及布局布线，尚未记录最新整合版实板验收。代码公开不代表所有功能已通过最新实板测试。

## 按键

| 按键 | 图片模式 | 视频模式 |
|---|---|---|
| KEY1 | 复位，进入视频，亮度100% | 同左 |
| KEY2短按并释放 | 下一图并转场 | 从头播放，退出暂停 |
| KEY2长按约1.5秒 | 自动轮播开/关 | 暂停/原位置继续 |
| KEY3 | 100%→25%→50%→75% | 同左 |
| KEY4 | 切到视频并重播 | 切到图片，自动轮播开启 |

## 目录

- `src/user_source/hdl_source`：本项目新增和修改的RTL。
- `src/user_source/constraints_source`：引脚与时序约束。
- `src/td_project`：TD工程和本项目使用的IP参数配置。
- `sim`：六组独立逻辑仿真、脚本及音频基线。
- `media/scripts`：素材打包、音频提取和TF物理地址只读查询工具。
- `docs`：设计、验证范围、来源和依赖说明。

## 仿真

六组行为仿真不依赖TF卡、开发板或安路加密IP，需要Vivado Simulator（参考版本2022.2）。脚本只在各自`*_run`目录生成文件，不烧录开发板。

在PowerShell中将路径替换成自己的Vivado安装位置：

```powershell
$env:VIVADO_BIN = 'C:/tools/Xilinx/Vivado/2022.2/bin'
./sim/run_key_hold.ps1
./sim/run_pause_audio.ps1
./sim/run_show_osd.ps1
./sim/run_bmp_preload.ps1
./sim/run_show_controller.ps1
./sim/run_show_video.ps1
```

OSD脚本还使用PATH中的Python生成预览PNG。暂停测试所需旧版音频基线已放在`sim/fixtures`，不依赖其他历史工程。

## TD构建与厂商依赖

**这是包含项目改动和依赖说明的公开源码目录，不是独立包含厂商IP的完整发行包。** 直接打开前须补齐依法取得的HDMI、SDRAM基础核心和TD生成网表，详见[依赖说明](docs/DEPENDENCIES.md)与[来源清单](docs/PROVENANCE.md)。不要将本目录所有文件统一标为原创，未附加整套工程统一开源许可证。

从自己已有的、与此版本匹配的完整工程恢复依赖：

```powershell
python ./tools/restore_vendor_dependencies.py --from-project '<your-matching-complete-project>'
python ./tools/restore_vendor_dependencies.py
```

随后在TD6.2中打开`src/td_project/HDMI1.4b_Transmitter_v1.0.al`，或使用TD命令行工具运行`run_build.tcl`。许可证使用本机合法配置；若需要指定文件，将`ANLOGIC_LICENSE`环境变量设为自己的许可证路径。仓库不提供许可证。构建脚本检查时序总负裕量后才生成bit，不执行下载或Flash固化。

## 素材与边界

制作方法见[媒体说明](docs/MEDIA.md)。原视频、字幕内容、字体、音频和1.4GB的AVP包未随仓库发布。

当前播放器未实现FAT目录或碎片链解析。AVP读取已核对的连续物理扇区，BMP扫描固定扇区范围；替换或重新复制素材后必须重新查询地址并更新参数。`card_layout.py`仅只读查询，不格式化、不写卡。

## 验证记录

2026-10-29正常音量版完整工程布局布线：7302 LUT、5214寄存器、62/64 BRAM、2 DSP；SWNS +0.083ns、HWNS +0.011ns，STNS/HTNS均为0。原始完整工程的验证范围见[验证摘要](docs/VALIDATION.md)。公开副本路径迁移的复验结果另列，不能与实板验收混为一谈。
