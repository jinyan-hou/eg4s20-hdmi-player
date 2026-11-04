# 源码来源与改动范围

本项目基于比赛配套`lab_ex5_i2s`例程及安路TD IP进行扩展，保留已有来源标记，未为整套工程附加统一授权。

## 新增模块

- `src/user_source/hdl_source/AVP/avp_reader.v`
- `src/user_source/hdl_source/AVP/avp_audio.v`
- `src/user_source/hdl_source/AVP/avp_subtitles.v`
- `src/user_source/hdl_source/SD/sd_native_4bit.v`
- `src/user_source/hdl_source/OSD/brightness_control.v`
- `src/user_source/hdl_source/OSD/brightness_osd.v`
- `src/user_source/hdl_source/OSD/audio_waveform.v`
- `src/user_source/hdl_source/OSD/key_hold_actions.v`
- `src/user_source/hdl_source/OSD/show_controller.v`

## 基于配套例程修改

- `src/user_source/hdl_source/top_tf_hdmi_audio.v`
- `src/user_source/hdl_source/video_rgb_to_axis_640x480.v`
- `src/user_source/hdl_source/SD/bmp_read.v`
- `src/user_source/hdl_source/SD/frame_fifo_read.v`
- `src/user_source/hdl_source/SD/frame_fifo_write.v`
- `src/user_source/hdl_source/SD/frame_read_write.v`
- `src/user_source/hdl_source/SD/sd_card_bmp.v`

## 第三方依赖

参考模块、加密核心和生成IP未放入公开目录；精确清单见`vendor_dependencies.json`。其中`include/global_def.v`为修改版依赖，包含50MHz SDRAM时钟周期与刷新计数修正，不能使用原ZIP参数替代。旧例程面向另一器件的`edid_debug.cwc`及其工程引用已从公开副本移除；当前构建不启用该调试配置。源目录的完整RTL在整理过程中未被修改。
