# updater-release — 软件更新、下载、签名与发布

规则：`upd-001-designated-requirement`（designated requirement，v1.1.355 搁浅）、`upd-002-update-source-availability`（更新源可用性）、`upd-003-relaunch-and-version-switch`（relaunch/版本切换卡死）。证据链见 [../REGRESSION_CATALOG.md](../REGRESSION_CATALOG.md) F1–F3。

## 不变量

### 签名身份与 designated requirement（upd-001-designated-requirement，原 AGENTS.md 全文）

每个构建在 app bundle 内嵌一条 **designated requirement（DR）**，macOS 用它判定更新包是否「是同一个 app」。它必须跨签名身份、机器、Agent 字节一致——不一致会让应用内更新无法安装（搁浅了 v1.1.355 以下的全部安装）。嵌套代码（updater、FinderSync appex、helpers、dylib）保有自己的 identifier 并独立签名；只有 app bundle 的 requirement 是共享身份。

- **单一来源：** `Scripts/signing-requirement.sh`。它钉 bundle identifier、Apple 代码签名锚与 team OU（`U8U443D7ZL`）——没有别的。
- **绝不让 codesign 自推 requirement**，绝不加 Developer-ID-only OID 或 `subject.CN` 子句。每一种都只被一种证书满足，Apple Development 构建就会不再是发布版的「同一个 app」：更新与隐私授权双向失效。
- **四条签名路径**（Developer ID、Apple Distribution、Apple Development、ad-hoc）必须嵌同一字节。不得按签名身份分支 requirement。
- **三道门强制执行：** `Scripts/build-app.sh`（签名后）、`Scripts/distribute-app.sh`（重打包后）、`dist` job（`gh release create` 前）。`Tests/MacPilotTests/SigningRequirementTests.swift` 是把这些门接起来的 tripwire 测试。
- **绝不为过门弱化 requirement。** 修签名路径；已安装的 app 说服不了它接受不认识的包。

正式发布仍须 Developer ID 签名并经 `Scripts/distribute-app.sh` 公证。本地 Apple Development 构建共享同一身份（TCC/更新），但不可分发（Gatekeeper 拒绝）。

### 更新源可用性（upd-002-update-source-availability）

- 403/匿名 API 限额 = 源不可达，**不是**「无效发布」；回退链（镜像、Xget 直连、公开 releases 页）保持可用。
- beta 通道没有 `/releases/latest` 可回退，必须经公开 releases 页取数（`19b99f0`）。

### relaunch 与版本切换（upd-003-relaunch-and-version-switch）

- relaunch 等**主进程退出后**再原子替换已验证的 bundle 并重启；`NSApp.terminate` 被 sheet 吞掉不算退出（卡 awaitingRelaunch）；`isCancelled` 极性不得反转（曾使所有下载秒抛 `CancellationError`）。
- FinderSync 启用的机器上更新失败不得把扩展留在禁用状态（跨 help-001-findersync-registration）。

### 凭据与发布纪律

- `MacPilot.entitlements` 只启用 `com.apple.security.cs.disable-library-validation`——无理由不加 entitlement。
- tag workflow 恰需六个 Actions secrets（`APPLE_CERTIFICATE_P12`、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_DEVELOPER_ID`、`APPLE_ID`、`APPLE_APP_SPECIFIC_PASSWORD`、`APPLE_TEAM_ID`）。app-specific 密码绝不进聊天/命令参数；泄露立即吊销。
- 本地 `MACPILOT_NOTARY_PROFILE` 可选且用前必须核验（`xcrun notarytool history --keychain-profile <profile>`）；不要因上次成功就假设某 profile 存在。
- 推送的 tag ≠ 已发布：必须核验 Actions `dist` job 与 `gh release view <tag>` 都成功且 ZIP 资产存在。绝不移动/覆盖已推送的版本 tag；发布修复用新 patch 版本。

## 必跑测试

`SigningRequirementTests`、`SoftwareUpdateTests`、`SoftwareUpdateInstallerTests`、`UpdateChannelTests`、`UpdateArchiveDownloaderTests`、`ReleaseCatalogServiceTests`、`VersionSwitch*`、`VersionRelationTests`、`VersionCompatibilityTests`；`python3 Tests/Release/stapler-retry-tests.py`。

## 人工验收

- 最终下载包：`codesign --verify --deep --strict`、`./Scripts/verify-signing-requirement.sh`、`xcrun stapler validate`、Gatekeeper 首开。
- 安装版内「检查更新→安装→自动重启」全流程；FinderSync 启用的机器更新后扩展仍可用。
- 限流时段检查更新：提示稍后重试而非损坏提示。
