# 素材制作与寻址

环境：Windows，Python3.11或更新版本，OpenCV、NumPy、Pillow；音频提取工具使用MATLAB。字体读取系统`C:/Windows/Fonts/msyh.ttc`，不随仓库分发字体。

1. 在仓库根目录自行准备具有使用权限的`Video.mp4`和UTF-8编码`Video_txt.txt`。字幕格式为`[mm:ss.mmm]文字`，时间必须严格递增；AVP包含的字形数量不超过256种。
2. 使用48kHz音频输入；MATLAB工具只做混合和16位PCM转换，不做重采样。在MATLAB中将`media/scripts`加到路径，运行`extract_audio`，在`media/work`生成PCM及信息文件。
3. 安装`media/requirements.txt`中的依赖，运行`python media/scripts/prepare_video640.py`，在`media/output640`生成640×480、10fps的`VIDEO640.AVP`。
4. 运行`python media/scripts/prepare_video640.py --check`核对包结构。此操作需事先有对应PCM中间文件，脚本按项目原有工作流运行。
5. 将生成的素材复制至自己的TF卡后，用`python media/scripts/card_layout.py <drive:/VIDEO640.AVP>`查询只读物理布局；无需写盘命令。只有连续分配且地址核对正确的文件适合当前RTL。
6. 依据新素材更新顶层的文件LBA、包头CRC字段、帧数等绑定参数，并核对字幕/字形容量。不可把当前2270帧素材的参数照用于任意新视频。

当前参考包：前17扇区为头与字幕等元数据；每记录614400字节RGB565、9600字节PCM及128字节填充，共1219个512字节扇区。参考素材2270帧、约227秒。不同字幕数量会影响元数据扇区布局。

生成的audio_info/manifest可能带输入文件本机路径，属于本地产物，默认忽略不上传。大AVP、PCM及原始媒体都不作为普通Git文件发布。
