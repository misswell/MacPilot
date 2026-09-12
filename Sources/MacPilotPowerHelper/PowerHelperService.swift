import Foundation
import MacPilotPowerIPC
import OSLog
import Security

/// The XPC listener delegate. One instance is exported to every trusted
/// connection; all work runs on a private serial queue.
final class PowerHelperService: NSObject, NSXPCListenerDelegate, MacPilotPowerHelperProtocol {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "PowerHelper")
    private let manager: SleepDisabledManager
    private let queue = DispatchQueue(label: "com.misswell.macpilot.powerhelper.xpc")

    init(manager: SleepDisabledManager) {
        self.manager = manager
        super.init()
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard Self.isTrustedClient(newConnection) else {
            logger.error("Rejected XPC connection from pid \(newConnection.processIdentifier, privacy: .public)")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: MacPilotPowerHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        logger.notice("Accepted XPC connection from pid \(newConnection.processIdentifier, privacy: .public)")
        return true
    }

    // MARK: - MacPilotPowerHelperProtocol

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async { [manager] in
            let result = disabled ? manager.enable() : manager.disable()
            switch result {
            case .success:
                reply(true, nil)
            case .failure(let error):
                reply(false, error.message)
            }
        }
    }

    func getSleepDisabled(reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async { [manager] in
            guard let value = manager.currentSystemSleepDisabled() else {
                reply(false, "Could not read the current SleepDisabled setting.")
                return
            }
            reply(value, nil)
        }
    }

    func heartbeat(reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [manager] in
            manager.recordHeartbeat()
            reply(manager.isOwned)
        }
    }

    // MARK: - Client validation

    /// Only code signed by the MacPilot team with an allow-listed bundle
    /// identifier may talk to the helper. Nothing is derived from the
    /// connection's own claims about itself.
    static func isTrustedClient(_ connection: NSXPCConnection) -> Bool {
        let attributes = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return false }
        guard let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              teamIdentifier == MacPilotPowerService.teamIdentifier else { return false }
        guard let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
              MacPilotPowerService.allowedClientBundleIdentifiers.contains(identifier) else { return false }
        return true
    }
}
