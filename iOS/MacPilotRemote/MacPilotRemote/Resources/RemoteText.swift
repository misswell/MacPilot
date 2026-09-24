import Foundation

/// Unified localization for the iOS app. Mirrors the Mac side's `AppText` so no
/// user visible string is hard coded in a view.
enum RemoteText {
    static func value(_ key: String, _ arguments: CVarArg...) -> String {
        let language = preferredLanguage
        let table = language == .simplifiedChinese ? chinese : english
        let format = table[key] ?? english[key] ?? key
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: language.locale, arguments: arguments)
    }

    enum Language {
        case english
        case simplifiedChinese

        var locale: Locale {
            switch self {
            case .english: return Locale(identifier: "en")
            case .simplifiedChinese: return Locale(identifier: "zh-Hans")
            }
        }
    }

    static var preferredLanguage: Language {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    private static let chinese: [String: String] = [
        "appName": "PilotNest",
        "tabHome": "控制",
        "tabDevices": "设备",
        "tabSettings": "设置",
        "controllingMac": "当前控制的 Mac",
        "chooseMac": "选择 Mac",
        "switchMac": "切换",
        "switchMacAccessibility": "当前控制 %@，切换 Mac",
        "manageMacs": "管理设备",

        "stateIdle": "未连接",
        "stateDiscovering": "正在查找 Mac…",
        "stateConnecting": "正在连接…",
        "statePairing": "等待配对",
        "stateAuthenticating": "正在验证…",
        "stateConnected": "已连接",
        "stateReconnecting": "正在重新连接…",
        "stateFailed": "连接失败",
        "latency": "延迟 %d ms",
        "noMac": "未发现 MacPilot",
        "noMacDetail": "请确认 Mac 与 iPhone 在同一个 Wi-Fi，并且已在 MacPilot 的「远程控制」中启用 iPhone 遥控。",
        "retry": "重试",
        "openSystemSettings": "打开系统设置",
        "localNetworkHint": "需要允许「本地网络」权限才能发现 MacPilot。",
        "unrecognizedServiceHint": "发现了本地服务但读不到它的信息，可能对方版本不兼容。请把 MacPilot 更新到最新版。",
        "foundUnpaired": "发现 MacPilot",
        "foundUnpairedDetail": "已找到「%@」，去「设备」页点「配对」即可开始使用。",
        "goToPairing": "去配对",
        "noNewDevices": "本网络暂无可配对的新设备。",

        "actionLock": "锁屏",
        "actionDisplayOff": "黑屏",
        "actionWakeDisplay": "亮屏",
        "actionWakeAndUnlock": "唤醒解锁",
        "actionRunning": "执行中…",
        "actionDone": "完成",

        "levelsTitle": "亮度与音量",
        "brightnessLabel": "屏幕亮度",
        "volumeLabel": "音量",
        "mute": "静音",
        "unmute": "取消静音",
        "levelsUnavailable": "这台 Mac 暂不上报亮度或音量，请把 Mac 上的 MacPilot 更新到最新版。",
        "levelsUnavailableShort": "暂不可用",
        "levelsNotConnected": "连接后可在此调节 Mac 的亮度与音量。",

        "devicesTitle": "设备",
        "devicesSubtitle": "选择默认 Mac，或在局域网内发现新的 MacPilot。",
        "pairedSection": "已配对",
        "discoveredSection": "已发现",
        "online": "在线",
        "offline": "离线",
        "connectedLabel": "已连接",
        "defaultMac": "默认",
        "setDefault": "设为默认",
        "forget": "移除",
        "forgetConfirmTitle": "移除这台 Mac？",
        "forgetConfirmMessage": "移除后会立即删除本机保存的配对密钥，之后需要重新配对。",
        "noPaired": "还没有已配对的 Mac。",

        "pairingTitle": "配对 MacPilot",
        "pairingSubtitle": "请在 Mac 上打开「设置 → 远程控制」，点击「开始配对」，然后输入 Mac 上显示的 6 位配对码。",
        "pairingCodePlaceholder": "6 位配对码",
        "pairingConfirm": "确认配对",
        "pairingCancel": "取消",
        "pairingWaiting": "正在等待 Mac 显示配对码…",
        "pairingSuccess": "配对成功",

        "settingsTitle": "设置",
        "settingsSubtitle": "本机标识、权限与连接偏好。",
        "clientName": "本机名称",
        "clientNameHint": "Mac 上会在已配对设备列表中看到这个名称。",
        "clientID": "本机标识",
        "permissions": "权限",
        "localNetwork": "本地网络",
        "granted": "已允许",
        "unknown": "未知",
        "resetPairings": "移除所有配对",
        "resetPairingsConfirm": "所有配对密钥都会从本机删除，需要重新配对。",
        "transportSection": "连接方式",
        "transportCurrent": "当前链路",
        "transportRacing": "并发拨号",
        "transportRacingIdle": "未在拨号",
        "racePathBonjour": "Bonjour",
        "racePathRemembered": "地址直连",
        "racePathBluetooth": "蓝牙",
        "transportBLE": "蓝牙链路",
        "transportBLEOff": "未广播",
        "transportBLEAdvertising": "广播中",
        "transportBLEReady": "已就绪",
        "linkDiagnostics": "连接诊断记录",
        "linkShareDiagnostics": "导出连接诊断",
        "performance": "连接性能",
        "metricDiscovery": "发现耗时",
        "metricConnect": "连接耗时",
        "metricHandshake": "握手耗时",
        "metricRTT": "往返延迟",
        "metricExecution": "命令耗时",
        "about": "关于",
        "aboutBody": "PilotNest 通过局域网直连 Mac，不经过任何服务器。Mac 的登录密码始终保存在 Mac 上，不会传输到 iPhone。",

        "requirements": "使用前需要准备",
        "requirementsIntro": "PilotNest 只是手机上的遥控端，本身不能控制 Mac。请先在 Mac 上装好 MacPilot 并保持运行：",
        "requirementsStep1": "在 Mac 上安装 MacPilot（macOS 14 或更高版本）。",
        "requirementsStep2": "打开 MacPilot，在「远程控制」里启用 iPhone 遥控。",
        "requirementsStep3": "回到本 App，在「设备」页找到这台 Mac，点「配对」。",
        "requirementsStep4": "输入 Mac 上显示的 6 位配对码。之后会自动重连，不用再配对。",
        "requirementsDownload": "下载 MacPilot",
        "requirementsFooter": "两台设备需要在同一个 Wi-Fi 下，并允许「本地网络」权限。MacPilot 未运行或不在同一网络时，本 App 找不到 Mac。",

        "errorUnsupportedProtocol": "MacPilot 与 App 的协议版本不一致，请更新两端。",
        "errorPairingWindowClosed": "Mac 上没有打开配对窗口。请在 MacPilot 的「远程控制」中点击「开始配对」。",
        "errorInvalidPairCode": "配对码不正确，请重新输入。",
        "errorAuthenticationFailed": "配对验证失败，请重新配对。",
        "errorNotPaired": "这台 Mac 还没有与本机配对。",
        "errorNetwork": "网络连接中断，正在重试。",
        "errorUnauthenticated": "身份验证失败。",
        "errorPairingRequired": "需要先在 Mac 上完成配对。",
        "errorUnsupportedCommand": "Mac 不支持该操作，请更新 MacPilot。",
        "errorAccessibility": "请在 MacPilot 中授予「辅助功能」权限。",
        "errorCredential": "需要先在 MacPilot 中配置解锁密码。",
        "errorAlreadyLocked": "Mac 已经处于锁屏状态。",
        "errorAlreadyUnlocked": "Mac 已经解锁。",
        "errorUnlockFailed": "解锁失败，请确认 Mac 上的解锁密码正确。",
        "errorWakeFailed": "无法唤醒 Mac 的显示器。",
        "errorLockFailed": "锁屏未生效。",
        "errorDisplaySleepFailed": "关闭屏幕未生效。",
        "errorBrightnessUnavailable": "无法调节亮度：这台 Mac 没有可控制的屏幕背光（例如合盖外接显示器时）。",
        "errorVolumeUnavailable": "无法调节音量：Mac 上没有可调音量的输出设备。",
        "errorTimeout": "命令超时。",
        "errorInternal": "Mac 返回了内部错误。"
    ]

    private static let english: [String: String] = [
        "appName": "PilotNest",
        "tabHome": "Control",
        "tabDevices": "Devices",
        "tabSettings": "Settings",
        "controllingMac": "Controlling Mac",
        "chooseMac": "Choose a Mac",
        "switchMac": "Switch",
        "switchMacAccessibility": "Controlling %@, switch Mac",
        "manageMacs": "Manage devices",

        "stateIdle": "Not connected",
        "stateDiscovering": "Looking for your Mac…",
        "stateConnecting": "Connecting…",
        "statePairing": "Waiting to pair",
        "stateAuthenticating": "Authenticating…",
        "stateConnected": "Connected",
        "stateReconnecting": "Reconnecting…",
        "stateFailed": "Connection failed",
        "latency": "%d ms",
        "noMac": "No MacPilot found",
        "noMacDetail": "Make sure the Mac and iPhone are on the same Wi-Fi and that iPhone remote control is enabled in MacPilot's Remote Control settings.",
        "retry": "Retry",
        "openSystemSettings": "Open Settings",
        "localNetworkHint": "Local Network access is required to find MacPilot.",
        "unrecognizedServiceHint": "Found a local service but could not read its details, which usually means a version mismatch. Update MacPilot on your Mac.",
        "foundUnpaired": "MacPilot found",
        "foundUnpairedDetail": "Found \"%@\". Open the Devices tab and tap Pair to get started.",
        "goToPairing": "Pair now",
        "noNewDevices": "No new devices to pair on this network.",

        "actionLock": "Lock",
        "actionDisplayOff": "Blank",
        "actionWakeDisplay": "Wake screen",
        "actionWakeAndUnlock": "Wake & Unlock",
        "actionRunning": "Working…",
        "actionDone": "Done",

        "levelsTitle": "Brightness & volume",
        "brightnessLabel": "Brightness",
        "volumeLabel": "Volume",
        "mute": "Mute",
        "unmute": "Unmute",
        "levelsUnavailable": "This Mac does not report brightness or volume yet. Update MacPilot on the Mac.",
        "levelsUnavailableShort": "Unavailable",
        "levelsNotConnected": "Connect to adjust your Mac's brightness and volume here.",

        "devicesTitle": "Devices",
        "devicesSubtitle": "Choose the default Mac or discover a new MacPilot on this network.",
        "pairedSection": "Paired",
        "discoveredSection": "Discovered",
        "online": "Online",
        "offline": "Offline",
        "connectedLabel": "Connected",
        "defaultMac": "Default",
        "setDefault": "Set as default",
        "forget": "Remove",
        "forgetConfirmTitle": "Remove this Mac?",
        "forgetConfirmMessage": "The pairing key stored on this iPhone is deleted and you will need to pair again.",
        "noPaired": "No Mac has been paired yet.",

        "pairingTitle": "Pair with MacPilot",
        "pairingSubtitle": "On the Mac open Settings → Remote Control, click Start pairing, then type the 6 digit code shown on the Mac.",
        "pairingCodePlaceholder": "6 digit code",
        "pairingConfirm": "Pair",
        "pairingCancel": "Cancel",
        "pairingWaiting": "Waiting for the Mac to show a pairing code…",
        "pairingSuccess": "Paired",

        "settingsTitle": "Settings",
        "settingsSubtitle": "This iPhone's identity, permissions and connection preferences.",
        "clientName": "Device name",
        "clientNameHint": "The Mac shows this name in its paired device list.",
        "clientID": "Client ID",
        "permissions": "Permissions",
        "localNetwork": "Local Network",
        "granted": "Allowed",
        "unknown": "Unknown",
        "resetPairings": "Remove all pairings",
        "resetPairingsConfirm": "Every pairing key stored on this iPhone is deleted and you will need to pair again.",
        "transportSection": "Connection link",
        "transportCurrent": "Active link",
        "transportRacing": "Dialling",
        "transportRacingIdle": "Idle",
        "racePathBonjour": "Bonjour",
        "racePathRemembered": "Saved address",
        "racePathBluetooth": "Bluetooth",
        "transportBLE": "Bluetooth link",
        "transportBLEOff": "Not advertising",
        "transportBLEAdvertising": "Waiting for the Mac",
        "transportBLEReady": "Ready",
        "linkDiagnostics": "Connection diagnostics",
        "linkShareDiagnostics": "Export connection diagnostics",
        "performance": "Connection performance",
        "metricDiscovery": "Discovery",
        "metricConnect": "Connect",
        "metricHandshake": "Handshake",
        "metricRTT": "Round trip",
        "metricExecution": "Command",
        "about": "About",
        "aboutBody": "PilotNest talks to your Mac directly over the local network. Nothing goes through a server, and the Mac login password never leaves the Mac.",

        "requirements": "Before you start",
        "requirementsIntro": "PilotNest is only the remote control on your phone; it cannot control a Mac by itself. Install MacPilot on the Mac and keep it running:",
        "requirementsStep1": "Install MacPilot on the Mac (macOS 14 or later).",
        "requirementsStep2": "Open MacPilot and enable iPhone remote control under Remote Control.",
        "requirementsStep3": "Come back to this app, find the Mac on the Devices tab and tap Pair.",
        "requirementsStep4": "Type the 6 digit pairing code shown on the Mac. After that it reconnects on its own, with no re-pairing.",
        "requirementsDownload": "Download MacPilot",
        "requirementsFooter": "Both devices must be on the same Wi-Fi and allow Local Network access. If MacPilot is not running, or the Mac is on another network, this app cannot find it.",

        "errorUnsupportedProtocol": "This app and MacPilot speak different protocol versions. Update both.",
        "errorPairingWindowClosed": "The pairing window on the Mac is closed. Click Start pairing in MacPilot → Remote Control.",
        "errorInvalidPairCode": "That pairing code did not match. Try again.",
        "errorAuthenticationFailed": "Pairing verification failed. Please pair again.",
        "errorNotPaired": "This Mac has not been paired with this iPhone yet.",
        "errorNetwork": "The connection dropped. Reconnecting.",
        "errorUnauthenticated": "Authentication failed.",
        "errorPairingRequired": "Pair on the Mac first.",
        "errorUnsupportedCommand": "The Mac does not support that action. Update MacPilot.",
        "errorAccessibility": "Grant Accessibility permission in MacPilot on the Mac.",
        "errorCredential": "Set the unlock password in MacPilot on the Mac first.",
        "errorAlreadyLocked": "The Mac is already locked.",
        "errorAlreadyUnlocked": "The Mac is already unlocked.",
        "errorUnlockFailed": "Unlock failed. Check the unlock password saved on the Mac.",
        "errorWakeFailed": "Could not wake the Mac's display.",
        "errorLockFailed": "The Mac did not lock.",
        "errorDisplaySleepFailed": "The display did not turn off.",
        "errorBrightnessUnavailable": "Cannot change brightness: this Mac has no display with a controllable backlight (an external monitor in clamshell mode, for example).",
        "errorVolumeUnavailable": "Cannot change volume: no output device with a volume control.",
        "errorTimeout": "The command timed out.",
        "errorInternal": "The Mac reported an internal error."
    ]
}

extension RemoteText {
    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        value(key, arguments)
    }
}
