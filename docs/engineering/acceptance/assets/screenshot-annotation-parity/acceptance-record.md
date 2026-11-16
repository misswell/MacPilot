# 截图标注实机验收记录

- 日期：2026-11-16T22:00:22Z
- 系统：版本27.2.1（版号26B131）
- 构建：bbe5e63
- 方式：debug `.app` 以 `--acceptance-annotation` 启动；真实 AppKit 窗口、真实 NSEvent 鼠标/键盘、真实 NSPasteboard；跳过 MacPilotAppServices，不触发全局快捷键、配置写入、屏幕采集或 TCC 授权
- 会话状态：已解锁
- 范围：全编辑器与 Inline 工具条的真实 UI 组件；区域截图裁剪本身由固定测试图像代替

| 验收项 | 结果 | 证据 |
|---|---|---|
| 完整编辑器窗口 | 通过 | isKeyWindow=true |
| 鼠标绘制第一个矩形 | 通过 | annotations=1 |
| 连续绘制第二个矩形 | 通过 | annotations=2 |
| 历史栈初始状态 | 通过 | annotations=2 |
| Cmd+Z 撤销 | 通过 | annotations=1 |
| Cmd+Shift+Z 重做 | 通过 | annotations=2 |
| 鼠标调整对象大小 | 通过 | before=(0.5820512820512821, 0.3873504273504274, 0.18461538461538463, 0.2092307692307692) after=(0.5820512820512821, 0.29435897435897435, 0.2666666666666666, 0.3022222222222222) |
| 鼠标移动对象 | 通过 | before=(0.5820512820512821, 0.29435897435897435, 0.2666666666666666, 0.3022222222222222) after=(0.5, 0.212991452991453, 0.2666666666666666, 0.3022222222222222) |
| 鼠标修改线宽 | 通过 | before=3.0 after=47.0 |
| 鼠标修改颜色 | 通过 | before=SmartAnnotationColor(red: 0.95, green: 0.16, blue: 0.18) after=SmartAnnotationColor(red: 0.18, green: 0.72, blue: 0.38) |
| Inline 工具常驻数量 | 通过 | visible=13 missing= |
| 工具栏在 1024×768 内可达 | 通过 | frame=(299.0, 74.0, 717.0, 74.0) |
| 工具栏在 1920×1080 内可达 | 通过 | frame=(1195.0, 74.0, 717.0, 74.0) |
| 物理显示器数量 | 通过 | #1 1440×900@2.0x, #2 1920×1080@1.0x |
| 工具栏落在显示器 #1 | 通过 | frame=(715.0, 38.0, 717.0, 110.0) visible=(0.0, 0.0, 1440.0, 870.0) scale=2.0 |
| 工具栏落在显示器 #2 | 通过 | frame=(-725.0, -36.0, 717.0, 110.0) visible=(-1864.0, -74.0, 1864.0, 1050.0) scale=1.0 |
| 完整编辑器最小窗口 | 通过 | minSize=(720.0, 448.0) |
| Copy & Close 关闭编辑器 | 通过 | window=closed |
| Copy & Close 写入剪贴板 | 通过 | pngBytes=423698 |
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
- 08-after-move-resize-color-width.png
- 09-toolbar-display-1.png
- 09-toolbar-display-2.png

结果：全部通过。