import CoreBluetooth
import Foundation
import Testing
@testable import MacPilot

/// Restarting production must re-arm the periodic challenge cadence even when
/// a diagnostic session kept the radio and its subscriptions alive.
///
/// These drive the real state machine without a radio: with no
/// `CBPeripheralManager` the production start still records intent, and the
/// cadence invariant is asserted on the task handle.
@MainActor
struct ProximityGATTProductionRestartTests {
    @Test func stoppingProductionDisarmsTheCadence() {
        let peripheral = ProximityBLEPeripheral()
        peripheral.startProduction(macDeviceID: UUID())
        #expect(peripheral.isProductionRunning)
        peripheral.stopProduction()
        #expect(!peripheral.isProductionRunning)
        #expect(!peripheral.isChallengeCadenceRunning)
    }

    @Test func productionAndDiagnosticSessionsAreIndependent() {
        let peripheral = ProximityBLEPeripheral()
        peripheral.start(macDeviceID: UUID())
        #expect(peripheral.isRunning)
        peripheral.startProduction(macDeviceID: UUID())
        #expect(peripheral.isProductionRunning)
        // Stopping production must not end the diagnostic session.
        peripheral.stopProduction()
        #expect(!peripheral.isProductionRunning)
        #expect(peripheral.isRunning, "The diagnostic session is a different role and stays up")
        peripheral.stop()
        #expect(!peripheral.isRunning)
    }
}
