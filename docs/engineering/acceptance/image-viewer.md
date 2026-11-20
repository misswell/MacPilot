# MacPilot 看图交付与验收

## 范围与复用

对照 [LumaView 1.3.3 源码](https://github.com/ixiehao/LumaView/tree/863f98221e013dc8a835083d6db4314a2f134f7b)，以及其 QA、性能基准与 2026-11-06 回归记录。未引入 Swift 包或其他运行时依赖。

| LumaView 实现 | MacPilot 适配 |
|---|---|
| `ImagePipeline` 的 ImageIO 降采样、EXIF 方向、源文件指纹、成本 LRU | `ImageViewerPipeline`、`ImageViewerSession`；以 CGImage 的 stride × height 计费，打印单独排队，PDF 只保留可见页 |
| PDF crop box、内在旋转与 Retina 放大 | `ImageViewerPDFRenderer`：采用相同的页面点坐标到像素映射，再与用户旋转分离 |
| 固定 Sketch 预览名及有界管道读取 | `ImageViewerSketchPreview`：取消、总截止时间与 SIGKILL 兜底；目录包用 `openat` 拒绝符号链接，归档仅输出到管道 |
| `ImageBrowserStore` 单层目录枚举/自然排序/共享索引；`ImageCanvasView` 单画布与逐帧图像 | 订阅共用目录结果；AppKit 画布按 backing scale 定位、裁切、缩放；动画状态归其可见窗口，无帧序列缓存 |
| `ImageInformation` 的 ImageIO 属性读取；`LumaDocumentWindow` 的焦点键路由；App delegate 的冷启动缓冲 | 信息按需读取、补 GPS；窗口局部键处理；沿用 MacPilot 的晚启动和退出流程 |

没有搬入上游独立应用生命周期、默认应用设置、欢迎窗口、更新机制、菜单本地化观察器或静态缓存。完整上游 MIT 许可证放在 `Resources/LumaView-LICENSE.txt`，打包时复制进 `Contents/Resources`。

## 文件与所有权

- `Sources/MacPilot/ImageViewer/`：Feature、Runtime、Session、文档窗口/画布、文件入口/索引、解码、动画、PDF、Sketch、EXIF、设置页和双语文案。
- `MacPilotApp.swift`、`Core/Resource/FeatureRegistry.swift`、`FeatureDiagnostics.swift`：连接配置、首页分组、侧栏、菜单、Finder、退出、诊断。首页通过现有 `MainSection.utilitySections` 自动长出卡片，因此不另改 `HomeView.swift`。
- `Resources/Info.plist`、`Scripts/build-app.sh`：Alternate Viewer 和许可证；保持既有 URL scheme、指定签名要求和 entitlements。
- `Tests/MacPilotTests/ImageViewer*Tests.swift`：生命周期、解码、浏览、文件入口、窗口和配置。选择器新条目复用 `regression-gate.yml`，不另维护 CI 套件列表。

进程只常驻轻量 Feature。启用即创建 Runtime 和菜单能力；打开面板本身不创建解码队列。打开图片时创建 Session，显式打开文件夹时临时建 Session 搜索首项（空或失败即释放）。窗口拥有各自的选择、页码、缩放、旋转、当前帧和调度令牌。异步工作只持有必要的输入、缓存和取消令牌，不持有窗口；关闭时撤销作业登记，回调必须通过会话登记和窗口世代检查。最后一个窗口关闭后仅在功能已开启时保留 Runtime；不保留最近打开路径。关闭功能或退出时释放 Runtime。

资源上限：导航位图 16 MiB、渲染位图 64 MiB、Sketch 数据缓存 16 MiB、元数据 256 条；渲染并发 2、打印与元数据分别并发 1；单个相邻预读；动画边长 2048 px；文档显示边长 4096 px；独立打印边长最多 7200 px。系统内存压力时取消预读并清除缓存，不清除可见帧。系统同步文件调用或已进入框架的 ImageIO/CGPDF 调用不能强制中断；取消使其完成后不递交结果、不重建资源。

## 验收矩阵

使用临时测试数据和隔离 macOS 会话，不改用户默认打开应用，不替换正在用的 MacPilot。用 Allocations 的 Mark Generation、Time Profiler，以及 `FeatureDiagnostics` 的 `taskCount`、`observerCount`、`cacheBytes` 记录，不把 RSS 当成资源所有权证明。每个阶段同时记录进程 footprint/CPU、活跃 Job 和压力监听数、缓存字节，另查 WindowServer/原生位图释放。

| 阶段 | 夹具和动作 | 预期 |
|---|---|---|
| 冷启动（关闭） | 启动成品；Finder 打开 JPEG 与 PDF | 无 Runtime、Job、缓存、监听；只显示启用提示 |
| 冷启动（开启、无窗口） | 重启成品，不打开文件 | 仅 Runtime；无图片 Job、缓存或压力监听 |
| 首次打开 | 5K 照片、超大相机 RAW、大型多页 PDF、长 GIF/WebP、Sketch、不可读/损坏/不支持文件 | 响应主线程；分辨率与错误回报准确；动图不可见/最小化时停；PDF 仅当前页 |
| 单窗浏览 | 100、1,000、10,000 张目录，各浏览至少 100 张；另用过限目录 | 自然顺序、切页无旧结果覆盖；明确上限提示 |
| 8 窗口 | 8 张不同的 5K 图；测试其中两个窗口不同 EXIF/旋转/缩放/PDF 页 | 不串窗口；目录订阅允许共享；缓存不超上限 |
| 关掉所有窗口 | 渲染、PDF 跳页和动画工作进行时分别关窗；观察后续清理 | Session、窗口/位图、监听、任务与缓存归零；Runtime 仍能接受新打开 |
| 关闭功能或退出 | 打开多窗口并在解码时禁用，再测退出；反复启停 100 次 | 无残留 Session/Runtime，不显示旧窗口；进程 CPU 和分配趋势回到基线 |

补充交互：从 Finder 冷/热打开、真实 Finder 拖拽、菜单和打开面板批量选图、双击 Fit、实际像素与混合 DPI、触控板缩放、侧栏及深浅色、全屏进出、当前 PDF 页打印并保存到临时 PDF，以及升级降级往返。真实格式支持和性能以本机测量为准，不引用上游测量值作为 MacPilot 结果。

## 本机压力用例

`MACPILOT_IMAGE_VIEWER_STRESS=1 swift test --no-parallel --filter ImageViewerPerformanceTests` 在 100、1,000、10,000 个临时路径上分别测索引，以 5K JPEG 连续浏览 100 次并创建八个 AppKit 文档控制器。它不展示窗口，不接管当前桌面，不测实际合成和图形驱动；`IMAGE_VIEWER_PERF` 记录进程 footprint、阶段 CPU、受管作业、压力监听与缓存，单位为字节和单核百分比。保留原始输出并明确它来自 Swift 测试进程，而非已签名应用。

2026-11-19，Apple Silicon、macOS 27.2.1，Luna 单独运行该用例，1/1 通过（约 9 秒）。100、1,000、10,000 路径分别耗时 0.005、0.055、0.492 秒；夹具为硬链接的 5K JPEG，不能代表网络卷或不同文件编码代价。

| 阶段 | Footprint（字节） | CPU（单核 %） | Jobs | 监听 | 缓存（字节） |
|---|---:|---:|---:|---:|---:|
| 关闭基线 | 48,153,512 | 9.79 | 0 | 0 | 0 |
| 启用，无窗口 | 48,104,360 | 0.17 | 0 | 0 | 0 |
| 第一张 5K | 68,764,776 | 120.22 | 1 | 1 | 2,359,296 |
| 连续浏览 100 张 | 53,101,816 | 123.65 | 0 | 1 | 51,904,512 |
| 八窗口渲染完成 | 90,621,152 | 90.12 | 0 | 1 | 66,060,288 |
| 关完窗口 | 73,057,480 | 31.07 | 0 | 0 | 0 |
| 关闭功能 | 73,057,480 | 24.20 | 0 | 0 | 0 |

CPU 是相邻采样间隔的平均值，包含建立/销毁窗口的开销；关闭功能样本间隔很短，不是静置 CPU。测试证明受管资源归零，不证明短时 footprint 回到基线，也不替代 Instruments。原始输出：`/tmp/octoquit-imageviewer-performance.log`。

## 证据状态

- 看图专项：20 项通过，默认跳过的压力用例单独启用后通过。
- 安全回归：`bash Scripts/run-regressions.sh` 全量门禁通过；追加索引经 `origin/main` 的基线检查器核对，不缩小原覆盖。门禁主批记录 1,771 项，含条件跳过；既有包测试与发版 Python 检查同样通过。
- 普通 `swift test`：1,958 项、229 套件，7 项失败（11 个断言/超时问题），不能称全绿。五项属于项目登记的定时波动：Snapzy 单帧超时、远程视频套接字、BLE 唤醒恢复、截图快捷键注册、画中画停滞检测。另外两项未列入白名单：`LocalPortsModelTests.forceKillConfirmationSendsSigkill`、`RemoteConnectionIdleWatchdogTests.inboundTrafficKeepsTheConnection`。七项逐个用 `--no-parallel` 复测均通过；未削弱断言或加豁免。原始结果：`/tmp/octoquit-imageviewer-full.log`。
- 本地 Release 包：`/tmp/octoquit-imageviewer-package.YUEbVR/MacPilot.app`；Luna 验证 Developer ID 深度签名、固定指定要求、文档类型及随包许可证。没有公证或发布；没有替换或启动用户正在使用的副本。
- 实机 Instruments、真实 Finder、混合 DPI、打印与旧版本升级降级尚无测量证据；未执行的项目不计入通过。远端 CI 与正式发行不等同于本地回归和本地应用包。

## Finder 直接打开修复验收

此修复之后，关闭首页看图也可用 Finder 一次性打开；上一版表中的「只显示启用提示」不再是预期。测试关闭和开启两种状态，分别从系统「打开方式」和已配置 MacPilot 的 Finder 扩展菜单打开 JPG、PNG、HEIC、WebP 及五张混合图片。先退出 MacPilot 做冷启动，再保持设置窗口已关闭/已打开分别试热启动。检查只打开文档、设置已开时不关窗、应用只运行一个实例、首页开关不变、关掉所有临时窗口后资源归零。再从菜单栏打开设置验证原入口，选择普通目录不进入看图。待在隔离桌面用本次构建执行，先前的本地包不包含此次修复。

Luna 已通过 137 项专项测试及本地安全回归门禁（1,925 项，包含有条件跳过项）。真实 Finder/LaunchServices 冷热启动尚未验收。

## 格式关联验收

在隔离账户打开看图设置，确认每行显示系统当前默认应用，进入页面不写关联。记录 JPEG 与 PNG 当前应用后，只把 JPEG 设为 MacPilot；若系统提示则分别验证取消和同意。确认 PNG 未变、双击 JPEG 只出看图窗口，最后从同一菜单选回原应用。真机验证待完成。

Luna 已通过 39 项专项和本地安全门禁（1,931 项，无失败或豁免）。自动化仅使用测试替身，不更改真实文件关联。CI macOS 15 首轮暴露测试夹具 URL 尾斜杠差异（生产关联逻辑未失败），修复后随新 Beta 重跑门禁，见 `BUG_FIX_LOG.md`。

## 滚轮手势验收

在看图设置中分别选择「滚轮翻页」和「Option+滚轮翻页」。每种模式下用鼠标滚轮与触控板各测一次：所选手势切换上一张/下一张，另一个手势放大缩小；触控板一次滑动只切换一张，惯性阶段不再跳图。按住/松开 Option 时确认不会连续跳图；文件夹首尾不循环；缩放以指针位置为锚点；上一张/下一张按钮、方向键、pinch、双击适应窗口和命令菜单保持原行为。退出重开后设置仍在，旧配置升级后默认为「Option+滚轮翻页」（滚轮缩放）。真机鼠标与触控板验收待完成。
