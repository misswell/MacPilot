# MacPilot 屏幕控制：源码调研与实现方案

日期：2026-10-25。状态：方案中的屏幕控制模块、独立恢复助手和界面已实现；已通过模拟驱动与配置回归、Release warnings-as-errors 构建。尚未安装运行或进行真实屏幕/UU 画面验收，步骤见 [DISPLAY_CONTROL_MANUAL_TESTS.md](DISPLAY_CONTROL_MANUAL_TESTS.md)。

调研基准：UUyc-companion 的 `master` HEAD `f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1`。以下将已读到的源码行为与 MacPilot 的拟议设计分开；上游的硬件经验不代表已在本机验证。

## 1. 目标与控制语义

新增独立「屏幕控制」功能，首页总开关默认关闭。UU 自动控制默认「不调整」，用户选择规则后才运行。

| 用户操作 / UU 策略 | 预期行为 | 退出方式 |
| --- | --- | --- |
| 单独关闭某一屏 | 停用指定显示器，其他屏继续工作；不允许停用最后一个可用输出 | 该屏的「恢复」或「解除屏幕控制」 |
| 只保留选定实体屏 | 先确认目标可用并设为主屏，再停用其他屏 | 解除控制，恢复本功能改动的屏幕和布局 |
| UU 连接时只保留实体屏 | 检测到有效被控会话后执行上一规则 | UU 断开、手动解除或安全检查失败时恢复 |
| UU 连接时只保留虚拟屏 | 创建指定分辨率虚拟屏，确认上线和远程可操作后，停用实体屏 | 先恢复实体屏并核验，再移除虚拟屏 |
| UU 连接时增加虚拟屏 | 可选的较温和模式：创建虚拟屏，保留实体屏 | UU 断开后移除自建虚拟屏 |

这里的「关闭」指从 macOS 活跃桌面拓扑中停用：窗口和 Dock 不应继续落到该屏；它不保证每款显示器的背光或电源指示灯都熄灭。若还需要物理电源节能，应另做可选 DDC 操作并独立验证，不能把黑色遮罩或亮度为零报告为拓扑停用。

本地只剩虚拟屏、却没有经过确认的远程会话时，拒绝关闭最后一个实体屏。手动单屏模式要求保留可用实体屏。目标拔出、识别不唯一或处于合盖不可用状态时，停止自动关屏并恢复本功能停用的其他实体屏，不任意选择另一个作为唯一输出。

## 2. UUyc-companion 的关键技术

### 显示器停用与虚拟屏

- [PhysicalDisplays.swift](https://github.com/aoyamashou/UUyc-companion/blob/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1/Sources/UUDisplay/PhysicalDisplays.swift)：通过 `dlsym` 取得私有 `CGSConfigureDisplayEnabled`，在 CoreGraphics 显示配置事务中停用/启用显示器。源码注释记录：被停用的屏幕会从 online 列表消失，进程退出也不会自动恢复；因此先把 ID 写盘。
- [CGVirtualDisplay.h](https://github.com/aoyamashou/UUyc-companion/blob/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1/Sources/CGVirtualDisplayBridge/include/CGVirtualDisplay.h) 与 [DisplayManager.swift](https://github.com/aoyamashou/UUyc-companion/blob/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1/Sources/UUDisplay/DisplayManager.swift)：用 Objective-C 桥接私有 `CGVirtualDisplay`，设置像素尺寸、单个 60 Hz 模式和 HiDPI；HiDPI 下模式逻辑尺寸是物理像素尺寸的一半。持有对象维持虚拟屏生命周期。
- 显示事务放后台串行队列；以「期望拓扑 → 一步变化 → 等待稳定 → 再判断」收敛。更换配置时先保留旧虚拟屏，待新屏就绪后再释放旧屏。
- 上游代码记录快速创建、释放和重配置曾导致 WindowServer 崩溃或配置卡死；采用最短存活 2.5 秒、步间等待等经验保护。这些数字不能视为 Apple 的稳定性保证。

### UU 会话识别

- [UUMonitor.swift](https://github.com/aoyamashou/UUyc-companion/blob/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1/Sources/UUDisplay/UUMonitor.swift)：每 0.5 秒检查 `CGWindowListCopyWindowInfo` 中 `UURemoteServer` 的屏上窗口，并合并辅助功能读到的控制端信息。
- [UUReader.swift](https://github.com/aoyamashou/UUyc-companion/blob/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1/Sources/UUDisplay/UUReader.swift)：通过 bundle ID `com.netease.uuremote` 找进程，用 AX 读取带「远程控制」标记的行、控制端名称及设备列表。这是对 UU 界面结构的适配，没有使用官方会话 API。
- AX 后台串行读取且只允许一项在途，丢弃耗时过长的快照；[UUConnectionState.swift](https://github.com/aoyamashou/UUyc-companion/blob/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1/Sources/UUDisplay/UUConnectionState.swift) 用 1.5 秒缺席防抖，降低切屏瞬间的误断开。
- 设备分辨率来自用户配置，不是从远程协议自动协商。上游在多控制端时取第一个名称；MacPilot 不应直接继承这个决策。

### 恢复兜底

[Watchdog.swift](https://github.com/aoyamashou/UUyc-companion/blob/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1/Sources/UUDisplay/Watchdog.swift) 实现独立 LaunchAgent、磁盘心跳与恢复记录。其轮询周期为 5 秒，主程序心跳超时阈值为 10 秒；主程序失联或判断 UU 断开后恢复屏幕。另有全局快捷键、菜单恢复和启动恢复。

### 不能直接照搬的安全缺口

以下为源码路径推导，尚未在硬件上复现其故障后果。

1. **虚拟屏上线超时后仍可能关闭实体屏。** `DisplayManager.step()` 的等待次数超过 20 后将 `mainSet = true`；后续停用实体屏只检查持有虚拟屏对象，没有再次要求该屏 online/active。MacPilot 必须在每次停用前重新验证，超时只能中止并恢复。
2. **逐屏错误被丢弃，事务成功后没有状态回读。** `PhysicalDisplays` 忽略 `setEnabled` 的返回值；恢复在 `CGCompleteDisplayConfiguration` 成功后直接删除记录。应保留未验证成功的条目。
3. **守护进程是可选项。** `Coordinator.physicalDisableAllowed` 仅检查用户设置和私有 API 是否存在。MacPilot 应要求恢复助手就绪、有效心跳和恢复快捷键注册成功，缺一项就不允许停用屏幕。
4. **主程序与守护进程的连接证据不同。** 主程序接受「覆盖窗口或 AX 控制端表格」，守护进程只检查覆盖窗口；无覆盖窗口的有效连接可能被守护进程判断为断开。
5. **恢复记录只有数字 display ID，且缺少跨进程事务锁。** 应加入显示身份、会话身份、操作代次和锁，避免旧 ID、并发恢复和迟到操作覆盖新状态。
6. **释放等待到期可能绕过稳定条件。** `readyToRelease` 等待超过 8 秒就放行；MacPilot 不应仅因等待过久就认定安全，需进入保护状态并保留实体屏。
7. 守护进程会按心跳 PID 强杀主程序。MacPilot 应优先撤销控制租约并恢复，拒绝旧代次继续停用，不照搬按 PID 杀进程的方式。

仓库 `tests/` 中看到连接状态及阻塞 AX 的两个模拟测试入口；它们不能证明显示器停用、崩溃恢复或 WindowServer 稳定性。`docs/PLAN.md` 有历史验收记录，但部分开关、快捷键及轮询描述与当前代码不同，本方案以当前源码为准。

## 3. 不失去画面的操作规则

### 何谓「至少一屏」

必须区分「有一个虚拟屏对象」「online」「active」「用户确实能看见并操作」。[Apple 的 CoreGraphics 文档](https://developer.apple.com/documentation/coregraphics/core-graphics-functions) 分别定义 online、active 和 asleep；单独统计 online 数量不足以证明还有可操作画面。

本功能的每次停用操作必须满足：

- 剩余目标属于本次最新拓扑，仍 online、active，具有有效模式和非零尺寸；处理镜像组时不能把依附同一输出的镜像成员简单算成独立保险。
- 本地模式保留实体屏；远程纯虚拟模式还必须具有有效 UU 会话证据及用户在远程端完成的画面确认。
- 剩余屏不能仍被 MacPilot 原有全屏遮黑、DDC 关电等操作覆盖；模式进入前协调这些操作，控制期间也不能绕过共同安全检查把唯一输出再次遮黑。
- 操作开始前保存恢复意图，恢复助手已经确认接管；每一步完成后重新读取拓扑，发现目标消失立即中止并恢复。

这些规则约束 MacPilot 自己发起的操作。拔线、显示器断电、系统休眠、WindowServer 崩溃或恢复助手同时故障，无法承诺始终有可见画面。尤其「所有实体屏关闭、只留虚拟屏」仍有故障后短暂失去输出的可能；需要保留实体屏的模式作为更保守选择，不把它宣传为零风险。

「保留一屏」不应新增阻止系统显示休眠的断言，也不改变原有 Awake 和锁屏策略；正常系统休眠需要与误关最后一个输出分开处理，唤醒时重新核验可用拓扑。

### 纯虚拟模式的进入与退出

```text
确认 UU 会话 + 恢复助手/快捷键可用
  → 保存当前实体屏状态、主屏与布局
  → 创建虚拟屏，等待 online + active + 模式就绪
  → 用户在 UU 中选择该屏，并在该屏确认能看见和操作
  → 设置主屏并验证
  → 逐步停用其他屏，每步重新检查剩余输出
  → 显示「保留此配置」倒计时，未确认自动恢复

UU 断开 / 手动解除 / 心跳失联 / 安全检查失败
  → 撤销本次自动控制租约，拒绝迟到的关闭命令
  → 启用本功能停用的实体屏并逐屏核验
  → 至少一个实体屏可用后，才移除自建虚拟屏
  → 尝试恢复原主屏与布局，保存仍未完成的恢复项
```

UUyc-companion 的 README 明确说明：仅创建虚拟屏时，需要用户在 UU 的显示面板手动选择它。现有源码没有证明远程端已经显示或正在操控该虚拟屏的接口。因此第一版保留上述人工确认步骤；确认窗口应位于虚拟屏，不能以「检测到 UU 连接」代替画面确认。

如果恢复实体屏失败，保持可用虚拟屏及恢复助手运行，不为完成退出而提前释放唯一输出。采用显式异步结束事务，不能仅依赖进程退出时的同步 `stop()`。

### 方便解除控制的入口

1. **固定紧急快捷键**：建议 `⌃⌥⌘9`，独立恢复助手持有；应用到系统前检查冲突及注册结果。它直接撤销控制并恢复，不弹确认框，不依赖设置窗口或主程序主线程。UU 可能拦截远端组合键，需要同时告知用户可用 Mac 本地键盘触发。
2. **菜单栏固定「解除屏幕控制」**：恢复本功能停用的屏幕；纯虚拟模式先恢复实体屏，再退出虚拟屏。详情页提供同样按钮和待恢复状态。
3. **确认倒计时**：初次进入或更换唯一输出后，建议 15 秒内确认保留，否则由独立助手恢复。实际期限需在真实设备上校准。
4. **独立助手自动恢复**：主程序失联、租约过期或持续无法确认 UU 会话时恢复。通过 `launchd` 管理，助手重启先处理未完成记录，不直接重新关屏。
5. **不依赖 GUI 的恢复入口**：拟提供 `MacPilotDisplayRecovery --restore`，与助手使用同一恢复协议，便于通过终端或用户已有的远程维护渠道调用；不额外开放网络端口。

手动解除必须设置本次会话的 override：同一次 UU 连接不再自动关屏，直到用户显式重新应用，或确认断开后建立新会话。仅点击恢复、500 毫秒后又被自动规则关闭，不能算有效恢复。

### 确认超时、引导与显式重新应用（2026-10-28 实机问题修正）

实机现象：UU 已连接、自动创建虚拟屏成功，但 30 秒内没有在虚拟屏上完成确认，于是按安全规则恢复实体屏；之后页面看起来一切正常，自动规则也不再重试，用户无法判断发生了什么。

- **确认控件必须留在虚拟屏**，但用户切到虚拟屏之前看不到它。因此进入 `awaitingVirtualConfirmation` 时，同时在该屏之外的**当前实体屏**上显示一块不可交互的引导窗口：说明要在 UU 显示面板选择 `MacPilot Remote Display`、再在虚拟屏上确认，并显示倒计时。引导窗口不能代替确认，也不能放在任意物理屏上执行确认。
- **一次确认超时 / 紧急解除 = 本次会话 override**，自动规则不得重试，否则会立刻把用户刚恢复的桌面再次关掉。设置页的「应用当前 UU 策略」是唯一的显式重新应用路径：`prepareVirtual` / `keepOnly` 带 `confirmed: true` 时才会清除 `DisplayControlOverride.json`；自动路径始终为 `false`，无权清除。禁止把「清除 override」做成自动重试的一部分。
- **失败必须在页面顶部可见**：错误提示从「安全恢复」卡片移到页头下方，UU 已连接且规则非 `none` 时在同一处提供「应用当前 UU 策略」重试按钮。
- **启动时已连接的 UU 会话同样自动应用**：旧实现为了让"重启 GUI 不撤销启动恢复/紧急解除"而禁止启动后自动应用，结果装完新版本重启时 UU 明明连着却什么都不做，页面还留着上一次会话的「已手动解除控制」。启动恢复由助手状态机负责（`recovering` 期间 `canChange == false`），上一次解除由 `DisplayControlOverride.json` 按会话拦住，因此 GUI 不再自行抑制；自动请求若被会话 override 挡住，助手返回 `userOverride` 而不是误导性的 `uuSessionRequired`。
- **消息只描述最近一次事务**：`userOverride` 等消息不得跨会话/跨 GUI 重启存活。助手处理 `status` 时，若会话与 override 记录的会话不同（或 UU 已断开），清掉这条陈旧消息，避免新会话一打开页面就被说成"你刚手动解除了控制"。
- **状态迁移与策略决定写入 `~/Library/Logs/MacPilot/Diagnostics.log`（`DisplayControl`）**：状态 / message 变化时才记录，附带 UU 状态、会话前缀与实体/虚拟屏数量。没有这条记录，「没有反应」无法回溯。
- 回归：`DisplayTopologyControllerTests.anExplicitReapplyClearsTheSessionOverrideLeftByAConfirmationTimeout`、`DisplayTopologyControllerTests.aStaleOverrideMessageDoesNotGreetANewSession`、`DisplayControlIntegrationTests.onlyTheUserInitiatedUUApplyAsksTheHelperToClearTheSessionOverride`；`DisplayControlTranslationsHaveMatchingKeys` 保证两份文案同步。

## 4. 运行时、恢复记录和会话策略

### 恢复助手与并发

建议 GUI 负责界面和 UU 检测，独立、同用户图形会话的恢复助手统一串行执行显示拓扑操作并持有自建虚拟屏。GUI 发出带代次的目标状态，不能直接旁路写拓扑；助手在 GUI 心跳过期时撤销目标并恢复。可采用 [SMAppService 的 LaunchAgent](https://developer.apple.com/documentation/servicemanagement/) 管理，注册结果及实际握手都通过才算就绪，不需要复用 root 电源 Helper。

- 紧急快捷键、倒计时和健康判断不能排在耗时显示事务的同一执行队列上；正常变更在后台串行执行。
- 助手与一次性恢复入口共享跨进程锁；事务 journal 与代次更新也在锁内完成。恢复优先，旧 GUI 命令不能在恢复后继续执行。
- IPC 校验同用户与应用签名身份，journal 限定在本功能的私有目录；不接受任意文件路径、PID 或未验证显示器记录作为恢复命令。
- 显示事务超时进入保护状态：停止创建、释放、停用等新变化，有限尝试恢复并报告结果。线程超时不能取消一个已卡住的系统调用，这部分必须在原型中验证，不能承诺快捷键可修复系统显示服务死锁。
- 助手崩溃由 launchd 拉起后，先恢复日志；助手不可用或被用户禁用时，功能拒绝新的停用操作。更新、降级、退出、卸载均先完成恢复握手，不依赖新版本仍能读取旧进程的内存。

### 恢复 journal

拟使用独立 `DisplayControlRecovery.json`，不与普通偏好设置或既有 `DisplayBlankRecovery.json` 混写。字段包括 schema version、操作 UUID/代次、当前用户及系统/显示会话身份、原主屏、原布局、各屏稳定身份、当前会话 display ID、原始启用状态、自建虚拟屏身份、步骤及待恢复状态。

持久身份优先使用显示 UUID，辅以厂商/产品/序列信息；数字 ID 只作为当前显示会话的句柄。显示 UUID 在转接器、相同型号无序列号设备上的稳定性，以及被停用后如何重新核验身份，必须做原型。重启或显示服务重启后不可盲用旧 ID，也不能仅凭 vendor ID 认领其他程序创建的虚拟屏。

记录必须先原子写入并确认成功，助手才执行停用；写失败则中止。恢复读取每一步错误并回查实际状态，仅删除确认完成的项目。拔出的屏幕保留为未完成恢复项，重新接入时核验身份后再处理；不反复切换或猜测设备。仅恢复本功能拥有的改动，不擅自启用用户或其他软件原先停用的屏幕。

### UU 策略

- 会话状态至少为 `disconnected / connecting / connected / unknown / recovering / userOverride`，区分「没有连接」和「读不到」；未知状态禁止新关屏，已控制时经过有限宽限后恢复实体屏。
- 窗口证据核对所属进程与当前 UU 进程关系，不能只匹配 owner name；AX 遍历设置深度、节点数、时间预算及过期快照代次，支持版本和语言适配。
- 统一连接证据和恢复租约：助手不另用更弱的「没有透明窗口」判断去推翻有效 AX 会话；GUI 无法持续提供新鲜证据时让租约过期。
- 多个控制端同时连接、无法唯一识别设备、未知设备缺少虚拟屏规格时，不自动关闭实体屏；界面说明原因。
- 默认提供全局固定虚拟屏规格，支持可选的每设备覆盖；控制端名称仅作可编辑匹配条件，不当成可信唯一设备 ID。分辨率由用户填写或选择预设，HiDPI 明示物理像素与逻辑尺寸，先支持一个 60 Hz 模式，校验尺寸上限及偶数尺寸。
- 分辨率变化先恢复实体屏，再创建和确认新虚拟屏；串行合并快速设置变化，绝不并发建屏/销屏。休眠、用户切换及合盖导致的未知状态先撤销控制，唤醒后核验，不立即重复关屏。

恢复主屏、模式、排列可以记录并验证；应用窗口受 Space、Stage Manager 和应用自身行为影响，第一版只尽力避免越界，不承诺像素级恢复每个窗口。自动移动其他应用窗口应另行设计，不作为本需求的默认副作用。

## 5. MacPilot 接入位置

当前 `DisplayPower.swift` 处理全屏遮黑、背光、DDC 和系统显示休眠；`DisplayBlankRecovery.swift` 恢复亮度/电源。二者尚不是单屏拓扑停用器，不应把现有「关闭屏幕」动作直接替换成停用。

拟议模块：

| 新模块 / 文件 | 责任 |
| --- | --- |
| `Sources/MacPilot/DisplayControl/` | 设置、状态机、UU 检测、屏幕清单、与现有屏控的协调、设置页 |
| `Sources/MacPilotDisplayControlCore/` | 纯策略、显示身份、恢复 journal、租约与 IPC 类型，可注入测试 |
| `Sources/MacPilotDisplayBridge/` | 最小 Objective-C 私有 API 桥接、运行时可用性检查 |
| `Sources/MacPilotDisplayRecovery/` | 独立恢复助手、串行拓扑执行、虚拟屏持有、快捷键及恢复 CLI |

上述模块已创建。虚拟屏私有类及方法先动态检查，找不到接口则显示不支持，不能让可选功能导致主程序启动失败。未新增签名 entitlement、未改现有 designated requirement；助手及 LaunchAgent 配置已接入构建打包与嵌套签名流程。

配置接入 `StoredConfiguration.section(...)`、`ConfigStore` 的 feature/shortcut 分域、首页 `MainSection`、`prepareFeatureForUserEnable`、`aligningHomeControlledSwitches` 和 `FeatureRegistry`。新增字段容错解码，既有键不删不改；运行态租约和待恢复状态不作为普通配置随版本快照重放。

现有 `ManagedFeature.stop()` 和主程序 `shutdown()` 是同步路径，不能凭调用它们就声称异步显示恢复完成。需明确退出/禁用前的恢复屏障，以及无法完成时助手继续负责恢复的协议。启动时先处理拓扑恢复，再处理背光恢复，再允许新规则启动。

设置页遵循 `docs/UI_DESIGN.md`：30pt 页头、`SettingsCard`、36/34/30 外边距、24 卡片间距，中英文 `AppText` 同步。页面分为「当前屏幕」「UU 自动策略」「虚拟屏规格」「安全恢复」，屏幕行区分实体/虚拟、主屏、启用、待恢复；总开关只放首页。恢复入口不能因总开关关闭而消失。

## 6. 实施顺序与验收

1. **安全核心先行**：实现纯状态机、模拟显示驱动、journal、租约与恢复助手协议；覆盖拒绝关闭最后一屏、旧代次失效、恢复幂等和写盘失败。
2. **实体屏控制**：单屏停用、仅保留选定实体屏、恢复、快捷键、确认倒计时；先证明助手退出/重启、目标拔出及恢复失败路径。
3. **UU 自动实体屏策略**：接入可注入的 AX/窗口适配器，处理延迟、权限丢失、多控制端和手动 override。
4. **虚拟屏策略**：动态桥接、规格验证、先建后关、先恢复后销、远程画面确认、创建失败保护及快速反复配置收敛。
5. **兼容与交付**：验证系统版本、更新/降级、原有屏幕遮黑、BLE、Awake、录屏和截图的协调。通过后才能开放默认关闭的实验功能；具体硬件和 UU 版本单独记录。

自动测试只用隐藏/模拟显示和临时目录，不停用真实屏幕、不改用户配置、不操作通用剪贴板。新增安全用例至少覆盖：只有一屏、唯一目标突然消失、镜像组、第三方虚拟屏、虚拟屏未上线/模式失败、私有符号缺失、配置事务失败/卡住、journal 写失败、恢复部分成功、崩溃重启、并发解除、过期 AX 回调、热键冲突、无助手及多控制端。

配置回归包含 `ConfigurationSchemaContractTests`、`ConfigStoreTests`、`ConfigurationSnapshotTests`；原屏控回归包含 `DisplayPowerTests`、`DisplayBlankRecoveryTests`、`ScreenControlSafetyTests`。实施阶段已由 `luna_worker` 运行这些回归、新增模拟核心/界面测试、输入源回归及 Release warnings-as-errors 构建。未运行真实屏幕测试、注册助手或安装应用。

真实验收需用户明确授权，在可隔离的 AgentSpace 会话可用时使用它，准备本地键盘和独立恢复入口：分别测单/双外接屏、内屏、合盖、UU 手机/平板/电脑、断连与重连、应用/助手崩溃、睡眠唤醒、显示热插拔、15 秒回滚和同会话解除不再自动关闭。核对远程实际可见画面、实体屏实际可操作、窗口/Dock 可达及恢复布局；记录恢复耗时，不把阈值配置或日志成功当成实测。

## 7. 可行性与尚待证明的部分

源码证明存在可参考的实现路径，尚未证明该私有接口在目标 macOS、GPU、转接器及显示器组合上可靠。最值得借鉴的是目标状态收敛、后台串行事务、先记录再停用和独立恢复；必须补强的部分是可用输出核验、强制恢复前提、跨进程一致性和会话误判处理。

优先完成实体屏控制和恢复底座，再开放纯虚拟 UU 模式。若私有接口失效，应禁用对应能力并保留清晰状态，不能悄悄用黑色遮罩冒充实现。

上游采用 [MIT License](https://github.com/aoyamashou/UUyc-companion/blob/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1/LICENSE)；若复用源码或桥接声明，应保留对应版权和许可，并核对其引用的 FreeDisplay 等来源。本设计不需要复制其 AboutKit 或引导 UI。
