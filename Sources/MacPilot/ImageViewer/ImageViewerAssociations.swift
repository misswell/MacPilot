import AppKit
import Combine
import UniformTypeIdentifiers

struct ImageViewerAssociationFormat: Identifiable {
    let type: UTType
    let extensions: [String]

    var id: String { type.identifier }
    var title: String { extensions.map { $0.uppercased() }.joined(separator: " / ") }

    static let supported: [Self] = {
        let extensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp",
                          "ico", "icns", "avif", "jxl", "jp2", "j2k", "dng", "raw", "cr2", "nef", "arw",
                          "orf", "rw2", "pdf"]
        return catalog(extensions, resolve: { UTType(filenameExtension: $0) })
    }()

    static func catalog(_ extensions: [String], resolve: (String) -> UTType?) -> [Self] {
        var formats: [Self] = []
        for suffix in extensions {
            guard let type = resolve(suffix), !type.isDynamic,
                  type != .image, type != .rawImage, type == .pdf || type.conforms(to: .image) else { continue }
            if let index = formats.firstIndex(where: { $0.type == type }) {
                formats[index] = Self(type: type, extensions: formats[index].extensions + [suffix])
            } else {
                formats.append(Self(type: type, extensions: [suffix]))
            }
        }
        return formats
    }
}

@MainActor
struct ImageViewerAssociationSystem {
    let defaultApplication: (UTType) -> URL?
    let applications: (UTType) -> [URL]
    let setDefaultApplication: (URL, UTType) async throws -> Void
    let macPilotURL: URL?

    static var live: Self {
        let bundle = Bundle.main
        return Self(
            defaultApplication: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
            applications: { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
            setDefaultApplication: { try await NSWorkspace.shared.setDefaultApplication(at: $0, toOpen: $1) },
            macPilotURL: bundle.bundleURL.pathExtension == "app" ? bundle.bundleURL : nil
        )
    }
}

@MainActor
final class ImageViewerAssociations: ObservableObject {
    enum Notice: Equatable {
        case changed
        case unchanged
        case cancelled
        case failed(String)
    }

    struct Row: Identifiable {
        let format: ImageViewerAssociationFormat
        let current: URL?
        let choices: [URL]
        let macPilot: URL?
        var id: String { format.id }
    }

    private let formats: [ImageViewerAssociationFormat]
    private let system: ImageViewerAssociationSystem
    @Published private(set) var rows: [Row] = []
    @Published private(set) var isApplying = false
    @Published private(set) var notices: [String: Notice] = [:]

    init(formats: [ImageViewerAssociationFormat] = ImageViewerAssociationFormat.supported,
         system: ImageViewerAssociationSystem = .live) {
        self.formats = formats
        self.system = system
    }

    func refresh() {
        guard !isApplying else { return }
        notices = [:]
        rows = formats.map(read)
    }

    func change(_ id: String, to app: URL) async {
        guard !isApplying, let row = rows.first(where: { $0.id == id }),
              row.choices.contains(app), row.current != app else { return }
        let currentRow = read(row.format)
        guard currentRow.choices.contains(app), currentRow.current != app else {
            update(currentRow)
            return
        }

        isApplying = true
        notices[id] = nil
        defer { isApplying = false }
        var failure: Notice?
        do {
            try await system.setDefaultApplication(app, row.format.type)
        } catch {
            let details = error as NSError
            if error is CancellationError || (details.domain == NSCocoaErrorDomain && details.code == NSUserCancelledError) {
                failure = .cancelled
            } else {
                failure = .failed(error.localizedDescription)
            }
        }
        let updated = read(row.format)
        update(updated)
        notices[id] = failure ?? (updated.current == app ? .changed : .unchanged)
    }

    private func update(_ row: Row) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row }
    }

    private func read(_ format: ImageViewerAssociationFormat) -> Row {
        let current = system.defaultApplication(format.type).map(Self.canonicalURL)
        let macPilot = system.macPilotURL.map(Self.canonicalURL)
        var choices = system.applications(format.type).map(Self.canonicalURL)
        if let macPilot { choices.insert(macPilot, at: 0) }
        if let current { choices.append(current) }
        var seen: Set<URL> = []
        return Row(format: format, current: current, choices: choices.filter { seen.insert($0).inserted }, macPilot: macPilot)
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
