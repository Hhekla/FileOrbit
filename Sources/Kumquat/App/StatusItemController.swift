import AppKit
import KumquatCore

/// The menu bar item: hints, recent results, settings and quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        item.button?.image = StatusIcon.make()
        item.button?.toolTip = "FileOrbit"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: L("Hold ⇧ while dragging a file to convert it"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let tools = NSMenuItem(title: L("Hold ⌥⇧ for tools"), action: nil, keyEquivalent: "")
        tools.isEnabled = false
        menu.addItem(tools)
        menu.addItem(.separator())

        if !AppActions.recentOutputs.isEmpty {
            add("查看最近结果与保存位置…", #selector(showWorkbench), key: "")
            let title = NSMenuItem(title: "最近保存 · 点击在 Finder 中显示", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for url in AppActions.recentOutputs.prefix(6) {
                let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = url
                entry.toolTip = url.path
                entry.image = NSWorkspace.shared.icon(forFile: url.path)
                entry.image?.size = NSSize(width: 16, height: 16)
                entry.isEnabled = FileManager.default.fileExists(atPath: url.path)
                menu.addItem(entry)
            }
            menu.addItem(.separator())
        }

        add("文件工作台…", #selector(showWorkbench), key: "o")
        add(L("Welcome Guide…"), #selector(showWelcome), key: "")
        add(L("Settings…"), #selector(showSettings), key: ",")
        menu.addItem(.separator())
        add(L("Quit FileOrbit"), #selector(quit), key: "q")
    }

    private func add(_ title: String, _ action: Selector, key: String) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func showWorkbench() { WorkbenchWindow.show() }
    @objc private func showWelcome() { WelcomeWindow.show() }
    @objc private func showSettings() { SettingsWindow.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// FileOrbit menu bar glyph, following the system appearance.
enum StatusIcon {
    static func make() -> NSImage {
        let image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "FileOrbit") ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }
}
