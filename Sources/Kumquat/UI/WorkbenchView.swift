import AppKit
import SwiftUI
import KumquatCore
import UniformTypeIdentifiers

@MainActor
final class WorkbenchModel: ObservableObject {
    @Published var files: [URL] = []
    @Published var selection: WheelAction?
    @Published var parameters = ToolParameters()
    @Published var pdfMode: PDFDocxMode = .editableText
    @Published var running = false
    @Published var completed = 0
    @Published var total = 0
    @Published var result: ConversionEngine.Report?
    private var task: Task<Void, Never>?
    private var worker: Task<ConversionEngine.Report, Never>?
    var actions: [WheelAction] {
        let catalog = ActionCatalog(capabilities: AppSettings.shared.capabilities)
        return catalog.formatActions(for: files) + catalog.toolActions(for: files)
    }
    func setFiles(_ urls: [URL], action: WheelAction? = nil) {
        guard !running else { return }
        files = urls; result = nil
        selection = action ?? actions.first
    }
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.prompt = "添加文件"
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }
    func addFiles(_ urls: [URL]) {
        setFiles(files + urls.filter { !files.contains($0) })
    }
    func move(_ index: Int, by delta: Int) {
        guard !running, files.indices.contains(index + delta) else { return }
        files.swapAt(index, index + delta)
    }
    func cancel() { worker?.cancel() }
    func run() {
        guard !running, !files.isEmpty, let action = selection else { return }
        let kind = FileClassifier.kind(of: files[0])
        if case .tool(let tool) = action,
           !ActionCatalog.needsParameters(tool),
           ActionCatalog.isInteractive(tool, kind: kind, fileCount: files.count),
           !((kind == .video || kind == .audio) && [.crop, .split].contains(tool)) {
            ToolLauncher.open(tool, for: files[0]); return
        }
        var options = AppSettings.shared.conversionOptions
        options.pdfDocxMode = pdfMode
        var engine = ConversionEngine(capabilities: AppSettings.shared.capabilities, options: options)
        engine.parameters = parameters
        let inputs = files
        result = nil; completed = 0; total = inputs.count; running = true
        let worker = Task.detached(priority: .userInitiated) { [engine] in
                await engine.run(action, on: inputs) { done, count in
                    Task { @MainActor in self.completed = done; self.total = count }
                }
        }
        self.worker = worker
        task = Task {
            let report = await worker.value
            self.result = report; self.running = false
            if !report.outputs.isEmpty { AppActions.finished(outputs: report.outputs) }
        }
    }
}

struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel
    @State private var dragOver = false
    private var tool: ToolKind? {
        if case .tool(let t) = model.selection { return t }; return nil
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 270)
            Divider()
            ScrollViewReader { scroll in
              ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("让文件，回到手边。").font(.system(size: 27, weight: .semibold))
                            Text("本机处理 · 保留原文件 · 每项都有结果").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")").font(.caption).padding(8).background(.white.opacity(0.7), in: Capsule())
                    }.id("workbench-top")
                    if let result = model.result { ConversionResultView(report: result) }
                    else { RecentOutputsView() }
                    if model.files.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("拖动文件时按 ⇧，打开格式轮盘", systemImage: "cursorarrow.rays")
                            Label("按 ⌥ ⇧，打开当前文件可用工具", systemImage: "slider.horizontal.3")
                            Label("也可以在左侧选择文件，在这里调整参数", systemImage: "folder")
                        }.font(.system(size: 15)).padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("选择操作").font(.headline)
                            Picker("操作", selection: $model.selection) {
                                ForEach(model.actions, id: \.self) { action in
                                    Text(label(action)).tag(Optional(action))
                                }
                            }.labelsHidden().disabled(model.running)
                            if model.actions.isEmpty {
                                Text("这组文件没有共同的可用操作。请分开选择文件，或检查所需转换引擎。").foregroundStyle(.orange)
                            }
                            parameters
                        }
                        HStack {
                            Button(action: model.run) { Label(interactive ? "打开编辑器" : "开始处理", systemImage: "arrow.right") }
                                .buttonStyle(.borderedProminent).tint(Color(red: 0.08, green: 0.40, blue: 0.34))
                                .disabled(model.running || model.selection == nil || model.actions.isEmpty)
                                .keyboardShortcut(.return, modifiers: .command)
                            if model.running {
                                ProgressView(value: Double(model.completed), total: Double(max(1, model.total))).frame(width: 140)
                                Text("\(model.completed) / \(model.total)").font(.caption).monospacedDigit()
                                Button("取消") { model.cancel() }
                            }
                        }
                    }
                    if model.result != nil {
                        DisclosureGroup("查看最近保存的其他结果") { RecentOutputsView().padding(.top, 10) }
                    }
                    Spacer(minLength: 0)
                    Text("高级影音功能使用本机 FFmpeg。转换器不会上传文件；网络磁盘由其原有同步服务管理。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(30)
              }
              .onChange(of: model.running) { _, running in
                  if !running { withAnimation { scroll.scrollTo("workbench-top", anchor: .top) } }
              }
            }.background(Color(red: 0.96, green: 0.96, blue: 0.93))
        }.frame(minWidth: 880, minHeight: 640)
    }
    private var interactive: Bool {
        guard let tool, let first = model.files.first else { return false }
        let kind = FileClassifier.kind(of: first)
        return !ActionCatalog.needsParameters(tool) && ActionCatalog.isInteractive(tool, kind: kind, fileCount: model.files.count)
            && !((kind == .video || kind == .audio) && [.crop, .split].contains(tool))
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.teal); Text("FileOrbit").font(.system(size: 24, weight: .bold, design: .rounded)) }
            Text("文件工作台").font(.caption).foregroundStyle(.secondary)
            Button(action: model.chooseFiles) { Label("添加文件…", systemImage: "plus").frame(maxWidth: .infinity) }.disabled(model.running)
            VStack {
                if model.files.isEmpty {
                    Image(systemName: "doc.on.doc").font(.system(size: 35)).foregroundStyle(.tertiary)
                    Text("把文件拖到这里").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(model.files.enumerated()), id: \.offset) { index, url in
                                HStack(alignment: .top) {
                                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                        Text(ByteCountFormatter.string(fromByteCount: FileClassifier.fileSize(of: url), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    VStack(spacing: 5) {
                                        Button { model.move(index, by: -1) } label: { Image(systemName: "chevron.up") }.help("上移").disabled(index == 0 || model.running)
                                        Button { model.move(index, by: 1) } label: { Image(systemName: "chevron.down") }.help("下移").disabled(index == model.files.count - 1 || model.running)
                                    }.buttonStyle(.plain).font(.caption2)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16).background(dragOver ? Color.teal.opacity(0.12) : Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dragOver) { providers in
                    guard !model.running else { return false }
                    Task { @MainActor in
                        var urls: [URL] = []
                        for provider in providers {
                            let data: Data? = await withCheckedContinuation { continuation in
                                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in continuation.resume(returning: data) }
                            }
                            if let data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                        }
                        if !urls.isEmpty { model.addFiles(urls) }
                    }
                    return true
                }
            HStack {
                Text("\(model.files.count) 个文件").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空列表") { model.setFiles([]) }.disabled(model.running).font(.caption)
            }
            Divider()
            Label(AppSettings.shared.capabilities.hasFFmpeg ? "影音引擎已就绪" : "未发现 FFmpeg", systemImage: AppSettings.shared.capabilities.hasFFmpeg ? "checkmark.circle" : "info.circle").font(.caption).foregroundStyle(.secondary)
            Button("设置") { SettingsWindow.show() }.buttonStyle(.plain).font(.caption)
        }.padding(22).background(.white)
    }
    @ViewBuilder private var parameters: some View {
        if model.selection == .convert(.docx), model.files.contains(where: { FileClassifier.kind(of: $0) == .pdf }) {
            Picker("PDF 转 Word", selection: $model.pdfMode) {
                Text("可编辑文字（默认，版式会重排）").tag(PDFDocxMode.editableText)
                Text("页面图片（文本编辑不支持）").tag(PDFDocxMode.preserveAppearance)
            }
            Text(model.pdfMode == .preserveAppearance ? "每页嵌入图片，正文不可编辑。macOS 文本编辑不显示这些图片，会呈现空白；需要支持 DOCX 图片的阅读器。本版本尚未完成 Word/Pages 显示验收。" : "生成可编辑正文，macOS 文本编辑可读取文字；复杂布局会重排，图表不保留。扫描页会尝试 OCR；未识别到文字会报告失败。").font(.caption).foregroundStyle(.secondary)
        }
        if let tool {
            VStack(alignment: .leading, spacing: 10) {
                if [.resize, .collage, .crop].contains(tool) {
                    HStack { integer("宽度 / px", $model.parameters.width); integer("高度 / px", $model.parameters.height) }
                    if tool == .resize { Text("保持比例，缩放到宽高范围内。").font(.caption).foregroundStyle(.secondary) }
                    if tool == .crop { HStack { integer("左侧偏移 / px", $model.parameters.x); integer("顶部偏移 / px", $model.parameters.y) } }
                }
                if tool == .collage { HStack { integer("列数", $model.parameters.columns); integer("间距 / px", $model.parameters.padding) } }
                if tool == .speed { decimal("速度倍数", $model.parameters.speed) }
                if tool == .targetSize { decimal("目标上限 / MB", $model.parameters.targetMegabytes); Text("达到上限才保存；无法达到会报告失败。图片保留像素尺寸。").font(.caption).foregroundStyle(.secondary) }
                if tool == .channels { Picker("声道", selection: $model.parameters.channels) { Text("单声道").tag(1); Text("双声道").tag(2) } }
                if tool == .bleep { HStack { decimal("起点 / 秒", $model.parameters.start); decimal("终点 / 秒", $model.parameters.end) } }
                if tool == .split, model.files.first.map({ FileClassifier.kind(of: $0) != .pdf }) == true { decimal("每段时长 / 秒", $model.parameters.end) }
                if tool == .reorderPages { TextField("页码，例如 3,1-2,5", text: $model.parameters.pages); Text("按输入顺序导出新 PDF；未指定的页不进入新文件，原文件保留。").font(.caption).foregroundStyle(.secondary) }
                if tool == .join || tool == .collage { Text("按左侧文件顺序组合；点击箭头调整顺序。").font(.caption).foregroundStyle(.secondary) }
                if [.join, .speed, .normalize, .bleep, .channels, .targetSize, .crop, .split].contains(tool), model.files.first.map({ [.audio, .video].contains(FileClassifier.kind(of: $0)) }) == true { Text("高级影音操作只处理第一路视频/音轨；字幕、附加音轨和封面不随输出保留。").font(.caption).foregroundStyle(.secondary) }
                if tool == .normalize { Text("将响度标准化为适合日常收听的水平，生成新文件。").font(.caption).foregroundStyle(.secondary) }
                if tool == .extract { Text("逐条检查归档路径与大小；拒绝符号链接和越界路径。").font(.caption).foregroundStyle(.secondary) }
            }.disabled(model.running)
        }
    }
    private func integer(_ title: String, _ value: Binding<Int>) -> some View { VStack(alignment: .leading) { Text(title).font(.caption); TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder) } }
    private func decimal(_ title: String, _ value: Binding<Double>) -> some View { VStack(alignment: .leading) { Text(title).font(.caption); TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder) } }
    private func label(_ action: WheelAction) -> String {
        switch action { case .convert(let f): return "转换为 \(f.title)"; case .tool: return L10n.title(for: action) }
    }
}

struct ConversionResultView: View {
    let report: ConversionEngine.Report
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(report.outputs.isEmpty ? "处理结果" : "处理结果 · 文件已保存", systemImage: report.outputs.isEmpty ? "info.circle" : "checkmark.circle.fill").font(.headline)
            Text("成功 \(report.succeededInputs) 项 · 失败 \(report.failures.count) 项 · 取消 \(report.cancelled.count) 项")
                .foregroundStyle(report.failures.isEmpty && report.cancelled.isEmpty ? Color.teal : Color.orange)
            ForEach(report.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            SavedOutputsList(urls: report.outputs)
            ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in Text("\(failure.url.lastPathComponent)：\(failure.message)").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            ForEach(report.cancelled, id: \.path) { url in Text("已取消：\(url.lastPathComponent)").font(.caption).foregroundStyle(.secondary) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
enum WorkbenchWindow {
    static let model = WorkbenchModel()
    private static var window: NSWindow?
    private static var resultWindow: NSWindow?
    static func showResult(_ report: ConversionEngine.Report) {
        if resultWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "FileOrbit · 处理结果"; w.isReleasedWhenClosed = false; w.center(); resultWindow = w
        }
        resultWindow?.contentView = NSHostingView(rootView: ScrollView { ConversionResultView(report: report).padding(24) }.frame(minWidth: 500, minHeight: 320))
        NSApp.activate(ignoringOtherApps: true); resultWindow?.makeKeyAndOrderFront(nil)
    }
    static func show(files: [URL]? = nil, action: WheelAction? = nil) {
        if let files {
            if model.running {
                let alert = NSAlert(); alert.messageText = "工作台正在处理另一组文件"
                alert.informativeText = "请等待当前任务完成，或取消后再选择这组文件。此次拖入的文件尚未处理。"
                alert.addButton(withTitle: "知道了"); alert.runModal()
                return
            }
            model.setFiles(files, action: action)
        }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "FileOrbit · 文件工作台"; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WorkbenchView(model: model))
            w.center(); window = w
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
}
