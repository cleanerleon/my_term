# WindTerm 安装包分析与 WindNative 界面实现

目标：还原本机 WindTerm 的主要工作区和交互，使用 SwiftUI/AppKit 独立实现，保留 WindNative 已有的认证与配置管理。用户选择优先界面与交互。本轮没有替换系统 OpenSSH。

## 证据和边界

分析对象为 `/Applications/WindTerm.app`。可复核的文件路径、SHA-256、字节数、动态库依赖和动作定义位置收录在 [安装包证据索引](evidence/windterm-installation.json)。证据由本机 `file`、`otool -L` 和资源文本检查取得，不是 REA 反编译结果。

- **观察 E01**：主程序是 x86_64 Mach-O；动态依赖包含 Qt 5.15、AppKit、Metal 和 libssh.4。不能仅凭 Intel 架构或 Qt 依赖判断重启原因。
- **观察 E02**：`terminal/configs/menu.config` 定义 Session、Edit、Search、Selection、Goto、View、Mode、Tool、Window、Help 等菜单以及 Explorer/Filer/Sender/Session/Transfer 停靠面板。
- **观察 E03**：`global/wind.actions` 中找到 526 个按资源格式锚定的动作定义；不是严格 JSON，因此仅按动作边界读取文本，没有执行其脚本。`Window.SplitViewHorizontally` 声明向右分屏，`Window.SplitViewVertically` 声明向下分屏。动作声明不证明其闭源实现细节。
- **观察 E04**：随包动作包含会话复制、标签改名、标签颜色、重新打开关闭视图以及命令发送器启动/停止/增删操作。
- **观察 E05**：菜单和工具栏声明远程文件后退、前进、上级目录、刷新与目录历史入口。
- **观察 E06**：随包 `session.config` 的 SSH 指纹检查默认开启，终端类型为 `xterm-256color`，包含 20 秒连接超时、60 秒保活等字段。WindNative 原有的更短保活参数保持独立，不将资源默认值冒充用户的实际连接设置。
- **工具检查 E07**：REA CLI 6.7.0 的 doctor 检查发现 Codex 注册缺失/未对齐，且没有可用 Hopper、Ghidra 或 IDA provider。本轮没有修改 Codex 配置，也没有安装反编译引擎。没有伪造 REA Evidence ID。

先前已实现的会话和认证解码继续使用原逻辑；本轮没有重新导入、重新合并或改写用户的原始 WindTerm 文件。分析记录不包含用户密码、私钥或服务器终端输出。

## 问题清单与实现对应

| 问题 | 证据与状态 | WindNative 行为 |
| --- | --- | --- |
| 工作区由哪些区域构成？ | E02，主要区域已确认 | 会话/文件侧栏、多标签终端、路径栏、状态栏、可切换的底部面板 |
| 分屏方向和焦点如何呈现？ | E03，声明已确认；原闭源调度未知 | 左右/上下嵌套分屏，可拖动分隔条；当前窗格有边框与标题提示 |
| 分屏是否复用连接？ | 原程序完整语义未确认 | 设计选择：每个新窗格新建独立 PTY/连接，同一 PTY 只挂载到一个视图 |
| 标签和会话有哪些操作？ | E04，入口已确认 | 复制、标签改名/着色/拖动排序、最近关闭标签重开、复制保存的会话配置 |
| 如何组织辅助面板？ | E02/E04，入口已确认 | 命令发送器、活动会话列表、跨服务器传输列表，支持显隐与高度调整 |
| 命令如何发送？ | E04，仅入口可确认 | 设计选择：仅发往当前窗格；多行内容转换为终端回车，可显式追加末尾回车；不自动广播或记录历史 |
| 文件路径如何导航？ | E05，入口已确认 | 成功导航后记录规范路径；支持前进、后退和目录历史，失败不污染历史 |
| 原程序为何重启、跳转异常？ | **未解决** | 没有匹配的 WindTerm 崩溃报告或已定位的故障调用栈，不能声称修复原程序原因 |
| 是否已恢复闭源 SSH 与终端内核？ | **未解决/本轮未做** | SwiftTerm + OpenSSH + 自有 SFTP 客户端；未声称是 WindTerm 内核移植 |

## 实现和验证

- `Sources/WindCore/TerminalLayout.swift`：嵌套分屏模型、唯一叶节点、关闭后自动合并分隔条。
- `Sources/WindNative/WorkspaceView.swift`：原生分屏视图、焦点提示、工具栏和标签操作。
- `Sources/WindNative/WorkspaceDock.swift`：命令编辑/常用命令、活动会话、传输列表。
- `Sources/WindNative/AppModel.swift`：独立进程生命周期、焦点切换、隐藏终端保留、常用命令与字体/面板状态保存。
- `Sources/WindNative/RemoteBrowser.swift`：规范路径与成功导航历史。
- `Tests/WindCoreTests/TerminalLayoutChecks.swift`：重复挂载拒绝、嵌套拆分、叶节点替换和关闭合并。
- 应用级 smoke：隔离配置与合成凭据，实际 PTY 定向发送中文命令，确认另一窗格未收到；验证常用命令显式保存、三窗格挂载、隐藏终端存活及 SFTP 后退/前进。生成的截图可能包含本机用户名和路径，因此不纳入版本控制。

## 尚未覆盖

完整的 Qt 布局配置迁移、任意浮动停靠、多窗口视图迁移、终端行号与命令折叠、同步广播输入、周期发送器、原主题/快捷键配置导入、Telnet/Serial/ZMODEM，以及闭源内核的反编译和故障根因分析。当前产物是依据安装包证据扩展的原生实现，不能称为 WindTerm 的全功能等价版本。

## 标签与跳板回归修复

- 标签问题根因：SwiftUI 复用终端叶视图时，原 `TerminalHost.updateNSView` 为空，仍显示旧 AppKit 子视图。现在容器更新时明确替换子视图，同时为窗格绑定终端 UUID。应用级检查新建不同输出的第二标签，来回切换三轮并核对实际窗口归属，避免只测模型 ID。
- 标签双击关闭沿用原有关闭流程：运行中的连接仍需确认，结束的标签直接关闭。
- 连接方式显式区分系统继承、直接连接、已保存跳板和手动链。直接连接输出 `ProxyJump none` 与 `ProxyCommand none`；旧会话未设置方式时兼容原行为。
- 已保存的跳板链提供逐跳地址、端口、用户名与认证预览，拒绝循环、丢失会话和非 SSH 跳板。SFTP 重连时取得最新跳板设置，不中断正在进行的传输。
- 回环 sshd 按目标端口与跳板端口要求不同私钥，验证单级/两级跳转、SSH、SFTP，并在删除原始私钥后使用 WindNative 托管副本再次验证。合成密码检查覆盖每一跳的认证路由及直接连接不读取跳板凭据。
