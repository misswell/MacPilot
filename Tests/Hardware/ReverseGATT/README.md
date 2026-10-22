# 真机反向 GATT 验收宿主

此目录只用于显式真机验收，不属于 MacPilot 可执行 target，不会随产品发布。
`prepare-host.sh <新的绝对临时目录>` 创建临时 SwiftPM 工程，复制并打印生产
`ProximityBLEPeripheral.swift` 的 SHA-256，依赖仓库原共享 transport；不重写无线协议。
构建、签名和运行必须交给构建代理。

将产物包装成独立 bundle ID 的 LSUIElement app，包含蓝牙用途说明，在 AgentSpace
后台会话运行，环境变量 `MACPILOT_GATT_HARDWARE=1`。命令行唯一参数是控制文件绝对路径；
写入 `<唯一序号> start`、`<唯一序号> stop` 或 `<唯一序号> quit` 即可控制。
可选 `MACPILOT_GATT_HARDWARE_CYCLE_SECONDS=30`：每 30 秒最后 4 秒停止该测试服务，
其余时间广播，用于触发手机后台断连/恢复。宿主输出带事件的 JSON 状态，测试结束写 quit
并核验进程退出，清理本次临时资源。禁止同时广播旧实验服务的同一组 UUID。

PilotNest 的 `ReverseGATTHardwareUITests.testForegroundRepeatAndBackgroundRecovery`
默认 skip，必须给 test runner 的 xctestrun EnvironmentVariables 显式设置
`MACPILOT_GATT_HARDWARE=1`，只在实体手机上选中运行。可选
`MACPILOT_GATT_BACKGROUND_SECONDS`（35–180 秒，默认 65）。它只访问设置里的实验页，
测试前台回环、重复发送、后台自动恢复，并要求日志中在 background 与 foreground 之间
存在真正的新回环；不会点击任何锁屏/解锁/远程控制动作，不清空配对或用户偏好。
测试在退出前停止实验会话，附件保存状态截图和两端可核对的手机事件。

现有 PilotNest App 会按其原有设置启动 BLE/L2CAP 等链路，用于并行观察。
仅看到旧链路广告/PSM 不等于完成端到端 L2CAP 命令验收。iPhone 物理锁屏需人工操作并用
`devicectl device info lockState` 记录真实锁屏区间；公开 XCUIDevice API 没有锁屏按钮。
不得用返回前台后的刷新回环替代后台或锁屏期间的回环证据，也不得访问/记录手机解锁口令。
