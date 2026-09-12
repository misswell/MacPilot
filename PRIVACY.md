# MacPilot 隐私政策 / Privacy Policy

最后更新 / Last updated: 2026-09-12

MacPilot(含 macOS 主应用与 iOS 端 MacPilot Remote,下称"本应用")是一款本地工具:自动管理容易分心的应用,并支持用 iPhone 遥控 Mac 的锁屏、黑屏与解锁。

MacPilot (including the macOS app and the iOS app MacPilot Remote, "the app") is a local tool: it auto-manages distracting apps and lets you lock, blank and unlock your Mac from your iPhone.

## 我们不收集任何数据 / We collect no data

- 本应用没有开发者自建服务器,所有通信都在你自己的 iPhone 与 Mac 之间直连完成(局域网或蓝牙)。
- 本应用不嵌入任何统计分析、崩溃上报、广告或追踪 SDK。
- 我们不会获取、传输、存储或分享任何个人信息。

- The app has no developer-operated server. All communication happens directly between your own iPhone and your own Mac over the local network or Bluetooth.
- The app embeds no analytics, crash reporting, advertising or tracking SDKs.
- We never access, transmit, store or share any personal information.

## 数据存储 / Data storage

- 配对信息(设备标识与配对密钥)只保存在你的设备本地:iPhone 端存于 iOS 钥匙串,Mac 端存于 macOS 钥匙串。删除应用或移除配对即随之删除。
- Mac 解锁密码(可选功能)只保存在 Mac 的钥匙串中,永远不会离开你的 Mac。
- 应用设置保存在本机的用户默认设置中。运行时配置文件保存在本机 `~/Library/Application Support/MacPilot/`。

- Pairing information (device identity and pairing keys) is stored only on your devices: on the iPhone in the iOS Keychain, on the Mac in the macOS Keychain. Deleting the app or removing a pairing deletes them.
- The Mac unlock password (optional feature) is stored only in the Mac's Keychain and never leaves your Mac.
- App settings live in local user defaults; the runtime config file lives at `~/Library/Application Support/MacPilot/` on your Mac.

## 系统权限 / System permissions

- 本地网络与蓝牙:仅用于发现并连接你自己的 Mac。
- 辅助功能(macOS):仅用于执行锁屏、黑屏、解锁与关闭分心应用窗口等操作。
- 你可以随时在系统设置中撤销这些权限。

- Local Network and Bluetooth are used only to discover and connect to your own Mac.
- Accessibility (macOS) is used only to perform actions such as locking, blanking, unlocking and closing distracting app windows.
- You can revoke these permissions at any time in System Settings.

## 第三方服务 / Third-party services

本应用不依赖任何第三方云服务。若你通过 GitHub 获取更新或提交 Issue,其数据处理适用 GitHub 的隐私政策。

The app does not rely on any third-party cloud service. If you obtain updates or file issues via GitHub, GitHub's privacy policy applies to that interaction.

## 联系方式 / Contact

如有隐私方面的疑问,请通过 GitHub Issues 联系:
For privacy questions, reach us via GitHub Issues:

<https://github.com/misswell/MacPilot/issues>
