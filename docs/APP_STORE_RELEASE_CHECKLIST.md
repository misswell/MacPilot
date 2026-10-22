# PilotNest：App Store 发布检查与 ITMS-90161 记录

每次上传 PilotNest 的最终 IPA 前必须完成此检查；任何签名项失败都应停止上传。本文是项目发布记录，不是需要在普通用户界面中显示的产品功能。

## 2026-09-28 事件：不是缺少审核内容

Apple 邮件针对 PilotNest（App ID `6811335132`）、版本 `1.2.0`、构建 `20`，指出：

> ITMS-90161: Invalid Provisioning Profile — Missing code-signing certificate

涉及 bundle：`com.misswell.macpilot.remote`，包内位置：`Payload/PilotNest.app`。Apple 要求修正签名并上传新 binary，且上传 App Store Connect 必须使用分发 provisioning profile。

这次明确缺的是**有效的分发签名授权／证书关联**，不是截图、隐私政策、功能说明或软件功能。它属于二进制验证失败，不能混称为功能审核驳回。

邮件能够确认 profile 无效、代码签名证书相关验证未通过；单凭邮件不能进一步确定是证书被撤销、profile 过期、profile 与签名证书不匹配，还是用了错误的签名资产。只有取得**构建 20 实际上传的最终 IPA**并检查，才能确定具体子原因；不要把这些可能性记录成已经证实的根因。

诊断时曾检查到其他构建的开发签名 archive；该证据不能用于断言构建 20 的最终 IPA 使用了开发签名。Xcode 可以在 export 阶段重新签名，因此最终 IPA 才是上传前检查对象。

后续构建 26（1.2.0）的最终 IPA 已通过本机签名检查和 Apple 处理检查（VALID），并已重新提交审核。2026-09-28 核对时状态为 WAITING_FOR_REVIEW；2026-10-01 已通过 API 确认 1.2.0 上架。

## 当前项目配置

- App ID：`6811335132`；bundle ID：`com.misswell.macpilot.remote`；Team：`U8U443D7ZL`。
- `iOS/MacPilotRemote/project.yml` 是 XcodeGen 配置源，当前使用 `CODE_SIGN_STYLE: Automatic`。
- `iOS/MacPilotRemote/ExportOptions.plist` 使用 `method=app-store-connect`、`signingStyle=automatic`，并指定上述 Team。
- 允许 Xcode 在导出时管理分发证书和 profile。不要仅因 archive 的签名显示 Apple Development 就切换整个项目的签名策略。
- 若确需手动分发签名，必须先确认可用 Apple Distribution 签名身份、私钥和与其匹配的有效 App Store profile；不能把临时手动 profile UUID 固化为永久发布配置。

## 上传前：必须检查最终 IPA

- [ ] 核对最终 IPA 中的 bundle ID、版本、构建号和 Team；不得上传旧包或用另一个 archive 的检查结果代替。
- [ ] 使用新的构建号；改过 `project.yml` 后运行 XcodeGen，并检查生成项目未出现意外的签名覆盖。
- [ ] 导出方式是 App Store Connect，而不是 development、ad-hoc 或 enterprise。
- [ ] 解包至新临时目录，运行 `codesign --verify --deep --strict` 检查主 App 及嵌套代码；同时检查签名身份、Team 和实际签名证书。
- [ ] 用 `security cms -D -i <app>/embedded.mobileprovision` 解析 profile；核对有效期、TeamIdentifier、application-identifier、平台和预期 App Store 类型。
- [ ] profile 的 `DeveloperCertificates` 必须包含**实际给 App 签名的证书**：比较 DER 证书内容或 SHA-256 指纹，不要只比较显示名称或 profile 名称。另查证书有效期及开发者账户中的撤销状态；本地签名校验不能替代 Apple 的服务器检查。
- [ ] App Store profile 的 `get-task-allow` 必须为 false，不能带设备白名单 `ProvisionedDevices` 或企业分发的 `ProvisionsAllDevices=true`；这些字段的缺失也不能单独证明 profile 合格。
- [ ] 核对 App 实际签名 entitlements 均被 profile 授权；存在扩展时，对每个扩展的独立 bundle/profile 重复检查。
- [ ] 留存 IPA 的 SHA-256、构建号、profile UUID/有效期和签名证书指纹作为发布证据；不记录私钥、密码或 API 凭据。

本地存在“Apple Distribution”这个显示名称不够，签名机器必须能使用对应私钥完成签名。反过来，private key 不应嵌入 IPA 或 profile；profile 内包含的是公开证书。

## 上传后：确认 Apple 接收的就是这个构建

- [ ] 等待该构建号处理为 `VALID`；上传请求成功或上传 ID 返回不等于二进制已通过处理。
- [ ] 查询 App Store 版本附带的实际 build ID / buildVersion，确认是本次通过检查的新包。
- [ ] 先执行 `asc review submit ... --dry-run`，确认版本与 build 正确，再执行已获用户授权的 `--confirm` 提交。
- [ ] 记录提交 ID 与当前审核状态。区分“处理有效”“等待审核”“审核通过”“已上架”；不得把 VALID 当作审核批准。
- [ ] 如果收到签名错误邮件，对照邮件中的版本和构建号定位原始 IPA，修复后增加构建号、重新导出、重复全套检查，再上传新包。

## 三类凭据不要混淆

- Apple Distribution 证书及其私钥：用于签名；App Store provisioning profile 授权对应 App 和签名证书。
- App Store Connect API key：用于 asc/API 操作，不会自动替代代码签名证书或生成合格的 IPA。
- Apple App 专用密码：用于支持它的上传／公证认证，不是签名证书，也不能修复 profile 与签名证书不匹配。

MacPilot 的 Developer ID + notarization 是 **macOS App Store 外**分发流程；不能拿这个流程的证书或“已公证”结论代替 PilotNest 的 iOS App Store 分发检查。

## Apple 官方依据

- [Create an App Store provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)：App Store profile 包含分发证书，Xcode 自动签名可管理分发 profile。
- [TN3125: Inside Code Signing: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)：解释 profile 的证书、身份和 entitlement 授权关系。
- [Distribution methods](https://help.apple.com/xcode/mac/current/en.lproj/dev31de635e5.html)：区分 App Store Connect 与 Developer ID 分发。

## 2026-10-01：1.2.1 / 构建 27 发布检查

- 最终 IPA：`/tmp/PilotNest-1.2.1-27.ipa`；bundle/team/版本/构建号均核对一致。
- Xcode 自动导出因本机未登录账户失败，本次使用临时手动导出参数；仓库仍保留自动签名配置。已重新验证本机分发私钥可用、profile 与 signer DER 一致、账户证书仍有效。
- IPA SHA-256：`aaf5dfc93ef85432b43649d52bc20d9440e76655609a2babdfa7e47446b009d3`。
- Signer SHA-256：`62e7580e4e86da3c0c5a015e89f2074bb8439ecc34148575ed3d88499a233704`；profile：`df12e579-3dec-4e63-b2df-86c5e2d37281`，有效至 `2027-07-20T01:28:32Z`。
- `codesign --verify --deep --strict` 通过；App Store profile 无设备名单或企业分发标记，`get-task-allow=false`；签名 entitlements 全部获得 profile 授权。
- Apple 构建 ID：`7cd09f01-51e5-4a12-8a15-562ed9437834`，处理状态为 `VALID`。
- 版本已绑定构建 27，提交前检查为 0 errors / 0 warnings；通过 `--dry-run` 后正式提交，submission ID：`ae53cb79-f05f-4e53-aaf1-a99954985923`，状态 `WAITING_FOR_REVIEW`。这不代表 Apple 已批准。

## 2026-10-09：1.2.2 / 构建 30 TestFlight 内部分发

- 初次准备的 1.2.1 / 构建 29 IPA 签名校验通过，但 ASC upload `d3cf9375-76d7-46a5-a23e-e8355185236b` 以错误码 `90186`、`90062` 处理失败。ASC 当前版本记录显示 1.2.1 为 `READY_FOR_SALE`，该预发布 train 已关闭；失败原因是版本 train，不是签名/profile。未重复上传构建 29。
- 最终 IPA：`/Users/guofeng/Downloads/PilotNest-1.2.2-30.ipa`；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.2 (30)`，Team ID `U8U443D7ZL`。
- IPA SHA-256：`b21b096f21fad81d319267de64287ac85607af7ee6e0439a15366884d534e63c`。
- Signer leaf DER SHA-256：`62e7580e4e86da3c0c5a015e89f2074bb8439ecc34148575ed3d88499a233704`；profile UUID：`df12e579-3dec-4e63-b2df-86c5e2d37281`，有效至 `2027-07-20T01:28:32Z`。IPA 内签名证书 DER 与 profile 内 DeveloperCertificates DER 相同。
- `codesign --verify --deep --strict` 通过；profile 的 `get-task-allow=false`、无设备名单、无企业分发标记；bundle/team/application identifier 一致，签名 entitlements 由 profile 授权。Xcode 自动导出因本机没有 Xcode 账户/profile 而失败，沿用本机重新验证过的有效 App Store profile 做一次性手动导出；仓库自动签名设置未更改。
- ASC Build ID：`e1dfded8-ae02-4474-9638-717d080e2be9`，处理状态 `VALID`，TestFlight `internalBuildState=IN_BETA_TESTING`。已核对内部组“内部”（`dbf86047-0ba9-4944-bc39-7c78e92b0cd8`，`isInternalGroup=true`、`hasAccessToAllBuilds=true`），build relationship 中包含此 Build ID。
- 仅加入现有内部 TestFlight 组；未提交 App Store Review，未发起外部 Beta Review，也未新增测试员。`VALID` 只表示构建处理成功，不代表 App Store 审核通过。

## 2026-10-09：1.2.2 / 构建 31 TestFlight 内部分发

- 最终 IPA：`/Users/guofeng/Downloads/PilotNest-1.2.2-31.ipa`；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.2 (31)`，Team ID `U8U443D7ZL`。
- IPA SHA-256：`ada87b8b47c34292af0bcab0472d6cdb0637abbc3e8482503c01cd493aa99915`。
- Signer leaf DER SHA-256：`62e7580e4e86da3c0c5a015e89f2074bb8439ecc34148575ed3d88499a233704`；profile UUID：`df12e579-3dec-4e63-b2df-86c5e2d37281`，有效至 `2027-07-20T01:28:32Z`。最终 IPA 的签名叶证书 DER 与 profile 内 `DeveloperCertificates[0]` 完全相同。
- `codesign --verify --deep --strict` 通过；profile 的 `get-task-allow=false`、无设备名单、无企业分发标记；bundle/team/application identifier 一致，签名 entitlements 由 profile 授权。`ITSAppUsesNonExemptEncryption=false`。Xcode 自动导出因本机没有 Xcode 账户/profile 而失败，使用重新验证过的有效 App Store profile 做一次性手动导出；仓库自动签名设置未更改。
- Generic iOS Simulator `build-for-testing` 编译通过（未启动模拟器或 App）；隔离 SwiftPM harness 对实际 `RemoteControlPreferences.swift` 与测试源码运行 8 项偏好排序纯测试，全部通过（0 failures）。
- ASC Build ID：`c2e84358-c900-4254-9db8-71c4eedfa263`，处理状态 `VALID`，内部测试状态 `IN_BETA_TESTING`，`autoNotifyEnabled=true`。已核对现有内部组“内部”（`dbf86047-0ba9-4944-bc39-7c78e92b0cd8`）的 build relationship 包含本次构建，中英文 What to Test 已更新并读回。
- 仅分发给现有内部组；未提交 App Store Review，未发起外部 Beta Review，也未新增测试员。`VALID` 表示构建处理成功，不代表 App Store 审核批准。

## 2026-10-09：1.2.2 / 构建 32 TestFlight 内部分发

- 最终 IPA：`/Users/guofeng/Downloads/PilotNest-1.2.2-32.ipa`；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.2 (32)`，Team ID `U8U443D7ZL`。
- IPA SHA-256：`b454bc4a041cf95c675fcd70d5e8805cf88999863b57b07dffdd2ccff91a7940`。
- Signer leaf DER SHA-256：`62e7580e4e86da3c0c5a015e89f2074bb8439ecc34148575ed3d88499a233704`；profile UUID：`df12e579-3dec-4e63-b2df-86c5e2d37281`，有效至 `2027-07-20T01:28:32Z`。IPA 签名叶证书 DER 与 profile 的 `DeveloperCertificates[0]` 完全相同；ASC 分发证书仍有效，serial `49C25FF7CF83CF4D27B7AC4B77D27A85`。
- `codesign --verify --deep --strict` 通过；bundle/team/application identifier 一致，profile 的 `get-task-allow=false`、无设备名单、无企业分发标记，签名 entitlements 由 profile 授权；`ITSAppUsesNonExemptEncryption=false`。Xcode 自动导出因本机无 Xcode 账户/profile 失败，使用重新核验过的有效 App Store profile 一次性手动导出，仓库自动签名设置未改。
- Generic iOS Simulator `build-for-testing` 编译通过（未启动模拟器或 App；仅有 `TrackpadContainerView.swift:47` 已知 LocalizedString 插值警告）；隔离 SwiftPM harness 对实际偏好模型、自动选择策略及两组测试运行 18 项纯测试，全部通过（0 failures）。
- ASC Build ID：`359ba3dd-d494-47a8-bf72-ff9948abe1d9`，处理状态 `VALID`，内部测试状态 `IN_BETA_TESTING`，`autoNotifyEnabled=true`；现有内部组“内部”的 build relationship 包含此构建。中英文 What to Test 已更新并读回。build 31 保留在原内部组中，没有移除或替换；未提交 App Store Review、未发起外部 Beta Review、未新增测试员。

## 2026-10-09：1.2.2 / 构建 33 TestFlight 内部分发

- 最终 IPA：`/Users/guofeng/Downloads/PilotNest-1.2.2-33.ipa`；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.2 (33)`，Team ID `U8U443D7ZL`。
- IPA SHA-256：`2b5f517df810189c8f0525c0705147d4bb59a51492a49a6994698b49eed73313`。
- Signer leaf DER SHA-256：`62e7580e4e86da3c0c5a015e89f2074bb8439ecc34148575ed3d88499a233704`；profile UUID：`df12e579-3dec-4e63-b2df-86c5e2d37281`，有效至 `2027-07-20T01:28:32Z`。最终 IPA 的签名叶证书 DER 与 profile 的 `DeveloperCertificates[0]` 完全相同；ASC 中对应 Apple Distribution 证书 serial `49C25FF7CF83CF4D27B7AC4B77D27A85`，有效期至同日。
- `codesign --verify --deep --strict` 通过；bundle/team/application identifier 一致，profile 的 `get-task-allow=false`、无设备名单、无企业分发标记，签名 entitlements 均由 profile 授权；`ITSAppUsesNonExemptEncryption=false`。Xcode 自动导出因本机没有 Xcode 账户/profile 报 `No Accounts / No profiles`，使用重新核验过的有效 App Store profile 做一次性手动导出；仓库自动签名设置未更改。
- 隔离 iOS Simulator 上的分区排序 UI 回归 2/2 通过：入口可从顶部工具栏打开，分区顺序及组内排序在重启后保留；未触发远控按键或屏幕控制。19 项纯偏好/自动切换策略测试全部通过（0 failures）。
- ASC Build ID：`7864f2b6-ca6d-4d93-b285-87300dea0adc`，处理状态 `VALID`，内部测试状态 `IN_BETA_TESTING`，`autoNotifyEnabled=true`。已核对现有内部组“内部”（`dbf86047-0ba9-4944-bc39-7c78e92b0cd8`，`isInternalGroup=true`、`hasAccessToAllBuilds=true`），group config 的 build relationship 包含本次构建；原 build 31、32 仍在组中。中英文 What to Test 已更新并读回。
- 仅使用现有内部组；未提交 App Store Review、未发起外部 Beta Review、未新增测试员。`VALID` 仅表示构建处理有效，不代表 App Store 审核批准。

## 2026-10-10：1.2.2 / 构建 34 签名与发布门禁

- 用户要求“翻页与导航”四个按键默认关闭，构建号增加到 34；没有提交构建 33 的 App Store 审核。其他功能默认值、已有隐藏偏好及排序保持不变。新增 append-only `remoteControl.enabledFeatures` 保存明确开启的选择，保存时仍向历史隐藏列表写入默认关闭项以兼容降级。
- 最终 IPA：`/Users/guofeng/Downloads/PilotNest-1.2.2-34.ipa`，bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.2 (34)`，Team `U8U443D7ZL`。
- IPA SHA-256：`c41d665154e863a78216313ddb33f29b47ea85bc42d88bf595c4ca3b331518e8`。深度严格签名与 ZIP 完整性校验通过，实际 signer 为 Apple Distribution；signer leaf 与 embedded profile 的证书 DER SHA-256 一致：`62e7580e4e86da3c0c5a015e89f2074bb8439ecc34148575ed3d88499a233704`。
- Profile UUID `df12e579-3dec-4e63-b2df-86c5e2d37281`，ASC profile 状态 `ACTIVE`、类型 `IOS_APP_STORE`，有效至 `2027-07-20`；app-id/team 一致，`get-task-allow=false`，没有设备名单或企业分发标记，签名 entitlements 为 profile 授权子集，`ITSAppUsesNonExemptEncryption=false`。ASC 证书 serial `49C25FF7CF83CF4D27B7AC4B77D27A85`、有效期同日。
- Release/generic iOS archive 成功。Automatic App Store export 实际尝试后因 `No Accounts / No profiles` 失败，再用任务临时目录中的一次性手动参数导出；仓库 automatic signing 配置不变，没有固定旧 profile UUID。
- 23 项纯测试（偏好 13、自动选择 10）及 3 项隔离 iPhone UI 回归全部通过。UI 验证四键初始关闭、Home 单独开启、重启后保留、再关闭；分区入口与分区/组内排序持久化同时通过。测试必须点击 Toggle 行里的真实子 Switch，而非整行中点或拖动手柄；首次失败是测试定位问题，产品 UI 未因此修改。
- Mac 安全测试 17 项、协议导航/命令纯测试 4 项通过；fresh Release `-Xswiftc -warnings-as-errors` 编译通过。只执行安全/mock 门禁，没有运行会触及真实屏幕状态的全量测试，也没有启动本机 MacPilot 或发送真实按键。
- Canonical `metadata/version/1.2.2` 中英文更新说明包含默认关闭与按需开启说明；description、keywords、marketing/support URL 沿用 1.2.1。`asc metadata validate` 为 0 errors / 0 warnings；公开隐私标签核验不等于读取或修改 ASC 隐私问卷。
- 本节记录发布门禁。处理有效、内部分发、等待审核、审核批准及上架必须分别以 ASC 中构建 34 的实际记录确认，不能由本地验签结果推断。

## 2026-10-13：1.2.2 / 构建 36 上传失败——版本 train 已关闭

- 目的是把「随航」功能发到 TestFlight。先按 1.2.2 / 构建 36 准备：IPA SHA-256 `2fe4e18d0e7b8435f994e391c25e06a044b3f9dd6887e76e555bcbee0e14dbde`，本地签名门禁全部通过（Apple Distribution、`codesign --verify --deep --strict`、profile `get-task-allow=false`、无设备名单、signer leaf DER 与 profile `DeveloperCertificates[0]` 一致）。
- ASC upload `a03aa768-5f59-43ce-a0f3-2ab488235723` 处理为 `FAILED`，错误码 `90186`、`90062`。原因不是签名：`asc versions list` 显示 **1.2.2 已变为 `READY_FOR_SALE`**，该预发布 train 已关闭，与 2026-10-09 构建 29 的失败同因。构建 36 在 ASC 中没有留下 build 记录。
- 结论与当时一致：`90186`/`90062` 要先查版本 train 状态，不要当成 profile 或证书问题重做签名。发 TestFlight 前应先确认目标 marketing version 在 ASC 里仍可编辑。

## 2026-10-13：1.2.3 / 构建 37 TestFlight 内部分发

- 新建版本 train：`asc versions create --version 1.2.3`，version id `62c45e31-2b58-42f6-b173-eb0ab45e5ee8`，状态 `PREPARE_FOR_SUBMISSION`；从 1.2.2 复制 description/keywords/marketingUrl/supportUrl/promotionalText（2 个 locale、8 项），不复制 `whatsNew`。1.2.2 仍是线上版本，未被改动。
- `project.yml`：`MARKETING_VERSION` 1.2.2 → 1.2.3，`CURRENT_PROJECT_VERSION` → 37；`xcodegen generate` 后生成项目仍为 `CODE_SIGN_STYLE=Automatic`、`DEVELOPMENT_TEAM=U8U443D7ZL`，没有固定任何 profile UUID。
- 最终 IPA：`/Users/guofeng/Downloads/PilotNest-1.2.3-37.ipa`（2,486,549 字节）；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.3 (37)`，Team `U8U443D7ZL`，`MinimumOSVersion=17.0`，`ITSAppUsesNonExemptEncryption=false`。ZIP 完整性无错误。
- IPA SHA-256：`1c33ee2460488bb3014007f9babec94af7f55c0231bedb9b22a179073d8f8ece`。
- Signer leaf DER SHA-256：`c9f379c6ec0ebf40e7fd5c3034849bc40b466c3ab78a595b3de09f81d2d17040`，serial `7A601D1A847C8DD6EC50DBE3A7CECACC`，有效期 2026-09-06 → 2027-09-06；ASC 证书 id `J4Z29X3RMS`、类型 `DISTRIBUTION`，仍在证书列表中（未撤销）。这与历史记录里的 `62e7580e…`/serial `49C25FF7…` 是**不同证书**，两者都在本 profile 的 `DeveloperCertificates` 中（共 3 张）。
- Profile：UUID `b6b2e034-9cf1-4475-8cc9-dda1fff53fe7`，名称 `iOS Team Store Provisioning Profile: com.misswell.macpilot.remote`，`IsXcodeManaged=true`，创建于 2026-09-12，有效至 2027-09-06，Platform `iOS/xrOS/visionOS`。Apple 签名的 CMS 属性中 `ProfileDistributionType=STORE`；`get-task-allow=false`、`beta-reports-active=true`、无 `ProvisionedDevices`、无 `ProvisionsAllDevices`；app-id/team 一致；4 项签名 entitlements 全部由 profile 授权且取值一致。
- **Xcode-managed profile 不会出现在 `asc profiles list` 中**（该接口只返回手工创建的 profile，本次 12 条里没有它）。因此改用密码学验证代替 ASC 查表：`openssl cms -verify` 以 macOS 系统钥匙串里的 Apple Root CA 为信任锚，对 `embedded.mobileprovision` 返回 `CMS Verification successful`；把内容改一个字节后同一命令返回 `CMS Verification failure`，证明该检查有效。注意 `security cms -D` **只解码不验签**，篡改样本同样返回 0，不能用它作为完整性证据。
- 本次 automatic export **成功**（`xcodebuild -exportArchive -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates`，method `app-store-connect`），不再需要构建 27–34 时的一次性手动导出；仓库自动签名设置未改。无嵌套扩展或 framework，单一 arm64 二进制。
- 测试：iOS Simulator `test-without-building` 全量 59 项 / 11 suites 通过（含 `SidecarPanelPolicyTests` 11 项）；`swift test --filter Sidecar` 24 项 / 2 suites 通过。Release archive 与 Debug `build-for-testing` 编译均成功，仅剩既有告警（`RemoteVideoDecoder.swift` 的 Swift 6 并发告警、`TrackpadContainerView.swift:47` 的 LocalizedString 插值告警），非本次改动引入。
- 二进制中确认包含随航实现（`SidecarDeviceSheet`、`RemoteSidecarSnapshot`、`connectSidecar`、`disconnectSidecar`、`MacPilotRemote.lastSidecarDevice.` 等 105 处 Sidecar 相关字符串）。
- ASC Build ID：`93bb79f0-af61-4f17-a4c8-d1a91bd32330`，处理状态 `VALID`，`internalBuildState=IN_BETA_TESTING`，`autoNotifyEnabled=true`，`externalBuildState=READY_FOR_BETA_SUBMISSION`。内部组“内部”（`dbf86047-0ba9-4944-bc39-7c78e92b0cd8`，`isInternalGroup=true`、`hasAccessToAllBuilds=true`）的 builds relationship 包含此构建（组内共 34 个构建）；`asc publish testflight` 因该组已自动接收全部构建而跳过显式添加。
- 中英文 What to Test 已写入并读回（zh-Hans 370 字、en-US 1029 字），内容为随航的测试要点而非营销文案。
- Canonical `metadata/version/1.2.3/{en-US,zh-Hans}.json` 已按 1.2.2 沿用 description/keywords/marketing/support URL 并新写 `whatsNew`；`asc metadata validate` 为 0 errors / 0 warnings。**未执行 `asc metadata push`**，ASC 上 1.2.3 的 `whatsNew` 仍为空。
- 仅分发给现有内部组；未提交 App Store Review、未发起外部 Beta Review、未新增测试员、未把构建 37 附加到 1.2.3 版本。`VALID` 与 `IN_BETA_TESTING` 都不代表 Apple 已审核批准。

## 2026-10-13：1.2.3 / 构建 38 TestFlight 内部分发

- 目的是把「首页随航行跟着用户开关走」的改动发到手机。上传前 `asc versions list` 确认 **1.2.3 仍为 `PREPARE_FOR_SUBMISSION`**（train 可编辑），`project.yml` 的 `CURRENT_PROJECT_VERSION` 37 → 38、`MARKETING_VERSION` 保持 1.2.3；`xcodegen generate` 后生成项目仍是 `CODE_SIGN_STYLE=Automatic`、`DEVELOPMENT_TEAM=U8U443D7ZL`，没有固定任何 profile UUID。
- 最终 IPA：`/Users/guofeng/Downloads/PilotNest-1.2.3-38.ipa`（2,488,379 字节）；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.3 (38)`，Team `U8U443D7ZL`，`MinimumOSVersion=17.0`，`ITSAppUsesNonExemptEncryption=false`。单一 arm64 二进制，无嵌套扩展或 framework。`unzip -t` 无错误。
- IPA SHA-256：`8b5c1682cd4fd04b94285fcfe2429022ee9aaaa619935a5d79d49861cd2a204e`。
- `codesign --verify --deep --strict`：`valid on disk` + `satisfies its Designated Requirement`；`Authority=Apple Distribution: Guofeng Liu (U8U443D7ZL)`，`TeamIdentifier=U8U443D7ZL`。
- Signer leaf DER SHA-256：`c9f379c6ec0ebf40e7fd5c3034849bc40b466c3ab78a595b3de09f81d2d17040`，serial `7A601D1A847C8DD6EC50DBE3A7CECACC`，有效期 2026-09-06 → 2027-09-06。它等于 profile 的 `DeveloperCertificates[0]`（该 profile 共 3 张证书：`c9f379c6…`、`62e7580e…`、`d6c4e2d8…`）；与构建 37 是同一张分发证书。
- Profile：UUID `b6b2e034-9cf1-4475-8cc9-dda1fff53fe7`，名称 `iOS Team Store Provisioning Profile: com.misswell.macpilot.remote`，`IsXcodeManaged=true`，创建 2026-09-12，有效至 2027-09-06。签名 entitlements 四项（`application-identifier`、`beta-reports-active=true`、`com.apple.developer.team-identifier`、`get-task-allow=false`）全部是 profile `Entitlements` 的子集且取值一致；顶层无 `ProvisionedDevices`、无 `ProvisionsAllDevices`。
- App Store 类型的密码学证明分两层，都要验：外层 `embedded.mobileprovision` 用 `openssl cms -verify -inform DER -CAfile <SystemRootCertificates 里的 Apple Root CA> -purpose any` 返回 **CMS Verification successful**；其认证内容里的 `DER-Encoded-Profile`（`plutil -extract … raw` 给出的是单行 base64，必须用 `openssl base64 -d -A`，默认的 MIME 模式会静默产出 0 字节）再验一次同样 successful，而这段**已认证字节**中 `ProfileDistributionType=STORE`。反向对照：把 profile 中间一个字节改成 `0x41`，外层同一命令报 `CMS_SignerInfo_verify_content: verification failure`——所以这个检查真的有牙。`security cms -D` 依旧只解码不验签，不能当完整性证据。
- 二进制内容确认：Sidecar 相关字符串 109 处；新文案按 UTF-8 字节搜索各命中 1 处（`这台 Mac 没有提供随航。`、`重新连接后会再问一次`、`This Mac does not offer Sidecar.`）。注意 `strings -a` 只提取 ASCII 序列，用它找中文必然 0 命中，不能据此断言文案缺失。
- 本轮只增构建号，代码与提交 `e38749b` 相同。上传后对 build 38 的生成项目重跑手机端全量单元测试：**61 项 / 11 suites 通过**（`Test run with 61 tests in 11 suites passed`，`** TEST SUCCEEDED **`）。那一轮的 XCUITest `testSidecarRowStaysOnTheHomePageAndNamesWhyItCannotRun` 9.039 秒通过，且把 `HomeView` 的旧过滤器加回去后它在 27.311 秒失败于 `ControlSectionOrderUITests.swift:164/168`。
- ASC Build ID：`b40ef635-2a63-4a1f-b327-2fd87431bc13`，`processingState=VALID`，`internalBuildState=IN_BETA_TESTING`，`autoNotifyEnabled=true`，`externalBuildState=READY_FOR_BETA_SUBMISSION`。内部组「内部」（`dbf86047-0ba9-4944-bc39-7c78e92b0cd8`，`isInternalGroup=true`、`hasAccessToAllBuilds=true`）自动接收该构建，`asc publish testflight` 因此跳过显式添加。中英文 What to Test 已写入并读回（zh-Hans 576 字、en-US 1507 字；措辞按真实轮询节奏改写：面板开着且有操作进行中每秒一次，列表静止时每 3 秒一次）。
- 仅分发给现有内部组；未提交 App Store Review、未发起外部 Beta Review、未新增测试员、未把构建 38 附加到 1.2.3 版本，也未执行 `asc metadata push`。`VALID` 与 `IN_BETA_TESTING` 都不代表 Apple 已审核批准。**真机 iPhone 上的画面仍未实测**：显示规则与那一屏文案是在模拟器 XCUITest 里证明的。

## 2026-10-13：1.2.3 / 构建 39 TestFlight 内部分发

- 目的是把「随航入口默认关闭、由用户手动开启」发到手机，并与 MacPilot `v1.2.1-beta.18`（标签指向 `c2643a7`）配套：那一版把 `sidecarHosting`/`dockGroupsHosting` 提升为 `RemoteConnectionHost` 的协议要求，修掉协议扩展静态派发导致 Mac 端从不通告 `sidecar` 能力的问题；Mac 修复不到位的话，手机端会如实显示「这台 Mac 上的 MacPilot 没有随航功能」。
- 上传前 `asc versions list` 确认 **1.2.3 仍为 `PREPARE_FOR_SUBMISSION`**（train 可编辑，本轮是该 train 的第三次上传，前两次为构建 37/38）；`project.yml` 的 `CURRENT_PROJECT_VERSION` 38 → 39、`MARKETING_VERSION` 保持 1.2.3；`xcodegen generate` 后生成项目仍是 `CODE_SIGN_STYLE=Automatic`、`DEVELOPMENT_TEAM=U8U443D7ZL`，无固定 profile UUID。
- 最终 IPA：`/Users/guofeng/Downloads/PilotNest-1.2.3-39.ipa`（2,492,576 字节）；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.3 (39)`，Team `U8U443D7ZL`，`MinimumOSVersion=17.0`，`ITSAppUsesNonExemptEncryption=false`。单一 arm64 二进制，无 `Frameworks/`、无 `PlugIns/`、无嵌套扩展；`unzip -t` 输出 `No errors detected`。
- IPA SHA-256：`55ccc50c0212dbf2d4bd563556fa8bcdc2b4f1c5c17f7c614def7fa8313148cf`。
- `codesign --verify --deep --strict`：`valid on disk` + `satisfies its Designated Requirement`；`Authority=Apple Distribution: Guofeng Liu (U8U443D7ZL)`；`TeamIdentifier=U8U443D7ZL`。
- Signer leaf DER SHA-256：`c9f379c6ec0ebf40e7fd5c3034849bc40b466c3ab78a595b3de09f81d2d17040`，serial `7A601D1A847C8DD6EC50DBE3A7CECACC`，有效期 2026-09-06 → 2027-09-06。它等于 profile 的 `DeveloperCertificates[0]`；该 profile 共 3 张证书（`c9f379c6…`、`62e7580e…`、`d6c4e2d8…`），与构建 37/38 同一张分发证书。
- Profile：UUID `b6b2e034-9cf1-4475-8cc9-dda1fff53fe7`，名称 `iOS Team Store Provisioning Profile: com.misswell.macpilot.remote`，`IsXcodeManaged=true`，创建 2026-09-12，有效至 2027-09-06。签名 entitlements 四项（`application-identifier`、`beta-reports-active=true`、`com.apple.developer.team-identifier`、`get-task-allow=false`）全部是 profile `Entitlements` 的子集且取值一致；顶层无 `ProvisionedDevices`、无 `ProvisionsAllDevices`。
- 两层 `openssl cms -verify` 均通过：外层 `embedded.mobileprovision` 返回 `CMS Verification successful`；内层 `DER-Encoded-Profile` 同样 successful，且这段**已认证字节**中 `ProfileDistributionType=STORE`、`Platform=iOS/xrOS/visionOS`（内层不是 plist 而是 Apple 的 DER 形式 profile，`plutil -p` 读不了，用 `grep -aob` 在已认证 DER 里定位）。反向对照：翻转 profile 中间一字节后同一命令以退出码 4、`CMS_SignerInfo_verify_content: verification failure` 失败。`security cms -D` 依旧只解码不验签，不作为完整性证据。
- 本次 automatic export **成功**（`xcodebuild -exportArchive -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates`），无需构建 27–34 时的手工导出；仓库自动签名设置未改。
- 本批代码改动（相对 origin/main 的 5 个提交）：`sidecar` 进入 `isEnabledByDefault=false` 的 opt-in 集合（首页入口默认不出现，在「设置 → 控制功能 → 屏幕操作」手动开启，并把选择 mirror 进历史 `remoteControl.hiddenFeatures` key）；不支持随航的 Mac 文案改为「这台 Mac 上的 MacPilot 没有随航功能」；`RemoteText.value(_:language:)` 显式语言接缝与 27 个随航键的中英对照测试。
- 合并树（`832032a` + 本批提交）上的 Mac 侧门禁：`swift test --filter Sidecar` 29/3、`--filter Remote` 125/25、`--filter QuickSearch` 124/15、`--filter CarbonHotKey` 3/1、`--filter SoftwareUpdate` 28/4、`ConfigurationSchemaContractTests` 4/1、`ConfigStoreTests` 2/1、协议包 91/16 全部通过；`swift build -c release -Xswiftc -warnings-as-errors` 通过（152.68 秒）。
- 手机端：build 39 生成项目上 `xcodebuild test -only-testing:MacPilotRemoteTests`（iPhone 17e 模拟器，booted）**65 项 / 12 suites 通过**（`Test run with 65 tests in 12 suites passed`，`** TEST SUCCEEDED **`）。本批 iOS 源码即上一轮做过双重反向对照（默认值改回开启 → 单元 5 红、XCUITest 169/177/181/186/190 行红）的同一内容；`testSidecarRowAppearsOnlyOnceTheUserEnablesIt` 在那一轮 25.264 秒通过。
- ASC Build ID：`18474352-73f7-428f-8f1e-9a1e481df94d`，`processingState=VALID`，`internalBuildState=IN_BETA_TESTING`，`autoNotifyEnabled=true`，`externalBuildState=READY_FOR_BETA_SUBMISSION`。内部组「内部」（`dbf86047-0ba9-4944-bc39-7c78e92b0cd8`，`isInternalGroup=true`、`hasAccessToAllBuilds=true`）自动接收该构建，`asc publish testflight` 因此跳过显式添加。中英文 What to Test 已写入并读回（zh-Hans 448 字、en-US 1164 字）。
- 仅分发给现有内部组；未提交 App Store Review、未发起外部 Beta Review、未新增测试员、未把构建 39 附加到 1.2.3 版本，也未执行 `asc metadata push`。`VALID` 与 `IN_BETA_TESTING` 都不代表 Apple 已审核批准。**真机 iPhone/iPad 上的画面与实际随航连接仍未实测**：默认关闭、开启后入口出现、不支持 Mac 的文案，都是在模拟器 XCUITest 里证明的。

## 2026-10-13（同日稍后）：1.2.3 metadata 推送与构建 39 的外部 Beta Review

上一节记录的是**上传当时**的状态（仅内部组、未推 metadata、未发起外部 Review）。同一轮稍后补上了后两件，App Store Review 仍未提交。

- **前置检查**：`asc versions list --app 6811335132 --platform IOS` 确认 1.2.3 仍是 `PREPARE_FOR_SUBMISSION`（可编辑 train），1.2.2／1.2.1／1.2.0 均为 `READY_FOR_DISTRIBUTION`——已 `READY_FOR_SALE` 的 train 再传会撞 90186/90062。
- **metadata 推送**：先 `asc metadata push --app 6811335132 --version 1.2.3 --platform IOS --dir metadata --dry-run`，计划为 **2 条 adds（zh-Hans 与 en-US 的 `whatsNew`）、0 updates、0 deletes**，即纯新增、不覆盖任何既有字段；确认后才去掉 `--dry-run` 真跑（未使用 `--allow-deletes`）。
- **读回判据**：推送后再 dry-run 一次，`adds=0 / updates=0 / deletes=0`。远端读回为空差异才算「推上去了」；仓库里改了 `metadata/version/1.2.3/*.json` 本身不构成证据。
- **外部组**：`asc testflight groups list` 给出内部组 `dbf86047-0ba9-4944-bc39-7c78e92b0cd8`（`isInternalGroup=true`）与外部组 `bd37fc5a-05d4-4e9c-bff5-510559085da5`（公开链接 `https://testflight.apple.com/join/zMkmV3dh`，`publicLinkEnabled=true`）。
- **提交 Beta Review**：`asc builds add-groups --build-id 18474352-73f7-428f-8f1e-9a1e481df94d --group bd37fc5a-05d4-4e9c-bff5-510559085da5 --submit --confirm`，返回 added 1 group + submitted。
- **状态读回**：`asc status --app 6811335132` → `testflight.betaReviewState=WAITING_FOR_REVIEW`、`submittedDate=2026-10-13T07:08:30-07:00`；`appstore.state` 仍是 `PREPARE_FOR_SUBMISSION`，`submission.inFlight=false`。`WAITING_FOR_REVIEW` 只代表排队，**不代表 Apple 已批准**。
- **未做**：未提交 App Store Review、未新增测试员、未把构建 39 附加到 1.2.3 版本对象、未改签名或 provisioning 设置（本轮 automatic export 正常，无需回到构建 27–34 的手工导出路径）。
- **装机分布拿不到**：`asc testflight metrics group-testers` 对内部组与外部组都返回 `attributes:null`，`client hello` 日志也不带手机端构建号，因此**无法从服务端证明用户手机上装的是 build 38 还是 39**。要确认只能在手机 TestFlight 上看 `1.2.3 (39)`。真机画面（默认关闭、入口出现、iPad 实际成为扩展显示）仍未实测。

## 2026-10-15：1.2.3 / 构建 39 提交 App Store Review

用户指令「IOS版发布新版本提交审核」授权本轮提交，本节补上上一节遗留的「未提交 App Store Review」。

- **前置读回**：`asc versions list --app 6811335132` → 1.2.3 `PREPARE_FOR_SUBMISSION`（train 可编辑），1.2.2/1.2.1/1.2.0 `READY_FOR_DISTRIBUTION`。两条本地化（zh-Hans `74866d93-b0a9-4d09-bd74-a7b674d06bd0`、en-US `858a24d8-4daf-435d-a73e-68e3a8a24091`）的 `whatsNew` 已在 2026-10-13 推送，与仓库 canonical `metadata/version/1.2.3/*.json` 一致，本轮无需再 push。
- **截图审计与一次自纠错**：四个截图集（zh-Hans/en-US × `APP_IPAD_PRO_3GEN_129`/`APP_IPHONE_67`）本来各已有 3 张与线上 1.2.2 `sourceFileChecksum` 完全一致的截图（如 zh iPad `b986716382bc`/`b01fc8e302a8`/`cfa5445cc28b`），本无需补传。此前把 `asc screenshots list` JSON 的顶层 key 误当作 `data`（真实 key 是 `sets`），解析出「0 个 set」，基于这个假前提从线上 1.2.2 下载并多传了 12 张重复截图（每集 6 张）。发现后逐一 `asc screenshots delete --id <asset-id> --confirm` 删除，复查四集恢复为每集 3 张、`assetDeliveryState.state=COMPLETE`、`sourceFileChecksum` 与线上 1.2.2 相同。教训：解析 ASC JSON 前先看原始输出结构；「缺截图」这类阻塞性结论必须用原始 response 复核一遍。
- **提交 dry-run**：`asc review submit --app 6811335132 --version-id 62c45e31-2b58-42f6-b173-eb0ab45e5ee8 --build 18474352-73f7-428f-8f1e-9a1e481df94d --dry-run` → `wouldAttach=true`、`wouldSubmit=true`、无错误。
- **正式提交与两次服务端报错**：`--confirm` 在最后一步 PATCH 报 `context deadline exceeded`；复查发现构建已挂上、reviewSubmission `633caf40-d35b-4a5c-8939-3c6316dd191f` 已创建为 `READY_FOR_REVIEW`（attach-build 与 items-add 已生效，只差最后一步 submit）。补跑 `asc review submissions-submit --id 633caf40-d35b-4a5c-8939-3c6316dd191f --confirm` 返回 HTTP 500，再次读回却显示提交已生效——**ASC 的超时/500 不能用来判断操作是否生效，唯一依据是读回状态；也不能因报错盲目重试**，两次报错都发生在服务端已经应用之后。
- **最终读回（提交成功的证据）**：版本 1.2.3 `state=WAITING_FOR_REVIEW`；reviewSubmission `633caf40-d35b-4a5c-8939-3c6316dd191f` `state=WAITING_FOR_REVIEW`、`submittedDate=2026-10-15T14:13:03.13Z`；`asc builds links view --build-id 18474352-73f7-428f-8f1e-9a1e481df94d --type appStoreVersion` → `62c45e31-...`，证明挂载的就是构建 39；`nextAction=Wait for App Store review outcome`。`WAITING_FOR_REVIEW` 只代表已排队，**不代表 Apple 已批准**。
- **未做**：未改签名/provisioning/export 设置；未新增测试员；未动已发布的 tag。真机画面（默认关闭、开启后入口出现、iPad 实际随航）仍未实测。

## 2026-10-19：1.2.4 / 构建 40 TestFlight 内部分发

- 目的是把「Mac 通过 GATT 读取手机发布的临时身份令牌」这版配套 PilotNest 发到手机，修复 BLE 解锁始终找不到设备的问题。上传前 `asc versions list` 确认 1.2.3 已 `READY_FOR_SALE`，新建 1.2.4 train（`370852c7-a324-4a15-9223-132b1471911d`，创建于 2026-10-18T23:22:42-07:00，状态 `PREPARE_FOR_SUBMISSION`）；`project.yml` 的 `MARKETING_VERSION` 1.2.4、`CURRENT_PROJECT_VERSION` 40，未固定任何 profile UUID。
- 最终 IPA：`/tmp/PilotNest-export-40/PilotNest.ipa`（2,505,335 字节）；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.4 (40)`，Team `U8U443D7ZL`，`MinimumOSVersion=17.0`，`ITSAppUsesNonExemptEncryption=false`。单一 arm64 二进制，无 `Frameworks/`、`PlugIns/`、嵌套扩展或 framework；`unzip -t` → `No errors detected`。
- IPA SHA-256：`b9bb38a82e7ed2eaa32ed792c16b0906858b87e9db044f671cca0b5c024ab9b9`。
- `codesign --verify --deep --strict`：`valid on disk` + `satisfies its Designated Requirement`；`Authority=Apple Distribution: Guofeng Liu (U8U443D7ZL)`，`TeamIdentifier=U8U443D7ZL`。
- Signer leaf DER SHA-256：`62e7580e4e86da3c0c5a015e89f2074bb8439ecc34148575ed3d88499a233704`，serial `49C25FF7CF83CF4D27B7AC4B77D27A85`，有效期 2026-07-20 → 2027-07-20。与构建 37–39 使用的 `c9f379c6…` 是同一开发者账号下的另一张 Apple Distribution 证书。
- Profile 与构建 39 不同：UUID `df12e579-3dec-4e63-b2df-86c5e2d37281`，名称 `PilotNest App Store 1.0.2 (8)`，`IsXcodeManaged=false`，创建 2026-09-24、有效至 2027-07-20。它只含一张 `DeveloperCertificates[0]`，DER SHA-256 正是签名 leaf `62e7580e…`（签名证书与 profile 完全匹配）；顶层无 `ProvisionedDevices`、无 `ProvisionsAllDevices`。签名 entitlements 四项（`application-identifier`、`beta-reports-active=true`、`com.apple.developer.team-identifier`、`get-task-allow=false`）全部是 profile `Entitlements` 的子集且取值一致。
- 两层 `openssl cms -verify` 均返回 `CMS Verification successful`：外层 `embedded.mobileprovision`（exit 0）与内层 `DER-Encoded-Profile` 均通过；已认证的内层 DER 中 `ProfileDistributionType` 的值为 `STORE`、`Platform=iOS/xrOS/visionOS`。反向对照：翻转 profile 中间一字节后同一命令 exit 4（`CMS_SignerInfo_verify_content: verification failure`）；`security cms -D` 仍只解码不验签。
- ASC Build ID：`b2158c8a-8e38-4ef4-82a6-4af8e47e6216`，`processingState=VALID`，`internalBuildState=IN_BETA_TESTING`，`autoNotifyEnabled=true`，`externalBuildState=READY_FOR_BETA_SUBMISSION`。内部组「内部」（`dbf86047-0ba9-4944-bc39-7c78e92b0cd8`，`isInternalGroup=true`、`hasAccessToAllBuilds=true`）自动接收该构建。中英文 What to Test 已写入并读回（en-US 593 字符、zh-Hans 259 字符），要求把 MacPilot 升级到 `1.2.2-beta.18` 后验证 iPhone UUID 被学习为别名，以及靠近/离开的自动解锁与锁定。
- 仅分发给现有内部组；未提交 App Store Review、未发起外部 Beta Review、未新增测试员、未把构建 40 附加到 1.2.4 版本，也未执行 `asc metadata push`。`VALID` 与 `IN_BETA_TESTING` 都不代表 Apple 已审核批准。**真机 iPhone 上的 GATT 令牌读取与自动解锁仍未实测**。

## 2026-10-19：1.2.4 / 构建 41 TestFlight 内部分发

- 目的是修复「BLE 解锁在 PilotNest 退到后台或 Wi-Fi 远控胜出后找不到手机」：手机端把 Mac 的 BLE 解锁绑定（hello 中的 `bleIdentityLearning`）持久化为 `wantsBLEProximity`，只要有这种 Mac 就在后台继续广播，但后台不建立 L2CAP 控制会话；Mac 端在已经打开的 GATT 链路上直接、限次重读身份令牌（手机在 ack 之后才写入 token），且身份学习不再拆掉已交付的 L2CAP 控制链路。
- 上传前 `asc versions list` 确认 1.2.4 train（`370852c7-a324-4a15-9223-132b1471911d`）仍为 `PREPARE_FOR_SUBMISSION`；`project.yml` 的 `MARKETING_VERSION` 保持 1.2.4、`CURRENT_PROJECT_VERSION` 40 → 41；`xcodegen generate` 后生成项目仍为 `CODE_SIGN_STYLE=Automatic`、`DEVELOPMENT_TEAM=U8U443D7ZL`，没有固定任何 profile UUID。
- 最终 IPA：`/tmp/PilotNest-export-41/PilotNest.ipa`（2,503,551 字节）；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.4 (41)`，Team `U8U443D7ZL`，`MinimumOSVersion=17.0`，`ITSAppUsesNonExemptEncryption=false`。单一 arm64 二进制，无 `Frameworks/`、`PlugIns/`、嵌套扩展或 framework；`unzip -t` → `No errors detected`。
- IPA SHA-256：`5df2ce2b73cb9cd3e39ecdca237bd579d9c063074d8f34fcf8e0b8edaadcbdc1`。
- `codesign --verify --deep --strict`：`valid on disk` + `satisfies its Designated Requirement`；`Authority=Apple Distribution: Guofeng Liu (U8U443D7ZL)`，`TeamIdentifier=U8U443D7ZL`。
- Signer leaf DER SHA-256：`c9f379c6ec0ebf40e7fd5c3034849bc40b466c3ab78a595b3de09f81d2d17040`，serial `7A601D1A847C8DD6EC50DBE3A7CECACC`，有效期 2026-09-06 → 2027-09-06；等于 profile 的 `DeveloperCertificates[0]`（该 profile 共 3 张证书：`c9f379c6…`、`62e7580e…`、`d6c4e2d8…`）。
- Profile：UUID `b6b2e034-9cf1-4475-8cc9-dda1fff53fe7`，名称 `iOS Team Store Provisioning Profile: com.misswell.macpilot.remote`，`IsXcodeManaged=true`，创建 2026-09-12，有效至 2027-09-06，Platform `iOS/xrOS/visionOS`。签名 entitlements 四项（`application-identifier`、`beta-reports-active=true`、`com.apple.developer.team-identifier`、`get-task-allow=false`）全部是 profile `Entitlements` 的子集且取值一致；顶层无 `ProvisionedDevices`、无 `ProvisionsAllDevices`。
- 两层 `openssl cms -verify` 均返回 `CMS Verification successful`；已认证的内层 DER 中 `ProfileDistributionType=STORE`。反向对照：翻转 `embedded.mobileprovision` 中间一字节后同一命令报 `CMS_SignerInfo_verify_content: verification failure`；`security cms -D` 仍只解码不验签。本次 automatic App Store Connect export 成功，使用 Xcode-managed profile，仓库自动签名设置未改。
- 测试：iOS Simulator 71 项 / 13 suites 通过（含 6 项新增的广播策略与 `wantsBLEProximity` 持久化测试）；Mac 定向 `RemoteControlTests` + `RemoteBLEBackoffTests` 54 项 / 10 suites 通过；Mac 全量 1436 项 / 162 suites 仅 6 项失败，全部属于 AGENTS.md 已记录的 wall-clock/主线程饥饿 flake（`CPUMonitorTests.samplerReportsAFullyBusyCoreAtItsRealShare`、`BLEWakeRecoveryTests.overdueSignalTimeoutClearsThePreSleepPresence`、`ScreenCaptureTests.quickCopyAutoSaveWritesFileAndRecordsStats`、`ScreenCaptureTests.startupShortcutRegistrationRetriesTransientFailure`、`RemoteVideoTransportTests.independentVideoSocketAuthenticatesAndRejectsAQueuedFrameBacklog`、`PictureInPictureTests.stalledCaptureStateAppearsAfterMotionStopsAndClearsOnChange`），无新增回归；fresh Release `-Xswiftc -warnings-as-errors` 构建通过。
- ASC Build ID：`de531f7f-0ea4-4fa5-800b-20f66909f3f8`，`processingState=VALID`，`internalBuildState=IN_BETA_TESTING`，`autoNotifyEnabled=true`，`externalBuildState=READY_FOR_BETA_SUBMISSION`。内部组「内部」（`dbf86047-0ba9-4944-bc39-7c78e92b0cd8`，`isInternalGroup=true`、`hasAccessToAllBuilds=true`）的 builds relationship 包含本次构建（共 38 个）；`asc publish testflight` 跳过显式添加。中英文 What to Test 已写入并读回（zh-Hans 286 字符、en-US 619 字符），要求把 MacPilot 升级到 `1.2.2-beta.20` 后验证后台/锁屏仍能被 BLE 解锁发现、网络切换后的靠近解锁与离开锁定，以及后台不建立远控会话。
- 仅分发给现有内部组；未提交 App Store Review、未发起外部 Beta Review、未新增测试员、未把构建 41 附加到 1.2.4 版本，也未执行 `asc metadata push`。`VALID` 与 `IN_BETA_TESTING` 都不代表 Apple 已审核批准。**真机 iPhone 上的后台广播与自动解锁仍未实测**；本轮验证覆盖策略/持久化/编译与签名门禁。

## 2026-10-20：1.2.4 / 构建 42 TestFlight 内部分发

- 目的是修复「iOS 轮换 BLE 地址后 Mac 只在前台 claim 时才会学习，口袋里的手机永远解锁不了」：Mac 通过新增的 GATT 特征写入 `version ‖ nonce ‖ Mac UUID`，手机用长期配对密钥返回 HMAC-SHA256，Mac 验证后把刚观察到的地址学习为别名；认证只证明身份，解锁仍要求 RSSI 越过阈值。配套 Mac 版本为 `1.2.2-beta.24`。
- 上传前 `asc versions list` 确认 1.2.4 train（`370852c7-a324-4a15-9223-132b1471911d`）仍为 `PREPARE_FOR_SUBMISSION`；`project.yml` 的 `MARKETING_VERSION` 保持 1.2.4、`CURRENT_PROJECT_VERSION` 41 → 42；`xcodegen generate` 后生成项目仍为 `CODE_SIGN_STYLE=Automatic`、`DEVELOPMENT_TEAM=U8U443D7ZL`，没有固定任何 profile UUID。
- 最终 IPA：`/tmp/PilotNest-export-42/PilotNest.ipa`（2,520,006 字节）；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.4 (42)`，Team `U8U443D7ZL`，`MinimumOSVersion=17.0`，`ITSAppUsesNonExemptEncryption=false`。单一 arm64 二进制，无 `Frameworks/`、`PlugIns/`、嵌套扩展或 framework；`unzip -t` → `No errors detected`。
- IPA SHA-256：`3213226a135db734a353cc110e3cc12401513eb70e87a29bf889c056ce0c111d`。
- `codesign --verify --deep --strict`：`valid on disk` + `satisfies its Designated Requirement`；`Authority=Apple Distribution: Guofeng Liu (U8U443D7ZL)`，`TeamIdentifier=U8U443D7ZL`。
- Signer leaf DER SHA-256：`62e7580e4e86da3c0c5a015e89f2074bb8439ecc34148575ed3d88499a233704`，与 profile 的 `DeveloperCertificates[0]` 完全相同。
- Profile：UUID `df12e579-3dec-4e63-b2df-86c5e2d37281`，名称 `PilotNest App Store 1.0.2 (8)`，`IsXcodeManaged=false`，有效至 2027-07-20；bundle/team/application identifier 一致，`get-task-allow=false`，顶层无 `ProvisionedDevices`、无 `ProvisionsAllDevices`，签名 entitlements 四项均由 profile 授权。
- 两层 `openssl cms -verify` 均返回 `CMS Verification successful`（CAfile 由系统钥匙串导出的 Apple Root CA + WWDR 组成）；已认证的内层 DER 中 `ProfileDistributionType=STORE`、Platform `iOS/xrOS/visionOS`。反向对照：翻转 profile 中间一字节后同一命令报 `CMS_SignerInfo_verify_ex: verification failure`。本次 automatic export 因本机 `No Accounts / No profiles` 失败，使用任务临时目录中的一次性手动参数导出（profile 未写入仓库）。
- ASC Build ID：`2d6405ff-0af3-424d-bf66-67588bc7e37a`，`processingState=VALID`，`internalBuildState=IN_BETA_TESTING`，`autoNotifyEnabled=true`，`externalBuildState=READY_FOR_BETA_SUBMISSION`。内部组「内部」（`dbf86047-0ba9-4944-bc39-7c78e92b0cd8`，`isInternalGroup=true`、`hasAccessToAllBuilds=true`）自动接收该构建。中英文 What to Test 已写入并读回（zh-Hans 191 字符、en-US 382 字符）。
- 仅分发给现有内部组；未提交 App Store Review、未发起外部 Beta Review、未新增测试员、未把构建 42 附加到 1.2.4 版本，也未执行 `asc metadata push`。`VALID` 与 `IN_BETA_TESTING` 都不代表 Apple 已审核批准。**真机 iPhone 上的后台挑战应答与自动解锁仍未实测**；本轮验证覆盖策略、协议、编译与签名门禁。

## 2026-10-21：1.2.4 / 构建 42 提交 App Store Review

用户指令「PilotNest 发版审核」授权本轮提交；本次直接使用已存在于 TestFlight 的构建 42，没有重新打包或上传 IPA。

- **前置读回**：`asc versions list --app 6811335132 --platform IOS` → 1.2.4（`370852c7-a324-4a15-9223-132b1471911d`）`PREPARE_FOR_SUBMISSION`，train 可编辑；1.2.3 及更早均为 `READY_FOR_SALE`。最新构建 42（`2d6405ff-0af3-424d-bf66-67588bc7e37a`）`processingState=VALID`，上传于 2026-10-19T23:45:16-07:00。
- **构建与代码一致**：`git diff --stat 989b642..HEAD -- iOS/ Packages/` 为空；构建 42 的发布提交 `989b642` 之后只有 Mac 侧改动，iOS 与共享协议包没有变化，因此没有为凑新构建号重新上传。构建 42 的 IPA SHA-256、签名、profile 与 entitlement 证据见上一节。
- **截图**：1.2.4 的四个截图集均已存在（zh-Hans/en-US × `APP_IPHONE_67`/`APP_IPAD_PRO_3GEN_129`），每个集 3 张、`assetDeliveryState=COMPLETE`。未新增、删除或替换任何截图。解析 `asc screenshots list` 时先读原始输出的 `sets[].set` 与 `sets[].screenshots` 结构，避免再次把顶层 key 判断错。
- **metadata**：新增 `iOS/MacPilotRemote/metadata/version/1.2.4/{zh-Hans,en-US}.json`，description/keywords/marketing/support 沿用 1.2.3，`whatsNew` 说明后台蓝牙广播、地址轮换后的后台识别、设备列表持续刷新，以及距离仍决定是否解锁；中英长度 234 / 640 字符。`asc metadata validate --dir iOS/MacPilotRemote/metadata` 为 **0 errors / 0 warnings**。
- **推送与读回**：`asc metadata push ... --dry-run` 计划为 **2 adds（两个 locale 的 `whatsNew`）、0 updates、0 deletes**；正式推送返回 `succeeded=2/2`；再跑 dry-run 读回 `adds=0 updates=0 deletes=0`。
- **审核备注**：`asc review details-update` 将 review detail `b8937aa8-3f5f-4da7-90ad-efe83d77717d` 从「Version 1.2.2 review steps」更新为 1.2.4，保留控制功能默认关闭与排序步骤，注明 1.2.4 没有新界面、BLE 靠近解锁不是主流程审核所必需；未设置 demo 账号。
- **提交**：`asc review submit --app 6811335132 --version 1.2.4 --build 2d6405ff-... --dry-run` → `wouldAttach=true`、`wouldSubmit=true`；`--confirm` 返回 submission `6e4b1158-42ef-47f1-b526-955fc88c1c5f`、`submittedDate=2026-10-21T01:25:50.33Z`、`attached=true`。
- **最终读回**：版本 1.2.4 `WAITING_FOR_REVIEW`；`asc builds links view --build-id 2d6405ff-... --type appStoreVersion` 返回版本 `370852c7-...`，证明挂载的就是构建 42；review submission `6e4b1158-...` 为 `WAITING_FOR_REVIEW`；`asc status` 的 `nextAction` 为 `Wait for App Store review outcome`。`WAITING_FOR_REVIEW` 只代表已排队，**不代表 Apple 已批准**。
- **未做**：未重新打包或上传新 IPA；未改签名、provisioning 或 export 设置；未发起外部 Beta Review；未新增测试员；未改动线上 1.2.3。**真机 iPhone 上的后台挑战应答、地址轮换识别与自动解锁仍未实测**，本轮验证覆盖已有构建状态、元数据、截图与提交流程。

## 2026-10-22：1.2.5 / 构建 43 TestFlight 内部分发

- 目的是给「MacPilot 反向 BLE 纯 GATT 可行性验证」提供手机端：Mac 广播测试服务，PilotNest 扫描、连接、读取 Mac 信息、订阅并完成 16 字节回环。界面只在前台运行，不保存身份、不参与解锁；配套 Mac 版本为 `1.2.2-beta.40`。上一轮 `asc versions list` 显示 1.2.4 已 `READY_FOR_SALE`，因此新建 1.2.5 train（`3ff9dbeb-fcb1-418b-baf6-e2b4c62dd007`，`PREPARE_FOR_SUBMISSION`），metadata 从 1.2.4 复制 2 个 locale、8 个字段并排除 `whatsNew`。
- 归档前 `project.yml`：`MARKETING_VERSION` 1.2.5、`CURRENT_PROJECT_VERSION` 43；`xcodegen generate` 后仍为 `CODE_SIGN_STYLE=Automatic`、`DEVELOPMENT_TEAM=U8U443D7ZL`，没有固定 profile UUID。Git 提交 `d0aceb9`（GATT harness）已先发布为 Mac `v1.2.2-beta.40`。
- 最终 IPA：`/tmp/PilotNest-export-43/PilotNest.ipa`（2,589,843 字节）；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.5 (43)`，Team `U8U443D7ZL`，`MinimumOSVersion=17.0`，`ITSAppUsesNonExemptEncryption=false`。单一 arm64 二进制，无 `Frameworks/`、`PlugIns/`、嵌套扩展或 framework；`unzip -t` → `No errors detected`。
- IPA SHA-256：`efbaeed296a20075987d251819455e468a5b3bb36a6775a00c4df169777e0c8f`。
- `codesign --verify --deep --strict`：`valid on disk` + `satisfies its Designated Requirement`；`Authority=Apple Distribution: Guofeng Liu (U8U443D7ZL)`，`TeamIdentifier=U8U443D7ZL`。
- Signer leaf DER SHA-256：`62e7580e4e86da3c0c5a015e89f2074bb8439ecc34148575ed3d88499a233704`，与 profile 的 `DeveloperCertificates[0]` 完全相同。
- Profile：UUID `df12e579-3dec-4e63-b2df-86c5e2d37281`，名称 `PilotNest App Store 1.0.2 (8)`，`IsXcodeManaged=false`，有效至 2027-07-20；`get-task-allow=false`，顶层无 `ProvisionedDevices`、无 `ProvisionsAllDevices`，签名 entitlements 四项（`application-identifier`、`beta-reports-active=true`、`com.apple.developer.team-identifier`、`get-task-allow=false`）全部由 profile 授权且取值一致。
- 两层 `openssl cms -verify` 均返回 `CMS Verification successful`（CAfile：系统根证书 + WWDR，共 163 张）；已认证的内层 DER 中 `ProfileDistributionType=STORE`、`IsXcodeManaged=0`、UUID 与 profile 一致。反向对照：翻转 `embedded.mobileprovision` 中间一字节后同一命令 exit 4（`CMS_SignerInfo_verify_content: verification failure`）；`security cms -D` 仍只解码不验签。自动导出因本机 `No profiles` 失败，使用 `/tmp` 中的一次性手动导出参数与既有 profile，仓库自动签名设置未改。
- 测试：共享包 `ProximityGATTServiceTests` 5/5；Mac `ProximityGATTLocalizationTests` 3/3；PilotNest `RemoteTextProximityGATTTests` 2/2（iPhone 17 Pro 模拟器）；Mac 全量 1609 项中的失败均为 AGENTS.md 已记录的 wall-clock/主线程饥饿 flake，`ClosedLidSleepControllerTests`、`RemoteConnectionIdleWatchdogTests`、`BLEWakeRecoveryTests` 单独重跑通过；fresh Release `-Xswiftc -warnings-as-errors` 构建 0 warnings。
- ASC Build ID：`a3695df9-69c9-424f-ae2e-5c1ccd98d75a`，`processingState=VALID`，`internalBuildState=IN_BETA_TESTING`，`autoNotifyEnabled=true`，`externalBuildState=READY_FOR_BETA_SUBMISSION`；pre-release version 为 1.2.5。内部组「内部」（`dbf86047-0ba9-4944-bc39-7c78e92b0cd8`，`isInternalGroup=true`、`hasAccessToAllBuilds=true`）的 builds relationship 包含本次构建。中英文 What to Test 已写入并读回，要求双方在前台执行 GATT 测试并回传两侧日志。
- 仅分发给现有内部组；未提交 App Store Review、未发起外部 Beta Review、未新增测试员、未把构建 43 附加到 1.2.5 版本，也未执行 `asc metadata push`。`VALID` 与 `IN_BETA_TESTING` 都不代表 Apple 已审核批准。**真机 iPhone ↔ Mac 的纯 GATT 连接、锁屏与后台场景仍未实测**；本阶段按方案要求先验证前台纯 GATT 链路，通过后才允许进入后台发现与解锁开发。

## 2026-10-22：1.2.5 / 构建 44 TestFlight 内部分发

- 目的是把构建 43 之后补齐的反向 GATT 恢复与诊断发到手机：断连/蓝牙切换恢复、有上限退避、15 秒请求超时、iOS Central 状态恢复、定向回传与通知背压、双语诊断界面，以及默认跳过、显式启用的真机验收测试。构建 43 只含最初的 GATT harness，此后 iOS 与共享协议包共有 13 个文件、729 行新增，因此必须新构建号而不是复用 43。
- 上传前 `asc versions list` 确认 1.2.5 train（`3ff9dbeb-fcb1-418b-baf6-e2b4c62dd007`）仍为 `PREPARE_FOR_SUBMISSION`（可编辑），1.2.4 及更早为 `READY_FOR_SALE`；`asc builds next-build-number` 返回 `44`（latestProcessed/latestUpload/latestObserved 均为 43）。`project.yml` 的 `MARKETING_VERSION` 保持 1.2.5、`CURRENT_PROJECT_VERSION` 43 → 44；`xcodegen generate` 后仍为 `CODE_SIGN_STYLE=Automatic`、`DEVELOPMENT_TEAM=U8U443D7ZL`，`PROVISIONING_PROFILE_SPECIFIER` 出现 0 次，未固定任何 profile UUID。
- 最终 IPA：`/tmp/PilotNest-export-44/PilotNest.ipa`（2,637,975 字节）；bundle `com.misswell.macpilot.remote`，版本/构建号 `1.2.5 (44)`，Team `U8U443D7ZL`，`MinimumOSVersion=17.0`，`ITSAppUsesNonExemptEncryption=false`。单一 arm64 二进制，无 `Frameworks/`、`PlugIns/`、嵌套扩展或 framework；`unzip -t` → `No errors detected`。
- IPA SHA-256：`6efb7be0f9898d747f6d90be6e625c22b8fe7c0d501cfe384d8b8be7065588fd`。
- `codesign --verify --deep --strict`：`valid on disk` + `satisfies its Designated Requirement`；`Authority=Apple Distribution: Guofeng Liu (U8U443D7ZL)`，`TeamIdentifier=U8U443D7ZL`。
- Signer leaf DER SHA-256：`62e7580e4e86da3c0c5a015e89f2074bb8439ecc34148575ed3d88499a233704`，与 profile 的 `DeveloperCertificates[0]` 完全相同；本机 `security find-certificate` 导出的 Apple Distribution 证书 DER 也是同一哈希。
- Profile：UUID `df12e579-3dec-4e63-b2df-86c5e2d37281`，名称 `PilotNest App Store 1.0.2 (8)`，`IsXcodeManaged=False`，有效至 2027-07-20，ASC 状态 `ACTIVE`／类型 `IOS_APP_STORE`；`get-task-allow=false`，顶层无 `ProvisionedDevices`、无 `ProvisionsAllDevices`，签名 entitlements 四项（`application-identifier`、`beta-reports-active=true`、`com.apple.developer.team-identifier`、`get-task-allow=false`）全部由 profile 授权且取值一致。
- 两层 `openssl cms -verify`（CAfile：系统根证书 + WWDR，3 张）均返回 `CMS Verification successful`；已认证的内层 DER 经 `openssl asn1parse` 读出 `ProfileDistributionType=STORE`、`Platform=iOS/xrOS/visionOS`、UUID 与 profile 一致。反向对照：翻转 `embedded.mobileprovision` 中间一字节后同一命令报 `CMS_SignerInfo_verify_ex: verification failure`；`security cms -D` 仍只解码不验签。自动导出 `asc xcode export` 因本机 `No profiles for 'com.misswell.macpilot.remote' were found` 失败（既有已知条件），改用 `/tmp` 中的一次性手动 ExportOptions 与上述 profile 导出，仓库自动签名设置未改、profile 未写入仓库。
- ASC Build ID：`f9b687b6-881c-4bc0-b2f8-a232b1cc21e4`，`processingState=VALID`，上传于 2026-10-22T04:49:14-07:00，过期日 2027-01-20；pre-release version `be68d2f7-7ecd-454d-ba94-1703ef9ec493` 为 1.2.5。内部组「内部」（`dbf86047-0ba9-4944-bc39-7c78e92b0cd8`，`isInternalGroup=true`、`hasAccessToAllBuilds=true`）的 builds relationship 已包含本次构建（`asc testflight config export --include-builds` 读回）。
- 中英文 What to Test 已写入并读回：zh-Hans 483 字符、en-US 1265 字符，内容覆盖退避重连、后台与可选锁屏验证步骤、导出日志，并说明该功能不参与自动解锁或远程控制。
- 仅分发给现有内部组；未提交 App Store Review、未发起外部 Beta Review、未新增测试员、未把构建 44 附加到 1.2.5 版本，也未执行 `asc metadata push`。`VALID` 不代表 Apple 已审核批准。
