import Foundation
import Darwin

public struct HostKeyChange: Equatable {
    public let host: String
    public let fingerprint: String
    public let file: String
    public let line: Int

    public static func parse(_ output: String) -> HostKeyChange? {
        let text = output.replacingOccurrences(of: "\r", with: "")
        guard text.contains("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!") else { return nil }
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
                  let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<result.numberOfRanges).compactMap { Range(result.range(at: $0), in: text).map { String(text[$0]) } }
        }
        guard let fingerprint = match("^(SHA256:[A-Za-z0-9+/]{43}=?)\\.?$")?.first,
              let location = match("^Offending [A-Za-z0-9 -]+ key in (/.+):([0-9]+)$"), location.count == 2,
              let line = Int(location[1]), line > 0,
              let host = match("^Host key for (.+) has changed and you have requested strict checking\\.$")?.first,
              !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }) else { return nil }
        return HostKeyChange(host: host, fingerprint: fingerprint, file: location[0], line: line)
    }

    /// Check the reported line using OpenSSH itself, including hashed hosts and port syntax.
    public func removeOldKey(expectedContents: Data? = nil) throws -> URL {
        let url = URL(fileURLWithPath: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw WindError.invalid("主机记录不是当前用户拥有的普通文件，未更新。")
        }
        let original = try Data(contentsOf: url)
        if let expectedContents, original != expectedContents { throw WindError.invalid("确认期间主机记录已变化，未更新；请重新连接后确认。") }
        guard original.count < 16_000_000, let text = String(data: original, encoding: .utf8) else { throw WindError.invalid("主机记录无法读取，未更新。") }
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        task.arguments = ["-F", host, "-f", file]
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        try task.run()
        let matches = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        guard task.terminationStatus == 0, matches.split(separator: "\n").contains(where: {
            let value = $0.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("# Host ") && value.hasSuffix("found: line \(line)")
        }) else {
            throw WindError.invalid("主机记录已变化或不匹配，未更新；请重新连接后确认。")
        }
        var lines = text.components(separatedBy: "\n")
        guard line <= lines.count else { throw WindError.invalid("旧主机记录已不存在。") }
        lines.remove(at: line - 1)
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".windnative-" + UUID().uuidString + ".bak")
        try original.write(to: backup, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        guard try Data(contentsOf: url) == original else { throw WindError.invalid("主机记录被其他程序修改，未覆盖。") }
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: attributes[.posixPermissions] ?? 0o600], ofItemAtPath: file)
        return backup
    }
}
