# MyTerm

MyTerm 是一个面向 macOS 的原生 SSH、终端和 SFTP 客户端，使用 SwiftUI、AppKit、SwiftTerm 和系统 OpenSSH 构建。项目目前处于早期开发阶段。

## 项目背景

项目起源于日常使用 WindTerm 管理多台服务器的需求。WindTerm 的会话管理方式很好用，但在 macOS 上遇到了应用重启和跳板连接不稳定的问题，因此希望开发一个更贴近 macOS 使用习惯的客户端，并尽可能复用已有的 WindTerm 配置。

MyTerm 是独立实现，不是 WindTerm 的官方版本，也不声称已经完整复刻 WindTerm。SSH 连接使用系统 OpenSSH；终端组件使用 SwiftTerm。WindTerm 原有问题的原因尚未确定，MyTerm 的实际稳定性仍需要更多使用验证。

## 功能

- 以文件夹管理 SSH 会话，支持搜索、拖动、编辑和嵌套分组。
- 支持本地 Shell、多标签、终端分屏、命令发送和断线后手动重连。
- 通过已保存的会话配置多级 SSH 跳板；每一跳使用自己的会话设置。
- 集中管理用户名、密码和私钥，并尝试从兼容的 WindTerm 配置迁移认证。
- 图形 SFTP 文件管理，支持目录浏览、上传、下载、重命名和删除。
- SSH 主机指纹发生变化时，显示新指纹供用户确认；确认后备份并更新旧记录，再重新连接。

## 安装

从 [Releases](https://github.com/cleanerleon/my_term/releases) 下载 `MyTerm.dmg`，打开后将 MyTerm 拖入 Applications。支持 macOS 13 及以上；首个构建针对 Apple Silicon。

当前安装包使用本地签名，**未经过 Apple 公证**。下载后 macOS 可能阻止打开，需在系统设置中根据实际提示处理。

## 数据与安全

为兼容旧版 WindNative，连接配置和加密认证库存放在 `~/Library/Application Support/WindNative`，原有钥匙串服务标识继续沿用。认证库密钥存入 macOS 钥匙串；私钥保存在应用的私有配置目录。请妥善保护并备份这些数据，不要将其提交到 Git 仓库。

首次运行可以读取 WindTerm 会话并尝试迁移兼容的认证。不同版本的配置格式可能有差异；启用 WindTerm 主密码的认证尚不支持自动解锁。未知代理配置不会自动退回直连。

## 构建与测试

需要 macOS 13 或更新版本，以及支持 Swift Package Manager 的开发工具。

```sh
./scripts/test.sh         # 自动检查与本地回环 SSH / SFTP 测试
./scripts/build-app.sh    # 生成 dist/MyTerm.app
./scripts/build-dmg.sh    # 生成 dist/MyTerm.dmg
```

首次构建需要下载 SwiftTerm。测试使用临时凭据和本地回环服务，不应将生成的截图、私钥、认证库或用户会话文件提交到仓库。

## 当前限制

不支持 Telnet、串口、ZMODEM、WindTerm 主密码解锁及完整的主题和布局迁移。图形 SFTP 暂不支持递归传输文件夹。网络、休眠唤醒和长期连接的稳定性仍需持续验证。

## 致谢

- [WindTerm](https://github.com/kingToolbox/WindTerm)：项目背景与配置兼容参考。
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)：终端组件。

第三方组件许可说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
