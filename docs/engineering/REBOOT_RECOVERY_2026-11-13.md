# 重启后的功能恢复：修改前分析（2026-11-13）

基线：`origin/main` `f3fa33e`。在独立工作区修复；原目录未提交改动保留。

## 七问

1. 根因：现场 beta.101 的首次 Accessibility/ListenEvent 查询发生于 20:46:44，系统 tccd 返回 `Failed to get code reference … 100024` 并按 extension 拒绝；WindowServer 的 CreateApplication 直到 20:46:47 才出现。系统授权开关开启，进程仍报告 AX=false。源码在 SwiftUI App.init 内构造全部模型，属性初始化就查询权限，功能随后也在初始化期间启动。窗口切换的 `tapHealthIsArmed` 又依赖旧的权限值，首次 false 后恢复路径不会重新查询。菜单入口还存在独立的冷启动依赖：opener 通过 StateObject autoclosure 创建、创建窗口回调仅在窗口 onAppear 安装；晚到的 creator 不消费 pending 请求。
2. 历史：`win-001-main-window-opener`、`menu-002-session-release-vs-action-dispatch`；滚轮 `8842bef` / `8012c8c` / `df44c24` 已增加重试，但未约束首次查询所处的应用启动阶段。Core 路径命中窗口规则，WindowSwitcher 未匹配历史路径时选择器升级完整安全集合。
3. 旧修复不足：测试使用可人工翻转的 trust bool，未覆盖在 AppKit 尚未完成启动时构造权限使用者；watchdog 的 mock 以 armed=true 起步，掩盖生产 host 把权限作为恢复前提；窗口测试只验证记录 noCreator，未验证 creator 晚到后真的创建窗口。
4. 影响：应用启动、已启用功能的启动顺序、主窗口内容懒加载、菜单/Dock/deep-link 入口、窗口切换 tap。配置键、签名 DR、菜单跟踪/动作存活规则保持原契约。
5. 必跑：选择器完整安全集合；重点 AppLifecycleTests、MainWindowOpenerTests、MainWindowContentStateTests、WindowSwitcherFirstPressTests、WindowSwitcherTests、SmoothScrollRecoveryTests、EventTapDenialTests、MenuBarOwnedMenuTests、AppPresenceTests、FeatureResourceLifecycleTests、ConfigurationSchemaContractTests。
6. 新增回归：启动通知前不构造模型、通知后下一轮只构造一次、晚创建/取消；真实 WindowSwitcherModel 在权限 false 时仍可恢复；creator 晚到、连续请求和通知入口覆盖；将覆盖加入索引。旧行为与新行为对照验证。
7. 实机：真实 Mac 重启/登录和 macOS 14/15/26 必须单列待验收。当前只读现场证据不能证明修改已通过重启验收；不退出、替换或重启用户当前 app，不更改 TCC。

## 证据边界

当前主线程采样在正常事件循环，未见全局卡死。签名 DR 符合仓库固定规则。独立正常系统环境 probe 显示 NSApplication.shared 本身并不是可证明的代码身份屏障，因此不采用仅提前调用 shared 的补丁，也不添加固定等待秒数。修改将以 didFinishLaunching 后的下一轮作为功能构造边界；是否消除系统重启时 tccd 的身份错误仍需重启验收。用户在界面检查后报告设置可打开；这发生在源码修改前，不能宣称菜单已修复。
