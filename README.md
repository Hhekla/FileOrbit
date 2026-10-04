# FileOrbit

一款面向 macOS 的本地文件转换与处理工具，提供中文工作台、拖放轮盘和命令行入口。把文件加入工作台，或在 Finder 中拖动文件时按住 **⇧ Shift**，即可选择当前文件可用的转换格式；**⌥ Option + ⇧ Shift** 打开工具轮盘。

**当前版本：0.1.0-alpha.3。** 这是一个早期开源版本，源码见 [Hhekla/FileOrbit](https://github.com/Hhekla/FileOrbit)。当前以源码构建为主要使用方式，尚未提供经过 Apple 公证的正式安装包。它已实现多类常用操作，但尚不能宣称完全替代 Tangerine，也未完成对其全部选项的逐项等效验收。可用范围、依赖和明确限制见 [功能说明](docs/FEATURES.md)。

FileOrbit 从 MIT 许可的 [Kumquat](https://github.com/kelvin715/Kumquat) 派生，基线提交为 `dc51f9005b58f99aeec82748e8d7fb54d1fee5bf`。保留了上游版权和许可证；来源与修改说明见 [NOTICE](NOTICE.md)。本项目与 Tangerine、Apple 或 Kumquat 上游维护者没有官方关联。

## 能做什么

| 类别 | 主要功能 |
| --- | --- |
| 图片 | 常用格式转换、压缩、等比缩放、拼图、二维码识别、目标大小、裁剪、标注、背景、遮挡和元数据处理 |
| PDF | 转图片/文字/Word、合并、拆页、旋转、指定页码重排、水印和压缩 |
| 文档 | DOC/DOCX、RTF、ODT、HTML、TXT、Markdown 等文档的读取和支持格式输出 |
| 影音 | 格式转换、音轨提取、剪辑、压缩、静音、旋转、截图；可选 FFmpeg 提供变速、拼接、分段、声道和目标大小等 |
| 字幕 | SRT/VTT 互转及导出 TXT，保留时间戳和多行内容 |
| 压缩包 | ZIP/TAR/GZIP 互转、受限安全解压；RAR 读取取决于系统支持，尚未实测验收 |

转换在本机框架或用户安装的本机辅助工具中执行，不需要账户、订阅或大模型服务。结果保存到原文件旁边，自动选择未占用的文件名；批处理分别报告成功、失败与取消。

## 运行要求

- macOS 14 或更新版本。
- 本机验证环境为 Apple Silicon；Intel Mac 尚未验证，也未提供经过验证的 Universal 安装包。
- 编译需要兼容 Swift 5.10 包清单的 Swift 工具链和 macOS SDK。完整 `swift test` 需要带 XCTest 的 Xcode 环境；仅安装 Command Line Tools 的环境可能可以构建 App，但无法运行 XCTest。
- 基础操作使用系统框架。部分格式及高级影音功能需要用户单独安装辅助工具，见下文。

## 从源码构建

获取源码后，在项目根目录执行：

```sh
git clone https://github.com/Hhekla/FileOrbit.git
cd FileOrbit
```

```sh
bash scripts/build-app.sh
```

脚本会在 `dist/` 中新建独立版本目录，输出 `FileOrbit.app`、`FileOrbit-macOS.zip` 和 `SHA256SUMS.txt`，并打印具体位置。再次构建会创建新目录，保留已有输出。构建默认使用 release 配置；可通过 `FILEORBIT_VERSION` 和 `FILEORBIT_CONFIGURATION` 指定版本与配置。

当前脚本使用 **ad hoc 本机签名，未经过 Apple 公证**。该 ZIP 是本机构建产物，不代表可以不经额外签名、公证和测试便向所有 Mac 用户发行；macOS 也可能阻止从网络取得的未公证包。当前开发阶段可优先在自己的 Mac 上审阅并构建源码。

仅运行开发版本或查看命令行帮助：

```sh
swift run FileOrbit
swift run FileOrbit --help
```

## 使用

1. 打开 FileOrbit，从菜单栏进入“文件工作台”，添加一个或多个文件。
2. 选择动作。缩放、拼图、重排 PDF、影音变速等操作会显示所需参数；图片编辑和剪辑等操作会打开对应编辑器。
3. 执行后，结果区会出现在工作台顶部，显示完整保存路径；点击“在 Finder 中显示”定位文件，或直接“打开文件 / 打开结果文件夹”。多页 PDF 图片存于原文件旁的 `文件名 Pages` 文件夹，每页一张，结果卡显示图片数量。失败条目会显示具体原因。
4. 最近 12 个结果保留在工作台和菜单栏中，重启后仍可找回。轮盘转换完成后也可通过提示卡的“查看结果”进入。
5. 更新版本时先退出正在运行的旧版，再打开新 App；工作台右上角显示实际运行版本。

拖放轮盘提供相同的常用入口：拖动文件时按 ⇧ 选择格式，按 ⌥ ⇧ 选择工具，再把文件投递到目标区域。混合选择只展示共同可用的动作。当前工作台和通用命令行入口接受具体文件，尚未开放文件夹打包。

PDF 转 Word 提供两个明确模式：

- **页面图片（需手动选择）**：每页转成图片嵌入 Word。macOS 文本编辑不显示 DOCX 图片，因此会显示空白；正文也无法编辑。本版本尚未完成 Word/Pages 的渲染验收。
- **可编辑文字（默认）**：提取文字并重建段落；扫描页尝试 OCR。没有提取/识别到文字的页会报告失败，不生成空白 Word。复杂布局会重排，图表不保留。

## 可选辅助工具

FileOrbit **不打包、不自动下载安装** FFmpeg、ffprobe、cwebp 或 gif2webp。用户可自行选择可信来源安装。例如，已使用 Homebrew 的用户可以执行：

```sh
brew install ffmpeg webp
```

| 工具 | 作用 |
| --- | --- |
| FFmpeg + ffprobe | 更多音视频格式及高级影音操作；具体编码器仍取决于安装的构建版本 |
| cwebp | 可选 WebP 编码器；没有它时仍有内置静态 WebP 路径 |
| gif2webp | GIF 动画转 WebP 的首选路径；也可使用含 `libwebp_anim` 的 FFmpeg |

检测到工具不代表它具备所有编码器。在 GIF→WebP 路径中，缺少所需编码器或无法保持动画时会报错，不会将第一帧伪装成完整动画转换结果。安装后可在设置中查看 FFmpeg/cwebp 的检测情况。第三方工具的许可独立于本项目，见 [THIRD_PARTY](THIRD_PARTY.md)。

## 命令行示例

命令行与工作台使用相同的转换引擎。完整选项以 `--help` 为准：

```sh
swift run FileOrbit actions photo.png
swift run FileOrbit convert captions.srt --to vtt
swift run FileOrbit convert report.pdf --to docx --pdf-mode editable
swift run FileOrbit tool reorderPages report.pdf --pages '3,1-2'
swift run FileOrbit tool resize photo.png --width 1280 --height 720
swift run FileOrbit tool extract archive.zip --json
```

高级影音示例需要可用的 FFmpeg 和 ffprobe：

```sh
swift run FileOrbit tool speed clip.mp4 --speed 1.5
swift run FileOrbit tool join first.mp4 second.mp4
swift run FileOrbit tool split clip.mp4 --end 10
```

`split` 的 `--end` 表示每段时长（秒）。路径含空格时使用引号；路径以 `-` 开头时，在路径前加 `--`。`--json` 输出结果、失败、取消及警告，适合脚本处理；非零退出码表示失败或取消，不能仅因生成了部分输出就视为整批成功。

## 当前验证

已执行 96 个测试方法，全部通过，零失败、零跳过。本机没有 XCTest，使用仓库内明确标注的独立断言适配器运行原测试体；不能将此记录称为原生 XCTest 通过。覆盖范围和证据见 [验证记录](docs/VALIDATION.md)。

仅有 Command Line Tools 时可执行：

```sh
bash scripts/verify-core.sh
```

该工具不安装依赖、不删除夹具；缺失能力造成跳过会返回非零退出码。完整 Xcode 环境仍应运行 `swift test`。仓库提供 macOS CI 工作流，云端结果以 [GitHub Actions](https://github.com/Hhekla/FileOrbit/actions/workflows/macos.yml) 中对应提交的运行状态为准。

## 当前边界与参与方式

SVG、复杂 Office 高保真、多轨影音完整保留、带定位/样式的字幕转换、扫描 PDF OCR 准确率和广泛兼容性仍未完成。RAR 只尝试系统支持的读取，未承诺创建或兼容全部 RAR 变体。当前能力不是“188 个选项已全部替代”的结论。

完整边界见 [功能说明](docs/FEATURES.md)，开发与验证要求见 [CONTRIBUTING](CONTRIBUTING.md)。本项目代码依 [MIT License](LICENSE) 提供；分发时请保留上游许可、[NOTICE](NOTICE.md) 和 [第三方说明](THIRD_PARTY.md)。
