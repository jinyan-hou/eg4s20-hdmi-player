
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 增加 hdmi_5x_clk / audio_mclk 的命名
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    你的原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径是按你当前工程实例名写的：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#      音频 PLL     -> u_audio_pll
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]

# ------------------------------------------------------------
# 4. HDMI 像素/串行时钟由同一个 PLL 产生。
#    两个时钟同时运行，不能声明为互斥时钟。
# ------------------------------------------------------------
# 像素和串行时钟同时运行，保持 PLL 推导的同步关系并分析两域路径。

# ------------------------------------------------------------
# 5. 音频 I2S 发生器/接收器跨域
#
#    audio_mclk 域里生成 I2S，video_clk 域里做三拍同步采样。
#    这类路径不是普通同步时序路径，直接切掉更合理。
# ------------------------------------------------------------
# PCM sample enable now comes from video_clk; there is no I2S clock crossing.

# rst_all directly drives only the eight reset-release synchronizer SR inputs.
# Their D chains and registered reset outputs remain timed, including HFO copies.
set_false_path -through [get_nets {rst_all}]

# Held request crosses through three registers. Exempt only the first capture;
# keep write_req_d0 -> d1 -> d2 and all other inter-clock paths timed.
set_false_path -from [get_clocks {sd_card_clk}] -to [get_regs {frame_read_write_m0/frame_fifo_write_m0/write_req_d0}]

# KEY3 drives only the first capture (packed into an IO register by TD).
set_false_path -from [get_ports {key_brightness}]
# KEY2 also feeds only the first input synchronizer of its short/long classifier.
set_false_path -from [get_ports {key1}]
# Brightness clocks share the board-clock master; time the full Gray sync chain.

# ------------------------------------------------------------
# 6. 可选：如果你的 frame_read_write 内部异步 FIFO 已经完全处理好了跨域，
#    且报告里总出现 video_clk / sd_card_clk / ext_mem_clk 之间的大量伪违例，
#    可以打开下面这组异步分组。
#
#    建议先不要开，先看报告；
#    只有确认这些跨域都只经过 FIFO / 同步器时再开。
# ------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks {sd_card_clk}] \
#     -group [get_clocks {ext_mem_clk}] \
#     -group [get_clocks {video_clk}] \
#     -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 7. 其余 Input/Output delay 先保持空白
#    你当前两个原始 sdc 也都没有写这部分。
# ------------------------------------------------------------

# Native SD samples 30 ns after the driven rising edge.
# Reserve 5 ns for outgoing CLK/CMD and 6 ns for pad-to-capture logic.
# Card tODLY (14 ns) and PCB round-trip delay remain a board-level check.
set_max_delay 5 -datapath_only -to [get_ports {sd_dclk sd_cmd}]
set_max_delay 6 -datapath_only -from [get_ports {sd_cmd sd_dat[*]}]
