import SwiftUI
import AppKit
import WindCore

@main struct MyTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("MyTerm", id: "workspace") {
            WorkspaceView(model: model)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { delegate.model = model; NSApp.activate(ignoringOtherApps: true); delegate.runSmokeTestIfRequested() }
        }
        .defaultSize(width: 1320, height: 840)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 SSH 连接…") { model.editing = Session() }.keyboardShortcut("n")
                Button("本地终端") { model.localShell() }.keyboardShortcut("t")
                Button("导入 WindTerm 配置…") { model.chooseImport() }.keyboardShortcut("o")
                Divider()
                Button("关闭标签") { if let tab = model.currentTab { model.close(tab) } }.keyboardShortcut("w")
            }
            CommandGroup(after: .textEditing) {
                Button("查找终端内容…") {
                    let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    model.currentTab?.terminal.performTextFinderAction(item)
                }.keyboardShortcut("f")
            }
            CommandMenu("会话") {
                Button("连接所选会话") { if let session = model.selected { model.connect(session) } }.keyboardShortcut(.return)
                Button("重新连接") { model.reconnect() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("SFTP 文件管理器") { if let session = model.selected ?? model.currentTab?.session { model.openFiles(session) } }
                Button("SFTP 命令终端") { if let session = model.selected { model.connect(session, sftp: true) } }
                Button("复制当前会话标签") { if let tab = model.currentTab { model.duplicateTab(tab) } }.disabled(model.currentTab == nil)
                Button("重新打开关闭的标签") { model.reopenLastClosed() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("断开当前会话") { model.disconnectCurrent() }.disabled(model.currentTab?.running != true)
                Button("保存终端输出…") { model.exportOutput() }.disabled(model.currentTab == nil)
                Divider()
                Button("认证管理…") { openWindow(id: "credentials") }.keyboardShortcut(",")
                Button("刷新配置") { model.refresh() }
                Button("显示 / 隐藏连接详情") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandMenu("查看") {
                Button("左右分屏") { model.splitTerminal(.columns) }.keyboardShortcut("d").disabled(model.currentTab == nil)
                Button("上下分屏") { model.splitTerminal(.rows) }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(model.currentTab == nil)
                Button("仅显示当前窗格") { model.unsplit() }.disabled(model.currentTab == nil)
                Divider()
                Toggle("会话侧栏", isOn: $model.showSidebar).onChange(of: model.showSidebar) { _ in model.saveWorkspace() }
                Toggle("连接详情", isOn: $model.showInspector)
                Button("命令发送器") { model.toggleBottom(.sender) }
                Button("活动会话") { model.toggleBottom(.sessions) }
                Button("传输任务") { model.toggleBottom(.transfers) }
                Divider()
                Button("放大字体") { model.setFontSize(model.fontSize + 1) }.keyboardShortcut("+")
                Button("缩小字体") { model.setFontSize(model.fontSize - 1) }.keyboardShortcut("-")
                Button("恢复默认字体") { model.setFontSize(13) }.keyboardShortcut("0")
            }
            CommandMenu("转到") {
                Button("下一个窗格") { model.nextPane() }.keyboardShortcut("]", modifiers: [.command, .option])
                Button("下一个标签") {
                    guard !model.tabs.isEmpty else { return }
                    let index = model.tabs.firstIndex { $0.id == model.activeTab } ?? 0
                    model.activeTab = model.tabs[(index + 1) % model.tabs.count].id
                }.keyboardShortcut(.tab, modifiers: [.control])
                Button("上一个标签") {
                    guard !model.tabs.isEmpty else { return }
                    let index = model.tabs.firstIndex { $0.id == model.activeTab } ?? 0
                    model.activeTab = model.tabs[(index + model.tabs.count - 1) % model.tabs.count].id
                }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
            CommandMenu("选择") {
                Button("选择全部终端文本") { model.currentTab?.terminal.selectAll(nil) }.disabled(model.currentTab == nil)
            }
            CommandMenu("工具") {
                Button("清屏") { model.currentTab?.terminal.feed(text: "\u{1b}[2J\u{1b}[H") }.disabled(model.currentTab == nil)
                Button("重命名当前标签…") { if let tab = model.currentTab { model.renameTab(tab) } }.disabled(model.currentTab == nil)
                Divider()
                Button("认证管理…") { openWindow(id: "credentials") }
                Button("显示配置目录") { NSWorkspace.shared.open(model.support) }
            }
        }
        Window("认证管理", id: "credentials") {
            CredentialManagerView(model: model)
        }
        .defaultSize(width: 850, height: 610)
        .windowToolbarStyle(.unifiedCompact)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var smokeStarted = false
    @MainActor func runSmokeTestIfRequested() {
        let args = CommandLine.arguments
        guard !smokeStarted, let index = args.firstIndex(of: "--smoke-report"), args.indices.contains(index + 1), let model else { return }
        smokeStarted = true
        let output = URL(fileURLWithPath: args[index + 1])
        let fixture = Session(name: "本地启动验证", group: "验证", kind: "Shell", host: "/bin/zsh", shellArguments: ["-c", "printf '\\033[32mWINDNATIVE_SMOKE 中文\\033[0m\\n'; sleep 1; exit 7"])
        model.connect(fixture)
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                if model.currentTab?.exitCode != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let migrationDeadline = Date().addingTimeInterval(15)
            while model.isMigratingAuthentication && Date() < migrationDeadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            let tab = model.currentTab
            let workspaceWindow = tab?.terminal.window
            let text = tab.map { String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "") } ?? ""
            let attached = tab?.terminal.window != nil
            let unicode = text.contains("WINDNATIVE_SMOKE 中文")
            // A second tab must mount its own terminal, not reuse the first tab's NSView.
            model.connect(Session(name: "第二标签验证", group: "验证", kind: "Shell", host: "/bin/zsh", shellArguments: ["-f", "-c", "printf 'SECOND_TAB_UNIQUE\\n'; exit 0"]))
            let secondTab = model.currentTab
            let tabDeadline = Date().addingTimeInterval(5)
            while secondTab?.exitCode == nil && Date() < tabDeadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            let secondText = secondTab.map { String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self) } ?? ""
            var tabSwitchCheck = secondTab?.id != tab?.id && secondTab?.terminal.window != nil && tab?.terminal.window == nil && secondText.contains("SECOND_TAB_UNIQUE")
            for _ in 0..<3 {
                model.activeTab = tab?.id; model.activeTabChanged()
                try? await Task.sleep(nanoseconds: 100_000_000)
                tabSwitchCheck = tabSwitchCheck && tab?.terminal.window != nil && secondTab?.terminal.window == nil
                model.activeTab = secondTab?.id; model.activeTabChanged()
                try? await Task.sleep(nanoseconds: 100_000_000)
                tabSwitchCheck = tabSwitchCheck && secondTab?.terminal.window != nil && tab?.terminal.window == nil
            }
            if let secondTab { secondTab.stop(); model.close(secondTab) }
            model.activeTab = tab?.id; model.activeTabChanged()
            try? await Task.sleep(nanoseconds: 100_000_000)
            var folderOperations = true
            if let session = model.sessions.first(where: { $0.id == "fixture-target" }) {
                model.updateFolder(FolderEdit(parent: "dev"), name: "staging")
                model.move(session, to: "dev/staging")
                model.updateFolder(FolderEdit(original: "dev/staging", parent: "dev"), name: "application")
                folderOperations = model.sessions.first(where: { $0.id == session.id })?.group == "dev/application"
                if let moved = model.sessions.first(where: { $0.id == session.id }) { model.move(moved, to: "dev") }
                model.removeEmptyFolder("dev/application")
                folderOperations = folderOperations && !model.folderPaths.contains("dev/application") && model.error == nil
            }
            model.expandedFolders.insert("dev")
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.writePreview(output.deletingPathExtension().appendingPathExtension("sessions.png"))
            let folderCheck = !model.folderTree.isEmpty && folderOperations
            var browserCheck = true
            let browserExpected = ProcessInfo.processInfo.environment["WINDNATIVE_SMOKE_SFTP_CONFIG"] != nil
            if browserExpected, let session = model.sessions.first(where: { $0.id == "fixture-target" }) {
                model.openFiles(session)
                let deadline = Date().addingTimeInterval(15)
                while model.currentBrowser?.busy == true && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
                browserCheck = model.currentBrowser?.connected == true && model.currentBrowser?.entries.contains(where: { $0.name == "backup" && $0.isDirectory }) == true
                if let browser = model.currentBrowser, browserCheck {
                    let originalPath = browser.path
                    browser.navigate(originalPath + "/backup")
                    let navigationDeadline = Date().addingTimeInterval(5)
                    while browser.busy && Date() < navigationDeadline { try? await Task.sleep(nanoseconds: 50_000_000) }
                    browserCheck = browserCheck && browser.canGoBack && browser.path.hasSuffix("/backup")
                    browser.goBack()
                    while browser.busy && Date() < navigationDeadline { try? await Task.sleep(nanoseconds: 50_000_000) }
                    browserCheck = browserCheck && browser.path == originalPath && browser.canGoForward
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.writePreview(output.deletingPathExtension().appendingPathExtension("files.png"))
            }
            var credentialsCheck = !model.isMigratingAuthentication && model.credentialIssue == nil
            if let target = model.sessions.first(where: { $0.id == "fixture-target" }) {
                let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                settingsWindow.title = "跳板机设置验证"; settingsWindow.isReleasedWhenClosed = false
                let content = NSHostingView(rootView: SessionEditor(model: model, original: target).preferredColorScheme(.dark))
                settingsWindow.contentView = content; settingsWindow.makeKeyAndOrderFront(nil)
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.writePreview(output.deletingPathExtension().appendingPathExtension("jump-settings.png"), view: content)
                settingsWindow.close()
            }
            if let id = model.createCredential() {
                do {
                    var profile = model.authenticationProfiles.first { $0.id == id }!
                    profile.name = "共享服务器认证"; profile.username = "fixture"
                    if let key = model.authenticationProfiles.first(where: { $0.method.usesKey })?.identityFile {
                        profile.method = .keyAndPassword; profile.identityFile = key
                    } else { profile.method = .password }
                    try model.saveCredential(profile, password: "synthetic-ui-password", passphrase: "")
                    model.selectedCredentialID = id
                    let credentialWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    credentialWindow.title = "认证管理"; credentialWindow.isReleasedWhenClosed = false
                    let content = NSHostingView(rootView: CredentialManagerView(model: model))
                    credentialWindow.contentView = content; credentialWindow.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.writePreview(output.deletingPathExtension().appendingPathExtension("credentials.png"), view: content)
                    credentialWindow.close()
                    let owned = try model.credentialStore.credential(id)
                    credentialsCheck = credentialsCheck && owned.1.password == "synthetic-ui-password"
                } catch { credentialsCheck = false }
            } else { credentialsCheck = false }
            // Exercise actual independent PTYs: nested split, focused command input,
            // hidden terminal preservation and divider collapse when closing a pane.
            model.showBottomPanel = true; model.bottomPanel = .sender
            model.connect(Session(name: "分屏验证", group: "验证", kind: "Shell", host: "/bin/zsh", shellArguments: ["-f", "-c", "printf 'PANE_READY\\n'; while IFS= read -r line; do eval \"$line\"; done"]))
            let left = model.currentTab
            model.splitTerminal(.columns)
            let right = model.currentTab
            let startupDeadline = Date().addingTimeInterval(5)
            while Date() < startupDeadline {
                let ready = [left, right].allSatisfy { item in
                    item?.running == true && item.map { String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("PANE_READY") } == true
                }
                if ready { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            model.senderText = "printf 'PANE_%s_%s\\n' RIGHT 中文"
            model.sendCommand()
            let senderDeadline = Date().addingTimeInterval(4)
            while Date() < senderDeadline {
                let text = right.map { String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "") } ?? ""
                if text.contains("PANE_RIGHT_中文") { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let rightOutput = right.map { String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "") } ?? ""
            let leftOutput = left.map { String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "") } ?? ""
            var splitCheck = model.paneLayout?.terminals.count == 2 && left?.terminal.window != nil && right?.terminal.window != nil
            let senderCheck = rightOutput.contains("PANE_RIGHT_中文") && !leftOutput.contains("PANE_RIGHT_中文") && model.commands.isEmpty
            model.saveCommand()
            let commandSaved = (try? JSONDecoder().decode(SavedState.self, from: Data(contentsOf: model.support.appendingPathComponent("sessions.json"))))?.commands?.count == 1
            model.splitTerminal(.rows)
            let lower = model.currentTab
            let thirdDeadline = Date().addingTimeInterval(5)
            while lower?.running != true && Date() < thirdDeadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 200_000_000)
            splitCheck = splitCheck && model.paneLayout?.terminals.count == 3 && lower?.terminal.window != nil
            model.setFontSize(14)
            self.writePreview(output.deletingPathExtension().appendingPathExtension("workspace.png"), view: workspaceWindow?.contentView)
            if let lower { lower.stop(); model.close(lower) }
            splitCheck = splitCheck && model.paneLayout?.terminals.count == 2
            model.nextPane()
            model.unsplit()
            splitCheck = splitCheck && model.paneLayout?.terminals.count == 1 && model.tabs.count == 3
            for item in [left, right].compactMap({ $0 }) { item.stop(); model.close(item) }
            model.activeTab = tab?.id; model.reconcilePanes()
            let reconnectCheck = await self.checkDisconnectedReturn(configDirectory: model.configDirectory)
            // Real SwiftUI layout with more tabs than fit in the window; these
            // isolated fixture tabs never start a shell or touch saved sessions.
            for index in 1...14 {
                let fixture = Session(name: "标签验证 \(index)", kind: "Shell", host: "/bin/zsh")
                model.tabs.append(TerminalTab(session: fixture, sftp: false, configDirectory: model.configDirectory))
            }
            model.activeTab = model.tabs.last?.id
            model.reconcilePanes()
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.writePreview(output.deletingPathExtension().appendingPathExtension("many-tabs.png"), view: workspaceWindow?.contentView)
            let selectionFixtures = (1...3).map { Session(id: "selection-\($0)", name: "Selection \($0)", group: "Selection Test", host: "test\($0).invalid") }
            for session in selectionFixtures { model.save(session) }
            model.setFolderExpanded("Selection Test", expanded: true)
            model.selectSession("selection-1", modifiers: [])
            model.selectSession("selection-3", modifiers: [.shift])
            let rangeSelected = model.selectedSessions == Set(selectionFixtures.map(\.id))
            model.selectSession("selection-2", modifiers: [.control])
            let toggleSelected = model.selectedSessions == Set(["selection-1", "selection-3"])
            model.moveSessions(model.selectedSessions, to: "Selection Target")
            let persisted = try? JSONDecoder().decode(SavedState.self, from: Data(contentsOf: model.support.appendingPathComponent("sessions.json")))
            let moved = persisted?.custom.filter { $0.id.hasPrefix("selection-") } ?? []
            let selectionCheck = rangeSelected && toggleSelected && moved.filter { $0.group == "Selection Target" }.count == 2 && moved.first { $0.id == "selection-2" }?.group == "Selection Test"
            let passed = selectionCheck && reconnectCheck && tabSwitchCheck && splitCheck && senderCheck && commandSaved && credentialsCheck && tab?.exitCode == 7 && tab?.running == false && attached && unicode && folderCheck && browserCheck
            let window = workspaceWindow
            let titlebarHeight = window.map { $0.frame.height - $0.contentLayoutRect.height } ?? -1
            let report: [String: Any] = ["tabSwitching": tabSwitchCheck, "nestedSplitPanes": splitCheck, "focusedCommandSender": senderCheck, "savedCommands": commandSaved, "credentialsManager": credentialsCheck, "titlebarHeight": titlebarHeight, "passed": passed, "terminalAttachedToWindow": attached, "unicodeOutput": unicode, "exitCode": tab?.exitCode ?? -1, "applicationSurvivedChildExit": true, "folderTree": folderCheck, "sftpBrowser": browserExpected ? browserCheck as Any : NSNull()]
            var checkedReport = report
            checkedReport["multipleSessionSelectionAndMove"] = selectionCheck
            checkedReport["disconnectedSSHReturnReconnect"] = reconnectCheck
            do { try JSONSerialization.data(withJSONObject: checkedReport, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic) }
            catch { fputs("Could not write smoke report: \(error.localizedDescription)\n", stderr) }
            model.shutdown()
            NSApp.terminate(nil)
        }
    }
    @MainActor private func checkDisconnectedReturn(configDirectory: URL) async -> Bool {
        // Synthetic child exit: no SSH server, credentials or network required.
        let tab = TerminalTab(session: Session(name: "重连验证", kind: "SSH", host: "127.0.0.1"), sftp: false, configDirectory: configDirectory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.terminal
        window.makeFirstResponder(tab.terminal)
        defer { tab.stop(); window.close() }
        var calls = 0
        tab.onReconnect = { calls += 1 }
        func enter(_ code: UInt16 = 36, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeated, keyCode: code)!
        }
        var passed = tab.handleReconnectKey(enter()) != nil && calls == 0
        tab.processTerminated(source: tab.terminal, exitCode: 255 << 8)
        try? await Task.sleep(nanoseconds: 50_000_000)
        passed = passed && tab.exitCode == 255 && tab.handleReconnectKey(enter(flags: .command)) != nil
        window.makeFirstResponder(window)
        passed = passed && tab.handleReconnectKey(enter()) != nil && calls == 0
        window.makeFirstResponder(tab.terminal)
        passed = passed && tab.handleReconnectKey(enter(repeated: true)) == nil && calls == 0
        passed = passed && tab.handleReconnectKey(enter()) == nil && calls == 1
        passed = passed && tab.handleReconnectKey(enter()) != nil && calls == 1
        tab.processTerminated(source: tab.terminal, exitCode: 255 << 8)
        try? await Task.sleep(nanoseconds: 50_000_000)
        passed = passed && tab.handleReconnectKey(enter(76)) == nil && calls == 2
        return passed
    }
    @MainActor private func writePreview(_ destination: URL, view explicitView: NSView? = nil) {
        // Snapshot only this isolated test app's own view hierarchy, never another app or desktop.
        guard let view = explicitView ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: destination)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.tabs.contains(where: \.running) == true || model?.hasFileConnections == true {
            let alert = NSAlert(); alert.messageText = "退出 MyTerm？"; alert.informativeText = "所有运行中的终端、SSH 和 SFTP 连接都将关闭。"
            alert.addButton(withTitle: "退出"); alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        model?.shutdown(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
