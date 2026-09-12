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

## 二十、截图与录屏对标升级：延迟截图、聚光灯标注、录屏取消与电平、GIF 导出参数（本节随 v1.1.237 引入）

对标「浮光」等同类工具的演示能力做一轮补强，原则是“吸收对方亮点 + 用我们已有的更深能力拉开差距”：

- **延迟截图**（新增入口，对标“延迟截图”）：新增 `ScreenCaptureShortcutKind.delayedArea`（默认 ⌥⌘7），按下后弹出居中倒计时面板（进度环 + 取消按钮，`SnapzyCapture/DelayedCaptureCountdown.swift`，倒计时算术为可单测的值类型 `DelayedCaptureCountdown`），结束后打开常规区域选区；延迟秒数可在截图页选择（3/5/10 秒，存 `screenCapture.delayedCaptureSeconds`，安全解码默认 5）。菜单栏“延迟截图”、深链 `macpilot://capture/delayed`（兼容 `screenshot/delayed`、`delayed`）同步入口；快捷键走既有 Carbon 管线（新 id 13），支持冲突检测与编辑器改键。
- **HUD 接入聚光灯标注**：`AreaSelectionAnnotationTool` 新增 `spotlight`，截图后工具栏新增聚光灯按钮（⌀ 圆点虚线图标），经既有桥接映射到 `SmartAnnotationTool.spotlight`——此前该工具只能在独立编辑器中使用，现在框选标注可直接压暗聚焦。
- **录屏悬浮控制条升级**：新增取消按钮（两段式：第一次点击进入“确认取消”武装态、3 秒未再点自动解除，第二次点击才真正丢弃文件，防误触）；新增实时麦克风电平条（4 段），引擎在 AVAudioEngine 麦克风 tap 里计算 RMS（`ScreenRecordingEngine.microphoneRMS`，≈10Hz 节流经 `microphoneLevelHandler` 回传模型 `@Published microphoneLevel`；命名设备路径不提供电平）；控制条随之加宽。
- **完成预览与文案本地化**：完成预览右键菜单（显示于访达/删除/拷贝/关闭）此前硬编码英文，现经 `AppText` 按模型语言本地化（`scRecordingRevealInFinder` 等新键，中英同步）。
- **GIF 导出参数**（对标方无 GIF 能力）：导出帧率（10/15/20/24）与最大宽度（480/720/960/1080 px）可在录屏页“输出”卡片配置，存 `screenRecording.gifFramesPerSecond/gifMaximumWidth`（夹取 5–30、200–2000，解码默认 15/960），`ScreenRecordingGIFConverter` 直接接收参数。
- **兼容性**：`StoredConfiguration.version` 18 → 19；所有新键走 `decodeIfPresent ?? 默认`，旧 config.json 无需迁移。新增 `Tests/MacPilotTests/CaptureEnhancementsTests.swift`（12 例：快捷键默认/往返、旧配置解码、倒计时算术、聚光灯桥接、RMS、GIF 参数与钳制）。

> **v1.1.257 验收修复**：① 倒计时面板“取消”按钮此前只关面板、不重置模型的倒计时中标志，导致取消一次后延迟截图被静默忽略——现通过 `onCancel` 回调重置，`shutdown()` 同步关闭面板；② 倒计时驱动从 SwiftUI `.task` 移入控制器（Task + ObservableObject 状态），归零/取消路径不依赖视图生命周期。真机端到端验证：面板出现 → 恰好 5 秒关闭 → 选区浮层开启。

## 二十一、吸收「浮光」演示交互：准备录制条与序号自动重排（v1.1.258）

按用户验收反馈，把视频演示中尚未吸收的两项核心交互补齐：

- **准备录制条（对标"浮光"录屏"准备录制"）**：框选/选窗口提交后不再立即开录，先在选区下方（放不下则上方）弹出深色胶囊工具条：准备录制标签 + 实时选区尺寸、麦克风开关、系统声音开关、**16:9 横屏 / 9:16 竖屏**一键重设框（保持选区中心、夹回所在显示器，`RecordingRegionFraming` 纯函数可测）、取消 X、绿色开始按钮。点开始才走原有倒计时→开录流程；音频开关直接持久化到 `screenRecording.capturesMicrophone/capturesSystemAudio`。新增 `Recording/RecordingPrepareBar.swift`（控制器 ObservableObject + 非激活 NSPanel）；`ScreenRecordingModel.prepareRecording(captureRect:)` 接管原 `onRecordingSelection→start` 直通路径，准备期间屏蔽重复触发，`shutdown()` 同步清理。设置页"录制行为"新增"录制前显示准备工具条"开关（`showsPrepareBar`，默认开，关闭恢复旧行为）。真机 E2E：合成点击提交窗口选区后，准备条在目标窗口下方出现（346×44）。
- **序号标注自动重排（对标"有的序号重新排一遍"）**：橡皮/删除任一步骤序号后，剩余序号按绘制顺序立即重排为 1..n，下一个新序号从 n+1 继续（此前只有删光才归 1，删除中间序号会留空洞）。撤销/重做基于文档快照，天然恢复重排前编号。
- 新增 7 个测试：序号重排×3、16:9/9:16 适配几何×2、`showsPrepareBar` 旧配置解码、偏好开关。全量 425 例通过。

## 二十二、iPhone 远程控制：局域网直连锁屏 / 黑屏 / 解锁 / 唤醒解锁（本节随 v1.1.300 引入）

MacPilot 新增配套 iPhone App「MacPilot 遥控」（`iOS/MacPilotRemote/`）。目标是「掏出手机点一下」：同一 Wi-Fi 下自动发现 Mac、自动连接，四个动作一键完成，不需要输入 IP、端口，也不需要每次重新配对。

### 分层结构

- **共享协议包** `Packages/MacPilotRemoteProtocol/`（新 SwiftPM target，macOS 14+ / iOS 17+）：命令与模型、4 字节大端长度前缀分帧、明文/加密帧编解码、P-256 ECDH 配对、HKDF-SHA256 会话密钥、ChaChaPoly 加解密、重放保护、Bonjour TXT 记录解析。Mac 与 iOS 共用同一份实现，不存在两套协议代码。
- **Mac 服务端** `Sources/MacPilot/RemoteControl/`：`RemoteControlServer`（NWListener + Bonjour 注册，优先 43847，占用时自动动态端口）、`RemoteConnection`（握手状态机 + 加密命令通道）、`RemoteCommandRouter`（命令 → `MacScreenControlService`）、`RemotePairingManager`（6 位配对码）、`RemoteDeviceStore`（已配对设备 + 钥匙串配对密钥）、`RemoteControlSettingsView`（设置页）。
- **iOS 客户端** `iOS/MacPilotRemote/`：`RemoteDiscoveryService`（NWBrowser 发现 `_macpilot._tcp`）、`RemoteConnectionManager`（长连接 + 握手 + 保活 ping）、`RemoteAppModel`（唯一状态源）、SwiftUI 三个标签页（控制 / 设备 / 设置）与配对弹窗。

### 屏幕控制重构（阶段一）

把锁屏/解锁的**原语**从 `BLEUnlock.swift` 抽到 `Sources/MacPilot/ScreenControl/`，BLE 与远程控制共用，但**策略**各自独立：

- `MacScreenControlService`：`lockScreen`、`sleepDisplay`、`wakeDisplay`、`unlock`、`wakeAndUnlock`、`currentState`，统一返回 `ScreenControlResult`，并通过 `willLock` / `didUnlock` 回调让 BLE 侧维护「手动锁定」与「抑制自动解锁」状态。
- `ScreenCredentialStore`：登录密码只存在于本机钥匙串；通过 `SecretStore` 协议抽象，测试用内存实现，绝不触碰真实钥匙串。
- `ScreenUnlockExecutor`：快捷键锁屏（⌃⌘Q）、显示器电源、键盘事件注入。
- `ScreenLockState` / `ScreenLockStateResolver`：屏幕锁定状态判定，`BLEScreenLockState` 等旧类型以 typealias 保留，既有测试不变。
- 重试策略刻意不同：BLE 保持 `[2, 5, 9, 14, 20]` 秒，远程使用更快的 `[0.35, 0.8, 1.5, 2.5, 4]` 秒。

### 安全模型

- **Mac 登录密码永不出 Mac**：协议里没有 `password` 字段，iPhone 不存储、不接收、不请求密码；解锁由 `MacScreenControlService` → `ScreenCredentialStore` → `CGEvent` 在 Mac 本地完成。
- 首次配对：临时 P-256 ECDH（每次连接一对临时密钥），HKDF-SHA256 从共享密钥派生 6 位配对码与 256 位长期配对密钥。配对码只用于**人工确认**，不是长期密钥；Mac 必须在「远程控制」页手动打开 120 秒配对窗口才会显示配对码。
- 长期配对密钥分别存两端钥匙串（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不参与 iCloud 同步），之后连接只走 `clientHello → serverHello → authRequest(clientProof) → authResult(serverProof)`，双向验证。
- 会话密钥 = HKDF(配对密钥, salt: clientNonce‖serverNonce, info: "MacPilotRemote-v1-session")；所有命令帧为 `0x02 ‖ UInt64 序号 ‖ ChaChaPoly`，序号严格递增 + 时间戳偏移校验，重放帧直接被丢弃。
- 日志只记录命令名、耗时与结果，绝不记录密码、配对密钥、会话密钥与报文内容。

### 性能

- 发现走 Bonjour（`NWBrowser`），不做 IP 扫描、不发 UDP 广播、不用 HTTP。
- 连接由**唯一一个前台监管循环**负责（见下节「自相残杀的快速路径」），先试上次成功连接的地址直连、再试 Bonjour 结果，尝试超过 4 秒无传输层才丢弃。
- 连接保持长活，命令走同一连接；15 秒一次 `ping` 保活并回传往返延迟。
- 重试节奏前密后疏 `0.25、0.5、1、1.5、2、3、5` 秒——刚打开 App 时最密；进入后台主动断开，回到前台立即重连。
- 阶段七埋点：发现耗时、TCP 连接耗时、握手耗时、命令往返、命令执行耗时，iOS 设置页「连接性能」可见；Mac 端日志输出 `handshake complete event=... latency=...ms`。

### 验证

- `Packages/MacPilotRemoteProtocol/Tests/`：24 例（分帧、加解密、重放、配对码、TXT 记录、命令元数据）。
- `Tests/MacPilotTests/RemoteControlTests.swift`：19 例（屏幕控制模型、命令路由、配置编解码、配对管理器、设备存储）。
- iOS 端 `xcodegen generate` + `xcodebuild -sdk iphonesimulator` 构建通过、无警告。

### 踩过的坑

- **自相残杀的「快速路径」：一个机制取消掉自己发起的连接，而没有任何东西再发起它。** 旧实现先直连上次的地址，然后 500ms 到点，如果传输层还没就绪就 `disconnect()` 掉**自己刚发起的那条连接**。链路本地的邻居解析冷启动很容易超过 500ms——尤其是 Mac 换了网段、记录里的地址已失效时，那正是用户报障的场景。而 Bonjour 结果通常就在这 500ms 内到达，`handleDiscovery` 看到「已有连接在飞」就正确让路了；等快速路径把自己杀掉之后**再没有东西重新发起连接**，因为发现只在结果**变化**时回调，Mac 一直在列表里不会变。于是永远停在「搜索中」，而手动点击走的是另一条优先用 Bonjour 新端点的路径，所以秒连。修法是把重连收敛成唯一一个监管循环：有连接在飞时绝不 `connect()`，超时才丢弃，且不管有没有回调都会继续重试。
- **`connectingDeviceID` 不能用来判断「有没有尝试在飞」。** 蓝牙通道在握手拿到 `serverHello` 之前**没有 device ID**，所以把它传成 `nil` 时，任何只认 ID 的守卫都会以为「没有尝试」，于是放行一次新的连接、把活着的蓝牙尝试取消掉。现在用独立的 `hasActiveAttempt`（即「transport 是否存在」）判断。
- **`CBUUID` 不是 `Sendable`**，`static let` 的 UUID 常量在 Swift 6 严格并发下会报 `MutableGlobalVariable`。仓库里已有的蓝牙标识符就是用 `nonisolated(unsafe)` 声明的，新代码保持一致。
- **`NWBrowser` 必须用 `.bonjourWithTXTRecord`，不能用 `.bonjour`。** 两者都叫「Bonjour 浏览」，但 `.bonjour(type:domain:)` 的浏览描述符**不请求 TXT 记录**，每个结果都带 `metadata == .none`，于是 `RemoteServiceInfo(txtRecord:)` 解析失败、`makeMac` 把结果全部丢掉。现象是「手机永远找不到 Mac」，而 Mac 端 `dns-sd -B` / `-L` 一切正常、`lsof` 也显示端口在监听——因为它根本不是网络或权限问题。排查时看 iOS 日志里 `nw_browse_descriptor ... (no txt)`（错误）与 `(txt)`（正确）的区别即可一眼定位。
- 这类「结果被静默过滤」的失败与「网络里确实没有目标」在 UI 上完全无法区分。因此 `RemoteDiscoveryService` 现在单独统计 `unrecognizedServiceCount` 并写 `os_log`，首页也区分「未发现」与「发现了但读不到信息」。
- SwiftUI 中**嵌套的 `ObservableObject` 不会向上转发 `objectWillChange`**：视图观察 `RemoteAppModel` 时，直接读 `appModel.discovery.xxx` 不会随之刷新。发现相关状态改为镜像到 `RemoteAppModel` 自己的 `@Published` 属性。**同一个坑还会以「看起来能用」的形态出现**：`RemoteAppModel.pairedMacs` 转发到 `PairedMacStore`，因为 `handleDiscovery` / `handleConnected` 恰好也会改模型上的其他 `@Published`，列表看起来是正常的；但 `setDefault` 只改 store、`forget` 删除非当前设备时只改 store，这两条路径没有任何东西触发刷新，界面就会停在旧状态。最终改成把 `store.objectWillChange` 桥接到模型，而不是逐个镜像——镜像只是碰巧掩盖问题。
- **`RemotePairing` 只写 Keychain，没人写设备列表。** `PairedMac` 结构体全工程从未被构造，而 `PairedMacStore.markConnected` 是 `guard var mac = mac(id:) else { return }`，只更新「已存在」的条目。于是配对成功后设备列表永远为空：已配对的 Mac 一直被当成新设备显示「配对」按钮，`preferredMacID` 永远为 nil，**「记住上次地址直连」的快速路径从未执行过**——功能看起来只是「偶尔慢一点」，实际是整条路径被静默禁用。现在 `handleConnected` 会先 `ensurePaired` 再 `markConnected`，并用 `RemoteKeychain.hasPairingKey` 认领「密钥还在、记录丢了」的 Mac（重装、旧版本）。
- **`includePeerToPeer` 让发现不必局限在同一局域网，但系统可能因此挑中 AWDL。** `NWParameters.includePeerToPeer = true`（listener 与 browser 都设了）会让系统把 AWDL——AirDrop / AirPlay / Sidecar 用的点对点 Wi-Fi——也纳入候选，所以 Mac 接网线、iPhone 用蜂窝这种「不在同一网络」的组合理论上也能发现。实测确认服务确实在 `awdl0` 上广播，且与 App 同配置（`includePeerToPeer` + `.bonjourWithTXTRecord`）的 `NWBrowser` 会在 `awdl0` 上枚举到它。但副作用是：系统会自己挑传输，可能选中 AWDL，而 AWDL 是时间切片共享电台，吞吐和延迟都明显差于基础设施 Wi-Fi——对「<500ms」是个隐患。用 `Scripts/verify-awdl.sh check` 做前置检查、`Scripts/verify-awdl.sh watch` 判断一条连接到底走的是哪个接口（`lsof` 把 IPv6 链路本地的 scope 以十六进制写在地址里：`fe80:c::` 里 `c`=12=en0，`fe80:11::` 里 `11`=17=awdl0）。
- **socket 是 `ESTABLISHED` 不代表客户端还活着。** iOS 会把挂起的 App 连同它的 TCP 连接一起冻结，连接会**无限期**保持 `ESTABLISHED`；而 TCP keepalive 是**对端内核**应答的，App 冻结了一样会 ACK，所以 keepalive 查不出这种情况。实测：同一台 iPhone 累积出 2–3 条 `ESTABLISHED`，但只有一条心跳流；Mac 端 `active` 计数只增不减，冻结的手机一直算「已连接」。只有**应用层心跳**能识别，因此 Mac 现在按 `RemoteConnectionIdlePolicy` 自行回收（已认证 90s / 配对中 180s——后者必须大于 120s 配对窗口，否则用户还在输码就被断开），keepalive 作为补充只负责「设备本身消失」。验证这类接线要小心：集成测试里 `RemoteFrameCodec.encodePlain` **内部已经做了长度前缀**，再套一层 `frame()` 会双份帧头，服务端按错误的长度切包后走 `fail()` 关闭连接——而 `lastActivityAt` 因为是在解析前打时间戳，仍然会更新，断言「流量刷新了心跳」会通过，只有断言「连接没被关闭」才暴露出问题。

## 二十三、多传输层：抽出 `RemoteTransport`，蓝牙作为第二条通道

「除了局域网，还有别的发现方式吗」的答案落地成了链路层可替换、协议层一行不动。

### 分层

- `MacPilotRemoteProtocol`（纯 Foundation + CryptoKit）：分帧、ChaChaPoly、配对、命令。**保持不变**。
- `MacPilotRemoteTransport`（新 target，两端共用）：`RemoteTransport` 协议 + `NetworkRemoteTransport`（TCP，Wi-Fi 与 AWDL 是同一个实现，区别只在接口）+ `L2CAPStreamTransport`（BLE 流）。
- 角色代码各自保留：Mac 是 `CBPeripheralManager` 外设（`RemoteBLEPeripheral`），iOS 是 `CBCentralManager`（`RemoteBLECentral`）——BLE 的角色本来就不对称，没有可共用的部分。

### 为什么蓝牙便宜

`CBL2CAPChannel`（macOS 10.14+ / iOS 11+）给的是 `InputStream`/`OutputStream`，是**面向流的**而不是消息。所以 4 字节长度前缀、ChaChaPoly、重放保护、配对信任链**全部原样复用**，只是把 `NWConnection` 换成流。GATT 服务只是一个交接仪式：手机读一个 characteristic 拿到 PSM，然后 `openL2CAPChannel`，之后就是同一条字节流。

实测负载也够：最大的帧是带 P-256 公钥的 `serverHello`（350 B），加密命令帧 130 B，`getState` 应答 241 B；ATT MTU 185 B，即 1–2 个分片。

### 传输选择

Wi-Fi/AWDL 优先，蓝牙保底——**不是并列竞速**。蓝牙建立是数秒级（扫描 + 连接 + 服务发现 + 开 L2CAP），且两端都要耗电维持，所以只在网络**连续失败两次**之后接管；扫描只在前台且未连接时进行。已连接后立刻停止扫描并关掉闲置通道。

### 诊断：接口名让 AWDL 可见

设置页新增「连接方式」，显示当前链路与接口（`网络 · en0`、`网络 · awdl0`、`蓝牙`）以及蓝牙保底状态。接口名取自链路本地地址的 scope 后缀——实测确认 `currentPath?.localEndpoint` 会带 `%en0`（`fe80::cfc:eb99:7564:5494%en0.50445`），所以**一条连接到底走 Wi-Fi 还是 AWDL，现在在 App 里直接能看出来**，不必再用 `lsof` 的十六进制 scope 反推。

## 二十四、黑屏不再顺带锁屏：把背光压到 0 而不是让显示器休眠（v1.1.305）

### 问题不在 MacPilot

「黑屏」的调用链是 `RemoteCommandRouter .displayOff` → `MacScreenControlService.sleepDisplay()` → `DisplayPower.sleepDisplay()` → `/usr/bin/pmset displaysleepnow`，**全程没有任何锁屏调用**。锁屏是 macOS 的策略加的：`com.apple.screensaver` 的 `askForPassword` 一旦为「立即」（新装系统的默认值），**任何**显示器休眠都会顺手锁掉会话。

所以这不只影响遥控——Mac 菜单栏的「关闭屏幕」同样会锁。而 MacPilot 本来就有独立的「锁屏」动作，所以「黑屏」顺带锁屏是语义错位，不是缺功能。

### 解法：显示器不休眠，只把背光压到 0

系统认为显示器一直醒着，锁屏策略就永远不会触发。屏幕全黑但会话不锁。

| 路径 | 结论 |
|---|---|
| IOKit `IODisplaySetFloatParameter` / `IODisplayConnect` | ❌ 在 Apple Silicon 内置屏上**已失效**——`IOServiceMatching("IODisplayConnect")` 的迭代器是空的，读都读不到 |
| 私有框架 `DisplayServices`（`brightness` 命令行工具用的就是它） | ✅ M1 MacBookAir10,1 实测：读 `0.9026` → 写 `0` → 回读 `0.0` → 写回 `0.9026`，全部 `rc=0` |

`DisplayServices` 是私有的，但**用 `dlopen`/`dlsym` 运行时解析**，所以 App 不产生链接期依赖；而且每一处调用都是可选的——拿不到就退回真休眠，不会比以前更差。Developer ID 分发 + 公证不检查私有 API（那只在 App Store 审核管）。

### 最大的坑：没有东西会把背光「唤醒」

显示器根本没睡，所以按键、动鼠标**不会**点亮它——系统认为它一直醒着。屏幕会一直黑着，直到有人去按亮度键。这是必须补的一环：

- 记下黑屏瞬间的「自上次输入的时间」（`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)`，其中 `anyInputEventType` 是 `CGEventType(rawValue: ~0)!`，即头文件里的 `kCGAnyInputEventType`，Swift 没有对应成员）。
- 每 400 ms 采样一次，**空闲时间倒退了**就说明刚有人动了输入设备 → 立即恢复背光。
- 用轮询而不是全局事件监听，因为**它不需要辅助功能授权**。这一条是刻意的：MacPilot 绝不能把用户困在黑屏上。判定抽成 `DisplayPower.didUserInputOccur(idleNow:idleAtBlank:)` 这个纯函数并加了测试——逻辑一旦写反就是「用户被困黑屏」。

### 边界：哪条路走真休眠

只有**用户主动的黑屏**（遥控 `displayOff`、菜单栏「关闭屏幕」）走亮度归零，即 `DisplayPower.turnOffScreen()`。蓝牙靠近锁屏（`BLEUnlock` 的 `turnOffScreen`）和 `AwakeSessionManager` 仍然走真正的 `sleepDisplay()`——因为那条路希望 Mac 能继续空闲休眠；若在那里把背光压到 0，显示器永不休眠，**系统也就再也不会自动睡眠**，是明显的功耗回归。

### 实测（用仓库里真实的 `DisplayPower.swift` 编探针跑）

```
0. 合成事件能否冒充用户输入: 能（idle 50.13 → 0.29）
1. 初始亮度            = 0.54687065
   blankDisplay() -> true  isBlanked=true  亮度=0.0
2. 静置 1.5s（无输入）  isBlanked=true  亮度=0.0   ← 看门狗不会误触发
3. 模拟用户输入后       isBlanked=false 亮度=0.54687065  ← 精确恢复
✅ 亮度归零 → 保持黑屏 → 恢复，全链路通过
```

`unlock` / `wakeAndUnlock` / 解锁重试循环里也一并补了「黑屏也算屏幕没亮」的判断，否则亮度归零状态下解锁会先对着黑屏敲键盘（虽然合成按键本身也会触发恢复，但不该依赖这个副作用）。

## 二十五、Mac 侧 BLE 管线实测：能发布，但三个反直觉的坑（v1.1.305 期间）

目标里「BLE 后端到端」一直被两件事挡住：Mac 端还是旧版、手机必须在场。为了不再空等，我把 `RemoteBLEPeripheral` / `RemoteBLEService` **原样**编进一个带 `Info.plist` 的探针 App 里跑，用真实代码验证 Mac 侧。

### 已验证

| 项 | 结果 |
|---|---|
| `publishL2CAPChannel(withEncryption: true)` | ✅ 在这台 M1 上拿到 `psm=193` |
| 服务添加 + 开始广播 | ✅ `didAdd error=none` |
| `start()` → `stop()` → `start()` | ✅ 重新发布 PSM（**这正是 v1.1.304 改的点**） |
| `stop()` → `start()` 零间隔 | ✅ 也重新发布，没有和 `removeAllServices()` 抢 |
| 失败行数 | **0** |

### 坑一：探针里首个 state 回调晚到约 18 秒——但这是 TCC 的，不是 App 的

探针冷启动后 **15 秒内没有任何回调**，到 **+18.58s** 才收到 `didUpdateState raw=5`（`poweredOn`），此时才发布 PSM，期间**既不发布也不报错**。

**但装到正式版后查到的事实是**：

```
[14:56:41] MacPilot 1.1.305 启动
[14:56:44.411] BLE peripheral powered on; publishing L2CAP channel
[14:56:44.434] BLE L2CAP channel published psm=192
```

**真实 App 只要 3 秒**，而且全程没有任何失败行。差别在于身份：正式版是 Developer ID 签名、TCC 授权稳定；探针每次重编 cdhash 都变，TCC 要重新评估，评估期间 CoreBluetooth 一个回调都不投递。

所以那条「18 秒」属于**探针环境**，不是产品行为。保留下来的教训只有一条：**用临时签名的二进制测蓝牙时，不要拿冷启动的头几秒下结论。**

### 坑二：同机 loopback 不可行

我一度想用本机同时当 peripheral 和 central 来自测 GATT→L2CAP 交接，**行不通**：central 扫了 **134 秒**也收不到自己的广播（单射频收不到自己发的包）。所以 `openL2CAPChannel` 这一步**必须有第二台设备**，本机无法自测。这条排除了一个看似省事的捷径。

### 坑三：TCC 归属会决定探针能不能跑

从终端/自动化宿主 exec 的进程，TCC 把蓝牙请求**归属给宿主**（这里是 DSH）。宿主没有 `NSBluetoothAlwaysUsageDescription` 时，tccd 直接拒绝并 **SIGABRT**：

```
Refusing authorization request for service kTCCServiceBluetoothAlways
  and subject Sub:{com.deepseek.harnessdesk} without NSBluetoothAlwaysUsageDescription key
```

必须走 LaunchServices（`open -a`）让归属落到探针自己身上，才会弹询问框。另外**每重新编译一次 cdhash 就变**，TCC 会重新评估，评估期间 CoreBluetooth 同样一个回调都不投递——这一点曾经让我误判出一个「首次 start 不发布 PSM」的假 bug，追了三轮才排掉。**结论：`RemoteBLEPeripheral` 没有 bug。**

## 二十六、AWDL 端到端实测通过（v1.1.305）

### 通过的证据：四重独立确认

条件：手机 Wi-Fi **开着但不连任何网络**、蓝牙**关闭**、App **完全重启**。

| 来源 | 读数 |
|---|---|
| App 自己的传输诊断 | `connection ready kind=network link=awdl0` |
| 独立 socket 守望（netstat） | `fe80::109c:73ff:.43847 ← fe80::c87a:b0ff:.53658 ESTABLISHED` |
| lsof 完整 scope | `[fe80:11::109c:73ff:fe03:41dc]:43847 → [fe80:11::c87a:b0ff:feaf:c141]:53658`，`0x11` = 17 = **awdl0** |
| IPv6 邻居表 | 连接前 awdl0 上**只有 Mac 自己**（`permanent`）；连接后多出 `fe80::c87a:b0ff:feaf:c141%awdl0`（iPhone 的 MAC `ca:7a:b0:af:c1:41`） |

握手 `event=auth latency=355ms`（同一局域网内是 70ms——AWDL 慢一些但完全可用），并且 `client hello name=iPhone paired=true`，**不需要重新配对**。

**结论：AWDL 端到端成立。** `includePeerToPeer` + Bonjour 这条路真的走通了，不需要任何 IP/端口输入（`tests` 里那 7 个套件保证的正是这类不变量）。诊断 UI 报出的 `awdl0` 与独立读到的接口索引 17 严格一致，说明「当前传输 + 接口」这个诊断本身是可信的。

### 流程发现：换网后必须「彻底重启 App」，切回前台不够

前两次尝试全部失败，而且 Mac 侧 `ndp` 显示 **awdl0 上从来没有出现过任何对端**——手机的 AWDL 流量根本没发出来。第三次改成**从后台卡片上滑彻底关掉 App、再重新打开**，两分钟内就连上了。

区别在于：去「设置」里改网络会让 iOS 挂起 App，**切回前台只是「恢复」**，它内部那个已经失败的 `NWBrowser` 和连接状态可能一直是旧的。**恢复 ≠ 重新开始。**

这是个真实的用户可见限制，写在这里以免以后当成玄学：

> 手机换了网络之后，如果遥控 App 一直连不上，**彻底退出重开一次**，而不是切回前台等它自己恢复。

（顺带确认：`Networking/RemoteDiscoveryService.swift` 的 `includePeerToPeer = true` 与 `.bonjourWithTXTRecord` 组合是正确的，Mac 侧 `RemoteControlServer` 的监听和连接也都开了 P2P；这条链路两头都没有代码改动需要做。）

## 二十七、BLE 端到端：卡在最后一公里（GATT 连接不建立）

### 逐层验证：Mac 侧和 iOS 侧各自都是对的

| 层 | 证据 |
|---|---|
| Mac TCC 授权 | bluetoothd `CBMsgIdTCCDone` ✓ |
| L2CAP 发布 | `Automatically selected psm:193` / `Registering L2CAP Channel with PSM 0x00c1` ✓ |
| GATT 服务 | statedump：服务 `6D616350-…-0001` + 特征 `…-0002`（read），值 `[ C1 00 ]` = PSM 193 ✓ |
| 广播请求 | `Received 'start advertising' … UUID(s) [ 6D616350-…-0001 ]` ✓ |
| 广播结果 | 新增的 `peripheralManagerDidStartAdvertising` 报 `error=none` ✓ |
| iOS 蓝牙状态 | `BLE central state=5`（poweredOn）→ `BLE scanning for the MacPilot service` ✓ |
| iOS 发现 | `BLE found the Mac; connecting` —— **手机确实看得见广播** ✓ |

### 卡住的地方

`connect()` 之后**永远不回调**：既没有 `didConnect`，也没有 `didFailToConnect`。12 秒后被看门狗重启，循环往复。而 Mac 侧**从控制器到 App 都没有任何连接痕迹**——bluetoothd 的 LE 连接事件里找不到我们的外设。

### 已排除的原因

1. **「128 位 UUID 进 overflow 区看不见」** —— 排除。官方文档：前台初始包 28 字节，128 位 UUID 占 18 字节装得下；而且手机确实 `found` 了。
2. **「MacPilot 这个 App 的问题」** —— 排除。把真实 `RemoteBLEPeripheral` 原样装进独立探针 App，用完全相同的配置广播，4 分钟同样没人连。
3. **「和距离感应解锁抢链路」** —— 排除了「释放就好」这个简单版本。关掉距离感应、确认 Mac 已释放与 iPhone 的 BLE 连接（`system_profiler` 里 BENG 消失）后，**仍然连不上**。
4. **「广播缺设备名导致不可连接」** —— 排除。加上 `CBAdvertisementDataLocalNameKey` 再广播，同样连不上。

### 目前最可疑的

iPhone 的蓝牙栈可能**缓存了与这台 Mac 的陈旧链路状态**（距离感应解锁长期握着的那条），因而静默丢弃 connect。这与「手机 found、Mac 侧毫无痕迹」完全吻合——连接请求可能**在手机本地就被丢掉了**，根本没发出去。下一步要验证的是**把手机蓝牙关掉再打开**（重置协议栈）后重试。

### ⚠️ 诚实声明

上面第 2、4 两项实验是在**无法确认手机 App 仍在前台扫描**的情况下跑的。若当时 App 已被 iOS 挂起，这两次阴性结果**不成立**，必须在确认 App 处于扫描状态的前提下重跑。这条限制必须和结论一起保留。

### 顺带修掉的真实缺陷

- `RemoteBLEPeripheral` 没有实现 `peripheralManagerDidStartAdvertising` → 广播失败是完全静默的。**已补上并验证有效**（探针里打出 `DIAG didStartAdvertising error=none`）。
- iOS 的 `isActive` 返回 `wantsChannel`，**权限被拒/蓝牙关闭时界面照样显示「搜索中」** → 界面会说谎。已改为「有真实诊断文本就优先显示」，并给 `beginScanningIfPossible` 的每个提前返回都加上原因（`BLE waiting for Bluetooth: state=…`），`centralManagerDidUpdateState` 也把原始状态值打出来。

## 二十八、BLE 失败根因收敛：方向反了（角色应当对调）

把第二十七节的所有观测放在一起，指向一个很具体的结论。

### 两台设备上，只有一个 BLE 方向被证明可用

| 方向 | central | 实测 |
|---|---|---|
| iPhone → Mac | 手机 | ❌ **从未成功**：`didDiscover` 之后 `connect()` 永不回调（既无 `didConnect` 也无 `didFailToConnect`），12 秒看门狗重启，循环；Mac 侧从控制器到 App 零痕迹 |
| **Mac → iPhone** | Mac | ✅ **连续数小时 `connected=true`**——BLEUnlock 的距离感应解锁一直是这么连的 |

辅助证据：Mac 扫描到的 iPhone 广播带 `DvF 0x40000000100 < Family Connectable >`，即 iPhone 作为外设**广播是可连接的**，Mac 作为 central 能稳定建立并维持链路。反过来那条方向，**换两个独立广播者（MacPilot 自己 + 一个干净探针）、加不加设备名、手机蓝牙重置后，全部失败**。

所以问题不在我们的代码，而在 **macOS 作为 BLE 外设、被 iOS 作为 central 连接的这条方向本身**。

### 修法：把两个角色对调

- **iPhone 当外设**：publish L2CAP 通道 + 暴露 PSM 特征 + 广播
- **Mac 当 central**：扫描 → 连接 → 读 PSM → 打开 L2CAP 通道

**可行性已经查证**：

```
$ grep publishL2CAPChannel $(xcrun --sdk iphoneos --show-sdk-path)/.../CBPeripheralManager.h
- (void)publishL2CAPChannelWithEncryption:(BOOL)encryptionRequired NS_AVAILABLE(10_14, 11_0);
```

macOS 与 iOS 可用性完全一致（`10_14` / `11_0`），**iOS 可以发布 L2CAP 通道**。

**复用程度**：`RemoteBLEService`（UUID + PSM 编解码）本来就对称，`L2CAPStreamTransport` 收的就是 `CBL2CAPChannel`，因此**分帧层与 ChaChaPoly 加密层一行不改**——正好符合「复用现有分帧与加密层不动」的要求。需要新写的是 iOS 侧的外设和 macOS 侧的 central（即两端实现互换）。

### 需要权衡的代价

对调后**手机侧要持续广播**，而 iOS 外设广播有电量成本；后台行为也和现在（`bluetooth-central` 常驻扫描）不同。这是设计取舍，不应当由实现方单方面决定。
