# MacPilot 界面设计规范（UI Design Spec）

> 所有功能页必须遵循本规范。新增功能、修改既有功能界面时，按本规范执行，
> 并对照文末的「新功能检查清单」自检后再提交。

## 1. 设计语言

MacPilot 的界面统一采用 **「原生侧边栏 + 大标题页头 + 自适应玻璃卡片」** 的视觉语言：

- 主导航使用 `NavigationSplitView` 与原生 `.sidebar` 列表，让 macOS 26 自动呈现最新侧边栏层次。
- 每个功能页顶部是 **30pt 粗体大标题 + 副标题**。
- 页面内容按逻辑分组，放入 **自适应玻璃卡片（SettingsCard）** 中。
- macOS 26 使用原生 Liquid Glass；macOS 15–25 使用视觉等价的 `regularMaterial` 降级实现。
- 卡片内的小节标题使用 `headline`。
- 不同功能页之间只有内容不同，骨架、间距、材质完全一致。
- **页面自身不铺背景材质**：内容直接落在 `NavigationSplitView` 的 detail 列上，由窗口兜底；玻璃只出现在 `SettingsCard` 这一层。给整页加 `.background { glassEffect / regularMaterial }` 会把页面变成一张大卡片，`List` 的 `Section` 头随之读成色带，和其余页面对不上。

Liquid Glass 只用于导航、操作和内容分组表面。内容本身保持安静，避免多层玻璃嵌套、过度着色或额外装饰。

## 2. 设计令牌（Design Tokens）

所有数值与样式以下表为准，不要自行发挥：

| 元素 | 值 |
| --- | --- |
| 页头标题 | `.font(.system(size: 30, weight: .bold))` |
| 页头副标题 | 默认正文 + `.foregroundStyle(.secondary)`，与标题间距 5 |
| 页面外边距 | `.padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)` |
| 页头与卡片之间 / 卡片之间间距 | `24` |
| 卡片背景 | macOS 26：`.glassEffect(.regular)`；macOS 15–25：`.regularMaterial` |
| 卡片圆角 | macOS 26：20；macOS 15–25：16，均为 continuous |
| 卡片描边 | macOS 26：由系统玻璃渲染；macOS 15–25：`.strokeBorder(.primary.opacity(0.07))` |
| 卡片阴影 | macOS 26：由系统玻璃渲染；macOS 15–25：`.shadow(color: .black.opacity(0.035), radius: 8, y: 3)` |
| 卡片内边距 | `20` |
| 卡片内部间距 | `14` |
| 卡片内小节标题 | `.font(.headline)` |
| 说明 / 提示文字 | `.font(.subheadline)` 或 `.font(.caption)` + `.foregroundStyle(.secondary)` |
| 启用类开关 | `.toggleStyle(.switch)` |
| 主操作按钮 | `macPilotProminentButtonStyle()`（macOS 26 为 `glassProminent`，旧系统为 `borderedProminent`） |
| 分类选中态 | `SettingsSelectionPill` / `RightClickSettingsSelectionPill` |
| 设置页滑块 | `SettingsSlider`（轨道高 5、滑块直径 18、控件高 22，accent 已选区间；禁止用带 `step` 的系统 `Slider`，会渲染成刻度线） |
| 权限 / 警告内联提示框 | 背景 `.orange.opacity(0.1)` + 圆角 10 + 描边 `.orange.opacity(0.35)` |

## 3. 页面结构（标准模板）

新增功能页必须使用下面的骨架（所有值来自上面的令牌表，不许改）：

```swift
struct 新功能SettingsView: View {
    // @EnvironmentObject model / @ObservedObject 功能model 等按需注入

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 1) 页头
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("xxx")).font(.system(size: 30, weight: .bold))
                    Text(model.t("xxxSubtitle")).foregroundStyle(.secondary)
                }

                // 2) 一个逻辑分组一张卡片
                SettingsCard {
                    Text(model.t("xxxGroupTitle")).font(.headline)
                    Toggle(model.t("xxxEnable"), isOn: ...).toggleStyle(.switch)
                    Text(model.t("xxxHint")).font(.caption).foregroundStyle(.secondary)
                }

                SettingsCard {
                    // 更多控件...
                }
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
    }
}
```

## 4. 复用组件

必须复用以下组件，禁止重新写一套卡片样式：

- **`SettingsCard`**（主模块）：`Sources/MacPilot/SettingsUI.swift`
- **`SettingsSlider`**（主模块）：`Sources/MacPilot/SettingsUI.swift`——设置页滑块统一用它，自带步进取整、键盘微调与 VoiceOver 支持
- **`RightClickSettingsCard`**（MacPilotRightClickKit 模块）：`Sources/MacPilotRightClickKit/Settings/RightClickSettingsCard.swift`
  - Kit 是独立模块，无法使用主模块组件，因此本地复制了一份；两处必须保持视觉一致。
- 需要新组件时：优先基于现有设计令牌扩展；新组件放入 `Sources/MacPilot/`（主模块）并注明用途。

### 列表的处理

**应用/规则类的可排序列表：使用原生全高 `List` 作为页面滚动容器，不要包进卡片、不要套 `ScrollView`。**
把 `List` 直接放在页头下方，让它占满剩余高度（父容器已给 `maxHeight: .infinity`），否则会出现嵌套/多余的滚动条：

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 0) {
        // 页头（30pt 标题 + 副标题，自带 36/34/22 内边距）
        List {
            Section(标题) {
                ForEach(items) { item in ... }
                    .onMove { ... }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }
}
```

- 列表是页面唯一的滚动容器，只显示一条原生滚动条。
- 不要在列表外加 `ScrollView`，也不要给列表设固定 `minHeight`。
- 列表上方的少量设置控件（如折叠开关、添加按钮）放在页头与列表之间的普通行里。

### 「总览 + 列表」三段骨架

内存监控、CPU 监控、本地端口三页共用同一个纵向结构，顺序和边距都不许变：

```swift
VStack(alignment: .leading, spacing: 0) {
    // 1) 页头：36 / 34 / 22
    if 已经拿到数据 {
        SettingsCard { … }                                   // 2) 总览卡
            .padding(.horizontal, 36).padding(.bottom, 16)
    }
    HStack(spacing: 12) {                                    // 3) 列表控制行
        VStack(alignment: .leading, spacing: 2) {
            Text(列表标题).font(.headline).accessibilityAddTraits(.isHeader)
            Text(最后更新).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 16)
        TextField(搜索, …).textFieldStyle(.roundedBorder).frame(width: 180...200)
        Button(刷新) { … }.fixedSize()
    }
    .padding(.horizontal, 36).padding(.bottom, 12)
    List { … }        // 行：listRowInsets(7/14/7/14) + listRowSeparator(.hidden)
}
```

- 总览卡**只在真的拿到数据之后**出现：首轮采样没落地时显示一排 0 就是谎报。
- 卡片里 label 用 `.subheadline` + secondary、value 用 `.subheadline.monospacedDigit().weight(.medium)`，两列 `GridItem(.flexible(), spacing: 24)`；要保留状态色就在值前放 8pt 圆点（见 `pressureValue`），不要把整行染色。
- 加载态与空态是列表里的一行居中文字，不是整页 `ProgressView` / `ContentUnavailableView`——否则数据落地时整页骨架会跳版。
- 行不要加 `.listRowBackground(Color.clear)`：`List` 自己负责层次，抹掉行背景会让 `Section` 头读成色带。

### 首页功能网格

首页（`HomeView`）是唯一不使用「一张卡片装一组控件」的页面：每个功能是一张独立的开关卡片，按自适应网格排列。

- 卡片列用 `GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)`；列数随窗口宽度自动变化（默认窗口两列，拉宽后三列、四列），**不要写死列数**。
- 每张卡片用 `SettingsCard(accented:)`：`accented == true`（功能已开启）时仅在描边上加一层 accent，不换材质、不加内边距，也不要在卡片外面再套一层玻璃（避免多层玻璃嵌套）。
- 卡片内部结构固定：第一行是 34pt 圆角图标底座 + 右侧 `.toggleStyle(.switch)` 开关；第二行是 `.body.weight(.semibold)` 标题 + `.caption` 说明。说明文字用 `.lineLimit(3, reservesSpace: true)` 保证同一行卡片等高。
- 分组标题（如「自动化」「效率工具」）以 `.font(.headline)` 直接放在网格上方，不放进卡片——网格本身已经是卡片，再套一层就是嵌套玻璃。

### 功能总开关只在首页

**一个功能的总开关只有一个，就在首页。详情页不要再放「启用本功能」这类总开关。**

- 详情页只有在功能已开启时才可达（`isSectionAvailable`），所以在详情页上它永远是开着的；再放一个总开关只会和首页互相打架。
- 详情页里**保留**语义不同的开关：
  - 子功能开关，例如屏幕录制的「启用定时截屏」、截屏的「启用截图功能」之外的各项参数；
  - 暂停类开关，例如退出规则页的「规则执行中 / 已暂停」、启动页的「启动计划已启用 / 已暂停」。
- 功能模型内部仍保留 `settings.isEnabled` 作为运行时镜像，由 `MacPilotModel.prepareFeatureForUserEnable(_:)` 在首页打开时置位；
  历史配置里关掉的总开关由 `StoredConfiguration.aligningHomeControlledSwitches()` 在启动时按首页状态校正，
  所以**新增这类功能时必须同时更新这两处**，否则会出现「首页开着、功能却没启动」。

## 5. 特殊情况

| 场景 | 处理方式 |
| --- | --- |
| 多标签 / 多分类功能（画中画分类栏、右键菜单标签页） | **保留**导航栏，但页头、卡片、间距必须与全局一致 |
| 模态编辑弹窗（RuleEditor、EditAppSheet 等） | 允许使用独立表单/弹窗风格，不强制卡片 |
| 权限/警告内联提示 | 用「2. 令牌表」中的橙色提示框样式 |
| 侧边栏（Sidebar） | 使用 `NavigationSplitView` + `.sidebar` `List`，不要手写选中背景；按功能域分组 |

## 6. 文案

- 所有用户可见文案必须走 `AppText.value(_:language:)`（主模块）或 `AppLocalization`（Kit），**中英文同步维护**。
- 不要在 View 里硬编码用户可见字符串。

## 7. 新功能检查清单（提交前逐项自检）

- [ ] 页头：30pt 粗体标题 + 副标题（secondary）
- [ ] 内容全部放进 `SettingsCard`（主模块用 `SettingsCard`，Kit 用 `RightClickSettingsCard`）
- [ ] 页面没有自行铺整页背景材质：玻璃只在 `SettingsCard` 这一层
- [ ] 统计/总览是卡片里的 label-value 网格，不是页头下方的裸文本行；列表上方有 `.headline` 标题行
- [ ] 外边距 `36 / 34 / 30`，卡片间距 `24`
- [ ] 卡片内小节标题用 `.font(.headline)`，说明文字用 `caption/subheadline` + `secondary`
- [ ] 启停开关用 `.toggleStyle(.switch)`
- [ ] 功能总开关只放在首页，详情页不再放「启用本功能」开关（子功能 / 暂停开关除外）
- [ ] 主操作按钮使用 `macPilotProminentButtonStyle()`；多分类选中态使用统一 selection pill
- [ ] 应用/规则列表用原生全高 `List`（不嵌卡片、不加 `ScrollView`/`minHeight`，避免嵌套滚动条）
- [ ] 文案走 `AppText`/`AppLocalization`，中英文同步
- [ ] macOS 26 Liquid Glass 与 macOS 15 fallback 都能编译；深色 / 浅色模式正常
- [ ] `swift build` 通过；`swift test` 无新增失败
