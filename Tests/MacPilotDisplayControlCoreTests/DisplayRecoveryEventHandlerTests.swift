import Dispatch
import Darwin
import Foundation
import Testing
@testable import MacPilotDisplayControlCore

@MainActor
struct DisplayRecoveryEventHandlerTests {
    @Test func utilityTimerCallbacksEnqueueEachTickOffTheCreatingActor() {
        let operations = DispatchQueue(label: "display-recovery.event-handler.operations", qos: .utility)
        let timerQueue = DispatchQueue(label: "display-recovery.event-handler.timer", qos: .utility)
        let probe = RecoveryCallbackProbe()
        probe.markExpectedQueue(operations)

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        let callback = DisplayRecoveryEventHandler.enqueue(on: operations) {
            if probe.recordOperation() == 3 { timer.cancel() }
        }
        timer.schedule(deadline: .now() + .milliseconds(1), repeating: .milliseconds(20))
        timer.setEventHandler(handler: callback)
        timer.resume()
        defer { timer.cancel() }

        for _ in 0..<3 {
            #expect(probe.waitForOperation(timeout: .seconds(2)))
        }
        #expect(probe.operationCount == 3)
        #expect(probe.allOperationsUsedExpectedQueue)
    }

    @Test func simulatedSignalCallbackEnqueuesFromUtilityQueue() {
        let operations = DispatchQueue(label: "display-recovery.event-handler.signal-operations", qos: .utility)
        let signalQueue = DispatchQueue.global(qos: .utility)
        let probe = RecoveryCallbackProbe()
        probe.markExpectedQueue(operations)

        let signalEventHandler = DisplayRecoveryEventHandler.enqueue(on: operations) {
            probe.recordOperation()
        }
        // The helper registers this factory result on its SIGTERM DispatchSource.
        // Simulate that callback on the source queue without registering a
        // process signal handler or sending a real signal.
        signalQueue.async(execute: signalEventHandler)

        #expect(probe.waitForOperation(timeout: .seconds(2)))
        #expect(probe.operationCount == 1)
        #expect(probe.allOperationsUsedExpectedQueue)
    }
}

private final class RecoveryCallbackProbe: @unchecked Sendable {
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueMarker = UUID()
    private let lock = NSLock()
    private let operationFinished = DispatchSemaphore(value: 0)
    private var count = 0
    private var allOperationsOnExpectedQueue = true

    func markExpectedQueue(_ queue: DispatchQueue) {
        queue.setSpecific(key: queueKey, value: queueMarker)
    }

    var operationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var allOperationsUsedExpectedQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return allOperationsOnExpectedQueue
    }

    @discardableResult
    func recordOperation() -> Int {
        let isOnExpectedQueue = DispatchQueue.getSpecific(key: queueKey) == queueMarker
        lock.lock()
        count += 1
        allOperationsOnExpectedQueue = allOperationsOnExpectedQueue && isOnExpectedQueue
        let currentCount = count
        lock.unlock()
        operationFinished.signal()
        return currentCount
    }

    func waitForOperation(timeout: Duration) -> Bool {
        let components = timeout.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return operationFinished.wait(timeout: .now() + seconds) == .success
    }
}
