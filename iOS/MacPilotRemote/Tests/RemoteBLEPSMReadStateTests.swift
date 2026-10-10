import CoreBluetooth
import Foundation
import Testing

@testable import PilotNest

struct RemoteBLEPSMReadStateTests {
    @Test func republishedChannelReadDoesNotRetainPreviousPSM() {
        var state = RemoteBLEPSMReadState()
        state.publish(0x00C0)
        let characteristic = RemoteBLEPSMCharacteristic.make()
        #expect(state.response(offset: 0) == Data([0xC0, 0x00]))

        state.clear()
        #expect(state.response(offset: 0) == nil)

        state.publish(0x00C4)
        #expect(characteristic.value == nil)
        #expect(state.response(offset: 0) == Data([0xC4, 0x00]))
        #expect(state.response(offset: 1) == Data([0x00]))
        #expect(state.response(offset: 2) == Data())
        #expect(state.response(offset: -1) == nil)
        #expect(state.response(offset: 3) == nil)
    }
}
