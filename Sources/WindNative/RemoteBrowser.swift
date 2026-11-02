import AppKit
import SwiftUI
import WindCore

struct TransferRecord: Identifiable {
    let id = UUID()
    let name: String
    let upload: Bool
    var fraction: Double = 0
    var status = "传输中"
}

@MainActor final class RemoteBrowser: ObservableObject {
    let session: Session
    var all: [Session]
    let directory: URL
    let credentialStore: CredentialStore
    @Published var path = ""
    @Published var pathInput = ""
    @Published var entries: [RemoteEntry] = []
    @Published var selected: String?
    @Published var busy = false
    @Published var connected = false
    @Published var message = "尚未连接"
    @Published var failure: String?
    @Published var showHidden = false
    @Published var transfers: [TransferRecord] = []
    @Published var filter = ""
    @Published private(set) var history: [String] = []
    @Published private(set) var historyIndex = -1
    var canGoBack: Bool { connected && !busy && historyIndex > 0 }
    var canGoForward: Bool { connected && !busy && historyIndex >= 0 && historyIndex + 1 < history.count }
    private var client: SFTPClient?
    private var task: Task<Void, Never>?
    private var operation = UUID()
    init(session: Session, all: [Session], directory: URL, credentialStore: CredentialStore) { self.session = session; self.all = all; self.directory = directory; self.credentialStore = credentialStore }
    var visible: [RemoteEntry] { entries.filter { (showHidden || !$0.name.hasPrefix(".")) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) } }
    var selectedEntry: RemoteEntry? { entries.first { $0.id == selected } }

    func connect() {
        guard !busy else { return }
        client?.disconnect()
        let client = SFTPClient(); self.client = client
        run("正在连接 \(session.name)…") { [self] in
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/WindAskpass").path
            let development = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("WindAskpass").path
            let helper = [bundled, development].first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let helper else { throw WindError.invalid("缺少 SSH 认证助手，请重新构建应用。") }
            do {
                let environment = ProcessInfo.processInfo.environment
                let home: String
                if CommandLine.arguments.contains("--smoke-report"), let config = environment["WINDNATIVE_SMOKE_SFTP_CONFIG"], let alias = environment["WINDNATIVE_SMOKE_SFTP_ALIAS"] {
                    _ = try await client.open(arguments: ["-F", config, "-s", alias, "sftp"])
                    home = environment["WINDNATIVE_SMOKE_REMOTE_PATH"] ?? "."
                } else {
                    home = try await client.connect(session: session, all: all, directory: directory, askpass: helper, credentialStore: credentialStore)
                }
                let canonicalHome = try await client.realpath(home)
                let entries = try await client.list(canonicalHome)
                try Task.checkCancellation()
                self.path = canonicalHome; self.pathInput = canonicalHome; self.entries = entries
                self.history = [canonicalHome]; self.historyIndex = 0
                self.connected = true; self.message = "已连接 · \(session.name)"
            } catch { client.disconnect(); self.connected = false; throw error }
        }
    }
    private func run(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failure = nil; self.message = message
        let id = UUID(); operation = id
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await action(); if self.operation == id { self.message = "\(self.entries.count) 项 · \(self.session.name)" } }
            catch {
                guard self.operation == id else { return }
                self.failure = error is CancellationError ? "操作已取消" : error.localizedDescription
                self.message = "操作未完成"
            }
            if self.operation == id { self.busy = false; self.task = nil }
        }
    }
    func disconnect() {
        operation = UUID(); task?.cancel(); task = nil
        client?.disconnect(); client = nil; busy = false; connected = false; message = "已断开"
        for index in transfers.indices where transfers[index].status == "传输中" { transfers[index].status = "已取消" }
    }
    func navigate(_ destination: String, historyIndex destinationIndex: Int? = nil) {
        guard let client, connected else { return }
        run("正在读取目录…") { [self] in
            let canonical = try await client.realpath(destination)
            let rows = try await client.list(canonical)
            try Task.checkCancellation()
            self.path = canonical; self.pathInput = canonical; self.entries = rows; self.selected = nil
            if let destinationIndex { self.historyIndex = destinationIndex; self.history[destinationIndex] = canonical }
            else { self.recordHistory(canonical) }
        }
    }
    private func recordHistory(_ path: String) {
        guard history.indices.contains(historyIndex) ? history[historyIndex] != path : true else { return }
        history = Array(history.prefix(historyIndex + 1)) + [path]; historyIndex = history.count - 1
    }
    func goBack() { if canGoBack { navigate(history[historyIndex - 1], historyIndex: historyIndex - 1) } }
    func goForward() { if canGoForward { navigate(history[historyIndex + 1], historyIndex: historyIndex + 1) } }
    func refresh() { navigate(path) }
    func up() { navigate(path == "/" ? "/" : (path as NSString).deletingLastPathComponent) }
    func open(_ entry: RemoteEntry) {
        if entry.isDirectory { navigate(entry.path) }
        else if entry.isSymbolicLink, let client {
            run("正在读取链接…") { [self] in
                let info = try await client.stat(entry.path)
                if info.isDirectory {
                    let canonical = try await client.realpath(entry.path)
                    let rows = try await client.list(canonical)
                    try Task.checkCancellation()
                    self.path = canonical; self.pathInput = canonical; self.entries = rows; self.selected = nil
                    self.recordHistory(canonical)
                } else { self.message = "文件链接，请使用下载按钮" }
            }
        } else { download(entry) }
    }
    private func validName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") }
    private func askName(_ title: String, initial: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 25)); field.stringValue = initial
        alert.accessoryView = field; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard validName(field.stringValue) else { failure = "名称不能为空，也不能包含 / 或空字符。"; return nil }
        return field.stringValue
    }
    func mkdir() {
        guard let client, connected, !busy, let name = askName("新建远程文件夹") else { return }
        run("正在创建文件夹…") { [self] in
            try await client.mkdir(SFTPClient.join(path, name))
            self.entries = try await client.list(path)
        }
    }
    func rename(_ entry: RemoteEntry) {
        guard let client, connected, !busy, let name = askName("重命名", initial: entry.name), name != entry.name else { return }
        run("正在重命名…") { [self] in
            try await client.rename(entry.path, to: SFTPClient.join(path, name))
            self.entries = try await client.list(path)
        }
    }
    func remove(_ entry: RemoteEntry) {
        guard let client, connected, !busy else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "删除远程\(entry.isDirectory ? "文件夹" : "文件")「\(entry.name)」？"
        alert.informativeText = "此操作直接从服务器删除，无法移至废纸篓。文件夹必须为空。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        run("正在删除…") { [self] in
            try await client.remove(entry.path, directory: entry.isDirectory)
            self.entries = try await client.list(path); self.selected = nil
        }
    }
    func chooseUpload() {
        guard connected, !busy else { return }
        let panel = NSOpenPanel(); panel.title = "上传文件到 \(session.name)"; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { upload(panel.urls) }
    }
    func upload(_ urls: [URL]) {
        guard let client, connected, !busy, !urls.isEmpty else { return }
        run("正在上传…") { [self] in
            for url in urls {
                try Task.checkCancellation()
                let name = url.lastPathComponent
                guard validName(name) else { throw WindError.invalid("文件名无效。") }
                if entries.contains(where: { $0.name == name }) { throw WindError.invalid("远端已存在「\(name)」。请先重命名后上传；现有文件未被覆盖。") }
                let record = TransferRecord(name: name, upload: true); transfers.insert(record, at: 0)
                let operation = self.operation
                do {
                    try await client.upload(url, to: SFTPClient.join(path, name)) { [weak self] done, total in
                        guard done == total || done % 1_048_576 < 65536 else { return }
                        Task { @MainActor in self?.progress(record.id, operation: operation, done: done, total: total) }
                    }
                    complete(record.id, status: "已完成")
                } catch { complete(record.id, status: "失败 / 已取消"); throw error }
                self.entries = try await client.list(path)
            }
        }
    }
    func download(_ entry: RemoteEntry) {
        guard let client, connected, !busy else { return }
        guard !entry.isDirectory else { failure = "暂不支持递归下载文件夹，请进入目录选择文件。"; return }
        let panel = NSSavePanel(); panel.title = "下载 \(entry.name)"; panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        run("正在下载…") { [self] in
            let record = TransferRecord(name: entry.name, upload: false); transfers.insert(record, at: 0)
            let operation = self.operation
            do {
                try await client.download(entry.path, to: destination) { [weak self] done, total in
                    guard done == total || done % 1_048_576 < 65536 else { return }
                    Task { @MainActor in self?.progress(record.id, operation: operation, done: done, total: total) }
                }
                complete(record.id, status: "已完成")
            } catch { complete(record.id, status: "失败 / 已取消"); throw error }
        }
    }
    private func progress(_ id: UUID, operation: UUID, done: UInt64, total: UInt64) {
        guard self.operation == operation, let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].status == "传输中" else { return }
        transfers[index].fraction = total > 0 ? min(1, Double(done) / Double(total)) : 0
    }
    private func complete(_ id: UUID, status: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].status = status
        if status == "已完成" { transfers[index].fraction = 1 }
        if transfers.count > 30 { transfers.removeLast(transfers.count - 30) }
    }
}
