import Foundation
import IOKit.pwr_mgt
import OSLog

struct AwakeAssertionFailure: Error, Equatable, LocalizedError, Sendable {
    enum Kind: String, Sendable {
        case systemSleep
        case displaySleep
    }

    let kind: Kind
    let operation: String
    let code: String

    var errorDescription: String? {
        operation + " (" + kind.rawValue + ", code " + code + ")"
    }
}

@MainActor
protocol AwakeAssertionControlling: AnyObject {
    var isSystemAssertionActive: Bool { get }
    var isDisplayAssertionActive: Bool { get }

    @discardableResult
    func apply(_ desiredState: DesiredAwakeState) -> Result<Void, AwakeAssertionFailure>

    @discardableResult
    func releaseAll() -> Result<Void, AwakeAssertionFailure>
}

/// Owns the process' two ordinary IOKit power assertions.
///
/// The controller deliberately knows nothing about sessions. It only moves
/// the current system state toward the desired aggregate state and keeps the
/// assertion IDs stable across repeated applications.
@MainActor
final class AwakeAssertionController: AwakeAssertionControlling {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.Assertion")
    private let reason = "MacPilot Awake"
    private var systemAssertionID: IOPMAssertionID?
    private var displayAssertionID: IOPMAssertionID?

    var isSystemAssertionActive: Bool { systemAssertionID != nil }
    var isDisplayAssertionActive: Bool { displayAssertionID != nil }

    @discardableResult
    func apply(_ desiredState: DesiredAwakeState) -> Result<Void, AwakeAssertionFailure> {
        var firstFailure: AwakeAssertionFailure?
        if let failure = updateSystemAssertion(enabled: desiredState.preventSystemSleep) {
            firstFailure = failure
        }
        if let failure = updateDisplayAssertion(enabled: desiredState.preventDisplaySleep) {
            firstFailure = firstFailure ?? failure
        }
        if let firstFailure { return .failure(firstFailure) }
        return .success(())
    }

    @discardableResult
    func releaseAll() -> Result<Void, AwakeAssertionFailure> {
        apply(.inactive)
    }

    private func updateSystemAssertion(enabled: Bool) -> AwakeAssertionFailure? {
        updateAssertion(
            enabled: enabled,
            currentID: systemAssertionID,
            kind: .systemSleep,
            assertionType: kIOPMAssertionTypePreventUserIdleSystemSleep
        ) { [weak self] id in
            self?.systemAssertionID = id
        }
    }

    private func updateDisplayAssertion(enabled: Bool) -> AwakeAssertionFailure? {
        updateAssertion(
            enabled: enabled,
            currentID: displayAssertionID,
            kind: .displaySleep,
            assertionType: kIOPMAssertionTypePreventUserIdleDisplaySleep
        ) { [weak self] id in
            self?.displayAssertionID = id
        }
    }

    private func updateAssertion(
        enabled: Bool,
        currentID: IOPMAssertionID?,
        kind: AwakeAssertionFailure.Kind,
        assertionType: String,
        setID: (IOPMAssertionID?) -> Void
    ) -> AwakeAssertionFailure? {
        if enabled {
            guard currentID == nil else { return nil }

            var assertionID = IOPMAssertionID()
            let result = IOPMAssertionCreateWithName(
                assertionType as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else {
                let failure = AwakeAssertionFailure(
                    kind: kind,
                    operation: "IOPMAssertionCreateWithName failed",
                    code: String(describing: result)
                )
                logger.error("\(failure.localizedDescription, privacy: .public)")
                return failure
            }
            setID(assertionID)
            logger.notice("Created \(kind.rawValue, privacy: .public) assertion")
            return nil
        }

        guard let currentID else { return nil }
        let result = IOPMAssertionRelease(currentID)
        guard result == kIOReturnSuccess else {
            let failure = AwakeAssertionFailure(
                kind: kind,
                operation: "IOPMAssertionRelease failed",
                code: String(describing: result)
            )
            logger.error("\(failure.localizedDescription, privacy: .public)")
            return failure
        }
        setID(nil)
        logger.notice("Released \(kind.rawValue, privacy: .public) assertion")
        return nil
    }
}
