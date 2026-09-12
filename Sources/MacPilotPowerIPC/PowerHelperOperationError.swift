import Foundation

/// Failure raised by a privileged power operation. The message is meant to be
/// shown to the user as-is (it never contains paths, tokens, or user data).
public struct PowerHelperOperationError: Error, Equatable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
