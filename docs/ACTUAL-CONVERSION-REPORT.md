# FileOrbit 实际文件转换报告

验收日期：2026-10-05（北京时间）。当前验收版本：**0.1.0-alpha.5**。alpha.4 原始记录保留在文末。

**已实际尝试软件明确列出的全部菜单转换方向：82 个输入后缀（含同格式别名），679 个“输入后缀→输出”组合，未测方向为 0。** 每个菜单方向均至少有一个通过内容检查的正常样本，但这不意味着每个文件都能成功；例如同为 RAW 的不同机型存在明确差异。SVG 算入明确识别的输入清单，但没有可选转换菜单，另以真实 SVG 验证明确拒绝。

本轮与原有矩阵复验合计 **1082 个去重案例**：**890 个产物通过相应内容检查，48 个生成可用产物但有已知内容/外观限制，117 个明确拒绝或不支持，27 个转换失败**。失败与拒绝均未计作成功。定向重复复测替换同一案例的最终状态，历史失败证据保留；额外 GUI 操作和回归测试方法数不混入这个计数。

这次逐项真实写出文件并独立读取/解码，主矩阵通过构建后的 App 命令行入口执行，与图形工作台使用同一转换引擎。不是 679 条逐一鼠标点击记录，也不代表所有编码、相机型号、版式、文件大小与系统版本兼容。

## 覆盖范围

| 类别 | 明确输入后缀（含别名） | 菜单转换方向 | 未测方向 |
|---|---:|---:|---:|
| 图片 | 32 | 268 | 0 |
| 文档 | 12 | 75 | 0 |
| 视频及提取音频 | 14 | 204 | 0 |
| 音频 | 15 | 109 | 0 |
| PDF | 1 | 4 | 0 |
| 字幕 | 2 | 4 | 0 |
| 压缩包 | 6 | 15 | 0 |

## 实际结果

| 案例组 | 通过内容检查 | 有明确限制 | 明确拒绝/不支持 | 失败 | 合计 |
|---|---:|---:|---:|---:|---:|
| 文档补测 | 32 | 8 | 35 | 0 | 75 |
| 图片补测 | 279 | 0 | 25 | 27 | 331 |
| 影音补测 | 235 | 34 | 30 | 0 | 299 |
| PDF/归档/字幕边界补测 | 53 | 6 | 21 | 0 | 80 |
| 原有文档矩阵复验 | 43 | 0 | 0 | 0 | 43 |
| 原有图片矩阵复验 | 66 | 0 | 4 | 0 | 70 |
| 原有影音矩阵复验 | 140 | 0 | 0 | 0 | 140 |
| 原有 PDF/归档/字幕复验 | 28 | 0 | 2 | 0 | 30 |
| 纯文本 RTFD/Webarchive | 14 | 0 | 0 | 0 | 14 |
| 合计 | **890** | **48** | **117** | **27** | **1082** |

通过依据随文件类型不同：图片独立解码、尺寸/像素/透明度；动画检查逐帧内容、时间与循环；文档核对正文顺序并渲染可见内容；影音完整解码、时长、声道和测试频率；归档独立解包逐字节核对文件；字幕核对时间戳、Unicode 与多行。不能用文件存在或进程退出码代替内容检查。

最后一包另完成 **21 次 DOCX 定向复查**，未加入上面的 1,082 例主计数或增加方向数：简单列表转 PDF/TXT/Markdown 的 3 项通过，5 类复杂编号和纯图片页眉的 18 项明确拒绝，0 次非预期失败。输入均先独立读取确认是真实 DOCX，源文件保持不变，拒绝案例没有发布残缺输出；PDF 结果已实际查看。脱敏 JSON 的 `additional_final_docx_checks` 保留明细。

## 本轮修复与复验

- **图片**：修正 ICNS 多分辨率识别、部分 NEF 导出 JPEG/HEIC、多页 TIFF 转 PDF/Word 缺页、EXR 解码回退；GIF/APNG 转 WebP 增加 `cwebp + webpmux` 路径。10ms 短帧动画不再被延长；四种 GIF 循环声明独立解析后正确映射为 0/2/3/1 次总播放。两帧 0.6 秒、三帧 1.0 秒 GIF 转视频均保留实际画面和总时长。
- **文档**：将 Word 样式继承、简单列表编号转换为读取器可识别的格式，修复旧版标题字号/列表丢失；RTFD/Webarchive 转 HTML 实际内嵌图片，独立读取像素一致。402 段长中文文档的 20 页内容已核验。复杂 Word 内容及当前不能保留图片的输出路径明确拒绝，避免静默漏内容。
- **PDF**：补齐表单值的图片渲染与文字提取；扫描正文加表单值同时保留；文本字段中的字面值 `Off` 不再被误认为未选中按钮。长文档、旋转/裁剪页、低对比扫描页、空白页、密码及损坏文件均已实测。
- **影音**：修复 MPEG/TS/AMR 等原生音轨读取失败时的转换回退，避免部分 5.1 音频被悄悄变为立体声；新增针对实际额外音轨、字幕及 HDR 信息损失的警告。补测包含 AMR 真样本、可变帧率、旋转、3 分钟视频、无声/损坏文件、多音轨、5.1 和 HDR10。
- **归档与字幕**：修复 `.gzip` 被错误视为普通载荷；真实 RAR5 压缩/solid 样例转 ZIP/TAR/GZIP 已逐字节验证。符号链接、越界路径、损坏与资源限制等拒绝路径保留。字幕异常时间轴与不可保留样式也已实际验证。

## 仍然失败或有限制的项目

1. **27 个真实 RAW 案例失败**：Fujifilm FinePix S5000（RAF）、Olympus E-10（ORF）、Samsung NX500（SRW）各 9 个输出。当前本机解码能力无法处理这些样本。同格式的 Fuji X-T1、Olympus E-420、Samsung NX10 各方向均通过，因此不能按扩展名承诺所有机型兼容。
2. **Word 高保真仍有边界**：页眉页脚（含纯图片）、脚注、公式、未实现的复杂编号等明确拒绝；DOCX 内嵌图片到富文本输出不能完整保留时拒绝。TXT/Markdown 的纯文字提取不包含图片/表格版式。未宣称 Microsoft Word 或跨平台 Office 渲染验收完成。
3. **部分产物有已知限制**：48 个案例包含文档纯文字/版式损失、影音额外轨道/字幕/HDR/环绕声损失，以及 6 个已填写表单的渲染结果。表单文字内容与数值已独立 OCR 检查，但 PDFKit 与 Poppler 的字段字体垂直位置不同，不能称为像素一致。
4. **明确拒绝不代表成功转换**：透明 AVIF、独立封面帧 APNG、将多页 TIFF 导出为会丢页的单张图像、SVG、空白 PDF 文字提取，以及损坏/密码/危险归档等已列为拒绝。APNG 独立封面帧的系统解码结果错误，当前通过报错防止生成错误画面。
5. EXR 回退使用 16 位 RGBA 中间图，不承诺保留完整浮点 HDR；所有 OCR 仍需人工复核。保守的 PDF 文字策略会拒绝包含正常空白页/纯插图页的混合文档。
6. 仍未做 Intel、多 macOS 版本、全部相机/编解码变体、任意规模压力测试、完整 Finder 拖放与多屏矩阵；本次完成的是当前明确格式菜单的实际转换覆盖，不是 Tangerine 所有功能的等效验收。

## 用户可见结果与版本

- 在 alpha.5 工作台实际把“扫描正文与表单”合成 PDF 转 TXT，界面显示成功 1、失败 0；点击打开后，文本编辑可见扫描正文、中文、金额和表单值。
- 同一 PDF 转 PNG，点击“在 Finder 中显示”定位到真实结果，再用 Quick Look 查看图像，正文与表单值均可见。原有用户 PDF 和多页图片的界面验收记录保留在下方 alpha.4 历史中。
- 桌面原件未改动。用户简历、路书、实际文件名和正文仅留本机；公开摘要不含私人路径或内容。原文件、失败基线和中间产物保留，没有批量删除。
- 最终构建已正常打开，工作台显示 alpha.5，并恢复最近转换的 PNG 结果；运行进程路径核验确认只剩最终新版。

## 证据、构建与复跑

最终 App 可执行文件 SHA-256：`2a190453b7d7a88270935af7b29db8c3935d6fd1cb2f1e55b50a763839f80c1e`。

主矩阵在 alpha.5 候选构建运行，后续修复只针对受影响路径复测；逐例记录保留实际二进制 SHA-256，没有把旧构建结果冒充全部在最后一包重跑。额外 **119 个回归测试方法全部通过，零失败、零跳过**，使用独立断言适配器，非原生 XCTest，不混入实际转换案例数。

- [逐例脱敏摘要及全部菜单覆盖](actual-conversion-results.json)：包含状态、标量检查结果和各案例实际构建哈希。
- 本机完整证据在 `.build/extended-conversions-20261005/`；包括 `images/results-consolidated.json`、`documents/verified/results.json`、`media-alpha5/results.json`、`pdf-archives/accepted/results.json` 与 GUI 记录 `ui-accepted.json`。旧失败记录未删除。
- 复跑使用 `scripts/real-conversion-*-extended.py`、`scripts/real-conversion-extended-pdf-archives.py`、原有矩阵脚本和 `scripts/summarize-conversion-coverage.py`。需本机 macOS 框架及已安装的 FFmpeg、libwebp、Python 文档/图像库与独立读取工具。
- 最终构建使用本机 ad hoc 签名，仍未经过 Apple 公证。上述测试是本机结果；云端验证以 GitHub Actions 对应提交的最终状态为准。
- 最终 App 构建、本机签名验证和 ZIP CRC 检查均通过。

## 全部输入后缀与已测试菜单方向

下表列的是**实际尝试过的菜单方向**；同一方向的正常样本、边界拒绝与失败变体详见 JSON。后缀别名分别计数，PDF→DOCX 两种模式不重复增加方向数。

| 输入后缀 | 已实际尝试的可选输出 | 方向数 |
|---|---|---:|
| 3GP | MP4、MOV、MKV、WEBM、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 15 |
| AAC | M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 8 |
| AIF | M4A、MP3、WAV、FLAC、OGG、OPUS、WMA | 7 |
| AIFC | M4A、MP3、WAV、FLAC、OGG、OPUS、WMA | 7 |
| AIFF | M4A、MP3、WAV、FLAC、OGG、OPUS、WMA | 7 |
| AMR | M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 8 |
| ARW | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| AVI | MP4、MOV、MKV、WEBM、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 14 |
| AVIF | JPG、PNG、WEBP、HEIC、TIFF、BMP、PDF、DOCX | 8 |
| BMP | JPG、PNG、WEBP、HEIC、TIFF、AVIF、PDF、DOCX | 8 |
| CAF | M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 8 |
| CR2 | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| CR3 | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| DNG | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| DOC | PDF、DOCX、RTF、TXT、HTML、ODT、MD | 7 |
| DOCX | PDF、RTF、TXT、HTML、ODT、MD | 6 |
| EXR | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| FLAC | M4A、MP3、WAV、OGG、OPUS、AIFF、WMA | 7 |
| FLV | MP4、MOV、MKV、WEBM、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 15 |
| GIF | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX、MP4 | 10 |
| GZ | ZIP、TAR | 2 |
| GZIP | ZIP、TAR、GZ | 3 |
| HEIC | JPG、PNG、WEBP、TIFF、AVIF、BMP、PDF、DOCX | 8 |
| HEIF | JPG、PNG、WEBP、TIFF、AVIF、BMP、PDF、DOCX | 8 |
| HTM | PDF、DOCX、RTF、TXT、ODT、MD | 6 |
| HTML | PDF、DOCX、RTF、TXT、ODT、MD | 6 |
| ICNS | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| ICO | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| J2K | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| JFIF | PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 8 |
| JP2 | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| JPE | PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 8 |
| JPEG | PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 8 |
| JPG | PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 8 |
| JXL | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| M2TS | MP4、MOV、MKV、WEBM、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 15 |
| M4A | MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 7 |
| M4V | MP4、MOV、MKV、WEBM、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 15 |
| MARKDOWN | PDF、DOCX、RTF、TXT、HTML、ODT | 6 |
| MD | PDF、DOCX、RTF、TXT、HTML、ODT | 6 |
| MKV | MP4、MOV、WEBM、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 14 |
| MOV | MP4、MKV、WEBM、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 14 |
| MP3 | M4A、WAV、FLAC、OGG、OPUS、AIFF、WMA | 7 |
| MP4 | MOV、MKV、WEBM、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 14 |
| MPEG | MP4、MOV、MKV、WEBM、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 15 |
| MPG | MP4、MOV、MKV、WEBM、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 15 |
| MTS | MP4、MOV、MKV、WEBM、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 15 |
| NEF | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| ODT | PDF、DOCX、RTF、TXT、HTML、MD | 6 |
| OGA | M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 8 |
| OGG | M4A、MP3、WAV、FLAC、OPUS、AIFF、WMA | 7 |
| OPUS | M4A、MP3、WAV、FLAC、OGG、AIFF、WMA | 7 |
| ORF | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| PDF | DOCX、JPG、PNG、TXT | 4 |
| PEF | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| PNG | JPG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 8 |
| PSD | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| RAF | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| RAR | ZIP、TAR、GZ | 3 |
| RTF | PDF、DOCX、TXT、HTML、ODT、MD | 6 |
| RTFD | PDF、DOCX、RTF、TXT、HTML、ODT、MD | 7 |
| RW2 | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| SRT | VTT、TXT | 2 |
| SRW | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| SVG | 无菜单；SVG 输入明确拒绝已实测 | 0 |
| TAR | ZIP、GZ | 2 |
| TEXT | PDF、DOCX、RTF、HTML、ODT、MD | 6 |
| TGA | JPG、PNG、WEBP、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 9 |
| TGZ | ZIP、TAR、GZ | 3 |
| TIF | JPG、PNG、WEBP、HEIC、AVIF、BMP、PDF、DOCX | 8 |
| TIFF | JPG、PNG、WEBP、HEIC、AVIF、BMP、PDF、DOCX | 8 |
| TS | MP4、MOV、MKV、WEBM、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 15 |
| TXT | PDF、DOCX、RTF、HTML、ODT、MD | 6 |
| VTT | SRT、TXT | 2 |
| WAV | M4A、MP3、FLAC、OGG、OPUS、AIFF、WMA | 7 |
| WAVE | M4A、MP3、FLAC、OGG、OPUS、AIFF、WMA | 7 |
| WEBARCHIVE | PDF、DOCX、RTF、TXT、HTML、ODT、MD | 7 |
| WEBM | MP4、MOV、MKV、AVI、WMV、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 14 |
| WEBP | JPG、PNG、HEIC、TIFF、AVIF、BMP、PDF、DOCX | 8 |
| WMA | M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF | 7 |
| WMV | MP4、MOV、MKV、WEBM、AVI、GIF、M4A、MP3、WAV、FLAC、OGG、OPUS、AIFF、WMA | 14 |
| ZIP | TAR、GZ | 2 |

---

# 历史记录：alpha.4

以下保留当时的结果与局限，不代表 alpha.5 当前未修复项目；部分缺口已由上文补齐。旧段落中的 JSON 链接现指向当前汇总，原始 alpha.4 明细保留在该节列出的本机证据目录。

验收日期：2026-10-05（北京时间）。版本：0.1.0-alpha.4。

本次直接调用构建后的 App 可执行文件进行文件转换；命令行与桌面工作台使用同一转换引擎。源文件先落盘，转换后用独立读取器解码、提取正文或逐页渲染；没有用单元测试方法数代替实际转换次数。

**263 个不同转换方向，283 次实际尝试：277 次产物通过相应内容检查，6 次按预期明确拒绝，0 次非预期失败。** 此处通过限于下面的样例和检查标准；DOCX 样式保真仍有已确认问题，不表示所有版式、编码、文件大小均已验收。

## 分组与计数

| 分组 | 成功方向 | 实际尝试 | 产物内容通过 | 按预期拒绝 |
|---|---:|---:|---:|---:|
| 图片互转、图片转 PDF/Word、GIF 转视频 | 66 | 70 | 66 | 4 |
| 文字与富文本文档 | 43 | 43 | 43 | 0 |
| 音频、视频及音轨提取 | 140 | 140 | 140 | 0 |
| PDF | 4 | 18 | 16 | 2 |
| 字幕 | 4 | 4 | 4 | 0 |
| 压缩包互转 | 6 | 8 | 8 | 0 |
| 合计 | **263** | **283** | **277** | **6** |

相同输入→输出方向只计一次；不同样例、透明/不透明变体、TAR.GZ 变体和私人 PDF 不重复增加方向数。4 次透明 AVIF 拒绝和2次空白 PDF 拒绝不算转换成功。

## 实际检查了什么

- 图片：8 种真实输入，49 条图片互转、8 条转 PDF、8 条转 DOCX、GIF→MP4。独立解码、像素/尺寸、透明度、动画帧/时长、原生文字读取和可见性检查。
- 文档：7 种输入、43 条方向；每份77段中文/英文/数字/首尾标记，核验全文及顺序。7个PDF输出共36页实际渲染通览，6个DOCX通过macOS全文读取和Quick Look原生预览。
- 影音：2秒、320×180标准编码素材；30条视频互转、48条视频提取音频、6条视频转GIF、56条音频互转。全部输出整段解码，核验时长、画面首尾变化及双声道440/660Hz测试音。
- PDF：单页、多页中英文、纯扫描页以及两份用户PDF。图片逐页与独立Poppler渲染对照；DOCX/TXT检查实际文字，扫描内容检查标记或每页有字。
- 字幕：SRT/VTT互转、二者转TXT；检查毫秒时间戳、多行及中文内容。
- 压缩包：ZIP/TAR/GZIP互转，另测TAR.GZ；通过独立ZIP/TAR/GZIP读取器检查中文路径、条目数和逐字节内容。
- 全部组检查原文件未被改动、输出存在且可见；产物和失败基线均保留。

## 实测发现并处理的五类问题

| 问题 | 原版实测 | alpha.4 处理与复验 |
|---|---|---|
| 透明图片→AVIF | 返回成功但透明通道丢失 | 当前FFmpeg回退明确拒绝透明源，推荐PNG/WebP；不透明变体实际转换成功 |
| GIF→MP4 | 0.6秒两帧动图被截成0.4秒 | 为每帧写入明确时长；实测0.600秒、两帧内容正确 |
| WMV→MOV | 输出成功但音轨无法解码 | 容器直拷后试解码，失败则H.264/AAC重编码；样例整段有声有画 |
| TAR/GZIP→ZIP 中文文件名 | 独立ZIP读取器显示乱码 | 明确写入UTF-8编码标记；独立读取文件名和内容完全一致 |
| 空白PDF→TXT | 生成空内容但报告成功 | 无文字页明确失败，不发布空白或缺页的TXT |

## 尚未通过或未覆盖的质量项目

1. **DOCX 排版保真未通过**：DOCX→PDF/Markdown 已确认丢失部分 Word 段落样式定义的标题字号和项目符号。43条文档方向通过指正文及文件可用性，不包括这些样式。
2. 部分PDF提取汉字变为Unicode兼容部首；NFKC规范化后正文一致，原码位并不完全一致。
3. 本机附带的LibreOffice连未转换的基准DOCX也缺中文字，因此该渲染环境不作为中文显示依据；已改用原生Quick Look与全文读取，未宣称Microsoft Word/其他LibreOffice环境验收通过。
4. 当前PDF→TXT/DOCX策略会拒绝任一无文字页，带正常空白页或纯插图页的混合PDF也可能被拒绝；这是保守的兼容性限制。扫描OCR没有逐字校对。
5. 未覆盖复杂表格、页眉页脚、公式、脚注、所有动画/编解码变体、HDR、多音轨/环绕声、长文件、Intel或全部macOS版本。
6. 263条矩阵主要通过App命令行入口；后续已补做下列图形界面验收并恢复TextEdit可视检查，仍不能把矩阵称为263条鼠标操作流程验证。
7. MOV运行时直拷验证仅试解码前0.1秒；本次测试脚本另行对实际样例完整解码，不能据此前置检查承诺任意长视频全程无损。

## 用户文件复验（材料仅留本机）

- 两页PDF：DOCX两页均有正文；与独立PDF文本提取结果去空白后的顺序相似度为0.98489，该比较不是逐字一致性承诺；另生成2张PNG。
- 26页PDF：生成26张PNG，每页可解码且未隐藏，逐页与Poppler渲染比较；另生成含26个非空文字页段的OCR DOCX，OCR准确率未逐字校对。
- 独立渲染比较的最大像素平均绝对误差分别为6.637/255与12.646/255。不同渲染器/抗锯齿会产生差异，不以此宣称像素无损。
- 已把这四项输出复制到本机 `dist/actual-conversion-2026-10-05/` 普通目录，并核验复制前后内容哈希；原桌面文件未改动。源码与可发布汇总不包含私人文档、正文或真实文件名。

## 证据与复跑

此次四组使用的可执行文件SHA-256完全一致：

`63edc2118a9f8c6a169c532bbbdc3ee568992b84f7660c67982f71c9b95c4a47`

- 可发布的逐例摘要：[actual-conversion-results.json](actual-conversion-results.json)。
- 完整本机证据：`.build/actual-conversions-20261005/` 下的 `images/results-verified.json`、`documents/verified/results.json`、`media/alpha4/results.json`、`pdf-archives-verified/results.json`；原始材料、CLI报告和检查产物均保留，不上传。
- 复跑脚本：`scripts/real-conversion-images.py`、`scripts/real-conversion-documents.py`、`scripts/real-conversion-documents-render.py`、`scripts/real-conversion-media.py`、`scripts/real-conversion-pdf-archives.py`。各自 `--help` 列出参数；需要本机macOS框架、FFmpeg/ffprobe、Python图像/文档库及Poppler。
- 对本机Vision/AVFoundation等服务的沙箱失败，在获准的正常本机环境复跑后再判断；诊断批次未混入最终统计。
- 另执行102个回归测试方法，102通过、0失败、0跳过；使用明确标注的独立断言适配器，非原生XCTest。这102项不计入上面的283次实转。
- alpha.4构建与本机签名验证通过；包仍未经过Apple公证。

## 追加：alpha.4 图形界面实际验收

2026-10-05 在正常桌面环境完成以下操作。它们补充前面的实转矩阵，不重复增加转换方向数。

- 发现 alpha.1、alpha.3、alpha.4 三个进程同时运行。通过活动监视器的普通“退出”操作分别退出两个旧版，进程路径核查确认只剩 alpha.4；没有结束其他应用。
- 从 alpha.4 工作台添加用户两页 PDF，使用默认可编辑模式转 DOCX；界面显示成功1、失败0，点击“打开文件”后在 TextEdit 实际查看首尾正文。去除空白后1,721个字符与已验证的同版本输出一致。特殊字体项目符号仍显示异常，段落/标题排版有重排，不视为排版保真通过。
- 从工作台把26页PDF转PNG，界面显示成功1、失败0及26张图片；点击“打开结果文件夹”后Finder列出Page 01.png到Page 26.png，Quick Look实际打开首末页。全部26张图片独立解码通过，且SHA-256逐页与先前验收产物完全一致，目录与图片未隐藏。
- 使用已知内容PDF加空白PDF进行混合批次，界面正确显示成功1、失败1并明确指出空白页；成功结果保留，空白DOCX没有发布。
- 同一批次再次执行，生成带编号的新DOCX；已有文件SHA-256保持不变，未覆盖。
- 正常退出alpha.4并重新打开：工作台仍显示alpha.4，最近结果记录恢复，能找到此次用户DOCX及26张图片的文件夹，打开/定位按钮可用。最终保留新版运行。

此次UI共执行6次文件处理：4次产物成功、2次空白PDF按预期拒绝。两个桌面原PDF校验值均未改变。完整本机记录为 `.build/actual-conversions-20261005/ui-verified.json`；私有内容与路径不进入可发布汇总。

## 成功转换方向全表

| 输入 | 实际成功的输出 | 方向数 |
|---|---|---:|
| AIFF | FLAC、M4A、MP3、OGG、OPUS、WAV、WMA | 7 |
| AVI | AIFF、FLAC、GIF、M4A、MKV、MOV、MP3、MP4、OGG、OPUS、WAV、WEBM、WMA、WMV | 14 |
| AVIF | BMP、DOCX、HEIC、JPG、PDF、PNG、TIFF、WEBP | 8 |
| BMP | AVIF、DOCX、HEIC、JPG、PDF、PNG、TIFF、WEBP | 8 |
| DOC | DOCX、HTML、MD、ODT、PDF、RTF、TXT | 7 |
| DOCX | HTML、MD、ODT、PDF、RTF、TXT | 6 |
| FLAC | AIFF、M4A、MP3、OGG、OPUS、WAV、WMA | 7 |
| GIF | AVIF、BMP、DOCX、HEIC、JPG、MP4、PDF、PNG、TIFF、WEBP | 10 |
| GZ | TAR、ZIP | 2 |
| HEIC | AVIF、BMP、DOCX、JPG、PDF、PNG、TIFF、WEBP | 8 |
| HTML | DOCX、MD、ODT、PDF、RTF、TXT | 6 |
| JPG | AVIF、BMP、DOCX、HEIC、PDF、PNG、TIFF、WEBP | 8 |
| M4A | AIFF、FLAC、MP3、OGG、OPUS、WAV、WMA | 7 |
| MD | DOCX、HTML、ODT、PDF、RTF、TXT | 6 |
| MKV | AIFF、AVI、FLAC、GIF、M4A、MOV、MP3、MP4、OGG、OPUS、WAV、WEBM、WMA、WMV | 14 |
| MOV | AIFF、AVI、FLAC、GIF、M4A、MKV、MP3、MP4、OGG、OPUS、WAV、WEBM、WMA、WMV | 14 |
| MP3 | AIFF、FLAC、M4A、OGG、OPUS、WAV、WMA | 7 |
| MP4 | AIFF、AVI、FLAC、GIF、M4A、MKV、MOV、MP3、OGG、OPUS、WAV、WEBM、WMA、WMV | 14 |
| ODT | DOCX、HTML、MD、PDF、RTF、TXT | 6 |
| OGG | AIFF、FLAC、M4A、MP3、OPUS、WAV、WMA | 7 |
| OPUS | AIFF、FLAC、M4A、MP3、OGG、WAV、WMA | 7 |
| PDF | DOCX、JPG、PNG、TXT | 4 |
| PNG | AVIF、BMP、DOCX、HEIC、JPG、PDF、TIFF、WEBP | 8 |
| RTF | DOCX、HTML、MD、ODT、PDF、TXT | 6 |
| SRT | TXT、VTT | 2 |
| TAR | GZ、ZIP | 2 |
| TIFF | AVIF、BMP、DOCX、HEIC、JPG、PDF、PNG、WEBP | 8 |
| TXT | DOCX、HTML、MD、ODT、PDF、RTF | 6 |
| VTT | SRT、TXT | 2 |
| WAV | AIFF、FLAC、M4A、MP3、OGG、OPUS、WMA | 7 |
| WEBM | AIFF、AVI、FLAC、GIF、M4A、MKV、MOV、MP3、MP4、OGG、OPUS、WAV、WMA、WMV | 14 |
| WEBP | AVIF、BMP、DOCX、HEIC、JPG、PDF、PNG、TIFF | 8 |
| WMA | AIFF、FLAC、M4A、MP3、OGG、OPUS、WAV | 7 |
| WMV | AIFF、AVI、FLAC、GIF、M4A、MKV、MOV、MP3、MP4、OGG、OPUS、WAV、WEBM、WMA | 14 |
| ZIP | GZ、TAR | 2 |
