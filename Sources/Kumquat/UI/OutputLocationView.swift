import AppKit
import SwiftUI

/// A saved path is always visible, with explicit actions for files and multi-page folders.
struct OutputLocationView: View {
    let url: URL
    @ObservedObject private var history = OutputHistory.shared
    @State private var openFailed = false

    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    private var isDirectory: Bool {
        history.entry(for: url)?.isDirectory == true ||
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    private var detail: String {
        guard exists else { return "文件已移动或删除，原保存位置如下" }
        guard isDirectory else { return "已保存文件" }
        if let entry = history.entry(for: url), let images = entry.imageCount, images > 0 {
            return "文件夹 · 保存时含\(entry.countIsLimited ? "至少 " : "")\(images) 张图片"
        }
        if let count = history.entry(for: url)?.fileCount {
            return "文件夹 · 保存时顶层含 \(count) 个文件"
        }
        return "已保存文件夹 · 打开查看全部结果"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isDirectory ? "folder.fill" : "doc.badge.checkmark")
                    .foregroundStyle(exists ? Color.teal : Color.secondary).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(url.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(url.path)
            HStack(spacing: 9) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: { Label("在 Finder 中显示", systemImage: "magnifyingglass") }
                    .buttonStyle(.borderedProminent).tint(Color(red: 0.08, green: 0.40, blue: 0.34))
                Button(isDirectory ? "打开结果文件夹" : "打开文件") {
                    openFailed = !NSWorkspace.shared.open(url)
                }.buttonStyle(.bordered)
                Button("复制路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }.buttonStyle(.borderless)
            }.controlSize(.small).disabled(!exists)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teal.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .alert("无法打开结果", isPresented: $openFailed) {
            Button("知道了", role: .cancel) { }
        } message: { Text("请在 Finder 中确认文件仍在，并选择支持该格式的应用打开。\n\(url.path)") }
    }
}

struct SavedOutputsList: View {
    let urls: [URL]
    var visibleCount = 3
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(urls.prefix(visibleCount)), id: \.path) { OutputLocationView(url: $0) }
            if urls.count > visibleCount {
                DisclosureGroup("其余 \(urls.count - visibleCount) 个结果", isExpanded: $expanded) {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(Array(urls.dropFirst(visibleCount)), id: \.path) { OutputLocationView(url: $0) }
                        }.padding(.top, 8)
                    }.frame(maxHeight: 320)
                }
            }
        }
    }
}

struct RecentOutputsView: View {
    @ObservedObject private var history = OutputHistory.shared
    var body: some View {
        if !history.entries.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Label("最近保存的结果", systemImage: "clock.arrow.circlepath").font(.headline)
                Text("最近 12 个结果保留在这里，重新打开软件后仍可找回。").font(.caption).foregroundStyle(.secondary)
                SavedOutputsList(urls: history.entries.map(\.url), visibleCount: 1)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
