import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MacPilot

@MainActor
struct ImageViewerAssociationTests {
    @MainActor
    private final class Workspace {
        let macPilot = URL(filePath: "/MacPilot.app", directoryHint: .isDirectory)
        let preview = URL(filePath: "/Preview.app", directoryHint: .isDirectory)
        var defaults: [UTType: URL] = [:]
        var writes: [(app: URL, type: UTType)] = []
        var apply: ((URL, UTType) async throws -> Void)?

        var system: ImageViewerAssociationSystem {
            ImageViewerAssociationSystem(
                defaultApplication: { self.defaults[$0] },
                applications: { _ in [self.preview, self.macPilot, self.preview] },
                setDefaultApplication: { app, type in
                    self.writes.append((app, type))
                    if let apply = self.apply { try await apply(app, type) }
                    else { self.defaults[type] = app }
                },
                macPilotURL: macPilot
            )
        }
    }

    private let formats = [
        ImageViewerAssociationFormat(type: .jpeg, extensions: ["jpg", "jpeg"]),
        ImageViewerAssociationFormat(type: .png, extensions: ["png"])
    ]

    @Test func catalogGroupsAliasesAndRejectsGenericOrUnknownTypes() {
        let catalog = ImageViewerAssociationFormat.catalog(["jpg", "jpeg", "png", "image", "raw", "bin", "unknown"]) {
            switch $0 {
            case "jpg", "jpeg": .jpeg
            case "png": .png
            case "image": .image
            case "raw": .rawImage
            case "bin": .data
            default: nil
            }
        }
        #expect(catalog.map(\.title) == ["JPG / JPEG", "PNG"])
        #expect(ImageViewerAssociationFormat.supported.contains { $0.type == .pdf })
    }

    @Test func refreshingIsReadOnlyAndOneExplicitChoiceChangesOnlyItsType() async throws {
        let workspace = Workspace()
        workspace.defaults = [.jpeg: workspace.preview, .png: workspace.preview]
        let associations = ImageViewerAssociations(formats: formats, system: workspace.system)
        #expect(associations.rows.isEmpty)
        associations.refresh()
        let jpeg = try #require(associations.rows.first)
        #expect(jpeg.current == workspace.preview)
        #expect(jpeg.choices == [workspace.macPilot, workspace.preview])
        #expect(workspace.writes.isEmpty)
        await associations.change(jpeg.id, to: URL(filePath: "/Unknown.app"))
        await associations.change(jpeg.id, to: workspace.preview)
        #expect(workspace.writes.isEmpty)

        await associations.change(jpeg.id, to: workspace.macPilot)
        #expect(workspace.writes.map(\.type) == [.jpeg])
        #expect(associations.rows.map(\.current) == [workspace.macPilot, workspace.preview])
        #expect(associations.notices[jpeg.id] == .changed)

        await associations.change(jpeg.id, to: workspace.preview)
        #expect(workspace.writes.map(\.type) == [.jpeg, .jpeg])
        #expect(associations.rows.map(\.current) == [workspace.preview, workspace.preview])
    }

    @Test func cancellationAndUnconfirmedChangesDoNotReportSuccess() async {
        let workspace = Workspace()
        workspace.defaults[.jpeg] = workspace.preview
        let associations = ImageViewerAssociations(formats: formats, system: workspace.system)
        associations.refresh()
        let jpeg = UTType.jpeg.identifier
        workspace.apply = { _, _ in throw CancellationError() }
        await associations.change(jpeg, to: workspace.macPilot)
        #expect(associations.notices[jpeg] == .cancelled)
        #expect(associations.rows.first?.current == workspace.preview)

        workspace.apply = { _, _ in }
        await associations.change(jpeg, to: workspace.macPilot)
        #expect(associations.notices[jpeg] == .unchanged)
        #expect(!associations.isApplying)
        #expect(associations.rows.first?.current == workspace.preview)
    }

    @Test func aSecondFormatCannotStartWhileSystemConsentIsPending() async {
        let workspace = Workspace()
        workspace.defaults = [.jpeg: workspace.preview, .png: workspace.preview]
        let associations = ImageViewerAssociations(formats: formats, system: workspace.system)
        workspace.apply = { app, type in
            #expect(associations.isApplying)
            await associations.change(UTType.png.identifier, to: app)
            workspace.defaults[type] = app
        }
        defer { workspace.apply = nil }
        associations.refresh()
        await associations.change(UTType.jpeg.identifier, to: workspace.macPilot)
        #expect(workspace.writes.map(\.type) == [.jpeg])
        #expect(associations.rows.map(\.current) == [workspace.macPilot, workspace.preview])
    }
}
