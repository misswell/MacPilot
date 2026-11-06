# 问题与修复速记

每次修复追加一行：**现象/根因 → 修复与不变量 → 自动回归**。旧历史见 [目录册](REGRESSION_CATALOG.md)；未解决、未发布、待实机验收分开标明。

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
