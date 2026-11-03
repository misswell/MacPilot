# helper-lifecycle — FinderSync、Power/Dock Helper 等辅助进程生命周期

规则：`help-001-findersync-registration`（FinderSync 注册，9 修）、`help-002-on-demand-processes`（按需资源与辅助进程，2026-10-28 用户要求）、`help-003-dock-groups-cross-process`（Dock 分组跨进程编辑）。证据链见 [../REGRESSION_CATALOG.md](../REGRESSION_CATALOG.md) D1–D3。

## 不变量

### FinderSync 生命周期恢复（help-001-findersync-registration，原 AGENTS.md 全文）

- 绝不暂时把 Finder 扩展选举成 `ignore` 而不先在跨进程锁下记录有效的、绑定目标的 `FinderSyncRecoveryJournal` 意图。用 `FinderSyncRegistration`，不开放手写选举变更。
- 只有在**新鲜的 PlugInKit 查询**确认 `+` 且在当前 app 的精确 `Contents/PlugIns/FinderSync.appex` 路径之后，才能清除恢复意图。命令成功或启用的陈旧副本不是确认。
- 只在有效匹配意图证明是 MacPilot 自身未完成事务时自动恢复被 ignore 的选举；保留未标记的用户禁用，拒绝无效/不匹配的意图。
- 成功的更新/回滚事务必须先恢复并验证再启动 app。失败保留 journal；为恢复而重启完好 app 只能在注册事务/锁结束之后，且不得报告为成功恢复。
- 驻留扩展在每个认证的主 app `running` 通知上恢复心跳并请求当前配置；重复通知不得创建重复定时器；延迟初始化不得撤销 `quit`。
- 生命周期改动后跑 mock 的 `FinderSyncRegistrationTests`、`FinderSyncRecoveryJournalTests`、`FinderSyncHeartbeatLifecycleTests`。`zsh Scripts/verify-findersync.sh` 是只读安装态检查，不是视觉菜单验收。绝不自动重启 Finder 或重置权限。

### 按需资源与辅助进程生命周期（help-002-on-demand-processes，2026-10-28 用户要求全文）

- 功能仅在实际使用时占用对应资源。**关闭功能必须停止该功能的任务、定时器、监听、事件 tap、采集、编码和连接，并释放可重建的缓存；隐藏窗口不能被误当成功能关闭。**
- 专属辅助进程按需启动，关闭所属功能后正常退出；不能只把 CPU 降到接近零却永久驻留。共享辅助进程按实际使用者/租约计数，最后一个使用者结束后退出。注册安装状态与进程运行状态分离，避免每次使用反复索要管理员授权。
- 显示控制与电源辅助进程须先完成屏幕拓扑/原始电源状态恢复并确认再退出；恢复未完成时只保留必要恢复工作并明确失败，不能通过 kill 绕过安全事务。快速关闭再开启、崩溃恢复和延迟回调不得误停新会话。
- launchd 的 RunAtLoad/KeepAlive 必须有实际必要性；无活动租约的辅助服务应支持按需启动及安全空闲退出，防止退出后又被无条件拉起。
- FinderSync、系统自动填充等 macOS 托管扩展，关闭功能时停止自身工作并释放资源；不得为移除进程而重启系统宿主、强杀系统进程或重置用户权限。不可保证进程消失时，说明系统控制边界。
- 生命周期验证必须覆盖：关闭后后台工作计数归零、缓存释放、专属进程正常退出/不重启、快速重开、恢复失败、旧回调隔离。测试用 mock，不在用户会话真实锁屏/黑屏/休眠/改电源策略。

### Dock 分组 helper 编辑（help-003-dock-groups-cross-process，原 AGENTS.md 全文）

- helper 面板可增删重排组内应用，「主 app 写、helper 读」的旧分工已不成立。两进程编辑同一 `groups.json`，正确性取决于：
  - **每次写都走 `DockGroupStore.update`**：对 `<root>/.groups.lock` 独占 `flock`、重读文档、应用变更、原子写。任何一侧都禁止开写「读→改→save」——读与写之间 helper 的编辑会被静默丢失。`DockGroupsModel.commit` 与 `refreshDockTileAnchors` 基于同一理由合并到最新磁盘文档。
  - **只有主 app 再生 helper bundle。** helper 编辑后 `DockGroupChangeNotifier.post(groupID:)` 发分布式通知；主 app 重载并再生该组 helper，复合 Dock 图标跟随成员。helper 绝不自建 bundle。
  - **拖拽 payload 安全：** 重排拖拽带 `dockgroup-app:<uuid>`（`DockHelperView.dragPrefix`）。不匹配前缀的不是重排。落点是移动后的最终 index。
  - **app picker 不得让面板关闭。** `NSOpenPanel.runModal()` 抢 key；`DockHelperPanel.isPresentingModal` 抑制 key-loss 与外点关闭直到 picker 关闭，然后重新 key 可见面板并重置 `DockGroupPanelDismissalPolicy`。
  - 增删成员经 `DockHelperLayout.size(for:)` + `DockHelperPanelPlacement.resizedOrigin` 调整面板：底部 Dock 保底边与水平中线，侧边 Dock 保垂直中线与靠 Dock 边。
  - 改此路径后验证 `DockGroupsCoreTests` 与 `DockHelperPanelPlacementTests`；并发测试用 40 个队列分别经独立 store 实例写，不得丢改动。

## 必跑测试

`FinderSyncRegistrationTests`、`FinderSyncRecoveryJournalTests`、`FinderSyncHeartbeatLifecycleTests`、`MenuSectionLayoutTests`、`MenuTagTests`、`PowerHelperIdleStateTests`、`PowerHelperRetirementTests`、`DockHelperLifecycleTests`、`DockGroupsCoreTests`、`DockGroupsIntegrityTests`、`DockHelperPanelPlacementTests`、`DockGroupPanelDismissalTests`、`FeatureResourceLifecycleTests`、`ResourceLifecycleTests`。

## 人工验收

- 安装更新后 FinderSync 保持启用、右键菜单出现；用户手动禁用后不被自动恢复（`zsh Scripts/verify-findersync.sh` 只读核对）。
- 活动监视器：关闭各功能后专属 helper 退出且不被 launchd 拉起；快速开关无重复进程。
- helper 面板与主 app 同时编辑同一分组，双方改动都保留。
