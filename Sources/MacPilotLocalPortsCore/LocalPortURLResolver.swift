import Foundation

public enum LocalPortURLResolver {
    /// Chooses a safe browser probe host from the observed bind addresses.
    /// Wildcard binds are probed through loopback rather than exposing a LAN
    /// address; a concrete address is used only when it is the sole useful
    /// option.
    public static func probeHost(for addresses: [String]) -> String? {
        let normalized = addresses.map { normalize($0) }
        if normalized.contains("127.0.0.1") || normalized.contains("localhost") {
            return "127.0.0.1"
        }
        if normalized.contains("::1") { return "[::1]" }
        if normalized.contains("0.0.0.0") || normalized.contains("*") {
            return "127.0.0.1"
        }
        if normalized.contains("::") { return "[::1]" }

        guard let first = normalized.first(where: { !$0.isEmpty }) else { return nil }
        return first.contains(":") ? "[\(first)]" : first
    }

    public static func url(
        port: Int,
        addresses: [String],
        scheme: String = "http"
    ) -> URL? {
        guard (1...65535).contains(port), let host = probeHost(for: addresses) else { return nil }
        return URL(string: "\(scheme)://\(host):\(port)/")
    }

    public static func isLoopback(_ host: String) -> Bool {
        let normalized = normalize(host)
        return normalized == "127.0.0.1" || normalized == "::1" || normalized == "localhost"
    }

    private static func normalize(_ address: String) -> String {
        address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }
}
