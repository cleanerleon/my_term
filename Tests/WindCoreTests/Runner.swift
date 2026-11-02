import Foundation
import AppKit
import SwiftTerm
import WindCore
import Darwin

struct CheckFailure: Error, CustomStringConvertible { var description: String }
struct CheckSkip: Error { var reason: String; init(_ reason: String) { self.reason = reason } }
func expectTrue(_ condition: @autoclosure () throws -> Bool, _ message: String = "", file: String = #filePath, line: Int = #line) throws {
    guard try condition() else { throw CheckFailure(description: "\(file):\(line) assertion failed \(message)") }
}
func expectFalse(_ condition: @autoclosure () throws -> Bool, file: String = #filePath, line: Int = #line) throws {
    try expectTrue(try !condition(), file: file, line: line)
}
func expectEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, _ message: String = "", file: String = #filePath, line: Int = #line) throws {
    try expectTrue(try left() == right(), message, file: file, line: line)
}
func expectThrows<T>(_ body: @autoclosure () throws -> T, file: String = #filePath, line: Int = #line) throws {
    do { _ = try body() } catch { return }
    throw CheckFailure(description: "\(file):\(line) expected rejection")
}
func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckFailure(description: "unexpected nil") }; return value
}

final class PTYProbe: NSObject, LocalProcessTerminalViewDelegate {
    var ended = false
    var exitCode: Int32?
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { self.exitCode = exitCode; ended = true }
}

func checkPTYLifecycle() throws {
    _ = NSApplication.shared
    for index in 0..<5 {
        let probe = PTYProbe()
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.processDelegate = probe
        let directories = ["", FileManager.default.temporaryDirectory.path, "${HomeDir}", "~", "/"]
        let session = Session(kind: "Shell", host: "/bin/zsh", shellArguments: ["-c", "printf '\\033[32mPTY-OK-\(index) 中文\\033[0m\\n'; pwd -P; exit 7"], workingDirectory: directories[index])
        let plan = try ConnectionBuilder.build(session, all: [], configPath: "/unused")
        view.startProcess(executable: plan.executable, args: plan.arguments, currentDirectory: plan.directory)
        let deadline = Date().addingTimeInterval(5)
        while !probe.ended && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        try expectTrue(probe.ended, "PTY exit callback timed out")
        try expectEqual(probe.exitCode.map { ($0 >> 8) & 0xff }, 7)
        // Drain any output queued before the exit event.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let output = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "")
        try expectTrue(output.contains("PTY-OK-\(index) 中文"), "PTY output or UTF-8 rendering failed: \(String(reflecting: output.prefix(300)))")
        let expected = index == 1 ? FileManager.default.temporaryDirectory : index == 4 ? URL(fileURLWithPath: "/") : FileManager.default.homeDirectoryForCurrentUser
        let resolvedPath = realpath(expected.path, nil)
        let expectedPath = resolvedPath.map { String(cString: $0) } ?? expected.path
        free(resolvedPath)
        let lines = output.replacingOccurrences(of: "\r", with: "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        try expectTrue(lines.contains(expectedPath), "Shell cwd mismatch at case \(index): expected \(expectedPath), output \(String(reflecting: output.prefix(400)))")
    }
}

@main struct ChecksRunner {
    static func main() {
        let tests = WindCoreTests()
        let checks: [(String, () throws -> Void)] = [
            ("WindTerm fields and credential exclusion", tests.testImportsWindTermFieldsWithoutCredentials),
            ("Malformed JSON and duplicate UUID", tests.testInvalidRootAndDuplicateIDAreRejected),
            ("Shell argument quoting", tests.testShellArgumentsAreParsedWithoutExpansion),
            ("Jump session identity and port", tests.testProxyUUIDResolvesToSeparateIdentityAndPort),
            ("Jump cycle rejection", tests.testCyclicJumpChainFailsBeforeLaunch),
            ("Unknown proxy fails closed", tests.testUnconvertedProxyNeverFallsBackToDirectConnection),
            ("SSH config injection and invalid ports", tests.testMalformedFieldsCannotInjectSSHConfig),
            ("System OpenSSH config validation (offline)", tests.testGeneratedConfigurationAcceptedBySystemSSHWithoutNetwork),
            ("SFTP shares SSH route", tests.testSFTPUsesSameConnectionRoute),
            ("Missing key and unsupported protocol", tests.testUnreadableIdentityAndUnsupportedProtocolAreExplicitErrors),
            ("Installed WindTerm profile is unchanged", tests.testLocalInstalledProfileIsReadOnlyAndAllRowsRepresented),
            ("PTY output, Unicode, exit and repeated cleanup", checkPTYLifecycle),
            ("Real SSH jump + binary SFTP listing, upload, download and rename", checkLoopbackSSH),
            ("OpenSSH aliases and explicit override precedence", tests.testOpenSSHDefaultsSurviveGeneratedAliases),
            ("Nested session folders and subtree rename", tests.testNestedFoldersAndSubtreeRename),
            ("SHA3, PBKDF2 and WindTerm AES fixture", checkWindCryptography),
            ("Private SSH askpass channel and one-shot routing", checkSavedAuthenticationBroker),
            ("Installed WindTerm saved authentication (redacted)", checkInstalledWindAuthentication),
            ("Managed vault encryption, edit, reload and wrong-key preservation", checkManagedCredentialVault),
            ("Credential migration is deduplicated and independent of WindTerm", checkCredentialMigrationIndependence),
            ("Nested terminal panes, unique PTY ownership and divider collapse", checkTerminalLayout),
            ("Explicit direct/system/saved/manual jump modes and legacy compatibility", checkJumpModes),
            ("Jump and target use independent managed authentication", checkPerHopManagedAuthentication),
            ("Changed host key diagnostics and one-shot fingerprint approval", checkHostKeyChange)
        ]
        var failures = 0
        for (name, check) in checks {
            do { try check(); print("PASS \(name)") }
            catch let skip as CheckSkip { print("SKIP \(name): \(skip.reason)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(checks.count) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
