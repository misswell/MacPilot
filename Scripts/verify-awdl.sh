#!/bin/zsh
# MacPilot — AWDL (peer-to-peer Wi-Fi) discovery verification.
#
# Answers one question: can an iPhone find and reach this Mac *without* sharing
# a Wi-Fi network? AWDL is what AirDrop/AirPlay/Sidecar use; MacPilot enables it
# via `includePeerToPeer` on the listener and on the iOS browser.
#
# Usage:
#   Scripts/verify-awdl.sh check          # are the Mac-side preconditions met?
#   Scripts/verify-awdl.sh watch [secs]   # which interface do phone connections arrive on?
#
# `watch` is the decisive test. Run it, then put the phone on a *different*
# network (Wi-Fi still ON — turning Wi-Fi off kills AWDL too). If a connection
# arrives whose scope decodes to awdl0, discovery works without a shared LAN.
#
# The scope trick: lsof renders an IPv6 link-local as `fe80:<hex-scope>::...`
# where <hex-scope> is the interface index in hex (12 -> "c" for en0,
# 17 -> "11" for awdl0). Comparing that against the listener's local address
# tells you which interface the connection came in on.

set -uo pipefail

SERVICE="_macpilot._tcp"
PORT="${MACPILOT_REMOTE_PORT:-43847}"
BROWSE_SECONDS=6

iface_index() {
    python3 -c 'import socket,sys;print(socket.if_nametoindex(sys.argv[1]))' "$1" 2>/dev/null
}

# Index -> interface name, e.g. 17 -> awdl0.
iface_name() {
    python3 - "$1" <<'PY'
import socket, subprocess, sys
want = int(sys.argv[1])
for name in subprocess.check_output(["ifconfig", "-l"]).decode().split():
    if socket.if_nametoindex(name) == want:
        print(name)
        break
PY
}

# Hex scope from a link-local as printed by lsof, e.g. "c" -> 12 -> en0.
scope_iface() {
    local hex="$1"
    [[ -z "$hex" ]] && return
    local index
    index=$((16#$hex))
    local name
    name="$(iface_name "$index")"
    print -r -- "${name:-index-$index}"
}

# Browse for the service, printing "iface-index instance-name" per result.
browse() {
    local out
    out="$(mktemp)"
    dns-sd -includeAWDL -B "$SERVICE" >"$out" 2>&1 &
    local pid=$!
    sleep "$BROWSE_SECONDS"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    awk '$2 == "Add" { print $4, $7 }' "$out" | sort -u
    rm -f "$out"
}

cmd_check() {
    local awdl_idx
    awdl_idx="$(iface_index awdl0)"

    print "== MacPilot AWDL 前置检查 ==\n"

    if [[ -z "$awdl_idx" ]]; then
        print "✗ 没有 awdl0 接口：这台机器不支持 AWDL（或 Wi-Fi 被关闭）"
        return 1
    fi
    local awdl_name
    awdl_name="$(iface_name "$awdl_idx")"
    if ifconfig awdl0 2>/dev/null | grep -q "flags=.*UP"; then
        print "✓ awdl0 存在且 UP（interface index $awdl_idx）"
    else
        print "✗ awdl0 存在但未 UP —— Wi-Fi 电台可能被关闭"
        return 1
    fi

    local lladdr
    lladdr="$(ifconfig awdl0 2>/dev/null | awk '/inet6/ && /fe80/ {print $2}')"
    print "  AWDL 链路本地地址：${lladdr:-<无>}"

    print "\n== 服务是否在 awdl0 上广播 ==\n"
    local results
    results="$(browse)"
    if [[ -z "$results" ]]; then
        print "✗ ${BROWSE_SECONDS}s 内没找到 $SERVICE"
        return 1
    fi
    local on_awdl=""
    # Declared once: zsh's `local` re-run on an existing local prints its value.
    local idx name iname
    while read -r idx name; do
        iname="$(iface_name "$idx")"
        if [[ "$idx" == "$awdl_idx" ]]; then
            on_awdl="$name"
            print "✓ $name 在 $iname（index $idx）上广播  ← AWDL 可用"
        else
            print "  $name 在 ${iname:-index-$idx}（index $idx）上广播"
        fi
    done <<<"$results"

    if [[ -z "$on_awdl" ]]; then
        print "\n✗ 服务只在基础设施接口上广播，AWDL 上没有 —— 手机无法脱离同一局域网发现本机"
        return 1
    fi

    # The most faithful check: the same API and flags the iOS app uses.
    print "\n== Network.framework P2P 浏览器（与 App 完全相同的配置）==\n"
    local src="/tmp/macpilot-awdl-browse-$$.swift"
    local bin="/tmp/macpilot-awdl-browse-$$"
    if ! command -v swiftc >/dev/null 2>&1; then
        print "· 没有 swiftc，跳过这一步"
    else
        cat >"$src" <<'SWIFT'
import Foundation
import Network

// Mirrors RemoteDiscoveryService: TCP + includePeerToPeer + TXT records.
let params = NWParameters.tcp
params.includePeerToPeer = true
let browser = NWBrowser(
    for: .bonjourWithTXTRecord(type: "_macpilot._tcp", domain: nil),
    using: params
)
browser.browseResultsChangedHandler = { results, _ in
    for result in results {
        let names = result.interfaces.map { "\($0.name)(idx \($0.index))" }
        print("interfaces: \(names.joined(separator: ", "))")
    }
    exit(0)
}
browser.start(queue: .main)
RunLoop.main.run(until: Date().addingTimeInterval(15))
print("no results")
exit(1)
SWIFT
        local browse_out
        if swiftc -O -o "$bin" "$src" 2>/dev/null; then
            browse_out="$("$bin" 2>/dev/null)"
            if print -r -- "$browse_out" | grep -q "awdl0"; then
                print "✓ 浏览器在 awdl0 上枚举到服务 —— 与 App 同配置，AWDL 结果可达"
            else
                print "✗ 浏览器没有在 awdl0 上枚举到服务"
            fi
            print "  $browse_out"
        else
            print "· swiftc 编译失败，跳过这一步"
        fi
        rm -f "$src" "$bin"
    fi

    print "\n结论：Mac 侧前置条件满足。用 'watch' 模式做端到端确认。"
}

# Decisive test: report which interface each incoming phone connection used.
cmd_watch() {
    local seconds="${1:-90}"
    local awdl_idx
    awdl_idx="$(iface_index awdl0)"
    print "监听 :$PORT 上的入站连接 ${seconds}s（awdl0 index=$awdl_idx, en0 index=$(iface_index en0)）"
    print "现在把手机切到另一个网络（保持 Wi-Fi 打开），然后看下面有没有 awdl0 的连接。\n"

    local seen=""
    local deadline=$((SECONDS + seconds))
    # Declared once: zsh's `local` re-run on an existing local prints its value.
    local line remote_hex local_hex remote_iface local_iface key
    while (( SECONDS < deadline )); do
        while read -r line; do
            remote_hex="$(print -r -- "$line" | sed -nE 's/.*->\[fe80:([0-9a-fA-F]+)::.*/\1/p')"
            local_hex="$(print -r -- "$line" | sed -nE 's/.*\[fe80:([0-9a-fA-F]+)::.*->.*/\1/p')"
            [[ -z "$local_hex" ]] && continue
            remote_iface="$(scope_iface "$remote_hex")"
            local_iface="$(scope_iface "$local_hex")"
            key="$local_iface/$remote_iface"
            [[ "$seen" == *"$key"* ]] && continue
            seen+="$key "
            if [[ "$local_iface" == "awdl0" ]]; then
                print "✓ 连接到达于 awdl0 —— 手机走的是 AWDL（无需同一局域网）"
            else
                print "· 连接到达于 ${local_iface}（对端在 ${remote_iface}）"
            fi
        done < <(lsof -nP -iTCP:"$PORT" 2>/dev/null | grep ESTABLISHED)
        sleep 2
    done

    print ""
    if [[ "$seen" == *"awdl0/"* ]]; then
        print "结论：AWDL 端到端可用。"
    elif [[ -z "$seen" ]]; then
        print "结论：期间没有任何连接。确认手机 App 在前台，且 phone/Mac 距离足够近。"
    else
        print "结论：只看到基础设施接口的连接。AWDL 广播是有的，但手机没走它。"
    fi
}

case "${1:-check}" in
    check) cmd_check ;;
    watch) shift; cmd_watch "${1:-90}" ;;
    *) print -u2 "用法：$0 {check|watch [秒数]}"; exit 2 ;;
esac
