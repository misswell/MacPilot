import Foundation

enum UUDisplayPolicy: String, Codable, CaseIterable, Identifiable {
    case none, keepPhysical, virtualOnly, addVirtual

    var id: String { rawValue }
    var titleKey: String { "displayPolicy_\(rawValue)" }
}

struct DisplayControlSettings: Codable, Equatable {
    var isEnabled = false
    var uuPolicy: UUDisplayPolicy = .none
    var targetUUID = ""
    var virtualWidth = 1920
    var virtualHeight = 1080
    var hiDPI = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case isEnabled, uuPolicy, targetUUID, virtualWidth, virtualHeight, hiDPI
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        uuPolicy = UUDisplayPolicy(rawValue: try c.decodeIfPresent(String.self, forKey: .uuPolicy) ?? "") ?? .none
        targetUUID = try c.decodeIfPresent(String.self, forKey: .targetUUID) ?? ""
        virtualWidth = try c.decodeIfPresent(Int.self, forKey: .virtualWidth) ?? 1920
        virtualHeight = try c.decodeIfPresent(Int.self, forKey: .virtualHeight) ?? 1080
        hiDPI = try c.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? true
    }

    var hasValidVirtualSize: Bool {
        (640...8192).contains(virtualWidth) && (480...8192).contains(virtualHeight)
            && virtualWidth.isMultiple(of: 2) && virtualHeight.isMultiple(of: 2)
    }
}
