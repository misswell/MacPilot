# MacPilot 发版前历史问题回归

每次发版读取本清单及全局 `~/.codex/docs/agent-rules/release-regressions.md`，运行项目要求的安全全套测试和适用的历史回归；全套已在相同源码、工具链与配置通过时可复用，失败按项目规则隔离复测并如实报告。下列套件是入口，不能把 mock 通过称为真机通过。每次修复新问题时补充触发条件和测试入口。

| 曾遇到的问题 | 发版前回归 |
|---|---|
| `CGDisplayCreateUUIDFromDisplayID` 在当前 macOS 不导出，导致手机点击黑屏获取显示 UUID 失败并提前退出 | `DisplayBlankRecoveryTests.onlineDisplaysHaveRecoverableIdentities`（只读在线显示身份检查）、`sessionBoundFallbackRequiresWindowServerAndDisplayIdentity`、`sessionBoundRecoveryRejectsAnotherWindowServerOrDisplay`；验证 native identity 优先，fallback identity 绑定当前 WindowServer 会话并在恢复时重新核对。真实黑屏/恢复须另行授权及安全环境。 |
| 手机黑屏后外接屏 DDC 开机失败、记录被丢弃；不可读或断连后恢复 | `DisplayBlankRecoveryTests`、`DisplayPowerTests`、`KeyboardBacklightTests`；现有测试覆盖恢复记录和输入判断。自动化缺口：恢复定时重试、显示连接变化和后续输入触发重试的完整调度链路尚需测试。实机覆盖内屏及外屏、长时间黑屏、键盘唤醒、断连重连和恢复，须明确授权及安全环境。 |
| 显示拓扑控制丢失后未恢复、最后一块屏幕被关 | 项目显示控制/恢复相关安全测试，验证事务日志、控制失效恢复、最后可用输出和紧急恢复；物理拓扑验证须授权、隔离及可逆恢复。 |
| 手动锁屏后 BLE 意外解锁、睡眠唤醒后无法恢复或反复断连 | `BLEManualLockSuppressionTests`、项目 BLE 恢复套件；覆盖真实睡眠/唤醒信号顺序、旧信号丢弃、重连和超时。真实锁屏与手机蓝牙行为另行授权验证。 |
| FinderSync 更新后被留在禁用状态、后台心跳未恢复 | `FinderSyncRegistrationTests`、`FinderSyncRecoveryJournalTests`、`FinderSyncHeartbeatLifecycleTests`；只读安装状态可用 `zsh Scripts/verify-findersync.sh`，不自动重启 Finder 或重置权限。 |
| 配置字段变化导致降级解码失败并丢配置 | `ConfigurationSchemaContractTests` 与配置加载/隔离相关测试；旧版升级、降级和真实用户配置迁移分别记录是否实测。 |
| Dock/菜单栏入口消失或菜单重建异常 | `AppPresenceTests`、`MenuBarDisplayControllerTests`、`MenuBarMenuSessionTests`、`ConfigurationSchemaContractTests`；确保至少一个入口可用。 |
| 菜单栏右键菜单比系统菜单偏高、顶边压进菜单栏 | `MenuBarOwnedMenuTests`（状态栏 item 必须拥有 AppKit 定位的 `NSMenu`，一旦改回 `popUp` 手算锚点即失败）、`MenuBarDisplayControllerTests`、`MenuBarMenuSessionTests`。锚点实测：`bounds.minY` 高 24pt、`bounds.maxY` 仍高 6pt，而 AppKit 自己挂的菜单在菜单栏底边下方 1pt。 |
| 点菜单里的「设置」打不开主窗口（历史上反复出现） | `MainWindowOpenerTests`、`MainWindowContentStateTests`、`AppPresenceTests`；覆盖「菜单跟踪期间只排队一次、下一轮才真正抬窗」「没有窗口时必须经 `openWindow(id:)` 重建，不能静默挂起」「场景丢弃的窗口不复用」「每次结果写入 `MainWindow` 诊断日志」。另有 `MenuBarOwnedMenuTests.relayTargetsSurviveThePostCloseActionDispatchAndDropOneTurnLater`：macOS 27 在 `menuDidClose` 之后才执行所选动作，快照 session 不得在关闭回调里同步释放（同步释放会清空弱引用 target，让所有菜单动作静默失效）。实机回归：关闭主窗口后分别从菜单「设置」、Dock 图标、Finder 重新打开，连续关闭重开多次；即使 macOS 拒绝前台激活，`orderFrontRegardless` 也必须让窗口可见。 |
| Dock 组跨进程编辑丢失或面板放置错误 | `DockGroupsCoreTests`、`DockHelperPanelPlacementTests`；覆盖并发写入及布局。 |
| 远程发现或协议能力宣告不正确 | `RemoteBonjourPublisherTests`、远程连接/能力相关套件；覆盖注册失败恢复、旧回调和版本兼容。 |
| 搜索查询过期、位置/收藏丢失或索引不可用误报无结果 | `QuickSearchCancellationTests`、`QuickSearchPersistenceTests`、`QuickSearchSpotlightHonestyTests` 及项目搜索测试；覆盖查询取消、状态恢复和不可搜索提示。 |
| 发布包签名身份不一致，升级或权限失效 | `SigningRequirementTests`，并对最终下载包执行项目指定签名要求、strict codesign、公证、stapler、Gatekeeper 和摘要验证。 |

真实显示、电源、锁屏、键盘注入及 Finder/权限状态操作不得在用户当前会话自动执行。未获得授权或缺少安全设备时只运行安全测试，并明确列出未验证的实机项。
