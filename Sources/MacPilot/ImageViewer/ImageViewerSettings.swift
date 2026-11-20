import Foundation

/// Which wheel gesture changes images. The other one zooms.
enum ImageViewerScrollBehavior: String, Codable, CaseIterable, Identifiable {
    /// A plain wheel scroll changes images; Option+scroll zooms.
    case scrollNavigates
    /// Option+scroll changes images; a plain wheel scroll zooms. This keeps the
    /// viewer's historical behavior for existing installations.
    case optionScrollNavigates

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .scrollNavigates: "viewerScrollModeScroll"
        case .optionScrollNavigates: "viewerScrollModeOption"
        }
    }
}

struct ImageViewerSettings: Codable, Equatable {
    var scrollBehavior: ImageViewerScrollBehavior

    init(scrollBehavior: ImageViewerScrollBehavior = .optionScrollNavigates) {
        self.scrollBehavior = scrollBehavior
    }

    private enum CodingKeys: String, CodingKey {
        case scrollBehavior
    }

    /// A missing key and an unknown stored value both keep the installation
    /// default. Throwing here would take the whole section down with it after a
    /// downgrade, so this follows the `QuickSearchSettings` pattern.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stored = try? container.decodeIfPresent(ImageViewerScrollBehavior.self, forKey: .scrollBehavior) {
            scrollBehavior = stored
        } else {
            scrollBehavior = .optionScrollNavigates
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scrollBehavior, forKey: .scrollBehavior)
    }
}
