import OSLog
import UIKit

/// Bridges the SwiftUI app to the window scene's interface orientation.
///
/// The trackpad page refuses system rotation on principle, with one exception:
/// when the remote keyboard opens while the user holds the phone in a
/// landscape orientation, the scene rotates to that hold so the keyboard
/// rises from the long edge. The supported mask lives in one place so the
/// app delegate and the geometry requests cannot drift apart.
@MainActor
final class InterfaceOrientationController {
    static let shared = InterfaceOrientationController()

    private static let logger = Logger(subsystem: "com.misswell.macpilot.remote", category: "Trackpad")

    /// The interface orientations the app currently admits. Outside the
    /// trackpad page an iPad rotates freely; an iPhone stays portrait.
    private(set) var supportedMask: UIInterfaceOrientationMask = InterfaceOrientationController.baseMask

    /// The resting mask: iPads get every orientation but upside down, phones
    /// stay portrait — the remote actions are designed one-handed.
    static var baseMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .allButUpsideDown : .portrait
    }

    func setSupported(_ mask: UIInterfaceOrientationMask) {
        guard mask != supportedMask else { return }
        supportedMask = mask
        request(mask)
    }

    /// Freezes the scene at its current orientation for the duration of the
    /// trackpad page: rotating the device must never flip the surface under a
    /// finger. On a phone this is simply the portrait lock it always was.
    func freezeCurrentOrientation() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }
        let mask: UIInterfaceOrientationMask
        switch scene.interfaceOrientation {
        case .landscapeLeft: mask = .landscapeLeft
        case .landscapeRight: mask = .landscapeRight
        default: mask = .portrait
        }
        setSupported(mask)
    }

    private func request(_ mask: UIInterfaceOrientationMask) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }
        // SwiftUI's root hosting controller caches its answer; without this
        // invalidation the geometry request below is denied and the scene
        // silently stays portrait.
        for window in scene.windows where window.isKeyWindow {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            Self.logger.error("interface rotation denied: \(String(describing: error), privacy: .public)")
        }
    }

    /// The hold's matching interface orientation: the right-edge-up hold
    /// (`.right`) reads upright as `landscapeRight`, and the left-edge-up
    /// hold as `landscapeLeft`.
    static func mask(for hold: TrackpadOrientation) -> UIInterfaceOrientationMask {
        switch hold {
        case .left: return .landscapeLeft
        case .right: return .landscapeRight
        case .top, .bottom: return .portrait
        }
    }
}

/// Reports the controller's mask so the geometry request is actually honored.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ProximityBLECentral.shared.resumeIfEnabled()
        ReversePresenceCentral.shared.resumeAtLaunch()
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated {
            InterfaceOrientationController.shared.supportedMask
        }
    }
}
