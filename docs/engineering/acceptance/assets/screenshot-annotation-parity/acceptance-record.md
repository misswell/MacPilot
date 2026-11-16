# 截图标注实机验收记录

- 日期：2026-11-16T18:44:11Z
- 系统：版本27.2.1（版号26B131）
- 构建：342da6e
- 方式：debug `.app` 以 `--acceptance-annotation` 启动；真实 AppKit 窗口、真实 NSEvent 鼠标/键盘、真实 NSPasteboard；跳过 MacPilotAppServices，不触发全局快捷键、配置写入、屏幕采集或 TCC 授权
- 会话状态：锁屏
- 范围：全编辑器与 Inline 工具条的真实 UI 组件；区域截图裁剪本身由固定测试图像代替

| 验收项 | 结果 | 证据 |
|---|---|---|
| 完整编辑器窗口激活 | 阻塞 | 当前 macOS 会话已锁屏，App 无法成为前台 |
| 鼠标绘制第一个矩形 | 阻塞 | 锁屏会话不接收前台鼠标事件（session locked） |
| 连续绘制第二个矩形 | 阻塞 | 锁屏会话不接收前台鼠标事件（session locked） |
| 历史栈初始状态 | 通过 | annotations=2 |
| Cmd+Z 撤销 | 通过 | annotations=1 |
| Cmd+Shift+Z 重做 | 通过 | annotations=2 |
| Inline 工具常驻数量 | 通过 | visible=13 missing= |
| 工具栏在 1024×768 内可达 | 通过 | frame=(306.5, 74.0, 709.5, 74.0) |
| 工具栏在 1920×1080 内可达 | 通过 | frame=(1202.5, 74.0, 709.5, 74.0) |
| 完整编辑器最小窗口 | 通过 | minSize=(720.0, 448.0) |
| Copy & Close 关闭编辑器 | 通过 | window=closed |
| Copy & Close 写入剪贴板 | 通过 | pngBytes=501259 |
| 区域选区 Copy 裁剪尺寸 | 通过 | size=Optional((80, 50)) |
| 区域选区 Copy 成功后关闭 | 通过 | dismissals=1 |

## 截图
- 01-full-editor-bottom-bar.png
- 02-two-rectangles.png
- 03-after-undo.png
- 04-after-redo.png
- 05-inline-toolbar.png
- 06-copy-and-close-clipboard.png
- 07-area-selection-copy.png

结果：可执行项全部通过；3 项因锁屏会话无法执行（见上表“阻塞”行）。