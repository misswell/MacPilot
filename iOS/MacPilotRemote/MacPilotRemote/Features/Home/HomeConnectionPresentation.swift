/// Presentation follows the connection attempt before considering discovery results.
enum HomeConnectionPresentation: Equatable {
    case connected
    case inProgress(titleKey: String)
    case failed(detail: String)
    case unpaired
    case notFound

    init(state: RemoteConnectionState, hasUnpairedMac: Bool) {
        switch state {
        case .connected:
            self = .connected
        case .discovering where hasUnpairedMac:
            self = .unpaired
        case .discovering, .connecting, .pairing, .authenticating, .reconnecting:
            self = .inProgress(titleKey: state.titleKey)
        case .failed(let detail):
            self = .failed(detail: detail)
        case .idle:
            self = hasUnpairedMac ? .unpaired : .notFound
        }
    }

    static func showsSuccessBanner(state: RemoteConnectionState) -> Bool {
        state.isConnected
    }
}
