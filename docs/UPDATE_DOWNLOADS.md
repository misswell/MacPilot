# 更新包下载源

## 两个发布仓库

更新检查和版本管理同时查询 `misswell/MacPilot` 与 `jollyfon/MacPilot`。两个仓库独立分页并并发查询；一个来源不可用时使用另一个成功来源，全部失败才报告检查失败。取消检查会停止所有来源。自动更新从成功来源中选择当前 Stable/Beta 通道的最高 SemVer，仍然只安装比当前版本新的版本。版本管理合并并去重相同版本，保留逐页显示和兼容性清单加载；相同版本优先使用旧仓库的有效记录。

两个仓库的安装包都使用以下下载镜像和签名校验。项目主页链接仍为原仓库，不影响新增发布来源。

MacPilot 下载本项目 GitHub Release 安装包时，按以下顺序尝试：

1. Xget：`https://xget.xi-xu.me/gh/<发布仓库>/releases/download/...`
2. GHFast：`https://ghfast.top/https://github.com/...`
3. GH-Proxy：`https://gh-proxy.org/https://github.com/...`
4. GitHub 原始下载地址（最终兜底）。

首次按上述顺序尝试，后续优先使用上次下载并通过 SHA-256 校验的镜像，其余镜像保持默认顺序，直连始终最后。上次只有直连成功则恢复默认镜像顺序。偏好仅限内置域名，不接受任意地址。网络变化导致镜像失效时自动继续尝试其他源；这不是实时测速排序。单个源连续 15 秒没有网络响应、请求失败、HTTP 状态不是 200，或下载文件的 SHA-256 不匹配时，会自动尝试下一个源。正常持续传输不受 15 秒空闲超时限制。用户取消请求时停止，不继续切换源。所有源失败后显示更新失败，并在诊断日志记录各源失败原因。

版本信息和预期 SHA-256 仍由 GitHub 直接提供；检查更新阶段目前仍需要能够连接 GitHub。Xget 只传输安装包，不能改变预期摘要。下载成功后仍执行应用版本、Developer ID 团队和签名身份校验。第三方地址及其他仓库不会被自动改写为镜像地址。

Xget 地址规则：https://github.com/xixu-me/Xget

GHFast：https://ghfast.top/

GH-Proxy 地址规则：https://gh-proxy.com/docs/github-accelerator
## Stable / Beta 通道

设置 → 软件更新中选择更新通道。正式安装和缺少 `updateChannel` 的旧配置均使用 Stable；纯 Debug 新配置默认 Beta。启用 Beta 需要确认，切回 Stable 不需要确认。About/设置版本区域显示的是安装包通道，与订阅偏好分开。

Stable 使用各仓库的 GitHub `/releases/latest`，拒绝 draft、prerelease 及预发布版本标签；API 限流时尝试同一仓库的公开发布网页（`/releases/latest` 的重定向标签 → `releases/expanded_assets/<tag>`，摘要只从后者取）。Beta 分页读取各仓库的 `/releases`，只选 `prerelease=true`、`-beta.N` 且存在适配 CPU 的校验安装包的最高 SemVer。成功来源没有 Beta 时显示已是最新版本。目标版本小于或等于当前版本均不提示更新；Beta 切回 Stable 后须等更高的正式版，不自动降级。切换通道会清除旧结果，正在进行的旧查询不会覆盖新通道结果。**Beta 的 API 被限流时同样回退到发布网页**：`/releases` 列表页按标签找出通道内最高 SemVer 的 `-beta.N`，再从 `releases/expanded_assets/<tag>` 取安装包名与 `sha256:` 摘要；`/releases/latest` 永远指不到预发布版，所以 Beta 不能沿用 Stable 的单页路径。API 与网页都拿不到版本信息时按「GitHub 暂时没有返回版本信息（可能触发 API 限流）」报告，不再谎报安装包无效。

**自动更新永远只向前；只有版本管理（用户明确选择目标版本）才允许降级。**

## 版本管理（Version Manager）

设置 → 软件更新 → 版本管理打开独立页面：

- 列出全部可安装的 GitHub Release（分页读取，按 SemVer 倒序，5 分钟缓存，可手动刷新）。没有合法校验 ZIP 的 Release 不进入列表。
- 任意组合均可安装：Stable → 新/旧 Stable、Stable → Beta、Beta → 新/旧 Beta、Beta → Stable，以及任意高/低版本之间。按钮措辞区分「升级到 / 降级到 / 安装正式版 / 安装开发版」。
- 发布包附带 `MacPilot-<version>-compatibility.json`（配置 Schema、可读 Schema 下限、版本管理协议版本）。历史版本没有该文件时显示「配置兼容性未知」，不猜测；仍允许安装。
- 安装包安全要求与自动更新完全一致：HTTPS、GitHub SHA-256 摘要、Bundle ID/可执行文件校验、版本匹配、目标系统 `LSMinimumSystemVersion` 检查、Developer ID、Team ID、designated requirement、Gatekeeper、CPU 架构。下载与校验只有一套实现（`UpdateArchiveDownloader` + `UpdatePackageValidator`），App 替换只有 `MacPilotUpdater` 一个实现。
- 自动更新仍严格 newer-only（`SoftwareUpdater.install(release:intent:.automatic)`）；`checkForUpdates` 不受版本管理影响。

### 版本切换事务与降级保护

每次通过版本管理安装都是一个事务（`VersionManager/transactions/active.json` 记录阶段，崩溃后下次启动归档）：

1. 下载并完整校验目标安装包（先验证包，再做快照；下载失败不产生任何备份）。
2. 冻结配置写入（`ConfigStore.isVersionSwitching`），`finish()` 确认无脏数据。
3. 创建降级保护快照到 `~/Library/Application Support/MacPilot/VersionManager/snapshots/<时间戳>_<源版本>_to_<目标版本>/`：
   - `configuration/`：config.json、features.json、clipboard.json、shortcuts.json、window.json、config-legacy.json 原样保存；另有 `merged-config.json` 仅用于诊断。
   - `dock-groups/`：groups.json 与自定义图标。
   - `right-click/`：RightClick SQLite 经 Backup API（含 WAL 中已提交事务）+ `PRAGMA integrity_check`，副本归一为普通 journal 模式。
   - `preferences.plist`：整个 UserDefaults persistent domain（恢复时排除镜像缓存等运行时 key）。
   - Keychain 配对密钥与解锁密码复制为 Keychain 备份项（`com.misswell.macpilot.version-backup.<snapshotID>`），**绝不落盘**；manifest 只记录数量。
   - 大型剪贴板历史内容不复制（manifest 中 `clipboardContentBackedUp=false`），版本切换也绝不触发剪贴板清理。
   - 每个文件记录 SHA-256，快照完成后逐个重算验证；任何失败都禁止降级。
4. 创建降级前 App 的本地恢复包 `VersionManager/recovery/MacPilot-<version>-recovery.zip`（含 SHA-256），并复制独立 `MacPilotRecovery` Helper——即使降到没有版本管理器的旧版本，也能从本机恢复原 App 与原配置。
5. 快照验证通过后才切换 `updateChannel`（跟随目标版本；恢复配置时还原快照记录的原通道），写入 pending restore（可选），启动 `MacPilotUpdater` 替换并重启。
6. `MacPilotUpdater` 收到 success token 参数时保留旧 App 作为回滚包；新版本正常启动后才删除（两阶段成功确认）。
7. 「恢复降级前配置」= 切回快照来源版本：先对当前状态再做一次快照（Restore 前再 Snapshot），恢复请求在下一次启动、配置加载之前应用（staging + 校验 + 原子替换）。

快照生命周期：`downgradeActive`（当前保护）不可自动清理、不可在 UI 删除；新降级会把旧保护降级为历史；历史快照最多保留 5 个。「恢复降级前配置」要求目标版本支持版本管理（compatibility manifest 中 `versionManagerProtocolVersion >= 1`），否则仅按普通方式安装并保留快照。

自动更新不会重置任何 macOS 权限（TCC）；版本切换继续沿用相同 Bundle ID、签名身份与 FinderSync 注册逻辑。

### FinderSync 恢复记录与多份安装

恢复记录按应用的规范化绝对路径隔离在 `~/Library/Application Support/MacPilot/FinderSyncRecovery/<路径 SHA-256>.json`。各路径仍共用原来的跨进程锁，因为 Finder 扩展的启用状态由系统共同管理。记录只能授权恢复其原始应用路径；命令成功后还必须查询确认当前扩展路径已启用，才能清除记录。

旧的 `FinderSyncRecovery.json` 在持锁后迁移到记录中原始应用的目录项，内容原样保留。另一份安装的未完成恢复不会阻止当前应用更新。无效记录或目标目录项已存在时拒绝迁移，保留现场。

旧版更新助手若因另一份安装的记录报 `journalTargetMismatch`，可用新版 `MacPilotUpdater --migrate-findersync-journal <当前 MacPilot.app 的绝对路径>` 仅迁移恢复元数据，再由用户重新点击更新。此命令不会替换、退出或启动应用，也不会改变 Finder 扩展启用状态；迁移不代表原始安装的扩展恢复已完成。

替换应用后，系统可能已自动移除旧的 FinderSync 注册，导致先前查询到的路径在执行 `pluginkit -r` 时返回 `remove: no plugin at <路径>`。安装器只对该命令的精确路径和已知 PlugInKit 错误重新查询完整注册列表；确认该路径已不存在后继续注册新版扩展。权限错误、仍存在的注册、添加失败及启用状态未确认仍会报错。启用状态恢复必须继续由当前路径的最新 `+` 查询确认，不能凭命令成功清除恢复记录。

升级使用已经完整验签的新包内的更新助手，让助手自身的修复能够在本次升级生效；降级保留较新安装版的助手。所选助手缺失时拒绝安装，不退回已知较旧的助手。v1.2.1-beta.6 及更早版本仍使用旧的助手选择逻辑；已被旧助手阻塞的安装需要一次经校验的新助手引导升级，发布新版不会自动修改本机旧安装。

## 构建示例：

```sh
MACPILOT_CHANNEL=stable MACPILOT_VERSION=1.6.0 ./Scripts/build-app.sh
MACPILOT_CHANNEL=beta MACPILOT_VERSION=1.7.0-beta.1 ./Scripts/build-app.sh
```

未显式指定版本时，Stable 的版本推导忽略 Beta 标签；Beta 在没有可用预发布基线时生成下一个 patch 的 `-beta.1`。CI 发布始终使用触发标签的精确版本。

脚本验证通道与版本一致后生成编译期 `BuildInfo.swift`，退出时恢复开发源码；Info.plist 同时嵌入 `MacPilotUpdateChannel` 与完整 `MacPilotVersion`；Apple 的 `CFBundleShortVersionString` 保留纯数字核心版本，界面和安装校验均读取完整版本。Bundle ID、签名 designated requirement、Helper 和权限身份共用原有值。

`release.yml` 负责正式 tag，`release-beta.yml` 负责 beta tag，均调用 `release-common.yml` 执行主分支 CI 门禁、Developer ID 签名、公证和装订。Beta 发布使用 `--prerelease --latest=false`，正式发布使用 `--latest`。每次发布含 arm64/x86_64 更新 ZIP 和通用 `MacPilot-<version>.dmg`，DMG 也签名、公证和装订。

版本排序遵循 [SemVer 2.0.0](https://semver.org/)，API 通道约定见 [GitHub Releases API](https://docs.github.com/en/rest/releases/releases)。权限延续仍需在实际升级后人工确认 Accessibility、屏幕录制、FinderSync 和 Helper；签名身份测试不能代替系统授权验收。
