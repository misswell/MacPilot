# 截图标注实机验收记录（2026-11-16）

关联任务书：`SCREENSHOT_ANNOTATION_PARITY_TASK.md` §6.5
关联不变量：`docs/engineering/regressions/screenshot-reliability.md` —「标注工具栏与编辑历史」

## 方式与范围

本次不是模拟器或纯模型测试，而是启动一个真实的 macOS `.app` 进程（debug 构建，bundle id `com.misswell.macpilot.acceptance`），以 `--acceptance-annotation` 进入验收模式：

- 跳过 `MacPilotAppServices`，不注册全局快捷键、不读写用户 `config.json`、不采集屏幕、不请求 TCC 授权。
- 打开真实的 `SmartAnnotationWindowController` 全编辑器与真实的 `AreaSelectionActionBar`。
- 用真实 `NSEvent` 驱动窗口按键与鼠标；用真实 `NSPasteboard` 复制；用 `NSView.cacheDisplay` 保存窗口画面。
- 区域截图裁剪本身由固定测试图像代替；本记录验证的是标注交互层，不是 ScreenCaptureKit 采集链路。

原始记录与完整截图在 `docs/engineering/acceptance/assets/screenshot-annotation-parity/`。

## 环境

- macOS：版本 27.2.1（版号 26B131）
- 构建：`342da6e`
- 会话状态：**锁屏**（`CGSSessionScreenIsLocked = Yes`）

## 结果

| 验收项 | 结果 | 证据 |
|---|---|---|
| 完整编辑器窗口激活 | **阻塞** | 验收时会话已锁屏，App 无法成为前台 |
| 鼠标绘制第一个矩形 | **阻塞** | 锁屏会话不接收前台鼠标事件 |
| 连续绘制第二个矩形 | **阻塞** | 锁屏会话不接收前台鼠标事件 |
| 历史栈初始状态 | 通过 | 两个不同位置矩形，`annotations=2` |
| Cmd+Z 撤销 | 通过 | `annotations=1`，见 `03-after-undo.png` |
| Cmd+Shift+Z 重做 | 通过 | `annotations=2`，见 `04-after-redo.png` |
| Inline 工具常驻 | 通过 | 13 个工具全部直接可见，见 `05-inline-toolbar.png` |
| 工具栏在 1024×768 内可达 | 通过 | 靠右下角选区时 frame 仍在屏幕内 |
| 工具栏在 1920×1080 内可达 | 通过 | 同上 |
| 完整编辑器最小窗口 | 通过 | `minSize=(720, 448)`，底栏不被裁掉 |
| Copy & Close 关闭编辑器 | 通过 | 窗口关闭 |
| Copy & Close 写入剪贴板 | 通过 | 501,259 字节 PNG，见 `06-copy-and-close-clipboard.png` |
| 区域选区 Copy 裁剪尺寸 | 通过 | 200×100 冻结图选 80×50，剪贴板得到 80×50，见 `07-area-selection-copy.png` |
| 区域选区 Copy 成功后关闭 | 通过 | `dismissals=1` |

结论：**撤销、工具可见性、复制关闭、工具栏屏幕内可达、最小窗口、区域选区裁剪/关闭均通过**；真实鼠标绘制与前台激活被锁屏会话阻塞，未写成通过。多显示器项用真实布局函数在 1024×768 / 1920×1080 边界下验证，未连接第二台物理显示器；普通区域截图的冻结帧由测试图像代替，未调用 ScreenCaptureKit。

## 截图证据

全编辑器底部动作区（分享 / 贴图 / 删除 / 取消 / 复制并关闭 / 完成）：

![全编辑器底栏](assets/screenshot-annotation-parity/01-full-editor-bottom-bar.png)

撤销后剩一个矩形：

![撤销后](assets/screenshot-annotation-parity/03-after-undo.png)

重做后恢复两个矩形：

![重做后](assets/screenshot-annotation-parity/04-after-redo.png)

Inline 工具条（13 个独立工具 + 撤销/重做 + 独立动作行）：

![Inline 工具条](assets/screenshot-annotation-parity/05-inline-toolbar.png)

Copy & Close 写入剪贴板的最终渲染：

![剪贴板结果](assets/screenshot-annotation-parity/06-copy-and-close-clipboard.png)

普通区域选区 Copy 的裁剪结果（200×100 冻结图 → 80×50 选区）：

![区域选区裁剪](assets/screenshot-annotation-parity/07-area-selection-copy.png)

## 锁屏阻塞项如何补齐

解锁 macOS 会话后，在仓库根目录执行：

```bash
swift build
rm -rf /tmp/MacPilotAcceptance.app
mkdir -p /tmp/MacPilotAcceptance.app/Contents/MacOS /tmp/MacPilotAcceptance.app/Contents/Resources
cp .build/debug/MacPilot /tmp/MacPilotAcceptance.app/Contents/MacOS/MacPilot
cp Resources/Info.plist /tmp/MacPilotAcceptance.app/Contents/Info.plist
cp Resources/AppIcon.icns /tmp/MacPilotAcceptance.app/Contents/Resources/AppIcon.icns
plutil -replace CFBundleIdentifier -string com.misswell.macpilot.acceptance /tmp/MacPilotAcceptance.app/Contents/Info.plist
plutil -replace LSUIElement -bool NO /tmp/MacPilotAcceptance.app/Contents/Info.plist
plutil -replace CFBundleDisplayName -string "MacPilot Acceptance" /tmp/MacPilotAcceptance.app/Contents/Info.plist
codesign --force --deep --sign - --entitlements Resources/MacPilot.entitlements /tmp/MacPilotAcceptance.app
open -n /tmp/MacPilotAcceptance.app --args \
  --acceptance-annotation \
  --acceptance-output "$PWD/docs/engineering/acceptance/assets/screenshot-annotation-parity" \
  --acceptance-commit "$(git rev-parse --short HEAD)"
```

解锁后 `完整编辑器窗口激活`、`鼠标绘制第一个矩形`、`连续绘制第二个矩形` 会从「阻塞」变为真实结果；若仍失败，按真实缺陷处理，不得改写成通过。

## 自动化交叉证据

- `AnnotationInteractionParityTests.fullEditorRoutesRealKeyEventsThroughTheWindow`：真实 `NSEvent` 驱动 Cmd+Z、Cmd+Shift+Z、Cmd+Shift+C，并验证 `NSTextView` 为第一响应者时 Cmd+Z 不动画布。
- `AnnotationInteractionParityTests.aCopiedScreenshotSurvivesADelayedPaste`：复制后延迟 1.2 秒再读取，懒加载 provider 仍返回原尺寸 PNG。
- `AnnotationInteractionParityTests.quickAccessAnnotateCopyAndCloseUpdatesCardFileAndClipboard`：复制成功才关闭，源文件与缩略图都变成 60×40；临时卡片在标注保存前后都不得进入 `CaptureHistoryStore`。
- `AnnotationInteractionParityTests.legacyHUDAttachesCopyAndCloseToTheSameClipboardTransaction`：旧 HUD 的 Copy & Close 同样先写剪贴板再退出。
- `AnnotationInteractionParityTests.fullEditorBottomRailExposesTheHostsSupportedActions`：底栏按宿主能力提供分享/Pin/删除/Copy & Close/保存。
- `AnnotationInteractionParityTests.areaSelectionCopyCropsTheFrozenImageAndClosesAfterCopy`：真实 `finishSnapzySelectionAction` → 冻结图裁剪 80×50 → 剪贴板 → 关闭。
- `AnnotationInteractionParityTests.hudBarStaysReachableOnSmallAndLargeDisplays`：1024×768 到 1920×1080、右下角/近全屏选区都落在屏幕内。
- `AnnotationInteractionParityTests.fullEditorKeepsItsActionRailReachableAtTheMinimumWindowSize`：完整编辑器最小窗口 720×420 内容区。
- `bash Scripts/run-regressions.sh`：完整回归门禁通过；CI `regression-gate.yml` 同步通过。
