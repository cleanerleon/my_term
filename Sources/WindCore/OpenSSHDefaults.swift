import Foundation

/// OpenSSH resolves its own config grammar (Include, Host, Match); no network connection is opened.
public struct OpenSSHDefaults {
    public var values: [String: [String]]
    public init(values: [String: [String]] = [:]) { self.values = values }
    public func first(_ key: String) -> String? { values[key]?.first }

    public static func resolve(_ session: Session) throws -> OpenSSHDefaults {
        let task = Process(); let output = Pipe(); let errors = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-G", "-o", "CanonicalizeHostname=no", "--", session.host]
        task.standardOutput = output; task.standardError = errors
        try task.run()
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit(); timeout.cancel()
        guard task.terminationStatus == 0 else {
            throw WindError.invalid("无法解析系统 SSH 配置，请检查 ~/.ssh/config。")
        }
        var values: [String: [String]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<space]).lowercased()
            let value = String(line[line.index(after: space)...])
            values[key, default: []].append(value)
        }
        return OpenSSHDefaults(values: values)
    }
}
