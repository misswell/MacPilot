# 问题与修复速记

每次修复追加一行：**现象/根因 → 修复与不变量 → 自动回归**。旧历史见 [目录册](REGRESSION_CATALOG.md)；未解决、未发布、待实机验收分开标明。

## 2026-11-06：8 项源码修复

修复提交 `a071a52` / 合并提交 `ef835c0`；本地安全门禁通过；目标 beta.98 候选，实际发布以 GitHub Release 为准；真实设备验收未做。

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

黑屏补充：只读观察捕获“系统休眠 → ANY-only 变化 → 旧版解除保持”的同类路径；**00:11 那次具体事件源仍未知**。手机端修改需另行 iOS 分发，Mac beta 不等于 TestFlight 上传。

## 2026-11-06：验证与发布问题

| 问题 | 处理与以后规则 | 状态 |
|---|---|---|
| 并发测试堵塞 MainActor，XPC 超时 | 显式串行跑相同集合，不删测试或加豁免 | 本地完整门禁通过 |
| 测试写全局 termination owner 干扰其他套件 | 注入注册动作并断言对象，不污染全局 | 已修复并回归 |
| 文件树含 main 改动，但提交图缺 main，push 被拒 | 正常 merge；push 前核验 main 是祖先；树等价时复用检查，不 force push | 已处理 |
| 隐藏日志未上传，CI 失败无诊断附件 | 上传隐藏日志，失败输出最多 50 行上下文 | `c16114e` / `99b7356` 已修改，CI 确认中 |
| CI：无 GUI runner 无法启动仿真 App；多份 Xcode 使旧路径期望不稳定；runner 的 `ditto` 未生成 provenance；ScreenCapture 墙钟阈值 0.1 秒实测 0.108 秒；菜单栏测试错过 5ms 移除窗口；资源生命周期测试用固定 50ms 窗口观察 one-shot timer；macOS 15 回归命令日志在测试中途结束且无 Swift Testing 总结 | 注入启动与注册查询、显式创建并验证 provenance、以事件顺序验证截图 overlay；菜单栏重插阶段可控暂停并等待真实 remove+insert 事件；BackgroundTask 注入默认 Task.sleep，one-shot 测试用 continuation 推进并等待真实动作完成；回归失败输出命令退出码并收集精简崩溃报告栈；不删回归覆盖 | 定向回归通过（4/4；菜单栏suite 13/13；ResourceLifecycle 9/9；ProcessIconStore+QuickAccess 21/21）；完整本地safe gate 0 waiver、严格Release构建均通过；macOS 15 退出码/根因待CI诊断；未发布 |

发版采用一个 Luna 执行者、持久检查点、同源码检查复用、一个等待脚本和一次最终验收；必要诊断修改合并后一次推送。问题解决后更新原行状态，不把“已修改”写成“已发布”。
