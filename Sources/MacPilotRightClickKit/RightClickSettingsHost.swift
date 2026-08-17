import SwiftUI

/// Public bridge for embedding the RClick settings UI in MacPilot.
///
/// The individual RClick settings views intentionally remain module-private;
/// exposing one host keeps the integration surface small while still giving
/// the main app access to the complete configuration UI.
public struct RightClickSettingsHost: View {
    public init() {}

    public var body: some View {
        RightClickSettingsView()
            .environmentObject(AppState.shared)
    }
}
