# 问题与修复速记

## 2026-11-27：安全键盘输入下继续使用 ⌥Tab

beta.127 在系统保护持续时只有鼠标入口。现场无可见密码框时，macOS 仍报告保护开启且监听器显示启用 → 改由系统注册两个方向的快捷键，保护期间直接切换一次，解除后沿用按住 Option 浏览。首页警告按 ⌥Tab 实际可用通路显示 → `win-003-secure-input-switcher`、`WindowSwitcherFirstPressTests`、`CarbonHotKeyRoutingTests`。现场已验证保护开启时系统接受两个注册，真实按键与窗口置前待隔离桌面验收。

重叠快捷键被占用 → 「抢回快捷键」重试冲突组合并重新置顶键盘监听。按系统返回值提示仍占用，读取到真实快捷键才确认监听接管 → `WindowSwitcherFirstPressTests.reclaimRetriesRegistrationAndListenerWithoutClaimingAnOccupiedShortcut`、`HomeAttentionTests`。与另一真实应用同时争用的验收待完成。

## 2026-11-26：安全键盘输入期间的窗口切换

⌥Tab 无响应时系统仍将监听器标为启用，定期检查遗漏了键盘保护 → 在现有检查中采样保护状态，丢弃中断的快捷键会话，菜单和首页提供鼠标切换，系统恢复投递后清除暂停提示 → `win-003-secure-input-switcher`、`WindowSwitcherFirstPressTests`、`HomeAttentionTests`。新构建的原生菜单点击及安全输入转换待隔离桌面验收。

## 2026-11-20：快速滚动鼠标只切一张（未发布，待鼠标实机验收）

鼠标滚轮的 0.1 秒冷却丢弃了快速连续事件 → 每个非精确非零滚动事件各翻一张，不按时间合并；触控板一次手势一张及缩放映射不变 → `ImageViewerScrollGestureTests.everyMouseWheelNotchNavigatesEvenDuringARapidScroll`（旧实现复现失败后通过）、`img-006-scroll-gesture-mapping`。

每次修复追加一行：**现象/根因 → 修复与不变量 → 自动回归**。旧历史见 [目录册](REGRESSION_CATALOG.md)；未解决、未发布、待实机验收分开标明。

## 2026-11-13：登录启动恢复（beta.102 已发布，待实机重启验收）

| 问题 / 根因 | 修复与不可破坏的规则 | 回归入口 |
|---|---|---|
| 开机后滚轮/窗口切换失效，系统授权开启但进程 AX=false；现场首次 TCC 查询早于 AppKit 注册，窗口切换恢复又被旧权限值禁用 | AppKit 完成启动后的下一轮才构造所有功能模型；恢复以功能意图武装，不能依赖上一次权限结论 | `AppLifecycleTests`、`WindowSwitcherFirstPressTests`、`SmoothScrollRecoveryTests`；真实 tccd 重启恢复待验收 |
| 后台启动菜单打不开窗口；opener 惰性依赖窗口，creator 晚到不消费 pending；Release 又过滤了打开结果日志 | 进程显式持有 opener，Commands 提供 scene 创建动作，late creator 在下一轮消费请求，Release 保留结果日志 | `MainWindowOpenerTests` 新用例在旧代码创建次数 0（红）；菜单真实冷启动待验收 |
| 冷启动经 URL 打开时深链早于 `didFinishLaunching` 送达，模型延后构造会错过 | `AppDelegate` 缓冲启动期 URL，模型构造后重放一次，此后不再缓冲 | `AppLifecycleTests.deepLinksDeliveredBeforeServicesAreBufferedAndDrainedOnce` |

## 2026-11-09：屏幕控制菜单入口

| 问题 / 根因 | 修复与不可破坏的规则 | 回归入口 |
|---|---|---|
| 菜单栏「解除屏幕控制」无条件渲染在顶层；关闭屏幕控制后仍占位，启用时也未归入二级菜单 | `DisplayControlMenuSection` 按 `isFeatureEnabled(.displayControl)` 启禁用，功能关闭时连同分隔线整段不渲染；启用时「解除屏幕控制」放在「当前屏幕」二级菜单，顶层不再有该按钮 | `DisplayControlMenuTests.releaseRowIsNestedInsideTheEnabledDisplayControlSubmenu`、`DisplayControlMenuTests.disabledDisplayControlSectionLeavesNoMenuRowOrDivider`；菜单栏实机点击待验收 |

## 2026-11-06：源码修复（beta.98）

已随 `v1.2.2-beta.98`（`ed37eab`）发布；同 SHA 的 Build、macOS 15/26 回归门禁与发布工作流通过。真实设备验收未做。

| 问题 / 根因 | 修复与不可破坏的规则 | 回归入口 |
|---|---|---|
| 旧输入法任务覆盖新应用；无需新切换时未失效 | 每次应用激活都取消旧链 | `InputSourceSwitchTests` |
| 反向 BLE 慢读取丢样本；nonce 提前替换 | 保留已送达挑战至消费/本机 TTL；旧读取结束后处理新挑战 | `ProximityGATTProductionRestartTests`、`ReversePresenceCentralTests`、协议包 |
| UU 自动策略失败后不重试；提前标记完成 | 确认获得控制才标记；失败退避，新会话清旧退避，手动恢复优先 | `DisplayControlIntegrationTests` |
| Helper 获批后仍无监控；启动资源未补齐 | 准备成功后补齐监控与终止清理注册 | `DisplayControlIntegrationTests` |
| 崩溃恢复重新关闭用户已手动打开的屏幕 | 非强制恢复尊重已开屏状态；显式恢复仍还原原状态 | `DisplayBlankRecoveryTests` |
| 搜索关闭抢设置窗口焦点；只看进程 active | 尊重其他 key window；旧异步聚焦不得抢回焦点 | `QuickSearchApplicationActivationTests`、`QuickSearchHiddenFieldEditorTests` |
| 超大图标缓存先读入再检查 | 读取前检查，实际读取也限长 | `QuickSearchIconDiskCacheTests` |
| 无操作自行亮屏；ANY 计数被当成输入 | 核对具体输入，忽略静止指针/重复修饰键/计数重置；保留正常熄屏并记录解除类别 | `DisplayPowerTests` |

| 键盘布局只复制资源头，`UCKeyTranslate` 可能越界读取 | 保持完整、对齐的布局数据存活；TIS 在主线程调用；非法 keyCode 提前拒绝 | `QuickAccessTests` |

黑屏补充：只读观察捕获“系统休眠 → ANY-only 变化 → 旧版解除保持”的同类路径；**00:11 那次具体事件源仍未知**。手机端修改需另行 iOS 分发，Mac beta 不等于 TestFlight 上传。

## 2026-11-06：快速搜索多显示器闪一下消失

| 问题 / 根因 | 修复与不可破坏的规则 | 回归入口 |
|---|---|---|
| 设置窗口在一屏、指针在另一屏时唤起快速搜索，面板闪一下即关闭；应用异步激活完成时 AppKit 优先把另一屏的普通窗口选成 key window，面板 resignKey 后触发延迟关闭（`a071a52` 引入临时激活本进程后暴露）。beta.99 的首次修复只在 `didBecomeActive` 重抢一拍，首次仍会闪退，第二次才正常 | 打开时若本进程未激活，在 `NSApplication.didBecomeActiveNotification` 到达后 `makeKeyAndOrderFront`，并保持 0.6 秒 settle：期间每次失 key 都重抢、不关闭；settle 结束仍未拿到 key 才走正常失焦关闭；关闭面板解除观察；激活超时才走兜底 | `QuickSearchPanelActivationTests`、`QuickSearch`；双屏实机验收待做 |

## 2026-11-06：验证与发布问题

以下均已处理；beta.98 的完整 CI 通过，未增加测试豁免。

| 问题 / 根因 | 修复与以后规则 |
|---|---|
| 并发测试堵塞 MainActor，产生超时 | 串行运行相同完整集合，不删测试或放宽断言 |
| 测试写全局 termination owner，污染其他套件 | 注入注册动作，只记录测试对象 |
| 无界面 CI 无法真实启动应用 | 注入启动操作，测试不依赖桌面会话 |
| 路径测试绑定本机 Xcode 版本 | 注入独立注册路径，避免依赖机器安装状态 |
| 测试假设 ditto 自动生成 provenance | 显式创建属性，再验证复制后保留 |
| 截图测试用 0.1 秒判断执行先后 | 改为断言 overlay 与 AX resolver 的事件顺序 |
| 菜单栏测试错认旧插入状态或错过移除窗口 | 等待本轮移除/插入；注入暂停点验证 selfHeal |
| 一次性资源测试依赖 50/70 毫秒调度窗口 | 注入等待，按任务完成顺序断言 |
| PiP 参数文件先出现后写完，被读成空内容 | 写临时文件后原子改名，保留参数精确断言 |
| 隐藏回归日志未上传，崩溃缺少证据 | 上传隐藏日志；失败输出末 50 行，限量收集崩溃栈 |
| 文件树含 main，但提交图未包含 main，push 被拒 | 正常合并并检查祖先关系，不强推；树等价才复用检查 |
| 检查点直接覆盖，异常时留下截断 JSON | 验证旧 JSON，写同目录临时文件后原子替换 |

发布规则：一个 Luna 执行者、持久检查点、同 SHA 门禁、脚本等待、一次最终验收。已发布 tag 不移动；文档后续更正单独提交。

发布验收：附件 SHA-256、应用签名、固定 DR、公证票据与 DMG 校验通过；未安装。本机 Gatekeeper assessment 已关闭，不能据此声称首开验收通过。iOS 修改尚未分发 TestFlight；黑屏/显示器实机与升级验收仍待完成。

## 2026-11-06：beta.99 复查修复

| 复查问题 / 根因 | 修复或澄清与防复发 | 验证入口 |
|---|---|---|
| AX 空结果提前清 pending 且取消 fallback；按键已消费但会话不显示 | pending 与 fallback 由同一生命周期状态机管理；仅最终可展示的非空 AX/cache snapshot resolve；fallback 用代次 token 拒绝旧回调 | `WindowSwitcherFirstPressTests`（旧分支 mutant 红、修复后绿） |
| BLE sampledAt 被误读成可靠的无线测量时间 | 注明它是 iOS 收到 RSSI callback 后写入的诊断墙钟；生产授权仍依赖 Mac 单调 TTL、当前 nonce、设备 ID 与 HMAC；配对密钥持有者仍可伪造 RSSI | `ReversePresenceSampleTests`、`ReversePresenceOperationTrackerTests`、`BLEReversePresenceTests` |
| 发布只等 Build，回归或 iOS CI 未成功也可能出包；合并后旧逻辑测试从移动 main ref 取样导致递归失败 | tag gate 逐项要求同 SHA、main push 的 Build、双 macOS Regression Gate、PilotNest 成功；逐轮扫描所有门禁，任一失败即阻断；历史 build-only 行为固定为带来源 SHA 的只读 shell fixture | `python3 Tests/Release/release-gate-tests.py` |
| 门禁索引可缩减测试/路径或增加豁免 | base 版本 guard 禁止删除规则/状态降级/缩小规则及全量 suite 覆盖/新豁免；索引变化升级全量；macOS 26 改为阻断门禁 | `python3 Tests/Python/test_regression_index_guard.py`；`Regression Gate` |

信任边界：仓库 checker 无法阻止有写权限者同时改 checker 与 workflow。当前 GitHub 主分支保护/Rulesets 未配置；需管理员另设 branch protection 与 CODEOWNERS 强制审查。本次只记录，不更改远端权限。BLE 处理是协议/威胁模型澄清，不代表新发现一条超时绕过漏洞。实机显示器与 BLE 验收待完成；本 PR 未发 beta。完整验证证据见关联 PR。

## 2026-11-16：截图状态、文件生命周期与捕获可靠性重构（beta 待发布）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| Quick Access 卡片先出现、文件还没写完就能复制/保存/拖拽；写入失败后卡片被移除且截图丢失 | `CaptureArtifactState` 状态机 + `QuickAccessOperationCoordinator` 门控；失败保留卡片、错误与重试；自动保存失败保留一份临时回退文件 | `ScreenshotReliabilityTests`、`QuickAccessTests` |
| 同一张图被 Quick Access、剪贴板、自动保存各自编码多次；工具栏复制绕过保存流程 | `handleCapturedImage` 统一入口 + `PostCaptureRouter` intent 路由；复制/保存/贴图共享同一 `CaptureArtifact`；`.copy` 改走 `.explicitCopy` | `ScreenshotReliabilityTests`、`ScreenCaptureTests` |
| 延迟粘贴丢失截图：剪贴板用懒加载 provider，但清理逻辑只看 `.fileURL` | `ClipboardArtifactLeaseManager` 按 `changeCount` 记录 lease，并支持命名 consumer；自动清理前查询 lease | `ScreenshotReliabilityTests`、`ScreenCaptureClipboardRegressionTests` |
| 「当前窗口截图」截到最大的非焦点窗口；目标显示器按尺寸相似猜测；窗口固定 2× 输出 | `CaptureWindowFocusResolver`（AXFocusedWindow → z-order 回退）、`CaptureDisplayResolver`（仅 DisplayID 精确匹配）、`pointPixelScale` 输出比例 | `ScreenshotReliabilityTests` |
| 跨屏截图缺少某个显示器时静默 `continue`，结果带透明空洞 | `CaptureCompositeValidator` 校验覆盖、裁剪与最终尺寸，失败整次中止 | `ScreenshotReliabilityTests`、`ScreenCaptureTests` |
| 截图 UI 可能被截进图里，而排除整个进程会连普通 MacPilot 窗口一起排除 | `CaptureChromeWindowRegistry` 按 window id 排除选区面板/Quick Access/HUD；`sharingType = .none` | `ScreenshotReliabilityTests`、`SnapzyCaptureTests` |
| 刷新截图的任务不归属会话：旧刷新完成后会恢复新会话面板、替换新会话冻结画面；取消后隐藏状态无人恢复 | 刷新任务绑定 sessionID + 递增 token；面板隐藏改为 `RefreshHideLedger` 引用计数，旧会话 token 无法解除新会话隐藏；会话结束释放全部 token | `RefreshHideLedgerTests`、`SnapzyPopupCaptureOrderingTests`、`ScreenshotPopupWindowProbeTests` |
| 窗口列表未就绪时单击/回车被吞掉；加载失败与“此处无窗口”都表现为什么都不发生 | 引入 loading/ready/failed 状态与对应提示；加载中暂存一次点击并在快照到达后重放，未命中或失败则从该点手动框选 | `WindowSelectionLoadingStateTests`、`ScreenshotReliabilityTests` |
| 定格后的尺寸徽标把点数当像素显示（混合 DPI 下错误） | `expectedOutputPixelSize` 复用真实裁剪的对齐与放大规则预测输出像素；实时气泡显示 pt，定格徽标显示 px | `CapturePixelSizeTests`、`ScreenshotReliabilityTests` |
| 选区提交后的裁剪/合成/圆角阴影仍在主线程执行，5K/跨屏截图会卡住选区与 Quick Access 动画 | 裁剪、合成与样式改为 detached + `CaptureImageWorkGate`（并发上限 2）；冻结会话传递快照值拷贝；编码同样经 gate 限流 | `CaptureImageWorkGateTests`、`ScreenshotReliabilityTests` |
| Quick Access 手动保存后历史里没有正式文件，删除后历史仍留失效路径；标注保存用 `try?` 吞掉写入失败 | `CaptureHistoryStore` 改为委托 `SmartCaptureHistoryStore`，提升时用 `previousPath` 重指向正式路径并发外部变更通知；删除同步移除历史；标注写入改为 staging → 解码校验 → 原子替换，失败保留原图并报错 | `CaptureHistoryServiceTests`、`ScreenshotReliabilityTests` |
| 全屏、当前窗口、滚动截图以 `.other` 调用处理入口，按模式配置永远不生效；设置页也没有任何按模式入口 | 四类入口改为携带真实 `CaptureMode`；`setPerModePostCaptureActions` 写入/删除模式键；设置页新增「按截图模式」卡片，缺省键=跟随全局，取消自定义即删除键 | `PostCaptureRoutingTests`、`ConfigurationSchemaContractTests`、`ConfigStoreTests` |
| 选区操作栏在标注时仍混排 OCR/贴图/更多，框选阶段则被工具按钮占满 | `AreaSelectionActionBar.applyStageVisibility()` 单点切换两阶段：框选=主要动作，标注=工具+完成/取消；完成按原定动作交付，取消丢弃会话 | `SnapzyCaptureTests` |
| 截图界面排除、写入前禁用操作、连续截图与剪贴板 lease 缺少可重复的自动化守护 | `CaptureChromeWindowRegistry` 接受可注入的 window number provider（生产仍读真实窗口）；新增产物状态门禁、20 连拍唯一文件、界面窗口按 session 排除、lease 生成器替换测试 | `CaptureArtifactStoreTests`、`RapidCaptureSequenceTests`、`QuickAccessOperationCoordinatorTests`、`ClipboardArtifactLeaseTests`、`CaptureChromeWindowRegistryTests` |
| 生产落盘绕过 `CaptureArtifactStore`：自动保存直接 `CGImageDestination` 写最终路径，标注覆盖只做临时文件+`replaceItemAt`，临时截图自写 PNG 且先删旧文件再移动，均无解码校验，编码失败可能留下半截文件 | `ScreenCaptureStorage.save`、`ScreenCaptureStorage.replace`（标注覆盖）与 `TempCaptureManager.writeScreenshot`（保留预约路径）统一委托 store；新增 `CaptureArtifactStore.write(to:)`（staging → 解码尺寸校验 → 原子提交，目标已存在时用 `replaceItemAt`），验证失败保留旧文件字节并清掉 staging；删除废弃的 `uniqueFileURL` | `CaptureArtifactStoreTests`、`ScreenCaptureTests` |

| 标注工具被收进「标注」入口再经下拉箭头选变体，常用工具要两次点击；撤销按钮用 `annotations.isEmpty` 判断，删掉最后一个标注后反而不能撤销；没有 Redo 按钮；完整编辑器没有可见 Copy & Close；普通截图复制先关窗后写剪贴板 | 工具区改为常驻独立按钮（分隔线只做视觉分组），属性区默认展开且切换工具不改折叠状态；`SmartAnnotationModel` 新增 `canUndo` 并由历史栈驱动按钮，删除/清空/改属性/移动缩放/文本提交全部入同一事务，连续拖动合并为一步；Inline 与完整编辑器接入 Cmd+Z / Cmd+Shift+Z；Inline Copy 留在会话、Copy & Close 复制成功才关闭；普通截图 Copy 经 `onCaptureReporting` 等剪贴板成功后才关闭选区；完整编辑器与 Quick Access 增加 Copy & Close，失败保留编辑内容 | `AnnotationInteractionParityTests`、`SnapzyCaptureTests`、`QuickAccessTests` |

状态：自动化测试已通过；混合 DPI、跨屏、AX 无权限、按模式配置的实机验收仍待完成。2026-11 标注交互纠偏后，旧的「操作栏阶段分层」契约已废止（旧规则保留在索引中仅供 append-only 校验，实际验收以新条目为准）；标注工具可见性、Undo/Redo、Copy 语义的人工验收见 `docs/engineering/REGRESSION_INDEX.json` 的追加条目。截图可靠性重构已随 `v1.2.2-beta.103` 发布；本轮测试补强随后续 Beta 发布。


## 2026-11-16：标注交互对齐复查补强（beta 待发布）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| 填充矩形按钮首次点击退化成普通矩形：`AreaSelectionAnnotationTool` 没有 `filledRectangle`，工具栏桥接把两种工具合并；水印在 Inline 完全没有入口 | 增加 `.filledRectangle` / `.watermark` 桥接，首次点击以精确工具开始会话；Inline 工具区补齐水印按钮与 `F` / `W` 字母键；文字/水印/计数属性区增加透明度 | `AnnotationInteractionParityTests`、`SnapzyCaptureTests` |
| 撤销属性修改后画布恢复了，但属性栏和下一笔仍用被撤销的颜色：撤销 `Document` 没有包含 `stylesByTool` | `Document` 纳入 `stylesByTool`；`apply` 同时恢复逐工具默认值，撤销后属性栏、工具默认样式与恢复后的对象一致 | `AnnotationInteractionParityTests` |
| 完整编辑器 Cmd+Z 在文本框聚焦时仍会撤销整张图；连续滑块拖动跨多次释放仍合并成一步 | SwiftUI 快捷键在 `inlineTextFocused` 时置空，让位原生文本撤销；`Slider.onEditingChanged` 在释放时结束样式事务，离散色板/线型/填充每次点击各自成步 | `AnnotationInteractionParityTests` |
| Quick Access 标注保存仍自写 staging/PNG，绕过 `CaptureArtifactStore` | `writeAnnotatedImage` 改为 `CaptureArtifactStore.write(to:)`，统一 staging、解码校验与原子替换；失败保留原文件 | `ScreenshotReliabilityTests`、`CaptureArtifactStoreTests` |
| 复制测试直接清空系统剪贴板；复制失败路径无法验证 | `ScreenCaptureModel` / `SnapzyAreaSelectionController` / `QuickAccessManager` 可注入 pasteboard；新增成功与失败路径测试，成功时验证 pasteboard 实际含 PNG，失败时保留 HUD/会话与编辑内容 | `AnnotationInteractionParityTests` |

状态：自动化测试通过；填充矩形/水印的实际鼠标绘制、完整编辑器文本焦点 Cmd+Z、多屏工具栏可达性仍需实机验收。

## 2026-11-17：完整编辑器底栏、真实窗口按键与实机验收补强（beta 待发布）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| 完整编辑器把分享/Pin/删除/取消/复制并关闭/完成全部挤在顶部工具行，与 Snapzy 的底部 Action Rail 不一致；旧 HUD 与贴图编辑器也没有分享/删除入口 | standalone 编辑器新增固定底栏：分享（经 `TempCaptureManager`/`CaptureArtifactStore` 生成稳定文件）、Pin（宿主有 pin 目标时）、删除（宿主有可删除源时）、取消、Copy & Close、完成；工具/属性/历史留在顶栏。QA 编辑器、旧 HUD、区域标注窗口都接入对应回调 | `AnnotationInteractionParityTests`、`05-inline-toolbar.png`、实机记录 |
| 完整编辑器的 Cmd+Z 只靠 SwiftUI `keyboardShortcut`，真实按键路径与文本焦点没有被窗口级验证 | 新增 `SmartAnnotationWindow.performKeyEquivalent`：Cmd+Z/Cmd+Shift+Z/Cmd+Shift+C/工具字母键统一进模型，`NSTextView` 为第一响应者时让位；测试用真实 `NSEvent` 驱动窗口 | `AnnotationInteractionParityTests.fullEditorRoutesRealKeyEventsThroughTheWindow` |
| §6.4 缺延迟粘贴与 Quick Access Copy & Close 一致性验证 | 新增 1.2 秒延迟读取懒加载剪贴板 provider 的测试；QA 编辑器 Copy & Close 抽出 `copyAndCloseAnnotatedItem`，测试同时校验剪贴板、源文件解码尺寸与缩略图 | `AnnotationInteractionParityTests` |
| 旧 Quick Access HUD 的 Copy & Close 没有直接测试 | HUD 的标注模型与 Copy & Close 动作加 DEBUG seam，测试验证复制成功、保存回调收到标注图、编辑器退出 | `AnnotationInteractionParityTests` |
| 实机验收只有清单，没有可重复执行的真实 UI 记录 | 新增 DEBUG `--acceptance-annotation` 模式：跳过 `MacPilotAppServices`（不碰全局快捷键/配置/屏幕采集/TCC），启动真实 AppKit 进程，驱动全编辑器/Inline 工具条并写出截图+`acceptance-record.md`。锁屏会话无法投递鼠标事件时标记为「阻塞」，不冒充通过 | `docs/engineering/acceptance/screenshot-annotation-parity-2026-11-16.md` |
| 完整编辑器可被缩到固定控件以下；区域选区 Copy 只有模型级测试，多显示器/小窗口只有人工清单 | 完整编辑器根视图设置 720×420 内容下限（窗口 `minSize` 720×452），工具面板在内部横向滚动；新增真实 `finishSnapzySelectionAction` 裁剪→剪贴板→关闭测试；验收 App 追加 1024×768/1920×1080 工具栏可达、最小窗口、区域选区 80×50 Copy 检查 | `AnnotationInteractionParityTests`、验收记录 `07-area-selection-copy.png` |

状态：自动化测试与可执行项通过；本次验收会话处于锁屏状态，真实鼠标绘制/窗口激活被标记为阻塞，解锁后重新运行 `--acceptance-annotation` 可补齐。

## 2026-11-17：登录启动只显示菜单栏图标（beta 待发布）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| 两个入口都开启时，开机自启仍出现 Dock 图标：登录启动时 SwiftUI 自己建出主窗口并短暂成为 key/main，`didBecomeMain` 把 `mainWindowVisibilityChanged(true)` 喂给 presence，策略从 `.accessory` 切成 `.regular`；随后 `hideRegularWindows` 只是 `orderOut`，不触发 `willClose`，于是 Dock 图标留在整个会话里 | 新增 `AppPresencePolicy.showsDockIcon(..., isDockIconDeferred:)` 与 `AppPresenceController.mainWindowRequestedByUser()`：登录启动期间（`defersDockIcon = AppLaunchContext.wasLaunchedAtLogin`）Dock 图标推迟，窗口自己出现不算用户请求；只有 `MainWindowOpener.requestOpen` 经 `onUserRequest` 通告真实请求（菜单栏、Dock 点击、深链、Finder 重开）后才解除，之后照常跟随窗口。Dock-only 配置忽略推迟，避免开机后无路可回。不在 `orderOut` 里隐藏 Dock 图标 | `AppPresenceTests`、`MainWindowOpenerTests`、`AppLifecycleTests` |

状态：自动化测试通过；真实登录启动（重启/注销后 SMAppService 拉起）的外观验收仍待实机确认。

## 2026-11-17：截图工具栏功能回归与视觉整理（beta 待发布）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| 用户从 beta.102 升级后找不到截图上传：上传仍存在，但上一轮重构把它只留在「更多」菜单，Action Rail 没有直接入口 | 上传恢复为截图操作栏的直接按钮（`icloud.and.arrow.up`），继续使用原有 `ImageHostingUploadCoordinator`/Keychain/图床设置；「更多」菜单移除重复项。贴图右键上传保持不变 | `AnnotationInteractionParityTests.uploadIsADirectActionOnTheRailAgain` |
| 完整编辑器的工具面板被颜色/线宽等属性控件挤到只剩一个可见图标，用户误以为大量工具被删 | standalone 完整编辑器拆为独立的两行：工具行（14 个工具 + 撤销/重做/清空）与属性行（颜色/线宽/透明度/填充/线型）；工具行获得完整宽度，所有工具可见，属性不再压缩工具 | 验收 App `01-full-editor-bottom-bar.png`、AX 工具树、`toolbarUsesTheSharedCardMetrics` |
| 截图工具栏边距、圆角和图标风格不统一 | `CaptureChromeStyle` 统一为 30pt 圆角方形 chip（9pt 圆角）、10pt 卡内边距、7pt 行距、6pt 项距、18pt 分隔线；文字/计数/水印/聚光灯图标改为 `character.textbox`/`list.number`/`seal`/`viewfinder`；Copy & Close 使用合成的“双文档 + 勾选”图标 | `toolbarUsesTheSharedCardMetrics`、`SnapzyCaptureTests`、`05-inline-toolbar.png` |
| 贴图钉住、上传仍要展开菜单/找不到；用户要求放到“截图的右侧竖着列”，而不是工具栏右侧放一圈 | 工具/属性留在截图下方的横栏；OCR/贴图/上传/保存/复制/更多/关闭移入截图右侧常驻的竖向动作栏，标注会话只追加复制并关闭/完成；`AreaSelectionRailLayout` 负责右侧优先、左侧/内侧兜底，`AreaSelectionBarLayout` 避让动作栏，两者不重叠 | `pinAndUploadLiveOnThePersistentSideRail`、`postSelectionHudInstallsTheToolDeckAndSideActionColumn`、`05-inline-toolbar.png` |
| 标注文字输入白底白字看不清；水印按钮与文字按钮输入框完全相同，用户不知道区别 | 文字工具使用白底黑字浅色胶囊，水印工具使用黑底白字深色胶囊，placeholder 分别为“文字”/“添加水印”；水印提交后是半透明白字，文字提交后也只有字形、不再绘制任何背景底板。文字/水印样式通过 `textEntryUsesDarkCapsule` 与渲染像素测试钉住 | `watermarkTextEntryLooksDifferentFromTextEntry`、`smartAnnotationTextIsBareGlyphsWithoutABackgroundPlate`、实机 `10-text-entry.png`/`11-watermark-entry.png` |

功能对照结论：以 `v1.2.2-beta.102` 为基线，`AreaSelectionAction`、`AppText` 键集、Quick Access/贴图上传菜单均没有功能删除；上传只是入口层级变化，已恢复为直接按钮。

## 2026-11-19：新增看图（未发布）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| 独立看图应用的进程级资源和启动入口不能直接用于常驻 MacPilot | 首页默认关闭；Runtime 空闲无解码资源；窗口共享按需 Session，关闭时取消并丢弃过期结果；Finder 等配置加载，文件不进入截图深链 | `ImageViewerLifecycleTests`、`ImageViewerFileRouterTests`、`ImageViewerConfigurationTests` |

真实 Finder 打开、升级降级、打印、混合 DPI 与性能验收，见 [看图验收记录](acceptance/image-viewer.md)。

## 2026-11-19：并发测试中的端口信号与远程空闲截止时间（未发布）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| 普通全量测试下模拟 SIGKILL 没有发出，或远程 hello 尚未进接收路径就超时：前者夹具用扫描次数模拟进程是否存在，后者用 3 秒真实墙钟约束 MainActor 和本地 TCP | 端口用例在确认前主动插入扫描且夹具只随模拟信号改变；远程用例等待真实服务端响应，用受控时钟分别跨越旧、新截止时间，保留生产默认超时与检查间隔；不加豁免 | `LocalPortsModelTests.forceKillConfirmationSendsSigkill`、`RemoteConnectionIdleWatchdogTests.inboundTrafficKeepsTheConnection` |

对照：看图之前的 `9b18182` 全套复现端口失败，远程用例当次通过。修复后两项在专项与并发全套中均通过；选择器安全门禁通过（无豁免），普通全套仍有四项已登记时序失败，不把该次全量结果记作通过。

## Finder 打开图片却只显示设置（未发布，待实机验收）

关闭看图时外部请求走启用提示、SwiftUI 冷启动自动显示设置、扩展将图片标成目录 → 显式打开只建临时文档运行时，冷启动抑制设置的自动出现，扩展一次提交所选文件的真实 URL → `RightClickOpenWithTests`、`ImageViewerFileRouterTests`、`ImageViewerLifecycleTests`、`MainWindowOpenerTests`。

## 看图窗口旁仍出现设置（未发布，待实机验收）

上一版靠一次启动快照及一次隐藏，队列排空后至文档显示前也未区分 reopen → 只有显式设置请求才解除设置窗口抑制，文件交付完成前及图片窗口可见时拦住隐式设置入口 → `ImageViewerFileRouterTests`、`MainWindowOpenerTests`（`img-004-settings-explicit-open`）。

## 看图设置：格式关联替代最近打开（未发布，待实机验收）

移除最近文件状态；格式关联只读系统当前结果，显式选择后仅修改所选具体类型并回读确认，不改变注册等级、其他格式或首页开关 → `ImageViewerAssociationTests`（`img-005-format-associations`）。

## 2026-11-19：Beta 118 门禁的关联 URL 尾斜杠（未发布）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| macOS 15 的 `URL(filePath:directoryHint:.isDirectory)` 保留 `/Preview.app/`，生产规范化得到无尾斜杠 URL，三个关联用例把测试夹具与模型结果直接比较而失败；macOS 26 与本地未复现 | 夹具先走与 `ImageViewerAssociations.canonicalURL` 相同的 `standardizedFileURL.resolvingSymlinksInPath()` 再比较；不改生产关联逻辑，不加豁免 | `ImageViewerAssociationTests` |

对照：`v1.2.2-beta.118` 的 Regression Gate（macos-15）失败 13 个断言，`dist` 跳过、未发布；修复随下一个 Beta 重新走全部门禁。

## 2026-11-20：看图空白和设置、Dock 一起弹出（待 Finder 实机验收）

设置首次打开后一直允许隐式显示，画布也没直接收到解码帧变化 → 关闭设置即收回窗口显示许可，只有实际设置窗口驱动 Dock；画布随解码帧和变换重绘 → `MainWindowOpenerTests.closingSettingsRevokesPermissionForTheNextAutomaticPresentation`、`ImageViewerWindowTests.decodedPhotoAndRotationInvalidateTheNativeCanvas`。

## 2026-11-25：截图标注工具栏悬停名称、拖动与文字输入框（待实机验收）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| 截图选区工具栏只有图标；AppKit 原生 `toolTip` 依赖系统提示计时器，非激活的选区面板不保证弹出，用户无法确认每个图标做什么 | 工具/动作 chip 与拖动 grip 增加自己的 hover tracking area，由工具栏在选区窗口内绘制标题气泡（无需系统 tooltip 计时器）；`toolTip` 与 accessibility label 仍保留 | `SnapzyCaptureTests.hoveringAToolbarChipNamesItWithoutTheSystemTooltipTimer` |
| 工具栏左侧的「拖动工具栏」只是一张 `NSImageView`，没有任何拖动实现；工具栏落到选区内部时无法移开，挡住要标注的区域 | 新增专用拖动 grip：`mouseDown/Dragged` 按窗口坐标增量移动工具卡；`AreaSelectionOverlayView` 把用户偏移保存为相对自动锚点的 `actionBarDragOffset`，并在每次 `layout()`/属性行伸缩后重新套用、限制在屏幕内，避免拖动后自动弹回 | `SnapzyCaptureTests.toolbarDragHandleMovesTheDeckAndRelayoutKeepsTheUsersPlacement` |
| 文字输入框画在点击点上方（`anchor.y - fieldHeight`），提交后的字形从点击点向下画，输入态与最终位置上下差一整行；空框固定 28pt 高，输入后又按 12/6pt padding 放大，和字形范围不一致；文字不能缩放 | 输入框改为与最终字形相同的 top-leading 锚点；非空时宽高按真实字体度量（无 28pt 地板），字体按截图宽度/显示缩放和 `SmartAnnotationRenderer` 使用同一公式；右下角新增缩放把手，拖动时按比例改 `textScale`，提交的样式随标注进入 Undo/Redo，导出的字号同步变化 | `SnapzyCaptureTests.textEntryFieldUsesTheExactGlyphBoundsAfterTyping`、`typedTextAndFinalGlyphsShareTheSameTopLeadingAnchor`、`inlineTextFontMatchesTheRenderedImageAtAnyDisplayScale`、`draggingTheTextFieldHandleScalesTheTextWithItsBox`；`AnnotationInteractionParityTests.aResizedTextEntryKeepsItsScaleThroughUndoAndRedo` |

状态：自动化测试通过；非激活面板上的悬停气泡、真实鼠标拖动、文字输入/缩放与导出像素一致性仍需实机验收。

## 2026-11-25：截图标注工具栏层级与 hover 标题省略号（beta 124 待发布）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| 工具栏拖进截图选区后拖不动：内嵌标注画布最后 `addSubview`，AppKit 命中测试按 subview 顺序而不看 layer `zPosition`，鼠标落在画布而不是拖动 grip | `showEmbeddedAnnotationEditor` 与 `attachAnnotationSession` 安装画布后重新把动作栏、工具卡抬到 subview 最前；layer z 只负责绘制层级，命中测试必须单独保证。工具卡拖进选区后仍能接收拖动 | `SnapzyCaptureTests.deckInsideSelectionStaysAboveTheInlineCanvasForHitTesting` |
| 悬停名称大多数显示成“……”。气泡用 `NSTextField.intrinsicContentSize` 算宽度，但那只是裸字形宽，不包含 `NSTextFieldCell` 的内边距；标签帧比实际文本窄 3–4pt，被截断 | 气泡宽度改用 `sizeThatFits`（含 cell 内边距）并多留 2pt；标签帧必须不小于实测文本宽度，禁止把中文工具名截成省略号 | `SnapzyCaptureTests.hoveringAToolbarChipNamesItWithoutTheSystemTooltipTimer` |

状态：自动化测试通过；工具栏在真实选区内拖动与悬停气泡外观仍需实机验收。

## 2026-11-25：水印工具与文字工具几乎相同（beta 125 待发布）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| 用户认为【文字】和【水印】没有区别。根因：`SmartAnnotation.watermark` 只存一个文字插入点，渲染器也调用同一套 `drawText`；默认只是白字、透明度 0.76，既没有区域、旋转，也没有低透明度，实际就是第二个文字工具 | 水印改为区域标注 `.watermark(String, CGRect)`：默认区域为画布 42%×18%，以点击点为中心并夹在画布内；默认白字、22% 透明度、居中 -24° 倾斜、带轻微阴影；输入态显示虚线区域框、输入框放在区域中心，提交后文字在区域内居中倾斜；区域可像其他盒状标注一样移动/缩放，预览与 `SmartAnnotationRenderer` 使用同一几何 | `AnnotationInteractionParityTests.watermarkTextEntryLooksDifferentFromTextEntry`、`watermarkUsesARegionAndDefaultTextUsesAPoint`；`ScreenCaptureTests.watermarkRendersAFaintCenteredRegionMark`；实机 `11-watermark-entry.png` 的虚线区域 |

状态：自动化测试与真实 AppKit 输入态验收通过；最终导出的水印观感仍需实机截图确认。

## 2026-11-25：Beta 125 发布在 DMG 阶段磁盘耗尽（待 beta 126 发布）

| 现象 / 根因 | 修复与不变量 | 回归入口 |
|---|---|---|
| `v1.2.2-beta.125` 的 `dist` 连续两次在 `hdiutil create` 报 `No space left on device`，发布未生成；流水线先做了 arm64、x86_64 和 universal 三次构建，`.build`/`build` 留下多 GB 缓存，DMG 还要复制整个 app 并创建临时读写镜像 | `release-common.yml` 在 universal `distribute-app.sh` 完成、app 与 ZIP 已定稿后，先打印磁盘余量并删除 `.build`、`build`、`DerivedData`，再执行 `build-dmg.sh`；清理只针对可重建缓存，不触碰 app、ZIP、签名或公证产物。已推送的 `beta.125` tag 保持不动，修复用新 beta tag 发布 | `SigningRequirementTests`、`python3 Tests/Release/stapler-retry-tests.py`，以及下一次 `dist` 的 DMG 生成与 Release 资产核验 |

状态：修复已进入新 beta；上一失败 tag 不移动，不作为已发布版本。
