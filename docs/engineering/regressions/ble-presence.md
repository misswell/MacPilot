# ble-presence — BLE 身份识别、地址轮换与在场检测

规则：`ble-001-unlock-state-rearm`（状态机重新武装，10+ 修，全仓最大热点）、`ble-002-address-rotation`（地址轮换）、`ble-003-background-session-misjudge`（后台会话误判）、`ble-004-reverse-presence-cadence`（反向 presence cadence）。证据链见 [../REGRESSION_CATALOG.md](../REGRESSION_CATALOG.md) B1–B4。

## 不变量

### 状态机重新武装（ble-001-unlock-state-rearm）

每次「解锁/监控在 X 之后失效」的修复，都只补了当时那条路径。任何改动必须回答：**这个状态还能被什么事件重新触发？** 只依赖单一回调的恢复路径视为死路。具体：

- system wake、display wake、监控停滞、重连、retry 掉臂之后，挑战/解锁必须重新武装。
- 后台广播暂停与真实离开必须区分（ble-003-background-session-misjudge）：iOS 后台挂起导致 RSSI/广播静默 ≠ 设备离开；判定离开必须有独立超时证据。
- 手动锁屏不得被自动解锁覆盖。
- 旧连接回调不得修改新连接状态；地址轮换（ble-002-address-rotation）不得误判离开，历史地址不得产生多余定时器。

### 反向 presence（ble-004-reverse-presence-cadence，原 AGENTS.md 全文）

- 挑战 cadence 的生命周期属于 production：只有 `startProduction`/`stopProduction` 可以 arm 或结束它。`issuePresenceChallengesIfNeeded` 和 `didUnsubscribeFrom` 必须把「无 manager、未上电的 radio、空订阅列表、未发布的服务」当作**瞬态**——历史上在任何一个上 cancel 任务，都会让仍订阅着的手机直到 app 重启都得不到挑战，因为重新武装依赖一个不会再来的 subscribe 回调。
- 反向链路转换必须持久化，不只是内存态：production start/stop、subscribe/unsubscribe、cadence wait/resume、≥30s 后恢复采样的已验证样本，都写 `DiagnosticLog` 的 `BLEReverse` 通道；逐样本拒绝按 10s 节流。`log()` 只写安装版看不到的 ring buffer，链路丢失曾因此无法诊断。

#### Challenge 与 RSSI 样本时序

- Challenge 的 15 秒有效期由 Mac `ContinuousClock` 单调时钟控制；它限制 nonce 重放和迟到响应。手机端 4 秒 RSSI 请求超时会将对应操作标为失效并留在队列中，迟到回调仍归属原 nonce，必须丢弃或只触发读取最新 nonce。
- 样本 `sampledAt` 是 iOS 收到 `readRSSI()` 回调后构造签名数据时写入的手机墙钟值，不是 CoreBluetooth 的底层测量时间。它可用于诊断；`isFresh`/`isValid` 不作为跨设备生产授权门槛。生产路径由 Mac 校验 live challenge、Mac ID、nonce、配对密钥 HMAC 和 RSSI 范围。
- 配对密钥持有者可以自选签名的 RSSI 和时间戳；HMAC 认证配对身份、challenge 防重放，不能证明对端诚实报告了无线电读数。不得把“时间戳新鲜”描述成对恶意配对客户端的防伪措施。
- Tripwires：协议包 `ReversePresenceSampleTests.localChallengeAcceptsClockSkewAndConsumesNonceExactlyOnce`、`localChallengeRejectsExpiryIdentityAndTamperingWithoutConsuming`；iOS `ReversePresenceCentralTests` 的 `aMeasurementOnlyConsumesTheChallengeItWasTakenFor` 与 `ReversePresenceOperationTrackerTests`。
- 新学 alias 的首个样本仍可能命中 `unlock skipped reason=noFreshSignal`（presence 在 `lastRSSI` 记录前重算）；`updateMonitoredPeripheral` 尾部的逐样本 retry 就是解锁它的。不要当冗余删掉。
- 挑战过期用本地连续时钟（`5f95fb3`），不得依赖会被挂起的 Timer/Task.sleep。

### 远端发现（关联 RemoteBonjourPublisher 不变量）

发现可用性必须跟随真实 DNS-SD 注册回调，绝不用 `NWListener.ready`（ready 的 socket 可与 `PolicyDenied`、无广播并存）。注册失败必须自动恢复，且不重置系统权限、不重启 app、不移除配对；保持 listener 与既有已认证连接存活。不得从单个 policy error 推断用户拒绝授权。改动后跑 `RemoteBonjourPublisherTests`（含重复失败/恢复与过期回调）。

### 双端版本前提

「BLE 搜不到手机」「没有随航」类报告先核对两端版本（PilotNest TestFlight 与 MacPilot beta 版本下限），再排查——见项目 memory 与 docs/REMOTE_CONTROL.md。

## 必跑测试

`BLEWakeRecoveryTests`、`BLEMonitoringRestorationTests`、`BLERediscoveryTests`、`BLEManualLockSuppressionTests`、`BLEIdentity*`、`BLEUnlockAttributionTests`、`BLEPresenceAuthenticationTests`、`BLEAdvertisementLivenessTests`、`BLEBackgroundSessionTests`、`BLEReversePresenceTests`、`ProximityGATTProductionRestartTests`、`RemoteBLEBackoffTests`；协议包内 `ProximityGATT|ReversePresence`。

已知抖动（不要追）：`BLEWakeRecoveryTests.overdueSignalTimeoutClearsThePreSleepPresence` 属共享 MainActor 饥饿类，`--filter` 单跑通过即可，见 AGENTS.md 抖动清单。

## 人工验收（须用户明确授权与安全环境）

- 真实睡眠/唤醒、合盖再开盖、手机蓝牙地址轮换（重启蓝牙）后监控不中断。
- 手机走离再走回范围；息屏放兜半小时后离开，到超时才锁而不是立刻锁。
- 手动锁屏不被自动解锁覆盖。
- 手机订阅反向 presence 后重启 MacPilot，挑战仍按节奏到达；断开重连后恢复。
