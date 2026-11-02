import SwiftUI
import AppKit
import WindCore

struct SessionEditor: View {
    @ObservedObject var model: AppModel
    let original: Session
    @State private var draft: Session
    @State private var portText: String
    @State private var jumpMode: JumpMode
    @State private var validationError: String?
    @Environment(\.openWindow) private var openWindow
    init(model: AppModel, original: Session) {
        self.model = model; self.original = original
        var initial = original; initial.jumpMode = original.effectiveJumpMode(all: model.sessions)
        _draft = State(initialValue: initial); _portText = State(initialValue: String(original.port))
        _jumpMode = State(initialValue: initial.jumpMode!)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.mint)
                Text(original.isImported ? "编辑连接" : "连接设置").font(.title2.bold())
                Spacer()
            }
            Form {
                TextField("名称", text: $draft.name)
                TextField("分组", text: $draft.group)
                LabeledContent("协议", value: draft.kind)
                TextField(draft.kind == "Shell" ? "Shell 路径" : "服务器", text: $draft.host)
                if draft.kind == "SSH" {
                    TextField("端口", text: $portText)
                    Picker("连接方式", selection: $jumpMode) {
                        ForEach(JumpMode.allCases.filter { $0 != .manual }, id: \.self) { mode in Text(mode.title).tag(mode) }
                        if jumpMode == .manual { Text("原有手动跳板链（保留）").tag(JumpMode.manual) }
                    }.onChange(of: jumpMode) { mode in
                        draft.jumpMode = mode
                        if mode == .session && !model.sessions.contains(where: { $0.id == draft.jump }) { draft.jump = "" }
                        if mode == .manual && model.sessions.contains(where: { $0.id == draft.jump }) { draft.jump = "" }
                    }
                    if jumpMode == .session {
                        Picker("跳板机", selection: $draft.jump) {
                            Text("请选择跳板机会话").tag("")
                            ForEach(model.sessions.filter { $0.kind == "SSH" && $0.id != draft.id }) { session in
                                Text("\(session.group) / \(session.name)").tag(session.id)
                            }
                        }
                    }
                    jumpPreview
                    HStack {
                        Picker("目标认证", selection: Binding(get: { draft.credentialProfileID ?? "" }, set: { draft.credentialProfileID = $0.isEmpty ? nil : $0 })) {
                            Text("系统 SSH 配置 / SSH Agent").tag("")
                            ForEach(model.authenticationProfiles) { profile in Text(profile.name).tag(profile.id) }
                        }
                        Button("认证…") { model.selectedCredentialID = draft.credentialProfileID; openWindow(id: "credentials") }
                    }
                } else if draft.kind == "Shell" {
                    TextField("工作目录", text: $draft.workingDirectory, prompt: Text("默认使用主目录"))
                    Text("Shell 参数保持导入值：\(draft.shellArguments.joined(separator: " "))").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let validationError { Text(validationError).font(.callout).foregroundStyle(.red) }
            Text("会话和认证由 MyTerm 保存；更新应用不会覆盖这些配置。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { model.editing = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { save(connect: false) }.disabled(model.isMigratingAuthentication)
                Button("保存并连接") { save(connect: true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.isMigratingAuthentication)
            }
        }.padding(24).frame(width: 580)
            .onChange(of: model.authenticationProfiles.map(\.id)) { ids in
                if let id = draft.credentialProfileID, !ids.contains(id) { draft.credentialProfileID = nil }
            }
    }
    @ViewBuilder private var jumpPreview: some View {
        if jumpMode == .direct {
            Text("直接连接目标服务器，不使用系统 SSH 配置中的跳板或代理。").font(.caption).foregroundStyle(.secondary)
        } else if jumpMode == .system {
            Text("继承 ~/.ssh/config 的 ProxyJump / ProxyCommand；系统配置未设置代理时直接连接。").font(.caption).foregroundStyle(.secondary)
        } else if jumpMode == .manual {
            Text("此连接保留已有跳板链；如需修改，请选择已保存的跳板机会话。").font(.caption).foregroundStyle(.secondary)
        } else {
            let result = routePreview
            VStack(alignment: .leading, spacing: 8) {
                Text("连接路径 · 从本机开始").font(.caption.weight(.semibold))
                if let issue = result.issue {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else {
                    ForEach(Array(result.sessions.enumerated()), id: \.offset) { index, session in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.cyan)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.name + (session.id == draft.id ? " · 目标" : " · 跳板")).font(.system(size: 11, weight: .medium))
                                Text("\(session.host):\(String(session.port))")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Text("跳板机使用其会话中保存的连接设置。SSH 与 SFTP 使用同一路径。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var routePreview: (sessions: [Session], issue: String?) {
        var target = draft; target.jumpMode = jumpMode; target.port = Int(portText) ?? draft.port
        do { return (try JumpSettings.chain(target, all: model.sessions.filter { $0.id != target.id } + [target]), nil) }
        catch { return ([], error.localizedDescription) }
    }
    private func save(connect: Bool) {
        draft.host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.jump = draft.jump.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { validationError = "请填写名称。"; return }
        if draft.group.isEmpty { draft.group = "我的连接" }
        if draft.kind == "SSH" {
            guard let port = Int(portText), (1...65535).contains(port) else { validationError = "端口必须为 1–65535。"; return }
            draft.port = port
        }
        draft.jumpMode = jumpMode
        if jumpMode == .system || jumpMode == .direct { draft.jump = "" }
        // Preserve legacy per-session credentials when only editing the route.
        // Selecting a different managed profile deliberately switches its source.
        if draft.credentialProfileID != original.credentialProfileID || draft.credentialProfileID != nil {
            draft.windAuthenticationEnabled = false
            draft.username = ""; draft.identityFile = ""
        }
        do {
            let all = model.sessions.filter { $0.id != draft.id } + [draft]
            if draft.kind == "SSH" { _ = try JumpSettings.chain(draft, all: all) }
            _ = try ConnectionBuilder.build(draft, all: all, configPath: "/unused")
            model.save(draft)
            if connect && model.editing == nil { model.connect(draft) }
        } catch { validationError = error.localizedDescription }
    }
}
