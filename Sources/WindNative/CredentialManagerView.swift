import AppKit
import SwiftUI
import WindCore

struct CredentialManagerView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("认证配置").font(.headline)
                    Spacer()
                    Button { model.createCredential() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("新建认证")
                }.padding(16)
                List(selection: $model.selectedCredentialID) {
                    ForEach(model.authenticationProfiles) { profile in
                        HStack(spacing: 10) {
                            Image(systemName: profile.method.usesKey ? "key.fill" : "person.badge.key.fill").foregroundStyle(.cyan)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text((profile.username.isEmpty ? "系统用户" : profile.username) + " · " + profile.method.title).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).tag(profile.id)
                    }
                }.listStyle(.sidebar)
                Divider()
                Text("同一认证可供多个 SSH / SFTP 会话复用").font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
            }.frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
            VStack(spacing: 0) {
                if let profile = model.authenticationProfiles.first(where: { $0.id == model.selectedCredentialID }) {
                    CredentialEditor(model: model, original: profile).id(profile.id)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "key.horizontal").font(.system(size: 36)).foregroundStyle(.cyan)
                        Text("统一管理登录认证").font(.title3)
                        Text("创建用户名、密码或私钥配置，再在会话中选择使用。").font(.callout).foregroundStyle(.secondary)
                        Button("新建认证配置") { model.createCredential() }.buttonStyle(.borderedProminent)
                    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let issue = model.credentialIssue {
                    Divider()
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        ScrollView { Text(issue).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 80)
                        Button { model.credentialIssue = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }.padding(12)
                }
            }.frame(minWidth: 470)
        }
        .frame(minWidth: 760, minHeight: 570)
        .preferredColorScheme(.dark)
        .onAppear { if model.selectedCredentialID == nil { model.selectedCredentialID = model.authenticationProfiles.first?.id } }
        .toolbar {
            ToolbarItem {
                Button { model.migrateAuthentication() } label: { Label("导入 WindTerm 认证", systemImage: "square.and.arrow.down") }.disabled(model.isMigratingAuthentication).help("把尚未迁移的 WindTerm 会话认证导入 MyTerm")
            }
        }
    }
}

private struct CredentialEditor: View {
    @ObservedObject var model: AppModel
    let original: AuthenticationProfile
    @State private var draft: AuthenticationProfile
    @State private var password = ""
    @State private var passphrase = ""
    @State private var showPassword = false
    @State private var showPassphrase = false
    @State private var message: String?
    @State private var failed = false
    init(model: AppModel, original: AuthenticationProfile) {
        self.model = model; self.original = original; _draft = State(initialValue: original)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("编辑认证").font(.title2.weight(.medium))
                Spacer()
                Text("\(model.credentialUsage(original.id)) 个会话使用").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
            Form {
                TextField("名称", text: $draft.name)
                TextField("用户名", text: $draft.username, prompt: Text("例如 root / ubuntu"))
                Picker("认证方式", selection: $draft.method) {
                    ForEach(AuthenticationMethod.allCases, id: \.self) { method in Text(method.title).tag(method) }
                }
                if draft.method.usesPassword {
                    HStack {
                        if showPassword { TextField("登录密码", text: $password) }
                        else { SecureField("登录密码", text: $password) }
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }.buttonStyle(.borderless).help(showPassword ? "隐藏密码" : "显示密码")
                    }
                }
                if draft.method.usesKey {
                    HStack {
                        TextField("私钥文件", text: $draft.identityFile, prompt: Text("选择需要导入的私钥"))
                        Button("选择…") { chooseKey() }
                    }
                    Text(model.credentialStore.isManagedKey(draft.identityFile) ? "私钥已由 MyTerm 保管" : "保存时会导入私钥，原文件保持不变").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if showPassphrase { TextField("私钥口令", text: $passphrase, prompt: Text("无口令可留空")) }
                        else { SecureField("私钥口令", text: $passphrase, prompt: Text("无口令可留空")) }
                        Button { showPassphrase.toggle() } label: { Image(systemName: showPassphrase ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                    }
                }
                Text("密码和口令保存在加密认证库，库密钥存入 macOS 钥匙串。修改后将在下次连接时生效。").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            if let message { Text(message).font(.callout).foregroundStyle(failed ? Color.red : Color.green).padding(.horizontal, 22).padding(.bottom, 10) }
            HStack {
                Button("删除认证…", role: .destructive) { model.deleteCredential(original) }
                    .help("删除认证并清空相关会话的认证选择")
                Spacer()
                Button("保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut("s")
            }.padding(22)
        }
        .onAppear {
            do { let secrets = try model.credentialStore.credential(original.id).1; password = secrets.password ?? ""; passphrase = secrets.passphrase ?? "" }
            catch { failed = true; message = error.localizedDescription }
        }
    }
    private func chooseKey() {
        let panel = NSOpenPanel(); panel.title = "导入 SSH 私钥"; panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { draft.identityFile = url.path }
    }
    private func save() {
        do {
            try model.saveCredential(draft, password: password, passphrase: passphrase)
            if let saved = model.authenticationProfiles.first(where: { $0.id == original.id }) { draft = saved }
            NSApp.windows.first { $0.title == "认证管理" }?.performClose(nil)
        } catch { failed = true; message = error.localizedDescription }
    }
}
