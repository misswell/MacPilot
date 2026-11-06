# quick-search — 快捷搜索：按键路由、异步查询取消与索引

规则：`qs-001-key-routing-ime`（按键路由/IME，3 修）、`qs-002-stale-results-generation`（过期结果/回调，4 修）、`qs-003-panel-activation-multiscreen`（应用异步激活抢走面板 key，多显示器）。证据链见 [../REGRESSION_CATALOG.md](../REGRESSION_CATALOG.md) G1/G2/G3。

## 不变量（原 AGENTS.md「Quick Search」全文）

- 文件搜索**只走 `NSMetadataQuery`**。绝不用 `FileManager` 递归遍历主目录/磁盘，绝不自建全盘索引——Spotlight 就是本功能要骑的索引。
- 「无结果」和「不能搜索」是不同状态。索引关闭、所选 scope 未索引、无可用 scope、查询拒启时，面板显示原因（`QuickSearchIndexIssue`）；绝不能呈现为「没有匹配文件」。不允许存在「没有对 scope 可搜索的正面判定就报告空结果」的代码路径。
- 同时只有一个在飞查询：每次击键 150ms 防抖并打上递增 generation，新查询终止上一个及其通知观察者，关面板停查询。**过期 generation 的结果必须丢弃。**
- 空 scope 决策属于 model：`startFileSearch` 报 `.noScopeSelected` 而不是派发空 scope 查询（Spotlight 会自行扩大搜索范围）。
- 面板不依赖主设置窗口打开：召唤时绝不初始化整个设置 UI；app 的拼音与首字母在索引构建时归一化，不是每次击键；磁盘枚举与 Info.plist 读取离开主 actor；面板关闭时无定时器扫盘。
- 面板打开时若本进程尚未激活，必须在 `NSApplication.didBecomeActiveNotification` 到达后重新 `makeKeyAndOrderFront`；多显示器下 AppKit 会在异步激活完成时、甚至在 `didBecomeActive` 之后继续排窗口，把另一块屏上的普通窗口（设置页）选成 key window。面板须保持 0.6 秒 settle：期间每次 `resignKey` 都重抢 key 且不得关闭，settle 结束仍未拿到 key 才走正常失焦关闭；等待激活期间的 `resignKey` 同样不得关闭；关闭面板必须解除观察。人工验收：设置页放一屏，另一屏首次呼出快速搜索，面板保持可见且可直接输入。
- Carbon 注册状态如实上报（`isHotKeyRegistered`、`lastRegistrationStatus`）。`RegisterEventHotKey` 失败必须在设置页显示原因且不得标记为已启用；与其他功能冲突时保留先前有效绑定且不写配置。**IME 文字组装期间快捷键仍要分发**（`1415f7a` 复发教训）。
- 面板位置归用户所有：搜索行 leading 边的手柄拖动面板（`dragFromHeader` → `performDrag`，WindowServer 拥有拖动、`mouseUp` 永远到不了 view，用 `NSEvent.pressedMouseButtons` 轮询检测松手），frame 以**左上角**存进 `quickSearch.panelPosition`，与 clipboard 同一套键校验。绝不召唤时重新居中，锚点绝不取左下角——面板随行数增长必须向下长。坐标校验属于 `rememberPanelPosition`（写到磁盘的 NaN 会让整个 config 保存失败），不属于 decoder。`resetPanelPosition()` 清键并调 `applyPlacement()` 让用户立即看到移动。
- 面板尺寸同样归用户：6pt 边带（含角）用 `QuickSearchPanelLayout.frameResized` 拖动，对边钉住、钳制 400×180 与当前屏幕，`rememberPanelFrame` 把尺寸与（可能移动过的）左上角一次写入 `quickSearch.panelSize`。用户设定的尺寸取代行数驱动的高度；`resetPanelSize()` 只清尺寸。绝不重新居中或重新适配用户设定。
- 收藏与用量共享一个身份键（`QuickSearchUsageStore.identity`：Bundle ID，否则路径）。收藏行在索引未建好时从存储快照渲染——「索引构建中」绝不能看起来像「收藏为空」——建好后经 inventory 解析，改名/移动的 app 跟随现名。行动作（含上下文菜单）必须携带自己的行；绝不只按选中 index 行动。
- 悬停只有指针自召唤后**真正移动过**才可改变选中。面板出现在静止指针下时，AppKit 会对身下的行投递初始 hover——不得顶掉第一行。`openPanel()` 用召唤位置 arm `QuickSearchHoverGate`，`selectRowByHover(at:)` 在位置变化前拒绝；行用 `onContinuousHover` 让同行内的移动也算数。每次打开重新 arm。
- 匹配层级是首要排序键（`QuickSearchRanking.orderedByRelevance`）：每个名称命中（含模糊）高于标签与描述命中，使用频率只在同层内破平。文件行在等计数下保持 Spotlight 顺序（`QuickSearchFrequencyOrder`）。只有在打开真正成功后才记录使用。
- 用途标签与可搜索描述是**推导的，不是猜的**：只有 vendor 写在 app bundle 里的才算——`Info.plist`（`LSApplicationCategoryType`、URL schemes、DocumentTypes UTIs、`NSServices` 菜单标题、`CFBundleGetInfoString`）、`InternetAccessPolicy.plist`/`.strings`、Electron 的 `package.json`（asar 内或明文）、本地化 `InfoPlist.strings` 名称/描述，在后台扫描器建索引时计算——无网络、无 App Store 查询。`utilities`/`productivity` 与 `developer-tools` 类目刻意不算用途（后者是打包工具链默认值，本机 52 个 app 都宣称它，含 有道云笔记/字由/QQ），代码工具从声明的源码/脚本 UTI 识别。注册 `http`/`https` 的是通用 handler，其文档类型不得让它成为「图片工具」。标签命中低于一切名称命中，且只在 `quickSearch.matchScope` 为 `.nameAndPurpose` 时参与。
- 描述词经 `QuickSearchKeywordLexicon` 匹配——内置离线中英概念表（AI/Agent、下载/download、清理/cleanup、截图/screenshot……）建索引时展开；**绝不加翻译 API，绝不把整份 package.json/UI 文案嵌进索引**。有界 fallback 只在 app 既无标签又无描述时读 en/zh `.lproj` UI strings，且只接受主导概念——至少 3 条匹配的 UI 字符串、按命中数排序，第二概念需要头名一半的证据。描述匹配层级 `.keyword`，低于模糊名称命中——名称命中永远胜过描述命中，无论使用频率；同样受 `.nameAndPurpose` scope 门控。
- 一个 app 可以有两个名字：索引显示（本地化）名**和**原始 `CFBundleName`/`CFBundleDisplayName` 与 bundle 文件夹名——Finder 显示 迅雷 而 plist 写 Thunder——每个变体带自己的拼音与首字母。本地化 `InfoPlist.strings` 可以用**空字符串**覆盖名字（三局通就这样，development region 是 `en`），所以解析必须把空当缺失、落回 bundle 文件夹名：plain `??` 链停在空值留下无名行。
- 持久化枚举的未知值必须落默认而不是 throw：throw 会 wipe 整个 `quickSearch` section（正是 `ConfigurationSchemaContractTests` 防的事故——见 configuration-migration.md E1）。
- 行图标走 `QuickSearchIconLoader` 与磁盘缓存 `~/Library/Caches/MacPilot/QuickSearch/Icons/`（`QuickSearchIconDiskCache`），绝不每次打开实时调 icon 服务。缓存键 = 标准化路径 + bundle 修改日期 + 点尺寸，app 更新立即失效；7 天刷新（陈旧条目在后台重建时照常渲染）、30 天清理。面板打开的读取同步，图标与文本同帧绘制；成功加载写穿。后台渲染失败只在系统 loader 在用时回退主线程 `NSWorkspace` 路径；注入的测试 loader 绝不读写用户缓存（测试传自己的临时 `diskCache`；默认 loader 在测试宿主下跳过 `.shared`）。
- 改本模块后验证 QuickSearch 全套 + `ConfigurationSchemaContractTests`、`ConfigStoreTests`、`QuickSearchPersistenceTests`。`QuickSearchHotKeyTests` 是 `.serialized`（Carbon 注册是进程级），其他套件用 `Harness.quietHotkey`（故意无效的绑定）不抢真实组合键。

## 必跑测试

`QuickSearch*` 全族（含 `QuickSearchCancellationTests`、`QuickSearchPersistenceTests`、`QuickSearchSpotlightHonestyTests`）、`CarbonHotKeyRoutingTests`、`QuickSearchHiddenFieldEditorTests`、`ConfigStoreTests`。

## 人工验收

- 中文输入法组装拼音时 Option+Space 仍唤起/关闭面板。
- 快速连续输入后结果只属最后一次查询；面板出现在静止指针下首行不被顶掉。
- Spotlight 索引关闭时显示「不能搜索」而非空结果。
- 双显示器：设置窗口放一屏、指针在另一屏时唤起快速搜索，面板留在指针所在屏并可直接输入；关闭后焦点回到原应用。
