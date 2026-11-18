import Foundation

@MainActor
struct ImageViewerWindowRegistry {
    private var controllers: [UUID: ImageViewerWindowController] = [:]
    var all: [ImageViewerWindowController] { Array(controllers.values) }
    var isEmpty: Bool { controllers.isEmpty }

    func window(showing url: URL) -> ImageViewerWindowController? {
        controllers.values.first { $0.browser.url == url }
    }

    mutating func insert(_ controller: ImageViewerWindowController) {
        controllers[controller.id] = controller
    }

    mutating func remove(_ controller: ImageViewerWindowController) {
        controllers.removeValue(forKey: controller.id)
    }
}
