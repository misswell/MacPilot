# Awake P0 手工验收

这些场景依赖真实的 macOS 电源与显示器状态，不能完全由 Swift Testing 自动化。

1. 在菜单栏选择「保持唤醒」后运行 `pmset -g assertions`，确认出现 `PreventUserIdleSystemSleep`；重复点击不会产生额外 assertion。
2. 保持「允许显示器休眠」开启，等待系统显示器休眠超时：显示器可以关闭，但系统不会因 idle 进入 system sleep。
3. 选择自定义时长 1 分钟，确认约 60 秒后菜单栏恢复非 Awake 状态，`pmset -g assertions` 中的 Awake assertion 消失。
4. 在 Awake 设置中选择「直到指定时间」，设置一个临近时间，确认到点后 Session 和 assertion 都结束；手动修改系统时间后重新打开设置也应立即刷新。
5. Session 运行期间让 Mac 睡眠再唤醒；唤醒后若 Session 已到期，应立即结束，否则 assertion 继续按当前 Session 聚合状态保持。
6. 在电池电量低于阈值的 Mac 上开启电量保护，确认所有 Awake Session 自动结束；关闭保护后不应自动恢复已经结束的 Session。

退出 MacPilot 后再次运行，确认上一次手动 Awake Session 不会恢复；这是 P0 的默认启动策略。

## Awake P1 自动规则

7. 在 Awake 设置的「自动规则」中新增 Process Running 规则，填写 `claude`，保持「阻止系统休眠」开启。启动并退出 Claude CLI，确认规则分别创建和结束 Trigger Session；重复进程事件不应创建多个 Session。
8. 新增 Application Running 或 Application Frontmost 规则，填写目标应用的 Bundle ID。启动或切换到该应用后，确认规则状态和 Session 详情显示自动规则来源。
9. 新增 Power Adapter Connected 规则。插入和拔出电源适配器，确认对应 Trigger Session 随电源状态开始和结束。
10. 新增 External Display 规则并设为至少 1 台。插拔外接显示器，确认 Session 随显示器重配置事件开始和结束。
11. 为任一规则设置启动/停止延迟：状态短暂变化不应闪断 Session；持续超过延迟后才应切换状态。
12. 停用或删除最后一个使用 Process、Power 或 Display 的规则，确认对应 Monitor 停止；没有相关规则时不应持续轮询这些系统状态。
