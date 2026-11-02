import Foundation

public struct ConnectionPlan {
    public var executable: String
    public var arguments: [String]
    public var directory: String?
    public var config: String?
    public init(executable: String, arguments: [String], directory: String? = nil, config: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.directory = directory; self.config = config
    }
}

public enum ConnectionBuilder {
    public static func build(_ session: Session, all: [Session], configPath: String, sftp: Bool = false, resolver: ((Session) throws -> OpenSSHDefaults)? = nil) throws -> ConnectionPlan {
        if session.kind == "Shell" {
            guard !sftp else { throw WindError.invalid("本地 Shell 没有 SFTP 连接。") }
            guard session.host.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: session.host) else { throw WindError.invalid("本地 Shell 不存在或不可执行。") }
            guard !session.shellArguments.contains("__INVALID_ARGUMENTS__") else { throw WindError.invalid("请先修正 Shell 参数。") }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let configured = (session.workingDirectory as NSString).expandingTildeInPath
                .replacingOccurrences(of: "${HomeDir}", with: home)
            let dir = configured.isEmpty ? home : configured
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &directory), directory.boolValue else { throw WindError.invalid("工作目录不存在。") }
            return ConnectionPlan(executable: session.host, arguments: session.shellArguments.isEmpty ? ["-l"] : session.shellArguments, directory: dir)
        }
        guard session.kind == "SSH" else { throw WindError.invalid("暂不支持 \(session.kind) 协议。") }
        _ = try JumpSettings.chain(session, all: all)
        var blocks: [String] = [], visited = Set<String>(), active = Set<String>()
        func alias(_ s: Session) -> String { "wn-" + s.id.utf8.map { String(format: "%02x", $0) }.joined() }
        func safeHost(_ host: String) throws {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]%")
            guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw WindError.invalid("服务器地址格式无效；只填写主机名、SSH 别名或 IP。") }
        }
        func quote(_ value: String) throws -> String {
            guard !value.contains(where: { $0.isNewline || $0 == "\0" || $0 == "\"" || $0 == "\\" }) else { throw WindError.invalid("连接字段含有不支持的控制字符或引号。") }
            return "\"\(value)\""
        }
        func visit(_ s: Session) throws {
            guard !active.contains(s.id) else { throw WindError.invalid("跳板机形成循环，请检查连接设置。") }
            if visited.contains(s.id) { return }
            guard s.kind == "SSH" else { throw WindError.invalid("跳板会话必须使用 SSH 协议。") }
            try safeHost(s.host)
            guard (1...65535).contains(s.port) else { throw WindError.invalid("端口必须为 1–65535。") }
            if !s.username.isEmpty {
                guard !s.username.hasPrefix("-"), !s.username.contains(where: { $0.isWhitespace || $0 == "@" }) else { throw WindError.invalid("用户名格式无效。") }
            }
            active.insert(s.id)
            let defaults = try resolver?(s) ?? OpenSSHDefaults()
            let hostname = defaults.first("hostname") ?? s.host
            try safeHost(hostname)
            let username = s.username.isEmpty ? defaults.first("user") ?? "" : s.username
            var block = "Host \(alias(s))\n  HostName \(hostname)\n  Port \(s.port)\n"
            if !username.isEmpty { block += "  User \(try quote(username))\n" }
            if !s.identityFile.isEmpty { block += "  IdentitiesOnly yes\n" }
            // Copy resolved auth and transport options so Host-specific settings survive aliasing.
            let inherited = ["identityagent", "identitiesonly", "forwardagent", "forwardx11", "preferredauthentications", "passwordauthentication", "pubkeyauthentication", "kbdinteractiveauthentication", "gssapiauthentication", "hostkeyalgorithms", "pubkeyacceptedalgorithms", "ciphers", "kexalgorithms", "macs", "userknownhostsfile", "globalknownhostsfile", "hostkeyalias", "addkeystoagent", "compression"]
            for key in inherited {
                for value in defaults.values[key] ?? [] {
                    guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw WindError.invalid("SSH 配置字段格式无效。") }
                    block += "  \(key) \(value)\n"
                }
            }
            if !s.identityFile.isEmpty {
                let path = try IdentityFile.resolve(s.identityFile)
                guard FileManager.default.isReadableFile(atPath: path) else { throw WindError.invalid("密钥文件不可读，请在连接设置中重新选择。") }
                block += "  IdentityFile \(try quote(path))\n"
            } else {
                for path in defaults.values["identityfile"] ?? [] {
                    let defaultNames = ["~/.ssh/id_rsa", "~/.ssh/id_ecdsa", "~/.ssh/id_ecdsa_sk", "~/.ssh/id_ed25519", "~/.ssh/id_ed25519_sk", "~/.ssh/id_xmss", "~/.ssh/id_dsa"]
                    let expanded = (path as NSString).expandingTildeInPath
                    if defaultNames.contains(path) && !FileManager.default.fileExists(atPath: expanded) { continue }
                    block += "  IdentityFile \(try quote(path))\n"
                }
            }
            let jumpMode = s.effectiveJumpMode(all: all)
            if jumpMode == .direct { block += "  ProxyJump none\n  ProxyCommand none\n" }
            if jumpMode == .system {
                if let proxy = defaults.first("proxyjump"), proxy != "none" {
                    guard !proxy.contains(where: { $0.isNewline || $0 == "\0" }) else { throw WindError.invalid("系统 SSH 跳板配置无效。") }
                    block += "  ProxyJump \(proxy)\n"
                } else if let proxy = defaults.first("proxycommand"), proxy != "none" {
                    guard !proxy.contains(where: { $0.isNewline || $0 == "\0" }) else { throw WindError.invalid("系统 SSH 代理配置无效。") }
                    block += "  ProxyCommand \(proxy)\n"
                }
            }
            if jumpMode == .session || jumpMode == .manual {
                guard !s.jump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WindError.invalid("请选择跳板机或填写跳板链。") }
                if s.jump.hasPrefix("unsupported:") { throw WindError.invalid("原会话代理尚未转换，请先在连接设置中指定跳板机。") }
                if jumpMode == .session, let parent = all.first(where: { $0.id == s.jump }) {
                    try visit(parent); block += "  ProxyJump \(alias(parent))\n"
                } else {
                    guard jumpMode == .manual else { throw WindError.invalid("跳板机会话已不存在，请重新选择。") }
                    let chain = s.jump.split(separator: ",", omittingEmptySubsequences: false)
                    guard !chain.isEmpty, chain.allSatisfy({ !$0.isEmpty }) else { throw WindError.invalid("跳板链格式无效。") }
                    for hop in chain {
                        let parts = hop.split(separator: "@", omittingEmptySubsequences: false)
                        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty }) else { throw WindError.invalid("跳板机格式应为 user@host:port。") }
                        if parts.count == 2 {
                            let user = String(parts[0])
                            guard user.range(of: "^[a-zA-Z0-9_.-]+$", options: .regularExpression) != nil, !user.hasPrefix("-") else { throw WindError.invalid("跳板机用户名无效。") }
                        }
                        let endpoint = String(parts.last!)
                        try safeHost(endpoint)
                        // Let OpenSSH parse bracketed IPv6, but reject invalid ports before launch.
                        if endpoint.hasPrefix("[") {
                            guard let end = endpoint.firstIndex(of: "]") else { throw WindError.invalid("IPv6 跳板机应使用 [地址]:端口。") }
                            let tail = String(endpoint[endpoint.index(after: end)...])
                            if !tail.isEmpty { guard tail.hasPrefix(":"), let port = Int(tail.dropFirst()), (1...65535).contains(port) else { throw WindError.invalid("跳板机端口无效。") } }
                        } else if endpoint.contains(":") {
                            let pieces = endpoint.split(separator: ":", omittingEmptySubsequences: false)
                            guard pieces.count == 2, !pieces[0].isEmpty, let port = Int(pieces[1]), (1...65535).contains(port) else { throw WindError.invalid("跳板机端口无效；IPv6 地址请加方括号。") }
                        }
                    }
                    block += "  ProxyJump \(s.jump)\n"
                }
            }
            blocks.append(block); active.remove(s.id); visited.insert(s.id)
        }
        try visit(session)
        // Specific entries come first. Global SSH preferences and aliases remain available for manual jumps.
        let homeConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path
        var config = blocks.joined(separator: "\n")
        config += "\nHost *\n  ServerAliveInterval 20\n  ServerAliveCountMax 3\n  ConnectTimeout 60\n  TCPKeepAlive yes\n  ControlMaster no\n  ControlPath none\n  StrictHostKeyChecking ask\n"
        config += "\nInclude \(try quote(homeConfig))\n"
        return ConnectionPlan(executable: sftp ? "/usr/bin/sftp" : "/usr/bin/ssh", arguments: ["-F", configPath] + (sftp ? [] : ["-tt"]) + [alias(session)], config: config)
    }
}
