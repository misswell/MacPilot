# acceptance/macos-compatibility — 系统版本兼容矩阵

MacPilot 目标系统为 macOS 14+。以下矩阵按**可实际获得的 CI Runner**建立，不假设存在任何 Beta Runner；不能自动跑的版本明确列为人工验收。

## 自动矩阵（GitHub-hosted runner，已核实的可用标签）

| macOS 版本 | Runner 标签 | 状态 |
|---|---|---|
| macOS 15 | `macos-15` | 自动（regression-gate 矩阵 + 既有 build.yml） |
| macOS 26（当前稳定大版本线） | `macos-26` | 自动（regression-gate 矩阵） |

注：仓库历史上实测过 macOS 27 行为（菜单栏 30pt、menuDidClose 后派发 action、`IOHIDUserDeviceCreate` 拒绝普通进程、TASK_VM_INFO flavor=22）。若 GitHub 提供 `macos-27`（或更新）标签，可在 regression-gate.yml 的 matrix 里追加，无需改索引。

## 人工验收（无 Runner，明确列出、不得伪造通过）

| macOS 版本 | 验收方式 |
|---|---|
| macOS 14（最低支持） | 找一台 14 的实机/虚拟机安装发布 ZIP，跑下方清单；无设备时在 PR 中标注「macOS 14 待验收」 |
| macOS 16–25 各中间版本 | 每个正式 Stable 发布前抽验一次（用户实机） |
| macOS 最新 Beta | 不主动支持；重大系统行为变化（菜单栏几何、TCC、HID 策略）出现时单独评估 |

macOS 14 人工清单（最低目标系统回归）：

1. 安装、首次启动、辅助权限申请。
2. 菜单栏图标出现、菜单打开/点击各项、窗口开合。
3. 快速搜索面板唤起、搜索、打开 app。
4. BLE 配对与一次锁/解锁（授权环境）。
5. 检查更新（不安装）。
6. 退出与重启，配置保留。

## 系统行为差异的历史教训（修改菜单/电源/显示代码时必须意识到的）

- macOS 27：菜单栏 30pt、29pt 按钮、`menuDidClose` 后派发 action（menu-002-session-release-vs-action-dispatch）、TASK_VM_INFO flavor=22（必须校验 `count_out`）、`IOHIDUserDeviceCreate` 对普通进程拒绝（CGEvent 路径是实际出货行为）。
- macOS 14+：激活是协作式（window-lifecycle 的 `orderFrontRegardless` 依据）。
- 任何「在新系统上量出来的几何/时序」只能作为该系统的实测，不得外推为所有版本的行为；新差异记录回本文件。
