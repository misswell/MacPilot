# configuration-migration — 配置持久化、升级降级兼容

规则：`cfg-001-downgrade-wipe`（v1.1.482-beta.5 事故家族）。证据见 [../REGRESSION_CATALOG.md](../REGRESSION_CATALOG.md) E1。

## 不变量（原 AGENTS.md「Configuration compatibility」全文）

`StoredConfiguration`（`config.json` + sidecar 文件）之下的一切必须**升级和降级都存活**。v1.1.482-beta.5 删除一个 struct 字段使旧版无法解码整文件，fallback-to-defaults 路径在降级时清空了每个功能的配置。以下规则是硬不变量：

- **绝不删除或改名已编码的 Codable 键。** 原地弃用：UI/逻辑停用但保留存储属性并始终编码（`AwakeSessionProfileConfiguration.endCalculation` 是参考案例）。
- **新字段必须容错解码**——`decodeIfPresent` + 默认值，绝不做必填键；必填键集与最旧支持版本写的保持一致。
- **section 隔离：** `StoredConfiguration.init(from:)` 每个 section 都经 `section(...)` helper 解码；一个不可读 section 落回该 section 的默认值并记入 `unreadableSections`，`load()` 在任何保存之前隔离原始文件。持久化 section 不得绕过这个 helper。
- **持久化枚举的未知 rawValue 必须落默认值而不是 throw。** throw 即 wipe 整节。`QuickSearchSettings.matchScope` 用 `try?` 容错；`fileScope` 在 2026-11-01 审计中发现仍是裸 `decodeIfPresent`，已修复并补测试——给其余枚举补容错时必须同样带「未知值 → 默认值、其余键保留」的测试。
- **tripwire 测试** `Tests/MacPilotTests/ConfigurationSchemaContractTests.swift` 断言每个持久化类型仍编码其历史键集（append-only）。契约失败 = 你的改动会搁浅降级——保留键，别删断言。

## 必跑测试

`ConfigurationSchemaContractTests`、`ConfigStoreTests`、`ConfigurationSnapshotTests`、`QuickSearchPersistenceTests`；改任何 `Codable` 类型后同时跑该类型所属模块的套件。

## 人工验收

真实用户 `config.json` 在新↔旧两个发布版本间各切换一次，逐节确认配置保留；发现不可读 section 时原始文件被隔离而非覆盖。
