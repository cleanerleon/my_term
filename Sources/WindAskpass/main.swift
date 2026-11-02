import AppKit
import Darwin
import WindCore

// Closing/cancelling the SFTP connection must also dismiss a pending password dialog.
let parent = getppid()
guard parent > 1 else { exit(1) }
let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
parentWatch.setEventHandler { exit(1) }
parentWatch.resume()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
if let response = AuthenticationBroker.savedResponse(prompt: prompt) {
    FileHandle.standardOutput.write(Data((response + "\n").utf8)); exit(0)
}
let confirmation = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] == "confirm"
    || prompt.lowercased().contains("yes/no")
let alert = NSAlert()
alert.messageText = confirmation ? "确认 SSH 主机身份" : "SSH 身份验证"
alert.informativeText = prompt.isEmpty ? "请输入 SSH 密码或私钥口令。" : String(prompt.prefix(4096))
alert.addButton(withTitle: confirmation ? "信任并继续" : "连接")
alert.addButton(withTitle: "取消")
let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
if !confirmation { alert.accessoryView = field; alert.window.initialFirstResponder = field }
application.activate(ignoringOtherApps: true)
let response = alert.runModal()
guard response == .alertFirstButtonReturn else { exit(1) }
let answer = confirmation ? "yes" : field.stringValue
guard !answer.contains("\n") && !answer.contains("\0") else { exit(1) }
FileHandle.standardOutput.write(Data((answer + "\n").utf8))
field.stringValue = ""
exit(0)
