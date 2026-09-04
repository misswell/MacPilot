# MacPilot 开发总结

本文档总结近期 MacPilot 的主要开发工作，涵盖新功能、界面与性能优化、可分发构建及发布流程。

## 一、BLE 解锁功能

在原有「退出规则 / 启动规则」基础上，新增 BLE 解锁功能：根据蓝牙低功耗（BLE）设备的接近程度自动锁定和解锁 Mac。

核心实现位于 `Sources/MacPilot/BLEUnlock.swift`，主要能力包括：

- **设备扫描与选择**：扫描附近 BLE 设备，解析 MAC 地址与名称（蓝牙偏好 plist + 系统蓝牙数据库 + Apple 设备型号表），按信号强度排序展示。
- **接近判定**：基于 RSSI 滑动均值（最近 5 次）与双阈值（解锁 RSSI / 锁定 RSSI，均可独立禁用），配合「锁定延迟」与「无信号超时」两个计时器。
- **锁屏与解锁**：登录密码安全存入钥匙串；锁屏时模拟键盘输入解锁；支持「用屏幕保护程序锁定」「锁定时关闭屏幕」「接近时唤醒」「唤醒但不解锁」。
- **活动 / 被动模式**：默认主动连接设备读取 RSSI（更稳定）；可切换被动模式仅靠扫描，避免与其他蓝牙设备相互干扰。
- **媒体控制**：锁屏时暂停「正在播放」，解锁后恢复（运行时加载系统媒体框架，失败则降级）。
- **事件脚本**：锁/解锁时可运行 `~/Library/Application Scripts/com.misswell.macpilot/event`，参数 `away` / `lost` / `unlocked` / `intruded`。
- **屏幕状态观察**：显示器睡眠/唤醒、系统睡眠/唤醒、屏保、解锁等系统事件。

入口：
- 主窗口侧边栏「BLE 解锁」板块（完整配置）
- 菜单栏菜单（启用、立即锁定、选择设备、管理）

设置随 `~/Library/Application Support/MacPilot/config.json` 持久化（配置版本升至 5），中英双语。

## 二、界面设计

BLE 板块采用独立的视觉语言，区别于普通列表：

- **圆形信号仪表盘**：标题旁圆环显示实时 RSSI，按强度绿/黄/红变色，中心显示数值与接近状态。
- **信号强度条**：设备列表每项用 4 格信号条直观展示强弱。
- **RSSI 范围条**：阈值区用水平条可视化——绿色解锁区、红色锁定区、黑色竖线标记当前位置。
- **卡片化分组**：触发阈值 / 时间参数 / 行为选项 / 密码与锁定 各成卡片。
- **彩色状态点**：启用卡片用圆点 + 文字表示蓝牙、接近、未检测等状态。
- **密码状态徽标**：用图标显示密码已保存 / 未设置。

## 三、性能优化

针对办公室等设备密集场景，解决扫描列表卡顿与顺序跳动：

- **刷新合并**：设备列表发布最多每 200ms 一次，突发广播不再逐条刷新主线程。
- **设备上限**：候选列表最多 100 台，优先保留信号强的设备。
- **单一清理定时器**：用一个 5 秒定时器清理失联设备，替代为每台设备反复创建 Timer。
- **名称解析缓存**：设备名称/MAC 只解析一次，避免重复读盘。
- **稳定排序**：默认按加载顺序（首次发现时间）显示，不再因 RSSI 实时变化而跳动。
- **排序选择器**：提供「加载顺序 / 名称 / 信号」三种排序切换。
- **懒加载列表**：使用 `LazyVStack` 渲染设备行。

回归测试：`Tests/MacPilotTests/BLEUnlockPerformanceTests.swift` 验证突发刷新被合并为一次发布。

## 四、Bug 修复

- **菜单栏设备入口无反应**：原 SwiftUI 子菜单无法可靠触发扫描，改为点击直接打开主窗口 BLE 板块选择设备。
- **权限弹窗叠加**：启用 BLE 时不再同时弹出辅助功能系统窗 + 应用内提示 + 蓝牙窗；拆分到不同用户动作，蓝牙权限推迟到扫描时。
- **BLE 辅助功能重置**：BLE 提示新增「重置权限并退出」按钮，与退出规则板块一致，调用 `tccutil reset Accessibility` 并退出。

## 五、可分发构建

从 ad-hoc 签名升级为 Apple 公证的可分发应用：

- `Resources/MacPilot.entitlements`：Hardened Runtime 所需权限。
- `Scripts/build-app.sh`：优先用 Developer ID，否则自动选择 Apple Development；两者都以相同的 Bundle ID 与 Apple 信任链 requirement 签名（刻意不绑定证书 Team ID，以兼容开发/正式证书属于不同团队的机器），嵌套 updater/dylib 独立签名，找不到稳定身份时才回退 ad-hoc；旧环境变量别名仍可用。
- **更新器隐私授权保护（v1.1.241）**：应用内更新在既有 SHA-256 / codesign / Team ID / Gatekeeper 四重校验之上，新增「designated requirement 与运行中应用一致」校验——身份不同的更新包直接拒绝安装，杜绝更新后辅助功能/屏幕录制/自动化授权全部失效；校验通过后移除更新包的隔离属性，避免重启后 App Translocation；从隔离位置（下载目录直开）运行时启动即提示移到「应用程序」，且拒绝在转移位置执行更新。
- `Scripts/distribute-app.sh`：一键签名 → 提交 Apple 公证 → 装订票据 → 打 zip → Gatekeeper 校验；支持钥匙串公证 profile（不接触明文密码）。
- `.github/workflows/build.yml`：日常 push/PR 使用本机可用的稳定开发签名或回退 ad-hoc artifact；打 `v*` tag 自动以同一共享 requirement 签名、公证并发布 Release。
- tag 工作流依赖 6 个 Actions secrets：`APPLE_CERTIFICATE_P12`、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_DEVELOPER_ID`、`APPLE_ID`、`APPLE_APP_SPECIFIC_PASSWORD`、`APPLE_TEAM_ID`；已于 2026-07-24 配齐。
- 签名身份：`Developer ID Application: Guofeng Liu (U8U443D7ZL)`。本机钥匙串中有签名身份，但不得据此假定存在名为 `MacPilot` 的 notarytool profile；使用本地 profile 前必须实际验证。

仅在已确认本机存在对应 notarytool profile 时，才使用以下本地兜底命令：

```sh
MACPILOT_DEVELOPER_ID="Developer ID Application: Guofeng Liu (U8U443D7ZL)" \
MACPILOT_NOTARY_PROFILE="MacPilot" \
./Scripts/distribute-app.sh
```

## 六、发布记录

- 清理了 GitHub 上所有历史版本（v1.0.0 ~ v1.1.0，共 25 个 release 及对应 tag）。
- 重新发布 **v1.1.1**：https://github.com/misswell/MacPilot/releases/tag/v1.1.1
  - 已签名 + Apple 公证 + Hardened Runtime
  - 产物：`OctoPilot-1.1.1-macos.zip`，双击运行无 Gatekeeper 拦截
  - 该版本不是 tag workflow 自动成功：对应 Actions 运行失败，最终 Release 与 ZIP 由本机流程手动发布。
- 正式发布 **v1.1.6**：https://github.com/misswell/MacPilot/releases/tag/v1.1.6
  - 首次完整验证 Actions 自动链路：Developer ID 签名 → Apple 公证 → stapler → ZIP → GitHub Release。
  - 修复新版 Swift runner 将 MainActor/Sendable 诊断升级为编译错误的问题。

## 七、分发方式说明

MacPilot 依赖辅助功能、系统蓝牙文件、媒体框架、模拟键盘等深度系统能力，采用 **Developer ID 公证分发**（非 App Store）。这种方式适合此类系统工具，用户下载 zip 解压即可运行。App Store 因强制沙盒、禁止私有 API、禁止读系统文件等限制，不适用于当前功能形态。

## 八、测试

`swift test` 共 15 个测试通过，覆盖启动规则编解码、辅助功能重置、本地化、版本格式、BLE 设备列表刷新合并，以及软件更新的语义版本比较、Release 解析、SHA-256 强制校验与更新文案。

## 九、后续可选改进

- 定期检查 Developer ID 证书有效期与 6 个 Actions secrets，轮换 App 专用密码后同步更新 GitHub。
- 将“全新 Release 构建 + `-Xswiftc -warnings-as-errors`”固化为发 tag 前检查，避免本机增量缓存掩盖并发诊断。
- 考虑为 BLE 设备名解析增加更友好的兜底（系统蓝牙数据库不可读时的提示）。

## 十、发版运维经验（更正于 2026-07-24，v1.1.4～v1.1.6）

旧认知“Release 迟迟不出主要是 macOS runner 排队”不完整，已更正。排队只描述某个时刻的状态，必须继续跟踪到 job 的最终 conclusion 与失败步骤。

- 运行中可用 `gh run watch <run_id>` 或 `gh api repos/misswell/MacPilot/actions/jobs/<job_id> --jq '{s:.status,c:.conclusion,steps:[.steps[]|{name:.name,s:.status,c:.conclusion}]}'` 查看 step 状态；任务完成后用 `gh run view <run_id> --job <job_id> --log-failed` 提取失败日志。
- `job_status=queued` + `steps=[]` = **runner 在排队等 macOS runner，不是构建失败**；同日 GitHub API 还 503，属平台抖动。
- tag push 时 `build` job `conclusion=skipped` 是 `.github/workflows/build.yml` 里 `if: !startsWith(github.ref,'refs/tags/v')` 的正常跳过。
- `v1.1.4`、`v1.1.5` 的 tag workflow 最终都失败过；tag 已存在不代表 Release 已发布。必须再用 `gh release view <tag>` 检查 Release，并确认当前发布的 `MacPilot-<version>-macos.zip` asset 存在（历史 OctoPilot 版本仍使用旧名称）。
- `v1.1.5` 首次失败于缺少 `APPLE_CERTIFICATE_P12`；补齐证书相关 secrets 后，又明确失败于缺少 `APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD`。Secret 名称固定为 `APPLE_ID`，它的值才是 Apple Developer 登录邮箱；命令应是 `gh secret set APPLE_ID`，再在提示中输入邮箱值。
- 6 个 secrets 配齐后，发布继续暴露新版 CI 编译器的 Swift 并发错误：Timer 与 NotificationCenter 的 `@Sendable` 回调直接访问 `@MainActor` 状态。本机缓存构建曾显示成功，全新构建加 `-Xswiftc -warnings-as-errors` 才稳定复现。
- 修复方式是保留 `BLEUnlockModel` 的 `@MainActor` 隔离，在明确使用 `.main` queue / `RunLoop.main` 的同步回调内使用 `MainActor.assumeIsolated`，并避免跨 Sendable 边界捕获 `CBPeripheral`。
- `v1.1.5` 已是公开 tag，修复后没有移动旧 tag，而是提交到 `main` 并发布新补丁版本 `v1.1.6`。该版本 Actions 在约 1 分钟内完成签名、公证、装订、打包和 Release 发布。
- GitHub API 偶发 `EOF` / TLS timeout 是传输抖动，可对只读查询安全重试；不要因此改变 tag 或重复创建 Release。

标准流程：严格 Release 构建与 `swift test` → 提交并推送 `main` → 创建全新的语义化版本 tag → 推送 tag → 跟踪 `dist` 到成功 → 用 `gh release view` 核验非草稿 Release 与 ZIP asset。任何一步未完成，都不能宣布发布成功。（本节为 MacPilot 项目级发版记录。）

## 十一、存储压缩

新增“存储压缩”侧边栏板块，对用户选择的 APFS/HFS+ 文件夹执行 macOS 文件系统透明压缩：

- 默认推荐 `txt`、`log`、`md`、`json`、`jsonl`、`xml`、`csv`、`tsv`、`yaml`、`yml`，可自行指定后缀。
- 支持最小文件大小、稳定期和最低节省比例；可手动扫描/压缩，也可每 5 分钟定期处理。
- 使用系统 `/usr/bin/ditto --hfsCompression` 创建同目录临时副本，验证压缩标志与 SHA-256 后原子替换。
- 保留创建时间、修改时间、权限、ACL 和扩展属性；透明压缩后的文件可直接读取，也可在界面中恢复。
- 默认跳过隐藏目录、应用包、符号链接、硬链接、稀疏文件、云端占位文件及带系统保护标志的文件。
- 真实 APFS 测试覆盖候选筛选、递归扫描、压缩、低收益跳过、恢复及内容/时间属性保持。

## 十二、画中画

新增 `Sources/MacPilot/PictureInPicture.swift`，按 Pipiri 公开功能做等价的原生 macOS 实现：

- 使用 ScreenCaptureKit 逐窗口捕获，默认使用清晰的 `⌥⌘P` 全局快捷键（可配置，加 Shift 选择区域，组合键双击快速捕获），以及命令行 `--app` / `--window` / `--zoom` 启动参数。
- 悬浮面板保持源窗口比例，支持跨全屏 Space、调整大小、⌘ 框选区域缩放、滚轮缩放、⌘+滚轮平移、快捷键缩放、自动隐藏、聚焦具体源窗口和多窗口模式。
- 设置页拆分为通用、窗口行为、面板 UI、捕获、媒体、检测和补丁；支持 1–60 fps、0–100% 强度增强对比度、真实 Now Playing 媒体控制、按 App 保存的空闲/变化/敏感检测与 shell 脚本通知；检测使用整帧差分，敏感模式捕获细小变化。
- Chromium/Electron 目标通过 `--disable-backgrounding-occluded-windows` 重启；Firefox、Floorp、kitty、Ghostty、iTerm2 和手动选择的 App 可使用自研 universal `libMacPilotOcclusionPatch.dylib`。补丁流程包含 Mach-O `LC_LOAD_DYLIB` 注入、完整备份、临时目录构建、重签名、管理员授权安装、恢复、更新后自动重打及连续快速崩溃自动恢复，且修改第三方 App 前始终要求用户明确确认。
- 画中画配置并入 `config.json`，版本升至 10；单元测试覆盖默认值、配置约束、区域坐标、Codable、媒体匹配、离屏设置及真实 Firefox universal Mach-O 注入。
- 全局快捷键在获得辅助功能权限后使用 Core Graphics event tap 拦截，兼容监听保留为无权限时的降级路径；本应用自己的 PiP 面板也接入了本地键盘、滚轮和 Function 事件监听。
- 补丁更新监听使用 FSEvents；源窗口关闭会自动清理 PiP，窗口级 AX/CGWindow 焦点用于精确执行隐藏/关闭。真实测试覆盖 Pipiri frame/crop/hide/restore、快捷键 event tap 抑制、检测脚本、FSEvents 重打补丁、Firefox 副本运行和签名验证。

Pipiri 本身没有公开源码。研究其官网、DMG 元数据、可观察行为、二进制符号和 MediaHelper 协议后，MacPilot 使用独立代码实现行为等价功能；没有复制或打包 Pipiri 的专有代码、helper 或 dylib。涉及修改第三方 App bundle 的自定义合成器补丁仅在用户明确确认后执行，并始终先创建可恢复的完整备份。

## 十三、输入法自动化

新增 `Sources/MacPilot/InputSourceFeature.swift`，将 Input Source Pro 的核心工作流整合到 MacPilot：

- 使用 Carbon 枚举和切换键盘输入源，持久化包含输入模式的稳定标识符，避免同一输入法多模式时出现重复或选错。
- 按应用规则和浏览器网站规则自动切换；浏览器通过 Accessibility 获取当前 URL，并轮询页面变化以覆盖同一浏览器内切换标签页/网站的场景。
- 支持鼠标附近/屏幕中央的输入法屏幕提示、菜单栏循环切换、`⌥⌘I` 全局快捷键，以及为具体输入法录制自定义组合键。
- 可按应用强制将全角/中文标点映射为英文标点，并通过 IOKit 按应用设置标准功能键或媒体键模式；关闭功能后会恢复启用前的系统功能键模式。
- 规则层、域名边界、URL 正则、配置兼容解码和输入模式标识符都有 Swift Testing 覆盖。

实现基于 macOS Carbon、Accessibility、Core Graphics 和 IOKit 的独立代码，没有复制或打包 Input Source Pro（GPL-3.0）的源码、Core Data 模型或第三方依赖。全局快捷键和英文标点需要辅助功能权限；没有权限时，规则自动切换和手动菜单操作仍可使用。

## 十四、窗口切换器

新增 `Sources/MacPilot/WindowSwitcher.swift`，参考 alt-tab-macos 的交互方式实现独立窗口切换功能：

- 默认使用 `⌥Tab` 呼出窗口切换器；按住 Option 连续按 Tab 前进，`Shift+Tab` 后退，松开 Option 聚焦当前选中的窗口，支持 Escape 取消。
- 使用 Accessibility 读取真实窗口对象并通过 WindowServer 顺序显示应用窗口；支持最小化/隐藏应用筛选、应用图标和可用时的窗口缩略图，聚焦时会恢复最小化窗口并提升目标窗口。
- 呼出热路径只读取后台预热的窗口缓存，不再同步执行 Accessibility 枚举或截图；Accessibility 属性使用批量读取，缩略图按当前选择及相邻窗口的优先级异步抓取、缩放并以 LRU 缓存复用，切换面板和 SwiftUI 承载视图也会跨会话复用。
- 接入菜单栏、主窗口侧边栏和设置页；配置并入 `config.json`，版本升至 11，旧配置缺少窗口切换字段时使用安全默认值。
- 合并应用仅在窗口切换器清单中折叠为一个代表项，优先显示未最小化窗口，不改变应用实际窗口状态。
- 全局按键拦截需要辅助功能权限；缩略图依赖屏幕录制权限，权限不可用时自动回退到应用图标。

alt-tab-macos 使用 GPL-3.0 授权，MacPilot 只参考其公开行为和架构思路，未复制或链接其源码。

## 十五、平滑滚动

新增 `Sources/MacPilot/SmoothScrolling/`，为 MacPilot 提供鼠标滚轮平滑能力：

- 使用 CGEvent tap 读取真实鼠标滚轮事件，跳过触控板/远程已平滑事件与平滑滚动自产的合成事件，按原始目标进程用 `CGEventPostToPid` 直投框间插值事件。
- 最小步长归一化、速度增益、持续时间曲线、曲线峰值滤波与滚动/动量相位状态机（可选模拟触控板相位）。
- 支持垂直/水平平滑独立开关、垂直/水平方向反转、最短步长、速度、持续时长、死区和触控板相位模拟。
- 支持「滚轮越快加速越多」开关与自动加速上限，按相邻滚轮事件间隔动态放大步长（默认关闭）。
- 支持按应用 Bundle ID 添加排除项；排除应用的滚轮事件不参与平滑插值，并可为每个应用独立开启方向反转。PID 与 Bundle ID 通过应用生命周期缓存关联，输入事件路径只做集合查询。
- 配置并入 `config.json`，版本升至 15；新增侧边栏板块和菜单栏快捷入口，配置缺失或越界时使用安全默认值/钳制。
- Swift Testing 覆盖默认值与越界钳制、持续时间曲线、事件轴解析、平滑/透传计划、曲线滤波、相位机和自适应加速。
- 相位模拟先发送 `TrackingBegin` 再进入 `TrackingOngoing`/惯性阶段，避免普通应用因缺少开始阶段而忽略平滑滚动。

## 十六、Finder 右键菜单扩展

FinderSync 右键菜单扩展随 `v1.1.126` 首次发布，`v1.1.127` 修复启动崩溃：

- 扩展本体（`FinderSync/`，沙盒、App Group entitlement）只负责菜单渲染与事件转发，通过 `DistributedNotificationCenter` 与主 App 通信，**不读取 SwiftData**。
- 主 App（非沙盒）与扩展通过 `UserDefaults(suiteName: appGroupIdentifier)` 共享菜单开关等设置——非沙盒 App 访问 App Group 的 **UserDefaults 可用**，无需处理。
- **关键坑（v1.1.126 启动崩溃根因）**：主 App 是非沙盒的，带 `com.apple.security.application-groups` entitlement 也无法向 App Group 容器写文件（TCC 返回 errno 1 / `Sandbox access to file-write-create denied`）。原 `SharedDataManager.sharedModelContainer` 直接把 SQLite 放到 `~/Library/Group Containers/group.com.misswell.macpilot.rightclick/`，SwiftData 初始化抛错后 `fatalError`，导致 App 启动即崩溃。
- **修复**：`ModelContainer.swift` 先检查 App Group 目录是否真正可写（`isWritableFile`，仅沙盒上下文为 true），不可写则回退到 `~/Library/Application Support/MacPilot/RightClick/RClickDatabase.sqlite`；只有全部候选都失败才 `fatalError`。
- 判断「App Group 是否可写」必须用实际进程（带真实 entitlements 签名）验证；从终端直接运行二进制会继承终端的 TCC 身份，行为可能与真实启动不同。
- `swiftc -output-file-map <(...)` 进程替换在部分 shell/沙箱环境下会报 `unable to load output file map '/dev/fd/11'`；本地临时构建可改为先写临时文件再传入（CI 的 runner 不受影响）。

## 十七、剪切板历史

剪切板历史功能随 `v1.1.128` 首次发布：

- 核心逻辑（`Sources/MacPilot/Clipboard/`）：剪切板监听（Timer 轮询 `NSPasteboard.changeCount`）、历史去重合并、固定（pin）、数量上限裁剪、大小写不敏感搜索、Codable JSON 持久化到 `~/Library/Application Support/MacPilot/ClipboardHistory.json`。
- 弹出面板：非激活 `NSPanel`（不抢占前台焦点），搜索框 + 历史列表 + 底部提示；键盘操作：↑↓ 选择、⏎ 粘贴（默认）/复制、1-9 选前 9 条未固定、字母选固定条目、⌫ 删除、Esc 关闭；失焦自动关闭；面板打开期间暂停记录。
- 全局快捷键：默认 ⌘⇧V（Carbon `RegisterEventHotKey`，复用 `SmartCaptureShortcutBinding`），可在设置里录制。
- 粘贴通过 CGEvent 模拟 ⌘V（需要辅助功能权限）；⌘ 点击=复制、⌥ 点击=粘贴、⌥⇧=无格式粘贴。
- 去依赖实现：不用 SwiftData（上次 App Group 容器坑的教训），也不引入 Sauce/Defaults/KeyboardShortcuts/Settings/Fuse 等第三方依赖。
- 已知取舍：搜索仅大小写不敏感子串（未实现模糊搜索）；数字/字母快捷键优先于在搜索框输入数字/字母；未提供忽略应用/正则规则（v2 候选）。

## 十八、剪切板与右键菜单样式统一（v1.1.132）

把剪切板面板与 Finder 右键菜单的界面统一到 MacPilot 现有视觉语言，去掉「复制」痕迹：

- **剪切板面板**：背景改为 `.ultraThinMaterial` + 白色描边圆角（与窗口切换器一致），新增顶部标题栏（图标 + 剪切板 + 快捷键），选中行改为系统蓝高亮 + 蓝色描边，历史列表高度上限 440、宽度上限 480（避免历史条目多时面板撑满整屏）。
- **剪切板面板文案**：接入应用双语（`ClipboardModel.language` + `t(_:)`，由 `MacPilotModel.language` 同步），不再写死中文。
- **右键菜单设置页**：去掉原 NavigationSplitView 侧边栏与 Logo，改为 MacPilot 风格的大标题 + 图标标签栏（通用/应用/操作/新建文件/常用目录/关于），选中态与主窗口侧边栏一致。
- **关于页**：应用图标改用 `NSApp.applicationIconImage`，关于页链接替换为 MacPilot 仓库。
- **Finder 右键菜单**：顶部加品牌头部（MacPilot + 图标），展开的各分组加禁用态分组标题与分隔线，子菜单图标与设置页标签一致，空配置时给出「暂无可用菜单项」。
- **中文本地化**：补齐 MacPilotRightClickKit 与 FinderSync 两份 `AppLocalization.simplifiedChinese` 词条（约 120 项），设置页与右键菜单全程中文。
## 十九、屏幕录制引擎升级：全功能录屏（v1.1.234 引入，v1.1.235 重写，v1.1.236 功能升级）

v1.1.236 对录屏功能做整体升级，补齐主流录屏工具的完整能力（UI 样式保留 MacPilot 设计语言）。当前能力：

- **引擎模块**：`Sources/MacPilot/Recording/` 共 15 个文件——引擎本体 `RecordingEngine.swift`（生命周期 makeSession/start/pause/resume/stop/cancel、采样处理、麦克风、存帧、演示者叠加）；纯函数规划 `RecordingOutputPlanning.swift`（码率预算/压缩字典）与 `RecordingCapturePlanning.swift`（窗口选择/Blueprint/滤镜构建/背景填充）；支撑件 `RecordingSampleBuffers.swift`（时间轴平移/PCM 封装）、`RecordingAudioMixer.swift`（混音重封装）、`RecordingDisplaySleep.swift`（防休眠）、`RecordingNotifications.swift`（系统通知）；设备 `RecordingDeviceDiscovery.swift`（发现/采样率/CMIO 标志）、`RecordingCameraOverlay.swift`（浮动摄像头窗）、`RecordingMobileRecorder.swift`（iOS 设备录制）；悬浮件 `RecordingMouseAids.swift`（鼠标高亮/放大镜）、`RecordingPanels.swift`（倒计时/控制条/完成预览）；状态机 `ScreenRecordingSettings.swift`（全部设置类型与安全解码）、`ScreenRecordingModel.swift`（模型 + 错误 + 会话 hooks）、`ScreenRecordingHotKeys.swift`（Carbon 热键管线）；`ScreenRecordingModel` 状态机、快捷键、选区浮层、快速访问面板、config.json 持久化全部复用。
- **录制模式**：框选区域 / 全屏 / 应用窗口（桌面无关窗口，跟随移动）/ **纯音频**（系统声音+可选麦克风 → m4a/caf），另支持「录制最前窗口」快捷启动与 iOS 设备录制。
- **码率公式**：`max(600,宽)×max(600,高)×(fps/8)×编码器系数(H.264 0.9 / HEVC 0.5)×画质系数(低/中/高)×(HDR ×2)`，下限 200 kbps。
- **编码与画质**：H.264 / HEVC / **HEVC With Alpha**（选 Alpha 自动强制 HEVC+MOV）；**HDR 录制**（macOS 15 使用 `captureHDRStreamLocalDisplay` 预设、BT.2020 PQ 色域、HEVC Main10）；像素格式 6 选（默认/BGRA/YUV 8/10bit 视频与全幅）；Retina 原生分辨率开关；窗口背景填充（保留壁纸/透明/八色/自定义十六进制，透明时同步排除 Dock 壁纸窗口）。
- **滤镜构造**（对齐 QR）：应用黑名单排除、隐藏控制中心图标、隐藏桌面文件（Finder 全屏无标题窗口）、可选包含菜单栏（macOS 14.2+）、排除自身窗口（摄像头/鼠标/放大镜/iDevice 悬浮窗除外）。
- **音频**：AAC/ALAC/FLAC 三格式、128–320 kbps 音质档（低采样率自动减半封顶 64k）；麦克风支持设备选择（非默认设备走 AVCaptureSession）+ 回声消除（VoiceProcessing）+ **压低系统音量三档**（`kAUVoiceIOProperty_OtherAudioDuckingConfiguration`）；**remux 混音**——录制完成后把麦克风轨混入主音轨并 passthrough 重封装，关闭则保留双音轨。
- **录制辅助**（`RecordingOverlays.swift`）：鼠标点击高亮（左键蓝/右键紫/其他橙，按下 0.8 / 移动 0.3 透明度，未捕获光标时补点）、屏幕放大镜（3x、快捷键开关、截图排除本应用窗口）、录制前倒计时（0–99 秒）、悬浮控制条（停止/暂停/计时/摄像头入口）、完成后悬浮预览（打开/Finder/删除/复制，6 秒自动消失）、定时自动停止（分钟）。
- **摄像头与设备**（`RecordingDevices.swift`）：浮动摄像头窗口（可翻转、圆角、可拖动，画面经窗口被录制流捕获）、iPhone/iPad 预览与直接录制（AVCaptureSession + AVCaptureMovieFileOutput，静音连接移除），启动时置 `kCMIOHardwarePropertyAllowScreenCaptureDevices`；**演示者叠加（Presenter Overlay）**支持——帧信息 `presenterOverlayContentRect` 状态机 + delegate 回调 + 保护延迟设置，叠加激活时自动收起摄像头窗口。
- **快捷键**：主开关外新增 8 个可选热键（停止/暂停继续/录系统声音/录当前屏/录最前窗口/框选/存帧/放大镜），Carbon 注册，默认未绑定（与 QR 一致）。
- **存帧**：录制中保存当前帧为 PNG（`Capturing at <时间>.png`），HDR 帧走 10-bit PNG + EV+1。
- **其他**：H.264 硬件编码器预检（VideoToolbox 探测失败弹窗询问切 HEVC 并持久化）、帧去重（20 帧滚动窗口）、完成/失败/混音系统通知、防休眠可开关。
- **未纳入**：MP3/Opus 音频导出（需第三方编码器依赖）、多窗口同录选择 UI、后期剪辑窗口。
