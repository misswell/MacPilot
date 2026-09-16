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

> ⚠️ 这一版只在**外接显示器不是主显示器**时成立：它问的是 `CGMainDisplayID()` 的背光，而合盖场景下主显示器正是那台没有背光可调的外接屏。当时的「回退到真休眠」就是后来「黑屏却锁屏」的根因，见第三十节。

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

## 二十九、角色对调：链路打通了，数据面另有两个真 bug

### 对调本身是完全正确的

Mac 当 central、手机当外设之后，**BLE 链路一次就建立成功**：

```
BLE central starting
BLE central state=5
BLE scanning for the phone
BLE found the phone; connecting
BLE opening L2CAP channel psm=192
BLE L2CAP channel open
connection ready kind=bluetooth link=BLE      ← 传输层生效
incoming BLE connection accepted active=1
```

从「发现」到「通道打开」约 **0.9 秒**。第二十七、二十八节的判断得到证实：**原来那条方向（Mac 当外设、iOS 当 central）就是建立不起来**，换方向即刻可用。`publishL2CAPChannel` 在 iOS 上 `NS_AVAILABLE(10_14, 11_0)`，与 macOS 完全对称，分帧与 ChaChaPoly 层一行未改。

### 顺带挖出两个真 bug（第二个是共享传输层的）

**1. 看门狗用错了守卫（iOS）**

```swift
if connection.connectingDeviceID != nil {   // BLE 尝试没有 deviceID
```

`RemoteConnectionManager.hasActiveAttempt` 早就为这个坑写好（注释明确写着「BLE 通道在握手完成前没有 device ID，只看 ID 的守卫会乐意取消一次正在进行的 BLE 尝试」），**但看门狗没有用它**。后果：BLE 传输刚创建 200ms，循环就再走网络分支，`connect` 内部先 `disconnect()` 把 BLE 传输踩掉。

**2. Foundation Stream 的线程/RunLoop 约束（共享层）**

```swift
func start() {
    input.open()          // 在调用者线程（主线程）打开
    output.open()
    let thread = Thread { self?.run() }   // 却在另一条没有 RunLoop 的线程上轮询
```

`CBL2CAPChannel` 给的是 Foundation 流，而流**必须「调度到、打开于、使用于同一条正在跑 RunLoop 的线程」**。原实现违反了这个约定（在调用者线程 open、在另一条没有 RunLoop 的线程上轮询），并且依赖了一个不可靠的事件：单元测试里那条 `CFStreamCreateBoundPair` 的 `hasSpaceAvailable` 实测不会触发（加了 0.1 秒兜底 tick 后，连续发送用例从 14ms 变成 113ms，正是它在起作用）。

修法：`StreamPump` 端到端独占自己的线程——在那里 schedule + open，读用 `StreamDelegate` 事件驱动，写由事件加兜底 tick 保证；`send` 只碰队列、绝不跨线程碰流（早先一版用 `perform(_:on:)` 编送，而**编送一旦落空，现象与「对端从没发过东西」完全无法区分**，这个失败模式不值得留着）。**35 个测试仍然全过。**

> ⚠️ **更正**：这一条当时被我当成 `Bad file descriptor` 的根因，**是错的**。下面的探针实验证明，即使把两条流完美调度并打开在同一个 RunLoop 上，也仍然第一次读写就失败。它是一处真实的契约违反，值得修，但**不是拦路的那个**。

**3. `CBL2CAPChannel` 没有被保留（共享层）**

`L2CAPStreamTransport` 只存了 `channel.inputStream` / `channel.outputStream`，而流是通道的附属物。改成在传输层里持有 `CBL2CAPChannel` 本身。同样**不是**拦路的那个，但形状是对的。

### 决定性实验：数据面卡在平台层，不在我们的代码里

最小探针（复用真实的 `RemoteBLECentral`）拿到通道后，把两条流 **schedule 到主 RunLoop、在同一线程 open、并保留 channel 对象**，然后每秒打印流状态并试探读写：

```
[+29.2s] in=2(已打开) out=2(已打开) inAvail=true outSpace=true 错误: 无
[+29.2s] <<< 读返回 -1
[+29.2s] >>> 试探写 4 字节 → 返回 -1
[+31.2s] in=7(错误) out=7(错误) 错误: Bad file descriptor
```

流先自报「已打开、可读、可写」，**第一次读和第一次写就双双失败**，随即整体转入错误态。同一条 macOS central → iOS peripheral 路径，两种独立实现（MacPilot 与几十行的探针）复现同一结果。

**这条阴性结果一次排掉三个假设**：不是线程/RunLoop 模型（已完美满足）、不是 channel 生命周期（已持有）、不是 MacPilot 的逻辑（探针里没有 MacPilot 的逻辑）。剩下的解释是**对端（iOS 外设侧）没有把通道真正建立起来**，但手机侧没有任何日志可看——`log collect --device` 需要 root（见第二十七节），而 App 的 BLE 路径本身不写系统日志。

**下一步该做的**：给 iOS 端加**屏上通道诊断**（`peripheralManager(_:didOpen:error:)` 是否触发、pump 打开成功与否、写入/读取字节数、最近一次流错误），把唯一的可见通道（App 界面）用起来。这是能一次定位问题的下一步，改动很小。

### 当前状态：链路通、数据未通

Mac 侧稳定地反复建立通道（发现→通道打开约 0.9 秒），但**那条通道上一次可用的读写都没有成功过**，手机侧也始终没有发出 hello，Mac 因此每次等到 `connection idle timeout; closing silent client`。链路每 ~65 秒断一次并自动重连。

更早的一次探针里，4 分钟、4 条通道、**收到 0 字节**，与 MacPilot 自己的现象一致。

已用排除法否掉的原因：
- ❌ 128 位 UUID 不可见 / 广播缺设备名 / 与距离感应解锁抢链路 —— 见第二十七、二十八节。
- ❌ 角色方向 —— 对调后链路立刻可建立，方向确实曾是问题（第二十八、二十九节开头），但**只解决了「连不上」，没有解决「传不动」**。
- ❌ 看门狗误取消 BLE 尝试 —— 已修，链路因此能稳定建立。
- ❌ 屏幕自动锁定导致 App 挂起 —— 设成「永不」后现象不变，不成立。
- ❌ 线程/RunLoop、channel 生命周期 —— 见上面的更正与决定性实验，均已排除。

### 关于「BLE 后台存活」的实测结论（可写进文档）

App 退到后台（或被系统挂起）后：
- **广播继续**，Mac 仍能反复发现并连上手机（这正是整段排查里 Mac 一直能 `BLE found the phone` 的原因）；
- 但 **App 不会去使用那条通道**——当前的看门狗只在 `isForeground` 时启动，所以后台不会发起协议握手；
- iOS 会周期性断开后台外设连接（实测约 65 秒一次）。

也就是说：**广播能活，会话不能活**。这与 V1「后台不开 socket、切后台就干净断开」的设计一致，但和「BLE 保底能在后台接上」的预期不同，需要在文档里写明。

## 三十、「黑屏」偶尔还是锁屏：被回退掉的真休眠（v1.1.318）

### 现象与根因

用户报告：手机上点「黑屏」只黑不锁，Mac 菜单里点「关闭屏幕」却锁了屏。

两个入口走的是**同一个** `DisplayPower.turnOffScreen()`，所以差异不在入口，而在**当时是否驱动得了背光**。诊断日志把过程完整记下来了：

```
21:11:53.466 [RemoteControl] command received command=displayOff
21:11:53.467 [ScreenControl] display sleep requested reason=backlightUnavailable   ← 背光没驱上
21:11:53.678 [BLEUnlock]     display sleep notification received
21:11:54.008 [BLEUnlock]     screen lock history recorded source=manual            ← 会话被锁
...
21:12:37.754 [ScreenControl] display blanked without sleeping                      ← 盖打开后就正常了
```

`reason=backlightUnavailable` 就是旧代码的回退分支：背光压不下去时它调用 `DisplayPower.sleepDisplay()`，也就是 `pmset displaysleepnow`。显示器一睡，`com.apple.screensaver` 的「立即要求密码」策略就把会话锁掉——**黑屏的调用链里没有一行锁屏代码，锁屏是系统策略加的**。

为什么背光会驱不上？`pmset -g log` 给出了当时的状态：

```
21:10:21 Sleep  Entering Sleep state due to 'Clamshell Sleep'
```

**机器合着盖、用外接 HP 24w**。合盖后内置屏下线，`CGMainDisplayID()` 变成外接屏，而旧代码只问主显示器的背光：这台 HP 对 `DisplayServicesGetBrightness` 返回 `rc=1000`，于是 `blankDisplay()` 失败 → 回退真休眠 → 锁屏。手机上成功的那几次（21:12:37 之后）恰好是盖已经打开、内置屏又变回主显示器的时候——「手机能用、菜单不能用」只是两个入口在不同时刻被试到。

### 修法：黑屏这条路不再有「真休眠」这个回退

1. **`turnOffScreen()` 只在驱动不了背光时改走黑窗，绝不调用 `sleepDisplay()`。** 锁屏是 MacPilot 里另一个独立动作的事。
2. **逐显示器判断，而不是只看主显示器**：`ScreenBlankPlanner`（纯函数，有测试）给每台在线显示器各定一个动作，内置屏与可驱动背光的屏优先走背光。
3. **驱动不了背光的显示器用黑色窗口盖住**（`ScreenBlankOverlay`）。窗口是 `.nonactivatingPanel` + `CGShieldingWindowLevel()`，盖住菜单栏与程序坞、跨 Space 存在，且点它不会把 MacPilot 激活、把用户从原来的前台应用里拽出来。合盖用外接屏的场景就是靠这一条才真的黑得下去。
4. **黑屏期间持有 `PreventUserIdleDisplaySleep`**，否则系统自己的「显示器闲置 10 分钟休眠」迟早会把黑屏变成锁屏——那正是用户要避免的结果。第一次输入、`unblankDisplay()`、以及任何锁屏动作（锁屏必须看得见）都会立即释放它。
5. 真的一台都黑不了时返回失败（遥控会提示「关闭屏幕未生效」），**不再静默变成锁屏**。

### 实测（合盖 + 外接 HP 24w，正是出问题的那套配置）

用仓库里真实的 `DisplayPower.swift` / `ScreenBlankOverlay.swift` 编探针跑：

```
screens=1 main=2
candidate display=2 builtin=false backlight=false
plan=[Step(displayID: 2, action: overlay)]          ← 不再赌主显示器
blankDisplay=true isBlanked=true locked=false       ← 黑了，而且没锁
windows=["layer=2147483628 onscreen=true bounds={{0, 0}, {1920, 1080}}"]
while blanked: PreventUserIdleDisplaySleep named: "MacPilot screen off"
after unblank: []                                    ← 断言精确释放
```

`layer=2147483628` 就是 `CGShieldingWindowLevel()`，`onscreen=true` 且铺满整块 1920×1080，说明黑窗真的在合成；`locked=false` 说明会话没被锁。`swift test` 559 个测试全过。

### 边界

黑屏期间显示器被刻意留在「醒着」，所以这一状态由用户输入界定：按下任意键或动一下鼠标就恢复亮度/收起黑窗，同时释放断言。用户在合盖 + 仅外接屏的场景下点「关闭屏幕」，看到的是一块全黑的外接屏，而不是被锁的登录窗口。

## 三十一、手机端显示并调节 Mac 的亮度与音量

### 做了什么

iPhone 遥控的「控制」页新增一张「亮度与音量」卡片：两个滑杆分别显示并实时调节 Mac 的屏幕亮度与输出音量，音量右边还有一个静音按钮。数值直接读自 `MacRemoteState`——也就是手机上每次命令响应里本来就有的那份状态，没有新增轮询。

### 协议：只做加法，两个 App 可以各自升级

这次没有动 `RemoteProtocolVersion`（仍是 1），新增的三样东西都是**向后兼容的加法**：

1. **状态字段**：`MacRemoteState` 增加 `brightness` / `volume` / `volumeMuted`，全部可选。
   - 新版手机连旧版 Mac：字段解不出来 → `nil` → 卡片不显示这条滑杆（并提示更新 Mac 端），不会点下去才失败。
   - 旧版手机连新版 Mac：`Codable` 默认忽略未知字段，旧的 1.0.0 收得到、不发这些命令，因此不会因为新字段解包失败。
   - 所以**不需要**在 `RemoteCapability` 里加枚举值：往 TXT/握手包里塞旧客户端不认识的 capability 字符串，反而会让旧客户端整个握手解码失败。用「值是否存在」表达能力，比用版号猜更稳。
2. **两条命令**：`setBrightness` / `setVolume`，载荷是 `RemoteLevelRequest`（`value` 归一化到 `0...1`，`muted` 可选），走已有的 `RemoteRequest.payload`。缺少或解不出的载荷一律以 `invalidMessage` 拒绝，绝不猜一个电平去动用户的设备。
3. **两个错误码**：`brightnessUnavailable` / `volumeUnavailable`，各自在手机上有明确文案。

### Mac 端

- 亮度走既有的 `DisplayServices` 驱动（`DisplayPower.brightness()` / `setBrightness()`），目标是**背光真的驱得动的那块屏**：内置屏优先，否则退到任何可驱动的显示器。哪个都没用时返回失败。
- 音量走 **CoreAudio**（`kAudioDevicePropertyVolumeScalar` / `kAudioDevicePropertyMute`），而不是 `osascript`：AppleScript 每次都要起进程还要 Automation 授权，而 CoreAudio 只是读系统本来就在用的那个输出设备的属性。设备只提供左右声道控制时，两边都写、读取时取平均。
- 滑杆拖动会把「调亮度」当成「我要看屏幕」：若此刻正黑屏，先解除黑屏再设新亮度（否则改了也看不见）。
- 拉高音量会顺带取消静音（和 Mac 自己的音量键一致），拖到 0 则不动静音状态。
- 读不到就报 `nil`/失败，不编造数值（沿用这个项目一贯的三态约定）。

### 手机端

- 拖动时滑杆用自己的草稿值：Mac 的应答要一个往返才回来，让远端值在拖动中途写回去会和手指打架。每次变化交给 model，由它做**合并节流**——同一时刻最多一个请求在飞，队列只保留最后那个值，抬手时再显式补发一次，保证最终落点是手指松开的位置（蓝牙链路下这点尤其重要）。
- 连接建立后立刻补一次 `getState`，回到前台时也补一次：这样 Mac 上用键盘改的音量/亮度不需要等到 15 秒保活才反映到手机上。
- 手机上没有这条滑杆时（对端上报不了）卡片会说明原因，而不是给一个按不动的控件。

### 验证

- `swift test` 全绿（新增协议编解码、旧版状态解码、缺载荷拒绝、`brightnessTarget` 选择、电平回环等用例）；`swift build -c release -Xswiftc -warnings-as-errors` 干净。
- 用真机探针跑通 CoreAudio 读写：`before volume=0.1875` → `setVolume(0.2575)` → `after=0.2574999` → 还原后 `osascript` 读回 19，与改动前一致。
- iOS App 模拟器与真机（`-sdk iphoneos`）两套构建都通过。

### 边界

- 亮度只对「背光可驱动」的屏幕直接生效：内置屏走 `DisplayServices`，外接屏走显示器自己的 DDC/CI（见下一节）。两条路都走不通（显示器不支持 DDC/CI，或走的是屏蔽 DDC 的 HDMI 转接）时状态里就没有亮度，手机不显示这条滑杆，卡片说明原因——这与 Mac 自己的亮度键在同样情况下的表现一致。
- 静音按钮只在输出设备真的有 mute 控制时出现。

### 动作组：加上「亮屏」，去掉重复的「解锁」

手机首页的四个动作现在是 **锁屏 / 黑屏 / 亮屏 / 唤醒解锁**，按意图分两行：上一行把 Mac 收起来（锁、黑），下一行把它叫回来（亮屏、唤醒解锁）。

- **「亮屏」用的是协议里早就存在的 `wakeDisplay`**（一直标注为「留给后续版本放到界面上，不需要动版号」），Mac 端无需改动：它会解除 MacPilot 自己压的背光/黑窗，显示器真睡着时用 `IOPMAssertionDeclareUserActivity` 唤醒，**不会解锁**——这正是「仅亮屏」与「唤醒解锁」的区别。
- **去掉了「解锁」按钮**：`MacScreenControlService.unlock` 在显示器睡着时本来就会先唤醒再解锁，且「已解锁」时报 `alreadyUnlocked` 错误，而 `wakeAndUnlock` 在已解锁时直接返回成功——两者实际是同一件事，后者还更宽容（多花一次 `getState` 判断，少一种错误路径）。
- 协议里的 `unlock` 命令**保留不动**：旧版手机（商店里的 1.0.0）仍会发它，删掉会让旧客户端整包解码失败。

## 三十二、外接显示器的 DDC/CI 亮度：让「黑屏」重新变成真黑屏

### 问题：黑屏变成了一层假黑

用户报告「黑屏之后屏幕上还留着一个鼠标，以前是真黑屏」。查证后他记得没错，是真实的行为回退：

- `e36c4e1` 时「关闭屏幕」用的是 `pmset displaysleepnow`，那是**真息屏**：面板熄灭、指针一起消失，但你的「锁定屏幕」设置是**「立即」**，所以息屏同时把会话锁了。
- `528467f` 为了解决「黑屏不该锁屏」改成：能驱背光的屏幕把背光压到 0（内置屏 = 真黑），驱不动的屏幕盖一层黑色遮罩窗口。会话因此不锁——代价是遮罩只是「面板显示黑色」，**背光还亮着**，而硬件指针由 WindowServer 画在所有窗口之上（连 `CGShieldingWindowLevel()` 也盖不住），于是黑屏上浮着一支箭头。

实测确认：本机合盖 + 外接 HP 24w 时 `DisplayServices` 读写返回 `rc=1000`（驱不动），所以只剩遮罩这条路；标准隐藏指针的手段（`CGDisplayHideCursor`、`SLSHideCursor`、`NSCursor.hide`）在这台机器上都返回成功但**指针依旧可见**（用 75 秒真机实验确认），所以「保留遮罩 + 隐藏指针」这条捷径走不通。

### 方案：让显示器把自己的背光关掉

外接屏的背光其实可以控制，只是不走 macOS，而是走显示器自己的 **DDC/CI**（MCCS 命令集，跑在 I2C 上）。把背光调到 0：面板真的不发光、指针自然看不见、显示器没有睡眠、会话也不会锁——这正是「真黑屏 + 不锁屏」。

- 新增 `Sources/MacPilot/ScreenControl/DDCBacklight.swift`。
- **包格式全部是纯函数**（`DDCPacket`），并以真机抓到的包作为测试夹具：读请求 `82 01 10 AC`、写 0 `84 03 10 00 00 A8`、写满 `84 03 10 00 64 CC`、回复 `6E 88 02 00 10 00 00 64 00 64 A4`。关键细节是**校验和要覆盖子地址 `0x51`**（只对数据字节求校验和的话，显示器会把包整个丢掉，症状和「不支持 DDC」一模一样）。
- `IOAVServiceCreateWithService` / `IOAVServiceReadI2C` / `IOAVServiceWriteI2C` 都是私有 IOKit 符号，和 `DisplayServices` 一样用 `dlopen`/`dlsym` 在运行时解析，App 不产生链接期依赖。
- **显示器与 `CGDirectDisplayID` 的对应关系靠读 EDID**：`DCPAVServiceProxy` 自身的祖先链到不了显示节点（实测），所以沿同一条 I2C 通道读 128 字节 EDID，用 product/serial 与 CoreGraphics 报告的 `CGDisplayModelNumber`/`CGDisplaySerialNumber` 比对；只有一个外接屏时退化为「就是它」。猜错会把别人的显示器调暗，所以这里不做启发式猜测。
- **写后必读回**：DDC 写是「发射后不管」，读回差值超过 1 就认为没生效，退回黑色遮罩，绝不上报一个其实还亮着的「黑屏」。
- `ScreenBlankPlanner` 的动作从两档变三档：`DisplayServices` 背光 → DDC 背光 → 黑色遮罩（最后手段，因为只有它会留下亮着的面板）。手机亮度滑杆的目标也按同样优先级挑选 `brightnessTarget`。
- 亮度滑杆在黑屏期间仍然上报**用户原来设的亮度**（而不是被压到的 0），松手后 `unblankDisplay()` 再把 DDC 亮度还原。
- **读回结果缓存 1 秒**，并对 I2C 访问加锁串行化：一次状态请求里「探测」和「读亮度」问的是同一件事，而一次通道解析 + 亮度读回约 70 ms。实测缓存后状态请求从 145 ms 降到 2 ms，写亮度从 279 ms 降到约 140 ms（其中 60 ms 是等显示器把新值落实后再读回，属于刻意保留）。

### 验证

- `swift test`：新增 8 个 `DDCPacketTests`（真机包夹具、校验和、越界钳位、忽略写入不得误判为已变黑、回复校验）与 4 个规划/目标选择用例。
- **真机探针（跑的是产品代码路径，不是临时脚本）**：
  - `DisplayPower.brightness()` → `1.0`（不再是 `nil`，所以手机端会出现亮度滑杆）；
  - `setBrightness(0.5)` → 读回 `0.5` → 还原 `1.0`；
  - `blankDisplay()` 期间直接读显示器自己的回答 → **`0.0`**（面板真的灭），而滑杆看到的仍是 `1.0`；
  - `unblankDisplay()` → 读回 `1.0`，与黑屏前一致。
- 直接 I2C 探针另测：写 0 → 读回 0；写 100 → 读回 100（无钳位）。

### 边界

- 显示器/连接必须支持 DDC/CI：DisplayPort 基本都行，HDMI（尤其经转接）常被屏蔽。不支持时行为与改动前完全一致（黑色遮罩），只是仍然会有那支指针。
- 同一时刻只能有一个进程占用 I2C：第三方 DDC 工具高频轮询时，读写可能失败；失败会退回遮罩，不会谎报黑屏。
- 外接屏亮度是**显示器自己的**控制，与系统「显示器」面板里的亮度滑杆不是同一个东西（后者对外接屏本来就不提供）。

## 三十三、锁屏态黑屏与解锁输密码防泄漏（v1.1.332）

真机测试暴露的两个屏幕控制问题，同属 `ScreenControl` 一条链路。

### 问题一：锁屏后再点「黑屏」没有反应

手机先点「锁屏」，再点「黑屏」毫无效果。原因：「黑屏」走 `DisplayPower.turnOffScreen()`（背光压零 / DDC / 黑色遮罩），这三样都以「解锁会话在前台」为前提——黑色遮罩是用户会话的 NSWindow，画不到 loginwindow 之上，背光 seam 在锁屏态也不再可靠。

修复：新增纯决策 `DisplayOffApproach.forScreen(locked:)`——锁屏态改用系统自己的「锁屏黑屏方式」，即真实显示器睡眠（`pmset displaysleepnow`，`DisplayPower.sleepDisplay()`），并等 `CGDisplayIsAsleep` 确认后才报成功。真实睡眠在锁屏态是无害的：会话本来就锁着，「显示器关闭后要求密码」策略已无事可做。解锁桌面保持原行为（遮罩式黑屏，绝不真睡眠）。

### 问题二：解锁竞态把锁屏密码打进用户会话的输入框

用户解锁快于 MacPilot 打字（Touch ID / 手表 / 手输密码）时，会话带着锁屏前的输入焦点回来，此时还在重试循环里的键击会落进用户留下的输入框——实测把整条密码「发送」进了聊天输入框。旧实现的三个缺口：远程路径在会话状态 unknown 时也照打；整条密码加回车一次性批量发出，中途不复查；密码字段是否就绪全凭时序。

修复（`ScreenUnlockExecutor`，BLE 与远程共用）：

- 新增纯决策 `PasswordTypingGate.command(locked:secureFieldFocused:)`：只有「会话确认锁定 + 密码框持有 secure event input（`IsSecureEventInputEnabled()`，锁屏密码框聚焦时才置位，普通文本框不会）」才允许输入；锁定但字段未弹出时先 Escape 唤出（有时限）；未锁定一律 `.abort`。
- 输入改小段（4 个 UTF-16 单元/段），清屏（⌘A/Delete）、每段、回车之前全部重新过门；中途发现会话解锁立即中止并记日志（`stage=… reason=sessionNoLongerLocked`）。竞态窗口从「整条密码」缩到「4 字符 × 毫秒级」。
- 中途只有「不再锁定」才中止：锁屏 UI 在唤醒服务稳定期间可能短暂丢掉 secure input，此时键击仍归 loginwindow 所有，若因此中止反而会留下半截密码（下次尝试会先清空字段）。

### 验证

- 新增 `ScreenControlSafetyTests`（5 例：黑屏方式决策、密码门全表、中途中止规则、解锁态即使有安全字段也中止）；`swift test` 589 例全过。
- 真机待验证：锁屏后手机点「黑屏」应看到屏幕熄灭且状态报 displaySleeping；锁屏后立即手动 Touch ID 解锁，诊断日志应出现 `password typing aborted`，聊天框不应出现密码。

## 三十四、黑屏崩溃恢复：亮度快照落盘（v1.1.333）

「黑屏」的省电本质是把每块屏的背光真压到 0（内建走 `DisplayServices`、外接走 DDC/CI，遮罩只是兜底），原始亮度只存在内存字典里。这带来一个唯一的"卡黑屏"场景：**黑屏期间进程被强杀或崩溃**，恢复用的原始亮度随之丢失，面板停在 0，用户只能自己摸亮度键。

修复：黑屏成功时把捕获到的原始亮度**原子落盘**到 `Application Support/MacPilot/DisplayBlankRecovery.json`（`DisplayBlankSnapshot`，按显示器 ID 分键，遮罩态没有背光状态可丢、不落盘）；`unblankDisplay()` 全部还原之后才删文件。下次启动 `MacPilotApp.init()` 最先执行 `DisplayBlankRecovery.recover`：

- **逐屏先读后写**：读回仍是 0 才恢复（用户已经自己调亮的屏绝不覆盖回去）；读不到（显示器已断开）直接跳过；
- **写失败不清档**：锁屏态等场景可能拒写，被拒的条目留在快照里等下次启动重试；只有全部写成功（DDC 路径 `setLevel` 自带写后读回确认）才清文件；
- **中途崩溃幂等**：恢复到一半再崩，文件还在，下次启动重跑——已还原的屏读回非 0 会被 `alreadyRepaired` 跳过，天然幂等。

`DisplayBlankRecovery.Appliers` 把两套背光驱动做成注入缝，测试用假驱动完整跑通恢复流程；新增 5 个用例（快照往返、清档、决策表、只恢复仍黑的屏、被拒写入留档），`swift test` 594 例全过。真机验证方法：黑屏状态下强退 MacPilot，重开应用后面板亮度应自动回到黑屏前的值。

## 三十五、截图后自动保存到本地：把「一定落盘」变成可选（v1.1.334）

截图此前是"一定落盘"：每次截图都会按保存文件夹、格式与质量写入本地文件，并计入截图历史与磁盘占用，用户没法选择只把这次截图放进剪贴板、快捷操作或贴图。截图页「智能截图」卡片新增勾选项**「截图后自动保存到本地」**（`screenCapture.saveAfterCapture`，`decodeIfPresent ?? true`，旧 config.json 升级后行为不变）：

- **开启（默认）**：与之前完全一致——写入保存文件夹、记录截图历史、累计磁盘占用与截屏次数，再按剪贴板/快捷操作/贴图设置分发。
- **关闭**：不写保存文件夹、不记历史与统计；截图只按需要在 `Application Support/MacPilot/Captures/` 留一份**临时文件**给剪贴板、快捷操作与贴图用（三者都不需要时连临时文件都不生成）。关闭时连保存配置都不准备，因此不会像以前那样顺手创建空的 `MacPilot Screenshots` 目录。
- 标注编辑器双击画布那条"复制并保存"快捷路径同样遵守该开关：关闭后只复制到剪贴板，不再落盘。

实现上 `handleCapturedImage`（改为 `internal` 以便测试）按开关把保存配置取成 `nil`，持久化结果新增 `skippedAutoSave` 区分"保存失败"与"用户主动关闭"两种 `nil`：前者沿用原有的错误提示与兜底，后者走 `finishSkippedAutoSave` 只做剪贴板/快捷操作/贴图收尾。

新增 4 个用例：默认开启、旧配置（无该键）解码仍开启、模型 setter 持久化、关闭后双击快速复制不产生文件与统计，以及关闭自动保存的截图不落在保存文件夹；`swift test` 全过。

## 三十六、Dock 分组：把多个 App 收进一个固定到原生 Dock 的 Helper（v1.1.335）

目标不是再画一个 Dock，而是让用户把若干 App 归到一个**由 MacPilot 自己生成的轻量 Helper App** 上，把它拖进 macOS 原生 Dock；点这个图标弹出二级浮层列出组内 App。

### 红线：第三方 App 全程只读

需求里最硬的一条是"MacPilot 永远不得修改被管理的第三方 App"。这不是靠自觉，而是靠代码结构：

- `TargetAppAccessPolicy` 把权限拆成 `read/write/modify/replace/sign/patch/inject/launch/activate`，只有 `read/launch/activate` 对第三方 App 放行；任何写意图先过 `decide(_:for:managedRoot:)`，落在 MacPilot 自己目录里才算 `allowedManagedArtifact`。
- `ManagedPathGuard.requireManaged(_:root:)` 拒绝符号链接，也拒绝把 `/`、用户主目录、`/Applications`、`/Library` 这类宽目录当作管理根，防止"校验通过但删错东西"。
- 拖入 `.app` 只存引用（`bundleIdentifier` 优先、`path` 兜底），读取范围限于 Bundle URL / Bundle ID / 名称 / 版本 / 图标 / 可执行文件路径 / 运行状态；启动走公开的 `NSWorkspace.openApplication`，已运行则 `activate(from:options:)`，`createsNewApplicationInstance = false` 保证不会起第二个实例。
- §14 明确"第一版不许改写 `com.apple.dock.plist`"，所以只做"在访达中显示 + 拖拽引导"，绝不重建 `persistent-apps`。
- 隐藏运行中的第三方 Dock 图标（§18/§20）**故意不做**：那必然要打补丁、注入或重签，属于明令禁止的手段；`NSRunningApplication.hide()` 也绝不用来"消 Dock 图标"。

### 结构

- `Sources/MacPilotDockGroupsCore/`：主程序写配置、Helper 读配置、测试校验完整性，三方共用同一份模型（SwiftPM 里 executable target 不能互相 import，所以核心必须抽成 library）。
- `Sources/MacPilotDockHelper/`：独立可执行文件，每个分组生成一个 `.app` 复用它，只靠 `Bundle.main.bundleIdentifier` 里的 Group ID 区分。
- `Sources/MacPilot/DockGroups/`：设置页、编辑器、App 选择器、Helper 管理器。`Package.swift` 与 `Scripts/build-app.sh` 相应新增 target 与嵌入逻辑。

### 两个必须记住的坑

1. **生成出来的 `<Group>.app` 必须再签一次。** 在 bundle 内部执行 `codesign --force --sign - <binary>` 时，签名标识符取自**所在 bundle** 的 `CFBundleIdentifier`（`--identifier` 在 ad-hoc 分支实测被忽略），而生成物用的是 `com.misswell.macpilot.dockgroup.<id>`。只拷二进制会让"签名里的标识符"和"Info.plist 里的 Bundle ID"对不上，`codesign --verify` 直接报 `invalid Info.plist`。解法是内容写完之后对我们**自己的**产物跑一次 `codesign --force --sign - <app>`（只调 Apple 自带的 `/usr/bin/codesign`，不经过 shell，目标路径已过 `ManagedPathGuard`），验证结果从 `invalid` 变成 `valid on disk / satisfies its Designated Requirement`。
2. **"复用同一个 binary"不能用整文件哈希断言。** 因为上面那一步重签，拷出来的可执行文件尾部签名数据必然变化。测试改成断言更有意义的不变量：生成 Helper 的整个过程里，**MacPilot 自己随包的那个 Helper binary 零修改**（与第三方 App 用同一套 `ThirdPartyAppIntegrity` 度量，`differences(from:)` 必须为空）。

### 配置与数据

- `config.json` 只放开关与两个偏好（`dockGroups`，`version` 升到 24，`decodeIfPresent` 兜底，旧配置升级后行为不变）；`~/Library/Application Support/MacPilot/DockGroups/groups.json` 是分组的唯一权威来源，Helper 只读它。
- 自定义图片拷进 `DockGroups/Icons/`，原图保持只读；App 图标另存一份 PNG 缩略图到 `~/Library/Caches/MacPilot/DockGroups/`，缓存键是「Bundle ID + 版本 + 尺寸」，删掉缓存只影响首屏速度。
- 时间戳统一取**秒级精度**再按 ISO8601 落盘：ISO8601 没有小数位，若不先把 `Date` 归整，"保存 → 读取"会因为微秒丢失而不相等，测试里的整体比较就永远过不去。
- 删分组/删 Helper 有两道保险：路径必须在管理目录内，且目标 `Info.plist` 的 `CFBundleIdentifier` 必须能被 `DockGroupIdentifier.groupID(fromHelperBundleIdentifier:)` 解析出 Group ID；两条不满足就原样保留（宁可留残留也不误删）。

### 图标缓存与清理（补齐 §12、§26）

- **图标缓存**：`DockGroupIconCache` 只把 `NSImage` 编码成 PNG 写进 `~/Library/Caches/MacPilot/DockGroups/`，写入前过一次 `ManagedPathGuard`；缓存键带 App 版本，所以升级换图标会自动失效。写失败一律忽略 —— 缓存只是加速，绝不能因为它失败就显示不出图标。
- **清理入口**：页面上的「清理分组数据」调用 `removeAllGroupData()`，只删 MacPilot 自己的 Helper App、`groups.json`、`Icons/` 与图标缓存。返回值是「是否已无残留」：管理目录里若混进了归属不明的 `.app`，它会如实返回 `false` 而不是谎报清空。
- 三处清理 API（`removeGroupsFile` / `removeCustomIcons` / `DockGroupIconCache.removeAll`）都把**路径校验放在「文件是否存在」之前**。原先先判断存在性再校验，管理根目录配错成 `/Applications` 时会因为"本来就没东西可删"而返回成功，把配置错误掩盖掉。

### 三个只有真机才暴露的坑

1. **夹具不能借用真实 App 的 Bundle ID。** 测试里原本用 `dev.zed.Zed`、`com.apple.dt.Xcode` 当夹具 ID，而本机真的装着 Zed 和 Xcode，于是 `NSWorkspace.urlForApplication(withBundleIdentifier:)` 直接解析到**真实应用**，测试看着通过、实际上没测到夹具（连"版本从 1.0 升到 1.1"都被真实 Zed 的 1.16.2 顶掉了）。现在夹具统一加唯一后缀。
2. **`Bundle` 的 Info.plist 缓存会让"App 原地升级"看不见。** `Bundle.object(forInfoDictionaryKey:)` 在进程内缓存，第三方 App 原地升级后同一次运行里读到的还是旧版本号，连带图标缓存键也失效不了。改成 `InstalledAppResolver.freshVersion(of:)` 每次直接解析 `Contents/Info.plist`（只读），B 案才是「升级后立刻看到新版本/新图标」。
3. **"App 被移动后仍能找到"靠的是 LaunchServices，不是 MacPilot。** §6 说"优先 bundleIdentifier、path 只是兜底"，真正的语义是：Finder 挪动 App 时系统会更新登记信息，而 MacPilot 只是重新查询。用 `FileManager.moveItem` 搬走夹具并不会更新登记，所以那条断言原来是不成立的；现在改成用一个真实安装的 App + 一个故意失效的旧路径来验证优先级，另加一个"两边都找不到时安静报未找到"的用例。

### 浮层细节

`.accessory` 激活策略 + `.borderless` 面板：无标题栏、无普通 Window Chrome、不产生第二个 Dock 图标；ESC（keyCode 53 + `cancelOperation`）与 `didResignKey` 关窗，另加 mouseDown 级全局监听兜底"点击外部关闭"（鼠标全局监听不需要任何隐私授权）；关闭即 `NSApp.terminate`，浮层关掉之后不留后台进程。网格/列表两种布局、绿点表示运行中、方向键移动焦点、深色模式与 Retina 都覆盖。原先把启动失败提示塞进内容区会把预先算好的面板高度撑破，改成占用页脚的提示位。

### 验证

- 完整性快照（§30）逐项覆盖：Bundle 目录元数据与顶层条目、主可执行文件 SHA-256、Info.plist SHA-256、代码签名身份（identifier / team / cdHash / 是否有效 / Hardened Runtime）、**Entitlements**。Entitlements 用「键=值」的排序字符串拍平，避免字典比较的不确定性；`differences(from:)` 会报出具体是哪个字段变了。
- `ThirdPartyAppIntegrityTest` 在"创建分组 → 解析/查运行状态 → 生成 Helper → 改名换图标改布局 → 清理全部数据"前后做整体快照比较，必须 `before == after`。
- **§29 点名的应用清单现在真的被测到**：`installedThirdPartyAppSurvivesTheWholeDockGroupLifecycle` 对 VS Code / Zed / Xcode / IntelliJ IDEA / Chrome / Safari / ChatGPT / Claude / OrbStack / DBeaver 逐个跑完整生命周期（装了就测，没装跳过；本机覆盖其中 8 个），只读快照、**不启动**这些真实应用以免打断用户。
- 真实启动路径用仿真 App 覆盖：`launchingAnAppThroughTheWorkspaceDoesNotTouchItsBundle` 通过公开的 `NSWorkspace` API 连启两次（第二次走激活分支），Bundle 零变化。
- §29 的其余状态各有对应用例：App 原地升级、path 失效仍按 Bundle ID 命中、Helper 被用户删掉后不崩且能重新生成、MacPilot 重启后从 `groups.json` 恢复、多个分组共享同一个 App 且可独立删除、配置损坏、App 删除、关闭状态下管理目录必须保持为空。
- `swift test` 646 例全过（`--no-parallel` 下稳定全绿；并行跑时偶发的失败集中在既有的 `ScreenCaptureTests` / `ClosedLidSleepTests` 计时用例上，与本功能无关）。
- release 构建（`-warnings-as-errors`）通过；`Scripts/build-app.sh` 产出的 `MacPilot.app` 里 `MacPilotPowerHelper`、`MacPilotUpdater`、`MacPilotDockHelper`、`FinderSync.appex` 都在 `codesign --verify --deep --strict` 下 prepared/validated 通过，Dock Helper 带 hardened runtime 与 Developer ID，标识符为 `com.misswell.macpilot.dock-helper`。
- 端到端手测：把打包出来的 Helper binary 按生成流程拷进 `Dev.app`、ad-hoc 重签后 `codesign --verify` 通过，用 `MACPILOT_DOCK_GROUPS_ROOT` 指向临时 `groups.json` 启动，浮层正常弹出、进程存活、无 stderr 输出；发布出去的公证 ZIP 解包后 `Contents/MacOS/MacPilotDockHelper` 在位，`codesign --verify --deep --strict` 与 `spctl --assess` 均通过。

### 环境备注

本机 `xcrun clang` 链接遮挡补丁 dylib 时会因为 `/Library/Developer/CommandLineTools/SDKs` 里那套 macOS 27 SDK 的 `.tbd`（含 `arm64e.x1` 架构）报 `tapi error: malformed file`，`Scripts/build-app.sh` 因此走不到打包步骤。这与本功能无关（失败的是没动过的 `MacPilotOcclusionPatch.m`），临时把 `SDKROOT` 指向 Xcode 的 `MacOSX26.5.sdk` 即可绕过；没有修改任何构建配置。

## 三十四、外接屏「真黑屏」：用显示器自己的电源开关（v1.1.342）

### 问题：DDC 亮度 0 只是「很暗」

用户反馈手机点「黑屏」后屏幕只是变暗、并没有变黑。真机读回给出解释：这台 HP 24w 接受 DDC 亮度写 0 并且读回也是 0，但**它的 0 档是一个很暗的低亮度，不是关背光**——很多廉价显示器都有这个下限。所以「写亮度 0」这条路对它们永远只能得到「暗」。

关键发现：**显示器的 DDC 电源模式（MCCS `0xD6`）可写**。真机实测：

- 写 `0xD6 = 4`（DPMS soft off）→ 读回 4，面板真的熄灭（用户肉眼确认：内容没了、鼠标指针也看不见）；写 `2`（standby）被显示器直接忽略（读回 1），所以用 4。
- **macOS 不认为显示器睡了**（全程 `CGDisplayIsAsleep == 0`）→ 不触发「显示器关闭后要求密码」策略，会话不锁 ✓ 这正是「黑屏但不锁屏」要的性质。
- 熄灭期间**显示器仍然应答 DDC**（这是它可逆的前提）；反过来「开机」后约 1 秒内 DDC 会不应答，所以点亮必须重试而不能一读定成败。

### 实现

- `DDCPacket` 增加 `powerMode = 0xD6`、`powerOn = 0x01`、`powerOff = 0x04`；`DDCBacklight` 增加 `powerMode(_:)` 与 `setPowerMode(_:for:)`（写后读回确认，熄灭方向 5×200 ms、点亮方向 8×300 ms；被忽略的显示器记 60 秒，期间直接走下一档机制）。
- `DisplayPower.blankDisplay()` 的外接屏档位变成三级：**DDC 电源关闭 → DDC 亮度 0 → 黑色遮罩**（最后手段，因为只有它会留下亮着的面板）；`isBlanked`/`unblankDisplay()` 增加电源恢复（点亮优先，因为点亮前对它写亮度也落不下去）。
- 崩溃恢复同步扩展：`DisplayBlankSnapshot` 增加 `ddcPowerOff`（**可选字段**，否则旧快照会解码失败，那会把里面的面板永远留在暗处），`DisplayBlankRecovery` 用 `powerDecision(current:)` 判断「还是我关的（4）就点亮，已经亮了就不碰」。
- 修掉一个自己引入的缓存缺陷：读回缓存改成**按控制器分别记忆**。之前只按显示器缓存，导致先问 `0xD6` 之后再问 `0x10` 会拿到 nil（被误判成「显示器不应答」）——真机探针当场复现：黑屏退回遮罩、电源模式仍是 1。

### 验证

- `swift test`：DDC 包/恢复相关 30 例全绿（含电源包校验和、旧快照兼容、仅点亮仍处于关机的显示器、被拒写入继续排队等用例）。
- 产品代码路径真机探针：`before power=1 level=0.71` → `blankDisplay()` → **`power=4`**（且滑杆仍报 0.71，不跳 0）→ `unblankDisplay()` → `power=1 level=0.71`，`isBlanked=false`。

### 「亮屏」的语义（本次确认，未改行为）

- 黑屏过（MacPilot 自己压黑的）→ `wakeDisplay` 先解除黑屏：外接屏点亮、内置屏恢复亮度，**不解锁**。
- 锁屏态（显示器被系统/`黑屏` 真睡眠）→ 只把显示器唤醒到**锁屏界面**，同样不解锁；要解锁是另一个动作「唤醒解锁」。
- 注意：人在 Mac 旁边时，BLE 就近解锁也可能会把锁屏解掉——那不是「亮屏」干的。

## 三十七、Dock 分组：设置页布局与深色图标（v1.1.344）

### 页面布局

- 改前：页头下面直接是一行**右对齐**的按钮（左边空着），再一行偏好，看不出哪行是「设置」哪行是「操作」。
- 改后：两个偏好进 `SettingsCard`（标题「分组设置」）；列表上方改成「分组」小节标题 + `n 个分组 · m 个应用` 统计，四个操作按钮挂在这一行右侧——与内存监控页的小节行一致。
- **详情页不要再加功能总开关**。`3d25c41` 把 11 个详情页的总开关全部移除，改成「首页开关同时控制功能入口与后台运行」。我第一版按老结构又加了「启用 Dock 分组」，与那次重构直接冲突，已改成卡片里只放偏好。

### 深色模式

- 渲染器原先有三处硬编码浅色底（合成图标 / Emoji / 自定义图片），描边固定黑色 10% 透明——在深色界面上就是一块刺眼的白。
- 现在由 `DockGroupIconAppearance` 决定一整套 Palette：深色底 `0.24 → 0.15` 渐变、描边换成白色 18%、强调色降饱和（0.62 → 0.52）降亮度（0.86 → 0.66，**色相不动**，同一个分组在两种外观下仍是同一种颜色）。
- 视图侧显式传 SwiftUI 的 `colorScheme`，而不是让渲染器自己去读 `NSApp.effectiveAppearance`：视图重绘的时机和 App 外观不一定同步。

### 三个坑

1. **`drawEmoji` 没设 `.foregroundColor`**。`NSAttributedString` 不带前景色时 AppKit 按**黑色**绘制，深色底上的兜底符号与文字直接看不见。Emoji 是彩色字形不受影响，所以只在「符号缺失 → 文字兜底」这条路径上暴露。
2. **图标缓存键必须带外观**。`DockGroupsModel` 原先按 `group@size` 记忆，切到深色模式会原样返回上一次渲染的浅色图；外观已并进 cacheKey。
3. **默认参数撞上主 actor 隔离**。`current(_ appearance: NSAppearance? = NSApp?.effectiveAppearance)` 里的 `NSApp` 是主 actor 隔离的，非隔离函数用它会报 `main actor-isolated default value in a nonisolated context`；拆成 `@MainActor current()` + 非隔离 `current(_:)` 即可。

### 边界

- 写进 Helper `.app` 的 `.icns` **仍然是浅色版本**：`.icns` 没有外观变体，Dock 里第三方 App 的图标本来也不随系统外观变化，而按「生成那一刻的外观」出图会在用户之后切换外观时变得不一致。这个取舍写进了 README。

### 验证

- 像素级用例：深色版底色亮度 < 1.2、浅色版 > 2.0（三通道之和）；符号图标深色版更暗且色相不变；模型缓存对两种外观返回不同对象且各自命中。
- 真机：把 `MACPILOT_DOCK_GROUPS_ROOT` 指向临时 `groups.json`、用 `open -a` 启动 Helper（直接跑二进制会因为抢不到 key window 被「失去 key 即关闭」收掉，走 LaunchServices 才是真实路径），截图确认深色浮层 + 深色分组图标 + 绿点运行状态。
- 截图本身的两个坑：桌面被别的窗口压住时，`screencapture -l <windowID>` 可以直接抓被遮挡的窗口（窗口号用 `CGWindowListCopyWindowInfo` 取）；另外本机同时装着一份同 Bundle ID 的构建，`open macpilot://…` 会一直被路由到**已安装**的那份，必须写成 `open -a <自己那份>.app "macpilot://…"` 才送得到指定构建。

## 三十八、浮层页头改成「标题 + 齿轮」（v1.1.345）

- 页头不再画分组图标：点开的就是这个分组，图标在这里没有信息量。现在只有标题，紧跟一个 12pt 齿轮。
- 设置从页脚挪到标题旁（保留 `⌘,` 快捷键），页脚只剩「点击图标打开或切换到应用」这行提示，不再和「设置…」挤在一行。
- 顺带删掉页头里为图标准备的 `colorScheme` 环境变量——浮层不再画分组图标，深浅外观对浮层已经无事可做（浅色/深色切换仍由 `.regularMaterial` 自适应）。

### 验证方式（值得留给下次）

- 屏幕锁定时**浮层的窗口根本不会被合成**：`CGWindowListCopyWindowInfo` 里查不到，`screencapture` 全是黑的，进程却还活着——别误判成「浮层没弹出来」。
- 于是临时给 `main.swift` 加了一个 `MACPILOT_DOCK_HELPER_SNAPSHOT` 环境变量，用 `ImageRenderer` 把 `DockHelperView` 离屏渲染成 PNG（验证完立刻还原，未提交）。这招能拿到页头/页脚的布局，但**受限于离屏渲染**：`Button` 里的 SF Symbol 在锁屏环境会渲染成「缺图」黄色占位符（同一个 `Image(systemName:)` 不在 Button 里就正常，纯文字 Button 也正常）。真实窗口里这个组合是正常的——早前非锁屏时的真机截图里，`Label(_, systemImage:)` 按钮图形都正确，别把这个占位符当成 bug。

## 三十九、浮层去掉页脚那行提示与分隔线（v1.1.346）

- 页脚原本固定占一行：一句「点击图标打开或切换到应用」加一条分隔线。用户看下来是纯噪声，整行连同分隔线一起去掉，列表下面直接就是浮层底边。
- `DockHelperLayout` 的 `footerHeight` 与那一段 `sectionSpacing` 一并从 `size(for:)` 里去掉，浮层高度少 38pt（9 个应用的网格：358 → 320）。**关键是尺寸与视图必须一起改**：只删视图不改尺寸会在底部留一条空白带，只改尺寸不删视图会把最后一行压扁。
- 页脚还兼着「启动失败 / 应用未找到」的提示位，不能跟着一起删。现在这条提示占用**标题右侧的空白**（橙色 + 感叹号，超长中间截断），既不新增行高也不需要动态改窗口尺寸——原来那行页脚的注释专门说过「尺寸预先算好，不会被撑高或裁切」，现在这个约束更简单了：根本不需要额外高度。
- `dockGroupStrings` 里的 `hint` 键随之删除（中英各一条），避免留下永不显示的文案。

### 验证

离屏渲染这次终于可信了（屏幕已解锁），9 个应用的真实分组渲染出来：页头 `集合 + 齿轮`、无页脚、无分隔线、深色/浅色两套都正确。踩到的坑记一下：

- **离屏渲染的代码必须放在 `NSApplication.shared` 之后**：一开始插在文件顶部，`DockHelperModel` 一碰 AppKit 就 `Segmentation fault: 11`，而且连提前写的日志都没输出——看着像业务崩溃，其实是「App 还没建出来」。
- 浮层窗口在**抢不到 key window** 时会按设计立刻关闭，所以用脚本 `open -n` 拉起后往往抓不到窗口（用户此刻正在别的 App 里操作）。`CGWindowListCopyWindowInfo` 找不到窗口时先分辨是「没弹出来」还是「已经被焦点策略关掉」。
- 屏幕锁定时窗口根本不会被合成（截图全黑）；解锁后再渲染才拿到正常结果。

## 四十、Dock 分组：点开即现 + 贴着图标出现（v1.1.346 之后）

用户报的两个问题：点 Dock 图标要等 2 秒浮层才出来；浮层跟着鼠标位置出现，而不是贴着 Dock 图标。

### 先量，再改

拿真机把整条路径拆开量（本轮所有数字都在同一台机器上）：

- 直接 `spawn` Helper 二进制：135–290 ms 窗口上屏；
- 用辅助功能 `AXPress` 点 Dock 图标（等价真实点击）：230–270 ms；
- 真机**鼠标点击** Dock 图标：鼠标抬起后 214 ms 面板上屏；
- 面板已经开着时再点一次：1–6 ms（LaunchServices 走 reopen，不再起进程）。

所以「2 秒」不在解析里（9 个 App 的解析实测 7 ms、图标 60 ms 上下），而在**冷进程那条路径**：LaunchServices + 进程启动本身就占掉了大头，机器忙或图标服务冷启动时会成倍放大。结论是**别每次都付这个钱**，同时把「首次冷启动」里能挪走的都挪到面板上屏之后。

### 改了什么

1. **面板先上屏、内容后到**。`DockHelperModel` 拆成 `loadConfiguration()`（只读 `groups.json`，毫秒级，面板尺寸只取决于它）与 `loadContent()`（解析版本 / 运行状态 + 渲染图标）。`show()` 建完面板立刻 `makeKeyAndOrderFront`，内容在**已经上屏之后**才补，每画一张图标 `await Task.yield()` 一次。图标没到位的格子画中性占位方块（不是「应用未找到」的黄色问号）。
2. **进程留在原地待命**。浮层关掉只 `orderOut`，不 `NSApp.terminate`；`applicationShouldHandleReopen` 与 `applicationDidBecomeActive` 两条路径都指向同一个 `show()`（重复调用幂等）。待命 5 分钟后自退，Info.plist 另外加上 `NSSupportsAutomaticTermination` / `NSSupportsSuddenTermination`，让系统在内存吃紧时提前回收——「不留后台进程」的约束仍在，只是有了上限。
   * 顺带修掉一个隐藏很久的问题：Helper 的 Info.plist 一直没有 `NSSupportsAutomaticTermination`，所以原来那套 `disable/enableAutomaticTermination` 其实是空转。
   * 待命期间 Dock 图标**不会**多出运行小圆点（accessory 策略，真机截图对比过，前后像素完全一致）。
3. **图标与轮询不再重复干活**。图标结果进内存缓存（`Entry.icon` + 版本键），不再在每次 SwiftUI body 求值时重画（原先一次展开要重画 3 遍，27 次取图）；2 秒一次的轮询只改 `isRunning`，不再重新解析整个分组，而且**真的变了才写回** `@Published`（`@Published` 不看内容是否相等，无脑赋值会让浮层每 2 秒白重绘一次）。
4. **落点贴着 Dock 图标**。新增纯函数 `DockHelperPanelPlacement`（在 Core 里，便于测试）：Dock 贴哪一边由「可见区域往哪边内缩」判断（自动隐藏时退化成「鼠标离哪条边最近」）；沿 Dock 方向用点击那一刻的鼠标坐标把浮层居中到图标上，垂直于 Dock 的方向**完全不看鼠标**，永远紧贴 Dock 内侧 10pt。左 / 下 / 右三种 Dock 都覆盖，最后再夹进可见区域。
   * 为什么不用 Dock 图标的精确 AX frame：Helper 进程 `AXIsProcessTrusted()` 实测为 **false**（它是 ad-hoc 重签的另一个 bundle），拿不到 Dock 的 AX 树；为了这个去要一次辅助功能授权不值得。点击那一刻鼠标必然在图标上，沿 Dock 轴取鼠标坐标就是这个图标的位置。
5. **App 升级后 Helper 会自己重做**。`ensureHelpersExistIfNeeded` 原来只补「缺失」的 Helper，于是 App 升级后 Dock 上跑的一直是**旧 binary**（本机实测：App 1.1.345、Helper 还停在 1.1.344，连浮层页脚都还是老布局）。现在改成按 Helper Info.plist 里的版本号 / build 判断，不一致就重新生成。

### 验证

- 真机鼠标点击 Dock 图标（`CGWarpMouseCursorPosition` + `CGEvent`，辅助功能已授权）：冷启动 214 ms（换过二进制后第一次还会到 498 ms——文件缓存和图标服务都是冷的）；关掉之后再点是 **22 / 49 / 55 ms**，而且 pid 不变（面板本来就开着时再点只要 10–16 ms）。面板 cocoa 落点横坐标恒为 `可见区左边缘 + 10`，纵坐标正对图标中心（1080p 左边 Dock：图标中心 y=216、浮层高 320 → 落点 y=56）。
- 那 20–50 ms 里有一大半是 Dock 自己的点击处理与抬起后的派发，不是 Helper 的活，别再拿「比 10 ms 慢」当回归。
- 「点外部关闭」用**中键**点 Dock 上方空白区来做最干净：全局监听同样收得到（事件是送给别的 App 的），又不会激活任何 App、不会弹菜单。左键点菜单栏/桌面会把焦点交给 Dock/Finder，测出来的就不是热展开那条路径了。
- 关掉浮层后 `pgrep` 确认 Helper 进程仍在，再点图标直接复用同一个 pid。
- 截图确认 3×3 图标 + 名称 + 绿点正常，浮层无页脚（320pt）。
- 单元测试：新增 `DockHelperPanelPlacementTests`（左/下/右/自动隐藏、垂直轴不看鼠标、贴边夹取、超大浮层不越出屏幕）；`DockGroupsIntegrityTests` 补两条 Helper Info.plist 断言。三个 Dock 分组套件 45 项全过。全量 `swift test` 里 `ScreenCaptureTests.startupShortcutRegistrationRetriesTransientFailure` 与 `ClosedLidSleepControllerTests.heartbeatFailureTriggersABoundedReconnect` 会因为并行负载偶发失败（单独跑必过），与本次改动无关。
- 量完把用户机器上那份 Helper 恢复原状（本轮只借它做真机测试，正式生效走 App 重新生成）。

### 踩坑

- **别用 `open -b` 或 `AXPress` 量落点**：这两条路径都不会移动鼠标，`NSEvent.mouseLocation` 还停在用户上次放鼠标的地方，于是浮层会出现在鼠标那里——看着像「落点算错了」，其实是「点击位置不是图标」。要么用真鼠标点击，要么先把鼠标 warp 到图标中心。
- 想确认「面板是否真的出现」，`CGWindowListCopyWindowInfo` 只说明窗口被 order 到屏幕上，不说明内容画完了；要判断「有没有白屏两秒」得看窗口内是不是已经成型（截图或计时日志）。
- `NSApp.hide(nil)` 要放在 `dismiss()` 里：没有窗口的 accessory App 不该继续占着最前面，否则 ESC 关掉浮层后焦点会停在一个什么都没有的 App 上。

## 四十一、贴图只留一套：把「直接贴图」并回快捷操作贴图窗口

截图链路上长期存在两套贴图窗口，用户点不同入口会得到两种完全不同的贴图：

- **直接贴图**：`SmartScreenshot.swift` 里的 `SmartPinWindowController` / `SmartTextPinWindowController`。入口是框选工具栏的贴图（⌘T）、剪贴板贴图快捷键（F3）和「截图后自动贴图」。行为是贴回框选原位、双击复制、右键菜单（复制 / OCR / 标注 / 上传），还支持剪贴板文字贴图与双击 ESC 关闭全部贴图。
- **快捷操作卡片贴图**：从 Snapzy 迁移的 `QuickAccessPinWindowManager` / `QuickAccessPinWindow`。入口是快速操作卡片右下角的 pin 按钮，行为是缩放（滚轮 / 捏合 / 百分比菜单）、锁定穿透、拖拽手柄。

同一件事在两条入口长得不一样，用户没法预期点下去得到哪一种。这次统一到后者，并把前者的能力补进去。

### 改了什么

1. **一套窗口状态**。`QuickAccessPinWindowState` 从「图片 + 文件 URL」扩展成「图片或文字」二选一：文字贴图没有栅格可缩放，于是 `supportsZoom` 为 false，顶部缩放菜单和底部拖拽手柄自动隐藏；文字底尺寸由 `QuickAccessPinTextMetrics` 量出，顶部额外留 40pt 的 chrome 带，保证关闭/锁定按钮不会压住第一行字。
2. **能力取并集**。右键菜单（复制 / OCR / 标注 / 上传 / 关闭）和双击复制放在 `QuickAccessPinHostingView`（`NSHostingView` 子类）里用 AppKit 实现——SwiftUI 的 `.contextMenu` / `.onTapGesture` 会抢走 mouseDown，而贴图窗口靠 `isMovableByWindowBackground` 拖动。标注是原地编辑：把 `SmartAnnotationEditor` 换进同一个窗口，完成后 `state.updateImage` 再换回贴图界面。
3. **所有入口走同一个管理器**。`QuickAccessPinWindowManager` 新增 `showImage(_:scaleFactor:at:language:)` 与 `showText(_:language:)`；`at:` 沿用「贴回框选原位」，`nil` 时居中到鼠标所在屏幕。直接贴图是**临时贴图**：不进快捷操作卡片栈，只登记一个保留的临时路径给拖拽命名，真正落盘发生在用户真的把贴图拖出去那一刻。
4. **删掉旧的一套**。`SmartPinWindowController`、`SmartTextPinWindowController`、`SmartPinImageView`、`SmartPinContentView`、`PinCloseButton`，以及控制器里的 `pinControllers` / `textPinControllers` / ESC 监听全部移除（净减 620 行）。双击 ESC 关闭全部贴图的行为搬到 `QuickAccessPinWindowManager.registerEscapePress()` + `QuickAccessPinEscapeRouting`：第一次 ESC 关掉当前这一张，0.8 秒内的第二下关掉全部。
5. **生命周期各归其主**。截图控制器只记录自己开出来的贴图 id（`directPinWindowIDs`），关闭截图功能时只关这些；快捷操作卡片那边的贴图仍由 `QuickAccessManager` 管理。

### 验证

- `swift build` 无警告；`swift test --no-parallel` 689 项全过。并行跑时 `startupShortcutRegistrationRetriesTransientFailure`、`heartbeatFailureTriggersABoundedReconnect`、`quickCopyAutoSaveWritesFileAndRecordsStats` 会因主 actor 被画中画与远程看门狗测试占满而偶发超时，单独跑均通过，与本次改动无关。
- 新增 `clipboardTextPinsGetTheirOwnUnzoomedSurface`：文字贴图底尺寸随文字增长、有下限、不可缩放；`doubleEscapeWithinWindowDismissesThePins` 改用新的路由类型。

### 踩坑

- **`NSHostingView` 子类里别用 SwiftUI 手势做贴图交互**：`.onTapGesture(count: 2)` 会消费 mouseDown，`isMovableByWindowBackground` 的窗口拖拽随即失效；重写 `mouseDown` / `rightMouseDown` 并调用 `super` 才两全。
- **文字贴图必须给 chrome 留位置**：未锁定时关闭/锁定按钮是常驻的，文字卡片按普通内边距排版会让第一行字被左上角关闭按钮压住。
- **临时贴图不要预先写盘**：`QuickAccessPinDragHandleNSView` 拖拽时会用内存里的图另写一个拖拽文件，贴图只要给一个用于命名的「保留路径」即可；否则每次剪贴板贴图都会在 `Captures/` 留下一份没人回收的 PNG。

## 四十二、外接屏「点亮不了」：软关机写下去了，但显示器不承认

### 现象

手机上先点「黑屏」再点「亮屏」：内屏正常回来，外接屏一直黑着，怎么点都不亮。日志（`~/Library/Logs/MacPilot/Diagnostics.log`）只有这一行关键信息：

```
[DisplayPower] display blanked without sleeping backlight=1 ddc=0 ddcOff=0 overlay=1 displays=[1, 2]
```

`ddcOff=0` 就是说「DDC 电源关没生效」，于是外接屏退回了黑色遮罩；可遮罩在 `亮屏` 时明明被收掉了（`display unblank requested` 之后 `isBlanked` 立刻变回 false），屏幕却依然黑着。

### 真机实测：问题不在遮罩，在「确认」这一步

写了个探针按 `DDCBacklight` 一模一样的包和节奏跑这台 SSN-24（displayID=2，内置屏是 1）：

```
baseline power = 1
soft-off write sent=true at t=0ms
  t=318ms read power = NIL (no answer)
  t=632ms read power = 2      ← 面板已经灭了，但它回答的是 standby(0x02)
  ...（3 秒内始终是 2）
```

**写 `0x04`（DPMS soft off）面板确实灭了，但显示器回读的是 `0x02`（standby），永远不是 `0x04`。** 旧代码 `guard reply.current == mode` 拿写入值去比对回读值，5×200ms 轮询全落空 → `setPowerMode(powerOff)` 返回 `false` → `ddcPoweredOff.insert` 被跳过 → MacPilot **没有记下这台显示器被关过**。

而写命令早就发出去了，面板也真的灭了。于是：`unblankDisplay()` 里那一轮「点亮」根本不会执行（集合是空的），内屏恢复亮度、遮罩收起，外接屏留在 DPMS 关断状态没人管 —— 这就是「睡死了」。次要点「黑屏」时 `canDriveDDC` 探测也失败（面板已灭），所以两次 blank 的日志都是 `ddc=0 ddcOff=0 overlay=1`，把线索指错了方向。第一次 `displayOff` 的 `latency=1604ms` 正是那 1.25 秒的空轮询。

### 修法：按状态确认，按写入记账

1. **关机确认改成「任何暗态都算」**。新增 `DDCPacket.isPoweredDown(_:)`（`0x02...0x05` 即 standby / suspend / soft off / hard off）与 `DDCPacket.confirms(powerMode:reported:)`：开机只认 `0x01`，关机认任意暗态。显示器没有义务回显你写进去的那个字节。
2. **写入即记账，确认只用来决定要不要兜底**。`setPowerMode` 的返回值从 `Bool` 换成 `PowerModeWrite { sent, confirmed }`。`blankDisplay()` 用 `write.mayHavePoweredDown`（即 `sent`）决定是否 `ddcPoweredOff.insert`；只有 `confirmed` 时才 `continue`，否则继续走亮度 0 / 遮罩兜底，保证「现在就是黑的」。**这是本次的核心不变式：让面板变黑的是那次写入，不是显示器的承认，所以状态必须从写入记起。**
3. **恢复路径同一套规则**。`DisplayBlankRecovery.powerDecision(current:)` 同样改成 `isPoweredDown`；否则强杀后重开，这台回报 `0x02` 的显示器会被判为「用户已经自己弄好了」而永远不被点亮。
4. **点亮没确认不再被静默丢弃**。`unblankDisplay()` 里 `sent` 但未确认的点亮会写进崩溃快照（只留 `ddcPowerOff` 字段）留给下次启动重试，而不是随着内存状态一起消失。
5. **补上唤醒日志**。原来 `unblankDisplay()` 一行日志都没有，用户只能靠 `isBlanked` 的副作用猜；现在是 `display unblanked backlight=… ddcOn=… ddcOnPending=… overlay=…`。

### 验证

- 真机探针按新规则重跑：软关机 **523ms 确认**（旧规则 1250ms 后返回 false），点亮 368ms 确认，最终 `power=1`。
- `swift test`：`DDCPacketTests` 增加真机 standby 回包夹具（`6E 88 02 00 D6 00 00 05 00 02 65`）与 `mayHavePoweredDown` 语义用例；`DisplayBlankRecoveryTests` 的电源决策用例覆盖 standby / suspend / hard off / on / 未知值；三个套件全绿。

### 教训

- **DDC 的「写后读回」不能拿写入值做等值比较**：同一台显示器在不同固件/状态下会回 `standby` 而不是 `soft off`，把「没回显」当成「没生效」会得到一个已经黑了却没人认领的面板。
- **有副作用的写操作，状态要从「发出去了」记起，而不是从「被承认了」记起**。确认只能决定要不要再补一层兜底，不能决定要不要记住。

## 四十三、Dock 分组：图标外观可选、浮层严格贴图标（v1.1.352）

用户在真机上提了三个问题：**图标在深色 Dock 上是一块白的**、**展开还是跟着鼠标上下移动**、**展开后的齿轮点了没反应**。三件事都要落到真机行为上，不能只看代码。

### 一、图标外观：把「固定浅色」换成「跟随系统 / 浅色 / 深色」

§37（v1.1.344）当初的取舍是「写进 Helper 的 `.icns` 固定浅色」，理由是「`.icns` 没有外观变体，跟随生成时的外观会在用户之后切换外观时不一致」。用户看到的结果就是深色 Dock 上一块刺眼的白，而设置页里明明是深色图标——**同一个分组，两处显示不一致，这本身就是 bug**。

改法：

1. `DockGroup` 新增 `iconStyle`（`system` / `light` / `dark`，默认 `system`），旧 `groups.json` 缺这个键时按 `system` 解码。
2. `DockGroupIconStyle.appearance(isDark:)` 把「跟随系统」解析成实际绘制外观；`DockHelperBundleBuilder.build(...)` 收这个参数出图，并把结果写进 Helper 的 `Info.plist`：`MacPilotDockGroupIconAppearance = light|dark`。
3. `DockHelperManager.helperNeedsRegeneration` 增加一条：**Info.plist 里记录的外观 ≠ 当前该用的外观（或缺这个键）就要重建**。老版本生成的 Helper 没有这个键，所以升级后第一次启动会自动把 Dock 图标换成正确外观，不需要用户做什么。
4. `DockGroupsModel` 订阅 `AppleInterfaceThemeChangedNotification`，300ms 合并后 `ensureHelpersExistIfNeeded()` + 重读 Dock 图标位置；分组列表、编辑器预览、Helper 图标三处都按配置的外观绘制。

### 二、浮层严格贴图标：由 MacPilot 把图标矩形写进配置

「跟着鼠标上下移动」的根因不是数学，是**信息**：`DockHelperPanelPlacement` 原先只能拿 `NSEvent.mouseLocation` 沿 Dock 方向定位，而真机实测 Dock 图标槽位是 49.33 × 37.33 点，点在图标上沿和下沿会让浮层差出整整一个身位。

Helper 自己拿不到图标位置——它是 ad-hoc 重签的另一个 App，**没有辅助功能授权**（真机实测 `AXIsProcessTrusted()=false`，读 Dock 的辅助功能树直接返回 `-25211` / `kAXErrorAPIDisabled`）。让用户为了一个每次升级都重建的 Helper 去授权也不合理。所以：

- 新增 `DockTileLocator`（主程序侧，MacPilot 本来就有辅助功能权限）：读 Dock 的 `AXList`，按每项的 `kAXURLAttribute` 匹配分组的 Helper 路径，把 frame 从「主屏左上角原点」换算成 Cocoa 全局坐标。
- `DockGroupsModel.refreshDockTileAnchors()` 把结果写进 `groups.json` 的 `dockTile`（含 `updatedAt`）。**只在位置真的变了（>0.5 点）时才写盘**，1 秒节流；触发点是激活、应用启停、前台切换、唤醒、外观变化与重建 Helper 之后。日志里会留一行 `Dock tile anchors: trusted=… groups=… found=…`，排查「为什么没贴到图标上」先看它。
- **必须丢掉跑到屏幕外的几何**：Dock 自动隐藏时、或显示器刚重新配置过而 Dock 还没回到当前屏幕时，整条 Dock 的 AX 坐标会变成负数（实测容器 `frame=(-52, 61, 52, 988)`，图标 x=-57），此时读到的根本不是「图标在哪」。`DockTileLocator.intersectsAnyScreen` 会把这些矩形全部滤掉（`NSScreen.screens` 一个都不相交就不存），Helper 于是退回按点击位置落点 —— 这比存一个错误位置安全得多。真机上这条守卫是有用的：显示器重新配置后 Dock 真的卡在了屏幕外，`killall Dock` 才让它回到 x=10。
- Helper 侧 `DockHelperPanelPlacement.origin(..., tile:)`：点击点落在记录的图标矩形里（±12 点容差）就用**图标中心**沿 Dock 定位，垂直于 Dock 的方向永远不看鼠标；点击点落到矩形外（Dock 刚增删过图标、布局平移了）或压根没有这份几何，就退回按点击位置落点，绝不落在一个错误的图标旁边。

Helper 依然只读 `groups.json`，一个字节都不写。

### 三、齿轮「点了没反应」：在当前版本上已经好了

真机上用辅助功能 `AXPress` 直接按浮层里的齿轮（`AXButton` desc「设置…」，CG 117,730，13×13）：返回成功，MacPilot 变成前台、窗口切到「Dock 分组」；`open macpilot://dock-groups` 同样正常。根因是 v1.1.347 之前的 `close()` 在 `open(url)` 之后立刻 `NSApp.terminate`，把还在飞的 URL 请求一起杀了；改成 `dismiss()`（不终止进程）之后就不存在了。

### 四、真机实测：**已经固定在 Dock 上的图标，macOS 会缓存那张图**

这是这次最花时间、也最值得记下来的一条。为了确认「跟随系统」到底能不能在 Dock 上生效，做了这些对照实验（每次都截图比对 Dock 那一格）：

| 操作 | Dock 图标是否更新 |
| --- | --- |
| 替换 `Contents/Resources/AppIcon.icns` + 重新 ad-hoc 签名 | 否 |
| `touch` 整个 `.app` + `lsregister -f` | 否 |
| 改 `CFBundleVersion` / `CFBundleShortVersionString` | 否 |
| 改 `CFBundleIdentifier` | 否 |
| `rm -rf` 后重新拷贝整个 `.app`（新 inode） | 否 |
| `killall Dock` / 清 `~/Library/Saved Application State/com.apple.dock.savedState` | 否 |
| `killall iconservicesagent` | 否 |
| `NSWorkspace.setIcon(_:forFile:)` 设自定义图标 | 否 |
| 启动该 Helper（含点 Dock 图标） | 否 |

同时 `NSWorkspace.shared.icon(forFile:)` 早就是新图标（中心像素纯品红），说明**磁盘与 IconServices 都对，只有 Dock 那个已固定的格子还捧着旧图**。所以：

- 「跟随系统」在**新固定 / 重新拖入**的图标上一定正确；已经固定的图标要等 macOS 自己过期（或重新登录）才会刷新。
- 因此编辑器里加了一行明确提示（`dockGroupsDockIconCacheHint`），README 也写清楚了：改完外观若 Dock 上还是旧图标，把图标从 Dock 移除再拖回来即可。
- 这是系统行为，不是 MacPilot 能绕过的：能立刻刷新的两条路（改写 `com.apple.dock.plist` 里的 bookmark、或 `sudo` 清系统图标缓存）分别违反「MacPilot 不改写用户的 Dock 配置」和「不许要 sudo」。

### 验证

- `swift test`：`DockHelperPanelPlacementTests` 增加「同一个图标点上沿/下沿落点必须完全相同」「Dock 平移后旧矩形失效要退回点击点」「±12 点容差」等用例；`DockGroupDockTileTests`（新）覆盖外观解析、`groups.json` 旧配置兼容与往返、`contains`/`isClose` 容差、AX 坐标翻转与路径匹配；`DockGroupsIntegrityTests` 里那条「Helper 图标必须固定浅色」的用例改成「跟随图标外观」（深色系统下默认出深色图、固定浅色时依旧出浅色图、Info.plist 记录一致、系统切深色后判定为需要重建）。
- `swift build -c release -Xswiftc -warnings-as-errors` 干净。
- 真机（未锁屏时）：把新 Helper 二进制临时装进已固定的分组，手写一份 `dockTile` 到 `groups.json`（取真机 AX 读到的矩形，49–52 点宽、37–40 点高），分别在图标上沿与下沿合成鼠标点击 —— **两次浮层落点完全一致**（cocoa `(67, 25)`，正对图标中心 185.5 − 160）；抽掉 `dockTile` 再点同样的两处，落点分别回到 `(67, 38)` 与 `(67, 12)`，差出 26 点，正是用户说的「跟着鼠标上下移动」。
- 真机跑发布版：装上 1.1.352 后 MacPilot 自动做了三件事 —— 重建 Helper（旧 Helper 没有 `MacPilotDockGroupIconAppearance` 键，判定过期）、把 `iconStyle: system` 与 `dockTile: {x: 5, y: 132.52, w: 52.15, h: 40.15}` 写进 `groups.json`、日志里留下 `trusted=true groups=1 found=1` + `Published Dock tile anchors for 1 group(s)`。Helper 的 `.icns` 中心像素从 0.94（浅色底）变成 0.29（深色底），与「跟随系统 + 深色外观」一致。
- 锁屏状态下合成点击不会送到 Dock（点击被锁屏吃掉），真机交互验证必须在解锁状态做；期间那次「点了没反应」是锁屏，不是回归。

## 四十四、合盖不休眠提示「请使用已签名的正式版本」：状态快照启动了就不再更新（v1.1.353）

用户报：当前就是已签名的正式版，Awake 页却提示「当前版本无法使用后台电源服务，请使用已签名的正式版本」。**签名完全是无辜的**——这次真正的缺陷是「一次读取、永不复查」，而那句文案把责任推给了构建。

### 一、先排除掉的假设：plist 名称

第一反应是 `SMAppService.daemon(plistName:)` 的入参。用一份已签名的 bundle 做对照，结论是**必须带 `.plist` 后缀**：

| `daemon(plistName:)` | `status` | `register()` |
| --- | --- | --- |
| `com.misswell.macpilot.powerhelper` | `.notFound` | `SMAppServiceErrorDomain 108`：Unable to read plist |
| `com.misswell.macpilot.powerhelper.plist` | `.notFound`（= 未注册的正常初始态） | `1`：Operation not permitted → 状态转 `.requiresApproval` |

但 v1.1.352 的 `MacPilotPowerService.daemonPlistName` **本来就是带后缀的**（`git show v1.1.352` 可查），`PrivilegedPowerHelper` 也照传。所以「少写 `.plist`」不是本次根因——只是顺手把这个易踩的约定写进常量注释，并用 `PowerServiceIdentityTests` 钉住「常量 = `machServiceName + ".plist"`，且 `Resources/` 下确有同名 plist、`Label`/`MachServices` 对得上」。

### 二、根因：`closedLidServiceState` 只在启动那一刻读过一次

时间线来自 `backgroundtaskmanagementd` / `smd` 的系统日志（不是推测）：

| 时间 | 事件 |
| --- | --- |
| 08:24:21 | MacPilot 启动 |
| 08:24:22 | `effectiveItemDisposition: record not found: appURL=/Applications/MacPilot.app … type=daemon` —— 此刻 daemon 记录**确实不存在** |
| 09:17:29 | `smd: copyJobWithLabel … failed with error 113` → `launchd: Setting service com.misswell.macpilot.powerhelper to enabled` —— 才第一次注册成功 |

也就是说用户看到提示时，daemon 是真的没注册，`SMAppService.daemon(...).status` 返回 `.notFound`，`registrationState` 把它映射成 `.unavailable`，UI 就渲染了那句「请使用已签名的正式版本」。**问题在于：查完一次就再没查过。**

- `ClosedLidSleepController.serviceState` 是 `init` 时从 `helper.registrationState` 取的快照，`AwakeSessionManager` 在初始化时把它抄进 `@Published var closedLidServiceState`。
- 之后只有 `syncClosedLidServiceState()` 会重新读，而它的调用点只有：`applyAssertions()`（有会话时才跑）、关合盖开关时的 `applyClosedLidPolicy`、`prepareClosedLidService()`（用户点按钮）、`shutdown()`。
- `AwakeSettingsView` 是 `.onAppear` 都没有的纯 `ScrollView`，`closedLidServiceStatus` 只在 `preventClosedLidSleep` 打开时渲染。

于是：**没有任何路径会在「用户去系统设置批准了这个服务、回到 App」之后重新读一次状态**。系统侧 09:17 已经 `enabled` 了，界面上那句警告依旧挂着，直到用户重启 App。这正是「明明签名了却说我用的不是正式版」的由来。

### 三、修法

- `AwakeSessionManager.refreshClosedLidServiceState()`：对外暴露一次「重读系统状态并同步到 `closedLidServiceState`」。底层复用已有的 `syncClosedLidServiceState()`，它本来就只在值真的变了才写 `@Published`，不会白刷。
- `AwakeSettingsView` 加 `.onAppear`：每次进入 Awake 页都重读。用户去系统设置批准、回来切页即可自愈。
- 主窗口根视图监听 `NSApplication.didBecomeActiveNotification`：批准动作发生在 App 处于后台时，回前台是**唯一必然发生的时机**，比等用户手动切页更可靠（仓库里已有两处同样用法的先例）。
- 单位测试：`refreshingPublishesTheLiveServiceStateInsteadOfTheLaunchSnapshot`（`.ready` → `.unavailable` → `.ready` 必须跟着变）与 `refreshingTracksThePendingApprovalTransition`（`.unavailable` → `.requiresApproval`）。

### 四、顺带修掉的构建坑：`clang` 默认去了 Command Line Tools 的 SDK

改完重打包时构建在最后一步挂了：

```
tapi error: malformed file .../MacOSX27.0.sdk/usr/lib/libSystem.B.tbd:4:20:
  error: unknown architecture  arm64e.x1-macos, arm64e.x1-maccatalyst
```

Command Line Tools 的 SDK 比 Xcode 自带的新，`xcrun clang` 解析 `MacOSX.sdk` 时选到了它，而本机 Xcode 的 `ld` 不认识新 tbd 里的 `arm64e.x1-macos`。SwiftPM 不受影响（它走 `-sdk macosx` 拿 Xcode SDK），所以现象是「Swift 全绿、最后链接 dylib 才炸」。`build-app.sh` 里给那条 `xcrun clang` 加上 `-isysroot "$(xcrun -sdk macosx --show-sdk-path)"`，让汇编那条命令与 SwiftPM 用同一个 SDK，构建不再依赖 `MacOSX.sdk` 这个软链当前指向谁。

### 五、这次的教训

「已签名」那句文案把一个**状态刷新问题**说成了**构建合法性问题**，于是用户第一反应是去质疑自己的版本，我们也差点顺着文案去改签名。**报错文案描述的是现象，不是原因**：拿到「版本不合法」这种断言时，先去系统日志（`backgroundtaskmanagementd` / `smd`）把「那一刻系统里到底有没有这条记录」查清楚，再决定往哪改。

### 验证

- `swift test --filter "ClosedLidSleepTests|PowerServiceIdentityTests"`：29 条全绿，含两条新增的刷新用例与两条服务身份用例。
- 真机：在**已签名**的 `MacPilot.app` 里塞探针实测 `SMAppService.daemon(plistName:)`，两种入参的 108 / Operation not permitted 差异如上表；`sfltool dumpbtm` 中该 daemon 记录从 `[enabled, disallowed, not notified]` 变为 `[enabled, allowed, notified]`，`status` 读出 `enabled`、`register()` 返回 OK。
- `./Scripts/build-app.sh` 全流程走通（universal arm64 + x86_64、Developer ID 签名、`codesign --verify --deep --strict` 通过）。
- 全量 `swift test` 出现的 `ScreenCaptureTests` 两条 ~39s 超时属并行负载下偶发，单独 `--filter ScreenCaptureTests` 复跑 74 条全绿，与本次改动无关。
