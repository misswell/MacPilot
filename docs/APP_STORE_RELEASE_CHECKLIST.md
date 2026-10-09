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
