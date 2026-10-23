# 反向识别后台重连修复（2026-10-23）

## 现场证据

用户确认手机已回到电脑旁，前台可以发现，问题是后台不重连。
本轮未先打开手机 App 或重启 MacPilot 来改变现场。
已安装的 MacPilot 为 1.2.2-beta.52，12:02 启动。
`~/Library/Logs/MacPilot/Diagnostics.log` 显示：

- 16:33:57：最后一条认证反向 RSSI 样本，−83 dBm。
- 16:34:01：手机取消 presence 订阅，订阅者为 0。
- 16:34:02：challenge cadence 等待 `no presence subscriber`。
- 截至 16:41:12：仍没有新的订阅或反向样本。
- 用户重新接入、解锁手机后，16:42:14 旧版恢复订阅并送回 −47 dBm 样本；此时修复尚未安装，不能计为新版修复成功。

掉线前信号曾下降到 −87 dBm；它可以解释链路为何丢失，但不能解释手机回到旁边后一直不恢复。
Mac 日志证明断连后没有恢复订阅，不足以单独证明手机具体在哪条恢复分支停住。
手机当时未接入调试器，没有把源代码推断冒充已取得的手机后台调用栈。

## 代码问题与修复

`ReversePresenceCentral` 的正常断连和 GATT 拒绝恢复原先都先等待
`Task.sleep`，之后才调用 `CBCentralManager.connect`。退避可能达到 30 秒，
GATT 故障冷却最长 60 秒；iOS 挂起应用后，这些任务没有继续执行的保证。
原有全局退避仅在启动时重置，成功通信不会重置。
此外，12 秒 setup timeout 从发起连接就开始，可能取消仍在等待范围恢复的请求。

修复为：

- 在蓝牙回调内同步提交连接请求，把退避交给系统 `CBConnectPeripheralOptionStartDelayKey`。
- 主动取消尚未完成时保留恢复计划，等待对应断连回调后提交一次，重复回调不重复提交。
- 按 peripheral 记录 1/2/4/8/16/30 秒退避；认证采样被 Mac 接受后只重置对应设备。
- GATT 初始化超时从连接成功开始；不使用应用定时器取消系统正在等待的连接。
- 停止、无线状态清理和忘记配对仍丢弃恢复计划；无密钥的 Mac 不自动重试。
- 不改变 Mac 广播、challenge cadence、认证载荷、RSSI 判定或锁屏解锁策略。

Apple 的[后台处理文档](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
说明后台事件处理时间有限，而已提交的连接请求没有超时，可由系统等待外设重新进入范围。

## 验证

新增共享状态机回归覆盖同步产生系统请求、取消完成后单次提交、停止/忘记清理、
成功后按设备重置退避和故障冷却覆盖。原有 CoreBluetooth 对象没有可注入的完整运行时测试接口，
这些测试能验证恢复计划，不能证明 iOS 实际后台调度或真机无线恢复。

- 共享包：`swift test --package-path Packages/MacPilotRemoteProtocol --jobs 1 --no-parallel`，151 tests / 25 suites 通过，包含本次 5 项恢复状态机回归。
- iOS 模拟器：`xcodebuild ... test`，88 tests / 17 suites 通过。
- Mac BLE 相关：`swift test --filter 'BLE|ReversePresence|ProximityGATT|ConfigurationSchemaContractTests|ConfigStoreTests'`，187 tests / 21 suites 通过。
- fresh release：`swift build -c release -Xswiftc -warnings-as-errors`，通过，0 warning。
- 新版尚未部署到实体手机，不能把 16:42:14 的旧版重新订阅算作修复后真机通过。

本修复使系统在应用仍获得蓝牙回调执行时间时就持有待连接请求；不承诺系统固定恢复延迟，
也不承诺用户强制结束 App 后可以自动重新启动。验证需要在已安装新版的手机上，
保持 App 后台经历真实断连，再回到蓝牙范围，核对未进入前台之前的新订阅和认证样本。

## 发布

- Mac Beta：`v1.2.2-beta.53`
- PilotNest：1.2.5 (49)，Build ID `eecd5dcb-f072-4422-b66e-71306ce5d80e`，`VALID`，内部组
- 签名门禁证据见 `docs/APP_STORE_RELEASE_CHECKLIST.md`
