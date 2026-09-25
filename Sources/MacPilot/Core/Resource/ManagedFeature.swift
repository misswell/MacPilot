import Foundation

@MainActor
protocol ManagedFeature: AnyObject {
    var identifier: String { get }
    var isRunning: Bool { get }
    func start()
    func stop()
}
