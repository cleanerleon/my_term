import AppKit
import SwiftUI
import SwiftTerm
import WindCore
import Darwin

enum SidebarMode { case sessions, files }
enum BottomPanel: String, CaseIterable { case sender = "命令发送器", sessions = "活动会话", transfers = "传输" }
struct FolderEdit: Identifiable {
    let id = UUID()
    var original: String?
    var parent: String = ""
}

struct SavedState: Codable {
    var source: String?
    var overrides: [String: Session] = [:]
    var custom: [Session] = []
    var hidden: Set<String> = []
    var folders: [String]?
    var expandedFolders: [String]?
    var importedSnapshot: [Session]?
    var commands: [SavedCommand]?
    var fontSize: Double?
    var sidebarVisible: Bool?
    var bottomVisible: Bool?
}

final class DiagnosticTerminalView: LocalProcessTerminalView {
    private let outputLock = NSLock()
    private var recentOutput = Data()
    override func dataReceived(slice: ArraySlice<UInt8>) {
        outputLock.lock()
        recentOutput.append(contentsOf: slice)
        if recentOutput.count > 131_072 { recentOutput.removeFirst(recentOutput.count - 131_072) }
        outputLock.unlock()
        super.dataReceived(slice: slice)
    }
    var diagnosticOutput: String {
        outputLock.lock(); defer { outputLock.unlock() }
        return String(decoding: recentOutput, as: UTF8.self)
    }
}

final class TerminalTab: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let session: Session
    let isSFTP: Bool
    let terminal: DiagnosticTerminalView
    let configURL: URL
    @Published var status = "启动中"
    @Published var title: String
    @Published var running = false
    @Published var exitCode: Int32?
    @Published var tabColor = "cyan"
    var onChange: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onHostKeyChange: ((HostKeyChange) -> Void)?
    private var stopped = false
    private var authentication: AuthenticationBroker?
    private var reconnectKeyMonitor: Any?

    init(session: Session, sftp: Bool, configDirectory: URL) {
        self.session = session; self.isSFTP = sftp; title = session.name + (sftp ? " · SFTP" : "")
        configURL = configDirectory.appendingPathComponent(UUID().uuidString + ".conf")
        terminal = DiagnosticTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        super.init()
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(calibratedRed: 0.115, green: 0.115, blue: 0.12, alpha: 1)
        terminal.nativeForegroundColor = NSColor(calibratedRed: 0.84, green: 0.87, blue: 0.91, alpha: 1)
        terminal.optionAsMetaKey = true
        terminal.processDelegate = self
        terminal.getTerminal().changeScrollback(10_000)
    }

    @MainActor func start(all: [Session], credentialStore: CredentialStore, approvedHostFingerprint: String? = nil) async throws {
        let session = session, configURL = configURL, isSFTP = isSFTP
        let (plan, bindings) = try await Task.detached(priority: .userInitiated) {
            let prepared = try WindAuthResolver().prepare(session, all: all, store: credentialStore)
            var bindings = prepared.bindings
            let plan = try ConnectionBuilder.build(prepared.session, all: prepared.all, configPath: configURL.path, sftp: isSFTP, resolver: { session in
                let defaults = try OpenSSHDefaults.resolve(session)
                for index in bindings.indices where bindings[index].host == session.host {
                    bindings[index].host = defaults.first("hostname") ?? session.host
                }
                return defaults
            })
            return (plan, bindings)
        }.value
        guard !stopped else { return }
        if let config = plan.config {
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["TERM_PROGRAM"] = "MyTerm"
        if session.kind == "SSH" {
            environment["LC_ALL"] = "C"
            let broker = try AuthenticationBroker(bindings: bindings, approvedHostFingerprint: approvedHostFingerprint); authentication = broker
            environment.merge(broker.environment) { _, new in new }
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/WindAskpass").path
            let development = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("WindAskpass").path
            guard let helper = [bundled, development].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw WindError.invalid("缺少 SSH 认证助手，请重新构建应用。") }
            environment["SSH_ASKPASS"] = helper; environment["SSH_ASKPASS_REQUIRE"] = "force"; environment["DISPLAY"] = "WindNative"
        }
        running = true
        status = session.kind == "Shell" ? "本地进程运行中" : "SSH 进程运行中"
        terminal.startProcess(executable: plan.executable, args: plan.arguments, environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: plan.directory)
        if terminal.process.shellPid <= 0 { running = false; throw WindError.invalid("无法创建终端进程，请关闭部分标签后重试。") }
        onChange?()
    }
    func stop() {
        stopped = true
        authentication?.stop(); authentication = nil
        onChange = nil
        onReconnect = nil
        onHostKeyChange = nil
        removeReconnectKeyMonitor()
        if running {
            let pid = terminal.process.shellPid
            var childStatus: Int32 = 0
            // Never signal a PID that the library has already reaped.
            let isLiveChild = pid > 0 && waitpid(pid, &childStatus, WNOHANG) == 0
            if isLiveChild { terminal.terminate() }
            // SwiftTerm cancels its exit monitor on terminate; reap the child ourselves.
            if isLiveChild {
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    for _ in 0..<20 {
                        let result = waitpid(pid, &status, WNOHANG)
                        if result == pid || result < 0 { return }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    kill(pid, SIGKILL)
                    _ = waitpid(pid, &status, 0)
                }
            }
        }
        running = false
        try? FileManager.default.removeItem(at: configURL)
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    private func removeReconnectKeyMonitor() {
        if let reconnectKeyMonitor { NSEvent.removeMonitor(reconnectKeyMonitor) }
        reconnectKeyMonitor = nil
    }
    deinit { removeReconnectKeyMonitor() }

    func handleReconnectKey(_ event: NSEvent) -> NSEvent? {
        guard reconnectKeyMonitor != nil, !stopped, !running,
              event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let window = terminal.window, event.window === window,
              window.firstResponder === terminal else { return event }
        if !event.isARepeat {
            let reconnect = onReconnect
            removeReconnectKeyMonitor()
            reconnect?()
        }
        return nil
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Keep the saved session name stable; remote titles are untrusted presentation text.
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.running = false
            self.authentication?.stop(); self.authentication = nil
            // LocalProcess reports waitpid status, not a decoded shell exit code.
            let code = exitCode.map { raw in (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f) }
            self.exitCode = code
            self.status = code == 0 ? "已结束" : "已断开 · \(code.map(String.init) ?? "未知状态")"
            let canReconnect = self.session.kind == "SSH"
            if canReconnect {
                self.removeReconnectKeyMonitor()
                self.reconnectKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    return self.handleReconnectKey(event)
                }
            }
            let hint = canReconnect ? "按回车键或使用工具栏重新连接。" : "使用工具栏重新连接。"
            self.terminal.feed(text: "\r\n\u{1b}[90m[\(self.status)] \(hint)\u{1b}[0m\r\n")
            try? FileManager.default.removeItem(at: self.configURL)
            self.onChange?()
            if self.session.kind == "SSH", code == 255,
               let change = HostKeyChange.parse(self.terminal.diagnosticOutput) {
                self.onHostKeyChange?(change)
            }
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var tabs: [TerminalTab] = []
    @Published var selectedSession: String?
    @Published var selectedSessions: Set<String> = []
    private var selectionAnchor: String?
    @Published var activeTab: UUID?
    @Published var query = ""
    @Published var error: String?
    @Published var notice = ""
    @Published var editing: Session?
    @Published var showInspector = false
    @Published var sidebarMode: SidebarMode = .sessions
    @Published var fileSession: String?
    @Published var browsers: [String: RemoteBrowser] = [:]
    @Published var folderEdit: FolderEdit?
    @Published var expandedFolders: Set<String> = []
    @Published var source = ""
    @Published var authenticationProfiles: [AuthenticationProfile] = []
    @Published var selectedCredentialID: String?
    @Published var isMigratingAuthentication = false
    @Published var credentialIssue: String?
    @Published var paneLayout: TerminalLayout?
    @Published var showSidebar = true
    @Published var showBottomPanel = false
    @Published var bottomPanel: BottomPanel = .sender
    @Published var commands: [SavedCommand] = []
    @Published var fontSize: Double = 13
    @Published var senderText = ""
    @Published var senderAppendsReturn = true
    private var focusedPane: UUID?
    private var lastClosed: (Session, Bool)?
    private var saved = SavedState()
    private var imported: [Session] = []
    let support: URL
    let configDirectory: URL
    let credentialStore: CredentialStore
    private let stateURL: URL

    init() {
        let smoke = CommandLine.arguments.contains("--smoke-report")
        support = smoke ? FileManager.default.temporaryDirectory.appendingPathComponent("windnative-ui-" + UUID().uuidString) : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WindNative")
        credentialStore = CredentialStore(directory: support, keyProvider: smoke ? EphemeralVaultKey() : KeychainVaultKey())
        stateURL = support.appendingPathComponent("sessions.json")
        configDirectory = ConnectionRuntime.newDirectoryURL()
        do {
            try ConnectionRuntime.create(configDirectory)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
                expandedFolders = Set(saved.expandedFolders ?? [])
                commands = saved.commands ?? []
                fontSize = min(30, max(9, saved.fontSize ?? 13))
                showSidebar = saved.sidebarVisible ?? true
                showBottomPanel = saved.bottomVisible ?? false
            }
            authenticationProfiles = try credentialStore.profiles()
            if smoke {
                if let path = ProcessInfo.processInfo.environment["WINDNATIVE_SMOKE_SESSIONS"] { imported = try WindImporter.load(URL(fileURLWithPath: path)).sessions }
                else { imported = [Session(id: "demo-dev", name: "Development", group: "dev/api", host: "dev.example.invalid"), Session(id: "demo-vps", name: "Production", group: "vps", host: "vps.example.invalid")] }
                rebuild(); migrateAuthentication(); return
            }
            if let snapshot = saved.importedSnapshot {
                imported = snapshot; source = saved.source ?? ""; rebuild(); migrateAuthentication(); return
            }
            let file = saved.source.map { URL(fileURLWithPath: $0) } ?? WindImporter.discover().first
            if let file { try importFile(file) }
            else { rebuild(); notice = "未发现 WindTerm 配置，可导入 user.sessions 或新建 SSH 连接。"; migrateAuthentication() }
        } catch { self.error = "加载配置失败：\(error.localizedDescription)"; rebuild() }
    }
    var selected: Session? { sessions.first { $0.id == selectedSession } }
    var currentTab: TerminalTab? { tabs.first { $0.id == activeTab } }
    var filtered: [Session] {
        sessions.filter { query.isEmpty || "\($0.name) \($0.host) \($0.group) \($0.username)".localizedCaseInsensitiveContains(query) }
    }
    var groups: [String] { Array(Set(filtered.map(\.group))).sorted() }
    var folderTree: [SessionFolder] { SessionFolder.tree(sessions: filtered, emptyFolders: query.isEmpty ? saved.folders ?? [] : []) }
    var folderPaths: [String] { SessionFolder.allPaths(sessions: sessions, emptyFolders: saved.folders ?? []) }
    var visibleSessionIDs: [String] {
        func flatten(_ folder: SessionFolder) -> [String] {
            guard !query.isEmpty || expandedFolders.contains(folder.path) else { return [] }
            return folder.children.flatMap(flatten) + folder.sessions.map(\.id)
        }
        return folderTree.flatMap(flatten)
    }
    func selectSession(_ id: String, modifiers: NSEvent.ModifierFlags) {
        let toggle = modifiers.contains(.command) || modifiers.contains(.control)
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let start = visibleSessionIDs.firstIndex(of: anchor), let end = visibleSessionIDs.firstIndex(of: id) {
            let range = Set(visibleSessionIDs[min(start,end)...max(start,end)])
            selectedSessions = toggle ? selectedSessions.union(range) : range
        } else if toggle {
            if selectedSessions.contains(id) { selectedSessions.remove(id) } else { selectedSessions.insert(id) }
            selectionAnchor = id
        } else {
            selectedSessions = [id]; selectionAnchor = id
        }
        selectedSession = selectedSessions.contains(id) ? id : selectedSessions.first
    }
    var currentBrowser: RemoteBrowser? { fileSession.flatMap { browsers[$0] } }
    var hasFileConnections: Bool { browsers.values.contains { $0.connected || $0.busy } }
    func setFolderExpanded(_ path: String, expanded: Bool) {
        if expanded { expandedFolders.insert(path) } else { expandedFolders.remove(path) }
        saved.expandedFolders = Array(expandedFolders)
        do { try persist() } catch { self.error = error.localizedDescription }
    }
    func openFiles(_ session: Session) {
        guard !isMigratingAuthentication else { error = "正在迁移认证配置，请稍后再连接。"; return }
        guard session.kind == "SSH" else { return }
        sidebarMode = .files; fileSession = session.id
        if browsers[session.id] == nil {
            browsers[session.id] = RemoteBrowser(session: session, all: sessions, directory: configDirectory, credentialStore: credentialStore)
            browsers[session.id]?.connect()
        }
    }
    func selectFilesMode() {
        sidebarMode = .files
        if let session = currentTab?.session, session.kind == "SSH" { openFiles(session) }
        else if currentBrowser == nil, let selected, selected.kind == "SSH" { openFiles(selected) }
    }
    func activeTabChanged() {
        reconcilePanes()
        if sidebarMode == .files, let session = currentTab?.session, session.kind == "SSH" { openFiles(session) }
    }
    func move(_ session: Session, to folder: String) {
        moveSessions([session.id], to: folder)
    }
    func moveSessions(_ ids: Set<String>, to folder: String) {
        let matching = sessions.filter { ids.contains($0.id) }
        guard !matching.isEmpty else { return }
        let previous = saved, previousExpanded = expandedFolders
        for session in matching {
            var updated = session; updated.group = folder
            saved.folders = Array(Set((saved.folders ?? []) + [session.group, folder]))
            if imported.contains(where: { $0.id == session.id }) { saved.overrides[session.id] = updated }
            else if let index = saved.custom.firstIndex(where: { $0.id == session.id }) { saved.custom[index] = updated }
        }
        for path in SessionFolder.allPaths(sessions: [], emptyFolders: [folder]) { expandedFolders.insert(path) }
        saved.expandedFolders = Array(expandedFolders)
        do { try persist(); rebuild(); selectedSessions = Set(matching.map(\.id)); notice = "已移动 \(matching.count) 个会话到 \(folder)" }
        catch { saved = previous; expandedFolders = previousExpanded; self.error = error.localizedDescription }
    }
    func removeEmptyFolder(_ path: String) {
        guard !sessions.contains(where: { let group = SessionFolder.normalized($0.group); return group == path || group.hasPrefix(path + "/") }) else { return }
        let previous = saved
        saved.folders = (saved.folders ?? []).filter { $0 != path && !$0.hasPrefix(path + "/") }
        do { try persist(); rebuild() } catch { saved = previous; self.error = error.localizedDescription }
    }
    func updateFolder(_ edit: FolderEdit, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else { error = "文件夹名称无效。"; return }
        let destination = edit.parent.isEmpty ? name : edit.parent + "/" + name
        if let original = edit.original, original == destination { folderEdit = nil; return }
        guard !folderPaths.contains(destination) else { error = "该位置已经有同名文件夹。"; return }
        let previous = saved
        if let original = edit.original {
            for session in sessions where SessionFolder.normalized(session.group) == original || SessionFolder.normalized(session.group).hasPrefix(original + "/") {
                let updated = SessionFolder.moved(session, from: original, to: destination)
                if imported.contains(where: { $0.id == session.id }) { saved.overrides[session.id] = updated }
                else if let index = saved.custom.firstIndex(where: { $0.id == session.id }) { saved.custom[index] = updated }
            }
            saved.folders = (saved.folders ?? []).map { path in
                path == original || path.hasPrefix(original + "/") ? destination + path.dropFirst(original.count) : path
            }
        }
        saved.folders = Array(Set((saved.folders ?? []) + [destination]))
        do { try persist(); rebuild(); folderEdit = nil }
        catch { saved = previous; self.error = error.localizedDescription }
    }
    func rebuild() {
        sessions = (imported.map { original in
            var session = saved.overrides[original.id] ?? original
            if session.windAuthentication == nil { session.windAuthentication = original.windAuthentication }
            return session
        } + saved.custom).filter { !saved.hidden.contains($0.id) }
        // Existing transfers keep their transport; the next reconnect uses current hop settings.
        browsers.values.forEach { $0.all = sessions }
    }
    func persist() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(saved).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    func importFile(_ file: URL) throws {
        let result = try WindImporter.load(file)
        imported = result.sessions; source = file.path; saved.source = file.path; saved.importedSnapshot = imported
        rebuild(); notice = result.notes.joined(separator: " ")
        try persist(); migrateAuthentication()
    }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.title = "选择 WindTerm 的 user.sessions"; panel.allowsMultipleSelection = false
        panel.directoryURL = WindImporter.discover().first?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            do { try importFile(url) } catch { self.error = error.localizedDescription }
        }
    }
    func refresh() {
        guard !source.isEmpty else { chooseImport(); return }
        do { try importFile(URL(fileURLWithPath: source)) } catch { self.error = error.localizedDescription }
    }
    func save(_ session: Session) {
        let previous = saved
        let previousGroup = sessions.first { $0.id == session.id }?.group
        saved.folders = Array(Set((saved.folders ?? []) + [session.group] + (previousGroup.map { [$0] } ?? [])))
        if imported.contains(where: { $0.id == session.id }) { saved.overrides[session.id] = session }
        else if let index = saved.custom.firstIndex(where: { $0.id == session.id }) { saved.custom[index] = session }
        else { saved.custom.append(session) }
        do {
            try persist(); rebuild(); selectedSession = session.id; editing = nil
            browsers.removeValue(forKey: session.id)?.disconnect()
        }
        catch { saved = previous; self.error = error.localizedDescription }
    }
    func hide(_ session: Session) {
        let previous = saved
        if session.isImported { saved.hidden.insert(session.id) }
        else { saved.custom.removeAll { $0.id == session.id } }
        do { try persist(); rebuild(); selectedSession = nil }
        catch { saved = previous; self.error = error.localizedDescription }
    }
    func connect(_ session: Session, sftp: Bool = false, approvedHostFingerprint: String? = nil) {
        if session.kind == "SSH" && isMigratingAuthentication { error = "正在迁移认证配置，请稍后再连接。"; return }
        do {
            // Validate before allocating a terminal view or launching a process.
            _ = try ConnectionBuilder.build(session, all: sessions, configPath: "/unused", sftp: sftp)
            let tab = TerminalTab(session: session, sftp: sftp, configDirectory: configDirectory)
            tab.onChange = { [weak self] in self?.objectWillChange.send() }
            tab.onReconnect = { [weak self, weak tab] in
                guard let self, let tab, !tab.running else { return }
                self.reconnect(tab)
            }
            tab.onHostKeyChange = { [weak self, weak tab] change in
                guard let self, let tab else { return }
                self.confirmHostKeyChange(change, tab: tab)
            }
            tab.terminal.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            tabs.append(tab); activeTab = tab.id; reconcilePanes()
            // Wait for SwiftUI to attach and size the PTY view.
            Task { @MainActor [weak self, weak tab] in
                guard let self, let tab, self.tabs.contains(where: { $0.id == tab.id }) else { return }
                do { try await tab.start(all: self.sessions, credentialStore: self.credentialStore, approvedHostFingerprint: approvedHostFingerprint) }
                catch { tab.stop(); tab.status = "启动失败"; self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func localShell() { connect(Session(name: "本地终端", group: "本机", kind: "Shell", host: "/bin/zsh")) }
    func close(_ tab: TerminalTab) {
        lastClosed = (tab.session, tab.isSFTP)
        tab.stop(); tabs.removeAll { $0.id == tab.id }
        paneLayout = paneLayout?.removing(tab.id)
        if activeTab == tab.id { activeTab = paneLayout?.terminals.last ?? tabs.last?.id }
        reconcilePanes()
    }
    func closeTabsToRight(of tab: TerminalTab) {
        guard let index=tabs.firstIndex(where: {$0.id == tab.id}) else {return}
        for other in Array(tabs.dropFirst(index + 1)) {close(other)}
    }
    func confirmHostKeyChange(_ change: HostKeyChange, tab: TerminalTab) {
        guard tabs.contains(where: { $0.id == tab.id }), !tab.running else { return }
        guard let snapshot = try? Data(contentsOf: URL(fileURLWithPath: change.file)) else {
            error = "无法读取旧主机记录，未更新。"; return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(change.host)」的主机密钥已变化"
        alert.informativeText = "服务器重装可能导致变化，也可能是连接被冒充。请核对新指纹后确认：\n\n\(change.fingerprint)\n\n确认后将备份并更新旧记录，然后重新连接。\n记录：\(change.file):\(change.line)"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "信任新密钥并重新连接")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn,
              tabs.contains(where: { $0.id == tab.id }), !tab.running else { return }
        Task { @MainActor in
            do {
                _ = try await Task.detached(priority: .userInitiated) { try change.removeOldKey(expectedContents: snapshot) }.value
                guard self.tabs.contains(where: { $0.id == tab.id }), !tab.running else { return }
                self.reconnect(tab, approvedHostFingerprint: change.fingerprint)
            } catch { self.error = error.localizedDescription }
        }
    }
    func reconnect(_ target: TerminalTab? = nil, approvedHostFingerprint: String? = nil) {
        guard let tab = target ?? currentTab, tabs.contains(where: { $0.id == tab.id }) else { return }
        let session = sessions.first { $0.id == tab.session.id } ?? tab.session
        activeTab = tab.id
        reconcilePanes()
        if tab.running { close(tab); guard !tabs.contains(where: { $0.id == tab.id }) else { return } }
        else { tab.stop(); tabs.removeAll { $0.id == tab.id } }
        connect(session, sftp: tab.isSFTP, approvedHostFingerprint: approvedHostFingerprint)
    }
    func profileName(_ id: String?) -> String {
        guard let id else { return "系统 SSH 配置" }
        return authenticationProfiles.first { $0.id == id }?.name ?? "认证配置不存在"
    }
    func credentialUsage(_ id: String) -> Int { Set((sessions + Array(saved.overrides.values) + saved.custom).filter { $0.credentialProfileID == id }.map(\.id)).count }
    @discardableResult func createCredential() -> String? {
        do {
            let profile = AuthenticationProfile(name: "新认证配置 \(authenticationProfiles.count + 1)")
            try credentialStore.save(profile, secrets: CredentialSecrets())
            authenticationProfiles = try credentialStore.profiles(); selectedCredentialID = profile.id
            return profile.id
        } catch { credentialIssue = error.localizedDescription; return nil }
    }
    func saveCredential(_ profile: AuthenticationProfile, password: String, passphrase: String) throws {
        var updated = profile
        updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.username = updated.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty else { throw WindError.invalid("请填写认证名称。") }
        if updated.method != .agent && updated.username.isEmpty { throw WindError.invalid("请填写登录用户名。") }
        if updated.method.usesPassword && password.isEmpty { throw WindError.invalid("请填写登录密码，或选择其他认证方式。") }
        if updated.method.usesKey {
            guard !updated.identityFile.isEmpty else { throw WindError.invalid("请选择私钥文件。") }
            updated.identityFile = try credentialStore.importIdentity(updated.identityFile)
        }
        try credentialStore.save(updated, secrets: CredentialSecrets(password: password.isEmpty ? nil : password, passphrase: passphrase.isEmpty ? nil : passphrase))
        authenticationProfiles = try credentialStore.profiles(); credentialIssue = nil
    }
    func deleteCredential(_ profile: AuthenticationProfile) {
        let usage = credentialUsage(profile.id)
        let alert = NSAlert(); alert.messageText = "删除认证「\(profile.name)」？"
        alert.informativeText = "将清空 \(usage) 个会话对此认证的引用，并删除保存的密码、口令，以及不再被其他认证使用的托管私钥。下次连接将使用系统 SSH 配置。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let previous = saved
        func clear(_ session: inout Session) {
            guard session.credentialProfileID == profile.id else { return }
            session.credentialProfileID = nil
            session.username = ""; session.identityFile = ""; session.windAuthenticationEnabled = false
        }
        for original in imported {
            var current = saved.overrides[original.id] ?? original
            if current.credentialProfileID == profile.id { clear(&current); saved.overrides[original.id] = current }
        }
        for id in Array(saved.overrides.keys) { if var item = saved.overrides[id] { clear(&item); saved.overrides[id] = item } }
        for index in saved.custom.indices { clear(&saved.custom[index]) }
        do {
            try persist()
            do { try credentialStore.delete(profile.id) }
            catch {
                saved = previous
                do { try persist() } catch { credentialIssue = "删除认证失败，且恢复会话配置失败：\(error.localizedDescription)"; rebuild(); return }
                throw error
            }
            rebuild()
            authenticationProfiles.removeAll { $0.id == profile.id }
            selectedCredentialID = authenticationProfiles.first?.id; credentialIssue = nil
        } catch { saved = previous; rebuild(); credentialIssue = error.localizedDescription }
    }
    func migrateAuthentication() {
        guard !isMigratingAuthentication else { return }
        let pending = sessions.filter { $0.kind == "SSH" && $0.credentialProfileID == nil && (($0.windAuthentication != nil && $0.windAuthenticationEnabled != false) || !$0.username.isEmpty || !$0.identityFile.isEmpty) }
        guard !pending.isEmpty else { return }
        isMigratingAuthentication = true
        let snapshot = sessions, store = credentialStore
        Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { try CredentialMigration.run(snapshot, store: store) }.value
                guard let self else { return }
                for migrated in result.sessions where migrated.credentialProfileID != nil {
                    guard var current = self.sessions.first(where: { $0.id == migrated.id }), current.credentialProfileID == nil else { continue }
                    current.credentialProfileID = migrated.credentialProfileID
                    current.username = ""; current.identityFile = ""; current.windAuthenticationEnabled = false
                    if self.imported.contains(where: { $0.id == current.id }) { self.saved.overrides[current.id] = current }
                    else if let index = self.saved.custom.firstIndex(where: { $0.id == current.id }) { self.saved.custom[index] = current }
                }
                self.saved.importedSnapshot = self.imported
                try self.persist(); self.rebuild()
                self.authenticationProfiles = try store.profiles()
                self.credentialIssue = result.issues.isEmpty ? nil : "部分认证未迁移：\n" + result.issues.joined(separator: "\n")
                self.notice = "认证已由 MyTerm 管理，共 \(self.authenticationProfiles.count) 项。"
            } catch { self?.credentialIssue = "认证迁移失败：\(error.localizedDescription)" }
            self?.isMigratingAuthentication = false
        }
    }
    func shutdown() {
        tabs.forEach { $0.stop() }; browsers.values.forEach { $0.disconnect() }
        try? FileManager.default.removeItem(at: configDirectory)
        if CommandLine.arguments.contains("--smoke-report") { try? FileManager.default.removeItem(at: support) }
    }
}

extension AppModel {
    func reopenLastClosed() {
        guard let (session, sftp) = lastClosed else { return }
        connect(sessions.first { $0.id == session.id } ?? session, sftp: sftp)
    }
    func reorderTab(_ source: UUID, before destination: UUID) {
        guard source != destination, let original = tabs.firstIndex(where: { $0.id == source }), tabs.contains(where: { $0.id == destination }) else { return }
        let tab = tabs.remove(at: original)
        if let index = tabs.firstIndex(where: { $0.id == destination }) { tabs.insert(tab, at: index) }
    }
    func reconcilePanes() {
        guard let activeTab, tabs.contains(where: { $0.id == activeTab }) else {
            if tabs.isEmpty { paneLayout = nil; focusedPane = nil }
            return
        }
        if let layout = paneLayout {
            if !layout.terminals.contains(activeTab) {
                paneLayout = layout.replacing(focusedPane ?? layout.terminals[0], with: activeTab)
            }
        } else { paneLayout = .terminal(activeTab) }
        focusedPane = activeTab
    }
    func splitTerminal(_ axis: PaneAxis) {
        guard let tab = currentTab else { localShell(); return }
        let previous = paneLayout ?? .terminal(tab.id)
        let session = sessions.first { $0.id == tab.session.id } ?? tab.session
        connect(session, sftp: tab.isSFTP)
        guard let newID = activeTab, newID != tab.id else { return }
        paneLayout = previous.splitting(tab.id, with: newID, axis: axis)
        focusedPane = newID
    }
    func unsplit() { if let activeTab { paneLayout = .terminal(activeTab); focusedPane = activeTab } }
    func nextPane() {
        guard let ids = paneLayout?.terminals, !ids.isEmpty else { return }
        let current = ids.firstIndex(of: activeTab ?? ids[0]) ?? 0
        activeTab = ids[(current + 1) % ids.count]; reconcilePanes()
    }
    func duplicateTab(_ tab: TerminalTab) { connect(sessions.first { $0.id == tab.session.id } ?? tab.session, sftp: tab.isSFTP) }
    func duplicateSession(_ original: Session) {
        var copy = original; copy.id = UUID().uuidString; copy.name += " 副本"; copy.isImported = false
        editing = copy
    }
    func renameTab(_ tab: TerminalTab) {
        let alert = NSAlert(); alert.messageText = "重命名标签"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); field.stringValue = tab.title
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tab.title = field.stringValue }
    }
    func disconnectCurrent() { currentTab?.stop(); currentTab?.status = "已主动断开"; objectWillChange.send() }
    func setFontSize(_ value: Double) {
        fontSize = min(30, max(9, value))
        tabs.forEach { $0.terminal.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        saveWorkspace()
    }
    func saveWorkspace() {
        saved.commands = commands; saved.fontSize = fontSize
        saved.sidebarVisible = showSidebar; saved.bottomVisible = showBottomPanel
        do { try persist() } catch { self.error = error.localizedDescription }
    }
    func toggleBottom(_ panel: BottomPanel) {
        showBottomPanel = bottomPanel == panel ? !showBottomPanel : true
        bottomPanel = panel; saveWorkspace()
    }
    func saveCommand() {
        guard !senderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        commands.append(SavedCommand(name: String(senderText.split(separator: "\n").first.map(String.init)?.prefix(48) ?? "命令"), text: senderText))
        saveWorkspace()
    }
    func sendCommand() {
        guard let tab = currentTab, tab.running, !senderText.isEmpty else { return }
        // Explicitly targets only the focused PTY. Never broadcast or keep an automatic history.
        let text = senderText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        tab.terminal.send(txt: text + (senderAppendsReturn && !text.hasSuffix("\r") ? "\r" : ""))
    }
    func exportOutput() {
        guard let tab = currentTab else { return }
        let panel = NSSavePanel(); panel.title = "保存终端输出"; panel.nameFieldStringValue = tab.session.name + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try tab.terminal.getTerminal().getBufferAsData().write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
}
