# 第三方组件说明

FileOrbit 的 MIT 许可不替代下列组件各自的许可。此表记录当前使用方式；未来如果改变为随包分发第三方二进制，应按实际版本重新核对分发材料。

| 组件 | 当前使用方式 | 许可与来源 |
| --- | --- | --- |
| Kumquat | 派生源码，保留原始版权声明与 MIT 文本 | [项目](https://github.com/kelvin715/Kumquat)、本项目 [LICENSE](LICENSE) 与 [NOTICE](NOTICE.md) |
| Apple 系统框架 | 调用 macOS 的 AppKit、SwiftUI、ImageIO、AVFoundation、PDFKit、Vision、Compression 等；不重新分发系统框架 | 按所用 macOS SDK 与系统组件适用条款使用 |
| 系统 libarchive | 动态加载 macOS 自带库，进行归档读取与写入；不随 App 附带独立 libarchive 库 | [libarchive 项目与许可说明](https://github.com/libarchive/libarchive/blob/master/COPYING)；本机版本由 macOS 提供 |
| FFmpeg / ffprobe | 可选：运行用户自行安装的命令行工具；当前 App 与 ZIP 不包含其二进制 | [FFmpeg 官方许可说明](https://ffmpeg.org/legal.html)；实际许可取决于构建所含的可选组件 |
| cwebp / gif2webp | 可选：运行用户自行安装的 libwebp 工具；当前 App 与 ZIP 不包含其二进制 | [libwebp COPYING](https://github.com/webmproject/libwebp/blob/main/COPYING) |

FFmpeg 官方说明区分 LGPL 与包含 GPL 可选组件的构建。因此不能仅根据工具名称，断言某个已安装二进制或未来捆绑包适用同一种许可。当前版本采用外部工具调用方式；本文件不对未来打包方案给出许可兼容性结论。

libarchive 的上游许可文件还说明其源码内存在分别标注的组成部分。FileOrbit 使用的是系统提供的库，未复制或重新打包上游库源码；核对某一 macOS 版本的组件时，应同时查看该系统提供的许可材料。

这些链接指向上游维护的许可信息。已安装工具的版本、构建选项和随附许可应一并保留；不要用本文件替换实际分发版本所需的版权或许可文件。
