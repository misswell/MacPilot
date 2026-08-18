# MacPilot 界面设计规范（UI Design Spec）

> 所有功能页必须遵循本规范。新增功能、修改既有功能界面时，按本规范执行，
> 并对照文末的「新功能检查清单」自检后再提交。

## 1. 设计语言

MacPilot 的界面统一采用 **「大标题页头 + 毛玻璃卡片」** 的视觉语言：

- 每个功能页顶部是 **30pt 粗体大标题 + 副标题**。
- 页面内容按逻辑分组，放入 **毛玻璃卡片（SettingsCard）** 中。
- 卡片内的小节标题使用 `headline`。
- 不同功能页之间只有内容不同，骨架、间距、材质完全一致。

## 2. 设计令牌（Design Tokens）

所有数值与样式以下表为准，不要自行发挥：

| 元素 | 值 |
| --- | --- |
| 页头标题 | `.font(.system(size: 30, weight: .bold))` |
| 页头副标题 | 默认正文 + `.foregroundStyle(.secondary)`，与标题间距 5 |
| 页面外边距 | `.padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)` |
| 页头与卡片之间 / 卡片之间间距 | `24` |
| 卡片背景 | `.regularMaterial` |
| 卡片圆角 | `RoundedRectangle(cornerRadius: 16, style: .continuous)` |
| 卡片描边 | `.strokeBorder(.primary.opacity(0.07))` |
| 卡片阴影 | `.shadow(color: .black.opacity(0.035), radius: 8, y: 3)` |
| 卡片内边距 | `20` |
| 卡片内部间距 | `14` |
| 卡片内小节标题 | `.font(.headline)` |
| 说明 / 提示文字 | `.font(.subheadline)` 或 `.font(.caption)` + `.foregroundStyle(.secondary)` |
| 启用类开关 | `.toggleStyle(.switch)` |
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

## 5. 特殊情况

| 场景 | 处理方式 |
| --- | --- |
| 多标签 / 多分类功能（画中画分类栏、右键菜单标签页） | **保留**导航栏，但页头、卡片、间距必须与全局一致 |
| 模态编辑弹窗（RuleEditor、EditAppSheet 等） | 允许使用独立表单/弹窗风格，不强制卡片 |
| 权限/警告内联提示 | 用「2. 令牌表」中的橙色提示框样式 |
| 侧边栏（Sidebar） | 保持现有样式，不在本规范范围内 |

## 6. 文案

- 所有用户可见文案必须走 `AppText.value(_:language:)`（主模块）或 `AppLocalization`（Kit），**中英文同步维护**。
- 不要在 View 里硬编码用户可见字符串。

## 7. 新功能检查清单（提交前逐项自检）

- [ ] 页头：30pt 粗体标题 + 副标题（secondary）
- [ ] 内容全部放进 `SettingsCard`（主模块用 `SettingsCard`，Kit 用 `RightClickSettingsCard`）
- [ ] 外边距 `36 / 34 / 30`，卡片间距 `24`
- [ ] 卡片内小节标题用 `.font(.headline)`，说明文字用 `caption/subheadline` + `secondary`
- [ ] 启停开关用 `.toggleStyle(.switch)`
- [ ] 应用/规则列表用原生全高 `List`（不嵌卡片、不加 `ScrollView`/`minHeight`，避免嵌套滚动条）
- [ ] 文案走 `AppText`/`AppLocalization`，中英文同步
- [ ] 深色 / 浅色模式都正常（毛玻璃材质自动适配）
- [ ] `swift build` 通过；`swift test` 无新增失败
