import Foundation

public struct Session: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var group: String
    public var kind: String
    public var host: String
    public var port: Int
    public var username: String
    public var identityFile: String
    public var jump: String
    public var shellArguments: [String]
    public var workingDirectory: String
    public var warnings: [String]
    public var isImported: Bool
    public var windAuthentication: WindAuthReference?
    public var windAuthenticationEnabled: Bool?
    public var credentialProfileID: String?
    public var jumpMode: JumpMode?

    public init(id: String = UUID().uuidString, name: String = "新建连接", group: String = "我的连接", kind: String = "SSH", host: String = "", port: Int = 22, username: String = "", identityFile: String = "", jump: String = "", shellArguments: [String] = [], workingDirectory: String = "", warnings: [String] = [], isImported: Bool = false, windAuthentication: WindAuthReference? = nil) {
        self.id = id; self.name = name; self.group = group; self.kind = kind
        self.host = host; self.port = port; self.username = username
        self.identityFile = identityFile; self.jump = jump
        self.shellArguments = shellArguments; self.workingDirectory = workingDirectory
        self.warnings = warnings; self.isImported = isImported; self.windAuthentication = windAuthentication
    }
    public var endpoint: String { kind == "Shell" ? host : "\(username.isEmpty ? "" : username + "@")\(host):\(port)" }
    public var supported: Bool { kind == "SSH" || kind == "Shell" }
}

public enum WindError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

public struct ImportResult {
    public var sessions: [Session]
    public var source: URL
    public var notes: [String]
}

public enum WindImporter {
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var roots = [home.appendingPathComponent(".wind/profiles")]
        let config = URL(fileURLWithPath: "/Applications/WindTerm.app/Contents/MacOS/profiles.config")
        if let data = try? Data(contentsOf: config),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = object["path"] as? String {
            let expanded = (path as NSString).expandingTildeInPath
            let base = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : config.deletingLastPathComponent().appendingPathComponent(expanded)
            roots.append(base.appendingPathComponent(".wind/profiles"))
        }
        var found: [URL] = []
        for root in roots {
            let profiles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for profile in profiles.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                let file = profile.appendingPathComponent("terminal/user.sessions")
                if FileManager.default.fileExists(atPath: file.path), !found.contains(file) { found.append(file) }
            }
        }
        return found
    }

    public static func load(_ source: URL) throws -> ImportResult {
        try parse(Data(contentsOf: source), source: source)
    }

    public static func parse(_ data: Data, source: URL = URL(fileURLWithPath: "/import/user.sessions")) throws -> ImportResult {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let rows = object as? [[String: Any]] else { throw WindError.invalid("会话文件应为 WindTerm user.sessions JSON 数组。") }
        var ids = Set<String>()
        let sessions = try rows.enumerated().map { index, row -> Session in
            func string(_ key: String) -> String { row[key] as? String ?? "" }
            let originalID = string("session.uuid")
            let id = originalID.isEmpty ? "import-\(index)" : originalID
            guard ids.insert(id).inserted else { throw WindError.invalid("配置中存在重复的会话 UUID，未导入。") }
            let kind = string("session.protocol")
            var target = string("session.target")
            var username = string("ssh.userName")
            if username.isEmpty { username = string("session.username") }
            if let at = target.lastIndex(of: "@"), kind.uppercased() == "SSH" {
                username = String(target[..<at]); target = String(target[target.index(after: at)...])
            }
            var warnings: [String] = []
            if !string("session.oneKey").isEmpty || !string("session.autoLogin").isEmpty {
                warnings.append("已关联 WindTerm 认证配置；连接时在内存中读取用户名、密码或密钥，不改写原配置。")
            }
            let proxy = string("session.proxy")
            var jump = string("ssh.proxyJump")
            if jump.isEmpty { jump = string("ssh.jumpServer") }
            if !proxy.isEmpty && proxy.lowercased() != "none" {
                if rows.contains(where: { $0["session.uuid"] as? String == proxy }) { jump = proxy }
                else { warnings.append("未转换的 WindTerm 代理：\(proxy)。请在连接设置中明确配置跳板机。"); if jump.isEmpty { jump = "unsupported:\(proxy)" } }
            }
            let unsupported = row.keys.filter { key in
                (key.hasPrefix("session.proxy") && key != "session.proxy" && key != "session.proxyDns" && key != "session.proxyWorkingDirectory") || key == "ssh.proxyCommand"
            }
            if !unsupported.isEmpty && jump.isEmpty {
                jump = "unsupported:proxy"
                warnings.append("包含尚未支持的代理字段：\(unsupported.sorted().joined(separator: ", "))。请重新配置跳板机。")
            }
            var args: [String] = []
            if let array = row["process.arguments"] as? [String] { args = array }
            else if !string("process.arguments").isEmpty {
                do { args = try splitArguments(string("process.arguments")) }
                catch { warnings.append("Shell 参数格式无效，请在原配置中修正。"); args = ["__INVALID_ARGUMENTS__"] }
            }
            let rawPort = row["session.port"]
            let port = (rawPort as? Int) ?? (rawPort as? String).flatMap(Int.init) ?? (rawPort == nil ? 22 : 0)
            if kind != "SSH" && kind != "Shell" { warnings.append("当前版本尚不支持 \(kind) 协议。") }
            let authReference = (!string("session.oneKey").isEmpty || !string("session.autoLogin").isEmpty) ? WindAuthReference(sessionsFile: source.path, sessionID: id) : nil
            return Session(id: id, name: string("session.label").isEmpty ? target : string("session.label"), group: string("session.group").isEmpty ? "未分组" : string("session.group"), kind: kind, host: target, port: port, username: username, identityFile: string("ssh.identityFilePath.macos"), jump: jump, shellArguments: args, workingDirectory: string("process.workingDirectory"), warnings: warnings, isImported: true, windAuthentication: authReference)
        }
        return ImportResult(sessions: sessions, source: source, notes: ["只读导入 \(sessions.count) 条会话；未读取密码，未修改原文件。"])
    }

    public static func splitArguments(_ text: String) throws -> [String] {
        var args: [String] = [], current = "", quote: Character?, escaped = false, started = false
        for c in text {
            if escaped { current.append(c); escaped = false; started = true; continue }
            if c == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let q = quote { if c == q { quote = nil } else { current.append(c) }; continue }
            if c == "\"" || c == "'" { quote = c; started = true }
            else if c.isWhitespace { if started { args.append(current); current = ""; started = false } }
            else { current.append(c); started = true }
        }
        guard quote == nil && !escaped else { throw WindError.invalid("Shell 参数引号不完整。") }
        if started { args.append(current) }
        return args
    }
}
