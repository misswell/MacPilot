# 反向 GATT 实现与验收记录

日期：2026-10-22（Asia/Shanghai）。本报告区分代码/自动化验证与真实无线链路验收。

## 范围与兼容性

在已有实验链路上补齐恢复功能，继续使用 `ProximityGATTService`、
`ProximityBLEPeripheral` 和 `ProximityBLECentral`，未引入第二套反向协议。
服务为 `6D616350-696C-6F74-0002-000000000001`；读、通知、写特征分别为
同一空间的 `…0002`、`…0003`、`…0004`。截图中的 `69773B01-…` 是 Central
设备标识，不能拿来替换通知 UUID。

未改动 `RemoteBLECentral`、`RemoteBLEPeripheral`、`RemoteBLEService`、
`BLEUnlockModel`、RSSI 监控、设备绑定、配对认证和 L2CAP 协议/生命周期。
既有 `StoredConfiguration` 的编码字段及默认启用状态未变。
iOS 只新增独立测试开关 `reverseGATTTest.wantsToRun`（UserDefaults），默认为关；
手动开始后持久化运行意图，停止后清除。已有 `bluetooth-peripheral` 后台模式保留。

## 实现

- Mac 独立广播和服务发布，错误退避重试，蓝牙恢复后重新发布；广播状态和订阅数独立展示。
- 只接受已订阅的写入者；ATT 批次先整体校验再回应一次；通知定向发送给对应 Central。
- 通知队列最多 8 个订阅者，每个订阅者最多一条；满时保留未发出的数据，等待 ready 回调；15 秒过期，取消订阅/停止/蓝牙重置时清理。
- iPhone 只扫描测试服务；自动发现、连接、读取、订阅和发送 16 字节随机载荷。
- 同时最多一个请求在途，15 秒超时；旧通知、重复通知和不匹配通知不计成功。发送确认未结束时也不发送下一条。
- 断连、服务移除、发现/订阅/写入失败自动恢复；退避为 1/2/4/8/16 秒，之后保持最多每 30 秒一次。
- 固定 Central 恢复标识，在应用启动时按明确保存的意图重建；恢复后重新校验服务、特征和订阅，再执行新的回环。
- 测试页退出不销毁运行中的会话。回到前台检查旧请求是否过期，并可再次发送。
- 中英文诊断显示连接、订阅、字节数、最近发送/接收/校验时间及错误，保留协议 UUID、导出日志并新增清理日志。
- 日志带时间和会话 UUID，不记录载荷、配对密钥或认证材料。Mac“通知已入队”与 iPhone“回环校验成功”明确区分。

## 变更文件

| 文件 | 用途 |
| --- | --- |
| `Packages/MacPilotRemoteProtocol/Sources/MacPilotRemoteTransport/ProximityGATTSession.swift` | 单请求、定向通知队列与退避的纯逻辑；不改 wire 常量 |
| `Packages/MacPilotRemoteProtocol/Tests/MacPilotRemoteProtocolTests/ProximityGATTSessionTests.swift` | 6 项会话与边界测试 |
| `Sources/MacPilot/BLE/ProximityBLEPeripheral.swift` | 原有实验 Peripheral 的生命周期、写入、背压和诊断 |
| `Sources/MacPilot/MacPilotApp.swift` | 原实验卡片与双语诊断 |
| `Tests/MacPilotTests/ProximityGATTLocalizationTests.swift` | Mac 新文案覆盖 |
| `iOS/MacPilotRemote/MacPilotRemote/Networking/ProximityBLECentral.swift` | 原有实验 Central 的恢复、重连、单请求和诊断 |
| `iOS/MacPilotRemote/MacPilotRemote/Features/Settings/ProximityGATTTestView.swift` | 原测试页接入共享会话、诊断与重复测试 |
| `iOS/MacPilotRemote/MacPilotRemote/App/InterfaceOrientationController.swift` | 只给已有 AppDelegate 增加启动恢复入口，未改方向策略 |
| `iOS/MacPilotRemote/MacPilotRemote/App/MacPilotRemoteApp.swift` | 独立测试的前后台通知 |
| `iOS/MacPilotRemote/MacPilotRemote/Resources/Info.plist` | 合并 Central 后台模式与蓝牙用途说明 |
| `iOS/MacPilotRemote/MacPilotRemote/Resources/RemoteText.swift` | iOS 双语文案 |
| `iOS/MacPilotRemote/Tests/ProximityGATTOptInTests.swift`、`RemoteTextProximityGATTTests.swift` | iOS 默认关闭/停止与新文案测试 |
| `iOS/MacPilotRemote/MacPilotRemote.xcodeproj/project.pbxproj` | xcodegen 生成的测试文件登记 |
| `iOS/MacPilotRemote/ScreenshotTests/ReverseGATTHardwareUITests.swift` | 默认跳过、显式启用的真机前台/重复/后台回环测试 |
| `Tests/Hardware/ReverseGATT/` | 复制并校验生产 Peripheral 的隔离宿主准备工具和操作说明 |
| `.github/workflows/build.yml` | 主分支增加 GATT 文案与共享协议回归门禁 |
| `docs/REMOTE_CONTROL.md`、本报告 | 行为、操作、系统限制与真实验证记录 |

## 自动化验证

共享包 `swift test --package-path Packages/MacPilotRemoteProtocol`：115 tests / 20 suites 通过。
新增测试覆盖单请求、随机请求相关性、重复/旧/错误长度通知、超时、队列容量与订阅者隔离、
过期/取消订阅/停止清理、连续失败退避上限与重置。双语测试包含所有新增界面文案。
iOS 新增默认关闭、重复停止、清理日志与独立 UserDefaults 意图测试，不启动真实蓝牙。

- Mac fresh release：`swift build -c release -Xswiftc -warnings-as-errors --scratch-path /tmp/octopilot-release-20261022` 通过，无 warning/error。产物已保留：`/Users/guofeng/Code/solo/OctoPilot/build/reverse-gatt-validation/MacPilot`。
- iOS generic device `build-for-testing`（`CODE_SIGNING_ALLOWED=NO`）通过。产物：`/tmp/octopilot-ios-device-20261022/Build/Products/Debug-iphoneos/PilotNest.app`，仅供编译验证，未签名、未安装、未上传 TestFlight。
- Mac 首次完整测试：1609 tests / 187 suites，13 issues。已知计时波动 9 issues，另有 ClosedLid 三项心跳测试的 4 issues；后者整个套件隔离运行 15/15 通过，最终完整复验结果见下方。

- Mac 最终完整复验：`env -u MACPILOT_TEST_DISPLAY_BLANK swift test --jobs 1 --no-parallel`，1609 tests / 187 suites，0 failures。此前失败项目均通过；不改动原测试或屏幕行为。
- iOS AgentSpace 模拟器（iPhone 17 Pro / iOS 26.5）：新增 GATT opt-in/localization 与 3 个已有 BLE 套件共 12/12 通过。
- iOS 实体 iPhone：Automatic Apple Development 签名 `build-for-testing` 通过；`ProximityGATTOptInTests` 1/1 通过，验证 Xcode 26.6 runner 可在 iOS 27.0.1 上运行。该纯逻辑结果不是无线验收。

- 专用硬件 UI 测试：`MacPilotRemoteScreenshots` scheme 的 `generic/platform=iOS` 签名 `build-for-testing` 通过，包含默认 skip 的 `ReverseGATTHardwareUITests`。
- 隔离 Mac 宿主：生产 Peripheral 源码 SHA-256 与复制源一致，fresh release warnings-as-errors 编译、Developer ID 签名及 strict codesign 校验通过。
- 无线执行当前受环境阻塞：AgentUse 蓝牙隐私页只有 `agentspace-worker` 项且关闭，宿主实际返回 `Bluetooth unauthorized`；AgentSpace 工具要求隐私权限由人亲自授予，不能代点。宿主已正常收尾，没有成功广播。手机在运行器探路测试后再次变为 `unavailable`，无线 UI 测试尚未开始。

已保留的 PilotNest 开发测试 App：`/Users/guofeng/Code/solo/OctoPilot/build/reverse-gatt-validation/PilotNest.app`。
它不是 App Store/TestFlight 分发包；此次没有上传 TestFlight。

## 真机验收状态

最初 iPhone 15 Pro为 `unavailable`；用户随后连接了设备，状态变为 `available (paired)`。
设备系统为 iOS 27.0.1（24A446），Developer Mode Enabled。用户确认旧 MacPilot 的实验服务原本未广播。
硬件验收使用 AgentSpace 中独立 bundle ID 的测试宿主，复制并核对实际生产 Peripheral 源码，
不启动另一个完整 MacPilot，不替换/退出用户已安装的 MacPilot。
用户提供的截图证明旧实验版本曾记录订阅和 16 字节通知入队，不能证明本次修改后的后台恢复或完整回环。
没有把模拟器编译、纯逻辑测试或这张旧截图计为以下真机验收通过。

| 验收项 | 本次状态 | 需要的证据 |
| --- | --- | --- |
| 前台连接、16 字节匹配回环 | 待真机 | 本次构建两端日志、iPhone verified 计数 |
| iPhone 锁屏维持与断连恢复 | 待真机 | 锁屏期间真实事件及恢复延迟 |
| iPhone 后台连接与回环 | 待真机 | background 标记后的新回环、实际耗时 |
| 任一端蓝牙关闭/开启 | 待真机 | 关闭诊断、poweredOn 后自动恢复 |
| Mac 停止/重新广播 | 待真机 | service removed/断连、重新发现与新回环 |
| 原 RSSI/锁屏解锁/远程/L2CAP 回归 | 自动化结果另列，真机待测 | 授权隔离会话的实际行为 |
| 新旧链路并行及独立停止 | 待真机 | 同时运行与停止测试后旧链路日志 |
| 失败/重复/满队列/多次启停 | 纯逻辑已测；CoreBluetooth 运行时待测 | 模拟逻辑结果及真实委托/缓冲区事件 |

操作步骤见 [REMOTE_CONTROL.md](REMOTE_CONTROL.md#on-device-acceptance)。
本次不停止、不替换、不重启用户 `/Applications/MacPilot.app`，也不操作用户锁屏或登录界面。

## 系统限制

`bluetooth-central` 与状态恢复允许系统按调度交付蓝牙事件，不保证固定扫描、重试或回环延迟。
本地 Task 在后台可被挂起；本实现不声称定时器能够持续唤醒应用。
用户手动强制退出 App 后不保证系统重启它。Mac Peripheral 没有 Central 物理连接建立/断开的
完整回调，因此只如实展示订阅状态，不能由“已广播”推断“iPhone 已连接”。

参考 Apple [Core Bluetooth 后台处理](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)、
[TN3115 恢复启动规则](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)
和 [ATT 写入批次响应要求](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanagerdelegate/peripheralmanager(_:didreceivewrite:))。
