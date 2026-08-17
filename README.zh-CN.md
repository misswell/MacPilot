# MacPilot

[English](README.md)

MacPilot 是一款原生 macOS 菜单栏应用。它会按照你为每个应用设置的规则，在应用闲置后自动隐藏、关闭窗口或退出，帮助减少邮件、聊天、社交和浏览器应用带来的干扰。

## 功能

- 为每个应用单独设置规则：
  - 闲置一段时间后隐藏；
  - 闲置一段时间后关闭可关闭窗口，但保留后台进程；
  - 闲置一段时间后退出；
- 被隐藏一段时间后退出。
- 为每个应用设置登录后的延迟启动时间（秒），并选择启动后显示到前台、隐藏，或在 10 秒启动宽限期后关闭窗口但保留后台进程。
- 在规则列表中显示最近一次即将触发的退出倒计时（分钟级）。
- 在启动列表中显示秒级倒计时；已运行的应用会自动跳过。
- 可从正在运行的应用中选择、从磁盘选择 `.app`，或直接把应用拖入窗口。
- 支持编辑、删除、排序、启用或暂停单条规则。
- 支持退出规则与启动规则的独立总开关、菜单栏控制、登录时启动。
- 支持跟随系统、English、简体中文三种界面语言。
- 规则与偏好会保存到本机，更新或替换 App 后不会丢失。

## BLE 解锁

MacPilot 还可以根据蓝牙低功耗（BLE）设备的接近程度自动锁定和解锁 Mac--支持 iPhone、Apple Watch，或任何使用**固定 MAC 地址**周期性广播信号的 BLE 设备。

在侧边栏或菜单栏中打开 **BLE 解锁**，然后：

- 扫描附近设备并选择你的设备。设备会显示名称、解析出的 MAC 地址和实时 RSSI。
- 设置 **解锁 RSSI**（设备靠近时解锁）和 **锁定 RSSI**（设备远离时锁定），两者可分别禁用。
- 设置 **锁定延迟**（设备离开后的宽限期）和 **无信号超时**（信号丢失后锁定）。
- 可选：接近时唤醒、唤醒但不解锁、锁定时暂停播放、用屏幕保护程序锁定、锁定时关闭屏幕，或开启**被动模式**以避免与其他蓝牙设备相互干扰。
- 使用 **立即锁定屏幕** 可立即锁定；待设备离开后重新靠近即会解锁。
- 登录密码会安全保存在**钥匙串**中，仅在锁屏时用于模拟键盘输入解锁。可用“设置密码…”设置或更新。

需要蓝牙与辅助功能权限。BLE MAC 地址会周期性轮换的设备（多数非苹果设备）无法被可靠跟踪。

## 输入法自动化

侧边栏的**输入法**可以把 Input Source Pro 的核心工作流整合到 MacPilot：

- 使用 Carbon 枚举并切换 macOS 键盘输入源，按应用或浏览器网站的域名/URL 规则自动切换。
- 支持输入法切换时的屏幕提示、鼠标附近或屏幕中央的位置，以及菜单栏中的循环切换。
- 可按应用强制英文标点，并按应用切换标准功能键或媒体键模式。
- 全局循环快捷键为 `⌥⌘I`，也可以为具体输入法录制自定义组合键；在其他 App 中工作需要辅助功能权限。规则与其他偏好一起保存到 `config.json`。

该功能基于 macOS Carbon、Accessibility、Core Graphics 与 IOKit API 独立实现，没有打包 Input Source Pro 的源码或第三方依赖。

## 截屏与贴图

侧边栏的**截图**为 MacPilot 增加了 Snapzy 风格的截图与快捷操作：

- 按全局快捷键（默认 `F1`）进入智能元素截图；元素选择器会在鼠标停下后显示高亮，并带有防抖与自动复查，避免移动时闪屏或停在某个外层元素上。
- 截图设置页还提供区域框选、应用窗口、全屏、当前窗口、标注、OCR、滚动长截图和抠图等入口。
- 区域或应用窗口选中后会保留 PixPin 风格选区，显示八个缩放控制点、尺寸提示和悬浮工具栏；可拖动/调整选区后再复制、保存、标注、OCR、贴图或取消。
- 截图后可以复制到剪贴板、显示快捷操作预览卡片、贴图、自动打开标注编辑器、识别文字，或直接在访达中显示。
- 每个截图入口都支持在设置中修改快捷键；截图功能的全局总开关在截图设置页顶部。

所有功能都可以在各自设置页中启用或关闭。关闭后的功能不会注册全局快捷键，不会启动后台监听或定时任务，也不会出现在顶栏菜单中。例如关闭**启用截图功能**后，顶栏不会再显示任何截图菜单，同时停止截图相关后台资源占用。

## 存储压缩

侧边栏的**存储压缩**会扫描指定文件夹，使用 macOS 文件系统透明压缩减少稳定文本类文件的实际磁盘占用，同时保持文件的逻辑内容不变。你可以指定后缀、最小文件大小、保持未修改的时间和最低节省比例，然后手动扫描压缩，或启用每 5 分钟一次的定期扫描。

MacPilot 会在原子替换前使用 SHA-256 校验压缩副本，并通过 macOS `ditto` 保留创建时间、修改时间及文件系统元数据。应用会跳过应用包、隐藏目录、符号链接、硬链接、稀疏文件和云端占位文件，并且只在 APFS 或 HFS+ 宗卷上工作。透明压缩后的文件仍可被其他应用直接读取，也可在同一界面恢复为未压缩文件。

## 画中画

侧边栏的**画中画**使用 ScreenCaptureKit 直接捕获单个窗口，生成跨 Space 的实时悬浮面板：

- 默认使用 `⌥⌘P` 捕获当前窗口（可在画中画设置中配置），加 `Shift` 选择窗口区域；开启快速区域后可用组合键双击直接捕获鼠标附近区域。
- 面板支持自由调整大小、保持源窗口比例、⌘ 拖动框选区域后放大、滚轮缩放、⌘+滚轮平移、`+/-` 缩放，以及跨全屏 Space 显示。
- 支持自动隐藏、单击聚焦源窗口、双击聚焦并关闭、Backspace/Esc 关闭、空格快速查看、媒体播放/暂停和方向键 seek。
- 媒体控制会匹配源 App 的真实 Now Playing 会话，支持播放/暂停、前后 5 秒、进度显示与拖动，以及 YouTube 字幕按钮。
- 支持 1–60 fps、0–100% 强度的增强对比度、多窗口模式、悬停提示、圆角，以及按 App 保存的空闲/变化/敏感检测；检测脚本可读取 `PIPIRI_EVENT`、`PIPIRI_APP`、`PIPIRI_BUNDLE_ID`、`PIPIRI_WINDOW_ID` 环境变量。
- 离屏渲染修复可用后台渲染参数重启 Chromium/Electron 应用；Firefox、Floorp、kitty、Ghostty、iTerm2 及手动选择的自定义合成器 App 可在用户确认后安装补丁。MacPilot 会完整备份原 App，支持恢复、管理员授权安装，用 FSEvents 监听更新后自动重打补丁，并在连续快速崩溃后自动恢复原版。
- 画中画配置与其他偏好一起保存在 `~/Library/Application Support/MacPilot/config.json`。

首次使用需要在“系统设置 → 隐私与安全性 → 屏幕录制”中允许 MacPilot。要在其他 App 激活时拦截全局快捷键，还需要授予 MacPilot“辅助功能”权限；没有该权限时，应用内的兼容监听仍可观察快捷键，但无法阻止原按键继续传给前台 App。自定义合成器补丁绝不会静默执行：目标 App 必须先退出，用户必须明确确认，原始 bundle 会保存在 MacPilot 的 Application Support 目录并可恢复。

## 平滑滚动

侧边栏的**平滑滚动**会把鼠标滚轮事件改写成经过插值的连续滚动帧，让滚轮手感更接近触控板。该功能改编自 [Mos](https://github.com/Caldis/Mos) 的滚动流水线（CC BY-NC 4.0）。

- 可分别启用垂直/水平平滑，也可以让某个轴保持原生滚动、另一轴平滑。
- 可分别反转垂直/水平方向。
- 可调整最短步长、速度增益、持续时长和死区。
- 可选地模拟触控板的滚动/惯性阶段，兼容依赖这些字段的应用。
- 设置与其他功能一起写入 `config.json`；因为要读取并改写其他应用中的滚轮事件，需要辅助功能权限。

## 配置文件

退出规则、启动规则与偏好配置保存在：

```text
~/Library/Application Support/MacPilot/config.json
```

该文件独立于 `MacPilot.app`。首次启动时，MacPilot 会自动迁移上一版本的兼容配置，但不会修改原文件。你可以在应用的“设置 → 配置文件”中复制路径，或点击“在访达中显示”。

## 构建与启动

```sh
./Scripts/build-app.sh
open MacPilot.app
```

构建出的应用位于项目根目录的 `MacPilot.app`。“关闭窗口”动作需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许 MacPilot；选择该模式时会立即触发系统授权提示。目标应用关闭窗口后是否隐藏 Dock 图标由目标应用自身决定。

只要存在稳定签名身份，正式版和开发版会使用同一条显式 designated requirement（Bundle ID 和 Apple 信任链）。这条 requirement 刻意不包含签名证书的 Team ID，因为开发机上的 Apple Development 与正式版 Developer ID 证书可能属于不同团队。本地构建会自动使用钥匙串中的 Apple Development 身份；没有稳定身份时才会警告并回退到 ad-hoc。第一次从旧的 ad-hoc/默认签名迁移后可能需要重新授予一次权限，之后开发版与正式版可以共用屏幕录制和辅助功能授权。

如果升级后辅助功能列表中已经勾选 MacPilot，但“关闭窗口”仍提示无权限，仅关闭再打开开关可能不会更新旧签名记录。权限提示中可直接点击**重置权限并退出**，MacPilot 会自动执行 `tccutil reset Accessibility com.misswell.macpilot` 并退出；重新打开应用后再次允许权限即可。运行规则只会静默检查权限，不会在后台反复重新请求。

## 分发

如果钥匙串中没有稳定签名身份，本地构建才会回退到 ad-hoc。要生成可分发、已公证的构建，需要 Apple 开发者账号和 Developer ID Application 证书。

### 前置条件

1. **Developer ID Application** 证书（在 Apple Developer 后台创建，把 `.p12` 导入钥匙串）。
2. 用于公证的**App 专用密码**（appleid.apple.com -> 登录和安全 -> App 专用密码）。
3. **Team ID**（10 位，在开发者后台查看）。

### 本地分发

```sh
export MACPILOT_DEVELOPER_ID="Developer ID Application: 你的名字 (TEAMID)"
export MACPILOT_APPLE_ID="you@example.com"
export MACPILOT_APPLE_PASSWORD="app-specific-password"
export MACPILOT_TEAM_ID="TEAMID"
./Scripts/distribute-app.sh
```

脚本会构建、用 Developer ID + Hardened Runtime 签名、提交 Apple 公证、装订票据，产出 `MacPilot.app` 与 `MacPilot-<版本>-macos.zip`，双击即可打开，无 Gatekeeper 拦截。

### 改名桥接版

首次使用新 Bundle ID 正式发布前，应先发布一次桥接版。桥接版保留 `OctoPilot.app`、`com.misswell.octopilot` 和 `OctoPilot-<版本>-macos.zip` 归档名，但应用显示名称已经是 `MacPilot`：

```sh
MACPILOT_BRIDGE=1 \
MACPILOT_VERSION=1.1.20 \
MACPILOT_OUTPUT_DIR="$PWD/bridge-artifacts" \
./Scripts/distribute-app.sh
```

发布时不要重命名这个归档。旧版 OctoPilot 可以先升级到桥接版，桥接版再验证并安装后续的 MacPilot 正式版。如果自动升级是从现有的 `OctoPilot.app` 开始，更新器会原地替换 app bundle，因此磁盘路径可能仍保留旧文件名，但安装后的 Bundle ID 和显示名称已经是 `MacPilot`。本地测试时运行 `./Scripts/build-app.sh`，脚本会应用与正式版相同的共享 designated requirement。

### GitHub Release

推送形如 `v1.1.0` 的 tag 会触发 `dist` 任务，自动签名并公证。一次性的桥接 tag `v1.1.20` 会发布旧身份的 `OctoPilot.app`；之后的 tag 会发布正常的 `MacPilot.app`。请在仓库配置以下 secrets：

- `APPLE_CERTIFICATE_P12` - Developer ID Application 证书 `.p12` 的 base64
- `APPLE_CERTIFICATE_PASSWORD` - 该 `.p12` 的密码
- `APPLE_DEVELOPER_ID` - `Developer ID Application: 你的名字 (TEAMID)`
- `APPLE_ID` - 你的 Apple ID
- `APPLE_APP_SPECIFIC_PASSWORD` - App 专用密码
- `APPLE_TEAM_ID` - 你的 Team ID

## GitHub Actions

仓库包含 macOS 编译流水线。每次推送到 `main` 或创建面向 `main` 的拉取请求时，流水线会：

1. 编译 Release 二进制；
2. 打包 `MacPilot.app`；
3. 校验应用签名；
4. 上传 App 构建产物，保留 14 天。

最新版本标签之后的每个提交都会自动递增小版本号。例如 `v1.0.0` 后的提交会依次构建为 `1.0.1`、`1.0.2`；创建新标签后会以新标签作为版本基准。推送版本标签（例如 `v1.1.0`）时，流水线还会创建 GitHub Release，并上传压缩后的 `MacPilot.app`。

普通分支构建使用 `MACPILOT_ALLOW_UNSTABLE_SIGNING=1`，保证日常提交不需要 Release 证书也能一次通过。推送版本标签时运行的 `dist` 任务会导入 Developer ID 证书，使用 Hardened Runtime 签名并提交 Apple 公证，装订票据、验证签名，然后创建 GitHub Release。

## 改名与迁移

MacPilot 使用新的 Bundle ID `com.misswell.macpilot`。首次启动时，它会从旧版 `OctoPilot` 和 `OctoQuit` 的配置目录读取兼容配置，并把原有 BLE 解锁密码从旧 Keychain 服务迁移到新服务，密码本身不会暴露。macOS 的辅助功能、蓝牙、屏幕录制和登录项权限都绑定到应用身份，改名后需要重新授予这些权限。

正式发布新的 Bundle ID 和 `MacPilot.app` 之前，应先发布一个仍使用旧身份的桥接版。旧版 OctoPilot 无法验证新的 Bundle ID 或归档名称，而桥接版更新器可以同时识别新旧名称。
