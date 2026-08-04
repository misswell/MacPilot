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
- `Scripts/build-app.sh`：检测到 `MACPILOT_DEVELOPER_ID` 时用 Developer ID + Hardened Runtime 签名，否则回退 ad-hoc；旧环境变量别名仍可用。
- `Scripts/distribute-app.sh`：一键签名 → 提交 Apple 公证 → 装订票据 → 打 zip → Gatekeeper 校验；支持钥匙串公证 profile（不接触明文密码）。
- `.github/workflows/build.yml`：日常 push/PR 走 ad-hoc artifact；打 `v*` tag 自动签名、公证并发布 Release。
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
- 重新发布 **v1.1.1**：https://github.com/misswell/OctoPilot/releases/tag/v1.1.1
  - 已签名 + Apple 公证 + Hardened Runtime
  - 产物：`OctoPilot-1.1.1-macos.zip`，双击运行无 Gatekeeper 拦截
  - 该版本不是 tag workflow 自动成功：对应 Actions 运行失败，最终 Release 与 ZIP 由本机流程手动发布。
- 正式发布 **v1.1.6**：https://github.com/misswell/OctoPilot/releases/tag/v1.1.6
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

- 运行中可用 `gh run watch <run_id>` 或 `gh api repos/misswell/OctoPilot/actions/jobs/<job_id> --jq '{s:.status,c:.conclusion,steps:[.steps[]|{name:.name,s:.status,c:.conclusion}]}'` 查看 step 状态；任务完成后用 `gh run view <run_id> --job <job_id> --log-failed` 提取失败日志。
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
