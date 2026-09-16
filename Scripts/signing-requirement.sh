#!/bin/zsh
# 全局唯一的 designated requirement（DR）定义。
#
# 为什么必须只有一处、必须显式写死、必须对所有签名身份都用同一串：
#
# 1. macOS 用 DR 认「这还是不是同一个 App」。TCC 在授权那一刻把这串 requirement
#    记下来，之后按它校验候选 App；应用内更新也用它决定「这个更新包是不是同一个
#    身份」（见 Sources/MacPilot/SoftwareUpdate.swift 的 UpdatePackageValidator）。
# 2. 让 codesign 自行推导就会随签名机器、钥匙串内容、证书类型漂移：有 Developer ID
#    中间证书时推导出 Apple 规范形式（带两个 OID 断言 + OU），看不到时退化成
#    「identifier X and anchor apple generic」，Apple Development 证书又会写成
#    带 CN 的另一串。任一处漂移，已经装好的 App 就可能拒绝新包。
# 3. 只钉到「bundle id + 团队 OU」这一层，是为了让四种签名路径产出**逐字节相同**
#    的 DR：Developer ID、Apple Distribution、Apple Development、ad-hoc。
#    本机开发版与 CI 发布版因此互为同一个身份：TCC 授权互通、应用内更新永远匹配。
#    加 Developer ID 专用 OID 断言会把这个统一性打碎（开发证书满足不了它），
#    加 CN 断言同理。别的团队被 OU 这一条挡住，这正是需要保留的强度。
#
# 因此：不要改这串文本，也不要新增任何让某个签名身份单独分支的 requirement。
# Scripts/build-app.sh 签名后、Scripts/distribute-app.sh 打包后、CI 的 dist job
# 发布前都会用 Scripts/verify-signing-requirement.sh 按下面的定义做逐字节校验；
# Tests/MacPilotTests/SigningRequirementTests.swift 里还有一道 tripwire 测试。

MACPILOT_SIGNING_TEAM_ID="U8U443D7ZL"

# $1 = bundle identifier（正式版 com.misswell.macpilot，bridge 版 com.misswell.octopilot）
# 输出不带 "designated => " 前缀，即 `codesign --display -r-` 读回的形式。
macpilot_designated_requirement_body() {
    printf '%s\n' "identifier \"$1\" and anchor apple generic and certificate leaf[subject.OU] = $MACPILOT_SIGNING_TEAM_ID"
}

# $1 = bundle identifier；输出可直接传给 `codesign --requirements "=..."`。
macpilot_designated_requirement() {
    printf '%s\n' "designated => $(macpilot_designated_requirement_body "$1")"
}
