#!/bin/zsh
set -euo pipefail
# Preparation only. The build/sign/run operations belong to the build worker.
# Usage: prepare-host.sh /absolute/new/temp/package
TASK_REPO_ROOT="${0:A:h:h:h:h}"
TASK_HOST_ROOT="${1:?Provide a new absolute temporary package path}"
[[ "$TASK_HOST_ROOT" == /* && ! -e "$TASK_HOST_ROOT" ]] || {
    echo "Expected a new absolute path" >&2
    exit 1
}
mkdir -p "$TASK_HOST_ROOT/Sources/ReverseGATTHardwareHost"
cp "$TASK_REPO_ROOT/Sources/MacPilot/BLE/ProximityBLEPeripheral.swift" "$TASK_HOST_ROOT/Sources/ReverseGATTHardwareHost/ProximityBLEPeripheral.swift"
cp "$TASK_REPO_ROOT/Tests/Hardware/ReverseGATT/main.swift" "$TASK_HOST_ROOT/Sources/ReverseGATTHardwareHost/Host.swift"
python3 - "$TASK_HOST_ROOT/Package.swift" "$TASK_REPO_ROOT/Packages/MacPilotRemoteProtocol" <<'PYTHON'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text("""// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ReverseGATTHardwareHost",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: """ + json.dumps(sys.argv[2]) + """)],
    targets: [.executableTarget(name: "ReverseGATTHardwareHost", dependencies: [
        .product(name: "MacPilotRemoteTransport", package: "MacPilotRemoteProtocol")
    ])]
)
""")
PYTHON
shasum -a 256 "$TASK_REPO_ROOT/Sources/MacPilot/BLE/ProximityBLEPeripheral.swift" "$TASK_HOST_ROOT/Sources/ReverseGATTHardwareHost/ProximityBLEPeripheral.swift"
echo "Prepared $TASK_HOST_ROOT; build, wrap in a distinct LSUIElement app, sign, and run only in AgentSpace."
