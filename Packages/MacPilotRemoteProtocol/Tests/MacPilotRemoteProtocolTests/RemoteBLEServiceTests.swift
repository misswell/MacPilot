import CoreBluetooth
import Foundation
import Testing

@testable import MacPilotRemoteTransport

/// The GATT contract is small but it is a wire contract: the Mac advertises the
/// service and answers the PSM read, and a already-shipped phone app has to agree
/// on both. These tests exist so a change here cannot pass unnoticed.
@Suite("Remote BLE service contract")
struct RemoteBLEServiceTests {
    @Test("a PSM travels as two little-endian bytes")
    func psmIsLittleEndian() {
        let encoded = RemoteBLEService.encodePSM(0x1234)
        #expect(encoded.count == 2)
        #expect(Array(encoded) == [0x34, 0x12])
        // A big-endian slip would hand the phone a PSM that opens nothing.
        #expect(RemoteBLEService.decodePSM(encoded) == 0x1234)
    }

    @Test("every PSM value survives a round trip")
    func psmRoundTrips() {
        for psm: CBL2CAPPSM in [0, 1, 0x007F, 0x0080, 0x00FF, 0x0100, 0x1234, 0x7FFF, 0xFFFF] {
            #expect(RemoteBLEService.decodePSM(RemoteBLEService.encodePSM(psm)) == psm)
        }
    }

    @Test("a PSM is read out of unaligned storage without trapping")
    func decodesFromUnalignedStorage() {
        // Reading a PSM straight out of a received buffer lands on an arbitrary
        // offset, which is why the decoder uses `loadUnaligned` — a plain `load`
        // would trap here and take the connection down with it.
        let padded = Data([0xAA, 0x34, 0x12, 0xBB])
        let slice = padded[(padded.startIndex + 1)...(padded.startIndex + 2)]
        #expect(RemoteBLEService.decodePSM(slice) == 0x1234)
    }

    @Test("a truncated read is rejected instead of guessing")
    func shortReadsAreRejected() {
        #expect(RemoteBLEService.decodePSM(Data()) == nil)
        #expect(RemoteBLEService.decodePSM(Data([0x34])) == nil)
    }

    @Test("trailing bytes do not change the PSM")
    func trailingBytesAreIgnored() {
        #expect(RemoteBLEService.decodePSM(Data([0x34, 0x12, 0xFF, 0xFF])) == 0x1234)
    }

    @Test("the fixed UUIDs are frozen and spell macPilot")
    func uuidsAreFrozen() {
        #expect(RemoteBLEService.serviceUUID == CBUUID(string: "6D616350-696C-6F74-0001-000000000001"))
        #expect(RemoteBLEService.psmCharacteristicUUID == CBUUID(string: "6D616350-696C-6F74-0001-000000000002"))
        // The leading bytes are ASCII "macPilot" so the traffic is recognisable
        // in a packet capture.
        #expect(Array(RemoteBLEService.serviceUUID.data.prefix(8)) == Array("macPilot".utf8))
        // A copy-paste that collapsed these into one UUID would make the phone
        // read a characteristic the Mac never answers.
        #expect(RemoteBLEService.serviceUUID != RemoteBLEService.psmCharacteristicUUID)
    }
}
