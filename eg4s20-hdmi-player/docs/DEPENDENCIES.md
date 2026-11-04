# 厂商依赖与本地补齐

本工程直接参考开发板比赛资源包中的 `lab_ex5_i2s` 音视频例程。所需核心与`2_Example/31_hdmi_tx_display_B`采用的另一套HDMI显示架构不同，不能相互替代。

公开目录保留本项目新增/修改RTL、约束和IP参数配置，排除了未改动的配套参考代码、安路加密HDMI/SDRAM核心及生成网表。`vendor_dependencies.json`逐项列出路径与匹配版本SHA256。没有这些依赖不能宣称完整FPGA构建可复现，但六组独立逻辑仿真可以直接运行。

## 具有匹配完整工程时

执行根目录README中的`restore_vendor_dependencies.py --from-project`，参数是自己合法取得且与本版本匹配的完整工程目录。工具先校验所有来源哈希，再复制缺少的依赖；若目标已有不同文件会停止，不覆盖。它不会下载、提交Git、烧录或访问TF卡。所恢复文件已加入`.gitignore`，勿手工把它们上传到公开仓库。

## 仅具有比赛配套资源时

合法取得配套资源包后，按清单从`lab_ex5_i2s`复制参考代码到相同相对路径。注意`include/global_def.v`和`SD/video_define.v`虽未作为独立综合文件参与，仍被其他模块包含。

`include/global_def.v`是本项目修改的依赖，原ZIP版本不能直接使用。SDRAM运行50MHz，需修改以下两个宏，其余内容保留原文件：

```verilog
`define SDR_CLK_PERIOD 20
`define SELF_REFRESH_INTERVAL (64000000/`SDR_CLK_PERIOD/2**(`ROW_WIDTH)-1)
```

以清单SHA256核对匹配版本，再进行构建。旧例程的125MHz参数不适用于当前工程。

五项活跃IP配置位于`src/td_project/al_ip/PLL_HDMI_AUDIO.ipc`以及`src/user_source/hdl_source/IP`中的两个FIFO、sys_pll和video_pll配置。使用合法TD的IP生成器生成配套Verilog及FIFO时序约束。当前FIFO/PLL配置包含本项目调整，不能用原例程默认输出覆盖。TD生成版本或文件头变化可能使SHA不同，应核对实际参数并重新综合、布局布线、验证时序后使用。

`.al`中的IP目录已统一为实际的大写`IP`。TD原生项目属性含`UsedInP&R`，并非严格XML，通用检查器需要转义该属性，不能据通用XML报错认定TD项目无效。

厂商文件遵循其原有授权，本仓库未核实或授予第三方代码再分发权；参数配置也不代表HDMI或SDRAM协议核为本项目原创。不要上传工具许可证、私钥或完整厂商资料包。
