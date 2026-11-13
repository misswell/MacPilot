# 问题与修复速记

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
