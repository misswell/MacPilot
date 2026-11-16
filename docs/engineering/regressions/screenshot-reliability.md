# 截图状态、文件生命周期与捕获可靠性（不变量）

历史事故与任务书：`SCREENSHOT_RELIABILITY_TASK.md`。本文件只记录必须一直成立的规则；索引规则 id 为 `shot-001`…`shot-005`。

## 单一产物与一次编码

- 一次截图只编码一次。`handleCapturedImage` 是唯一产出入口：它按 `CaptureRequest`（intent + mode）经 `PostCaptureRouter` 算出动作，再写出一份文件。
- Quick Access、剪贴板、自动保存、贴图、标注编辑器全部引用同一 `CaptureArtifact`。禁止再从 `CGImage` 直接编码第二份给剪贴板或预览。
- 显式工具栏动作必须携带 intent：`.capture` → `.automatic`、`.save` → `.explicitSave`/`.annotatedSave`、`.copy` → `.explicitCopy`、`.pin` → `.explicitPin`。显式保存永远产生永久文件，不受“自动保存”开关影响。

## 文件状态机

- `CaptureArtifactState`：`reserved → writing → ready | failed`，提升到永久目录时经过 `promoting`。
- 文件依赖操作（复制、保存、拖拽、标注、Finder 展示）只在 `.ready` 开放；写入中显示“正在写入”，不得先移除卡片。
- 写入失败保留卡片 + 失败状态 + 重试；自动保存失败时允许一份临时回退文件，并明确提示，不得静默吞掉截图。
- 保存/删除是可失败事务：失败时卡片、历史记录和文件都保持原状。
- 磁盘写入先写 staging 文件，验证（可解码 + 尺寸 + 非空）后再原子改名；替换成功前不得删除源文件。
- 所有落盘路径（自动保存、编辑后覆盖、临时文件、提升）都经由 `CaptureArtifactStore`；禁止在调用方直接 `CGImageDestination` 写文件绕过 staging/验证/原子提交。编辑后覆盖使用 `replace(at:)`，验证失败时旧文件字节必须原样保留。

## 剪贴板 lease

- 每次复制向 `ClipboardArtifactLeaseManager` 记录一条与 `NSPasteboard.changeCount` 绑定的 lease；旧一代变更计数自动释放。
- 延迟粘贴依赖这份文件：只要 pasteboard lease 或命名 consumer（标注编辑器、保存流程）仍持有 URL，临时文件不得回收。
- 显式用户删除不受 lease 阻止，但自动清理必须查询 lease。

## 窗口与显示器解析

- “当前窗口截图”优先使用 `AXFocusedWindow` 的 window id；AX 不可用时回退 WindowServer z-order；禁止静默选择“最大的标题窗口”。
- 目标显示器只按 `CGDirectDisplayID` 精确匹配；尺寸/分辨率相似不得用于猜测。找不到请求的显示器必须报错。
- 输出像素比例使用 `pointPixelScale`，回退 backing scale；禁止固定 2×。

## 跨屏合成与截图界面

- 跨屏截图必须覆盖全部请求显示器，缺快照或裁剪失败使整次截图失败；禁止 `continue` 留下透明空洞。
- 合成结果尺寸与请求像素尺寸不一致必须报错。
- 截图专用窗口（选区面板、Quick Access、悬浮 HUD）按 window id 排除；禁止排除整个 MacPilot 进程，普通 MacPilot 窗口仍必须可被截取。

## 窗口选择状态

- 应用窗口模式必须区分 `loading` / `ready` / `failed`。`ready` 但候选为空表示“此处没有窗口”，不是加载失败，也不是“无法搜索”。
- 加载期间点击套索、单击或回车，只暂存一次待处理点击；快照到达后若命中窗口则选择它，未命中则从该点开始手动框选。失败时同一操作直接进入手动框选。
- 每个提示语必须对应真实状态（识别中 / 窗口列表不可用 / 此处无窗口），不得把不可用伪装成“没有结果”。

## 尺寸指示（pt / px）

- 拖动中的实时气泡显示逻辑尺寸（pt）；定格后的尺寸徽标必须显示提交产物的真实像素尺寸。
- 像素尺寸由冻结快照预测，且必须使用与真实裁剪完全相同的对齐与放大规则：`pixelAlignedRect` 对齐到快照像素网格，混合 DPI 合成取参与显示器的最大 pixel scale，并应用 `minimumOutputScaleFactor` 升级。
- 预测值与 `cropImage` / `cropCompositeImage` 的实际输出尺寸必须逐像素一致；禁止用点数乘固定 2 猜测。

## 刷新截图的会话绑定

- 刷新任务必须同时绑定 `snapzySessionID` 与递增的刷新 token；取消、超时或开启新会话后，旧任务的完成不得恢复面板、替换快照或清除新会话状态。
- 面板隐藏由 token 引用计数持有（`RefreshHideLedger`）：只有第一个 token 隐藏、最后一个 token 恢复；旧会话的 token 不能解除新会话的隐藏。
- 同一会话重复刷新时取消旧任务，不允许并行抓取多份快照；会话结束时释放全部 hide token，避免面板永久隐藏。

## 按模式的后处理配置

- 唯一分发入口仍是 `PostCaptureRouter.plan(request:global:perMode:)`；任何新截图入口都必须构造带真实 `CaptureMode` 的 `CaptureRequest`，不得用 `.other` 落入全局而绕开模式配置（全屏、当前窗口、滚动、智能元素曾经如此）。
- `perModeActions` 缺少某模式键即回退全局开关，这是旧配置升级后的行为基线；取消自定义时删除该键，而不是写回全局值，避免以后全局改动被旧副本冻结。
- 每个模式的动作集合互相隔离：修改一个模式不得创建或改写其他模式的条目。显式 intent（保存/复制/贴图/标注）仍然只产生自己的动作，优先于模式配置。
- 设置的读写都走 `ScreenCaptureModel.setPerModePostCaptureActions`，不得绕过模型直接改 `settings` 后不落盘。

## 操作栏阶段分层

- 选区操作栏有两个互斥阶段：框选阶段只显示主要动作（标注入口、OCR、贴图、更多、保存、复制、取消）；标注阶段只显示标注工具与完成/取消，主要动作隐藏。
- `AreaSelectionActionBar.applyStageVisibility()` 是唯一决定阶段可见性的地方；初始化、`bindAnnotationSession`、进入/结束标注都必须调用它，禁止在各处零散地隐藏按钮。
- 完成（checkmark）结束标注会话并交回原定 post-capture 动作（`.capture` → `.automatic`）；取消（xmark）直接丢弃本次标注。两者都不得在文件尚未写出时移除产物。
- `bindAnnotationSession(nil)` 必须把栏位恢复成框选阶段，否则用户会卡在没有退出入口的工具栏里。

## 图像工作与主线程

- 裁剪、跨屏合成、圆角/阴影样式、编码与完整性校验必须在 detached task 中执行；MainActor 只做窗口、状态与最终 UI 更新。冻结会话交给后台的是 `allSnapshots()` 的值拷贝，刷新写入不得与裁剪竞争。
- 所有整图工作经过 `CaptureImageWorkGate`（并发上限 2）；快速连拍不得同时持有多个 5K 缓冲。ScreenCaptureKit 的串行抓屏策略保持不变。
- 后台任务不得捕获可变局部图像变量；先取 `let` 快照再进入并发闭包，否则编译期即拒绝。

## 截图历史与 Quick Access 服务接入

- 历史只有一个来源：`SmartCaptureHistoryStore`（`MacPilot.smartCapture.history.v1`）。Quick Access 的 `CaptureHistoryStore` 只是委托，不得再维护第二份记录或空实现。
- 手动保存/提升产物时必须在同一次成功事务里用 `previousPath` 重指向临时路径，历史中只留一条正式路径；删除产物必须同时移除历史，不能留下失效记录。
- 非模型写入（提升、删除）发出 `externalChangeNotification`，`ScreenCaptureModel` 收到后重新加载；历史与卡片不能各持一份互相背离的数据。
- 标注“保存到原文件”先编码到 staging、解码校验尺寸后再原子替换；失败必须保留原文件、在卡片上报告错误，不得用 `try?` 吞掉写入失败。

## 配置兼容

- `PostCaptureConfiguration` 缺省为空 = 沿用旧版全局开关；未知 mode key 在 `sanitized()` 中丢弃，不能让整个 section 解码失败。
- 新增键使用 `decodeIfPresent` + 默认值；历史键只废弃不删除。

## 回归入口

`ScreenshotReliabilityTests`（含 `RefreshHideLedgerTests`、`WindowSelectionLoadingStateTests`、`CapturePixelSizeTests`、`CaptureHistoryServiceTests`、`PostCaptureRoutingTests`、`CaptureArtifactStoreTests`、`RapidCaptureSequenceTests`、`QuickAccessOperationCoordinatorTests`、`ClipboardArtifactLeaseTests`、`CaptureChromeWindowRegistryTests`）、`ScreenCaptureTests`、`ScreenCaptureClipboardRegressionTests`、`SnapzyCaptureTests`、`SnapzySingleFrameCaptureTests`、`QuickAccessTests`、`ScreenshotPopupCaptureOrderingTests`、`ScreenshotPopupWindowProbeTests`、`ConfigurationSchemaContractTests`、`ConfigStoreTests`。实机验收见 `docs/engineering/acceptance/`（混合 DPI、跨屏、AX 无权限）。
