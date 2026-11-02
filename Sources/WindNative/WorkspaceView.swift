import SwiftUI
import AppKit
import SwiftTerm
import WindCore
import UniformTypeIdentifiers

private let terminalBackground = Color(red: 0.115, green: 0.115, blue: 0.12)

struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab
    func makeNSView(context: Context) -> TerminalContainer {
        let view = TerminalContainer(); view.show(tab.terminal); return view
    }
    func updateNSView(_ nsView: TerminalContainer, context: Context) { nsView.show(tab.terminal) }
}

/// SwiftUI can reuse a leaf when switching tabs. Always replace its actual AppKit child.
final class TerminalContainer: NSView {
    func show(_ terminal: NSView) {
        guard subviews.first !== terminal else { return }
        subviews.forEach { $0.removeFromSuperview() }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor), terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor), terminal.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if model.showSidebar { sidebar.frame(minWidth: 245, idealWidth: 300, maxWidth: 460) }
                VStack(spacing: 0) {
                    tabBar; Divider()
                    if model.currentTab != nil { breadcrumb; Divider() }
                    VSplitView {
                        terminalArea.frame(minHeight: 170)
                        if model.showBottomPanel { WorkspaceDock(model: model).frame(minHeight: 150, idealHeight: 205, maxHeight: 430) }
                    }
                    statusBar
                }.frame(minWidth: 520)
                if model.showInspector { inspector.frame(minWidth: 220, idealWidth: 255, maxWidth: 320) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { model.showSidebar.toggle(); model.saveWorkspace() } label: { Label("会话侧栏", systemImage: "sidebar.left") }
                Button { openWindow(id: "credentials") } label: { Label("认证管理", systemImage: "key.horizontal") }.help("管理用户名、密码和私钥")
                Button { model.localShell() } label: { Label("本地终端", systemImage: "terminal") }.help("本地终端 · ⌘T")
                Button { model.editing = Session() } label: { Label("新建连接", systemImage: "plus") }.help("新建连接 · ⌘N")
                Button { model.reconnect() } label: { Label("重新连接", systemImage: "arrow.clockwise") }.disabled(model.currentTab == nil)
                Menu {
                    Button("左右分屏") { model.splitTerminal(.columns) }
                    Button("上下分屏") { model.splitTerminal(.rows) }
                    Button("下一个窗格") { model.nextPane() }
                    Button("仅显示当前窗格") { model.unsplit() }
                } label: { Label("分屏", systemImage: "rectangle.split.2x1") }.disabled(model.currentTab == nil)
                Button { model.toggleBottom(.sender) } label: { Label("命令发送器", systemImage: "text.append") }
                Button { model.showInspector.toggle() } label: { Label("连接详情", systemImage: "sidebar.right") }
            }
        }
        .sheet(item: $model.editing) { session in SessionEditor(model: model, original: session) }
        .sheet(item: $model.folderEdit) { FolderEditor(model: model, edit: $0) }
        .alert("无法完成操作", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: model.activeTab) { _ in model.activeTabChanged(); focusTerminal() }
        .onChange(of: model.tabs.count) { _ in focusTerminal() }
    }
    private var terminalArea: some View {
        ZStack {
            terminalBackground
            if model.tabs.isEmpty { welcome }
            else if let layout = model.paneLayout { TerminalPaneGroup(layout: layout, model: model) }
        }
    }
    private func focusTerminal() {
        DispatchQueue.main.async {
            if let terminal = model.currentTab?.terminal { terminal.window?.makeFirstResponder(terminal) }
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebarTab("会话", symbol: "square.fill", selected: model.sidebarMode == .sessions) { model.sidebarMode = .sessions }
                sidebarTab("文件管理器", symbol: "folder", selected: model.sidebarMode == .files) { model.selectFilesMode() }
                Spacer(minLength: 0)
                Menu {
                    Button("认证管理…") { openWindow(id: "credentials") }
                    Divider()
                    Button("新建文件夹…") { model.folderEdit = FolderEdit() }
                    Button("导入 WindTerm 配置…") { model.chooseImport() }
                    Button("重新读取原配置") { model.refresh() }
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).fixedSize().padding(.trailing, 10)
            }.frame(height: 32).background(Color.primary.opacity(0.025))
            Divider()
            if model.sidebarMode == .sessions {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("筛选会话", text: $model.query).textFieldStyle(.plain)
                    if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") } }
                }.font(.system(size: 12)).padding(12)
                Divider()
                List(selection: $model.selectedSession) {
                    ForEach(model.folderTree) { folder in SessionFolderView(folder: folder, model: model) }
                }.listStyle(.sidebar)
                Divider()
                HStack {
                    Text("\(model.sessions.count) 个会话").foregroundStyle(.secondary)
                    Spacer()
                    Button { model.folderEdit = FolderEdit() } label: { Image(systemName: "folder.badge.plus") }.help("新建文件夹")
                    Button { model.editing = Session() } label: { Image(systemName: "plus") }.help("新建连接")
                }.font(.system(size: 11)).padding(12)
            } else {
                fileSidebar
            }
        }.buttonStyle(.borderless).background(Color(nsColor: .controlBackgroundColor))
    }
    private func sidebarTab(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(selected ? Color.cyan : .secondary)
                Text(title).font(.system(size: 12, weight: .semibold))
            }.padding(.horizontal, 13).frame(height: 32).background(selected ? Color.primary.opacity(0.08) : .clear)
        }
    }
    @ViewBuilder private var fileSidebar: some View {
        if let browser = model.currentBrowser {
            FileBrowserView(browser: browser)
                .id(browser.session.id)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "folder.badge.gearshape").font(.system(size: 32)).foregroundStyle(.secondary)
                Text("选择 SSH 会话浏览文件").font(.system(size: 13))
                Menu("选择服务器") {
                    ForEach(model.sessions.filter { $0.kind == "SSH" }) { session in
                        Button("\(session.group) / \(session.name)") { model.openFiles(session) }
                    }
                }.menuStyle(.borderedButton)
                Text("也可在会话上右键，选择打开文件管理器。").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var breadcrumb: some View {
        HStack(spacing: 9) {
            if let tab = model.currentTab {
                Image(systemName: tab.session.kind == "Shell" ? "terminal" : "lock.shield").foregroundStyle(.cyan)
                Text(tab.session.kind.lowercased())
                Image(systemName: "chevron.right").font(.system(size: 8))
                Text(tab.session.group)
                Image(systemName: "chevron.right").font(.system(size: 8))
                Text(tab.session.name).foregroundStyle(.primary)
                Spacer()
                Button { model.splitTerminal(.columns) } label: { Image(systemName: "rectangle.split.2x1") }.help("左右分屏")
                Button { model.splitTerminal(.rows) } label: { Image(systemName: "rectangle.split.1x2") }.help("上下分屏")
                Button { model.disconnectCurrent() } label: { Image(systemName: "stop") }.disabled(!tab.running).help("断开当前终端")
                if tab.session.kind == "SSH" {
                    Button { model.openFiles(tab.session) } label: { Label("SFTP", systemImage: "folder") }.buttonStyle(.borderless).help("打开左侧文件管理器")
                }
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 26).background(Color.primary.opacity(0.025))
    }
    private var tabBar: some View {
        HStack(spacing: 0) {
            Button { selectAdjacentTab(-1) } label: { Image(systemName: "chevron.left").frame(width: 27, height: 31) }
                .buttonStyle(.plain).help("上一个标签")
                .disabled(model.activeTab == model.tabs.first?.id || model.tabs.isEmpty)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(model.tabs) { tab in
                            TabButton(tab: tab, selected: model.activeTab == tab.id, select: { model.activeTab = tab.id }, close: { model.close(tab) })
                                .id(tab.id)
                                .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
                                .onDrop(of: [.utf8PlainText], isTargeted: nil) { providers in
                                    guard let provider = providers.first else { return false }
                                    _ = provider.loadObject(ofClass: String.self) { value, _ in
                                        guard let value, let source = UUID(uuidString: value) else { return }
                                        Task { @MainActor in model.reorderTab(source, before: tab.id) }
                                    }
                                    return true
                                }
                                .contextMenu {
                                    Button("复制会话标签") { model.duplicateTab(tab) }
                                    Button("重命名标签…") { model.renameTab(tab) }
                                    Menu("标签颜色") {
                                        ForEach(["cyan", "pink", "green", "orange", "purple"], id: \.self) { name in
                                            Button(tabColorName(name)) { tab.tabColor = name }
                                        }
                                    }
                                    Divider()
                                    Button("关闭标签") { model.close(tab) }
                                    Button("关闭右侧所有标签") { model.closeTabsToRight(of: tab) }
                                        .disabled(model.tabs.last?.id == tab.id)
                                }
                        }
                    }
                }
                .onChange(of: model.activeTab) { id in
                    guard let id else { return }
                    // Dispatch after insertion/layout so newly created and keyboard-selected tabs become visible.
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Button { selectAdjacentTab(1) } label: { Image(systemName: "chevron.right").frame(width: 27, height: 31) }
                .buttonStyle(.plain).help("下一个标签")
                .disabled(model.activeTab == model.tabs.last?.id || model.tabs.isEmpty)
            Menu {
                ForEach(model.tabs) { tab in
                    Button { model.activeTab = tab.id } label: {
                        if model.activeTab == tab.id { Label(tab.title, systemImage: "checkmark") }
                        else { Text(tab.title) }
                    }
                }
            } label: { Image(systemName: "list.bullet").frame(width: 30, height: 31) }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.tabs.isEmpty)
                .help("查看所有标签")
            Button { model.localShell() } label: { Image(systemName: "plus").frame(width: 30, height: 31) }
                .buttonStyle(.plain).help("新建本地终端")
        }.frame(height: 32).background(Color(nsColor: .controlBackgroundColor))
    }
    private func selectAdjacentTab(_ direction: Int) {
        guard let current=model.tabs.firstIndex(where: {$0.id == model.activeTab}) else {return}
        let next=current + direction
        guard model.tabs.indices.contains(next) else {return}
        model.activeTab=model.tabs[next].id
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.mint).frame(width: 4, height: 20)
                Text("SSH · SFTP · SHELL").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.mint)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("MyTerm").font(.system(size: 28, weight: .medium))
                Text("熟悉的会话，全新的原生体验。\n从左侧选择服务器，或打开一个本地终端。").font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.5)).lineSpacing(6)
            }
            HStack(spacing: 12) {
                Button { model.localShell() } label: { Label("打开本地终端", systemImage: "terminal").padding(.horizontal, 6).padding(.vertical, 5) }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                Button { model.editing = Session() } label: { Label("新建 SSH", systemImage: "plus").padding(.horizontal, 6).padding(.vertical, 5) }.buttonStyle(.bordered)
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.vertical, 6)
            HStack(alignment: .top, spacing: 38) {
                feature("\(model.sessions.filter { $0.kind == "SSH" }.count)", "SSH 会话")
                feature("OpenSSH", "系统连接引擎")
                feature("ProxyJump", "支持多级跳板")
            }
            Text("⌘T  本地终端     ⌘N  新建连接     ⌘O  导入配置").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.3)).padding(.top, 16)
        }.padding(40).frame(maxWidth: 670, alignment: .leading).foregroundStyle(.white)
    }
    private func feature(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value).font(.system(size: 19, weight: .medium, design: .monospaced))
            Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        }
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("连接详情").font(.headline)
                if let session = model.selected {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: session.kind == "Shell" ? "terminal.fill" : "server.rack").font(.system(size: 28)).foregroundStyle(.mint).padding(.bottom, 4)
                        Text(session.name).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                        Text(session.group).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    detail("协议", session.kind)
                    detail("服务器", session.host)
                    if session.kind == "SSH" {
                        detail("端口", String(session.port))
                        detail("认证配置", model.profileName(session.credentialProfileID))
                        detail("用户名", model.authenticationProfiles.first(where: { $0.id == session.credentialProfileID })?.username ?? (session.username.isEmpty ? "系统默认" : session.username))
                        detail("认证方式", model.authenticationProfiles.first(where: { $0.id == session.credentialProfileID })?.method.title ?? "SSH Agent / 系统配置")
                        detail("连接路径", jumpDescription(session))
                    }
                    Button { model.connect(session) } label: { Label("连接会话", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(!session.supported)
                    HStack {
                        Button("编辑设置") { model.editing = session }
                        if session.kind == "SSH" { Button("SFTP") { model.openFiles(session) } }
                    }.buttonStyle(.bordered)
                    if !session.warnings.isEmpty {
                        Divider()
                        ForEach(session.warnings, id: \.self) { warning in
                            Label { Text(warning).font(.system(size: 11)).lineSpacing(4) } icon: { Image(systemName: "info.circle") }.foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "cursorarrow.click.2").font(.system(size: 30)).foregroundStyle(.tertiary).padding(.top, 20)
                    Text("选择一个会话").font(.system(size: 15, weight: .medium))
                    Text("查看连接信息，编辑用户名、密钥与跳板机。双击会话即可连接。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                }
                Divider()
                Label("每个终端独立运行", systemImage: "square.stack.3d.up").font(.system(size: 11, weight: .medium))
                Text("连接退出时保留终端输出，可手动重新连接。使用程序统一管理的认证配置，缺少凭据时再交互输入。").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private func jumpDescription(_ session: Session) -> String {
        switch session.effectiveJumpMode(all: model.sessions) {
        case .direct: return "直接连接"
        case .system: return "跟随系统 SSH 配置"
        case .manual: return "手动跳板：" + session.jump
        case .session:
            if let route = try? JumpSettings.chain(session, all: model.sessions) { return "本机 → " + route.map(\.name).joined(separator: " → ") }
            return "跳板配置无效，请编辑连接"
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle().fill(model.currentTab?.running == true ? Color.mint : Color.secondary).frame(width: 5, height: 5)
            Text(model.isMigratingAuthentication ? "正在接管认证配置…" : model.currentTab?.status ?? "就绪")
            Spacer()
            Button { model.toggleBottom(.sessions) } label: { Text("活动会话") }.buttonStyle(.borderless)
            Button { model.toggleBottom(.transfers) } label: { Text("传输") }.buttonStyle(.borderless)
            Text("UTF-8"); Text("·"); Text("xterm-256color"); Text("·"); Text("\(model.tabs.count) 个终端")
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 26)
    }
}

struct TabButton: View {
    @ObservedObject var tab: TerminalTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(tab.running ? tabColor(tab.tabColor) : Color.secondary).frame(width: 7, height: 7)
            Text(tab.title).font(.system(size: 11)).lineLimit(1)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }.buttonStyle(.plain).help("关闭标签")
        }.padding(.horizontal, 12).frame(height: 31).frame(minWidth: 130, maxWidth: 230)
            .background(selected ? Color.primary.opacity(0.08) : .clear)
            .overlay(alignment: .top) { if selected { tabColor(tab.tabColor).frame(height: 2) } }
            .contentShape(Rectangle())
            .background(MiddleClickHandler(action: close))
            .gesture(TapGesture(count: 2).onEnded { close() }.exclusively(before: TapGesture().onEnded { select() }))
            .help("点击切换，双击或中键关闭标签")
    }
}

/// Listen only while the pointer is inside this tab; do not intercept left/right clicks.
private struct MiddleClickHandler: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> MiddleClickView {let view=MiddleClickView();view.action=action;return view}
    func updateNSView(_ view: MiddleClickView, context: Context) {view.action=action}
    static func dismantleNSView(_ view: MiddleClickView, coordinator: ()) {view.removeMonitor()}
}
private final class MiddleClickView: NSView {
    var action: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? {nil}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else {return}
        monitor=NSEvent.addLocalMonitorForEvents(matching:.otherMouseDown) {[weak self] event in
            guard let self,event.buttonNumber == 2,event.window === self.window,
                  !self.isHiddenOrHasHiddenAncestor,self.visibleRect.contains(self.convert(event.locationInWindow,from:nil)) else {return event}
            self.action?();return nil
        }
    }
    func removeMonitor() {if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}}
    deinit {removeMonitor()}
}

func tabColor(_ name: String) -> SwiftUI.Color {
    switch name { case "pink": return .pink; case "green": return .green; case "orange": return .orange; case "purple": return .purple; default: return .cyan }
}
func tabColorName(_ name: String) -> String {
    switch name { case "pink": return "粉色"; case "green": return "绿色"; case "orange": return "橙色"; case "purple": return "紫色"; default: return "青色" }
}

struct TerminalPaneGroup: View {
    let layout: TerminalLayout
    @ObservedObject var model: AppModel
    var body: some View { content(layout) }
    private func content(_ node: TerminalLayout) -> AnyView {
        switch node {
        case .terminal(let id):
            guard let tab = model.tabs.first(where: { $0.id == id }) else { return AnyView(Color.clear) }
            return AnyView(TerminalPane(tab: tab, model: model).id(tab.id))
        case .split(let axis, let first, let second):
            if axis == .columns { return AnyView(HSplitView { content(first); content(second) }) }
            return AnyView(VSplitView { content(first); content(second) })
        }
    }
}

private struct TerminalPane: View {
    @ObservedObject var tab: TerminalTab
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if (model.paneLayout?.terminals.count ?? 0) > 1 {
                HStack(spacing: 7) {
                    Rectangle().fill(tabColor(tab.tabColor)).frame(width: 5, height: 5)
                    Text(tab.title).lineLimit(1)
                    Text(tab.status).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { model.activeTab = tab.id; model.unsplit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("仅显示此窗格")
                }.font(.system(size: 10)).padding(.horizontal, 9).frame(height: 24)
                    .background(model.activeTab == tab.id ? Color.cyan.opacity(0.1) : Color.white.opacity(0.03))
                    .contentShape(Rectangle()).onTapGesture { model.activeTab = tab.id }
            }
            TerminalHost(tab: tab).padding(5)
                .simultaneousGesture(TapGesture().onEnded { model.activeTab = tab.id })
        }.frame(minWidth: 180, minHeight: 100)
            .overlay { Rectangle().stroke(model.activeTab == tab.id && (model.paneLayout?.terminals.count ?? 0) > 1 ? Color.cyan.opacity(0.55) : .clear, lineWidth: 1).allowsHitTesting(false) }
    }
}
