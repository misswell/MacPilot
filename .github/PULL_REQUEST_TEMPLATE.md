<!-- PR 审查必填。与 docs/engineering/AGENT_CHANGE_PROTOCOL.md 的修改前检查一一对应；
     空着或敷衍填写的 PR 不应被合并。CI 的 Regression Gate 会按
     docs/engineering/REGRESSION_INDEX.json 独立选择回归测试，请勿在此伪造「已运行」。 -->

## 根因（Root cause）

<!-- 本次修改解决的真实根因是什么？现象 ≠ 根因。禁止「加了个 if 修了现象」。 -->

<!-- 若是历史问题复发：以前的修复为什么不够？（协议第 2 问，必须回答） -->

## 涉及模块与命中的历史规则

<!-- 对照 docs/engineering/REGRESSION_INDEX.json：命中哪些规则 id（如 menu-002-session-release-vs-action-dispatch）？
     未命中任何规则的源码修改会在 CI 中触发全量安全套件。 -->

## 受影响的其他功能（跨模块影响）

<!-- 改动波及的调用方、共享状态、注册/事件路径；以及异步/生命周期/状态机/资源释放检查清单。 -->

## 是否改变原有架构约束

<!-- 命中模块的不变量（docs/engineering/regressions/<module>.md）是否有例外或调整？逐条说明。 -->

## 测试

- [ ] 新增/修改的测试（先证明旧实现失败、新实现通过）
- [ ] 已运行的历史回归（列出套件名与结果；本地 `bash Scripts/run-regressions.sh`）
- [ ] CI Regression Gate 结果

## 性能影响

<!-- 定时器/监听器/事件 tap/后台任务的数量变化；有无新增的每帧或高频路径。 -->

## 资源生命周期影响

<!-- 异步任务取消路径、对象存活期、缓存释放；功能关闭后是否真正停止工作。 -->

## 真实设备验收

<!-- 对照 docs/engineering/acceptance/hardware-acceptance.md：哪些项已实机执行、
     哪些保持「待验收」？不得用 mock 通过冒充实机通过。 -->

## 尚未验证的风险（如实列出）

<!-- 不确定的行为、无法自动化覆盖的场景、需要后续观察的点。没有就写「无」。 -->
