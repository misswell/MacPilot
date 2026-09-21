import Foundation
import Testing
@testable import MacPilotLocalPortsCore

struct LocalPortOwnerInferenceTests {
    @Test func projectEvidenceWinsOverParentApplication() {
        let process = makeProcess(command: "node", path: "/Applications/Code.app/Contents/MacOS/Code")
        let project = LocalPortProject(name: "PhotoVault", root: "/tmp/PhotoVault", marker: "package.json", markerPath: "/tmp/PhotoVault/package.json")
        let application = LocalPortOwnerInference.application(for: process, parents: [])
        let owner = LocalPortOwnerInference.infer(process: process, project: project, application: application)

        #expect(owner.category == .project)
        #expect(owner.label == "PhotoVault")
    }

    @Test func appProcessIsDetectedAsProtectedOwner() {
        let process = makeProcess(command: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari")
        let application = LocalPortOwnerInference.application(for: process, parents: [])
        #expect(application?.direct == true)
        #expect(application?.path == "/Applications/Safari.app")
        let owner = LocalPortOwnerInference.infer(process: process, project: nil, application: application)
        #expect(owner.category == .application)
    }

    @Test func parentAppAndUnknownProcessesAreClassified() {
        let process = makeProcess(command: "node", path: "/opt/homebrew/bin/node")
        let parent = makeProcess(command: "Code", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron")
        let application = LocalPortOwnerInference.application(for: process, parents: [parent])
        #expect(application?.direct == false)
        #expect(application?.sourcePID == parent.pid)

        let owner = LocalPortOwnerInference.infer(process: process, project: nil, application: application)
        #expect(owner.category == .application)
        #expect(owner.reason == .parentApplication(pid: parent.pid, path: "/Applications/Visual Studio Code.app"))

        let unknown = makeProcess(command: "mystery-service", path: "/tmp/mystery-service")
        #expect(LocalPortOwnerInference.infer(process: unknown, project: nil, application: nil).category == .unknown)
    }

    @Test func nodeAndPythonEvidenceUsesUsefulNames() {
        let node = makeProcess(
            command: "node",
            path: "/opt/homebrew/bin/node",
            arguments: "/opt/homebrew/bin/node /Users/me/node_modules/@scope/tool/bin/server.js"
        )
        let nodeOwner = LocalPortOwnerInference.infer(process: node, project: nil, application: nil)
        #expect(nodeOwner.label == "@scope/tool")
        #expect(nodeOwner.category == .service)

        let python = makeProcess(
            command: "python3",
            path: "/usr/bin/python3",
            arguments: "python3 -m http.server 8765"
        )
        let pythonOwner = LocalPortOwnerInference.infer(process: python, project: nil, application: nil)
        #expect(pythonOwner.label == "HTTP Server")
    }

    @Test func knownServicesAndSystemExecutablesAreClassified() {
        let redis = makeProcess(command: "redis-server", path: "/opt/homebrew/bin/redis-server")
        let redisOwner = LocalPortOwnerInference.infer(process: redis, project: nil, application: nil)
        #expect(redisOwner.label == "Redis")

        let system = makeProcess(command: "launchd", path: "/sbin/launchd")
        let systemOwner = LocalPortOwnerInference.infer(process: system, project: nil, application: nil)
        #expect(systemOwner.category == .systemService)

        let ollama = makeProcess(command: "ollama", path: "/opt/homebrew/bin/ollama")
        #expect(LocalPortOwnerInference.infer(process: ollama, project: nil, application: nil).label == "Ollama")
    }

    @Test func nodePackageLocatorHandlesScopedAndPnpmLayouts() {
        let scoped = LocalPortNodePackageLocator.locate(
            inPath: "/x/node_modules/@scope/tool/bin/cli.js",
            resolvingSymlinks: false
        )
        #expect(scoped?.name == "@scope/tool")
        #expect(scoped?.directory == "/x/node_modules/@scope/tool")

        let pnpm = LocalPortNodePackageLocator.locate(
            inPath: "/p/node_modules/.pnpm/vite@5/node_modules/vite/bin/vite.js",
            resolvingSymlinks: false
        )
        #expect(pnpm?.name == "vite")
        #expect(pnpm?.directory == "/p/node_modules/.pnpm/vite@5/node_modules/vite")
        #expect(LocalPortNodePackageLocator.locate(inPath: "/p/node_modules/.bin/vite", resolvingSymlinks: false) == nil)
    }

    private func makeProcess(
        command: String,
        path: String?,
        arguments: String? = nil
    ) -> LocalPortProcess {
        LocalPortProcess(
            pid: 42,
            ppid: nil,
            command: command,
            executablePath: path,
            uid: 501,
            user: "me",
            cwd: "/tmp/project",
            arguments: arguments
        )
    }
}
