# 更新包下载源

MacPilot 下载本项目 GitHub Release 安装包时，按以下顺序尝试：

1. Xget：`https://xget.xi-xu.me/gh/misswell/MacPilot/releases/download/...`
2. GitHub 原始下载地址（最终兜底）。

每次更新重新尝试镜像，以适应网络变化。单个源连续 15 秒没有网络响应、请求失败、HTTP 状态不是 200，或下载文件的 SHA-256 不匹配时，会自动尝试下一个源。正常持续传输不受 15 秒空闲超时限制。用户取消请求时停止，不继续切换源。所有源失败后显示更新失败，并在诊断日志记录各源失败原因。

版本信息和预期 SHA-256 仍由 GitHub 直接提供；检查更新阶段目前仍需要能够连接 GitHub。Xget 只传输安装包，不能改变预期摘要。下载成功后仍执行应用版本、Developer ID 团队和签名身份校验。第三方地址及其他仓库不会被自动改写为镜像地址。

Xget 地址规则：https://github.com/xixu-me/Xget
