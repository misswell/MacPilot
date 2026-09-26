import Foundation
import Testing
@testable import MacPilotRightClickKit

struct RightClickLifecycleTests {
    @Test func mainProcessDistributedObserverStopsWithTheFeature() {
        let messager = Messager()
        #expect(!messager.isObserving)
        messager.startObserving()
        messager.startObserving()
        #expect(messager.isObserving)
        messager.stopObserving()
        #expect(!messager.isObserving)
    }
}
