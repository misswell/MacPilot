# docs/engineering — MacPilot 防回归体系

这里存放让「过去修过的 Bug 不再复发」变成可执行机制的全部资产。单一数据源是 `REGRESSION_INDEX.json`：AI 修改前检查、本地回归选择器、CI 门禁共用它，任何地方都不允许另维护一份测试清单。

## 目录

| 文件 | 作用 |
|---|---|
| [REGRESSION_INDEX.json](REGRESSION_INDEX.json) | 机器可读规则索引（id、模块、affected_paths、不变量、测试、人工验收、证据提交）。选择器与 CI 的唯一数据源。 |
| [REGRESSION_CATALOG.md](REGRESSION_CATALOG.md) | 人类可读的历史重复 Bug 目录册：根因、为何旧修复不彻底、最终原则、禁止实现。 |
| [AGENT_CHANGE_PROTOCOL.md](AGENT_CHANGE_PROTOCOL.md) | Agent 修改源码前的强制检查协议（AGENTS.md 引用的完整版）。 |
| [regressions/](regressions/) | 分模块的不变量全文与历史证据（从 AGENTS.md 迁入，AGENTS.md 只留摘要与链接）。 |
| [acceptance/](acceptance/) | 模拟测试无法覆盖的真机/系统版本验收清单；未执行的项目保持「待验收」。 |

## 使用方式

```bash
# 修改前：看本次改动命中哪些历史规则（工作区模式）
python3 Scripts/regression-plan.py --mode local

# 修改后：执行选出的回归（本地工作区）
bash Scripts/run-regressions.sh

# 强制完整安全套件（合并 main / 发版前）
bash Scripts/run-regressions.sh --force-full

# 校验索引引用的测试套件都真实存在（CI 每次都跑）
python3 Scripts/regression-plan.py --validate

# PR 模式（CI 用同一入口）
python3 Scripts/regression-plan.py --mode pr --base origin/main --head HEAD
```

## 「完整测试」的定义

源码修改未命中任何规则时，选择器**默认扩大**到完整安全套件，而不是跳过。完整套件 = 所有规则的 `test_filters` 并集 + `full_suite.baseline_extra_filters`（对应 build.yml 既有安全清单），外加 `package_suites` 与 `extra_commands`。真实锁屏/黑屏/硬件操作永远不属于自动完整套件，见 acceptance/。

## 失败判定与豁免（同一条规则管本地与 CI）

- 每条 `swift test` 命令先做**预检**：`--filter` 必须在测试清单里真实命中，命中 0 条 = 索引写了不存在的套件 = 门禁失败（不是「跳过」）。
- 命令结束后做**后检**：日志里必须有真实执行证据（`✔/✘/Test run with`），只有退出码 0 不算通过。
- 失败测试只有在**同时满足**两条时才允许豁免：① 它逐条列在索引的 `known_flaky_tests`（`Suite.method` 全名）；② 单独 `swift test --filter '<Suite.method>'` 重跑**通过**。豁免会以 `WAIVED:` 打印并计数。
- 未列入清单的失败一律让门禁红；已列入但单独重跑仍红的也一律红。豁免不是为了放行问题，只是把 AGENTS.md 已记录的「共享 main actor 饥饿」类墙钟断言与真实回归区分开——**断言与阈值一个都不改**。
- 新增豁免必须写清同族证据；某条豁免连续多次在隔离环境也失败，说明它已不再是 flake，要当真实缺陷修。

退出码：选择器 `0` 正常 / `1` 计划错误 / `2` 索引无效；执行器 `2` 索引无效 / `3` 计划或枚举失败 / `4` 测试失败。

## 维护规则

- 新增/修改历史规则时同时更新 `REGRESSION_INDEX.json` 与 `REGRESSION_CATALOG.md`，并跑 `--validate`。
- 修一个新 Bug：先查它是否命中既有规则；若是同族复发，把新证据提交 SHA 追加到该规则而不是另开一条。
- 新测试命名沿用行为句式；禁止为通过而删断言。
