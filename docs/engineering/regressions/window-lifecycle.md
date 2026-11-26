# window-lifecycle — 主窗口与 AppKit 生命周期

规则：`win-001-main-window-opener`（confirmed-recurring，critical）。证据与修复链见 [../REGRESSION_CATALOG.md](../REGRESSION_CATALOG.md) A1/A2。

## 不变量

**打开主窗口必须逃离菜单跟踪循环，并且永远留下一条创建窗口的路。**

- `MainWindowOpener` 立即加载内容（窗口不能闪空），但在下一个 run-loop turn 才显示：在状态菜单跟踪循环内把窗口排到前面，可能随循环结束被撤销。
- 它先 raise 被持有的 `NSWindow`，然后在激活之前调用 `orderFrontRegardless()`——macOS 14+ 的激活是协作式的，激活被拒也必须留下可见窗口，而不是死菜单项。
- 找不到可用窗口的请求走 scene 的 `openWindow(id: "main")`，**绝不**落入没有东西去消费（drain）它的 `pendingRequest` 标志（那个静默死路正是「菜单 › 设置没反应」反复出现的原因）。
- 关窗后的内容保持未加载，直到下次打开；每个结果写入 `DiagnosticLog` 的 `MainWindow` 通道，下次失败有证据。

禁止：

- 把 `makeKeyAndOrderFront` + `orderFrontRegardless` 换成 `NSRunningApplication.activate`（LSUIElement 进程不会那样把 scene 窗口排到前面）。
- 从菜单 action 同步抬窗。
- 引入任何无人消费的 pending 标志位。

## 历史证据

`5ecdb66`（09-28）→ `8d8daa6` → Revert `9d71f61` → `42453ac`（10-29）→ `d080766`（10-30，误诊）→ `dc224ff`（10-31，真正根因在菜单侧，见 menu-bar-lifecycle.md）。五次修复、一次 Revert、一次修错模块——先读协议再动手的典型反面教材。

## 必跑测试

`MainWindowOpenerTests`、`MainWindowContentStateTests`、`WindowFocusServiceTests`、`WindowSwitcherTests`、`AppLifecycleTests`。

## 人工验收

- 关闭主窗口后分别从菜单「设置」、Dock 图标、Finder 深链重新打开，连续关闭重开多次。
- 即使 macOS 拒绝前台激活，`orderFrontRegardless` 也必须让窗口可见。

## 登录启动边界（win-002-login-startup-readiness）

- `MacPilotApp` 只建立启动观察者；`MacPilotAppServices` 在 `didFinishLaunching` 后下一 main-queue turn 才构造模型。模型属性初始化也会查询权限，因此只延后 feature.start 不足以保护第一次 TCC 请求。正常晚创建时同样只构造一次，终止/释放取消尚未执行的构造。
- `MainWindowOpener` 在 `App.init` 即创建并持在进程级 `StateObject` 中（它不查询任何权限），只有功能模型与界面经由 `AppLaunchBootstrap` 延后。创建场景的动作由 Commands 的首次求值安装，不依赖窗口先出现；窗口的 onAppear 只作补充。creator 晚到时消费 pending 请求，重复安装不得重复开窗。
- 冷启动经 URL 打开时，`application(_:open:)` 早于 `didFinishLaunching`，而模型与其深链观察者在其后一轮才存在：`AppDelegate` 必须缓冲 URL，并在模型构造后重放一次（之后不再缓冲）。
- `WindowSwitcherModel.tapHealthIsArmed` 只看运行意图；首次 AX=false 不是关闭功能。恢复路径必须继续调用实际权限检查；持续失败只记录一次，关闭功能立即停止。
- `MainWindow` 的打开结果必须在 Release 诊断级别也能落盘，否则现场无法区分 action 丢失与 window 创建失败。
- 自动回归：`AppLifecycleTests`、`MainWindowOpenerTests`、`WindowSwitcherFirstPressTests`、`SmoothScrollRecoveryTests`。现场 tccd 100024 与修复边界见 [启动分析](../REBOOT_RECOVERY_2026-11-13.md)；真实重启验收仍须另做。

## 安全键盘输入期间的窗口切换（win-003-secure-input-switcher）

- 系统可以在监听器仍启用时停止发送键盘事件。检查监听健康时也要读取安全输入状态，覆盖同一应用内开始或结束保护的情况。沿用功能自己的定期检查和应用激活、唤醒入口。停用功能时清除状态。
- 观察到保护开始时，丢弃可能已失去按键释放事件的快捷键会话。保留鼠标会话和窗口筛选、排序、置前路径。下一次收到 ⌥Tab 时重新确认状态，恢复提示无需等待下一次定期检查。
- 原生菜单打开时读取当前状态，然后生成固定快照。点击鼠标切换在菜单跟踪结束后显示面板。图标与首页使用同一警告列表，设置页说明暂停原因。
- 通过公开的 `IsSecureEventInputEnabled` 查询系统状态。发布版为进入和退出各记录一条诊断。保持 macOS 键盘输入保护。
- 自动回归覆盖启用着的监听器、同应用内的保护转换、未完成快捷键、鼠标会话、停用清理及双语告警。真机用测试密码框验证原生菜单和解除保护后的第一轮 ⌥Tab。
