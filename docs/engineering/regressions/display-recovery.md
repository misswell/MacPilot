# display-recovery — 黑屏/亮屏、显示器拓扑与 DDC 恢复

规则：`disp-001-recovery-not-durable`（恢复不持久，5 天 8 修）、`disp-002-closed-lid-registration`（合盖注册状态过期，4 修）。证据链见 [../REGRESSION_CATALOG.md](../REGRESSION_CATALOG.md) C1/C2。详细设计见 docs/DISPLAY_CONTROL_DESIGN.md、docs/DISPLAY_CONTROL_MANUAL_TESTS.md。

## 不变量

### 恢复必须持久（disp-001-recovery-not-durable）

- 恢复意图**先落 journal 再动硬件**（`bc0d4ef` 的教训：内存态一次性调用在崩溃/重启/拓扑变化后全部丢失）。
- durable 请求跨 helper 重启仍可识别；虚拟 creation intent 跨重启。
- 恢复未完成时，helper 先完成屏幕拓扑/原始电源状态恢复并确认，再退出；只保留必要恢复工作并明确失败。**不得通过 kill 绕过安全事务；恢复失败不得上报为成功。**
- 新旧显示器拓扑切换不得覆盖未完成事务；显示器断开不得丢失恢复记录。
- 不得错误关闭最后一块可用实体显示器（紧急恢复路径保底）。
- 快速关闭再开启、崩溃恢复、延迟回调不得误停新会话。

### 身份与绑定

- `CGDisplayCreateUUIDFromDisplayID` 在当前 macOS 可能不导出：native identity 优先，fallback identity 绑定当前 WindowServer 会话并在恢复时重新核对（`DisplayBlankRecoveryTests` 的三个身份测试钉住）。
- 手机黑屏的 identity 必须按请求绑定（`133e466`），不能拿别的会话/显示器的身份恢复。
- 黑屏走背光压 0 而不是显示器休眠（v1.1.305 设计，见 SUMMARY.md 相应章节与 docs/DISPLAY_CONTROL_DESIGN.md）。

### 注册状态（disp-002-closed-lid-registration）

- 合盖电源服务注册状态必须 re-read 系统而非缓存；registration loss 后自动恢复；旧版 helper 兼容。
- 显示/电源辅助进程退出前先完成恢复并确认（见 helper-lifecycle.md 的按需生命周期）。

## 必跑测试

`DisplayBlankRecoveryTests`、`DisplayPowerTests`、`KeyboardBacklightTests`、`DisplayRecoveryClientTests`、`DisplayRecoveryPreparationTests`、`DisplayRecoveryEventHandlerTests`、`DisplayRecoveryJournal`、`DisplayOperationStoreTests`、`DisplayControl*`、`DisplayTopology*`、`DisplayRemoteLease*`、`DDCPacketTests`、`ScreenControlSafetyTests`、`ClosedLid`、`SleepDisabledPlannerTests`、`PowerHelper*`。

已知自动化缺口（如实报告，不要用 mock 冒充）：恢复定时重试、显示连接变化触发重试的完整调度链路尚需测试；`DisplayBlankHardwareTests` 属硬件类，不入 CI 自动集。

## 人工验收

见 [../acceptance/hardware-acceptance.md](../acceptance/hardware-acceptance.md)：实机外接屏 DDC 黑屏→断电→重连→恢复、长时间黑屏、键盘唤醒、内屏外屏分别验证、热插拔拓扑切换、合盖睡眠/唤醒（docs/AWAKE_MANUAL_TESTS.md）。全部须用户明确授权与安全环境。
