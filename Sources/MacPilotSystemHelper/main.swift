import Foundation
import MacPilotSystemIPC

// root Helper 由 SMAppService 注册的 LaunchDaemon 按 MachServices 按需拉起。
// 监听的 mach service 名称来自打包在 app 内的 LaunchDaemon plist（构建脚本
// 会按 MacPilot / OctoPilot bridge 身份改写），保证两种身份互不冲突。
let helperServiceDelegate = SystemHelperService()
let helperListener = NSXPCListener(
    machServiceName: SystemHelperLaunchdConfig.helperMachServiceName()
)
helperListener.delegate = helperServiceDelegate
helperListener.resume()
dispatchMain()
