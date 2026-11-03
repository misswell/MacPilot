# Agent 修改前强制检查协议（AGENT_CHANGE_PROTOCOL.md）

本协议对所有在 MacPilot 仓库改源码的 Agent（含人）生效。AGENTS.md 的「防回归强制流程」是本协议的入口摘要，以本文件为准。

**不允许只因为用户报告一个现象，就直接在对应位置加一个 `if`。** 历史上 `d080766` 把菜单动作失效误诊成主窗口 opener 问题、`ced94af` 在错误坐标系里调锚点，都是跳过下面流程的直接代价。

## 第一步：定位模块与历史规则

1. 列出本次修改将触碰的文件。
2. 运行 `python3 Scripts/regression-plan.py --mode local --dry-run`（或在心里等价地）比对 `docs/engineering/REGRESSION_INDEX.json` 的 `affected_paths`，得出命中的规则 id。
3. 阅读 `docs/engineering/regressions/<module>.md` 中的不变量；命中窗口/菜单栏/BLE/显示/配置/发布任一 critical 规则时，必须通读对应文档。

## 第二步：查历史提交与 Revert

对每个要改的文件运行（示例）：

```
git log --oneline --no-merges -- Sources/MacPilot/MenuBarDisplayController.swift
git log --oneline --all -i --grep=revert
```

重点识别：同一根因的多次修复、被 Revert 的修复、修复 A 引发 B 的链（目录册 A1/A2 就是样本）。

## 第三步：阅读回归测试

打开命中规则的 `test_filters` 列出的套件，确认：
- 测试覆盖的触发条件与本次修改的触发条件是否同族；
- 是否存在「测试只验证返回值、不验证状态变化」的弱测试。

## 第四步：影响分析（写进 PR 描述）

回答以下问题后才能改代码：

1. 本次修改的**根因**是什么（现象 ≠ 根因）？
2. 历史上是否出现过类似问题？规则 id 是什么？
3. 以前的修复为什么不彻底？本次与它们有什么不同？
4. 哪些**既有功能**可能受影响（共享代码、生命周期、状态机）？
5. 必须运行哪些历史回归测试（由选择器给出）？
6. 是否需要新增测试钉住本次修复？
7. 是否需要真实设备验收（对照 `acceptance/` 两个清单）？

异步/生命周期检查清单（每个涉及对象都必须过一遍）：

- 异步任务的取消路径上，是否还有事件能重新武装它？
- 回调持有的对象生命周期是否超过其正确性所需（弱引用 target、过期 generation）？
- 状态机的每个状态，进入/退出的所有出口是否都恢复不变量（菜单 reattach、显示恢复、BLE 挑战 cadence 的教训）？
- 定时器、监听器、事件 tap、连接是否随功能关闭/对象释放注销？
- 持久化数据结构是否动了已编码键（append-only）？

## 第五步：修改后验证

1. `bash Scripts/run-regressions.sh`（工作区改动）或 `bash Scripts/run-regressions.sh --base <修改前commit>`（按 ref 区间选测试），也可以让 CI 的 `regression-gate` 跑同一套计划。
2. 触发条件可复现的历史 Bug，先证明旧实现失败、新实现通过（新测试先红后绿）。
3. 修复涉及人工验收场景的，在 PR 中明确标注「待实机验收」；不得用 mock 通过冒充实机通过。
4. 门禁红时先看是否打印 `WAIVED`：只有索引 `known_flaky_tests` 里逐条列出、且单独 `swift test --filter 'Suite.method'` 重跑通过的测试才会被豁免。未列出的失败、或单独重跑仍红的「老 flake」，都按真实缺陷处理，禁止靠加豁免清单来放行。

## 禁止事项

- 禁止删断言、降低测试标准或跳过 `--filter` 之外不相关但命中的套件来换 CI 绿灯。
- 禁止把 `REGRESSION_INDEX.json` 的 `test_filters` 改成不存在的套件来缩小范围（`--validate` 会失败）。
- 禁止为让构建通过而弱化签名 requirement、绕过 CI、`--no-verify`。
- 禁止在用户当前会话执行真实锁屏/黑屏/休眠/电源策略变更，或替换 `/Applications/MacPilot.app`。
